//! 真实集群 StorageTask 状态回写（kube-rs，设计 §3.4 单写者原则）。
//!
//! 仅 Agent 写 `StorageTask.status`；控制面 StorageTaskReconciler 据此回写 NodeDisk/NodeVG。
//! 采用 **轮询 list + 客户端按 nodeName 过滤**（CRD 不支持自定义字段选择器，且 POC 规模下足够）。
//! 终态（Succeeded/Failed）任务跳过，保证幂等；taskID 去重由 executor 负责。

use crate::executor::{self, ExecPlan, HostState, StorageTask as ExecTask};
use crate::reporter::{plan_to_status, TaskStatus};
use anyhow::Result;
use kube::{
    api::{Api, ListParams, Patch, PatchParams},
    Client,
};
use kube::CustomResource;
use serde::{Deserialize, Serialize};
use std::sync::{Arc, RwLock};
use std::time::Duration;

/// 尝试构建集群客户端（in-cluster 或 kubeconfig，§5 / §6.2）。
pub async fn try_client() -> Result<Client> {
    Ok(Client::try_default().await?)
}

/// 镜像 Go 侧 StorageTaskSpec（仅 Agent 消费所需字段，§3.4）。
#[derive(CustomResource, Clone, Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[kube(
    group = "storage.hlvm.io",
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
        task_type: executor::TaskType::from_str(&t.spec.type_).unwrap_or(executor::TaskType::PVCreate),
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

/// StorageTask 回写协调循环（§3.4）：轮询 → 节点过滤 → executor → 回写。
///
/// 永不退出（常驻）；错误仅告警并继续下一轮。
pub async fn run_task_reconciler(
    client: Client,
    node: &str,
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
                for task in list.items {
                    if task.spec.node_name != node {
                        continue; // 客户端按 nodeName 过滤（CRD 不支持自定义字段选择器）。
                    }
                    if is_terminal(&task) {
                        continue; // 终态跳过。
                    }
                    let name = task.metadata.name.clone().unwrap_or_default();
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
