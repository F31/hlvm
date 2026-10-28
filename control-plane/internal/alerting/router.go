package alerting

import (
	"context"
	"fmt"
)

// Sender 是一个告警渠道发送器（webhook/mail/sms/ticket）。
type Sender interface {
	Send(ctx context.Context, alert AlertEvent) error
}

// AlertRouter 将告警事件按级别/显式渠道分发到对应 Sender（设计 §3.3 alertChannels: [webhook, mail, sms]）。
type AlertRouter struct {
	// Channels 是渠道名到发送器的注册表。
	Channels map[string]Sender
	// DefaultChannels 按级别返回默认渠道；告警未显式指定 Channels 时使用。
	DefaultChannels func(level Level) []string
}

// DefaultChannelForLevel 返回按级别的默认渠道（设计 §3.3）。
// Critical 走全部渠道（webhook/mail/sms）以最快触达；Warning 仅 webhook 轻量通知。
func DefaultChannelForLevel(level Level) []string {
	switch level {
	case LevelCritical:
		return []string{"webhook", "mail", "sms"}
	case LevelWarning:
		return []string{"webhook"}
	default:
		return []string{"webhook"}
	}
}

// Route 分发一条告警到目标渠道；任一渠道失败不影响其它渠道，返回首个错误。
// 目标渠道取 alert.Channels（显式覆盖，如转人工工单 "ticket"），否则取 DefaultChannels。
func (r *AlertRouter) Route(ctx context.Context, alert AlertEvent) error {
	chans := alert.Channels
	if len(chans) == 0 && r.DefaultChannels != nil {
		chans = r.DefaultChannels(alert.Level)
	}
	var firstErr error
	for _, name := range chans {
		s := r.Channels[name]
		if s == nil {
			continue // 未配置的渠道静默跳过，不阻断其它渠道。
		}
		if err := s.Send(ctx, alert); err != nil && firstErr == nil {
			firstErr = fmt.Errorf("渠道 %s 发送失败: %w", name, err)
		}
	}
	return firstErr
}
