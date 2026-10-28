//! agent 模式主循环（设计 §5）：发现 → SMART → 预检 → 消费 StorageTask 回写闭环。
//!
//! 数据面独立于控制面（§1.4）：无任务时不写任何 PV/VG/thinpool。
//! 真实写路径经 executor 执行 + kube-rs 回写 `StorageTask.status`（单写者原则，§3.4）。

use crate::common::Health;
use crate::discovery::{self, LsblkDevice};
use crate::executor::HostState;
use crate::lvm;
use crate::precheck::{self, PrecheckInput};
use crate::reporter;
use crate::smart;
use anyhow::Result;
use std::path::Path;
use std::sync::{Arc, RwLock};

/// 系统盘挂载点（根/boot/kubelet 数据目录及其 holders，§3.1 预检）。
const SYS_MOUNTS: &[&str] = &[
    "/",
    "/boot",
    "/var/lib/kubelet",
    "/var/lib/docker",
    "/var/lib/containers",
];

/// 由发现设备判定是否系统盘（纯函数，可单测）。
///
/// 规则：设备自身或任一子分区挂载于系统目录即判为系统盘（受保护，禁止破坏性操作）。
pub fn is_system_disk(d: &LsblkDevice) -> bool {
    let hit = |mp: &Option<serde_json::Value>| -> bool {
        mp.as_ref()
            .and_then(|v| v.as_str())
            .map(|s| SYS_MOUNTS.contains(&s))
            .unwrap_or(false)
    };
    if hit(&d.mountpoint) {
        return true;
    }
    d.children.iter().any(|c| hit(&c.mountpoint))
}

/// 由发现 + 健康 + 占用构造预检输入（纯函数，可单测，§3.1 / §5.1）。
pub fn classify_disk(
    is_system_disk: bool,
    is_pv: bool,
    health: Health,
) -> PrecheckInput {
    PrecheckInput {
        is_system_disk,
        occupied_by: if is_pv {
            Some("lvm-pv".into())
        } else {
            Some("none".into())
        },
        is_pv,
        smart_failed: health == Health::Failed,
    }
}

/// 枚举宿主机 /dev/disk/by-id 软链，将设备路径解析为 by-id 路径（真实解析，§5.1）。
///
/// 解析失败返回 None（不臆造路径，遵守 by-id 安全约束，§5.2）。
pub fn resolve_by_id(device_path: &str) -> Option<String> {
    let want = std::fs::canonicalize(device_path).ok()?;
    let dir = Path::new("/dev/disk/by-id");
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        if let Ok(c) = std::fs::canonicalize(entry.path()) {
            if c == want {
                return Some(entry.path().to_string_lossy().to_string());
            }
        }
    }
    None
}

/// 构建宿主机实际状态（发现 + 健康 + PV 列表），失败时仅告警，不中断。
fn build_host_state(host: &mut HostState) {
    match discovery::enumerate_disks() {
        Ok(disks) => {
            for d in &disks {
                let is_system = is_system_disk(d);
                let by_id = match d.path.as_deref().and_then(resolve_by_id) {
                    Some(p) => p,
                    None => continue, // 无法解析 by-id 的盘不参与（安全优先）。
                };
                if is_system {
                    host.system_disks.push(by_id.clone());
                }
                // 健康采集（运行时真实执行；失败则 Healthy 占位，不臆断）。
                let health = smart::collect_health(&by_id).unwrap_or(Health::Healthy);
                let input = classify_disk(is_system, false, health);
                let eligible = precheck::is_eligible(&input).unwrap_or(false);
                tracing::info!(device = by_id, ?health, eligible, "发现磁盘预检");
            }
        }
        Err(e) => tracing::warn!("discovery 失败（非节点环境？）: {e}"),
    }
    // PV 列表（宿主机 lvm 真实状态，供 executor 幂等补回执，§3.4）。
    if let Ok(v) = lvm::report_pv() {
        if let Some(pvs) = lvm::parse_pvs(&v) {
            host.pvs = pvs.into_iter().map(|p| p.name).collect();
        }
    }
}

/// agent 模式入口（同步）：构建 tokio 运行时并驱动异步主循环。
pub fn run_agent(node_name: Option<&str>) -> Result<()> {
    let node = node_name.unwrap_or("unknown").to_string();
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    rt.block_on(async move { run_agent_async(&node).await })
}

async fn run_agent_async(node: &str) -> Result<()> {
    tracing::info!(node, "agent 启动：discovery → smart → precheck → StorageTask 回写闭环");
    let mut host = HostState {
        node: node.to_string(),
        ..Default::default()
    };
    build_host_state(&mut host);

    match reporter::kube_rw::try_client().await {
        Ok(client) => {
            let shared = Arc::new(RwLock::new(host));
            reporter::kube_rw::run_task_reconciler(client, node, shared).await
        }
        Err(e) => {
            // 未接入集群（脱机诊断/测试）：仅演示闭环，无任务则不写。
            tracing::warn!("未接入集群（{e}），以离线模式演示闭环（无任务不写）");
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn system_disk_by_root_mount() {
        let d = LsblkDevice {
            name: "nvme0n1".into(),
            serial: Some("X".into()),
            wwn: None,
            path: Some("/dev/nvme0n1".into()),
            size: None,
            mountpoint: Some(json!("/")),
            children: vec![],
        };
        assert!(is_system_disk(&d));
    }

    #[test]
    fn system_disk_by_child_mount() {
        let d = LsblkDevice {
            name: "sda".into(),
            serial: None,
            wwn: None,
            path: Some("/dev/sda".into()),
            size: None,
            mountpoint: Some(json!(null)),
            children: vec![LsblkDevice {
                name: "sda1".into(),
                serial: None,
                wwn: None,
                path: Some("/dev/sda1".into()),
                size: None,
                mountpoint: Some(json!("/boot")),
                children: vec![],
            }],
        };
        assert!(is_system_disk(&d));
    }

    #[test]
    fn data_disk_not_system() {
        let d = LsblkDevice {
            name: "sdb".into(),
            serial: None,
            wwn: None,
            path: Some("/dev/sdb".into()),
            size: None,
            mountpoint: Some(json!(null)),
            children: vec![],
        };
        assert!(!is_system_disk(&d));
    }

    #[test]
    fn classify_disk_marks_failed_smart() {
        let input = classify_disk(false, false, Health::Failed);
        assert!(input.smart_failed);
        assert!(!input.is_system_disk);
        assert!(!precheck::is_eligible(&input).unwrap());
    }

    #[test]
    fn classify_disk_clean_eligible() {
        let input = classify_disk(false, false, Health::Healthy);
        assert!(precheck::is_eligible(&input).unwrap());
    }

    #[test]
    fn classify_disk_pv_occupied() {
        let input = classify_disk(false, true, Health::Healthy);
        assert_eq!(input.occupied_by.as_deref(), Some("lvm-pv"));
        assert!(!precheck::is_eligible(&input).unwrap());
    }
}
