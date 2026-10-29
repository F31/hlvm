//! StorageTask 执行窗口（`spec.ttl`）的 **agent 侧复核**（ADR-006 补遗）。
//!
//! 控制面 `StorageTaskReconciler` 已在任务开始前拦截过期任务；本模块是第二道闸：
//! agent 采用轮询 list，若在控制面标记 `Failed` 的同一瞬间已取走任务，仍可能执行一次过期任务。
//! 执行前复核 `creationTimestamp + ttl` 可关闭该竞态窗口（窗口 ≈ 一轮轮询间隔）。
//!
//! 语义与控制面**逐条对齐**（避免两侧判定分叉）：
//! - `spec.ttl` 为空：不限制执行窗口；
//! - 语法沿用 Go `time.ParseDuration`（`300ms` / `1.5h` / `2h45m` / `0`）；
//! - 非法或 `<= 0`：**失败关闭**（视为已过期，拒绝执行破坏性任务）；
//! - 只有**尚未开始**（phase 为空或 `Pending`）的任务才由 TTL 拦截，`Running`/`Unknown` 不覆盖。

use std::time::Duration;

/// `spec.ttl` 的评估结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskWindow {
    /// 未声明 TTL，不限制执行窗口。
    NoTtl,
    /// 仍在窗口内，附剩余时间。
    Open { remaining: Duration },
    /// 已超出窗口（或 TTL 非法），携带应写入 status 的原因（含 `DeadlineExceeded: ` 前缀）。
    Expired(String),
}

/// 原因前缀，与控制面 `TaskExpiredMessagePrefix` 保持一致。
pub const DEADLINE_EXCEEDED_PREFIX: &str = "DeadlineExceeded: ";

/// 解析 Go `time.ParseDuration` 语法（支持 `ns`/`us`/`µs`/`μs`/`ms`/`s`/`m`/`h` 与组合、小数）。
///
/// 仅接受**正**时长：TTL 为负没有意义，按非法处理（失败关闭由调用方执行）。
pub fn parse_go_duration(raw: &str) -> Result<Duration, String> {
    if raw.is_empty() {
        return Err("空字符串".into());
    }
    // Go 的零值特例：单独的 "0" 合法（其余形如 "5" 缺单位必须报错）。
    if raw == "0" {
        return Ok(Duration::ZERO);
    }
    let (negative, body) = match raw.as_bytes()[0] {
        b'+' => (false, &raw[1..]),
        b'-' => (true, &raw[1..]),
        _ => (false, raw),
    };
    if body.is_empty() {
        return Err("缺少数值".into());
    }

    let bytes = body.as_bytes();
    let mut idx = 0usize;
    let mut total_secs = 0f64;
    let mut segments = 0usize;
    while idx < bytes.len() {
        let start = idx;
        while idx < bytes.len() && bytes[idx].is_ascii_digit() {
            idx += 1;
        }
        if idx < bytes.len() && bytes[idx] == b'.' {
            idx += 1;
            let frac_start = idx;
            while idx < bytes.len() && bytes[idx].is_ascii_digit() {
                idx += 1;
            }
            if idx == frac_start {
                return Err(format!("位置 {start} 处小数点后缺少数字"));
            }
        }
        if idx == start {
            return Err(format!("位置 {start} 处缺少数字"));
        }
        let number: f64 = body[start..idx]
            .parse()
            .map_err(|_| format!("无法解析数值 {:?}", &body[start..idx]))?;
        let rest = &body[idx..];
        let (unit_secs, unit_len) =
            pick_unit(rest).ok_or_else(|| format!("缺少或未知时间单位: {rest:?}"))?;
        total_secs += number * unit_secs;
        idx += unit_len;
        segments += 1;
    }
    if segments == 0 {
        return Err("缺少数值".into());
    }
    if negative {
        return Err("TTL 必须为正时长".into());
    }
    if !total_secs.is_finite() {
        return Err("时长溢出".into());
    }
    // 0 交给调用方按「非法 TTL」处理（失败关闭），此处不做判断。
    Duration::try_from_secs_f64(total_secs).map_err(|e| format!("时长无法表示: {e}"))
}

/// 匹配单位（先长后短，避免 "ms" 被 "m" 抢先）。
fn pick_unit(rest: &str) -> Option<(f64, usize)> {
    const UNITS: &[(&str, f64)] = &[
        ("ns", 1e-9),
        ("us", 1e-6),
        ("µs", 1e-6),
        ("μs", 1e-6),
        ("ms", 1e-3),
        ("s", 1.0),
        ("m", 60.0),
        ("h", 3600.0),
    ];
    UNITS
        .iter()
        .find(|(u, _)| rest.starts_with(u))
        .map(|(u, secs)| (*secs, u.len()))
}

/// 评估执行窗口。时间以 **Unix 毫秒**传入，便于测试与避免亚秒精度丢失。
pub fn evaluate_task_window(ttl: &str, created_unix_ms: i64, now_unix_ms: i64) -> TaskWindow {
    let raw = ttl.trim();
    if raw.is_empty() {
        return TaskWindow::NoTtl;
    }
    let window = match parse_go_duration(raw) {
        Err(e) => {
            return TaskWindow::Expired(format!(
                "{DEADLINE_EXCEEDED_PREFIX}spec.ttl {raw:?} 非法（{e}）；按失败关闭策略拒绝执行"
            ))
        }
        Ok(d) => d,
    };
    if window.is_zero() {
        return TaskWindow::Expired(format!(
            "{DEADLINE_EXCEEDED_PREFIX}spec.ttl {raw:?} 必须为正时长；按失败关闭策略拒绝执行"
        ));
    }
    let deadline_ms = created_unix_ms.saturating_add(window.as_millis() as i64);
    if now_unix_ms >= deadline_ms {
        return TaskWindow::Expired(format!(
            "{DEADLINE_EXCEEDED_PREFIX}任务超出 spec.ttl（{raw:?}）执行窗口，未执行"
        ));
    }
    TaskWindow::Open {
        remaining: Duration::from_millis((deadline_ms - now_unix_ms) as u64),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_go_style_durations() {
        assert_eq!(parse_go_duration("2s").unwrap(), Duration::from_secs(2));
        assert_eq!(
            parse_go_duration("300ms").unwrap(),
            Duration::from_millis(300)
        );
        assert_eq!(
            parse_go_duration("1h30m").unwrap(),
            Duration::from_secs(5400)
        );
        assert_eq!(
            parse_go_duration("1.5h").unwrap(),
            Duration::from_secs(5400)
        );
        assert_eq!(parse_go_duration("0").unwrap(), Duration::ZERO);
        assert_eq!(parse_go_duration("+10s").unwrap(), Duration::from_secs(10));
    }

    #[test]
    fn rejects_invalid_durations() {
        for bad in ["", "nonsense", "5", "1x", "-5s", "s", "1.5", "1..5s"] {
            assert!(parse_go_duration(bad).is_err(), "{bad:?} 应被判为非法时长");
        }
    }

    #[test]
    fn no_ttl_means_unbounded() {
        assert_eq!(evaluate_task_window("", 0, i64::MAX), TaskWindow::NoTtl);
    }

    #[test]
    fn expired_after_window() {
        // 创建于 t=0，ttl=2s，now=3000ms → 已过期。
        match evaluate_task_window("2s", 0, 3_000) {
            TaskWindow::Expired(reason) => {
                assert!(reason.starts_with(DEADLINE_EXCEEDED_PREFIX), "{reason}");
                assert!(reason.contains("未执行"), "{reason}");
            }
            other => panic!("应判为过期，实际 {other:?}"),
        }
    }

    #[test]
    fn open_within_window() {
        // 创建于 t=0，ttl=1h，now=10s → 剩余 3590s。
        match evaluate_task_window("1h", 0, 10_000) {
            TaskWindow::Open { remaining } => assert_eq!(remaining, Duration::from_secs(3590)),
            other => panic!("应仍在窗口内，实际 {other:?}"),
        }
        // 边界：恰好到截止时刻即过期（与控制面 `!now.Before(deadline)` 一致）。
        assert!(matches!(
            evaluate_task_window("2s", 0, 2_000),
            TaskWindow::Expired(_)
        ));
    }

    #[test]
    fn invalid_or_zero_ttl_fails_closed() {
        for bad in ["nonsense", "0", "-1s", "0s"] {
            match evaluate_task_window(bad, 0, 0) {
                TaskWindow::Expired(reason) => {
                    assert!(reason.starts_with(DEADLINE_EXCEEDED_PREFIX), "{reason}");
                }
                other => panic!("{bad:?} 应失败关闭，实际 {other:?}"),
            }
        }
    }
}
