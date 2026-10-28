//! hlvm 节点 Agent 入口（设计 §5）。
//!
//! 单一二进制，按 `--mode` 切换：
//! - `agent`：磁盘发现、SMART、预检、StorageTask 执行（唯一 PV/VG/pool 写路径）。
//! - `exporter`：只读指标采集（独立非特权 DaemonSet）。
//! - `doctor`：节点诊断打包。

mod agent;
mod common;
mod discovery;
mod doctor;
mod executor;
mod lvm;
mod precheck;
mod reporter;
mod smart;

use clap::{Parser, ValueEnum};
use tracing_subscriber::EnvFilter;

#[derive(Copy, Clone, PartialEq, Eq, ValueEnum)]
enum Mode {
    Agent,
    Exporter,
    Doctor,
}

#[derive(Parser)]
#[command(
    name = "hlvm-agent",
    version,
    about = "hlvm 节点 Agent（discovery/smart/precheck/executor/lvm/reporter/doctor）"
)]
struct Cli {
    /// 运行模式：agent | exporter | doctor
    #[arg(long, value_enum, default_value_t = Mode::Agent)]
    mode: Mode,
    /// 节点名（运行时由 Downward API 注入）
    #[arg(long)]
    node_name: Option<String>,
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive(tracing::Level::INFO.into()))
        .init();

    let cli = Cli::parse();
    match cli.mode {
        Mode::Agent => agent::run_agent(cli.node_name.as_deref()),
        Mode::Exporter => reporter::run_exporter(),
        Mode::Doctor => doctor::run(),
    }
}
