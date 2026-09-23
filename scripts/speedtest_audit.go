// Manual diagnostic only: run on the phone through its explicit loopback mixed
// proxy. No profile, credential, subscription or selector APIs are accessed.
// Build from the native core module to reuse the exact pinned dependency.
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/component/ca"
	"github.com/showwin/speedtest-go/speedtest"
)

func emit(value any) { _ = json.NewEncoder(os.Stdout).Encode(value) }
func check(err error) {
	if err != nil {
		emit(map[string]any{"error": err.Error()})
		os.Exit(1)
	}
}

func main() {
	mode := flag.String("mode", "discover", "discover, peak, sustained, cf or fixture")
	proxyPort := flag.Int("proxy-port", 0, "explicit phone mixed port or HDC-forwarded local port; required")
	serverURL := flag.String("server", "", "public test server upload.php URL")
	seconds := flag.Int("seconds", 15, "capture window, 1..60 seconds")
	workers := flag.Int("workers", 8, "concurrency, 1..8")
	direction := flag.String("direction", "down", "down or up")
	size := flag.Int64("bytes", 25000000, "CF sample bytes, at most 250 MB")
	flag.Parse()
	if *mode == "fixture" {
		runFixture()
		return
	}
	if *proxyPort < 1 || *proxyPort > 65535 || *seconds < 1 || *seconds > 60 || *workers < 1 || *workers > 8 || *size <= 0 || *size > 250000000 {
		check(fmt.Errorf("invalid bounded diagnostic options"))
	}
	proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", *proxyPort))
	tr := &http.Transport{
		Proxy: http.ProxyURL(proxy), DialContext: (&net.Dialer{Timeout: 12 * time.Second}).DialContext,
		ForceAttemptHTTP2: true, MaxIdleConns: 64, MaxIdleConnsPerHost: 8,
		IdleConnTimeout: 30 * time.Second, TLSHandshakeTimeout: 12 * time.Second,
		TLSClientConfig:    &tls.Config{RootCAs: ca.GetCertPool(), MinVersion: tls.VersionTLS12},
		DisableCompression: true,
	}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr}
	engine := speedtest.New(speedtest.WithUserConfig(&speedtest.UserConfig{
		MaxConnections: *workers, PingMode: speedtest.HTTP,
	}), speedtest.WithDoer(client))
	engine.SetCaptureTime(time.Duration(*seconds) * time.Second)
	engine.SetRateCaptureFrequency(100 * time.Millisecond)
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()
	if *mode == "discover" {
		servers, err := engine.FetchServerListContext(ctx)
		check(err)
		available := servers.Available()
		for i, server := range *available {
			if i >= 3 {
				break
			}
			emit(map[string]any{"id": server.ID, "url": server.URL, "name": server.Name,
				"country": server.Country, "latencyMs": server.Latency.Milliseconds()})
		}
		return
	}
	if *mode == "cf" {
		u := fmt.Sprintf("https://speed.cloudflare.com/__down?bytes=%d&audit=%d", *size, time.Now().UnixNano())
		var body io.Reader
		method := http.MethodGet
		if *direction == "up" {
			u = "https://speed.cloudflare.com/__up"
			method = http.MethodPost
			body = io.LimitReader(zeroReader{}, *size)
		}
		req, err := http.NewRequestWithContext(ctx, method, u, body)
		check(err)
		if body != nil {
			req.ContentLength = *size
		}
		started := time.Now()
		resp, err := client.Do(req)
		check(err)
		first := time.Since(started).Seconds()
		n, err := io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		check(err)
		elapsed := time.Since(started).Seconds()
		payload := n
		if body != nil {
			payload = *size
		}
		emit(map[string]any{"mode": *mode, "direction": *direction, "http": resp.StatusCode,
			"bytes": payload, "seconds": elapsed, "firstByteSeconds": first,
			"wholeMbps": float64(payload) * 8 / elapsed / 1e6,
			"cfRay":     resp.Header.Get("CF-Ray"), "serverTiming": resp.Header.Get("Server-Timing")})
		return
	}
	u, err := url.Parse(*serverURL)
	check(err)
	if u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		check(fmt.Errorf("test server URL required"))
	}
	if *mode == "peak" {
		target, err := engine.CustomServer(u.Scheme + "://" + u.Host)
		check(err)
		target.URL = *serverURL
		check(target.PingTestContext(ctx, nil))
		for _, dir := range []string{"down", "up"} {
			started := time.Now()
			if dir == "down" {
				check(target.DownloadTestContext(ctx))
			} else {
				check(target.UploadTestContext(ctx))
			}
			elapsed := time.Since(started).Seconds()
			bytes, mbps := engine.GetTotalDownload(), target.DLSpeed.Mbps()
			if dir == "up" {
				bytes, mbps = engine.GetTotalUpload(), target.ULSpeed.Mbps()
			}
			emit(map[string]any{"mode": *mode, "direction": dir, "requestedSeconds": *seconds,
				"seconds": elapsed, "workers": *workers, "engineMbps": mbps,
				"payloadBytes": bytes, "wholeMbps": float64(bytes) * 8 / elapsed / 1e6,
				"passesAppDurationGate": elapsed >= 12, "server": u.Host})
		}
		return
	}
	if *mode != "sustained" {
		check(fmt.Errorf("unknown mode"))
	}
	endpoint := *serverURL
	if *direction == "down" {
		endpoint = strings.TrimSuffix(endpoint, "upload.php") + "random1000x1000.jpg"
	}
	var bytes, confirmed, requests, failures atomic.Int64
	started := time.Now()
	captureCtx, stop := context.WithTimeout(ctx, time.Duration(*seconds)*time.Second)
	defer stop()
	var wg sync.WaitGroup
	for i := 0; i < *workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for captureCtx.Err() == nil {
				var body io.Reader
				method := http.MethodGet
				const uploadSize int64 = 1499490
				if *direction == "up" {
					method = http.MethodPost
					body = &countReader{r: io.LimitReader(zeroReader{}, uploadSize), count: &bytes}
				}
				req, err := http.NewRequestWithContext(captureCtx, method, endpoint, body)
				if err != nil {
					failures.Add(1)
					return
				}
				if body != nil {
					req.ContentLength = uploadSize
					req.Header.Set("Content-Type", "application/octet-stream")
				}
				resp, err := client.Do(req)
				if err != nil {
					if captureCtx.Err() == nil {
						failures.Add(1)
					}
					continue
				}
				requests.Add(1)
				if resp.StatusCode < 200 || resp.StatusCode >= 300 {
					failures.Add(1)
					_ = resp.Body.Close()
					continue
				}
				reader := io.Reader(resp.Body)
				if *direction == "down" {
					reader = &countReader{r: reader, count: &bytes}
				}
				_, err = io.Copy(io.Discard, reader)
				_ = resp.Body.Close()
				if err == nil && body != nil {
					confirmed.Add(uploadSize)
				}
			}
		}()
	}
	finished := make(chan struct{})
	go func() { wg.Wait(); close(finished) }()
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	prev, prevAt := int64(0), started
	for {
		select {
		case now := <-ticker.C:
			current := bytes.Load()
			emit(map[string]any{"windowMbps": float64(current-prev) * 8 / now.Sub(prevAt).Seconds() / 1e6,
				"elapsedSeconds": now.Sub(started).Seconds(), "direction": *direction})
			prev, prevAt = current, now
		case <-finished:
			elapsed := time.Since(started).Seconds()
			emit(map[string]any{"mode": *mode, "direction": *direction, "seconds": elapsed, "workers": *workers,
				"payloadBytes": bytes.Load(), "confirmedUploadBytes": confirmed.Load(),
				"wholeMbps": float64(bytes.Load()) * 8 / elapsed / 1e6, "requests": requests.Load(), "failures": failures.Load(), "server": u.Host})
			return
		}
	}
}

type zeroReader struct{}

func (zeroReader) Read(b []byte) (int, error) { clear(b); return len(b), nil }

type countReader struct {
	r     io.Reader
	count *atomic.Int64
}

func (r *countReader) Read(b []byte) (int, error) {
	n, err := r.r.Read(b)
	r.count.Add(int64(n))
	return n, err
}

// Deterministic engine calibration: continuously feed a shared, paced 40 Mbps
// source into the same upstream sampler. No Internet or device traffic.
func runFixture() {
	engine := speedtest.New(speedtest.WithUserConfig(&speedtest.UserConfig{MaxConnections: 8}))
	engine.SetCaptureTime(15 * time.Second)
	engine.SetRateCaptureFrequency(100 * time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	pacer := &pacedReader{ctx: ctx, bytesPerSecond: 5000000, next: time.Now()}
	start := time.Now()
	engine.RegisterDownloadHandler(func() { _ = engine.NewChunk().DownloadHandler(pacer) }).Start(cancel, 0)
	elapsed := time.Since(start).Seconds()
	emit(map[string]any{"mode": "fixture", "knownMbps": 40, "engineMbps": engine.GetEWMADownloadRate() * 8 / 1e6,
		"wholeMbps": float64(engine.GetTotalDownload()) * 8 / elapsed / 1e6, "seconds": elapsed,
		"passesAppDurationGate": elapsed >= 12, "payloadBytes": engine.GetTotalDownload()})
}

type pacedReader struct {
	ctx            context.Context
	mu             sync.Mutex
	next           time.Time
	bytesPerSecond int64
}

func (r *pacedReader) Read(b []byte) (int, error) {
	r.mu.Lock()
	r.next = r.next.Add(time.Duration(int64(len(b)) * int64(time.Second) / r.bytesPerSecond))
	wait := time.Until(r.next)
	r.mu.Unlock()
	if wait > 0 {
		timer := time.NewTimer(wait)
		select {
		case <-timer.C:
		case <-r.ctx.Done():
			timer.Stop()
			return 0, r.ctx.Err()
		}
	}
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	clear(b)
	return len(b), nil
}
