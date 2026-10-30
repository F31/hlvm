//! 指标采集与上报（设计 §5.4）。
//!
//! exporter 以独立非特权 DaemonSet 运行，只读采集。指标按 §5.4 定义；
//! CRD status 仅在 health/phase 变化或每 10 分钟低频刷新（§3.1）。
//!
//! 本模块同时承载 **StorageTask 状态回写** 抽象（§3.4 单写者原则：Agent 仅写
//! StorageTask.status）。`build_status_patch` 为纯函数（可单测），`Reporter` trait
//! 抽离真实写入通道（`LogReporter` 用于测试/无集群回退，`KubeReporter` 见 kube 集成）。

pub mod kube_rw;

use crate::common::Health;
use crate::precheck::DiskPhase;
use anyhow::Result;
use serde_json::json;
use serde_json::Value;

/// StorageTask 阶段（与 Go 侧 TaskPhase 对齐，§3.4）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskPhase {
    Pending,
    Running,
    Succeeded,
    Failed,
    Unknown,
}

impl TaskPhase {
    pub fn as_str(self) -> &'static str {
        match self {
            TaskPhase::Pending => "Pending",
            TaskPhase::Running => "Running",
            TaskPhase::Succeeded => "Succeeded",
            TaskPhase::Failed => "Failed",
            TaskPhase::Unknown => "Unknown",
        }
    }

    pub fn from_str(s: &str) -> Self {
        match s {
            "Pending" => TaskPhase::Pending,
            "Running" => TaskPhase::Running,
            "Succeeded" => TaskPhase::Succeeded,
            "Failed" => TaskPhase::Failed,
            _ => TaskPhase::Unknown,
        }
    }
}

/// StorageTask 执行结果（简洁枚举，省略值序列化空串）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskResult {
    Empty,
    Success,
    Failure,
}

impl TaskResult {
    pub fn as_str(self) -> &'static str {
        match self {
            TaskResult::Empty => "",
            TaskResult::Success => "success",
            TaskResult::Failure => "failure",
        }
    }
}

/// 一次状态回写意图（由 executor 结果映射而来，§3.4）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskStatus {
    pub phase: TaskPhase,
    pub result: TaskResult,
    pub message: Option<String>,
    /// RFC3339 时间戳（对应 Go metav1.Time 序列化形态）。
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
}

impl TaskStatus {
    pub fn running() -> Self {
        TaskStatus {
            phase: TaskPhase::Running,
            result: TaskResult::Empty,
            message: None,
            started_at: None,
            completed_at: None,
        }
    }

    pub fn succeeded(msg: Option<String>) -> Self {
        TaskStatus {
            phase: TaskPhase::Succeeded,
            result: TaskResult::Success,
            message: msg,
            started_at: None,
            completed_at: None,
        }
    }

    pub fn failed(msg: Option<String>) -> Self {
        TaskStatus {
            phase: TaskPhase::Failed,
            result: TaskResult::Failure,
            message: msg,
            started_at: None,
            completed_at: None,
        }
    }

    /// 执行窗口过期（agent 侧复核，ADR-006 补遗）。
    ///
    /// 结果写成 `Failed` 且 `completedAt` 置为当前时间，与控制面 `expireTask` 的对象形态一致；
    /// 原因串由 `common::ttl` 生成，带 `DeadlineExceeded: ` 前缀。
    pub fn expired(reason: String) -> Self {
        TaskStatus {
            phase: TaskPhase::Failed,
            result: TaskResult::Failure,
            message: Some(reason),
            started_at: None,
            completed_at: Some(jiff::Timestamp::now().to_string()),
        }
    }
}

/// 构造写入 `/status` 子资源的 merge patch（纯函数，可单测）。
///
/// 仅包含 status 字段（phase/result/message/startedAt/completedAt），与 Go 侧
/// `StorageTaskStatus` 对齐；CRD status 使用 `preserve-unknown-fields`，多出的字段安全保留。
pub fn build_status_patch(status: &TaskStatus) -> Value {
    let mut obj = serde_json::Map::new();
    obj.insert("phase".into(), json!(status.phase.as_str()));
    if let TaskResult::Empty = status.result {
        // 省略 result 字段（Running/未决态不写结果）。
    } else {
        obj.insert("result".into(), json!(status.result.as_str()));
    }
    if let Some(m) = &status.message {
        obj.insert("message".into(), json!(m));
    }
    if let Some(s) = &status.started_at {
        obj.insert("startedAt".into(), json!(s));
    }
    if let Some(c) = &status.completed_at {
        obj.insert("completedAt".into(), json!(c));
    }
    json!({ "status": obj })
}

/// 将执行计划映射为回写状态（纯函数，可单测，§3.4）。
///
/// - `AlreadyDone`：目标状态已达成 / 已回执 ⇒ Succeeded（幂等补回执）。
/// - `Rejected(reason)`：校验失败 ⇒ Failed（携带拒绝原因）。
/// - `DryRun(cmd)`：仅回显将执行命令 ⇒ Succeeded（dry-run 不落地，由控制面决定是否放行）。
/// - `Run(cmd)`：需结合真实执行结果 `outcome`：成功 ⇒ Succeeded，失败 ⇒ Failed；
///   尚未执行（outcome=None）⇒ Running。
pub fn plan_to_status(
    plan: &crate::executor::ExecPlan,
    outcome: Option<&Result<crate::executor::ExecOutcome>>,
) -> TaskStatus {
    use crate::executor::ExecPlan;
    match plan {
        ExecPlan::AlreadyDone => TaskStatus::succeeded(Some("目标状态已达成，幂等补回执".into())),
        ExecPlan::Rejected(reason) => TaskStatus::failed(Some(reason.clone())),
        ExecPlan::DryRun(cmd) => {
            TaskStatus::succeeded(Some(format!("[dry-run] {}", cmd.join(" "))))
        }
        ExecPlan::Run(_) => match outcome {
            Some(Ok(crate::executor::ExecOutcome::Success(out))) => {
                TaskStatus::succeeded(Some(out.clone()))
            }
            Some(Ok(crate::executor::ExecOutcome::Skipped)) => {
                TaskStatus::succeeded(Some("skipped".into()))
            }
            Some(Err(e)) => TaskStatus::failed(Some(format!("{e}"))),
            None => TaskStatus::running(),
        },
    }
}

/// 状态回写通道抽象（§3.4）。真实集群走 `KubeReporter`，测试/无集群回退 `LogReporter`。
pub trait Reporter: Send + Sync {
    fn report(&self, name: &str, status: &TaskStatus) -> Result<()>;
}

/// 日志回退实现：仅打印 patch，不触达 API（测试与离线诊断用）。
pub struct LogReporter;

impl Reporter for LogReporter {
    fn report(&self, name: &str, status: &TaskStatus) -> Result<()> {
        let patch = build_status_patch(status);
        tracing::info!(task = name, patch = %patch, "上报 StorageTask 状态（LogReporter）");
        Ok(())
    }
}

// ----------------------------------------------------------------------------
// NodeDisk 低频状态写回（设计 §3.1 / §3.2：phase/health/occupiedBy/isSystemDisk 变化或每 10 分钟刷新）。
//
// Agent 是磁盘真实观察者，是这些字段的权威来源；控制面 StorageTaskReconciler 仍负责
// 由 StorageTask 终态回写 NodeDisk/NodeVG 的 *任务相关* 字段（§3.4 单写者）。此处仅由
// Agent 周期写回 *观测类* 状态，避免双写冲突（不写 vgRef/raid 等任务结果字段）。
// ----------------------------------------------------------------------------

/// NodeDisk 拟写回的观测状态（对齐 Go `DiskStatus` 观测字段，§3.1）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NodeDiskStatus {
    pub phase: DiskPhase,
    pub health: Health,
    /// 占用来源（None 表示 none）。
    pub occupied_by: Option<String>,
    pub is_system_disk: bool,
}

impl Default for NodeDiskStatus {
    fn default() -> Self {
        NodeDiskStatus {
            phase: DiskPhase::Discovered,
            health: Health::Healthy,
            occupied_by: None,
            is_system_disk: false,
        }
    }
}

/// 构造写入 NodeDisk `/status` 子资源的 merge patch（纯函数，可单测）。
///
/// 仅含观测字段（phase/health/occupiedBy/isSystemDisk）；vgRef/raid/conditions 等任务结果
/// 字段由控制面写，避免双写（§3.4）。字段名与 Go `DiskStatus` JSON tag 对齐。
pub fn build_nodedisk_patch(status: &NodeDiskStatus) -> Value {
    let occupied = status
        .occupied_by
        .clone()
        .unwrap_or_else(|| "none".to_string());
    json!({
        "status": {
            "phase": status.phase.as_str(),
            "health": status.health.as_str_lowercase(),
            "occupiedBy": occupied,
            "isSystemDisk": status.is_system_disk
        }
    })
}

/// 判断两次观测状态是否变化（纯函数，可单测；用于低频刷新节流）。
pub fn diff_nodedisk_status(prev: &NodeDiskStatus, next: &NodeDiskStatus) -> bool {
    prev.phase != next.phase
        || prev.health != next.health
        || prev.occupied_by != next.occupied_by
        || prev.is_system_disk != next.is_system_disk
}

/// 低频刷新节流纯函数（可单测，§3.1）：变化 ⇒ 立即刷新；否则距上次刷新 ≥ interval 才刷新。
///
/// `last_millis=None` 表示从未刷新（首次 ⇒ 刷新）。`now_millis`/`last_millis` 为 Unix 毫秒。
pub fn should_refresh(
    last_millis: Option<u64>,
    now_millis: u64,
    changed: bool,
    interval_millis: u64,
) -> bool {
    if changed {
        return true;
    }
    match last_millis {
        None => true,
        Some(last) => now_millis.saturating_sub(last) >= interval_millis,
    }
}

/// 由当前 phase + 预检结果提议下一 phase（§3.2，复用 precheck::advance_phase）。
///
/// 仅在 `Candidate` 且预检通过（eligible）时推进到 `PreChecked`；其余保持。
pub fn propose_nodedisk_status(
    current_phase: DiskPhase,
    eligible: bool,
    health: Health,
    is_system_disk: bool,
    occupied_by: Option<String>,
) -> NodeDiskStatus {
    NodeDiskStatus {
        phase: crate::precheck::advance_phase(current_phase, eligible),
        health,
        occupied_by,
        is_system_disk,
    }
}

/// NodeDisk 状态写回通道抽象（§3.1）。真实集群走 `KubeNodeDiskReporter`（见 kube_rw）；
/// 测试/离线回退 `LogNodeDiskReporter`。
pub trait NodeDiskReporter: Send + Sync {
    fn report(&self, name: &str, status: &NodeDiskStatus) -> Result<()>;
}

/// 日志回退实现：仅打印 patch（测试与离线诊断用）。
pub struct LogNodeDiskReporter;

impl NodeDiskReporter for LogNodeDiskReporter {
    fn report(&self, name: &str, status: &NodeDiskStatus) -> Result<()> {
        let patch = build_nodedisk_patch(status);
        tracing::info!(disk = name, patch = %patch, "上报 NodeDisk 观测状态（LogNodeDiskReporter）");
        Ok(())
    }
}

/// 渲染 Prometheus 文本格式指标（single metric）。
pub fn render_metric(name: &str, value: f64, labels: &[(&str, &str)]) -> String {
    let label_str = if labels.is_empty() {
        String::new()
    } else {
        let inner = labels
            .iter()
            .map(|(k, v)| format!("{k}=\"{v}\""))
            .collect::<Vec<_>>()
            .join(",");
        format!("{{{inner}}}")
    };
    format!("# TYPE {name} gauge\n{name}{label_str} {value}\n")
}

/// 渲染 `storage_disk_smart_health{node,device,media}`（§5.4）。
pub fn render_smart_health(node: &str, device: &str, media: &str, health: Health) -> String {
    render_metric(
        "storage_disk_smart_health",
        f64::from(health.metric_value()),
        &[("node", node), ("device", device), ("media", media)],
    )
}

/// 渲染节点 agent 心跳指标（§6.1 / add-observability）：`storage_agent_heartbeat{node}` 恒为 1。
///
/// 心跳缺失上报即触发 `AgentHeartbeatLost` 告警（数据面不受影响，仅通知）。
pub fn render_heartbeat(node: &str) -> String {
    render_metric("storage_agent_heartbeat", 1.0, &[("node", node)])
}

/// 渲染 `storage_disk_media_errors{node,device,media}`（§5.4 / §8，media_errors 增量来源）。
pub fn render_media_errors(node: &str, device: &str, media: &str, count: u64) -> String {
    render_metric(
        "storage_disk_media_errors",
        count as f64,
        &[("node", node), ("device", device), ("media", media)],
    )
}

/// 渲染 `storage_disk_capacity_bytes{node,device,media}`（§5.4，容量水位基线）。
pub fn render_capacity_bytes(node: &str, device: &str, media: &str, bytes: u64) -> String {
    render_metric(
        "storage_disk_capacity_bytes",
        bytes as f64,
        &[("node", node), ("device", device), ("media", media)],
    )
}

/// 解析 collector 模式的目标设备（`HLVM_EXPORTER_DEVICE`）。
///
/// 背景：每盘一个 collector Pod 时，设备由 device plugin 下发——容器内只有 `/dev/sdX`，
/// **没有** `/dev/disk/by-id`（插件不下发 udev 链接）。若仍走 by-id 解析，每块盘都会被
/// 判为「无稳定 ID」而跳过，指标恒为空（旧 DaemonSet 形态的缺口之一）。
pub fn device_override(raw: Option<&str>) -> Option<&str> {
    let v = raw?.trim();
    if v.is_empty() {
        return None;
    }
    Some(v)
}

/// `HLVM_EXPORTER_DEVICE` 的取值：采集本容器内**实际可见**的块设备。
///
/// 为什么需要它：扩展资源只能表达「申请 N 块盘」，具体分到哪一块由 kubelet 决定，
/// NodeDisk.spec.deviceRef 只是意图而非保证。若 collector 硬编码该路径，可能采到
/// 未被授权的设备（指标为空）或把 A 盘的读数标成 B 盘。实测申请 1 块后容器 `/dev`
/// 内**只有**被分配的那块（`sda` 存在、`sdb` 不存在），因此「枚举 /dev」得到的集合
/// 恰好就是本 Pod 的授权集合。
pub const DEVICE_AUTO: &str = "auto";

/// 判断 `/dev` 下的名字是否是**整盘**设备节点（排除分区与虚拟设备）。
///
/// 纯函数以便单测：容器内 `lsblk` 不可用——挂载的是宿主 `/sys`，会列出全部磁盘。
pub fn is_whole_disk_node(name: &str) -> bool {
    // 虚拟/不可采设备：loop、ram、rom/sr、fd、device-mapper、md、zram。
    const SKIP_PREFIXES: [&str; 8] = ["loop", "ram", "sr", "fd", "dm-", "md", "zram", "nbd"];
    if SKIP_PREFIXES.iter().any(|p| name.starts_with(p)) {
        return false;
    }

    // NVMe / MMC：`nvme0n1`、`mmcblk0` 是整盘，`nvme0n1p1`、`mmcblk0p1` 是分区
    // （分区名以 `p<数字>` 结尾；`nvme0c0n1` 这类无 `p` 的仍是整盘）。
    if name.starts_with("nvme") || name.starts_with("mmcblk") {
        return match name.rsplit_once('p') {
            Some((_, tail)) => !(!tail.is_empty() && tail.chars().all(|c| c.is_ascii_digit())),
            None => true,
        };
    }

    // SCSI/SATA/USB/virtio/Xen：`sda`/`vdb`/`xvda` 是整盘，`sda1` 是分区。
    const DISK_PREFIXES: [&str; 4] = ["sd", "vd", "hd", "xvd"];
    if DISK_PREFIXES.iter().any(|p| name.starts_with(p)) {
        return !name.chars().last().is_some_and(|c| c.is_ascii_digit());
    }
    false
}

/// 枚举某 `dev_root` 下可见的整盘块设备节点（绝对路径，已排序保证输出稳定）。
pub fn visible_block_devices(dev_root: &std::path::Path) -> Vec<String> {
    use std::os::unix::fs::FileTypeExt;

    let Ok(entries) = std::fs::read_dir(dev_root) else {
        return Vec::new();
    };
    let mut out: Vec<String> = entries
        .filter_map(|e| e.ok())
        .filter(|e| {
            let name = e.file_name();
            let Some(name) = name.to_str() else {
                return false;
            };
            if !is_whole_disk_node(name) {
                return false;
            }
            e.file_type().map(|t| t.is_block_device()).unwrap_or(false)
        })
        .map(|e| dev_root.join(e.file_name()).to_string_lossy().into_owned())
        .collect();
    out.sort();
    out
}

/// 解析 `/sys/block/<name>/size` 的扇区数为字节数（内核固定 512B/扇区）。
pub fn parse_sectors(raw: &str) -> Option<u64> {
    let sectors = raw.trim().parse::<u64>().ok()?;
    Some(sectors.saturating_mul(512))
}

/// 从 sysfs 读取设备容量；失败返回 None（只少一条容量指标，不影响健康/错误指标）。
fn sysfs_capacity_bytes(name: &str) -> Option<u64> {
    std::fs::read_to_string(format!("/sys/block/{name}/size"))
        .ok()
        .and_then(|s| parse_sectors(&s))
}

/// 采集单个设备（collector 模式）。
///
/// label 用设备名而非 by-id：容器内没有 udev 链接，且本 Pod 只被分配这一块盘，
/// 设备名在节点内唯一（同一节点不会有两条 `device="sda"` 的序列）。
fn collect_device_metrics(node: &str, dev_path: &str) -> String {
    let name = std::path::Path::new(dev_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(dev_path);
    let media_str = match crate::smart::detect_media(dev_path) {
        crate::smart::Media::Nvme => "nvme",
        crate::smart::Media::SataSas => "sata_sas",
    };
    let mut out = String::new();
    // 采集失败不臆断：沿用既有语义回退 Healthy/0，只由 `smart` 模块内部告警。
    let health = crate::smart::collect_health(dev_path).unwrap_or(Health::Healthy);
    out.push_str(&render_smart_health(node, name, media_str, health));
    let media_errors = crate::smart::collect_media_errors(dev_path).unwrap_or(0);
    out.push_str(&render_media_errors(node, name, media_str, media_errors));
    if let Some(bytes) = sysfs_capacity_bytes(name) {
        out.push_str(&render_capacity_bytes(node, name, media_str, bytes));
    }
    out
}

/// 采集并渲染 exporter 全部指标（§5.4 / add-observability）。
///
/// 三种形态：
/// - `HLVM_EXPORTER_DEVICE=auto`（每盘一个 collector Pod，推荐）：采集本容器可见的块设备；
/// - `HLVM_EXPORTER_DEVICE=/dev/sdX`：只采指定设备（历史形态/调试）；
/// - 未设置（DaemonSet 形态）：枚举节点全部磁盘，按 by-id 解析后采集。
///
/// 仅只读采集：发现 → SMART 健康 + media_errors；失败设备仅告警，不臆断（占位 Healthy/0）。
/// 无集群/无磁盘时返回空指标帧（仍含心跳），保证 `/metrics` 始终可达。
pub fn collect_exporter_metrics() -> String {
    let node = std::env::var("NODE_NAME").unwrap_or_else(|_| "unknown".to_string());
    let mut out = String::new();
    out.push_str(&render_heartbeat(&node));

    let device_env = std::env::var("HLVM_EXPORTER_DEVICE").ok();
    if let Some(dev) = device_override(device_env.as_deref()) {
        if dev == DEVICE_AUTO {
            // 空集合是合法状态（Pod 刚创建、设备尚未挂入），此时只输出心跳。
            for path in visible_block_devices(std::path::Path::new("/dev")) {
                out.push_str(&collect_device_metrics(&node, &path));
            }
        } else {
            out.push_str(&collect_device_metrics(&node, dev));
        }
        return out;
    }

    match crate::discovery::enumerate_disks() {
        Ok(disks) => {
            for d in &disks {
                let path = match &d.path {
                    Some(p) => p.clone(),
                    None => continue,
                };
                // 解析为 by-id（安全约束，§5.2）；失败则跳过该盘。
                let by_id = match crate::agent::resolve_by_id(&path) {
                    Some(p) => p,
                    None => continue,
                };
                let media = crate::smart::detect_media(&by_id);
                let media_str = match media {
                    crate::smart::Media::Nvme => "nvme",
                    crate::smart::Media::SataSas => "sata_sas",
                };
                let health = crate::smart::collect_health(&by_id).unwrap_or(Health::Healthy);
                out.push_str(&render_smart_health(&node, &by_id, media_str, health));
                let media_errors = crate::smart::collect_media_errors(&by_id).unwrap_or(0);
                out.push_str(&render_media_errors(&node, &by_id, media_str, media_errors));
                if let Some(size) = &d.size {
                    if let Ok(bytes) = size.parse::<u64>() {
                        out.push_str(&render_capacity_bytes(&node, &by_id, media_str, bytes));
                    }
                }
            }
        }
        Err(e) => tracing::warn!("exporter 枚举磁盘失败（返回空指标帧）: {e}"),
    }
    out
}

/// exporter HTTP 服务（独立非特权 DaemonSet，§5.4）：在 `:9105` 暴露 `/metrics`。
///
/// 采用最小依赖实现（tokio TcpListener），避免引入额外 HTTP 框架；`/metrics` 返回
/// Prometheus 文本格式。连接处理失败仅告警，不影响主循环。
async fn serve_exporter() -> anyhow::Result<()> {
    let listener = tokio::net::TcpListener::bind("0.0.0.0:9105").await?;
    tracing::info!("exporter 监听 :9105/metrics");
    loop {
        match listener.accept().await {
            Ok((mut stream, _)) => {
                let metrics = collect_exporter_metrics();
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    metrics.len(),
                    metrics
                );
                if let Err(e) =
                    tokio::io::AsyncWriteExt::write_all(&mut stream, resp.as_bytes()).await
                {
                    tracing::warn!("exporter 写响应失败: {e}");
                }
                let _ = tokio::io::AsyncWriteExt::shutdown(&mut stream).await;
            }
            Err(e) => tracing::warn!("exporter accept 失败（继续监听）: {e}"),
        }
    }
}

/// exporter 模式入口（只读采集，独立 DaemonSet）。构建 tokio 运行时并常驻。
pub fn run_exporter() -> anyhow::Result<()> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    rt.block_on(serve_exporter())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_gauge_with_labels() {
        let m = render_metric(
            "storage_vg_free_bytes",
            123.0,
            &[("node", "n1"), ("vg", "vg1")],
        );
        assert!(m.contains("storage_vg_free_bytes{node=\"n1\",vg=\"vg1\"} 123"));
    }

    #[test]
    fn renders_smart_health() {
        let m = render_smart_health("n1", "nvme-x", "nvme", Health::Critical);
        assert!(
            m.contains("storage_disk_smart_health{node=\"n1\",device=\"nvme-x\",media=\"nvme\"} 2")
        );
    }

    #[test]
    fn renders_heartbeat() {
        let m = render_heartbeat("n1");
        assert!(m.contains("storage_agent_heartbeat{node=\"n1\"} 1"));
    }

    #[test]
    fn device_override_ignores_blank_values() {
        assert_eq!(device_override(None), None);
        assert_eq!(device_override(Some("")), None);
        assert_eq!(device_override(Some("   ")), None);
        assert_eq!(device_override(Some(" /dev/sda \n")), Some("/dev/sda"));
    }

    #[test]
    fn parse_sectors_converts_to_bytes() {
        // 2048 扇区 * 512B = 1 MiB
        assert_eq!(parse_sectors("2048\n"), Some(1_048_576));
        assert_eq!(parse_sectors("not-a-number"), None);
        assert_eq!(parse_sectors(""), None);
    }

    // ---- NodeDisk 低频写回纯函数用例 ----
    use crate::precheck::DiskPhase;

    #[test]
    fn nodedisk_patch_fields() {
        let s = NodeDiskStatus {
            phase: DiskPhase::PreChecked,
            health: Health::Critical,
            occupied_by: Some("lvm-pv".into()),
            is_system_disk: false,
        };
        let p = build_nodedisk_patch(&s);
        assert_eq!(p["status"]["phase"], "PreChecked");
        assert_eq!(p["status"]["health"], "critical");
        assert_eq!(p["status"]["occupiedBy"], "lvm-pv");
        assert_eq!(p["status"]["isSystemDisk"], false);
    }

    #[test]
    fn nodedisk_patch_none_occupied_defaults_none() {
        let s = NodeDiskStatus {
            phase: DiskPhase::Discovered,
            health: Health::Healthy,
            occupied_by: None,
            is_system_disk: false,
        };
        let p = build_nodedisk_patch(&s);
        assert_eq!(p["status"]["occupiedBy"], "none");
    }

    #[test]
    fn nodedisk_diff_detects_change() {
        let a = NodeDiskStatus {
            phase: DiskPhase::Candidate,
            health: Health::Healthy,
            occupied_by: None,
            is_system_disk: false,
        };
        let mut b = a.clone();
        assert!(!diff_nodedisk_status(&a, &b)); // 相同
        b.phase = DiskPhase::PreChecked;
        assert!(diff_nodedisk_status(&a, &b)); // phase 变化
    }

    #[test]
    fn should_refresh_logic() {
        // 变化 ⇒ 立即刷新。
        assert!(should_refresh(Some(1000), 1100, true, 600_000));
        // 未变化但首次（last=None）⇒ 刷新。
        assert!(should_refresh(None, 1100, false, 600_000));
        // 未变化且距上次 < interval ⇒ 不刷新。
        assert!(!should_refresh(Some(1000), 1100, false, 600_000));
        // 未变化且距上次 ≥ interval ⇒ 刷新。
        assert!(should_refresh(Some(1000), 1000 + 600_000, false, 600_000));
    }

    #[test]
    fn propose_advances_only_candidate_eligible() {
        let s = propose_nodedisk_status(DiskPhase::Candidate, true, Health::Healthy, false, None);
        assert_eq!(s.phase, DiskPhase::PreChecked);
        // ineligible 不推进。
        let s2 = propose_nodedisk_status(
            DiskPhase::Candidate,
            false,
            Health::Critical,
            true,
            Some("x".into()),
        );
        assert_eq!(s2.phase, DiskPhase::Candidate);
        assert!(s2.is_system_disk);
        // 非 Candidate 不推进。
        let s3 = propose_nodedisk_status(DiskPhase::Discovered, true, Health::Healthy, false, None);
        assert_eq!(s3.phase, DiskPhase::Discovered);
    }

    #[test]
    fn log_nodedisk_reporter_does_not_error() {
        let r = LogNodeDiskReporter;
        let s = NodeDiskStatus {
            phase: DiskPhase::PreChecked,
            health: Health::Healthy,
            occupied_by: None,
            is_system_disk: false,
        };
        assert!(r.report("disk1", &s).is_ok());
    }

    #[test]
    fn renders_media_errors_and_capacity() {
        let m = render_media_errors("n1", "nvme-x", "nvme", 5);
        assert!(
            m.contains("storage_disk_media_errors{node=\"n1\",device=\"nvme-x\",media=\"nvme\"} 5")
        );
        let c = render_capacity_bytes("n1", "nvme-x", "nvme", 1000);
        assert!(c.contains(
            "storage_disk_capacity_bytes{node=\"n1\",device=\"nvme-x\",media=\"nvme\"} 1000"
        ));
    }

    #[test]
    fn phase_mapping_roundtrip() {
        assert_eq!(TaskPhase::from_str("Succeeded"), TaskPhase::Succeeded);
        assert_eq!(TaskPhase::from_str("bogus"), TaskPhase::Unknown);
        assert_eq!(TaskPhase::Failed.as_str(), "Failed");
    }

    #[test]
    fn patch_succeeded_has_result() {
        let s = TaskStatus::succeeded(Some("ok".into()));
        let p = build_status_patch(&s);
        assert_eq!(p["status"]["phase"], "Succeeded");
        assert_eq!(p["status"]["result"], "success");
        assert_eq!(p["status"]["message"], "ok");
        assert!(p["status"].get("startedAt").is_none());
    }

    #[test]
    fn patch_running_omits_result_and_message() {
        let s = TaskStatus::running();
        let p = build_status_patch(&s);
        assert_eq!(p["status"]["phase"], "Running");
        assert!(p["status"].get("result").is_none());
        assert!(p["status"].get("message").is_none());
    }

    #[test]
    fn patch_failed_with_timestamps() {
        let mut s = TaskStatus::failed(Some("serial mismatch".into()));
        s.started_at = Some("2026-10-28T01:02:03Z".into());
        s.completed_at = Some("2026-10-28T01:02:05Z".into());
        let p = build_status_patch(&s);
        assert_eq!(p["status"]["phase"], "Failed");
        assert_eq!(p["status"]["result"], "failure");
        assert_eq!(p["status"]["startedAt"], "2026-10-28T01:02:03Z");
        assert_eq!(p["status"]["completedAt"], "2026-10-28T01:02:05Z");
    }

    #[test]
    fn log_reporter_does_not_error() {
        let r = LogReporter;
        assert!(r.report("t1", &TaskStatus::succeeded(None)).is_ok());
    }

    #[test]
    fn plan_to_status_mapping() {
        use crate::executor::{ExecOutcome, ExecPlan};
        assert_eq!(
            plan_to_status(&ExecPlan::AlreadyDone, None),
            TaskStatus::succeeded(Some("目标状态已达成，幂等补回执".into()))
        );
        assert_eq!(
            plan_to_status(&ExecPlan::Rejected("bad".into()), None),
            TaskStatus::failed(Some("bad".into()))
        );
        assert!(matches!(
            plan_to_status(&ExecPlan::DryRun(vec!["pvcreate".into()]), None),
            TaskStatus {
                phase: TaskPhase::Succeeded,
                ..
            }
        ));
        assert!(matches!(
            plan_to_status(&ExecPlan::Run(vec!["x".into()]), None),
            TaskStatus {
                phase: TaskPhase::Running,
                ..
            }
        ));
        assert!(matches!(
            plan_to_status(
                &ExecPlan::Run(vec![]),
                Some(&Ok(ExecOutcome::Success("ok".into())))
            ),
            TaskStatus {
                phase: TaskPhase::Succeeded,
                ..
            }
        ));
        assert!(matches!(
            plan_to_status(&ExecPlan::Run(vec![]), Some(&Err(anyhow::anyhow!("boom")))),
            TaskStatus {
                phase: TaskPhase::Failed,
                ..
            }
        ));
    }

    #[test]
    fn whole_disk_node_filter_excludes_partitions_and_virtual_devices() {
        // 整盘：必须被采集。
        for name in ["sda", "vdb", "xvda", "nvme0n1", "mmcblk0"] {
            assert!(is_whole_disk_node(name), "{name} 应视为整盘");
        }
        // 分区：同节点上会让指标出现 `device="sda1"` 的噪声序列。
        for name in ["sda1", "nvme0n1p1", "mmcblk0p1"] {
            assert!(!is_whole_disk_node(name), "{name} 应视为分区");
        }
        // 虚拟设备：不可采 SMART，且会污染「盘数」。
        for name in ["loop0", "ram0", "sr0", "dm-0", "md0", "zram0", "nbd0"] {
            assert!(!is_whole_disk_node(name), "{name} 应被跳过");
        }
        // 非磁盘命名。
        assert!(!is_whole_disk_node("tty"));
    }

    #[test]
    fn visible_block_devices_on_empty_dir_is_empty() {
        // 容器刚创建、设备尚未挂入时是合法状态：必须返回空而不是 panic。
        let dir = std::env::temp_dir().join(format!("hlvm-devview-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("建临时目录");
        assert!(visible_block_devices(&dir).is_empty());
        let _ = std::fs::remove_dir(&dir);
        // 目录不存在同样不应 panic。
        assert!(visible_block_devices(std::path::Path::new("/nonexistent-hlvm-dev")).is_empty());
    }
}
