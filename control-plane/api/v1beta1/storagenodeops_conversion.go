package v1beta1

// Hub 把 StorageNodeOps 标记为 conversion hub（v1beta1 是转换中枢）。
func (*StorageNodeOps) Hub() {}

// Hub 把 StorageNodeOpsList 标记为 conversion hub。
func (*StorageNodeOpsList) Hub() {}
