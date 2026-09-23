import { connection, http, webSocket } from '@kit.NetworkKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

export interface PlatformTarget {
  name: string
  url: string
}

export interface PlatformCheckResult {
  category: string
  label: string
  success: boolean
  latency: number
  statusCode: number
  responseBytes: number
  transferBytes: number
  speedMbps: number
  errorMessage: string
}

export interface PlatformConnectivityResult {
  name: string
  url: string
  successCount: number
  attempts: number
  latency: number
  minLatency: number
  maxLatency: number
  statusCode: number
  errorMessage: string
  detail: string
  quality: string
  checks: PlatformCheckResult[]
}

export type PlatformConnectivityProgress = (results: PlatformConnectivityResult[],
  completed: number, total: number) => void

interface PlatformHttpProbe {
  category: string
  label: string
  url: string
  method: http.RequestMethod
  body?: string
  contentType?: string
  acceptEmptyResponse?: boolean
  minimumResponseBytes?: number
}

export const PLATFORM_TARGETS: PlatformTarget[] = [
  { name: 'ChatGPT', url: 'https://android.chat.openai.com/' },
  { name: 'Gemini', url: 'https://gemini.google.com/' },
  { name: 'Grok', url: 'https://grok.com/' },
  { name: 'X', url: 'https://x.com/' },
  { name: 'Telegram', url: 'https://api.telegram.org/' }
]

const PLATFORM_CONNECT_TIMEOUT: number = 8000
const PLATFORM_READ_TIMEOUT: number = 12000
const PLATFORM_WEBSOCKET_HOLD_MS: number = 8000
const PLATFORM_WEBSOCKET_TIMEOUT_MS: number = 16000
const ACTION_PAYLOAD: string = 'x'.repeat(32 * 1024)
const FILE_PAYLOAD: string = 'f'.repeat(64 * 1024)
const TRANSPORT_UPLOAD_PAYLOAD: string = 'u'.repeat(128 * 1024)

/**
 * 平台检测分成两层：
 * 1. 平台自己的入口、消息/发帖、上传、媒体/CDN 与实时域名；
 * 2. 共享的 128 KiB 上传、256 KiB 下载、16 KiB 双向 WebSocket 8 秒保持。
 *
 * 所有平台请求都不带用户令牌。平台返回 4xx 代表匿名探针已经完整抵达真实
 * 服务，只验证网络路径，不创建对话、帖子、评论、文件或视频。
 */
export class PlatformConnectivityService {
  /**
   * 节点切换/VPN 启动时使用的轻量探针。
   *
   * 完整的上传、会话、媒体和 WebSocket 检测保留给用户主动点击的
   * “一键测试”。后台自动检测不能和刚建立的代理争抢连接及带宽，否则
   * 会把真实应用的首个请求推迟到多轮探针超时以后。
   */
  static async testQuick(useProxy: boolean = true,
    mixedPort: number = 7890,
    onProgress?: PlatformConnectivityProgress): Promise<PlatformConnectivityResult[]> {
    const quickResults: PlatformConnectivityResult[] = []
    await Promise.all(PLATFORM_TARGETS.map(async (target: PlatformTarget): Promise<void> => {
      const check = await PlatformConnectivityService.requestQuick(target, useProxy, mixedPort)
      const result = PlatformConnectivityService.buildResult(target, [check])
      quickResults.push(result)
      if (onProgress) {
        // 保持回调快照只包含已经完成的项目；排序在最后按平台声明顺序恢复。
        const snapshot = PLATFORM_TARGETS
          .map((item: PlatformTarget): PlatformConnectivityResult | undefined =>
            quickResults.find((current: PlatformConnectivityResult): boolean => current.name === item.name))
          .filter((item: PlatformConnectivityResult | undefined): boolean => item !== undefined) as PlatformConnectivityResult[]
        onProgress(snapshot, snapshot.length, PLATFORM_TARGETS.length)
      }
    }))
    return PLATFORM_TARGETS
      .map((target: PlatformTarget): PlatformConnectivityResult | undefined =>
        quickResults.find((result: PlatformConnectivityResult): boolean => result.name === target.name))
      .filter((result: PlatformConnectivityResult | undefined): boolean => result !== undefined) as PlatformConnectivityResult[]
  }

  static async testAll(useProxy: boolean = true,
    mixedPort: number = 7890,
    onProgress?: PlatformConnectivityProgress): Promise<PlatformConnectivityResult[]> {
    // 共享传输检测与第一个平台并行启动，后续平台依次执行。每个平台完成后
    // 立即发布一份结果快照，避免界面长时间保留上一轮数据后再一次性跳变。
    const transportPromise = Promise.all([
      PlatformConnectivityService.requestOnce({
        category: '上传',
        label: '128 KiB 上行传输',
        url: 'https://postman-echo.com/post',
        method: http.RequestMethod.POST,
        body: `{"probe":"${TRANSPORT_UPLOAD_PAYLOAD}"}`,
        contentType: 'application/json',
        // 2xx 代表回显服务完整接收了请求正文；其响应只返回摘要而非正文副本。
        minimumResponseBytes: 0
      }, useProxy, mixedPort),
      PlatformConnectivityService.requestOnce({
        category: '媒体',
        label: '256 KiB 媒体下载',
        url: 'https://speed.cloudflare.com/__down?bytes=262144',
        method: http.RequestMethod.GET,
        minimumResponseBytes: 200 * 1024
      }, useProxy, mixedPort),
      PlatformConnectivityService.testBidirectionalWebSocket(useProxy, mixedPort)
    ])
    const results: PlatformConnectivityResult[] = []
    for (const target of PLATFORM_TARGETS) {
      const platformChecks = await PlatformConnectivityService.testPlatformChecks(target, useProxy, mixedPort)
      const transport = await transportPromise
      const checks: PlatformCheckResult[] = []
      for (const check of platformChecks) checks.push(check)
      for (const check of transport) checks.push(check)
      results.push(PlatformConnectivityService.buildResult(target, checks))
      if (onProgress) onProgress(results.slice(), results.length, PLATFORM_TARGETS.length)
    }
    return results
  }

  static async testTarget(target: PlatformTarget, useProxy: boolean = true,
    mixedPort: number = 7890): Promise<PlatformConnectivityResult> {
    const transport = await Promise.all([
      PlatformConnectivityService.requestOnce({
        category: '上传', label: '128 KiB 上行传输', url: 'https://postman-echo.com/post',
        method: http.RequestMethod.POST, body: `{"probe":"${TRANSPORT_UPLOAD_PAYLOAD}"}`,
        contentType: 'application/json', minimumResponseBytes: 0
      }, useProxy, mixedPort),
      PlatformConnectivityService.requestOnce({
        category: '媒体', label: '256 KiB 媒体下载',
        url: 'https://speed.cloudflare.com/__down?bytes=262144', method: http.RequestMethod.GET,
        minimumResponseBytes: 200 * 1024
      }, useProxy, mixedPort),
      PlatformConnectivityService.testBidirectionalWebSocket(useProxy, mixedPort)
    ])
    return PlatformConnectivityService.testTargetWithTransport(target, transport, useProxy, mixedPort)
  }

  static overallQuality(results: PlatformConnectivityResult[]): string {
    if (results.length === 0) return 'idle'
    if (results.some((result: PlatformConnectivityResult): boolean => result.quality === 'error')) {
      return 'error'
    }
    if (results.some((result: PlatformConnectivityResult): boolean => result.quality === 'slow')) {
      return 'slow'
    }
    return 'normal'
  }

  static overallSummary(results: PlatformConnectivityResult[]): string {
    const normal = results.filter((item: PlatformConnectivityResult): boolean => item.quality === 'normal').length
    const slow = results.filter((item: PlatformConnectivityResult): boolean => item.quality === 'slow').length
    const error = results.filter((item: PlatformConnectivityResult): boolean => item.quality === 'error').length
    if (error > 0) return `异常 ${error} · 慢速 ${slow} · 正常 ${normal}`
    if (slow > 0) return `慢速 ${slow} · 正常 ${normal}`
    return `正常 ${normal}/${results.length}`
  }

  private static async testTargetWithTransport(target: PlatformTarget,
    transport: PlatformCheckResult[], useProxy: boolean,
    mixedPort: number): Promise<PlatformConnectivityResult> {
    const platformChecks = await PlatformConnectivityService.testPlatformChecks(target, useProxy, mixedPort)
    const checks: PlatformCheckResult[] = []
    for (const check of platformChecks) checks.push(check)
    for (const check of transport) checks.push(check)
    return PlatformConnectivityService.buildResult(target, checks)
  }

  private static async testPlatformChecks(target: PlatformTarget, useProxy: boolean,
    mixedPort: number): Promise<PlatformCheckResult[]> {
    const probes = PlatformConnectivityService.platformProbes(target)
    return Promise.all(probes.map((probe: PlatformHttpProbe) =>
      PlatformConnectivityService.requestOnce(probe, useProxy, mixedPort)))
  }

  private static platformProbes(target: PlatformTarget): PlatformHttpProbe[] {
    if (target.name === 'ChatGPT') {
      return [
        PlatformConnectivityService.probe('入口', 'Android入口', target.url, http.RequestMethod.GET),
        PlatformConnectivityService.probe('会话', '消息会话POST',
          'https://api.openai.com/v1/responses', http.RequestMethod.POST,
          `{"model":"connectivity-probe","input":"${ACTION_PAYLOAD}"}`),
        PlatformConnectivityService.probe('上传', '文件上传接口',
          'https://api.openai.com/v1/files', http.RequestMethod.POST, FILE_PAYLOAD,
          'application/octet-stream'),
        PlatformConnectivityService.probe('媒体', '静态与图片CDN',
          'https://cdn.oaistatic.com/', http.RequestMethod.GET),
        PlatformConnectivityService.probe('长连接', 'OpenAI实时域名',
          'https://ws.chatgpt.com/', http.RequestMethod.GET, undefined, undefined, true)
      ]
    }
    if (target.name === 'Gemini') {
      return [
        PlatformConnectivityService.probe('入口', 'Gemini入口', target.url, http.RequestMethod.GET),
        PlatformConnectivityService.probe('会话', '生成内容POST',
          'https://generativelanguage.googleapis.com/v1beta/models/connectivity-probe:generateContent',
          http.RequestMethod.POST,
          `{"contents":[{"parts":[{"text":"${ACTION_PAYLOAD}"}]}]}`),
        PlatformConnectivityService.probe('上传', '文件上传接口',
          'https://generativelanguage.googleapis.com/upload/v1beta/files',
          http.RequestMethod.POST, `{"file":{"display_name":"${FILE_PAYLOAD}"}}`),
        PlatformConnectivityService.probe('媒体', 'Google媒体CDN',
          'https://www.gstatic.com/images/branding/googlelogo/2x/googlelogo_color_272x92dp.png',
          http.RequestMethod.GET),
        PlatformConnectivityService.probe('长连接', 'Gemini实时API域名',
          'https://generativelanguage.googleapis.com/', http.RequestMethod.GET)
      ]
    }
    if (target.name === 'Grok') {
      return [
        PlatformConnectivityService.probe('入口', 'Grok入口', target.url, http.RequestMethod.GET),
        PlatformConnectivityService.probe('会话', 'Grok消息POST',
          'https://api.x.ai/v1/chat/completions', http.RequestMethod.POST,
          `{"model":"connectivity-probe","messages":[{"role":"user","content":"${ACTION_PAYLOAD}"}]}`),
        PlatformConnectivityService.probe('上传', 'Grok文件上传',
          'https://api.x.ai/v1/files', http.RequestMethod.POST, FILE_PAYLOAD,
          'application/octet-stream'),
        PlatformConnectivityService.probe('媒体', 'Grok文件CDN',
          'https://files-cdn.x.ai/', http.RequestMethod.GET, undefined, undefined, true),
        PlatformConnectivityService.probe('视频', 'Grok视频接口',
          'https://api.x.ai/v1/videos', http.RequestMethod.GET, undefined, undefined, true)
      ]
    }
    if (target.name === 'X') {
      return [
        PlatformConnectivityService.probe('入口', 'X时间线入口', target.url, http.RequestMethod.GET),
        PlatformConnectivityService.probe('发帖', '发布/评论POST',
          'https://api.x.com/2/tweets', http.RequestMethod.POST,
          `{"text":"${ACTION_PAYLOAD.substring(0, 1024)}"}`),
        PlatformConnectivityService.probe('上传', '图片视频上传接口',
          'https://api.x.com/2/media/upload', http.RequestMethod.POST,
          `{"media":"${FILE_PAYLOAD}","media_category":"tweet_image","media_type":"image/png"}`),
        PlatformConnectivityService.probe('媒体', 'X图片视频CDN',
          'https://pbs.twimg.com/', http.RequestMethod.GET, undefined, undefined, true),
        PlatformConnectivityService.probe('长连接', 'X活动流接口',
          'https://api.x.com/2/activity/stream', http.RequestMethod.GET, undefined, undefined, true)
      ]
    }
    return [
      PlatformConnectivityService.probe('入口', 'Telegram API入口', target.url, http.RequestMethod.GET),
      PlatformConnectivityService.probe('消息', '消息发送POST',
        'https://api.telegram.org/botINVALID/sendMessage', http.RequestMethod.POST,
        `{"chat_id":0,"text":"${ACTION_PAYLOAD}"}`),
      PlatformConnectivityService.probe('上传', '图片视频上传接口',
        'https://api.telegram.org/botINVALID/sendDocument', http.RequestMethod.POST,
        `{"chat_id":0,"document":"${FILE_PAYLOAD}"}`),
      PlatformConnectivityService.probe('媒体', 'Telegram媒体下载',
        'https://telegram.org/img/t_logo.svg', http.RequestMethod.GET),
      PlatformConnectivityService.probe('长连接', 'Telegram文件API',
        'https://api.telegram.org/file/botINVALID/probe', http.RequestMethod.GET,
        undefined, undefined, true)
    ]
  }

  private static probe(category: string, label: string, url: string,
    method: http.RequestMethod, body?: string, contentType?: string,
    acceptEmptyResponse: boolean = false): PlatformHttpProbe {
    return {
      category: category,
      label: label,
      url: url,
      method: method,
      body: body,
      contentType: contentType ?? 'application/json',
      acceptEmptyResponse: acceptEmptyResponse,
      minimumResponseBytes: 0
    }
  }

  private static buildResult(target: PlatformTarget,
    checks: PlatformCheckResult[]): PlatformConnectivityResult {
    const successful = checks.filter((result: PlatformCheckResult): boolean => result.success)
    let latency = 0
    let minLatency = 0
    let maxLatency = 0
    if (successful.length > 0) {
      const total = successful.reduce((sum: number, result: PlatformCheckResult): number =>
        sum + result.latency, 0)
      latency = Math.round(total / successful.length)
      minLatency = Math.min(...successful.map((result: PlatformCheckResult): number => result.latency))
      maxLatency = Math.max(...successful.map((result: PlatformCheckResult): number => result.latency))
    }
    const failed = checks.filter((result: PlatformCheckResult): boolean => !result.success)
    let quality = 'normal'
    if (failed.length >= 2 || successful.length === 0) {
      quality = 'error'
    } else if (failed.length === 1 || maxLatency > 3500) {
      quality = 'slow'
    }
    const detail = failed.length === 0 ? '入口、操作、上传、媒体与长连接全部通过' :
      `失败：${failed.map((item: PlatformCheckResult): string => item.label).join('、')}`
    return {
      name: target.name,
      url: target.url,
      successCount: successful.length,
      attempts: checks.length,
      latency: latency,
      minLatency: minLatency,
      maxLatency: maxLatency,
      statusCode: checks.length > 0 ? checks[checks.length - 1].statusCode : 0,
      errorMessage: failed.length > 0 ? failed[0].errorMessage : '',
      detail: detail,
      quality: quality,
      checks: checks
    }
  }

  private static async requestOnce(probe: PlatformHttpProbe, useProxy: boolean,
    mixedPort: number): Promise<PlatformCheckResult> {
    const request = http.createHttp()
    const startedAt = Date.now()
    try {
      const response = await request.request(probe.url, {
        method: probe.method,
        extraData: probe.body,
        connectTimeout: PLATFORM_CONNECT_TIMEOUT,
        readTimeout: PLATFORM_READ_TIMEOUT,
        usingCache: false,
        maxLimit: 2 * 1024 * 1024,
        usingProxy: PlatformConnectivityService.proxyOption(useProxy, mixedPort),
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 15) FireflyProbe/2.0',
          'Cache-Control': 'no-cache',
          'Content-Type': probe.contentType ?? 'application/json',
          'Accept': '*/*'
        }
      })
      const statusCode = response.responseCode
      const elapsed = Date.now() - startedAt
      const responseBytes = PlatformConnectivityService.responseByteLength(response.result)
      const requestBytes = probe.body?.length ?? 0
      const transferBytes = probe.method === http.RequestMethod.POST && requestBytes > 0 ?
        requestBytes : responseBytes
      const speedMbps = elapsed > 0 ? Math.round(transferBytes * 8 / elapsed / 1000 * 100) / 100 : 0
      const minimum = probe.minimumResponseBytes ?? 0
      const success = statusCode >= 200 && statusCode < 500 &&
        (probe.acceptEmptyResponse === true || responseBytes > minimum)
      hilog.info(0xA020, 'PlatformTest',
        `%{public}s status=%{public}d bytes=%{public}d latency=%{public}dms`,
        probe.label, statusCode, responseBytes, elapsed)
      return {
        category: probe.category,
        label: probe.label,
        success: success,
        latency: elapsed,
        statusCode: statusCode,
        responseBytes: responseBytes,
        transferBytes: transferBytes,
        speedMbps: speedMbps,
        errorMessage: success ? '' : `${probe.label}: HTTP ${statusCode} / ${responseBytes}B`
      }
    } catch (error) {
      const elapsed = Date.now() - startedAt
      const message = error instanceof Error ? error.message : JSON.stringify(error)
      hilog.warn(0xA020, 'PlatformTest',
        `%{public}s failed latency=%{public}dms reason=%{public}s`, probe.label, elapsed, message)
      return {
        category: probe.category,
        label: probe.label,
        success: false,
        latency: elapsed,
        statusCode: 0,
        responseBytes: 0,
        transferBytes: 0,
        speedMbps: 0,
        errorMessage: `${probe.label}: ${PlatformConnectivityService.normalizeError(message)}`
      }
    } finally {
      request.destroy()
    }
  }

  private static async requestQuick(target: PlatformTarget, useProxy: boolean,
    mixedPort: number): Promise<PlatformCheckResult> {
    const request = http.createHttp()
    const startedAt = Date.now()
    const QUICK_CONNECT_TIMEOUT = 3000
    const QUICK_READ_TIMEOUT = 5000
    try {
      const response = await request.request(target.url, {
        // 轻量检测只关心入口是否可达。Gemini 首页的响应体较大，HarmonyOS
        // NetworkKit 在配置热加载后的首个 GET 上偶尔会以 2300023 结束接收，
        // 即使 TLS 和绝大部分正文都已经成功到达，最终却被误报成平台异常。
        // HEAD 保留完整 DNS/TCP/TLS/HTTP 链路，同时避免下载页面正文。
        method: http.RequestMethod.HEAD,
        connectTimeout: QUICK_CONNECT_TIMEOUT,
        readTimeout: QUICK_READ_TIMEOUT,
        usingCache: false,
        maxLimit: 256 * 1024,
        usingProxy: PlatformConnectivityService.proxyOption(useProxy, mixedPort),
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 15) FireflyQuickProbe/1.0',
          'Cache-Control': 'no-cache',
          'Accept': '*/*'
        }
      })
      const elapsed = Date.now() - startedAt
      const responseBytes = PlatformConnectivityService.responseByteLength(response.result)
      const statusCode = response.responseCode
      // 3xx/4xx 仍代表已经抵达平台边缘；这里测的是网络可达性，不是账号授权。
      const success = statusCode >= 200 && statusCode < 500
      hilog.info(0xA020, 'PlatformQuickTest',
        `%{public}s status=%{public}d bytes=%{public}d latency=%{public}dms`,
        target.name, statusCode, responseBytes, elapsed)
      return {
        category: '入口',
        label: '轻量入口探测',
        success: success,
        latency: elapsed,
        statusCode: statusCode,
        responseBytes: responseBytes,
        transferBytes: responseBytes,
        speedMbps: elapsed > 0 ? Math.round(responseBytes * 8 / elapsed / 1000 * 100) / 100 : 0,
        errorMessage: success ? '' : `${target.name}: HTTP ${statusCode} / ${responseBytes}B`
      }
    } catch (error) {
      const elapsed = Date.now() - startedAt
      const message = error instanceof Error ? error.message : JSON.stringify(error)
      hilog.warn(0xA020, 'PlatformQuickTest',
        `%{public}s failed latency=%{public}dms reason=%{public}s`, target.name, elapsed, message)
      return {
        category: '入口',
        label: '轻量入口探测',
        success: false,
        latency: elapsed,
        statusCode: 0,
        responseBytes: 0,
        transferBytes: 0,
        speedMbps: 0,
        errorMessage: `${target.name}: ${PlatformConnectivityService.normalizeError(message)}`
      }
    } finally {
      request.destroy()
    }
  }

  private static testBidirectionalWebSocket(useProxy: boolean,
    mixedPort: number): Promise<PlatformCheckResult> {
    return new Promise((resolve) => {
      const client = webSocket.createWebSocket()
      const startedAt = Date.now()
      const payload = `firefly-${Date.now()}-${'w'.repeat(16 * 1024)}`
      let settled = false
      let echoReceived = false
      let echoLatency = 0
      let timeoutTimer = 0
      let holdTimer = 0

      const finish = (success: boolean, message: string, closeAfter: boolean): void => {
        if (settled) return
        settled = true
        clearTimeout(timeoutTimer)
        clearTimeout(holdTimer)
        const elapsed = Date.now() - startedAt
        const qualityLatency = success && echoLatency > 0 ? echoLatency : elapsed
        if (closeAfter) {
          client.close({ code: 1000, reason: 'platform transport probe complete' }).catch(() => {})
        }
        resolve({
          category: '长连接',
          label: '双向WS保持8秒',
          success: success,
          latency: qualityLatency,
          statusCode: success ? 101 : 0,
          responseBytes: success ? 16 * 1024 : 0,
          transferBytes: success ? 32 * 1024 : 0,
          speedMbps: success && qualityLatency > 0 ?
            Math.round(32 * 1024 * 8 / qualityLatency / 1000 * 100) / 100 : 0,
          errorMessage: success ? '' : `双向WS保持: ${PlatformConnectivityService.normalizeError(message)}`
        })
      }

      client.on('open', (error: BusinessError) => {
        if (error) {
          finish(false, error.message, false)
          return
        }
        client.send(payload).catch((sendError: BusinessError) => {
          finish(false, `发送失败 ${sendError.message}`, true)
        })
        holdTimer = setTimeout((): void => {
          finish(echoReceived, echoReceived ? '16 KiB 双向传输并保持8秒' : '未收到完整回显', true)
        }, PLATFORM_WEBSOCKET_HOLD_MS)
      })
      client.on('message', (error: BusinessError, data: string | ArrayBuffer) => {
        if (!error) {
          const receivedBytes = typeof data === 'string' ? data.length : data.byteLength
          if (receivedBytes >= 16 * 1024) {
            echoReceived = true
            if (echoLatency === 0) echoLatency = Date.now() - startedAt
          }
        }
      })
      client.on('close', (error: BusinessError, result: webSocket.CloseResult) => {
        if (!settled) {
          const errorMessage = typeof error?.message === 'string' ? error.message : ''
          const closeReason = typeof result?.reason === 'string' ? result.reason : ''
          finish(false, errorMessage || closeReason || `关闭码 ${result?.code ?? 0}`, false)
        }
      })
      client.on('error', (error: BusinessError) => finish(false, error.message, false))
      timeoutTimer = setTimeout((): void => finish(false, '双向长连接超时', true),
        PLATFORM_WEBSOCKET_TIMEOUT_MS)
      client.connect('wss://ws.postman-echo.com/raw', {
        header: { 'User-Agent': 'Mozilla/5.0 (Linux; Android 15) FireflyProbe/2.0' },
        proxy: useProxy ? PlatformConnectivityService.httpProxy(mixedPort) : 'no-proxy',
        pingInterval: 3,
        pongTimeout: 3
      }).catch((error: BusinessError) => finish(false, error.message, false))
    })
  }

  private static responseByteLength(result: string | Object | ArrayBuffer | null | undefined): number {
    if (result === null || result === undefined) return 0
    if (typeof result === 'string') return result.length
    if (result instanceof ArrayBuffer) return result.byteLength
    return JSON.stringify(result).length
  }

  private static proxyOption(useProxy: boolean,
    mixedPort: number): boolean | connection.HttpProxy {
    return useProxy ? PlatformConnectivityService.httpProxy(mixedPort) : false
  }

  private static httpProxy(mixedPort: number): connection.HttpProxy {
    return { host: '127.0.0.1', port: mixedPort > 0 ? mixedPort : 7890, exclusionList: [] }
  }

  private static normalizeError(message: string): string {
    const safeMessage = typeof message === 'string' && message.length > 0 ? message : '连接失败'
    const lowerMessage = safeMessage.toLowerCase()
    if (lowerMessage.includes('timeout') || lowerMessage.includes('timed out') ||
      lowerMessage.includes('超时')) return '连接超时'
    if (lowerMessage.includes('resolve') || lowerMessage.includes('dns')) return 'DNS 解析失败'
    if (lowerMessage.includes('ssl') || lowerMessage.includes('tls') ||
      lowerMessage.includes('certificate')) return 'TLS 握手失败'
    if (lowerMessage.includes('reset') || lowerMessage.includes('eof') ||
      lowerMessage.includes('closed') || lowerMessage.includes('关闭')) return '连接被节点提前中断'
    return safeMessage.length > 42 ? `${safeMessage.substring(0, 42)}…` : safeMessage
  }
}

export default PlatformConnectivityService
