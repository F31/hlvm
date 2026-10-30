package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"sigs.k8s.io/controller-runtime/pkg/webhook/conversion"
)

// 这些测试直接打 conversion webhook 的 HTTP 处理器，覆盖的是**真实协议**：
// apiserver 发什么 body、我们回什么 body，不经过任何 Go 类型假设。
// 集群侧验证（verify-conversion）覆盖证书/Service/CRD 接线，两边互补。

const convertPath = "/convert"

// postConversionReview 发一次 ConversionReview，返回解码后的 response 段。
func postConversionReview(t *testing.T, review map[string]any) map[string]any {
	t.Helper()
	body, err := json.Marshal(review)
	if err != nil {
		t.Fatalf("序列化 ConversionReview 失败: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, convertPath, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	conversion.NewWebhookHandler(scheme).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("期望 200，实际 %d，body=%s", rec.Code, rec.Body.String())
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("响应不是合法 JSON: %v，body=%s", err, rec.Body.String())
	}
	resp, ok := out["response"].(map[string]any)
	if !ok {
		t.Fatalf("响应缺少 response 段: %s", rec.Body.String())
	}
	result, _ := resp["result"].(map[string]any)
	if status, _ := result["status"].(string); status != "Success" {
		t.Fatalf("转换未成功: %v", result)
	}
	return resp
}

func review(desiredAPIVersion string, objects ...map[string]any) map[string]any {
	return map[string]any{
		"apiVersion": "apiextensions.k8s.io/v1",
		"kind":       "ConversionReview",
		"request": map[string]any{
			"uid":               "test-uid",
			"desiredAPIVersion": desiredAPIVersion,
			"objects":           objects,
		},
	}
}

func alphaDisk(name, deviceRef string) map[string]any {
	return map[string]any{
		"apiVersion": "storage.example.io/v1alpha1",
		"kind":       "NodeDisk",
		"metadata":   map[string]any{"name": name},
		"spec":       map[string]any{"nodeName": "node-a", "deviceRef": deviceRef, "adopt": true},
		"status":     map[string]any{"phase": "InVG", "health": "healthy", "capacityBytes": 100},
	}
}

// firstConverted 取出响应的第 n 个转换结果。
func firstConverted(t *testing.T, resp map[string]any) map[string]any {
	t.Helper()
	objs, ok := resp["convertedObjects"].([]any)
	if !ok || len(objs) == 0 {
		t.Fatalf("响应缺少 convertedObjects: %v", resp)
	}
	obj, ok := objs[0].(map[string]any)
	if !ok {
		t.Fatalf("convertedObjects[0] 不是对象: %v", objs[0])
	}
	return obj
}

func TestConvertAlphaToBetaMapsDeviceRef(t *testing.T) {
	resp := postConversionReview(t, review("storage.example.io/v1beta1", alphaDisk("node-a-sda", "/dev/sda")))
	got := firstConverted(t, resp)

	if got["apiVersion"] != "storage.example.io/v1beta1" {
		t.Fatalf("apiVersion 未改成 v1beta1: %v", got["apiVersion"])
	}
	spec := got["spec"].(map[string]any)
	if _, stillThere := spec["deviceRef"]; stillThere {
		t.Errorf("v1beta1 不应再出现 spec.deviceRef: %v", spec)
	}
	device, ok := spec["device"].(map[string]any)
	if !ok {
		t.Fatalf("v1beta1 缺少 spec.device: %v", spec)
	}
	if device["path"] != "/dev/sda" {
		t.Errorf("device.path 不对: %v", device["path"])
	}
	// status 不是空壳：漏映射会让容量/相位丢失。
	status := got["status"].(map[string]any)
	if status["phase"] != "InVG" {
		t.Errorf("status.phase 丢失: %v", status)
	}
	if status["capacityBytes"] != float64(100) {
		t.Errorf("status.capacityBytes 丢失: %v", status["capacityBytes"])
	}
}

func TestConvertBetaToAlphaRestoresDeviceRef(t *testing.T) {
	betaDisk := map[string]any{
		"apiVersion": "storage.example.io/v1beta1",
		"kind":       "NodeDisk",
		"metadata":   map[string]any{"name": "node-a-sda"},
		"spec": map[string]any{
			"nodeName": "node-a",
			"device":   map[string]any{"path": "/dev/sda"},
			"adopt":    true,
		},
		"status": map[string]any{"phase": "InVG"},
	}
	resp := postConversionReview(t, review("storage.example.io/v1alpha1", betaDisk))
	got := firstConverted(t, resp)

	if got["apiVersion"] != "storage.example.io/v1alpha1" {
		t.Fatalf("apiVersion 未改成 v1alpha1: %v", got["apiVersion"])
	}
	spec := got["spec"].(map[string]any)
	if spec["deviceRef"] != "/dev/sda" {
		t.Errorf("deviceRef 未还原: %v", spec)
	}
	if _, stillThere := spec["device"]; stillThere {
		t.Errorf("v1alpha1 不应再出现 spec.device: %v", spec)
	}
}

// 空设备引用：v1alpha1 的 "" 在 v1beta1 必须是**缺省**（不是空对象），
// 否则读写双方都要额外判断"空设备"，往返也不再等价。
func TestConvertAlphaEmptyDeviceRefOmitsDevice(t *testing.T) {
	resp := postConversionReview(t, review("storage.example.io/v1beta1", alphaDisk("node-a-sdb", "")))
	got := firstConverted(t, resp)
	spec := got["spec"].(map[string]any)
	if _, exists := spec["device"]; exists {
		t.Errorf("空 deviceRef 不应产生 spec.device: %v", spec)
	}
}

// 列表转换：apiserver 对 GET .../nodedisks 会整列表下发，逐条走后端会漏。
func TestConvertNodeDiskList(t *testing.T) {
	list := map[string]any{
		"apiVersion": "storage.example.io/v1alpha1",
		"kind":       "NodeDiskList",
		"metadata":   map[string]any{"resourceVersion": "42"},
		"items": []any{
			alphaDisk("node-a-sda", "/dev/sda"),
			alphaDisk("node-b-sdc", "/dev/sdc"),
		},
	}
	resp := postConversionReview(t, review("storage.example.io/v1beta1", list))
	got := firstConverted(t, resp)

	if got["apiVersion"] != "storage.example.io/v1beta1" || got["kind"] != "NodeDiskList" {
		t.Fatalf("列表 TypeMeta 不对: %v/%v", got["apiVersion"], got["kind"])
	}
	items, ok := got["items"].([]any)
	if !ok || len(items) != 2 {
		t.Fatalf("条目数不对: %v", got["items"])
	}
	second := items[1].(map[string]any)["spec"].(map[string]any)
	device, ok := second["device"].(map[string]any)
	if !ok || device["path"] != "/dev/sdc" {
		t.Fatalf("第二条 device 未映射: %v", second)
	}
}
