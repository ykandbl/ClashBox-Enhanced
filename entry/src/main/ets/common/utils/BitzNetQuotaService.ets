import { http } from '@kit.NetworkKit'
import { JSON } from '@kit.ArkTS'
import { Xb_SecureKVdbUtil } from 'xb_components'
import { SubscriptionInfo } from 'proxy_core/src/main/ets/models/Common'
import { parse } from 'yaml'
import { hilog } from '@kit.PerformanceAnalysisKit'

const CREDENTIAL_KEY_PREFIX: string = 'bitznet_credential_'
const ENDPOINT_CACHE_KEY: string = 'bitznet_api_endpoints'
const BITZ_API_BASES: string[] = [
  'https://ent.webitz.net/api/v1',
  'https://sec.webitz.net/api/v1',
  'https://sec.thisbitz.com/api/v1',
  'https://ent.neobitz.net/api/v1'
]
const BITZ_DISCOVERY_ROOTS: string[] = [
  'https://thisbitz.com',
  'https://webitz.net',
  'https://bitzconnect.com',
  // BitzNet 对外维护的入口页相对稳定；仅在所有已知 API 都失效时才访问。
  'https://github.com/edutfree/bitznet'
]
/** BitzNet 官方桌面客户端下载订阅配置时使用的客户端标识。 */
const BITZ_SUBSCRIPTION_USER_AGENT: string = 'BBGen2UA'
const BITZ_CLASH_USER_AGENT: string = 'Clash.Meta'
const BITZ_LOG_DOMAIN: number = 0xC012
const BITZ_LOG_TAG: string = 'BitzSubscription'

export interface BitzNetCredential {
  username: string
  password: string
  authorization: string
  apiBase: string
  /** getSubscribe 返回的稳定订阅地址，仅保存在加密 KV 中。 */
  subscriptionUrl: string
}

interface BitzApiData {
  auth_data?: string
  u?: number
  d?: number
  transfer_enable?: number
  expired_at?: number
  subscribe_url?: string
}

interface BitzApiPayload {
  data?: BitzApiData
  message?: string
}

interface BitzHttpResult {
  statusCode: number
  payload: BitzApiPayload
}

export interface BitzNetValidationResult {
  authorization: string
  apiBase: string
  subscriptionUrl: string
  subscriptionInfo: SubscriptionInfo
}

export interface BitzNetSubscriptionDownload {
  content: string
  contentHash: string
  proxyCount: number
  subscriptionInfo: SubscriptionInfo
  format: string
}

interface BitzSubscriptionConfig {
  proxies?: Object[]
}

interface BitzTextResult {
  statusCode: number
  content: string
}

interface BitzSubscriptionCandidate {
  url: string
  /** 只有账号接口明确返回或同源迁移的地址才能携带登录令牌。 */
  useAuthorization: boolean
  source: string
}

/** 与 BitzNet 官方客户端一致的 DJB2 变体，用于跳过未变化配置的核心重载。 */
export function bitzSubscriptionHash(content: string): string {
  let hash = 5381
  for (let index = 0; index < content.length; index++) {
    hash = (hash * 33) ^ content.charCodeAt(index)
  }
  return (hash >>> 0).toString(16)
}

/** 面板会返回 http 地址，但下载仍强制 HTTPS，避免明文发送登录令牌。 */
export function normalizeBitzSubscriptionUrl(value: string): string {
  const match = value.trim().match(/^https?:\/\/([^/?#\s]+)([^\s]*)$/i)
  if (!match || /[@\\]/.test(match[1]) || match[2].includes('\\')) return ''
  const authority = match[1].replace(/:80$/, '')
  return `https://${authority}${match[2] || '/'}`
}

/** BBGen2UA 本身不会选择 Clash 格式，必须显式请求 flag=clash。 */
export function bitzClashSubscriptionUrl(value: string): string {
  const normalized = normalizeBitzSubscriptionUrl(value).split('#')[0]
  if (!normalized) return ''
  const queryIndex = normalized.indexOf('?')
  const path = queryIndex >= 0 ? normalized.substring(0, queryIndex) : normalized
  const parameters = queryIndex >= 0 ? normalized.substring(queryIndex + 1).split('&') : []
  const retained = parameters.filter((parameter: string): boolean =>
    parameter.length > 0 && parameter.split('=')[0] !== 'flag')
  retained.push('flag=clash')
  return path + '?' + retained.join('&')
}

/**
 * BitzNet 账号凭据保存于单独的 encrypt=true KVStore。普通配置数据库只保存
 * “是否启用”与刷新状态，不包含账号、密码或 authorization。
 */
export class BitzNetCredentialStore {
  static async save(profileId: string, username: string, password: string,
    authorization: string = '', apiBase: string = '', subscriptionUrl?: string): Promise<void> {
    // 老调用只更新令牌或 API 域名时，保留最近一次 getSubscribe 返回的稳定地址。
    const previous = subscriptionUrl === undefined ? await BitzNetCredentialStore.load(profileId) : null
    const value: BitzNetCredential = {
      username: username.trim(),
      password: password,
      authorization: authorization,
      apiBase: apiBase,
      subscriptionUrl: subscriptionUrl ?? previous?.subscriptionUrl ?? ''
    }
    await Xb_SecureKVdbUtil.putData(CREDENTIAL_KEY_PREFIX + profileId, JSON.stringify(value))
  }

  static async load(profileId: string): Promise<BitzNetCredential | null> {
    try {
      const raw = await Xb_SecureKVdbUtil.getData(CREDENTIAL_KEY_PREFIX + profileId)
      if (typeof raw !== 'string' || !raw) {
        return null
      }
      const value = JSON.parse(raw) as BitzNetCredential
      if (!value.username || !value.password) {
        return null
      }
      value.subscriptionUrl = value.subscriptionUrl ?? ''
      return value
    } catch (_) {
      return null
    }
  }

  static async remove(profileId: string): Promise<void> {
    try {
      await Xb_SecureKVdbUtil.deleteData(CREDENTIAL_KEY_PREFIX + profileId)
    } catch (_) {
    }
  }

  /** 删除全部 BitzNet 登录凭据以及已发现的动态 API 入口。 */
  static async clearAll(): Promise<void> {
    try {
      await Xb_SecureKVdbUtil.deleteEntriesByPrefix(CREDENTIAL_KEY_PREFIX)
    } catch (_) {
    }
    try {
      await Xb_SecureKVdbUtil.deleteData(ENDPOINT_CACHE_KEY)
    } catch (_) {
    }
  }
}

/**
 * 跨配置共享最近成功的 BitzNet API 入口。站点切换域名后，只要任意一个账号
 * 成功发现新入口，后续新增账号和其他账号刷新都会优先复用它。
 */
class BitzNetEndpointStore {
  static async load(): Promise<string[]> {
    try {
      const raw = await Xb_SecureKVdbUtil.getData(ENDPOINT_CACHE_KEY)
      if (typeof raw !== 'string' || !raw) return []
      const values = JSON.parse(raw) as string[]
      return values.filter((value: string): boolean => value.startsWith('https://'))
    } catch (_) {
      return []
    }
  }

  static async remember(apiBase: string): Promise<void> {
    if (!apiBase.startsWith('https://')) return
    const previous = await BitzNetEndpointStore.load()
    const next: string[] = [apiBase]
    for (const value of previous) {
      if (value !== apiBase && next.length < 8) next.push(value)
    }
    await Xb_SecureKVdbUtil.putData(ENDPOINT_CACHE_KEY, JSON.stringify(next))
  }
}

export class BitzNetQuotaService {
  /** 网络抖动、网关限流或服务端暂时不可用时，不应被误判为账号失效。 */
  static isTransientError(reason: string): boolean {
    const value = reason.toLowerCase()
    if (/http (401|403)|账号密码|密码错误|账号不存在|未登录|登录失败|unauthorized|forbidden|invalid (credential|password)/.test(value)) {
      return false
    }
    return /连接|超时|timeout|timed out|network|socket|dns|host|resolve|connect|connection|reset|closed|eof|tls|ssl|handshake|拒绝|不可用|服务端错误|http (408|425|429|5\d\d)/.test(value)
  }

  /** 始终保留 HTTP 状态码，避免有 message 的 429/5xx 被当成普通登录错误。 */
  static httpFailureReason(stage: string, statusCode: number, message: string = ''): string {
    const detail = message.trim()
    return `${stage} HTTP ${statusCode}${detail ? `：${detail}` : ''}`
  }

  /** 多面板全部失败时，以账号最近成功面板的结果为准。 */
  static preferredFailureReason(primaryReason: string, fallbackReason: string): string {
    return primaryReason || fallbackReason
  }

  private static async retryDelay(): Promise<void> {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => resolve(), 1200)
    })
  }

  /**
   * 保存前强制使用当前输入的账号密码重新登录，并立即读取一次套餐信息。
   * 这里不读取或写入本地凭据，调用方只在完整验证成功后才持久化。
   */
  static async validateCredentials(username: string, password: string,
    subscriptionUrl: string = ''): Promise<BitzNetValidationResult> {
    const normalizedUsername = username.trim()
    if (!normalizedUsername || !password) {
      throw new Error('请输入 BitzNet 账号和密码')
    }
    let lastReason = 'BitzNet 登录服务连接失败'
    const bases = await BitzNetQuotaService.orderedBases('',
      BitzNetQuotaService.apiBaseFromSubscriptionUrl(subscriptionUrl))
    for (const base of bases) {
      try {
        return await BitzNetQuotaService.validateAtBase(base, normalizedUsername, password)
      } catch (error) {
        lastReason = (error as Error).message
      }
    }

    // 已缓存及内置入口全部失败后，从 BitzNet 官方入口页发现新的用户面板。
    const dynamicBases = await BitzNetQuotaService.discoverApiBases()
    for (const base of dynamicBases) {
      if (bases.includes(base)) continue
      try {
        return await BitzNetQuotaService.validateAtBase(base, normalizedUsername, password)
      } catch (error) {
        lastReason = (error as Error).message
      }
    }
    throw new Error(lastReason)
  }

  static async refresh(profileId: string, subscriptionUrl: string = '', allowRetry: boolean = true,
    preferredOnly: boolean = false): Promise<SubscriptionInfo> {
    const credential = await BitzNetCredentialStore.load(profileId)
    if (!credential) {
      throw new Error('请在配置编辑中填写 BitzNet 账号和密码')
    }

    let bases = await BitzNetQuotaService.orderedBases(credential.apiBase,
      BitzNetQuotaService.apiBaseFromSubscriptionUrl(subscriptionUrl))
    if (preferredOnly && bases.length > 1) bases = [bases[0]]
    let lastReason = 'BitzNet 额度服务连接失败'

    // 优先复用上一次登录令牌。令牌失效后才重新用加密保存的账号密码登录。
    if (credential.authorization) {
      for (let baseIndex = 0; baseIndex < bases.length; baseIndex++) {
        const base = bases[baseIndex]
        // 账号最近成功的首选面板优先原地短重试。否则首选面板的一次 503
        // 可能被随后无关面板的 401 覆盖，最终误报成账号密码失效。
        const attemptCount = allowRetry && baseIndex === 0 ? 2 : 1
        for (let attempt = 0; attempt < attemptCount; attempt++) {
          try {
            const quotaResult = await BitzNetQuotaService.requestQuota(base, credential.authorization)
            if (quotaResult.statusCode === 200 && quotaResult.payload.data) {
              await BitzNetEndpointStore.remember(base)
              const latestSubscriptionUrl = quotaResult.payload.data.subscribe_url?.trim() ||
                credential.subscriptionUrl
              if (credential.apiBase !== base || credential.subscriptionUrl !== latestSubscriptionUrl) {
                await BitzNetCredentialStore.save(profileId, credential.username, credential.password,
                  credential.authorization, base, latestSubscriptionUrl)
              }
              return BitzNetQuotaService.toSubscriptionInfo(quotaResult.payload.data)
            }
            lastReason = BitzNetQuotaService.httpFailureReason('额度接口', quotaResult.statusCode,
              quotaResult.payload.message)
          } catch (error) {
            lastReason = (error as Error).message
          }
          if (attempt + 1 < attemptCount && BitzNetQuotaService.isTransientError(lastReason)) {
            hilog.warn(BITZ_LOG_DOMAIN, BITZ_LOG_TAG,
              `stage=preferred_quota_retry profileId=${profileId}, ` +
              `reason=${BitzNetQuotaService.sanitizeLogReason(lastReason)}`)
            await BitzNetQuotaService.retryDelay()
          } else {
            break
          }
        }
      }
    }

    // 周期任务遇到 DNS/路由类错误时立即交给全局退避，不再尝试登录、备用
    // 面板和入口发现。明确的令牌失效仍允许在首选面板重新登录一次。
    if (preferredOnly && credential.authorization && BitzNetQuotaService.isTransientError(lastReason)) {
      throw new Error(lastReason)
    }

    // 已保存令牌在全部已知入口都失效时，从官方入口页补充新的面板域名。
    if (!preferredOnly) {
      const dynamicBases = await BitzNetQuotaService.discoverApiBases()
      for (const base of dynamicBases) {
        if (!bases.includes(base)) bases.push(base)
      }
    }

    let primaryLoginReason = ''
    for (let baseIndex = 0; baseIndex < bases.length; baseIndex++) {
      const base = bases[baseIndex]
      try {
        const loginResult = await BitzNetQuotaService.login(base, credential.username, credential.password)
        const authorization = loginResult.payload.data?.auth_data ?? ''
        if (loginResult.statusCode !== 200 || !authorization) {
          lastReason = BitzNetQuotaService.httpFailureReason('账号登录', loginResult.statusCode,
            loginResult.payload.message)
          if (baseIndex === 0) primaryLoginReason = lastReason
          continue
        }
        await BitzNetCredentialStore.save(profileId, credential.username, credential.password,
          authorization, base, credential.subscriptionUrl)
        const quotaResult = await BitzNetQuotaService.requestQuota(base, authorization)
        if (quotaResult.statusCode === 200 && quotaResult.payload.data) {
          await BitzNetEndpointStore.remember(base)
          await BitzNetCredentialStore.save(profileId, credential.username, credential.password,
            authorization, base, quotaResult.payload.data.subscribe_url?.trim() || credential.subscriptionUrl)
          return BitzNetQuotaService.toSubscriptionInfo(quotaResult.payload.data)
        }
        lastReason = BitzNetQuotaService.httpFailureReason('额度接口', quotaResult.statusCode,
          quotaResult.payload.message)
      } catch (error) {
        lastReason = (error as Error).message
        if (baseIndex === 0) primaryLoginReason = lastReason
      }
    }
    // 全部入口均失败时，首选面板的结果比无关备用面板的 401 更能代表该账号。
    // 例如 wu 属于面板 A，A 暂时 503，而面板 B 不认识 wu 并返回 401。
    const finalReason = BitzNetQuotaService.preferredFailureReason(primaryLoginReason, lastReason)
    if (allowRetry && BitzNetQuotaService.isTransientError(finalReason)) {
      hilog.warn(BITZ_LOG_DOMAIN, BITZ_LOG_TAG,
        `stage=transient_refresh_retry profileId=${profileId}, reason=${BitzNetQuotaService.sanitizeLogReason(finalReason)}`)
      await BitzNetQuotaService.retryDelay()
      return await BitzNetQuotaService.refresh(profileId, subscriptionUrl, false, preferredOnly)
    }
    throw new Error(finalReason)
  }

  /**
   * 使用账号登录态刷新稳定订阅地址，再按官方客户端请求语义下载 Clash YAML。
   * 临时激活 URL 即使已返回 403，也不会影响加密 KV 中的稳定地址与旧配置。
   */
  static async downloadSubscription(profileId: string,
    fallbackUrl: string = ''): Promise<BitzNetSubscriptionDownload> {
    hilog.warn(BITZ_LOG_DOMAIN, BITZ_LOG_TAG,
      `stage=account_refresh_start profileId=${profileId}`)
    const subscriptionInfo = await BitzNetQuotaService.refresh(profileId, fallbackUrl)
    hilog.warn(BITZ_LOG_DOMAIN, BITZ_LOG_TAG,
      `stage=account_refresh_ok profileId=${profileId}`)
    const credential = await BitzNetCredentialStore.load(profileId)
    if (!credential || !credential.authorization) {
      throw new Error('BitzNet 登录状态已失效')
    }
    hilog.warn(BITZ_LOG_DOMAIN, BITZ_LOG_TAG,
      `stage=stable_url_ready profileId=${profileId}, present=${credential.subscriptionUrl.length > 0}`)
    return await BitzNetQuotaService.downloadWithSession(credential.authorization, credential.apiBase,
      credential.subscriptionUrl, fallbackUrl, subscriptionInfo, profileId)
  }

  /** 新增配置尚未落库时，直接复用本次保存前已经验证成功的登录会话。 */
  static async downloadValidatedSubscription(validation: BitzNetValidationResult,
    fallbackUrl: string = ''): Promise<BitzNetSubscriptionDownload> {
    return await BitzNetQuotaService.downloadWithSession(validation.authorization, validation.apiBase,
      validation.subscriptionUrl, fallbackUrl, validation.subscriptionInfo, 'new-profile')
  }

  private static async validateAtBase(base: string, username: string,
    password: string): Promise<BitzNetValidationResult> {
    const loginResult = await BitzNetQuotaService.login(base, username, password)
    const authorization = loginResult.payload.data?.auth_data ?? ''
    if (loginResult.statusCode !== 200 || !authorization) {
      throw new Error(BitzNetQuotaService.httpFailureReason('登录接口', loginResult.statusCode,
        loginResult.payload.message))
    }
    const quotaResult = await BitzNetQuotaService.requestQuota(base, authorization)
    if (quotaResult.statusCode !== 200 || !quotaResult.payload.data) {
      throw new Error(`账号已登录，但额度读取失败：${BitzNetQuotaService.httpFailureReason(
        '额度接口', quotaResult.statusCode, quotaResult.payload.message)}`)
    }
    await BitzNetEndpointStore.remember(base)
    return {
      authorization: authorization,
      apiBase: base,
      subscriptionUrl: quotaResult.payload.data.subscribe_url?.trim() ?? '',
      subscriptionInfo: BitzNetQuotaService.toSubscriptionInfo(quotaResult.payload.data)
    }
  }

  private static async downloadWithSession(authorization: string, apiBase: string,
    subscriptionUrl: string, fallbackUrl: string,
    subscriptionInfo: SubscriptionInfo, profileId: string): Promise<BitzNetSubscriptionDownload> {
    if (!authorization) {
      throw new Error('BitzNet 登录令牌为空')
    }
    const candidates = BitzNetQuotaService.subscriptionCandidates(subscriptionUrl, fallbackUrl, apiBase)
    if (candidates.length === 0) {
      const value = subscriptionUrl.trim()
      const urlKind = /^https:\/\//i.test(value) ? 'https' : /^http:\/\//i.test(value) ? 'http' :
        value.startsWith('/') ? 'relative' : value.length > 0 ? 'other' : 'empty'
      hilog.warn(BITZ_LOG_DOMAIN, BITZ_LOG_TAG,
        `stage=stable_url_rejected profileId=${profileId}, kind=${urlKind}, length=${value.length}`)
      throw new Error('BitzNet 账号没有可用的订阅地址')
    }
    hilog.warn(BITZ_LOG_DOMAIN, BITZ_LOG_TAG,
      `stage=download_start profileId=${profileId}, candidates=${candidates.length}`)

    let lastReason = 'BitzNet 订阅服务器连接失败'
    let uriFallback: string = ''
    for (let candidateIndex = 0; candidateIndex < candidates.length; candidateIndex++) {
      const candidate = candidates[candidateIndex]
      // 部分 BitzNet 线路只认官方 BBGen2UA，部分仍按通用 Clash UA 选择
      // 输出格式。先严格复刻官方客户端；若正文仍是 base64 URI 列表，再用
      // Clash.Meta UA 请求同一 HTTPS 地址。两次都必须通过 YAML/节点校验。
      const userAgents: string[] = [BITZ_SUBSCRIPTION_USER_AGENT, BITZ_CLASH_USER_AGENT]
      for (let userAgentIndex = 0; userAgentIndex < userAgents.length; userAgentIndex++) {
        let responseContent: string = ''
        try {
          const response = await BitzNetQuotaService.requestSubscriptionText(candidate.url,
            candidate.useAuthorization ? authorization : '',
            userAgents[userAgentIndex])
          responseContent = response.content
          hilog.warn(BITZ_LOG_DOMAIN, BITZ_LOG_TAG,
            `stage=http_response profileId=${profileId}, candidate=${candidateIndex + 1}, ` +
            `source=${candidate.source}, auth=${candidate.useAuthorization}, ` +
            `ua=${userAgentIndex === 0 ? 'official' : 'clash'}, status=${response.statusCode}, ` +
            `bodyLength=${response.content.length}`)
          if (response.statusCode < 200 || response.statusCode >= 300) {
            lastReason = `BitzNet 订阅服务器返回 HTTP ${response.statusCode}`
            continue
          }
          const proxyCount = BitzNetQuotaService.validateSubscriptionContent(response.content)
          hilog.warn(BITZ_LOG_DOMAIN, BITZ_LOG_TAG,
            `stage=yaml_valid profileId=${profileId}, nodes=${proxyCount}, ` +
            `bodyLength=${response.content.length}`)
          return {
            content: response.content,
            contentHash: bitzSubscriptionHash(response.content),
            proxyCount: proxyCount,
            subscriptionInfo: subscriptionInfo,
            format: 'clash'
          }
        } catch (error) {
          lastReason = (error as Error).message
          if (!uriFallback && BitzNetQuotaService.isLikelyUriSubscription(responseContent)) {
            uriFallback = responseContent
          }
          hilog.error(BITZ_LOG_DOMAIN, BITZ_LOG_TAG,
            `stage=download_candidate_failed profileId=${profileId}, candidate=${candidateIndex + 1}, ` +
            `source=${candidate.source}, auth=${candidate.useAuthorization}, ` +
            `ua=${userAgentIndex === 0 ? 'official' : 'clash'}, ` +
            `reason=${BitzNetQuotaService.sanitizeLogReason(lastReason)}`)
        }
      }
    }
    if (uriFallback) {
      hilog.warn(BITZ_LOG_DOMAIN, BITZ_LOG_TAG,
        `stage=uri_subscription_fallback profileId=${profileId}, bodyLength=${uriFallback.length}`)
      return {
        content: uriFallback,
        contentHash: bitzSubscriptionHash(uriFallback),
        proxyCount: 0,
        subscriptionInfo: subscriptionInfo,
        format: 'v2ray'
      }
    }
    throw new Error(lastReason)
  }

  /** 日志严禁包含完整订阅地址、长令牌或账号信息。 */
  static sanitizeLogReason(reason: string): string {
    return reason.replace(/https:\/\/[^\s]+/gi, '[url]')
      .replace(/[A-Za-z0-9_+\/=.-]{80,}/g, '[secret]')
      .substring(0, 240)
  }

  /**
   * 官方客户端实际优先使用用户配置中保存的普通订阅地址。该地址在浏览器式
   * 请求过期后，仍可凭 BBGen2UA + flag=clash 返回完整 Clash 配置；账号接口
   * 的 subscribe_url 可能只是 3 节点通用 URI 订阅，不能反过来覆盖普通地址。
   *
   * 回退地址可由用户填写，所以请求它时永远不携带账号登录令牌；只有
   * getSubscribe 明确返回的地址及其同源迁移候选可以带 Authorization。
   */
  private static subscriptionCandidates(subscriptionUrl: string, fallbackUrl: string,
    apiBase: string): BitzSubscriptionCandidate[] {
    const result: BitzSubscriptionCandidate[] = []
    const seen: string[] = []
    const fallback = bitzClashSubscriptionUrl(fallbackUrl)
    if (fallback) {
      result.push({ url: fallback, useAuthorization: false, source: 'profile' })
      seen.push(fallback)
    }

    const stableUrl = bitzClashSubscriptionUrl(subscriptionUrl)
    if (stableUrl && !seen.includes(stableUrl)) {
      result.push({ url: stableUrl, useAuthorization: true, source: 'account' })
      seen.push(stableUrl)
    }

    const apiOrigin = BitzNetQuotaService.urlOrigin(apiBase)

    // 官方 helper 会在入口域名迁移后保留订阅路径与查询参数。API 面板与
    // 订阅承载同源的部署可直接使用此候选；不同源时首个稳定地址仍优先。
    if (stableUrl && apiOrigin) {
      const migrated = BitzNetQuotaService.replaceOrigin(stableUrl, apiOrigin)
      if (migrated && !seen.includes(migrated)) {
        result.push({ url: migrated, useAuthorization: true, source: 'account-migrated' })
      }
    }
    return result
  }

  private static urlOrigin(value: string): string {
    const match = value.match(/^(https:\/\/[^\/?#]+)/i)
    return match?.[1]?.toLowerCase().replace(/\/+$/, '') ?? ''
  }

  private static replaceOrigin(value: string, origin: string): string {
    const match = value.match(/^https:\/\/[^\/?#]+(.*)$/i)
    if (!match) return ''
    return origin.replace(/\/+$/, '') + (match[1] || '/')
  }

  static validateSubscriptionContent(content: string): number {
    if (!content || content.length > 100 * 1024 * 1024) {
      throw new Error('BitzNet 返回的订阅内容为空或过大')
    }
    const trimmed = content.trim().toLowerCase()
    if (trimmed.startsWith('<!doctype') || trimmed.startsWith('<html') || trimmed.startsWith('{')) {
      throw new Error('BitzNet 返回的不是 Clash 配置')
    }
    try {
      const config = parse(content) as BitzSubscriptionConfig
      if (!config || !Array.isArray(config.proxies) || config.proxies.length === 0) {
        hilog.warn(BITZ_LOG_DOMAIN, BITZ_LOG_TAG,
          `stage=invalid_content kind=${typeof config}, base64=${/^[A-Za-z0-9+/=\r\n]+$/.test(content.trim())}, ` +
          `html=${/<(?:html|script|head|meta)\b/i.test(content)}, challenge=${/captcha|challenge|document\.cookie/i.test(content)}`)
        throw new Error('BitzNet 订阅中没有代理节点')
      }
      return config.proxies.length
    } catch (error) {
      const reason = (error as Error).message
      if (reason === 'BitzNet 订阅中没有代理节点') throw new Error(reason)
      throw new Error('BitzNet 返回的 Clash YAML 校验失败')
    }
  }

  private static isLikelyUriSubscription(content: string): boolean {
    const trimmed = content.trim()
    return trimmed.length >= 16 && trimmed.length <= 20 * 1024 * 1024 &&
      /^[A-Za-z0-9+/=\r\n]+$/.test(trimmed)
  }

  private static async requestSubscriptionText(url: string,
    authorization: string, userAgent: string = BITZ_SUBSCRIPTION_USER_AGENT): Promise<BitzTextResult> {
    const request = http.createHttp()
    const headers: Record<string, string> = {
      'User-Agent': userAgent,
      // BitzNet 网关会区分普通浏览器式请求。identity 既符合官方 helper
      // 的显式 Accept-Encoding 行为，也避免 ArkTS 再处理 gzip 正文。
      'Accept-Encoding': 'identity',
      'Accept': 'text/yaml,text/plain,application/yaml,*/*',
      'Cache-Control': 'no-cache'
    }
    if (authorization) headers['Authorization'] = authorization
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 15000,
        readTimeout: 30000,
        usingCache: false,
        maxLimit: 100 * 1024 * 1024,
        expectDataType: http.HttpDataType.STRING
      })
      return {
        statusCode: response.responseCode,
        content: typeof response.result === 'string' ? response.result as string : ''
      }
    } finally {
      request.destroy()
    }
  }

  private static async orderedBases(savedBase: string, hintedBase: string = ''): Promise<string[]> {
    const result: string[] = []
    if (savedBase) result.push(savedBase)
    // 新增配置时优先使用订阅 URL 对应的当前面板，避免先等待一串已经迁移的
    // 历史域名超时；已有配置仍以最近成功的 savedBase 为第一选择。
    if (hintedBase && !result.includes(hintedBase)) result.push(hintedBase)
    const cached = await BitzNetEndpointStore.load()
    for (const base of cached) {
      if (!result.includes(base)) result.push(base)
    }
    // 订阅地址本身通常位于当前用户面板。网站换域名时，以用户刚输入的
    // 新订阅地址自动推导 /api/v1，比继续依赖旧官网入口更及时。
    for (const base of BITZ_API_BASES) {
      if (!result.includes(base)) result.push(base)
    }
    return result
  }

  private static apiBaseFromSubscriptionUrl(subscriptionUrl: string): string {
    const match = subscriptionUrl.trim().match(/^(https:\/\/[^\/?#]+)/i)
    if (!match || !match[1]) return ''
    return match[1].replace(/\/+$/, '') + '/api/v1'
  }

  /** 从官方入口页提取用户面板地址，并用公开 guest 接口确认它确为 V2Board 面板。 */
  private static async discoverApiBases(): Promise<string[]> {
    const result: string[] = []
    const discoveryPages: string[] = [...BITZ_DISCOVERY_ROOTS]
    for (let pageIndex = 0; pageIndex < discoveryPages.length && pageIndex < 12; pageIndex++) {
      const root = discoveryPages[pageIndex]
      try {
        const html = await BitzNetQuotaService.requestText(root)
        const links = html.match(/https:\/\/[A-Za-z0-9.-]+/g) ?? []
        for (const link of links) {
          const origin = link.replace(/\/+$/, '')
          const host = origin.replace(/^https:\/\//, '').toLowerCase()
          if (!(host.startsWith('ent.') || host.startsWith('sec.') || host.includes('bitz'))) continue
          // GitHub 入口页通常先指向品牌官网，再由官网指向最新用户面板。
          // 把品牌官网加入有限队列，多走一跳即可适配整套域名迁移。
          if (!host.startsWith('ent.') && !host.startsWith('sec.') &&
            !discoveryPages.includes(origin)) {
            discoveryPages.push(origin)
          }
          const apiBase = origin + '/api/v1'
          if (result.includes(apiBase)) continue
          const probe = await BitzNetQuotaService.request(apiBase + '/guest/comm/config',
            http.RequestMethod.GET, '')
          if (probe.statusCode === 200 && probe.payload.data) {
            result.push(apiBase)
          }
        }
      } catch (_) {
      }
    }
    return result
  }

  private static async login(base: string, username: string, password: string): Promise<BitzHttpResult> {
    const body = `email=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`
    return await BitzNetQuotaService.request(base + '/passport/auth/login', http.RequestMethod.POST, body)
  }

  private static async requestQuota(base: string, authorization: string): Promise<BitzHttpResult> {
    return await BitzNetQuotaService.request(base + '/user/getSubscribe', http.RequestMethod.GET, '', authorization)
  }

  private static async request(url: string, method: http.RequestMethod, body: string,
    authorization: string = ''): Promise<BitzHttpResult> {
    const request = http.createHttp()
    const headers: Record<string, string> = {
      'Content-Language': 'zh-CN',
      'Accept': 'application/json',
      'Cache-Control': 'no-cache'
    }
    if (method === http.RequestMethod.POST) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded'
    }
    if (authorization) {
      headers['authorization'] = authorization
    }
    try {
      const response = await request.request(url, {
        method: method,
        header: headers,
        extraData: body,
        connectTimeout: 10000,
        readTimeout: 10000,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING
      })
      let payload: BitzApiPayload = {}
      if (typeof response.result === 'string' && response.result) {
        try {
          payload = JSON.parse(response.result as string) as BitzApiPayload
        } catch (_) {
          payload = { message: 'BitzNet 返回了非 JSON 数据' }
        }
      }
      return { statusCode: response.responseCode, payload: payload }
    } finally {
      request.destroy()
    }
  }

  private static async requestText(url: string): Promise<string> {
    const request = http.createHttp()
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: { 'Accept': 'text/html' },
        connectTimeout: 5000,
        readTimeout: 5000,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING
      })
      if (response.responseCode < 200 || response.responseCode >= 300 ||
        typeof response.result !== 'string') return ''
      return response.result as string
    } finally {
      request.destroy()
    }
  }

  private static toSubscriptionInfo(data: BitzApiData): SubscriptionInfo {
    const info = new SubscriptionInfo()
    info.upload = Number(data.u ?? 0)
    info.download = Number(data.d ?? 0)
    info.total = Number(data.transfer_enable ?? 0)
    info.expire = Number(data.expired_at ?? 0)
    info.source = 'bitz-account'
    info.state = info.total > 0 ? 'known' : 'header-no-total'
    info.updatedAt = Date.now()
    return info
  }
}

export default BitzNetQuotaService
