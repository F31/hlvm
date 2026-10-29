# ADR-005：lvmd ConfigMap 的聚合语义（一节点一份，聚合该节点所有 NodeVG）

- **状态**：已接受（2026-10-29，M15 集成验证中发现并决策）
- **日期**：2026-10-29
- **决策人**：平台团队
- **触发**：M15 kind 实测发现 `hlmd-lvmd-<node>` 由单个 NodeVG 渲染，同节点多 VG 时互相覆盖；
  ConfigMap 无 `ownerReference` 导致 `.Owns()` 不触发、篡改不自愈、NodeVG 删除后残留。

## 背景

`capacity-governance` spec 要求「lvmd-config-ctrl SHALL 由 NodeVG CRD 渲染各节点 lvmd ConfigMap」。
当前实现存在三处偏差：

1. **粒度错位**：ConfigMap 以**节点**为唯一键（`hlmd-lvmd-<node>`），但渲染输入是**单个** NodeVG。
   `per-disk` 布局（一盘一 VG）下同节点存在多个 NodeVG，后 reconcile 者覆盖前者内容。
2. **device-class 命名冲突**：`device-class.name` 取 `spec.tier`，同节点同 tier 的多个 VG 会生成重复 name。
3. **触发与生命周期缺失**：创建 ConfigMap 未设置 `ownerReference`，`.Owns(&ConfigMap{})` 永不触发；
   Reconcile 无 requeue，人工篡改不自愈；NodeVG 删除后 ConfigMap 残留（kind 实测复现）。

## 业界参考

| 实现 | 模型 | 对本决策的意义 |
| --- | --- | --- |
| **TopoLVM** | `lvmd.yaml` 为**节点本地**文件（`/etc/topolvm/lvmd.yaml`，systemd 服务），每节点一份；`device-classes` 是**数组**，一个节点可配置多个 device-class 分别映射多个 VG（如 `ssd-vg` / `hdd-vg` / `thin-vg`） | 配置粒度天然是「节点 = 该节点全部 VG 的映射集合」→ **聚合是上游原生形态**，不存在「一 VG 一份配置」 |
| **TopoLVM Helm / Talos 部署** | chart 的 `lvmd.deviceClasses` 为**全局单份**列表，所有节点共用 | 更简单，但隐含「各节点 VG 布局一致」，不适配异构节点；本文不采用 |
| **OpenEBS LVM LocalPV** | 每节点一个 `LVMNode` CR（node controller 周期扫描本地 VG 写入），`LVMVolume` 带 `volGroup`；节点插件直读 CRD/本地 LVM，**无配置文件投影层** | 证明「ConfigMap 投影」是可选的；保留它仅为对齐 TopoLVM 的静态文件消费方式（未来 lvmd 进程） |
| **OpenShift MCO** | 多个 `MachineConfig` 按节点池聚合渲染为**每节点一份**文件，以内容 hash 做幂等/漂移检测 | 印证「多 CR → 一节点一份产物」是成熟范式，前提是渲染**确定性**（稳定排序）以便逐字节比对 |

## 决策

1. **真相源为 NodeVG，产物为每节点一份 ConfigMap**：`hlmd-lvmd-<node>` 的内容由该节点**全部** NodeVG
   聚合而成，`device-classes` 为数组，按 device-class 名**稳定升序**排列，保证确定性渲染与逐字节漂移比对。
2. **新增 `spec.deviceClassName`**（可选）：显式指定 device-class 名；缺省回退 `spec.tier`，再回退 `default`。
   解决 `per-disk` 下同 tier 多 VG 的重名问题。
3. **只渲染 `status.vgExists=true` 的 NodeVG**。理由：device-class 指向尚不存在的 VG 会使 lvmd 无法服务该 class；
   而 `vgExists` 由 false→true 会触发 NodeVG 事件并重渲染，窗口期可自愈。若聚合结果为空，输出
   `device-classes: []`。
4. **重名视为错误**：聚合时若两个 VG 解析出相同 device-class 名，返回 error，控制器记录并重试，
   **不写入非法配置**（优于静默生成 lvmd 会拒绝的文件）。
5. **触发与生命周期用 ownerReference 表达**：
   - 为 ConfigMap 设置该节点**每个** NodeVG 的 `ownerReference`（`controller: false`）；
   - 控制器用 `Owns(&corev1.ConfigMap{}, builder.MatchEveryOwner)` 注册 watch。
     注意 controller-runtime v0.20.4 的 `Owns()` **默认 `OnlyControllerOwner()`**，不显式传
     `MatchEveryOwner` 则多 owner 不会触发。
   - K8s GC 语义为「所有 owner 均删除后才删除 dependent」，因此删除最后一个 NodeVG 时 ConfigMap 被回收，
     天然解决孤儿，无需 finalizer。
   - 跨作用域合法性：cluster-scoped 的 NodeVG 可以作为 namespaced（`hlvm-system`）ConfigMap 的 owner。

## 备选方案（未采纳）

- **每 VG 一份 ConfigMap**（`hlmd-lvmd-<node>-<vg>`）：与「一节点一个 lvmd 配置文件」的消费方式冲突，
  且与 TopoLVM 格式不兼容。
- **不做 ConfigMap 投影，agent 直读 CRD**（OpenEBS 路线）：架构上更简洁，但会放弃与 TopoLVM lvmd
  静态文件的兼容性，属更大范围的设计变更，留待后续评估。
- **controller ownerReference 指向「首个 VG」**：归属不稳定（VG 增删会改变 controller owner），
  且 `Owns()` 默认只认 controller owner，无法覆盖多 VG。

## 影响与风险

- `capacity-governance` 的「变更灰度 + 滚动重载」语义不变：ConfigMap 内容变化仍是灰度下发的载体。
- **待真实验证（真实 LV / lvmd 环境）**：
  1. lvmd 是否接受 `device-classes: []`（节点尚无 VG 时）；
  2. lvmd 对「配置中缺失某 class」的热加载行为（过滤 `vgExists=false` 的直接影响）。
     若 lvmd 要求至少一个 class，需回退为「不过滤 + 依赖 vgcreate 先于 lvmd 启动」。
- 同节点 device-class 名唯一性目前靠运行时检测（返回 error）；后续可评估用 VAP 做跨对象校验。
- 该决策不改变 `agent` 行为：agent 当前不消费此 ConfigMap（仅 executor/lvm 使用 lvm 命令）。
