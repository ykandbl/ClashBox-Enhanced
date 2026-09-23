
export interface Provider {
  name: string;
  type: ProviderType;
  path: string
  "subscription-info": SubscriptionInfo,
  "vehicle-type": VehicleType;
  "update-at": number;
}
export enum ProviderType {
  Proxy = "Proxy",
  Rule = "Rule"
}
export enum VehicleType {
  HTTP = "HTTP",
  File = "File",
  Compatible = "Compatible"
}


export class SubscriptionInfo{
  upload = 0
  download = 0
  total = 0
  expire = 0
  // 额度来源与可见性。旧数据库记录没有这些字段时，按 unknown 处理。
  source: string = "none"
  state: string = "unknown"
  updatedAt: number = 0
  static formHString(info: string | undefined): SubscriptionInfo{
    const si = new SubscriptionInfo()
    if (!info)
      return si
    const list = info.split(";");
    const map = {} as  Record<string, number>;
    for (let i of list) {
      const keyValue = i.trim().split("=");
      map[keyValue[0]] = parseInt(keyValue[1]);
    }
    si.upload = map["upload"] ?? 0
    si.download = map["download"] ?? 0
    si.total = map["total"] ?? 0
    si.expire = map["expire"] ?? 0
    si.source = "header"
    si.state = si.total > 0 ? "known" : "header-no-total"
    si.updatedAt = new Date().getTime()
    return si
  }

  /** 仅解析配置文本中明确的额度字段，避免误判代理节点名称。 */
  static formConfigText(content: string | undefined): SubscriptionInfo {
    const si = new SubscriptionInfo()
    if (!content) return si
    const unlimited = /(unlimited|no[\s_-]*limit|无限流量|不限流量|流量不限)/i.test(content)
    const totalRaw = content.match(/(?:total|quota|traffic[_ -]?limit|总流量|流量上限)\s*[:=]\s*([0-9]+(?:\.[0-9]+)?\s*(?:[kmgt]?i?b|[kmgt]?字节|字节))/i)
    const usedRaw = content.match(/(?:used|traffic[_ -]?used|已用流量)\s*[:=]\s*([0-9]+(?:\.[0-9]+)?\s*(?:[kmgt]?i?b|[kmgt]?字节|字节))/i)
    const remainingRaw = content.match(/(?:remaining|traffic[_ -]?remaining|剩余流量)\s*[:=]\s*([0-9]+(?:\.[0-9]+)?\s*(?:[kmgt]?i?b|[kmgt]?字节|字节))/i)
    if (totalRaw) si.total = SubscriptionInfo.parseBytes(totalRaw[1])
    if (usedRaw) {
      si.download = SubscriptionInfo.parseBytes(usedRaw[1])
    } else if (remainingRaw && si.total > 0) {
      si.download = Math.max(0, si.total - SubscriptionInfo.parseBytes(remainingRaw[1]))
    }
    if (unlimited) {
      si.source = "config"
      si.state = "unlimited"
    } else if (si.total > 0) {
      si.source = "config"
      si.state = "known"
    }
    si.updatedAt = new Date().getTime()
    return si
  }

  private static parseBytes(raw: string): number {
    const match = raw.trim().match(/^([0-9]+(?:\.[0-9]+)?)\s*([kmgt]?i?b|[kmgt]?字节|字节)$/i)
    if (!match) return 0
    const value = Number(match[1])
    const unit = match[2].toLowerCase()
    if (unit === "tb" || unit === "tib" || unit === "t字节") return value * Math.pow(1024, 4)
    if (unit === "gb" || unit === "gib" || unit === "g字节") return value * Math.pow(1024, 3)
    if (unit === "mb" || unit === "mib" || unit === "m字节") return value * Math.pow(1024, 2)
    if (unit === "kb" || unit === "kib" || unit === "k字节") return value * Math.pow(1024, 1)
    return value
  }
  static GetTotal(info: SubscriptionInfo): TrafficValue{
    if(!info)
      return
    return new TrafficValue(info["Total"] ?? info.total ?? 0)
  }
  static GetUsed(info: SubscriptionInfo): TrafficValue{
    if (!info)
      return
    return new TrafficValue((info["Upload"] ?? info.upload) + (info["Download"] ?? info.download ?? 0))
  }
  static getExpire(info: SubscriptionInfo){
    if(!info)
      return
    return info["Expire"] ?? info.expire
  }

}

export enum ProxySort {
  Default = "Default", Title = "Title", Delay = "Delay", Experience = "Experience"
}

export enum ProxyMode { Global ="GLOBAL", Rule = "RULE", Direct = "DIRECT" }
export enum ProxyType {
  Direct = "Direct",
  Reject = "Reject",
  RejectDrop = "RejectDrop",
  Compatible = "Compatible",
  Pass = "Pass",

  Shadowsocks = "Shadowsocks",
  ShadowsocksR = "ShadowsocksR",
  Snell = "Snell",
  Socks5 = "Socks5",
  Http = "Http",
  Vmess = "Vmess",
  Vless = "Vless",
  Trojan = "Trojan",
  Hysteria = "Hysteria",
  Hysteria2 = "Hysteria2",
  Tuic = "Tuic",
  WireGuard = "WireGuard",
  Dns = "Dns",
  Ssh = "Ssh",

  Relay = "Relay",
  Selector = "Selector",
  Fallback = "Fallback",
  URLTest = "URLTest",
  LoadBalance = "LoadBalance",

  Unknown = "Unknown"
}
export interface Proxy {
  name: string
  type: ProxyType;
  /** Transport and UDP capability reported by the active Clash runtime. */
  network?: string
  udp?: boolean
  latency?: number
  id?: string
  g?: string
  isShowFavoriteProxy?: boolean
}

export interface ProxyGroup{
  type: ProxyType
  name: string
  proxies: Array<Proxy>
  now: string
  hidden?: boolean
  icon?: string
}
export enum OverrideSlot{
  Persist, Session
}

export interface FetchInfo{
  type: string
  value: string
}

export enum LogLevel {
  Debug = "debug",
  Info = "info",
  Warning = "warning",
  Error = "error",
  Silent = "silent",
  Unknown = "unknown"
}
export class LogInfo{
  logLevel: LogLevel
  payload: string
  time: number
}
export enum TrafficUnit{
  KB = "KB",
  MB= "MB",
  GB= "GB",
  TB= "TB",
  B = "B"
}
export class TrafficValue{
  value: number
  show: number
  unit: TrafficUnit
  constructor(value: number) {
    this.value = value ?? 0
    if (this.value > Math.pow(1024, 4)) {
      this.show = (this.value / Math.pow(1024, 4))
      this.unit = TrafficUnit.TB
    }else if (this.value > Math.pow(1024, 3)) {
      this.show = (this.value / Math.pow(1024, 3))
      this.unit = TrafficUnit.GB
    }else if (this.value > Math.pow(1024, 2)) {
      this.show = (this.value / Math.pow(1024, 2))
      this.unit = TrafficUnit.MB
    }else if (this.value > Math.pow(1024, 1)) {
      this.show = (this.value / Math.pow(1024, 1))
      this.unit = TrafficUnit.KB
    } else{
      this.show = this.value
      this.unit = TrafficUnit.B
    }
  }
  toString(){
    return this.show.toFixed(0)  + " " + this.unit
  }

}
export interface Snapshot{
  downloadTotal: number
  uploadTotal: number
  connections: ConnectionInfo
  memory: number
}
export  interface Metadata{
  uid: number
  network: string
  sourceIP: string
  sourcePort: string
  destinationIP: string
  destinationPort: string
  host: string
  /** Hostname discovered by the TLS/HTTP sniffer when the original host is absent. */
  sniffHost?: string
  process: string
  remoteDestination: string
}
export interface ConnectionInfo{
  id: string
  metadata : Metadata
  upload : number
  download : number
  start: number
  chains: string[]
  rule : string
  rulePayload : string
}
export class Traffic{
  upRaw: number;
  downRaw: number;
  up: TrafficValue
  down: TrafficValue

  constructor(up: number, down: number) {
    this.upRaw = up ?? 0;
    this.downRaw = down ?? 0;
    this.up = new TrafficValue(up)
    this.down = new TrafficValue(down)
  }

  total(): TrafficValue{
    return new TrafficValue(this.upRaw + this.downRaw)
  }

  static FetchUp(value: number){
      return Traffic.ScaleTraffic(value >>> 32)
  }
  static FetchDown(value: number){
    return Traffic.ScaleTraffic(value & 0xFFFFFFFF)
  }
  static ScaleTraffic(value: number): number {
    const type = (value >>> 30) & 0x3;
    const data = value & 0x3FFFFFFF;

    switch (type) {
      case 0:
        return data;
      case 1:
        return data * 1024;
      case 2:
        return data * 1024 * 1024;
      case 3:
        return data * 1024 * 1024 * 1024;
      default:
        throw new Error("Invalid value type");
    }
  }

}
export class IpInfo {
  ip: string
  country: string
  location?: string
  ipSource?: string
  ipProperty?: string
  ipPureScore?: number
  cloudflareScore?: number
  viaProxy?: boolean
  qualityError?: string
  updatedAt?: number
}
