import { UIConfig } from '../../entryability/AppState'
import { PageMargin } from '../../common/breakpoint/BreakPoint'
import { customSound } from '../../common/utils/SoundPoolUtil'
import { customVibrator } from '../../common/utils/VibratorUtil'
import { EventHub, EventKey } from '../../common/EventHub'
import { toggleRowList } from '../Common/Common'
import TopBuilder from './TopBuilder'

@Component
struct NoticeClean {
  @Consume('NavSettingsPathStack') SettingsPageInfos: NavPathStack
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  @StorageLink('currentHeightBreakpoint') heightBp: HeightBreakpoint = 0
  @StorageLink('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1

  aboutToAppear(): void {
    if (this.uiConfig.isSound) customSound.initSoundPool(3, 'beat_short.wav')
  }

  aboutToDisappear(): void {
    customSound.destroySoundPool()
  }

  build() {
    NavDestination() {
      TopBuilder({
        title: $r('app.string.Notice'),
        pathStack: this.SettingsPageInfos
      })
      List({ space: 10 }) {
        ListItem() {
          Column() {
            Row() {
              toggleRowList({
                title: $r('app.string.vibrate_feedback'),
                icons: $r('sys.symbol.rectangle_portrait_wave_2')
              }) {
                Toggle({ type: ToggleType.Switch, isOn: $$this.uiConfig.isVibrate })
                  .selectedColor(this.icon_emphasize)
                  .hitTestBehavior(HitTestMode.None)
                  .margin({ right: 12 })
              }
            }
            .RowStyle()
            .onClick(() => {
              this.uiConfig.isVibrate = !this.uiConfig.isVibrate
              if (this.uiConfig.isVibrate) customVibrator.vibratorTriggerOfHapticClockTimer()
            })
            Row().height(0.5).backgroundColor($r('app.color.divider')).width('93%')
            Row() {
              toggleRowList({
                title: $r('app.string.sound_feedback'),
                icons: $r('sys.symbol.bell_fill')
              }) {
                Toggle({ type: ToggleType.Switch, isOn: $$this.uiConfig.isSound })
                  .selectedColor(this.icon_emphasize)
                  .hitTestBehavior(HitTestMode.None)
                  .margin({ right: 12 })
              }
            }
            .RowStyle()
            .onClick(() => {
              this.uiConfig.isSound = !this.uiConfig.isSound
              if (this.uiConfig.isSound) customSound.playAudioForSoundPool()
            })
          }
          .ColumnStyle()
        }

        ListItem() {
          Column() {
            Row() {
              toggleRowList({
                title: $r('app.string.notice_main_switch'),
                subtitle: $r('app.string.notice_main_switch_subtitle'),
                icons: $r('sys.symbol.message_on_message_fill')
              }) {
                Toggle({ type: ToggleType.Switch, isOn: $$this.uiConfig.Enablednotice })
                  .selectedColor(this.icon_emphasize)
                  .hitTestBehavior(HitTestMode.None)
                  .margin({ right: 12 })
              }
            }
            .RowStyle()
            .onClick((): void => {
              EventHub.sendEvent(EventKey.EnabledNotice, !this.uiConfig.Enablednotice)
            })

          }
          .ColumnStyle()
        }

        ListItem() {
          Row() {
            toggleRowList({
              title: $r('app.string.speed_notification'),
              subtitle: $r('app.string.speed_notification_subtitle'),
              icons: $r('sys.symbol.network_acceleration')
            }) {
              Toggle({ type: ToggleType.Switch, isOn: $$this.uiConfig.EnabledPermanentnotice })
                .selectedColor(this.icon_emphasize)
                .hitTestBehavior(HitTestMode.None)
                .margin({ right: 12 })
            }
          }
          .RowStyle()
          .onClick(() => {
            this.uiConfig.EnabledPermanentnotice = !this.uiConfig.EnabledPermanentnotice
          })
        }

        ListItem() {
          Text($r('app.string.vpn_system_notification_explanation'))
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
            .padding({ left: 8, right: 8 })
        }
      }
      .width('100%')
      .padding({ left: PageMargin(this.widthBp, this.heightBp),
        right: PageMargin(this.widthBp, this.heightBp) })
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.background'))
    .onBackPressed(() => {
      this.SettingsPageInfos.pop(true)
      return true
    })
  }
}

export default NoticeClean

@Extend(Row)
function RowStyle() {
  .width('100%')
  .borderRadius(20)
  .backgroundColor($r('app.color.container_background'))
}

@Extend(Column)
function ColumnStyle() {
  .width('100%')
  .borderRadius(20)
  .backgroundColor($r('app.color.container_background'))
}
