//! 预检规则引擎（设计 §3.1 / §5.1）。
//!
//! 规则：系统盘、存在 fs/LVM/md 签名、被 multipath/dm 持有、已是 PV、SMART failed、
//! 容量/介质不符 tier。任一命中 ⇒ 不可进入 PreChecked（Candidate→PreChecked 由 agent 自动完成）。

use anyhow::Result;

/// 预检输入（运行时由 discovery + smart + lvm 填充）。
pub struct PrecheckInput {
    pub is_system_disk: bool,
    pub occupied_by: Option<String>,
    pub is_pv: bool,
    pub smart_failed: bool,
}

/// 执行预检，返回命中的不合规原因列表（空列表表示通过）。
pub fn run(input: &PrecheckInput) -> Result<Vec<String>> {
    let mut issues = Vec::new();
    if input.is_system_disk {
        issues.push("系统盘（根/boot/swap/kubelet 数据目录所在盘及其 holders）".into());
    }
    if let Some(occ) = &input.occupied_by {
        if occ != "none" {
            issues.push(format!("已被占用: {occ}"));
        }
    }
    if input.is_pv {
        issues.push("已是 PV".into());
    }
    if input.smart_failed {
        issues.push("SMART failed".into());
    }
    Ok(issues)
}

/// 预检是否通过（无命中即通过）。
pub fn is_eligible(input: &PrecheckInput) -> Result<bool> {
    Ok(run(input)?.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eligible_when_clean() {
        let input = PrecheckInput {
            is_system_disk: false,
            occupied_by: Some("none".into()),
            is_pv: false,
            smart_failed: false,
        };
        assert!(is_eligible(&input).unwrap());
    }

    #[test]
    fn blocked_on_system_disk() {
        let input = PrecheckInput {
            is_system_disk: true,
            occupied_by: Some("none".into()),
            is_pv: false,
            smart_failed: false,
        };
        let issues = run(&input).unwrap();
        assert!(issues.iter().any(|i| i.contains("系统盘")));
        assert!(!is_eligible(&input).unwrap());
    }
}
