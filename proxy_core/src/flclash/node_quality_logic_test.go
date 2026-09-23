package main

import (
	"context"
	"errors"
	"io"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/showwin/speedtest-go/speedtest"
)

type qualityFixtureTransport func(*http.Request) (*http.Response, error)

func (transport qualityFixtureTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return transport(request)
}

type qualityDeadlineBody struct{ count int }

func (body *qualityDeadlineBody) Read(buffer []byte) (int, error) {
	if body.count > 0 {
		return 0, context.DeadlineExceeded
	}
	body.count++
	return copy(buffer, "partial download"), nil
}
func (*qualityDeadlineBody) Close() error { return nil }

type qualityRateLimiter struct {
	mu             sync.Mutex
	next           time.Time
	bytesPerSecond float64
}

func (limiter *qualityRateLimiter) wait(bytes int) {
	limiter.mu.Lock()
	start := limiter.next
	if start.IsZero() {
		start = time.Now()
	}
	duration := time.Duration(float64(bytes) / limiter.bytesPerSecond * float64(time.Second))
	limiter.next = start.Add(duration)
	finish := limiter.next
	limiter.mu.Unlock()
	time.Sleep(time.Until(finish))
}

type qualityRateLimitedBody struct {
	remaining int
	limiter   *qualityRateLimiter
}

func (body *qualityRateLimitedBody) Read(buffer []byte) (int, error) {
	if body.remaining <= 0 {
		return 0, io.EOF
	}
	count := len(buffer)
	if count > body.remaining {
		count = body.remaining
	}
	body.limiter.wait(count)
	for index := 0; index < count; index++ {
		buffer[index] = 0
	}
	body.remaining -= count
	return count, nil
}
func (*qualityRateLimitedBody) Close() error { return nil }

type qualityThrottledRequestBody struct {
	source  io.ReadCloser
	limiter *qualityRateLimiter
}

func (body *qualityThrottledRequestBody) Read(buffer []byte) (int, error) {
	count, err := body.source.Read(buffer)
	if count > 0 {
		body.limiter.wait(count)
	}
	return count, err
}
func (body *qualityThrottledRequestBody) Close() error { return body.source.Close() }

func qualityRateLimitedTransport(mbps float64) qualityFixtureTransport {
	limiter := &qualityRateLimiter{bytesPerSecond: mbps * 1_000_000 / 8}
	return func(req *http.Request) (*http.Response, error) {
		if req.Method == http.MethodPost {
			throttled := &qualityThrottledRequestBody{source: req.Body, limiter: limiter}
			_, err := io.Copy(io.Discard, throttled)
			if err != nil {
				return nil, err
			}
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(""))}, nil
		}
		size, err := strconv.Atoi(req.URL.Query().Get("bytes"))
		if err != nil || size <= 0 {
			return &http.Response{StatusCode: 400, Body: io.NopCloser(strings.NewReader("bad size"))}, nil
		}
		return &http.Response{StatusCode: 200,
			Body: &qualityRateLimitedBody{remaining: size, limiter: limiter}}, nil
	}
}

func TestQualityTransferRejectsHTTPErrorPayloadAndTracksTraffic(t *testing.T) {
	client := &http.Client{Transport: qualityFixtureTransport(func(req *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 403, Body: io.NopCloser(strings.NewReader("denied"))}, nil
	})}
	probe := qualityTransfer(client, http.MethodGet, 6)
	if probe.Success || probe.PayloadBytes != 0 || probe.TransferredBytes != 6 || probe.ErrorCode != "http_403" {
		t.Fatalf("error page counted as download: %#v", probe)
	}
}

func TestQualityUploadRequiresAcknowledgementAndExactLength(t *testing.T) {
	client := &http.Client{Transport: qualityFixtureTransport(func(req *http.Request) (*http.Response, error) {
		if req.ContentLength != 4096 {
			t.Errorf("content length = %d", req.ContentLength)
		}
		_, _ = io.Copy(io.Discard, req.Body)
		return nil, errors.New("fixture disconnected before acknowledgement")
	})}
	probe := qualityTransfer(client, http.MethodPost, 4096)
	if probe.Success || probe.PayloadBytes != 0 || probe.TransferredBytes != 4096 {
		t.Fatalf("unacknowledged upload counted as throughput: %#v", probe)
	}
}

func TestQualityDownloadRetainsRealPartialBytesAtDeadline(t *testing.T) {
	client := &http.Client{Transport: qualityFixtureTransport(func(req *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: &qualityDeadlineBody{}}, nil
	})}
	probe := qualityTransfer(client, http.MethodGet, 4096)
	if probe.Success || probe.PayloadBytes != 16 || probe.TransferredBytes != 16 {
		t.Fatalf("partial download lost: %#v", probe)
	}
}

func TestNodeQualityModes(t *testing.T) {
	for _, mode := range []string{
		"stability", "bandwidth", "bandwidth_economy", "bandwidth_standard", "bandwidth_full", "bandwidth_peak",
	} {
		if !isNodeQualityMode(mode) {
			t.Fatalf("mode %s should be accepted", mode)
		}
	}
	if isNodeQualityMode("fixture") {
		t.Fatal("unknown mode should be rejected")
	}
}

func TestPeakSpeedtestPinnedSettings(t *testing.T) {
	if speedtest.Version() != "1.8.0" {
		t.Fatalf("unexpected speedtest-go version %s", speedtest.Version())
	}
	if peakSpeedtestConnections != 8 || peakSpeedtestDuration != 15*time.Second ||
		peakSpeedtestTimeout != 70*time.Second {
		t.Fatalf("unexpected peak settings: %d %v %v", peakSpeedtestConnections,
			peakSpeedtestDuration, peakSpeedtestTimeout)
	}
}

func TestBandwidthPlansKeepManualFourStreamsAndEconomyTwoStreams(t *testing.T) {
	if qualityBandwidthConcurrency != 4 {
		t.Fatalf("bandwidth concurrency = %d", qualityBandwidthConcurrency)
	}
	if qualityEconomyConcurrency != 2 {
		t.Fatalf("economy concurrency = %d", qualityEconomyConcurrency)
	}
	economy := bandwidthPlan("bandwidth_economy")
	standard := bandwidthPlan("bandwidth_standard")
	full := bandwidthPlan("bandwidth_full")
	if economy.SampleCount != 2 || standard.SampleCount != 2 || full.SampleCount != 3 {
		t.Fatalf("unexpected sample counts: %#v %#v %#v", economy, standard, full)
	}
	if economy.MinimumDownloadBytes != 2_000_000 || economy.MinimumUploadBytes != 2_000_000 ||
		standard.MinimumDownloadBytes != 25_000_000 || standard.MinimumUploadBytes != 10_000_000 ||
		full.MinimumDownloadBytes != 25_000_000 || full.MinimumUploadBytes != 10_000_000 {
		t.Fatalf("minimum payload floors are wrong: %#v %#v %#v", economy, standard, full)
	}
	if economy.MinimumSampleDuration >= standard.MinimumSampleDuration ||
		standard.MinimumSampleDuration != full.MinimumSampleDuration {
		t.Fatalf("sample durations are wrong: %#v %#v %#v", economy, standard, full)
	}
}

func TestQualityPayloadReaderTracksActualBytesWithoutAllocation(t *testing.T) {
	reader := &qualityPayloadReader{remaining: 10}
	buffer := make([]byte, 6)
	if count, err := reader.Read(buffer); count != 6 || err != nil {
		t.Fatalf("first read = %d, %v", count, err)
	}
	if count, err := reader.Read(buffer); count != 4 || err != nil {
		t.Fatalf("second read = %d, %v", count, err)
	}
	if count, err := reader.Read(buffer); count != 0 || err != io.EOF {
		t.Fatalf("final read = %d, %v", count, err)
	}
	if reader.read.Load() != 10 {
		t.Fatalf("tracked %d bytes", reader.read.Load())
	}
}

func TestAggregateParallelThroughputUsesWallTimeAndTotalPayload(t *testing.T) {
	result := aggregateTransferProbes([]nodeTransferProbe{
		{Success: true, PayloadBytes: 10_000_000, TransferredBytes: 10_000_100},
		{Success: true, PayloadBytes: 20_000_000, TransferredBytes: 20_000_100},
	}, time.Second, true)
	if !result.Success || result.SpeedMbps != 240 {
		t.Fatalf("aggregate = %#v", result)
	}
	if result.TransferredBytes != 30_000_200 {
		t.Fatalf("transferred = %d", result.TransferredBytes)
	}
	failed := aggregateTransferProbes([]nodeTransferProbe{
		{Success: true, PayloadBytes: 10}, {Success: false, ErrorCode: "tls"},
	}, time.Second, true)
	if failed.Success || failed.ErrorCode != "tls" {
		t.Fatalf("failed aggregate = %#v", failed)
	}
	tolerant := aggregateTransferProbes([]nodeTransferProbe{
		{Success: true, PayloadBytes: 10_000_000}, {Success: false, ErrorCode: "timeout"},
	}, time.Second, false)
	if !tolerant.Success || tolerant.SpeedMbps != 80 {
		t.Fatalf("tolerant aggregate = %#v", tolerant)
	}
	if tolerant.TotalStreams != 2 || tolerant.ValidStreams != 1 || tolerant.ErrorCode != "timeout" {
		t.Fatalf("partial failures must remain observable: %#v", tolerant)
	}
}

func TestRateControlledParallelMeasurementMatchesKnownBandwidth(t *testing.T) {
	client := &http.Client{Transport: qualityRateLimitedTransport(80)}
	probe := qualityParallelTransfer(client, http.MethodGet, 1_000_000, 4)
	if !probe.Success {
		t.Fatalf("rate-controlled transfer failed: %#v", probe)
	}
	if probe.SpeedMbps < 77 || probe.SpeedMbps > 82 {
		t.Fatalf("measured %.2f Mbps on an 80 Mbps fixture", probe.SpeedMbps)
	}
}

func TestAdaptiveDirectionRepeatsACompleteLongEnoughSample(t *testing.T) {
	client := &http.Client{Transport: qualityRateLimitedTransport(80)}
	result := qualityAdaptiveDirection(client, http.MethodGet, []int{1_000_000, 2_000_000},
		qualityBandwidthPlan{MinimumSampleDuration: 300 * time.Millisecond, SampleCount: 2}, 2_000_000)
	if len(result.Probes) != 2 || !result.Probes[0].Success || !result.Probes[1].Success {
		t.Fatalf("adaptive probes = %#v", result)
	}
	for _, probe := range result.Probes {
		if probe.ElapsedMs < 700 || probe.PayloadBytes != 8_000_000 ||
			probe.SpeedMbps < 77 || probe.SpeedMbps > 82 {
			t.Fatalf("adaptive sample not calibrated: %#v", probe)
		}
	}
	if result.OverheadBytes < 4_400_000 {
		t.Fatalf("warmup and undersized ramp-up traffic were not counted: %#v", result)
	}
	if variation := speedVariationPercent(successfulProbeSpeeds(result.Probes)); variation > 3 {
		t.Fatalf("stable rate fixture reported %d%% variation", variation)
	}
}

func TestEconomyDirectionUsesBoundedLightSamples(t *testing.T) {
	client := &http.Client{Transport: qualityRateLimitedTransport(80)}
	plan := bandwidthPlan("bandwidth_economy")
	result := qualityAdaptiveDirection(client, http.MethodGet, qualityEconomyDownloadSizes,
		plan, plan.MinimumDownloadBytes, qualityEconomyConcurrency)
	if len(result.Probes) != 2 || !result.Probes[0].Success || !result.Probes[1].Success {
		t.Fatalf("economy probes = %#v", result)
	}
	for _, probe := range result.Probes {
		if probe.PayloadBytes != 4_000_000 || probe.TransferredBytes != 4_000_000 {
			t.Fatalf("economy sample payload = %#v", probe)
		}
	}
	if result.OverheadBytes <= 0 || result.OverheadBytes >= 1_500_000 {
		t.Fatalf("economy overhead is not bounded: %d", result.OverheadBytes)
	}
}

func TestVariationAndPercentileExposeUnstableSamples(t *testing.T) {
	values := []float64{80, 100, 120}
	if variation := speedVariationPercent(values); variation != 40 {
		t.Fatalf("variation = %d", variation)
	}
	if percentile := percentileFloat(values, 0.9); percentile != 116 {
		t.Fatalf("p90 = %v", percentile)
	}
}
