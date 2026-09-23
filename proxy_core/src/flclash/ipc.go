package main

import (
	"core/state"
	"encoding/json"
	"log"
	"net"
	"os"
	"strconv"
	"sync"

	"github.com/metacubex/mihomo/tunnel/statistic"
)

const tunReadyResult = "__TUN_READY__"

// StartClash is a session-scoped streaming RPC.  Keep only the connection for
// the current VPN session: when Harmony destroys the extension, the peer side
// closes its socket, but the Go server otherwise has no event that tells it to
// discard the old net.Conn.  Reusing the stale connection caused writes to a
// closed fd (NETSTACK errno=9) and let a later session inherit old callbacks.
// controlConnection wraps the long-lived fd-protection socket.  Harmony's
// LocalSocket implementation is more sensitive than a regular net.Conn to
// concurrent writes; a burst of HTTPS dials used to make several goroutines
// write the same accepted socket at once.  Serializing frames here also keeps
// JSON+EOF boundaries intact.
type controlConnection struct {
	conn    net.Conn
	writeMu sync.Mutex
	closed  bool
}

var clashControlState struct {
	sync.Mutex
	conn *controlConnection
}

func replaceClashControlConn(conn net.Conn) *controlConnection {
	current := &controlConnection{conn: conn}
	clashControlState.Lock()
	previous := clashControlState.conn
	clashControlState.conn = current
	clashControlState.Unlock()
	if previous != nil && previous != current {
		closeControlConnection(previous)
	}
	return current
}

func clearClashControlConn(conn net.Conn) {
	clashControlState.Lock()
	current := clashControlState.conn
	if current != nil && current.conn == conn {
		clashControlState.conn = nil
	}
	clashControlState.Unlock()
}

func closeControlConnection(control *controlConnection) {
	if control == nil {
		return
	}
	// net.Conn.Close is concurrency-safe and interrupts a blocked Write. Do it
	// before waiting for writeMu; taking the mutex first can deadlock teardown
	// behind a peer that stopped reading the protection stream.
	_ = control.conn.Close()
	control.writeMu.Lock()
	control.closed = true
	control.writeMu.Unlock()
}

func closeClashControlConn() {
	clashControlState.Lock()
	previous := clashControlState.conn
	clashControlState.conn = nil
	clashControlState.Unlock()
	closeControlConnection(previous)
}

// writeControlFrame only writes while the connection is still the active VPN
// session.  A node switch can otherwise close the old socket while a delayed
// fd callback is still trying to use it.
func writeControlFrame(control *controlConnection, payload []byte) error {
	if control == nil {
		return net.ErrClosed
	}
	clashControlState.Lock()
	active := clashControlState.conn == control
	if active {
		control.writeMu.Lock()
	}
	clashControlState.Unlock()
	if !active {
		return net.ErrClosed
	}
	defer control.writeMu.Unlock()
	if control.closed {
		return net.ErrClosed
	}
	if _, err := control.conn.Write(payload); err == nil {
		return nil
	} else {
		// Harmony LocalSocket has shipped builds where the accepted endpoint is
		// reported as a connected Unix socket but is backed by a datagram-like
		// descriptor.  net.Conn.Write then returns `destination address
		// required`; retry the same frame with the peer's abstract Unix address.
		// The first attempt reports n=0 on this path, so the frame is not
		// duplicated.
		if unixConn, ok := control.conn.(*net.UnixConn); ok {
			if remote, remoteOK := unixAddr(control.conn.RemoteAddr()); remoteOK {
				if _, retryErr := unixConn.WriteToUnix(payload, remote); retryErr == nil {
					log.Printf("ipc_go response write fallback=WriteToUnix remote=%s", remote.String())
					return nil
				} else {
					err = retryErr
				}
			}
		}
		control.closed = true
		return err
	}
}

func unixAddr(addr net.Addr) (*net.UnixAddr, bool) {
	if addr == nil {
		return nil, false
	}
	if unixAddr, ok := addr.(*net.UnixAddr); ok {
		return unixAddr, true
	}
	// A few OHOS net.Conn implementations only expose the address string.
	// An abstract Unix name is represented by an initial '@' in diagnostics;
	// net.UnixAddr expects the leading NUL to be added by the syscall layer.
	name := addr.String()
	if name == "" {
		return nil, false
	}
	if name[0] == '@' {
		name = "\x00" + name[1:]
	}
	return &net.UnixAddr{Name: name, Net: "unix"}, true
}

func startIpcProxy(path string) {
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		log.Println("ipc_go", err)
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		log.Println("ipc_go", err)
		return
	}
	defer listener.Close()
	log.Println("ipc_go", "Server is listening on", path)
	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Println("ipc_go Accept err:", err)
			continue
		}
		go handleConnection(conn)
	}
}
func handleConnection(conn net.Conn) {
	if conn == nil {
		return
	}
	// Never let malformed or stale requests take down the native core. This is
	// particularly important during a node switch, when the UI can race a
	// proxy-list refresh and briefly observe an incomplete group.
	defer func() {
		if recovered := recover(); recovered != nil {
			log.Println("ipc_go request panic recovered:", recovered)
			_ = conn.Close()
		}
	}()
	buffer := make([]byte, 10240)

	n, err := conn.Read(buffer)
	if err != nil {
		log.Println("ipc_go", err)
		_ = conn.Close()
		return
	}
	if n == 0 {
		_ = conn.Close()
		return
	}
	request := RpcRequest{}
	err = json.Unmarshal(buffer[:n], &request)
	if err != nil {
		log.Println("ipc_go error", err)
		_ = conn.Close()
		return
	}
	var control *controlConnection
	if request.Method == StartClash {
		control = replaceClashControlConn(conn)
		log.Println("ipc_go StartClash control connection installed")
	}
	handleRemoteRequest(request, func(rr RpcResult) {
		res, _ := json.Marshal(rr)
		payload := []byte(string(res) + "EOF")
		var err error
		if control != nil {
			err = writeControlFrame(control, payload)
		} else {
			_, err = conn.Write(payload)
		}
		if err != nil {
			log.Println("ipc_go response write error", err)
			if control != nil {
				clearClashControlConn(conn)
			}
		}
		// Harmony LocalSocket may retain the final received bytes until the server
		// closes. One-shot RPCs therefore end at their first response. The log
		// observer is a streaming RPC and deliberately keeps its connection open.
		if request.Method != SetLogObserver && request.Method != StartClash {
			_ = conn.Close()
		}
	})
	if request.Method != SetLogObserver && request.Method != StartClash {
		clearClashControlConn(conn)
	}
}

type RpcRequest struct {
	Key    int          `json:"key"`
	Method ClashRpcType `json:"method"`
	Params []any        `json:"params"`
}
type RpcResult struct {
	Key    int          `json:"key"`
	Method ClashRpcType `json:"method"`
	Result string       `json:"result"`
	Error  string       `json:"error"`
}
type ClashRpcType int

// 定义常量来模拟枚举
const (
	QueryTrafficNow ClashRpcType = iota
	QueryTunnelState
	QueryTrafficTotal
	QueryProxyGroup
	QueryProviders
	ChangeProxy
	HealthCheck
	UpdateProvider
	UploadProvider
	QueryConnections
	CloseConnection
	ClearConnections
	Load
	StartClash
	StopClash
	ValidConfig
	Reset
	GetCountryCode
	UpdateGeoData
	RegisterOnMessage
	GetRequestList
	ClearRequestList
	SetLogObserver
	StopLogObserver
	VpnOptions
	SetOptionState
	GetVpnRunTime
	VpnConfigInited
	SetNetInterfaces
	NodeQualityCheck
	NodeQualityProgress
	NodeQualityCancel
)

func handleRemoteRequest(request RpcRequest, fn func(RpcResult)) {
	ret := RpcResult{
		Key:    request.Key,
		Method: request.Method,
	}
	switch request.Method {
	case QueryTrafficNow:
		onlyProxy := true
		if len(request.Params) > 1 {
			res, _ := request.Params[0].(bool)
			onlyProxy = res
		}
		ret.Result = handleGetTraffic(onlyProxy)

		fn(ret)
	case QueryTrafficTotal:
		onlyProxy := true
		if len(request.Params) > 1 {
			res, _ := request.Params[0].(bool)
			onlyProxy = res
		}
		ret.Result = handleGetTotalTraffic(onlyProxy)
		fn(ret)
	case QueryProviders:
		ret.Result = handleGetExternalProviders()
		fn(ret)
	case QueryConnections:
		ret.Result = handleGetConnections()
		fn(ret)
	case QueryProxyGroup:
		ret.Result = handleGetProxies()
		fn(ret)
	case GetCountryCode:
		str, _ := request.Params[0].(string)
		handleGetCountryCode(str, func(value string) {
			ret.Result = value
			fn(ret)
		})
	case GetRequestList:
		ret.Result = HandleRequestList()
		fn(ret)
	case ClearRequestList:
		reqeustList = []statistic.Tracker{}
		fn(ret)
	case CloseConnection:
		str, _ := request.Params[0].(string)
		handleCloseConnection(str)
		fn(ret)
	case ClearConnections:
		handleCloseConnections()
		fn(ret)
	case Load:
		paramsString, _ := request.Params[0].(string)
		bytes := []byte(paramsString)
		ret.Result = handleUpdateConfig(bytes)
		fn(ret)
	case Reset:
		handleForceGc()
		fn(ret)
	case ValidConfig:
		filePath, _ := request.Params[0].(string)
		data, err := os.ReadFile(filePath)
		if err != nil {
			ret.Error = err.Error()
			fn(ret)
			return
		}
		ret.Result = handleValidateConfig(data)
		fn(ret)

	case UpdateGeoData:
		geoType, _ := request.Params[0].(string)
		geoName, _ := request.Params[1].(string)
		handleUpdateGeoData(geoType, geoName, func(value string) {
			ret.Result = value
			fn(ret)
		})
	case UpdateProvider:
		name, _ := request.Params[0].(string)
		handleUpdateExternalProvider(name, func(value string) {
			ret.Result = value
			fn(ret)
		})
	case UploadProvider:
		provider, _ := request.Params[0].(string)
		pathUri, _ := request.Params[1].(string)
		data, err := os.ReadFile(pathUri)
		if err != nil {
			ret.Error = err.Error()
			fn(ret)
			return
		}
		handleSideLoadExternalProvider(provider, data, func(value string) {
			ret.Result = value
			fn(ret)
		})
	case ChangeProxy:
		group, _ := request.Params[0].(string)
		proxy, _ := request.Params[1].(string)
		proyInfo := map[string]string{
			"group-name": group,
			"proxy-name": proxy,
		}
		json, _ := json.Marshal(proyInfo)
		handleChangeProxy(string(json), func(value string) {
			ret.Result = value
			fn(ret)
		})
	case HealthCheck:
		if len(request.Params) < 2 {
			ret.Error = "invalid health check parameters"
			fn(ret)
			return
		}
		name, _ := request.Params[0].(string)
		timeout := anyToInt(request.Params[1])
		testURL := ""
		if len(request.Params) > 2 {
			testURL, _ = request.Params[2].(string)
		}
		testInfo := map[string]any{
			"proxy-name": name,
			"timeout":    timeout,
			"url":        testURL,
		}
		json, _ := json.Marshal(testInfo)

		handleAsyncTestDelay(string(json), func(value string) {
			ret.Result = value
			fn(ret)
		})
	case NodeQualityCheck:
		if len(request.Params) < 2 {
			ret.Error = "invalid node quality parameters"
			fn(ret)
			return
		}
		name, _ := request.Params[0].(string)
		mode, _ := request.Params[1].(string)
		params, _ := json.Marshal(nodeQualityParams{ProxyName: name, Mode: mode})
		ret.Result = handleNodeQualityCheck(string(params))
		fn(ret)
	case NodeQualityProgress:
		ret.Result = getSustainedProgress()
		fn(ret)
	case NodeQualityCancel:
		ret.Result = strconv.FormatBool(cancelSustainedProgress())
		fn(ret)
	case SetLogObserver:
		handleStartLog(func(value string) {
			ret.Result = value
			fn(ret)
		})
	case StopLogObserver:
		handleStopLog()
		fn(ret)
	case StartClash:
		tunFd := anyToInt(request.Params[0])
		log.Println("ipc_go", "tunFd", tunFd)
		// params[1] is true when the Harmony VPN Extension successfully called
		// protectProcessNet(). In that case all core sockets are already excluded
		// from the TUN and the fd-by-fd LocalSocket bridge is skipped. Requests
		// from older callers keep the original fallback behaviour.
		processProtected := false
		if len(request.Params) > 1 {
			processProtected, _ = request.Params[1].(bool)
		}
		log.Printf("ClashVPN-DIAG StartClash tunFd=%d processProtected=%t", tunFd, processProtected)
		// Protection requests and the final readiness acknowledgement share one
		// streaming connection. Build a fresh RpcResult for every callback so a
		// burst of fd requests cannot race the readiness frame's Result/Error.
		emit := func(result string, requestErr error) {
			response := ret
			response.Result = result
			if requestErr != nil {
				response.Error = requestErr.Error()
			}
			fn(response)
		}
		var markSocket func(Fd)
		if !processProtected {
			markSocket = func(fd Fd) {
				res, _ := json.Marshal(fd)
				emit(string(res), nil)
			}
		}
		StartTUNWithReady(tunFd, markSocket, func(err error) {
			if err != nil {
				emit("", err)
				return
			}
			log.Printf("ClashVPN-DIAG TUN ready tunFd=%d", tunFd)
			emit(tunReadyResult, nil)
		})
	case StopClash:
		StopTun()
		fn(ret)
	case VpnOptions:
		ret.Result = GetVpnOptions()
		fn(ret)
	case SetOptionState:
		paramsString, _ := request.Params[0].(string)
		err := json.Unmarshal([]byte(paramsString), state.CurrentState)
		if err != nil {
			ret.Error = err.Error()
		} else {
			ret.Result = ""
		}
		fn(ret)
	case GetVpnRunTime:
		ret.Result = GetRunTime()
		fn(ret)
	case VpnConfigInited:
		ret.Result = ConfigInited()
		fn(ret)
	case SetNetInterfaces:
		paramsString, _ := request.Params[0].(string)
		err := SetInterfaces(paramsString)
		if err != nil {
			ret.Error = err.Error()
		} else {
			ret.Result = ""
		}
		fn(ret)
	default:
		ret.Error = "未知请求"
		fn(ret)
	}

}
func HandleRequestList() string {
	json, _ := json.Marshal(reqeustList)
	return string(json)
}

func anyToInt(val any) int {
	switch v := val.(type) {
	case int:
		return v
	case int64:
		return int(v)
	case float64:
		return int(v)
	case string:
		i, err := strconv.Atoi(v)
		if err == nil {
			return i
		}
	}
	return 0
}
