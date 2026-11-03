package v1beta1

// Hub 把 StorageTask 标记为 conversion hub（v1beta1 是转换中枢）。
func (*StorageTask) Hub() {}

// Hub 把 StorageTaskList 标记为 conversion hub。
func (*StorageTaskList) Hub() {}
