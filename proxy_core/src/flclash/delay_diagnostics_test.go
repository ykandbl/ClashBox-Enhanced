package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"syscall"
	"testing"
	"time"
)

func TestDelayErrorCode(t *testing.T) {
	cases := []struct {
		err  error
		code string
	}{
		{nil, ""},
		{fmt.Errorf("wrapped: %w", context.DeadlineExceeded), "timeout"},
		{&net.DNSError{Err: "fixture", Name: "private.example"}, "dns"},
		{&net.OpError{Op: "dial", Err: syscall.ECONNREFUSED}, "refused"},
		{syscall.ENETUNREACH, "unreachable"},
		{errors.New("x509: private.example invalid certificate"), "tls"},
		{errors.New("EOF https://private.example/?token=fixture"), "connection"},
	}
	for _, tc := range cases {
		if got := delayErrorCode(tc.err); got != tc.code {
			t.Fatalf("got %q, want %q", got, tc.code)
		}
	}
}

func TestDeadlineOverridesTransportEOF(t *testing.T) {
	ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	if got := delayRequestErrorCode(ctx, errors.New("EOF")); got != "timeout" {
		t.Fatalf("deadline was mislabeled as %s", got)
	}
	if got := delayRequestErrorCode(context.Background(), errors.New("EOF")); got != "connection" {
		t.Fatalf("non-deadline EOF was mislabeled as %s", got)
	}
}

func TestValidDelayTestURL(t *testing.T) {
	for _, raw := range []string{"https://www.gstatic.com/generate_204", "http://fixture.example/ping"} {
		if !validDelayTestURL(raw) {
			t.Fatalf("rejected test URL: %q", raw)
		}
	}
	for _, raw := range []string{"", "file:///tmp/fixture", "https://", "https://user:pass@fixture.example/"} {
		if validDelayTestURL(raw) {
			t.Fatal("accepted invalid URL")
		}
	}
}
