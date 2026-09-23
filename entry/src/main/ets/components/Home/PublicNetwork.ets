import { BreakpointState } from '../../common/breakpoint/breakpointsystem'
import { UIConfig } from '../../entryability/AppState'
import { IpInfo } from 'proxy_core'
import { EventHub, EventKey } from '../../common/EventHub'
import { customVibrator } from '../../common/utils/VibratorUtil'
import { customAnimationUtil } from '../../common/utils/Animation'
import { HomeCardFontSize, HomeCardPadding,
  HomeCardPartSmallFontSize } from '../../common/breakpoint/BreakPoint'
import { webview } from '@kit.ArkWeb'
import { CloudflareWebProbe } from '../../common/utils/CloudflareWebProbe'
import ClashViewModel from '../../entryability/ClashViewModel'

class IpPureProbeBridge {
  callback: ((payload: string) => void) | null = null

  report(payload: string): void {
    this.callback?.(payload)
  }
}

@Component
struct PublicNetwork {
  @StorageLink('currentHeightBreakpoint') heightBp: HeightBreakpoint = 0
  @StorageLink('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  @StorageLink('isCheckIpInfo') isRefreshing: boolean = false
  @StorageLink('ipCheckError') ipCheckError: string = ''
  @Consume ipPureScore: number
  @Consume cloudflareScore: number
  @Consume ipDisplayAddress: string
  @Consume ipDisplayLocation: string
  @Consume ipDisplaySource: string
  @Consume ipDisplayProperty: string
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  @Consume isShowHomeEdit: boolean
  @Consume remoteIp: IpInfo | null
  private probeController: webview.WebviewController = new webview.WebviewController()
  private probeBridge: IpPureProbeBridge = new IpPureProbeBridge()
  private probeReady: boolean = false
  private probeResolve: ((payload: string) => void) | null = null
  private probeReject: ((error: Error) => void) | null = null
  private probeTimer: number = -1

  aboutToAppear(): void {
    this.probeBridge.callback = (payload: string): void => this.finishWebProbe(payload)
    CloudflareWebProbe.register((useProxy: boolean, mixedPort: number): Promise<string> =>
      this.startWebProbe(useProxy, mixedPort))
  }

  aboutToDisappear(): void {
    CloudflareWebProbe.unregister()
    this.probeBridge.callback = null
    this.failWebProbe(new Error('Cloudflare 浏览器探针已关闭'))
  }

  build() {
    Column({ space: 7 }) {
      Row({ space: 7 }) {
        Text($r('app.string.PublicNetwork'))
          .fontSize(HomeCardFontSize(this.widthBp, this.heightBp) + 2)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)

        Button({ type: ButtonType.Circle, stateEffect: !this.isRefreshing }) {
          if (this.isRefreshing) {
            LoadingProgress()
              .width(14)
              .height(14)
              .color(this.icon_emphasize)
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(15)
              .fontColor([this.icon_emphasize])
          }
        }
        .width(25)
        .height(25)
        .backgroundColor($r('app.color.home_card_background'))
        .accessibilityText($r('app.string.refresh_IP'))
        .onClick(() => this.requestRefresh())
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(VerticalAlign.Center)

      if (this.ipDisplayAddress) {
        Row({ space: 8 }) {
          Text(this.ipDisplayLocation)
            .fontSize(HomeCardPartSmallFontSize(this.widthBp, this.heightBp))
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.ipDisplayAddress)
            .fontSize(12)
            .fontColor(this.icon_emphasize)
            .maxLines(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 12 }) {
          Row({ space: 5 }) {
            Text('IP来源')
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
            Text(this.ipDisplaySource || '待检测')
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor(this.ipDisplaySource === '广播IP' ? '#EF476F' :
                (this.ipDisplaySource === '原生IP' ? '#32C98B' : '#8A8A8A'))
              .borderRadius(7)
              .maxLines(1)
          }
          Row({ space: 5 }) {
            Text('IP属性')
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
            Text(this.ipDisplayProperty || '待检测')
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor(this.ipDisplayProperty === '机房IP' ? '#FF5C7A' :
                (this.ipDisplayProperty === '住宅IP' ? '#32C98B' : '#8A8A8A'))
              .borderRadius(7)
              .maxLines(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 10 }) {
          Row({ space: 5 }) {
            Text('IPPure系数')
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
            Text(this.ipPureScore >= 0 ?
              `${this.ipPureScore}% ${this.scoreLabel(this.ipPureScore)}` : '检测异常')
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.ipPureScore >= 0 ? Color.White : '#D92D20')
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .backgroundColor(this.ipPureScore >= 0 ? this.scoreColor(this.ipPureScore) : '#14E84033')
              .border({ width: this.ipPureScore >= 0 ? 0 : 0.5, color: '#45E84033' })
              .borderRadius(7)
              .maxLines(1)
          }
          Row({ space: 5 }) {
            Text('Cloudflare系数')
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
            Text(this.cloudflareScore >= 0 ?
              `${this.cloudflareScore}% ${this.scoreLabel(this.cloudflareScore)}` : '本次未返回')
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.cloudflareScore >= 0 ? Color.White : '#667085')
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .backgroundColor(this.cloudflareScore >= 0 ? this.scoreColor(this.cloudflareScore) : '#F2F4F7')
              .border({ width: this.cloudflareScore >= 0 ? 0 : 0.5, color: '#D0D5DD' })
              .borderRadius(7)
              .maxLines(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else {
        Row({ space: 8 }) {
          if (this.isRefreshing) {
            LoadingProgress()
              .width(22)
              .height(22)
              .color(this.icon_emphasize)
          } else {
            Text('!')
              .width(22)
              .height(22)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .backgroundColor('#D92D20')
              .borderRadius(11)
          }
          Text(this.ipCheckError ? 'IPPure 请求异常，点击标题旁图标重试' : $r('app.string.loading'))
            .fontSize(14)
            .fontColor(this.ipCheckError ? '#D92D20' : $r('sys.color.font_secondary'))
            .maxLines(2)
        }
        .layoutWeight(1)
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      // IPPure 官网的 Cloudflare 系数依赖真实浏览器侧摘要。1px ArkWeb 只运行
      // 官方隐藏 iframe，不参与显示；透明和绝对定位避免影响卡片布局。
      Web({ src: 'https://ippure.com/__clashbox_cf_probe__', controller: this.probeController })
        .width(1)
        .height(1)
        .opacity(0)
        .position({ x: -20, y: -20 })
        .fileAccess(true)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .javaScriptProxy({
          object: this.probeBridge,
          name: 'ippureNative',
          methodList: ['report'],
          controller: this.probeController
        })
        .onInterceptRequest((event) => {
          if (event?.request.getRequestUrl() !== 'https://ippure.com/__clashbox_cf_probe__') return null
          const response = new WebResourceResponse()
          response.setResponseData($rawfile('html/ippure_cf_probe.html'))
          response.setResponseEncoding('utf-8')
          response.setResponseMimeType('text/html')
          response.setResponseCode(200)
          response.setReasonMessage('OK')
          response.setResponseIsReady(true)
          return response
        })
        .onPageEnd((): void => {
          this.probeReady = true
          if (this.probeResolve) this.launchWebProbe()
        })
    }
    .padding(HomeCardPadding(this.widthBp, this.heightBp))
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .id('PublicNetworkId')
    .transition(customAnimationUtil.isOpacity(this.uiConfig))
    .onVisibleAreaChange([0], (isExpanding: boolean) => {
      // 首帧出现早于冷启动 TUN 恢复。此时直连探测会跨越路由切换并与
      // 客户端首个请求竞争；启动后的延迟刷新由 Index 统一负责。
      if (isExpanding && ClashViewModel.vpnStarted) {
        EventHub.sendEvent(EventKey.checkIpInfo)
      }
    })
  }

  private requestRefresh(): void {
    if (this.isShowHomeEdit || this.isRefreshing) return
    EventHub.sendEvent(EventKey.checkIpInfo)
    if (this.uiConfig.isVibrate) customVibrator.vibratorTriggerOfHapticClockTimer()
  }

  private async startWebProbe(useProxy: boolean, mixedPort: number): Promise<string> {
    await this.configureWebProxy(useProxy, mixedPort)
    if (this.probeReject) this.failWebProbe(new Error('Cloudflare 浏览器检测已被新的请求替换'))
    return new Promise<string>((resolve: (payload: string) => void,
      reject: (error: Error) => void): void => {
      this.probeResolve = resolve
      this.probeReject = reject
      if (this.probeReady) this.launchWebProbe()
    })
  }

  private configureWebProxy(useProxy: boolean, mixedPort: number): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      try {
        if (useProxy) {
          const config = new webview.ProxyConfig()
          config.insertProxyRule(`127.0.0.1:${mixedPort > 0 ? mixedPort : 7890}`)
          webview.ProxyController.applyProxyOverride(config, resolve)
        } else {
          webview.ProxyController.removeProxyOverride(resolve)
        }
      } catch (error) {
        reject(error as Error)
      }
    })
  }

  private launchWebProbe(): void {
    if (!this.probeResolve) return
    if (this.probeTimer >= 0) clearTimeout(this.probeTimer)
    this.probeTimer = setTimeout((): void => {
      this.failWebProbe(new Error('Cloudflare 浏览器检测超时'))
    }, 15000)
    this.probeController.runJavaScript('window.runProbe()').catch((error: Error): void => {
      this.failWebProbe(error)
    })
  }

  private finishWebProbe(payload: string): void {
    if (!this.probeResolve) return
    if (this.probeTimer >= 0) clearTimeout(this.probeTimer)
    this.probeTimer = -1
    const resolve = this.probeResolve
    this.probeResolve = null
    this.probeReject = null
    resolve(payload)
  }

  private failWebProbe(error: Error): void {
    if (this.probeTimer >= 0) clearTimeout(this.probeTimer)
    this.probeTimer = -1
    const reject = this.probeReject
    this.probeResolve = null
    this.probeReject = null
    reject?.(error)
  }

  private scoreColor(score: number): ResourceColor {
    if (score <= 15) return '#16803C'
    if (score <= 25) return '#22C55E'
    if (score <= 40) return '#84CC16'
    if (score <= 50) return '#EAB308'
    if (score <= 70) return '#F97316'
    return '#DC2626'
  }

  private scoreLabel(score: number): string {
    if (score <= 15) return '极纯净'
    if (score <= 25) return '纯净'
    if (score <= 40) return '较纯净'
    if (score <= 50) return '一般'
    if (score <= 70) return '风险'
    return '高风险'
  }
}

export default PublicNetwork
