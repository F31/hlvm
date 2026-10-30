package v1beta1

// Hub 把 NodeDisk 标记为 conversion hub（v1beta1 是转换中枢）。
//
// 约定：整个 group 里只能有一个 hub 版本；v1alpha1 是 spoke，实现
// ConvertTo(hub) / ConvertFrom(hub)。conversion webhook 在
// spoke↔spoke 之间转换时会经 hub 中转（controller-runtime 的 convertViaHub）。
func (*NodeDisk) Hub() {}

// Hub 把 NodeDiskList 标记为 conversion hub。
//
// 列表也需要转换：apiserver 对 `GET /apis/storage.example.io/v1beta1/nodedisks`
// 会把整个 List 对象交给 webhook，而不是逐条对象。
func (*NodeDiskList) Hub() {}
