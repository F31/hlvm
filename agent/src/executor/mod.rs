//! StorageTask 消费者（唯一 PV/VG/pool 写路径，设计 §3.4 / §5.2 / §5.3）。
//!
//! 约束：命令一律以 argv 数组执行（禁止 shell 拼接）；设备路径只接受 by-id；
//! 破坏性动作前二次校验（serial 匹配、非系统盘、已审批）；支持 dryRun；
//! 以 taskID 去重（崩溃恢复补回执）；统一经 lvm 模块构造宿主命令。

use crate::common::{require_by_id, AgentError};
use crate::lvm;
use anyhow::Result;
use std::collections::HashMap;
use std::process::Command;

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

/// 宿主机实际状态（运行时由 discovery/lvm 填充，供二次校验与状态探测补回执）。
#[derive(Debug, Clone, Default)]
pub struct HostState {
    pub node: String,
    /// 已是 PV 的盘 by-id 列表（用于 pvcreate 幂等补回执）。
    pub pvs: Vec<String>,
    /// 系统盘 by-id 列表（受保护，禁止破坏性操作）。
    pub system_disks: Vec<String>,
    /// by-id -> serial 映射（破坏性操作前二次校验 serial 一致性）。
    pub serials: HashMap<String, String>,
}

/// 执行计划（plan_execution 的纯函数输出）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExecPlan {
    /// 需真实执行宿主命令。
    Run(Vec<String>),
    /// dry-run：仅返回将执行的命令，不落地。
    DryRun(Vec<String>),
    /// 已回执/已达成目标状态，跳过（幂等补回执）。
    AlreadyDone,
    /// 校验失败，拒绝执行并记录原因。
    Rejected(String),
}

/// 执行结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExecOutcome {
    Success(String),
    Skipped,
}

/// 构造待执行命令（argv 数组）。校验设备 by-id，破坏性行为校验审批。
pub fn build_command(task: &StorageTask) -> Result<Vec<String>> {
    let dev = require_by_id(&task.target)?;
    if task.task_type.is_destructive() && task.approved_by.is_none() {
        return Err(AgentError::Precheck("破坏性行为缺少 approvedBy 审批人".into()).into());
    }
    Ok(match task.task_type {
        TaskType::PVCreate => lvm::pvcreate_cmd(&dev),
        TaskType::VGCreate => lvm::vgcreate_cmd(&format!("vg-{}-tier", task.node), &dev),
        TaskType::VGExtend => lvm::vgextend_cmd(&format!("vg-{}", task.node), &dev),
        TaskType::Wipe => lvm::wipefs_cmd(&dev),
        TaskType::VGReduce => lvm::vgreduce_cmd(&format!("vg-{}", task.node), &dev),
        TaskType::ThinpoolExtend => lvm::lvextend_cmd(&dev),
        TaskType::MDRepair => lvm::mdadm_run_cmd(&dev),
    })
}

/// 规划一次 StorageTask 的执行（纯函数，便于单测，设计 §5.2 / §5.3 / 幂等）。
///
/// 顺序：
/// 1. 幂等：taskID 已在 acked 中 → AlreadyDone（崩溃恢复不重复执行）。
/// 2. by-id 校验 + 破坏性审批（无 approvedBy → Rejected）。
/// 3. 破坏性二次校验：serial 一致性（防误选盘）、系统盘保护。
/// 4. 状态探测补回执：如 pvcreate 但盘已是 PV → AlreadyDone。
/// 5. dry-run → DryRun(cmd)；否则 Run(cmd)。
pub fn plan_execution(task: &StorageTask, state: &HostState, acked: &[String]) -> ExecPlan {
    if acked.iter().any(|a| a == &task.task_id) {
        return ExecPlan::AlreadyDone;
    }
    let dev = match require_by_id(&task.target) {
        Ok(d) => d,
        Err(e) => return ExecPlan::Rejected(format!("设备路径校验失败: {e}")),
    };
    if task.task_type.is_destructive() {
        if task.approved_by.is_none() {
            return ExecPlan::Rejected("破坏性行为缺少 approvedBy 审批人".into());
        }
        if let Some(confirm) = &task.confirm_serial {
            match state.serials.get(&dev) {
                Some(actual) if actual != confirm => {
                    return ExecPlan::Rejected(format!("serial 不一致: 期望 {confirm}, 实际 {actual}"));
                }
                None => return ExecPlan::Rejected(format!("无法读取目标盘 {dev} 的 serial")),
                _ => {}
            }
        }
        if state.system_disks.iter().any(|d| d == &dev) {
            return ExecPlan::Rejected(format!("系统盘受保护: {dev}"));
        }
    }
    // 崩溃恢复：pvcreate 但盘已是 PV → 补回执。
    if task.task_type == TaskType::PVCreate && state.pvs.iter().any(|p| p == &dev) {
        return ExecPlan::AlreadyDone;
    }
    let cmd = match build_command(task) {
        Ok(c) => c,
        Err(e) => return ExecPlan::Rejected(format!("{e}")),
    };
    if task.dry_run {
        return ExecPlan::DryRun(cmd);
    }
    ExecPlan::Run(cmd)
}

/// 执行计划落地（仅在 Run 时真实执行；dry-run/already/拒绝不写）。
///
/// 生产环境应经 `chroot /host`（或 nsenter）调用宿主机 lvm，与 lvmd 共享锁；
/// 可通过环境变量 HLVM_HOST_WRAPPER 注入前缀（如 "nsenter -t 1 -m -- chroot /host"）。
pub fn execute(plan: &ExecPlan) -> Result<ExecOutcome> {
    let ExecPlan::Run(cmd) = plan else {
        return Ok(ExecOutcome::Skipped);
    };
    let mut argv: Vec<String> = Vec::new();
    if let Ok(wrapper) = std::env::var("HLVM_HOST_WRAPPER") {
        argv.extend(wrapper.split_whitespace().map(|s| s.to_string()));
    }
    argv.extend(cmd.iter().cloned());
    let args: Vec<&str> = argv.iter().map(|s| s.as_str()).collect();
    let (bin, rest) = args.split_first().ok_or_else(|| anyhow::anyhow!("空命令"))?;
    let out = Command::new(bin).args(rest).output()?;
    if out.status.success() {
        Ok(ExecOutcome::Success(
            String::from_utf8_lossy(&out.stdout).to_string(),
        ))
    } else {
        Err(AgentError::Command(String::from_utf8_lossy(&out.stderr).to_string()).into())
    }
}

/// 执行器闭环：对一批 StorageTask 逐一规划（不在此真实落地，落地由 execute 完成）。
/// 已达成/已回执的任务会被记入 acked（崩溃恢复幂等）。返回每个任务的计划。
pub fn process_tasks(
    tasks: &[StorageTask],
    state: &HostState,
    acked: &mut Vec<String>,
) -> Vec<(String, ExecPlan)> {
    tasks
        .iter()
        .map(|t| {
            let plan = plan_execution(t, state, acked);
            if plan == ExecPlan::AlreadyDone && !acked.contains(&t.task_id) {
                acked.push(t.task_id.clone());
            }
            (t.task_id.clone(), plan)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn by_id() -> String {
        "/dev/disk/by-id/nvme-Samsung_1234".into()
    }

    fn base_task() -> StorageTask {
        StorageTask {
            task_id: "t1".into(),
            node: "node37".into(),
            task_type: TaskType::PVCreate,
            target: by_id(),
            confirm_serial: None,
            dry_run: false,
            approved_by: None,
        }
    }

    #[test]
    fn rejects_non_by_id() {
        let mut t = base_task();
        t.target = "/dev/nvme0n1".into();
        assert!(matches!(plan_execution(&t, &HostState::default(), &[]), ExecPlan::Rejected(_)));
    }

    #[test]
    fn acked_is_idempotent() {
        let t = base_task();
        let plan = plan_execution(&t, &HostState::default(), &["t1".to_string()]);
        assert_eq!(plan, ExecPlan::AlreadyDone);
    }

    #[test]
    fn destructive_requires_approver() {
        let mut t = base_task();
        t.task_type = TaskType::Wipe;
        assert!(matches!(plan_execution(&t, &HostState::default(), &[]), ExecPlan::Rejected(_)));
    }

    #[test]
    fn serial_mismatch_rejected() {
        let mut t = base_task();
        t.task_type = TaskType::Wipe;
        t.approved_by = Some("ops".into());
        t.confirm_serial = Some("SERIAL-A".into());
        let mut state = HostState::default();
        state.serials.insert(by_id(), "SERIAL-B".into());
        assert!(matches!(plan_execution(&t, &state, &[]), ExecPlan::Rejected(_)));
    }

    #[test]
    fn system_disk_protected() {
        let mut t = base_task();
        t.task_type = TaskType::Wipe;
        t.approved_by = Some("ops".into());
        let mut state = HostState::default();
        state.system_disks.push(by_id());
        assert!(matches!(plan_execution(&t, &state, &[]), ExecPlan::Rejected(_)));
    }

    #[test]
    fn already_pv_is_already_done() {
        let mut t = base_task();
        t.approved_by = Some("ops".into());
        let mut state = HostState::default();
        state.pvs.push(by_id());
        assert_eq!(plan_execution(&t, &state, &[]), ExecPlan::AlreadyDone);
    }

    #[test]
    fn dry_run_returns_command() {
        let mut t = base_task();
        t.approved_by = Some("ops".into());
        t.dry_run = true;
        let plan = plan_execution(&t, &HostState::default(), &[]);
        assert_eq!(plan, ExecPlan::DryRun(vec!["pvcreate".to_string(), by_id()]));
    }

    #[test]
    fn approved_pvcreate_runs() {
        let mut t = base_task();
        t.approved_by = Some("ops".into());
        let plan = plan_execution(&t, &HostState::default(), &[]);
        assert_eq!(plan, ExecPlan::Run(vec!["pvcreate".to_string(), by_id()]));
    }

    #[test]
    fn process_tasks_marks_acked() {
        let t = base_task();
        let mut acked = vec!["t1".to_string()];
        let plans = process_tasks(&[t], &HostState::default(), &mut acked);
        assert_eq!(plans[0].1, ExecPlan::AlreadyDone);
    }
}
