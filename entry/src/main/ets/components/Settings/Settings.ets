
import {
  BORDER_RADIUS_20,
  CONTENT_END_OFFSET_150, settingsData, SettingsListItem } from "../../common/entity/Constants"
import settingsListItem from "./settingsListItem"
import { hilog } from "@kit.PerformanceAnalysisKit"
import Appearance from "./Appearance"
import Backup from "./Backup"
import Notice from "./NoticeClean"
import WipeData from "./WipeData"
import About, { AboutCollaborators, AboutUpdateHistory, ThirdServices } from "./About"
import Language from "./Language"
import RuntimeDiagnostics from "./RuntimeDiagnostics"
import TopBuilder from "./TopBuilder"
import { Nothing } from "../Common/Common"
import { UIConfig } from "../../entryability/AppState"
import ClashViewModel from "../../entryability/ClashViewModel"
import { getResourceString } from "../../common/utils/ResourceStringUtil"
import { common } from "@kit.AbilityKit"
import { timestampToDateTime } from "../../common/utils/TimeConvertUtil"
import { ProxyGroupItemDataSource } from "../../common/datasources/ProxyData"
import { ConfigData } from "../../common/entity/PageArgumentEntity"
import { PageMargin } from "../../common/breakpoint/BreakPoint"
import { EventHub, EventKey } from '../../common/EventHub';


@Entry
@Component
struct Settings {
  @Consume isDisclaimer: boolean
  // 判断设置是否清楚数据
  @Consume isClearData: boolean
  @Consume currentLanguage: ResourceStr
  @Consume configList: Array<ConfigData>
  @Consume proxyGroups: ProxyGroupItemDataSource
  @State settingsList: settingsData[] = SettingsListItem()
  /* 主题色 */
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  // 当前设备`height`是否符合(320vp< height <= 500vp)
  @StorageLink ('isLandscapePhone') private isLandscapePhone: boolean = false
  @Consume('NavSettingsPathStack') SettingsPageInfos: NavPathStack
  /* 是否开启 `Index` 页面的前景模糊 */
  @Consume('isEnableIndexForegroundBlur') isEnableIndexForegroundBlur: boolean
  // 高度断点
  @StorageLink ('currentHeightBreakpoint') heightBp: HeightBreakpoint = 0
  // 宽度断点
  @StorageLink ('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1

  private context = this.getUIContext().getHostContext()! as common.UIAbilityContext

  build() {
    Navigation(this.SettingsPageInfos) {
      TopBuilder({
        showBackButton: false,
        title: $r('app.string.Settings'),
        pathStack: this.SettingsPageInfos
      })
      List({space: 10}) {
        ForEach(this.settingsList, (item: settingsData, index: number) => {
          ListItem() {
            settingsListItem({
              index: index,
              itemObj: item,
              onCheck: (index: number) => {
                this.handleCheck(index)
              }
            })
          }
        })
      }
      .width('100%')
      .contentEndOffset(CONTENT_END_OFFSET_150 - 75)
      .borderRadius(18)
      .alignListItem(ListItemAlign.Center)
      .padding({left: PageMargin(this.widthBp, this.heightBp), right: PageMargin(this.widthBp, this.heightBp)})
    }
    .hideToolBar(true)
    .mode(this.isLandscapePhone ? NavigationMode.Stack : NavigationMode.Auto)
    .navDestination(this.SettingsPagesMap)
    .width('100%')
    .height('100%')
    .onNavBarStateChange((isVisible: boolean) => {
      // 刷新备份行显示
      if (this.uiConfig.isShowExperimentalFunction) {
        this.settingsList = SettingsListItem()
      }
      // 刷新语言行的语言提示
      const itemData = this.settingsList[0]
      itemData.hint = this.currentLanguage
      this.settingsList.splice(0, 1, itemData)
    })
  }

  handleCheck(index: number) {
    const itemSettingsData = this.settingsList[index]
    this.SettingsPageInfos.pushPathByName(itemSettingsData.name, false)
    hilog.isLoggable(0xFF00, "SettingstestTag", hilog.LogLevel.INFO);
    hilog.info(0xFF00, "SettingstestTag", itemSettingsData.name)
  }

  onLanguageChanged() {
    hilog.info(0xFF00, "SettingsTestTag", "设置页页面栈：%{public}d", this.SettingsPageInfos.size())
  }

  aboutToAppear(): void {
    // if (!this.uiConfig.isShowExperimentalFunction) {
    //   this.settingsList = removeItemsByIndex(this.settingsList, [2])
    // }
  }

  // 在自定义组件即将析构销毁时将dialogController置空
  aboutToDisappear() {
    // 注销WebDav登录事件
    EventHub.off(EventKey.LoginWebDav)
    // 释放WebDav连接
    // this.webdavClient.close()
  }

  // 设置页路由表
  @Builder
  SettingsPagesMap(name: string) {
    if (name == 'Appearance') {
      Appearance()
    } else
      if (name == 'Backup') {
        Backup()
      } else
      if (name == 'Notice') {
        Notice()
      } else
      if (name == 'RuntimeDiagnostics') {
        RuntimeDiagnostics()
      } else
      if (name == 'WipeData') {
        WipeData()
      } else
      if (name == 'About') {
        About()
      } else
      if (name == 'Language') {
        Language()
      } else
      if (name == 'collaborators') {
        AboutCollaborators()
      } else
      if (name == 'UpdateHistory') {
        AboutUpdateHistory()
      } else
      if (name == 'Three') {
        ThirdServices()
      } else
      if (name == 'offline-detail') {
        OfflineDetail()
      }
  }

}
export default Settings


@Component
struct OfflineDetail {

  @State offline: number[] = []
  @Consume('NavSettingsPathStack') SettingsPageInfos: NavPathStack
  // 宽度断点
  @StorageLink ('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1
  // 高度断点
  @StorageLink ('currentHeightBreakpoint') heightBp: HeightBreakpoint = 0


  aboutToAppear(): void {
    this.offline = ClashViewModel.socketProxy.offlineTime.reverse()
  }

  build() {
    NavDestination() {
      TopBuilder({
        title: $r('app.string.offline'),
        subtitle: '',
        pathStack: this.SettingsPageInfos
      })

      if (this.offline.length === 0) {
        Nothing({
          name: $r('app.string.offline')
        })
      } else {
        List({ space: 10 }) {
          ForEach(this.offline, (item: number, index: number) => {
            ListItem() {
              Row() {
                Column() {
                  Text() {
                    Span($r('app.string.id'))
                    Span('：')
                    Span((index + 1).toString())
                  }
                  .fontWeight(FontWeight.Normal)
                  .fontSize(15)
                  Text() {
                    Span($r('app.string.time'))
                    Span('：')
                    Span(timestampToDateTime(item))
                  }
                  .fontWeight(FontWeight.Normal)
                  .fontSize(15)
                }
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding(12)
              .justifyContent(FlexAlign.Start)
              .backgroundColor($r('app.color.container_background'))
              .borderRadius(BORDER_RADIUS_20)
            }
          })
        }.width('100%')
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
        .contentEndOffset(CONTENT_END_OFFSET_150 - 85)
        .padding({ left: PageMargin(this.widthBp, this.heightBp), right: PageMargin(this.widthBp, this.heightBp), bottom: PageMargin(this.widthBp, this.heightBp) })

      }

    }.width('100%')
    .backgroundColor($r('app.color.background'))
    .hideTitleBar(true)
    .onBackPressed(() => {
      this.SettingsPageInfos.clear();
      return true;
    })
  }
}
