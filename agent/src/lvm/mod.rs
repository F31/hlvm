//! LVM 执行环境封装（设计 §5.3）。
//!
//! 读写路径统一经 `HLVM_HOST_WRAPPER`（默认空）构造宿主命令：若设置，则前缀注入，
//! 使 agent 调用的 lvm 与 lvmd 落在同一份宿主二进制、同一把 `/run/lock/lvm` 锁上。
//! **推荐值**：`nsenter -t 1 -m -u -i -n -p --`（进入宿主 mount + IPC 命名空间，
//! 需 `hostPID: true` + `privileged`）。**禁止用 `chroot /host`**：只切文件系统根、
//! 不切 IPC NS，lvm/libdm 的 udev 同步用 SysV 信号量，宿主 udev 与容器 IPC NS
//! 互不可见 ⇒ 真实写操作持 VG flock 永久挂死（ADR-006 §11 真机实测）。
//! 门禁必须包含一次真实写；只读 `lvm version` 不取锁，会假绿。
//! 统一 `--reportformat json` 解析；解析失败一律视为"未知"，不得推断。
//! 本模块同时提供命令构造原语，供 executor 统一复用（单一写路径）。
//!
//! 注意：`executor::execute` 已对写路径（pvcreate/vgcreate/wipefs/…）应用同一 wrapper；
//! 此处补齐读路径（vgs/lvs/pvs 三方对账、漂移检测），**读写一致才算锁一致**。

use anyhow::Result;
use serde_json::Value;
use std::process::Command;

/// 纯函数：按 wrapper 前缀构造 lvm argv（设计 §5.3）。返回 `(bin, args)`，便于
/// `Command::new(bin).args(args)`。wrapper 为空时等价于直接 `lvm <args> --reportformat json`。
///
/// **幂等**：仅当 `args` 未自带 `--reportformat` 时才追加。真机 2026-11-12 实测
/// `lvm lvs ... --reportformat json --reportformat json` 直接报
/// `Option --reportformat may not be repeated.`（exit 3）——而 `report_vg/lv/pv`
/// 各自都带了该 flag，`lvm_json` 又无条件追加一次，导致所有读路径一直失败
/// （`build_host_state` 里 `report_pv()` 的失败被静默忽略，故长期未暴露）。
pub fn lvm_argv_with(wrapper: Option<&str>, args: &[&str]) -> (String, Vec<String>) {
    let mut argv: Vec<String> = Vec::new();
    if let Some(w) = wrapper {
        let w = w.trim();
        if !w.is_empty() {
            argv.extend(w.split_whitespace().map(|s| s.to_string()));
        }
    }
    argv.push("lvm".to_string());
    argv.extend(args.iter().map(|s| s.to_string()));
    if !args.iter().any(|a| *a == "--reportformat") {
        argv.extend(["--reportformat".to_string(), "json".to_string()]);
    }
    match argv.split_first() {
        Some((bin, rest)) => (bin.clone(), rest.to_vec()),
        None => ("lvm".to_string(), Vec::new()),
    }
}

/// 读路径 lvm 命令行：从运行环境读取 `HLVM_HOST_WRAPPER`，与 `executor::execute` 的写路径共用同一约定。
pub fn lvm_argv(args: &[&str]) -> (String, Vec<String>) {
    let wrapper = std::env::var("HLVM_HOST_WRAPPER")
        .ok()
        .filter(|s| !s.trim().is_empty());
    lvm_argv_with(wrapper.as_deref(), args)
}

/// 调用宿主机 lvm 并解析 JSON 输出（§5.3）。
///
/// 读路径现在与写路径同样尊重 `HLVM_HOST_WRAPPER`；真实环境（agent 经
/// `nsenter -t 1 -m -u -i -n -p --` 进入宿主 mount + IPC NS）下，读写共用宿主 lvm
/// 二进制、`/run/lock/lvm` 锁与宿主 udev 信号量，与 lvmd 互斥。
/// 注意：本函数只做读，不能当作 §5.3 门禁——真实写路径由
/// `docs/poc/scripts/host-wrapper-gate.sh` 验证（ADR-006 §11）。
pub fn lvm_json(args: &[&str]) -> Result<Value> {
    let (bin, rest) = lvm_argv(args);
    let out = Command::new(&bin).args(&rest).output()?;
    if !out.status.success() {
        anyhow::bail!(
            "lvm {:?} 执行失败: {}",
            rest,
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(serde_json::from_slice(&out.stdout)?)
}

/// `vgs` 读路径固定列（ADR-006 §23.12）：显式 `-o`，不依赖 `vgs` 的默认列集。
///
/// 不带 `-o` 时 `vgs` 输出的默认列随 LVM 版本变化（旧版本无 `vg_attr`、部分发行版
/// 追加 `vg_skip_*`）。容量上报只需要这三列，缺任何一列都必须失败关闭——
/// 「少一列」绝不能退化成「读到 0」。
const VG_CAPACITY_ARGS: &[&str] = &["vgs", "-o", "vg_name,vg_size,vg_free", "--units", "b"];

/// 读取 VG 信息（`status.totalBytes/freeBytes` 与 `storage_vg_*` 的唯一数据源，
/// ADR-006 §23.12；pvs/vgs 三方对账亦复用本函数）。
pub fn report_vg() -> Result<Value> {
    lvm_json(VG_CAPACITY_ARGS)
}

/// `lvs` 读路径固定列（ADR-006 §16）：`lv_attr` / `pool_lv` 用于区分 thin-pool
/// 自身与业务 LV；`--reportformat` 由 `lvm_json` 统一注入，避免重复 flag。
const LV_REPORT_ARGS: &[&str] = &[
    "lvs",
    "-o",
    "lv_name,vg_name,lv_size,lv_attr,pool_lv",
    "--units",
    "b",
];

/// 读取 LV 信息（删盘保护占用判定、三方对账时使用，ADR-006 §16）。
///
/// 显式 `-o` 固定列集合：除名称/容量外必须取 `lv_attr` 与 `pool_lv`，否则无法区分
/// thin-pool 自身（`twi-aotz--`）与业务 thin LV（`Vwi-aotz--`，`pool_lv=thinpool`）。
/// 真机 2026-11-12 实测字段：`lv_name/vg_name/lv_size/lv_attr/pool_lv`。
pub fn report_lv() -> Result<Value> {
    lvm_json(LV_REPORT_ARGS)
}

/// 读取 PV 信息（宿主机 pv 列表，供 executor 幂等补回执，§5.3 / §3.4）。
pub fn report_pv() -> Result<Value> {
    lvm_json(&["pvs", "--units", "b"])
}

/// 解析后的 PV 信息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PvInfo {
    pub name: String,
    pub vg_name: String,
}

/// 解析 `pvs --reportformat json`（纯函数）。返回 PV 设备路径与所属 VG（空串表示游离）。
pub fn parse_pvs(v: &Value) -> Option<Vec<PvInfo>> {
    let report = v.get("report")?.as_array()?;
    let mut out = Vec::new();
    for r in report {
        let pvs = r.get("pv").and_then(|x| x.as_array())?;
        for p in pvs {
            let name = p.get("pv_name")?.as_str()?.to_string();
            let vg = p
                .get("vg_name")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            out.push(PvInfo { name, vg_name: vg });
        }
    }
    Some(out)
}

/// 解析后的 VG 信息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VgInfo {
    pub name: String,
    pub size_bytes: u64,
    pub free_bytes: u64,
}

/// 解析后的 LV 信息（`lvs -o ... --reportformat json`）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LvInfo {
    pub name: String,
    pub vg_name: String,
    pub size_bytes: u64,
    /// `lv_attr`：thin-pool 自身 `twi-aotz--`、业务 thin LV `Vwi-aotz--`、普通 LV `-wi-a-----`。
    /// 缺省空串表示「类型未知」，上报侧必须按失败关闭跳过（不得推断成业务 LV）。
    pub lv_attr: String,
    /// `pool_lv`：业务 thin LV 指向其 thin-pool；普通 LV / pool 自身为空。
    pub pool_lv: String,
}

/// 解析 lvm JSON 中的尺寸字符串（支持 b/k/m/g/t/p 后缀，缺省按字节）。
/// 解析失败返回 None（按"未知"处理，不推断）。
pub fn parse_size(s: &str) -> Option<u64> {
    let s = s.trim();
    let (num, mult) = match s.chars().last() {
        Some(c) if "bkmgtp".contains(c.to_ascii_lowercase()) => {
            let n = s[..s.len() - 1].trim().parse::<f64>().ok()?;
            (n, suffix_mult(c.to_ascii_lowercase()))
        }
        _ => (s.parse::<f64>().ok()?, 1.0),
    };
    Some((num * mult) as u64)
}

fn suffix_mult(c: char) -> f64 {
    match c {
        'b' => 1.0,
        'k' => 1024.0,
        'm' => 1024.0 * 1024.0,
        'g' => 1024.0 * 1024.0 * 1024.0,
        't' => 1024.0 * 1024.0 * 1024.0 * 1024.0,
        'p' => 1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0,
        _ => 1.0,
    }
}

/// 解析 `vgs --reportformat json` 输出（纯函数）。结构异常返回 None。
///
/// **单条失败关闭**：`vg_name` / `vg_size` / `vg_free` 任一缺失或不可解析时整条丢弃，
/// 绝不 `unwrap_or(0)`。把「读不到」记成 0 会让 VG 看起来「总量 0 / 空闲 0」：
/// 一方面 `storage_vg_*` 序列虽在、数值却是假的（假绿），另一方面
/// `requireFreeVGSpace` 会把「未知」当成「空间耗尽」而误报转人工。
/// 丢弃该条后上报侧写 `null` 删字段，控制面随即撤销整组序列——「不知道」就是不知道。
pub fn parse_vgs(v: &Value) -> Option<Vec<VgInfo>> {
    let report = v.get("report")?.as_array()?;
    let mut out = Vec::new();
    for r in report {
        let vgs = r.get("vg").and_then(|x| x.as_array())?;
        for g in vgs {
            let name = match g.get("vg_name").and_then(|x| x.as_str()) {
                Some(n) if !n.is_empty() => n.to_string(),
                _ => continue,
            };
            let size = match g.get("vg_size").and_then(|x| x.as_str()) {
                Some(s) => parse_size(s),
                None => None,
            };
            let free = match g.get("vg_free").and_then(|x| x.as_str()) {
                Some(s) => parse_size(s),
                None => None,
            };
            let (size, free) = match (size, free) {
                (Some(s), Some(f)) => (s, f),
                _ => continue,
            };
            out.push(VgInfo {
                name,
                size_bytes: size,
                free_bytes: free,
            });
        }
    }
    Some(out)
}

/// 解析 `lvs --reportformat json` 输出（纯函数）。结构异常返回 None。
///
/// `lv_attr` / `pool_lv` 为可选列：旧环境的 lvs 输出或缺列时记为空串（类型未知），
/// 由 `is_reportable_lv` 失败关闭跳过，绝不把 thin-pool 当业务 LV 上报。
pub fn parse_lvs(v: &Value) -> Option<Vec<LvInfo>> {
    let report = v.get("report")?.as_array()?;
    let mut out = Vec::new();
    for r in report {
        let lvs = r.get("lv").and_then(|x| x.as_array())?;
        for l in lvs {
            let name = l.get("lv_name")?.as_str()?.to_string();
            let vg = l.get("vg_name")?.as_str()?.to_string();
            let size = parse_size(l.get("lv_size")?.as_str()?).unwrap_or(0);
            let attr = l
                .get("lv_attr")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            let pool = l
                .get("pool_lv")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            out.push(LvInfo {
                name,
                vg_name: vg,
                size_bytes: size,
                lv_attr: attr,
                pool_lv: pool,
            });
        }
    }
    Some(out)
}

/// 判定一条 LV 是否属于「需要上报给控制面做三方对账的业务 LV」（ADR-006 §16）。
///
/// 真机宿主 `lvs` 除业务 LV 外还包含 thin-pool 自身（`twi-aotz--`，36 GiB）；
/// 全量上报会让每个节点稳定产生一条 `unmanaged-lv` 误报（控制面
/// `TestDetectDrift_ThinPoolLVNeedsReporterFiltering` 钉死该前置行为）。
///
/// 过滤规则（只排除内部对象，绝不排除手工创建的普通 LV）：
///   - `lv_name` 以 `[` 开头：LVM 内部 LV（如 `[thinpool_tdata]`）；
///   - `lv_attr` 首位 `t` / `T`：thin-pool 自身与其内部数据区；
///   - `lv_attr` 缺失/为空：类型未知，失败关闭（宁可少报，不误报）。
///
/// 保留：`Vwi-...` 业务 thin LV、`-wi-...` 手工普通 LV（后者正是漂移检测要发现的）。
pub fn is_reportable_lv(lv: &LvInfo) -> bool {
    if lv.name.is_empty() || lv.name.starts_with('[') {
        return false;
    }
    match lv.lv_attr.chars().next() {
        Some('t') | Some('T') => false,
        Some(_) => true,
        None => false,
    }
}

/// 解析并过滤出可直接上报的业务 LV 清单（纯函数，便于单测与复用）。
pub fn reportable_lvs(v: &Value) -> Option<Vec<LvInfo>> {
    Some(parse_lvs(v)?.into_iter().filter(is_reportable_lv).collect())
}

// ----------------------------------------------------------------------------
// thin-pool / VG 容量采集（exporter 指标来源，ADR-006 §23.11）
// ----------------------------------------------------------------------------

/// 容量读路径列集合：在三方对账列之上增加 `data_percent` / `metadata_percent` /
/// `lv_health_status`。
///
/// **不复用 `LV_REPORT_ARGS`**：对账路径不需要百分比，而 `lv_health_status` 在旧 LVM
/// 不存在，混列会让对账读路径整体失败（`lvs` 对未知列直接退出非零）。
const LV_CAPACITY_ARGS: &[&str] = &[
    "lvs",
    "-o",
    "lv_name,vg_name,lv_size,lv_attr,pool_lv,data_percent,metadata_percent,lv_health_status",
    "--units",
    "b",
];

/// 读取 thin-pool 容量所需列（exporter 专用读路径）。
pub fn report_lv_capacity() -> Result<Value> {
    lvm_json(LV_CAPACITY_ARGS)
}

/// 单个 thin-pool 的运行时容量。
#[derive(Debug, Clone, PartialEq)]
pub struct ThinPoolInfo {
    pub vg_name: String,
    pub pool_name: String,
    pub size_bytes: u64,
    /// `None` = lvs 未返回可解析的值（权限不足或 LVM 版本过旧）。
    ///
    /// 调用方**必须跳过该序列**而不是填 0：真机实测 root 但无 `CAP_SYS_ADMIN` 时
    /// `lvs` 仍退出 0，`data_percent` 返回 `""`——填 0 会让 ≥85% 的 critical 告警永久不触发。
    pub data_percent: Option<f64>,
    pub metadata_percent: Option<f64>,
    /// `lv_health_status` 空串是**正常**状态，故只有 `Some` 才代表可判定；
    /// `None` 表示该列缺失，不得当作健康。
    pub out_of_space: Option<bool>,
    /// 同 pool 下所有 thin LV 的**虚拟**大小之和（非已分配空间）。
    pub provisioned_bytes: u64,
}

impl ThinPoolInfo {
    /// 超分比例 = 已置备虚拟容量 / 池实际容量。池容量未知时返回 0。
    pub fn overprovision_ratio(&self) -> f64 {
        if self.size_bytes == 0 {
            0.0
        } else {
            self.provisioned_bytes as f64 / self.size_bytes as f64
        }
    }
}

/// 解析 lvs JSON 的百分比列。
///
/// lvs 以字符串输出（`"49.18"` / `""`）。空串既可能是「该卷不适用」也可能是
/// 「读不到」——两者对告警是同一后果，统一返回 `None` 交由调用方跳过。
fn parse_percent(v: Option<&Value>) -> Option<f64> {
    let raw = v?;
    if let Some(s) = raw.as_str() {
        let s = s.trim();
        if s.is_empty() {
            return None;
        }
        return s.parse::<f64>().ok();
    }
    raw.as_f64()
}

/// 判定 `lv_health_status` 是否代表不可用。
///
/// 取值可能是 `out_of_data`、`needs_check`、`failed`（含逗号组合）。空串是正常状态；
/// 整列缺失返回 `None`（不可判定），**不得**降级成「健康」。
fn is_out_of_space(health: Option<&Value>) -> Option<bool> {
    let s = health?.as_str()?.trim();
    let norm = s.to_ascii_lowercase().replace(['-', ' '], "_");
    Some(norm.contains("out_of_data") || norm.contains("needs_check") || norm.contains("failed"))
}

/// 解析 `lvs --reportformat json` 中的 thin-pool 容量（纯函数）。
///
/// 池自身 = `lv_attr` 首位 `t`/`T` 且名字不以 `[` 开头；`V` 开头且 `pool_lv` 指向
/// 某池的 thin LV 计入该池的 `provisioned_bytes`。字段异常一律不推断：
/// `report` 缺失返回 `None`，单条缺名字则跳过该条。
pub fn parse_thin_pools(v: &Value) -> Option<Vec<ThinPoolInfo>> {
    let report = v.get("report")?.as_array()?;
    let mut pools: Vec<ThinPoolInfo> = Vec::new();
    let mut thin_lv: Vec<(String, String, u64)> = Vec::new();

    for r in report {
        let lvs = match r.get("lv").and_then(|x| x.as_array()) {
            Some(a) => a,
            None => continue,
        };
        for l in lvs {
            let name = match l.get("lv_name").and_then(|x| x.as_str()) {
                Some(s) if !s.is_empty() => s,
                _ => continue,
            };
            if name.starts_with('[') {
                continue;
            }
            let vg = l
                .get("vg_name")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            let attr = l.get("lv_attr").and_then(|x| x.as_str()).unwrap_or("");
            let size = parse_size(l.get("lv_size").and_then(|x| x.as_str()).unwrap_or(""))
                .unwrap_or(0);
            match attr.chars().next() {
                Some('t') | Some('T') => pools.push(ThinPoolInfo {
                    vg_name: vg,
                    pool_name: name.to_string(),
                    size_bytes: size,
                    data_percent: parse_percent(l.get("data_percent")),
                    metadata_percent: parse_percent(l.get("metadata_percent")),
                    out_of_space: is_out_of_space(l.get("lv_health_status")),
                    provisioned_bytes: 0,
                }),
                Some('V') => {
                    let pool = l.get("pool_lv").and_then(|x| x.as_str()).unwrap_or("");
                    if !pool.is_empty() {
                        thin_lv.push((vg, pool.to_string(), size));
                    }
                }
                _ => {}
            }
        }
    }

    for (vg, pool, size) in thin_lv {
        if let Some(p) = pools
            .iter_mut()
            .find(|p| p.vg_name == vg && p.pool_name == pool)
        {
            p.provisioned_bytes = p.provisioned_bytes.saturating_add(size);
        }
    }
    Some(pools)
}

/// 宿主机 LVM 命令构造原语（argv 数组，禁止 shell 拼接）。

pub fn pvcreate_cmd(dev: &str) -> Vec<String> {
    vec!["pvcreate".into(), dev.into()]
}
pub fn vgcreate_cmd(vg: &str, dev: &str) -> Vec<String> {
    vec!["vgcreate".into(), vg.into(), dev.into()]
}
pub fn vgextend_cmd(vg: &str, dev: &str) -> Vec<String> {
    vec!["vgextend".into(), vg.into(), dev.into()]
}
pub fn vgreduce_cmd(vg: &str, dev: &str) -> Vec<String> {
    vec!["vgreduce".into(), vg.into(), dev.into()]
}
pub fn lvextend_cmd(dev: &str) -> Vec<String> {
    vec!["lvextend".into(), dev.into()]
}
pub fn wipefs_cmd(dev: &str) -> Vec<String> {
    vec!["wipefs".into(), "-a".into(), dev.into()]
}
pub fn mdadm_run_cmd(dev: &str) -> Vec<String> {
    vec![
        "mdadm".into(),
        "--manage".into(),
        "--run".into(),
        dev.into(),
    ]
}

/// 宿主机 lvm.conf `devices{}` / devices file 管理（§5.3 / 4.3）。
///
/// 将 lvm 扫描范围限定为已纳管 by-id 白名单，避免误扫系统盘/非纳管盘。

/// 渲染 devices file 内容（每行一个 by-id，注释行以 `#` 开头，§4.3）。
pub fn render_devices_file(managed_by_id: &[String]) -> String {
    let mut s =
        String::from("# hlvm managed devices file (auto-generated, do not edit manually)\n");
    for d in managed_by_id {
        s.push_str(d);
        s.push('\n');
    }
    s
}

/// 校验 devices file 内容：非空且每行均为 `/dev/disk/by-id/`（§4.3 安全约束）。
///
/// 注释行与空行忽略；若任一有效行非 by-id ⇒ 校验失败（拒绝宽泛扫描）。
pub fn validate_devices_file(content: &str) -> bool {
    let lines: Vec<&str> = content
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.starts_with('#') && !l.is_empty())
        .collect();
    !lines.is_empty() && lines.iter().all(|l| l.starts_with("/dev/disk/by-id/"))
}

/// 渲染 lvm.conf `devices{}` 片段（启用 devices file，§4.3）。
pub fn render_lvm_conf_devices(devices_file_path: &str) -> String {
    format!(
        "devices {{\n    use_devicesfile = 1\n    devicesfile = \"{}\"\n}}\n",
        devices_file_path
    )
}

/// dmeventd 与 thin_pool_autoextend 管理（§4.4）。
///
/// thin-pool 使用率超过 `threshold_percent` 时由 dmeventd 触发 lvextend 扩容 `extend_percent` 比例，
/// 避免 out-of-data-space。

/// thin-pool 自动扩容参数（安全阀：阈值 <100、扩容比例 (0,100)）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ThinPoolAutoextend {
    pub threshold_percent: u8,
    pub extend_percent: u8,
}

impl Default for ThinPoolAutoextend {
    fn default() -> Self {
        ThinPoolAutoextend {
            threshold_percent: 75,
            extend_percent: 20,
        }
    }
}

/// 渲染 `activation{}` 片段（thin_pool_autoextend 配置，§4.4）。
pub fn render_thin_pool_autoextend(cfg: &ThinPoolAutoextend) -> String {
    format!(
        "activation {{\n    thin_pool_autoextend_threshold = {}\n    thin_pool_autoextend_percent = {}\n}}\n",
        cfg.threshold_percent, cfg.extend_percent
    )
}

/// 校验 thin_pool_autoextend 配置：阈值 <100、扩容比例在 (0,100)（§4.4 安全阀）。
pub fn validate_thin_pool_autoextend(cfg: &ThinPoolAutoextend) -> bool {
    cfg.threshold_percent > 0
        && cfg.threshold_percent < 100
        && cfg.extend_percent > 0
        && cfg.extend_percent < 100
}

/// 启用 dmeventd 的命令构造（argv 数组，禁止 shell 拼接）：启用并启动 lvm2-monitor。
pub fn enable_dmeventd_cmd() -> Vec<String> {
    vec![
        "systemctl".into(),
        "enable".into(),
        "--now".into(),
        "lvm2-monitor".into(),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_size_suffixes() {
        assert_eq!(parse_size("1073741824"), Some(1073741824));
        assert_eq!(parse_size("1.00g"), Some(1024 * 1024 * 1024));
        assert_eq!(parse_size("512.00m"), Some(512 * 1024 * 1024));
        assert_eq!(parse_size("2.00t"), Some(2 * 1024 * 1024 * 1024 * 1024));
        assert_eq!(parse_size("garbage"), None);
    }

    #[test]
    fn parse_vgs_drops_entry_when_value_unparseable() {
        // 假绿防线：`vg_free` 是空串/垃圾值时整条丢弃，绝不 `unwrap_or(0)`。
        // 若记成 0，VG 会显示「空闲 0」→ requireFreeVGSpace 误报「空间耗尽」。
        let v = json!({"report":[{"vg":[
            {"vg_name":"vg-bad-free","vg_size":"1.00t","vg_free":""},
            {"vg_name":"vg-bad-size","vg_size":"not-a-size","vg_free":"1.00g"},
            {"vg_name":"","vg_size":"1.00t","vg_free":"1.00g"},
            {"vg_name":"vg-good","vg_size":"1.00t","vg_free":"0"}
        ]}]});
        let vgs = parse_vgs(&v).unwrap();
        assert_eq!(vgs.len(), 1, "只应保留可解析且有名字的一条: {vgs:?}");
        assert_eq!(vgs[0].name, "vg-good");
        // freeBytes = 0 是合法的「VG 打满」，必须原样保留而不是被当成未知丢掉。
        assert_eq!(vgs[0].free_bytes, 0);
        assert_eq!(vgs[0].size_bytes, 1024 * 1024 * 1024 * 1024);
    }

    #[test]
    fn parse_vgs_works() {
        let v = json!({"report":[{"vg":[
            {"vg_name":"vg-node37","vg_size":"1.00t","vg_free":"500.00g"}
        ]}]});
        let vgs = parse_vgs(&v).unwrap();
        assert_eq!(vgs.len(), 1);
        assert_eq!(vgs[0].name, "vg-node37");
        assert_eq!(vgs[0].size_bytes, 1024 * 1024 * 1024 * 1024);
        assert_eq!(vgs[0].free_bytes, 500 * 1024 * 1024 * 1024);
    }

    #[test]
    fn parse_lvs_works() {
        let v = json!({"report":[{"lv":[
            {"lv_name":"thinpool","vg_name":"vg-node37","lv_size":"100.00g",
             "lv_attr":"twi-aotz--","pool_lv":""}
        ]}]});
        let lvs = parse_lvs(&v).unwrap();
        assert_eq!(lvs.len(), 1);
        assert_eq!(lvs[0].vg_name, "vg-node37");
        assert_eq!(lvs[0].size_bytes, 100 * 1024 * 1024 * 1024);
        assert_eq!(lvs[0].lv_attr, "twi-aotz--");
        assert_eq!(lvs[0].pool_lv, "");
    }

    /// 真机 2026-11-12 的 lvs 形状（ADR-006 §15/§16）：thin-pool 自身 + 内部 LV +
    /// TopoLVM 业务 thin LV + 手工普通 LV。只有后两者应被上报。
    #[test]
    fn reportable_lvs_filters_pool_but_keeps_manual_lv() {
        let v = json!({"report":[{"lv":[
            {"lv_name":"thinpool","vg_name":"hlvm-lvmd-vg-153","lv_size":"38654705664B",
             "lv_attr":"twi-aotz--","pool_lv":""},
            {"lv_name":"[thinpool_tdata]","vg_name":"hlvm-lvmd-vg-153","lv_size":"38654705664B",
             "lv_attr":"Twi-aotz--","pool_lv":""},
            {"lv_name":"9e639840-23de-403e-aebe-2335b9505816","vg_name":"hlvm-lvmd-vg-153",
             "lv_size":"1073741824B","lv_attr":"Vwi-aotz--","pool_lv":"thinpool"},
            {"lv_name":"manual-lv","vg_name":"hlvm-lvmd-vg-153","lv_size":"67108864B",
             "lv_attr":"-wi-a-----","pool_lv":""}
        ]}]});
        let got = reportable_lvs(&v).unwrap();
        let names: Vec<&str> = got.iter().map(|l| l.name.as_str()).collect();
        assert_eq!(
            names,
            vec!["9e639840-23de-403e-aebe-2335b9505816", "manual-lv"]
        );
        assert_eq!(got[0].size_bytes, 1073741824);
        assert_eq!(got[0].pool_lv, "thinpool");
        // 反例：不过滤则 thin-pool 会作为第 1 条 unmanaged-lv 稳定误报。
        let unfiltered = parse_lvs(&v).unwrap();
        assert_eq!(unfiltered.len(), 4);
        assert!(!is_reportable_lv(&unfiltered[0]));
    }

    #[test]
    fn reportable_lvs_fails_closed_on_unknown_attr() {
        // 旧 lvs 输出缺 lv_attr：类型未知，宁可少报也不把 pool 当业务 LV。
        let v = json!({"report":[{"lv":[
            {"lv_name":"thinpool","vg_name":"vg1","lv_size":"1.00g"}
        ]}]});
        assert!(reportable_lvs(&v).unwrap().is_empty());
        assert!(reportable_lvs(&json!({})).is_none());
    }

    #[test]
    fn parse_unknown_on_bad_shape() {
        assert!(parse_vgs(&json!({"report":[{"vg":[]}]}))
            .unwrap()
            .is_empty());
        assert!(parse_vgs(&json!({})).is_none());
    }

    /// 真机形状（ADR-006 §23.11）：池自身 + 内部 tdata + 两个业务 thin LV + 手工 LV。
    #[test]
    fn parse_thin_pools_works() {
        let v = json!({"report":[{"lv":[
            {"lv_name":"thinpool","vg_name":"hlvm-poc-vg","lv_size":"38654705664B",
             "lv_attr":"twi-aotz--","pool_lv":"",
             "data_percent":"49.18","metadata_percent":"10.32","lv_health_status":""},
            {"lv_name":"[thinpool_tdata]","vg_name":"hlvm-poc-vg","lv_size":"38654705664B",
             "lv_attr":"Twi-ao----","pool_lv":"",
             "data_percent":"","metadata_percent":"","lv_health_status":""},
            {"lv_name":"pvc-a","vg_name":"hlvm-poc-vg","lv_size":"2147483648B",
             "lv_attr":"Vwi-aotz--","pool_lv":"thinpool",
             "data_percent":"12.00","metadata_percent":"","lv_health_status":""},
            {"lv_name":"pvc-b","vg_name":"hlvm-poc-vg","lv_size":"1073741824B",
             "lv_attr":"Vwi-aotz--","pool_lv":"thinpool",
             "data_percent":"3.00","metadata_percent":"","lv_health_status":""},
            {"lv_name":"manual-lv","vg_name":"hlvm-poc-vg","lv_size":"67108864B",
             "lv_attr":"-wi-a-----","pool_lv":"",
             "data_percent":"","metadata_percent":"","lv_health_status":""}
        ]}]});
        let pools = parse_thin_pools(&v).unwrap();
        assert_eq!(pools.len(), 1);
        let p = &pools[0];
        assert_eq!(p.pool_name, "thinpool");
        assert_eq!(p.size_bytes, 38654705664);
        assert_eq!(p.data_percent, Some(49.18));
        assert_eq!(p.metadata_percent, Some(10.32));
        assert_eq!(p.out_of_space, Some(false));
        // 只累加 pool_lv 指向本池的 thin LV；手工 LV 不计入。
        assert_eq!(p.provisioned_bytes, 3 * 1024 * 1024 * 1024);
        assert!((p.overprovision_ratio() - (3221225472.0 / 38654705664.0)).abs() < 1e-9);
    }

    /// 假绿防线：权限不足时 `lvs` 仍退出 0，但百分比列返回空串。
    /// 必须解析成 `None`（调用方跳过序列），绝不能变 0——0 会让 ≥85% critical 永不触发。
    #[test]
    fn parse_thin_pools_empty_percent_is_none_not_zero() {
        let v = json!({"report":[{"lv":[
            {"lv_name":"thinpool","vg_name":"vg1","lv_size":"100.00g",
             "lv_attr":"twi-aotz--","pool_lv":"",
             "data_percent":"","metadata_percent":"","lv_health_status":""}
        ]}]});
        let p = &parse_thin_pools(&v).unwrap()[0];
        assert_eq!(p.data_percent, None);
        assert_eq!(p.metadata_percent, None);
        // 健康字段本身是空串（正常），此时仍可判定为「非 out-of-space」。
        assert_eq!(p.out_of_space, Some(false));
    }

    #[test]
    fn parse_thin_pools_health_states() {
        let mk = |h: &str| {
            json!({"report":[{"lv":[
                {"lv_name":"thinpool","vg_name":"vg1","lv_size":"1.00g",
                 "lv_attr":"twi-aotz--","pool_lv":"",
                 "data_percent":"100.00","metadata_percent":"50.00","lv_health_status":h}
            ]}]})
        };
        assert_eq!(
            parse_thin_pools(&mk("out_of_data")).unwrap()[0].out_of_space,
            Some(true)
        );
        assert_eq!(
            parse_thin_pools(&mk("needs_check")).unwrap()[0].out_of_space,
            Some(true)
        );
        assert_eq!(
            parse_thin_pools(&mk("out-of-data")).unwrap()[0].out_of_space,
            Some(true)
        );
        assert_eq!(
            parse_thin_pools(&mk("out_of_data,needs_check")).unwrap()[0].out_of_space,
            Some(true)
        );
        assert_eq!(
            parse_thin_pools(&mk("failed")).unwrap()[0].out_of_space,
            Some(true)
        );
        assert_eq!(
            parse_thin_pools(&mk("")).unwrap()[0].out_of_space,
            Some(false)
        );

        // 该列整体缺失（旧 LVM）：不可判定，不得降级成「健康」。
        let no_col = json!({"report":[{"lv":[
            {"lv_name":"thinpool","vg_name":"vg1","lv_size":"1.00g",
             "lv_attr":"twi-aotz--","pool_lv":"","data_percent":"1.00"}
        ]}]});
        assert_eq!(parse_thin_pools(&no_col).unwrap()[0].out_of_space, None);
    }

    #[test]
    fn parse_thin_pools_handles_missing_report_and_zero_size() {
        assert!(parse_thin_pools(&json!({})).is_none());
        let v = json!({"report":[{"lv":[
            {"lv_name":"thinpool","vg_name":"vg1","lv_size":"",
             "lv_attr":"twi-aotz--","pool_lv":"",
             "data_percent":"1.00","metadata_percent":"1.00","lv_health_status":""}
        ]}]});
        let p = &parse_thin_pools(&v).unwrap()[0];
        assert_eq!(p.size_bytes, 0);
        // 容量未知时超分比例返回 0 而不是除零/Inf。
        assert_eq!(p.overprovision_ratio(), 0.0);
    }

    #[test]
    fn constructors_are_argv_arrays() {
        assert_eq!(
            pvcreate_cmd("/dev/disk/by-id/x"),
            vec!["pvcreate", "/dev/disk/by-id/x"]
        );
        assert_eq!(vgreduce_cmd("vg1", "d1"), vec!["vgreduce", "vg1", "d1"]);
    }

    // ---- §5.3 host wrapper（读路径与写路径共用同一约定） ----

    #[test]
    fn lvm_argv_plain_has_reportformat() {
        let (bin, rest) = lvm_argv_with(None, &["vgs", "--units", "b"]);
        assert_eq!(bin, "lvm");
        assert_eq!(rest, vec!["vgs", "--units", "b", "--reportformat", "json"]);
    }

    #[test]
    fn lvm_argv_applies_wrapper_prefix() {
        // 纯函数支持任意空白分隔的前缀；这里只验证构造语义，不代表 chroot /host
        // 是可用配置（不切 IPC NS，真实写会挂死，见 ADR-006 §11）。
        let (bin, rest) = lvm_argv_with(Some("chroot /host"), &["vgs", "--units", "b"]);
        assert_eq!(bin, "chroot");
        assert_eq!(
            rest,
            vec![
                "/host",
                "lvm",
                "vgs",
                "--units",
                "b",
                "--reportformat",
                "json"
            ]
        );
    }

    #[test]
    fn lvm_argv_matches_recommended_nsenter_wrapper() {
        // §5.3 推荐值的 argv 必须精确：wrapper 后依次追加 lvm、子命令、参数、报表 flag。
        // 对应 docs/poc/scripts/host-wrapper-gate.sh 在 Pod 内现场拼出的命令形态。
        let wrapper = "nsenter -t 1 -m -u -i -n -p --";
        let (bin, rest) = lvm_argv_with(Some(wrapper), &["vgs", "--units", "b"]);
        assert_eq!(bin, "nsenter");
        assert_eq!(
            rest,
            vec![
                "-t",
                "1",
                "-m",
                "-u",
                "-i",
                "-n",
                "-p",
                "--",
                "lvm",
                "vgs",
                "--units",
                "b",
                "--reportformat",
                "json",
            ]
        );
    }

    #[test]
    fn lvm_argv_ignores_blank_wrapper() {
        let (bin, rest) = lvm_argv_with(Some("   "), &["vgs"]);
        assert_eq!(bin, "lvm");
        assert_eq!(rest, vec!["vgs", "--reportformat", "json"]);
    }

    /// 真机 2026-11-12 实测：重复 `--reportformat` 会让 lvm 直接 exit 3
    /// （"Option --reportformat may not be repeated."），所有读路径都会失败。
    #[test]
    fn lvm_argv_never_repeats_reportformat() {
        let (_, rest) = lvm_argv_with(None, &["lvs", "--reportformat", "json"]);
        assert_eq!(rest, vec!["lvs", "--reportformat", "json"]);
        assert_eq!(
            rest.iter()
                .filter(|a| a.as_str() == "--reportformat")
                .count(),
            1
        );
    }

    #[test]
    fn lv_report_argv_matches_real_host_command() {
        let (bin, rest) = lvm_argv_with(Some("nsenter -t 1 -m -u -i -n -p --"), LV_REPORT_ARGS);
        assert_eq!(bin, "nsenter");
        assert_eq!(
            rest.iter()
                .filter(|a| a.as_str() == "--reportformat")
                .count(),
            1
        );
        assert!(rest
            .iter()
            .any(|a| a.as_str() == "lv_name,vg_name,lv_size,lv_attr,pool_lv"));
        assert_eq!(rest.last().map(|s| s.as_str()), Some("json"));
    }

    #[test]
    fn parse_pvs_works() {
        let v = json!({"report":[{"pv":[
            {"pv_name":"/dev/disk/by-id/nvme-x","vg_name":"vg-node37"},
            {"pv_name":"/dev/disk/by-id/nvme-y","vg_name":""}
        ]}]});
        let pvs = parse_pvs(&v).unwrap();
        assert_eq!(pvs.len(), 2);
        assert_eq!(pvs[0].name, "/dev/disk/by-id/nvme-x");
        assert_eq!(pvs[0].vg_name, "vg-node37");
        assert_eq!(pvs[1].vg_name, "");
    }

    // ---- 4.3 / 4.4 配置管理 ----

    #[test]
    fn renders_devices_file() {
        let content = render_devices_file(&[
            "/dev/disk/by-id/nvme-x".into(),
            "/dev/disk/by-id/nvme-y".into(),
        ]);
        assert!(content.contains("/dev/disk/by-id/nvme-x"));
        assert!(content.contains("/dev/disk/by-id/nvme-y"));
        assert!(content.starts_with('#'));
    }

    #[test]
    fn validates_devices_file_ok_and_reject() {
        let ok = render_devices_file(&["/dev/disk/by-id/nvme-x".into()]);
        assert!(validate_devices_file(&ok));
        // 含非 by-id 行 ⇒ 拒。
        assert!(!validate_devices_file("/dev/disk/by-id/nvme-x\n/dev/sda\n"));
        // 全注释/空 ⇒ 拒（非空约束）。
        assert!(!validate_devices_file("# only comment\n"));
    }

    #[test]
    fn renders_lvm_conf_devices() {
        let s = render_lvm_conf_devices("/etc/lvm/devices/hlvm.devices");
        assert!(s.contains("use_devicesfile = 1"));
        assert!(s.contains("/etc/lvm/devices/hlvm.devices"));
    }

    #[test]
    fn renders_and_validates_autoextend() {
        let cfg = ThinPoolAutoextend::default();
        assert!(validate_thin_pool_autoextend(&cfg));
        let s = render_thin_pool_autoextend(&cfg);
        assert!(s.contains("thin_pool_autoextend_threshold = 75"));
        assert!(s.contains("thin_pool_autoextend_percent = 20"));
        // 安全阀：阈值=100 不合法。
        assert!(!validate_thin_pool_autoextend(&ThinPoolAutoextend {
            threshold_percent: 100,
            extend_percent: 20
        }));
    }

    #[test]
    fn enable_dmeventd_cmd_is_argv() {
        assert_eq!(
            enable_dmeventd_cmd(),
            vec!["systemctl", "enable", "--now", "lvm2-monitor"]
        );
    }
}
