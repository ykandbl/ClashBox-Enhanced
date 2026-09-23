import { http } from '@kit.NetworkKit'
import { SubscriptionInfo } from 'proxy_core/src/main/ets/models/Common'
import { parse } from 'yaml'

interface SubscriptionClashDocument {
  proxies?: Object[]
  'proxy-groups'?: Object[]
}

export interface SubscriptionStructure {
  valid: boolean
  format: string
  proxyCount: number
  providerCount: number
}

interface SubscriptionResponse {
  statusCode: number
  content: string
  headers: Object
}

export interface CompatibleSubscriptionDownload {
  content: string
  format: string
  proxyCount: number
  providerCount: number
  subscriptionInfo: SubscriptionInfo | null
  diagnostic: string
}

const COMPATIBLE_USER_AGENTS: string[] = [
  'clash.meta/1.19.30',
  'Clash.Meta',
  'clash-verge/v2.4.2',
  'v2rayN/7.0'
]

/**
 * 与服务商无关的订阅兼容入口。后端换模板时依次识别 Clash YAML/JSON、
 * 代理提供者配置、明文 URI 和 base64 URI；最终仍必须经过 Mihomo 核心校验
 * 才能原子替换旧文件。
 */
export class SubscriptionCompatibilityService {
  static async download(url: string): Promise<CompatibleSubscriptionDownload> {
    if (!/^https?:\/\//i.test(url.trim())) throw new Error('订阅地址不是有效的 HTTP(S) URL')
    const failures: string[] = []
    let uriFallback = ''
    let metadata: SubscriptionInfo | null = null
    for (let index = 0; index < COMPATIBLE_USER_AGENTS.length; index++) {
      try {
        const response = await SubscriptionCompatibilityService.request(url, COMPATIBLE_USER_AGENTS[index])
        if (response.statusCode < 200 || response.statusCode >= 300) {
          failures.push(`${SubscriptionCompatibilityService.uaLabel(index)} HTTP ${response.statusCode}`)
          continue
        }
        metadata = SubscriptionCompatibilityService.readSubscriptionInfo(response.headers, response.content)
        SubscriptionCompatibilityService.rejectErrorDocument(response.content)
        const structure = SubscriptionCompatibilityService.inspectClashContent(response.content)
        if (structure.valid) {
          return {
            content: response.content,
            format: structure.format,
            proxyCount: structure.proxyCount,
            providerCount: structure.providerCount,
            subscriptionInfo: metadata,
            diagnostic: structure.providerCount > 0 ?
              `${structure.format} · ${structure.providerCount}个提供者` :
              `${structure.format} · ${structure.proxyCount}个节点`
          }
        }
        if (!uriFallback && SubscriptionCompatibilityService.isUriSubscription(response.content)) {
          uriFallback = response.content
        } else {
          failures.push(`${SubscriptionCompatibilityService.uaLabel(index)} 格式未识别`)
        }
      } catch (error) {
        failures.push(`${SubscriptionCompatibilityService.uaLabel(index)} ${(error as Error).message}`)
      }
    }
    if (uriFallback) {
      return {
        content: uriFallback,
        format: 'URI/base64',
        proxyCount: 0,
        providerCount: 0,
        subscriptionInfo: metadata,
        diagnostic: 'URI/base64 · 等待核心转换'
      }
    }
    throw new Error(`订阅兼容链全部失败：${SubscriptionCompatibilityService.compactFailures(failures)}`)
  }

  static inspectClashContent(content: string): SubscriptionStructure {
    try {
      const config = parse(content) as SubscriptionClashDocument
      if (!config || typeof config !== 'object') {
        return { valid: false, format: '', proxyCount: 0, providerCount: 0 }
      }
      const proxyCount = Array.isArray(config.proxies) ? config.proxies.length : 0
      // ArkTS 禁止按带连字符的字段名索引对象，因此从已经通过 YAML/JSON
      // 解析的原文统计顶层 provider 键；不能把 provider 内的 type/url 算进去。
      const providerCount = SubscriptionCompatibilityService.countProxyProviders(content)
      if (proxyCount === 0 && providerCount === 0) {
        return { valid: false, format: '', proxyCount: 0, providerCount: 0 }
      }
      const trimmed = content.trim()
      return {
        valid: true,
        format: trimmed.startsWith('{') ? 'Clash JSON' : 'Clash YAML',
        proxyCount: proxyCount,
        providerCount: providerCount
      }
    } catch (_) {
      return { valid: false, format: '', proxyCount: 0, providerCount: 0 }
    }
  }

  static sanitizeReason(reason: string): string {
    return reason.replace(/https?:\/\/[^\s]+/gi, '[url]')
      .replace(/[A-Za-z0-9_+\/=.-]{80,}/g, '[secret]')
      .substring(0, 300)
  }

  private static async request(url: string, userAgent: string): Promise<SubscriptionResponse> {
    const request = http.createHttp()
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': userAgent,
          'Accept': 'text/yaml,text/plain,application/yaml,application/json,*/*',
          'Accept-Encoding': 'identity',
          'Cache-Control': 'no-cache'
        },
        connectTimeout: 15000,
        readTimeout: 15000,
        usingCache: false,
        maxLimit: 100 * 1024 * 1024,
        expectDataType: http.HttpDataType.STRING
      })
      return {
        statusCode: response.responseCode,
        content: typeof response.result === 'string' ? response.result : '',
        headers: response.header
      }
    } finally {
      request.destroy()
    }
  }

  private static rejectErrorDocument(content: string): void {
    const trimmed = content.trim()
    if (!trimmed) throw new Error('返回正文为空')
    const lower = trimmed.substring(0, 4096).toLowerCase()
    if (lower.startsWith('<!doctype') || lower.startsWith('<html') ||
      /captcha|cloudflare challenge|document\.cookie|人机验证/.test(lower)) {
      throw new Error('返回登录页或人机验证页面')
    }
    if (trimmed.startsWith('{')) {
      try {
        const payload = JSON.parse(trimmed) as Record<string, Object>
        const message = payload['message'] ?? payload['msg'] ?? payload['error']
        if (message && !payload['proxies'] && !payload['proxy-providers']) {
          throw new Error(`服务端错误：${`${message}`.substring(0, 80)}`)
        }
      } catch (error) {
        if ((error as Error).message.startsWith('服务端错误：')) {
          throw new Error((error as Error).message)
        }
      }
    }
  }

  private static isUriSubscription(content: string): boolean {
    const trimmed = content.trim()
    if (/^(?:ss|ssr|vmess|vless|trojan|hysteria2?|hy2|tuic|wireguard):\/\//im.test(trimmed)) {
      return true
    }
    return trimmed.length >= 16 && trimmed.length <= 20 * 1024 * 1024 &&
      /^[A-Za-z0-9+\/=\r\n_-]+$/.test(trimmed)
  }

  private static countProxyProviders(content: string): number {
    const trimmed = content.trim()
    if (trimmed.startsWith('{')) {
      return SubscriptionCompatibilityService.countJsonProxyProviders(trimmed)
    }
    const lines = content.split(/\r?\n/)
    let baseIndent = -1
    let providerIndent = -1
    let count = 0
    for (const line of lines) {
      const providerHeader = line.match(/^(\s*)proxy-providers\s*:\s*(?:#.*)?$/)
      if (providerHeader) {
        baseIndent = providerHeader[1].length
        continue
      }
      if (baseIndent < 0 || line.trim().length === 0 || line.trim().startsWith('#')) continue
      const indent = line.length - line.trimStart().length
      if (indent <= baseIndent) break
      if (!/^\s+[^\s#][^:]*\s*:/.test(line)) continue
      if (providerIndent < 0) providerIndent = indent
      // 只统计 proxy-providers 的直接子键，不能把 type、url 等字段算成提供者。
      if (indent === providerIndent) count++
    }
    return count
  }

  /** 统计 JSON 中 proxy-providers 对象的直接成员，不受嵌套字段或数组影响。 */
  private static countJsonProxyProviders(content: string): number {
    const marker = content.search(/"proxy-providers"\s*:\s*\{/)
    if (marker < 0) return 0
    const openingBrace = content.indexOf('{', marker)
    if (openingBrace < 0) return 0
    let objectDepth = 0
    let arrayDepth = 0
    let count = 0
    let inString = false
    let escaped = false
    let expectingKey = false
    let readingTopLevelKey = false
    for (let index = openingBrace; index < content.length; index++) {
      const character = content.charAt(index)
      if (inString) {
        if (escaped) {
          escaped = false
        } else if (character === '\\') {
          escaped = true
        } else if (character === '"') {
          inString = false
          if (readingTopLevelKey) {
            count++
            readingTopLevelKey = false
          }
        }
        continue
      }
      if (character === '"') {
        inString = true
        readingTopLevelKey = objectDepth === 1 && arrayDepth === 0 && expectingKey
        if (readingTopLevelKey) expectingKey = false
      } else if (character === '{') {
        objectDepth++
        if (objectDepth === 1) expectingKey = true
      } else if (character === '}') {
        if (objectDepth === 1) break
        objectDepth--
      } else if (character === '[') {
        arrayDepth++
      } else if (character === ']') {
        arrayDepth--
      } else if (character === ',' && objectDepth === 1 && arrayDepth === 0) {
        expectingKey = true
      }
    }
    return count
  }

  private static readSubscriptionInfo(headers: Object, content: string): SubscriptionInfo | null {
    const raw = SubscriptionCompatibilityService.headerValue(headers, 'subscription-userinfo')
    if (raw) return SubscriptionInfo.formHString(raw)
    const fromConfig = SubscriptionInfo.formConfigText(content)
    return fromConfig.state === 'unknown' ? null : fromConfig
  }

  private static headerValue(headersObject: Object, name: string): string {
    const headers = headersObject as Record<string, string>
    const expected = name.toLowerCase()
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() === expected) return headers[key]
    }
    return ''
  }

  private static uaLabel(index: number): string {
    if (index === 0) return 'Mihomo'
    if (index === 1) return 'Clash.Meta'
    if (index === 2) return 'Clash Verge'
    return 'URI客户端'
  }

  private static compactFailures(failures: string[]): string {
    const unique: string[] = []
    for (const failure of failures) {
      const safe = SubscriptionCompatibilityService.sanitizeReason(failure)
      if (!unique.includes(safe)) unique.push(safe)
    }
    return unique.slice(0, 4).join('；') || '没有返回可识别配置'
  }
}

export default SubscriptionCompatibilityService
