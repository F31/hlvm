//! LVM 执行环境封装（设计 §5.3）。
//!
//! 读写路径统一经 `HLVM_HOST_WRAPPER`（默认空）构造宿主命令：若设置，则前缀注入
//! （如 `chroot /host` 或 `nsenter -t 1 -m -- chroot /host`），使 agent 调用的 lvm 二进制与
//! `/run/lock/lvm` 锁与 lvmd 完全一致，避免并发写同一 VG 时锁不互斥。
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
    argv.extend(["--reportformat".to_string(), "json".to_string()]);
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
/// 读路径现在与写路径同样尊重 `HLVM_HOST_WRAPPER`；真实环境（agent 经 `chroot /host` 调宿主
/// lvm）下，读写共用宿主 lvm 二进制与 `/run/lock/lvm` 锁，与 lvmd 互斥。
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

/// 读取 VG 信息（pvs/vgs 三方对账时使用，§2.1 / §7 drift-detector）。
pub fn report_vg() -> Result<Value> {
    lvm_json(&["vgs", "--units", "b", "--reportformat", "json"])
}

/// 读取 LV 信息（删盘保护占用判定、三方对账时使用）。
pub fn report_lv() -> Result<Value> {
    lvm_json(&["lvs", "--units", "b", "--reportformat", "json"])
}

/// 读取 PV 信息（宿主机 pv 列表，供 executor 幂等补回执，§5.3 / §3.4）。
pub fn report_pv() -> Result<Value> {
    lvm_json(&["pvs", "--units", "b", "--reportformat", "json"])
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

/// 解析后的 LV 信息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LvInfo {
    pub name: String,
    pub vg_name: String,
    pub size_bytes: u64,
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
pub fn parse_vgs(v: &Value) -> Option<Vec<VgInfo>> {
    let report = v.get("report")?.as_array()?;
    let mut out = Vec::new();
    for r in report {
        let vgs = r.get("vg").and_then(|x| x.as_array())?;
        for g in vgs {
            let name = g.get("vg_name")?.as_str()?.to_string();
            let size = parse_size(g.get("vg_size")?.as_str()?).unwrap_or(0);
            let free = parse_size(g.get("vg_free")?.as_str()?).unwrap_or(0);
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
pub fn parse_lvs(v: &Value) -> Option<Vec<LvInfo>> {
    let report = v.get("report")?.as_array()?;
    let mut out = Vec::new();
    for r in report {
        let lvs = r.get("lv").and_then(|x| x.as_array())?;
        for l in lvs {
            let name = l.get("lv_name")?.as_str()?.to_string();
            let vg = l.get("vg_name")?.as_str()?.to_string();
            let size = parse_size(l.get("lv_size")?.as_str()?).unwrap_or(0);
            out.push(LvInfo {
                name,
                vg_name: vg,
                size_bytes: size,
            });
        }
    }
    Some(out)
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
            {"lv_name":"thinpool","vg_name":"vg-node37","lv_size":"100.00g"}
        ]}]});
        let lvs = parse_lvs(&v).unwrap();
        assert_eq!(lvs.len(), 1);
        assert_eq!(lvs[0].vg_name, "vg-node37");
        assert_eq!(lvs[0].size_bytes, 100 * 1024 * 1024 * 1024);
    }

    #[test]
    fn parse_unknown_on_bad_shape() {
        assert!(parse_vgs(&json!({"report":[{"vg":[]}]}))
            .unwrap()
            .is_empty());
        assert!(parse_vgs(&json!({})).is_none());
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
        assert_eq!(
            rest,
            vec!["vgs", "--units", "b", "--reportformat", "json"]
        );
    }

    #[test]
    fn lvm_argv_applies_wrapper_prefix() {
        let (bin, rest) = lvm_argv_with(Some("chroot /host"), &["vgs", "--units", "b"]);
        assert_eq!(bin, "chroot");
        assert_eq!(
            rest,
            vec!["/host", "lvm", "vgs", "--units", "b", "--reportformat", "json"]
        );
    }

    #[test]
    fn lvm_argv_ignores_blank_wrapper() {
        let (bin, rest) = lvm_argv_with(Some("   "), &["vgs"]);
        assert_eq!(bin, "lvm");
        assert_eq!(rest, vec!["vgs", "--reportformat", "json"]);
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
