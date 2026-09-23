import { ClashConfig } from 'proxy_core'
import {  BreakpointState } from '../../common/breakpoint/breakpointsystem'
import { CardTitle } from './CardTitleBuilder'
import { ProxyItem, ProxyData  } from '../../common/datasources/ProxyData'
import { AppConfig } from '../../entryability/AppState'
import ClashViewModel from '../../entryability/ClashViewModel'
import { emptyNodeDelay, NodeDelayResult, nodeDelayText } from '../../common/utils/NodeDelayRunner'
import { HomeCardPadding, HomeCardPartSmFontSize, HomeCardProxyFontSize } from '../../common/breakpoint/BreakPoint'
import { font_primary } from '../Common/Common'
import PlatformConnectivityService, {
  PlatformCheckResult,
  PlatformConnectivityResult,
} from '../../common/utils/PlatformConnectivityService'
import { EventHub, EventKey } from '../../common/EventHub'
import { LengthMetrics } from '@kit.ArkUI'


@Component
struct CurrentNode {

  // 高度断点
  @StorageLink ('currentHeightBreakpoint') heightBp: HeightBreakpoint = 0
  // 宽度断点
  @StorageLink ('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1
  @StorageLink('appConfig') @Watch('syncDelay') appConfig: AppConfig = new AppConfig()
  @StorageLink('nodeDelayRevision') @Watch('syncDelay') nodeDelayRevision: number = 0
  @State currentDelay: NodeDelayResult = emptyNodeDelay('')
  @Consume isShowHomeEdit: boolean
  @Consume('isEnableIndexForegroundBlur') isEnableIndexForegroundBlur: boolean
  @StorageLink('platformCheckState') platformCheckState: string = 'idle'
  @StorageLink('platformCheckSummary') platformCheckSummary: string = '等待检测'

  private platformTestDialogController: CustomDialogController | null = new CustomDialogController({
    builder: PlatformTestDialog({}),
    alignment: DialogAlignment.Center,
    cornerRadius: 28,
    autoCancel: true,
    onWillDismiss: (action: DismissDialogAction) => {
      action.dismiss()
      this.isEnableIndexForegroundBlur = false
    }
  })

  build() {
    Column() {
      CardTitle({title: $r('app.string.CurrentNode')})
      Column() {
        if (this.appConfig.currentProxyItem) {
          Text(this.appConfig.currentProxyName ?? this.appConfig.currentProxyItem.name ?? '未选择节点')
            .fontSize(HomeCardProxyFontSize(this.widthBp, this.heightBp))
            .fontWeight(FontWeight.Bold)
            .fontColor(font_primary)
            .maxLines(2)

          Flex({
            direction: FlexDirection.Row,
            wrap: FlexWrap.Wrap,
            alignContent: FlexAlign.Start,
            space: { main: LengthMetrics.vp(5), cross: LengthMetrics.vp(4) }
          }) {
            Text('延迟 ' + nodeDelayText(this.currentDelay))
              .fontSize(HomeCardPartSmFontSize(this.widthBp, this.heightBp))
              .fontColor(ProxyData.getColorForLatency(this.currentDelay.delay))
              .maxLines(1)
            Text('平台检测')
              .fontSize(HomeCardPartSmFontSize(this.widthBp, this.heightBp))
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
            Text(this.cardStatusText())
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.cardStatusColor())
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .backgroundColor(this.cardStatusBackground())
              .borderRadius(8)
          }
          .width('100%')
        } else {
          Text($r('app.string.proxy_name'))
            .fontSize(HomeCardProxyFontSize(this.widthBp, this.heightBp))
            .fontWeight(FontWeight.Bold)
            .fontColor(font_primary)

          Row(){
            Text('ping ')
              .fontSize(HomeCardPartSmFontSize(this.widthBp, this.heightBp))
              .fontColor('#64BB5C')
            Text($r('app.string.Delay'))
              .fontSize(HomeCardPartSmFontSize(this.widthBp, this.heightBp))
              .fontColor('#64BB5C')
          }
        }
      }
      .flexGrow(1)
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(HorizontalAlign.Start)
    }
    .padding(HomeCardPadding(this.widthBp, this.heightBp))
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .id('CurrentNodeId')
    .onClick(() => {
      if (!this.isShowHomeEdit) {
        this.isEnableIndexForegroundBlur = true
        this.platformTestDialogController?.open()
      }
    })
  }

  aboutToDisappear(): void {
    this.platformTestDialogController = null
  }

  aboutToAppear(): void {
    this.syncDelay()
  }

  private syncDelay(): void {
    const name = this.appConfig.currentProxyItem?.name ?? ''
    this.currentDelay = ClashViewModel.delayMap.get(name) ?? emptyNodeDelay(name)
  }

  private cardStatusText(): string {
    if (this.platformCheckState === 'testing') return '检测中'
    if (this.platformCheckState === 'normal') return '正常'
    if (this.platformCheckState === 'slow') return '慢速'
    if (this.platformCheckState === 'error') return '异常'
    if (this.platformCheckState === 'inactive') return '未连接'
    return '待检测'
  }

  private cardStatusColor(): ResourceColor {
    if (this.platformCheckState === 'normal') return '#07875C'
    if (this.platformCheckState === 'slow' || this.platformCheckState === 'testing') return '#B66A00'
    if (this.platformCheckState === 'error') return '#D92D20'
    return '#667085'
  }

  private cardStatusBackground(): ResourceColor {
    if (this.platformCheckState === 'normal') return '#1400A870'
    if (this.platformCheckState === 'slow' || this.platformCheckState === 'testing') return '#16E59A16'
    if (this.platformCheckState === 'error') return '#14E84033'
    return '#12000000'
  }
}
export default CurrentNode

@CustomDialog
struct PlatformTestDialog {
  controller?: CustomDialogController
  @StorageLink('appConfig') appConfig: AppConfig = new AppConfig()
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  @Consume('isEnableIndexForegroundBlur') isEnableIndexForegroundBlur: boolean
  @StorageLink('platformCheckState') platformCheckState: string = 'idle'
  @StorageLink('platformCheckSummary') platformCheckSummary: string = '等待检测'
  @StorageLink('platformCheckResults') platformCheckResults: string = '[]'
  @StorageLink('platformCheckNode') platformCheckNode: string = ''
  @State nodeDelay: NodeDelayResult = emptyNodeDelay('')

  aboutToAppear(): void {
    const nodeName = this.appConfig.currentProxyItem?.name ?? this.appConfig.currentProxyName ?? ''
    if (nodeName.length > 0) {
      this.nodeDelay = emptyNodeDelay(nodeName, 'testing')
      ClashViewModel.testDelay(nodeName).then((delay: number): void => {
        if (nodeName === (this.appConfig.currentProxyItem?.name ?? this.appConfig.currentProxyName ?? '')) {
          this.nodeDelay = ClashViewModel.delayMap.get(nodeName) ?? emptyNodeDelay(nodeName)
        }
      })
    }
  }

  runTest(): void {
    if (!ClashViewModel.vpnStarted || this.platformCheckState === 'testing') return
    const nodeName = this.appConfig.currentProxyItem?.name ?? ''
    this.nodeDelay = emptyNodeDelay(nodeName, 'testing')
    if (nodeName.length > 0) {
      ClashViewModel.testDelay(nodeName).then((delay: number): void => {
        if (nodeName === this.appConfig.currentProxyItem?.name) {
          this.nodeDelay = ClashViewModel.delayMap.get(nodeName) ?? emptyNodeDelay(nodeName)
        }
      })
    }
    // 手动点击才执行完整的会话/上传/媒体/长连接检测；节点切换和 VPN
    // 启动的后台探针保持轻量，避免干扰真实应用的首个请求。
    EventHub.sendEvent(EventKey.checkIpInfo, { force: true, deep: true })
  }

  private statusText(result: PlatformConnectivityResult): string {
    const latencyRange = result.minLatency === result.maxLatency ? `${result.minLatency}ms` :
      `${result.minLatency}–${result.maxLatency}ms`
    const quality = result.quality === 'normal' ? '正常' : result.quality === 'slow' ? '慢速' : '异常'
    return `${quality} ${result.successCount}/${result.attempts} · ${latencyRange}`
  }

  private statusColor(result: PlatformConnectivityResult): ResourceColor {
    if (result.quality === 'normal') return '#3AA655'
    if (result.quality === 'slow') return '#E59A16'
    return '#E84026'
  }

  private checkColor(check: PlatformCheckResult): ResourceColor {
    return check.success ? '#3AA655' : '#E84026'
  }

  private checkMetric(check: PlatformCheckResult): string {
    if (!check.success) return check.errorMessage || '失败'
    if ((check.category === '上传' || check.category === '媒体' || check.category === '视频') &&
      check.transferBytes >= 32 * 1024) {
      return `${this.transferText(check.transferBytes)} · ${check.latency}ms`
    }
    return `${check.latency}ms`
  }

  private transferText(bytes: number): string {
    if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KiB`
    return `${Math.round(bytes / 1024 / 1024 * 100) / 100} MiB`
  }

  private parsedResults(): PlatformConnectivityResult[] {
    try {
      return JSON.parse(this.platformCheckResults) as PlatformConnectivityResult[]
    } catch (_) {
      return []
    }
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 3 }) {
          Text('应用会话链路检测')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
          Text(this.platformCheckNode || (this.appConfig.currentProxyName ??
            this.appConfig.currentProxyItem?.name ?? '未选择节点'))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(18)
            .fontColor([$r('sys.color.font_secondary')])
        }
        .type(ButtonType.Circle)
        .size({ width: 36, height: 36 })
        .backgroundColor($r('app.color.settings_container_background'))
        .onClick(() => {
          this.isEnableIndexForegroundBlur = false
          this.controller?.close()
        })
      }
      .width('100%')

      if (!ClashViewModel.vpnStarted) {
        Text('请先启动代理，再检测当前节点到各平台的真实 HTTPS 链路。')
          .fontSize(14)
          .fontColor('#E59A16')
          .width('100%')
      } else {
        Row() {
          Text('节点握手')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
          Blank()
          Text(nodeDelayText(this.nodeDelay))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(ProxyData.getColorForLatency(this.nodeDelay.delay))
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .borderRadius(12)
        .backgroundColor($r('app.color.settings_container_background'))

        if (this.platformCheckState === 'testing') {
          Row({ space: 10 }) {
            LoadingProgress().size({ width: 24, height: 24 }).color(this.icon_emphasize)
            Text(`${this.platformCheckSummary} · 完成一项立即显示`)
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        }

        List({ space: 7 }) {
          ForEach(this.parsedResults(), (result: PlatformConnectivityResult) => {
            ListItem() {
              Column({ space: 6 }) {
                Row() {
                  Text(result.name)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_primary'))
                  Blank()
                  SymbolGlyph(result.successCount === result.attempts ?
                    $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.exclamationmark_circle_fill'))
                    .fontSize(22)
                    .fontColor([this.statusColor(result)])
                }
                .width('100%')

                Text(this.statusText(result))
                  .fontSize(12)
                  .fontColor(this.statusColor(result))
                Text(result.detail)
                  .fontSize(11)
                  .fontColor($r('sys.color.font_secondary'))
                  .maxLines(2)

                ForEach(result.checks ?? [], (check: PlatformCheckResult) => {
                  Row({ space: 6 }) {
                    Text(check.success ? '✓' : '!')
                      .fontSize(11)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(this.checkColor(check))
                    Text(`${check.category} · ${check.label}`)
                      .fontSize(11)
                      .fontColor($r('sys.color.font_secondary'))
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.checkMetric(check))
                      .fontSize(10)
                      .fontColor(this.checkColor(check))
                      .maxLines(1)
                  }
                  .width('100%')
                })
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .borderRadius(12)
              .backgroundColor($r('app.color.settings_container_background'))
            }
          }, (result: PlatformConnectivityResult): string => result.name)
        }
        .layoutWeight(1)
        .width('100%')

        Text('每个平台均检测入口、消息/发帖、文件或媒体上传、图片视频下载与长连接；另验证 128 KiB 上行、256 KiB 下行和双向 WS 8 秒。这里显示传输量与耗时，不代表节点带宽；匿名探针不执行账号操作。')
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }

      Button(this.platformCheckState === 'testing' ? '正在检测…' : '重新检测')
        .width('100%')
        .height(42)
        .enabled(ClashViewModel.vpnStarted && this.platformCheckState !== 'testing')
        .backgroundColor(this.icon_emphasize)
        .onClick(() => this.runTest())
    }
    .padding(20)
    .width('100%')
    .height('82%')
    .backgroundColor($r('app.color.container_background'))
  }
}
