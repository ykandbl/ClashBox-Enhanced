import { BreakpointState } from "../../common/breakpoint/breakpointsystem"
import { BIND_SHEET_TITLE_CONTAINER_HEIGHT, BORDER_RADIUS_20, CONTENT_END_OFFSET_150,
  TAB_CONTENT_TITLE_HEIGHT } from "../../common/entity/Constants"
import { AppConfig, UIConfig } from "../../entryability/AppState"
import { convertTime, timestampToDateTime } from "../../common/utils/TimeConvertUtil"
import { Nothing } from "../Common/Common"
import { MoreTop } from "./MoreTopBuilder"
import { curves, LengthMetrics } from "@kit.ArkUI"
import ClashViewModel from "../../entryability/ClashViewModel"
import { ConnectionInfo, Metadata } from "proxy_core"
import { customAnimationUtil } from "../../common/utils/Animation"
import { ConnectItemDataSource } from "../../common/datasources/ConnectData"
import { hilog } from "@kit.PerformanceAnalysisKit"
import { NeedClearMoreStack, PageMargin } from "../../common/breakpoint/BreakPoint"
import { bundleManager } from '@kit.AbilityKit'


export function  getRequestText(metadata: Metadata ) {
  let text = `${metadata.network}://`;
  const ips = [
    metadata.host,
    metadata.destinationIP,
  ].filter((ip: string) => ip && ip !== "");
  text += ips.join("/");
  text += `:${metadata.destinationPort}`;
  return text;
}
export function getSourceText( connection: ConnectionInfo) {
  const  metadata = connection.metadata;
  if (metadata.process != "") {
    return connection.start;
  }
  return `${connection.start}`;
}

/**
 * 卓易通/Android 兼容层的网络连接通常只携带宿主 UID，鸿蒙 VPN 扩展
 * 拿不到 APK 自己的 UID。这里仅根据连接已经暴露的目标域名做保守归属，
 * 不参与分流，也不替代内核的真实 UID/包名结果。
 */
class CompatibilitySignature {
  label: string
  hosts: string[]
  constructor(label: string, hosts: string[]) {
    this.label = label
    this.hosts = hosts
  }
}

export function inferCompatibilityApp(connection: ConnectionInfo): string {
  const metadata = connection?.metadata
  // TUN connections from 卓易通 may lose the original destination host. The
  // sniffer keeps it in sniffHost, so include all three identity hints before
  // falling back to the system-provided UID.
  const haystack = [metadata?.host, metadata?.sniffHost, metadata?.remoteDestination]
    .filter((value: string | undefined): boolean => !!value)
    .join(' ')
    .toLowerCase()
  if (!haystack) return ''
  const signatures: CompatibilitySignature[] = [
    new CompatibilitySignature('ChatGPT（卓易通推断）', [
      'chatgpt.com', 'ws.chatgpt.com', 'oaistatic.com', 'oaiusercontent.com',
      'openai.com', 'api.openai.com', 'android.chat.openai.com', 'chat.openai.com'
    ]),
    new CompatibilitySignature('Gemini（卓易通推断）', [
      'gemini.google.com', 'generativelanguage.googleapis.com', 'ai.google.dev',
      'geller-pa.googleapis.com'
    ]),
    new CompatibilitySignature('Grok（卓易通推断）', ['grok.com', 'x.ai', 'api.x.ai', 'files-cdn.x.ai']),
    new CompatibilitySignature('X（卓易通推断）', ['twitter.com', 'x.com', 'twimg.com']),
    new CompatibilitySignature('Telegram（卓易通推断）', ['telegram.org', 't.me', 'telegram.me', 'telegra.ph']),
    new CompatibilitySignature('Discord（卓易通推断）', ['discord.com', 'discordapp.com', 'discord.gg', 'discord.media']),
    new CompatibilitySignature('YouTube（卓易通推断）', ['youtube.com', 'googlevideo.com', 'ytimg.com', 'youtu.be']),
    new CompatibilitySignature('Gmail（卓易通推断）', ['mail.google.com', 'gmail.com']),
    new CompatibilitySignature('Steam（卓易通推断）', ['steampowered.com', 'steamcommunity.com', 'steamusercontent.com'])
  ]
  for (const signature of signatures) {
    if (signature.hosts.some((host: string): boolean => haystack.includes(host))) return signature.label
  }
  return ''
}

/** Ignore legacy/core placeholder values so domain attribution still runs. */
function normalizedProcessName(metadata: Metadata): string {
  const value = `${metadata?.process ?? ''}`.trim()
  const placeholder = value.toLowerCase()
  if (placeholder === '进程未识别' || placeholder === '未识别' ||
    placeholder === 'unknown' || placeholder === 'unidentified') return ''
  return value
}

/** Best available destination identity, preferring a domain over a bare IP. */
export function getConnectionTargetText(metadata: Metadata): string {
  const values = [metadata?.host, metadata?.sniffHost, metadata?.remoteDestination,
    metadata?.destinationIP]
  for (const value of values) {
    const target = `${value ?? ''}`.trim()
    if (target.length > 0) return target
  }
  return '目标未提供'
}

function inferCompatibilityAppFromItems(items: ConnectionInfo[]): string {
  const counts = new Map<string, number>()
  items.forEach((item: ConnectionInfo): void => {
    const label = inferCompatibilityApp(item)
    if (label) counts.set(label, (counts.get(label) ?? 0) + 1)
  })
  let best = ''
  let score = 0
  counts.forEach((value: number, key: string): void => {
    if (value > score) {
      best = key
      score = value
    }
  })
  return best
}

export function  getTheSourceText( connection: ConnectionInfo) {
  const  metadata = connection.metadata;
  const processName = normalizedProcessName(metadata)
  if (processName.length > 0) return processName
  const uid = Number(metadata.uid ?? 0)
  const inferred = inferCompatibilityApp(connection)
  if (inferred) return inferred
  // A UID of zero is what the HarmonyOS VPN extension receives for sockets
  // owned by the Android compatibility container. Calling it an unidentified
  // process makes a real ChatGPT/Telegram connection look broken. Keep the
  // distinction explicit while avoiding a false package name claim.
  return uid > 0 ? `应用 UID ${uid}` : "系统/兼容层连接";
}

/** 根据内核返回的 rule/chains 显示实际连接路径；缺少信息时保留未知状态。 */
export function getConnectionRouteText(connection: ConnectionInfo): string {
  const rule = `${connection.rule ?? ''}`.toLowerCase()
  const chains = connection.chains ?? []
  if (rule.includes('reject') || rule.includes('block')) return '已拦截'
  if (rule.includes('direct') || chains.some((item: string) => item.toLowerCase() === 'direct')) return '直连'
  if (chains.length > 0 || rule.includes('proxy')) return '代理'
  return '路径未知'
}

export interface AppRouteSummary {
  process: string
  uid: number
  route: string
  connections: number
  upload: number
  download: number
  chains: string[]
  connectionIds: string[]
  lastStart: number
  /** 兼容层连接按域名推断出的应用，仅用于展示。 */
  compatibilityHint?: string
}

/** 汇总内核本次返回的活跃连接，用于验收各应用的真实分流路径。 */
export function summarizeConnectionsByApp(items: ConnectionInfo[]): AppRouteSummary[] {
  const groups = new Map<string, ConnectionInfo[]>()
  items.forEach((item: ConnectionInfo): void => {
    const processName = normalizedProcessName(item.metadata)
    // 系统返回的连接数据可能没有进程路径，但 UID 仍然是可靠的应用身份。
    const uid = Number(item.metadata.uid ?? 0)
    const compatibilityHint = processName.length === 0 ? inferCompatibilityApp(item) : ''
    const groupKey = processName || (uid > 0 ? `uid:${uid}` :
      (compatibilityHint || 'compatibility:system'))
    const group = groups.get(groupKey) ?? []
    group.push(item)
    groups.set(groupKey, group)
  })
  const summaries: AppRouteSummary[] = []
  groups.forEach((connections: ConnectionInfo[], groupKey: string): void => {
    const routes = new Set<string>()
    const chains = new Set<string>()
    let upload = 0
    let download = 0
    let lastStart = 0
    const firstUid = Number(connections[0].metadata.uid ?? 0)
    const connectionIds: string[] = []
    connections.forEach((item: ConnectionInfo): void => {
      routes.add(getConnectionRouteText(item))
      const itemChains = item.chains ?? []
      itemChains.forEach((chain: string): void => {
        if (chain && chain.toLowerCase() !== 'direct') chains.add(chain)
      })
      upload += Math.max(0, item.upload ?? 0)
      download += Math.max(0, item.download ?? 0)
      connectionIds.push(item.id)
      const startedAt = new Date(item.start).getTime()
      if (Number.isFinite(startedAt)) lastStart = Math.max(lastStart, startedAt)
    })
    const routeList = Array.from(routes)
    const route = routeList.length === 0 ? '路径未知' :
      routeList.length === 1 ? routeList[0] : '混合'
    const process = groupKey.startsWith('uid:') ? `应用 UID ${firstUid}` :
      (groupKey === 'compatibility:system' ? '系统/兼容层连接' : groupKey)
    const compatibilityHint = process.startsWith('（') ? undefined :
      inferCompatibilityAppFromItems(connections) || undefined
    summaries.push({ process, uid: firstUid, route, connections: connections.length, upload, download,
      chains: Array.from(chains), connectionIds, lastStart, compatibilityHint })
  })
  return summaries.sort((a: AppRouteSummary, b: AppRouteSummary): number =>
    b.connections - a.connections || b.lastStart - a.lastStart || a.process.localeCompare(b.process))
}

@Builder
export function ConnectBuilder(name: string, param: Object){
  Connect()
}

@Component
struct Connect {
  // page内顶部标题偏移量
  @Consume curYOffset: number
  // 是否进入二级界面
  @Consume isSecondary: boolean
  @State intervalId: number = 0
  private pageInfos: NavPathStack = AppStorage.get<NavPathStack>('NavPathStack') as NavPathStack
  // 状态栏高度
  @StorageProp('topRectHeight') topRectHeight: number = 0
  // 宽度断点
  @StorageLink ('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1
  // 高度断点
  @StorageLink ('currentHeightBreakpoint') heightBp: HeightBreakpoint = 0
  // 数据
  @State private connectListData: ConnectItemDataSource = new ConnectItemDataSource()
  @State private proxyConnectionCount: number = 0
  @State private directConnectionCount: number = 0
  @State private blockedConnectionCount: number = 0
  @State private unknownConnectionCount: number = 0
  @State private activeConnectionCount: number = 0
  @State private appRouteSummaries: AppRouteSummary[] = []
  @State private routeViewMode: string = 'app'
  private connectionRefreshRunning: boolean = false
  private bundleNameCache: Map<number, string> = new Map<number, string>()
  /* 是否开启 `Index` 页面的前景模糊 */
  @Consume('isEnableIndexForegroundBlur') isEnableIndexForegroundBlur: boolean
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  @StorageLink('appConfig') appConfig: AppConfig = new AppConfig()
  // 一级图标色，黑色
  @State icon_primary: ResourceColor = $r('sys.color.icon_primary')
  @Consume needSearch: boolean
  @Consume @Watch('ConnectList') isSearching: boolean
  @Consume @Watch('searchConnect') searchText: string

  async aboutToAppear(): Promise<void> {
    this.connectListData.empty()
    if (this.appConfig.enableConnect) {
      await this.getConnections()
      this.startPolling()
    } else {
      console.log("getConnections 未启用" )
    }
  }

  aboutToDisappear(): void {
    clearInterval(this.intervalId)
    this.connectListData.empty()
    this.resetRouteCounts()
  }

  ConnectList() {
    if (this.isSearching) {
      // 暂停计时任务
      clearInterval(this.intervalId)
    } else {
      // 如果不在搜索，还原请求列表并恢复计时任务
      this.connectListData.restoreData()
      this.startPolling()
    }
  }

  // 请求搜索
  searchConnect(keyword: string) {
    hilog.info(0xFF00, 'Request', `#smartsearchRequest 搜索文本：${this.searchText}`)
    keyword = this.searchText
    if (keyword !== '') {
      hilog.info(0xFF00, 'Request', `#smartsearchRequest 开始搜索，搜索文本：${this.searchText}`)
      // 搜索
      this.connectListData.searchData(keyword)
    } else {
      hilog.info(0xFF00, 'Request', `#smartsearchRequest 空搜索文本：${this.searchText}`)
      // 空文本还原请求列表并恢复计时任务
      this.connectListData.restoreData()
      this.startPolling()
    }
  }

  async getConnections() {
    if (this.connectionRefreshRunning) return
    this.connectionRefreshRunning = true
    try {
      const result = await ClashViewModel.getConnections()
      console.log(`#getConnections count=${result.length}`)
      // Keep the diagnostic payload small and free of subscription material:
      // only identity fields are logged while validating compatibility-layer
      // process attribution on a real device.
      if (result.length > 0) {
        console.info('#getConnections identities=' + result.map((item: ConnectionInfo): string =>
          `uid=${item.metadata.uid},process=${item.metadata.process},source=${item.metadata.sourcePort},host=${item.metadata.host}`
        ).join(' | '))
      }
      // 顶部计数和“按应用”汇总只反映这一次返回的活跃连接。
      this.appRouteSummaries = await this.resolveBundleNames(summarizeConnectionsByApp(result))
      this.refreshRouteCounts(result)
      this.activeConnectionCount = result.length
      // 保留原有连接详情的历史查询体验，但不再用它参与实际连接计数。
      const merged = [...result, ...this.connectListData.getTotslData()]
      const uniqueMap = new Map<string, ConnectionInfo>()
      merged.forEach(item => {
        uniqueMap.set(`${item.id}${item.start}`, item)
      })

      const ConnectListData = Array.from(uniqueMap.values()).sort((a, b) => {
        return new Date(b.start).getTime() - new Date(a.start).getTime()
      })
      this.connectListData.pushData(ConnectListData)
    } catch (error) {
      const reason = error as Error
      hilog.warn(0xFF00, 'Connect', `实时连接刷新失败：${reason.message || 'unknown'}`)
    } finally {
      this.connectionRefreshRunning = false
    }
  }

  async getPackageIcon(connection: ConnectionInfo)  {
    return connection.metadata.process;
  }

  private resetRouteCounts(): void {
    this.proxyConnectionCount = 0
    this.directConnectionCount = 0
    this.blockedConnectionCount = 0
    this.unknownConnectionCount = 0
    this.activeConnectionCount = 0
  }

  private startPolling(): void {
    clearInterval(this.intervalId)
    this.intervalId = setInterval(() => {
      void this.getConnections()
    }, 3000)
  }

  private routeColor(route: string): ResourceColor {
    if (route === '代理') return '#3AA655'
    if (route === '直连') return '#3B82F6'
    if (route === '已拦截') return '#E84026'
    if (route === '混合') return '#E59A16'
    return $r('sys.color.font_secondary')
  }

  private trafficText(bytes: number): string {
    if (bytes < 1024) return `${Math.round(bytes)} B`
    if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024 * 10) / 10} KiB`
    if (bytes < 1024 * 1024 * 1024) return `${Math.round(bytes / 1024 / 1024 * 10) / 10} MiB`
    return `${Math.round(bytes / 1024 / 1024 / 1024 * 100) / 100} GiB`
  }

  private visibleAppRoutes(): AppRouteSummary[] {
    const keyword = this.searchText.trim().toLowerCase()
    if (!this.isSearching || keyword.length === 0) return this.appRouteSummaries
    return this.appRouteSummaries.filter((item: AppRouteSummary): boolean =>
      item.process.toLowerCase().includes(keyword) || item.route.includes(keyword) ||
      item.chains.some((chain: string): boolean => chain.toLowerCase().includes(keyword)))
  }

  private async resolveBundleNames(summaries: AppRouteSummary[]): Promise<AppRouteSummary[]> {
    return await Promise.all(summaries.map(async (item: AppRouteSummary): Promise<AppRouteSummary> => {
      if (item.uid <= 0 || !item.process.startsWith('应用 UID ')) return item
      const cached = this.bundleNameCache.get(item.uid)
      if (cached) return this.renameSummary(item, cached)
      try {
        const bundleName = await bundleManager.getBundleNameByUid(item.uid)
        if (bundleName && bundleName.length > 0) {
          this.bundleNameCache.set(item.uid, bundleName)
          return this.renameSummary(item, bundleName)
        }
      } catch (error) {
        const reason = error as Error
        hilog.debug(0xFF00, 'Connect', `UID ${item.uid} 包名解析失败：${reason.message || 'unknown'}`)
      }
      return item
    }))
  }

  private renameSummary(item: AppRouteSummary, process: string): AppRouteSummary {
    return {
      process: process,
      uid: item.uid,
      route: item.route,
      connections: item.connections,
      upload: item.upload,
      download: item.download,
      chains: item.chains,
      connectionIds: item.connectionIds,
      lastStart: item.lastStart,
      compatibilityHint: item.compatibilityHint
    }
  }

  private async closeAppConnections(item: AppRouteSummary): Promise<void> {
    for (const id of item.connectionIds) await ClashViewModel.closeConnection(id)
    await this.getConnections()
  }

  private refreshRouteCounts(items: ConnectionInfo[]): void {
    this.resetRouteCounts()
    items.forEach((item: ConnectionInfo) => {
      const route = getConnectionRouteText(item)
      if (route === '代理') this.proxyConnectionCount++
      else if (route === '直连') this.directConnectionCount++
      else if (route === '已拦截') this.blockedConnectionCount++
      else this.unknownConnectionCount++
    })
  }


  build() {
    NavDestination() {
      Stack() {
          MoreTop({
            title: $r('app.string.Connect'),
            icon1: this.appConfig.enableConnect ? $r('sys.symbol.clean_fill') : undefined,
            icon2: !this.appConfig.enableConnect ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.checkmark_circle_fill'),
            onClick1: () => {
              this.connectListData.clear()
              this.resetRouteCounts()
              this.appRouteSummaries = []
              ClashViewModel.clearConnections()
            },
            onClick2: () => {
              this.getUIContext().animateTo({ duration: this.uiConfig.animationSpeed, curve: Curve.Linear }, () => {
                this.appConfig.enableConnect = !this.appConfig.enableConnect
                // this.needSearch = this.appConfig.enableConnect
                if (!this.appConfig.enableConnect) {
                  clearInterval(this.intervalId)
                  this.connectListData.clear()
                  this.resetRouteCounts()
                  this.appRouteSummaries = []
                } else {
                  void this.getConnections()
                  this.startPolling()
                }
              })
            }
          })

        Column() {
          Blank().height(TAB_CONTENT_TITLE_HEIGHT + (this.widthBp < 2 ? this.topRectHeight : 0) + 6)
          if (this.appConfig.enableConnect &&
            this.proxyConnectionCount + this.directConnectionCount + this.blockedConnectionCount +
              this.unknownConnectionCount > 0) {
            Text(`当前活跃 ${this.activeConnectionCount}：代理 ${this.proxyConnectionCount} · 直连 ${this.directConnectionCount} · 拦截 ${this.blockedConnectionCount} · 未知 ${this.unknownConnectionCount}`)
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .padding({
                left: PageMargin(this.widthBp, this.heightBp) + 12,
                right: PageMargin(this.widthBp, this.heightBp) + 12,
                bottom: 8
              })
            if (this.appRouteSummaries.some((item: AppRouteSummary): boolean =>
              (item.compatibilityHint ?? '').length > 0)) {
              Text('卓易通应用：系统只返回兼容层宿主 UID，应用名称按目标域名推断，仅用于展示，不影响分流')
                .fontSize(11)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .padding({
                  left: PageMargin(this.widthBp, this.heightBp) + 12,
                  right: PageMargin(this.widthBp, this.heightBp) + 12,
                  bottom: 8
                })
            }
          }
          if (this.appConfig.enableConnect) {
            Row({ space: 6 }) {
              Button('按应用')
                .fontSize(13)
                .fontColor(this.routeViewMode === 'app' ? Color.White : $r('sys.color.font_secondary'))
                .backgroundColor(this.routeViewMode === 'app' ? this.icon_primary :
                  $r('app.color.settings_container_background'))
                .height(34)
                .layoutWeight(1)
                .onClick(() => this.routeViewMode = 'app')
              Button('连接详情')
                .fontSize(13)
                .fontColor(this.routeViewMode === 'connection' ? Color.White : $r('sys.color.font_secondary'))
                .backgroundColor(this.routeViewMode === 'connection' ? this.icon_primary :
                  $r('app.color.settings_container_background'))
                .height(34)
                .layoutWeight(1)
                .onClick(() => this.routeViewMode = 'connection')
            }
            .width('100%')
            .padding({
              left: PageMargin(this.widthBp, this.heightBp),
              right: PageMargin(this.widthBp, this.heightBp),
              bottom: 8
            })
            Text(this.routeViewMode === 'app' ?
              '× 关闭该应用当前全部连接；不会关闭 VPN，应用重新联网会建立新连接' :
              '× 关闭这一条当前连接；不会关闭 VPN，应用需要时会重新连接')
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .padding({
                left: PageMargin(this.widthBp, this.heightBp) + 4,
                right: PageMargin(this.widthBp, this.heightBp) + 4,
                bottom: 8
              })
          }
          // 页面
          if (!this.appConfig.enableConnect) {
            Nothing({
              name: $r('app.string.Connect'),
              isNotEnabled: true
            })
          } else if (this.routeViewMode === 'app' && this.visibleAppRoutes().length === 0) {
            Column({ space: 6 }) {
              Text('当前没有活跃连接').fontSize(16).fontWeight(FontWeight.Medium)
              Text('打开要验收的应用，本页会在3秒内显示实际路径')
                .fontSize(13).fontColor($r('sys.color.font_secondary')).textAlign(TextAlign.Center)
            }
            .layoutWeight(1).justifyContent(FlexAlign.Center).padding(30)
          } else if (this.routeViewMode === 'connection' && this.connectListData.totalCount() === 0) {
            Nothing({ name: $r('app.string.Connect') })
          } else if (this.routeViewMode === 'app') {
            List({ space: 10 }) {
              ForEach(this.visibleAppRoutes(), (item: AppRouteSummary) => {
                ListItem() {
                  Row({ space: 10 }) {
                    Column({ space: 5 }) {
                      Row({ space: 7 }) {
                        Text(item.process).fontSize(16).fontWeight(FontWeight.Medium)
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                        Text(item.route).fontSize(12).fontWeight(FontWeight.Medium)
                          .fontColor(this.routeColor(item.route))
                          .backgroundColor(`${this.routeColor(item.route)}1A`)
                          .borderRadius(8).padding({ left: 7, right: 7, top: 3, bottom: 3 })
                      }.width('100%')
                      Text(`活跃连接 ${item.connections} · ↑${this.trafficText(item.upload)} · ↓${this.trafficText(item.download)}`)
                        .fontSize(13).fontColor($r('sys.color.font_secondary')).maxLines(1)
                      Text(item.chains.length > 0 ? `实际链路：${item.chains.join(' → ')}` : '实际链路：未识别')
                        .fontSize(12).fontColor($r('sys.color.font_secondary')).maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      if (item.process === '系统/兼容层连接') {
                        Text('系统未提供真实应用 UID，仅显示为兼容层连接')
                          .fontSize(11).fontColor($r('sys.color.font_secondary')).maxLines(2)
                      }
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                    Button({ type: ButtonType.Circle, stateEffect: true }) {
                      SymbolGlyph($r('sys.symbol.nosign')).fontSize(22).fontColor([this.icon_primary])
                    }
                    .width(38).height(38)
                    .backgroundColor($r('app.color.settings_container_background'))
                    .onClick(() => void this.closeAppConnections(item))
                  }
                  .width('100%').padding(12)
                  .backgroundColor($r('app.color.container_background')).borderRadius(BORDER_RADIUS_20)
                }
              }, (item: AppRouteSummary) => item.process)
            }
            .width('100%').height('100%')
            .padding({ right: PageMargin(this.widthBp, this.heightBp), left: PageMargin(this.widthBp, this.heightBp) })
            .contentEndOffset(CONTENT_END_OFFSET_150)
          } else {
            Scroll() {
              List({ space: 10 }) {
                LazyForEach(this.connectListData, (item: ConnectionInfo, index: number) => {
                  ListItem() {
                    Row() {
                      // 文本显示区
                      Column() {
                        Text(getRequestText(item.metadata))
                          .fontWeight(FontWeight.Bold)
                          .margin({ bottom: 2 })
                          .fontSize(17)
                        Flex({
                          alignContent: FlexAlign.Start,
                          direction: FlexDirection.Row,
                          wrap: FlexWrap.Wrap,
                          space: { main: LengthMetrics.vp(2), cross: LengthMetrics.vp(2) }
                        }) {
                          ForEach(item.chains, (c: string) => {
                            Text(c)
                              .smallText()
                          })
                          Text(`实际：${getConnectionRouteText(item)}`)
                            .smallText()
                          Text(`应用/进程：${getTheSourceText(item).toString()}`)
                            .smallText()
                          Text(`目标：${getConnectionTargetText(item.metadata)}`)
                            .smallText()
                          Text('·')
                            .smallText()
                          Text(timestampToDateTime(getSourceText(item)))
                            .smallText()
                        }
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)

                      Blank()
                      Button({ type: ButtonType.Circle, stateEffect: true }) {
                        SymbolGlyph($r('sys.symbol.nosign'))
                          .fontSize(24)
                          .fontColor([this.icon_primary])
                      }
                      .width(40)
                      .height(40)
                      .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
                      .backgroundColor($r('app.color.settings_container_background'))
                      .onClick(() => {
                        this.connectListData.notifyDataDelete(index)
                        ClashViewModel.closeConnection(item.id)
                      })
                    }
                    .width('100%')
                    .padding(12)
                    .justifyContent(FlexAlign.Center)
                    .width('100%')
                    .backgroundColor($r('app.color.container_background'))
                    .borderRadius(BORDER_RADIUS_20)
                  }.width('100%')
                  .transition(customAnimationUtil.isScaleTranFast(index, this.uiConfig))
                })
              }.width('100%')
              .height('100%')
              .cachedCount(5, true)
              .padding({ right: PageMargin(this.widthBp, this.heightBp), left: PageMargin(this.widthBp, this.heightBp) })
              .contentEndOffset(CONTENT_END_OFFSET_150)
              .chainAnimation(true)
              .nestedScroll({
                scrollForward: NestedScrollMode.PARENT_FIRST,
                scrollBackward: NestedScrollMode.SELF_FIRST
              })
            }
            .edgeEffect(this.uiConfig.isAnimation ? EdgeEffect.Spring : null)//,{alwaysEnabled:true})
            .onDidScroll((xOffset: number, yOffset: number): void => {
              // 累计计算当前父组件滚动在Y轴方向的偏移量
              if (this.uiConfig.isAnimation){
                this.curYOffset += yOffset
              }
              // console.debug("yOffset" + this.curYOffset);
            })
          }
        }
      }
      .width('100%')
      .height('100%')

    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.background'))
    .onShown(() => {
      // 初始化搜索按钮
      // this.needSearch = this.appConfig.enableConnect
      this.needSearch = false
    })
    .onWillHide(() => {
      this.needSearch = false
      this.isSearching = false
    })
    .onBackPressed(() => {
      if(this.isSearching) {
        this.isSearching = false
        this.searchText = ''
        return true
      }
      if (NeedClearMoreStack(this.widthBp, this.heightBp)) {
        this.pageInfos.clear()
        this.isSecondary = false
        return false
      } else {
      //  this.isSecondary = false
        return false
      }
    })
  }
}
export default Connect

@Extend(Text)
function smallText() {
  .textOverflow({ overflow: TextOverflow.Ellipsis })
  .fontWeight(FontWeight.Normal)
  .fontSize(15)
  .maxLines(1)
}
