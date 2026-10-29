# Tasks: add-admission-scheduling

> 进度说明（M9）：storage-webhook 控制逻辑收口并通过单测——纯函数 admission_logic.go（平台 SC 识别→tier、TierHasAvailableNode、BuildLockedNodeAffinity/MergeNodeAffinity、PodReferencedPlatformTiers、IsExpand、ReplicasDeclared、SanitizedDenyMessage、RetireInFlight、CountInUsePVs）；三类处理器 PVCValidator（tier 级准入 CREATE+扩容 UPDATE、脱敏拒绝+审计 Event、非平台直通）/ PodMutator（locked 节点 nodeAffinity 注入、保留既有约束）/ DeleteProtector（retire 在飞且有在用 PV 拒绝删 StorageNodeOps/NodeVG）；新 cmd/storage-webhook 注册；go build/vet/test 全绿 + fake-client 单测。
> 部署形态（1.1 Deployment×3/PDB/反亲和/超时）、VAP 静态规则清单（2.3）、matchConditions/FailurePolicy 配置（3.3 落到 YAML）、两项演练（4.2/4.3）移交 M9b（清单）与集成验证（需测试集群）。
> 进度说明（M9b）：部署与策略清单全部落地（control-plane/config/webhook/）——Deployment×3 + PDB(minAvailable=2) + podAntiAffinity + 超时 3s + resources（deployment.yaml/poddisruptionbudget.yaml/service.yaml）；Validating/MutatingWebhookConfiguration（manifests.yaml）含 matchConditions CEL（平台 SC 前缀 topolvm-<tier> + 操作/扩容/仅删）+ FailurePolicy 分级（容量类 Ignore / 删除保护 Fail）+ timeoutSeconds=3 + cert-manager 注入注解；证书自包含（certificate.yaml：selfSigned Issuer + Certificate）；VAP 静态规则（validatingadmissionpolicy.yaml：SC device-class/reclaimPolicy 强制 + replicas 仅提示 Ignore）；webhook RBAC（rbac.yaml：独立 SA + 最小权限 ClusterRole）。main.go 为四类 webhook 加 WithCustomPath 与清单 path 对齐。两项集群演练（4.2/4.3）需测试集群，移交集成验证。
> 进度说明（M14 收口）：VAP 清单在真实 K8s 1.36 集群验证暴露 1.34+ 兼容性缺陷（ValidatingAdmissionPolicyBinding 必须显式 validationActions），已修复（storageclass→Deny 配合 Fail；replicas→Warn 配合 Ignore）并加固表达式 has() 防御 null；4.2/4.3 静态规则层 + 非平台直通已在 kind 1.36 真实验收，动态 mutating 层仍待测试集群。

## 1. webhook 部署形态

- [x] 1.1 独立 Deployment ×3、active-active、PDB、反亲和、超时 ≤3s（M9b 清单交付）
- [x] 1.2 webhook 代码不含业务计算：仅读取 NodeVG/ThinPoolPolicy status 判定（M9 落地，PVCValidator/PodMutator/DeleteProtector 只读缓存）
- [x] 1.3 审计：每次拒绝写审计（对象 + 原因 Event，recorder.Event），对外拒绝信息脱敏（SanitizedDenyMessage 仅含 tier）；与 K8s audit log 交叉校验为基础设施项

## 2. 三层准入与调度

- [x] 2.1 PVC 准入（tier 级）：代码层按 provisioner=topolvm.io + device-class 识别本平台 SC（matchConditions CEL 落到 M9b YAML）；CREATE + 扩容 UPDATE；判定"tier 是否存在至少一个可用节点"（非具体 VG）
- [x] 2.2 节点级约束：Pod 变更注入 nodeAffinity 排除 locked 节点（消费 controller.LockLabelName，复用 capacity-ctrl 锁标签），保留既有亲和约束；已有 Pod 不受影响（M9 落地）
- [x] 2.3 静态规则 VAP：SC device-class/reclaimPolicy 强制（hlvm-storageclass-policy，Fail）+ replicas 声明标签仅格式校验（hlvm-pvc-replicas-policy，Ignore 只提示不强拦）（M9b 清单）
- [x] 2.4 删除保护：retire 中节点存在在用 PV 时，webhook 拒绝删除 StorageNodeOps/NodeVG（DeleteProtector，Fail 类）

## 3. FailurePolicy 分级

- [x] 3.1 安全类（删除保护）= Fail，作用域仅本平台对象（DeleteProtector；配置 FailurePolicy=Fail 落到 M9b YAML）
- [x] 3.2 容量类拦截 = Ignore；webhook 异常时按 Fail-safe 放行（PVCValidator/PodMutator 内部错误一律放行，不阻塞集群），由 capacity-ctrl 告警兜底
- [x] 3.3 配置核对：非本平台对象在代码层直通（PVCTier/StorageClassTier 判定）；matchConditions CEL 落到 M9b YAML 确保非本平台 PVC/Pod 完全不经过本平台 webhook

## 4. 测试

- [x] 4.1 单测（fake-client）：准入决策矩阵（tier 可用/全锁、扩容 UPDATE、非本平台 SC 直通、replicas 提示）、locked 亲和注入与保留、删除保护阻断；envtest 决策集成测试移交集成验证
- [x] 4.2 静态层真实验收（kind 1.36）：非本平台 PVC（默认 SC，非 topolvm- 前缀）在 webhook 未部署（模拟宕机）时仍可创建，证明非平台对象不经 webhook/策略、webhook 宕机不影响集群；另 hlvm-storageclass-policy(Fail) 验证非法 SC 被拒。动态层（webhook 副本真宕机 + 真实流量回归）仍待测试集群。
- [ ] 4.3 动态层：单节点 locked → 新 Pod 调度排除该节点、已有 Pod 不受影响（依赖 mutating webhook server 部署 + 真实节点 locked 标签 + cert-manager，control-plane 暂无 Dockerfile/证书机制，本机 kind 无法真实验收，待测试集群）

## 验证回路

- [x] V.1 go build / vet / test 全绿（两项演练需测试集群，移交集成验证）
- [x] V.2 commit + push（里程碑闭环）
