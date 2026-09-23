package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	nethttp "net/http"
	"time"

	"github.com/metacubex/mihomo/component/ca"
	C "github.com/metacubex/mihomo/constant"
	"github.com/showwin/speedtest-go/speedtest"
)

const (
	peakSpeedtestConnections = 8
	peakSpeedtestDuration    = 15 * time.Second
	peakSpeedtestTimeout     = 70 * time.Second
)

// qualityPeakSpeedtest runs the open-source speedtest-go engine through one
// explicit Mihomo adapter. It never mutates a selector or depends on system,
// ArkWeb, or loopback proxy settings, so the measured node is unambiguous.
func qualityPeakSpeedtest(proxy C.Proxy) nodeQualityResult {
	result := nodeQualityResult{
		Status:   "failed",
		Quality:  "峰值测试异常",
		Reliable: false,
	}
	client := peakSpeedtestClient(proxy)
	defer client.CloseIdleConnections()
	engine := speedtest.New(
		speedtest.WithUserConfig(&speedtest.UserConfig{
			MaxConnections: peakSpeedtestConnections,
			PingMode:       speedtest.HTTP,
		}),
		speedtest.WithDoer(client),
	)
	engine.SetCaptureTime(peakSpeedtestDuration)
	engine.SetRateCaptureFrequency(100 * time.Millisecond)

	ctx, cancel := context.WithTimeout(context.Background(), peakSpeedtestTimeout)
	defer cancel()
	servers, err := engine.FetchServerListContext(ctx)
	if err != nil {
		result.ErrorCode = peakSpeedtestErrorCode(ctx, err)
		result.Diagnostic = "speedtest-go 服务器发现失败"
		return result
	}
	targets, err := servers.FindServer(nil)
	if err != nil || len(targets) == 0 {
		result.ErrorCode = "unreachable"
		result.Diagnostic = "speedtest-go 没有找到可用测试点"
		return result
	}
	target := targets[0]
	if err = target.PingTestContext(ctx, nil); err != nil {
		result.ErrorCode = peakSpeedtestErrorCode(ctx, err)
		result.Diagnostic = "speedtest-go 测试点延迟失败"
		return result
	}
	result.LatencyMs = target.Latency.Milliseconds()
	result.JitterMs = target.Jitter.Milliseconds()

	if err = target.DownloadTestContext(ctx); err != nil {
		result.ErrorCode = peakSpeedtestErrorCode(ctx, err)
		result.Diagnostic = "speedtest-go 多连接下载失败"
		return result
	}
	downloadBytes := target.Context.GetTotalDownload()
	result.DownloadMbps = roundMbps(target.DLSpeed.Mbps())
	if result.DownloadMbps <= 0 || downloadBytes <= 0 || !validPeakCaptureDuration(target.TestDuration.Download) {
		result.ErrorCode = "incomplete"
		result.Diagnostic = "speedtest-go 下载样本不完整"
		return result
	}

	if err = target.UploadTestContext(ctx); err != nil {
		result.TransferredBytes = downloadBytes + target.Context.GetTotalUpload()
		result.ErrorCode = peakSpeedtestErrorCode(ctx, err)
		result.Diagnostic = "speedtest-go 多连接上传失败"
		return result
	}
	uploadBytes := target.Context.GetTotalUpload()
	result.UploadMbps = roundMbps(target.ULSpeed.Mbps())
	result.TransferredBytes = downloadBytes + uploadBytes
	if result.UploadMbps <= 0 || uploadBytes <= 0 || !validPeakCaptureDuration(target.TestDuration.Upload) {
		result.ErrorCode = "incomplete"
		result.Diagnostic = "speedtest-go 上传样本不完整"
		return result
	}

	result.Status = "ok"
	result.Quality = "8连接峰值"
	result.SuccessRate = 100
	result.ErrorCode = ""
	result.Reliable = true
	result.DownloadVariation = 0
	result.UploadVariation = 0
	result.Diagnostic = fmt.Sprintf(
		"speedtest-go v%s · %d连接 · 测试点 %s / %s · 下载%.1fs · 上传%.1fs · 有效载荷%.1fMB",
		speedtest.Version(), peakSpeedtestConnections, target.Name, target.Country,
		durationSeconds(target.TestDuration.Download), durationSeconds(target.TestDuration.Upload),
		float64(result.TransferredBytes)/1_000_000,
	)
	return result
}

func peakSpeedtestClient(proxy C.Proxy) *nethttp.Client {
	tlsConfig := &tls.Config{RootCAs: ca.GetCertPool(), MinVersion: tls.VersionTLS12}
	transport := &nethttp.Transport{
		DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
			metadata := &C.Metadata{NetWork: C.TCP}
			if err := metadata.SetRemoteAddress(address); err != nil {
				return nil, err
			}
			return proxy.DialContext(ctx, metadata)
		},
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          64,
		MaxIdleConnsPerHost:   peakSpeedtestConnections,
		IdleConnTimeout:       30 * time.Second,
		TLSHandshakeTimeout:   12 * time.Second,
		ExpectContinueTimeout: time.Second,
		TLSClientConfig:       tlsConfig,
		DisableCompression:    true,
	}
	return &nethttp.Client{Transport: transport}
}

// speedtest-go returns a nil/short duration when its context is cancelled
// while a direction is still collecting. Do not present that partial sample
// as a measured peak; a complete direction must run for at least 80% of the
// configured capture window.
func validPeakCaptureDuration(value *time.Duration) bool {
	return value != nil && *value >= peakSpeedtestDuration*4/5
}

func durationSeconds(value *time.Duration) float64 {
	if value == nil {
		return 0
	}
	return value.Seconds()
}

func peakSpeedtestErrorCode(ctx context.Context, err error) string {
	if err == nil {
		return ""
	}
	return delayRequestErrorCode(ctx, err)
}
