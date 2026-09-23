import { BORDER_RADIUS_20, CONTENT_END_OFFSET_150, FONT_SIZE_16, LIST_ITEM_HEIGHT} from '../../common/entity/Constants'
import { hilog } from "@kit.PerformanceAnalysisKit"
import ProxyGroupItem from './ProxyGroupItem'
import { Profile, ProxyGroup,ProxyType } from 'proxy_core'
import { ProxyItem, ProxyGroupItemDataSource } from '../../common/datasources/ProxyData'
import ClashViewModel from '../../entryability/ClashViewModel'
import { AppConfig, UIConfig } from '../../entryability/AppState'
import { customAnimationUtil } from '../../common/utils/Animation'
import { cardManager } from '../../common/utils/CardManageUtil'

const  componentName: string = 'ProxyPageArrangement'

/**
 * 列表排列
 */
@Component
struct ProxyArrangement {
  @Consume isRolling: boolean
  // page内顶部标题偏移量
  @Consume curYOffset: number
  @State selectItem: number = 0
  // px外屏隐藏top和tab偏移
  @Consume curOffsetRemain: number
  // 当前代理分组
  @Consume currentProxyIndex: number
  // 代理原始数据
  @Consume proxyGroups: ProxyGroupItemDataSource
  @State isContentShow: boolean | undefined = false
  @Consume('currentProfile') currentProfile: Profile
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  @StorageLink('appConfig') appConfig: AppConfig = new AppConfig()
  /* 当前设备`height`是否符合(320vp< height <= 500vp) */
  @StorageLink ('isLandscapePhone') private isLandscapePhone: boolean = false
  @StorageLink('favoriteProxys') favoriteProxys: Map<string, string> = new Map<string, string>([])

  private  proxyScroller: ListScroller = new ListScroller()

  build() {
    List({ initialIndex: 0, scroller: this.proxyScroller}) {
      LazyForEach(this.proxyGroups, (group: ProxyGroup, index: number) => {
        ListItemGroup({
          header: this.itemHead(group.name, !this.isContentShow && this.selectItem === index
            ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'), group.name)
        }) {
          // 展开后内容显示区域
          if (!this.isContentShow && this.selectItem === index) {
            ProxyGroupItem({
              proxyGroup: index,
              proxyitems: group.proxies as ProxyItem[] ?? [],
              ProxyGroupItemSelected: this.appConfig.proxyCardSize,
              disabled: group.type !== ProxyType.Selector,
              selectedProxy: this.getCurrentProxyName(group),
              OnProxyChange: (item) => {
                return this.changeProxy(group.name, item)
              }
            })
              .width('100%')
              .padding({ top: 10})
              .borderRadius(BORDER_RADIUS_20)
          }
        }
        .margin({bottom: (!this.isContentShow && this.selectItem === index) ? 0 : 10})
        .clickEffect(this.isContentShow?customAnimationUtil.isClickEffect(this.uiConfig):null)
        .transition(customAnimationUtil.isScaleTranFast(index, this.uiConfig))
        .width('100%')
        .borderRadius(BORDER_RADIUS_20)
      }, (item: ProxyGroup) => `${this.appConfig.currentProfileId}|${item.name}`)
    }
    .contentEndOffset(this.isLandscapePhone?80:CONTENT_END_OFFSET_150)
    .chainAnimation(true)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onScrollFrameBegin((offset: number) => {
      this.curOffsetRemain  += offset
      if (offset > 0) {
        this.isRolling = true
      } else if(offset < 0) {
        this.isRolling = false
        this.curOffsetRemain = 0
      }
      // console.info("offsetRemain:" + offset + '/' +this.curOffsetRemain);
      return { offsetRemain: offset }
    })
    .nestedScroll({
      scrollForward: NestedScrollMode.PARENT_FIRST,
      scrollBackward: NestedScrollMode.SELF_FIRST
    })
    .sticky(StickyStyle.Header)
    .height('100%')
    .width('100%')

  }

  aboutToAppear(): void {
    hilog.info(0xB000, componentName, '#aboutToAppear 组1数组长度： %{public}d', this.proxyGroups.getData(0).proxies.length )
    hilog.info(0xFF00, "ProxyPageGroupTag", "#ProxyArrangement#aboutToAppear 当前显示分组%{public}d", this.currentProxyIndex)
    if (this.currentProfile) {
      const theProxyGroups = this.proxyGroups.getAllData()
      let listIndexes = theProxyGroups.findIndex((d) => d.name == this.currentProfile?.currentGroupName)
      setTimeout(() => {
        if (listIndexes > -1 && this.currentProxyIndex === 0) {
          this.currentProxyIndex = listIndexes
          this.selectItem = listIndexes
        } else {
          this.selectItem = this.currentProxyIndex
        }
        try {
          this.proxyScroller.scrollToItemInGroup(0, this.currentProxyIndex)
        } catch (error) {
          console.error(`#aboutToAppear 滚动失败：error: ${error}`)
        }
      }, 200)
    }
    if(this.currentProfile && this.currentProfile?.proxySelected){
      console.log("proxySelected", this.currentProfile?.proxySelected.size)
    }
  }

  async changeProxy(g: string, item: ProxyItem): Promise<boolean> {
    if (this.currentProfile) {
      const switched = await ClashViewModel.changeProxy(this.currentProfile, g, item.name)
      if (!switched) return false
      // 首选项持久化存储 -> 供卡片使用
      cardManager.setSelectedProxyNode(this.currentProfile, g, item.name)
      return true
    }
    return false
  }

  /** 获取当前分组名 */
  getCurrentProxyName(group: ProxyGroup): string {
    if (!this.currentProfile) {
      return ''
    } else {
      const optimistic = this.appConfig.currentProxyItem
      if (optimistic && optimistic.g === group.name && this.appConfig.currentProxyName) {
        return this.appConfig.currentProxyName
      }
      return this.currentProfile.getSelectedProxy(group) ?? this.appConfig.currentProxyName ?? ''
    }
  }

  /**
   * The node list is a child of ListItemGroup.  A click handler on the group
   * bubbles node taps to the header/group and changes the expanded group while
   * the node RPC is still being dispatched.  The list then reflows under the
   * finger, which looks like tapping one node selects another one.  Keep the
   * toggle exclusively on the header and resolve the index from the stable
   * group name at event time.
   */
  private toggleGroup(groupName: string): void {
    const index = this.proxyGroups.getAllData().findIndex((group: ProxyGroup) => group.name === groupName)
    if (index < 0) return
    animateTo({
      duration: this.uiConfig.animationSpeed,
      onFinish: () => {
      }
    }, () => {
      if (!this.isContentShow) {
        try {
          this.proxyScroller.scrollToItemInGroup(index, 0, true, ScrollAlign.START)
        } catch (error) {
          console.error(`ProxyArrangement header scroll failed: ${error}`)
        }
      }
      this.isContentShow = !this.isContentShow
      this.selectItem = index
    })
  }

  // 分组标签。点击范围只覆盖标题，不覆盖展开后的节点内容。
  @Builder
  itemHead(text: string, icon: Resource, groupName: string) {
    Row() {
      Text(text)
        .fontSize(FONT_SIZE_16)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      SymbolGlyph(icon)
        .fontSize(25).fontColor([$r('sys.color.icon_primary')])
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .padding({ left: 10, right: 10 })
    .borderRadius(BORDER_RADIUS_20)
    .backgroundColor($r('app.color.container_background'))
    .height(LIST_ITEM_HEIGHT)
    .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
    .onClick(() => this.toggleGroup(groupName))
  }


}

export default ProxyArrangement
