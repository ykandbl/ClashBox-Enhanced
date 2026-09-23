import { UIConfig } from '../../entryability/AppState'
import { icon_tertiary } from './Common'
import { customAnimationUtil } from '../../common/utils/Animation'
import ClashViewModel from '../../entryability/ClashViewModel'
import { hilog } from '@kit.PerformanceAnalysisKit'

/**
 * @fileName:      FloatControlButton
 * @author:     SummerKaze
 * @description:  悬浮控制按钮组件
 * @date:    2026/2/8 17:03
 * @version:    1.0
 */

@Component
export struct FloatControlButton {
  /** @description 是否为左侧按钮 */
  isLeft: boolean = false
  /** @description 代理启动状态 */
  @Consume proxyEnabled: boolean
  /** @description 主题强调色 */
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  /** @description UI 配置 */
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  /** @description 宽度断点 */
  @StorageProp('currentWidthBreakpoint') widthBp: number = 1

  build() {
    Row() {
      SymbolGlyph(this.proxyEnabled ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
        .fontSize(27)
        .fontColor([this.proxyEnabled ? Color.White : icon_tertiary])
    }
    .functionButtonStyle(this.proxyEnabled && this.widthBp <= 2, this.icon_emphasize)
    .animation({ duration: this.uiConfig.animationSpeed, curve: Curve.Linear })
    // 背景模糊
    .backdropBlur(this.uiConfig.isBlurr && !this.proxyEnabled ? 30 : 0)
    .backgroundColor(
      this.proxyEnabled
        ? this.icon_emphasize
        : this.uiConfig.isBlurr
          ? $r('app.color.float_tab_background_blur')
          : $r('app.color.background')
    )
    .onClick(async () => {
      // 以服务层状态为准，避免页面恢复时遗留的 UI 状态把首次点击误判为停止。
      const shouldStart = !ClashViewModel.vpnStarted
      hilog.info(0xA002, 'FloatControlButton',
        `点击代理按钮，服务状态：${ClashViewModel.vpnStarted}，目标启动：${shouldStart}`)
      if (shouldStart) {
        this.proxyEnabled = await ClashViewModel.StartVpn()
      } else {
        await ClashViewModel.StopVpn()
        this.proxyEnabled = false
      }
      // StartVpn/StopVpn 已在服务层发送状态事件，这里只同步按钮显示。
      this.proxyEnabled = ClashViewModel.vpnStarted
    })
    // 滑入/滑出 动画
    .transition(customAnimationUtil.getFloatButtonTransition(this.uiConfig, this.uiConfig.buttonPositionIndex))
  }
}

/**
 * 功能按钮样式
 * @param during - 是否处于激活状态（代理已启动）
 * @param c - 阴影颜色
 */
@Extend(Row)
function functionButtonStyle(during: boolean, c: ResourceColor = $r('app.color.shadow_button')) {
  .borderRadius(30)
  .padding(during ? { left: 8, right: 8 } : 0)
  .size({ width: 60, height: 60 })
  .justifyContent(FlexAlign.Center)
  .aspectRatio(1)
  .alignItems(VerticalAlign.Center)
  .shadow({
    radius: 15,
    offsetY: 4,
    color: during ? c : $r('app.color.shadow_button'),
    type: ShadowType.COLOR
  })
}
