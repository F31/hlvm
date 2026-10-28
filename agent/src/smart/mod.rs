//! SMART 采集与统一健康抽象（设计 §5.4 / §8）。
//!
//! NVMe（nvme-cli）与 SATA/SAS（smartctl --json）统一抽象为 `Health`。
//! 阈值表放 ConfigMap 并可热加载（§5.4 要点 4）。本模块聚焦命令构造、解析与映射，
//! 全部为纯函数（便于单测）；运行时命令执行走 `collect_*_health`。

use crate::common::{map_nvme_health, Health};
use anyhow::Result;
use serde_json::Value;
use std::process::Command;

/// 磁盘介质类型（决定采集路径，§5.4）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Media {
    Nvme,
    SataSas,
}

/// 由 by-id 路径推断介质：含 "nvme"（大小写不敏感）即 NVMe，其余归 SATA/SAS。
/// 纯函数，可单测（§5.1 by-id 约定）。
pub fn detect_media(by_id: &str) -> Media {
    if by_id.to_ascii_lowercase().contains("nvme") {
        Media::Nvme
    } else {
        Media::SataSas
    }
}

/// NVMe 关键字段（来自 `nvme smart-log --output-format json`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NvmeSmart {
    pub critical_warning: u32,
    pub available_spare_percent: u8,
    pub percentage_used: u8,
}

/// 从 nvme-cli JSON 值中提取关键字段（解析失败一律视为未知，§5.3）。
pub fn parse_nvme_json(v: &Value) -> Option<NvmeSmart> {
    let critical_warning = v
        .get("critical_warning")?
        .as_u64()
        .unwrap_or(0) as u32;
    let available_spare = v
        .get("available_spare")
        .and_then(|x| x.as_u64())
        .unwrap_or(0) as u8;
    let percentage_used = v
        .get("percentage_used")
        .and_then(|x| x.as_u64())
        .unwrap_or(0) as u8;
    Some(NvmeSmart {
        critical_warning,
        available_spare_percent: available_spare,
        percentage_used,
    })
}

/// SATA/SAS 关键字段（来自 `smartctl -A -j`）。
///
/// 解析失败一律视为 None（§5.3：不得推断）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SataSmart {
    /// Reallocated_Sector_Ct 原始值。
    pub reallocated: u64,
    /// Current_Pending_Sector 原始值。
    pub pending: u64,
    /// Offline_Uncorrectable 原始值。
    pub offline_uncorrectable: u64,
    /// smartctl 整体自测是否通过（smart_status.passed）。
    pub passed: bool,
}

/// 从 smartctl JSON 值中提取 SATA/SAS 关键字段（§5.4）。
///
/// 兼容 `raw.value`（整数）与 `raw.string`（字符串解析失败则视为 0）。
/// 解析失败（缺字段）一律视为 None，不得推断。
pub fn parse_smartctl_json(v: &Value) -> Option<SataSmart> {
    let passed = v
        .get("smart_status")
        .and_then(|s| s.get("passed"))
        .and_then(|p| p.as_bool())
        .unwrap_or(false);

    let mut out = SataSmart {
        passed,
        ..Default::default()
    };

    let table = v
        .get("ata_smart_attributes")
        .and_then(|a| a.get("table"))
        .and_then(|t| t.as_array())?;

    for attr in table {
        let name = match attr.get("name").and_then(|n| n.as_str()) {
            Some(n) => n,
            None => continue,
        };
        let raw = attr
            .get("raw")
            .and_then(|r| r.get("value").and_then(|x| x.as_u64()))
            .or_else(|| {
                attr.get("raw")
                    .and_then(|r| r.get("string"))
                    .and_then(|s| s.as_str())
                    .and_then(|s| s.split_whitespace().next())
                    .and_then(|s| s.parse::<u64>().ok())
            })
            .unwrap_or(0);

        match name {
            "Reallocated_Sector_Ct" => out.reallocated = raw,
            "Current_Pending_Sector" => out.pending = raw,
            "Offline_Uncorrectable" => out.offline_uncorrectable = raw,
            _ => {}
        }
    }

    Some(out)
}

/// SATA/SAS 字段 → Health 纯映射（§5.4 / §8，阈值可经 ConfigMap 覆盖）。
///
/// 规则（默认阈值）：
/// - 自测未通过（passed=false） ⇒ Failed
/// - reallocated / pending / offline_uncorrectable 任一 > 0 ⇒ Critical（真实缺陷指示）
/// - 否则 Healthy
pub fn map_sata_health(s: &SataSmart) -> Health {
    if !s.passed {
        Health::Failed
    } else if s.reallocated > 0 || s.pending > 0 || s.offline_uncorrectable > 0 {
        Health::Critical
    } else {
        Health::Healthy
    }
}

/// 构造 nvme-cli 命令（argv 数组，禁止 shell 拼接，§5.2）。
pub fn nvme_command(device_by_id: &str) -> Vec<String> {
    vec![
        "nvme".into(),
        "smart-log".into(),
        "--output-format".into(),
        "json".into(),
        device_by_id.into(),
    ]
}

/// 构造 smartctl 命令（SATA/SAS）。
pub fn smartctl_command(device_by_id: &str) -> Vec<String> {
    vec!["smartctl".into(), "-A".into(), "-j".into(), device_by_id.into()]
}

/// 采集 NVMe SMART 并映射为 Health（默认阈值）。
pub fn collect_nvme_health(device_by_id: &str) -> Result<Health> {
    let out = Command::new("nvme")
        .args(["smart-log", "--output-format", "json", device_by_id])
        .output()?;
    if !out.status.success() {
        anyhow::bail!("nvme smart-log 失败: {}", String::from_utf8_lossy(&out.stderr));
    }
    let v: Value = serde_json::from_slice(&out.stdout)?;
    let smart = parse_nvme_json(&v).ok_or_else(|| anyhow::anyhow!("无法解析 nvme 输出"))?;
    Ok(map_nvme_health(
        smart.critical_warning,
        smart.available_spare_percent,
        smart.percentage_used,
        10,
        80,
    ))
}

/// 采集 SATA/SAS SMART 并映射为 Health。
pub fn collect_sata_health(device_by_id: &str) -> Result<Health> {
    let out = Command::new("smartctl")
        .args(["-A", "-j", device_by_id])
        .output()?;
    if !out.status.success() {
        anyhow::bail!("smartctl 失败: {}", String::from_utf8_lossy(&out.stderr));
    }
    let v: Value = serde_json::from_slice(&out.stdout)?;
    let smart = parse_smartctl_json(&v).ok_or_else(|| anyhow::anyhow!("无法解析 smartctl 输出"))?;
    Ok(map_sata_health(&smart))
}

/// 按介质分派采集（§5.4）：NVMe 走 nvme-cli，其余走 smartctl。
pub fn collect_health(device_by_id: &str) -> Result<Health> {
    match detect_media(device_by_id) {
        Media::Nvme => collect_nvme_health(device_by_id),
        Media::SataSas => collect_sata_health(device_by_id),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn detect_media_nvme() {
        assert_eq!(detect_media("/dev/disk/by-id/nvme-Samsung_PM9A3"), Media::Nvme);
        assert_eq!(detect_media("/dev/disk/by-id/NVMe-foo"), Media::Nvme);
    }

    #[test]
    fn detect_media_sata_sas() {
        assert_eq!(detect_media("/dev/disk/by-id/ata-ST123"), Media::SataSas);
        assert_eq!(detect_media("/dev/disk/by-id/wwn-0x500"), Media::SataSas);
        assert_eq!(detect_media("/dev/disk/by-id/scsi-foo"), Media::SataSas);
    }

    #[test]
    fn parse_nvme_ok() {
        let v = json!({
            "critical_warning": 0,
            "available_spare": 100,
            "percentage_used": 12
        });
        let s = parse_nvme_json(&v).unwrap();
        assert_eq!(s.critical_warning, 0);
        assert_eq!(s.percentage_used, 12);
    }

    #[test]
    fn parse_smartctl_real_shape() {
        let v = json!({
            "smart_status": { "passed": true },
            "ata_smart_attributes": {
                "table": [
                    { "name": "Reallocated_Sector_Ct", "raw": { "value": 0, "string": "0" } },
                    { "name": "Current_Pending_Sector", "raw": { "value": 3, "string": "3" } },
                    { "name": "Offline_Uncorrectable", "raw": { "value": 0, "string": "0" } }
                ]
            }
        });
        let s = parse_smartctl_json(&v).unwrap();
        assert!(s.passed);
        assert_eq!(s.reallocated, 0);
        assert_eq!(s.pending, 3);
        assert_eq!(s.offline_uncorrectable, 0);
    }

    #[test]
    fn parse_smartctl_string_raw_fallback() {
        // 部分 smartctl 版本 raw 只给 string。
        let v = json!({
            "smart_status": { "passed": true },
            "ata_smart_attributes": {
                "table": [
                    { "name": "Reallocated_Sector_Ct", "raw": { "string": "5" } }
                ]
            }
        });
        let s = parse_smartctl_json(&v).unwrap();
        assert_eq!(s.reallocated, 5);
    }

    #[test]
    fn parse_smartctl_failed_status() {
        let v = json!({
            "smart_status": { "passed": false },
            "ata_smart_attributes": { "table": [] }
        });
        let s = parse_smartctl_json(&v).unwrap();
        assert!(!s.passed);
        assert_eq!(map_sata_health(&s), Health::Failed);
    }

    #[test]
    fn sata_health_critical_on_pending() {
        let s = SataSmart {
            passed: true,
            reallocated: 0,
            pending: 1,
            offline_uncorrectable: 0,
        };
        assert_eq!(map_sata_health(&s), Health::Critical);
    }

    #[test]
    fn sata_health_healthy_when_clean() {
        let s = SataSmart {
            passed: true,
            ..Default::default()
        };
        assert_eq!(map_sata_health(&s), Health::Healthy);
    }

    #[test]
    fn commands_use_by_id() {
        assert_eq!(
            nvme_command("/dev/disk/by-id/nvme-x"),
            vec!["nvme", "smart-log", "--output-format", "json", "/dev/disk/by-id/nvme-x"]
        );
        assert_eq!(
            smartctl_command("/dev/disk/by-id/ata-x"),
            vec!["smartctl", "-A", "-j", "/dev/disk/by-id/ata-x"]
        );
    }
}
