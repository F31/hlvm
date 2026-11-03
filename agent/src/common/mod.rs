//! 节点 Agent 公共类型与纯函数（无外部依赖，便于单测）。
//!
//! 设计约束（§5.2 / §5.3）：
//! - 操作安全：设备路径只接受 `/dev/disk/by-id/...` 并做格式校验。
//! - Health 抽象：NVMe 与 SATA/SAS 的 SMART 统一映射为 Health。
//! - 执行窗口：`StorageTask.spec.ttl` 的 agent 侧复核（`ttl` 子模块，纯函数）。

pub mod ttl;

pub use ttl::{evaluate_task_window, parse_go_duration, TaskWindow};

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

    /// 映射为 JSON 小写串（与 Go `DiskHealth` 枚举值对齐，如 "healthy"）。
    pub fn as_str_lowercase(self) -> &'static str {
        match self {
            Health::Healthy => "healthy",
            Health::Warning => "warning",
            Health::Critical => "critical",
            Health::Failed => "failed",
        }
    }

    /// 从小写串解析（与 `as_str_lowercase` 互逆；未知值回退 Healthy，不臆断）。
    pub fn from_str_lowercase(s: &str) -> Health {
        match s {
            "healthy" => Health::Healthy,
            "warning" => Health::Warning,
            "critical" => Health::Critical,
            "failed" => Health::Failed,
            _ => Health::Healthy,
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

/// by-id 别名前缀的稳定度排序（越小越优先，纯函数）。
///
/// 同一块盘在 `/dev/disk/by-id` 下常有多个别名（实测 kind 的 4 块 virtio 盘各有
/// `scsi-*` 与 `wwn-*` 两条）。`read_dir` 顺序由目录项插入顺序决定（`/dev` 是 tmpfs），
/// 因此「取第一个匹配」会让同一块盘在两次枚举中拿到不同名字 ⇒ NodeDisk 身份漂移。
///
/// 排序依据是**标识来源是否由设备自身提供、是否随总线槽位变化**：
/// - `virtio-<serial>`：序列号来自 hypervisor 配置，跨重启稳定，且不会因换槽位而变。
/// - `scsi-<vendor>_<model>_<serial>`：带序列号时稳定，优先于纯位置类名字。
/// - `nvme-<model>_<serial>` / `nvme-eui.*`：NVMe 自身标识，天然唯一。
/// - `wwn-0x...`：盘片烧录的 WWN，稳定但与 `scsi-*` 常指向同一设备，作次选。
/// - `ata-<model>_<serial>`：ATA 序列号，同样稳定但信息量最低（无总线类型）。
/// - 其余（`dm-uuid-*` / `md-uuid-*` / `lvm-pv-uuid-*` / `usb-*` 等）：虚拟或可重建标识，最后考虑。
///
/// 未知前缀不返回 `None`，而是排到最后——「有别名但都不认识」时仍应解析成功，
/// 否则会退化成「无 by-id ⇒ `dev-<name>`」，反而丢了持久标识。
pub fn by_id_alias_rank(name: &str) -> u8 {
    if name.starts_with("virtio-") {
        0
    } else if name.starts_with("scsi-") {
        1
    } else if name.starts_with("nvme-") {
        2
    } else if name.starts_with("wwn-") {
        3
    } else if name.starts_with("ata-") {
        4
    } else {
        5
    }
}

/// 从同一设备的多个 by-id 别名中选出一个稳定引用（纯函数）。
///
/// 先按 [`by_id_alias_rank`] 排前缀优先级，同优先级再按名字字典序定序，保证
/// **同一组输入在任何 `read_dir` 顺序下都得到同一结果**。空输入返回 `None`。
pub fn pick_by_id_alias<'a, I>(names: I) -> Option<String>
where
    I: IntoIterator<Item = &'a str>,
{
    names
        .into_iter()
        .map(|n| (by_id_alias_rank(n), n))
        .min()
        .map(|(_, n)| n.to_string())
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
        assert_eq!(map_nvme_health(1, 100, 0, 10, 80), Health::Critical);
    }

    #[test]
    fn nvme_health_warning_on_used() {
        assert_eq!(map_nvme_health(0, 100, 85, 10, 80), Health::Warning);
    }

    #[test]
    fn nvme_health_healthy() {
        assert_eq!(map_nvme_health(0, 100, 10, 10, 80), Health::Healthy);
    }

    /// 回归（2026-11-03 复核）：同一块盘的多条别名必须选出**固定**的一条，
    /// 不能依赖 `read_dir` 顺序（`/dev` 是 tmpfs，顺序即目录项插入顺序）。
    #[test]
    fn picks_stable_alias_regardless_of_order() {
        let aliases = ["wwn-0x5000c500abc12345", "scsi-0QEMU_QEMU_HARDDISK_drive-scsi0"];
        // 两种枚举顺序必须给出同一结果。
        assert_eq!(
            pick_by_id_alias(aliases.iter().copied()).as_deref(),
            Some("scsi-0QEMU_QEMU_HARDDISK_drive-scsi0")
        );
        assert_eq!(
            pick_by_id_alias(aliases.iter().rev().copied()).as_deref(),
            Some("scsi-0QEMU_QEMU_HARDDISK_drive-scsi0")
        );
    }

    #[test]
    fn alias_priority_follows_declared_order() {
        // virtio 序列号最稳定 ⇒ 即使同时存在 scsi/wwn 也优先选它。
        assert_eq!(
            pick_by_id_alias(["wwn-0x1", "nvme-X_1", "scsi-V_M_S", "virtio-abc"].iter().copied())
                .as_deref(),
            Some("virtio-abc")
        );
        assert_eq!(
            pick_by_id_alias(["ata-M_S", "wwn-0x1", "nvme-X_1"].iter().copied()).as_deref(),
            Some("nvme-X_1")
        );
        // 未知前缀仍应解析成功（排最后），不能退化成「无 by-id」。
        assert_eq!(
            pick_by_id_alias(["dm-uuid-mpath-1", "ata-M_S"].iter().copied()).as_deref(),
            Some("ata-M_S")
        );
        assert_eq!(
            pick_by_id_alias(["dm-uuid-mpath-1"].iter().copied()).as_deref(),
            Some("dm-uuid-mpath-1")
        );
    }

    #[test]
    fn same_rank_breaks_tie_by_name() {
        // 同前缀（nvme-）时按字典序：`nvme-Model_S` < `nvme-eui.0`。
        assert_eq!(
            pick_by_id_alias(["nvme-eui.01000000", "nvme-Model_S"].iter().copied()).as_deref(),
            Some("nvme-Model_S")
        );
        assert!(pick_by_id_alias(std::iter::empty()).is_none());
    }
}

/// 健康映射阈值表（§5.4 要点 4）：放 ConfigMap 并可热加载（无需重启 Agent）。
///
/// 默认值与既有 `map_nvme_health`/`map_sata_health` 硬编码值一致，保证行为不回退；
/// `from_configmap_json` 提供热加载入口（M14b 运行时 watch ConfigMap 后调用）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ThresholdTable {
    /// available_spare 低于此值 ⇒ Critical。
    pub nvme_available_spare_warn: u8,
    /// percentage_used 达到此值 ⇒ Warning。
    pub nvme_used_warn: u8,
    /// reallocated 超过此值 ⇒ Critical（真实缺陷指示，默认 0 即任何 >0 即 Critical）。
    pub sata_reallocated_warn: u64,
    /// pending 超过此值 ⇒ Critical。
    pub sata_pending_warn: u64,
    /// offline_uncorrectable 超过此值 ⇒ Critical。
    pub sata_offline_uncorrectable_warn: u64,
    /// 自测未通过是否直接判 Failed（默认 true）。
    pub sata_require_passed: bool,
}

impl Default for ThresholdTable {
    fn default() -> Self {
        ThresholdTable {
            nvme_available_spare_warn: 10,
            nvme_used_warn: 80,
            sata_reallocated_warn: 0,
            sata_pending_warn: 0,
            sata_offline_uncorrectable_warn: 0,
            sata_require_passed: true,
        }
    }
}

impl ThresholdTable {
    /// 从 ConfigMap 载荷（JSON）解析阈值；缺失字段回退默认（热加载容忍部分字段）。
    pub fn from_configmap_json(json: &str) -> Result<Self, AgentError> {
        let v: serde_json::Value = serde_json::from_str(json)
            .map_err(|e| AgentError::Precheck(format!("阈值 JSON 解析失败: {e}")))?;
        let mut t = ThresholdTable::default();
        let get_u64 = |k: &str| v.get(k).and_then(|x| x.as_u64());
        if let Some(x) = get_u64("nvme_available_spare_warn") {
            t.nvme_available_spare_warn = x as u8;
        }
        if let Some(x) = get_u64("nvme_used_warn") {
            t.nvme_used_warn = x as u8;
        }
        if let Some(x) = get_u64("sata_reallocated_warn") {
            t.sata_reallocated_warn = x;
        }
        if let Some(x) = get_u64("sata_pending_warn") {
            t.sata_pending_warn = x;
        }
        if let Some(x) = get_u64("sata_offline_uncorrectable_warn") {
            t.sata_offline_uncorrectable_warn = x;
        }
        if let Some(b) = v.get("sata_require_passed").and_then(|x| x.as_bool()) {
            t.sata_require_passed = b;
        }
        Ok(t)
    }
}

/// NVMe media_errors 增量追踪器（§5.4 / §8：按两次采样间增量判定，非累计）。
///
/// 仅当本次累计值较上次增长才产生增量；curr 回退/重置（小于 last）时返回 0，不误报。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct MediaErrorTracker {
    pub last_cumulative: Option<u64>,
}

impl MediaErrorTracker {
    /// 返回本次新增增量（curr - last，curr < last 时取 0）。
    pub fn increment(&self, curr: u64) -> u64 {
        match self.last_cumulative {
            Some(prev) if curr >= prev => curr - prev,
            _ => 0,
        }
    }

    /// 推进基线到当前累计值（调用方在每次采样后调用）。
    pub fn advance(&mut self, curr: u64) {
        self.last_cumulative = Some(curr);
    }
}

#[cfg(test)]
mod threshold_tests {
    use super::*;

    #[test]
    fn threshold_default_matches_hardcoded() {
        let t = ThresholdTable::default();
        assert_eq!(t.nvme_available_spare_warn, 10);
        assert_eq!(t.nvme_used_warn, 80);
        assert!(t.sata_require_passed);
    }

    #[test]
    fn threshold_from_json_overrides() {
        let t =
            ThresholdTable::from_configmap_json(r#"{"nvme_used_warn":70,"sata_pending_warn":0}"#)
                .unwrap();
        assert_eq!(t.nvme_used_warn, 70);
        // 未提供的字段回退默认。
        assert_eq!(t.nvme_available_spare_warn, 10);
    }

    #[test]
    fn threshold_from_json_bad_shape_errors() {
        assert!(ThresholdTable::from_configmap_json("not json").is_err());
    }

    #[test]
    fn media_error_increment_basic() {
        let mut tr = MediaErrorTracker::default();
        assert_eq!(tr.increment(5), 0); // 首次无基线
        tr.advance(5);
        assert_eq!(tr.increment(8), 3); // 新增 3
        tr.advance(8);
        assert_eq!(tr.increment(8), 0); // 无新增
    }

    #[test]
    fn media_error_increment_no_false_alarm_on_reset() {
        let mut tr = MediaErrorTracker {
            last_cumulative: Some(10),
        };
        // 计数器回退（重置/换盘）⇒ 不误报。
        assert_eq!(tr.increment(2), 0);
        tr.advance(2);
        assert_eq!(tr.increment(4), 2);
    }
}
