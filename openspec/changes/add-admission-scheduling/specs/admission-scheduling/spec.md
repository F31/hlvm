# admission-scheduling 规格 Delta

## ADDED Requirements

### Requirement: webhook 作用域收窄
storage-webhook SHALL 仅对使用本平台 StorageClass 的 PVC（经 `matchConditions` CEL 过滤）及引用本平台 PVC 的 Pod 生效；SHALL NOT 作用于任何其他对象。

#### Scenario: 非本平台 PVC 直通
- **WHEN** 用户创建使用第三方 SC 的 PVC
- **THEN** 请求不经过本平台 webhook，webhook 故障也不影响其创建

### Requirement: tier 级准入判定
PVC 准入 SHALL 覆盖 CREATE 与扩容 UPDATE，判定"该 tier 是否存在至少一个可用节点"，而非某个具体 VG；拒绝信息 SHALL 面向租户，不暴露节点名/VG 名等内部细节。

#### Scenario: tier 全节点锁定
- **WHEN** 某 tier 的全部节点 locked，租户创建该 SC 的 PVC
- **THEN** 拒绝并提示容量受限，详细原因只进审计与告警

### Requirement: FailurePolicy 分级
webhook SHALL 按 Fail-safe 原则分级：安全类（删除保护）FailurePolicy=Fail 且仅作用于本平台对象；容量类拦截 FailurePolicy=Ignore，并由 capacity-ctrl 在 webhook 异常时告警兜底。

#### Scenario: webhook 全宕机
- **WHEN** 全部 webhook 副本不可用
- **THEN** 非本平台 PVC 创建不受阻塞；容量拦截缺失触发告警

### Requirement: 节点级调度约束
capacity-ctrl 置 locked 的节点 SHALL 被调度层排除：Pod 变更 webhook（或 Scheduling Gate）为引用本平台 PVC 的新 Pod 注入 nodeAffinity 排除 locked 节点。

#### Scenario: locked 节点不收新 Pod
- **WHEN** 新 Pod 引用 locked 节点所在 tier 的 PVC
- **THEN** 调度时排除 locked 节点，已有 Pod 与卷不受影响

### Requirement: 静态规则用 VAP
StorageClass 白名单、reclaimPolicy、`storage.example.io/replicas` 声明标签等静态规则 SHALL 用 ValidatingAdmissionPolicy 实现，不引入自研 webhook 延迟。

#### Scenario: 单副本声明缺失提示
- **WHEN** 单副本业务创建本平台 PVC 且未带 replicas 声明标签
- **THEN** 默认只提示不强拦（避免误杀 StatefulSet）

### Requirement: 删除保护
节点处于 retire 流程且存在在用 PV 时，webhook SHALL 拒绝删除该节点相关存储对象（含 finalizer 保护）。

#### Scenario: retire 中拒绝删对象
- **WHEN** StorageNodeOps(retire) 处于 wait-pvc-cleanup 且节点仍有在用 PV
- **THEN** 删除相关存储对象的请求被拒绝
