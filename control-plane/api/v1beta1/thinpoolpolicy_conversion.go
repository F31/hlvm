package v1beta1

// Hub 把 ThinPoolPolicy 标记为 conversion hub（v1beta1 是转换中枢）。
func (*ThinPoolPolicy) Hub() {}

// Hub 把 ThinPoolPolicyList 标记为 conversion hub。
func (*ThinPoolPolicyList) Hub() {}
