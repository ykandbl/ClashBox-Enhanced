import fs from '@ohos.file.fs';
import { getProfileDir, getProfilePath, getRuntimeProfilePath } from './appPath';
import { Context } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { ProxyGroup, ProxyType, SubscriptionInfo } from './models/Common';
import { JSON, taskpool, util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { parse, stringify, YAMLError } from 'yaml'

interface SubscriptionClashConfig {
  dns?: Record<string, Object>
  tun?: Record<string, Object>
  proxies?: SubscriptionProxy[]
  rules?: string[]
}

interface SubscriptionProxy {
  name?: string
  server?: string
}

const SMART_DIRECT_RULES: string[] = [
  "IP-CIDR,0.0.0.0/8,DIRECT,no-resolve",
  "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
  "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
  "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
  "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
  "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
  "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
  "IP-CIDR,224.0.0.0/4,DIRECT,no-resolve",
  "IP-CIDR6,::1/128,DIRECT,no-resolve",
  "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
  "IP-CIDR6,fe80::/10,DIRECT,no-resolve",
  "IP-CIDR6,ff00::/8,DIRECT,no-resolve",
  "GEOSITE,CN,DIRECT",
  "GEOIP,CN,DIRECT,no-resolve"
]

function findSmartProxyTarget(config: SubscriptionClashConfig): string | undefined {
  const rules = config.rules ?? []
  for (let index = rules.length - 1; index >= 0; index--) {
    const parts = rules[index].split(',').map((item: string) => item.trim())
    if (parts[0]?.toUpperCase() === 'MATCH' && parts[1] &&
      parts[1].toUpperCase() !== 'DIRECT' && parts[1].toUpperCase() !== 'REJECT') {
      return parts[1]
    }
  }
  return undefined
}

function isLoopbackDnsServer(value: string): boolean {
  const normalized = value.toLowerCase()
  return normalized.includes('127.0.0.1') || normalized.includes('localhost') ||
    normalized.includes('[::1]') || normalized === '::1'
}

function isProxyHostname(value: string): boolean {
  if (!value || value.includes(':') || /^\d{1,3}(\.\d{1,3}){3}$/.test(value)) {
    return false
  }
  return value.includes('.') && /[a-z]/i.test(value)
}

/**
 * 部分服务商把 proxy-server-nameserver 指向 Mihomo 自身的 Fake-IP DNS。
 * 保留服务商全部 DNS 设置，仅在运行时把节点域名加入 Fake-IP 排除列表，
 * 避免核心把 198.18.0.0/15 虚拟地址当成节点入口拨号。
 */
function preserveRealProxyServerAddresses(config: SubscriptionClashConfig): void {
  const dns = config.dns
  const proxyNameserverValue = dns?.["proxy-server-nameserver"]
  const proxyNameservers = Array.isArray(proxyNameserverValue) ? proxyNameserverValue as string[] : []
  const enhancedMode = dns?.["enhanced-mode"]
  if (!dns || typeof enhancedMode !== 'string' || enhancedMode.toLowerCase() !== 'fake-ip' ||
    !proxyNameservers.some((value: string) => isLoopbackDnsServer(value))) {
    return
  }
  const filterValue = dns["fake-ip-filter"]
  const currentFilters = Array.isArray(filterValue) ? filterValue as string[] : []
  const knownFilters = new Set<string>(currentFilters.map((value: string) => value.toLowerCase()))
  const additions: string[] = []
  for (const proxy of config.proxies ?? []) {
    const server = proxy.server?.trim()
    if (server && isProxyHostname(server) && !knownFilters.has(server.toLowerCase())) {
      additions.push(server)
      knownFilters.add(server.toLowerCase())
    }
  }
  if (additions.length > 0) {
    dns["fake-ip-filter"] = [...currentFilters, ...additions]
    console.info(`RuntimeConfig protected proxy hostnames from Fake-IP, count=${additions.length}`)
  }
}

/**
 * 手机网络上的明文 DNS 容易把海外域名返回到无关地址，最终表现为 TLS
 * 证书异常或“能打开页面但请求发不出去”。节点域名必须先直连解析才能建立
 * 隧道；隧道建立后，业务域名则交给当前代理组内的加密 DNS。这两个解析
 * 通道必须分开，不能继续沿用订阅中混杂的 nameserver 配置。
 */
function applyStableRuntimeDns(config: SubscriptionClashConfig, proxyTarget: string): void {
  // Mihomo accepts either a selector group or a real node after '#'. Pointing
  // DNS at the rule's final proxy group makes it follow every node switch
  // automatically. Pinning it to a leaf node leaves DNS on the previous node
  // after changing subscriptions/nodes and can select the wrong media CDN or
  // invalidate location-sensitive signed requests.
  const proxyName = encodeURIComponent(proxyTarget)
  const trustedOverseasDns: string[] = [
    `https://1.1.1.1/dns-query#${proxyName}`,
    `https://8.8.8.8/dns-query#${proxyName}`
  ]
  const nameserverPolicy: Record<string, Object> = {}
  nameserverPolicy["geosite:cn,private"] = [
    "https://dns.alidns.com/dns-query",
    "https://doh.pub/dns-query"
  ]
  nameserverPolicy["geosite:gfw"] = trustedOverseasDns
  nameserverPolicy["+.openai.com"] = trustedOverseasDns
  nameserverPolicy["+.chatgpt.com"] = trustedOverseasDns
  nameserverPolicy["+.oaistatic.com"] = trustedOverseasDns
  nameserverPolicy["+.grok.com"] = trustedOverseasDns
  nameserverPolicy["+.x.ai"] = trustedOverseasDns
  nameserverPolicy["+.x.com"] = trustedOverseasDns
  const runtimeDns: Record<string, Object> = {}
  runtimeDns["enable"] = true
  runtimeDns["ipv6"] = false
  runtimeDns["prefer-h3"] = false
  runtimeDns["use-hosts"] = true
  runtimeDns["use-system-hosts"] = false
  runtimeDns["respect-rules"] = false
  // HarmonyOS 的兼容应用容器会在 Fake-IP 上提前终止 TLS，TCP 连接尚未
  // 交给 Mihomo。redir-host 仍由 Mihomo 加密解析，但向应用返回真实地址。
  runtimeDns["enhanced-mode"] = "redir-host"
  // 只负责在代理建立前解析节点入口，避免 DNS 查询自身形成环路。
  runtimeDns["default-nameserver"] = ["223.5.5.5", "119.29.29.29"]
  runtimeDns["proxy-server-nameserver"] = ["223.5.5.5", "119.29.29.29"]
  // 未命中国内策略的域名使用当前代理组中的公共加密 DNS。这样 Grok/X/
  // ChatGPT 的 API、媒体和支付相关域名即使不在 geosite:gfw 中，也不会
  // 因本地 DNS 与代理出口国家不一致而拿到错误的 CDN 或签名端点。
  runtimeDns["nameserver"] = trustedOverseasDns
  runtimeDns["nameserver-policy"] = nameserverPolicy
  runtimeDns["direct-nameserver"] = [
    "https://dns.alidns.com/dns-query",
    "https://doh.pub/dns-query"
  ]
  runtimeDns["direct-nameserver-follow-policy"] = true
  config.dns = runtimeDns
  console.info('RuntimeConfig stable split DNS enabled, follows rule proxy group')
}

/**
 * 生成 ClashBox 自己的稳定规则模板。订阅原文件保持不变，核心只加载 runtime.yaml：
 * 局域网/回环/中国大陆直连，其余交给订阅的最终代理组。
 */
export function buildSmartRuntimeConfig(content: string, customRules: string[] = []): string {
  try {
    // 服务商可能依赖订阅内指定的节点 DNS。运行时仅替换分流规则，
    // DNS 配置保持订阅原样，避免第三方客户端覆写导致线路失效。
    const config = parse(content) as SubscriptionClashConfig
    preserveRealProxyServerAddresses(config)
    const proxyTarget = findSmartProxyTarget(config)
    if (!proxyTarget) {
      console.warn('SmartRoute skipped: no usable proxy group')
      return stringify(config)
    }
    applyStableRuntimeDns(config, proxyTarget)
    // Keep the generated runtime profile aligned with the Harmony VPN and the
    // native userspace stack. 1280 is the validated compatibility-container
    // baseline and avoids fragmentation on long HTTPS streams.
    config.tun = config.tun ?? {}
    config.tun["mtu"] = 1280
    config.tun["stack"] = "gvisor"
    const extraRules: string[] = []
    customRules.forEach((rule: string): void => {
      const value = rule.trim()
      if (value.length === 0 || value.split(',').length < 3 || /^MATCH\s*,/i.test(value)) return
      // 模板中的 MATCH 是“当前订阅最终代理组”占位符，不是一个真实策略组名。
      // 在写入 runtime.yaml 时解析它，模板即可跨不同订阅复用。
      extraRules.push(value.replace(/,MATCH\s*$/i, `,${proxyTarget}`))
    })
    config.rules = [...SMART_DIRECT_RULES, ...extraRules, `MATCH,${proxyTarget}`]
    console.info(`SmartRoute runtime template ready, proxyTargetLength=${proxyTarget.length}`)
    return stringify(config)
  } catch (_) {
    return content
  }
}

/**
 * 在后台线程中解析 YAML 内容
 * @param content - 待解析的 YAML 字符串内容
 * @returns 解析成功返回 true，失败返回 false
 */
@Concurrent
function parseYAMLInBackground(content: string): boolean {
  try {
    parse(content);
    return true;
  } catch (e) {
    console.error("TaskPool YAML parse error:", e);
    return false;
  }
}

export function generateUUID() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

export enum ProfileType {
  File,
  Url,
  External
}

let utf8e = new util.TextEncoder()

function getHttpHeader(headersObject: Object, name: string): string | undefined {
  const headers = headersObject as Record<string, string>
  const target = name.toLowerCase()
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() === target) {
      return headers[key]
    }
  }
  return undefined
}

export class Profile {
  id: string
  name: string | null
  type: ProfileType
  url: string = ""
  currentGroupName: string | null = null
  isUpdating: boolean = false
  autoUpdate: boolean = true
  lastUpdateDate: number
  autoUpdateDuration: number
  subscriptionInfo: SubscriptionInfo | null
  /** 订阅服务商账号。none / bitznet / yhc；账号密码与令牌另存于加密 KV。 */
  accountProvider: string = "none"
  accountState: string = "idle"
  accountError: string = ""
  accountUpdatedAt: number = 0
  /** 最近一次订阅兼容链结果；与账号/额度状态分开显示。 */
  subscriptionState: string = "idle"
  subscriptionError: string = ""
  subscriptionFormat: string = ""
  subscriptionNodeCount: number = 0
  subscriptionCheckedAt: number = 0
  /**
   * Durable subscription/runtime convergence markers.  These fields are the
   * source of truth after a process restart; the UI-side Set/Map is only a
   * short-lived scheduling aid.
   */
  lastGoodContentId: string = ""
  subscriptionPendingRepair: boolean = false
  subscriptionRetryAt: number = 0
  subscriptionRetryCount: number = 0
  coreLoadState: string = "unknown"
  coreLoadedContentId: string = ""
  coreLoadedAt: number = 0
  /** 当前启用的用户规则模板；仅注入 runtime.yaml，不改写原始订阅。 */
  private customRuntimeRules: string[] = []
  /** 旧版 BitzNet 字段只用于无损升级，写入时与通用账号字段同步。 */
  bitzQuotaEnabled: boolean = false
  bitzQuotaState: string = "idle"
  bitzQuotaError: string = ""
  bitzQuotaUpdatedAt: number = 0
  proxySelected: Map<string, string> = new Map()
  context?: Context

  constructor(type = ProfileType.Url, url: string) {
    this.id = generateUUID()
    this.name = null
    this.type = type // 0 url
    this.url = url
    // 订阅通常不会按分钟变化。较长的默认周期既能保持节点新鲜，也避免
    // 临时激活链接过期后持续请求和弹出失败提示。
    this.autoUpdateDuration = 6 * 60 * 60 * 1000 // 6 小时
    this.lastUpdateDate = new Date().getTime()
    this.subscriptionInfo = null
  }
  private globalUa: string = "clash.meta/1.19.5"
  loadContext(context: Context | undefined, globalUa: string | undefined = "clash.meta/1.19.5"){
    this.context = context
    this.globalUa = globalUa
  }
  setCustomRuntimeRules(rules: string[]): void {
    this.customRuntimeRules = rules.filter((rule: string): boolean => typeof rule === 'string')
  }
  async checkAndUpdate(vailConfig: (config: string) =>Promise<string>): Promise<void>{
    const isExists = await this.check();
    if (!isExists) {
      if (this.url != "") {
        await this.update(vailConfig);
      }
    }
  }
  async check(): Promise<boolean>{
    let profilePath = await getProfilePath(this.context, this.id);
    return await fs.access(profilePath, fs.AccessModeType.EXIST)
  }
  async delete(): Promise<void>{
    if(!await this.check())
      return
    let profileDir = await getProfileDir(this.context, this.id)
    let profilePath = await getProfilePath(this.context, this.id);
    const runtimePath = await getRuntimeProfilePath(this.context, this.id)
    await fs.unlink(profilePath)
    if (await fs.access(runtimePath, fs.AccessModeType.EXIST)) {
      await fs.unlink(runtimePath)
    }
    await fs.rmdir(profileDir)
  }

  async prepareRuntimeConfig(): Promise<boolean> {
    const sourcePath = await getProfilePath(this.context, this.id)
    if (!await fs.access(sourcePath, fs.AccessModeType.EXIST)) {
      return false
    }
    const runtimePath = await getRuntimeProfilePath(this.context, this.id)
    const source = await fs.readText(sourcePath)
    if (!this.lastGoodContentId) this.lastGoodContentId = subscriptionContentId(source)
    const runtime = buildSmartRuntimeConfig(source, this.customRuntimeRules)
    const bytes = utf8e.encodeInto(runtime)
    const file = await fs.open(runtimePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
    try {
      await fs.write(file.fd, bytes.buffer)
      await fs.fsync(file.fd)
    } finally {
      await fs.close(file.fd)
    }
    return true
  }
  async update(vailConfig: (config: string) => Promise<string>): Promise<boolean> {
    let httpRequest = http.createHttp();
    let timeoutId: number = -1
    let resp: http.HttpResponse
    try {
      const requestPromise: Promise<http.HttpResponse> = httpRequest.request(this.url, {
        header: {
          "User-Agent": this.globalUa ?? "clash.meta/1.19.5"
        },
        connectTimeout: 15000,
        readTimeout: 15000,
        maxLimit: 100 * 1024 * 1024,
      });
      const timeoutPromise: Promise<http.HttpResponse> = new Promise((resolve, reject) => {
        timeoutId = setTimeout(() => {
          console.warn('UpdateConfig subscription request timed out after 30 seconds')
          httpRequest.destroy()
          reject(new Error('订阅更新超时'))
        }, 30000)
      })
      resp = await Promise.race([requestPromise, timeoutPromise])
    } finally {
      if (timeoutId >= 0) clearTimeout(timeoutId)
      httpRequest.destroy()
    }
    const disposition = getHttpHeader(resp.header, "content-disposition");
    const userinfo = getHttpHeader(resp.header, "subscription-userinfo");
    const resultText = typeof resp.result === "string" ? resp.result as string : "";
    console.info(`UpdateConfig responseCode=${resp.responseCode} bodyLength=${resp.result ? (typeof resp.result === "string" ? (resp.result as string).length : 0) : 0} hasUserInfo=${!!userinfo}`);
    // YAML accepts arbitrary plain text as a scalar, so an HTTP error body such as
    // "Forbidden" must be rejected before the YAML check.  Keeping this guard here
    // also guarantees that an expired one-time update URL never replaces the last
    // known-good cached subscription.
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      throw new Error(`订阅服务器返回 HTTP ${resp.responseCode}`)
    }
    if (resp.result) {
      // JSON 数据，直接按错误处理
      try {
        let json = JSON.parse(resp.result as string) as object
        let msg = json?.["msg"] as string
        if (msg) {
          throw new Error(msg);
        } else {
          throw new Error("非配置JSON数据");
        }
      } catch (_) {
      }
      const value = await isYAML(resp.result as string | ArrayBuffer);
      console.debug(`UpdateConfig raw is yaml:${value} bodyLength=${typeof resp.result === "string" ? (resp.result as string).length : 0}`);
      if (!value) {
        console.error(`UpdateConfig 非yaml数据，不保存配置`);
        throw new Error("无有效链接数据");
      } else {
        const changed = await this.saveIfChanged(resp.result as string | ArrayBuffer, vailConfig);
        // 文件校验和原子落盘都成功后，才提交名称与额度元数据。HTTP 失败、
        // 临时激活链接过期或无效 YAML 均继续保留上次可用的 UI 数据。
        if (!this.name || this.name == "") {
          this.name = getFileNameFromDisposition(disposition) ?? this.id;
        }
        if (userinfo) {
          this.subscriptionInfo = SubscriptionInfo.formHString(userinfo);
        } else {
          const configInfo = SubscriptionInfo.formConfigText(resultText);
          if (configInfo.state !== "unknown") {
            this.subscriptionInfo = configInfo;
          }
        }
        return changed;
      }
    }
    // 无resp.result，直接抛出
    throw new Error("无响应数据");
  }

  /**
   * 只刷新套餐流量响应头，不改写 config.yaml，也不改变节点、规则和最后一次
   * 配置更新时间。优先使用 HEAD；服务端不支持 HEAD 时再 GET 并丢弃正文。
   */
  async refreshSubscriptionInfo(): Promise<boolean> {
    if (this.type !== ProfileType.Url || !this.url) {
      return false
    }
    let resp: http.HttpResponse
    try {
      resp = await this.requestSubscriptionMetadata(http.RequestMethod.HEAD, 1024 * 1024)
    } catch (_) {
      resp = await this.requestSubscriptionMetadata(http.RequestMethod.GET, 100 * 1024 * 1024)
    }

    let userinfo = getHttpHeader(resp.header, "subscription-userinfo")
    // 某些订阅网关只在 GET 响应中附加 Subscription-Userinfo。
    if (resp.responseCode < 200 || resp.responseCode >= 300 || !userinfo) {
      if (resp.responseCode !== 200 || !userinfo) {
        resp = await this.requestSubscriptionMetadata(http.RequestMethod.GET, 100 * 1024 * 1024)
        userinfo = getHttpHeader(resp.header, "subscription-userinfo")
      }
    }
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      throw new Error(`额度服务返回 HTTP ${resp.responseCode}`)
    }

    let refreshedInfo: SubscriptionInfo | null = null
    if (userinfo) {
      refreshedInfo = SubscriptionInfo.formHString(userinfo)
    } else if (typeof resp.result === "string") {
      const configInfo = SubscriptionInfo.formConfigText(resp.result as string)
      if (configInfo.state !== "unknown") {
        refreshedInfo = configInfo
      }
    }
    if (!refreshedInfo) {
      console.info(`QuotaRefresh no readable metadata, profileId=${this.id}`)
      return false
    }
    this.subscriptionInfo = refreshedInfo
    console.info(`QuotaRefresh succeeded, profileId=${this.id} source=${refreshedInfo.source}`)
    return true
  }

  private async requestSubscriptionMetadata(method: http.RequestMethod, maxLimit: number): Promise<http.HttpResponse> {
    const httpRequest = http.createHttp()
    let timeoutId: number = -1
    try {
      const requestPromise: Promise<http.HttpResponse> = httpRequest.request(this.url, {
        method: method,
        header: {
          "User-Agent": this.globalUa ?? "clash.meta/1.19.5",
          "Cache-Control": "no-cache"
        },
        connectTimeout: 10000,
        readTimeout: 10000,
        usingCache: false,
        maxLimit: maxLimit
      })
      const timeoutPromise: Promise<http.HttpResponse> = new Promise((resolve, reject) => {
        timeoutId = setTimeout(() => {
          httpRequest.destroy()
          reject(new Error('额度刷新超时'))
        }, 20000)
      })
      return await Promise.race([requestPromise, timeoutPromise])
    } finally {
      if (timeoutId >= 0) clearTimeout(timeoutId)
      httpRequest.destroy()
    }
  }

  async save(raw: string | ArrayBuffer, vailConfig:(config: string)=> Promise<string>): Promise<Profile>{
    let bytes = new Uint8Array()
    let content = ""
    if (typeof raw == "string") {
      // 原始订阅配置必须原样保存；尤其不要改写服务商的 DNS 字段。
      content = raw
      bytes= utf8e.encodeInto(raw)
    } else {
      bytes = new Uint8Array(raw)
      const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true })
      content = decoder.decodeWithStream(bytes)
    }
    const filePath = await getProfilePath(this.context, this.id)
    // 临时文件与正式配置放在同一目录，核心校验成功后使用同卷 rename 原子
    // 替换。下载、YAML/核心校验或写盘失败时，旧 config.yaml 始终保持完整。
    const profileDir = await getProfileDir(this.context, this.id)
    const tempPath = profileDir + `/config.yaml.update.${Date.now()}.${Math.floor(Math.random() * 1000000)}`
    try {
      const temp = await fs.open(tempPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
      try {
        await fs.write(temp.fd, bytes.buffer)
        await fs.fsync(temp.fd)
      } finally {
        await fs.close(temp.fd)
      }
      const message = await vailConfig(tempPath);
      if (message != "") {
        throw new Error(message);
      }
      await fs.rename(tempPath, filePath)
    } catch (error) {
      try {
        if (await fs.access(tempPath, fs.AccessModeType.EXIST)) {
          await fs.unlink(tempPath)
        }
      } catch (_) {
        // 清理异常不遮盖最初的下载/磁盘/核心校验错误，旧配置仍在原路径。
      }
      throw error instanceof Error ? error : new Error(`${error}`)
    }
    this.lastUpdateDate = new Date().getTime()
    this.lastGoodContentId = subscriptionContentId(content)
    this.subscriptionPendingRepair = false
    this.subscriptionRetryAt = 0
    this.subscriptionRetryCount = 0
    return this
  }

  /** 内容完全相同时只推进成功检查时间，不改文件，也不触发上层核心重载。 */
  async saveIfChanged(raw: string | ArrayBuffer,
    vailConfig: (config: string) => Promise<string>): Promise<boolean> {
    let content: string
    if (typeof raw === 'string') {
      content = raw
    } else {
      const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true })
      content = decoder.decodeWithStream(new Uint8Array(raw))
    }
    const filePath = await getProfilePath(this.context, this.id)
    if (await fs.access(filePath, fs.AccessModeType.EXIST)) {
      const previous = await fs.readText(filePath)
      if (previous === content) {
        this.lastUpdateDate = Date.now()
        if (!this.lastGoodContentId) this.lastGoodContentId = subscriptionContentId(content)
        this.subscriptionPendingRepair = false
        this.subscriptionRetryAt = 0
        this.subscriptionRetryCount = 0
        return false
      }
    }
    await this.save(content, vailConfig)
    return true
  }
  async saveByUri(uri: string): Promise<Profile>{
    const filePath = await getProfilePath(this.context, this.id)
    try {
      await fs.copy(uri, fileUri.getUriFromPath(filePath))
    } catch (error) {
      throw error as Error
    }
    return this
  }
  getSelectedProxy(g: ProxyGroup): string | undefined{
    if (g.type !== ProxyType.Selector)
      return g.now
    let dd = this.proxySelected.get(g.name) ?? g.now
    return dd
  }
  getSelectedMap(): Record<string, string>{
    const jsonObject: Record<string, string> = {};
    this.proxySelected.forEach((value, key) => {
      jsonObject[key] = value;
    });
    return jsonObject
  }
  markSubscriptionRetry(reason: string, now: number = Date.now()): void {
    this.subscriptionState = "error"
    this.subscriptionError = reason
    this.subscriptionCheckedAt = now
    this.subscriptionPendingRepair = true
    this.subscriptionRetryCount += 1
    const delay = Math.min(30 * 60 * 1000, Math.max(60 * 1000,
      Math.pow(2, Math.min(this.subscriptionRetryCount - 1, 4)) * 60 * 1000))
    this.subscriptionRetryAt = now + delay
  }

  markCoreLoaded(now: number = Date.now()): void {
    this.coreLoadState = "loaded"
    this.coreLoadedContentId = this.lastGoodContentId
    this.coreLoadedAt = now
  }

  markCoreLoadFailure(reason: string, now: number = Date.now()): void {
    this.coreLoadState = "error"
    this.coreLoadedAt = now
    // Core activation and subscription download are independent state
    // machines. A transient local RPC/config-apply failure must not enqueue a
    // subscription redownload on the next app launch; doing so used to turn a
    // cold-start core error into a misleading "subscription load failed"
    // notification even though the last-good YAML was still intact.
    console.warn(`Profile core load failed profileId=${this.id}, reason=${reason}`)
  }
}

/** Stable, non-secret identifier for a successfully validated subscription. */
export function subscriptionContentId(content: string): string {
  let hash = 2166136261
  for (let index = 0; index < content.length; index++) {
    hash ^= content.charCodeAt(index)
    hash = Math.imul(hash, 16777619) >>> 0
  }
  return `fnv1a-${hash.toString(16).padStart(8, '0')}-${content.length}`
}

async function isYAML(data: string | ArrayBuffer): Promise<boolean> {
  try {
    let content: string;
    if (typeof data === 'string') {
      content = data;
    } else if (data instanceof ArrayBuffer) {
      const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      content = decoder.decodeWithStream(new Uint8Array(data));
    } else {
      return false;
    }

    // 先进行快速的格式校验（在主线程进行轻量级检查）
    const trimmedContent = content.trim();
    // 如果内容是单行的、以 { 开头和 } 结尾的紧凑 JSON，不是典型的 YAML 配置
    if (trimmedContent.startsWith('{') && trimmedContent.endsWith('}') && !trimmedContent.includes('\n')) {
      return false;
    }

    // 使用 TaskPool 在后台线程执行耗时的 YAML 解析
    // 避免大数据量时阻塞 UI 主线程导致卡顿
    const task = new taskpool.Task(parseYAMLInBackground, content);
    const parseResult = await taskpool.execute(task) as boolean;

    if (!parseResult) {
      console.error("YAML 解析失败: TaskPool 解析返回 false");
      return false;
    }

    // 合法 YAML 配置
    return true;

  } catch (e) {
    console.error("YAML 解析失败:", e);
    return false;
  }
}

/**
 * 从 Content-Disposition 响应头中提取文件名
 * @param disposition - Content-Disposition 头的值，
 * @returns {string | null} - 提取到的文件名，如果解析失败返回 null
 */
function getFileNameFromDisposition(disposition: string | null | undefined): string | null {
  if (!disposition) return null;
  // 去除字符串两端的空格
  const cleanDisposition = disposition.trim();
  // 优先尝试解析 RFC 5987 格式
  // 使用更灵活的正则，允许大小写、空格等变化
  const filenameStarRegex = /filename\*\s*=\s*(?:UTF-8|utf-8)\s*''\s*([^;]+)/i;
  const filenameStarMatch = cleanDisposition.match(filenameStarRegex);

  if (filenameStarMatch && filenameStarMatch[1]) {
    // 去除可能的空格并进行 URL 解码
    const encodedFileName = filenameStarMatch[1].trim();
    return decodeURIComponent(encodedFileName);
  }
  // 无 filename*，尝试解析普通的 filename=
  const filenameRegex = /filename\s*=\s*"?([^;"]+)"?/i;
  const filenameMatch = cleanDisposition.match(filenameRegex);

  if (filenameMatch && filenameMatch[1]) {
    return filenameMatch[1].trim();
  }

  // 都没匹配到，返回 null
  return null;
}
