import { UIConfig, AppState, AppConfig } from '../../entryability/AppState'
import ClashViewModel from '../../entryability/ClashViewModel'
import BackgroundDownService from '../../common/utils/BackgroundDownService'
import { PageMargin } from '../../common/breakpoint/BreakPoint'
import TopBuilder from './TopBuilder'
import { picker, fileUri } from '@kit.CoreFileKit'
import fs from '@ohos.file.fs'
import { buildRedactedDiagnostics, DiagnosticProfileSnapshot } from '../../common/utils/RuntimeDiagnosticsService'

@Component
struct RuntimeDiagnostics {
  @Consume('NavSettingsPathStack') SettingsPageInfos: NavPathStack
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  @StorageLink('appConfig') appConfig: AppConfig = new AppConfig()
  @StorageLink('autoFailoverState') autoFailoverState: string = 'inactive'
  @StorageLink('autoFailoverFailures') autoFailoverFailures: number = 0
  @StorageLink('autoFailoverDetail') autoFailoverDetail: string = 'VPN 未连接'
  @StorageLink('currentHeightBreakpoint') heightBp: HeightBreakpoint = 0
  @StorageLink('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1

  @State vpnRunning: boolean = false
  @State continuousTaskRunning: boolean = false
  @State coreReady: boolean = false
  @State refreshing: boolean = false
  @State exporting: boolean = false
  private refreshTimer: number = -1

  refresh(): void {
    if (this.refreshing) return
    this.refreshing = true
    this.vpnRunning = ClashViewModel.vpnStarted
    this.continuousTaskRunning = BackgroundDownService.isContinuousTaskRunning()
    this.coreReady = ClashViewModel.isVpnRuntimeHealthy()
    this.refreshing = false
  }

  aboutToAppear(): void {
    this.refresh()
    this.refreshTimer = setInterval(() => this.refresh(), 5000)
  }

  aboutToDisappear(): void {
    if (this.refreshTimer !== -1) clearInterval(this.refreshTimer)
    this.refreshTimer = -1
  }

  async exportDiagnostics(): Promise<void> {
    if (this.exporting) return
    this.exporting = true
    try {
      const profiles = await ClashViewModel.getProfiles()
      const snapshots: DiagnosticProfileSnapshot[] = profiles.map((profile): DiagnosticProfileSnapshot => ({
        id: profile.id,
        provider: profile.accountProvider,
        accountState: profile.accountState,
        subscriptionState: profile.subscriptionState,
        subscriptionFormat: profile.subscriptionFormat,
        subscriptionNodeCount: profile.subscriptionNodeCount,
        lastGoodContentId: profile.lastGoodContentId,
        subscriptionPendingRepair: profile.subscriptionPendingRepair,
        subscriptionRetryAt: profile.subscriptionRetryAt,
        coreLoadState: profile.coreLoadState,
        coreLoadedContentId: profile.coreLoadedContentId,
        coreLoadedAt: profile.coreLoadedAt,
        lastError: profile.subscriptionError || profile.accountError
      }))
      const payload = buildRedactedDiagnostics({
        generatedAt: new Date().toISOString(),
        appVersion: AppState.versionName,
        coreVersion: AppState.coreVersion,
        vpnRunning: this.vpnRunning,
        tunHealthy: this.coreReady,
        backgroundTaskRunning: this.continuousTaskRunning,
        offlineRecordCount: ClashViewModel.socketProxy.offlineTime.length,
        profiles: snapshots,
        recentErrors: snapshots.map((item) => item.lastError).filter((item) => !!item)
      })
      const context = this.getUIContext().getHostContext()!
      const filePicker = new picker.DocumentViewPicker(context)
      const options = new picker.DocumentSaveOptions()
      options.newFileNames = [`clashbox_diagnostics_${Date.now()}.json`]
      options.fileSuffixChoices = ["'JSON|.json'"]
      options.pickerMode = picker.DocumentPickerMode.DOWNLOAD
      const result = await filePicker.save(options)
      const path = new fileUri.FileUri(result[0] + `/clashbox_diagnostics_${Date.now()}.json`).path
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
      try {
        fs.writeSync(file.fd, payload)
        fs.fsyncSync(file.fd)
      } finally {
        fs.closeSync(file.fd)
      }
      this.getUIContext().getPromptAction().showToast({ message: '脱敏诊断包已导出' })
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: `诊断包导出失败：${(error as Error).message}` })
    } finally {
      this.exporting = false
    }
  }

  @Builder
  StatusRow(title: ResourceStr, value: ResourceStr, color: ResourceColor) {
    Row() {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
        Text(value)
          .fontSize(14)
          .fontColor(color)
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      Row()
        .width(10)
        .height(10)
        .borderRadius(10)
        .backgroundColor(color)
    }
    .width('100%')
    .height(58)
    .padding({ left: 14, right: 14 })
  }

  private failoverEnabled(): boolean {
    return this.appConfig.autoFailoverEnabled !== false
  }

  private failoverColor(): ResourceColor {
    if (this.autoFailoverState === 'healthy' || this.autoFailoverState === 'switched' ||
      this.autoFailoverState === 'monitoring') return '#20A464'
    if (this.autoFailoverState === 'warning' || this.autoFailoverState === 'protected' ||
      this.autoFailoverState === 'cooldown' || this.autoFailoverState === 'checking_candidate') return '#E6A12A'
    if (this.autoFailoverState === 'failed' || this.autoFailoverState === 'error' ||
      this.autoFailoverState === 'no_candidate') return '#E84040'
    return $r('sys.color.font_secondary')
  }

  build() {
    NavDestination() {
      TopBuilder({
        title: $r('app.string.runtime_diagnostics'),
        pathStack: this.SettingsPageInfos
      })
      List({ space: 10 }) {
        ListItem() {
          Row() {
            Text($r('app.string.runtime_status_title'))
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
            Blank()
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(24)
              .fontColor([this.icon_emphasize])
              .rotate({ angle: this.refreshing ? 360 : 0 })
              .animation({ duration: 500, curve: Curve.Ease })
              .onClick(() => this.refresh())
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 12, bottom: 8 })
        }
        .backgroundColor($r('app.color.container_background'))
        .borderRadius(20)

        ListItem() {
          Button(this.exporting ? '正在生成…' : '导出脱敏诊断包')
            .width('100%')
            .onClick(() => this.exportDiagnostics())
        }
        .backgroundColor($r('app.color.container_background'))
        .borderRadius(20)

        ListItem() {
          Column() {
            this.StatusRow(
              $r('app.string.runtime_vpn_tunnel'),
              this.vpnRunning ? $r('app.string.runtime_running') : $r('app.string.runtime_stopped'),
              this.vpnRunning ? '#20A464' : $r('sys.color.font_secondary'))
            Row().height(0.5).backgroundColor($r('app.color.divider')).width('93%')
            this.StatusRow(
              $r('app.string.runtime_background_task'),
              this.continuousTaskRunning ? $r('app.string.runtime_normal') :
                (this.vpnRunning ? $r('app.string.runtime_abnormal') : $r('app.string.runtime_follow_vpn')),
              this.continuousTaskRunning ? '#20A464' :
                (this.vpnRunning ? '#E84040' : $r('sys.color.font_secondary')))
            Row().height(0.5).backgroundColor($r('app.color.divider')).width('93%')
            this.StatusRow(
              $r('app.string.runtime_core_rpc'),
              this.coreReady ? $r('app.string.runtime_normal') : $r('app.string.runtime_not_ready'),
              this.coreReady ? '#20A464' : '#E6A12A')
          }
        }
        .backgroundColor($r('app.color.container_background'))
        .borderRadius(20)

        ListItem() {
          Column() {
            Row() {
              Column({ space: 4 }) {
                Text('节点自动接管')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                Text('约每分钟主备检查；连续3次失败才切换，人工选择保护2分钟，切换后冷却5分钟')
                  .fontSize(12)
                  .fontColor($r('sys.color.font_secondary'))
                  .maxLines(2)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: this.failoverEnabled() })
                .onChange((enabled: boolean): void => ClashViewModel.setAutoFailoverEnabled(enabled))
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 12, bottom: 10 })
            Row().height(0.5).backgroundColor($r('app.color.divider')).width('93%')
            Row({ space: 8 }) {
              Row()
                .width(10)
                .height(10)
                .borderRadius(10)
                .backgroundColor(this.failoverColor())
              Column({ space: 2 }) {
                Text(this.failoverEnabled() ? `实时状态 · ${this.autoFailoverFailures}/3` : '实时状态 · 已关闭')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.failoverColor())
                Text(this.autoFailoverDetail)
                  .fontSize(12)
                  .fontColor($r('sys.color.font_secondary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 10, bottom: 12 })
          }
        }
        .backgroundColor($r('app.color.container_background'))
        .borderRadius(20)

        ListItem() {
          Column() {
            this.StatusRow($r('app.string.runtime_architecture'),
              $r('app.string.runtime_architecture_foreground'), this.icon_emphasize)
            Row().height(0.5).backgroundColor($r('app.color.divider')).width('93%')
            this.StatusRow($r('app.string.Kernel_Version'), AppState.coreVersion,
              $r('sys.color.font_secondary'))
          }
        }
        .backgroundColor($r('app.color.container_background'))
        .borderRadius(20)

        ListItem() {
          Row() {
            Column({ space: 3 }) {
              Text($r('app.string.runtime_disconnect_record'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
              Text(`${ClashViewModel.socketProxy.offlineTime.length}`)
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(24)
              .fontColor([$r('sys.color.icon_primary')])
          }
          .width('100%')
          .height(58)
          .padding({ left: 14, right: 14 })
        }
        .backgroundColor($r('app.color.container_background'))
        .borderRadius(20)
        .onClick(() => this.SettingsPageInfos.pushPathByName('offline-detail', false))

        ListItem() {
          Text($r('app.string.runtime_background_explanation'))
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

export default RuntimeDiagnostics
