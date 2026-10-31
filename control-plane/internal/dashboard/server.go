// Package dashboard 实现控制面只读大盘与纳管入口（add-observability 3.2/3.3）。
//
// 设计约束（见 openspec/changes/add-observability/spec.md）：
//   - 大盘只读：GET 仅查询，不写入任何对象。
//   - 纳管入口：adopt 仅置 Spec.Adopt=true（纳管意图，非破坏性）并生成「待审批」StorageTask
//     （ApprovedBy 留空 => 由 add-admission-scheduling 的 webhook 拦截，绝不在此直接执行擦除）。
//   - 双确认：confirmSerial 必须与 NodeDisk.Status.Identity.Serial 完全一致，防误选盘。
//
// 本仓库无独立前端工程，故以 Go 二进制内嵌只读 HTTP 服务形式交付（HTML + JSON API），
// 由控制面 manager 以 Runnable 托管生命周期。
package dashboard

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/go-logr/logr"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// Server 是控制面只读大盘 + 纳管入口 HTTP 服务。
type Server struct {
	reader client.Reader // 用于大盘只读查询（直连 apiserver，不依赖缓存）
	writer client.Client // 用于 adopt 的读+写操作（缓存客户端支持 Get/Update/Create）
	log    logr.Logger
	addr   string
	mux    *http.ServeMux
}

// NewServer 构造只读大盘服务。
// reader 建议传 mgr.GetAPIReader()（直连，无缓存同步依赖）；writer 传 mgr.GetClient()。
func NewServer(reader client.Reader, writer client.Client, log logr.Logger, addr string) *Server {
	s := &Server{reader: reader, writer: writer, log: log, addr: addr}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/api/v1/status", s.handleStatus)
	mux.HandleFunc("/api/v1/adopt", s.handleAdopt)
	mux.HandleFunc("/", s.handleIndex)
	s.mux = mux
	return s
}

// Handler 暴露内部 mux，便于单测用 httptest 托管。
func (s *Server) Handler() http.Handler { return s.mux }

// Start 实现 manager.Runnable，由控制面 manager 托管生命周期。
func (s *Server) Start(ctx context.Context) error {
	srv := &http.Server{Addr: s.addr, Handler: s.mux}
	s.log.Info("启动只读大盘服务", "addr", s.addr)
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// ---- 视图结构（大盘只暴露只读投影，不暴露完整对象）----

// DiskView 是 NodeDisk 的只读投影。
type DiskView struct {
	Name          string             `json:"name"`
	Node          string             `json:"node"`
	Serial        string             `json:"serial"`
	DeviceRef     string             `json:"deviceRef,omitempty"`
	Phase         string             `json:"phase"`
	Health        string             `json:"health"`
	CapacityBytes int64              `json:"capacityBytes"`
	OccupiedBy    string             `json:"occupiedBy,omitempty"`
	Adopt         bool               `json:"adopt"`
	Precheck      []metav1.Condition `json:"precheck,omitempty"` // 预检报告以 conditions 体现
}

// VGView 是 NodeVG 的只读投影。
type VGView struct {
	Name            string   `json:"name"`
	Node            string   `json:"node"`
	Layout          string   `json:"layout"`
	Redundancy      string   `json:"redundancy"`
	Disks           []string `json:"disks,omitempty"`
	TotalBytes      int64    `json:"totalBytes"`
	FreeBytes       int64    `json:"freeBytes"`
	CapacityStatus  string   `json:"capacityStatus,omitempty"`
	DataPercent     float64  `json:"thinpoolDataPercent"`
	MetadataPercent float64  `json:"thinpoolMetadataPercent"`
	OutOfSpace      bool     `json:"outOfSpace"`
	PendingOps      []string `json:"pendingOps,omitempty"`
}

// StatusView 是大盘聚合视图。
type StatusView struct {
	Disks []DiskView `json:"disks"`
	VGs   []VGView   `json:"vgs"`
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

// handleStatus 大盘只读聚合：列出所有 NodeDisk / NodeVG 的投影。
func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	ctx := r.Context()
	var dl storagev1beta1.NodeDiskList
	if err := s.reader.List(ctx, &dl); err != nil {
		s.writeErr(w, http.StatusInternalServerError, err)
		return
	}
	var vl storagev1alpha1.NodeVGList
	if err := s.reader.List(ctx, &vl); err != nil {
		s.writeErr(w, http.StatusInternalServerError, err)
		return
	}
	view := StatusView{}
	for i := range dl.Items {
		d := &dl.Items[i]
		view.Disks = append(view.Disks, DiskView{
			Name:          d.Name,
			Node:          d.Spec.NodeName,
			Serial:        d.Status.Identity.Serial,
			DeviceRef:     d.Spec.DevicePath(),
			Phase:         string(d.Status.Phase),
			Health:        string(d.Status.Health),
			CapacityBytes: d.Status.CapacityBytes,
			OccupiedBy:    string(d.Status.OccupiedBy),
			Adopt:         d.Spec.Adopt,
			Precheck:      d.Status.Conditions,
		})
	}
	for i := range vl.Items {
		v := &vl.Items[i]
		view.VGs = append(view.VGs, VGView{
			Name:            v.Name,
			Node:            v.Spec.NodeName,
			Layout:          string(v.Spec.Layout),
			Redundancy:      string(v.Spec.Redundancy),
			Disks:           v.Spec.Disks,
			TotalBytes:      v.Status.TotalBytes,
			FreeBytes:       v.Status.FreeBytes,
			CapacityStatus:  string(v.Status.CapacityStatus),
			DataPercent:     v.Status.ThinPool.DataPercent,
			MetadataPercent: v.Status.ThinPool.MetadataPercent,
			OutOfSpace:      v.Status.ThinPool.OutOfSpace,
			PendingOps:      v.Status.PendingOps,
		})
	}
	s.writeJSON(w, http.StatusOK, view)
}

// AdoptRequest 是纳管入口请求体。
type AdoptRequest struct {
	NodeDisk      string `json:"nodeDisk"`
	Wipe          bool   `json:"wipe"`
	WipePolicy    string `json:"wipePolicy,omitempty"`
	ConfirmSerial string `json:"confirmSerial,omitempty"`
}

// AdoptResponse 是纳管入口响应体。
type AdoptResponse struct {
	NodeDisk    string `json:"nodeDisk"`
	Adopted     bool   `json:"adopted"`
	CreatedTask string `json:"createdTask,omitempty"`
	Message     string `json:"message,omitempty"`
}

// handleAdopt 纳管入口：双确认 + 仅生成待审批任务，绝不直接执行。
func (s *Server) handleAdopt(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req AdoptRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.writeErr(w, http.StatusBadRequest, fmt.Errorf("请求体解析失败: %w", err))
		return
	}
	if req.NodeDisk == "" {
		s.writeErr(w, http.StatusBadRequest, fmt.Errorf("nodeDisk 必填"))
		return
	}
	ctx := r.Context()

	var disk storagev1beta1.NodeDisk
	if err := s.writer.Get(ctx, client.ObjectKey{Name: req.NodeDisk}, &disk); err != nil {
		if apierrors.IsNotFound(err) {
			s.writeErr(w, http.StatusNotFound, fmt.Errorf("NodeDisk %q 不存在", req.NodeDisk))
			return
		}
		s.writeErr(w, http.StatusInternalServerError, err)
		return
	}
	// 仅 Candidate 可纳管。
	if disk.Status.Phase != storagev1beta1.DiskPhaseCandidate {
		s.writeErr(w, http.StatusConflict,
			fmt.Errorf("磁盘 %q 当前 phase=%s，仅 Candidate 可纳管", req.NodeDisk, disk.Status.Phase))
		return
	}
	// 双确认：confirmSerial 必须与权威 serial 完全一致，防误选盘。
	serial := disk.Status.Identity.Serial
	if req.ConfirmSerial != serial {
		s.writeErr(w, http.StatusBadRequest, fmt.Errorf("confirmSerial 不匹配（期望 %q）", serial))
		return
	}

	// 纳管意图（非破坏性）：置 Adopt=true；如指定擦除策略则记录。
	disk.Spec.Adopt = true
	if req.Wipe {
		if req.WipePolicy != "" {
			disk.Spec.WipePolicy = storagev1beta1.WipePolicy(req.WipePolicy)
		}
		disk.Spec.ConfirmSerial = req.ConfirmSerial
	}
	if err := s.writer.Update(ctx, &disk); err != nil {
		s.writeErr(w, http.StatusInternalServerError, fmt.Errorf("更新 NodeDisk 失败: %w", err))
		return
	}

	resp := AdoptResponse{NodeDisk: req.NodeDisk, Adopted: true}
	if req.Wipe {
		// 仅生成待审批 StorageTask（ApprovedBy 留空 => 由 admission webhook 拦截，绝不在此直接执行擦除）。
		taskName := fmt.Sprintf("%s-wipe-%d", disk.Name, time.Now().UnixNano())
		task := &storagev1alpha1.StorageTask{
			ObjectMeta: metav1.ObjectMeta{Name: taskName},
			Spec: storagev1alpha1.StorageTaskSpec{
				NodeName:      disk.Spec.NodeName,
				Type:          storagev1alpha1.TaskWipe,
				Target:        storagev1alpha1.TaskTarget{DiskRef: disk.Name},
				ConfirmSerial: req.ConfirmSerial,
				// ApprovedBy 故意留空：待审批，不执行。
			},
		}
		if err := s.writer.Create(ctx, task); err != nil {
			s.writeErr(w, http.StatusInternalServerError, fmt.Errorf("创建待审批 StorageTask 失败: %w", err))
			return
		}
		resp.CreatedTask = taskName
		resp.Message = "已生成待审批擦除任务，需审批后由 Agent 执行"
	} else {
		resp.Message = "已置纳管意图（Adopt=true），未发起破坏性操作"
	}
	s.writeJSON(w, http.StatusOK, resp)
}

// handleIndex 提供极简只读 HTML 大盘（浏览器直接访问）。
func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(indexHTML))
}

func (s *Server) writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Server) writeErr(w http.ResponseWriter, code int, err error) {
	s.log.Error(err, "请求处理失败", "code", code)
	s.writeJSON(w, code, map[string]string{"error": err.Error()})
}

// indexHTML 是只读大盘页面：拉取 /api/v1/status 并渲染 Disk/VG 表。
// 注意：本文件为 Go 源码，字符串内不得出现反引号；JS 拼接一律用双引号 + 加号。
const indexHTML = `<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<title>hlvm 只读大盘</title>
<style>
body{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:24px;color:#222}
h1{font-size:20px}h2{font-size:16px;margin-top:24px}
table{border-collapse:collapse;width:100%;margin-top:8px;font-size:13px}
th,td{border:1px solid #ddd;padding:6px 8px;text-align:left}
th{background:#f5f5f5}
.healthy{color:#1a7f37}.warning{color:#9a6700}.critical,.failed{color:#cf222e}
.locked{color:#cf222e;font-weight:bold}
.tag{display:inline-block;padding:1px 6px;border-radius:3px;background:#eee;font-size:11px}
</style>
</head>
<body>
<h1>hlvm 只读大盘</h1>
<p style="color:#666">只读视图：展示 Disk/VG/容量/健康与预检状态。破坏性操作请走纳管入口 API（POST /api/v1/adopt）。</p>
<h2>磁盘 (NodeDisk)</h2>
<table id="disks"><thead><tr>
<th>名称</th><th>节点</th><th>Serial</th><th>设备</th><th>阶段</th><th>健康</th><th>容量</th><th>占用</th><th>纳管</th><th>预检条件数</th>
</tr></thead><tbody></tbody></table>
<h2>卷组 (NodeVG)</h2>
<table id="vgs"><thead><tr>
<th>名称</th><th>节点</th><th>布局</th><th>冗余</th><th>总容量</th><th>空闲</th><th>容量状态</th><th>Data%</th><th>Meta%</th><th>OOS</th><th>PendingOps</th>
</tr></thead><tbody></tbody></table>
<script>
function fmtBytes(n){if(!n)return '-';var u=['B','KB','MB','GB','TB','PB'];var i=0;var v=n;while(v>=1024&&i<u.length-1){v=v/1024;i++;}return v.toFixed(1)+u[i];}
function healthCls(h){if(h==='healthy')return 'healthy';if(h==='warning')return 'warning';if(h==='critical'||h==='failed')return 'critical';return '';}
function dp(n){return (typeof n==='number')?n.toFixed(1):'-';}
function load(){
  fetch('/api/v1/status').then(function(r){return r.json();}).then(function(d){
    var dt=document.querySelector('#disks tbody');dt.innerHTML='';
    (d.disks||[]).forEach(function(x){
      var tr=document.createElement('tr');
      tr.innerHTML='<td>'+x.name+'</td><td>'+x.node+'</td><td>'+x.serial+'</td><td>'+(x.deviceRef||'-')+'</td>'
        +'<td>'+x.phase+'</td><td class="'+healthCls(x.health)+'">'+x.health+'</td>'
        +'<td>'+fmtBytes(x.capacityBytes)+'</td><td>'+(x.occupiedBy||'-')+'</td>'
        +'<td>'+(x.adopt?'<span class="tag">adopt</span>':'-')+'</td><td>'+((x.precheck||[]).length)+'</td>';
      dt.appendChild(tr);
    });
    var vt=document.querySelector('#vgs tbody');vt.innerHTML='';
    (d.vgs||[]).forEach(function(x){
      var cs=(x.capacityStatus==='locked')?'locked':'';
      tr=document.createElement('tr');
      tr.innerHTML='<td>'+x.name+'</td><td>'+x.node+'</td><td>'+x.layout+'</td><td>'+x.redundancy+'</td>'
        +'<td>'+fmtBytes(x.totalBytes)+'</td><td>'+fmtBytes(x.freeBytes)+'</td>'
        +'<td class="'+cs+'">'+(x.capacityStatus||'-')+'</td><td>'+dp(x.thinpoolDataPercent)+'</td>'
        +'<td>'+dp(x.thinpoolMetadataPercent)+'</td><td>'+(x.outOfSpace?'是':'否')+'</td>'
        +'<td>'+((x.pendingOps||[]).join('; ')||'-')+'</td>';
      vt.appendChild(tr);
    });
  }).catch(function(e){console.error(e);});
}
load();setInterval(load,15000);
</script>
</body>
</html>`
