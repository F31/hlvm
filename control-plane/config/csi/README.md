# B 链路：TopoLVM CSI 供给（PVC → LV）

本目录是 B 链路（按 VG 容量动态供给 PVC）的部署清单。A 链路（`hlvm.io/disk` 整盘直通）
与本链路并存、互不替代：A 给裸设备，B 给 PVC。

## 组成

| 文件 | 内容 |
| --- | --- |
| `00-crd-logicalvolume.yaml` | `logicalvolumes.topolvm.io` CRD。`topolvm-node` 内置的 LogicalVolumeReconciler 依赖它，缺了会起不来 |
| `10-rbac-controller.yaml` | controller 的 SA / ClusterRole / Role / 绑定 |
| `11-rbac-node.yaml` | node 的 SA / ClusterRole / 绑定（含 `nodes` patch 权限：拓扑标签与容量注解由 node 自己写） |
| `20-csidriver.yaml` | `CSIDriver topolvm.io`，`attachRequired: false`、`storageCapacity: true` |
| `30-controller.yaml` | `topolvm-controller` Deployment + Service（含 csi-provisioner / csi-resizer / livenessprobe sidecar） |
| `40-node.yaml` | `topolvm-node` DaemonSet（含 csi-node-driver-registrar / livenessprobe） |
| `50-storageclass.yaml` | StorageClass `hlvm-b`，device-class 指向 `hlvm-lvmd` |

lvmd 本身不在本目录，由 `../lvmd/`（hlvm 自己维护）部署，两者通过宿主
`/run/topolvm/lvmd.sock` 通信。

## 来源与再生成

清单由上游 TopoLVM **v0.42.0** 的 helm chart（`charts/topolvm`，chart 版本 17.2.0）
渲染而来，不是手写的：

```bash
# 1. 取 chart（避免 GitHub API 限流，用源码包；只需要 charts/topolvm）
curl -sL https://codeload.github.com/topolvm/topolvm/tar.gz/refs/tags/v0.42.0 | tar xz

# 2. 渲染（values 见 docs/poc/adr/006 附录）
helm template topolvm <src>/charts/topolvm -n hlvm-system -f csi-values.yaml \
  -s templates/node/daemonset.yaml > 40-node.yaml   # 其余文件同理

# 3. 归一化元数据（去掉 helm.sh/chart、managed-by 改 hlvm-poc、版本号对镜像 tag）
python tmp/normalize-csi.py control-plane/config/csi/*.yaml
```

POC 覆盖值与上游默认的差异只有这些（都写进了 `docs/poc/adr/006-lvmd-deployment.md`）：

- `lvmd.managed=false` —— lvmd 已由 hlvm 部署，避免同一节点起两个 lvmd 抢同一批 VG；
- `image.*` 全部指向同一个 `topolvm-with-sidecar:0.42.0` —— 该变体镜像内含
  `csi-provisioner` / `csi-node-driver-registrar` / `livenessprobe` 等全部 sidecar 二进制，
  弱网环境只预热一个镜像即可，不必再拉 `registry.k8s.io` 的 5 个；
- `node.nodeSelector: hlvm.io/lvmd=true` —— 与 `../lvmd/daemonset.yaml` 一致，指向**所有**
  已建 VG 并打了 `hlvm.io/lvmd=true` 标签的节点（当前 2 个 worker；扩对账有效域时会加上 CP 节点），
  而不是像早期版本那样只写死一台 worker；
- **本地后加**：渲染产物 `40-node.yaml` 里 `topolvm-node` 额外带了一条
  `node-role.kubernetes.io/control-plane:NoSchedule` 的 toleration —— 上游 chart 没有这项，
  扩有效域时 CP 节点需要跑 CSI node 才有 `topolvm.io/node` 拓扑段。
  **再生成时必须重新注入**（`helm template` 之后再手工补，或改用 `--set node.tolerations`），
  否则 CP 节点上的 PVC 建不出来；
- `snapshot.enabled=false` —— 集群没有 `snapshot.storage.k8s.io` CRD，开着会让
  csi-snapshotter 起不来；
- `controller.replicaCount=1`、关 PDB —— POC 单节点存储，不需要 HA；
- `webhook.podMutatingWebhook=false`（上游默认）—— 因此不需要 cert-manager，
  渲染时把 chart 的 cert-manager 依赖摘掉了。

## 部署

```bash
kubectl apply -f control-plane/config/csi/
```

顺序无关：CRD 与 RBAC 会先就绪，Pod 起来时依赖已经在了。等 `topolvm-node` 在目标节点
Ready 后，节点上会出现：

- 标签 `topology.topolvm.io/node=<node>`（scheduler 用它做拓扑绑定）
- 注解 `capacity.topolvm.io/hlvm-lvmd=<字节数>`（VG 可用容量）

## 验证判据

```bash
kubectl get csidriver topolvm.io
kubectl get csinode <node> -o jsonpath='{.spec.drivers[*].name}'
kubectl get csistoragecapacity -A          # csi-provisioner 按 --enable-capacity 创建
kubectl get node <node> -o jsonpath='{.metadata.labels.topology\.topolvm\.io/node}'
```

PVC 端到端（详见 `docs/poc/scripts/pvc-supply-e2e.sh`）：

```bash
kubectl apply -f <pvc+pod yaml>            # SC: hlvm-b
kubectl get pvc                          # Bound，且 PV 带 node affinity
kubectl exec <pod> -- dd if=/dev/zero of=/data/x bs=1M count=16
ssh <node> lvs -o lv_name,lv_size,pool_lv hlvm-lvmd-vg-153
```

## 已知边界

- 只有 `10-60-153-100` 有专用 VG，所以 PVC 只能落到该节点；扩容到多节点需要每台
  worker 各自 `pvcreate`/`vgcreate` + 各自的 `NodeVG`（见 ADR-006 路线 A/B）。
- `hlvm.io/disk`（A 链路）与 `topolvm.io/capacity`（B 链路）是两套独立资源，不要把
  `hlvm.io/disk` 当容量调度资源用。
- NodeVG 目前是手工 seed（路线 A）；生产闭环需要 agent 的 VG-reporter（路线 B）。
