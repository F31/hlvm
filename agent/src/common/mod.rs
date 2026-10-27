//! 节点 Agent 公共类型与纯函数（无外部依赖，便于单测）。
//!
//! 设计约束（§5.2 / §5.3）：
//! - 操作安全：设备路径只接受 `/dev/disk/by-id/...` 并做格式校验。
//! - Health 抽象：NVMe 与 SATA/SAS 的 SMART 统一映射为 Health。

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// 磁盘健康度（设计 §5.4 / §8）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Health {
    Healthy,
    Warning,
    Critical,
    Failed,
}

impl Health {
    /// 映射为 exporter 指标值 0/1/2/3（§5.4 storage_disk_smart_health）。
    pub fn metric_value(self) -> u8 {
        match self {
            Health::Healthy => 0,
            Health::Warning => 1,
            Health::Critical => 2,
            Health::Failed => 3,
        }
    }
}

#[derive(Debug, Error)]
pub enum AgentError {
    #[error("命令执行失败: {0}")]
    Command(String),
    #[error("设备路径未走 by-id: {0}")]
    BadDevicePath(String),
    #[error("serial 不匹配: 期望 {expected}, 实际 {actual}")]
    SerialMismatch { expected: String, actual: String },
    #[error("系统盘受保护: {0}")]
    SystemDisk(String),
    #[error("破坏性行为未通过预检: {0}")]
    Precheck(String),
}

/// 校验设备路径必须以 `/dev/disk/by-id/` 开头（§5.2 操作安全）。
///
/// 返回规范化路径；非 by-id 路径一律拒绝（禁止 shell 拼接、防路径穿越）。
pub fn require_by_id(path: &str) -> Result<String, AgentError> {
    if path.starts_with("/dev/disk/by-id/") && !path.contains("..") {
        Ok(path.to_string())
    } else {
        Err(AgentError::BadDevicePath(path.to_string()))
    }
}

/// NVMe 关键字段 → Health 的纯映射（§5.4 / §8）。
///
/// 规则（可经 ConfigMap 热加载覆盖，此处为默认阈值）：
/// - critical_warning != 0 或 available_spare 低于阈值 ⇒ Critical
/// - percentage_used 超过 warning 阈值 ⇒ Warning
/// - 否则 Healthy
pub fn map_nvme_health(
    critical_warning: u32,
    available_spare_percent: u8,
    percentage_used: u8,
    available_spare_warn: u8,
    used_warn: u8,
) -> Health {
    if critical_warning != 0 || available_spare_percent < available_spare_warn {
        Health::Critical
    } else if percentage_used >= used_warn {
        Health::Warning
    } else {
        Health::Healthy
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn by_id_ok() {
        assert_eq!(
            require_by_id("/dev/disk/by-id/nvme-Samsung_PM9A3_1234").unwrap(),
            "/dev/disk/by-id/nvme-Samsung_PM9A3_1234"
        );
    }

    #[test]
    fn by_id_rejects_device_name() {
        assert!(require_by_id("/dev/nvme0n1").is_err());
    }

    #[test]
    fn by_id_rejects_traversal() {
        assert!(require_by_id("/dev/disk/by-id/../sda").is_err());
    }

    #[test]
    fn nvme_health_critical_on_warning_bit() {
        assert_eq!(
            map_nvme_health(1, 100, 0, 10, 80),
            Health::Critical
        );
    }

    #[test]
    fn nvme_health_warning_on_used() {
        assert_eq!(
            map_nvme_health(0, 100, 85, 10, 80),
            Health::Warning
        );
    }

    #[test]
    fn nvme_health_healthy() {
        assert_eq!(
            map_nvme_health(0, 100, 10, 10, 80),
            Health::Healthy
        );
    }
}
