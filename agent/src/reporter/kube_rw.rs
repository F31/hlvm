//! 真实集群 StorageTask 状态回写（kube-rs，设计 §3.4 单写者原则）。
//!
//! 仅 Agent 写 `StorageTask.status`；控制面 StorageTaskReconciler 据此回写 NodeDisk/NodeVG。
//! 采用 **轮询 list + 客户端按 nodeName 过滤**（CRD 不支持自定义字段选择器，且 POC 规模下足够）。
//! 终态（Succeeded/Failed）任务跳过，保证幂等；taskID 去重由 executor 负责。

use crate::executor::{self, ExecPlan, HostState, StorageTask as ExecTask};
use crate::lvm::{LvInfo, ThinPoolInfo};
use crate::precheck::DiskPhase;
use crate::reporter::{plan_to_status, NodeDiskStatus, NodeVGLVReport, NodeVGLVStatus, TaskStatus};
use anyhow::{anyhow, Result};
use kube::CustomResource;
use kube::{
    api::{Api, ListParams, Patch, PatchParams},
    Client,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
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
    version = "v1beta1",
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

/// 镜像 v1beta1 的 `spec.device.path`（由 v1alpha1 的扁平 `deviceRef` 演进而来，§3.1）。
///
/// v1beta1 用结构体承载设备引用以便后续扩展 by-id / 分区 / 多路径字段；Agent 只消费 path。
#[derive(Clone, Debug, Deserialize, Serialize, Default, schemars::JsonSchema)]
pub struct NodeDiskDeviceMirror {
    #[serde(rename = "path", default)]
    pub path: String,
}

/// 镜像 Go 侧 NodeDiskSpec（v1beta1，Agent 仅消费 nodeName/device.path，§3.1）。
///
/// 版本已随控制面收敛到 v1beta1（storage 版本）：Agent 读写 v1beta1 不经 conversion webhook，
/// 与控制器的存储版本对齐。`Api<NodeDisk>` 由 #[kube(version)] 派生的 GVK 决定端点版本。
#[derive(CustomResource, Clone, Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[kube(
    group = "storage.example.io",
    version = "v1beta1",
    kind = "NodeDisk",
    status = "NodeDiskStatusMirror"
)]
pub struct NodeDiskSpecMirror {
    #[serde(rename = "nodeName")]
    pub node_name: String,
    #[serde(rename = "device", default)]
    pub device: Option<NodeDiskDeviceMirror>,
}

impl NodeDiskSpecMirror {
    /// 返回设备路径；device 为 nil 或 path 为空时返回空串（等价于旧版空 deviceRef）。
    pub fn device_path(&self) -> String {
        self.device
            .as_ref()
            .map(|d| d.path.clone())
            .unwrap_or_default()
    }
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
                    let device = nd.spec.device_path();
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

// ----------------------------------------------------------------------------
// NodeVG LV 上报（ADR-006 §16，三方对账的 lvs 一侧）
//
// Agent 周期读宿主 `lvs`（经 HLVM_HOST_WRAPPER，与写路径锁同源），过滤 thin-pool
// 自身/内部 LV 后，把本 VG 的业务 LV 写进 `NodeVG.status.logicalVolumes` 与
// `lastLVReportTime`。这两个字段的唯一写者是 Agent：控制面只读，且 Go 类型已声明
// 字段，故其 Status().Update 不会把上报抹掉。
// ----------------------------------------------------------------------------

/// 镜像 Go 侧 NodeVGSpec（Agent 仅消费 nodeName / thinPool.name）。
#[derive(CustomResource, Clone, Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[kube(
    group = "storage.example.io",
    version = "v1beta1",
    kind = "NodeVG",
    status = "NodeVGStatusMirror"
)]
pub struct NodeVGSpecMirror {
    #[serde(rename = "nodeName")]
    pub node_name: String,
    #[serde(rename = "thinPool", default)]
    pub thin_pool: Option<NodeVGThinPoolMirror>,
}

#[derive(Clone, Debug, Deserialize, Serialize, Default, schemars::JsonSchema)]
pub struct NodeVGThinPoolMirror {
    #[serde(rename = "name", default)]
    pub name: String,
}

/// 镜像 status.logicalVolumes 的单条记录（读回用于 diff，字段名与 Go 对齐）。
#[derive(Clone, Debug, Deserialize, Serialize, Default, schemars::JsonSchema)]
pub struct NodeVGLVReportMirror {
    #[serde(rename = "name", default)]
    pub name: String,
    #[serde(rename = "bytes", default)]
    pub bytes: u64,
}

/// 镜像 NodeVG.status 中 Agent 负责的字段（其余字段由控制面写，Agent 不解析不覆盖）。
#[derive(Clone, Debug, Deserialize, Serialize, Default, schemars::JsonSchema)]
pub struct NodeVGStatusMirror {
    #[serde(rename = "logicalVolumes", default)]
    pub logical_volumes: Vec<NodeVGLVReportMirror>,
    #[serde(rename = "lastLVReportTime", default)]
    pub last_lv_report_time: Option<String>,
    /// thin-pool 运行时容量（ADR-006 §23.11）。读回用于写回节流。
    #[serde(rename = "thinPool", default)]
    pub thin_pool: Option<NodeVGThinPoolStatusMirror>,
}

/// 镜像 `NodeVG.status.thinPool`（Go 侧 `VGThinPoolStatus`，字段名逐字对齐）。
#[derive(Clone, Debug, Deserialize, Serialize, Default, PartialEq, schemars::JsonSchema)]
pub struct NodeVGThinPoolStatusMirror {
    #[serde(rename = "currentSizeBytes", default)]
    pub current_size_bytes: u64,
    #[serde(rename = "dataPercent", default)]
    pub data_percent: f64,
    #[serde(rename = "metadataPercent", default)]
    pub metadata_percent: f64,
    #[serde(rename = "provisionedBytes", default)]
    pub provisioned_bytes: u64,
    #[serde(rename = "outOfSpace", default)]
    pub out_of_space: bool,
    #[serde(rename = "state", default)]
    pub state: String,
}

/// 真实集群 NodeVG LV 上报器（patch `/status` 子资源）。
pub struct KubeNodeVGReporter {
    api: Api<NodeVG>,
}

impl KubeNodeVGReporter {
    pub fn new(client: Client) -> Self {
        KubeNodeVGReporter {
            api: Api::all(client),
        }
    }

    pub async fn report(&self, name: &str, status: &NodeVGLVStatus) -> Result<()> {
        let patch = crate::reporter::build_nodevg_lv_patch(status);
        self.api
            .patch_status(name, &PatchParams::default(), &Patch::Merge(&patch))
            .await?;
        Ok(())
    }
}

/// 采集宿主 lvs 并过滤出业务 LV；解析失败按「未知」处理（不推断、不上报）。
fn collect_reportable_lvs() -> Result<Vec<LvInfo>> {
    let v = crate::lvm::report_lv()?;
    crate::lvm::reportable_lvs(&v).ok_or_else(|| anyhow!("lvs JSON 结构异常，按未知处理"))
}

/// 按 VG 名筛出本 NodeVG 的业务 LV（纯函数）。
fn lv_report_for_vg(lvs: &[LvInfo], vg_name: &str) -> Vec<NodeVGLVReport> {
    lvs.iter()
        .filter(|l| l.vg_name == vg_name)
        .map(|l| NodeVGLVReport {
            name: l.name.clone(),
            bytes: l.size_bytes,
        })
        .collect()
}

/// 从集群侧读回上一次上报的清单，用于 diff 节流（纯函数）。
fn current_lv_report(vg: &NodeVG) -> Vec<NodeVGLVReport> {
    vg.status
        .as_ref()
        .map(|s| {
            s.logical_volumes
                .iter()
                .map(|l| NodeVGLVReport {
                    name: l.name.clone(),
                    bytes: l.bytes,
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 采集宿主 thin-pool 容量；失败返回 `None`（调用方写 `state: unreadable`）。
///
/// 与 `collect_reportable_lvs` **分开调用**是刻意的：容量列（`data_percent` /
/// `lv_health_status`）在旧 LVM 上不存在，与对账共用一次读取会让对账一并停摆。
fn collect_thin_pools() -> Option<Vec<ThinPoolInfo>> {
    match crate::lvm::report_lv_capacity() {
        Ok(v) => crate::lvm::parse_thin_pools(&v),
        Err(e) => {
            tracing::warn!("thin-pool 容量采集失败（本轮标 unreadable，不沿用旧值）: {e}");
            None
        }
    }
}

/// 取出属于指定 NodeVG 的池（VG 名 + `spec.thinPool.name` 双匹配）。
fn pool_for_vg<'a>(
    pools: &'a [ThinPoolInfo],
    vg_name: &str,
    pool_name: &str,
) -> Option<&'a ThinPoolInfo> {
    pools
        .iter()
        .find(|p| p.vg_name == vg_name && p.pool_name == pool_name)
}

/// 本次是否值得写 `status.thinPool`（纯函数，写回节流）。
///
/// data/metadata 用 0.01 个百分点作死区：容量是连续量，每 30s 微动就写会在 etcd
/// 上制造无意义版本递增，进而放大控制面 reconcile 次数。state 变化立即写。
fn thin_pool_needs_write(vg: &NodeVG, pool: Option<&ThinPoolInfo>) -> bool {
    let next_state = match pool {
        Some(p) if p.data_percent.is_some() => {
            if p.out_of_space == Some(true) {
                "out-of-space"
            } else {
                "ok"
            }
        }
        _ => "unreadable",
    };
    let prev = vg.status.as_ref().and_then(|s| s.thin_pool.as_ref());
    let prev_state = prev.map(|v| v.state.as_str()).unwrap_or("");
    if prev_state != next_state {
        return true;
    }
    match (prev, pool) {
        (Some(v), Some(p)) => match (p.data_percent, p.metadata_percent) {
            (Some(d), Some(m)) => {
                (v.data_percent - d).abs() >= 0.01
                    || (v.metadata_percent - m).abs() >= 0.01
                    || v.provisioned_bytes != p.provisioned_bytes
                    || v.current_size_bytes != p.size_bytes
            }
            _ => false,
        },
        (Some(_), None) => false,
        (None, _) => true,
    }
}

fn now_rfc3339() -> String {
    jiff::Timestamp::now().to_string()
}

/// 把 thin-pool 容量同步写入各 NodeVG 的 `status.thinPool`（ADR-006 §23.11）。
///
/// 采集失败时写 `state: unreadable` 并清空数值（**不沿用旧值**），让控制面停止输出
/// `storage_thinpool_*` 序列，而不是让上一轮的 0% 冒充当前水位。
async fn sync_thin_pools(api: &Api<NodeVG>, mine: &[NodeVG], pools: Option<&[ThinPoolInfo]>) {
    for vg in mine {
        let name = vg.metadata.name.clone().unwrap_or_default();
        if name.is_empty() {
            continue;
        }
        let pool_name = vg
            .spec
            .thin_pool
            .as_ref()
            .map(|p| p.name.clone())
            .unwrap_or_default();
        let pool = if pool_name.is_empty() {
            None
        } else {
            pool_for_vg(pools.unwrap_or(&[]), &name, &pool_name)
        };
        if !thin_pool_needs_write(vg, pool) {
            continue;
        }
        let patch = crate::reporter::build_nodevg_thinpool_patch(pool);
        match api
            .patch_status(&name, &PatchParams::default(), &Patch::Merge(&patch))
            .await
        {
            Ok(_) => tracing::info!(
                vg = %name,
                data_percent = ?pool.and_then(|p| p.data_percent),
                out_of_space = ?pool.and_then(|p| p.out_of_space),
                "NodeVG thinPool 上报完成"
            ),
            Err(e) => tracing::error!(vg = %name, "NodeVG thinPool 上报失败: {e}"),
        }
    }
}

/// NodeVG LV 上报协调循环（§16）：30s 采样；清单变化立即写，否则 60s 保活写。
///
/// 保活写是必需的：控制面用 `lastLVReportTime` 判新鲜度（默认 3min），长时间无变化
/// 却不刷新时间戳会被判过期并整轮放弃对账。宿主 lvs 采集失败时**不写**，
/// 让时间戳自然老化（失败关闭，绝不拿旧清单冒充当前实测）。
pub async fn run_nodevg_lv_reconciler(client: Client, node: String) -> Result<()> {
    let reporter = KubeNodeVGReporter::new(client.clone());
    let api: Api<NodeVG> = Api::all(client);
    let lp = ListParams::default();
    let keepalive_millis: u64 = 60_000;
    let mut last_write: HashMap<String, u64> = HashMap::new();

    tracing::info!(node, "进入 NodeVG LV 上报协调循环（kube-rs，ADR-006 §16）");
    loop {
        let now = now_unix_millis().max(0) as u64;
        match api.list(&lp).await {
            Ok(list) => {
                let mine: Vec<NodeVG> = list
                    .items
                    .into_iter()
                    .filter(|v| v.spec.node_name == node)
                    .collect();
                if !mine.is_empty() {
                    // thin-pool 容量先写：它的采集与 LV 清单互相独立，
                    // 不能因为 lvs（对账列）失败而连带丢掉容量指标。
                    let pools = collect_thin_pools();
                    sync_thin_pools(&api, &mine, pools.as_deref()).await;

                    match collect_reportable_lvs() {
                        Ok(lvs) => {
                            for vg in &mine {
                                let name = vg.metadata.name.clone().unwrap_or_default();
                                let next = lv_report_for_vg(&lvs, &name);
                                let current = current_lv_report(vg);
                                let changed =
                                    crate::reporter::diff_nodevg_lv_report(&current, &next);
                                let due = match last_write.get(&name) {
                                    None => true,
                                    Some(t) => now.saturating_sub(*t) >= keepalive_millis,
                                };
                                if !changed && !due {
                                    continue;
                                }
                                let status = NodeVGLVStatus {
                                    logical_volumes: next,
                                    reported_at: now_rfc3339(),
                                };
                                let count = status.logical_volumes.len();
                                match reporter.report(&name, &status).await {
                                    Ok(_) => {
                                        last_write.insert(name.clone(), now);
                                        tracing::info!(vg = %name, count, "NodeVG LV 上报完成");
                                    }
                                    Err(e) => {
                                        tracing::error!(vg = %name, "NodeVG LV 上报失败: {e}")
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            tracing::warn!("宿主 lvs 采集失败（本轮不写、保留旧时间戳）: {e}")
                        }
                    }
                }
            }
            Err(e) => tracing::warn!("list NodeVG 失败（下一轮重试）: {e}"),
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

    fn lv(name: &str, vg: &str, bytes: u64) -> LvInfo {
        LvInfo {
            name: name.into(),
            vg_name: vg.into(),
            size_bytes: bytes,
            lv_attr: "Vwi-aotz--".into(),
            pool_lv: "thinpool".into(),
        }
    }

    #[test]
    fn lv_report_for_vg_only_takes_its_own_vg() {
        let lvs = vec![lv("lv-a", "vg-1", 1), lv("lv-b", "vg-2", 2)];
        let got = lv_report_for_vg(&lvs, "vg-1");
        assert_eq!(
            got,
            vec![NodeVGLVReport {
                name: "lv-a".into(),
                bytes: 1
            }]
        );
        assert!(lv_report_for_vg(&lvs, "vg-missing").is_empty());
    }

    fn nodevg_with_thin_pool_status(status: serde_json::Value) -> NodeVG {
        serde_json::from_value(serde_json::json!({
            "apiVersion": "storage.example.io/v1beta1",
            "kind": "NodeVG",
            "metadata": {"name": "hlvm-lvmd-vg-153"},
            "spec": {"nodeName": "n1", "thinPool": {"name": "thinpool"}},
            "status": status
        }))
        .expect("NodeVG 形状应可解码")
    }

    fn tp(data: f64, meta: f64, oos: bool) -> ThinPoolInfo {
        ThinPoolInfo {
            vg_name: "hlvm-lvmd-vg-153".into(),
            pool_name: "thinpool".into(),
            size_bytes: 38_654_705_664,
            data_percent: Some(data),
            metadata_percent: Some(meta),
            out_of_space: Some(oos),
            provisioned_bytes: 8_589_934_592,
        }
    }

    #[test]
    fn thin_pool_writes_on_first_seen_and_state_flip() {
        // 首次（status 里还没有 thinPool）必须写，否则控制面永远拿不到序列。
        let vg = nodevg_with_thin_pool_status(serde_json::json!({}));
        assert!(thin_pool_needs_write(&vg, Some(&tp(50.0, 10.0, false))));

        // state 由 ok 翻成 out-of-space 立即写，不受死区限制。
        let vg = nodevg_with_thin_pool_status(serde_json::json!({"thinPool": {
            "dataPercent": 99.9, "metadataPercent": 10.0, "state": "ok"
        }}));
        assert!(thin_pool_needs_write(&vg, Some(&tp(100.0, 10.0, true))));

        // 从 ok 转为采集失败（unreadable）也要写：必须把旧值清掉。
        assert!(thin_pool_needs_write(&vg, None));
    }

    #[test]
    fn thin_pool_writes_throttled_inside_deadband() {
        let vg = nodevg_with_thin_pool_status(serde_json::json!({"thinPool": {
            "currentSizeBytes": 38654705664_u64,
            "dataPercent": 50.0,
            "metadataPercent": 10.0,
            "provisionedBytes": 8589934592_u64,
            "outOfSpace": false,
            "state": "ok"
        }}));
        // 0.005 个百分点在死区内：不写，避免 30s 一次的无意义 etcd 版本递增。
        assert!(!thin_pool_needs_write(&vg, Some(&tp(50.005, 10.0, false))));
        // 死区外的变化要写。注意别用 50.01 当边界：IEEE754 下 50.01-50.0=0.00999…，
        // 略小于 0.01，会把边界值误判成「无变化」。死区只负责抑制抖动，不承担精确语义。
        assert!(thin_pool_needs_write(&vg, Some(&tp(50.02, 10.0, false))));
        // 池被 dmeventd 扩容（size 变）必须写，否则超分比例一直是旧分母。
        let mut grown = tp(50.0, 10.0, false);
        grown.size_bytes += 1;
        assert!(thin_pool_needs_write(&vg, Some(&grown)));
        // 双方都是 unreadable 时不必反复写。
        let vg_u =
            nodevg_with_thin_pool_status(serde_json::json!({"thinPool": {"state": "unreadable"}}));
        assert!(!thin_pool_needs_write(&vg_u, None));
    }

    #[test]
    fn pool_for_vg_requires_vg_and_pool_name_match() {
        let pools = vec![tp(1.0, 1.0, false)];
        assert!(pool_for_vg(&pools, "hlvm-lvmd-vg-153", "thinpool").is_some());
        assert!(pool_for_vg(&pools, "hlvm-lvmd-vg-153", "other-pool").is_none());
        assert!(pool_for_vg(&pools, "other-vg", "thinpool").is_none());
        assert!(pool_for_vg(&[], "hlvm-lvmd-vg-153", "thinpool").is_none());
    }

    #[test]
    fn nodevg_mirror_decodes_agent_status_fields() {
        let vg: NodeVG = serde_json::from_value(serde_json::json!({
            "apiVersion": "storage.example.io/v1beta1",
            "kind": "NodeVG",
            "metadata": {"name": "hlvm-lvmd-vg-153"},
            "spec": {"nodeName": "10-60-153-100", "thinPool": {"name": "thinpool"}},
            "status": {
                "freeBytes": 2143289344,
                "logicalVolumes": [{"name": "lv-a", "bytes": 1073741824}],
                "lastLVReportTime": "2026-11-12T02:00:00Z"
            }
        }))
        .expect("真机形状应可解码");
        assert_eq!(vg.spec.node_name, "10-60-153-100");
        assert_eq!(
            vg.spec.thin_pool.as_ref().map(|p| p.name.as_str()),
            Some("thinpool")
        );
        assert_eq!(
            current_lv_report(&vg),
            vec![NodeVGLVReport {
                name: "lv-a".into(),
                bytes: 1073741824
            }]
        );
        assert_eq!(
            vg.status.as_ref().unwrap().last_lv_report_time.as_deref(),
            Some("2026-11-12T02:00:00Z")
        );
        // status 里控制面负责的字段 Agent 不解析、不覆盖（Patch::Merge 只动两个 key）。
        let no_status: NodeVG = serde_json::from_value(serde_json::json!({
            "metadata": {"name": "vg-x"},
            "spec": {"nodeName": "n1"}
        }))
        .expect("缺 status 也应可解码");
        assert!(current_lv_report(&no_status).is_empty());
    }

    #[test]
    fn agent_timestamp_is_valid_metav1_time() {
        use k8s_openapi::apimachinery::pkg::apis::meta::v1::Time;
        let s = now_rfc3339();
        let parsed: Time =
            serde_json::from_value(serde_json::json!(s)).expect("Go metav1.Time 必须能解析");
        assert!(parsed.0.as_millisecond() > 0);
    }
}
