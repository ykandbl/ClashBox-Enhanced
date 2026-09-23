import { RuleTemplate, RuleTemplateService } from '../../../common/utils/RuleTemplateService'
import { UIConfig } from '../../../entryability/AppState'
import { PageMargin, NeedClearMoreStack } from '../../../common/breakpoint/BreakPoint'
import { TAB_CONTENT_TITLE_HEIGHT } from '../../../common/entity/Constants'
import { MoreTop } from '../MoreTopBuilder'
import ClashViewModel from '../../../entryability/ClashViewModel'
import { Xb_ToastUtil } from 'xb_components'

@Builder
export function RuleTemplatesBuilder(name: string, param: Object) { RuleTemplates() }

@Component
export struct RuleTemplates {
  private pageInfos: NavPathStack = AppStorage.get<NavPathStack>('NavPathStack') as NavPathStack
  private morePageInfos: NavPathStack = AppStorage.get<NavPathStack>('MoreNavPathStack') as NavPathStack
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  @StorageLink('ruleTemplateRevision') revision: number = 0
  @StorageLink('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1
  @StorageProp('topRectHeight') topRectHeight: number = 0
  @State templates: RuleTemplate[] = []
  @State editorVisible: boolean = false
  @State editing: RuleTemplate | undefined = undefined
  @Consume isEnableIndexForegroundBlur: boolean
  @Consume isSecondary: boolean
  @Consume curYOffset: number

  aboutToAppear(): void { this.reload() }
  private reload(): void { this.templates = RuleTemplateService.list() }
  private changed(message: string): void {
    this.revision += 1
    this.reload()
    ClashViewModel.loadConfig(true, 'RuleTemplateChange').catch(() => {})
    Xb_ToastUtil.showToast({ message })
  }
  private openEditor(item?: RuleTemplate): void {
    this.editing = item
    this.isEnableIndexForegroundBlur = true
    this.editorVisible = true
  }
  private closeEditor(): void {
    this.editorVisible = false
    this.isEnableIndexForegroundBlur = false
    this.editing = undefined
  }

  build() {
    NavDestination() {
      Stack() {
        MoreTop({ title: $r('app.string.RuleTemplates') })
        Column() {
          Blank().height(TAB_CONTENT_TITLE_HEIGHT + (this.widthBp < 2 ? this.topRectHeight : 0) + 6)
          Row({ space: 8 }) {
            Text('启用的模板会在每次配置加载时注入 runtime.yaml，不修改原始订阅文件。')
              .fontSize(14).fontColor($r('sys.color.font_secondary')).layoutWeight(1)
            Button('新增').onClick(() => this.openEditor())
          }.padding({ left: PageMargin(this.widthBp, 0), right: PageMargin(this.widthBp, 0) })
          Scroll() {
            List({ space: 10 }) {
              ForEach(this.templates, (item: RuleTemplate) => {
                ListItem() {
                  Row({ space: 10 }) {
                    Column() {
                      Text(item.name).fontSize(17).fontWeight(FontWeight.Medium)
                      Text(item.description || `${item.rules.length} 条规则`)
                        .fontSize(13).fontColor($r('sys.color.font_secondary')).maxLines(2)
                      Text(`${item.rules.length} 条规则${item.builtIn ? ' · 内置' : ' · 自定义'}`)
                        .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                    Toggle({ type: ToggleType.Switch, isOn: item.enabled })
                      .onChange((enabled: boolean) => {
                        RuleTemplateService.setEnabled(item.id, enabled)
                        this.changed(enabled ? '模板已启用' : '模板已停用')
                      })
                    Button('编辑').onClick(() => this.openEditor(item))
                    if (!item.builtIn) {
                      Button('删除').fontColor(Color.Red).onClick(() => {
                        if (RuleTemplateService.remove(item.id)) this.changed('模板已删除')
                      })
                    }
                  }.padding(16).width('100%')
                }.backgroundColor($r('app.color.container_background')).borderRadius(18)
              }, (item: RuleTemplate) => item.id)
            }.padding({ left: PageMargin(this.widthBp, 0), right: PageMargin(this.widthBp, 0) })
          }.layoutWeight(1)
        }.width('100%').height('100%')
      }
    }
    .hideTitleBar(true).backgroundColor($r('app.color.background'))
    .bindSheet($$this.editorVisible, this.editorBuilder(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE], dragBar: false,
      onWillDismiss: () => this.closeEditor()
    })
    .onBackPressed(() => {
      if (NeedClearMoreStack(this.widthBp, 0)) { this.pageInfos.clear(); this.isSecondary = false }
      else if (this.widthBp < 2) this.pageInfos.pop(true)
      else this.morePageInfos.pop(true)
      return true
    })
  }

  @Builder editorBuilder() {
    RuleTemplateEditor({
      initial: this.editing,
      onCancel: () => this.closeEditor(),
      onSave: (item: RuleTemplate) => {
        RuleTemplateService.save(item)
        this.closeEditor()
        this.changed('模板已保存')
      }
    })
  }
}

@Component
struct RuleTemplateEditor {
  @Prop initial: RuleTemplate | undefined
  onCancel?: () => void
  onSave?: (item: RuleTemplate) => void
  @State name: string = ''
  @State description: string = ''
  @State rulesText: string = ''
  aboutToAppear(): void {
    if (this.initial) {
      this.name = this.initial.name; this.description = this.initial.description
      this.rulesText = this.initial.rules.join('\n')
    }
  }
  build() {
    Column({ space: 10 }) {
      Text(this.initial ? '编辑规则模板' : '新增规则模板').fontSize(20).fontWeight(FontWeight.Bold)
      TextInput({ placeholder: '模板名称', text: this.name }).onChange((value: string) => this.name = value)
      TextInput({ placeholder: '说明（可选）', text: this.description }).onChange((value: string) => this.description = value)
      Text('每行一条 Clash 规则，例如 DOMAIN-SUFFIX,example.com,DIRECT')
        .fontSize(13).fontColor($r('sys.color.font_secondary'))
      TextArea({ placeholder: 'DOMAIN-SUFFIX,example.com,DIRECT', text: this.rulesText })
        .height(180).onChange((value: string) => this.rulesText = value)
      Row({ space: 10 }) {
        Button('取消').layoutWeight(1).onClick(() => this.onCancel?.())
        Button('保存').layoutWeight(1).onClick(() => {
          const rules = this.rulesText.split(/\r?\n/).map((line: string) => line.trim()).filter((line: string) => line.length > 0)
          if (!this.name.trim() || rules.length === 0) { Xb_ToastUtil.showToast({ message: '请填写名称和至少一条规则' }); return }
          this.onSave?.({ id: this.initial?.id ?? `custom-${Date.now()}`, name: this.name.trim(),
            description: this.description.trim(), enabled: this.initial?.enabled ?? false,
            rules, builtIn: this.initial?.builtIn ?? false, updatedAt: Date.now() })
        })
      }.width('100%')
    }.padding(20).width('100%')
  }
}
