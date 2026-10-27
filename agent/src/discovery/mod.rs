//! 磁盘发现模块（设计 §5.1）。
//!
//! 来源：`/sys/block`、`lsblk --json`、udev 事件（热插拔即时重扫）+ 周期扫描。
//! 本模块聚焦 `lsblk --json` 的解析（纯函数，可单测）；运行时枚举走 `enumerate_disks`。

use anyhow::Result;
use serde::Deserialize;
use std::process::Command;

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct LsblkDevice {
    pub name: String,
    #[serde(default)]
    pub serial: Option<String>,
    #[serde(default)]
    pub wwn: Option<String>,
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub size: Option<String>,
    #[serde(default)]
    pub mountpoint: Option<serde_json::Value>,
    #[serde(default)]
    pub children: Vec<LsblkDevice>,
}

#[derive(Debug, Deserialize)]
struct LsblkOutput {
    blockdevices: Vec<LsblkDevice>,
}

/// 解析 `lsblk --json` 输出并展开 children（§5.1）。返回扁平化设备列表。
pub fn parse_lsblk(json: &str) -> Result<Vec<LsblkDevice>> {
    let out: LsblkOutput = serde_json::from_str(json)?;
    Ok(flatten(&out.blockdevices))
}

fn flatten(devs: &[LsblkDevice]) -> Vec<LsblkDevice> {
    let mut out = Vec::new();
    for d in devs {
        out.push(d.clone());
        out.extend(flatten(&d.children));
    }
    out
}

/// 运行时枚举：调用宿主机 `lsblk --json`（Agent 以特权运行，见 §2 部署形态）。
pub fn enumerate_disks() -> Result<Vec<LsblkDevice>> {
    let out = Command::new("lsblk")
        .args(["--json", "-b", "-o", "NAME,SERIAL,WWN,PATH,SIZE,TYPE,MOUNTPOINT"])
        .output()?;
    if !out.status.success() {
        anyhow::bail!("lsblk 执行失败: {}", String::from_utf8_lossy(&out.stderr));
    }
    parse_lsblk(&String::from_utf8_lossy(&out.stdout))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"{
      "blockdevices": [
        {"name":"nvme0n1","serial":"S5YJNX0R123456","wwn":"eui.xxxx","path":"/dev/nvme0n1","size":"1920383410176","type":"disk","mountpoint":null,"children":[
          {"name":"nvme0n1p1","path":"/dev/nvme0n1p1","size":"536870912","type":"part","mountpoint":"/boot"}
        ]},
        {"name":"sda","serial":"ABCD","path":"/dev/sda","size":"1000204886016","type":"disk","mountpoint":null,"children":[]}
      ]
    }"#;

    #[test]
    fn parses_and_flattens() {
        let devs = parse_lsblk(SAMPLE).unwrap();
        // 2 块盘 + 1 个分区（需排除分区？此处保留全部，调用方按 type 过滤）
        assert_eq!(devs.len(), 3);
        assert_eq!(devs[0].serial.as_deref(), Some("S5YJNX0R123456"));
        assert_eq!(devs[0].children.len(), 1);
    }
}
