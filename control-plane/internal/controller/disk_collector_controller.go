package controller

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
	metrics "github.com/F31/hlvm/control-plane/internal/metrics"
)

// 设备插件广告的扩展资源名（与 agent/src/plugin 保持一致）。
const (
	DiskResourceName corev1.ResourceName = "hlvm.io/disk"
	// CollectorComponent 是 collector Pod 的 label 值，也是清理时的选择器依据。
	CollectorComponent = "storage-collector"
	// DefaultCollectorImage 与 agent DaemonSet 同镜像，仅 --mode 不同。
	DefaultCollectorImage = "ghcr.io/f31/hlvm/storage-agent:latest"
	// CollectorMetricsPort 与 exporter 的 /metrics 端口一致。
	CollectorMetricsPort = 9105
)

// DiskCollectorReconciler 为每个 NodeDisk 维护一个**只采该盘 SMART** 的 collector Pod
// （add-disk-device-plugin 6.1）。
//
// 为什么不是 DaemonSet：exporter 以非 root(65532) 挂载宿主 `/dev`，而块设备节点是
// `brw-rw---- root:disk`——非 root 打开即 EACCES，SMART 永远采不到（旧形态的缺口）。
// 通过设备插件按盘申请后，kubelet 才会把该设备写进容器 devices cgroup；因此形态必须是
// 「一个盘一个 Pod，limit `hlvm.io/disk: 1`」，而不是「一个节点一个 Pod」。
//
// 单写者：本控制器只创建/删除 collector Pod，不写 NodeDisk.status（status 仍由 agent 写，
// 避免两个写者对同一对象竞争）；指标由 Prometheus 从 Pod 抓取。
type DiskCollectorReconciler struct {
	client.Client
	Scheme    *runtime.Scheme
	Namespace string
	Image     string
}

// +kubebuilder:rbac:groups=storage.example.io,resources=nodedisks,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=nodes,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch;create;delete

// CollectorOptions 收敛构建 Pod 时可配置项（便于纯函数单测）。
type CollectorOptions struct {
	Namespace string
	Image     string
}

// Reconcile 确保「一个 NodeDisk 恰好一个 collector Pod」，并在设备引用失效时撤掉它。
func (r *DiskCollectorReconciler) Reconcile(ctx context.Context, req ctrl.Request) (result ctrl.Result, err error) {
	logger := log.FromContext(ctx)
	start := time.Now()
	defer func() { metrics.ObserveReconcile(metrics.ControllerDiskCollector, start, err) }()

	var disk storagev1beta1.NodeDisk
	if err := r.Get(ctx, req.NamespacedName, &disk); err != nil {
		if apierrors.IsNotFound(err) {
			// 已删除：主动回收（Cluster-scoped owner 无法级联 namespaced Pod，见 BuildCollectorPod）。
			return ctrl.Result{}, r.cleanupOrphanCollectors(ctx)
		}
		return ctrl.Result{}, err
	}

	ns := r.Namespace
	if ns == "" {
		ns = ManagedNamespace
	}
	podName := CollectorPodName(disk.Spec.NodeName, disk.Name)

	// 设备引用缺失时无法确定要采哪块盘：撤掉既有 Pod，避免留下采集到「全部盘」的僵尸 Pod。
	if disk.Spec.DevicePath() == "" || disk.Spec.NodeName == "" {
		if err := r.deleteCollector(ctx, ns, podName); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}

	// 节点必须已注册 hlvm.io/disk（设备插件就绪）；否则 Pod 会永久 Pending 并占住调度位。
	var node corev1.Node
	if err := r.Get(ctx, types.NamespacedName{Name: disk.Spec.NodeName}, &node); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	qty, ok := node.Status.Allocatable[DiskResourceName]
	if !ok || qty.IsZero() {
		logger.Info("节点未注册设备插件资源，跳过 collector",
			"node", disk.Spec.NodeName, "resource", string(DiskResourceName))
		return ctrl.Result{}, nil
	}

	desired := BuildCollectorPod(&disk, CollectorOptions{Namespace: ns, Image: r.Image})
	var existing corev1.Pod
	getErr := r.Get(ctx, types.NamespacedName{Namespace: ns, Name: desired.Name}, &existing)
	switch {
	case apierrors.IsNotFound(getErr):
		// 扩展资源是**排他**分配的：同节点上同时存在的 collector 不得超过可分配盘数，
		// 否则多出来的 Pod 会永久 Pending 并占住调度位。
		// 盘位不足时定时重试：Pod 事件只映射到它自己的 NodeDisk，等待中的这个盘不会被
		// 别人的 Pod 删除事件唤醒，只靠事件会一直饿着（30s 一次的代价可忽略）。
		free, err := r.hasFreeDiskSlot(ctx, ns, disk.Spec.NodeName, qty)
		if err != nil {
			return ctrl.Result{}, err
		}
		if !free {
			logger.Info("节点盘位已用尽，暂不创建 collector",
				"node", disk.Spec.NodeName, "allocatable", qty.String())
			return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
		}
		if err := r.Create(ctx, desired); err != nil {
			return ctrl.Result{}, err
		}
		logger.Info("已创建 collector Pod",
			"pod", desired.Name, "node", disk.Spec.NodeName, "device", disk.Spec.DevicePath())
		return ctrl.Result{}, nil
	case getErr != nil:
		return ctrl.Result{}, getErr
	}

	// collector 是无状态只读进程：镜像或目标设备变更时删除重建，比原地 patch 更简单且不会
	// 出现「旧容器继续采旧盘」的窗口。
	if CollectorPodNeedsRecreate(&existing, desired) {
		if err := r.deleteCollector(ctx, ns, desired.Name); err != nil {
			return ctrl.Result{}, err
		}
		logger.Info("collector 配置漂移，已删除等待重建", "pod", desired.Name)
		return ctrl.Result{RequeueAfter: 5 * time.Second}, nil
	}
	return ctrl.Result{}, nil
}

// SetupWithManager 注册控制器：NodeDisk 为主资源；collector Pod 的删除/变更通过注解
// 反查回对应的 NodeDisk（无 ownerReference，原因见 BuildCollectorPod）。
func (r *DiskCollectorReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		Named("disk-collector").
		For(&storagev1beta1.NodeDisk{}).
		Watches(&corev1.Pod{}, handler.EnqueueRequestsFromMapFunc(func(_ context.Context, obj client.Object) []reconcile.Request {
			if obj.GetLabels()["component"] != CollectorComponent {
				return nil
			}
			name := obj.GetAnnotations()["hlvm.io/disk-name"]
			if name == "" {
				return nil
			}
			return []reconcile.Request{{NamespacedName: types.NamespacedName{Name: name}}}
		})).
		Complete(r)
}

// hasFreeDiskSlot 判断该节点是否还有未分配的盘位（allocatable - 现有 collector 数 > 0）。
//
// collector Pod 数量等于盘数，量级很小，因此全量 List 后按 spec.NodeName 计数，避免为
// 字段索引增加 cache 配置。
func (r *DiskCollectorReconciler) hasFreeDiskSlot(ctx context.Context, ns, node string, allocatable resource.Quantity) (bool, error) {
	var pods corev1.PodList
	if err := r.List(ctx, &pods, client.InNamespace(ns), client.MatchingLabels{"component": CollectorComponent}); err != nil {
		return false, err
	}
	used := int64(0)
	for i := range pods.Items {
		if pods.Items[i].Spec.NodeName == node {
			used++
		}
	}
	return used < allocatable.Value(), nil
}

// cleanupOrphanCollectors 删除没有对应 NodeDisk 的 collector Pod。
//
// 之所以全量比对而不是只删同名 Pod：控制器可能在 NodeDisk 删除期间重启而错过事件，
// 全量扫描能顺带清掉历史残留（collector Pod 数量 = 磁盘数，成本可忽略）。
func (r *DiskCollectorReconciler) cleanupOrphanCollectors(ctx context.Context) error {
	logger := log.FromContext(ctx)
	ns := r.Namespace
	if ns == "" {
		ns = ManagedNamespace
	}

	var pods corev1.PodList
	if err := r.List(ctx, &pods, client.InNamespace(ns), client.MatchingLabels{"component": CollectorComponent}); err != nil {
		return err
	}
	if len(pods.Items) == 0 {
		return nil
	}

	var disks storagev1beta1.NodeDiskList
	if err := r.List(ctx, &disks); err != nil {
		return err
	}
	alive := make(map[string]struct{}, len(disks.Items))
	for i := range disks.Items {
		alive[disks.Items[i].Name] = struct{}{}
	}

	for i := range pods.Items {
		pod := &pods.Items[i]
		name := pod.Annotations["hlvm.io/disk-name"]
		if name == "" {
			// 归属不明（例如旧版本创建的 Pod）：不盲删，留日志供人工确认。
			logger.Info("collector Pod 缺少归属注解，跳过清理", "pod", pod.Name)
			continue
		}
		if _, ok := alive[name]; ok {
			continue
		}
		if err := r.Delete(ctx, pod); err != nil && !apierrors.IsNotFound(err) {
			return err
		}
		logger.Info("已回收孤儿 collector Pod", "pod", pod.Name, "disk", name)
	}
	return nil
}

func (r *DiskCollectorReconciler) deleteCollector(ctx context.Context, ns, name string) error {
	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name}}
	if err := r.Delete(ctx, pod); err != nil && !apierrors.IsNotFound(err) {
		return err
	}
	return nil
}

// BuildCollectorPod 构造 collector Pod（纯函数，单测直接断言安全上下文与资源申请）。
//
// 安全上下文取舍：设备节点权限是 `root:disk 0640`，非 root 即使拿到 cgroup 授权仍会 EACCES；
// `smartctl` 读 SMART 还依赖 SG_IO ioctl。因此保留 uid 0 与 `SYS_RAWIO`，其余全部收敛：
// privileged=false、drop ALL、只读根、禁止提权、不挂宿主 /dev（设备由插件下发）、不挂 SA token。
func BuildCollectorPod(disk *storagev1beta1.NodeDisk, opts CollectorOptions) *corev1.Pod {
	ns := opts.Namespace
	if ns == "" {
		ns = ManagedNamespace
	}
	image := opts.Image
	if image == "" {
		image = DefaultCollectorImage
	}

	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      CollectorPodName(disk.Spec.NodeName, disk.Name),
			Namespace: ns,
			Labels: map[string]string{
				"app":          "hlvm",
				"component":    CollectorComponent,
				"hlvm.io/disk": labelValue(disk.Name),
			},
			// 注解保存**完整** NodeDisk 名：label 值被限制为 63 字符且会被清洗，
			// 长名字截断后无法反查（NodeDisk 名上限 253）。
			Annotations: map[string]string{
				"hlvm.io/disk-name":   disk.Name,
				"hlvm.io/disk-device": disk.Spec.DevicePath(),
				// Prometheus 的 Pod 服务发现按注解抓取；不依赖 Service 即可收集每个盘。
				"prometheus.io/scrape": "true",
				"prometheus.io/port":   "9105",
			},
			// 不设 ownerReference：NodeDisk 是 Cluster-scoped，而 Pod 是 namespaced，
			// 跨作用域 owner 会被 GC 判为无效并**立即删除**该 Pod。级联回收改由
			// cleanupOrphanCollectors 主动完成（见 Reconcile 的 NotFound 分支）。
		},
		Spec: corev1.PodSpec{
			// 盘在哪就在哪：直接绑定节点，避免调度到没有该设备的节点后再等待。
			NodeName:                      disk.Spec.NodeName,
			RestartPolicy:                 corev1.RestartPolicyAlways,
			AutomountServiceAccountToken:  ptr.To(false),
			Tolerations:                   []corev1.Toleration{{Operator: corev1.TolerationOpExists}},
			TerminationGracePeriodSeconds: ptr.To(int64(5)),
			Containers: []corev1.Container{{
				Name:  "collector",
				Image: image,
				Args:  []string{"--mode=exporter"},
				Env: []corev1.EnvVar{
					{Name: "NODE_NAME", ValueFrom: &corev1.EnvVarSource{
						FieldRef: &corev1.ObjectFieldSelector{FieldPath: "spec.nodeName"},
					}},
					// 单盘采集：容器内没有 /dev/disk/by-id，且**分到哪块盘由 kubelet 决定**
					// （扩展资源无法表达「指定某块」）。auto 让 exporter 枚举 /dev——设备插件
					// 只把分配到的那块 bind-mount 进容器，因此枚举结果恰好是授权集合，不会
					// 把 A 盘读数标成 B 盘（deviceRef 仅作为意图留在注解里）。
					{Name: "HLVM_EXPORTER_DEVICE", Value: "auto"},
					{Name: "HLVM_SMART_THRESHOLDS_CONFIGMAP", Value: "hlvm-smart-thresholds"},
				},
				Ports: []corev1.ContainerPort{{Name: "metrics", ContainerPort: CollectorMetricsPort}},
				Resources: corev1.ResourceRequirements{
					// 扩展资源必须 requests == limits，且「申请 1 块」正是授权的表达方式。
					Limits: corev1.ResourceList{DiskResourceName: resource.MustParse("1")},
				},
				SecurityContext: &corev1.SecurityContext{
					Privileged:               ptr.To(false),
					RunAsUser:                ptr.To(int64(0)),
					ReadOnlyRootFilesystem:   ptr.To(true),
					AllowPrivilegeEscalation: ptr.To(false),
					Capabilities: &corev1.Capabilities{
						Drop: []corev1.Capability{"ALL"},
						Add:  []corev1.Capability{"SYS_RAWIO"},
					},
				},
				VolumeMounts: []corev1.VolumeMount{
					{Name: "sys", MountPath: "/sys", ReadOnly: true},
					{Name: "proc", MountPath: "/proc", ReadOnly: true},
					{Name: "smart-thresholds", MountPath: "/etc/hlvm/smart", ReadOnly: true},
				},
				// exporter 对任意路径都返回 200 + 指标文本，这里用 /metrics 判活最贴近真实行为。
				ReadinessProbe: &corev1.Probe{
					ProbeHandler: corev1.ProbeHandler{HTTPGet: &corev1.HTTPGetAction{
						Path: "/metrics", Port: intstr.FromInt32(CollectorMetricsPort),
					}},
					InitialDelaySeconds: 3,
					PeriodSeconds:       10,
				},
			}},
			Volumes: []corev1.Volume{
				{Name: "sys", VolumeSource: corev1.VolumeSource{
					HostPath: &corev1.HostPathVolumeSource{Path: "/sys"},
				}},
				{Name: "proc", VolumeSource: corev1.VolumeSource{
					HostPath: &corev1.HostPathVolumeSource{Path: "/proc"},
				}},
				{Name: "smart-thresholds", VolumeSource: corev1.VolumeSource{
					ConfigMap: &corev1.ConfigMapVolumeSource{
						LocalObjectReference: corev1.LocalObjectReference{Name: "hlvm-smart-thresholds"},
						Optional:             ptr.To(true),
					},
				}},
			},
		},
	}
}

// CollectorPodName 生成稳定且合法的 Pod 名：`hlvm-collector-<node>-<disk>-<hash8>`。
// 加 hash 是因为 node/disk 组合可能超过 63 字符或清洗后碰撞，截断会丢唯一性。
func CollectorPodName(node, disk string) string {
	raw := "hlvm-collector-" + node + "-" + disk
	sum := sha256.Sum256([]byte(raw))
	suffix := hex.EncodeToString(sum[:4])
	base := sanitizeDNSLabel(raw)
	const maxLen = 63
	if len(base)+1+len(suffix) > maxLen {
		base = strings.Trim(base[:maxLen-1-len(suffix)], "-.")
	}
	return base + "-" + suffix
}

// CollectorPodNeedsRecreate 判断既有 Pod 是否已偏离期望（镜像或目标设备变化）。
//
// 设备比对用注解而非 env：collector 以 `HLVM_EXPORTER_DEVICE=auto` 采集实际分到的盘，
// env 恒定；`hlvm.io/disk-device` 才是 NodeDisk 声明的意图，意图变了就重建一次，
// 让注解与新意图一致（避免运维按注解排查时看到过期值）。
func CollectorPodNeedsRecreate(existing, desired *corev1.Pod) bool {
	if len(existing.Spec.Containers) != 1 || len(desired.Spec.Containers) != 1 {
		return true
	}
	if existing.Spec.Containers[0].Image != desired.Spec.Containers[0].Image {
		return true
	}
	return existing.Annotations["hlvm.io/disk-device"] != desired.Annotations["hlvm.io/disk-device"]
}

func envValue(env []corev1.EnvVar, name string) string {
	for _, e := range env {
		if e.Name == name {
			return e.Value
		}
	}
	return ""
}

// sanitizeDNSLabel 把任意字符串收敛为 DNS-1123 label（小写、[a-z0-9-]、首尾字母数字）。
func sanitizeDNSLabel(s string) string {
	var b strings.Builder
	lastDash := false
	for _, r := range strings.ToLower(s) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
			lastDash = false
		default:
			if !lastDash && b.Len() > 0 {
				b.WriteByte('-')
				lastDash = true
			}
		}
	}
	return strings.Trim(b.String(), "-.")
}

// labelValue 收敛为合法 label value（≤63）；空值回退 unknown，避免非法对象被 API 拒绝。
func labelValue(s string) string {
	v := sanitizeDNSLabel(s)
	if v == "" {
		return "unknown"
	}
	if len(v) > 63 {
		v = strings.Trim(v[:63], "-.")
	}
	return v
}
