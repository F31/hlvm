package v1alpha1

import (
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/conversion"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// 本文件实现 v1alpha1 作为 spoke 的双向转换（hub 在 api/v1beta1）。
//
// 字段映射：ThinPoolPolicy 在 v1alpha1 与 v1beta1 之间是**逐字段恒等**（本轮仅建立版本化机制，
// schema 未变；v1beta1 作为存储版本承担未来演进）。

// ConvertTo 把 v1alpha1 ThinPoolPolicy 转换为 hub 版本（v1beta1）。
func (src *ThinPoolPolicy) ConvertTo(dstRaw conversion.Hub) error {
	dst, ok := dstRaw.(*storagev1beta1.ThinPoolPolicy)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.ThinPoolPolicy，实际是 %T", dstRaw)
	}
	convertThinPoolPolicyToBeta(src, dst)
	return nil
}

// ConvertFrom 把 hub 版本（v1beta1）转换回 v1alpha1。
func (src *ThinPoolPolicy) ConvertFrom(srcRaw conversion.Hub) error {
	hub, ok := srcRaw.(*storagev1beta1.ThinPoolPolicy)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.ThinPoolPolicy，实际是 %T", srcRaw)
	}
	convertThinPoolPolicyFromBeta(hub, src)
	return nil
}

// ConvertTo 把 v1alpha1 ThinPoolPolicyList 转换为 hub 版本。
func (src *ThinPoolPolicyList) ConvertTo(dstRaw conversion.Hub) error {
	dst, ok := dstRaw.(*storagev1beta1.ThinPoolPolicyList)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.ThinPoolPolicyList，实际是 %T", dstRaw)
	}
	dst.TypeMeta = metav1.TypeMeta{
		APIVersion: storagev1beta1.GroupVersion.String(),
		Kind:       "ThinPoolPolicyList",
	}
	dst.ListMeta = src.ListMeta
	dst.Items = make([]storagev1beta1.ThinPoolPolicy, len(src.Items))
	for i := range src.Items {
		convertThinPoolPolicyToBeta(&src.Items[i], &dst.Items[i])
	}
	return nil
}

// ConvertFrom 把 hub 版本的 ThinPoolPolicyList 转换回 v1alpha1。
func (src *ThinPoolPolicyList) ConvertFrom(srcRaw conversion.Hub) error {
	hub, ok := srcRaw.(*storagev1beta1.ThinPoolPolicyList)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.ThinPoolPolicyList，实际是 %T", srcRaw)
	}
	src.TypeMeta = metav1.TypeMeta{
		APIVersion: GroupVersion.String(),
		Kind:       "ThinPoolPolicyList",
	}
	src.ListMeta = hub.ListMeta
	src.Items = make([]ThinPoolPolicy, len(hub.Items))
	for i := range hub.Items {
		convertThinPoolPolicyFromBeta(&hub.Items[i], &src.Items[i])
	}
	return nil
}

func convertThinPoolPolicyToBeta(in *ThinPoolPolicy, out *storagev1beta1.ThinPoolPolicy) {
	out.TypeMeta = metav1.TypeMeta{
		APIVersion: storagev1beta1.GroupVersion.String(),
		Kind:       "ThinPoolPolicy",
	}
	out.ObjectMeta = *in.ObjectMeta.DeepCopy()
	out.Spec = storagev1beta1.ThinPoolPolicySpec{
		Thresholds:         thresholdsToBeta(in.Spec.Thresholds),
		Forecast:           storagev1beta1.ThinPoolForecast{TimeToFullWarning: in.Spec.Forecast.TimeToFullWarning, TimeToFullCritical: in.Spec.Forecast.TimeToFullCritical},
		Lock:               storagev1beta1.ThinPoolLock{BlockNewPVC: in.Spec.Lock.BlockNewPVC, BlockPVCExpansion: in.Spec.Lock.BlockPVCExpansion},
		RequireFreeVGSpace: in.Spec.RequireFreeVGSpace,
		AlertChannels:      append([]string(nil), in.Spec.AlertChannels...),
		TierOverrides:      tierOverridesToBeta(in.Spec.TierOverrides),
	}
}

func convertThinPoolPolicyFromBeta(in *storagev1beta1.ThinPoolPolicy, out *ThinPoolPolicy) {
	out.TypeMeta = metav1.TypeMeta{
		APIVersion: GroupVersion.String(),
		Kind:       "ThinPoolPolicy",
	}
	out.ObjectMeta = *in.ObjectMeta.DeepCopy()
	out.Spec = ThinPoolPolicySpec{
		Thresholds:         thresholdsFromBeta(in.Spec.Thresholds),
		Forecast:           ThinPoolForecast{TimeToFullWarning: in.Spec.Forecast.TimeToFullWarning, TimeToFullCritical: in.Spec.Forecast.TimeToFullCritical},
		Lock:               ThinPoolLock{BlockNewPVC: in.Spec.Lock.BlockNewPVC, BlockPVCExpansion: in.Spec.Lock.BlockPVCExpansion},
		RequireFreeVGSpace: in.Spec.RequireFreeVGSpace,
		AlertChannels:      append([]string(nil), in.Spec.AlertChannels...),
		TierOverrides:      tierOverridesFromBeta(in.Spec.TierOverrides),
	}
}

func thresholdsToBeta(in ThinPoolThresholds) storagev1beta1.ThinPoolThresholds {
	return storagev1beta1.ThinPoolThresholds{
		AutoExtendPercent:       in.AutoExtendPercent,
		AutoExtendStepPercent:   in.AutoExtendStepPercent,
		WarningPercent:          in.WarningPercent,
		CriticalPercent:         in.CriticalPercent,
		UnlockPercent:           in.UnlockPercent,
		MetadataWarningPercent:  in.MetadataWarningPercent,
		MetadataCriticalPercent: in.MetadataCriticalPercent,
	}
}

func thresholdsFromBeta(in storagev1beta1.ThinPoolThresholds) ThinPoolThresholds {
	return ThinPoolThresholds{
		AutoExtendPercent:       in.AutoExtendPercent,
		AutoExtendStepPercent:   in.AutoExtendStepPercent,
		WarningPercent:          in.WarningPercent,
		CriticalPercent:         in.CriticalPercent,
		UnlockPercent:           in.UnlockPercent,
		MetadataWarningPercent:  in.MetadataWarningPercent,
		MetadataCriticalPercent: in.MetadataCriticalPercent,
	}
}

func tierOverridesToBeta(in map[string]ThinPoolThresholds) map[string]storagev1beta1.ThinPoolThresholds {
	if in == nil {
		return nil
	}
	out := make(map[string]storagev1beta1.ThinPoolThresholds, len(in))
	for k, v := range in {
		out[k] = thresholdsToBeta(v)
	}
	return out
}

func tierOverridesFromBeta(in map[string]storagev1beta1.ThinPoolThresholds) map[string]ThinPoolThresholds {
	if in == nil {
		return nil
	}
	out := make(map[string]ThinPoolThresholds, len(in))
	for k, v := range in {
		out[k] = thresholdsFromBeta(v)
	}
	return out
}
