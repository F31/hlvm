//! agent 模式主循环（设计 §5）：发现 → SMART → 预检 → 消费 StorageTask 回写闭环。
//!
//! 数据面独立于控制面（§1.4）：无任务时不写任何 PV/VG/thinpool。
//! 真实写路径经 executor 执行 + kube-rs 回写 `StorageTask.status`（单写者原则，§3.4）。

use crate::common::Health;
use crate::discovery::{self, LsblkDevice};
use crate::executor::HostState;
use crate::lvm;
use crate::precheck::{self, DiskPhase, PrecheckInput};
use crate::reporter;
use crate::smart;
use anyhow::Result;
use std::path::Path;
use std::process::Command;
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
        ..Default::default()
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

/// 对单块候选盘执行观测（真实命令）：签名(blkid) + 系统盘(lsblk 挂载点) + 容量 + 健康。
///
/// 返回供 NodeDisk 状态写回的观测数据（§3.1 / §3.2）。multipath/dm holders 持有者检测在
/// POC 阶段暂以空处理（`parse_lsblk_holders` 仍由单测覆盖，集成扫描后续接入 `lsblk -s`）。
pub struct NodeDiskObservation {
    pub health: Health,
    pub eligible: bool,
    pub is_system_disk: bool,
    pub occupied_by: Option<String>,
    pub capacity_bytes: Option<u64>,
}

/// 观测单块盘的预检与健康（运行时真实执行，§3.1 / §3.2）。
pub fn scan_node_disk(device_by_id: &str) -> Result<NodeDiskObservation> {
    // 健康采集（失败占位 Healthy，不臆断）。
    let health = smart::collect_health(device_by_id).unwrap_or(Health::Healthy);
    let media = smart::detect_media(device_by_id);

    // blkid 签名（存在 fstype 即拦截纳管）。
    let signatures = {
        match Command::new("blkid").args(["--json", device_by_id]).output() {
            Ok(o) if o.status.success() => {
                precheck::parse_blkid_signatures(&String::from_utf8_lossy(&o.stdout)).unwrap_or_default()
            }
            _ => Vec::new(),
        }
    };

    // lsblk：挂载点（系统盘判定）+ 容量。
    let (is_system_disk, capacity_bytes) = {
        match Command::new("lsblk")
            .args(["--json", "-b", "-o", "NAME,SERIAL,WWN,PATH,SIZE,TYPE,MOUNTPOINT", device_by_id])
            .output()
        {
            Ok(o) if o.status.success() => {
                let devs = discovery::parse_lsblk(&String::from_utf8_lossy(&o.stdout)).unwrap_or_default();
                let mut is_system = false;
                let mut cap = None;
                for d in &devs {
                    if let Some(sz) = &d.size {
                        if let Ok(b) = sz.parse::<u64>() {
                            cap = Some(b);
                        }
                    }
                    if let Some(mp) = &d.mountpoint {
                        if let Some(s) = mp.as_str() {
                            if SYS_MOUNTS.contains(&s) {
                                is_system = true;
                            }
                        }
                    }
                }
                (is_system, cap)
            }
            _ => (false, None),
        }
    };

    let input = PrecheckInput {
        is_system_disk,
        occupied_by: None,
        is_pv: false,
        smart_failed: health == Health::Failed,
        signatures,
        holders: Vec::new(),
        actual_media: Some(media),
        actual_capacity_bytes: capacity_bytes,
        tier: None,
    };
    let eligible = precheck::is_eligible(&input).unwrap_or(false);
    Ok(NodeDiskObservation {
        health,
        eligible,
        is_system_disk,
        occupied_by: None,
        capacity_bytes,
    })
}

/// 构建宿主机实际状态（发现 + 健康 + PV 列表），失败时仅告警，不中断。
///
/// 同时产出每块盘的拟写回 NodeDisk 观测状态（phase 由 Discovered 起，预检通过则 Candidate→PreChecked）。
fn build_host_state(host: &mut HostState) -> Vec<(String, reporter::NodeDiskStatus)> {
    let mut proposed: Vec<(String, reporter::NodeDiskStatus)> = Vec::new();
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
                let name = by_id.rsplit('/').next().unwrap_or(&by_id).to_string();
                let status = reporter::propose_nodedisk_status(
                    DiskPhase::Discovered,
                    eligible,
                    health,
                    is_system,
                    None,
                );
                proposed.push((name, status));
                tracing::info!(device = by_id, ?health, eligible, phase = status.phase.as_str(), "发现磁盘预检");
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
    proposed
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
    tracing::info!(node, "agent 启动：discovery → smart → pre检 → StorageTask 回写 + NodeDisk 观测写回");
    let mut host = HostState {
        node: node.to_string(),
        ..Default::default()
    };
    let proposed = build_host_state(&mut host);

    match reporter::kube_rw::try_client().await {
        Ok(client) => {
            let shared = Arc::new(RwLock::new(host));
            // 数据面任务回写（StorageTask.status，§3.4 单写者）。
            let task_handle = tokio::spawn(reporter::kube_rw::run_task_reconciler(
                client.clone(),
                node.to_string(),
                shared,
            ));
            // 观测类 NodeDisk.status 写回（Agent 周期观测，§3.1 / §3.2）。
            let nd_handle = tokio::spawn(reporter::kube_rw::run_nodedisk_reconciler(
                client,
                node.to_string(),
            ));
            // 二者均为常驻循环；等待主循环（任务回写）结束（实际不退出）。
            let _ = task_handle.await;
            let _ = nd_handle.await;
            Ok(())
        }
        Err(e) => {
            // 未接入集群（脱机诊断/测试）：日志演示 NodeDisk 拟写回，无任务则不写。
            let r = reporter::LogNodeDiskReporter;
            for (name, status) in &proposed {
                let _ = r.report(name, status);
            }
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
