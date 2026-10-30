//! 磁盘发现模块（设计 §5.1）。
//!
//! 来源：`/sys/block`、`lsblk --json`、udev 事件（热插拔即时重扫）+ 周期扫描。
//! 本模块聚焦 `lsblk --json` 的解析（纯函数，可单测）；运行时枚举走 `enumerate_disks`。

use anyhow::Result;
use serde::Deserialize;
use std::process::Command;

#[derive(Debug, Clone, Deserialize, PartialEq, Eq, Default)]
pub struct LsblkDevice {
    pub name: String,
    #[serde(default)]
    pub serial: Option<String>,
    #[serde(default)]
    pub wwn: Option<String>,
    #[serde(default)]
    pub path: Option<String>,
    /// lsblk 在 `-b`（字节）模式下把 size 输出为 JSON **数字**，非 `-b` 时为字符串
    /// （如 "388.6M"）。统一归一化为字符串，下游按字节解析（见 agent/mod.rs）。
    #[serde(default, deserialize_with = "de_size")]
    pub size: Option<String>,
    #[serde(default)]
    pub mountpoint: Option<serde_json::Value>,
    /// lsblk 的 `TYPE` 列（disk/part/dm/mpath/md/loop）。占用判定需要它来区分
    /// device-mapper / multipath / md 子设备（此前未采集，导致 `holders` 恒为空）。
    #[serde(rename = "type", default)]
    pub dev_type: Option<String>,
    /// lsblk 的 `FSTYPE` 列（无签名时为 null）。比 blkid 更可靠：`lsblk` 总是成功退出，
    /// 而 `blkid` 在无签名时以非 0 退出，无法区分「干净盘」与「探测失败」。
    #[serde(default)]
    pub fstype: Option<String>,
    #[serde(default)]
    pub children: Vec<LsblkDevice>,
}

#[derive(Debug, Deserialize)]
struct LsblkOutput {
    blockdevices: Vec<LsblkDevice>,
}

/// 容忍 lsblk 的两种 size 表示：`-b` 输出数字字节数，默认输出人类可读字符串。
///
/// 实际故障（2026-10-30 kind 首跑）：`lsblk -J -b` 的 `"size": 407490560` 是数字，
/// 而模型声明为 `Option<String>`，整个 discovery 直接解析失败 →
/// `discovery 失败（非节点环境？）: invalid type: integer, expected a string`。
fn de_size<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de::Error as DeError;
    match Option::<serde_json::Value>::deserialize(deserializer)? {
        None | Some(serde_json::Value::Null) => Ok(None),
        Some(serde_json::Value::String(s)) => Ok(Some(s)),
        Some(serde_json::Value::Number(n)) => Ok(Some(n.to_string())),
        Some(other) => Err(DeError::custom(format!("size 字段类型不支持: {other}"))),
    }
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
        .args([
            "--json",
            "-b",
            "-o",
            "NAME,SERIAL,WWN,PATH,SIZE,TYPE,MOUNTPOINT",
        ])
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

    /// 回归：`lsblk -J -b` 的 size 是数字（真实节点输出），不能被当作类型错误。
    #[test]
    fn parses_numeric_size_from_bytes_mode() {
        let json = r#"{"blockdevices":[
            {"name":"sda","path":"/dev/sda","size":407490560,"type":"disk","mountpoint":null,
             "serial":null,"wwn":null,"children":[]}
        ]}"#;
        let devs = parse_lsblk(json).unwrap();
        assert_eq!(devs.len(), 1);
        assert_eq!(devs[0].size.as_deref(), Some("407490560"));
    }

    /// 非 -b 模式（人类可读字符串）仍需可用。
    #[test]
    fn parses_human_readable_size() {
        let json = r#"{"blockdevices":[
            {"name":"sda","path":"/dev/sda","size":"388.6M","type":"disk","mountpoint":null,
             "serial":null,"wwn":null,"children":[]}
        ]}"#;
        let devs = parse_lsblk(json).unwrap();
        assert_eq!(devs[0].size.as_deref(), Some("388.6M"));
    }

    /// size 缺失（或 null）不应导致整体解析失败。
    #[test]
    fn tolerates_missing_size() {
        let json = r#"{"blockdevices":[
            {"name":"sda","path":"/dev/sda","size":null,"type":"disk","mountpoint":null,"children":[]}
        ]}"#;
        let devs = parse_lsblk(json).unwrap();
        assert_eq!(devs[0].size, None);
    }

    /// 回归：TYPE/FSTYPE 必须被采集（占用判定依赖它们），此前模型缺这两个字段，
    /// 导致 `OccupiedBy` 恒为 none、dm/mpath/md 持有者永远检测不到。
    #[test]
    fn parses_type_and_fstype() {
        let json = r#"{"blockdevices":[
            {"name":"sdb","path":"/dev/sdb","size":1000,"type":"disk","mountpoint":null,
             "fstype":"LVM2_member","children":[
                {"name":"dm-0","path":"/dev/dm-0","type":"dm","fstype":"xfs","children":[]}]}
        ]}"#;
        let devs = parse_lsblk(json).unwrap();
        assert_eq!(devs[0].dev_type.as_deref(), Some("disk"));
        assert_eq!(devs[0].fstype.as_deref(), Some("LVM2_member"));
        assert_eq!(devs[1].dev_type.as_deref(), Some("dm"));
        assert_eq!(devs[1].fstype.as_deref(), Some("xfs"));
    }
}
