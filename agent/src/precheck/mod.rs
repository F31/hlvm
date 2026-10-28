//! 预检规则引擎（设计 §3.1 / §5.1）。
//!
//! 规则：系统盘、存在 fs/LVM/md 签名、被 multipath/dm 持有、已是 PV、SMART failed、
//! 容量/介质不符 tier。任一命中 ⇒ 不可进入 PreChecked（Candidate→PreChecked 由 agent 自动完成）。

use crate::smart::Media;
use anyhow::Result;
use serde_json::Value;

/// 预检输入（运行时由 discovery + smart + lvm + blkid 填充）。
pub struct PrecheckInput {
    pub is_system_disk: bool,
    pub occupied_by: Option<String>,
    pub is_pv: bool,
    pub smart_failed: bool,
    /// blkid 解析出的签名类型（fstype），如 ext4 / xfs / LVM2_member / linux_raid_member。
    /// 任一非空即视为存在签名（保守：有签名一律拦截纳管）。
    pub signatures: Vec<String>,
    /// lsblk holders / device-mapper 持有者名称（multipath/dm 设备）。
    pub holders: Vec<String>,
    /// 实际探测到的介质（NVMe / SATA-SAS）。
    pub actual_media: Option<Media>,
    /// 实际探测到的容量（字节），用于 tier 容量下限校验。
    pub actual_capacity_bytes: Option<u64>,
    /// 期望 tier 约束（容量/介质），None 表示不校验 tier。
    pub tier: Option<TierExpectation>,
}

/// tier 期望约束（§3.1 容量/介质不符检测）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TierExpectation {
    pub media: Media,
    /// 期望最小容量（字节），实际小于此值视为容量不符。
    pub min_capacity_bytes: u64,
}

impl Default for PrecheckInput {
    fn default() -> Self {
        PrecheckInput {
            is_system_disk: false,
            occupied_by: None,
            is_pv: false,
            smart_failed: false,
            signatures: Vec::new(),
            holders: Vec::new(),
            actual_media: None,
            actual_capacity_bytes: None,
            tier: None,
        }
    }
}

/// 执行预检，返回命中的不合规原因列表（空列表表示通过）。
pub fn run(input: &PrecheckInput) -> Result<Vec<String>> {
    let mut issues = Vec::new();
    if input.is_system_disk {
        issues.push("系统盘（根/boot/swap/kubelet 数据目录所在盘及其 holders）".into());
    }
    if let Some(occ) = &input.occupied_by {
        if occ != "none" {
            issues.push(format!("已被占用: {occ}"));
        }
    }
    if input.is_pv {
        issues.push("已是 PV".into());
    }
    if input.smart_failed {
        issues.push("SMART failed".into());
    }
    // 3.1（余下）：fs/LVM/md 签名。
    for sig in signature_blockers(&input.signatures) {
        issues.push(sig);
    }
    // 3.1（余下）：multipath / device-mapper 持有者。
    if !input.holders.is_empty() {
        issues.push(format!(
            "被 multipath/device-mapper 持有: {}",
            input.holders.join(",")
        ));
    }
    // 3.1（余下）：tier 容量/介质不符。
    if let Some(msg) = tier_mismatch(input.actual_media, input.actual_capacity_bytes, input.tier) {
        issues.push(msg);
    }
    Ok(issues)
}

/// 预检是否通过（无命中即通过）。
pub fn is_eligible(input: &PrecheckInput) -> Result<bool> {
    Ok(run(input)?.is_empty())
}

/// 判定签名是否构成纳管拦截（保守：任何非空 fstype 均拦截）。
///
/// 覆盖 ext2/3/4、xfs、btrfs、vfat/ntfs/exfat、LVM2_member、linux_raid_member、crypto_LUKS、swap 等。
pub fn signature_blockers(signatures: &[String]) -> Vec<String> {
    signatures
        .iter()
        .filter(|s| !s.is_empty())
        .map(|s| format!("已存在签名（{s}），禁止纳管"))
        .collect()
}

/// 判定 tier 容量/介质是否不符（§3.1）。
///
/// - 介质不符：actual_media 与期望 media 同时存在且不同。
/// - 容量不符：实际容量低于期望最小容量。
/// 任一不符返回原因；tier 为 None 或实际信息缺失则不误判（保守放行）。
pub fn tier_mismatch(
    actual_media: Option<Media>,
    actual_capacity_bytes: Option<u64>,
    tier: Option<TierExpectation>,
) -> Option<String> {
    let tier = match tier {
        Some(t) => t,
        None => return None, // 不校验 tier
    };
    let mut msgs = Vec::new();
    if let Some(actual) = actual_media {
        if actual != tier.media {
            msgs.push(format!(
                "介质不符（期望 {:?}，实际 {:?}）",
                tier.media, actual
            ));
        }
    }
    if let Some(cap) = actual_capacity_bytes {
        if cap < tier.min_capacity_bytes {
            msgs.push(format!(
                "容量不符（期望 ≥{}B，实际 {}B）",
                tier.min_capacity_bytes, cap
            ));
        }
    }
    if msgs.is_empty() {
        None
    } else {
        Some(msgs.join("；"))
    }
}

/// 由发现 + 健康 + 占用构造预检输入（纯函数，可单测，§3.1 / §5.1）。
///
/// 保持既有三参语义（系统盘/是否 PV/健康）；新字段（签名/持有者/tier/介质）默认空，
/// 由 M14b 运行时 blkid/lsblk 填充后再参与预检。
pub fn classify_disk(
    is_system_disk: bool,
    is_pv: bool,
    health: crate::common::Health,
) -> PrecheckInput {
    PrecheckInput {
        is_system_disk,
        occupied_by: if is_pv {
            Some("lvm-pv".into())
        } else {
            Some("none".into())
        },
        is_pv,
        smart_failed: health == crate::common::Health::Failed,
        ..Default::default()
    }
}

/// 解析 `blkid --json` 输出，提取每块设备的 fstype 签名（纯函数，§3.1）。
///
/// blkid JSON 结构：`{"blockdevices":[{"name":...,"fstype":"ext4"|null,...}]}`。
/// 仅返回 fstype 非空的设备签名（None 表示无结构/解析失败）。
pub fn parse_blkid_signatures(json: &str) -> Option<Vec<String>> {
    let v: Value = serde_json::from_str(json).ok()?;
    let devs = v.get("blockdevices")?.as_array()?;
    let mut out = Vec::new();
    for d in devs {
        if let Some(fstype) = d.get("fstype").and_then(|x| x.as_str()) {
            if !fstype.is_empty() {
                out.push(fstype.to_string());
            }
        }
    }
    Some(out)
}

/// 解析 lsblk holders（device-mapper / multipath 持有者，纯函数，§3.1）。
///
/// 返回设备 `holders` 数组中非空的持有者名称；无结构返回 None。
pub fn parse_lsblk_holders(json: &str) -> Option<Vec<String>> {
    let v: Value = serde_json::from_str(json).ok()?;
    let devs = v.get("blockdevices")?.as_array()?;
    let mut out = Vec::new();
    for d in devs {
        if let Some(holders) = d.get("holders").and_then(|h| h.as_array()) {
            for h in holders {
                if let Some(name) = h.as_str() {
                    if !name.is_empty() {
                        out.push(name.to_string());
                    }
                }
            }
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::Health;

    fn base() -> PrecheckInput {
        PrecheckInput {
            is_system_disk: false,
            occupied_by: Some("none".into()),
            is_pv: false,
            smart_failed: false,
            ..Default::default()
        }
    }

    #[test]
    fn eligible_when_clean() {
        assert!(is_eligible(&base()).unwrap());
    }

    #[test]
    fn blocked_on_system_disk() {
        let mut i = base();
        i.is_system_disk = true;
        let issues = run(&i).unwrap();
        assert!(issues.iter().any(|i| i.contains("系统盘")));
        assert!(!is_eligible(&i).unwrap());
    }

    // ---- 3.1 扩展规则独立用例 ----

    #[test]
    fn blocks_on_fs_signature() {
        let mut i = base();
        i.signatures = vec!["ext4".into()];
        let issues = run(&i).unwrap();
        assert!(issues.iter().any(|x| x.contains("ext4")));
        assert!(!is_eligible(&i).unwrap());
    }

    #[test]
    fn blocks_on_lvm_member_signature() {
        let mut i = base();
        i.signatures = vec!["LVM2_member".into()];
        assert!(!is_eligible(&i).unwrap());
    }

    #[test]
    fn blocks_on_md_signature() {
        let mut i = base();
        i.signatures = vec!["linux_raid_member".into()];
        assert!(!is_eligible(&i).unwrap());
    }

    #[test]
    fn blocks_on_multipath_holder() {
        let mut i = base();
        i.holders = vec!["dm-3".into(), "mpatha".into()];
        let issues = run(&i).unwrap();
        assert!(issues.iter().any(|x| x.contains("multipath")));
        assert!(!is_eligible(&i).unwrap());
    }

    #[test]
    fn blocks_on_tier_media_mismatch() {
        let mut i = base();
        i.actual_media = Some(Media::SataSas);
        i.tier = Some(TierExpectation {
            media: Media::Nvme,
            min_capacity_bytes: 0,
        });
        let issues = run(&i).unwrap();
        assert!(issues.iter().any(|x| x.contains("介质不符")));
        assert!(!is_eligible(&i).unwrap());
    }

    #[test]
    fn tier_media_match_passes() {
        let mut i = base();
        i.actual_media = Some(Media::Nvme);
        i.tier = Some(TierExpectation {
            media: Media::Nvme,
            min_capacity_bytes: 0,
        });
        assert!(is_eligible(&i).unwrap());
    }

    #[test]
    fn blocks_on_tier_capacity_mismatch() {
        let mut i = base();
        i.actual_capacity_bytes = Some(100_000_000);
        i.tier = Some(TierExpectation {
            media: Media::SataSas,
            min_capacity_bytes: 1_000_000_000,
        });
        let issues = run(&i).unwrap();
        assert!(issues.iter().any(|x| x.contains("容量不符")));
        assert!(!is_eligible(&i).unwrap());
    }

    #[test]
    fn combined_blocking_scenario() {
        // 多规则同时命中：系统盘 + fs 签名 + multipath 持有。
        let mut i = base();
        i.is_system_disk = true;
        i.signatures = vec!["xfs".into()];
        i.holders = vec!["dm-1".into()];
        let issues = run(&i).unwrap();
        assert!(issues.len() >= 3);
        assert!(!is_eligible(&i).unwrap());
    }

    #[test]
    fn no_false_positive_on_missing_tier() {
        // 无 tier 约束且其它干净 ⇒ 通过（不误判）。
        let i = base();
        assert!(is_eligible(&i).unwrap());
    }

    // ---- 3.1.1 / 3.1.2 解析器用例 ----

    #[test]
    fn parses_blkid_signatures() {
        let j = r#"{"blockdevices":[
            {"name":"/dev/sda","fstype":null},
            {"name":"/dev/sda1","fstype":"ext4"},
            {"name":"/dev/sdb","fstype":"LVM2_member"}
        ]}"#;
        let sigs = parse_blkid_signatures(j).unwrap();
        assert_eq!(sigs, vec!["ext4", "LVM2_member"]);
    }

    #[test]
    fn parses_blkid_empty_on_null_only() {
        let j = r#"{"blockdevices":[{"name":"/dev/sda","fstype":null}]}"#;
        assert!(parse_blkid_signatures(j).unwrap().is_empty());
    }

    #[test]
    fn parses_lsblk_holders() {
        let j = r#"{"blockdevices":[
            {"name":"sda","holders":["dm-3"]},
            {"name":"sdb","holders":[]}
        ]}"#;
        let holders = parse_lsblk_holders(j).unwrap();
        assert_eq!(holders, vec!["dm-3"]);
    }

    #[test]
    fn classify_disk_still_compatible() {
        // 保持既有三参语义（agent/mod.rs 调用方不受影响）。
        let input = classify_disk(false, false, Health::Failed);
        assert!(input.smart_failed);
        assert!(!is_eligible(&input).unwrap());
    }

    #[test]
    fn classify_disk_clean_eligible() {
        let input = classify_disk(false, false, Health::Healthy);
        assert!(is_eligible(&input).unwrap());
    }
}

/// NodeDisk 生命周期阶段（对齐 Go `DiskPhase`，§3.1 / §5）。
///
/// 与 health 两维度分离；Agent 负责将 `Candidate` 在预检通过后推进到 `PreChecked`。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiskPhase {
    Discovered,
    Candidate,
    PreChecked,
    Wiped,
    InVG,
    Draining,
    Removed,
}

impl DiskPhase {
    pub fn as_str(self) -> &'static str {
        match self {
            DiskPhase::Discovered => "Discovered",
            DiskPhase::Candidate => "Candidate",
            DiskPhase::PreChecked => "PreChecked",
            DiskPhase::Wiped => "Wiped",
            DiskPhase::InVG => "InVG",
            DiskPhase::Draining => "Draining",
            DiskPhase::Removed => "Removed",
        }
    }

    pub fn from_str(s: &str) -> Self {
        match s {
            "Discovered" => DiskPhase::Discovered,
            "Candidate" => DiskPhase::Candidate,
            "PreChecked" => DiskPhase::PreChecked,
            "Wiped" => DiskPhase::Wiped,
            "InVG" => DiskPhase::InVG,
            "Draining" => DiskPhase::Draining,
            "Removed" => DiskPhase::Removed,
            _ => DiskPhase::Discovered,
        }
    }
}

/// 预检状态机推进（§3.2）：当前 `Candidate` 且预检通过（eligible）⇒ `PreChecked`；否则保持。
///
/// 预检命中（不合规）不推进，并保持 `Candidate`，由 control-plane/运维暴露不合规原因。
pub fn advance_phase(current: DiskPhase, eligible: bool) -> DiskPhase {
    match (current, eligible) {
        (DiskPhase::Candidate, true) => DiskPhase::PreChecked,
        _ => current,
    }
}

#[cfg(test)]
mod phase_tests {
    use super::*;

    #[test]
    fn phase_roundtrip() {
        assert_eq!(DiskPhase::from_str("PreChecked"), DiskPhase::PreChecked);
        assert_eq!(DiskPhase::PreChecked.as_str(), "PreChecked");
        assert_eq!(DiskPhase::from_str("bogus"), DiskPhase::Discovered);
    }

    #[test]
    fn candidate_eligible_advances() {
        assert_eq!(
            advance_phase(DiskPhase::Candidate, true),
            DiskPhase::PreChecked
        );
    }

    #[test]
    fn candidate_ineligible_stays() {
        assert_eq!(
            advance_phase(DiskPhase::Candidate, false),
            DiskPhase::Candidate
        );
    }

    #[test]
    fn non_candidate_unchanged() {
        assert_eq!(
            advance_phase(DiskPhase::Discovered, true),
            DiskPhase::Discovered
        );
        assert_eq!(advance_phase(DiskPhase::InVG, true), DiskPhase::InVG);
    }
}
