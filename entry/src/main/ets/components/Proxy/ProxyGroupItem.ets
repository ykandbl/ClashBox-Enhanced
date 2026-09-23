import { hilog } from '@kit.PerformanceAnalysisKit'
import {
  BORDER_RADIUS_20,
  CONTENT_END_OFFSET_150,
  LIST_ITEM_HEIGHT,
  TAB_CONTENT_TITLE_SYMBOL_FONT_SIZE } from '../../common/entity/Constants'
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { ProxyGroupItemDataSource, ProxyItem, ProxyItemDataSource } from '../../common/datasources/ProxyData';
import { ClashConfig, ConnectionInfo, Profile, ProxyGroup, ProxyMode, ProxySort } from 'proxy_core';
import { AppConfig, AppState, ClashCore, ProxyCardSize, ProxyGroupType, UIConfig } from '../../entryability/AppState';
import { ProxyNode } from './ProxyNodeItem';
import { customAnimationUtil } from '../../common/utils/Animation';
import { customVibrator } from '../../common/utils/VibratorUtil';
import ClashViewModel from '../../entryability/ClashViewModel';
import { PopTips, PopupBuilder } from '../Start/Popup';
import { ListGutter, ProxyListLanes } from '../../common/breakpoint/BreakPoint';
import { cardManager } from '../../common/utils/CardManageUtil';
import { Xb_ToastUtil } from 'xb_components';
import { EventHub, EventKey } from '../../common/EventHub';
import { emptyNodeDelay, NodeDelayResult, nodeDelayErrorText, nodeDelayText } from '../../common/utils/NodeDelayRunner';
import NodeQualityService, { NodeQualityMode, NodeQualityResult, nodeQualityBrief } from '../../common/utils/NodeQualityService';

// 组件名
const componentName: string = 'ProxyPage'
// 长按菜单图标
const startIconModifier1: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.bolt_filled_on_circle')).fontSize('24vp');
const startIconModifier2: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.timer')).fontSize('24vp');
const startIconModifier3: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.questionmark_circle')).fontSize('24vp');
const qualityIconModifier: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.network_acceleration')).fontSize('24vp');

@Component
struct ProxyGroupItem {

  /* 主题色 */
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  @State currentTouchIndex: number = 0
  // 主界面index
  @Consume tabCurrentPage: number

  /* 本页布局相关参数 */
  // 定义ProxyGroupItemSelectedWide的值便于切换布局方式
  @Prop ProxyGroupItemSelected: ProxyCardSize
  //是否显示网络测速半模拟态判定
  @State isShowNetworkSpeed: boolean = false
  @State isShowSustainedSpeed: boolean = false
  @State sustainedNodeName: string = ''
  @State sustainedModeName: string = ''
  @State sustainedPhase: string = '准备测速'
  @State sustainedDirection: string = ''
  @State sustainedCurrentMbps: number = 0
  @State sustainedDownloadMbps: number = 0
  @State sustainedUploadMbps: number = 0
  @State sustainedTrafficBytes: number = 0
  @State sustainedElapsedSeconds: number = 0
  @State sustainedDownloadSamples: number = 0
  @State sustainedUploadSamples: number = 0
  @State sustainedTargetName: string = ''
  @State sustainedDownloadPoints: number[] = []
  @State sustainedUploadPoints: number[] = []
  @State sustainedDownloadTimes: number[] = []
  @State sustainedUploadTimes: number[] = []
  @State sustainedRunning: boolean = false
  @State sustainedFinished: boolean = false
  @State sustainedReliable: boolean = false
  @State sustainedResultText: string = ''
  private sustainedLastBytes: number = 0
  private sustainedLastPollAt: number = 0
  private sustainedDownloadStartedAtMs: number = -1
  private sustainedUploadStartedAtMs: number = -1
  @State isShowMenu: boolean = false
  //网络测速半模拟态web控制器
  controller: webview.WebviewController = new webview.WebviewController();
  private officialSpeedEpoch: number = 0
  private officialSpeedTarget?: ProxyItem
  private officialSpeedGroup: string = ''
  private officialPreviousProxy: string = ''
  private officialSpeedRestored: boolean = true
  private officialEngineRunning: boolean = false
  private officialRouteVerified: boolean = false
  /* 是否开启 `Index` 页面的前景模糊 */
  @Consume('isEnableIndexForegroundBlur') isEnableIndexForegroundBlur: boolean
  // 是否需要改变排列顺序
  @StorageLink('SortChange') @Watch('onSortChange') needChangeSort: boolean = false
  @StorageLink('nodeQualitySortRevision') @Watch('onNodeQualitySortRevision') nodeQualitySortRevision: number = 0
  /* 代理节点数据相关参数  */
  // 节点数据组
  @Prop @Watch('applySort') proxyitems: ProxyItem[]
  private stopBatchListener?: () => void
  // 代理分组序号[0 ~ +∞]
  @Prop proxyGroup: number
  // 代理数据(懒加载)
  @Consume proxyGroups: ProxyGroupItemDataSource
  @State proxyLazyItems: ProxyItemDataSource = new ProxyItemDataSource()
  private selectionRunning: boolean = false
  private pendingSelection?: ProxyItem
  private confirmedSelectedName: string = ''
  private confirmedCurrentName: string = ''
  private confirmedItem?: ProxyItem
  @Consume('currentProfile') currentProfile: Profile | null
  // 当前代理节点单选选择的值
  @Prop @Watch('syncSelectedProxy') selectedProxy: string
  // The parent value is persisted asynchronously by the RPC/profile layer.
  // Keep an independent render value so the radio follows the finger before
  // that round trip completes.  External profile changes still synchronize
  // through syncSelectedProxy when no local selection is in flight.
  @State selectedNodeName: string = ''
  @Prop disabled: boolean
  // 宽度断点
  @StorageLink ('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1
  // 高度断点
  @StorageLink ('currentHeightBreakpoint') heightBp: HeightBreakpoint = 0
  @StorageLink('favoriteProxys') favoriteProxys: Map<string, string> = new Map<string, string>([])
  @StorageLink('appConfig') appConfig: AppConfig = new AppConfig()
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  // 收藏显示判定
  @Consume showStart:boolean
  // 代理页延迟按钮气泡提示
  @Consume isShowDelayPop: boolean
  // 列表滚动判断
  @Consume isRolling: boolean
  // px外屏隐藏top和tab偏移
  @Consume curOffsetRemain: number
  // px外屏
  @Consume isPXSecScreen: boolean
  /**
   * XXX 当前手指触摸的ListItem的对应 `this.configList` 中的 `configId`
   *    List的长按菜单中的响应都是根据这个的对象中的属性来处理的，是个不稳定因素
   */
  public static currentTouchProxyData: ProxyItem = {
    name: '',
    latency: 0,
    type: '',
    id: '',
    g: '',
    isShowFavoriteProxy: false
  }

  build() {
    List({ space: 10, initialIndex: 0 }) {
      LazyForEach(this.proxyLazyItems, (item: ProxyItem, index: number) => {
        ListItem() {
          ProxyNode({
            item: item,
            disabled: this.disabled,
            selected: this.selectedNodeName,
            selectProxy: (p: ProxyItem) => {
              this.selectProxy(p)
            },
            onLatencyChange:(p:number) =>{
              item.latency = p
              // hilog.info(0xFF00, "ProxyPageLatencyTag", "延迟运行3 延迟更新为%{public}d", p)
              // const nodeItem = this.theProxyGroups[this.proxyGroup]
              // nodeItem.proxies[index].latency = p
              // this.theProxyGroups.splice(this.proxyGroup, 1, nodeItem)
              // hilog.info(0xFF00, "ProxyPageLatencyTag", "延迟运行3 %{public}s", JSON.stringify(nodeItem))
            }
          })
            .restoreId(this.getRestoreId(index, `${item.g}|${item.name}`))
        }
        .transition(customAnimationUtil.isScaleTranFast(index, this.uiConfig))
        .ListItemStyle()
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .height(LIST_ITEM_HEIGHT + 16 + (this.ProxyGroupItemSelected === ProxyCardSize.Small ? 32 : 0))
        .bindContextMenu(this.isShowMenu && this.currentTouchIndex == index , this.isPXSecScreen ? null : this.MyMenu(item),
          {
            preview: MenuPreviewMode.IMAGE,
            placement: Placement.BottomRight,
            aboutToAppear: () => {
              // js 闭包 在函数里只能拿到最后一个item的值
              // ProxyGroupItem.currentTouchProxyData = item
              if (this.uiConfig.isVibrate) {
                customVibrator.vibratorTriggerOfHapticClockTimer()
              }
            },
            previewAnimationOptions: {
              scale: [1.0, 1.1],
              transition: this.uiConfig.isAnimation ? TransitionEffect.prototype.animation({ tempo: 1.5 }) : undefined
            },
            aboutToDisappear: () => {
              this.isShowMenu = false
            }
          })
        .onMouse((event) => {
          if (event.button == MouseButton.Right) {
            this.currentTouchIndex = index
            ProxyGroupItem.currentTouchProxyData = this.snapshotProxyItem(item)
            this.isShowMenu = true
          }
        })
        .gesture(LongPressGesture()
          .onAction(() => {
            this.currentTouchIndex = index
            ProxyGroupItem.currentTouchProxyData = this.snapshotProxyItem(item)
            this.isShowMenu = true
          }))
        .bindPopup((this.uiConfig.ShowProxyPop && this.proxyGroup === 0 && index === 0 && this.tabCurrentPage === 1), {
          builder: PopupBuilder(this, PopTips[2], () => {
            this.uiConfig.ShowProxyPop = false
            this.isShowDelayPop = true
          }),
          onWillDismiss: false,
          autoCancel: false
        })
      }, (item: ProxyItem) => `${item.g}|${item.name}`)
    }.cachedCount(4)
    .onScrollFrameBegin((offset: number) => {
      this.curOffsetRemain += offset
      if (offset > 0) {
        this.isRolling = true
      } else if(offset < 0) {
        this.isRolling = false
        this.curOffsetRemain = 0
      }
      // console.info("offsetRemain:" + offset + '/' +this.curOffsetRemain);
      return { offsetRemain: offset }
    })
    .lanes(this.ProxyGroupItemSelected === ProxyCardSize.Large ? 0 : ProxyListLanes(this.widthBp, this.heightBp), ListGutter(this.widthBp, this.heightBp))
    .ListStyle()
    .nestedScroll({
      scrollForward: this.isPXSecScreen ? NestedScrollMode.SELF_FIRST: NestedScrollMode.PARENT_FIRST,
      scrollBackward: this.isPXSecScreen ? NestedScrollMode.SELF_FIRST:NestedScrollMode.SELF_FIRST
    })
    .contentEndOffset(this.isPXSecScreen ? 65 : this.appConfig.proxyGroupType === ProxyGroupType.List ? 10 : CONTENT_END_OFFSET_150)
    .bindSheet($$this.isShowNetworkSpeed, this.BindSheetNetworkSpeed(), {
       detents: [SheetSize.LARGE],
       preferType: SheetType.CENTER,
       backgroundColor: $r('app.color.settings_container_background'),
       showClose: true,
       scrollSizeMode: ScrollSizeMode.CONTINUOUS,
       title: { title: '网页链路 · Cloudflare', subtitle: this.officialSpeedTarget?.name ?? '' },
       onWillDismiss: () => {
         this.isShowNetworkSpeed = false
         this.isEnableIndexForegroundBlur = false
         void this.restoreAfterOfficialSpeedTest()
       }
     })
    .bindSheet($$this.isShowSustainedSpeed, this.BindSheetSustainedSpeed(), {
      detents: [SheetSize.LARGE],
      preferType: SheetType.CENTER,
      backgroundColor: $r('app.color.settings_container_background'),
      showClose: !this.sustainedRunning,
      scrollSizeMode: ScrollSizeMode.CONTINUOUS,
      onWillDismiss: () => {
        if (this.sustainedRunning) void ClashViewModel.socketProxy.cancelNodeQuality()
        this.isShowSustainedSpeed = false
        this.isEnableIndexForegroundBlur = false
      }
    })
  }

  /** 速度与延迟区别弹窗 */
  ProxyDialogController: CustomDialogController | null = new CustomDialogController({
    builder: ProxyCustomDialog({
      cancel: () => {
        this.onCancel()
      },
      confirm: () => {
        this.onAccept()
      },
    }),
    alignment: DialogAlignment.Center,
    customStyle: false,
    cornerRadius: 32,
    gridCount: 4,
    cancel: this.existApp,
    autoCancel: true,
    onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
      console.info("reason=" + JSON.stringify(dismissDialogAction.reason))
      console.log("dialog onWillDismiss")
      if (dismissDialogAction.reason == DismissReason.PRESS_BACK) {
        dismissDialogAction.dismiss()
        this.isEnableIndexForegroundBlur = false
      }
      if (dismissDialogAction.reason == DismissReason.TOUCH_OUTSIDE) {
        dismissDialogAction.dismiss()
        this.isEnableIndexForegroundBlur = false
      }
    },
  })

  async aboutToAppear(): Promise<void> {
    this.syncSelectedProxy()
    this.applySort()
    this.stopBatchListener = EventHub.on(EventKey.NodeDelayBatchComplete, (): void => {
      // A daily run stages delay values and commits them together with the
      // final quality results.  Sorting here would otherwise expose a
      // half-completed run when the page is recreated in the foreground.
      if (AppStorage.get<boolean>('nodeQualityTestRunning') === true) return
      if (this.appConfig.proxySort === ProxySort.Delay || this.appConfig.proxySort === ProxySort.Experience) {
        this.applySort()
      }
    }, false)
  }

  private syncSelectedProxy(): void {
    // Do not let a parent rebuild carrying the previous persisted value erase
    // an optimistic selection while its RPC is still being processed.
    if (this.selectionRunning || this.pendingSelection) return
    this.selectedNodeName = this.selectedProxy ?? ''
    this.confirmedSelectedName = this.selectedNodeName
    this.confirmedCurrentName = this.selectedNodeName
  }

  aboutToDisappear(): void {
    this.stopBatchListener?.()
    void this.restoreAfterOfficialSpeedTest()
  }

  onSortChange() {
    if (!this.needChangeSort) return
    this.applySort()
    this.needChangeSort = false
  }

  /** 日常体验测试完成后由 ViewModel 发布单调递增版本号，页面重建也能补做排序。 */
  onNodeQualitySortRevision(): void {
    if (this.appConfig.proxySort === ProxySort.Experience) this.applySort()
  }

  applySort(): void {
    if (!this.proxyitems) {
      console.error(`ProxySort 节点数据不存在`)
      return
    }
    if (this.appConfig.proxySort == ProxySort.Default) {
      this.proxyLazyItems.DefaultSortItems(this.proxyitems)
    } else if (this.appConfig.proxySort == ProxySort.Title) {
      this.proxyLazyItems.NameSortItems(this.proxyitems)
    } else if (this.appConfig.proxySort == ProxySort.Delay) {
      this.proxyLazyItems.LatencySortItems(this.proxyitems)
      hilog.info(0xFF00, "ProxySort ProxyPageLatencyTag", "延迟排序成功 %{public}s", this.appConfig.proxySort)
    } else if (this.appConfig.proxySort == ProxySort.Experience) {
      this.proxyLazyItems.ExperienceSortItems(this.proxyitems)
      hilog.info(0xFF00, 'ProxySort ProxyPageExperienceTag', '日常体验推荐排序成功')
    }
    console.log(`ProxySort 排序类型：${this.appConfig.proxySort}, 节点数量：${this.proxyLazyItems.totalCount()}个`)
  }

  /** 将 字符串ID 转换为 HashID 用于 restoreId */
  getRestoreId(index: number, id?: string): number {
    if (id) {
      let hash = 0;
      for (let i = 0; i < id.length; i++) {
        const char = id.charCodeAt(i);
        hash = ((hash << 5) - hash) + char;
        hash |= 0; // Convert to 32bit integer
      }

      return hash;
    }

    return index
  }

  /**
   * 半模态窗口测速网站
   */
  @Builder
  BindSheetNetworkSpeed() {
    Row() {
      Column() {
        Web({ src: $rawfile('speedtest/cloudflare_runner.html'), controller: this.controller })
          .javaScriptAccess(true)
          .onlineImageAccess(true)
          .imageAccess(true)
          .domStorageAccess(true)
          .onPageEnd(() => {
            void this.runOfficialSpeedEngine()
          })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Center)
    //   .padding({bottom:100})
    .backgroundColor(($r('app.color.container_background')))
  }

  @Builder
  BindSheetSustainedSpeed() {
    Scroll() {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 3 }) {
            Text('节点测速')
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
            Text(this.sustainedNodeName)
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Row({ space: 6 }) {
            Text('')
              .width(7)
              .height(7)
              .borderRadius(4)
              .backgroundColor(this.sustainedRunning ? '#6F5FF2' :
                (this.sustainedFinished ? '#57D8A3' : '#AAB2C8'))
            Text(this.sustainedRunning ? '测速中' : (this.sustainedFinished ? '已完成' : '准备'))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
          }
          .padding({ left: 11, right: 11, top: 6, bottom: 6 })
          .borderRadius(16)
          .backgroundColor($r('app.color.container_background'))
        }
        .width('100%')

        Column({ space: 12 }) {
          Row() {
            Text(this.sustainedModeName)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#D8D4FF')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(14)
              .backgroundColor('#343052')
            Blank()
            Text(`${this.sustainedElapsedSeconds}s`)
              .fontSize(13)
              .fontColor('#B7BED1')
          }
          .width('100%')

          Row({ space: 8 }) {
            Text('')
              .width(8)
              .height(8)
              .borderRadius(4)
              .backgroundColor(this.sustainedFinished ?
                (this.sustainedReliable ? '#75E4B3' : '#FFC866') : '#9B8CFF')
            Text(this.sustainedPhase)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.sustainedFinished ?
                (this.sustainedReliable ? '#75E4B3' : '#FFC866') : '#B9AFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')

          Row() {
            Text(this.sustainedCurrentMbps.toFixed(2))
              .minFontSize(34)
              .maxFontSize(48)
              .maxLines(1)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text('Mbps')
              .fontSize(15)
              .fontColor('#AAB2C8')
              .alignSelf(ItemAlign.End)
              .margin({ bottom: 10, left: 8 })
          }
          .width('100%')
          Text(this.sustainedFinished ? '最终上传平均' :
            (this.sustainedDirection === 'upload' ? '实时上传' :
              (this.sustainedDirection === 'download' ? '实时下载' : '正在建立测速链路')))
            .fontSize(12)
            .fontColor('#8D96AA')
            .width('100%')

          // 上下行分开使用独立量程，避免下载峰值较高时把上传曲线压扁，
          // 也避免两条不同阶段的曲线叠加后难以辨认。
          this.SustainedDirectionChart(false, '#9B8CFF', '#211F36')
          this.SustainedDirectionChart(true, '#39C6F4', '#102A36')

          Row() {
            Text(`流量  ${this.formatPeakTraffic(this.sustainedTrafficBytes)}`)
              .fontSize(11).fontColor('#AAB2C8')
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(12).backgroundColor('#22283A')
            Blank()
            Text(`↓${this.sustainedDownloadSamples} · ↑${this.sustainedUploadSamples} 个样本`)
              .fontSize(11).fontColor('#AAB2C8')
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(12).backgroundColor('#22283A')
          }
          .width('100%')
        }
        .width('100%')
        .padding(20)
        .borderRadius(28)
        .linearGradient({ angle: 145, colors: [['#24213D', 0], ['#151B2B', 0.55], ['#101522', 1]] })
        .shadow({ radius: 22, color: '#24000000', offsetY: 8 })

        Column({ space: 8 }) {
          Row() {
            Text('测试点').fontSize(12).fontColor($r('sys.color.font_secondary'))
            Blank()
            Text(this.sustainedTargetName || '正在选择')
              .fontSize(12)
              .fontColor($r('sys.color.font_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.End)
              .constraintSize({ maxWidth: '72%' })
          }.width('100%')
          if (this.sustainedFinished && this.sustainedResultText) {
            Text(this.sustainedResultText)
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .borderRadius(16)
        .backgroundColor($r('app.color.container_background'))

        Button(this.sustainedRunning ? '停止测速' : '完成')
          .width('100%')
          .height(52)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.sustainedRunning ? '#FF6573' : '#FFFFFF')
          .backgroundColor(this.sustainedRunning ? '#FFF7F8' : '#6757E8')
          .border({ width: this.sustainedRunning ? 1 : 0, color: '#FF8792' })
          .borderRadius(26)
          .onClick(() => void this.stopSustainedSpeed())

        Text('完整载荷 · 实际耗时 · 同一测试点公平比较')
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 6, bottom: 24 })
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SustainedDirectionChart(upload: boolean, color: ResourceColor, surface: ResourceColor) {
    Column({ space: 8 }) {
      Row() {
        Row({ space: 7 }) {
          Text('')
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(color)
          Text(upload ? '上传速度' : '下载速度')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
        }
        Blank()
        Row() {
        Text((upload ? this.sustainedUploadMbps : this.sustainedDownloadMbps).toFixed(2))
            .minFontSize(18)
            .maxFontSize(25)
          .maxLines(1)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          Text(' Mbps')
            .fontSize(10)
            .fontColor('#9EA7BA')
            .alignSelf(ItemAlign.End)
            .margin({ bottom: 4 })
        }
      }
      .width('100%')

      Row() {
        Text(this.sustainedDirectionStatus(upload))
          .fontSize(11)
          .fontColor(this.sustainedDirectionActive(upload) ? color : '#8D96AA')
        Blank()
        Text(`峰值 ${this.sustainedDirectionMaximum(upload).toFixed(1)} Mbps · ` +
          `${upload ? this.sustainedUploadSamples : this.sustainedDownloadSamples} 个样本`)
          .fontSize(10)
          .fontColor('#8D96AA')
      }
      .width('100%')

      Row() {
        Text('速度 (Mbps)')
          .fontSize(9)
          .fontColor('#737E94')
        Blank()
        Text(this.sustainedDirectionActive(upload) ? '曲线随测试进度展开' : '完整测试区间')
          .fontSize(9)
          .fontColor('#737E94')
      }
      .width('100%')

      Row({ space: 6 }) {
        Column() {
          Text(this.sustainedAxisLabel(this.sustainedDirectionAxisMaximum(upload)))
            .fontSize(8).fontColor('#737E94')
          Blank()
          Text(this.sustainedAxisLabel(this.sustainedDirectionAxisMaximum(upload) * 2 / 3))
            .fontSize(8).fontColor('#737E94')
          Blank()
          Text(this.sustainedAxisLabel(this.sustainedDirectionAxisMaximum(upload) / 3))
            .fontSize(8).fontColor('#737E94')
          Blank()
          Text('0')
            .fontSize(8).fontColor('#737E94')
        }
        .width(36)
        .height(92)
        .alignItems(HorizontalAlign.End)

        Stack() {
          Line({ width: 252, height: 92 })
            .startPoint([0, 1]).endPoint([252, 1]).stroke('#30374D').strokeWidth(1)
          Line({ width: 252, height: 92 })
            .startPoint([0, 31]).endPoint([252, 31]).stroke('#30374D').strokeWidth(1)
          Line({ width: 252, height: 92 })
            .startPoint([0, 61]).endPoint([252, 61]).stroke('#30374D').strokeWidth(1)
          Line({ width: 252, height: 92 })
            .startPoint([0, 91]).endPoint([252, 91]).stroke('#30374D').strokeWidth(1)
          Polyline({ width: 252, height: 92 })
            .points(this.sustainedChartPoints(upload ? this.sustainedUploadPoints :
              this.sustainedDownloadPoints, upload ? this.sustainedUploadTimes :
              this.sustainedDownloadTimes, 252, 92, this.sustainedDirectionAxisMaximum(upload), upload))
            .fillOpacity(0)
            .stroke(upload ? '#2639C6F4' : '#269B8CFF')
            .strokeWidth(8)
            .strokeLineCap(LineCapStyle.Round)
            .strokeLineJoin(LineJoinStyle.Round)
          Polyline({ width: 252, height: 92 })
            .points(this.sustainedChartPoints(upload ? this.sustainedUploadPoints :
              this.sustainedDownloadPoints, upload ? this.sustainedUploadTimes :
              this.sustainedDownloadTimes, 252, 92, this.sustainedDirectionAxisMaximum(upload), upload))
            .fillOpacity(0)
            .stroke(color)
            .strokeWidth(3)
            .strokeLineCap(LineCapStyle.Round)
            .strokeLineJoin(LineJoinStyle.Round)
        }
        .width(252)
        .height(92)
      }
      .width('100%')

      Row() {
        Blank().width(42)
        Text('0s').fontSize(8).fontColor('#737E94')
        Blank()
        Text(this.sustainedDirectionTimelineLabel(upload))
          .fontSize(8)
          .fontColor('#737E94')
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 10 })
    .borderRadius(18)
    .backgroundColor(surface)
    .border({
      width: this.sustainedDirectionActive(upload) ? 1 : 0,
      color: this.sustainedDirectionActive(upload) ? color : Color.Transparent
    })
  }

  private sustainedDirectionMaximum(upload: boolean): number {
    const values = upload ? this.sustainedUploadPoints : this.sustainedDownloadPoints
    let maximum = upload ? this.sustainedUploadMbps : this.sustainedDownloadMbps
    maximum = Math.max(1, maximum)
    values.forEach((value: number): void => { maximum = Math.max(maximum, value) })
    return maximum
  }

  private sustainedDirectionAxisMaximum(upload: boolean): number {
    const paddedMaximum = Math.max(1, this.sustainedDirectionMaximum(upload) * 1.08)
    const roughStep = paddedMaximum / 3
    const magnitude = Math.pow(10, Math.floor(Math.log(roughStep) / Math.log(10)))
    const normalized = roughStep / magnitude
    let niceStep = magnitude
    if (normalized > 5) {
      niceStep = 10 * magnitude
    } else if (normalized > 2.5) {
      niceStep = 5 * magnitude
    } else if (normalized > 2) {
      niceStep = 2.5 * magnitude
    } else if (normalized > 1) {
      niceStep = 2 * magnitude
    }
    return Math.max(1, Math.ceil(paddedMaximum / niceStep) * niceStep)
  }

  private sustainedAxisLabel(value: number): string {
    if (value >= 10) return `${Math.round(value)}`
    if (value >= 1) return value.toFixed(1)
    return value.toFixed(2)
  }

  private sustainedDirectionActive(upload: boolean): boolean {
    return this.sustainedRunning && this.sustainedDirection === (upload ? 'upload' : 'download')
  }

  private sustainedDirectionStatus(upload: boolean): string {
    const samples = upload ? this.sustainedUploadSamples : this.sustainedDownloadSamples
    if (this.sustainedDirectionActive(upload)) return upload ? '实时上传采样' : '实时下载采样'
    if (samples > 0) return this.sustainedFinished ? '采样完成' : (upload ? '上传采样完成' : '下载采样完成')
    if (!this.sustainedRunning && this.sustainedFinished) return '本次无有效样本'
    if (upload && this.sustainedDirection !== 'upload') return '等待上传阶段'
    return '正在建立测速链路'
  }

  private sustainedDirectionTimelineSpan(upload: boolean, times: number[]): number {
    const latest = times.length > 0 ? times[times.length - 1] : 0
    // 内核每个方向最多约 1 秒预热 + 5.5 秒正式采样。进行中固定使用
    // 这条时间轴，使曲线只占据已经走过的比例；阶段结束后再用实际耗时
    // 铺满整张图，完整保留本轮从开始到结束的波动形态。
    if (this.sustainedDirectionActive(upload)) return Math.max(6500, latest)
    return Math.max(1, latest)
  }

  private sustainedDirectionTimelineLabel(upload: boolean): string {
    const times = upload ? this.sustainedUploadTimes : this.sustainedDownloadTimes
    if (times.length === 0) return this.sustainedDirectionActive(upload) ? '预计 6.5s' : '阶段结束'
    const span = this.sustainedDirectionTimelineSpan(upload, times)
    return `${this.sustainedDirectionActive(upload) ? '预计 ' : ''}${(span / 1000).toFixed(1)}s`
  }

  private sustainedChartPoints(values: number[], times: number[], width: number, height: number,
    maximum: number, upload: boolean): Array<Array<number>> {
    if (values.length === 0) return []
    const points: Array<Array<number>> = []
    const span = this.sustainedDirectionTimelineSpan(upload, times)
    values.forEach((value: number, index: number): void => {
      const time = index < times.length ? times[index] : 0
      const x = Math.min(width, Math.max(0, time) / span * width)
      const y = height - 3 - Math.max(0, value) / maximum * (height - 8)
      points.push([x, y])
    })
    if (points.length === 1) points.push([Math.min(width, 1), points[0][1]])
    return points
  }
  //半模态网络测速 end

  onCancel() {
    console.info('Callback when the first button is clicked')
  }

  onAccept() {
    console.info('Callback when the second button is clicked')
  }

  existApp() {
    console.info('Click the callback in the blank area')
  }

  OnProxyChange: ((item: ProxyItem) => Promise<boolean>) = async () => {
    return false
  }

  // 长按菜单 start
  @Builder
  // 长按菜单相关
  MyMenu(item: ProxyItem) {
    Menu() {
      // 根据当前配置信息来判断显示[收藏 /取消收藏] 单独处理 START
      if (this.favoriteProxys.has(ProxyGroupItem.currentTouchProxyData.g + '|' + ProxyGroupItem.currentTouchProxyData.name)) {
        MenuItem({
          symbolStartIcon: this.proxyListLongPressCtxMenuForUnFavorite.symbolStartIcon!
            .fontSize(TAB_CONTENT_TITLE_SYMBOL_FONT_SIZE),
          content: this.proxyListLongPressCtxMenuForUnFavorite.content
        })
          .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
          .contentFontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.proxyListLongPressCtxMenuForUnFavorite.callback()
          })
      } else {
        MenuItem({
          symbolStartIcon: this.proxyListLongPressCtxMenuForFavorite.symbolStartIcon!
            .fontSize(TAB_CONTENT_TITLE_SYMBOL_FONT_SIZE),
          content: this.proxyListLongPressCtxMenuForFavorite.content
        })
          .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
          .contentFontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.proxyListLongPressCtxMenuForFavorite.callback()
          })
      }
      // The shipped core has one shared RPC implementation for single/batch tests.
      MenuItem({ symbolStartIcon: startIconModifier1, content: $r('app.string.Test_Delay') })
        .onClick(async () => {
          const target = ProxyGroupItem.currentTouchProxyData
          await ClashViewModel.testDelay(target.name)
          const result = ClashViewModel.delayMap.get(target.name) ?? emptyNodeDelay(target.name)
          Xb_ToastUtil.showToast({ message: nodeDelayText(result), duration: 3000 })
        })
      MenuItem({ symbolStartIcon: startIconModifier3, content: '节点检测详情' })
        .onClick(() => this.showNodeDiagnostics(ProxyGroupItem.currentTouchProxyData))
      MenuItem({ symbolStartIcon: qualityIconModifier, content: '单连接 · 大文件持续测速' })
        .onClick(() => this.confirmPeakBandwidthTest(ProxyGroupItem.currentTouchProxyData, false))
      MenuItem({ symbolStartIcon: startIconModifier2, content: '多连接 · 大文件持续测速' })
        .onClick(() => this.confirmPeakBandwidthTest(ProxyGroupItem.currentTouchProxyData, true))
      // 暂时先屏蔽网站测速功能
      /* MenuItem({ symbolStartIcon: startIconModifier2, content: $r('app.string.Test_Speed') })
         .onClick(() => {
           this.isShowNetworkSpeed = true
           this.isEnableIndexForegroundBlur = true
         })

      MenuItem({ symbolStartIcon: startIconModifier3, content: $r('app.string.Delay_Speed') })
        .onClick(() => {
          if (this.ProxyDialogController != null) {
            this.ProxyDialogController.open()
            this.isEnableIndexForegroundBlur = true
          }
        })*/
    }
    //分割线
    .menuItemDivider({ color: $r('app.color.divider'), strokeWidth: LengthMetrics.vp(1) })
    .backgroundColor($r('app.color.container_background'))
    .borderRadius(BORDER_RADIUS_20)
    .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
  } // 长按菜单end

  private showNodeDiagnostics(item: ProxyItem): void {
    const target = this.snapshotProxyItem(item)
    const delay = ClashViewModel.delayMap.get(target.name) ?? emptyNodeDelay(target.name)
    const quality = ClashViewModel.getNodeQualityResult(this.currentProfile, target.g ?? '', target.name)
    const history = ClashViewModel.getNodeQualityHistorySummary(this.currentProfile,
      target.g ?? '', target.name)
    const lines: string[] = [
      `节点：${target.name}`,
      `协议：${target.type}${target.network ? ` / ${target.network}` : ''}`,
      `可达性：${nodeDelayText(delay)}`
    ]
    if (delay.checkedAt > 0) lines.push(`检测时间：${this.diagnosticTime(delay.checkedAt)}`)
    if (delay.source) lines.push(`检测通道：${delay.source}`)
    if (delay.fallbackUsed) {
      lines.push(`主源：${nodeDelayErrorText(delay.primaryErrorCode)}`)
      lines.push(`备用源：${delay.status === 'ok' ? '成功' : nodeDelayErrorText(delay.fallbackErrorCode)}`)
    }
    lines.push(`初步判断：${this.delayConclusion(delay)}`)
    if (quality) {
      lines.push(`真实传输：${nodeQualityBrief(quality)}`)
      if (quality.checkedAt > 0) lines.push(`传输检测：${this.diagnosticTime(quality.checkedAt)}`)
      if (quality.diagnostic) {
        const compact = quality.diagnostic.replace(/\n/g, ' / ')
        lines.push(`测速源记录：${compact.substring(0, 240)}`)
      }
    } else {
      lines.push('真实传输：本轮尚未检测')
    }
    if (history.sampleCount > 0) {
      lines.push(`7天历史：${history.successfulSamples}/${history.sampleCount}次成功 · ` +
        `成功率${history.successRate}% · 可靠率${history.reliableRate}%`)
      if (history.medianDownloadMbps > 0 || history.medianUploadMbps > 0) {
        lines.push(`历史中位速度：↓${history.medianDownloadMbps} ↑${history.medianUploadMbps} Mbps`)
      }
      if (history.averageExperienceScore > 0) {
        lines.push(`历史平均体验：${history.averageExperienceScore}分`)
      }
    } else {
      lines.push('7天历史：暂无完整测速记录')
    }
    Xb_ToastUtil.showAlertDialog({
      title: '节点检测详情',
      message: lines.join('\n'),
      primaryButton: { value: '关闭', action: () => {} },
      secondaryButton: {
        value: '重测可达性',
        action: () => void this.retestNodeDiagnostics(target)
      }
    })
  }

  private async retestNodeDiagnostics(item: ProxyItem): Promise<void> {
    if (!ClashViewModel.vpnStarted) {
      Xb_ToastUtil.showToast({ message: '请先启动VPN' })
      return
    }
    await ClashViewModel.testDelay(item.name)
    this.showNodeDiagnostics(item)
  }

  private diagnosticTime(timestamp: number): string {
    const time = new Date(timestamp)
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`
    return `${time.getMonth() + 1}-${pad(time.getDate())} ${pad(time.getHours())}:${pad(time.getMinutes())}:${pad(time.getSeconds())}`
  }

  private delayConclusion(result: NodeDelayResult): string {
    if (result.status === 'ok' && result.fallbackUsed) return '节点可用，主测速源与该节点不兼容'
    if (result.status === 'ok') return '节点入口和测速目标均可达'
    if (result.status !== 'failed') return '等待执行可达性检测'
    if (result.fallbackUsed) return '两个独立测速源均失败，更可能是节点入口或出口链路异常'
    return '单源检测失败，建议重测以执行双源复核'
  }

  async selectProxy(item: ProxyItem): Promise<void> {
    if (this.disabled || AppStorage.get<boolean>('nodeQualityTestRunning') === true) return
    // Resolve by the immutable node name against the current data source.  A
    // delayed touch can arrive after a LazyForEach sort/reload; using the
    // object captured by the old card would then switch the node that occupied
    // that slot before the touch was dispatched.
    const liveItem = this.resolveLiveProxy(item)
    if (!liveItem) {
      hilog.warn(0xFF00, 'ProxyPageGroupTag', '忽略已失效的节点点击：%{public}s', item.name)
      return
    }
    if (!this.selectionRunning) {
      this.confirmedSelectedName = this.selectedNodeName
      this.confirmedCurrentName = this.appConfig.currentProxyName ?? ''
      this.confirmedItem = this.appConfig.currentProxyItem
    }
    const target = this.snapshotProxyItem(liveItem)
    this.pendingSelection = target
    // Update the radio immediately. Profile.proxySelected is a nested Map and
    // mutating it after the RPC does not itself invalidate ArkUI @Prop values.
    this.selectedNodeName = target.name
    this.appConfig.currentProxyName = target.name
    this.appConfig.currentProxyItem = target
    await this.drainProxySelection()
  }

  /** Serialize rapid taps so the last card tapped is also the last RPC applied. */
  private async drainProxySelection(): Promise<void> {
    if (this.selectionRunning) return
    this.selectionRunning = true
    try {
      while (this.pendingSelection) {
        const target = this.pendingSelection
        this.pendingSelection = undefined
        const switched = await this.OnProxyChange(target)
        if (switched) {
          this.confirmedSelectedName = target.name
          this.confirmedCurrentName = target.name
          this.confirmedItem = target
          cardManager.pushCartCurrentProxyName(target.name)
        } else if (!this.pendingSelection) {
          this.selectedNodeName = this.confirmedSelectedName
          this.appConfig.currentProxyName = this.confirmedCurrentName
          this.appConfig.currentProxyItem = this.confirmedItem
        }
      }
    } finally {
      this.selectionRunning = false
    }
  }

  private snapshotProxyItem(item: ProxyItem): ProxyItem {
    return {
      name: item.name,
      latency: item.latency,
      type: item.type,
      network: item.network,
      udp: item.udp,
      id: item.id,
      g: item.g,
      isShowFavoriteProxy: item.isShowFavoriteProxy
    }
  }

  private confirmOfficialSpeedTest(item: ProxyItem): void {
    if (!ClashViewModel.vpnStarted) {
      Xb_ToastUtil.showToast({ message: '请先启动VPN' })
      return
    }
    if (AppStorage.get<boolean>('nodeQualityTestRunning') === true) {
      Xb_ToastUtil.showToast({ message: '已有节点质量测试正在运行' })
      return
    }
    const profile = this.currentProfile
    const group = this.proxyGroups.getData(this.proxyGroup)
    if (!profile || !group) {
      Xb_ToastUtil.showToast({ message: '节点信息尚未加载完成' })
      return
    }
    Xb_ToastUtil.showAlertDialog({
      title: '网页链路 · Cloudflare',
      message: `节点：${item.name}\n` +
        '直接运行 Cloudflare 官方开源测速引擎，逐级放大完整样本并输出 P90。\n' +
        '测试期间会临时切换当前分组到该节点，结束或关闭测速页后自动恢复；流量按实际链路速度决定。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '开始官方精测',
        action: async () => {
          try {
            await this.prepareOfficialSpeedTest(profile, group, item)
          } catch (error) {
            await this.restoreAfterOfficialSpeedTest()
            Xb_ToastUtil.showToast({ message: (error as Error).message || '官方测速启动失败', duration: 3000 })
          }
        }
      }
    })
  }

  private confirmPeakBandwidthTest(item: ProxyItem, multi: boolean = true): void {
    if (!ClashViewModel.vpnStarted) {
      Xb_ToastUtil.showToast({ message: '请先启动VPN' })
      return
    }
    if (AppStorage.get<boolean>('nodeQualityTestRunning') === true) {
      Xb_ToastUtil.showToast({ message: '已有节点质量测试正在运行' })
      return
    }
    const profile = this.currentProfile
    const group = this.proxyGroups.getData(this.proxyGroup)
    if (!profile || !group) {
      Xb_ToastUtil.showToast({ message: '节点信息尚未加载完成' })
      return
    }
    const target = this.snapshotProxyItem(item)
    Xb_ToastUtil.showAlertDialog({
      title: multi ? '多连接持续测速' : '单连接持续测速',
      message: `节点：${target.name}\n` +
        `${multi ? '8个连接' : '1个连接'}经指定节点到固定测速服务器（30分钟内所有节点复用同一测试点）；上下行短暂预热后，各持续采样约4–5.5秒。\n` +
        '按完整载荷与实际耗时计算平均吞吐并检查波动。通常约10–15秒；首次使用需发现并验证服务器，会额外多几秒。高速节点可能消耗数百MB，请勿切换网络或配置。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '开始持续测速',
        action: () => {
          const mode: NodeQualityMode = multi ? 'bandwidth_multi_sustained' : 'bandwidth_single_sustained'
          this.openSustainedSpeedPanel(profile, group, target, mode)
        }
      }
    })
  }

  private openSustainedSpeedPanel(profile: Profile, group: ProxyGroup, target: ProxyItem,
    mode: NodeQualityMode): void {
    this.sustainedNodeName = target.name
    this.sustainedModeName = mode === 'bandwidth_multi_sustained' ? '多连接 · 8 路' : '单连接 · 1 路'
    this.sustainedPhase = '选择并验证测速服务器'
    this.sustainedDirection = ''
    this.sustainedCurrentMbps = 0
    this.sustainedDownloadMbps = 0
    this.sustainedUploadMbps = 0
    this.sustainedTrafficBytes = 0
    this.sustainedElapsedSeconds = 0
    this.sustainedDownloadSamples = 0
    this.sustainedUploadSamples = 0
    this.sustainedTargetName = ''
    this.sustainedDownloadPoints = []
    this.sustainedUploadPoints = []
    this.sustainedDownloadTimes = []
    this.sustainedUploadTimes = []
    this.sustainedResultText = ''
    this.sustainedFinished = false
    this.sustainedReliable = false
    this.sustainedRunning = true
    this.sustainedLastBytes = 0
    this.sustainedLastPollAt = Date.now()
    this.sustainedDownloadStartedAtMs = -1
    this.sustainedUploadStartedAtMs = -1
    this.isEnableIndexForegroundBlur = true
    this.isShowSustainedSpeed = true
    void this.runSustainedSpeedPanel(profile, group, target, mode)
  }

  private async runSustainedSpeedPanel(profile: Profile, group: ProxyGroup, target: ProxyItem,
    mode: NodeQualityMode): Promise<void> {
    let settled = false
    let failedMessage: string = ''
    const task = ClashViewModel.testNodeBandwidth(profile, group, target, mode)
      .then((result): void => {
        this.applySustainedFinalResult(result)
      })
      .catch((error: Error): void => { failedMessage = error.message || '内核测速异常' })
      .finally((): void => { settled = true })
    while (!settled) {
      await this.speedTestDelay(700)
      try {
        const progress = await ClashViewModel.socketProxy.nodeQualityProgress()
        if (settled) break
        const now = Date.now()
        const elapsed = Math.max(1, now - this.sustainedLastPollAt)
        const bytes = Math.max(0, progress.transferredBytes - this.sustainedLastBytes)
        const liveMbps = Math.round(bytes * 8 / elapsed / 1000 * 100) / 100
        this.sustainedLastBytes = progress.transferredBytes
        this.sustainedLastPollAt = now
        this.sustainedCurrentMbps = liveMbps
        this.sustainedTrafficBytes = progress.transferredBytes
        this.sustainedElapsedSeconds = Math.round(progress.elapsedMs / 1000)
        this.sustainedDownloadSamples = progress.downloadSamples
        this.sustainedUploadSamples = progress.uploadSamples
        this.sustainedTargetName = progress.target
        this.sustainedDirection = progress.direction
        this.sustainedPhase = this.sustainedPhaseText(progress.phase, progress.direction)
        if (progress.phase === 'warmup' || progress.phase === 'measure') {
          this.appendSustainedPoint(progress.direction, liveMbps, progress.elapsedMs)
          if (progress.direction === 'download') {
            this.sustainedDownloadMbps = progress.averageMbps > 0 ? progress.averageMbps : liveMbps
          } else if (progress.direction === 'upload') {
            this.sustainedUploadMbps = progress.averageMbps > 0 ? progress.averageMbps : liveMbps
          }
        }
      } catch (_) {
      }
    }
    await task
    try {
      const finalProgress = await ClashViewModel.socketProxy.nodeQualityProgress()
      this.sustainedDownloadSamples = finalProgress.downloadSamples
      this.sustainedUploadSamples = finalProgress.uploadSamples
      this.sustainedElapsedSeconds = Math.round(finalProgress.elapsedMs / 1000)
      if (finalProgress.target) this.sustainedTargetName = finalProgress.target
    } catch (_) {
    }
    this.sustainedRunning = false
    this.sustainedFinished = true
    if (failedMessage) {
      this.sustainedPhase = '测速异常'
      this.sustainedResultText = failedMessage
    }
  }

  private applySustainedFinalResult(result: NodeQualityResult): void {
    this.sustainedReliable = result.status === 'ok' && result.reliable === true
    this.sustainedDownloadMbps = result.downloadMbps
    this.sustainedUploadMbps = result.uploadMbps
    this.sustainedCurrentMbps = result.uploadMbps
    this.sustainedDirection = 'upload'
    this.sustainedTrafficBytes = result.transferredBytes
    this.sustainedPhase = result.status === 'ok' ?
      (result.reliable ? '测速完成 · 样本稳定' : '测速完成 · 波动较大') : '测速未完成'
    this.sustainedResultText = result.status === 'ok' ?
      (result.reliable ? '本次样本稳定，可用于同网络环境下比较节点。' : '本次波动较大，建议网络空闲时复测。') :
      `${result.errorMessage}\n${result.diagnostic ?? ''}`
  }

  private sustainedPhaseText(phase: string, direction: string): string {
    if (phase === 'server') return '选择并验证测速服务器'
    if (phase === 'cancelling') return '正在停止测速'
    const label = direction === 'upload' ? '上传' : '下载'
    if (phase === 'warmup') return `${label}预热 · 正在放大样本`
    if (phase === 'measure') return `${label}持续采样`
    return '整理测速结果'
  }

  private appendSustainedPoint(direction: string, value: number, elapsedMs: number): void {
    const point = Math.max(0, Math.min(9999, value))
    const safeElapsed = Math.max(0, elapsedMs)
    if (direction === 'upload') {
      if (this.sustainedUploadStartedAtMs < 0) this.sustainedUploadStartedAtMs = safeElapsed
      const relativeTime = Math.max(0, safeElapsed - this.sustainedUploadStartedAtMs)
      this.sustainedUploadPoints = this.sustainedUploadPoints.concat([point]).slice(-48)
      this.sustainedUploadTimes = this.sustainedUploadTimes.concat([relativeTime]).slice(-48)
    } else if (direction === 'download') {
      if (this.sustainedDownloadStartedAtMs < 0) this.sustainedDownloadStartedAtMs = safeElapsed
      const relativeTime = Math.max(0, safeElapsed - this.sustainedDownloadStartedAtMs)
      this.sustainedDownloadPoints = this.sustainedDownloadPoints.concat([point]).slice(-48)
      this.sustainedDownloadTimes = this.sustainedDownloadTimes.concat([relativeTime]).slice(-48)
    }
  }

  private async stopSustainedSpeed(): Promise<void> {
    if (!this.sustainedRunning) {
      this.isShowSustainedSpeed = false
      this.isEnableIndexForegroundBlur = false
      return
    }
    this.sustainedPhase = '正在停止测速'
    await ClashViewModel.socketProxy.cancelNodeQuality()
  }

  private formatPeakTraffic(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes <= 0) return '0 MB'
    if (bytes >= 1_000_000_000) return `${(bytes / 1_000_000_000).toFixed(2)} GB`
    return `${(bytes / 1_000_000).toFixed(1)} MB`
  }

  private async prepareOfficialSpeedTest(profile: Profile, group: ProxyGroup, item: ProxyItem): Promise<void> {
    if (AppStorage.get<boolean>('nodeQualityTestRunning') === true) throw new Error('已有测速正在运行')
    AppStorage.setOrCreate('nodeQualityTestRunning', true)
    this.officialSpeedRestored = false
    this.officialSpeedGroup = ''
    this.officialPreviousProxy = ''
    this.officialRouteVerified = false
    await ClashViewModel.waitForAutomaticNetworkChecks()
    if (this.currentProfile?.id !== profile.id) throw new Error('配置已切换，请重新选择节点')
    this.officialSpeedTarget = this.snapshotProxyItem(item)
    const groups = await ClashViewModel.socketProxy.queryProxyGroups(ProxyMode.Global)
    const routingGroupName = this.appConfig.switchMode === ProxyMode.Global ? 'GLOBAL' : group.name
    const runtimeGroup = groups.find((entry: ProxyGroup): boolean => entry.name === routingGroupName)
    if (!runtimeGroup?.now) throw new Error('读取实际节点选择失败，测速尚未开始')
    this.officialSpeedGroup = routingGroupName
    // Restore the live core selection, not a potentially stale UI/profile Map.
    this.officialPreviousProxy = runtimeGroup.now
    await this.closeOfficialSpeedConnections()
    const switchError = await ClashViewModel.socketProxy.changeProxy(routingGroupName, item.name)
    if (switchError) throw new Error(switchError)
    await this.applyOfficialWebProxy()
    this.officialSpeedEpoch++
    this.isEnableIndexForegroundBlur = true
    this.isShowNetworkSpeed = true
  }

  private applyOfficialWebProxy(): Promise<void> {
    const config = AppStorage.get<ClashConfig>('clashConfig')
    const mixedPort = Number(config?.['mixed-port'] ?? 7890)
    if (!Number.isFinite(mixedPort) || mixedPort <= 0) throw new Error('本地代理端口无效')
    return new Promise<void>((resolve, reject) => {
      try {
        const proxyConfig = new webview.ProxyConfig()
        proxyConfig.insertProxyRule(`http://127.0.0.1:${mixedPort}`, webview.ProxySchemeFilter.MATCH_ALL_SCHEMES)
        webview.ProxyController.applyProxyOverride(proxyConfig, (): void => resolve())
      } catch (error) {
        reject(error as Error)
      }
    })
  }

  private async runOfficialSpeedEngine(): Promise<void> {
    if (this.officialEngineRunning) return
    this.officialEngineRunning = true
    const epoch = this.officialSpeedEpoch
    try {
      let ready = false
      for (let index = 0; index < 30 && epoch === this.officialSpeedEpoch; index++) {
        const value = await this.controller.runJavaScript('typeof window.fireflyStartSpeedTest === "function"')
        if (value === 'true' || value === '"true"') {
          ready = true
          break
        }
        await this.speedTestDelay(200)
      }
      if (!ready) throw new Error('Cloudflare 测速引擎加载超时')
      await this.controller.runJavaScript('window.fireflyStartSpeedTest()')
      for (let index = 0; index < 360 && epoch === this.officialSpeedEpoch; index++) {
        await this.speedTestDelay(1000)
        const raw = await this.controller.runJavaScript('window.fireflyReadSpeedTest()')
        const state = this.parseOfficialSpeedState(raw)
        await this.verifyOfficialSpeedRoute()
        if (state.status === 'done') {
          if (!this.officialRouteVerified) throw new Error('未核实测速流量经过所选节点，本次结果不保存')
          this.saveOfficialSpeedResult(state)
          await this.restoreAfterOfficialSpeedTest()
          return
        }
        if (state.status === 'failed') throw new Error(state.error || 'Cloudflare 官方测速失败')
      }
      if (epoch === this.officialSpeedEpoch) throw new Error('Cloudflare 官方测速超时')
    } catch (error) {
      if (epoch === this.officialSpeedEpoch) {
        const message = (error as Error).message || 'Cloudflare 官方测速失败'
        try {
          await this.controller.runJavaScript(`window.fireflyFailSpeedTest(${JSON.stringify(message)})`)
        } catch (_) {}
        console.error(`[OfficialSpeed] failed: ${message}`)
        Xb_ToastUtil.showToast({ message: message, duration: 3000 })
        await this.restoreAfterOfficialSpeedTest()
      }
    } finally {
      this.officialEngineRunning = false
    }
  }

  private isOfficialSpeedConnection(connection: ConnectionInfo): boolean {
    const metadata = connection.metadata
    return metadata?.host === 'speed.cloudflare.com' &&
      (metadata.sourceIP === '127.0.0.1' || metadata.sourceIP === '::1')
  }

  private async closeOfficialSpeedConnections(): Promise<void> {
    const connections = await ClashViewModel.socketProxy.queryConnections()
    for (const connection of connections) {
      if (this.isOfficialSpeedConnection(connection)) {
        await ClashViewModel.socketProxy.closeConnection(connection.id)
      }
    }
  }

  private resolveLiveProxy(item: ProxyItem): ProxyItem | undefined {
    for (let index = 0; index < this.proxyLazyItems.totalCount(); index++) {
      const candidate = this.proxyLazyItems.getData(index)
      if (candidate && candidate.name === item.name &&
        (candidate.g ?? item.g ?? '') === (item.g ?? candidate.g ?? '')) {
        return candidate
      }
    }
    return this.proxyitems?.find((candidate: ProxyItem) => candidate.name === item.name &&
      (candidate.g ?? item.g ?? '') === (item.g ?? candidate.g ?? ''))
  }

  private async verifyOfficialSpeedRoute(): Promise<void> {
    const target = this.officialSpeedTarget
    if (!target) throw new Error('测速目标已失效')
    const connections = await ClashViewModel.socketProxy.queryConnections()
    for (const connection of connections) {
      if (!this.isOfficialSpeedConnection(connection)) continue
      if (!connection.chains.includes(target.name)) {
        throw new Error('测速请求被分流到其他节点或直连，请检查该分组和分流规则')
      }
      if (!this.officialRouteVerified) console.error('[OfficialSpeed] route_verified=true')
      this.officialRouteVerified = true
    }
  }

  private parseOfficialSpeedState(raw: string): OfficialSpeedState {
    let parsed = JSON.parse(raw) as OfficialSpeedState | string
    if (typeof parsed === 'string') parsed = JSON.parse(parsed) as OfficialSpeedState
    return parsed as OfficialSpeedState
  }

  private saveOfficialSpeedResult(state: OfficialSpeedState): void {
    const profile = this.currentProfile
    const target = this.officialSpeedTarget
    if (!profile || !target || !state.downloadBps || !state.uploadBps) throw new Error('测速样本不完整，本次结果不保存')
    const downVariation = this.officialPointVariation(state.downPoints ?? [])
    const upVariation = this.officialPointVariation(state.upPoints ?? [])
    const reliable = downVariation <= 25 && upVariation <= 25
    const result = NodeQualityService.fromCore(profile.id, profile.lastUpdateDate,
      this.officialSpeedGroup, target.name, 'bandwidth_official', 'ok',
      reliable ? 'Cloudflare 官方' : 'Cloudflare 官方 · 波动较大',
      Math.round(state.latencyMs ?? 0), Math.round(state.jitterMs ?? 0), 100,
      Math.round(state.downloadBps / 10000) / 100, Math.round(state.uploadBps / 10000) / 100,
      Math.round(state.transferredBytes ?? 0), '',
      `官方P90 · 下载末级波动${downVariation}% · 上传末级波动${upVariation}% · ` +
        `耗时${Math.round((state.totalDurationMs ?? 0) / 1000)}秒`,
      reliable, downVariation, upVariation)
    ClashViewModel.recordNodeQualityResult(result)
    console.error(`[OfficialSpeed] result down=${result.downloadMbps} up=${result.uploadMbps} ` +
      `latency=${result.latencyMs} jitter=${result.jitterMs} bytes=${result.transferredBytes} ` +
      `downVariation=${downVariation} upVariation=${upVariation} seconds=${Math.round((state.totalDurationMs ?? 0) / 1000)}`)
  }

  private officialPointVariation(points: OfficialBandwidthPoint[]): number {
    if (points.length < 2) return 100
    let largest = 0
    points.forEach((point: OfficialBandwidthPoint): void => { largest = Math.max(largest, point.bytes) })
    const speeds = points.filter((point: OfficialBandwidthPoint): boolean => point.bytes === largest && point.bps > 0)
      .map((point: OfficialBandwidthPoint): number => point.bps)
      .sort((a: number, b: number): number => a - b)
    if (speeds.length < 2) return 100
    const middle = Math.floor(speeds.length / 2)
    const median = speeds.length % 2 === 0 ? (speeds[middle - 1] + speeds[middle]) / 2 : speeds[middle]
    return median > 0 ? Math.round((speeds[speeds.length - 1] - speeds[0]) / median * 100) : 100
  }

  private async restoreAfterOfficialSpeedTest(): Promise<void> {
    if (this.officialSpeedRestored) return
    this.officialSpeedRestored = true
    this.officialSpeedEpoch++
    try {
      await this.controller.runJavaScript('window.fireflyStopSpeedTest && window.fireflyStopSpeedTest()')
    } catch (_) {}
    try {
      await this.closeOfficialSpeedConnections()
      if (this.officialSpeedGroup && this.officialPreviousProxy) {
        const error = await ClashViewModel.socketProxy.changeProxy(this.officialSpeedGroup, this.officialPreviousProxy)
        if (error) throw new Error(error)
        const groups = await ClashViewModel.socketProxy.queryProxyGroups(ProxyMode.Global)
        if (groups.find((group: ProxyGroup): boolean => group.name === this.officialSpeedGroup)?.now !==
          this.officialPreviousProxy) throw new Error('原节点选择未恢复')
        console.error('[OfficialSpeed] previous_node_restored=true')
      }
    } catch (_) {
      console.error('[OfficialSpeed] previous_node_restored=false')
      Xb_ToastUtil.showToast({ message: '测速已停止；请检查 VPN 和当前节点，自动恢复未完成', duration: 4000 })
    }
    await new Promise<void>((resolve) => {
      try {
        webview.ProxyController.removeProxyOverride((): void => resolve())
      } catch (_) {
        resolve()
      }
    })
    AppStorage.setOrCreate('nodeQualityTestRunning', false)
    if (AppStorage.get<boolean>('nodeQualityNetworkRefreshPending') === true) {
      AppStorage.setOrCreate('nodeQualityNetworkRefreshPending', false)
      EventHub.sendEvent(EventKey.checkIpInfo, { force: true })
    }
  }

  private speedTestDelay(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(resolve, milliseconds))
  }

  public proxyListLongPressCtxMenuForFavorite: LongPressContextMenuItem = {
    symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.star'))
      .fontSize(TAB_CONTENT_TITLE_SYMBOL_FONT_SIZE).fontColor([$r('sys.color.font_primary')]),
    content: '收藏', callback: () => {
      this.favoriteProxy()
    }
  }
  public proxyListLongPressCtxMenuForUnFavorite: LongPressContextMenuItem = {
    symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.star_fill'))
      .fontSize(TAB_CONTENT_TITLE_SYMBOL_FONT_SIZE).fontColor([$r('sys.color.multi_color_11')]),
    content: '取消收藏', callback: () => {
      this.cancelFavoriteProxy()
    }
  }

  /**
   * 收藏配置
   */
  private favoriteProxy(): void {
    // 收藏节点 & 判断是否已经收藏
    const p = ProxyGroupItem.currentTouchProxyData
    console.debug(`FavoriteProxy [ProxyPage] 当前ProxyItem信息：${JSON.stringify(p)}`);
    if (AppState.fetchFavoriteProxys(this.favoriteProxys, this.proxyGroups.getAllData()).length < 6) {
      Xb_ToastUtil.showToast({ message: $r('app.string.Collect_Tip') })
      this.favoriteProxys.set(p.g + '|' + p.name, this.appConfig.currentProfileId ?? "")
      this.favoriteProxys.forEach((value, key) => {
          console.debug(`FavoriteProxy [ProxyPage] favoriteProxys收藏信息：${key}: ${value}`);
        });
    } else {
      Xb_ToastUtil.showToast({ message: $r('app.string.favorite_proxy_no') })
    }
  }

  /**
   * 取消收藏配置
   */
  private cancelFavoriteProxy(): void {
    Xb_ToastUtil.showToast({ message: $r('app.string.uncollected_tip') })
    const p = ProxyGroupItem.currentTouchProxyData
    this.favoriteProxys.delete(p.g + '|' + p.name)
    this.favoriteProxys.forEach((value, key) => {
      console.debug(`FavoriteProxy [ProxyPage] favoriteProxys收藏信息：${key}: ${value}`);
    });
  }
}


/** 速度与延迟区别弹窗 */
@CustomDialog
struct ProxyCustomDialog {
  /* 是否开启 `Index` 页面的前景模糊 */
  @Consume('isEnableIndexForegroundBlur')
  private isEnableIndexForegroundBlur: boolean
  /* 主题色 */
  @Consume('icon_emphasize')
  icon_emphasize: ResourceColor

  controller?: CustomDialogController
  cancel: () => void = () => {
  }
  confirm: () => void = () => {
  }

  build() {
    Column() {
      Text($r('app.string.Speed_Delay'))
        .fontSize(20)
        .padding({ bottom: 15 })
        .fontWeight(700)
      Text($r('app.string.Speed_Delay_Content'))
        .fontSize(16)
        .padding({ bottom: 8 })

      Button($r('app.string.Sure'))
        .fontSize(16)
        .width('100%')
        .onClick(() => {
          if (this.controller != undefined) {
            this.controller.close()
            this.isEnableIndexForegroundBlur=false
          }
        })
        .backgroundColor(this.icon_emphasize)
    }
    .backgroundColor($r('app.color.container_background'))
    .padding({
      left: 24,
      right: 24,
      top: 16,
      bottom: 16
    })
  }
}

// 自定义弹窗内容end

/**
 * 长按菜单参数
 */
interface LongPressContextMenuItem {
  symbolStartIcon?: SymbolGlyphModifier,
  symbolEndIcon?: SymbolGlyphModifier,
  content: ResourceStr
  callback : Callback<void>
}

interface OfficialBandwidthPoint {
  bytes: number
  bps: number
  duration: number
  ping: number
  transferSize: number
}

interface OfficialSpeedState {
  status: string
  phase?: string
  error?: string
  downloadBps?: number
  uploadBps?: number
  latencyMs?: number
  jitterMs?: number
  downLoadedLatencyMs?: number
  upLoadedLatencyMs?: number
  totalDurationMs?: number
  transferredBytes?: number
  downPoints?: OfficialBandwidthPoint[]
  upPoints?: OfficialBandwidthPoint[]
}

// list公用样式
@Extend(List)
function ListStyle() {
  // transition保证组件离场不被立即析构，可设置其他转场效果
  .width('100%')
  .chainAnimation(true)
  .scrollBar(BarState.Off)
  .edgeEffect(EdgeEffect.Spring)
  .constraintSize({minHeight: 120})
  .alignListItem(ListItemAlign.Center)
}

// ListItem公用样式
@Extend(ListItem)
function ListItemStyle() {
  .width('100%')
  .borderRadius(BORDER_RADIUS_20)
  .backgroundColor($r('app.color.container_background'))
}

export default ProxyGroupItem
