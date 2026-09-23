package main

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestHandleConvertV2RaySubscription(t *testing.T) {
	raw := "hysteria2://fixture@example.com:443/?insecure=1&sni=example.com#fixture-node"
	content, err := handleConvertV2RaySubscription([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]any
	if err := yaml.Unmarshal([]byte(content), &config); err != nil {
		t.Fatal(err)
	}
	proxies, ok := config["proxies"].([]any)
	if !ok || len(proxies) != 1 {
		t.Fatalf("unexpected proxy list: %#v", config["proxies"])
	}
	if !strings.Contains(content, "MATCH,Subscription") || !strings.Contains(content, "fixture-node") {
		t.Fatalf("converted config is missing group/rule/name: %s", content)
	}
}

func TestHandleConvertV2RaySubscriptionRejectsInvalidInput(t *testing.T) {
	if _, err := handleConvertV2RaySubscription([]byte("not a subscription")); err == nil {
		t.Fatal("invalid subscription was accepted")
	}
}
