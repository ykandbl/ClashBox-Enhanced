package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/ca"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

const (
	qualityKiB                  = 1024
	qualityMiB                  = 1024 * 1024
	qualityBandwidthConcurrency = 4
	qualityEconomyConcurrency   = 2
	qualityWarmupBytes          = 100_000
	qualityTransferTimeout      = 90 * time.Second
	qualityEconomyTimeout       = 15 * time.Second
	qualityScreeningTimeout     = 8 * time.Second
	qualityReliableVariation    = 25
)

var qualityDownloadSizes = []int{1_000_000, 5_000_000, 10_000_000, 25_000_000, 100_000_000}
var qualityUploadSizes = []int{1_000_000, 5_000_000, 10_000_000, 25_000_000, 50_000_000}
var qualityEconomyDownloadSizes = []int{512_000, 2_000_000}
var qualityEconomyUploadSizes = []int{512_000, 2_000_000}

type nodeQualityParams struct {
	ProxyName string `json:"proxy-name"`
	Mode      string `json:"mode"`
}

type nodeTransferProbe struct {
	Endpoint         string
	Success          bool
	ElapsedMs        int64
	SpeedMbps        float64
	TransferredBytes int64
	PayloadBytes     int64
	ErrorCode        string
	TotalStreams     int
	ValidStreams     int
}

type qualityPayloadReader struct {
	remaining int64
	read      atomic.Int64
	total     *atomic.Int64
}

func (reader *qualityPayloadReader) Read(buffer []byte) (int, error) {
	if reader.remaining <= 0 {
		return 0, io.EOF
	}
	length := len(buffer)
	if int64(length) > reader.remaining {
		length = int(reader.remaining)
	}
	for index := 0; index < length; index++ {
		buffer[index] = 0
	}
	reader.remaining -= int64(length)
	reader.read.Add(int64(length))
	trackSustainedBytes(int64(length))
	if reader.total != nil {
		reader.total.Add(int64(length))
	}
	return length, nil
}

type nodeQualityResult struct {
	Status            string  `json:"status"`
	Quality           string  `json:"quality"`
	LatencyMs         int64   `json:"latencyMs"`
	JitterMs          int64   `json:"jitterMs"`
	SuccessRate       int     `json:"successRate"`
	DownloadMbps      float64 `json:"downloadMbps"`
	UploadMbps        float64 `json:"uploadMbps"`
	TransferredBytes  int64   `json:"transferredBytes"`
	ErrorCode         string  `json:"errorCode"`
	Diagnostic        string  `json:"diagnostic"`
	Reliable          bool    `json:"reliable"`
	DownloadVariation int     `json:"downloadVariationPercent"`
	UploadVariation   int     `json:"uploadVariationPercent"`
}

type qualityBandwidthPlan struct {
	MinimumSampleDuration time.Duration
	SampleCount           int
	MinimumDownloadBytes  int
	MinimumUploadBytes    int
}

type qualityDirectionResult struct {
	OverheadBytes int64
	Probes        []nodeTransferProbe
}

func handleNodeQualityCheck(paramsString string) string {
	params := nodeQualityParams{}
	if err := json.Unmarshal([]byte(paramsString), &params); err != nil {
		return marshalNodeQualityError("invalid")
	}
	if !isNodeQualityMode(params.Mode) {
		return marshalNodeQualityError("invalid")
	}
	proxy := tunnel.Proxies()[params.ProxyName]
	if proxy == nil {
		return marshalNodeQualityError("missing")
	}
	if params.Mode == "bandwidth_peak" {
		result := qualityPeakSpeedtest(proxy)
		data, _ := json.Marshal(result)
		return string(data)
	}

	tlsConfig, err := ca.GetTLSConfig(ca.Option{})
	if err != nil {
		return marshalNodeQualityError("tls")
	}
	if params.Mode == "bandwidth_single_sustained" || params.Mode == "bandwidth_multi_sustained" {
		// A single HTTP/2 connection could otherwise multiplex all eight tasks.
		tlsConfig.NextProtos = []string{"http/1.1"}
	}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
			metadata := &C.Metadata{NetWork: C.TCP}
			if err := metadata.SetRemoteAddress(address); err != nil {
				return nil, err
			}
			return proxy.DialContext(ctx, metadata)
		},
		MaxIdleConns:          8,
		MaxIdleConnsPerHost:   8,
		IdleConnTimeout:       15 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: time.Second,
		TLSClientConfig:       tlsConfig,
		DisableCompression:    true,
	}
	clientTimeout := qualityTransferTimeout
	if params.Mode == "stability" {
		// Screening is deliberately short and fail-fast. Final single/multi
		// connection tests retain the full 90-second transfer window.
		clientTimeout = qualityScreeningTimeout
	} else if params.Mode == "bandwidth_economy" || params.Mode == "bandwidth" {
		// The daily quick test uses small adaptive samples. Keep one bad node
		// from occupying a candidate slot for the full sustained-test window.
		clientTimeout = qualityEconomyTimeout
	}
	client := &http.Client{Timeout: clientTimeout, Transport: transport}
	defer client.CloseIdleConnections()
	if params.Mode == "bandwidth_single_sustained" || params.Mode == "bandwidth_multi_sustained" {
		concurrency := 1
		if params.Mode == "bandwidth_multi_sustained" {
			concurrency = 8
		}
		result := qualitySustainedBandwidth(client, concurrency, proxy)
		data, _ := json.Marshal(result)
		return string(data)
	}

	delays := make([]int64, 0, 3)
	expectedStatus, _ := utils.NewUnsignedRanges[uint16]("")
	for i := 0; i < 3; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		delay, delayErr := proxy.URLTest(ctx, C.DefaultTestURL, expectedStatus)
		cancel()
		if delayErr == nil && delay > 0 {
			delays = append(delays, int64(delay))
		}
	}

	mode := params.Mode
	if mode == "bandwidth" {
		mode = "bandwidth_economy"
	}
	warmupBytes := int64(0)
	downloadProbes := make([]nodeTransferProbe, 0, 3)
	uploadProbes := make([]nodeTransferProbe, 0, 2)
	if isBandwidthMode(mode) {
		plan := bandwidthPlan(mode)
		downSizes, upSizes := qualityDownloadSizes, qualityUploadSizes
		if mode == "bandwidth_economy" {
			downSizes, upSizes = qualityEconomyDownloadSizes, qualityEconomyUploadSizes
		}
		concurrency := qualityBandwidthConcurrency
		if mode == "bandwidth_economy" {
			// The daily one-click flow prioritizes quick feedback and bounded
			// traffic. Keep the sustained/manual tiers at four streams, while
			// the economy tier uses two streams and smaller complete samples.
			concurrency = qualityEconomyConcurrency
		}
		down := qualityAdaptiveDirection(client, http.MethodGet, downSizes,
			plan, plan.MinimumDownloadBytes, concurrency)
		up := qualityAdaptiveDirection(client, http.MethodPost, upSizes,
			plan, plan.MinimumUploadBytes, concurrency)
		warmupBytes = down.OverheadBytes + up.OverheadBytes
		downloadProbes = down.Probes
		uploadProbes = up.Probes
	} else {
		for _, size := range []int{192 * qualityKiB, 192 * qualityKiB, 192 * qualityKiB} {
			probe := qualityScreeningTransfer(client, http.MethodGet, size)
			downloadProbes = append(downloadProbes, probe)
			// A failed screening download cannot become a final candidate. Stop
			// immediately instead of paying two more timeout windows.
			if !probe.Success {
				break
			}
		}
		if len(downloadProbes) == 3 && downloadProbes[2].Success {
			for _, size := range []int{32 * qualityKiB, 32 * qualityKiB} {
				probe := qualityScreeningTransfer(client, http.MethodPost, size)
				uploadProbes = append(uploadProbes, probe)
				if !probe.Success {
					break
				}
			}
		}
	}

	downloadSpeeds := successfulProbeSpeeds(downloadProbes)
	uploadSpeeds := successfulProbeSpeeds(uploadProbes)
	downloadVariation := speedVariationPercent(downloadSpeeds)
	uploadVariation := speedVariationPercent(uploadSpeeds)
	probes := make([]nodeTransferProbe, 0, len(downloadProbes)+len(uploadProbes))
	probes = append(probes, downloadProbes...)
	probes = append(probes, uploadProbes...)
	if len(probes) == 0 {
		return marshalNodeQualityError("invalid")
	}

	result := nodeQualityResult{
		Status:            "failed",
		Quality:           "异常",
		LatencyMs:         medianInt64(delays),
		JitterMs:          spreadInt64(delays),
		DownloadMbps:      roundMbps(percentileFloat(downloadSpeeds, 0.9)),
		UploadMbps:        roundMbps(percentileFloat(uploadSpeeds, 0.9)),
		TransferredBytes:  warmupBytes,
		DownloadVariation: downloadVariation,
		UploadVariation:   uploadVariation,
	}
	successes, attempts := 0, 0
	for _, probe := range probes {
		result.TransferredBytes += probe.TransferredBytes
		if probe.TotalStreams > 0 {
			attempts += probe.TotalStreams
			successes += probe.ValidStreams
		} else {
			attempts++
			if probe.Success {
				successes++
			}
		}
		if probe.ErrorCode != "" && result.ErrorCode == "" {
			result.ErrorCode = probe.ErrorCode
		}
	}
	if attempts > 0 {
		result.SuccessRate = successes * 100 / attempts
	}
	result.Diagnostic = transferDiagnostic("下载", downloadProbes, downloadVariation) + "；" +
		transferDiagnostic("上传", uploadProbes, uploadVariation)
	if result.SuccessRate == 100 && result.DownloadMbps > 0 && result.UploadMbps > 0 {
		result.Status = "ok"
		result.ErrorCode = ""
		result.Reliable = !isBandwidthMode(mode) ||
			(len(downloadSpeeds) >= 2 && len(uploadSpeeds) >= 2 &&
				downloadVariation <= qualityReliableVariation && uploadVariation <= qualityReliableVariation)
		if isBandwidthMode(mode) {
			result.Quality = "速度波动较大，仅供参考"
			if result.Reliable {
				result.Quality = "样本一致"
			}
		} else {
			result.Quality = "波动"
			if len(delays) == 3 && result.JitterMs <= 150 {
				result.Quality = "稳定"
			}
		}
	}
	data, _ := json.Marshal(result)
	return string(data)
}

func qualityTransfer(client *http.Client, method string, expectedBytes int) nodeTransferProbe {
	ctx, cancel := context.WithTimeout(context.Background(), qualityTransferTimeout)
	defer cancel()
	return qualityTransferContext(client, method, expectedBytes, ctx)
}

func qualityScreeningTransfer(client *http.Client, method string, expectedBytes int) nodeTransferProbe {
	ctx, cancel := context.WithTimeout(context.Background(), qualityScreeningTimeout)
	defer cancel()
	return qualityTransferContext(client, method, expectedBytes, ctx)
}

func bandwidthPlan(mode string) qualityBandwidthPlan {
	switch mode {
	case "bandwidth_standard":
		return qualityBandwidthPlan{MinimumSampleDuration: 1800 * time.Millisecond, SampleCount: 2,
			MinimumDownloadBytes: 25_000_000, MinimumUploadBytes: 10_000_000}
	case "bandwidth_full":
		return qualityBandwidthPlan{MinimumSampleDuration: 1800 * time.Millisecond, SampleCount: 3,
			MinimumDownloadBytes: 25_000_000, MinimumUploadBytes: 10_000_000}
	case "bandwidth_economy":
		return qualityBandwidthPlan{MinimumSampleDuration: 500 * time.Millisecond, SampleCount: 2,
			MinimumDownloadBytes: 2_000_000, MinimumUploadBytes: 2_000_000}
	default:
		return qualityBandwidthPlan{MinimumSampleDuration: 750 * time.Millisecond, SampleCount: 2,
			MinimumDownloadBytes: 10_000_000, MinimumUploadBytes: 5_000_000}
	}
}

// qualityAdaptiveDirection warms the selected number of connections, then
// increases a complete request until the aggregate transfer lasts long enough
// for setup latency not to dominate. The selected size is repeated to expose
// variation. Manual tiers use four connections; the daily economy tier passes
// two to keep feedback fast and traffic bounded.
// Requests are never cancelled to manufacture a rate from partial uploads.
func qualityAdaptiveDirection(client *http.Client, method string, sizes []int,
	plan qualityBandwidthPlan, minimumBytes int, concurrency ...int) qualityDirectionResult {
	result := qualityDirectionResult{}
	workers := qualityBandwidthConcurrency
	if len(concurrency) > 0 && concurrency[0] > 0 {
		workers = concurrency[0]
	}
	warmup := qualityParallelTransfer(client, method, qualityWarmupBytes, workers)
	result.OverheadBytes += warmup.TransferredBytes
	if len(sizes) == 0 || plan.SampleCount < 2 {
		result.Probes = []nodeTransferProbe{{ErrorCode: "invalid"}}
		return result
	}
	for index, size := range sizes {
		probe := qualityParallelTransfer(client, method, size, workers)
		if !probe.Success {
			result.Probes = []nodeTransferProbe{probe}
			return result
		}
		lastSize := index == len(sizes)-1
		longEnough := time.Duration(probe.ElapsedMs)*time.Millisecond >= plan.MinimumSampleDuration
		largeEnough := size >= minimumBytes
		if (longEnough && largeEnough) || lastSize {
			result.Probes = append(result.Probes, probe)
			for len(result.Probes) < plan.SampleCount {
				result.Probes = append(result.Probes,
					qualityParallelTransfer(client, method, size, workers))
			}
			return result
		}
		// A short completed probe is a ramp-up cost, not a bandwidth sample.
		result.OverheadBytes += probe.TransferredBytes
	}
	result.Probes = []nodeTransferProbe{{ErrorCode: "incomplete"}}
	return result
}

func qualityTransferContext(client *http.Client, method string, expectedBytes int,
	ctx context.Context) nodeTransferProbe {
	probe := nodeTransferProbe{}
	url := "https://speed.cloudflare.com/__down?bytes=" + strconv.Itoa(expectedBytes) +
		"&nonce=" + strconv.FormatInt(time.Now().UnixNano(), 10)
	var body io.Reader
	var payloadReader *qualityPayloadReader
	if method == http.MethodPost {
		url = "https://speed.cloudflare.com/__up"
		payloadReader = &qualityPayloadReader{remaining: int64(expectedBytes)}
		body = payloadReader
	}
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		probe.ErrorCode = "invalid"
		return probe
	}
	req.Header.Set("User-Agent", "FireflyQuality/1.0")
	req.Header.Set("Cache-Control", "no-store")
	if method == http.MethodPost {
		req.Header.Set("Content-Type", "application/octet-stream")
		req.ContentLength = int64(expectedBytes)
	}
	started := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		probe.ElapsedMs = time.Since(started).Milliseconds()
		if payloadReader != nil {
			probe.TransferredBytes = payloadReader.read.Load()
		}
		probe.ErrorCode = delayRequestErrorCode(ctx, err)
		return probe
	}
	responseBytes, readErr := io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
	if ray := resp.Header.Get("CF-Ray"); ray != "" {
		parts := strings.Split(ray, "-")
		probe.Endpoint = parts[len(parts)-1]
	}
	probe.ElapsedMs = time.Since(started).Milliseconds()
	statusOK := resp.StatusCode >= 200 && resp.StatusCode < 300
	payloadBytes := responseBytes
	if payloadReader != nil {
		payloadBytes = payloadReader.read.Load()
	}
	contentOK := payloadBytes >= int64(expectedBytes*98/100)
	probe.Success = statusOK && contentOK && readErr == nil
	// Only a valid download response or acknowledged upload contributes to
	// throughput. Error pages and unacknowledged buffered writes are traffic,
	// not successful transfer payload.
	if statusOK && (method == http.MethodGet || probe.Success) {
		probe.PayloadBytes = payloadBytes
	}
	if method == http.MethodPost {
		probe.TransferredBytes = payloadBytes + responseBytes
	} else {
		probe.TransferredBytes = responseBytes
	}
	if probe.Success {
		probe.SpeedMbps = bytesPerSecondMbps(payloadBytes, probe.ElapsedMs)
	}
	if !probe.Success {
		if readErr != nil {
			probe.ErrorCode = delayRequestErrorCode(ctx, readErr)
		} else if !statusOK {
			probe.ErrorCode = "http_" + strconv.Itoa(resp.StatusCode)
		} else {
			probe.ErrorCode = "incomplete"
		}
	}
	return probe
}

func qualityParallelTransfer(client *http.Client, method string, bytesPerWorker int,
	concurrency int) nodeTransferProbe {
	if concurrency <= 0 || bytesPerWorker <= 0 {
		return nodeTransferProbe{ErrorCode: "invalid"}
	}
	started := time.Now()
	results := make([]nodeTransferProbe, concurrency)
	var wait sync.WaitGroup
	for worker := 0; worker < concurrency; worker++ {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			results[index] = qualityTransfer(client, method, bytesPerWorker)
		}(worker)
	}
	wait.Wait()
	return aggregateTransferProbes(results, time.Since(started), true)
}

func aggregateTransferProbes(probes []nodeTransferProbe, elapsed time.Duration,
	requireAll bool) nodeTransferProbe {
	result := nodeTransferProbe{Success: len(probes) > 0, ElapsedMs: elapsed.Milliseconds(), TotalStreams: len(probes)}
	successes := 0
	for _, probe := range probes {
		if probe.Endpoint != "" && !strings.Contains(result.Endpoint, probe.Endpoint) {
			if result.Endpoint != "" {
				result.Endpoint += "/"
			}
			result.Endpoint += probe.Endpoint
		}
		result.PayloadBytes += probe.PayloadBytes
		result.TransferredBytes += probe.TransferredBytes
		if probe.Success {
			successes++
		} else if result.ErrorCode == "" {
			result.ErrorCode = probe.ErrorCode
		}
	}
	if requireAll {
		result.Success = successes == len(probes)
	} else {
		result.Success = successes > 0
	}
	result.ValidStreams = successes
	if result.Success && result.PayloadBytes > 0 {
		result.SpeedMbps = bytesPerSecondMbps(result.PayloadBytes, result.ElapsedMs)
	} else if result.ErrorCode == "" {
		result.ErrorCode = "incomplete"
	}
	return result
}

func transferDiagnostic(label string, probes []nodeTransferProbe, variation int) string {
	total, valid := 0, 0
	var elapsed int64
	var bytesPerConnection int64
	code := ""
	for _, probe := range probes {
		elapsed += probe.ElapsedMs
		if probe.TotalStreams > 0 {
			total += probe.TotalStreams
			valid += probe.ValidStreams
		} else {
			total++
			if probe.Success {
				valid++
			}
		}
		if code == "" {
			code = probe.ErrorCode
		}
		if bytesPerConnection == 0 && probe.TotalStreams > 0 && probe.PayloadBytes > 0 {
			bytesPerConnection = probe.PayloadBytes / int64(probe.TotalStreams)
		}
	}
	speeds := successfulProbeSpeeds(probes)
	minimum, maximum := float64(0), float64(0)
	if len(speeds) > 0 {
		minimum, maximum = speeds[0], speeds[0]
		for _, speed := range speeds[1:] {
			if speed < minimum {
				minimum = speed
			}
			if speed > maximum {
				maximum = speed
			}
		}
	}
	message := fmt.Sprintf("%s有效连接 %d/%d · 每连接%.0fMB · 样本%.1f–%.1fMbps · 波动%d%% · %.1fs",
		label, valid, total, float64(bytesPerConnection)/1_000_000,
		minimum, maximum, variation, float64(elapsed)/1000)
	if code != "" {
		message += " · " + code
	}
	return message
}

func successfulProbeSpeeds(probes []nodeTransferProbe) []float64 {
	speeds := make([]float64, 0, len(probes))
	for _, probe := range probes {
		if probe.Success && probe.SpeedMbps > 0 {
			speeds = append(speeds, probe.SpeedMbps)
		}
	}
	return speeds
}

func isNodeQualityMode(mode string) bool {
	switch mode {
	case "stability", "bandwidth", "bandwidth_economy", "bandwidth_standard", "bandwidth_full", "bandwidth_peak", "bandwidth_single_sustained", "bandwidth_multi_sustained":
		return true
	default:
		return false
	}
}

func isBandwidthMode(mode string) bool {
	return mode == "bandwidth" || mode == "bandwidth_economy" ||
		mode == "bandwidth_standard" || mode == "bandwidth_full" || mode == "bandwidth_peak" ||
		mode == "bandwidth_single_sustained" || mode == "bandwidth_multi_sustained"
}

func bytesPerSecondMbps(bytes int64, elapsedMs int64) float64 {
	if bytes <= 0 || elapsedMs <= 0 {
		return 0
	}
	return float64(bytes*8) / float64(elapsedMs) / 1000
}

func roundMbps(value float64) float64 {
	return float64(int(value*100+0.5)) / 100
}

func medianFloat(values []float64) float64 {
	if len(values) == 0 {
		return 0
	}
	values = append([]float64(nil), values...)
	sort.Float64s(values)
	middle := len(values) / 2
	if len(values)%2 == 0 {
		return (values[middle-1] + values[middle]) / 2
	}
	return values[middle]
}

func percentileFloat(values []float64, percentile float64) float64 {
	if len(values) == 0 {
		return 0
	}
	values = append([]float64(nil), values...)
	sort.Float64s(values)
	if percentile <= 0 {
		return values[0]
	}
	if percentile >= 1 {
		return values[len(values)-1]
	}
	position := percentile * float64(len(values)-1)
	lower := int(position)
	upper := lower + 1
	if upper >= len(values) {
		return values[lower]
	}
	fraction := position - float64(lower)
	return values[lower] + (values[upper]-values[lower])*fraction
}

func speedVariationPercent(values []float64) int {
	if len(values) < 2 {
		return 100
	}
	minimum, maximum := values[0], values[0]
	for _, value := range values[1:] {
		if value < minimum {
			minimum = value
		}
		if value > maximum {
			maximum = value
		}
	}
	center := medianFloat(values)
	if center <= 0 {
		return 100
	}
	return int((maximum-minimum)/center*100 + 0.5)
}

func medianInt64(values []int64) int64 {
	if len(values) == 0 {
		return 0
	}
	values = append([]int64(nil), values...)
	sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
	middle := len(values) / 2
	if len(values)%2 == 0 {
		return (values[middle-1] + values[middle]) / 2
	}
	return values[middle]
}

func spreadInt64(values []int64) int64 {
	if len(values) < 2 {
		return 0
	}
	minimum, maximum := values[0], values[0]
	for _, value := range values[1:] {
		if value < minimum {
			minimum = value
		}
		if value > maximum {
			maximum = value
		}
	}
	return maximum - minimum
}

func marshalNodeQualityError(code string) string {
	data, _ := json.Marshal(nodeQualityResult{Status: "failed", Quality: "异常", ErrorCode: code})
	return string(data)
}
