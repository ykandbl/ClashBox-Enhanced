import {
  BIND_SHEET_MAIN_FONT_WEIGHT,
  BIND_SHEET_MAIN_FONTSIZE,
  BIND_SHEET_SUB_FONTSIZE,
  BIND_SHEET_DRAG_BAR_HEIGHT,
  BIND_SHEET_TITLE_LEFT_SYMBOL_WEIGHT,
  RouteName,
  NewConfigData,
} from "../../common/entity/Constants"
import { BindSheetTitleCustomBuilder, BindSheetTitleCustomBuilderMenu,
  context,
  CustomDownloadingDialog } from "../Common/Common"
import { hilog } from "@kit.PerformanceAnalysisKit"
import { ConfigInfo } from "./ConfigInfo"
import { PromptAction, window } from "@kit.ArkUI"
import { ConfigData } from "../../common/entity/PageArgumentEntity"
import { util } from "@kit.ArkTS"
import { CustomConfirmDialog } from '../Common/Common'
import { BusinessError } from "@kit.BasicServicesKit"
import { common } from "@kit.AbilityKit"
import ClashViewModel from "../../entryability/ClashViewModel"
import { getResourceString } from "../../common/utils/ResourceStringUtil"
import { UIConfig } from "../../entryability/AppState"
import { Xb_ToastUtil } from "xb_components"
import ConfigAutoUpdateService from "../../common/utils/ConfigAutoUpdateService"
import { BitzNetCredentialStore } from "../../common/utils/BitzNetQuotaService"
import { YhcCredentialStore } from "../../common/utils/YhcAccountService"


// 关联：route_map.json
@Builder
export function ImportConfigFromURLBuilder(name: string, param: Object){
  ImportConfigFromURL()
}

const componentName: string = 'ImportConfigFromURL'
const mainTitle: string = getResourceString($r('app.string.add_config'), context)

@Component
export struct ImportConfigFromURL {

  /* 是否开启 配置页 `bindSheet` 组件的前景模糊 */
  @Consume('isEnableConfigPageBindSheetForegroundBlur') isEnableConfigPageBindSheetForegroundBlur: boolean
  /* 是否开启 `Index` 页面的前景模糊 */
  @Consume('isEnableIndexForegroundBlur') isEnableIndexForegroundBlur: boolean
  // 配置下载弹框 title动态值
  @State private customDownloadingDialogTitle: ResourceStr = $r('app.string.downloading_configuration_file')
  @State private subTitle: ResourceStr = $r('app.string.Import_from_url')

  // 配置详情（要添加到用户首选项里的数据）
  @Prop @Watch('configDataChanged') configData: ConfigData = NewConfigData
  @StorageLink('currentTouchConfigData') currentTouchConfigData: ConfigData = NewConfigData
  @StorageLink('appLinkConfigUrl') appLinkConfigUrl: string = ''
  // 当前显示的工具集合 默认为空 待两个input都有值之后才加入保存按钮菜单
  @State private menus: Array<BindSheetTitleCustomBuilderMenu> = []
  // 页面栈
  @Consume('configAddPageInfos') configAddPageInfos: NavPathStack

  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  /* 主题色 */
  @Consume('icon_emphasize') icon_emphasize: ResourceColor

  @StorageLink('ConfigDownloading') isConfigDownloading: boolean = false
  // 是否显示bindSheet
  @StorageLink('ShowConfigBindSheet') isShowConfigAddBindSheet: boolean = false
  // [true: 都有值, false: 不是所有的input都有值]
  @State allInputHaveValue: boolean = false
  // 欢迎页半模态窗口
  @Consume isShowWelcome: boolean

  build() {
    NavDestination() {
      Column() {
        // 替代`NavDestination`的标题栏 START
        BindSheetTitleCustomBuilder({
          pageInfos: this.configAddPageInfos,
          needSetHeight: true,
          isSubPage: this.configData.isNewConfig,
          titlePaddingLeft: BIND_SHEET_DRAG_BAR_HEIGHT / 2,
          mainTitle: this.configData.isNewConfig ? mainTitle : getResourceString($r('app.string.edit_config'), this),
          subTitle: this.configData.isNewConfig ? this.subTitle : '',
          mainTitleFontWeight: BIND_SHEET_MAIN_FONT_WEIGHT,
          mainTitleFontSize: BIND_SHEET_MAIN_FONTSIZE,
          subTitleFontSize: BIND_SHEET_SUB_FONTSIZE,
          titleBackgroundColor: $r('app.color.background'),
          padding: {
            // 为什么设置`15`，看Builder的参数中`padding`的介绍：ConfigAddBindSheetTitleBuilderParam
            left: 15,
            // 避让`bindSheet`右上角的叉号本身`40vp`、右`15vp`
            right: BIND_SHEET_TITLE_LEFT_SYMBOL_WEIGHT + 15
          },
          menus: this.menus,
        })
        // 替代`NavDestination`的标题栏 END

        // 配置信息只占标题栏之外的剩余高度，避免底部内容被裁到屏幕外。
        ConfigInfo({
          configData: $configData,
          onAccountDataChange: (): void => {
            this.configDataChanged()
          }
        })
          .layoutWeight(1)
        // 配置信息 END
      }
      .width('100%')
      .height('100%')
      .clip(true)
    }
    .height('100%')
    .hideTitleBar(true)
    // .title({builder: , height: BIND_SHEET_TITLE_CONTAINER_HEIGHT + BIND_SHEET_DRAG_BAR_HEIGHT})
    .backgroundColor($r('app.color.container_background'))
    .onBackPressed(() => {
      if (this.allInputHaveValue) {
        // 弹框是否保存已经编辑好的配置
        this.configCustomConfirmDialogController?.open()
        // 更改bindSheet的前景模糊
       this.isEnableConfigPageBindSheetForegroundBlur = true
        return true
      } else {
        return false
      }
    })
    .onReady( (ctx: NavDestinationContext) => {
      // 接收信息
      try {
        const params: ConfigData = ctx?.pathInfo?.param as ConfigData
        console.log(`ClashBox#ImportConfigFromUrl#onReady source=${params?.configId === 'newQR' ? 'qr' : 'url'} id=${params?.configId ?? ''}`)
        if (params) {
          this.configData = params
          if (params.configId === 'newQR') {
            this.subTitle = $r('app.string.import_from_QR_code')
          }
        }
      } catch (e) {
        console.log(`ClashBox#ImportConfigFromUrl#onReady Navigate onReady catch exception: ${JSON.stringify(e)}`)
      }
    })
    .animation({ duration: this.uiConfig.animationSpeed, curve: Curve.Ease })
  }

  // 保存按钮
  private saveMenus: BindSheetTitleCustomBuilderMenu = {
    symbol: $r('sys.symbol.save'),
    symbolFontColor: ['#e6ffffff'],
    // 跟随主题色：由于在这里直接赋值 this.icon_emphasize 编译器提示需要初始化 this.icon_emphasize 的值，放到了 aboutToAppear 回调里重新赋值
    symbolBackgroundColor: '#FF0A59F7',
    action: () => {
      this.saveConfig(this.configData.isNewConfig).then((saved: boolean) => {
        if (saved) {
          this.closeAfterSave()
        }
      })
    }
  }

  /* 自定义弹框 */
  // 配置是否保存弹框 Controller定义
  private configCustomConfirmDialogController: CustomDialogController | null= new CustomDialogController({
    builder: CustomConfirmDialog({
      title: $r('app.string.save_current_configuration'),
      cancelText: $r('app.string.Cancel'),
      confirmText: $r('app.string.Save'),
      cancelButtonBackgroundColor: Color.Transparent,
      // 不可以使用`@Consume`注解的变量
      // confirmButtonBackgroundColor: this.icon_emphasize,
      cancel: () => {
        // 取消保存配置后关闭半模态窗口
        this.isShowWelcome = false
        this.isShowConfigAddBindSheet = false
        this.isEnableConfigPageBindSheetForegroundBlur = false
        this.isEnableIndexForegroundBlur = false
        this.configAddPageInfos.pop(true)
      },
      confirm: () => {
        this.saveConfig(this.configData.isNewConfig).then((saved: boolean) => {
          if (saved) {
            this.closeAfterSave()
          }
        })
      }
    }),
    cancel: () => {
      this.isEnableConfigPageBindSheetForegroundBlur = false
      this.isEnableIndexForegroundBlur = false
    },
    // autoCancel: true,
    alignment: DialogAlignment.Center,
    width: 328,
    backgroundColor: $r('app.color.list_item_background_color'),
  })

  // 配置下载弹框 Controller定义
  configCustomDownloadingDialogController: CustomDialogController = new CustomDialogController({
    builder: CustomDownloadingDialog({
      title: this.customDownloadingDialogTitle,
      cancelText: $r('app.string.cancel_download'),
      cancel: () => {},
    }),
    alignment: DialogAlignment.Center,
    width: 328,
    backgroundColor: $r('app.color.list_item_background_color'),
    onWillDismiss: () => {
      this.isEnableIndexForegroundBlur = false
    },
    onDidDisappear: () => {
      if (!this.isConfigDownloading) {
        this.isEnableIndexForegroundBlur = false
      }
    }
  })

  async aboutToAppear(): Promise<void> {
    hilog.info(0xCA10, componentName, `#aboutToAppear executed`)
    // XXX 没有写`this.icon_emphasize`的`Watch`事件，是因为如果在设置页面里设置了其他主题色时，这个页面一定不是打开的状态
    this.saveMenus.symbolBackgroundColor = this.icon_emphasize
    this.isEnableIndexForegroundBlur = true
    if (!this.configData.accountProvider && this.configData.bitzQuotaEnabled) {
      this.configData.accountProvider = 'bitznet'
    }
    if (!this.configData.isNewConfig && this.configData.configId &&
      (this.configData.accountProvider ?? 'none') !== 'none') {
      const credential = this.configData.accountProvider === 'yhc' ?
        await YhcCredentialStore.load(this.configData.configId) :
        await BitzNetCredentialStore.load(this.configData.configId)
      if (credential) {
        this.configData.accountUsername = credential.username
        this.configData.accountPassword = credential.password
      }
      this.configDataChanged()
    }
    if (this.appLinkConfigUrl != '') {
      hilog.info(0xCA10, componentName, `#aboutToAppear import 检查文本`)
      this.configDataChanged()
    }
  }

  aboutToDisappear(): void {
    hilog.info(0xCA10, componentName, `#aboutToDisappear executed`)
    // 自定义弹框 清空
    this.configCustomConfirmDialogController = null
    this.isEnableConfigPageBindSheetForegroundBlur = false
    hilog.info(0xCA10, componentName, `#aboutToDisappear#置空[配置页\`bindSheet\`内提示是否保存配置信息的自定义弹框]`)
  }

  /**
   * 保存配置
   */
  async saveConfig(isNewConfig: boolean): Promise<boolean> {
    if (this.isConfigDownloading) {
      Xb_ToastUtil.showToast({ message: '配置正在保存，请稍候' })
      return false
    }
    this.isConfigDownloading = true
    this.currentTouchConfigData = this.configData
    hilog.info(0xFF00, "EditConfig #saveConfig configSaveTestTag", `URL新文件保存：${isNewConfig}`)
    hilog.info(0xC002, componentName,
      `EditConfig #saveConfig Name: ${this.currentTouchConfigData.configName} source=url-redacted`)
    const hasAccount = (this.configData.accountProvider ?? 'none') !== 'none'
    this.customDownloadingDialogTitle = hasAccount ? '正在验证账号并保存配置' :
      (isNewConfig ? $r('app.string.downloading_configuration_file') :
        $r('app.string.updating_configuration_file'))
    this.configCustomDownloadingDialogController.open()
    try {
      if (!isNewConfig) {
        this.uiConfig.autoUpdateTimeUtils = this.configData.configAutoUpdateTimeGapTextPickerIndex
      }
      await ClashViewModel.addOrUpdateProfileByUrl(this.configData,
        isNewConfig ? null : this.configData.configId)
      if (isNewConfig) {
        Xb_ToastUtil.showToast({message: getResourceString($r('app.string.download_success'), this)})
        if (this.appLinkConfigUrl != '') {
          this.appLinkConfigUrl = ''
        }
      }
      return true
    } catch (error) {
      const reason = (error as Error).message || `${error}`
      console.error("ClashBox下载配置失败：", reason, (error as Error).stack)
      Xb_ToastUtil.showToast({
        message: getResourceString($r('app.string.download_failed'), this) + `: ${reason}`,
        duration: 4000
      })
      return false
    } finally {
      this.isConfigDownloading = false
      this.configCustomDownloadingDialogController.close()
      // 检查是否需要开启配置自动更新服务
      ConfigAutoUpdateService.reset()
    }
  }

  private closeAfterSave(): void {
    this.isShowWelcome = false
    this.isShowConfigAddBindSheet = false
    this.isEnableConfigPageBindSheetForegroundBlur = false
    this.isEnableIndexForegroundBlur = false
  }

  /**
   * 检查配置名 Input && 配置 URL 是否都有值
   *    true: 显示保存按钮。 false反之
   */
  configDataChanged() {
    this.checkAllInputHaveValue()
    if (this.allInputHaveValue) {
      if (this.menus.filter(i => i === this.saveMenus).length <= 0) {
        // 新增`保存配置`菜单按钮
        this.menus.push(this.saveMenus)
      }
    } else {
      // 移除`保存配置`菜单按钮
      for (let i = 0; i < this.menus.length; i++) {
        if (this.menus[i] === this.saveMenus) {
          this.menus.splice(i, 1)
          break
        }
      }
    }
  }

  /**
   * 检查配置名 Input && 配置 URL 是否都有值
   */
  checkAllInputHaveValue() {
    if (!this.configData.configUrl) {
      this.allInputHaveValue = false
      return
    }
    this.allInputHaveValue = this.configData.configUrl.length > 0 &&
      ((this.configData.accountProvider ?? 'none') === 'none' ||
        (!!this.configData.accountUsername?.trim() && !!this.configData.accountPassword))
    // hilog.info(0xCA12, this.componentName, `#checkAllInputHaveValue is [${this.allInputHaveValue}]}`)
  }

}
