//go:build cgo && ohos

package main

//#include "bridge.h"
import "C"
import (
	"core/state"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"unsafe"

	napi "github.com/likuai2010/ohos-napi"
	"github.com/likuai2010/ohos-napi/entry"
	"github.com/likuai2010/ohos-napi/js"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var (
	fdProtectionHandlerMu sync.RWMutex
	fdProtectionHandler   unsafe.Pointer
	logHandlerMu          sync.RWMutex
	logHandler            unsafe.Pointer
	messageHandlerMu      sync.RWMutex
	messageHandler        unsafe.Pointer
)

func createSafeStringHandler(env js.Env, callback js.Value, name string) unsafe.Pointer {
	resourceName := C.CString(name)
	defer C.free(unsafe.Pointer(resourceName))
	return C.create_safe_string_tsfn(
		unsafe.Pointer(env.Env), unsafe.Pointer(callback.Value), resourceName)
}

func createSafeInt64Handler(env js.Env, callback js.Value, name string) unsafe.Pointer {
	resourceName := C.CString(name)
	defer C.free(unsafe.Pointer(resourceName))
	return C.create_safe_int64_tsfn(
		unsafe.Pointer(env.Env), unsafe.Pointer(callback.Value), resourceName)
}

func replaceSafeHandler(mu *sync.RWMutex, target *unsafe.Pointer, next unsafe.Pointer) {
	mu.Lock()
	previous := *target
	*target = next
	mu.Unlock()
	if previous != nil {
		C.release_safe_tsfn(previous)
	}
}

func callSafeStringHandler(mu *sync.RWMutex, target *unsafe.Pointer, key string, value string) bool {
	keyString := C.CString(key)
	valueString := C.CString(value)
	defer C.free(unsafe.Pointer(keyString))
	defer C.free(unsafe.Pointer(valueString))
	mu.RLock()
	defer mu.RUnlock()
	if *target == nil {
		return false
	}
	return C.call_safe_string_tsfn(*target, keyString, valueString) == 0
}

func callSafeInt64Handler(mu *sync.RWMutex, target *unsafe.Pointer, key int64, value int64) bool {
	mu.RLock()
	defer mu.RUnlock()
	if *target == nil {
		return false
	}
	return C.call_safe_int64_tsfn(*target, C.int64_t(key), C.int64_t(value)) == 0
}

func initClash(env js.Env, this js.Value, args []js.Value) any {
	homeDirStr, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	return handleInitClash(homeDirStr)
}

func startTun(env js.Env, this js.Value, args []js.Value) any {
	tunFd, _ := napi.GetValueInt32(env.Env, args[0].Value)
	handler := createSafeInt64Handler(env, args[1], "startTun")
	replaceSafeHandler(&fdProtectionHandlerMu, &fdProtectionHandler, handler)
	StartTUN(int(tunFd), func(fd Fd) {
		if !callSafeInt64Handler(&fdProtectionHandlerMu, &fdProtectionHandler, fd.Id, fd.Value) {
			log.Warnln("[NAPI] protect-socket callback was not queued")
		}
	})
	return nil
}
func stopTun(env js.Env, this js.Value, args []js.Value) any {
	StopTun()
	return nil
}

func validateConfig(env js.Env, this js.Value, args []js.Value) any {
	paramsString, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	bytes := []byte(paramsString)
	promise := env.NewPromise()
	go func() {
		promise.Resolve(handleValidateConfig(bytes))
	}()
	return promise
}

func convertV2RaySubscription(env js.Env, this js.Value, args []js.Value) any {
	paramsString, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	promise := env.NewPromise()
	go func() {
		content, err := handleConvertV2RaySubscription([]byte(paramsString))
		if err != nil {
			promise.Resolve("")
			return
		}
		promise.Resolve(content)
	}()
	return promise
}

func updateConfig(env js.Env, this js.Value, args []js.Value) any {
	paramsString, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	fmt.Println("updateConfig", paramsString)
	promise := env.NewPromise()
	bytes := []byte(paramsString)
	go func() {
		promise.Resolve(handleUpdateConfig(bytes))
	}()
	return promise
}

func getProxies(env js.Env, this js.Value, args []js.Value) any {
	return handleGetProxies()
}

func changeProxy(env js.Env, this js.Value, args []js.Value) any {
	paramsString, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	promise := env.NewPromise()
	handleChangeProxy(paramsString, func(value string) {
		promise.Resolve(value)
	})
	return promise
}

func getTraffic(env js.Env, this js.Value, args []js.Value) any {
	onlyProxy := true
	return handleGetTraffic(onlyProxy)
}
func getTotalTraffic(env js.Env, this js.Value, args []js.Value) any {
	onlyProxy := true
	return handleGetTotalTraffic(onlyProxy)
}
func resetTraffic(env js.Env, this js.Value, args []js.Value) any {
	handleResetTraffic()
	return nil
}
func forceGc(env js.Env, this js.Value, args []js.Value) any {
	handleForceGc()
	return nil
}
func asyncTestDelay(env js.Env, this js.Value, args []js.Value) any {
	paramsString, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	promise := env.NewPromise()
	handleAsyncTestDelay(paramsString, func(value string) {
		promise.Resolve(value)
	})
	return promise
}
func getExternalProviders(env js.Env, this js.Value, args []js.Value) any {
	return handleGetExternalProviders()
}
func getExternalProvider(env js.Env, this js.Value, args []js.Value) any {
	externalProviderName, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	return handleGetExternalProvider(externalProviderName)
}
func updateGeoData(env js.Env, this js.Value, args []js.Value) any {
	geoType, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	geoName, _ := napi.GetValueStringUtf8(env.Env, args[1].Value)
	promise := env.NewPromise()
	handleUpdateGeoData(geoType, geoName, func(value string) {
		promise.Resolve(value)
	})
	return promise
}
func updateExternalProvider(env js.Env, this js.Value, args []js.Value) any {
	providerName, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	promise := env.NewPromise()
	handleUpdateExternalProvider(providerName, func(value string) {
		promise.Resolve(value)
	})
	return promise
}

func sideLoadExternalProvider(env js.Env, this js.Value, args []js.Value) any {
	providerName, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	dataChar, _ := napi.GetValueStringUtf8(env.Env, args[1].Value)
	data := []byte(dataChar)
	promise := env.NewPromise()
	handleSideLoadExternalProvider(providerName, data, func(value string) {
		promise.Resolve(value)
	})
	return promise
}
func getConnections(env js.Env, this js.Value, args []js.Value) any {
	return handleGetConnections()
}

func closeConnections(env js.Env, this js.Value, args []js.Value) any {
	return handleCloseConnections()
}

func closeConnection(env js.Env, this js.Value, args []js.Value) any {
	connectionId, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	return handleCloseConnection(connectionId)
}

func startLog(env js.Env, this js.Value, args []js.Value) any {
	handler := createSafeStringHandler(env, args[0], "startLog")
	replaceSafeHandler(&logHandlerMu, &logHandler, handler)
	handleStartLog(func(value string) {
		if !callSafeStringHandler(&logHandlerMu, &logHandler, "startLog", value) {
			log.Warnln("[NAPI] log callback was not queued")
		}
	})
	return nil
}

func stopLog(env js.Env, this js.Value, args []js.Value) any {
	handleStopLog()
	return nil
}
func getCountryCode(env js.Env, this js.Value, args []js.Value) any {
	ip, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	promise := env.NewPromise()
	handleGetCountryCode(ip, func(value string) {
		promise.Resolve(value)
	})
	return promise
}
func getMemory(env js.Env, this js.Value, args []js.Value) any {
	promise := env.NewPromise()
	handleGetMemory(func(value string) {
		promise.Resolve(value)
	})
	return promise
}
func updateDns(env js.Env, this js.Value, args []js.Value) any {
	dnsList, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	promise := env.NewPromise()
	go func() {
		log.Infoln("[DNS] updateDns %s", dnsList)
		dns.UpdateSystemDNS(strings.Split(dnsList, ","))
		dns.FlushCacheWithDefaultResolver()
		promise.Resolve(nil)
	}()
	return promise
}
func setState(env js.Env, this js.Value, args []js.Value) any {
	paramsString, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	err := json.Unmarshal([]byte(paramsString), state.CurrentState)
	if err != nil {
		return nil
	}
	return nil
}
func setProcessMap(env js.Env, this js.Value, args []js.Value) any {
	paramsString, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	return SetProcessMap(paramsString)
}

func getVpnOptions(env js.Env, this js.Value, args []js.Value) any {
	return GetVpnOptions()
}
func getCurrentProfileName(env js.Env, this js.Value, args []js.Value) any {
	if state.CurrentState == nil {
		return ""
	}
	return state.CurrentState.CurrentProfileName
}

func setFdMap(env js.Env, this js.Value, args []js.Value) any {
	fdInt, _ := napi.GetValueInt32(env.Env, args[0].Value)
	protected := int32(1)
	if len(args) > 1 {
		protected, _ = napi.GetValueInt32(env.Env, args[1].Value)
	}
	go func() {
		// The first argument is the request id emitted by the Go socket hook.
		// Complete the event-driven waiter as well as the legacy map; otherwise
		// every connection waits for the two-second fallback timeout.
		setFdProtectionResult(int64(fdInt), protected != 0)
	}()
	return nil
}

func registerMessage(env js.Env, this js.Value, args []js.Value) any {
	log.Infoln("[ProcessBridge] Harmony message callback registered")
	handler := createSafeStringHandler(env, args[0], "messageTsfn")
	replaceSafeHandler(&messageHandlerMu, &messageHandler, handler)
	return nil
}
func getRequestList(env js.Env, this js.Value, args []js.Value) any {
	json, _ := json.Marshal(reqeustList)
	return env.ValueOf(string(json))
}

func clearRequestList(env js.Env, this js.Value, args []js.Value) any {
	reqeustList = []statistic.Tracker{}
	return env.ValueOf("")
}
func startListener(env js.Env, this js.Value, args []js.Value) any {
	// Listener recreation may close and reopen several local sockets. Newer
	// Mihomo releases can spend seconds in that work, so never hold ArkUI's NAPI
	// callback while it completes. The system VPN TUN is started independently.
	go handleStartListener()
	return env.ValueOf("")
}
func stopListener(env js.Env, this js.Value, args []js.Value) any {
	go handleStopListener()
	return env.ValueOf("")
}
func startIpc(env js.Env, this js.Value, args []js.Value) any {
	path, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	go startIpcProxy(path)
	return env.ValueOf("")
}

func init() {
	entry.Export("initClash", js.AsCallback(initClash))
	entry.Export("startTun", js.AsCallback(startTun))
	entry.Export("setFdMap", js.AsCallback(setFdMap))
	entry.Export("stopTun", js.AsCallback(stopTun))
	entry.Export("forceGc", js.AsCallback(forceGc))
	entry.Export("validateConfig", js.AsCallback(validateConfig))
	entry.Export("convertV2RaySubscription", js.AsCallback(convertV2RaySubscription))
	entry.Export("updateConfig", js.AsCallback(updateConfig))
	entry.Export("getTraffic", js.AsCallback(getTraffic))
	entry.Export("getTotalTraffic", js.AsCallback(getTotalTraffic))
	entry.Export("resetTraffic", js.AsCallback(resetTraffic))
	entry.Export("getProxies", js.AsCallback(getProxies))
	entry.Export("changeProxy", js.AsCallback(changeProxy))
	entry.Export("asyncTestDelay", js.AsCallback(asyncTestDelay))
	entry.Export("getConnections", js.AsCallback(getConnections))
	entry.Export("closeConnections", js.AsCallback(closeConnections))
	entry.Export("closeConnection", js.AsCallback(closeConnection))
	entry.Export("updateExternalProvider", js.AsCallback(updateExternalProvider))
	entry.Export("sideLoadExternalProvider", js.AsCallback(sideLoadExternalProvider))
	entry.Export("getExternalProviders", js.AsCallback(getExternalProviders))
	entry.Export("getVpnOptions", js.AsCallback(getVpnOptions))
	entry.Export("getCurrentProfileName", js.AsCallback(getCurrentProfileName))
	entry.Export("setProcessMap", js.AsCallback(setProcessMap))
	entry.Export("updateGeoData", js.AsCallback(updateGeoData))
	entry.Export("startListener", js.AsCallback(startListener))
	entry.Export("stopListener", js.AsCallback(stopListener))
	entry.Export("startIpc", js.AsCallback(startIpc))

	entry.Export("updateDns", js.AsCallback(updateDns))
	entry.Export("startLog", js.AsCallback(startLog))
	entry.Export("stopLog", js.AsCallback(stopLog))
	entry.Export("registerMessage", js.AsCallback(registerMessage))
	entry.Export("getRequestList", js.AsCallback(getRequestList))
	entry.Export("clearRequestList", js.AsCallback(clearRequestList))

	entry.Export("getCountryCode", js.AsCallback(getCountryCode))
	entry.Export("getMemory", js.AsCallback(getMemory))

}

func sendMessage(message Message) {
	// Only process-resolution requests cross the N-API bridge. They are emitted
	// on a connection's hot path and the resolver waits for setProcessMap; the
	// threadsafe function queues the callback on ArkTS without blocking Go.
	if message.Type != ProcessMessage {
		return
	}
	res, err := message.Json()
	if err != nil {
		return
	}
	if callSafeStringHandler(&messageHandlerMu, &messageHandler, string(message.Type), res) {
		log.Debugln("[ProcessBridge] dispatch process message")
	} else {
		log.Warnln("[ProcessBridge] process message dropped: callback is not registered")
	}
}

func main() {
}
