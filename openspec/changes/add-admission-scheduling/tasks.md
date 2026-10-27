# Tasks: add-admission-scheduling

## 1. webhook 部署形态

- [ ] 1.1 独立 Deployment ×3、active-active、PDB、反亲和、超时 ≤3s
- [ ] 1.2 webhook 代码不含业务计算：仅读取 NodeVG/ThinPoolPolicy status 判定
- [ ] 1.3 审计：每次拒绝写审计（操作人、对象、原因），对外拒绝信息脱敏

## 2. 三层准入与调度

- [ ] 2.1 PVC 准入（tier 级）：matchConditions CEL 过滤本平台 SC；CREATE + 扩容 UPDATE；判定"tier 是否存在至少一个可用节点"
- [ ] 2.2 节点级约束：locked 节点排除（nodeAffinity 注入或 Scheduling Gate，按 POC 结论二选一），消费 `storage.example.io/<tier>-locked` 标签
- [ ] 2.3 静态规则 VAP：SC 白名单、reclaimPolicy 校验、replicas 声明标签（默认只提示不强拦）
- [ ] 2.4 删除保护：retire 中节点存在在用 PV 时，webhook 拒绝删除节点相关存储对象（finalizer）

## 3. FailurePolicy 分级

- [ ] 3.1 安全类（删除保护）= Fail，作用域仅本平台对象
- [ ] 3.2 容量类拦截 = Ignore；webhook 异常时 capacity-ctrl 告警兜底
- [ ] 3.3 配置核对：确认非本平台 PVC/Pod 完全不经过本平台 webhook

## 4. 测试

- [ ] 4.1 单测 + envtest：准入决策矩阵（tier 可用/全锁、扩容 UPDATE、非本平台 SC 直通）
- [ ] 4.2 演练：全部 webhook 副本宕机 → 非本平台 PVC 创建不受阻（对照 POC 预演结论）
- [ ] 4.3 演练：单节点 locked → 新 Pod 调度排除该节点、已有 Pod 不受影响

## 验证回路

- [ ] V.1 go build / vet / test 全绿；两项演练通过
- [ ] V.2 commit + push（里程碑闭环）
