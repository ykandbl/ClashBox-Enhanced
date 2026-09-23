import { common } from '@kit.AbilityKit'
import { AppState, UIConfig } from '../../entryability/AppState'
import { PageMargin } from '../../common/breakpoint/BreakPoint'
import { theRowCustomDialog } from '../Common/Common'
import { Xb_ToastUtil } from 'xb_components'
import TopBuilder from './TopBuilder'

@Component
struct WipeData {
  @Consume('NavSettingsPathStack') SettingsPageInfos: NavPathStack
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  @StorageLink('currentHeightBreakpoint') heightBp: HeightBreakpoint = 0
  @StorageLink('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1
  @State busy: boolean = false
  private context = this.getUIContext().getHostContext()! as common.UIAbilityContext

  @Builder
  ActionRow(icon: Resource, title: ResourceStr, subtitle: ResourceStr, destructive: boolean = false) {
    Row() {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([destructive ? Color.Red : this.icon_emphasize])
        .margin({ right: 12 })
      Column({ space: 3 }) {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(destructive ? Color.Red : $r('sys.color.font_primary'))
        Text(subtitle)
          .fontSize(14)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ right: 8 })
      if (this.busy) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(this.icon_emphasize)
      } else {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(24)
          .fontColor([$r('sys.color.icon_primary')])
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 68 })
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.container_background'))
    .borderRadius(20)
  }

  @Builder
  ResetButton() {
    Button($r('app.string.data_confirm_reset'))
      .backgroundColor($r('app.color.container_background'))
      .width('100%')
      .height(39)
      .fontColor(this.icon_emphasize)
  }

  @Builder
  DeleteButton() {
    Button($r('app.string.data_confirm_delete'))
      .backgroundColor($r('app.color.container_background'))
      .width('100%')
      .height(39)
      .fontColor(Color.Red)
  }

  resetUiDialog: CustomDialogController = new CustomDialogController({
    builder: theRowCustomDialog({
      theDialogTitle: $r('app.string.data_reset_ui'),
      contentText: $r('app.string.data_reset_ui_confirm'),
      cancel: () => {},
      confirm: () => this.resetUi(),
      leftButton: this.ResetButton
    })
  })

  clearProfilesDialog: CustomDialogController = new CustomDialogController({
    builder: theRowCustomDialog({
      theDialogTitle: $r('app.string.data_clear_profiles'),
      contentText: $r('app.string.data_clear_profiles_confirm'),
      cancel: () => {},
      confirm: () => this.clearProfiles(),
      leftButton: this.DeleteButton
    })
  })

  fullResetDialog: CustomDialogController = new CustomDialogController({
    builder: theRowCustomDialog({
      theDialogTitle: $r('app.string.data_full_reset'),
      contentText: $r('app.string.data_full_reset_confirm'),
      cancel: () => {},
      confirm: () => this.fullReset(),
      leftButton: this.DeleteButton
    })
  })

  private finishAndRestart(message: ResourceStr): void {
    this.busy = false
    Xb_ToastUtil.showToast({ message: message, duration: 1800 })
    setTimeout((): void => {
      Xb_ToastUtil.restartApp()
    }, 1200)
  }

  async resetUi(): Promise<void> {
    if (this.busy) return
    this.busy = true
    try {
      await AppState.ResetUserInterface()
      this.finishAndRestart($r('app.string.data_reset_complete'))
    } catch (_) {
      this.busy = false
      Xb_ToastUtil.showToast({ message: $r('app.string.data_operation_failed') })
    }
  }

  async clearProfiles(): Promise<void> {
    if (this.busy) return
    this.busy = true
    try {
      await AppState.ClearProfilesAndCredentials(this.context)
      this.finishAndRestart($r('app.string.data_profiles_cleared'))
    } catch (_) {
      this.busy = false
      Xb_ToastUtil.showToast({ message: $r('app.string.data_operation_failed') })
    }
  }

  async fullReset(): Promise<void> {
    if (this.busy) return
    this.busy = true
    try {
      await AppState.ResetConfig(this.context)
      this.finishAndRestart($r('app.string.data_full_reset_complete'))
    } catch (_) {
      this.busy = false
      Xb_ToastUtil.showToast({ message: $r('app.string.data_operation_failed') })
    }
  }

  build() {
    NavDestination() {
      TopBuilder({
        title: $r('app.string.data_management'),
        pathStack: this.SettingsPageInfos
      })
      List({ space: 10 }) {
        ListItem() {
          this.ActionRow($r('sys.symbol.paintpalette_fill'),
            $r('app.string.data_reset_ui'), $r('app.string.data_reset_ui_subtitle'))
        }
        .enabled(!this.busy)
        .onClick(() => this.resetUiDialog.open())

        ListItem() {
          this.ActionRow($r('sys.symbol.folder_fill'),
            $r('app.string.data_clear_profiles'), $r('app.string.data_clear_profiles_subtitle'), true)
        }
        .enabled(!this.busy)
        .onClick(() => this.clearProfilesDialog.open())

        ListItem() {
          this.ActionRow($r('sys.symbol.trash_fill'),
            $r('app.string.data_full_reset'), $r('app.string.data_full_reset_subtitle'), true)
        }
        .enabled(!this.busy)
        .onClick(() => this.fullResetDialog.open())

        ListItem() {
          Text($r('app.string.data_management_tip'))
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

export default WipeData
