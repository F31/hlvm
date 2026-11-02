//! hlvm 节点 Agent 入口（设计 §5）。
//!
//! 单一二进制，按 `--mode` 切换：
//! - `agent`：磁盘发现、SMART、预检、StorageTask 执行（唯一 PV/VG/pool 写路径）。
//! - `exporter`：只读指标采集（独立非特权 DaemonSet）。
//! - `device-plugin`：按盘暴露 `hlvm.io/disk`，让非特权 Pod 获得指定磁盘的访问权。
//! - `doctor`：节点诊断打包。

mod agent;
mod common;
mod discovery;
mod doctor;
mod executor;
mod lvm;
mod plugin;
mod precheck;
mod reporter;
mod smart;

use clap::{Parser, ValueEnum};
use std::io::IsTerminal;
use tracing_subscriber::EnvFilter;

#[derive(Copy, Clone, PartialEq, Eq, Debug, ValueEnum)]
enum Mode {
    Agent,
    Exporter,
    DevicePlugin,
    Doctor,
}

/// 构建期提交号：CI 用 HLVM_GIT_COMMIT 注入，本地构建回退到 unknown。
/// 版本号本身取自 Cargo 包版本（`--version` 由 clap 自动输出），这里补上提交号，
/// 让 `kubectl logs` 能直接看出节点上跑的是哪个构建。
const BUILD_COMMIT: &str = match option_env!("HLVM_GIT_COMMIT") {
    Some(c) => c,
    None => "unknown",
};

#[derive(Parser)]
#[command(
    name = "hlvm-agent",
    version,
    about = "hlvm 节点 Agent（discovery/smart/precheck/executor/lvm/reporter/doctor）"
)]
struct Cli {
    /// 运行模式：agent | exporter | device-plugin | doctor
    #[arg(long, value_enum, default_value_t = Mode::Agent)]
    mode: Mode,
    /// 节点名（运行时由 Downward API 注入）
    #[arg(long)]
    node_name: Option<String>,
}

fn main() -> anyhow::Result<()> {
    // 仅在交互终端输出 ANSI 色码：k8s 里 kubectl logs / 日志采集拿到的是纯文本，
    // 否则每条日志都夹带 \x1b[...m，grep/断言与结构化解析都会失配（真机首跑即踩到）。
    let color = std::io::stderr().is_terminal() && std::env::var_os("NO_COLOR").is_none();
    tracing_subscriber::fmt()
        .with_ansi(color)
        .with_env_filter(EnvFilter::from_default_env().add_directive(tracing::Level::INFO.into()))
        .init();

    let cli = Cli::parse();
    tracing::info!(
        version = env!("CARGO_PKG_VERSION"),
        commit = BUILD_COMMIT,
        mode = ?cli.mode,
        "hlvm-agent 启动"
    );
    match cli.mode {
        Mode::Agent => agent::run_agent(cli.node_name.as_deref()),
        Mode::Exporter => reporter::run_exporter(),
        Mode::DevicePlugin => plugin::run(),
        Mode::Doctor => doctor::run(),
    }
}
