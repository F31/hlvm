package dashboard

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"github.com/go-logr/logr"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

func newScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(s); err != nil {
		t.Fatalf("clientgo scheme: %v", err)
	}
	if err := storagev1alpha1.AddToScheme(s); err != nil {
		t.Fatalf("storage scheme: %v", err)
	}
	return s
}

func seedClient(t *testing.T) client.Client {
	t.Helper()
	scheme := newScheme(t)
	disk := &storagev1alpha1.NodeDisk{
		ObjectMeta: metav1.ObjectMeta{Name: "disk-1"},
		Spec:       storagev1alpha1.DiskSpec{NodeName: "node-1"},
		Status: storagev1alpha1.DiskStatus{
			Identity:      storagev1alpha1.DiskIdentity{Serial: "ABC123"},
			Phase:         storagev1alpha1.DiskPhaseCandidate,
			Health:        storagev1alpha1.DiskHealthHealthy,
			CapacityBytes: 1 << 40,
		},
	}
	inVG := &storagev1alpha1.NodeDisk{
		ObjectMeta: metav1.ObjectMeta{Name: "disk-2"},
		Spec:       storagev1alpha1.DiskSpec{NodeName: "node-1"},
		Status: storagev1alpha1.DiskStatus{
			Identity: storagev1alpha1.DiskIdentity{Serial: "XYZ"},
			Phase:    storagev1alpha1.DiskPhaseInVG,
			Health:   storagev1alpha1.DiskHealthHealthy,
		},
	}
	vg := &storagev1alpha1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: "vg-1"},
		Spec: storagev1alpha1.VGSpec{
			NodeName:   "node-1",
			Layout:     storagev1alpha1.VGLayoutPooled,
			Redundancy: storagev1alpha1.RedundancyNone,
		},
		Status: storagev1alpha1.VGStatus{
			TotalBytes:     2 << 40,
			FreeBytes:      1 << 40,
			CapacityStatus: storagev1alpha1.CapacityAvailable,
			ThinPool: storagev1alpha1.VGThinPoolStatus{
				DataPercent:     30.5,
				MetadataPercent: 10.2,
				OutOfSpace:      false,
			},
			PendingOps: []string{"op-demo"},
		},
	}
	return fake.NewClientBuilder().WithScheme(scheme).WithObjects(disk, inVG, vg).Build()
}

func newTestServer(t *testing.T) (*Server, *httptest.Server) {
	t.Helper()
	c := seedClient(t)
	srv := NewServer(c, c, logr.Discard(), ":0")
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return srv, ts
}

func postJSON(t *testing.T, url string, body interface{}) (int, []byte) {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	resp, err := http.Post(url, "application/json", bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("post %s: %v", url, err)
	}
	defer resp.Body.Close()
	buf := new(bytes.Buffer)
	_, _ = buf.ReadFrom(resp.Body)
	return resp.StatusCode, buf.Bytes()
}

func TestStatusReadOnly(t *testing.T) {
	_, ts := newTestServer(t)
	resp, err := http.Get(ts.URL + "/api/v1/status")
	if err != nil {
		t.Fatalf("get status: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status code = %d, want 200", resp.StatusCode)
	}
	var view StatusView
	if err := json.NewDecoder(resp.Body).Decode(&view); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(view.Disks) != 2 {
		t.Fatalf("disks = %d, want 2", len(view.Disks))
	}
	if len(view.VGs) != 1 {
		t.Fatalf("vgs = %d, want 1", len(view.VGs))
	}
	var found bool
	for _, d := range view.Disks {
		if d.Name == "disk-1" && d.Serial == "ABC123" && d.Phase == "Candidate" {
			found = true
		}
	}
	if !found {
		t.Fatalf("disk-1/ABC123/Candidate 未出现在大盘: %+v", view.Disks)
	}
	if view.VGs[0].PendingOps[0] != "op-demo" {
		t.Fatalf("vg pendingOps 未正确投影: %+v", view.VGs[0])
	}
}

func TestAdoptWrongSerialRejected(t *testing.T) {
	srv, ts := newTestServer(t)
	code, body := postJSON(t, ts.URL+"/api/v1/adopt", AdoptRequest{
		NodeDisk:      "disk-1",
		Wipe:          true,
		ConfirmSerial: "WRONG",
	})
	if code != http.StatusBadRequest {
		t.Fatalf("code = %d, want 400; body=%s", code, body)
	}
	// 不应创建任何 StorageTask。
	var tl storagev1alpha1.StorageTaskList
	if err := srv.writer.List(context.Background(), &tl); err != nil {
		t.Fatalf("list tasks: %v", err)
	}
	if len(tl.Items) != 0 {
		t.Fatalf("confirmSerial 不匹配时不应创建任务，实际 = %d", len(tl.Items))
	}
}

func TestAdoptHappyPathCreatesPendingTask(t *testing.T) {
	srv, ts := newTestServer(t)
	code, body := postJSON(t, ts.URL+"/api/v1/adopt", AdoptRequest{
		NodeDisk:      "disk-1",
		Wipe:          true,
		WipePolicy:    "secure-erase",
		ConfirmSerial: "ABC123",
	})
	if code != http.StatusOK {
		t.Fatalf("code = %d, want 200; body=%s", code, body)
	}
	var resp AdoptResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("decode resp: %v", err)
	}
	if !resp.Adopted || resp.CreatedTask == "" {
		t.Fatalf("adopt 响应异常: %+v", resp)
	}
	// 创建了待审批 StorageTask：ApprovedBy 必须为空（未审批，绝不执行）。
	var tl storagev1alpha1.StorageTaskList
	if err := srv.writer.List(context.Background(), &tl); err != nil {
		t.Fatalf("list tasks: %v", err)
	}
	if len(tl.Items) != 1 {
		t.Fatalf("tasks = %d, want 1", len(tl.Items))
	}
	task := tl.Items[0]
	if task.Spec.ApprovedBy != "" {
		t.Fatalf("ApprovedBy = %q, 必须为空（待审批）", task.Spec.ApprovedBy)
	}
	if task.Spec.Type != storagev1alpha1.TaskWipe {
		t.Fatalf("Type = %q, want wipe", task.Spec.Type)
	}
	if task.Spec.Target.DiskRef != "disk-1" {
		t.Fatalf("Target.DiskRef = %q, want disk-1", task.Spec.Target.DiskRef)
	}
	// 磁盘被置 Adopt=true 并记录 WipePolicy。
	var disk storagev1alpha1.NodeDisk
	if err := srv.writer.Get(context.Background(), client.ObjectKey{Name: "disk-1"}, &disk); err != nil {
		t.Fatalf("get disk: %v", err)
	}
	if !disk.Spec.Adopt {
		t.Fatalf("Spec.Adopt 未被置 true")
	}
	if disk.Spec.WipePolicy != storagev1alpha1.WipeSecureErase {
		t.Fatalf("Spec.WipePolicy = %q, want secure-erase", disk.Spec.WipePolicy)
	}
}

func TestAdoptNonCandidateRejected(t *testing.T) {
	_, ts := newTestServer(t)
	code, body := postJSON(t, ts.URL+"/api/v1/adopt", AdoptRequest{
		NodeDisk:      "disk-2",
		Wipe:          true,
		ConfirmSerial: "XYZ",
	})
	if code != http.StatusConflict {
		t.Fatalf("code = %d, want 409; body=%s", code, body)
	}
}

func TestAdoptNotFound(t *testing.T) {
	_, ts := newTestServer(t)
	code, body := postJSON(t, ts.URL+"/api/v1/adopt", AdoptRequest{
		NodeDisk:      "nope",
		ConfirmSerial: "x",
	})
	if code != http.StatusNotFound {
		t.Fatalf("code = %d, want 404; body=%s", code, body)
	}
}

func TestIndexHTML(t *testing.T) {
	_, ts := newTestServer(t)
	resp, err := http.Get(ts.URL + "/")
	if err != nil {
		t.Fatalf("get /: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("code = %d, want 200", resp.StatusCode)
	}
	buf := new(bytes.Buffer)
	_, _ = buf.ReadFrom(resp.Body)
	if !bytes.Contains(buf.Bytes(), []byte("hlvm 只读大盘")) {
		t.Fatalf("index 页面内容异常: %s", buf.String()[:min(80, buf.Len())])
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
