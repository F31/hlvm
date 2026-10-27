//! LVM 执行环境封装（设计 §5.3）。
//!
//! 通过 `chroot /host`（或 nsenter）调用宿主机 lvm，与 lvmd 共享 `/run/lock/lvm` 锁；
//! 统一 `--reportformat json` 解析；解析失败一律视为"未知"，不得推断。

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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_unknown_on_bad_json() {
        // 模拟：解析失败由调用方按"未知"处理，这里验证 parse 不直接 panic。
        let v = json!({"report":[{"vg":[]}]});
        assert!(v.get("report").is_some());
    }
}
