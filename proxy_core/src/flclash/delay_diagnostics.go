package main

import (
	"context"
	"errors"
	"net"
	"net/url"
	"strings"
	"syscall"
)

// Never return a raw error: dial/TLS errors can contain provider hosts or URLs.
func delayErrorCode(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, context.Canceled) {
		return "cancelled"
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return "dns"
	}
	var netErr net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &netErr) && netErr.Timeout()) {
		return "timeout"
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		return "refused"
	}
	if errors.Is(err, syscall.ENETUNREACH) || errors.Is(err, syscall.EHOSTUNREACH) {
		return "unreachable"
	}
	message := strings.ToLower(err.Error())
	if strings.Contains(message, "tls") || strings.Contains(message, "x509") || strings.Contains(message, "certificate") {
		return "tls"
	}
	return "connection"
}

func delayRequestErrorCode(ctx context.Context, err error) string {
	// Some transports return EOF/stream-close when the deadline cancels them.
	// Preserve the request's real deadline instead of reporting a generic failure.
	if err != nil && ctx.Err() != nil {
		return delayErrorCode(ctx.Err())
	}
	return delayErrorCode(err)
}

func validDelayTestURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && (u.Scheme == "https" || u.Scheme == "http") && u.Hostname() != "" && u.User == nil
}
