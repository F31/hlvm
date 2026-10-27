//! agent 模式主循环（设计 §5）：发现 → SMART → 预检 → 消费 StorageTask。
//!
//! 数据面独立于控制面（§1.4）：无任务时不写任何 PV/VG/thinpool。
//! 执行器闭环（executor::process_tasks）已接入：消费 StorageTask 为唯一写路径，
//! 真实任务来源为 API watch（后续 change），当前以空队列演示"无任务不写"。

use crate::discovery;
use crate::executor::{self, HostState, StorageTask};
use crate::precheck::{self, PrecheckInput};
use anyhow::Result;

/// agent 模式入口。
pub fn run_agent(node_name: Option<&str>) -> Result<()> {
    let node = node_name.unwrap_or("unknown");
    tracing::info!(node, "agent 模式启动（discovery → smart → precheck → executor 闭环）");

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

    // 执行器闭环：消费 StorageTask（唯一写路径）。真实来源为 API watch（后续 change）；
    // 当前以空队列演示——无任务时只发现与采集，不执行任何 PV/VG/thinpool 写操作。
    let state = HostState {
        node: node.to_string(),
        ..Default::default()
    };
    let tasks: Vec<StorageTask> = Vec::new();
    let mut acked: Vec<String> = Vec::new();
    let plans = executor::process_tasks(&tasks, &state, &mut acked);
    tracing::info!(count = plans.len(), "执行器闭环已接入（当前无任务，仅发现与采集）");

    Ok(())
}
