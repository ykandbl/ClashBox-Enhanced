import { socket, vpnExtension } from '@kit.NetworkKit';
import {  RpcResult } from './RpcRequest';
import { JSON, util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { ClashRpcType, IClashManager, VpnRawOptions } from './IClashManager';
import { ConnectionInfo, IpInfo, LogInfo, Provider, ProxyGroup, ProxyMode,
  Traffic } from '../models/Common';
import  fs from  "@ohos.file.fs"
import { fileIo, fileUri } from "@kit.CoreFileKit";
import { PromptAction } from '@kit.ArkUI';
import { UpdateConfigParams } from '../models/ClashConfig';
import { checkIp, queryCurrentIpInfo } from '../Request';
import { Fd, ParseProxyGroup, VpnOptions } from './FlClashVpnService';
import { convertV2RaySubscription, getVpnOptions, setFdMap } from 'libflclash.so';
import { Address, isIpv4, isIpv6, VpnConfig } from './CommonVpnService';

export interface DelayInfo{
  name: string
  value: number
  errorCode?: string
  elapsedMs?: number
}
export interface CoreNodeQualityResult {
  status: string
  quality: string
  latencyMs: number
  jitterMs: number
  successRate: number
  downloadMbps: number
  uploadMbps: number
  transferredBytes: number
  errorCode: string
  diagnostic?: string
  reliable: boolean
  downloadVariationPercent: number
  uploadVariationPercent: number
}

export interface CoreNodeQualityProgress {
  running: boolean
  phase: string
  direction: string
  currentMbps: number
  averageMbps: number
  transferredBytes: number
  elapsedMs: number
  samples: number
  downloadSamples: number
  uploadSamples: number
  connections: number
  target: string
}
interface Snapshot{
  connections: ConnectionInfo[]
}
interface TrafficInfo{
  up: number
  down: number
}



export class SocketProxyService implements IClashManager {
  context?: common.Context
  active: boolean = false
  offlineTime: number[] = []
  static promptAction: PromptAction
  init(context: common.Context, promptAction: PromptAction) {
    this.context = context
    SocketProxyService.promptAction = promptAction
  }
  async isCoreReady(): Promise<boolean> {
    const rpcSocketPath = this.context?.filesDir + '/clash_go.sock'
    const controlSocketPath = this.context?.filesDir + '/ClashBox.sock'
    if (!rpcSocketPath || !controlSocketPath) {
      return false
    }
    return await fileIo.access(rpcSocketPath, fs.AccessModeType.EXIST) &&
      await fileIo.access(controlSocketPath, fs.AccessModeType.EXIST)
  }
  async setLogObserver(observer: (message: LogInfo) => void): Promise<()=>void> {
    return this.callbackRequest(ClashRpcType.setLogObserver, [], (message)=>{
        if(message != ""){
          observer(JSON.parse(message) as LogInfo)
        }
    })
  }
  async registerMessage(observer: (message: string) => void): Promise<()=>void> {
    return this.callbackRequest(ClashRpcType.registerOnMessage, [], observer)
  }
  async loadConfig(config: UpdateConfigParams): Promise<string> {
    // config.yaml 保留订阅原文；runtime.yaml 是每次加载前生成的本机分流模板。
    config['profile-id'] = config['profile-id'] + "/runtime"
    let result =  await this.sendMessageRequest(ClashRpcType.load, [JSON.stringify(config)])
    return result as string
  }
  async vailConfig(filepath: string){
    // 导入配置时 VPN 扩展可能尚未创建 RPC socket。YAML 结构校验已在
    // Profile.update 中完成，此时跳过仅依赖运行中核心的语义校验，避免把
    // “核心未启动”误报成订阅下载失败。核心在线时仍执行完整校验。
    const socketPath = this.context?.filesDir + '/clash_go.sock'
    if (!socketPath || !await fileIo.access(socketPath, fs.AccessModeType.EXIST)) {
      console.warn("VailConfig skipped: VPN core is not running")
      return ""
    }
    let result = await this.sendMessageRequest(ClashRpcType.validConfig, [filepath])
    return result as string;
  }
  async convertV2RaySubscription(content: string): Promise<string> {
    const converted = await convertV2RaySubscription(content)
    if (!converted) {
      throw new Error('BitzNet 返回的 URI 订阅格式转换失败')
    }
    return converted
  }
  async queryTrafficTotal(onlyProxy: boolean): Promise<Traffic> {
    let result = await this.sendMessageRequest(ClashRpcType.queryTrafficTotal, [onlyProxy])
    const json = JSON.parse(result as string) as TrafficInfo
    return new Traffic(json.up, json.down);
  } 
  async queryTrafficNow(onlyProxy: boolean): Promise<Traffic> {
    let result = await this.sendMessageRequest(ClashRpcType.queryTrafficNow,  [onlyProxy])
    const json = JSON.parse(result as string) as TrafficInfo
    return new Traffic(json.up, json.down);
  }

  async checkIpInfo(): Promise<IpInfo> {
    // let result = await checkIp()
    // let country = await queryIpInfo(result)
    // console.log(`IPtest SocketProxyService#checkIpInfo country: ${country}`)
    // if (country == "")
    //   country = await this.sendMessageRequest(ClashRpcType.getCountryCode, [result]) as string

    const ipInfo = await queryCurrentIpInfo()
    
    if (ipInfo) {
      console.log(`IPtest SocketProxyService#checkIpInfo Country: ${ipInfo.country}`)
      return {
        ip: ipInfo.ip,
        country: ipInfo.country
      } as IpInfo
    }
    
    // 如果所有 API 都失败，尝试使用本地方法获取
    console.warn(`IPtest SocketProxyService#checkIpInfo 所有 API 请求失败，尝试本地方法`)
    const result = await checkIp()
    const country = await this.sendMessageRequest(ClashRpcType.getCountryCode, [result]) as string

    return {
      ip: result,
      country: country
    } as IpInfo
  }
  async queryConnections(): Promise<ConnectionInfo[]> {
    let result = await this.sendMessageRequest(ClashRpcType.queryConnections)
    const json = JSON.parse(result as string) as Snapshot
    return json.connections ?? [];
  }
  async getRequestList(): Promise<ConnectionInfo[]>{
    let result = await this.sendMessageRequest(ClashRpcType.getRequestList)
    return JSON.parse(result as string) as ConnectionInfo[]
  }
  async  clearRequestList(): Promise<boolean>{
    await this.sendMessageRequest(ClashRpcType.clearRequestList)
    return true
  }
  async closeConnection(id: string): Promise<string> {
    let result = await this.sendMessageRequest(ClashRpcType.closeConnection, [id])
    return result as string;
  }
  async clearConnections(): Promise<ConnectionInfo[]> {
    await this.sendMessageRequest(ClashRpcType.clearConnections)
    return [];
  }

  async queryProxyGroups(model: ProxyMode): Promise<ProxyGroup[]> {
    let result = await this.sendMessageRequest(ClashRpcType.queryProxyGroup,[model])
    return ParseProxyGroup(model, result as string)
  }
  async queryProviders(): Promise<Provider[]> {
    let result = await this.sendMessageRequest(ClashRpcType.queryProviders)
    return JSON.parse(result as string) as Provider[]
  }
  async getVpnOptions(): Promise<VpnOptions> {
    let result = await this.sendMessageRequest(ClashRpcType.vpnOptions)
    return JSON.parse(result as string) as VpnOptions
  }
  async setOptionStates(options: VpnRawOptions): Promise<string> {
    let result = await this.sendMessageRequest(ClashRpcType.setOptionState, [JSON.stringify(options)])
    return result as string
  }
  /** Refreshes the physical-interface snapshot used by HarmonyOS route lookup. */
  async setNetInterfaces(infos: Array<Object>): Promise<string> {
    let result = await this.sendMessageRequest(ClashRpcType.setNetInterfaces, [JSON.stringify(infos)])
    return result as string
  }
  async updateProvider(provider: Provider): Promise<string> {
    return  (await this.sendMessageRequest(ClashRpcType.updateProvider,[provider.name])) as string
  }
  async upLoadProvider(provider: Provider, uri: string): Promise<string> {
    const temp = this.context?.filesDir + "/temp_provider"
    fs.copy(uri, fileUri.getUriFromPath(temp))
    return  (await this.sendMessageRequest(ClashRpcType.uploadProvider,[provider.name, temp])) as string
  }
  async updateGeoData(geoName: string, geoType: string): Promise<string>{
    return await (this.sendMessageRequest(ClashRpcType.updateGeoData,[geoName, geoType])) as string
  }
  async changeProxy(group: string, name: string): Promise<string> {
    // The native side has its own bounded core-mutation lock. Keep the UI
    // deadline just above that bound so a wedged config reload produces a
    // visible error instead of leaving the radio/button apparently frozen.
    let result = await this.sendMessageRequest(ClashRpcType.changeProxy,[group, name], false, 6000)
    return result as string
  }
  async healthCheck(proxyName: string): Promise<number> {
    return (await this.healthCheckDetailed(proxyName)).value
  }
  async healthCheckDetailed(proxyName: string,
    testUrl: string = 'https://www.gstatic.com/generate_204', timeoutMs: number = 8000): Promise<DelayInfo> {
    const boundedTimeout = Math.max(1000, Math.min(8000, Math.round(timeoutMs)))
    const result = await this.sendMessageRequest(ClashRpcType.healthCheck,
      [proxyName, boundedTimeout, testUrl], true)
    const info = JSON.parse(result as string) as DelayInfo
    if (!info || !Number.isFinite(info.value)) throw new Error('invalid delay response')
    return info
  }
  async nodeQualityCheck(proxyName: string, mode: string): Promise<CoreNodeQualityResult> {
    // Slow or lossy nodes can consume several per-transfer timeouts. Keep this
    // RPC alive long enough for the core to return its bounded final result.
    const result = await this.sendMessageRequest(ClashRpcType.nodeQualityCheck,
      [proxyName, mode], true, 360000)
    const info = JSON.parse(result as string) as CoreNodeQualityResult
    if (!info || typeof info.status !== 'string') throw new Error('invalid node quality response')
    return info
  }

  async nodeQualityProgress(): Promise<CoreNodeQualityProgress> {
    const result = await this.sendMessageRequest(ClashRpcType.nodeQualityProgress, [], true, 5000)
    const info = JSON.parse(result as string) as CoreNodeQualityProgress
    if (!info || typeof info.running !== 'boolean') throw new Error('invalid node quality progress')
    return info
  }

  async cancelNodeQuality(): Promise<boolean> {
    const result = await this.sendMessageRequest(ClashRpcType.nodeQualityCancel, [], true, 5000)
    return result === true || result === 'true'
  }

  async startClash(silent: boolean = false):Promise<boolean>{
    // Creating the HarmonyOS VPN connection is a system RPC and may legitimately
    // take more than the generic 10-second local-core deadline, especially just
    // after install, upgrade, or a previous tunnel teardown.  Timing this call
    // out at 10 seconds is dangerous: the platform can finish creating the TUN
    // immediately afterwards while the caller has already entered its failure
    // cleanup and tears the healthy tunnel back down.
    let json = await this.sendMessageRequest(ClashRpcType.startClash, [], silent, 45000)
    return json as boolean
  }
  // TODO 返回运行时间,卡片和ui统一使用 需要测试,
  async getRuntime(silent: boolean = false, requestTimeoutMs: number = 10000): Promise<number> {
    let result = await this.sendMessageRequest(ClashRpcType.GetVpnRunTime, [], silent, requestTimeoutMs)
    return result as number
  }
  // TODO startClash前需要调用判断, clash配置是否加载完成,
  // 没有加载,做友好提示,或则先加载clash配置,在启动
  async vpnConfigIsLoad(): Promise<boolean> {
    let result = await this.sendMessageRequest(ClashRpcType.VpnConfigInited)
    return result  == "true"
  }
  vpnConnection : vpnExtension.VpnConnection | undefined
  async getTunFd(config: VpnConfig): Promise<number> {
    let tunFd = -1
    try {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context as common.VpnExtensionContext);
      tunFd = await this.vpnConnection.create(config)
      console.log("ClashVPN", `获取tunFd: ${tunFd}`)
      return tunFd;
    } catch (error) {
      console.log("ClashVPN", `Clash启动失败 ${error.message} => ${error.stack}` )
      this.vpnConnection?.destroy()
      return -1
    }
  }
  async stopClash():Promise<boolean>{
    let json = await this.sendMessageRequest(ClashRpcType.stopClash, [])
    return json as boolean
  }
  async reset():Promise<boolean>{
    let json = await this.sendMessageRequest(ClashRpcType.reset, [])
    return json as boolean
  }
  ParseMessage(messageBuffer: string, resolve: (s: string| number | boolean | undefined)=>void,
    reject: (err: string)=>void): boolean {
    try {
      let json = JSON.parse(messageBuffer) as RpcResult
      if (!json.error || json.error == "")
        resolve(json.result)
      else{
        SocketProxyService.promptAction.showToast({message: JSON.stringify(json.error)})
        resolve(json.error)
      }
      return true
    } catch (e) {
      // LocalSocket 消息可能被拆成多段；上层继续累积，直到拿到完整 JSON。
      return false
    }
  }

  /**
   * 等待 RPC socket 真正进入监听状态。
   *
   * VPN Extension 冷启动时，socket 文件会比 LocalSocketServer.listen() 更早出现。
   * 这段很短的窗口此前会被当成“服务被系统干掉”，既误报给用户，也会中断
   * 本来能够自行完成的启动链。连接尚未建立时请求还没有发送，所以可以安全
   * 重试；一旦 connect 成功，后续读写错误仍交给调用方按真实失联处理。
   */
  private async connectRpcSocket(
    socketPath: string,
    retryWhileStarting: boolean
  ): Promise<socket.LocalSocket> {
    // 静默健康探针用于判断旧 Extension 是否已经死亡，需要快速返回，随后
    // ChangeCore 才能立即重建服务；真实业务请求才使用短暂退避等待监听就绪。
    const maxAttempts = retryWhileStarting ? 6 : 1
    let lastError: Error = new Error("VPN服务未启动")
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const socketExists = await fileIo.access(socketPath, fs.AccessModeType.EXIST)
      if (socketExists) {
        const client = socket.constructLocalSocketInstance()
        // connect() 会返回同一错误；这里注册监听是为了满足 LocalSocket 的事件约定，
        // 连接成功后 sendMessageRequest 会再注册正式的读写错误处理。
        const connectErrorListener = (error: Error): void => {
          lastError = error
        }
        client.on("error", connectErrorListener)
        try {
          await client.connect({ address: { address: socketPath }, timeout: 1000 })
          // 这个监听器只服务于 connect() 阶段。若保留到请求结束，Harmony
          // LocalSocket 在 close() 后仍可能把旧回调调度出来，形成 fd 竞态。
          client.off("error", connectErrorListener)
          if (attempt > 0) {
            console.info(`RPC socket 延迟就绪，重试次数=${attempt}`)
          }
          return client
        } catch (error) {
          lastError = error as Error
          client.off("error", connectErrorListener)
          // connect() 失败后平台可能已收回 fd；先等退订完成并检查状态，
          // 只关闭仍存活的 socket，避免与失败清理竞争产生 errno=9/88。
          setTimeout((): void => {
            client.getState().then((state): void => {
              if (!state.isClose) client.close().catch((): void => {})
            }).catch((): void => {})
          }, 80)
        }
      } else {
        lastError = new Error("VPN服务未启动")
      }

      if (attempt + 1 < maxAttempts) {
        console.warn(`RPC socket 尚未就绪，静默重试 attempt=${attempt + 1}`)
        await new Promise<void>((resolve) => setTimeout(resolve, 150 + attempt * 100))
      }
    }
    throw lastError
  }

  async sendMessageRequest(
    method: number,
    params: (string| number | boolean) [] = [],
    silent: boolean = false,
    requestTimeoutMs: number = 10000
  ): Promise<string| number | boolean | undefined>{
    console.log("sendMessageRequest " + method)
    let socketPath = this.context?.filesDir + '/clash_go.sock'
    // start/stop 由 VPN Extension 自身的控制 socket 处理。
    if (method == ClashRpcType.startClash || method == ClashRpcType.stopClash) {
      socketPath = this.context?.filesDir + '/ClashBox.sock'
    }

    let client: socket.LocalSocket
    try {
      client = await this.connectRpcSocket(socketPath, !silent)
      this.active = true
    } catch (error) {
      const connectError = error as Error
      this.active = false
      if (silent) {
        console.info(`RPC 静默健康探针未就绪: ${connectError.message}`)
      } else {
        console.error("vpn服务启动失败", connectError.message, connectError.stack)
        try {
          const message = connectError.message.includes("Connection refused") ?
            "VPN服务已失联，请重新启动代理" : "VPN服务启动失败"
          SocketProxyService.promptAction.showToast({ message: message })
        } catch (promptError) {
          console.error(`VPN服务失败提示弹窗error：${JSON.stringify(promptError)}`)
        }
      }
      throw connectError
    }

    return new Promise((resolve, reject)=>{
      let text = new util.TextDecoder()
      let fullMessage = '';
      let settled = false
      let closeRequested = false
      let listenersRemoved = false
      let closeListenerRemoved = false
      let closeGraceTimer = -1
      let timer = -1
      let messageListener: (value: socket.LocalSocketMessageInfo) => void = (_value: socket.LocalSocketMessageInfo): void => {}
      let errorListener: (error: Error) => void = (_error: Error): void => {}
      let closeListener: () => void = (): void => {}
      const detachListeners = (): void => {
        if (listenersRemoved) {
          return
        }
        listenersRemoved = true
        try {
          client.off('message', messageListener)
        } catch (_) {
        }
        try {
          client.off('error', errorListener)
        } catch (_) {
        }
      }
      const detachCloseListener = (): void => {
        if (closeListenerRemoved) {
          return
        }
        closeListenerRemoved = true
        try {
          client.off('close', closeListener)
        } catch (_) {
        }
      }
      const clearCloseGraceTimer = (): void => {
        if (closeGraceTimer !== -1) {
          clearTimeout(closeGraceTimer)
          closeGraceTimer = -1
        }
      }
      const closeClient = (): void => {
        if (closeRequested) {
          return
        }
        closeRequested = true
        // off() 返回时平台接收线程可能仍有一个已调度轮次。异常/超时路径
        // 需要主动关闭，但给退订留一个很短的缓冲，避免 close/recv 竞争。
        detachListeners()
        detachCloseListener()
        setTimeout((): void => {
          client.getState().then((state): void => {
            if (!state.isClose) client.close().catch((): void => {})
          }).catch((): void => {})
        }, 80)
      }
      const resolveOnce = (value: string | number | boolean | undefined): void => {
        if (settled) {
          return
        }
        settled = true
        clearTimeout(timer)
        clearCloseGraceTimer()
        // Go 端在写完一次性 RPC 响应后会主动关闭连接。客户端此时只需退订；
        // close 监听保留到远端 FIN，避免对象在 NetStack 收尾前被 GC 回收。
        detachListeners()
        resolve(value)
      }
      const rejectOnce = (reason: string | Error, shouldClose: boolean = true): void => {
        if (settled) {
          return
        }
        settled = true
        clearTimeout(timer)
        clearCloseGraceTimer()
        if (shouldClose) {
          closeClient()
        } else {
          detachListeners()
          detachCloseListener()
        }
        reject(reason)
      }
      const tryParseBufferedMessage = (): void => {
        const eofIndex = fullMessage.indexOf("EOF")
        const candidate = eofIndex >= 0 ? fullMessage.substring(0, eofIndex) : fullMessage
        if (candidate.length === 0) {
          return
        }
        if (this.ParseMessage(candidate, resolveOnce, (reason: string): void => rejectOnce(reason))) {
          fullMessage = eofIndex >= 0 ? fullMessage.substring(eofIndex + 3) : ''
        }
      }
      messageListener = (value: socket.LocalSocketMessageInfo): void => {
        let chunk = text.decodeToString(new Uint8Array(value.message),  { stream: true })
        fullMessage += chunk;
        tryParseBufferedMessage()
      }
      client.on('message', messageListener)
      timer = setTimeout((): void => {
        rejectOnce("请求超时")
      }, requestTimeoutMs)
      errorListener = (error: Error): void => {
        this.active = false
        // error 事件说明 NetStack 已经在清理该 fd，不重复 close。
        rejectOnce(error, false)
      }
      client.on("error", errorListener)
      closeListener = (): void => {
        detachCloseListener()
        if (settled) {
          return
        }
        // HarmonyOS LocalSocket 在服务端“写完最后一帧并立即关闭”时，偶尔
        // 先投递 close、再投递已经排队的 message。立即 reject 会把正常回包
        // 误报成“RPC连接已关闭”，配置页随后就显示“核心·待重载”。保留
        // message/error 监听一个很短的收尾窗口；真正断开仍会快速结束，正常
        // 回包则会先由 tryParseBufferedMessage/messageListener 收口。
        tryParseBufferedMessage()
        if (settled) {
          return
        }
        closeGraceTimer = setTimeout((): void => {
          closeGraceTimer = -1
          if (!settled) {
            this.active = false
            rejectOnce('RPC连接已关闭', false)
          }
        }, 180)
      }
      client.on('close', closeListener)
      client.send({ data: JSON.stringify({method, params}) }).catch((error: Error): void => {
        this.active = false
        rejectOnce(error)
      })
    })
  }
  async callbackRequest(
    method: number,
    params: (string | number | boolean) [] = [],
    callBack: (message: string) => void
  ): Promise<() => void> {
    return new Promise(async (resolve, reject)=>{
      let tcp: socket.LocalSocket = socket.constructLocalSocketInstance();
      const decoder = new util.TextDecoder()
      let pending = ''
      let closeRequested = false
      let messageListener: (value: socket.LocalSocketMessageInfo) => void = (_value: socket.LocalSocketMessageInfo): void => {}
      let errorListener: (e: Error) => void = (_e: Error): void => {}
      const detachListeners = (): void => {
        try {
          tcp.off('message', messageListener)
        } catch (_) {
        }
        try {
          tcp.off('error', errorListener)
        } catch (_) {
        }
      }
      const closeClient = (remoteFailed: boolean = false): void => {
        if (closeRequested) {
          return
        }
        closeRequested = true
        detachListeners()
        if (!remoteFailed) {
          setTimeout((): void => {
            tcp.getState().then((state): void => {
              if (!state.isClose) tcp.close().catch((): void => {})
            }).catch((): void => {})
          }, 80)
        }
      }
      const consumeFrame = (element: string): void => {
        if (element.trim() === '') return
        try {
          let json = JSON.parse(element) as RpcResult
          callBack(json.result as string)
        } catch (e) {
          console.error("log error", e.message, element)
        }
      }
      messageListener = (value: socket.LocalSocketMessageInfo): void => {
        pending += decoder.decodeToString(new Uint8Array(value.message), { stream: true })
        let eofIndex = pending.indexOf("EOF")
        while (eofIndex >= 0) {
          consumeFrame(pending.substring(0, eofIndex))
          pending = pending.substring(eofIndex + 3)
          eofIndex = pending.indexOf("EOF")
        }
      }
      tcp.on('message', messageListener)
      errorListener = (e: Error): void => {
        closeClient(true)
        reject("失败")
      }
      tcp.on('error', errorListener);
      const socketPath = this.context?.filesDir + '/clash_go.sock'
      tcp.connect({address: { address: socketPath }, timeout:3000}).then(()=>{
        tcp.send({ data: JSON.stringify({method, params}) });
        resolve(()=>{
          closeClient()
        })
      }).catch((e: Error)=>{
        console.log("socketProxy error", e.message)
        closeClient(true)
        reject(e)
      });
    })
  }
}

export default new SocketProxyService()
