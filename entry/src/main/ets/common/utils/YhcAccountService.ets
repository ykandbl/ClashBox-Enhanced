import { http } from '@kit.NetworkKit'
import { JSON, taskpool, util } from '@kit.ArkTS'
import { Xb_SecureKVdbUtil } from 'xb_components'
import { SubscriptionInfo } from 'proxy_core/src/main/ets/models/Common'

const CREDENTIAL_KEY_PREFIX: string = 'yhc_credential_'
const ENDPOINT_CACHE_KEY: string = 'yhc_api_endpoints'
const YHC_API_BASES: string[] = [
  'https://yhc222.com/api'
]
const YHC_DISCOVERY_ROOTS: string[] = [
  'https://yinghuochong.app',
  'https://yinghuochong.me',
  'https://yhc222.com'
]

interface YhcCaptchaPayload {
  challenge_id?: string
  salt?: string
  difficulty?: number
}

interface YhcLoginPayload {
  access_token?: string
  username?: string
  email?: string
  is_admin?: boolean
  detail?: string
}

interface YhcLoginRequest {
  username: string
  password: string
  captcha_id: string
  captcha_code: string
  fingerprint: string
}

interface YhcProfilePayload {
  active?: boolean
  days_remaining?: number
  expire_time?: string | number
  is_trial?: boolean
  trial_started_at?: string
  detail?: string
}

interface YhcHttpResult<T> {
  statusCode: number
  payload: T
}

export interface YhcCredential {
  username: string
  password: string
  accessToken: string
  apiBase: string
  tokenExpiresAt: number
}

export interface YhcValidationResult {
  accessToken: string
  apiBase: string
  tokenExpiresAt: number
  subscriptionInfo: SubscriptionInfo
}

/** 只把明确的服务端过期状态或已到期时间视为过期，未知有效期保持中性。 */
export function isYhcSubscriptionExpired(info: SubscriptionInfo | null,
  now: number = Date.now()): boolean {
  if (!info) return false
  if (info.state === 'account-expired') return true
  const raw = Number(info.expire ?? 0)
  if (!Number.isFinite(raw) || raw <= 0) return false
  const expireMs = raw > 100000000000 ? raw : raw * 1000
  return expireMs <= now
}

/** 识别服务商在账号过期时下发、并可能残留在核心中的单节点提示。 */
export function isYhcRenewalPlaceholderName(name: string): boolean {
  return /(已?到期|过期|充值|续费|expired|renew|recharge)/i.test(name)
}

/**
 * 网页端使用 SHA-256 工作量证明保护登录接口。算法与网页 powWorker 保持一致：
 * 寻找 SHA256(salt + nonce) 具有指定数量前导零位的十进制 nonce。
 */
@Concurrent
function solveYhcPow(salt: string, difficulty: number, maxIterations: number): string {
  const constants: Uint32Array = new Uint32Array([
    1116352408, 1899447441, 3049323471, 3921009573, 961987163, 1508970993, 2453635748, 2870763221,
    3624381080, 310598401, 607225278, 1426881987, 1925078388, 2162078206, 2614888103, 3248222580,
    3835390401, 4022224774, 264347078, 604807628, 770255983, 1249150122, 1555081692, 1996064986,
    2554220882, 2821834349, 2952996808, 3210313671, 3336571891, 3584528711, 113926993, 338241895,
    666307205, 773529912, 1294757372, 1396182291, 1695183700, 1986661051, 2177026350, 2456956037,
    2730485921, 2820302411, 3259730800, 3345764771, 3516065817, 3600352804, 4094571909, 275423344,
    430227734, 506948616, 659060556, 883997877, 958139571, 1322822218, 1537002063, 1747873779,
    1955562222, 2024104815, 2227730452, 2361852424, 2428436474, 2756734187, 3204031479, 3329325298
  ])
  const rotateRight = (value: number, count: number): number =>
    ((value >>> count) | (value << (32 - count))) >>> 0

  const sha256 = (text: string): Uint8Array => {
    const source = new Uint8Array(text.length)
    for (let index = 0; index < text.length; index++) source[index] = text.charCodeAt(index) & 0xFF
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
    for (let offset = 0; offset < paddedLength; offset += 64) {
      for (let index = 0; index < 16; index++) schedule[index] = view.getUint32(offset + index * 4)
      for (let index = 16; index < 64; index++) {
        const x = schedule[index - 15]
        const y = schedule[index - 2]
        const s0 = rotateRight(x, 7) ^ rotateRight(x, 18) ^ (x >>> 3)
        const s1 = rotateRight(y, 17) ^ rotateRight(y, 19) ^ (y >>> 10)
        schedule[index] = (schedule[index - 16] + s0 + schedule[index - 7] + s1) >>> 0
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

  const countLeadingZeroBits = (digest: Uint8Array): number => {
    let count = 0
    for (const byte of digest) {
      if (byte === 0) {
        count += 8
        continue
      }
      let mask = 0x80
      while ((byte & mask) === 0) {
        count++
        mask >>= 1
      }
      break
    }
    return count
  }

  for (let nonce = 0; nonce < maxIterations; nonce++) {
    if (countLeadingZeroBits(sha256(salt + nonce.toString())) >= difficulty) return nonce.toString()
  }
  return ''
}

export class YhcCredentialStore {
  static async save(profileId: string, username: string, password: string,
    accessToken: string = '', apiBase: string = '', tokenExpiresAt: number = 0): Promise<void> {
    const value: YhcCredential = {
      username: username.trim(),
      password: password,
      accessToken: accessToken,
      apiBase: apiBase,
      tokenExpiresAt: tokenExpiresAt
    }
    await Xb_SecureKVdbUtil.putData(CREDENTIAL_KEY_PREFIX + profileId, JSON.stringify(value))
  }

  static async load(profileId: string): Promise<YhcCredential | null> {
    try {
      const raw = await Xb_SecureKVdbUtil.getData(CREDENTIAL_KEY_PREFIX + profileId)
      if (typeof raw !== 'string' || !raw) return null
      const value = JSON.parse(raw) as YhcCredential
      if (!value.username || !value.password) return null
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

  /** 删除全部萤火虫登录凭据以及已发现的动态 API 入口。 */
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

class YhcEndpointStore {
  static async load(): Promise<string[]> {
    try {
      const raw = await Xb_SecureKVdbUtil.getData(ENDPOINT_CACHE_KEY)
      if (typeof raw !== 'string' || !raw) return []
      return (JSON.parse(raw) as string[]).filter((value: string): boolean => value.startsWith('https://'))
    } catch (_) {
      return []
    }
  }

  static async remember(apiBase: string): Promise<void> {
    if (!apiBase.startsWith('https://')) return
    const previous = await YhcEndpointStore.load()
    const next: string[] = [apiBase]
    for (const value of previous) {
      if (value !== apiBase && next.length < 8) next.push(value)
    }
    await Xb_SecureKVdbUtil.putData(ENDPOINT_CACHE_KEY, JSON.stringify(next))
  }
}

export class YhcAccountService {
  private static isTransientError(reason: string): boolean {
    return /连接|超时|timeout|timed out|network|socket|dns|host|resolve|connect|connection|reset|closed|eof|tls|ssl|handshake|拒绝|不可用|http (408|425|429|5\d\d)/i.test(reason)
  }

  static async validateCredentials(username: string, password: string): Promise<YhcValidationResult> {
    const normalized = username.trim()
    if (!normalized || !password) throw new Error('请输入萤火虫账号和密码')
    const bases = await YhcAccountService.orderedBases('')
    let lastReason = '萤火虫登录服务连接失败'
    for (const base of bases) {
      try {
        return await YhcAccountService.validateAtBase(base, normalized, password)
      } catch (error) {
        lastReason = (error as Error).message
        if (lastReason.includes('账号或密码错误')) throw new Error(lastReason)
      }
    }
    const discovered = await YhcAccountService.discoverApiBases()
    for (const base of discovered) {
      if (bases.includes(base)) continue
      try {
        return await YhcAccountService.validateAtBase(base, normalized, password)
      } catch (error) {
        lastReason = (error as Error).message
        if (lastReason.includes('账号或密码错误')) throw new Error(lastReason)
      }
    }
    throw new Error(lastReason)
  }

  static async refresh(profileId: string, preferredOnly: boolean = false): Promise<YhcValidationResult> {
    const credential = await YhcCredentialStore.load(profileId)
    if (!credential) throw new Error('请在配置编辑中填写萤火虫账号和密码')
    let bases = await YhcAccountService.orderedBases(credential.apiBase)
    if (preferredOnly && bases.length > 1) bases = [bases[0]]
    let lastReason = '萤火虫账号资料连接失败'
    if (credential.accessToken && credential.tokenExpiresAt > Date.now() + 30000) {
      for (const base of bases) {
        try {
          const profileResult = await YhcAccountService.requestProfile(base, credential.accessToken)
          if (profileResult.statusCode === 200 && !profileResult.payload.detail) {
            await YhcEndpointStore.remember(base)
            if (credential.apiBase !== base) {
              await YhcCredentialStore.save(profileId, credential.username, credential.password,
                credential.accessToken, base, credential.tokenExpiresAt)
            }
            return {
              accessToken: credential.accessToken,
              apiBase: base,
              tokenExpiresAt: credential.tokenExpiresAt,
              subscriptionInfo: YhcAccountService.toSubscriptionInfo(profileResult.payload)
            }
          }
          lastReason = profileResult.payload.detail || `账号资料 HTTP ${profileResult.statusCode}`
        } catch (error) {
          lastReason = (error as Error).message
          if (preferredOnly && YhcAccountService.isTransientError(lastReason)) {
            throw new Error(lastReason)
          }
        }
      }
    }
    for (const base of bases) {
      try {
        const validation = await YhcAccountService.validateAtBase(base, credential.username, credential.password)
        await YhcCredentialStore.save(profileId, credential.username, credential.password,
          validation.accessToken, validation.apiBase, validation.tokenExpiresAt)
        return validation
      } catch (error) {
        lastReason = (error as Error).message
        if (lastReason.includes('账号或密码错误')) break
      }
    }
    throw new Error(lastReason)
  }

  private static async validateAtBase(base: string, username: string,
    password: string): Promise<YhcValidationResult> {
    const login = await YhcAccountService.login(base, username, password)
    const token = login.payload.access_token ?? ''
    if (login.statusCode === 401) throw new Error('账号或密码错误')
    if (login.statusCode !== 200 || !token) {
      throw new Error(login.payload.detail || `登录接口 HTTP ${login.statusCode}`)
    }
    const profile = await YhcAccountService.requestProfile(base, token)
    if (profile.statusCode !== 200 || profile.payload.detail) {
      throw new Error(profile.payload.detail || `账号资料 HTTP ${profile.statusCode}`)
    }
    const tokenExpiresAt = YhcAccountService.readJwtExpire(token)
    await YhcEndpointStore.remember(base)
    return {
      accessToken: token,
      apiBase: base,
      tokenExpiresAt: tokenExpiresAt,
      subscriptionInfo: YhcAccountService.toSubscriptionInfo(profile.payload)
    }
  }

  private static async login(base: string, username: string,
    password: string): Promise<YhcHttpResult<YhcLoginPayload>> {
    const captcha = await YhcAccountService.request<YhcCaptchaPayload>(base + '/auth/captcha',
      http.RequestMethod.GET, null)
    const challengeId = captcha.payload.challenge_id ?? ''
    const salt = captcha.payload.salt ?? ''
    const difficulty = Number(captcha.payload.difficulty ?? 0)
    if (captcha.statusCode !== 200 || !challengeId || !salt || difficulty <= 0) {
      throw new Error(`登录验证接口 HTTP ${captcha.statusCode}`)
    }
    const powTask = new taskpool.Task(solveYhcPow, salt, difficulty, 8000000)
    const nonce = await taskpool.execute(powTask) as string
    if (!nonce) throw new Error('登录人机验证计算超时')
    const payload: YhcLoginRequest = {
      username: username,
      password: password,
      captcha_id: challengeId,
      captcha_code: nonce,
      fingerprint: 'HarmonyOS|ClashBoxLTS|phone'
    }
    return await YhcAccountService.request<YhcLoginPayload>(base + '/auth/login',
      http.RequestMethod.POST, payload)
  }

  private static async requestProfile(base: string,
    accessToken: string): Promise<YhcHttpResult<YhcProfilePayload>> {
    return await YhcAccountService.request<YhcProfilePayload>(base + '/user/profile',
      http.RequestMethod.GET, null, accessToken)
  }

  private static async request<T>(url: string, method: http.RequestMethod,
    payload: Object | null, accessToken: string = ''): Promise<YhcHttpResult<T>> {
    const request = http.createHttp()
    const headers: Record<string, string> = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Cache-Control': 'no-cache'
    }
    if (accessToken) headers['Authorization'] = `Bearer ${accessToken}`
    try {
      const response = await request.request(url, {
        method: method,
        header: headers,
        extraData: payload ? JSON.stringify(payload) : '',
        connectTimeout: 10000,
        readTimeout: 20000,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING
      })
      let parsed = JSON.parse('{}') as T
      if (typeof response.result === 'string' && response.result) {
        try {
          parsed = JSON.parse(response.result as string) as T
        } catch (_) {
        }
      }
      return { statusCode: response.responseCode, payload: parsed }
    } finally {
      request.destroy()
    }
  }

  private static async orderedBases(savedBase: string): Promise<string[]> {
    const result: string[] = []
    if (savedBase) result.push(savedBase)
    const cached = await YhcEndpointStore.load()
    for (const base of cached) if (!result.includes(base)) result.push(base)
    for (const base of YHC_API_BASES) if (!result.includes(base)) result.push(base)
    return result
  }

  /** 从官方发布页的“最新域名”发现新面板，并用公开验证码接口验证。 */
  private static async discoverApiBases(): Promise<string[]> {
    const result: string[] = []
    for (const root of YHC_DISCOVERY_ROOTS) {
      try {
        const html = await YhcAccountService.requestText(root)
        const matches = html.match(/(?:https:\/\/)?[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g) ?? []
        for (const raw of matches) {
          const host = raw.replace(/^https:\/\//, '').toLowerCase()
          if (!(host.includes('yhc') || host.includes('yinghuochong'))) continue
          const apiBase = `https://${host}/api`
          if (result.includes(apiBase)) continue
          const probe = await YhcAccountService.request<YhcCaptchaPayload>(apiBase + '/auth/captcha',
            http.RequestMethod.GET, null)
          if (probe.statusCode === 200 && probe.payload.challenge_id) result.push(apiBase)
        }
      } catch (_) {
      }
    }
    return result
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
      return response.responseCode === 200 && typeof response.result === 'string' ? response.result as string : ''
    } finally {
      request.destroy()
    }
  }

  static readJwtExpire(token: string): number {
    try {
      const parts = token.split('.')
      if (parts.length < 2) return 0
      let payload = parts[1].replace(/-/g, '+').replace(/_/g, '/')
      const padding = payload.length % 4
      if (padding) payload += new Array(4 - padding + 1).join('=')
      const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true })
      const decoded = decoder.decodeToString(new util.Base64Helper().decodeSync(payload))
      const value = JSON.parse(decoded) as Record<string, Object>
      return Number(value['exp'] ?? 0) * 1000
    } catch (_) {
      return 0
    }
  }

  private static toSubscriptionInfo(profile: YhcProfilePayload): SubscriptionInfo {
    const info = new SubscriptionInfo()
    let expireMs = 0
    if (typeof profile.expire_time === 'number') {
      expireMs = profile.expire_time > 100000000000 ? profile.expire_time : profile.expire_time * 1000
    } else if (typeof profile.expire_time === 'string' && profile.expire_time) {
      expireMs = new Date(profile.expire_time).getTime()
    }
    if ((!expireMs || Number.isNaN(expireMs)) && Number(profile.days_remaining ?? 0) > 0) {
      expireMs = Date.now() + Number(profile.days_remaining) * 24 * 60 * 60 * 1000
    }
    info.expire = expireMs > 0 && !Number.isNaN(expireMs) ? Math.floor(expireMs / 1000) : 0
    info.source = 'yhc-account'
    // 萤火虫账号接口提供有效期但不设置流量上限；用 unlimited 状态让配置卡
    // 展示明确的 ∞ 额度条，同时有效期仍由 expire 字段单独显示。
    info.state = profile.active === false ? 'account-expired' : 'unlimited'
    info.updatedAt = Date.now()
    return info
  }
}

export default YhcAccountService
