import { EventHub, EventKey } from '../../common/EventHub'
import { ProxyItem as ProxyItem, ProxyData } from '../../common/datasources/ProxyData'
import { AppConfig, ProxyCardSize, UIConfig } from '../../entryability/AppState'
import ClashViewModel, { DelayInfo } from '../../entryability/ClashViewModel'
import { customVibrator } from '../../common/utils/VibratorUtil'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { emptyNodeDelay, NodeDelayResult, nodeDelayText } from '../../common/utils/NodeDelayRunner'
import { NodeQualityResult, nodeQualityBrief } from '../../common/utils/NodeQualityService'
import { Profile } from 'proxy_core'

// 节点卡片使用 LazyForEach 的稳定 key 管理生命周期。这里不再启用
// @Reusable：节点卡片包含点击回调和动态测速状态，系统复用旧实例时可能在
// 触摸派发期间先替换 item，造成视觉卡片与实际点击目标错位。
@Component
export struct ProxyNode {
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  @Prop @Watch('syncDelay') item: ProxyItem
  @Prop disabled: boolean
  @State delayResult: NodeDelayResult = emptyNodeDelay('')
  @State qualityResult: NodeQualityResult | undefined = undefined
  @StorageLink('nodeQualityRevision') @Watch('syncQuality') nodeQualityRevision: number = 0
  private stopDelayListener?: () => void
  private stopResetListener?: () => void
  private stopQualityListener?: () => void
  @Consume('currentProfile') currentProfile: Profile | null
  @Prop selected: string
  @StorageLink('appConfig') appConfig: AppConfig = new AppConfig()
  @Consume isPXSecScreen: boolean
  selectProxy?: (item: ProxyItem) => void
  onLatencyChange?: (l: number) => void

  aboutToAppear(): void {
    this.syncDelay()
    this.syncQuality()
    this.listenForDelay()
  }

  private syncDelay(): void {
    this.delayResult = ClashViewModel.delayMap.get(this.item.name) ?? emptyNodeDelay(this.item.name)
  }

  private syncQuality(): void {
    this.qualityResult = ClashViewModel.getNodeQualityResult(this.currentProfile,
      this.item.g ?? '', this.item.name)
  }

  private listenForDelay(): void {
    this.stopDelayListener?.()
    this.stopResetListener?.()
    this.stopQualityListener?.()
    this.stopDelayListener = EventHub.on(EventKey.TestDelay, (delay: DelayInfo)=>{
      if (delay.name == this.item.name){
        this.delayResult = delay
        this.onLatencyChange?.(delay.delay)
      }
    }, false) // 批量监听
    this.stopResetListener = EventHub.on(EventKey.NodeDelayReset, (): void => this.syncDelay(), false)
    this.stopQualityListener = EventHub.on(EventKey.NodeQualityUpdated, (result: NodeQualityResult): void => {
      if (result.profileId === this.currentProfile?.id && result.group === (this.item.g ?? '') &&
        result.name === this.item.name) {
        this.qualityResult = result
      }
    }, false)
  }

  aboutToDisappear() {
    this.stopDelayListener?.()
    this.stopResetListener?.()
    this.stopQualityListener?.()
  }

  build() {
    if (this.appConfig.proxyCardSize === ProxyCardSize.Large) {
      Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Center, justifyContent: FlexAlign.SpaceBetween}) {
        Column({space: 3}) {
          Text(`${this.item.name}`).ItemTextStyle()
            .maxLines(1)
          Text(protocolText(this.item.type, this.item.network, this.item.udp)).ItemTypeStyle()
          if (this.qualityResult) {
            Text(nodeQualityBrief(this.qualityResult))
              .fontSize(10).fontColor(this.qualityColor()).maxLines(1)
          }
        }.layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Row({space: 5}) {
          Text(nodeDelayText(this.delayResult))
            .fontColor(this.delayColor())
            .fontSize(12)
            .maxLines(1)
            .textAlign(TextAlign.End)
          // group 不要写死, 会和其他tab页的生效，在一个组里唯一
          Radio({ value: this.item.name, group: this.item.g + this.item.name})
            .checked(this.item.name === this.selected)
            .radioStyle({
              checkedBackgroundColor: this.icon_emphasize,
            })
            .hitTestBehavior(HitTestMode.None)
        }
      }.width('100%')
      .padding({left: 14, right: 16})
      .onClick(() => this.selectCurrentProxy())
    } else if (this.appConfig.proxyCardSize === ProxyCardSize.Small) {
      Row() {
        Column() {
          Text(`${this.item.name}`).ItemTextStyle()
            .maxLines(2).padding({bottom: 5})
          Text(protocolText(this.item.type, this.item.network, this.item.udp)).ItemTypeStyle()
            .textOverflow({ overflow: TextOverflow.Ellipsis})
          if (this.qualityResult) {
            Text(nodeQualityBrief(this.qualityResult))
              .fontSize(10).fontColor(this.qualityColor()).maxLines(1)
          }
          Text(nodeDelayText(this.delayResult))
            .fontColor(this.delayColor())
            .fontSize(12)
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.SpaceBetween)
        Radio({ value: this.item.name, group: this.item.g + this.item.name })
          .checked(this.item.name === this.selected)
          .radioStyle({
            checkedBackgroundColor: this.icon_emphasize,
          })
          .hitTestBehavior(HitTestMode.None)
      }
      .ListRowStyle()
      .onClick(() => this.selectCurrentProxy())
    } else {
      Row() {
        Column({space: 3}) {
          Text(`${this.item.name}`).ItemTextStyle()
            .maxLines(1)
          Row({space: 3}) {
            Text(protocolText(this.item.type, this.item.network, this.item.udp))
              .maxLines(1)
              .ItemTypeStyle()
              .fontSize(this.isPXSecScreen ? 10 : 12)
              .constraintSize({maxWidth: this.uiConfig.stringDisplayIndex === 0 ? '55%' : Infinity})
              .textOverflow({ overflow: TextOverflow.Clip})
            Text(nodeDelayText(this.delayResult))
              .fontColor(this.delayColor())
              .textOverflow({ overflow:this.isPXSecScreen ? TextOverflow.MARQUEE : TextOverflow.Ellipsis})
              .layoutWeight(1)
              .fontSize(this.isPXSecScreen ? 10 : 12)
              .maxLines(1)
              .textAlign(this.uiConfig.stringDisplayIndex === 0 ? TextAlign.End:TextAlign.Start)
          }.width(this.uiConfig.stringDisplayIndex === 0 ? '70%' : '100%')
          .justifyContent(FlexAlign.Start)
          if (this.qualityResult) {
            Text(nodeQualityBrief(this.qualityResult))
              .fontSize(this.isPXSecScreen ? 9 : 10)
              .fontColor(this.qualityColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Radio({ value: this.item.name, group: this.item.g + this.item.name })
          .checked(this.item.name === this.selected)
          .radioStyle({
            checkedBackgroundColor: this.icon_emphasize,
          })
          .hitTestBehavior(HitTestMode.None)
          .onChange((isChecked) => {
            hilog.debug(0xFF00, "ProxyPageGroupTag", "ProxyNodeItem #onChange %{public}s的选中状态%{public}s", this.item.name, isChecked)
          })
      }
      .ListRowStyle()
      .onClick(() => this.selectCurrentProxy())
    }
  }

  /** Resolve the node held by this stable-keyed card at the moment of touch. */
  private selectCurrentProxy(): void {
    this.selectProxy?.(this.item)
  }

  private delayColor(): ResourceColor {
    if (this.delayResult.status === 'ok' || this.delayResult.status === 'failed') {
      return ProxyData.getColorForLatency(this.delayResult.delay)
    }
    return $r('sys.color.font_secondary')
  }

  private qualityColor(): ResourceColor {
    if (this.qualityResult?.status === 'failed') return '#E84026'
    if (this.qualityResult?.status === 'testing') return $r('sys.color.font_secondary')
    if ((this.qualityResult?.experienceRank ?? 0) > 0 || this.qualityResult?.reliable === true) return '#3AA655'
    return '#E59A16'
  }
}


@Extend(Text)
function ItemTextStyle() {
  .fontColor(($r('sys.color.font_primary')))
  .fontSize(16)
  .fontWeight(FontWeight.Medium)
  .textOverflow({ overflow: TextOverflow.Ellipsis })
}
//Item中type（节点类型）公用样式
@Extend(Text)
function ItemTypeStyle() {
  .fontColor($r('sys.color.font_secondary'))
  .fontSize(12)
}
@Extend(Row)
function ListRowStyle() {
  .width('100%')
  .padding({ left: 14, right: 8, top: 5, bottom: 5})
// .alignItems(VerticalAlign.Center)
}

export function delayText(delay: number){
  if (delay == 0) {
    return ""
  } else if(delay < 0){
    return "timeout"
  } else {
    return delay + "ms"
  }
}

/**
 * 将核心类型转换成用户可直接识别的协议说明。策略组、直连和拒绝动作
 * 不是代理协议，单独标注，避免把 URLTest/Direct 当成节点协议。
 */
export function protocolText(type: string, network?: string, udp?: boolean): string {
  switch (type) {
    case 'Selector':
      return '手动选择策略组'
    case 'URLTest':
      return '自动测速策略组'
    case 'Fallback':
      return '故障转移策略组'
    case 'LoadBalance':
      return '负载均衡策略组'
    case 'Relay':
      return '链式代理策略组'
    case 'Direct':
      return '直连'
    case 'Reject':
    case 'RejectDrop':
      return '拒绝连接'
    default:
      // type/network 来自当前订阅配置经 Clash 核心加载后的运行时对象，
      // udp 来自适配器 SupportUDP()。这里只组合和统一大小写，不推断字段。
      const details: string[] = []
      if (type) details.push(type.toUpperCase())
      if (network) details.push(network.toUpperCase())
      if (udp === true) details.push('UDP')
      return details.length > 0 ? `协议 · ${details.join(' / ')}` : '协议 · 未知'
  }
}
