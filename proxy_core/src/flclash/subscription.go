package main

import (
	"fmt"

	"github.com/metacubex/mihomo/common/convert"
	"gopkg.in/yaml.v3"
)

// handleConvertV2RaySubscription turns the base64/URI subscription format
// already supported by Mihomo providers into a standalone Clash config. The
// ArkTS layer still performs normal YAML and core validation before atomically
// replacing the user's last known-good configuration.
func handleConvertV2RaySubscription(data []byte) (string, error) {
	proxies, err := convert.ConvertsV2Ray(data)
	if err != nil {
		return "", err
	}
	names := make([]string, 0, len(proxies))
	for _, proxy := range proxies {
		name, ok := proxy["name"].(string)
		if !ok || name == "" {
			return "", fmt.Errorf("converted subscription contains an unnamed proxy")
		}
		names = append(names, name)
	}
	config := map[string]any{
		"mixed-port": 7890,
		"allow-lan":  true,
		"mode":       "rule",
		"log-level":  "info",
		"ipv6":       false,
		"proxies":    proxies,
		"proxy-groups": []map[string]any{{
			"name":    "Subscription",
			"type":    "select",
			"proxies": names,
		}},
		"rules": []string{"MATCH,Subscription"},
	}
	encoded, err := yaml.Marshal(config)
	if err != nil {
		return "", err
	}
	return string(encoded), nil
}
