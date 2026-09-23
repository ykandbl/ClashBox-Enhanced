package main

import (
	"context"
	"fmt"
	"math"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/http"
	C "github.com/metacubex/mihomo/constant"
)

const (
	sustainedWarmupTime     = 1 * time.Second
	sustainedMinimumTime    = 4 * time.Second
	sustainedMaximumTime    = 5500 * time.Millisecond
	sustainedTargetSample   = 1300 * time.Millisecond
	sustainedMinimumSample  = 650 * time.Millisecond
	sustainedRequestTimeout = 8 * time.Second
	sustainedTotalTimeout   = 60 * time.Second
	sustainedMinimumSamples = 3
	sustainedCVLimit        = 15
)

type sustainedDirection struct {
	Samples   []nodeTransferProbe
	Traffic   int64
	WarmupMs  int64
	ErrorCode string
}

// Both modes use the same endpoints, HTTP/1.1 transport and full-payload
// acknowledgement rules. Only concurrency differs. Never infer capacity from
// the small warm-up requests or from bytes merely buffered for upload.
func qualitySustainedBandwidth(client *http.Client, concurrency int, proxy C.Proxy) nodeQualityResult {
	ctx := beginSustainedProgress(concurrency)
	defer finishSustainedProgress()
	var target *sustainedTarget
	var down, up sustainedDirection
	var retryTraffic int64
	primaryDiagnostic := ""
	for attempt := 0; attempt < 2; attempt++ {
		var err error
		target, err = discoverSustainedTarget(ctx, client, proxy)
		if err != nil {
			if ctx.Err() != nil {
				return nodeQualityResult{Status: "failed", ErrorCode: "cancelled", Diagnostic: "测速已停止，本次未生成带宽结果"}
			}
			primaryDiagnostic = "主测速源：服务器发现失败"
			break
		}
		setSustainedProgressTarget(target.Label)
		down = sustainedDirectionCheck(ctx, client, http.MethodGet, concurrency, target)
		up = sustainedDirection{}
		if ctx.Err() == nil && down.ErrorCode == "" {
			// Large-image servers commonly close their download-side keep-alive.
			// Start upload from a known-fresh connection, then reuse it for the
			// server-compatible upload chunks.
			client.CloseIdleConnections()
			up = sustainedDirectionCheck(ctx, client, http.MethodPost, concurrency, target)
		}
		if ctx.Err() == nil && (down.ErrorCode != "" || up.ErrorCode != "") && attempt == 0 {
			// A public server can pass the small bidirectional validation and then
			// close a formal large sample, while a persisted server may disappear
			// or be unreachable from another subscription. In either case discard
			// it and transparently discover a fresh target in this same test.
			retryTraffic += down.Traffic + up.Traffic
			invalidateSustainedTarget(target)
			client.CloseIdleConnections()
			continue
		}
		break
	}
	primaryError := firstSustainedError(down, up)
	if primaryDiagnostic == "" && primaryError != "" {
		primaryDiagnostic = "主测速源：" + primaryError
	}
	if ctx.Err() == nil && (primaryDiagnostic != "" || primaryError != "") {
		// speedtest.net 测速点可能被某个节点的出口策略拒绝。使用独立的
		// Cloudflare 完整载荷端点复核，避免把“测速点不兼容”误判为节点故障。
		retryTraffic += down.Traffic + up.Traffic
		if target != nil {
			invalidateSustainedTarget(target)
		}
		client.CloseIdleConnections()
		setSustainedProgressTarget("Cloudflare 备用测速源")
		down = sustainedDirectionCheck(ctx, client, http.MethodGet, concurrency, nil)
		up = sustainedDirection{}
		if ctx.Err() == nil && down.ErrorCode == "" {
			client.CloseIdleConnections()
			up = sustainedDirectionCheck(ctx, client, http.MethodPost, concurrency, nil)
		}
		return buildSustainedResult(concurrency, down, up, retryTraffic,
			"Cloudflare 备用测速源", primaryDiagnostic)
	}
	return buildSustainedResult(concurrency, down, up, retryTraffic, "固定主测速源", "")
}

func firstSustainedError(down, up sustainedDirection) string {
	if down.ErrorCode != "" {
		return down.ErrorCode
	}
	return up.ErrorCode
}

func buildSustainedResult(concurrency int, down, up sustainedDirection, retryTraffic int64,
	source, prelude string) nodeQualityResult {
	dc, uc := sustainedCV(down.Samples), sustainedCV(up.Samples)
	result := nodeQualityResult{
		Status: "failed", Quality: "样本未完成", DownloadMbps: sustainedMean(down.Samples),
		UploadMbps: sustainedMean(up.Samples), TransferredBytes: retryTraffic + down.Traffic + up.Traffic,
		DownloadVariation: dc, UploadVariation: uc, ErrorCode: down.ErrorCode,
	}
	if result.ErrorCode == "" {
		result.ErrorCode = up.ErrorCode
	}
	if result.ErrorCode == "" && (!sustainedEnough(down.Samples) || !sustainedEnough(up.Samples)) {
		result.ErrorCode = "incomplete"
	}
	if result.ErrorCode == "" {
		result.Status = "ok"
		result.Reliable = sustainedStable(down.Samples) && sustainedStable(up.Samples)
		result.Quality = "波动较大，仅供参考"
		if result.Reliable {
			result.Quality = "样本稳定"
		}
		if prelude != "" {
			result.Quality += " · 备用源复核"
		}
	}
	valid, total := 0, 0
	for _, d := range []sustainedDirection{down, up} {
		for _, p := range d.Samples {
			total += p.TotalStreams
			valid += p.ValidStreams
		}
	}
	if total > 0 {
		result.SuccessRate = valid * 100 / total
	}
	prefix := ""
	if prelude != "" {
		prefix = prelude + "；已用独立备用源复核。\n"
	}
	result.Diagnostic = prefix + fmt.Sprintf("持续传输 v2 · %d连接 · %s · 完整载荷/实际耗时\n%s\n%s\n仅代表本次到该测试点的吞吐，不是所有平台的固定速度。",
		concurrency, source, sustainedDiagnostic("下载", down), sustainedDiagnostic("上传", up))
	return result
}

func sustainedDirectionCheck(ctx context.Context, client *http.Client, method string, concurrency int, target *sustainedTarget) sustainedDirection {
	result := sustainedDirection{}
	size := 100_000
	started := time.Now()
	// Warm persistent connections and increase the payload adaptively. None of
	// these samples can enter the published throughput average.
	for {
		setSustainedProgressPhase(method, false, 0, 0)
		probe := sustainedParallel(ctx, client, method, size, concurrency, target)
		result.Traffic += probe.TransferredBytes
		addSustainedProgress(method, false, probe, 0, 0)
		if !probe.Success {
			result.ErrorCode = probe.ErrorCode
			return result
		}
		size = sustainedNextSize(probe, concurrency, method)
		if time.Since(started) >= sustainedWarmupTime {
			break
		}
	}
	result.WarmupMs = time.Since(started).Milliseconds()
	measuredAt := time.Now()
	for ctx.Err() == nil && time.Since(measuredAt) < sustainedMaximumTime {
		setSustainedProgressPhase(method, true, len(result.Samples), sustainedMean(result.Samples))
		probe := sustainedParallel(ctx, client, method, size, concurrency, target)
		result.Traffic += probe.TransferredBytes
		if !probe.Success {
			result.Samples = append(result.Samples, probe)
			result.ErrorCode = probe.ErrorCode
			return result
		}
		if time.Duration(probe.ElapsedMs)*time.Millisecond >= sustainedMinimumSample {
			result.Samples = append(result.Samples, probe)
		}
		addSustainedProgress(method, true, probe, len(result.Samples), sustainedMean(result.Samples))
		size = sustainedNextSize(probe, concurrency, method)
		// Keep a node-comparison run bounded and predictable. Once we have the
		// required complete payloads and measured time, publish their weighted
		// result. Variation still controls the reliability label; it must not
		// silently stretch an everyday 10–15 second test into a long benchmark.
		if sustainedEnough(result.Samples) {
			return result
		}
	}
	if ctx.Err() != nil {
		result.ErrorCode = "cancelled"
		if ctx.Err() == context.DeadlineExceeded {
			result.ErrorCode = "timeout"
		}
	}
	return result
}

func sustainedParallel(parent context.Context, client *http.Client, method string, size, concurrency int, targets ...*sustainedTarget) nodeTransferProbe {
	ctx, cancel := context.WithTimeout(parent, sustainedRequestTimeout)
	defer cancel()
	started := time.Now()
	probes := make([]nodeTransferProbe, concurrency)
	var wg sync.WaitGroup
	for i := range probes {
		wg.Add(1)
		go func(index int) {
			defer wg.Done()
			if len(targets) > 0 && targets[0] != nil {
				probes[index] = targets[0].transfer(ctx, client, method, size)
				return
			}
			probes[index] = qualityTransferContext(client, method, size, ctx)
			if probes[index].Success && probes[index].PayloadBytes != int64(size) {
				probes[index].Success = false
				probes[index].ErrorCode = "incomplete"
			}
		}(i)
	}
	wg.Wait()
	return aggregateTransferProbes(probes, time.Since(started), true)
}

func sustainedNextSize(probe nodeTransferProbe, concurrency int, method string) int {
	if probe.ElapsedMs <= 0 || concurrency < 1 {
		return 1_000_000
	}
	size := int(float64(probe.PayloadBytes) / float64(concurrency) * float64(sustainedTargetSample.Milliseconds()) / float64(probe.ElapsedMs))
	minimum, maximum := 1_000_000, 250_000_000
	if method == http.MethodPost {
		maximum = 50_000_000
	}
	if size < minimum {
		size = minimum
	}
	if size > maximum {
		size = maximum
	}
	return size
}

func sustainedMean(probes []nodeTransferProbe) float64 {
	var bytes, milliseconds int64
	for _, p := range probes {
		if p.Success {
			bytes += p.PayloadBytes
			milliseconds += p.ElapsedMs
		}
	}
	return roundMbps(bytesPerSecondMbps(bytes, milliseconds))
}

func sustainedEnough(probes []nodeTransferProbe) bool {
	count := 0
	var elapsed int64
	for _, p := range probes {
		if !p.Success {
			return false
		}
		if time.Duration(p.ElapsedMs)*time.Millisecond < sustainedMinimumSample {
			return false
		}
		elapsed += p.ElapsedMs
		count++
	}
	return count >= sustainedMinimumSamples && time.Duration(elapsed)*time.Millisecond >= sustainedMinimumTime
}

func sustainedCV(probes []nodeTransferProbe) int {
	if len(probes) < sustainedMinimumSamples {
		return 100
	}
	last := probes[len(probes)-sustainedMinimumSamples:]
	mean := sustainedMean(last)
	if mean <= 0 {
		return 100
	}
	var variance float64
	for _, p := range last {
		if !p.Success {
			return 100
		}
		difference := p.SpeedMbps - mean
		variance += difference * difference
	}
	return int(math.Round(math.Sqrt(variance/float64(len(last))) / mean * 100))
}

func sustainedStable(probes []nodeTransferProbe) bool {
	if !sustainedEnough(probes) || sustainedCV(probes) > sustainedCVLimit {
		return false
	}
	last := probes[len(probes)-sustainedMinimumSamples:]
	mean := sustainedMean(probes)
	if mean <= 0 {
		return false
	}
	// Reject a run that is still ramping: the final block and both halves must
	// agree with the complete post-warmup average, not just have a short plateau.
	for _, block := range [][]nodeTransferProbe{last, probes[:len(probes)/2], probes[len(probes)/2:]} {
		if math.Abs(sustainedMean(block)-mean)/mean > 0.15 {
			return false
		}
	}
	return true
}

func sustainedDiagnostic(label string, d sustainedDirection) string {
	var elapsed int64
	points := []string{}
	endpoints := []string{}
	for _, p := range d.Samples {
		elapsed += p.ElapsedMs
		if p.Success {
			points = append(points, fmt.Sprintf("%.1f", p.SpeedMbps))
		}
		if p.Endpoint != "" && !strings.Contains(strings.Join(endpoints, "/"), p.Endpoint) {
			endpoints = append(endpoints, p.Endpoint)
		}
	}
	message := fmt.Sprintf("%s：预热%.1fs；有效采样%.1fs / %d段；末%d段CV %d%%；%s",
		label, float64(d.WarmupMs)/1000, float64(elapsed)/1000, len(d.Samples), sustainedMinimumSamples, sustainedCV(d.Samples),
		map[bool]string{true: "样本稳定", false: "样本不足或波动大"}[sustainedStable(d.Samples)])
	if d.ErrorCode != "" {
		message += "；" + d.ErrorCode
	}
	message += "\n样本Mbps：" + strings.Join(points, " / ") + "；测试点：" + strings.Join(endpoints, "/")
	return message
}
