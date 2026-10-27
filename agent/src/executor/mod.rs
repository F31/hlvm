//! StorageTask 消费者（唯一 PV/VG/pool 写路径，设计 §3.4 / §5.2 / §5.3）。
//!
//! 约束：命令一律以 argv 数组执行（禁止 shell 拼接）；设备路径只接受 by-id；
//! 破坏性动作前二次校验（serial 匹配、无签名/无持有者、非系统盘）；支持 dryRun；
//! 幂等以 taskID 去重（崩溃恢复补回执，本骨架仅做命令构造与校验）。

use crate::common::{require_by_id, AgentError};
use anyhow::Result;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskType {
    Wipe,
    PVCreate,
    VGCreate,
    VGExtend,
    VGReduce,
    ThinpoolExtend,
    MDRepair,
}

impl TaskType {
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "wipe" => Some(Self::Wipe),
            "pvcreate" => Some(Self::PVCreate),
            "vgcreate" => Some(Self::VGCreate),
            "vgextend" => Some(Self::VGExtend),
            "vgreduce" => Some(Self::VGReduce),
            "thinpool-extend" => Some(Self::ThinpoolExtend),
            "md-repair" => Some(Self::MDRepair),
            _ => None,
        }
    }

    /// 是否为破坏性任务（需 approvedBy + confirmSerial 校验）。
    pub fn is_destructive(self) -> bool {
        matches!(
            self,
            Self::Wipe | Self::VGCreate | Self::VGReduce | Self::ThinpoolExtend
        )
    }
}

#[derive(Debug, Clone)]
pub struct StorageTask {
    pub task_id: String,
    pub node: String,
    pub task_type: TaskType,
    pub target: String,
    pub confirm_serial: Option<String>,
    pub dry_run: bool,
    pub approved_by: Option<String>,
}

/// 构造待执行命令（argv 数组）。校验设备 by-id，破坏性行为校验审批与 serial。
pub fn build_command(task: &StorageTask) -> Result<Vec<String>> {
    let dev = require_by_id(&task.target)?;
    if task.task_type.is_destructive() {
        if task.approved_by.is_none() {
            return Err(AgentError::Precheck("破坏性行为缺少 approvedBy 审批人".into()).into());
        }
        // confirmSerial 一致性由调用方在二次校验阶段比对，此处仅占位声明。
    }
    let cmd = match task.task_type {
        TaskType::PVCreate => vec!["pvcreate".into(), dev],
        TaskType::VGCreate => vec!["vgcreate".into(), format!("vg-{}-{}", task.node, "tier"), dev],
        TaskType::VGExtend => vec!["vgextend".into(), format!("vg-{}", task.node), dev],
        TaskType::Wipe => vec!["wipefs".into(), "-a".into(), dev],
        TaskType::VGReduce => vec!["vgreduce".into(), "--removemissing".into(), format!("vg-{}", task.node)],
        TaskType::ThinpoolExtend => vec!["lvextend".into(), dev],
        TaskType::MDRepair => vec!["mdadm".into(), "--manage".into(), "--run".into(), dev],
    };
    Ok(cmd)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_non_by_id() {
        let t = StorageTask {
            task_id: "t1".into(),
            node: "node37".into(),
            task_type: TaskType::PVCreate,
            target: "/dev/nvme0n1".into(),
            confirm_serial: None,
            dry_run: false,
            approved_by: None,
        };
        assert!(build_command(&t).is_err());
    }

    #[test]
    fn builds_pvcreate_with_by_id() {
        let t = StorageTask {
            task_id: "t1".into(),
            node: "node37".into(),
            task_type: TaskType::PVCreate,
            target: "/dev/disk/by-id/nvme-Samsung_1234".into(),
            confirm_serial: None,
            dry_run: false,
            approved_by: None,
        };
        let cmd = build_command(&t).unwrap();
        assert_eq!(cmd, vec!["pvcreate", "/dev/disk/by-id/nvme-Samsung_1234"]);
    }

    #[test]
    fn destructive_requires_approver() {
        let t = StorageTask {
            task_id: "t1".into(),
            node: "node37".into(),
            task_type: TaskType::Wipe,
            target: "/dev/disk/by-id/nvme-Samsung_1234".into(),
            confirm_serial: None,
            dry_run: false,
            approved_by: None,
        };
        assert!(build_command(&t).is_err());
    }
}
