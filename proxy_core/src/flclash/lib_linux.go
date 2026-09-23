//go:build ohos && cgo

package main

import "C"
import (
	"core/platform"
	"core/state"
	t "core/tun"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"net"
	"net/netip"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/iface"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
)

type ProcessMap struct {
	m sync.Map
}

type FdMap struct {
	m sync.Map
}

// FdWaitMap is the completion side of the Go↔ArkTS socket-protection bridge.
// The previous implementation polled FdMap every 20ms.  Apart from wasting a
// native thread per dial, polling made a burst of ChatGPT TLS/WebSocket dials
// line up behind the 500ms fallback timer.  A one-shot channel lets the dial
// continue as soon as VpnConnection.protect() has actually completed.
type FdWaitMap struct {
	m sync.Map
}

func (wm *FdWaitMap) Store(key int64, ch chan FdProtectionResult) {
	wm.m.Store(key, ch)
}

func (wm *FdWaitMap) Load(key int64) (chan FdProtectionResult, bool) {
	value, ok := wm.m.Load(key)
	if !ok || value == nil {
		return nil, false
	}
	ch, ok := value.(chan FdProtectionResult)
	return ch, ok
}

func (wm *FdWaitMap) Delete(key int64) {
	wm.m.Delete(key)
}

// FdProtectionResult records the VPN extension's acknowledgement for a raw
// socket. Harmony can report a stale/closed fd while the socket is already in
// flight, so this result is diagnostic rather than a reason to abort the dial.
type FdProtectionResult struct {
	protected bool
}

type Fd struct {
	Id    int64 `json:"id"`
	Value int64 `json:"value"`
}

var (
	tunListener *sing_tun.Listener
	fdMap       FdMap
	fdWaitMap   FdWaitMap
	fdCounter   int64 = 0
	counter     int64 = 0
	processMap  ProcessMap
	tunLock     sync.Mutex
	runTime     *time.Time
	errBlocked  = errors.New("blocked")
)

func (cm *ProcessMap) Store(key int64, value string) {
	cm.m.Store(key, value)
}

func (cm *ProcessMap) Load(key int64) (string, bool) {
	value, ok := cm.m.Load(key)
	if !ok || value == nil {
		return "", false
	}
	cm.m.Delete(key)
	return value.(string), true
}

func (cm *FdMap) Store(key int64, protected bool) {
	cm.m.Store(key, FdProtectionResult{protected: protected})
}

func (cm *FdMap) Load(key int64) (protected bool, ready bool) {
	value, ok := cm.m.LoadAndDelete(key)
	if !ok || value == nil {
		return false, false
	}
	result, ok := value.(FdProtectionResult)
	if !ok {
		return false, true
	}
	return result.protected, true
}

// StartTUN preserves the N-API entry point used by the non-RPC caller.  The
// VPN control RPC uses StartTUNWithReady below so it can distinguish "the
// system accepted the VPN fd" from "gVisor is actually reading that fd".
func StartTUN(fd int, markSocket func(Fd)) {
	StartTUNWithReady(fd, markSocket, nil)
}

// StartTUNWithReady reports completion only after sing-tun has created the
// userspace listener and runTime has been published.  Harmony installs the
// system VPN route before this work finishes; acknowledging earlier leaves a
// short black-hole window in which a freshly launched HTTPS client can cache a
// TLS/network-configuration failure for the rest of its process lifetime.
func StartTUNWithReady(fd int, markSocket func(Fd), onReady func(error)) {
	if fd == 0 {
		tunLock.Lock()
		defer tunLock.Unlock()
		now := time.Now()
		runTime = &now
		if onReady != nil {
			onReady(nil)
		}
		// SendMessage(Message{
		// 	Type: StartedMessage,
		// 	Data: strconv.FormatInt(runTime.UnixMilli(), 10),
		// })
		return
	}
	// HarmonyOS API 22+ can protect the whole VPN Extension process in one
	// operation. In that mode no per-socket bridge is needed; keeping it active
	// would add an ArkTS round trip to every outbound connection. A nil callback
	// is the explicit signal from the control RPC that process protection is on.
	if markSocket != nil {
		log.Infoln("[ClashVPN-DIAG] StartTUN protection=per-fd stack=%s", currentConfig.General.Tun.Stack)
		initSocketHook(markSocket)
	} else {
		log.Infoln("[ClashVPN-DIAG] StartTUN protection=process stack=%s", currentConfig.General.Tun.Stack)
		removeSocketHook()
	}
	go func() {
		tunLock.Lock()
		defer tunLock.Unlock()
		f := int(fd)
		listener, err := t.Start(f, currentConfig.General.Tun.Device, currentConfig.General.Tun.Stack, currentConfig.General.Tun.DNSHijack)
		if err != nil {
			runTime = nil
			removeSocketHook()
			if onReady != nil {
				onReady(err)
			}
			return
		}
		tunListener = listener
		if tunListener != nil {
			log.Infoln("TUN address: %v", tunListener.Address())
		}
		now := time.Now()
		runTime = &now
		if onReady != nil {
			onReady(nil)
		}
	}()
}

func GetRunTime() string {
	if runTime == nil {
		return "clash服务未启动"
	}
	return strconv.FormatInt(runTime.UnixMilli(), 10)
}
func ConfigInited() string {
	if currentConfig != nil {
		return "true"
	}
	return "false"
}

func StopTun() {
	// StopClash is the ordering barrier before a later StartClash.  Returning
	// while teardown is still running lets a fast stop/start reuse the old
	// listener, control socket, or protection hook and is a reliable way to
	// create long-lived TLS/WebSocket stalls.  Keep this operation synchronous;
	// the RPC caller already awaits it and listener.Close is bounded locally.
	tunLock.Lock()
	defer tunLock.Unlock()

	runTime = nil
	// Stop the streaming Go↔VPN Extension control channel before removing
	// the socket hook. This prevents a late fd callback from the previous
	// VPN session from being written to a closed Harmony LocalSocket.
	closeClashControlConn()

	if tunListener != nil {
		_ = tunListener.Close()
		tunListener = nil
	}
	removeSocketHook()
}

// setFdProtectionResult is the single completion path for both the current
// event-driven bridge and the legacy FdMap.  The ArkTS side reports the
// request id (not the raw socket fd), so this must wake the channel registered
// by initSocketHook.  Writing only fdMap leaves the new waiters asleep until
// their two-second fallback timer, which is exactly the repeated delay seen
// on ChatGPT's parallel TLS/WebSocket dials.
func setFdProtectionResult(id int64, protected bool) {
	result := FdProtectionResult{protected: protected}
	fdMap.Store(id, protected)
	if ch, ok := fdWaitMap.Load(id); ok {
		// The channel is buffered and the result is one-shot. A duplicate or
		// late acknowledgement must not block the N-API callback goroutine.
		select {
		case ch <- result:
		default:
		}
	}
}

func SetFdMapResult(fd C.long, protected bool) {
	setFdProtectionResult(int64(fd), protected)
}

func initSocketHook(markSocket func(Fd)) {
	dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
		if platform.ShouldBlockConnection() {
			return errBlocked
		}
		var protectionError error
		if err := conn.Control(func(fd uintptr) {
			fdInt := int64(fd)
			startedAt := time.Now()
			id := atomic.AddInt64(&fdCounter, 1)
			log.Debugln("[Protect] request id=%d fd=%d network=%s address=%s", id, fdInt, network, address)

			// Direct mode does not install a VPN route for this socket.  Avoid
			// creating an IPC request in that case.
			if currentConfig != nil && string(currentConfig.General.Mode) == "direct" {
				return
			}

			waitCh := make(chan FdProtectionResult, 1)
			fdWaitMap.Store(id, waitCh)

			markSocket(Fd{
				Id:    id,
				Value: fdInt,
			})

			// Keep a bounded wait for a system-side protect() result. A socket
			// that was not protected must not continue silently: on a TUN VPN it
			// can enter the tunnel with a half-open TLS session and appear to the
			// caller as an endless "sending" state. Returning an error lets the
			// higher-level HTTP client retry on a fresh fd.
			select {
			case result := <-waitCh:
				if !result.protected {
					protectionError = errors.New("vpn socket protection failed")
					log.Warnln("[Protect] failed id=%d fd=%d elapsed=%s", id, fdInt, time.Since(startedAt))
				} else {
					log.Debugln("[Protect] ok id=%d fd=%d elapsed=%s", id, fdInt, time.Since(startedAt))
				}
			case <-time.After(2 * time.Second):
				protectionError = errors.New("vpn socket protection timeout")
				log.Warnln("[Protect] timeout id=%d fd=%d elapsed=%s", id, fdInt, time.Since(startedAt))
			}
			fdWaitMap.Delete(id)
		}); err != nil {
			return err
		}
		return protectionError
	}
}

func removeSocketHook() {
	dialer.DefaultSocketHook = nil
}

func init() {
	process.DefaultPackageNameResolver = func(metadata *constant.Metadata) (string, error) {
		if metadata == nil {
			return "", process.ErrInvalidNetwork
		}
		// Harmony Android-compatibility traffic currently arrives with UID 0.
		// BundleManager cannot map it to a package, so crossing Go -> ArkTS and
		// polling for an empty answer only delays every new HTTPS connection.
		// Connection UI attribution for these apps is performed from sniffed host.
		if metadata.Uid == 0 {
			return "", process.ErrNotFound
		}
		id := atomic.AddInt64(&counter, 1)

		timeout := time.After(200 * time.Millisecond)
		log.Debugln("[ProcessBridge] request id=%d network=%s source=%s uid=%d process=%s", id,
			metadata.NetWork.String(), metadata.SourceAddress(), metadata.Uid, metadata.Process)

		sendMessage(Message{
			Type: ProcessMessage,
			Data: Process{
				Id:       id,
				Metadata: metadata,
			},
		})

		for {
			select {
			case <-timeout:
				log.Debugln("[ProcessBridge] timeout id=%d uid=%d", id, metadata.Uid)
				return "", errors.New("package resolver timeout")
			default:
				value, exists := processMap.Load(id)
				if exists {
					return value, nil
				}
				time.Sleep(20 * time.Millisecond)
			}
		}
	}
}

func SetProcessMap(s string) string {
	paramsString := s
	go func() {
		var processMapItem = &ProcessMapItem{}
		err := json.Unmarshal([]byte(paramsString), processMapItem)
		if err == nil {
			log.Debugln("[ProcessBridge] response id=%d value=%s", processMapItem.Id, processMapItem.Value)
			processMap.Store(processMapItem.Id, processMapItem.Value)
		}
	}()
	return ""
}

func GetCurrentProfileName() string {
	if state.CurrentState == nil {
		return ""
	}
	return state.CurrentState.CurrentProfileName
}

func GetVpnOptions() string {
	tunLock.Lock()
	defer tunLock.Unlock()
	port := 7980
	if currentConfig != nil {
		port = currentConfig.General.MixedPort
	}
	options := state.AndroidVpnOptions{
		Enable:           state.CurrentState.Enable,
		Port:             port,
		Ipv4Address:      state.CurrentState.TunIp,
		Ipv6Address:      state.GetIpv6Address(),
		AccessControl:    state.CurrentState.AccessControl,
		SystemProxy:      state.CurrentState.SystemProxy,
		AllowBypass:      state.CurrentState.AllowBypass,
		RouteAddress:     state.CurrentState.RouteAddress,
		BypassDomain:     state.CurrentState.BypassDomain,
		DnsServerAddress: state.GetDnsServerAddress(),
	}
	data, err := json.Marshal(options)
	if err != nil {
		fmt.Println("Error:", err)
		return ""
	}
	return string(data)
}

func SetState(s *C.char) {
	paramsString := C.GoString(s)
	err := json.Unmarshal([]byte(paramsString), state.CurrentState)
	if err != nil {
		return
	}
}

func UpdateDns(s *C.char) {
	dnsList := C.GoString(s)
	go func() {
		log.Infoln("[DNS] updateDns %s", dnsList)
		dns.UpdateSystemDNS(strings.Split(dnsList, ","))
		dns.FlushCacheWithDefaultResolver()
	}()
}

type NetIpMacInfo struct {
	IpAddress  NetAddress `json:"ipAddress"`
	Iface      string     `json:"iface"`
	MacAddress string     `json:"macAddress"`
}
type NetAddress struct {
	Address string `json:"address"` // IP地址
	Family  int    `json:"family"`  // 地址族：4(IPv4)或6(IPv6)
	Port    int    `json:"port"`    // 端口号（如果有）
}

func (info *NetIpMacInfo) ToNetInterface() (*net.Interface, error) {
	// 解析 MAC 地址
	var mac net.HardwareAddr
	if info.MacAddress != "" {
		var err error
		mac, err = net.ParseMAC(info.MacAddress)
		if err != nil {
			return nil, fmt.Errorf("parse MAC address failed: %w", err)
		}
	}

	// 获取接口索引（通过接口名）
	var index int
	if info.Iface != "" {
		iface, err := net.InterfaceByName(info.Iface)
		if err == nil && iface != nil {
			index = iface.Index
		}
	}

	return &net.Interface{
		Index:        index,
		MTU:          1500, // 默认值，你可能需要从其他地方获取
		Name:         info.Iface,
		HardwareAddr: mac,
		Flags:        getInterfaceFlags(info), // 需要实现这个函数
	}, nil
}
func getInterfaceFlags(info *NetIpMacInfo) net.Flags {
	var flags net.Flags

	// HarmonyOS does not expose the physical MAC to the app. A valid address
	// from ConnectionProperties is still a live, usable interface snapshot.
	if info.MacAddress != "" || info.IpAddress.Address != "" {
		flags |= net.FlagUp
		flags |= net.FlagBroadcast
		flags |= net.FlagMulticast
	}

	// 检查是否为回环接口
	if info.Iface == "lo" || info.Iface == "lo0" {
		flags |= net.FlagLoopback
	}
	return flags
}

func SetInterfaces(paramsString string) error {
	interfaces := make(map[string]*iface.Interface)
	var infos []NetIpMacInfo
	// json.Unmarshal needs the slice address so it can allocate and populate
	// the interface list. Passing the slice value leaves `infos` nil, silently
	// dropping the physical-interface snapshot used by route selection.
	err := json.Unmarshal([]byte(paramsString), &infos)
	if err != nil {
		return err
	}
	seen := make(map[string]bool) // 去重
	for _, info := range infos {
		if seen[info.Iface] {
			continue
		}
		ifa, err := info.ToNetInterface()
		if err != nil {
			continue // 或者返回错误
		}

		if ifa != nil {
			prefixes := make([]netip.Prefix, 0, 1)
			if addr, parseErr := netip.ParseAddr(info.IpAddress.Address); parseErr == nil {
				bits := 128
				if addr.Is4() {
					bits = 32
				}
				prefixes = append(prefixes, netip.PrefixFrom(addr.Unmap(), bits))
			}
			interfaces[ifa.Name] = &iface.Interface{
				Index:        ifa.Index,
				MTU:          ifa.MTU,
				Name:         ifa.Name,
				HardwareAddr: ifa.HardwareAddr,
				Flags:        ifa.Flags,
				Addresses:    prefixes,
			}
			seen[info.Iface] = true
		}
	}
	iface.SetInterfaces(interfaces)
	return nil
}
