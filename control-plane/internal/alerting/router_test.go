package alerting

import (
	"context"
	"testing"
)

// fakeSender 记录被调用的告警，用于验证路由分发。
type fakeSender struct {
	name string
	got  []AlertEvent
}

func (f *fakeSender) Send(_ context.Context, a AlertEvent) error {
	f.got = append(f.got, a)
	return nil
}

func TestRouteByLevel(t *testing.T) {
	wh := &fakeSender{name: "webhook"}
	mail := &fakeSender{name: "mail"}
	sms := &fakeSender{name: "sms"}
	ticket := &fakeSender{name: "ticket"}

	r := &AlertRouter{
		Channels: map[string]Sender{
			"webhook": wh, "mail": mail, "sms": sms, "ticket": ticket,
		},
		DefaultChannels: DefaultChannelForLevel,
	}

	// Critical → webhook + mail + sms（设计 §3.3 全渠道触达）。
	crit := AlertEvent{Name: "X", Level: LevelCritical}
	if err := r.Route(context.Background(), crit); err != nil {
		t.Fatal(err)
	}
	if len(wh.got) != 1 || len(mail.got) != 1 || len(sms.got) != 1 {
		t.Fatalf("Critical 应分发到 webhook/mail/sms，got wh=%d mail=%d sms=%d", len(wh.got), len(mail.got), len(sms.got))
	}

	// Warning → 仅 webhook（轻量通知）。
	warn := AlertEvent{Name: "Y", Level: LevelWarning}
	if err := r.Route(context.Background(), warn); err != nil {
		t.Fatal(err)
	}
	if len(wh.got) != 2 || len(mail.got) != 1 {
		t.Fatalf("Warning 应仅追加到 webhook，got wh=%d mail=%d", len(wh.got), len(mail.got))
	}
}

func TestRouteExplicitChannels(t *testing.T) {
	ticket := &fakeSender{name: "ticket"}
	wh := &fakeSender{name: "webhook"}
	r := &AlertRouter{
		Channels:        map[string]Sender{"ticket": ticket, "webhook": wh},
		DefaultChannels: DefaultChannelForLevel,
	}
	// 显式渠道覆盖：转人工工单（VG 空闲不足）只走 ticket。
	a := AlertEvent{Name: "VGFreeInsufficient", Level: LevelCritical, Channels: []string{"ticket"}}
	if err := r.Route(context.Background(), a); err != nil {
		t.Fatal(err)
	}
	if len(ticket.got) != 1 || len(wh.got) != 0 {
		t.Fatalf("显式渠道应只分发到 ticket，got ticket=%d webhook=%d", len(ticket.got), len(wh.got))
	}
}

func TestRouteUnknownChannelSkipped(t *testing.T) {
	wh := &fakeSender{name: "webhook"}
	r := &AlertRouter{
		Channels:        map[string]Sender{"webhook": wh},
		DefaultChannels: DefaultChannelForLevel,
	}
	// 默认渠道含 mail/sms，但未注册对应 sender，应静默跳过不报错。
	if err := r.Route(context.Background(), AlertEvent{Name: "Z", Level: LevelCritical}); err != nil {
		t.Fatalf("未注册渠道应静默跳过，不应报错：%v", err)
	}
	if len(wh.got) != 1 {
		t.Fatalf("已注册 webhook 应收到 Critical，got %d", len(wh.got))
	}
}
