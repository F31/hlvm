//! 真实集群 StorageTask 状态回写（kube-rs，设计 §3.4 单写者原则）。
//!
//! 仅 Agent 写 `StorageTask.status`；控制面 StorageTaskReconciler 据此回写 NodeDisk/NodeVG。
//! 采用 **轮询 list + 客户端按 nodeName 过滤**（CRD 不支持自定义字段选择器，且 POC 规模下足够）。
//! 终态（Succeeded/Failed）任务跳过，保证幂等；taskID 去重由 executor 负责。

use crate::executor::{self, ExecPlan, HostState, StorageTask as ExecTask};
use crate::precheck::DiskPhase;
use crate::reporter::{plan_to_status, NodeDiskStatus, TaskStatus};
use anyhow::Result;
use kube::CustomResource;
use kube::{
    api::{Api, ListParams, Patch, PatchParams},
    Client,
};
use serde::{Deserialize, Serialize};
use std::sync::{Arc, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// 尝试构建集群客户端（in-cluster 或 kubeconfig，§5 / §6.2）。
pub async fn try_client() -> Result<Client> {
    Ok(Client::try_default().await?)
}

/// 镜像 Go 侧 StorageTaskSpec（仅 Agent 消费所需字段，§3.4）。
#[derive(CustomResource, Clone, Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[kube(
    group = "storage.example.io",
    version = "v1alpha1",
    kind = "StorageTask",
    status = "StorageTaskStatusMirror"
)]
pub struct StorageTaskSpecMirror {
    #[serde(rename = "nodeName")]
    pub node_name: String,
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(rename = "target", default)]
    pub target: Option<StorageTaskTargetMirror>,
    #[serde(rename = "disks", default)]
    pub disks: Vec<String>,
    #[serde(rename = "confirmSerial", default)]
    pub confirm_serial: String,
    #[serde(rename = "dryRun", default)]
    pub dry_run: bool,
    #[serde(rename = "approvedBy", default)]
    pub approved_by: String,
    #[serde(rename = "ttl", default)]
    pub ttl: String,
}

/// 镜像 StorageTaskSpec.target（diskRef）。
#[derive(Clone, Debug, Deserialize, Serialize, Default, schemars::JsonSchema)]
pub struct StorageTaskTargetMirror {
    #[serde(rename = "diskRef", default)]
    pub disk_ref: String,
}

/// 镜像 StorageTaskStatus（读取用，回写经 patch_status）。
#[derive(Clone, Debug, Deserialize, Serialize, Default, schemars::JsonSchema)]
pub struct StorageTaskStatusMirror {
    #[serde(rename = "phase", default)]
    pub phase: Option<String>,
    #[serde(rename = "result", default)]
    pub result: Option<String>,
    #[serde(rename = "message", default)]
    pub message: Option<String>,
}

/// 将集群侧 StorageTask 转换为 executor 内部任务（含目标盘解析）。
fn to_exec_task(t: &StorageTask) -> ExecTask {
    let target = t
        .spec
        .target
        .as_ref()
        .map(|x| x.disk_ref.clone())
        .filter(|s| !s.is_empty())
        .or_else(|| t.spec.disks.first().cloned())
        .unwrap_or_default();
    ExecTask {
        task_id: t.metadata.name.clone().unwrap_or_default(),
        node: t.spec.node_name.clone(),
        task_type: executor::TaskType::from_str(&t.spec.type_)
            .unwrap_or(executor::TaskType::PVCreate),
        target,
        confirm_serial: if t.spec.confirm_serial.is_empty() {
            None
        } else {
            Some(t.spec.confirm_serial.clone())
        },
        dry_run: t.spec.dry_run,
        approved_by: if t.spec.approved_by.is_empty() {
            None
        } else {
            Some(t.spec.approved_by.clone())
        },
    }
}

/// 真实集群回写器（patch /status 子资源）。
pub struct KubeReporter {
    api: Api<StorageTask>,
}

impl KubeReporter {
    pub fn new(client: Client) -> Self {
        KubeReporter {
            api: Api::all(client),
        }
    }

    /// 异步回写状态（§3.4）。patch_status 仅作用于 status 子资源（单写者）。
    pub async fn report(&self, name: &str, status: &TaskStatus) -> Result<()> {
        let patch = crate::reporter::build_status_patch(status);
        self.api
            .patch_status(name, &PatchParams::default(), &Patch::Merge(&patch))
            .await?;
        Ok(())
    }
}

/// 任务是否已是终态（跳过不再处理，保证幂等）。
fn is_terminal(t: &StorageTask) -> bool {
    matches!(
        t.status.as_ref().and_then(|s| s.phase.as_deref()),
        Some("Succeeded") | Some("Failed")
    )
}

/// 当前 Unix 毫秒（TTL 复核用；亚秒精度避免短 TTL 被截断）。
fn now_unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// agent 侧执行窗口复核（ADR-006 补遗「残余竞态」）。
///
/// 返回 `Some(reason)` 表示**不得执行**，并应把任务标记 `Failed`。语义与控制面逐条对齐：
/// 只拦截尚未开始的任务（phase 为空或 `Pending`）；`Running`/`Unknown` 不覆盖执行结果；
/// TTL 非法或 `<= 0` 失败关闭；缺少 `creationTimestamp` 同样失败关闭。
fn expired_reason(task: &StorageTask, now_ms: i64) -> Option<String> {
    if task.spec.ttl.trim().is_empty() {
        return None;
    }
    match task.status.as_ref().and_then(|s| s.phase.as_deref()) {
        None | Some("Pending") => {}
        _ => return None,
    }
    let Some(created) = task.metadata.creation_timestamp.as_ref() else {
        return Some(format!(
            "{}任务缺少 creationTimestamp，无法评估执行窗口；按失败关闭策略拒绝执行",
            crate::common::ttl::DEADLINE_EXCEEDED_PREFIX
        ));
    };
    match crate::common::evaluate_task_window(&task.spec.ttl, created.0.as_millisecond(), now_ms) {
        crate::common::TaskWindow::Expired(reason) => Some(reason),
        _ => None,
    }
}

/// StorageTask 回写协调循环（§3.4）：轮询 → 节点过滤 → executor → 回写。
///
/// 永不退出（常驻）；错误仅告警并继续下一轮。
pub async fn run_task_reconciler(
    client: Client,
    node: String,
    host: Arc<RwLock<HostState>>,
) -> Result<()> {
    let api: Api<StorageTask> = Api::all(client);
    let reporter = KubeReporter { api: api.clone() };
    let lp = ListParams::default();
    let mut acked: Vec<String> = Vec::new();

    tracing::info!(node, "进入 StorageTask 回写协调循环（kube-rs）");
    loop {
        match api.list(&lp).await {
            Ok(list) => {
                let now_ms = now_unix_millis();
                for task in list.items {
                    if task.spec.node_name != node {
                        continue; // 客户端按 nodeName 过滤（CRD 不支持自定义字段选择器）。
                    }
                    if is_terminal(&task) {
                        continue; // 终态跳过。
                    }
                    let name = task.metadata.name.clone().unwrap_or_default();
                    // 执行前复核执行窗口：关闭「控制面标记前已取走任务」的残余竞态。
                    if let Some(reason) = expired_reason(&task, now_ms) {
                        tracing::warn!(task = %name, %reason, "任务已超出执行窗口，拒绝执行");
                        if let Err(e) = reporter.report(&name, &TaskStatus::expired(reason)).await {
                            tracing::error!(task = name, "回写过期状态失败: {e}");
                        }
                        continue;
                    }
                    let exec = to_exec_task(&task);
                    let plans = executor::process_tasks(
                        std::slice::from_ref(&exec),
                        &host.read().map(|h| h.clone()).unwrap_or_default(),
                        &mut acked,
                    );
                    for (tid, plan) in plans {
                        let _ = &tid;
                        let outcome = if let ExecPlan::Run(_) = &plan {
                            Some(executor::execute(&plan))
                        } else {
                            None
                        };
                        let status = plan_to_status(&plan, outcome.as_ref());
                        if let Err(e) = reporter.report(&name, &status).await {
                            tracing::error!(task = name, "回写状态失败: {e}");
                        }
                    }
                }
            }
            Err(e) => tracing::warn!("list StorageTask 失败（下一轮重试）: {e}"),
        }
        tokio::time::sleep(Duration::from_secs(10)).await;
    }
}

// ----------------------------------------------------------------------------
// NodeDisk 观测状态写回（设计 §3.1 / §3.2）：Agent 作为磁盘真实观察者，周期写回 phase/health/
// occupiedBy/isSystemDisk；仅在变化或每 10 分钟低频刷新（避免 API 抖动）。任务结果字段
// （vgRef/raid 等）由控制面 StorageTaskReconciler 写，避免双写（§3.4）。
// ----------------------------------------------------------------------------

/// 镜像 Go 侧 NodeDiskSpec（Agent 仅消费 nodeName/deviceRef，§3.1）。
#[derive(CustomResource, Clone, Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[kube(
    group = "storage.example.io",
    version = "v1alpha1",
    kind = "NodeDisk",
    status = "NodeDiskStatusMirror"
)]
pub struct NodeDiskSpecMirror {
    #[serde(rename = "nodeName")]
    pub node_name: String,
    #[serde(rename = "deviceRef", default)]
    pub device_ref: String,
}

/// 镜像 Go 侧 NodeDiskStatus 观测字段（读用，写经 patch_status）。
#[derive(Clone, Debug, Deserialize, Serialize, Default, schemars::JsonSchema)]
pub struct NodeDiskStatusMirror {
    #[serde(rename = "phase", default)]
    pub phase: Option<String>,
    #[serde(rename = "health", default)]
    pub health: Option<String>,
    #[serde(rename = "occupiedBy", default)]
    pub occupied_by: Option<String>,
    #[serde(rename = "isSystemDisk", default)]
    pub is_system_disk: bool,
}

/// 真实集群 NodeDisk 观测状态写回器（patch `/status` 子资源）。
pub struct KubeNodeDiskReporter {
    api: Api<NodeDisk>,
}

impl KubeNodeDiskReporter {
    pub fn new(client: Client) -> Self {
        KubeNodeDiskReporter {
            api: Api::all(client),
        }
    }

    pub async fn report(&self, name: &str, status: &NodeDiskStatus) -> Result<()> {
        let patch = crate::reporter::build_nodedisk_patch(status);
        self.api
            .patch_status(name, &PatchParams::default(), &Patch::Merge(&patch))
            .await?;
        Ok(())
    }
}

/// 由集群侧 NodeDisk 当前状态构造用于 diff 的本地观测状态。
fn current_nodedisk_status(nd: &NodeDisk) -> NodeDiskStatus {
    let phase = DiskPhase::from_str(
        nd.status
            .as_ref()
            .and_then(|s| s.phase.as_deref())
            .unwrap_or("Discovered"),
    );
    let health = nd
        .status
        .as_ref()
        .and_then(|s| s.health.as_deref())
        .map(crate::common::Health::from_str_lowercase)
        .unwrap_or(crate::common::Health::Healthy);
    let occupied_by = nd.status.as_ref().and_then(|s| s.occupied_by.clone());
    NodeDiskStatus {
        phase,
        health,
        occupied_by,
        is_system_disk: nd
            .status
            .as_ref()
            .map(|s| s.is_system_disk)
            .unwrap_or(false),
    }
}

/// NodeDisk 观测状态写回协调循环（§3.1 / §3.2）：轮询本节点 NodeDisk → 观测 → 低频写回。
///
/// 永不退出（常驻）；错误仅告警并继续下一轮。每轮节流：变化立即写，否则每 10 分钟写一次。
pub async fn run_nodedisk_reconciler(client: Client, node: String) -> Result<()> {
    // kube 4.x 的 Api 无 `client()` 取值方法（旧版才有）；且 into_client 会消耗 api 本身
    // （后续 loop 仍需 api.list）。故先用入参 client 的 clone 构造 reporter，再 move 原 client 进 api。
    let reporter = KubeNodeDiskReporter::new(client.clone());
    let api: Api<NodeDisk> = Api::all(client);
    let lp = ListParams::default();
    let interval_millis: u64 = 600_000; // 10 分钟低频刷新（§3.1）。
    let mut last_refresh: Option<u64> = None;

    tracing::info!(node, "进入 NodeDisk 观测状态写回协调循环（kube-rs）");
    loop {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        match api.list(&lp).await {
            Ok(list) => {
                for nd in list.items {
                    if nd.spec.node_name != node {
                        continue;
                    }
                    let name = nd.metadata.name.clone().unwrap_or_default();
                    let device = nd.spec.device_ref.clone();
                    let current = current_nodedisk_status(&nd);
                    match crate::agent::scan_node_disk(&device) {
                        Ok(obs) => {
                            let next = crate::reporter::propose_nodedisk_status(
                                current.phase,
                                obs.eligible,
                                obs.health,
                                obs.is_system_disk,
                                obs.occupied_by,
                            );
                            let changed = crate::reporter::diff_nodedisk_status(&current, &next);
                            let refresh = crate::reporter::should_refresh(
                                last_refresh,
                                now,
                                changed,
                                interval_millis,
                            );
                            if refresh {
                                if let Err(e) = reporter.report(&name, &next).await {
                                    tracing::error!(disk = name, "NodeDisk 状态写回失败: {e}");
                                }
                                last_refresh = Some(now);
                            }
                        }
                        Err(e) => tracing::warn!(disk = device, "扫描盘观测失败（跳过）: {e}"),
                    }
                }
            }
            Err(e) => tracing::warn!("list NodeDisk 失败（下一轮重试）: {e}"),
        }
        tokio::time::sleep(Duration::from_secs(30)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use k8s_openapi::apimachinery::pkg::apis::meta::v1::{ObjectMeta, Time};

    fn task_with(ttl: &str, phase: Option<&str>, created_ms: Option<i64>) -> StorageTask {
        StorageTask {
            metadata: ObjectMeta {
                name: Some("t1".into()),
                creation_timestamp: created_ms
                    .map(|ms| Time(jiff::Timestamp::from_millisecond(ms).expect("合法毫秒"))),
                ..Default::default()
            },
            spec: StorageTaskSpecMirror {
                node_name: "n1".into(),
                type_: "pvcreate".into(),
                target: None,
                disks: Vec::new(),
                confirm_serial: String::new(),
                dry_run: false,
                approved_by: String::new(),
                ttl: ttl.into(),
            },
            status: phase.map(|p| StorageTaskStatusMirror {
                phase: Some(p.into()),
                ..Default::default()
            }),
        }
    }

    #[test]
    fn no_ttl_is_not_expired() {
        assert_eq!(
            expired_reason(&task_with("", None, Some(0)), 1_000_000),
            None
        );
    }

    #[test]
    fn expired_task_rejected_with_prefix() {
        // 创建于 1_000ms，ttl=2s，now=10_000ms → 过期。
        let reason =
            expired_reason(&task_with("2s", None, Some(1_000)), 10_000).expect("应判为过期");
        assert!(reason.starts_with(crate::common::ttl::DEADLINE_EXCEEDED_PREFIX));
    }

    #[test]
    fn within_window_not_expired() {
        assert_eq!(
            expired_reason(&task_with("1h", None, Some(1_000)), 10_000),
            None
        );
    }

    #[test]
    fn invalid_ttl_fails_closed() {
        assert!(expired_reason(&task_with("nonsense", None, Some(0)), 0).is_some());
    }

    #[test]
    fn running_task_is_not_overridden() {
        // 执行已开始：即便超出窗口也不改写 agent 的结果（与控制面单写者原则一致）。
        assert_eq!(
            expired_reason(&task_with("2s", Some("Running"), Some(0)), 60_000),
            None
        );
    }

    #[test]
    fn missing_creation_timestamp_fails_closed() {
        assert!(expired_reason(&task_with("2s", None, None), 0).is_some());
    }
}
