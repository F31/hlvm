//! SMART 采集与统一健康抽象（设计 §5.4 / §8）。
//!
//! NVMe（nvme-cli / ioctl）与 SATA/SAS（smartctl --json）统一抽象为 `Health`。
//! 阈值表放 ConfigMap 并可热加载（§5.4 要点 4）。本模块聚焦命令构造与解析骨架。

use crate::common::{map_nvme_health, Health};
use anyhow::Result;
use serde_json::Value;
use std::process::Command;

/// NVMe 关键字段（来自 `nvme smart-log --output-format json`）。
#[derive(Debug, Clone, Copy)]
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
    vec![
        "smartctl".into(),
        "-A".into(),
        "-j".into(),
        device_by_id.into(),
    ]
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
    fn commands_use_by_id() {
        assert_eq!(nvme_command("/dev/disk/by-id/nvme-x"), vec![
            "nvme","smart-log","--output-format","json","/dev/disk/by-id/nvme-x"]);
    }
}
