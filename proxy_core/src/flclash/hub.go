package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"runtime"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/observable"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var (
	isInit             = false
	configParams       = ConfigExtendedParams{}
	externalProviders  = map[string]cp.Provider{}
	logSubscriber      observable.Subscription[log.Event]
	currentConfig      *config.Config
	proxyDisplayMetaMu sync.RWMutex
	proxyDisplayMeta   = map[string]map[string]any{}
)

// collectProxyDisplayMeta preserves transport fields from the active profile's
// own YAML. The runtime proxy API already reports the parsed protocol type and
// UDP capability; transport (network) is not included by the upstream adapter
// JSON, so retain it here instead of inferring it from a node name or port.
func collectProxyDisplayMeta(proxies []map[string]any) map[string]map[string]any {
	result := make(map[string]map[string]any, len(proxies))
	for _, proxy := range proxies {
		name, ok := proxy["name"].(string)
		if !ok || name == "" {
			continue
		}
		meta := map[string]any{}
		if network, ok := proxy["network"].(string); ok && network != "" {
			meta["network"] = network
		}
		if rawType, ok := proxy["type"].(string); ok && rawType != "" {
			meta["config-type"] = rawType
		}
		result[name] = meta
	}
	return result
}

func handleInitClash(homeDirStr string) bool {
	if !isInit {
		constant.SetHomeDir(homeDirStr)
		isInit = true
	}
	return isInit
}

func handleStartListener() bool {
	runLock.Lock()
	defer runLock.Unlock()
	isRunning = true
	updateListeners(true)
	return true
}

func handleStopListener() bool {
	runLock.Lock()
	defer runLock.Unlock()
	isRunning = false
	stopListeners()
	return true
}

func handleGetIsInit() bool {
	return isInit
}

func handleForceGc() {
	go func() {
		log.Infoln("[APP] request force GC")
		runtime.GC()
	}()
}

func handleShutdown() bool {
	stopListeners()
	executor.Shutdown()
	runtime.GC()
	isInit = false
	return true
}

func handleValidateConfig(bytes []byte) string {
	_, err := config.UnmarshalRawConfig(bytes)
	if err != nil {
		return err.Error()
	}
	return ""
}

func handleUpdateConfig(bytes []byte) string {
	var params = &GenerateConfigParams{}
	err := json.Unmarshal(bytes, params)
	if err != nil {
		return err.Error()
	}

	configParams = params.Params
	prof := decorationConfig(params.ProfileId, params.Config)
	err = applyConfig(prof)
	if err != nil {
		return err.Error()
	}
	// prof is the subscription runtime RawConfig loaded from profile storage;
	// params.Config only contains application overrides such as mode/DNS/TUN.
	meta := collectProxyDisplayMeta(prof.Proxy)
	proxyDisplayMetaMu.Lock()
	proxyDisplayMeta = meta
	proxyDisplayMetaMu.Unlock()
	return ""
}

func handleGetProxies() string {
	runLock.Lock()
	defer runLock.Unlock()
	data, err := json.Marshal(tunnel.Proxies())
	if err != nil {
		return ""
	}
	proxies := map[string]map[string]any{}
	if err = json.Unmarshal(data, &proxies); err != nil {
		return string(data)
	}
	proxyDisplayMetaMu.RLock()
	for name, proxy := range proxies {
		if meta, ok := proxyDisplayMeta[name]; ok {
			for key, value := range meta {
				proxy[key] = value
			}
		}
	}
	proxyDisplayMetaMu.RUnlock()
	enriched, err := json.Marshal(proxies)
	if err != nil {
		return string(data)
	}
	return string(enriched)
}

func handleChangeProxy(data string, fn func(string string)) {
	go func() {
		// Config application owns runLock and may need to rebuild listeners and
		// providers. Waiting on that mutex in the IPC reader made the local RPC
		// look dead to ArkTS and left node cards stuck in their optimistic state.
		// Acquire it asynchronously with a hard bound so every tap gets a reply.
		lockDeadline := time.Now().Add(2500 * time.Millisecond)
		for !runLock.TryLock() {
			if time.Now().After(lockDeadline) {
				fn("核心正在重载，请稍后重试")
				return
			}
			time.Sleep(25 * time.Millisecond)
		}
		defer runLock.Unlock()
		// This RPC is called from the UI while the VPN is serving live traffic. A
		// transiently changing proxy group used to be able to panic here (nil
		// request fields, an unexpected group implementation, or an empty
		// selector). Since this function runs in a goroutine, that panic escaped
		// the IPC handler and terminated the native core. Convert every such
		// condition into a normal RPC error instead.
		responded := false
		respond := func(value string) {
			if responded {
				return
			}
			responded = true
			fn(value)
		}
		defer func() {
			if recovered := recover(); recovered != nil {
				log.Errorln("[APP] changeProxy panic recovered:", recovered)
				respond(fmt.Sprintf("节点切换异常：%v", recovered))
			}
		}()

		var params = &ChangeProxyParams{}
		if err := json.Unmarshal([]byte(data), params); err != nil {
			respond(err.Error())
			return
		}
		if params.GroupName == nil || params.ProxyName == nil || *params.GroupName == "" {
			respond("节点切换参数无效")
			return
		}
		groupName := *params.GroupName
		proxyName := *params.ProxyName
		proxies := tunnel.Proxies()
		group, ok := proxies[groupName]
		if !ok || group == nil {
			respond("代理组不存在或正在刷新")
			return
		}
		adapterProxy, ok := group.(*adapter.Proxy)
		if !ok || adapterProxy == nil || adapterProxy.ProxyAdapter == nil {
			respond("代理组类型不支持切换")
			return
		}
		selector, ok := adapterProxy.ProxyAdapter.(outboundgroup.SelectAble)
		if !ok || selector == nil {
			respond("代理组类型不支持切换")
			return
		}
		if proxyName == "" {
			selector.ForceSet(proxyName)
		} else if err := selector.Set(proxyName); err != nil {
			respond(err.Error())
			return
		}

		// A selector change only affects newly-created connections. Keeping the
		// old trackers alive makes apps continue to use the previous outbound.
		// Close them while runLock is held so the successful RPC reply means both
		// the selector and live connections have switched atomically.
		handleCloseConnectionsUnLock()
		respond("")
	}()
}

func handleGetTraffic(onlyProxy bool) string {
	up, down := statistic.DefaultManager.Now()
	traffic := map[string]int64{
		"up":   up,
		"down": down,
	}
	data, err := json.Marshal(traffic)
	if err != nil {
		fmt.Println("Error:", err)
		return ""
	}
	return string(data)
}

func handleGetTotalTraffic(onlyProxy bool) string {
	up, down := statistic.DefaultManager.Total()
	traffic := map[string]int64{
		"up":   up,
		"down": down,
	}
	data, err := json.Marshal(traffic)
	if err != nil {
		fmt.Println("Error:", err)
		return ""
	}
	return string(data)
}

func handleResetTraffic() {
	statistic.DefaultManager.ResetStatistic()
}

func handleAsyncTestDelay(paramsString string, fn func(string)) {
	b.Go(paramsString, func() (bool, error) {
		var params = &TestDelayParams{}
		err := json.Unmarshal([]byte(paramsString), params)
		if err != nil {
			fn("")
			return false, nil
		}

		expectedStatus, err := utils.NewUnsignedRanges[uint16]("")
		if err != nil {
			fn("")
			return false, nil
		}

		if params.Timeout < 1000 || params.Timeout > 8000 {
			params.Timeout = 8000
		}
		if params.URL == "" {
			params.URL = constant.DefaultTestURL
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond*time.Duration(params.Timeout))
		defer cancel()

		proxies := tunnel.Proxies()
		proxy := proxies[params.ProxyName]

		delayData := &Delay{
			Name:  params.ProxyName,
			Value: -1,
		}
		if !validDelayTestURL(params.URL) {
			delayData.ErrorCode = "invalid_url"
			data, _ := json.Marshal(delayData)
			fn(string(data))
			return false, nil
		}

		if proxy == nil {
			delayData.ErrorCode = "missing"
			data, _ := json.Marshal(delayData)
			fn(string(data))
			return false, nil
		}

		started := time.Now()
		delay, err := proxy.URLTest(ctx, params.URL, expectedStatus)
		delayData.ElapsedMs = time.Since(started).Milliseconds()
		if err != nil {
			delayData.ErrorCode = delayRequestErrorCode(ctx, err)
			data, _ := json.Marshal(delayData)
			fn(string(data))
			return false, nil
		}

		delayData.Value = int32(delay)
		if delayData.Value == 0 {
			delayData.Value = 1
		}
		data, _ := json.Marshal(delayData)
		fn(string(data))
		return false, nil
	})
}

func handleGetConnections() string {
	runLock.Lock()
	defer runLock.Unlock()
	snapshot := statistic.DefaultManager.Snapshot()
	data, err := json.Marshal(snapshot)
	if err != nil {
		fmt.Println("Error:", err)
		return ""
	}
	return string(data)
}

func handleCloseConnectionsUnLock() bool {
	// Snapshot first. Close removes the tracker from DefaultManager; keeping
	// mutation out of the Range callback makes this safe across the mobile
	// core's concurrent connection bookkeeping.
	trackers := make([]statistic.Tracker, 0)
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		if c != nil {
			trackers = append(trackers, c)
		}
		return true
	})
	for _, c := range trackers {
		func() {
			defer func() {
				if recovered := recover(); recovered != nil {
					log.Errorln("[APP] close connection panic recovered:", recovered)
				}
			}()
			if err := c.Close(); err != nil {
				log.Debugln("[APP] close connection failed:", err)
			}
		}()
	}
	return true
}

func handleCloseConnections() bool {
	runLock.Lock()
	defer runLock.Unlock()
	return handleCloseConnectionsUnLock()
}

func handleCloseConnection(connectionId string) bool {
	runLock.Lock()
	defer runLock.Unlock()
	c := statistic.DefaultManager.Get(connectionId)
	if c == nil {
		return false
	}
	_ = c.Close()
	return true
}

func handleGetExternalProviders() string {
	runLock.Lock()
	defer runLock.Unlock()
	externalProviders = getExternalProvidersRaw()
	eps := make([]ExternalProvider, 0)
	for _, p := range externalProviders {
		externalProvider, err := toExternalProvider(p)
		if err != nil {
			continue
		}
		eps = append(eps, *externalProvider)
	}
	sort.Sort(ExternalProviders(eps))
	data, err := json.Marshal(eps)
	if err != nil {
		return ""
	}
	return string(data)
}

func handleGetExternalProvider(externalProviderName string) string {
	runLock.Lock()
	defer runLock.Unlock()
	externalProvider, exist := externalProviders[externalProviderName]
	if !exist {
		return ""
	}
	e, err := toExternalProvider(externalProvider)
	if err != nil {
		return ""
	}
	data, err := json.Marshal(e)
	if err != nil {
		return ""
	}
	return string(data)
}

func handleUpdateGeoData(geoType string, geoName string, fn func(value string)) {
	go func() {
		switch geoType {
		case "MMDB":
			err := updater.UpdateMMDB()
			if err != nil {
				fn(err.Error())
				return
			}
		case "ASN":
			err := updater.UpdateASN()
			if err != nil {
				fn(err.Error())
				return
			}
		case "GeoIp":
			err := updater.UpdateGeoIp()
			if err != nil {
				fn(err.Error())
				return
			}
		case "GeoSite":
			err := updater.UpdateGeoSite()
			if err != nil {
				fn(err.Error())
				return
			}
		}
		fn("")
	}()
}

func handleUpdateExternalProvider(providerName string, fn func(value string)) {
	go func() {
		externalProvider, exist := externalProviders[providerName]
		if !exist {
			fn("external provider is not exist")
			return
		}
		err := externalProvider.Update()
		if err != nil {
			fn(err.Error())
			return
		}
		fn("")
	}()
}

func handleSideLoadExternalProvider(providerName string, data []byte, fn func(value string)) {
	go func() {
		runLock.Lock()
		defer runLock.Unlock()
		externalProvider, exist := externalProviders[providerName]
		if !exist {
			fn("external provider is not exist")
			return
		}
		err := sideUpdateExternalProvider(externalProvider, data)
		if err != nil {
			fn(err.Error())
			return
		}
		fn("")
	}()
}

func handleStartLog(fn func(value string)) {
	if logSubscriber != nil {
		log.UnSubscribe(logSubscriber)
		logSubscriber = nil
	}
	logSubscriber = log.Subscribe()
	go func() {
		for logData := range logSubscriber {
			if logData.LogLevel < log.Level() {
				continue
			}
			logMessage, _ := json.Marshal(LogInfo{
				LogLevel: logData.LogLevel.String(),
				Payload:  logData.Payload,
				Time:     time.Now().Unix(),
			})
			fn(string(logMessage))
		}
	}()
}

type LogInfo struct {
	LogLevel string `json:"logLevel"`
	Payload  string `json:"payload"`
	Time     int64  `json:"time"`
}

func handleStopLog() {
	if logSubscriber != nil {
		log.UnSubscribe(logSubscriber)
		logSubscriber = nil
	}
}
func handleGetCountryCode(ip string, fn func(value string)) {
	go func() {
		runLock.Lock()
		defer runLock.Unlock()
		codes := mmdb.IPInstance().LookupCode(net.ParseIP(ip))
		if len(codes) == 0 {
			fn("")
			return
		}
		fn(codes[0])
	}()
}

func handleGetMemory(fn func(value string)) {
	go func() {
		fn(strconv.FormatUint(statistic.DefaultManager.Memory(), 10))
	}()
}

var reqeustList = []statistic.Tracker{}

func init() {
	adapter.UrlTestHook = func(url string, name string, delay uint16) {
		delayData := &Delay{
			Name: name,
		}
		if delay == 0 {
			delayData.Value = -1
		} else {
			delayData.Value = int32(delay)
		}
		sendMessage(Message{
			Type: DelayMessage,
			Data: delayData,
		})
	}
	statistic.DefaultRequestNotify = func(c statistic.Tracker) {
		reqeustList = append(reqeustList, c)
		sendMessage(Message{
			Type: RequestMessage,
			Data: c,
		})
	}
	executor.DefaultProviderLoadedHook = func(providerName string) {
		sendMessage(Message{
			Type: LoadedMessage,
			Data: providerName,
		})
	}
}
