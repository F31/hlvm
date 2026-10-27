//! agent 模式主循环（设计 §5）：发现 → SMART → 预检 → 消费 StorageTask。
//!
//! 当前为骨架：串起 discovery / smart / precheck；StorageTask 消费与上报由后续 change 补全。
//! 数据面独立于控制面（§1.4）：无任务时不写任何 PV/VG/thinpool。

use crate::discovery;
use crate::precheck::{self, PrecheckInput};
use anyhow::Result;

/// agent 模式入口。
pub fn run_agent(node_name: Option<&str>) -> Result<()> {
    let node = node_name.unwrap_or("unknown");
    tracing::info!(node, "agent 模式启动（discovery → smart → precheck 骨架）");

    let disks = discovery::enumerate_disks()?;
    tracing::info!(count = disks.len(), "发现磁盘");

    for d in disks {
        // 占位：真实实现需结合 smart 与健康度做预检判定。
        let input = PrecheckInput {
            is_system_disk: false,
            occupied_by: Some("none".into()),
            is_pv: false,
            smart_failed: false,
        };
        let eligible = precheck::is_eligible(&input)?;
        tracing::info!(device = d.name, eligible, "预检结果");
    }

    Ok(())
}
