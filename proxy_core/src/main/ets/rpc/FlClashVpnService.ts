import { vpnExtension, socket } from '@kit.NetworkKit';
import {
  startTun, stopTun, setFdMap, getVpnOptions, startLog, getProxies, getTraffic,
  getTotalTraffic,
  getExternalProviders,
  asyncTestDelay,
  updateConfig,
  initClash,
  changeProxy,
  forceGc,
  updateExternalProvider,
  getCountryCode,
  updateGeoData,
  sideLoadExternalProvider,
  getConnections,
  closeConnections,
  closeConnection,
  validateConfig,
  registerMessage,
  setProcessMap,
  getRequestList,
  clearRequestList,
  startListener,
  stopListener
} from 'libflclash.so';
import {
  Address,
  AddressWithPrefix,
  cidrToRoute,
  CommonVpnService,
  VpnConfig
} from './CommonVpnService';
import { JSON, util } from '@kit.ArkTS';
import { bundleManager } from '@kit.AbilityKit';
import { RpcRequest, RpcResult } from './RpcRequest';
import { ClashRpcType } from './IClashManager';
import { ConnectionInfo, LogInfo, Provider, ProxyGroup, ProxyMode, ProxyType, Traffic } from '../models/Common';
import { getHome, getProfilePath } from '../appPath';
import { ClashConfig, Tun, UpdateConfigParams } from '../models/ClashConfig';
import { readFile, readFileUri, readText } from '../fileUtils';

function sleepTime(timeout: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, timeout))
}

export interface AccessControl {
  mode: string
  acceptList: string[]
  rejectList: string[]
  isFilterSystemApp: boolean
}

interface CoreProcessMessage {
  type: string
  data?: {
    id?: number
    metadata?: {
      uid?: number
      process?: string
      processPath?: string
    }
  }
}
export interface VpnOptions {
  enable: boolean,
  port: number,
  ipv4Address: string,
  ipv6Address: string,
  accessControl: AccessControl,
  systemProxy: boolean,
  allowBypass: boolean,
  routeAddress: string[],
  bypassDomain: string[],
  dnsServerAddress: string,
}

// API 20+ 的 VPN 排除路由：这些地址始终使用物理网络，不进入 GLOBAL。
const LOCAL_BYPASS_ROUTES: string[] = [
  "0.0.0.0/8",
  "10.0.0.0/8",
  "100.64.0.0/10",
  "127.0.0.0/8",
  "169.254.0.0/16",
  // 172.19.0.0/30 is the TUN peer network (DNS is 172.19.0.2).
  // Excluding the enclosing 172.16/12 route makes system DNS bypass Mihomo.
  "192.168.0.0/16",
  "224.0.0.0/4",
  "::1/128",
  // fdfe:dcba:9876::/126 is the IPv6 TUN peer network, so fc00::/7 must
  // enter the TUN first; Clash rules still send ordinary ULA traffic DIRECT.
  "fe80::/10",
  "ff00::/8"
]


export class FlClashVpnService extends CommonVpnService {
  vpnConnection: vpnExtension.VpnConnection | undefined
  public configPath: string = ""
  protectSocketPath: string = ""
  // One streaming IPC connection carries protect requests for the lifetime
  // of a VPN run. Reusing/closing it explicitly prevents old runs from
  // delivering stale fds into a newly-created VpnConnection.
  private protectSocket: socket.LocalSocket | undefined
  private protectSession: number = 0

  override async onRemoteMessageRequest(client: socket.LocalSocketConnection, message: socket.LocalSocketMessageInfo): Promise<void> {
    let decoder = new util.TextDecoder()
    let request = JSON.parse(decoder.decodeToString(new Uint8Array(message.message))) as RpcRequest
    let code = request.method
    let params = request.params
    let response = ''
    try {
      let result = await this.onRemoteMessage(code, params)
      response = JSON.stringify({ result: result, error: undefined })
    } catch (e) {
      console.error(`socket stub ${code} result: `, e.message ?? e, e.stack)
      response = JSON.stringify({ error: e.message ?? e })
    }
    try {
      await this.sendClient(client, response)
      // send() 完成只代表数据交给 NetStack；Harmony 仍可能先投递 close、后投递
      // 对端 message。给事件循环一个很短的发送窗口，避免主进程把成功响应误判
      // 成“RPC连接已关闭”，进而触发冷启动恢复风暴。
      await sleepTime(80)
    } finally {
      // ClashBox.sock 是一次性控制 RPC。服务端在完整响应落盘后主动关闭，
      // 客户端可通过正常 FIN 收尾，不再依赖 GC 或与 recv 并发 close。
      try {
        await client.close()
      } catch (_) {
      }
    }
  }
  onRemoteMessage(code: number, data: (string | number | boolean)[]): Promise<string | number | boolean> {
    // 根据code处理客户端的请求
    return new Promise(async (resolve, reject) => {
      switch (code) {
        case ClashRpcType.startClash: {
          startListener()
          this.startVpn().then((r) => {
            resolve(r)
          }).catch((e: Error) => {
            reject(e)
          })
          break;
        }
        case ClashRpcType.stopClash: {
          stopListener()
          this.stopVpn()
          resolve(true)
          break;
        }
        default: {
          resolve("不支持当前操作")
        }
      }
    })
  }

  ParseConfig(): VpnConfig {
    let vpnConfig = new VpnConfig();
    let option = JSON.parse(getVpnOptions()) as VpnOptions
    if (option.routeAddress == undefined) {
      option.routeAddress = []
    }
    if (option.ipv4Address != "") {
      const ips = option.ipv4Address.split("/")
      console.debug("tunIp ", ips)
      const prefixLength = ips.length > 1 ? parseInt(ips[1]) : 30
      vpnConfig.addresses[0] = new AddressWithPrefix(new Address(ips[0], 1), prefixLength)
      vpnConfig.isIPv4Accepted = true
    }
    if (option.ipv6Address != "") {
      const ips = option.ipv6Address.split("/")
      const prefixLength = ips.length > 1 ? parseInt(ips[1]) : 126
      vpnConfig.addresses.push(new AddressWithPrefix(new Address(ips[0], 2), prefixLength))
      vpnConfig.isIPv6Accepted = true
    }
    const routeAddresses: string[] = []
    const addRouteAddress = (cidr: string) => {
      if (cidr != "" && !routeAddresses.includes(cidr)) {
        routeAddresses.push(cidr)
      }
    }
    // Add only the address families enabled by the active profile. In
    // particular, an empty ipv6Address must stay empty: synthesizing one here
    // captures ::/0 even though Mihomo's runtime IPv6 path is disabled.
    option.routeAddress?.forEach(addRouteAddress)
    if (option.ipv4Address != "") {
      addRouteAddress("0.0.0.0/0")
    }
    if (option.ipv6Address != "") {
      addRouteAddress("::/0")
    }
    routeAddresses.forEach((cidr) => {
      const route = cidrToRoute(cidr)
      if (route != null) {
        vpnConfig.routes.push(route)
      }
    })
    LOCAL_BYPASS_ROUTES.forEach((cidr: string) => {
      const route = cidrToRoute(cidr, true)
      if (route != null) {
        vpnConfig.routes.push(route)
      }
    })
    if (option.accessControl?.mode) {
      if (option.accessControl?.mode == "AcceptSelected") {
        vpnConfig.trustedApplications = option.accessControl?.acceptList
      } else {
        vpnConfig.blockedApplications = option.accessControl?.rejectList
      }
    }
    if (option.systemProxy || option.allowBypass) {
      // TODO ohos 不支持
      // not use option.bypassDomain option.port
    }
    console.debug("vpnConfig", JSON.stringify(vpnConfig))
    return vpnConfig;
  }
  override async startVpn(): Promise<boolean> {

    let config = this.ParseConfig();
    let tunFd = -1
    try {
      tunFd = await super.getTunFd(config)
      if (tunFd > -1) {
        const started = await this.startClash(tunFd)
        if (!started) {
          stopTun()
          super.stopVpn()
        }
        return started
      }
      return false;
    } catch (error) {
      console.error("ClashVPN  error ", error)
      return false
    }
  }

  startClash(tunFd: number): Promise<boolean> {
    console.error("ClashVPN-DIAG",
      `startClash tunFd=${tunFd} processProtected=${this.isProcessNetProtectionEnabled()}`)
    const session = ++this.protectSession
    const previous = this.protectSocket
    this.protectSocket = undefined
    if (previous) {
      try { previous.close() } catch (_) {}
    }
    let tcp: socket.LocalSocket = socket.constructLocalSocketInstance();
    this.protectSocket = tcp
    let pending = ''
    // VpnConnection.protect() is backed by a single platform VPN object. A
    // strictly serial queue used to be safe for a quiet connection, but during
    // a Wi-Fi/cellular handoff it let dozens of new sockets pile up behind one
    // slow system call. The old 32-frame cap then reported those sockets as
    // failed, leaving callers connected to the wrong network generation.
    // Keep a small worker window so the platform still sees bounded pressure
    // while a burst can drain before the native dial timeout.
    const protectQueue: string[] = []
    const PROTECT_PARALLELISM = 4
    const PROTECT_QUEUE_LIMIT = 256
    let activeProtects = 0
    const decoder = new util.TextDecoder()
    let readySettled = false
    let readyTimer = -1
    let resolveReady: (value: boolean) => void = (_: boolean): void => {}
    const readyPromise = new Promise<boolean>((resolve): void => {
      resolveReady = resolve
    })
    const settleReady = (started: boolean): void => {
      if (readySettled) return
      readySettled = true
      if (readyTimer !== -1) clearTimeout(readyTimer)
      resolveReady(started)
    }
    const markResult = (id: number, isProtected: boolean): void => {
      // The native hook waits on this per-fd result. A failed or stale fd is
      // deliberately reported as failed so it returns immediately instead of
      // waiting through the bounded hook timeout.
      setFdMap(id, isProtected ? 1 : 0)
    }
    const PROTECT_TIMEOUT_MS = 1200
    const protectWithTimeout = (fd: number): Promise<boolean> => {
      // Harmony's protect() promise has no cancellation API. Do not let one
      // stale/closed fd hold the whole serial queue forever; the late platform
      // completion is ignored by finish() after the bounded failure result.
      return new Promise<boolean>((resolve): void => {
        let settled = false
        const finish = (protectedResult: boolean): void => {
          if (settled) return
          settled = true
          clearTimeout(timer)
          resolve(protectedResult)
        }
        const timer = setTimeout((): void => finish(false), PROTECT_TIMEOUT_MS)
        this.protect(fd).then((): void => finish(true)).catch((): void => finish(false))
      })
    }
    const failQueuedFrame = (element: string): void => {
      try {
        const json = JSON.parse(element) as RpcResult
        if (json.result == null || `${json.result}` === '' || `${json.result}` === '__TUN_READY__') {
          return
        }
        const fd = JSON.parse(json.result as string) as Fd
        if (fd && typeof fd.id === 'number') {
          markResult(fd.id, false)
          console.error('ClashVPN protect queue backpressure', fd.id)
        }
      } catch (_) {
        // Malformed frames are already contained by protectOne().
      }
    }
    const protectOne = async (element: string): Promise<void> => {
      try {
        const json = JSON.parse(element) as RpcResult
        if (json.error != null && `${json.error}` !== '') {
          console.error("ClashVPN core start error", json.error)
          settleReady(false)
          return
        }
        if (`${json.result ?? ''}` === '__TUN_READY__') {
          console.error("ClashVPN-DIAG", `TUN ready tunFd=${tunFd}`)
          settleReady(true)
          return
        }
        if (json.result == null || `${json.result}` === '') {
          return
        }
        const fd = JSON.parse(json.result as string) as Fd
        if (!fd || typeof fd.id !== 'number' || typeof fd.value !== 'number') {
          return
        }
        if (session !== this.protectSession) {
          markResult(fd.id, false)
          return
        }
        try {
          const protectedResult = await protectWithTimeout(fd.value)
          if (!protectedResult) {
            console.error("ClashVPN protect timeout/failure", fd.id, fd.value)
          }
          markResult(fd.id, protectedResult)
        } catch (e) {
          console.error("ClashVPN protect error", e?.message ?? e, element)
          markResult(fd.id, false)
        }
      } catch (e) {
        // The initial StartClash acknowledgement has an empty result. It is
        // valid and is intentionally ignored; malformed fd frames are also
        // ignored without interrupting the long-lived control socket.
        if (element.trim() !== '') {
          console.error("ClashVPN protect frame error", e?.message ?? e, element)
        }
      }
    }
    const drainProtectQueue = (): void => {
      while (activeProtects < PROTECT_PARALLELISM && protectQueue.length > 0) {
        const frame = protectQueue.shift() as string
        activeProtects++
        protectOne(frame).catch((e: Error): void => {
          console.error("ClashVPN protect queue error", e?.message ?? e)
        }).then((): void => {
          activeProtects--
          drainProtectQueue()
        })
      }
    }

    tcp.on('message', (value: socket.LocalSocketMessageInfo) => {
      pending += decoder.decodeToString(new Uint8Array(value.message))
      const frames: string[] = []
      let eofIndex = pending.indexOf("EOF")
      while (eofIndex >= 0) {
        frames.push(pending.substring(0, eofIndex))
        pending = pending.substring(eofIndex + 3)
        eofIndex = pending.indexOf("EOF")
      }
      // Harmony can coalesce several fd frames into one message. Keep the
      // ready/error control frame ahead of socket work, then drain fd frames
      // through the bounded worker window. A failed frame is contained here and
      // does not poison the next item.
      frames.forEach((frame: string): void => {
        let isControlFrame = false
        try {
          const json = JSON.parse(frame) as RpcResult
          isControlFrame = json.error != null || `${json.result ?? ''}` === '__TUN_READY__'
        } catch (_) {
          // protectOne() records malformed frames without affecting later work.
        }
        if (isControlFrame) {
          protectOne(frame).catch((e: Error): void => {
            console.error("ClashVPN control frame error", e?.message ?? e)
          })
          return
        }
        if (protectQueue.length >= PROTECT_QUEUE_LIMIT) {
          failQueuedFrame(frame)
          return
        }
        protectQueue.push(frame)
      })
      drainProtectQueue()
    })
    tcp.on('close', () => {
      if (this.protectSocket === tcp) this.protectSocket = undefined
      settleReady(false)
    })
    tcp.on('error', (e: Error) => {
      console.error("ClashVPN protect socket error", `session=${session}`, e?.message ?? e)
      if (this.protectSocket === tcp) this.protectSocket = undefined
      settleReady(false)
    })
    const socketPath = this.context?.filesDir + '/clash_go.sock'
    console.error("ClashVPN connect", tunFd)
    readyTimer = setTimeout((): void => {
      console.error("ClashVPN-DIAG", `TUN ready timeout tunFd=${tunFd}`)
      settleReady(false)
      try { tcp.close() } catch (_) {}
    }, 12000)
    tcp.connect({ address: { address: socketPath }, timeout: 1000 }).then(() => {
      if (session !== this.protectSession) {
        try { tcp.close() } catch (_) {}
        return
      }
      console.error("ClashVPN connect", tunFd)
      // 把进程级网络保护能力传给 Go。成功时核心无需再逐 socket 回调
      // ArkTS；旧系统/失败时仍保留原有逐 fd 保护路径。
      tcp.send({ data: JSON.stringify({
        method: ClashRpcType.startClash,
        params: [tunFd, this.isProcessNetProtectionEnabled()]
      }) }).catch((e: Error) => {
        console.error("ClashVPN startClash send error", e?.message ?? e)
        settleReady(false)
      })
    }).catch((e) => {
      console.error("ClashVPN  error ", e.message, e)
      if (this.protectSocket === tcp) this.protectSocket = undefined
      settleReady(false)
    })
    return readyPromise
  }


  stopVpn() {
    this.protectSession++
    const socketToClose = this.protectSocket
    this.protectSocket = undefined
    if (socketToClose) {
      try { socketToClose.close() } catch (_) {}
    }
    stopTun()
    super.stopVpn()
  }
  override async init() {
    initClash(await getHome(this.context), "1.0.0")
    // Mihomo's Linux process resolver runs inside the VPN extension process,
    // while HarmonyOS compatibility apps may own the socket in another
    // namespace. Bridge resolver requests to BundleManager so a known UID is
    // rendered as the actual package instead of timing out as "未识别".
    console.info('ClashVPN', '[ProcessBridge] registering Harmony process callback')
    registerMessage((message: string, value: string): void => {
      if (message !== 'process') return
      try {
        const envelope = JSON.parse(value) as CoreProcessMessage
        const item = envelope.data
        const id = Number(item?.id ?? 0)
        const uid = Number(item?.metadata?.uid ?? 0)
        // UID 0 is used by HarmonyOS for connections coming from the Android
        // compatibility container. Do not turn an empty process into a fake,
        // non-empty "unidentified" name: the connection UI still needs the
        // empty value so it can attribute services such as ChatGPT from the
        // host/sniffHost metadata.
        const fallback = uid > 0 ? `应用 UID ${uid}` :
          (item?.metadata?.process ?? '')
        if (id <= 0) return
        if (uid <= 0) {
          setProcessMap(JSON.stringify({ id: id, value: fallback }))
          return
        }
        bundleManager.getBundleNameByUid(uid).then((name: string) => {
          setProcessMap(JSON.stringify({ id: id, value: name || fallback }))
        }).catch(() => {
          console.warn('ClashVPN', `[ProcessBridge] uid=${uid} bundle lookup failed`)
          setProcessMap(JSON.stringify({ id: id, value: fallback }))
        })
      } catch (_) {
        // Always release the native resolver when a malformed callback arrives.
      }
    })
  }
}

export interface Fd {
  id: number
  value: number
}

export function ParseProxyGroup(mode, result: string): ProxyGroup[] {
  if (result == null)
    return []
  const map = JSON.parse(result) as Record<string, string | Record<string, string[] | string>>
  const global = map[ProxyMode.Global]
  let groupNames = global?.["all"] as string[] ?? []
  if (mode == ProxyMode.Global) {
    groupNames = ["GLOBAL", ...groupNames]
  } else if (mode == ProxyMode.Rule) {
    groupNames = groupNames
  } else {
    groupNames = []
  }
  groupNames = groupNames.filter(e => {
    const proxy = map[e] as Record<string, string>
    if (!proxy)
      return false
    const indexes = ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"].indexOf(proxy["type"])
    return indexes > -1
  })
  const groupsRaw = groupNames.map((groupName) => {
    const group = map[groupName];
    if (group){
      group["proxies"] = (group["all"] ?? []).map((n: string) => {
        if(!map[n]){
          return;
        }
        map[n]["name"] = map[n]?.["name"]
        return map[n]
      }).filter((d: string) => d != null && d != undefined)
      return {
        name: group["name"] as string,
        now: group["now"] as string,
        type: group["type"] as ProxyType,
        hidden: group["hidden"] == true,
        icon: group["icon"] as string,
        proxies: group["proxies"]
      } as ProxyGroup
    } else {
      return null;
    }
  })
  return groupsRaw.filter(g => g != null);
}
