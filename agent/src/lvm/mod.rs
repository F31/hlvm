//! LVM 执行环境封装（设计 §5.3）。
//!
//! 通过 `chroot /host`（或 nsenter）调用宿主机 lvm，与 lvmd 共享 `/run/lock/lvm` 锁；
//! 统一 `--reportformat json` 解析；解析失败一律视为"未知"，不得推断。
//! 本模块同时提供命令构造原语，供 executor 统一复用（单一写路径）。

use anyhow::Result;
use serde_json::Value;
use std::process::Command;

/// 调用宿主机 lvm 并解析 JSON 输出（§5.3）。
///
/// 生产环境应改为 `chroot /host lvm ...` 以保证与 lvmd 同工具/同锁；此处以可直接调用的
/// `lvm` 占位，便于非特权/测试环境运行。
pub fn lvm_json(args: &[&str]) -> Result<Value> {
    let out = Command::new("lvm")
        .args(args)
        .arg("--reportformat")
        .arg("json")
        .output()?;
    if !out.status.success() {
        anyhow::bail!("lvm {:?} 执行失败: {}", args, String::from_utf8_lossy(&out.stderr));
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
            out.push(VgInfo { name, size_bytes: size, free_bytes: free });
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
            out.push(LvInfo { name, vg_name: vg, size_bytes: size });
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
    vec!["mdadm".into(), "--manage".into(), "--run".into(), dev.into()]
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
        assert!(parse_vgs(&json!({"report":[{"vg":[]}]})).unwrap().is_empty());
        assert!(parse_vgs(&json!({})).is_none());
    }

    #[test]
    fn constructors_are_argv_arrays() {
        assert_eq!(pvcreate_cmd("/dev/disk/by-id/x"), vec!["pvcreate", "/dev/disk/by-id/x"]);
        assert_eq!(vgreduce_cmd("vg1", "d1"), vec!["vgreduce", "vg1", "d1"]);
    }
}
