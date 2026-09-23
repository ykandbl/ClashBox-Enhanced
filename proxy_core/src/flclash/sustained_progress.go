package main

import (
	"context"
	"encoding/json"
	"sync"
	"time"
)

type sustainedProgressState struct {
	Running          bool    `json:"running"`
	Phase            string  `json:"phase"`
	Direction        string  `json:"direction"`
	CurrentMbps      float64 `json:"currentMbps"`
	AverageMbps      float64 `json:"averageMbps"`
	TransferredBytes int64   `json:"transferredBytes"`
	ElapsedMs        int64   `json:"elapsedMs"`
	Samples          int     `json:"samples"`
	DownloadSamples  int     `json:"downloadSamples"`
	UploadSamples    int     `json:"uploadSamples"`
	Connections      int     `json:"connections"`
	Target           string  `json:"target"`
}

var sustainedProgress = struct {
	sync.RWMutex
	state   sustainedProgressState
	started time.Time
	cancel  context.CancelFunc
}{}

func beginSustainedProgress(connections int) context.Context {
	ctx, cancel := context.WithTimeout(context.Background(), sustainedTotalTimeout)
	sustainedProgress.Lock()
	if sustainedProgress.cancel != nil {
		sustainedProgress.cancel()
	}
	sustainedProgress.started = time.Now()
	sustainedProgress.cancel = cancel
	sustainedProgress.state = sustainedProgressState{Running: true, Phase: "server", Connections: connections}
	sustainedProgress.Unlock()
	return ctx
}

func setSustainedProgressTarget(target string) {
	sustainedProgress.Lock()
	sustainedProgress.state.Target = target
	sustainedProgress.Unlock()
}

func setSustainedProgressPhase(method string, measured bool, samples int, average float64) {
	sustainedProgress.Lock()
	if measured {
		sustainedProgress.state.Phase = "measure"
	} else {
		sustainedProgress.state.Phase = "warmup"
	}
	if method == "POST" {
		sustainedProgress.state.Direction = "upload"
	} else {
		sustainedProgress.state.Direction = "download"
	}
	sustainedProgress.state.Samples = samples
	if measured {
		if method == "POST" {
			sustainedProgress.state.UploadSamples = samples
		} else {
			sustainedProgress.state.DownloadSamples = samples
		}
	}
	sustainedProgress.state.AverageMbps = roundMbps(average)
	sustainedProgress.Unlock()
}

func trackSustainedBytes(bytes int64) {
	if bytes <= 0 {
		return
	}
	sustainedProgress.Lock()
	if sustainedProgress.state.Running &&
		(sustainedProgress.state.Phase == "warmup" || sustainedProgress.state.Phase == "measure") {
		sustainedProgress.state.TransferredBytes += bytes
	}
	sustainedProgress.Unlock()
}

func addSustainedProgress(method string, measured bool, probe nodeTransferProbe, samples int, average float64) {
	sustainedProgress.Lock()
	phase := "warmup"
	if measured {
		phase = "measure"
	}
	direction := "download"
	if method == "POST" {
		direction = "upload"
	}
	sustainedProgress.state.Phase = phase
	sustainedProgress.state.Direction = direction
	sustainedProgress.state.CurrentMbps = roundMbps(probe.SpeedMbps)
	sustainedProgress.state.AverageMbps = roundMbps(average)
	sustainedProgress.state.Samples = samples
	if measured {
		if method == "POST" {
			sustainedProgress.state.UploadSamples = samples
		} else {
			sustainedProgress.state.DownloadSamples = samples
		}
	}
	sustainedProgress.state.ElapsedMs = time.Since(sustainedProgress.started).Milliseconds()
	sustainedProgress.Unlock()
}

func finishSustainedProgress() {
	sustainedProgress.Lock()
	sustainedProgress.state.Running = false
	sustainedProgress.state.Phase = "done"
	sustainedProgress.state.ElapsedMs = time.Since(sustainedProgress.started).Milliseconds()
	if sustainedProgress.cancel != nil {
		sustainedProgress.cancel()
	}
	sustainedProgress.cancel = nil
	sustainedProgress.Unlock()
}

func cancelSustainedProgress() bool {
	sustainedProgress.Lock()
	defer sustainedProgress.Unlock()
	if !sustainedProgress.state.Running || sustainedProgress.cancel == nil {
		return false
	}
	sustainedProgress.state.Phase = "cancelling"
	sustainedProgress.cancel()
	return true
}

func getSustainedProgress() string {
	sustainedProgress.RLock()
	state := sustainedProgress.state
	if state.Running {
		state.ElapsedMs = time.Since(sustainedProgress.started).Milliseconds()
	}
	sustainedProgress.RUnlock()
	data, _ := json.Marshal(state)
	return string(data)
}
