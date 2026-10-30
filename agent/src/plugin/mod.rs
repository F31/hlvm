//! 磁盘设备插件（Kubernetes Device Plugin v1beta1，`--mode=device-plugin`）。
//!
//! ## 为什么需要它
//!
//! 2026-10-30 集群实测：**非特权 Pod 受设备 cgroup 限制读不了块设备**（`dd`/`blkid`/`wipefs`
//! 在 uid=0 下仍 EPERM），加 `SYS_ADMIN`/`DAC_OVERRIDE`/`SYS_RAWIO` 也绕不过——runc 的
//! device filter 对非特权 Pod 的 allowlist 为空。于是「只读 exporter 采不到 SMART」「agent
//! 想收敛特权就得先能读盘」都卡在同一处。
//!
//! 设备插件是 kubelet 提供的那条正路：插件通过 gRPC 把每块盘作为一个可分配设备暴露，
//! Pod 在 `resources.limits` 里申请 `hlvm.io/disk`，kubelet 在创建容器时把**被分配的那几个**
//! 设备节点写进容器 devices cgroup 允许列表并注入 `/dev`——按盘授权、无需 privileged。
//!
//! ## 边界（诚实说明）
//!
//! - 本插件**只做资源暴露**，不做纳管决策：占用判定（fs/LVM/md 签名、PV 归属）的权威
//!   实现在 agent 预检（需要读盘）。这里只按 `lsblk` 的 TYPE/FSTYPE/子设备做启发式标注，
//!   用于属性展示，不阻止分配。
//! - 设备身份优先用 `/dev/disk/by-id`；无 by-id 的环境（kind 等）回退 `dev-<name>`，
//!   仅用于本次分配的设备 ID，不影响 StorageTask 的 by-id 安全约束。
//! - 插件**不采集 SMART**（非特权读不了盘），因此 `Health` 恒为 `Healthy`；健康判定仍在
//!   agent/exporter 侧。若未来要按健康剔除设备，需要另建「健康快照」输入通道。
//! - Agent 仍保持特权：它需要**所有**盘做 wipe/pvcreate，而设备插件只能表达「申请 N 块」，
//!   无法表达「按节点全集」——收敛 agent 特权不在本次范围。

// 生成物不参与 rustfmt：保持与 tonic-build 输出逐字一致，重生成时 diff 才可读。
// （`#![rustfmt::skip]` 这种 inner attribute 在非 crate 根模块上不稳定，故加在 mod 声明上。）
#[rustfmt::skip]
#[path = "generated.rs"]
pub mod pb;

use anyhow::{bail, Context, Result};
use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::sync::{mpsc, watch, RwLock};
use tokio_stream::wrappers::{ReceiverStream, UnixListenerStream};

use crate::discovery::LsblkDevice;

/// 扩展资源名（`kubectl describe node` 中可见为 `hlvm.io/disk`）。
pub const RESOURCE_NAME: &str = "hlvm.io/disk";
/// 插件在 kubelet device-plugins 目录下的 socket 文件名（注册时的 endpoint）。
pub const SOCKET_FILE: &str = "hlvm-disk.sock";
/// kubelet 侧 socket（插件反向注册的连接目标）。
pub const KUBELET_SOCKET: &str = "kubelet.sock";
/// 默认 device-plugins 目录（DaemonSet 以 hostPath 挂入）。
pub const DEFAULT_DIR: &str = "/var/lib/kubelet/device-plugins";
/// 设备 ID 最大长度：kubelet 只要求非空，但过长的 ID 会出现在日志/事件里难以阅读。
const MAX_ID_LEN: usize = 63;
/// kubelet 只认这三个大写取值（`Healthy` / `Unhealthy` / `Unknown`），小写会被判为不健康。
const HEALTH_HEALTHY: &str = "Healthy";

/// 一块可分配的整盘（数据盘）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiskDevice {
    /// 设备 ID（由 by-id 归一化，`[A-Za-z0-9._-]`，去重后唯一）。
    pub id: String,
    /// `/dev/disk/by-id/...`（平台内设备引用的规范形式）；解析不到时为 None
    /// （kind/精简节点没有 udev 生成 by-id 链接，见 `select_disks` 的回退说明）。
    pub by_id: Option<String>,
    /// 宿主机真实设备节点（如 `/dev/nvme0n1`），Allocate 时按此路径授权。
    pub path: String,
    /// 介质类型：`nvme` / `sata_sas`（标签用）。
    pub media: String,
    /// 容量（字节，未知为 0）。
    pub size_bytes: u64,
    /// 型号（未知为空串）。
    pub model: String,
    /// 占用启发式：`none` / `filesystem` / `holder`（仅展示，不参与分配决策）。
    pub occupied: String,
}

/// 由 by-id 路径生成设备 ID（纯函数）。
///
/// 归一化规则：取路径末段（by-id 名），非 `[A-Za-z0-9._-]` 一律替换为 `-`，超过 63 字符截断。
/// kubelet 只把 ID 当不透明字符串，但日志/事件里要可读，且不能携带 `/`。
pub fn device_id(by_id: &str) -> String {
    let base = by_id.rsplit('/').next().unwrap_or(by_id);
    let mut out = String::with_capacity(base.len());
    for ch in base.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
            out.push(ch);
        } else {
            out.push('-');
        }
    }
    out.truncate(MAX_ID_LEN);
    out
}

/// 解析 `/proc/<pid>/mountinfo` 的 `major:minor` 列（纯函数）。
///
/// 用途：插件容器里的 `/proc/mounts` 是**容器自己**的挂载命名空间（根是 overlay），
/// 看不到宿主机根分区所在的盘，因此不能靠它判定系统盘。宿主机的 mountinfo 通过
/// hostPID 读 `/proc/1/mountinfo` 获得，再用 `/sys/dev/block/<maj>:<min>` 反查父盘。
///
/// mountinfo 行格式：`36 35 98:0 / / rw,relatime - ext4 /dev/sda1 rw`
/// 其中第 3 列是 `major:minor`。
pub fn parse_mountinfo_majmin(text: &str) -> Vec<(u32, u32)> {
    let mut out = Vec::new();
    for line in text.lines() {
        let mut it = line.split_whitespace();
        let _id = it.next();
        let _parent = it.next();
        let Some(majmin) = it.next() else { continue };
        let Some((maj, min)) = majmin.split_once(':') else {
            continue;
        };
        if let (Ok(maj), Ok(min)) = (maj.parse::<u32>(), min.parse::<u32>()) {
            out.push((maj, min));
        }
    }
    out
}

/// 从 `/sys/dev/block/<maj>:<min>` 的解析后路径中取父盘名（纯函数）。
///
/// 例：`/sys/devices/pci0000:00/.../block/sda/sda1` → `sda`；
/// 分区/逻辑卷/多路径设备都归到其所在的整盘。
pub fn disk_from_sysfs_path(p: &str) -> Option<String> {
    let mut segs = p.split('/');
    while let Some(seg) = segs.next() {
        if seg == "block" {
            return segs.next().map(|s| s.to_string());
        }
    }
    None
}

/// 读宿主 mountinfo 并映射为「被挂载的盘名集合」（IO 部分，失败返回空集）。
///
/// 失败一律返回空集并告警：这意味着系统盘保护退化为 `lsblk` 挂载点判定（容器里可能失效），
/// 属于**降级**而非「没有系统盘」。故调用方必须同时用 `agent::is_system_disk` 兜底。
pub fn host_mounted_disks(mountinfo: &Path) -> BTreeSet<String> {
    let text = match std::fs::read_to_string(mountinfo) {
        Ok(t) => t,
        Err(e) => {
            tracing::warn!(
                path = %mountinfo.display(),
                "读不到宿主 mountinfo，系统盘判定退化为 lsblk 挂载点（非特权容器下可能失真）: {e}"
            );
            return BTreeSet::new();
        }
    };
    let mut out = BTreeSet::new();
    for (maj, min) in parse_mountinfo_majmin(&text) {
        let link = format!("/sys/dev/block/{maj}:{min}");
        let Ok(real) = std::fs::canonicalize(&link) else {
            continue;
        };
        if let Some(disk) = disk_from_sysfs_path(&real.to_string_lossy()) {
            out.insert(disk);
        }
    }
    out
}

/// 设备节点根目录：容器内可见宿主 `/dev` 的挂载点（DaemonSet 挂到 `/host/dev`）。
///
/// 为什么不能直接把宿主 `/dev` 挂到容器 `/dev`：runc 会先在容器里建一个 tmpfs `/dev`，
/// hostPath 挂到 `/dev` 会被它盖住（实测：容器内 `/dev/disk/by-id` 不存在，`/dev` 是 tmpfs），
/// 于是 by-id 解析必然失败、设备列表恒为空。
fn device_root() -> PathBuf {
    std::env::var("HLVM_DEVICE_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/dev"))
}

/// `/dev/sda` → `sda`（纯函数）。
///
/// 只接受 `/dev/` 前缀：Allocate 回给 kubelet 的 hostPath 必须是宿主机设备路径，
/// 任何其它形态（相对路径、`/sys/...`、`/host/dev/...`）都视为非法——否则会把容器内路径
/// 当成宿主路径下发，kubelet 建节点时静默失败或建出错误的设备。
pub fn dev_rel(path: &str) -> Option<&str> {
    let rel = path.strip_prefix("/dev/")?;
    if rel.is_empty() || rel.contains('/') || rel == "." || rel == ".." {
        return None;
    }
    Some(rel)
}

/// 在 `root`（宿主 /dev 的挂载点）下按 by-id 反查设备（IO）。
///
/// 返回**宿主形态**的 by-id 路径（`/dev/disk/by-id/...`），供日志与 NodeDisk 引用对齐；
/// `root` 只用于本进程读取。
pub fn resolve_by_id_in(root: &Path, device_path: &str) -> Option<String> {
    let rel = dev_rel(device_path)?;
    let target = std::fs::canonicalize(root.join(rel)).ok()?;
    let dir = root.join("disk/by-id");
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        if let Ok(c) = std::fs::canonicalize(entry.path()) {
            if c == target {
                let name = entry.file_name().to_string_lossy().to_string();
                return Some(format!("/dev/disk/by-id/{name}"));
            }
        }
    }
    None
}

/// 是否为可分配的整盘（纯函数）：排除分区/loop/rom/ram/软设备。
///
/// `TYPE` 缺失时按不可分配处理（失败关闭：宁可少暴露一块盘，也不把分区当整盘发出去）。
pub fn is_allocatable_whole_disk(d: &LsblkDevice) -> bool {
    if d.dev_type.as_deref() != Some("disk") {
        return false;
    }
    let name = d.name.to_ascii_lowercase();
    // loop（含 losetup 出来的仿真盘）/ rom / ram / zram / fd 都不是平台纳管对象。
    !(name.starts_with("loop")
        || name.starts_with("ram")
        || name.starts_with("zram")
        || name.starts_with("sr")
        || name.starts_with("fd"))
}

/// 由 `lsblk` 结果挑选可分配设备（纯函数，可单测）。
///
/// 过滤顺序：整盘 → 非系统盘（`lsblk` 挂载点 ∪ 宿主 mountinfo）→ by-id 可解析 → ID 唯一。
/// `resolve` 用于把 `/dev/sda` 解析为 `/dev/disk/by-id/...`（IO 由调用方注入，便于单测）。
pub fn select_disks(
    devs: &[LsblkDevice],
    mounted_disks: &BTreeSet<String>,
    resolve: &dyn Fn(&str) -> Option<String>,
) -> Vec<DiskDevice> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for d in devs {
        if !is_allocatable_whole_disk(d) {
            continue;
        }
        if mounted_disks.contains(&d.name) || crate::agent::is_system_disk(d) {
            tracing::debug!(device = %d.name, "跳过系统盘（宿主挂载或根/boot 挂载点）");
            continue;
        }
        let Some(path) = d.path.clone() else { continue };
        // by-id 优先（跨重启稳定）；没有 by-id 链接时回退 `dev-<name>`。
        //
        // 为什么允许回退：kind 节点与部分精简镜像不由 udev 生成 `/dev/disk/by-id`
        // （2026-10-30 实测：节点内 `/dev/disk` 整个目录都不存在），若坚持「无 by-id 即跳过」，
        // 插件在这些环境里恒为零设备、按盘分配完全无法验证。设备 ID 只在本进程与 kubelet
        // 之间用于一次分配（不落盘、不做 Task 目标），故回退不影响写路径的安全约束
        // ——StorageTask 的 `diskRef` 仍只接受 `/dev/disk/by-id/...`。
        let by_id = resolve(&path);
        let id = match &by_id {
            Some(b) => device_id(b),
            None => {
                tracing::warn!(
                    device = %path,
                    "无 by-id 链接，设备 ID 回退为 dev-<name>（kind/无 udev 环境；真实节点应存在 by-id）"
                );
                format!("dev-{}", device_id(&d.name))
            }
        };
        if id.is_empty() || !seen.insert(id.clone()) {
            tracing::warn!(device = %path, id = %id, "设备 ID 冲突或为空，跳过该盘（不做猜测性改名）");
            continue;
        }
        let size_bytes = d
            .size
            .as_deref()
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(0);
        let model = d.model.clone().unwrap_or_default();
        tracing::debug!(
            id = %id,
            path = %path,
            size_bytes,
            model = %model,
            "可分配磁盘"
        );
        out.push(DiskDevice {
            id,
            by_id,
            path,
            media: match crate::smart::detect_media(d.name.as_str()) {
                crate::smart::Media::Nvme => "nvme".to_string(),
                crate::smart::Media::SataSas => "sata_sas".to_string(),
            },
            size_bytes,
            model,
            occupied: occupied_hint(d),
        });
    }
    out
}

/// 占用启发式（仅用于设备属性展示；权威判定在 agent 预检）。
pub fn occupied_hint(d: &LsblkDevice) -> String {
    if d.fstype.as_deref().is_some_and(|s| !s.is_empty()) {
        return "filesystem".to_string();
    }
    if d.children.iter().any(|c| {
        matches!(
            c.dev_type.as_deref(),
            Some("part") | Some("dm") | Some("md") | Some("mpath")
        )
    }) {
        return "holder".to_string();
    }
    "none".to_string()
}

/// 构造 `ListAndWatch` 的设备列表（纯函数）。
///
/// `Health` 恒 `Healthy`：插件非特权、读不了盘，无法独立判定 SMART；此处不臆断「不健康」，
/// 也不假装知道（健康由 agent/exporter 上报 `storage_disk_smart_health`）。
pub fn list_devices(disks: &[DiskDevice]) -> Vec<pb::Device> {
    disks
        .iter()
        .map(|d| pb::Device {
            id: d.id.clone(),
            health: HEALTH_HEALTHY.to_string(),
            topology: Default::default(),
        })
        .collect()
}

/// 设备属性（v1beta1 的 `Device` 只有 ID/Health/Topology，属性通过 Topology 之外的
/// 注解通道不下发；这里把可读属性放进日志，供 `kubectl logs` 核对）。
fn describe(d: &DiskDevice) -> (&str, &str, &str) {
    (d.by_id.as_deref().unwrap_or("-"), &d.media, &d.occupied)
}

/// 构造 `Allocate` 响应（纯函数）。
///
/// 每个申请的 ID 映射为一条 `DeviceSpec`：`host_path` 与 `container_path` 都取**宿主机真实
/// 节点路径**（如 `/dev/nvme0n1`）——
/// 1. 不用 `by-id` 软链：kubelet 按 hostPath 的 major/minor 建节点，软链路径在建/删节点时
///    语义会漂移；
/// 2. 不用 `/dev/hlvm/<id>` 这类重命名路径：`smartctl`/`nvme` 会按路径名猜设备类型
///    （`/dev/nvme*` 才走 NVMe 分支），改名会让采集侧误判。
///
/// 未知 ID 一律报错（不静默跳过）：静默会让 Pod 拿到少于申请数量的设备，而 kubelet 认为
/// 分配成功。
///
/// 注：proto 里字段名沿用上游的 `devicesIDs`，prost 蛇形化后是 `devices_i_ds`（缩写切分），
/// 故代码里出现后者——proto 保持与 k8s 上游逐字一致，便于核对字段号。
pub fn allocate(
    disks: &[DiskDevice],
    req: &pb::AllocateRequest,
) -> Result<Vec<pb::ContainerAllocateResponse>> {
    let mut out = Vec::with_capacity(req.container_requests.len());
    for (idx, c) in req.container_requests.iter().enumerate() {
        let mut specs = Vec::with_capacity(c.devices_i_ds.len());
        for id in &c.devices_i_ds {
            let Some(d) = disks.iter().find(|d| &d.id == id) else {
                bail!(
                    "请求了未知设备 {id}（容器请求 #{idx}）：插件当前暴露 {:?}",
                    disks.iter().map(|d| &d.id).collect::<Vec<_>>()
                );
            };
            let (by_id, media, occupied) = describe(d);
            tracing::info!(
                container_request = idx,
                id = %d.id,
                host = %d.path,
                by_id,
                media,
                occupied,
                "分配磁盘设备"
            );
            specs.push(pb::DeviceSpec {
                container_path: d.path.clone(),
                host_path: d.path.clone(),
                permissions: "rw".to_string(),
            });
        }
        out.push(pb::ContainerAllocateResponse {
            envs: Default::default(),
            mounts: Vec::new(),
            devices: specs,
            annotations: Default::default(),
            cdi_devices: Vec::new(),
        });
    }
    Ok(out)
}

/// `GetPreferredAllocation`：优先满足 `must_include`，其余按可用列表顺序补齐。
///
/// 本平台的盘彼此等价（不区分 NUMA/带宽档位），故不做最优匹配；唯一的硬约束是
/// `must_include` 必须被包含、总数等于 `allocation_size`，否则 kubelet 会拒。
pub fn preferred_allocation(req: &pb::PreferredAllocationRequest) -> Vec<Vec<String>> {
    req.container_requests
        .iter()
        .map(|c| {
            let want = c.allocation_size.max(0) as usize;
            let mut chosen = Vec::new();
            for id in &c.must_include_device_i_ds {
                if chosen.len() < want && !chosen.contains(id) {
                    chosen.push(id.clone());
                }
            }
            for id in &c.available_device_i_ds {
                if chosen.len() >= want {
                    break;
                }
                if !chosen.contains(id) {
                    chosen.push(id.clone());
                }
            }
            chosen
        })
        .collect()
}

/// 注册请求（纯函数，便于断言字段与 kubelet 的期望一致）。
pub fn register_request(endpoint: &str) -> pb::RegisterRequest {
    pb::RegisterRequest {
        version: "v1beta1".to_string(),
        endpoint: endpoint.to_string(),
        resource_name: RESOURCE_NAME.to_string(),
        options: Some(pb::DevicePluginOptions {
            pre_start_required: false,
            get_preferred_allocation_available: true,
        }),
    }
}

// ---------------------------------------------------------------------------
// 运行时：gRPC 服务 + kubelet 注册
// ---------------------------------------------------------------------------

/// 共享的设备快照（ListAndWatch 与 Allocate 都读它，刷新由后台任务负责）。
type Snapshot = std::sync::Arc<RwLock<Vec<DiskDevice>>>;

struct DiskPlugin {
    disks: Snapshot,
}

#[tonic::async_trait]
impl pb::device_plugin_server::DevicePlugin for DiskPlugin {
    async fn get_device_plugin_options(
        &self,
        _request: tonic::Request<pb::Empty>,
    ) -> std::result::Result<tonic::Response<pb::DevicePluginOptions>, tonic::Status> {
        Ok(tonic::Response::new(pb::DevicePluginOptions {
            pre_start_required: false,
            get_preferred_allocation_available: true,
        }))
    }

    type ListAndWatchStream =
        ReceiverStream<std::result::Result<pb::ListAndWatchResponse, tonic::Status>>;

    /// 先发一次全量，之后**仅在设备集合变化时**再发（kubelet 会据此更新可分配数量）。
    async fn list_and_watch(
        &self,
        _request: tonic::Request<pb::Empty>,
    ) -> std::result::Result<tonic::Response<Self::ListAndWatchStream>, tonic::Status> {
        let (tx, rx) = mpsc::channel(4);
        let disks = self.disks.clone();
        tokio::spawn(async move {
            let mut last: Option<Vec<pb::Device>> = None;
            let mut tick = tokio::time::interval(Duration::from_secs(5));
            loop {
                tick.tick().await;
                let current = list_devices(&disks.read().await);
                if last.as_ref() == Some(&current) {
                    continue;
                }
                if tx
                    .send(Ok(pb::ListAndWatchResponse {
                        devices: current.clone(),
                    }))
                    .await
                    .is_err()
                {
                    // kubelet 断开（重启/插件被移除）：结束流，注册循环会重新注册。
                    tracing::info!("ListAndWatch 客户端断开，流结束");
                    return;
                }
                last = Some(current);
            }
        });
        Ok(tonic::Response::new(ReceiverStream::new(rx)))
    }

    async fn allocate(
        &self,
        request: tonic::Request<pb::AllocateRequest>,
    ) -> std::result::Result<tonic::Response<pb::AllocateResponse>, tonic::Status> {
        let disks = self.disks.read().await.clone();
        let responses = allocate(&disks, request.get_ref())
            .map_err(|e| tonic::Status::invalid_argument(e.to_string()))?;
        Ok(tonic::Response::new(pb::AllocateResponse {
            container_responses: responses,
        }))
    }

    async fn get_preferred_allocation(
        &self,
        request: tonic::Request<pb::PreferredAllocationRequest>,
    ) -> std::result::Result<tonic::Response<pb::PreferredAllocationResponse>, tonic::Status> {
        let picks = preferred_allocation(request.get_ref());
        Ok(tonic::Response::new(pb::PreferredAllocationResponse {
            container_responses: picks
                .into_iter()
                .map(|ids| pb::ContainerPreferredAllocationResponse { device_i_ds: ids })
                .collect(),
        }))
    }

    async fn pre_start_container(
        &self,
        _request: tonic::Request<pb::PreStartContainerRequest>,
    ) -> std::result::Result<tonic::Response<pb::PreStartContainerResponse>, tonic::Status> {
        // 磁盘不需要每次分配前的重置；声明 pre_start_required=false 后 kubelet 不会调用。
        Ok(tonic::Response::new(pb::PreStartContainerResponse {}))
    }
}

/// 重新扫描设备（运行时 IO）。
fn rescan() -> Vec<DiskDevice> {
    let devs = match crate::discovery::enumerate_disks() {
        Ok(d) => d,
        Err(e) => {
            tracing::warn!("设备插件枚举失败（保留上一轮快照）: {e}");
            return Vec::new();
        }
    };
    select_disks(
        &devs,
        &host_mounted_disks(mountinfo_path().as_path()),
        &|p| crate::agent::resolve_by_id(p),
    )
}

/// 宿主 mountinfo 路径：hostPID 下 `/proc/1/mountinfo` 才是宿主机命名空间。
fn mountinfo_path() -> PathBuf {
    std::env::var("HLVM_HOST_MOUNTINFO")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/proc/1/mountinfo"))
}

/// 插件 socket 目录（DaemonSet 挂载 kubelet 的 device-plugins 目录）。
fn plugin_dir() -> PathBuf {
    std::env::var("HLVM_DEVICE_PLUGIN_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(DEFAULT_DIR))
}

/// socket 的身份签名 `(dev, inode, mtime_sec, mtime_nsec)`：任一侧 socket 被重建都必然改变它。
///
/// 只用 inode 不够（2026-10-30 kind 两次实测对比）：kubelet 重启会重建 `kubelet.sock`，
/// 但同目录下「删了立刻建」很可能**复用同一个 inode**，签名不变 ⇒ 不重注册 ⇒ 节点容量
/// 永久停在 0。mtime 在 bind 时刷新，即使 inode 复用也能区分出「这是一个新的 socket」。
type SocketSig = (u64, u64, i64, i64);

fn socket_signature(p: &Path) -> Option<SocketSig> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(p)
        .ok()
        .map(|m| (m.dev(), m.ino(), m.mtime(), m.mtime_nsec()))
}

/// 向 kubelet 注册自身（Unix socket 上的 gRPC）。
///
/// tonic 没有内建的 UDS connector：`unix:` 不是合法 URI scheme（`http::Uri` 只接受
/// `scheme://authority` 形式），必须用 `connect_with_connector` + `service_fn` 自建连接。
/// 实测踩过：写 `Endpoint::try_from("unix:/...")` 会得到 `invalid URI: invalid format`。
async fn register(kubelet_socket: &Path, endpoint: &str) -> Result<()> {
    let sock = kubelet_socket.to_path_buf();
    let channel = tonic::transport::Endpoint::from_static("http://[::]:50051")
        .connect_with_connector(tower::service_fn(move |_: tonic::transport::Uri| {
            let sock = sock.clone();
            async move {
                let stream = tokio::net::UnixStream::connect(sock).await?;
                Ok::<_, std::io::Error>(hyper_util::rt::TokioIo::new(stream))
            }
        }))
        .await
        .with_context(|| format!("连接 kubelet socket 失败: {}", kubelet_socket.display()))?;
    let mut client = pb::registration_client::RegistrationClient::new(channel);
    let resp = client
        .register(register_request(endpoint))
        .await
        .context("Register RPC 失败")?
        .into_inner();
    if !resp.error.is_empty() {
        bail!("kubelet 拒绝注册: {}", resp.error);
    }
    Ok(())
}

/// 单次注册的硬超时。kubelet 重启过程中 socket 已经在、gRPC 却未必能应答；
/// 没有超时的话注册会**永久挂起**——注册循环卡在 await 上，之后再也不会重试，
/// 节点容量就永远回不来（2026-10-30 kind 实测：重建监听成功但注册停在半路，allocatable 直接消失）。
const REGISTER_TIMEOUT: Duration = Duration::from_secs(5);
/// 兜底保活：即使两侧 socket 的 inode 都没变也定期重注册一次。
/// 低频（5 分钟）是刻意的——每次重注册 kubelet 都会重建该插件的设备管理器，
/// 太频繁会让 ListAndWatch 无谓抖动；这里的目的是覆盖「inode 复用 + kubelet 内部状态丢失」这类
/// 靠签名看不出来的情况。
const REREGISTER_INTERVAL: Duration = Duration::from_secs(300);

/// 持续注册：初次注册失败不退出（kubelet 可能尚未就绪）；任一侧 socket 变化即重注册。
///
/// 为什么要把**自己的** socket 也纳入签名（2026-10-30 kind 实测）：kubelet 重启时会清空
/// device-plugins 目录下的插件 socket，只保留它自己的 `kubelet.sock`。此时插件进程还活着、
/// 监听 fd 也还有效，但目录项已经没了——kubelet 反向连接 endpoint 得到 ENOENT，注册必然失败，
/// 节点 `hlvm.io/disk` 掉到 0 且**永不恢复**（实测 allocatable 一直是 0，直到手动删插件 Pod）。
/// 只盯 kubelet.sock 的 inode 不够：inode 可能被复用，且真正的前置条件是「我的 socket 在」。
async fn registration_loop(kubelet_socket: PathBuf, endpoint: String, self_socket: PathBuf) {
    let mut last = None;
    let mut last_ok: Option<tokio::time::Instant> = None;
    loop {
        let self_sig = socket_signature(&self_socket);
        let kubelet_sig = socket_signature(&kubelet_socket);
        if self_sig.is_some() && kubelet_sig.is_some() {
            let key = (self_sig, kubelet_sig);
            let stale = last_ok.map_or(true, |t| t.elapsed() >= REREGISTER_INTERVAL);
            if last != Some(key) || stale {
                match tokio::time::timeout(REGISTER_TIMEOUT, register(&kubelet_socket, &endpoint))
                    .await
                {
                    Ok(Ok(())) => {
                        tracing::info!(
                            resource = RESOURCE_NAME,
                            endpoint,
                            "已向 kubelet 注册设备插件"
                        );
                        last = Some(key);
                        last_ok = Some(tokio::time::Instant::now());
                    }
                    Ok(Err(e)) => {
                        tracing::warn!("设备插件注册失败（5s 后重试）: {e:#}");
                        last = None;
                    }
                    Err(_) => {
                        tracing::warn!(
                            timeout = REGISTER_TIMEOUT.as_secs(),
                            "设备插件注册超时（kubelet 未应答，5s 后重试）"
                        );
                        last = None;
                    }
                }
            }
        } else if kubelet_sig.is_none() {
            tracing::debug!(path = %kubelet_socket.display(), "kubelet socket 不存在，等待");
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

/// 插件 socket 看护：目录项被删除或被替换（签名含 mtime，比 inode 更可靠）时通知外层重建监听。
///
/// 监听 fd 在 unlink 后仍然有效，但已经没有任何路径能连到它了；gRPC server 自己不会报错，
/// 所以只能靠外部探测把「重建监听 + 重新注册」串起来。
async fn socket_guard(path: PathBuf, bound: Option<SocketSig>, tx: watch::Sender<bool>) {
    loop {
        tokio::time::sleep(Duration::from_secs(2)).await;
        if socket_signature(&path) != bound {
            tracing::warn!(
                socket = %path.display(),
                "插件 socket 已被删除或替换（kubelet 重启会清空 device-plugins），重建监听并重新注册"
            );
            let _ = tx.send(true);
            return;
        }
    }
}

/// 设备快照刷新循环：变化时写回共享快照（ListAndWatch 自行比对后推送）。
async fn rescan_loop(disks: Snapshot, interval: Duration) {
    loop {
        tokio::time::sleep(interval).await;
        let next = rescan();
        if next.is_empty() {
            // 空结果可能是「真没有盘」也可能是枚举失败，一律保留旧快照，避免把节点容量清空。
            continue;
        }
        let mut w = disks.write().await;
        if *w != next {
            tracing::info!(
                count = next.len(),
                ids = ?next.iter().map(|d| d.id.as_str()).collect::<Vec<_>>(),
                "设备集合变化，更新 ListAndWatch 快照"
            );
            *w = next;
        }
    }
}

async fn serve(dir: PathBuf, rescan_interval: Duration) -> Result<()> {
    std::fs::create_dir_all(&dir)
        .with_context(|| format!("创建 device-plugins 目录失败: {}", dir.display()))?;
    let socket_path = dir.join(SOCKET_FILE);
    let kubelet_socket = dir.join(KUBELET_SOCKET);

    let initial = rescan();
    tracing::info!(
        count = initial.len(),
        ids = ?initial.iter().map(|d| d.id.as_str()).collect::<Vec<_>>(),
        "设备插件初始设备集"
    );
    let disks: Snapshot = std::sync::Arc::new(RwLock::new(initial));

    // 注册与设备扫描都是跨「监听重建」存活的长任务，只 spawn 一次：
    // 注册循环每轮自己重读两侧 socket 的签名，重建后自然会再注册一次。
    tokio::spawn(registration_loop(
        kubelet_socket,
        SOCKET_FILE.to_string(),
        socket_path.clone(),
    ));
    tokio::spawn(rescan_loop(disks.clone(), rescan_interval));

    loop {
        // 上次崩溃/上一轮监听遗留的 socket 会让 bind 失败（EADDRINUSE），必须先删。
        match std::fs::remove_file(&socket_path) {
            Ok(()) => tracing::info!(path = %socket_path.display(), "清理陈旧 socket"),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => tracing::warn!(path = %socket_path.display(), "清理陈旧 socket 失败: {e}"),
        }

        let listener = tokio::net::UnixListener::bind(&socket_path)
            .with_context(|| format!("bind {} 失败", socket_path.display()))?;
        let bound = socket_signature(&socket_path);
        tracing::info!(resource = RESOURCE_NAME, socket = %socket_path.display(), "设备插件 gRPC 服务就绪");

        let (tx, mut rx) = watch::channel(false);
        tokio::spawn(socket_guard(socket_path.clone(), bound, tx));

        let server = tonic::transport::Server::builder()
            .add_service(pb::device_plugin_server::DevicePluginServer::new(
                DiskPlugin {
                    disks: disks.clone(),
                },
            ))
            .serve_with_incoming(UnixListenerStream::new(listener));
        tokio::pin!(server);

        tokio::select! {
            r = &mut server => {
                // gRPC server 自身异常退出属于真故障：交给调用方。
                return r.context("设备插件 gRPC 服务退出");
            }
            _ = rx.changed() => {
                tracing::info!("插件 socket 已重建，重新监听（注册循环会随之重注册）");
            }
        }
        // server 在此被 drop（监听 fd 关闭）；留一点间隔避免与 kubelet 的清理动作抢同一路径。
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

/// 设备插件模式入口（`--mode=device-plugin`）。
pub fn run() -> Result<()> {
    let dir = plugin_dir();
    let secs = std::env::var("HLVM_DEVICE_RESCAN_SECS")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .filter(|s| *s >= 5)
        .unwrap_or(60);
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    rt.block_on(serve(dir, Duration::from_secs(secs)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn dev(name: &str, ty: &str, path: &str, fstype: Option<&str>) -> LsblkDevice {
        LsblkDevice {
            name: name.to_string(),
            serial: None,
            wwn: None,
            path: Some(path.to_string()),
            size: Some("1000".to_string()),
            mountpoint: Some(json!(null)),
            dev_type: Some(ty.to_string()),
            fstype: fstype.map(|s| s.to_string()),
            model: None,
            children: vec![],
        }
    }

    fn resolver(p: &str) -> Option<String> {
        let base = p.rsplit('/').next().unwrap_or(p);
        Some(format!("/dev/disk/by-id/disk-{base}"))
    }

    #[test]
    fn device_id_keeps_allowed_chars() {
        assert_eq!(
            device_id("/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S1234"),
            "nvme-Samsung_SSD_980_PRO_1TB_S1234"
        );
    }

    #[test]
    fn device_id_sanitizes_illegal_chars() {
        // wwn 形式含冒号；必须归一化，否则会出现在日志/事件里并被当成路径分隔语义。
        assert_eq!(
            device_id("/dev/disk/by-id/wwn-0x5000c500:1234"),
            "wwn-0x5000c500-1234"
        );
        assert!(!device_id("a/b/c").contains('/'));
    }

    #[test]
    fn device_id_truncates_long_names() {
        let long = format!("/dev/disk/by-id/{}", "x".repeat(200));
        assert_eq!(device_id(&long).len(), MAX_ID_LEN);
    }

    #[test]
    fn selects_only_whole_disks() {
        let devs = vec![
            dev("sda", "disk", "/dev/sda", None),
            dev("sda1", "part", "/dev/sda1", None),
            dev("loop7", "loop", "/dev/loop7", None),
            dev("sr0", "rom", "/dev/sr0", None),
            dev("zram0", "disk", "/dev/zram0", None),
        ];
        let picked = select_disks(&devs, &BTreeSet::new(), &resolver);
        assert_eq!(picked.len(), 1);
        assert_eq!(picked[0].path, "/dev/sda");
        assert_eq!(picked[0].id, "disk-sda");
    }

    #[test]
    fn skips_system_disk_by_mountpoint() {
        let mut d = dev("sda", "disk", "/dev/sda", None);
        d.mountpoint = Some(json!("/"));
        let picked = select_disks(&[d], &BTreeSet::new(), &resolver);
        assert!(picked.is_empty());
    }

    #[test]
    fn skips_system_disk_by_host_mountinfo() {
        // 容器内 lsblk 看不到根挂载点（根是 overlay），必须靠宿主 mountinfo 兜底。
        let d = dev("sda", "disk", "/dev/sda", None);
        let mounted: BTreeSet<String> = ["sda".to_string()].into_iter().collect();
        assert!(select_disks(&[d], &mounted, &resolver).is_empty());
    }

    /// 回归（2026-10-30 kind 实测）：节点没有 `/dev/disk/by-id` 时若直接跳过，
    /// 插件恒为零设备、按盘分配无法验证。故回退 `dev-<name>`，但保留 path 为宿主设备节点。
    #[test]
    fn falls_back_to_dev_name_without_by_id() {
        let d = dev("sdb", "disk", "/dev/sdb", None);
        let picked = select_disks(&[d], &BTreeSet::new(), &|_| None);
        assert_eq!(picked.len(), 1);
        assert_eq!(picked[0].id, "dev-sdb");
        assert_eq!(picked[0].path, "/dev/sdb");
        assert!(picked[0].by_id.is_none());
    }

    #[test]
    fn dedupes_colliding_ids() {
        // 两块盘解析出同一个 by-id（异常环境）：只保留第一块，不臆造 ID。
        let devs = vec![
            dev("sdb", "disk", "/dev/sdb", None),
            dev("sdc", "disk", "/dev/sdc", None),
        ];
        let picked = select_disks(&devs, &BTreeSet::new(), &|_| {
            Some("/dev/disk/by-id/same".to_string())
        });
        assert_eq!(picked.len(), 1);
    }

    #[test]
    fn hints_occupied_state() {
        let clean = dev("sdb", "disk", "/dev/sdb", None);
        assert_eq!(occupied_hint(&clean), "none");
        let fs = dev("sdb", "disk", "/dev/sdb", Some("ext4"));
        assert_eq!(occupied_hint(&fs), "filesystem");
        let mut dm = dev("sdb", "disk", "/dev/sdb", None);
        dm.children = vec![dev("dm-0", "dm", "/dev/dm-0", None)];
        assert_eq!(occupied_hint(&dm), "holder");
    }

    #[test]
    fn list_devices_shape() {
        let disks = vec![
            DiskDevice {
                id: "disk-sda".into(),
                by_id: Some("/dev/disk/by-id/disk-sda".into()),
                path: "/dev/sda".into(),
                media: "sata_sas".into(),
                size_bytes: 1000,
                model: "X".into(),
                occupied: "none".into(),
            },
            DiskDevice {
                id: "disk-sdb".into(),
                by_id: Some("/dev/disk/by-id/disk-sdb".into()),
                path: "/dev/sdb".into(),
                media: "nvme".into(),
                size_bytes: 2000,
                model: "Y".into(),
                occupied: "none".into(),
            },
        ];
        let listed = list_devices(&disks);
        assert_eq!(listed.len(), 2);
        assert_eq!(listed[0].id, "disk-sda");
        assert_eq!(listed[0].health, "Healthy");
    }

    fn sample_disks() -> Vec<DiskDevice> {
        vec![DiskDevice {
            id: "disk-sda".into(),
            by_id: Some("/dev/disk/by-id/disk-sda".into()),
            path: "/dev/sda".into(),
            media: "sata_sas".into(),
            size_bytes: 1000,
            model: "X".into(),
            occupied: "none".into(),
        }]
    }

    #[test]
    fn allocate_maps_to_device_specs() {
        let req = pb::AllocateRequest {
            container_requests: vec![pb::ContainerAllocateRequest {
                devices_i_ds: vec!["disk-sda".into()],
            }],
        };
        let resp = allocate(&sample_disks(), &req).unwrap();
        assert_eq!(resp.len(), 1);
        let spec = &resp[0].devices[0];
        assert_eq!(spec.host_path, "/dev/sda");
        assert_eq!(spec.container_path, "/dev/sda");
        assert_eq!(spec.permissions, "rw");
    }

    #[test]
    fn allocate_rejects_unknown_id() {
        let req = pb::AllocateRequest {
            container_requests: vec![pb::ContainerAllocateRequest {
                devices_i_ds: vec!["nope".into()],
            }],
        };
        let err = allocate(&sample_disks(), &req).unwrap_err().to_string();
        assert!(err.contains("未知设备"), "actual: {err}");
    }

    #[test]
    fn allocate_handles_multiple_containers() {
        let req = pb::AllocateRequest {
            container_requests: vec![
                pb::ContainerAllocateRequest {
                    devices_i_ds: vec!["disk-sda".into()],
                },
                pb::ContainerAllocateRequest {
                    devices_i_ds: vec!["disk-sda".into()],
                },
            ],
        };
        let resp = allocate(&sample_disks(), &req).unwrap();
        assert_eq!(resp.len(), 2);
    }

    #[test]
    fn preferred_allocation_honours_must_include() {
        let req = pb::PreferredAllocationRequest {
            container_requests: vec![pb::ContainerPreferredAllocationRequest {
                available_device_i_ds: vec!["a".into(), "b".into(), "c".into()],
                must_include_device_i_ds: vec!["c".into()],
                allocation_size: 2,
            }],
        };
        let picks = preferred_allocation(&req);
        assert_eq!(picks.len(), 1);
        assert_eq!(picks[0].len(), 2);
        assert!(picks[0].contains(&"c".to_string()));
    }

    #[test]
    fn register_request_fields() {
        let r = register_request(SOCKET_FILE);
        assert_eq!(r.version, "v1beta1");
        assert_eq!(r.endpoint, "hlvm-disk.sock");
        assert_eq!(r.resource_name, "hlvm.io/disk");
        let opts = r.options.unwrap();
        assert!(!opts.pre_start_required);
        assert!(opts.get_preferred_allocation_available);
    }

    #[test]
    fn dev_rel_only_accepts_dev_node_paths() {
        assert_eq!(dev_rel("/dev/sda"), Some("sda"));
        assert_eq!(dev_rel("/dev/nvme0n1"), Some("nvme0n1"));
        // 分区/by-id/软链都不是整盘节点：Allocate 只允许下发 /dev/<disk>。
        assert_eq!(dev_rel("/dev/disk/by-id/x"), None);
        assert_eq!(dev_rel("/sys/dev/sda"), None);
        assert_eq!(dev_rel("sda"), None);
        assert_eq!(dev_rel("/dev/"), None);
        assert_eq!(dev_rel("/dev/.."), None);
    }

    /// 回归（2026-10-30 首次部署）：宿主 `/dev` 若挂到容器 `/dev` 会被 runc 的 tmpfs 盖住，
    /// `/dev/disk/by-id` 不存在 ⇒ 设备列表恒为空。改为挂 `/host/dev` 后必须能正常反查，
    /// 且返回的是**宿主形态**路径（`/dev/disk/by-id/...`），否则 kubelet 拿到的是容器内路径。
    #[test]
    fn resolve_by_id_in_uses_configured_root() {
        use std::os::unix::fs::symlink;
        let root = std::env::temp_dir().join(format!("hlvm-plugin-test-{}", std::process::id()));
        let by_id = root.join("disk/by-id");
        std::fs::create_dir_all(&by_id).unwrap();
        let node = root.join("sdz");
        std::fs::write(&node, b"").unwrap();
        symlink("../../sdz", by_id.join("ata-TEST_DISK_S1")).unwrap();

        let got = resolve_by_id_in(&root, "/dev/sdz");
        assert_eq!(got.as_deref(), Some("/dev/disk/by-id/ata-TEST_DISK_S1"));
        // 不在 root 下的设备不可解析（避免把容器内路径当宿主路径）。
        assert!(resolve_by_id_in(&root, "/dev/other").is_none());

        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn parses_mountinfo_majmin() {
        let text = "36 35 98:0 / / rw,relatime - ext4 /dev/sda1 rw\n\
                    37 35 8:16 / /data rw - xfs /dev/sdb rw\n\
                    malformed\n";
        assert_eq!(parse_mountinfo_majmin(text), vec![(98, 0), (8, 16)]);
    }

    #[test]
    fn maps_sysfs_path_to_disk() {
        assert_eq!(
            disk_from_sysfs_path("/sys/devices/pci0000:00/0000:00:1f.2/ata1/host0/block/sda/sda1"),
            Some("sda".to_string())
        );
        assert_eq!(
            disk_from_sysfs_path("/sys/devices/virtual/block/loop7"),
            Some("loop7".to_string())
        );
        assert_eq!(disk_from_sysfs_path("/sys/devices/nothing"), None);
    }

    /// 回归（2026-10-30 kind 两次实测对比）：kubelet 重启会重建 `kubelet.sock`，而「删了立刻建」
    /// 在 ext4 上很可能复用同一个 inode。若签名只看 inode，就永远发现不了这次重建
    /// ⇒ 插件不重注册 ⇒ 节点 `hlvm.io/disk` 永久停在 0。签名必须包含 mtime。
    #[test]
    fn socket_signature_detects_recreation() {
        let dir = std::env::temp_dir().join(format!("hlvm-plugin-sig-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("sig.sock");

        let l1 = std::os::unix::net::UnixListener::bind(&p).unwrap();
        let s1 = socket_signature(&p);
        drop(l1);
        std::fs::remove_file(&p).unwrap();
        // 保险：即使 fs 的 mtime 精度是秒级，也能让两次的 mtime 不同。
        std::thread::sleep(Duration::from_millis(20));
        let l2 = std::os::unix::net::UnixListener::bind(&p).unwrap();
        let s2 = socket_signature(&p);

        assert!(s1.is_some() && s2.is_some(), "socket 文件应可 stat");
        assert_ne!(
            s1, s2,
            "重建后的 socket 必须产生不同签名，否则感知不到 kubelet 重启"
        );

        drop(l2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 等 socket 可连接（而非只等文件出现）：unlink 之后旧 fd 仍在，文件不存在但监听
    /// 未必真的重建过；connect 成功才证明新 listener 在对外服务。
    async fn wait_connectable(path: &Path, rounds: usize) -> bool {
        for _ in 0..rounds {
            if tokio::net::UnixStream::connect(path).await.is_ok() {
                return true;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        false
    }

    /// 回归（2026-10-30 kind 实测）：kubelet 重启会清空 device-plugins 目录下的插件 socket，
    /// 节点 `hlvm.io/disk` 掉到 0 且**永不恢复**——插件进程还活着、监听 fd 也有效，但目录项没了，
    /// kubelet 反向连接 endpoint 得到 ENOENT，注册一直失败，直到手动删掉插件 Pod 才恢复。
    /// 这里锁住修复的一半：socket 被外部删除后必须能自动重建并可连接
    /// （另一半——重建后重新注册——由注册循环的 inode 签名覆盖）。
    #[tokio::test]
    async fn serve_rebuilds_socket_after_external_removal() {
        let dir = std::env::temp_dir().join(format!("hlvm-plugin-sock-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join(SOCKET_FILE);

        let h = tokio::spawn(serve(dir.clone(), Duration::from_secs(3600)));
        assert!(wait_connectable(&socket, 100).await, "首个 socket 未就绪");

        // 模拟 kubelet 启动时的清理：直接抹掉目录项（unlink）。
        std::fs::remove_file(&socket).unwrap();
        assert!(socket_signature(&socket).is_none());

        assert!(
            wait_connectable(&socket, 200).await,
            "socket 被删后未重建监听（kubelet 重启会导致节点容量永久为 0）"
        );

        h.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
