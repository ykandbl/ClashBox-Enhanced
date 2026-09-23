import { connection, http } from '@kit.NetworkKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { JSON, util } from '@kit.ArkTS'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { IpInfo } from 'proxy_core'
import { CloudflareWebProbe } from './CloudflareWebProbe'

const IPV4_DISCOVERY_URLS: string[] = [
  'https://www.cloudflare.com/cdn-cgi/trace',
  'https://checkip.amazonaws.com',
  'https://api4.ipify.org',
  'https://ipv4.icanhazip.com'
]
const IPV6_DISCOVERY_URLS: string[] = [
  'https://api6.ipify.org',
  'https://ipv6.icanhazip.com',
  'https://v6.ident.me'
]
const IPPURE_API_ORIGIN: string = 'https://api.123169.xyz'
const IPPURE_IPV6_API_ORIGIN: string = 'https://api.ippure.com'
const IPPURE_GATEWAY_URL: string = 'https://api.123169.xyz/api/gateway/cf'

interface IpPureGeoPayload {
  country_code?: string
  subdivisions?: string
  city?: string
}

interface IpPureAsnPayload {
  number?: number
  organization?: string
  type?: string
}

interface IpPureBasicPayload {
  ip?: string
  asn?: IpPureAsnPayload
  geo?: Record<string, IpPureGeoPayload>
  traits?: Record<string, boolean>
}

interface IpPureRiskPayload {
  risk_score?: number
}

interface IpPureApiResponse<T> {
  ok?: boolean
  message?: string
  my_ip?: string
  data?: T
}

interface CloudflarePayload {
  ip?: string
  risk_score?: number
  ipMatch?: boolean
  ja3?: string
  ja4?: string
}

interface GatewayState {
  key: string
  serverTime: number
  localTime: number
}

interface HttpResult {
  statusCode: number
  body: string
  headers: Object
}

/**
 * 按 IPPure 网页当前使用的数据链路读取出口信息。
 *
 * 所有 HTTP 请求都逐次明确指定 `usingProxy`：VPN 开启时固定送入本机
 * mixed HTTP 端口，关闭时固定直连，避免继承系统或桌面代理状态。
 */
export class IpPureService {
  static async query(useProxy: boolean, mixedPort: number = 7890): Promise<IpInfo> {
    // 与 IPPure 官网保持一致：先分别发现双栈出口，有 IPv4 时始终检测 IPv4。
    // 不能直接请求一个双栈“当前 IP”接口，否则系统更偏好 IPv6 时会与浏览器
    // 页面显示的 IPv4 成为两个不同的检测对象。
    // 某些节点会单独拦截或重置 icanhazip 的 TLS。用三个彼此独立的纯文本
    // 入口顺序回退，并在 IPv4 成功后跳过 IPv6，既贴合 IPPure 网页的 IPv4
    // 优先逻辑，也避免一个辅助探测域名让整张卡误报失败。
    const ipv4 = await IpPureService.discoverFirst(IPV4_DISCOVERY_URLS, false, useProxy, mixedPort)
    const ipv6 = ipv4 ? '' :
      await IpPureService.discoverFirst(IPV6_DISCOVERY_URLS, true, useProxy, mixedPort)
    const targetIp = ipv4 || ipv6
    if (!targetIp) throw new Error('未发现可检测的公网 IPv4 或 IPv6')

    const apiOrigin = ipv4 ? IPPURE_API_ORIGIN : IPPURE_IPV6_API_ORIGIN
    const secureState: GatewayState = { key: '', serverTime: 0, localTime: 0 }
    const basic = await IpPureService.requestBasic(targetIp, apiOrigin, secureState, useProxy, mixedPort)
    let ipPureScore = -1
    let qualityError = ''
    if (ipv4) {
      try {
        ipPureScore = await IpPureService.requestRisk(targetIp, apiOrigin, secureState, useProxy, mixedPort)
      } catch (error) {
        qualityError = (error as Error).message || 'IPPure 系数读取失败'
      }
    }

    let cloudflareScore = -1
    if (ipv4) {
      try {
        const cloudflare = await IpPureService.requestCloudflare(useProxy, mixedPort)
        if (cloudflare.ip === targetIp || cloudflare.ipMatch === true) {
          cloudflareScore = IpPureService.normalizeScore(cloudflare.risk_score)
        } else {
          qualityError = IpPureService.appendError(qualityError, 'Cloudflare 检测出口与 IPPure 出口不一致')
        }
      } catch (error) {
        qualityError = IpPureService.appendError(qualityError,
          (error as Error).message || 'Cloudflare 系数读取失败')
      }
    }

    const geo = IpPureService.preferredGeo(basic.geo)
    const country = IpPureService.localizedCountry(geo?.country_code ?? '', geo?.country_code ?? '')
    const locationParts: string[] = [country]
    if (geo?.subdivisions) locationParts.push(geo.subdivisions)
    if (geo?.city && geo.city !== geo.subdivisions) locationParts.push(geo.city)
    const result = new IpInfo()
    result.ip = basic.ip ?? targetIp
    result.country = country
    result.location = locationParts.filter((value: string): boolean => value.length > 0).join(' · ')
    result.ipSource = IpPureService.sourceLabel(basic.traits)
    result.ipProperty = IpPureService.propertyLabel(basic.asn?.type)
    result.ipPureScore = ipPureScore
    result.cloudflareScore = cloudflareScore
    result.viaProxy = useProxy
    result.qualityError = qualityError
    result.updatedAt = Date.now()
    hilog.info(0xC031, 'IPPure',
      `检测完成 viaProxy=${useProxy} ip=${result.ip} ippure=${result.ipPureScore} cloudflare=${result.cloudflareScore}`)
    return result
  }

  private static async discoverFirst(urls: string[], ipv6: boolean,
    useProxy: boolean, mixedPort: number): Promise<string> {
    for (let index = 0; index < urls.length; index++) {
      try {
        const ip = await IpPureService.discoverIp(urls[index], useProxy, mixedPort)
        const valid = ipv6 ? IpPureService.isIpv6(ip) : IpPureService.isIpv4(ip)
        if (valid) return ip
      } catch (error) {
        hilog.warn(0xC031, 'IPPure',
          `公网 IP 发现入口 ${index + 1}/${urls.length} 失败: ${(error as Error).message}`)
      }
    }
    return ''
  }

  private static async discoverIp(url: string, useProxy: boolean, mixedPort: number): Promise<string> {
    const request = http.createHttp()
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'Accept': 'text/plain',
          'User-Agent': 'Mozilla/5.0 (HarmonyOS NEXT; IPPure Check)'
        },
        connectTimeout: 8000,
        readTimeout: 10000,
        usingCache: false,
        usingProxy: IpPureService.proxyOption(useProxy, mixedPort),
        expectDataType: http.HttpDataType.STRING
      })
      if (response.responseCode !== 200) {
        throw new Error(`公网 IP 发现接口 HTTP ${response.responseCode}`)
      }
      const raw = IpPureService.resultToString(response.result).trim()
      // Cloudflare trace 返回多行 key=value；其余服务返回纯文本。也兼容
      // 常见 {"ip":"..."} 响应，避免为每个发现站维护独立解析器。
      const traceMatch = raw.match(/(?:^|\n)ip=([^\s]+)/)
      const jsonMatch = raw.match(/"ip"\s*:\s*"([^"]+)"/)
      const ip = (traceMatch?.[1] ?? jsonMatch?.[1] ?? raw).trim()
      if (!ip) throw new Error('公网 IP 发现接口返回为空')
      return ip
    } finally {
      request.destroy()
    }
  }

  private static isIpv4(value: string): boolean {
    const parts = value.trim().split('.')
    if (parts.length !== 4) return false
    return parts.every((part: string): boolean => {
      if (!/^\d{1,3}$/.test(part)) return false
      const number = Number(part)
      return number >= 0 && number <= 255
    })
  }

  private static isIpv6(value: string): boolean {
    const normalized = value.trim()
    return normalized.includes(':') && /^[0-9a-f:]+$/i.test(normalized)
  }

  private static async requestBasic(ip: string, origin: string, state: GatewayState,
    useProxy: boolean, mixedPort: number): Promise<IpPureBasicPayload> {
    const response = await IpPureService.secureGet<IpPureBasicPayload>(
      `${origin}/api/info/ip-basic/${ip}`, state, useProxy, mixedPort)
    if (response.ok !== true || !response.data?.ip) {
      throw new Error(response.message || 'IPPure 基础信息接口未返回数据')
    }
    hilog.info(0xC031, 'IPPure',
      `基础信息 ip=${response.data.ip} type=${String(response.data.asn?.type)}`)
    return response.data
  }

  private static async requestRisk(ip: string, origin: string, state: GatewayState,
    useProxy: boolean, mixedPort: number): Promise<number> {
    const response = await IpPureService.secureGet<IpPureRiskPayload>(
      `${origin}/api/info/ip-risk/${ip}`, state, useProxy, mixedPort)
    if (response.ok !== true) throw new Error(response.message || 'IPPure 系数接口返回异常')
    const score = IpPureService.normalizeScore(response.data?.risk_score)
    if (score < 0) throw new Error('IPPure 系数接口未返回分数')
    return score
  }

  private static async secureGet<T>(url: string, state: GatewayState,
    useProxy: boolean, mixedPort: number): Promise<IpPureApiResponse<T>> {
    for (let attempt = 0; attempt < 5; attempt++) {
      const headers: Record<string, string> = {
        'Accept': 'application/json',
        'Origin': 'https://ippure.com',
        'Referer': 'https://ippure.com/',
        'User-Agent': 'Mozilla/5.0 (HarmonyOS NEXT; IPPure Check)'
      }
      if (state.key) {
        const timestamp = state.serverTime + (Date.now() - state.localTime)
        const signatureSource = `GET-${url}--${timestamp}`
        const signature = IpPureService.toHex(IpPureService.hmacSha256(
          new util.TextEncoder('utf-8').encodeInto(state.key),
          new util.TextEncoder('utf-8').encodeInto(signatureSource)))
        headers['x-k'] = state.key
        headers['x-t'] = `${timestamp}-${signature}`
      }

      const request = http.createHttp()
      try {
        const response = await request.request(url, {
          method: http.RequestMethod.GET,
          header: headers,
          connectTimeout: 8000,
          readTimeout: 10000,
          usingCache: false,
          usingProxy: IpPureService.proxyOption(useProxy, mixedPort),
          expectDataType: http.HttpDataType.STRING
        })
        const nextKey = IpPureService.headerValue(response.header, 'x-k')
        const nextTime = Number(IpPureService.headerValue(response.header, 'x-t'))
        hilog.info(0xC031, 'IPPure',
          `安全接口 attempt=${attempt + 1} status=${response.responseCode} rotate=${nextKey.length > 0}`)
        if (nextKey && Number.isFinite(nextTime) && nextTime > 0) {
          state.key = nextKey
          state.serverTime = nextTime
          state.localTime = Date.now()
          continue
        }
        if (response.responseCode !== 200) throw new Error(`IPPure 数据接口 HTTP ${response.responseCode}`)
        return IpPureService.parseJsonResult<IpPureApiResponse<T>>(response.result, 'IPPure 数据接口')
      } finally {
        request.destroy()
      }
    }
    throw new Error('IPPure 数据接口握手超时')
  }

  private static async requestCloudflare(useProxy: boolean, mixedPort: number): Promise<CloudflarePayload> {
    // 官网由隐藏 iframe 先访问 Cloudflare 测试页，摘要包含浏览器 Cookie、TLS
    // 和指纹信息。普通 HTTP 请求会被当成另一种客户端，风险分数会严重失真。
    const summaryHex = await CloudflareWebProbe.request(useProxy, mixedPort)
    if (summaryHex.startsWith('ERROR:')) throw new Error(summaryHex.substring(6))
    const rawSummary = IpPureService.fromHex(summaryHex)
    if (rawSummary.length === 0) throw new Error('Cloudflare 浏览器探针未返回摘要')

    let state: GatewayState = { key: '', serverTime: 0, localTime: 0 }
    for (let attempt = 0; attempt < 5; attempt++) {
      let body = rawSummary
      const headers: Record<string, string> = {
        'Accept': 'application/json',
        'Content-Type': 'application/octet-stream',
        'Origin': 'https://ippure.com',
        'Referer': 'https://ippure.com/',
        'User-Agent': 'Mozilla/5.0 (HarmonyOS NEXT; IPPure Check)'
      }
      if (state.key) {
        const timestamp = state.serverTime + (Date.now() - state.localTime)
        const bodyText = util.TextDecoder.create('utf-8').decodeToString(rawSummary)
        const signatureSource = `POST-${IPPURE_GATEWAY_URL}-${bodyText}-${timestamp}`
        const signature = IpPureService.toHex(IpPureService.hmacSha256(
          new util.TextEncoder('utf-8').encodeInto(state.key),
          new util.TextEncoder('utf-8').encodeInto(signatureSource)))
        const signedTime = `${timestamp}-${signature}`
        headers['x-k'] = state.key
        headers['x-t'] = signedTime
        body = await IpPureService.encryptGatewayBody(rawSummary, signedTime)
      }

      const response = await IpPureService.postGateway(body, headers, useProxy, mixedPort)
      const nextKey = IpPureService.headerValue(response.headers, 'x-k')
      const nextTime = Number(IpPureService.headerValue(response.headers, 'x-t'))
      hilog.info(0xC031, 'IPPure',
        `Cloudflare 握手 attempt=${attempt + 1} status=${response.statusCode} rotate=${nextKey.length > 0}`)
      if (nextKey && Number.isFinite(nextTime) && nextTime > 0) {
        state = { key: nextKey, serverTime: nextTime, localTime: Date.now() }
        continue
      }
      if (response.statusCode !== 200) throw new Error(`Cloudflare 系数接口 HTTP ${response.statusCode}`)
      const payload = JSON.parse(response.body) as CloudflarePayload
      if (!Number.isFinite(Number(payload.risk_score))) throw new Error('Cloudflare 系数接口未返回分数')
      hilog.info(0xC031, 'IPPure',
        `Cloudflare 结果 ip=${String(payload.ip)} riskScore=${String(payload.risk_score)} ` +
        `ja3=${String(payload.ja3)} ja4=${String(payload.ja4)}`)
      return payload
    }
    throw new Error('Cloudflare 系数接口握手超时')
  }

  private static async postGateway(body: Uint8Array, headers: Record<string, string>,
    useProxy: boolean, mixedPort: number): Promise<HttpResult> {
    const request = http.createHttp()
    try {
      // 网络栈会读取整个 ArrayBuffer；重新复制可避免某些系统返回的 Uint8Array
      // 共享 16 MB 缓冲池，导致实际上传长度大于有效数据长度。
      const exactBody = new Uint8Array(body.byteLength)
      exactBody.set(body)
      const response = await request.request(IPPURE_GATEWAY_URL, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: exactBody.buffer,
        connectTimeout: 8000,
        readTimeout: 10000,
        usingCache: false,
        usingProxy: IpPureService.proxyOption(useProxy, mixedPort),
        expectDataType: http.HttpDataType.STRING
      })
      return {
        statusCode: Number(response.responseCode),
        body: IpPureService.resultToString(response.result),
        headers: response.header
      }
    } finally {
      request.destroy()
    }
  }

  private static proxyOption(useProxy: boolean, mixedPort: number): boolean | connection.HttpProxy {
    if (!useProxy) return false
    return {
      host: '127.0.0.1',
      port: mixedPort > 0 ? mixedPort : 7890,
      exclusionList: []
    }
  }

  private static headerValue(headers: Object, name: string): string {
    const values = headers as Record<string, Object>
    for (const key of Object.keys(values)) {
      if (key.toLowerCase() !== name.toLowerCase()) continue
      const value = values[key]
      if (typeof value === 'string') return value
      if (Array.isArray(value) && value.length > 0) return String(value[0])
      return String(value ?? '')
    }
    return ''
  }

  private static resultToString(result: string | Object | ArrayBuffer): string {
    if (typeof result === 'string') return result
    if (result instanceof ArrayBuffer) {
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(result))
    }
    return JSON.stringify(result)
  }

  private static parseJsonResult<T>(result: string | Object | ArrayBuffer, source: string): T {
    try {
      if (typeof result === 'object' && !(result instanceof ArrayBuffer)) return result as T
      return JSON.parse(IpPureService.resultToString(result)) as T
    } catch (error) {
      throw new Error(`${source}返回内容解析失败: ${(error as Error).message}`)
    }
  }

  private static async encryptGatewayBody(source: Uint8Array, password: string): Promise<Uint8Array> {
    const keyBytes = IpPureService.sha256(new util.TextEncoder('utf-8').encodeInto(password))
    const random = cryptoFramework.createRandom().generateRandomSync(16).data
    const keyGenerator = cryptoFramework.createSymKeyGenerator('AES256')
    const key = keyGenerator.convertKeySync({ data: keyBytes })
    const cipher = cryptoFramework.createCipher('AES256|CBC|PKCS7')
    const params: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: random }
    }
    try {
      await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params)
      const encrypted = await cipher.doFinal({ data: source })
      return IpPureService.concatBytes(random, encrypted.data)
    } finally {
      key.clearMem()
    }
  }

  private static hmacSha256(key: Uint8Array, message: Uint8Array): Uint8Array {
    const blockSize = 64
    let normalizedKey = key
    if (normalizedKey.length > blockSize) normalizedKey = IpPureService.sha256(normalizedKey)
    const innerPad = new Uint8Array(blockSize)
    const outerPad = new Uint8Array(blockSize)
    for (let index = 0; index < blockSize; index++) {
      const keyByte = index < normalizedKey.length ? normalizedKey[index] : 0
      innerPad[index] = keyByte ^ 0x36
      outerPad[index] = keyByte ^ 0x5C
    }
    const inner = IpPureService.sha256(IpPureService.concatBytes(innerPad, message))
    return IpPureService.sha256(IpPureService.concatBytes(outerPad, inner))
  }

  private static sha256(source: Uint8Array): Uint8Array {
    const constants = new Uint32Array([
      1116352408, 1899447441, 3049323471, 3921009573, 961987163, 1508970993, 2453635748, 2870763221,
      3624381080, 310598401, 607225278, 1426881987, 1925078388, 2162078206, 2614888103, 3248222580,
      3835390401, 4022224774, 264347078, 604807628, 770255983, 1249150122, 1555081692, 1996064986,
      2554220882, 2821834349, 2952996808, 3210313671, 3336571891, 3584528711, 113926993, 338241895,
      666307205, 773529912, 1294757372, 1396182291, 1695183700, 1986661051, 2177026350, 2456956037,
      2730485921, 2820302411, 3259730800, 3345764771, 3516065817, 3600352804, 4094571909, 275423344,
      430227734, 506948616, 659060556, 883997877, 958139571, 1322822218, 1537002063, 1747873779,
      1955562222, 2024104815, 2227730452, 2361852424, 2428436474, 2756734187, 3204031479, 3329325298
    ])
    const bitLength = source.length * 8
    const paddedLength = (((source.length + 8) >> 6) + 1) << 6
    const padded = new Uint8Array(paddedLength)
    padded.set(source)
    padded[source.length] = 0x80
    const view = new DataView(padded.buffer)
    view.setUint32(paddedLength - 8, Math.floor(bitLength / 4294967296))
    view.setUint32(paddedLength - 4, bitLength >>> 0)
    let h0 = 1779033703
    let h1 = 3144134277
    let h2 = 1013904242
    let h3 = 2773480762
    let h4 = 1359893119
    let h5 = 2600822924
    let h6 = 528734635
    let h7 = 1541459225
    const schedule = new Uint32Array(64)
    const rotateRight = (value: number, count: number): number =>
      ((value >>> count) | (value << (32 - count))) >>> 0
    for (let offset = 0; offset < paddedLength; offset += 64) {
      for (let index = 0; index < 16; index++) schedule[index] = view.getUint32(offset + index * 4)
      for (let index = 16; index < 64; index++) {
        const first = schedule[index - 15]
        const second = schedule[index - 2]
        const small0 = rotateRight(first, 7) ^ rotateRight(first, 18) ^ (first >>> 3)
        const small1 = rotateRight(second, 17) ^ rotateRight(second, 19) ^ (second >>> 10)
        schedule[index] = (schedule[index - 16] + small0 + schedule[index - 7] + small1) >>> 0
      }
      let a = h0
      let b = h1
      let c = h2
      let d = h3
      let e = h4
      let f = h5
      let g = h6
      let h = h7
      for (let index = 0; index < 64; index++) {
        const upper = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
        const choose = (e & f) ^ ((~e) & g)
        const temp1 = (h + upper + choose + constants[index] + schedule[index]) >>> 0
        const lower = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
        const majority = (a & b) ^ (a & c) ^ (b & c)
        const temp2 = (lower + majority) >>> 0
        h = g
        g = f
        f = e
        e = (d + temp1) >>> 0
        d = c
        c = b
        b = a
        a = (temp1 + temp2) >>> 0
      }
      h0 = (h0 + a) >>> 0
      h1 = (h1 + b) >>> 0
      h2 = (h2 + c) >>> 0
      h3 = (h3 + d) >>> 0
      h4 = (h4 + e) >>> 0
      h5 = (h5 + f) >>> 0
      h6 = (h6 + g) >>> 0
      h7 = (h7 + h) >>> 0
    }
    const digest = new Uint8Array(32)
    const digestView = new DataView(digest.buffer)
    digestView.setUint32(0, h0)
    digestView.setUint32(4, h1)
    digestView.setUint32(8, h2)
    digestView.setUint32(12, h3)
    digestView.setUint32(16, h4)
    digestView.setUint32(20, h5)
    digestView.setUint32(24, h6)
    digestView.setUint32(28, h7)
    return digest
  }

  private static concatBytes(first: Uint8Array, second: Uint8Array): Uint8Array {
    const result = new Uint8Array(first.length + second.length)
    result.set(first, 0)
    result.set(second, first.length)
    return result
  }

  private static toHex(value: Uint8Array): string {
    let result = ''
    for (const byte of value) result += byte.toString(16).padStart(2, '0')
    return result
  }

  private static fromHex(value: string): Uint8Array {
    const normalized = value.trim()
    if (normalized.length === 0 || normalized.length % 2 !== 0) return new Uint8Array(0)
    const result = new Uint8Array(normalized.length / 2)
    for (let index = 0; index < result.length; index++) {
      const byte = Number.parseInt(normalized.substring(index * 2, index * 2 + 2), 16)
      if (!Number.isFinite(byte)) return new Uint8Array(0)
      result[index] = byte
    }
    return result
  }

  private static normalizeScore(value: number | undefined): number {
    const score = Number(value)
    if (!Number.isFinite(score)) return -1
    return Math.max(0, Math.min(100, Math.round(score)))
  }

  private static preferredGeo(geo: Record<string, IpPureGeoPayload> | undefined): IpPureGeoPayload | undefined {
    return geo?.['IP2Location'] ?? geo?.['DB-IP'] ?? geo?.['MaxMind']
  }

  private static sourceLabel(traits: Record<string, boolean> | undefined): string {
    const broadcast = traits?.['is_broadcast']
    if (broadcast === true) return '广播IP'
    if (broadcast === false) return '原生IP'
    return '未知'
  }

  private static propertyLabel(type: string | undefined): string {
    switch (type) {
      case 'isp': return '住宅IP'
      case 'hosting': return '机房IP'
      case 'business': return '机房IP'
      case 'enterprise': return '商业宽带'
      case 'education': return '教育IP'
      case 'government': return '政府IP'
      default: return '未知'
    }
  }

  private static appendError(current: string, next: string): string {
    return current ? `${current}；${next}` : next
  }

  private static localizedCountry(code: string, fallback: string): string {
    switch (code.toUpperCase()) {
      case 'CN': return '中国'
      case 'HK': return '中国香港'
      case 'MO': return '中国澳门'
      case 'TW': return '中国台湾'
      case 'US': return '美国'
      case 'CA': return '加拿大'
      case 'GB': return '英国'
      case 'DE': return '德国'
      case 'FR': return '法国'
      case 'JP': return '日本'
      case 'KR': return '韩国'
      case 'SG': return '新加坡'
      case 'MY': return '马来西亚'
      case 'TH': return '泰国'
      case 'PH': return '菲律宾'
      case 'ID': return '印度尼西亚'
      case 'VN': return '越南'
      case 'IN': return '印度'
      case 'AU': return '澳大利亚'
      case 'NZ': return '新西兰'
      case 'RU': return '俄罗斯'
      case 'UA': return '乌克兰'
      case 'NL': return '荷兰'
      case 'BE': return '比利时'
      case 'CH': return '瑞士'
      case 'SE': return '瑞典'
      case 'NO': return '挪威'
      case 'FI': return '芬兰'
      case 'DK': return '丹麦'
      case 'IT': return '意大利'
      case 'ES': return '西班牙'
      case 'PT': return '葡萄牙'
      case 'PL': return '波兰'
      case 'TR': return '土耳其'
      case 'AE': return '阿联酋'
      case 'IL': return '以色列'
      case 'BR': return '巴西'
      case 'MX': return '墨西哥'
      case 'AR': return '阿根廷'
      default: return fallback || code
    }
  }
}

export default IpPureService
