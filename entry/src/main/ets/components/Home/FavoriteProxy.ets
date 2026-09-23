import { BreakpointState } from '../../common/breakpoint/breakpointsystem'
import { mediaquery} from '@kit.ArkUI'
import { CardTitle } from './CardTitleBuilder'
import { ProxyGroupItemDataSource, ProxyItem } from '../../common/datasources/ProxyData'
import { AppConfig, AppState, UIConfig } from '../../entryability/AppState'
import { Profile, ProxyGroup, ProxyType } from 'proxy_core'
import { customVibrator } from '../../common/utils/VibratorUtil'
import { customAnimationUtil } from '../../common/utils/Animation'
import ClashViewModel from '../../entryability/ClashViewModel'
import { HomeCardDeleteButtonSize, HomeCardFontSize, HomeCardPadding,
  HomeCardPartSmallFontSize } from '../../common/breakpoint/BreakPoint'
import { cardManager } from '../../common/utils/CardManageUtil'
import { Xb_ToastUtil } from 'xb_components'


@Component
struct FavoriteProxy {

  @StorageLink('favoriteProxys') favoriteProxys: Map<string, string> = new Map<string, string>([])
  // 高度断点
  @StorageLink ('currentHeightBreakpoint') heightBp: HeightBreakpoint = 0
  // 宽度断点
  @StorageLink ('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1
  @StorageLink('appConfig') appConfig: AppConfig = new AppConfig()
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  @Consume('currentProfile') currentProfile: Profile | null
  /* 主题色 */
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  // 代理数据(懒加载)
  @Consume proxyGroups: ProxyGroupItemDataSource
  // 编辑按钮点击后显示编辑状态判定
  @Consume isShowHomeEdit: boolean

  build() {
    Column() {
      CardTitle({ title: $r('app.string.FavoriteProxy') })
      //拥有收藏节点的布局 start
      if (AppState.fetchFavoriteProxys(this.favoriteProxys, this.proxyGroups.getAllData()).length > 0 ) {
        Flex({ direction: FlexDirection.Column, alignItems: ItemAlign.Center, justifyContent: FlexAlign.SpaceEvenly }) {
          List() {
            ForEach(AppState.fetchFavoriteProxys(this.favoriteProxys, this.proxyGroups.getAllData()),
              (group_node: [string, string], i: number) => {
                ListItem() {
                  Flex({
                    direction: FlexDirection.Row,
                    alignItems: ItemAlign.Center,
                    justifyContent: FlexAlign.SpaceBetween
                  }) {
                    Text(group_node[1])
                      .fontSize(HomeCardFontSize(this.widthBp, this.heightBp))
                      .fontColor($r('sys.color.font_primary'))
                      .maxLines(1)
                      .width('80%')
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Radio({ value: 'FavoriteProxyRadio', group: 'FavoriteProxyGroup' })
                      .width(HomeCardFontSize(this.widthBp, this.heightBp))
                      .checked(this.appConfig.currentProxyName === group_node[1])
                      .radioStyle({
                        checkedBackgroundColor: this.icon_emphasize,
                      })
                      .hitTestBehavior(HitTestMode.None)
                  }
                  .onClick(async () => {
                    // 在home页编辑状态时，无法操作
                    if (!this.isShowHomeEdit) {
                      const target = this.resolveSelectableProxy(group_node[0], group_node[1])
                      if (!target) {
                        Xb_ToastUtil.showToast({ message: '未找到包含该节点的可选择代理组', duration: 3000 })
                        return
                      }
                      // 由核心确认切换成功后再更新 UI，避免出现“名称已变、出口未变”的假切换。
                      const switched = await this.changeProxy(target[0], target[1])
                      if (switched) {
                        this.appConfig.currentProxyName = target[1].name
                        this.appConfig.currentProxyItem = target[1]
                      }
                      if (switched && this.uiConfig.isVibrate) {
                        customVibrator.vibratorTriggerOfHapticClockTimer()
                      }
                    }
                  })
                  .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
                }
                .height(AppState.fetchFavoriteProxys(this.favoriteProxys, this.proxyGroups.getAllData()).length - 1 == 1 ? '50%' : '32%')
                .transition({ type: TransitionType.Delete, opacity: 0 }).swipeAction({
                  end: {
                    builder: () => {
                      this.itemEnd(group_node[0] + '|' + group_node[1]);
                    },
                    actionAreaDistance: 56,
                  },
                  edgeEffect: SwipeEdgeEffect.Spring
                })
              })
          }.divider({ strokeWidth: 1, color: $r('app.color.FavoriteProxyDivider') })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None)
        }
        .width('100%')
        .height('82%')
        .backgroundColor($r('app.color.home_card_background'))
        .borderRadius(10)
        .padding({ left: 8, right: 5 })
      }// 拥有收藏节点的布局 end

      // 没有收藏节点的布局 start
      else {
        Flex({ direction: FlexDirection.Column, alignItems: ItemAlign.Center, justifyContent: FlexAlign.Center }) {
          SymbolGlyph($r('sys.symbol.star'))
            .fontSize(HomeCardDeleteButtonSize(this.widthBp, this.heightBp))
            .fontColor([$r('sys.color.font_secondary')])
            .padding({bottom:5})

          Text($r('app.string.favorite_proxy_tips'))
            .fontSize(HomeCardPartSmallFontSize(this.widthBp, this.heightBp))
            .fontColor($r('sys.color.font_secondary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height("78%")
      }//没有收藏节点的布局 end
    }
    .padding(HomeCardPadding(this.widthBp, this.heightBp))
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .id('FavoriteProxyId')
  }

  @Builder
  itemEnd(key: string) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r('sys.symbol.trash_fill'))
        .fontColor([Color.Red])
        .fontSize(HomeCardFontSize(this.widthBp, this.heightBp))
    }
    .padding(5)
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      this.favoriteProxys.delete(key)
    })
  }

  private resolveSelectableProxy(savedGroup: string, node: string): [string, ProxyItem] | undefined {
    const groups = this.proxyGroups.getAllData()
    const originalGroup = groups.find((group: ProxyGroup) => group.name === savedGroup)
    if (originalGroup?.type === ProxyType.Selector) {
      const originalItem = originalGroup.proxies.find((item) => item.name === node) as ProxyItem
      if (originalItem) {
        return [originalGroup.name, originalItem]
      }
    }
    const selectableGroup = groups.find((group: ProxyGroup) =>
      group.type === ProxyType.Selector && group.proxies.some((item) => item.name === node))
    const selectableItem = selectableGroup?.proxies.find((item) => item.name === node) as ProxyItem
    if (selectableGroup && selectableItem) {
      console.info(`FavoriteProxy 将收藏节点从不可选择组 ${savedGroup} 映射到 ${selectableGroup.name}`)
      return [selectableGroup.name, selectableItem]
    }
    return undefined
  }

  async changeProxy(g: string, item: ProxyItem): Promise<boolean> {
    console.debug(`FavoriteProxy [FavoriteProxyCard] Group：${g} node: ${item.name}`)
    if (this.currentProfile) {
      const switched = await ClashViewModel.changeProxy(this.currentProfile, g, item.name)
      if (switched) {
        // 首选项持久化存储 -> 供卡片使用
        cardManager.setSelectedProxyNode(this.currentProfile, g, item.name)
      }
      return switched
    }
    return false
  }

  aboutToAppear(): void {
  }

  aboutToDisappear() {
  }

}
export default FavoriteProxy
