//! 指标采集与上报（设计 §5.4）。
//!
//! exporter 以独立非特权 DaemonSet 运行，只读采集。指标按 §5.4 定义；
//! CRD status 仅在 health/phase 变化或每 10 分钟低频刷新（§3.1）。

use crate::common::Health;

/// 渲染 Prometheus 文本格式指标（single metric）。
pub fn render_metric(name: &str, value: f64, labels: &[(&str, &str)]) -> String {
    let label_str = if labels.is_empty() {
        String::new()
    } else {
        let inner = labels
            .iter()
            .map(|(k, v)| format!("{k}=\"{v}\""))
            .collect::<Vec<_>>()
            .join(",");
        format!("{{{inner}}}")
    };
    format!("# TYPE {name} gauge\n{name}{label_str} {value}\n")
}

/// 渲染 `storage_disk_smart_health{node,device,media}`（§5.4）。
pub fn render_smart_health(node: &str, device: &str, media: &str, health: Health) -> String {
    render_metric(
        "storage_disk_smart_health",
        f64::from(health.metric_value()),
        &[("node", node), ("device", device), ("media", media)],
    )
}

/// exporter 模式入口（只读采集，独立 DaemonSet）。
pub fn run_exporter() -> anyhow::Result<()> {
    tracing::info!("exporter 模式：采集并暴露指标（占位）");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_gauge_with_labels() {
        let m = render_metric("storage_vg_free_bytes", 123.0, &[("node", "n1"), ("vg", "vg1")]);
        assert!(m.contains("storage_vg_free_bytes{node=\"n1\",vg=\"vg1\"} 123"));
    }

    #[test]
    fn renders_smart_health() {
        let m = render_smart_health("n1", "nvme-x", "nvme", Health::Critical);
        assert!(m.contains("storage_disk_smart_health{node=\"n1\",device=\"nvme-x\",media=\"nvme\"} 2"));
    }
}
