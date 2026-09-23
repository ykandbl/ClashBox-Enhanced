package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/http"
	C "github.com/metacubex/mihomo/constant"
	"github.com/showwin/speedtest-go/speedtest"
)

type sustainedTarget struct {
	UploadURL, DownloadURL, Label string
	Expires                       time.Time
	Persisted                     bool
}

type sustainedTargetDiskCache struct {
	Version     int       `json:"version"`
	UploadURL   string    `json:"uploadUrl"`
	DownloadURL string    `json:"downloadUrl"`
	Label       string    `json:"label"`
	ValidUntil  time.Time `json:"validUntil"`
}

type sustainedDownloadWriter struct{}

func (sustainedDownloadWriter) Write(data []byte) (int, error) {
	trackSustainedBytes(int64(len(data)))
	return len(data), nil
}

var (
	sustainedTargets    sync.Map
	sustainedTargetFile sync.Mutex
)

const (
	sustainedUploadChunkBytes    = 4_000_000
	sustainedTargetCacheKey      = "shared-fair-comparison-target"
	sustainedTargetCacheFile     = "speedtest-target-v1.json"
	sustainedTargetMemoryTTL     = 30 * time.Minute
	sustainedTargetPersistentTTL = 24 * time.Hour
)

func sustainedTargetCachePath() string {
	return filepath.Join(C.Path.HomeDir(), sustainedTargetCacheFile)
}

func validSustainedTargetURLs(uploadRaw, downloadRaw string) bool {
	upload, uploadErr := url.Parse(uploadRaw)
	download, downloadErr := url.Parse(downloadRaw)
	if uploadErr != nil || downloadErr != nil || upload.Host == "" || download.Host == "" {
		return false
	}
	if (upload.Scheme != "http" && upload.Scheme != "https") || upload.Scheme != download.Scheme || upload.Host != download.Host {
		return false
	}
	return strings.HasSuffix(upload.Path, "upload.php") && strings.HasSuffix(download.Path, "random1000x1000.jpg")
}

func loadPersistedSustainedTarget(now time.Time) *sustainedTarget {
	sustainedTargetFile.Lock()
	defer sustainedTargetFile.Unlock()
	data, err := os.ReadFile(sustainedTargetCachePath())
	if err != nil {
		return nil
	}
	disk := sustainedTargetDiskCache{}
	if json.Unmarshal(data, &disk) != nil || disk.Version != 1 || disk.Label == "" || !now.Before(disk.ValidUntil) ||
		!validSustainedTargetURLs(disk.UploadURL, disk.DownloadURL) {
		_ = os.Remove(sustainedTargetCachePath())
		return nil
	}
	return &sustainedTarget{UploadURL: disk.UploadURL, DownloadURL: disk.DownloadURL, Label: disk.Label,
		Expires: now.Add(sustainedTargetMemoryTTL), Persisted: true}
}

func persistSustainedTarget(target *sustainedTarget, now time.Time) {
	if target == nil || target.Label == "" || !validSustainedTargetURLs(target.UploadURL, target.DownloadURL) {
		return
	}
	disk := sustainedTargetDiskCache{Version: 1, UploadURL: target.UploadURL, DownloadURL: target.DownloadURL,
		Label: target.Label, ValidUntil: now.Add(sustainedTargetPersistentTTL)}
	data, err := json.Marshal(disk)
	if err != nil {
		return
	}
	sustainedTargetFile.Lock()
	defer sustainedTargetFile.Unlock()
	path := sustainedTargetCachePath()
	if os.MkdirAll(filepath.Dir(path), 0o700) != nil {
		return
	}
	temporary := path + ".tmp"
	if os.WriteFile(temporary, data, 0o600) != nil {
		return
	}
	if os.Rename(temporary, path) != nil {
		_ = os.Remove(temporary)
	}
}

func removePersistedSustainedTarget() {
	sustainedTargetFile.Lock()
	defer sustainedTargetFile.Unlock()
	_ = os.Remove(sustainedTargetCachePath())
}

// Share one discovered host in memory and retain the validated choice for one
// day across process restarts. Switching nodes or changing single/multi mode
// must not silently pick another host and invalidate a comparison.
func discoverSustainedTarget(parent context.Context, transferClient *http.Client, proxy C.Proxy) (*sustainedTarget, error) {
	key := sustainedTargetCacheKey
	now := time.Now()
	if cached, ok := sustainedTargets.Load(key); ok {
		target := cached.(*sustainedTarget)
		if now.Before(target.Expires) {
			return target, nil
		}
		sustainedTargets.Delete(key)
	}
	// Reuse the last bidirectionally validated public server across process and
	// application restarts. This removes the otherwise repeated 8-12 second
	// server discovery phase. A stale persisted target is retried with fresh
	// discovery by qualitySustainedBandwidth in the same user action.
	if target := loadPersistedSustainedTarget(now); target != nil {
		sustainedTargets.Store(key, target)
		return target, nil
	}
	discoveryClient := peakSpeedtestClient(proxy)
	defer discoveryClient.CloseIdleConnections()
	engine := speedtest.New(speedtest.WithUserConfig(&speedtest.UserConfig{MaxConnections: 8, PingMode: speedtest.HTTP}), speedtest.WithDoer(discoveryClient))
	ctx, cancel := context.WithTimeout(parent, 20*time.Second)
	defer cancel()
	servers, err := engine.FetchServerListContext(ctx)
	if err != nil {
		return nil, err
	}
	available := servers.Available()
	if len(*available) == 0 {
		return nil, fmt.Errorf("no available test server")
	}
	// Latency alone does not prove that a public server accepts both large-file
	// download and upload through this adapter. Validate both directions before
	// pinning so a long download does not end with a predictably broken upload.
	limit := len(*available)
	if limit > 6 {
		limit = 6
	}
	for _, server := range (*available)[:limit] {
		u, parseErr := url.Parse(server.URL)
		if parseErr != nil || u.Host == "" || !strings.HasSuffix(u.Path, "upload.php") {
			continue
		}
		// Large speedtest.net images can make the sizing-only warm-up last five
		// seconds on an ordinary proxy. Repeating the complete 1000px payload
		// still exercises a persistent large-file path, while allowing three
		// full samples inside our short
		// measurement window. target.transfer never publishes partial images.
		u.Path = strings.TrimSuffix(u.Path, "upload.php") + "random1000x1000.jpg"
		target := &sustainedTarget{UploadURL: server.URL, DownloadURL: u.String(),
			Label: server.Name + " / " + server.Country + " (#" + server.ID + ")", Expires: time.Now().Add(sustainedTargetMemoryTTL)}
		probeCtx, probeCancel := context.WithTimeout(parent, 18*time.Second)
		down := target.transfer(probeCtx, transferClient, http.MethodGet, 100_000)
		up := target.transfer(probeCtx, transferClient, http.MethodPost, 100_000)
		probeCancel()
		if down.Success && up.Success {
			sustainedTargets.Store(key, target)
			persistSustainedTarget(target, time.Now())
			return target, nil
		}
		transferClient.CloseIdleConnections()
	}
	return nil, fmt.Errorf("no test server supports validated download and upload")
}

func invalidateSustainedTarget(target *sustainedTarget) {
	key := sustainedTargetCacheKey
	if cached, ok := sustainedTargets.Load(key); ok && cached == target {
		sustainedTargets.Delete(key)
		removePersistedSustainedTarget()
	}
}

func (target *sustainedTarget) transfer(ctx context.Context, client *http.Client, method string, goalBytes int) nodeTransferProbe {
	probe := nodeTransferProbe{Endpoint: target.Label}
	started := time.Now()
	for probe.PayloadBytes < int64(goalBytes) {
		endpoint := target.DownloadURL
		requestBytes := goalBytes
		var body io.Reader
		var counter *qualityPayloadReader
		var uploaded atomic.Int64
		if method == http.MethodPost {
			endpoint = target.UploadURL
			requestBytes = goalBytes - int(probe.PayloadBytes)
			if requestBytes > sustainedUploadChunkBytes {
				requestBytes = sustainedUploadChunkBytes
			}
			counter = &qualityPayloadReader{remaining: int64(requestBytes), total: &uploaded}
			body = counter
		}
		req, err := http.NewRequestWithContext(ctx, method, endpoint, body)
		if err != nil {
			probe.ErrorCode = "invalid"
			return probe
		}
		req.Header.Set("User-Agent", speedtest.DefaultUserAgent)
		req.Header.Set("Cache-Control", "no-cache, no-store")
		if counter != nil {
			req.ContentLength = int64(requestBytes)
			req.Header.Set("Content-Type", "application/octet-stream")
			// A speed-test server may close an idle keep-alive after download.
			// Supplying a replayable body lets net/http transparently retry that
			// stale connection without turning a harmless close into a failed run.
			req.GetBody = func() (io.ReadCloser, error) {
				return io.NopCloser(&qualityPayloadReader{remaining: int64(requestBytes), total: &uploaded}), nil
			}
		}
		resp, err := client.Do(req)
		if err != nil {
			if counter != nil {
				probe.TransferredBytes += uploaded.Load()
			}
			probe.ErrorCode = delayRequestErrorCode(ctx, err)
			probe.ElapsedMs = time.Since(started).Milliseconds()
			return probe
		}
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			_ = resp.Body.Close()
			if counter != nil {
				probe.TransferredBytes += uploaded.Load()
			}
			probe.ErrorCode = "http_" + strconv.Itoa(resp.StatusCode)
			probe.ElapsedMs = time.Since(started).Milliseconds()
			return probe
		}
		writer := io.Writer(io.Discard)
		if counter == nil {
			writer = sustainedDownloadWriter{}
		}
		n, readErr := io.Copy(writer, resp.Body)
		_ = resp.Body.Close()
		probe.TransferredBytes += n
		payload := n
		valid := readErr == nil
		if counter != nil {
			probe.TransferredBytes += uploaded.Load()
			payload = int64(requestBytes)
			valid = valid && uploaded.Load() >= int64(requestBytes)
		} else {
			kind := resp.Header.Get("Content-Type")
			valid = valid && n >= 100_000 && (strings.HasPrefix(kind, "image/") || strings.HasPrefix(kind, "application/octet-stream"))
			if resp.ContentLength >= 0 {
				valid = valid && n == resp.ContentLength
			}
		}
		if !valid {
			probe.ErrorCode = "incomplete"
			if readErr != nil {
				probe.ErrorCode = delayRequestErrorCode(ctx, readErr)
			}
			probe.ElapsedMs = time.Since(started).Milliseconds()
			return probe
		}
		probe.PayloadBytes += payload
	}
	probe.Success = true
	probe.ElapsedMs = time.Since(started).Milliseconds()
	probe.SpeedMbps = bytesPerSecondMbps(probe.PayloadBytes, probe.ElapsedMs)
	return probe
}
