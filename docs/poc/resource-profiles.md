# Agent 资源定稿模板（设计 §6.3 / M14c 6.3.1）

> 状态：**占位值，待 POC 实测回填**。本文件是资源定稿的方法论模板，正式值须经下方观测流程后写入 `agent/config/daemonset-agent.yaml` 的 `resources` 段。

## 1. 两个工作负载角色

| 工作负载 | 角色 | 性质 | 当前占位 requests / limits |
|----------|------|------|---------------------------|
| `hlvm-storage-agent`（`--mode=agent`） | 唯一 PV/VG/pool **写路径** | 特权收敛（SYS_ADMIN/DAC_OVERRIDE/SYS_RAWIO），宿主机 lvm 共享锁 | cpu 100m/500m，mem 128Mi/256Mi |
| `hlvm-storage-exporter`（`--mode=exporter`） | 只读指标采集 | 非特权，`:9105/metrics` | cpu 50m/200m，mem 64Mi/128Mi |

> 占位值已在 `daemonset-agent.yaml` 落地，保证可调度（避免 LimitRange 拒绝）；**不等于真实基线**，必须回填。

## 2. 实测回填流程

1. **常驻基线**：POC 集群稳定运行 24h，用 Prometheus/ `kubectl top pod` 采集两容器的：
   - CPU：P50 / P95 / 峰值（LVM 批量操作、StorageTask 并发回写时的突发）。
   - 内存：常驻 RSS 上限（`process_resident_memory_bytes`）。
2. **突发场景**：在 `fault-injection.sh` / `concurrency-lvmd-test.sh` 压测下记录峰值。
3. **定稿规则**：
   - `requests` 取 P50 + 余量（保证调度合理，不超额预留）。
   - `limits` 取实测峰值 ×1.3（留出 LVM 操作突发，避免 OOMKill 中断写路径）。
   - 内存 limit 宁紧勿松（RSS 异常增长应触发 OOM 而非拖垮节点）。
4. **回填**：将实测值替换 `daemonset-agent.yaml` 的占位段，更新本表「当前占位」列为「实测值」并提交。

## 3. 实测记录表（POC 填写）

| 指标 | agent 实测 | exporter 实测 | 采集时间 |
|------|-----------|--------------|----------|
| CPU P50 | — | — | — |
| CPU P95 | — | — | — |
| CPU 峰值 | — | — | — |
| 内存常驻上限 | — | — | — |

## 4. 约束

- agent 为数据面唯一写路径，**limit 过紧会导致 LVM 操作超时/重试风暴**，须以压测峰值为准。
- exporter 只读、长期常驻，**limit 宜小**，避免占用节点可观内存。
- 任何资源变更须配合 `control-plane/config/hardening` 的 PSA/配额约束回归。
