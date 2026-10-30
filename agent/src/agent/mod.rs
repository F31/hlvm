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
use crate::reporter::NodeDiskReporter;
use crate::smart;
use anyhow::Result;
use std::path::Path;
use std::process::Command;
use std::sync::{Arc, RwLock};

/// 系统盘挂载点（根/boot/swap/kubelet 数据目录及其 holders，§3.1 预检）。
///
/// `[SWAP]` 是 lsblk 对 swap 分区的 MOUNTPOINT 表示（没有真实挂载点）；设计 §3.1
/// 明确把 swap 纳入系统盘保护，漏掉它等于把 swap 盘当成可纳管盘。
const SYS_MOUNTS: &[&str] = &[
    "/",
    "/boot",
    "[SWAP]",
    "/var/lib/kubelet",
    "/var/lib/docker",
    "/var/lib/containers",
];

/// 由发现设备判定是否系统盘（纯函数，可单测）。
///
/// 规则：设备自身或任一子孙分区挂载于系统目录即判为系统盘（受保护，禁止破坏性操作）。
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
    d.children.iter().any(is_system_disk)
}

/// 占用类型标签（值域必须与 CRD `OccupiedBy` 枚举一致：
/// `none;filesystem;lvm-pv;md;mpath;holder;unknown`，见
/// `control-plane/api/v1alpha1/nodedisk_types.go`）。
///
/// 这些值写入 `NodeDisk.status.occupiedBy`，超出枚举范围会被 API Server 拒绝，
/// 导致整条观测状态写不进去。此前实现**恒写 `none`**：既有 PV 盘被判为「干净」，
/// `occupiedBy` 也永远是 `none`，运维看不到真实占用。
pub const OCC_NONE: &str = "none";
pub const OCC_FILESYSTEM: &str = "filesystem";
pub const OCC_LVM_PV: &str = "lvm-pv";
pub const OCC_MD: &str = "md";
pub const OCC_MPATH: &str = "mpath";
pub const OCC_HOLDER: &str = "holder";
pub const OCC_UNKNOWN: &str = "unknown";

/// 单块盘的 lsblk 观测结果（纯函数产物，可单测）。
pub struct LsblkInspection {
    /// 各层设备上的文件系统/LVM/RAID 签名（FSTYPE 列）。
    pub signatures: Vec<String>,
    pub is_system_disk: bool,
    pub capacity_bytes: Option<u64>,
    /// dm / mpath / md 子设备类型（用于占用判定）。
    pub holder_types: Vec<String>,
    /// 上述子设备名（用于预检原因文本）。
    pub holder_names: Vec<String>,
}

/// 解析 lsblk 结果并汇总观测事实（纯函数，§3.1）。
///
/// `parse_lsblk` 已把 children 拉平，因此这里按扁平列表逐项统计即可覆盖子分区/子设备。
pub fn inspect_devices(devs: &[LsblkDevice]) -> LsblkInspection {
    let mut signatures = Vec::new();
    let mut holder_types = Vec::new();
    let mut holder_names = Vec::new();
    for d in devs {
        if let Some(fs) = &d.fstype {
            if !fs.is_empty() {
                signatures.push(fs.clone());
            }
        }
        match d.dev_type.as_deref() {
            Some(t @ ("dm" | "mpath" | "md")) => {
                holder_types.push(t.to_string());
                holder_names.push(d.name.clone());
            }
            _ => {}
        }
    }
    LsblkInspection {
        is_system_disk: devs.iter().any(is_system_disk),
        capacity_bytes: devs
            .first()
            .and_then(|d| d.size.as_ref())
            .and_then(|s| s.parse::<u64>().ok()),
        signatures,
        holder_types,
        holder_names,
    }
}

/// 由观测事实推导 `occupiedBy` 标签（纯函数，返回值必属 CRD 枚举）。
///
/// 优先级：已注册为 PV > md 成员 > multipath > 其它 dm 持有 > 文件系统签名 >
/// 无法探测（unknown）> 干净（none）。
pub fn classify_occupied(
    signatures: &[String],
    holder_types: &[String],
    is_pv: bool,
    signatures_unknown: bool,
) -> &'static str {
    let has_sig = |want: &str| signatures.iter().any(|s| s == want);
    if is_pv || has_sig("LVM2_member") {
        return OCC_LVM_PV;
    }
    if holder_types.iter().any(|t| t == "md") || has_sig("linux_raid_member") {
        return OCC_MD;
    }
    if holder_types.iter().any(|t| t == "mpath") {
        return OCC_MPATH;
    }
    if !holder_types.is_empty() {
        return OCC_HOLDER;
    }
    if signatures.iter().any(|s| !s.is_empty()) {
        return OCC_FILESYSTEM;
    }
    if signatures_unknown {
        // 探测失败 ≠ 干净：不能把「不知道」写成 none 放行纳管。
        return OCC_UNKNOWN;
    }
    OCC_NONE
}

/// 判断两个设备路径是否指向同一设备（by-id 软链 ↔ `/dev/sdX` ↔ `/dev/mapper/...`）。
///
/// 解析失败时只承认字面相等（不臆断）。
pub fn device_matches(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(x), Ok(y)) => x == y,
        _ => false,
    }
}

/// 探测设备签名（兼容各版本 blkid）。
///
/// 只用 `blkid -o export`：端口稳定、老版本也支持。注意 `blkid` **没有** `--json`
/// 选项（那是 lsblk 的），此前实现调 `blkid --json` 永远失败，签名规则形同虚设。
fn probe_signatures(device: &str) -> precheck::SignatureProbe {
    match Command::new("blkid")
        .args(["-o", "export", device])
        .output()
    {
        Ok(o) => precheck::probe_outcome(
            o.status.code(),
            &String::from_utf8_lossy(&o.stdout),
            &String::from_utf8_lossy(&o.stderr),
        ),
        Err(_) => precheck::SignatureProbe::Unknown,
    }
}

/// 枚举宿主机 PV 列表（`pvs` 不可用时为空，交由签名判定兜底）。
fn host_pvs() -> Vec<String> {
    match lvm::report_pv() {
        Ok(v) => lvm::parse_pvs(&v)
            .map(|pvs| pvs.into_iter().map(|p| p.name).collect())
            .unwrap_or_default(),
        Err(_) => Vec::new(),
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
///
/// 一次 `lsblk` 取全：挂载点（系统盘）、容量、子设备类型（dm/mpath/md）、FSTYPE（签名）。
/// `blkid` 作为补充（能识别 lsblk 未上报的细节）；`pvs` 用于确认已注册的 PV。
/// `lsblk` 不可用时**失败关闭**：占用状态记为 `unknown` 且不可纳管，绝不把「不知道」写成 `none`。
pub fn scan_node_disk(device_by_id: &str) -> Result<NodeDiskObservation> {
    scan_node_disk_with_pvs(device_by_id, &host_pvs())
}

/// 同 `scan_node_disk`，但复用调用方已取得的 PV 列表（避免逐盘重复执行 `pvs`）。
pub fn scan_node_disk_with_pvs(device_by_id: &str, pvs: &[String]) -> Result<NodeDiskObservation> {
    // 健康采集（失败占位 Healthy，不臆断）。
    let health = smart::collect_health(device_by_id).unwrap_or(Health::Healthy);
    let media = smart::detect_media(device_by_id);

    // 签名探测（存在 fs/LVM/md 签名即拦截纳管）：`blkid -o export` 为主，lsblk FSTYPE 为辅。
    let mut signatures = Vec::new();
    let mut signatures_unknown = match probe_signatures(device_by_id) {
        precheck::SignatureProbe::Known(sigs) => {
            signatures.extend(sigs);
            false
        }
        precheck::SignatureProbe::Unknown => true,
    };

    // lsblk：挂载点 + 容量 + 子设备类型 + FSTYPE。
    let inspection = match Command::new("lsblk")
        .args([
            "--json",
            "-b",
            "-o",
            "NAME,SERIAL,WWN,PATH,SIZE,TYPE,MOUNTPOINT,FSTYPE",
            device_by_id,
        ])
        .output()
    {
        Ok(o) if o.status.success() => discovery::parse_lsblk(&String::from_utf8_lossy(&o.stdout))
            .ok()
            .map(|devs| inspect_devices(&devs)),
        _ => None,
    };
    let Some(insp) = inspection else {
        tracing::warn!(
            device = device_by_id,
            "lsblk 不可用，占用状态记为 unknown（失败关闭）"
        );
        return Ok(NodeDiskObservation {
            health,
            eligible: false,
            is_system_disk: false,
            occupied_by: Some(OCC_UNKNOWN.to_string()),
            capacity_bytes: None,
        });
    };

    // 容器内 lsblk 的 FSTYPE 依赖 udev 数据库，可能为 null（实测 kind 节点对已格式化 loop 设备
    // 就返回 null），因此它只作补充证据；一旦有值即可把「探测失败」升级为「已知」。
    if !insp.signatures.is_empty() {
        signatures.extend(insp.signatures.iter().cloned());
        signatures_unknown = false;
    }
    signatures.sort();
    signatures.dedup();

    // 「已是 PV」有两条独立证据：签名 LVM2_member，或 pvs 列表中真实注册（丢标签的 PV 只能后者发现）。
    let is_pv = signatures.iter().any(|s| s == "LVM2_member")
        || pvs.iter().any(|p| device_matches(p, device_by_id));
    let occupied = classify_occupied(&signatures, &insp.holder_types, is_pv, signatures_unknown);

    let input = PrecheckInput {
        is_system_disk: insp.is_system_disk,
        occupied_by: Some(occupied.to_string()),
        is_pv,
        smart_failed: health == Health::Failed,
        signatures,
        holders: insp.holder_names.clone(),
        actual_media: Some(media),
        actual_capacity_bytes: insp.capacity_bytes,
        tier: None,
    };
    let eligible = precheck::is_eligible(&input).unwrap_or(false);
    Ok(NodeDiskObservation {
        health,
        eligible,
        is_system_disk: insp.is_system_disk,
        occupied_by: Some(occupied.to_string()),
        capacity_bytes: insp.capacity_bytes,
    })
}

/// 构建宿主机实际状态（发现 + 健康 + PV 列表），失败时仅告警，不中断。
///
/// 同时产出每块盘的拟写回 NodeDisk 观测状态（phase 由 Discovered 起，预检通过则 Candidate→PreChecked）。
///
/// 占用判定与 `scan_node_disk` 共用同一条路径（签名 + dm/mpath/md 持有者 + PV 列表），
/// 避免启动期汇总与周期观测给出互相矛盾的结论。
fn build_host_state(host: &mut HostState) -> Vec<(String, reporter::NodeDiskStatus)> {
    let mut proposed: Vec<(String, reporter::NodeDiskStatus)> = Vec::new();
    // PV 列表必须先采集：预检的「已是 PV」规则依赖它（原先放在循环之后，判定时永远为空）。
    if let Ok(v) = lvm::report_pv() {
        if let Some(pvs) = lvm::parse_pvs(&v) {
            host.pvs = pvs.into_iter().map(|p| p.name).collect();
        }
    }
    let pvs = host.pvs.clone();
    match discovery::enumerate_disks() {
        Ok(disks) => {
            for d in &disks {
                let by_id = match d.path.as_deref().and_then(resolve_by_id) {
                    Some(p) => p,
                    None => continue, // 无法解析 by-id 的盘不参与（安全优先）。
                };
                if is_system_disk(d) {
                    host.system_disks.push(by_id.clone());
                }
                let obs = match scan_node_disk_with_pvs(&by_id, &pvs) {
                    Ok(o) => o,
                    Err(e) => {
                        tracing::warn!(device = by_id, "磁盘观测失败（跳过）: {e}");
                        continue;
                    }
                };
                let name = by_id.rsplit('/').next().unwrap_or(&by_id).to_string();
                let status = reporter::propose_nodedisk_status(
                    DiskPhase::Discovered,
                    obs.eligible,
                    obs.health,
                    obs.is_system_disk,
                    obs.occupied_by.clone(),
                );
                let phase = status.phase.as_str();
                proposed.push((name, status));
                tracing::info!(
                    device = by_id,
                    health = ?obs.health,
                    eligible = obs.eligible,
                    phase,
                    occupied = obs.occupied_by.as_deref().unwrap_or("-"),
                    "发现磁盘预检"
                );
            }
        }
        Err(e) => tracing::warn!("discovery 失败（非节点环境？）: {e}"),
    }
    proposed
}

/// agent 模式入口（同步）：构建 tokio 运行时并驱动异步主循环。
pub fn run_agent(node_name: Option<&str>) -> Result<()> {
    let node = resolve_node_name(node_name)?;
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    rt.block_on(async move { run_agent_async(&node).await })
}

/// 解析本节点名：命令行 > HLVM_NODE_NAME > NODE_NAME（Downward API）。
///
/// 必须失败关闭：`run_task_reconciler` 按 `spec.nodeName == node` 过滤任务，节点名缺失时
/// 旧实现回退为 "unknown"，Agent 看起来健康却**永远不执行任何任务**（静默空转，比报错更难发现）。
fn resolve_node_name(arg: Option<&str>) -> Result<String> {
    let hlvm = std::env::var("HLVM_NODE_NAME").ok();
    let node = std::env::var("NODE_NAME").ok();
    match pick_node_name(arg, hlvm.as_deref(), node.as_deref()) {
        Some(n) => Ok(n),
        None => anyhow::bail!(
            "未提供节点名：请传 --node-name，或由 Downward API 注入 HLVM_NODE_NAME / NODE_NAME"
        ),
    }
}

/// 纯函数：按优先级选出首个非空节点名（便于单测，不触碰进程环境）。
fn pick_node_name(
    arg: Option<&str>,
    hlvm_env: Option<&str>,
    node_env: Option<&str>,
) -> Option<String> {
    [arg, hlvm_env, node_env]
        .into_iter()
        .flatten()
        .map(str::trim)
        .find(|s| !s.is_empty())
        .map(str::to_string)
}

async fn run_agent_async(node: &str) -> Result<()> {
    tracing::info!(
        node,
        "agent 启动：discovery → smart → pre检 → StorageTask 回写 + NodeDisk 观测写回"
    );
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

    /// 常用测试构造：仅填关心字段，其余取默认（字段扩展不破坏既有用例）。
    fn dev(name: &str, size: Option<&str>, mountpoint: Option<serde_json::Value>) -> LsblkDevice {
        LsblkDevice {
            name: name.into(),
            size: size.map(str::to_string),
            mountpoint,
            ..Default::default()
        }
    }

    #[test]
    fn system_disk_by_root_mount() {
        assert!(is_system_disk(&dev("nvme0n1", None, Some(json!("/")))));
    }

    #[test]
    fn system_disk_by_child_mount() {
        let mut d = dev("sda", None, Some(json!(null)));
        d.children = vec![dev("sda1", None, Some(json!("/boot")))];
        assert!(is_system_disk(&d));
    }

    #[test]
    fn data_disk_not_system() {
        assert!(!is_system_disk(&dev("sdb", None, Some(json!(null)))));
    }

    // ---- 占用判定（NodeDisk.status.occupiedBy）----

    #[test]
    fn occupied_none_on_clean_disk() {
        assert_eq!(classify_occupied(&[], &[], false, false), OCC_NONE);
    }

    /// 探测失败必须与「干净」区分：`blkid` 缺失/不支持时不能放行纳管。
    #[test]
    fn occupied_unknown_when_probe_failed() {
        assert_eq!(classify_occupied(&[], &[], false, true), OCC_UNKNOWN);
        // 有确定证据时仍以后者为准（未知不覆盖已观测事实）。
        assert_eq!(
            classify_occupied(&["ext4".to_string()], &[], false, true),
            OCC_FILESYSTEM
        );
    }

    /// swap 盘按设计 §3.1 属系统盘（lsblk 以 `[SWAP]` 表示，没有真实挂载点）。
    #[test]
    fn swap_is_system_disk() {
        assert!(is_system_disk(&dev("sdc", None, Some(json!("[SWAP]")))));
    }

    #[test]
    fn occupied_lvm_pv_from_signature_or_pvs() {
        assert_eq!(
            classify_occupied(&["LVM2_member".to_string()], &[], false, false),
            OCC_LVM_PV
        );
        // 丢标签的 PV 只能由 pvs 列表发现（is_pv=true），仍需判为 lvm-pv。
        assert_eq!(classify_occupied(&[], &[], true, false), OCC_LVM_PV);
    }

    #[test]
    fn occupied_filesystem_wins_over_none() {
        assert_eq!(
            classify_occupied(&["ext4".to_string()], &[], false, false),
            OCC_FILESYSTEM
        );
    }

    #[test]
    fn occupied_md_by_signature_or_holder() {
        assert_eq!(
            classify_occupied(&["linux_raid_member".to_string()], &[], false, false),
            OCC_MD
        );
        assert_eq!(
            classify_occupied(&[], &["md".to_string()], false, false),
            OCC_MD
        );
    }

    #[test]
    fn occupied_mpath_and_generic_dm_holder() {
        assert_eq!(
            classify_occupied(&[], &["mpath".to_string()], false, false),
            OCC_MPATH
        );
        assert_eq!(
            classify_occupied(&[], &["dm".to_string()], false, false),
            OCC_HOLDER
        );
    }

    #[test]
    fn occupied_labels_are_distinct_and_stable() {
        // 值域与 CRD `OccupiedBy` 枚举对齐（跨语言一致性由 control-plane 的
        // occupiedby_enum_test.go 直接比对两侧源码，防止单侧改名）。
        let all = [
            OCC_NONE,
            OCC_FILESYSTEM,
            OCC_LVM_PV,
            OCC_MD,
            OCC_MPATH,
            OCC_HOLDER,
            OCC_UNKNOWN,
        ];
        let mut sorted = all.to_vec();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), all.len(), "占用标签必须互不相同");
        assert_eq!(
            all,
            [
                "none",
                "filesystem",
                "lvm-pv",
                "md",
                "mpath",
                "holder",
                "unknown"
            ]
        );
    }

    #[test]
    fn inspect_devices_collects_fstype_and_holders() {
        let json = r#"{"blockdevices":[
            {"name":"sdb","path":"/dev/sdb","size":1000204886016,"type":"disk",
             "mountpoint":null,"fstype":null,"children":[
                {"name":"sdb1","path":"/dev/sdb1","size":1000204886016,"type":"part",
                 "mountpoint":null,"fstype":"LVM2_member"},
                {"name":"dm-0","path":"/dev/dm-0","size":1000204886016,"type":"dm",
                 "mountpoint":null,"fstype":"xfs"}
            ]}
        ]}"#;
        let devs = discovery::parse_lsblk(json).unwrap();
        let insp = inspect_devices(&devs);
        assert_eq!(
            insp.signatures,
            vec!["LVM2_member".to_string(), "xfs".to_string()]
        );
        assert_eq!(insp.holder_types, vec!["dm".to_string()]);
        assert_eq!(insp.holder_names, vec!["dm-0".to_string()]);
        assert_eq!(insp.capacity_bytes, Some(1000204886016));
        assert!(!insp.is_system_disk);
        // 子分区带 LVM2_member ⇒ 归为 lvm-pv，而不是被 dm holder 覆盖。
        assert_eq!(
            classify_occupied(&insp.signatures, &insp.holder_types, false, false),
            OCC_LVM_PV
        );
    }

    #[test]
    fn inspect_devices_detects_system_mount_in_children() {
        let json = r#"{"blockdevices":[
            {"name":"sda","path":"/dev/sda","size":500107862016,"type":"disk","mountpoint":null,
             "children":[{"name":"sda2","path":"/dev/sda2","type":"part","mountpoint":"/"}]}
        ]}"#;
        let devs = discovery::parse_lsblk(json).unwrap();
        assert!(inspect_devices(&devs).is_system_disk);
    }

    #[test]
    fn device_matches_literal_paths() {
        assert!(device_matches("/dev/sdb", "/dev/sdb"));
        assert!(!device_matches("/dev/sdb", "/dev/sdc"));
        // 不存在的路径不做臆断。
        assert!(!device_matches("/dev/nonexistent-a", "/dev/nonexistent-b"));
    }

    /// 预检入口的「PV ⇒ 不可纳管」语义（实现唯一来源是 `precheck::classify_disk`，
    /// agent 侧曾经的副本已删除，避免两处语义漂移）。
    #[test]
    fn classify_disk_pv_occupied() {
        let input = precheck::classify_disk(false, true, Health::Healthy);
        assert_eq!(input.occupied_by.as_deref(), Some("lvm-pv"));
        assert!(!precheck::is_eligible(&input).unwrap());
    }

    #[test]
    fn pick_node_name_prefers_cli() {
        assert_eq!(
            pick_node_name(Some("node-a"), Some("node-b"), Some("node-c")).as_deref(),
            Some("node-a")
        );
    }

    #[test]
    fn pick_node_name_falls_back_to_downward_api() {
        assert_eq!(
            pick_node_name(None, Some("node-b"), Some("node-c")).as_deref(),
            Some("node-b")
        );
        assert_eq!(
            pick_node_name(None, None, Some("node-c")).as_deref(),
            Some("node-c")
        );
    }

    #[test]
    fn pick_node_name_ignores_blank() {
        // 空格/空串不得被当作有效节点名（否则过滤条件恒不成立，Agent 静默空转）。
        assert_eq!(
            pick_node_name(Some("  "), Some(""), Some("node-c")).as_deref(),
            Some("node-c")
        );
        assert_eq!(pick_node_name(None, None, None), None);
    }
}
