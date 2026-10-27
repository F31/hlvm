//! 诊断打包模块（设计 §5.1 doctor 模式）。
//!
//! 收集 lvm 状态、agent 日志、任务历史、对账结果，供故障排查。当前为占位实现。

/// doctor 模式入口：打包节点诊断信息（占位）。
pub fn run() -> anyhow::Result<()> {
    tracing::info!("doctor 模式：打包诊断信息（占位）");
    Ok(())
}
