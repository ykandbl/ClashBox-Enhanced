package main

import (
	"context"
	"github.com/metacubex/http"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

func sustainedFixture(mbps float64, seconds int64) nodeTransferProbe {
	return nodeTransferProbe{Success: true, PayloadBytes: int64(mbps*1e6/8) * seconds,
		ElapsedMs: seconds * 1000, SpeedMbps: mbps, TotalStreams: 1, ValidStreams: 1}
}

func TestSustainedRequiresLongRepeatedSamples(t *testing.T) {
	short := []nodeTransferProbe{sustainedFixture(100, 1), sustainedFixture(100, 1), sustainedFixture(100, 1)}
	if sustainedEnough(short) || sustainedStable(short) {
		t.Fatal("short samples accepted")
	}
	probes := []nodeTransferProbe{sustainedFixture(100, 8), sustainedFixture(102, 8), sustainedFixture(99, 8), sustainedFixture(101, 8)}
	if !sustainedEnough(probes) || !sustainedStable(probes) {
		t.Fatal("long consistent samples rejected")
	}
	if sustainedMean(probes) != 100.5 {
		t.Fatal("wrong average")
	}
	probes[3].Success = false
	if sustainedEnough(probes) || sustainedStable(probes) {
		t.Fatal("failed sample marked stable")
	}
}

func TestSustainedUsesByteWeightedTimeNotP90(t *testing.T) {
	probes := []nodeTransferProbe{sustainedFixture(10, 10), sustainedFixture(100, 5)}
	if sustainedMean(probes) != 40 {
		t.Fatalf("mean=%f, expected 40 Mbps", sustainedMean(probes))
	}
}

func TestSustainedRejectsRampAndWideVariation(t *testing.T) {
	probes := []nodeTransferProbe{sustainedFixture(10, 8), sustainedFixture(30, 8), sustainedFixture(70, 8), sustainedFixture(100, 8)}
	if sustainedStable(probes) {
		t.Fatal("ramp marked stable")
	}
	for i := 0; i < 4; i++ {
		probes = append(probes, sustainedFixture(100, 8))
	}
	if sustainedStable(probes) {
		t.Fatal("short terminal plateau hid full-run drift")
	}
}

func TestSustainedAdaptivePayloadGrowsWithSpeed(t *testing.T) {
	probe := sustainedFixture(200, 2)
	if size := sustainedNextSize(probe, 1, http.MethodGet); size != 32_500_000 {
		t.Fatalf("size=%d", size)
	}
	if size := sustainedNextSize(probe, 8, http.MethodGet); size != 4_062_500 {
		t.Fatalf("size=%d", size)
	}
	if size := sustainedNextSize(probe, 1, http.MethodPost); size != 32_500_000 {
		t.Fatalf("size=%d", size)
	}
}

func TestSustainedTransferCalibratedOnKnown80MbpsLink(t *testing.T) {
	for _, workers := range []int{1, 8} {
		for _, method := range []string{http.MethodGet, http.MethodPost} {
			client := &http.Client{Transport: qualityRateLimitedTransport(80)}
			probe := sustainedParallel(context.Background(), client, method, 1_000_000, workers)
			t.Logf("known=80 Mbps workers=%d method=%s measured=%.3f Mbps", workers, method, probe.SpeedMbps)
			if !probe.Success || probe.SpeedMbps < 75 || probe.SpeedMbps > 82 {
				t.Fatalf("workers=%d method=%s result=%#v", workers, method, probe)
			}
		}
	}
}

func TestSustainedConstantsAreFullSamplingNotTrafficTiers(t *testing.T) {
	if sustainedMinimumTime != 4*time.Second || sustainedMaximumTime != 5500*time.Millisecond ||
		sustainedWarmupTime != time.Second || sustainedMinimumSamples != 3 {
		t.Fatal("full-sample defaults changed")
	}
}

func TestSustainedFallbackResultDisclosesIndependentSource(t *testing.T) {
	down := sustainedDirection{Samples: []nodeTransferProbe{
		sustainedFixture(40, 2), sustainedFixture(41, 2), sustainedFixture(40, 2),
	}}
	up := sustainedDirection{Samples: []nodeTransferProbe{
		sustainedFixture(12, 2), sustainedFixture(12, 2), sustainedFixture(12, 2),
	}}
	result := buildSustainedResult(1, down, up, 1024, "Cloudflare 备用测速源", "主测速源：timeout")
	if result.Status != "ok" || !strings.Contains(result.Quality, "备用源复核") ||
		!strings.Contains(result.Diagnostic, "独立备用源复核") ||
		!strings.Contains(result.Diagnostic, "Cloudflare 备用测速源") {
		t.Fatalf("fallback result = %#v", result)
	}
}

func TestSustainedTargetUsesValidatedLargeFileAndConfirmedUpload(t *testing.T) {
	target := &sustainedTarget{UploadURL: "https://fixture/upload.php", DownloadURL: "https://fixture/random1000x1000.jpg?bytes=1000000", Label: "fixture"}
	for _, method := range []string{http.MethodGet, http.MethodPost} {
		limited := qualityRateLimitedTransport(80)
		client := &http.Client{Transport: qualityFixtureTransport(func(req *http.Request) (*http.Response, error) {
			resp, err := limited(req)
			if resp != nil {
				resp.Header = make(http.Header)
				resp.Header.Set("Content-Type", "image/jpeg")
				resp.ContentLength = -1
			}
			return resp, err
		})}
		probe := sustainedParallel(context.Background(), client, method, 2_000_000, 4, target)
		t.Logf("dedicated target known=80 Mbps method=%s measured=%.3f Mbps", method, probe.SpeedMbps)
		if !probe.Success || probe.SpeedMbps < 77 || probe.SpeedMbps > 82 || probe.PayloadBytes != 8_000_000 {
			t.Fatalf("method=%s result=%#v", method, probe)
		}
	}
	client := &http.Client{Transport: qualityFixtureTransport(func(req *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"text/html"}}, Body: io.NopCloser(strings.NewReader(strings.Repeat("x", 100001)))}, nil
	})}
	probe := target.transfer(context.Background(), client, http.MethodGet, 100000)
	if probe.Success || probe.PayloadBytes != 0 || probe.ErrorCode != "incomplete" {
		t.Fatal("HTML page counted as speed payload")
	}
}

func TestSustainedUploadUsesServerCompatibleChunks(t *testing.T) {
	sizes := []int64{}
	client := &http.Client{Transport: qualityFixtureTransport(func(req *http.Request) (*http.Response, error) {
		n, err := io.Copy(io.Discard, req.Body)
		if err != nil {
			return nil, err
		}
		sizes = append(sizes, n)
		return &http.Response{StatusCode: 200, Header: make(http.Header),
			Body: io.NopCloser(strings.NewReader("ok")), ContentLength: 2}, nil
	})}
	target := &sustainedTarget{UploadURL: "https://fixture/upload.php", Label: "fixture"}
	probe := target.transfer(context.Background(), client, http.MethodPost, 10_000_000)
	if !probe.Success || probe.PayloadBytes != 10_000_000 {
		t.Fatalf("upload result = %#v", probe)
	}
	if len(sizes) != 3 || sizes[0] != 4_000_000 || sizes[1] != 4_000_000 || sizes[2] != 2_000_000 {
		t.Fatalf("upload chunks = %#v", sizes)
	}
}

func TestSustainedTargetPersistsAcrossCoreRestartAndInvalidatesAtomically(t *testing.T) {
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(t.TempDir())
	sustainedTargets.Delete(sustainedTargetCacheKey)
	t.Cleanup(func() {
		sustainedTargets.Delete(sustainedTargetCacheKey)
		C.SetHomeDir(oldHome)
	})
	now := time.Now()
	target := &sustainedTarget{
		UploadURL:   "https://fixture.example/upload.php",
		DownloadURL: "https://fixture.example/random1000x1000.jpg",
		Label:       "fixed fixture",
		Expires:     now.Add(sustainedTargetMemoryTTL),
	}
	persistSustainedTarget(target, now)
	info, err := os.Stat(sustainedTargetCachePath())
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("cache permissions/info = %v, %v", info, err)
	}
	loaded := loadPersistedSustainedTarget(now.Add(time.Minute))
	if loaded == nil || !loaded.Persisted || loaded.UploadURL != target.UploadURL || loaded.DownloadURL != target.DownloadURL || loaded.Label != target.Label {
		t.Fatalf("persisted target = %#v", loaded)
	}
	sustainedTargets.Store(sustainedTargetCacheKey, loaded)
	invalidateSustainedTarget(loaded)
	if _, err = os.Stat(sustainedTargetCachePath()); !os.IsNotExist(err) {
		t.Fatalf("invalidated cache still exists: %v", err)
	}
}

func TestSustainedTargetRejectsExpiredOrCrossHostCache(t *testing.T) {
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(t.TempDir())
	sustainedTargets.Delete(sustainedTargetCacheKey)
	t.Cleanup(func() {
		sustainedTargets.Delete(sustainedTargetCacheKey)
		C.SetHomeDir(oldHome)
	})
	target := &sustainedTarget{
		UploadURL:   "https://fixture.example/upload.php",
		DownloadURL: "https://fixture.example/random1000x1000.jpg",
		Label:       "expired fixture",
	}
	persistSustainedTarget(target, time.Now().Add(-25*time.Hour))
	if loaded := loadPersistedSustainedTarget(time.Now()); loaded != nil {
		t.Fatalf("expired target loaded: %#v", loaded)
	}
	if validSustainedTargetURLs("https://one.example/upload.php", "https://two.example/random1000x1000.jpg") {
		t.Fatal("cross-host target accepted")
	}
}
