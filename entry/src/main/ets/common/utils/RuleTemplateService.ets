import { Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'

export interface RuleTemplate {
  id: string
  name: string
  description: string
  enabled: boolean
  rules: string[]
  builtIn: boolean
  updatedAt: number
}

const STORE_NAME: string = 'ruleTemplatePreference'
const STORE_KEY: string = 'templatesV1'
const DEFAULT_TEMPLATES: RuleTemplate[] = [
  {
    id: 'builtin-local-direct', name: '常用本地直连', description: '常用国内服务直连示例', enabled: false,
    rules: ['DOMAIN-SUFFIX,ntp.org,DIRECT', 'DOMAIN-SUFFIX,baidu.com,DIRECT'], builtIn: true, updatedAt: 0
  },
  {
    id: 'builtin-ai-proxy', name: 'AI 服务走代理', description: '常用 AI 域名交给当前代理出口', enabled: false,
    rules: ['DOMAIN-SUFFIX,openai.com,MATCH', 'DOMAIN-SUFFIX,chatgpt.com,MATCH',
      'DOMAIN-SUFFIX,gemini.google.com,MATCH', 'DOMAIN-SUFFIX,grok.com,MATCH'], builtIn: true, updatedAt: 0
  }
]

function cleanRules(value: Object): string[] {
  if (!Array.isArray(value)) return []
  const result: string[] = []
  ;(value as Object[]).forEach((item: Object): void => {
    const rule: string = String(item).trim()
    if (rule.length > 0 && rule.split(',').length >= 3 && !/^MATCH\s*,/i.test(rule)) result.push(rule)
  })
  return result
}

function copyTemplate(item: RuleTemplate): RuleTemplate {
  return { id: item.id, name: item.name, description: item.description, enabled: item.enabled,
    rules: [...item.rules], builtIn: item.builtIn, updatedAt: item.updatedAt }
}

export class RuleTemplateManager {
  private store?: preferences.Preferences
  private templates: RuleTemplate[] = []

  constructor() {
    this.templates = DEFAULT_TEMPLATES.map(copyTemplate)
  }

  init(context: Context): void {
    this.store = preferences.getPreferencesSync(context, { name: STORE_NAME })
    const raw: string = this.store.getSync(STORE_KEY, '') as string
    let parsed: Object | undefined
    try {
      if (raw) parsed = JSON.parse(raw) as Object
    } catch (_) {
      parsed = undefined
    }
    if (Array.isArray(parsed)) {
      this.templates = []
      ;(parsed as Object[]).forEach((item: Object): void => {
        const normalized: RuleTemplate | undefined = this.normalize(item)
        if (normalized) this.templates.push(normalized)
      })
      let changed: boolean = false
      DEFAULT_TEMPLATES.forEach((defaultTemplate: RuleTemplate): void => {
        if (!this.templates.some((item: RuleTemplate): boolean => item.id === defaultTemplate.id)) {
          this.templates.push(copyTemplate(defaultTemplate))
          changed = true
        }
      })
      if (changed) this.persist()
    } else {
      this.templates = DEFAULT_TEMPLATES.map(copyTemplate)
      this.persist()
    }
  }

  list(): RuleTemplate[] { return this.templates.map(copyTemplate) }

  enabledRules(): string[] {
    const rules: string[] = []
    this.templates.filter((item: RuleTemplate): boolean => item.enabled)
      .forEach((item: RuleTemplate): void => { rules.push(...item.rules) })
    return cleanRules(rules as Object)
  }

  save(item: RuleTemplate): void {
    const normalized: RuleTemplate | undefined = this.normalize(item as Object)
    if (!normalized) return
    const index: number = this.templates.findIndex((current: RuleTemplate): boolean => current.id === normalized.id)
    if (index >= 0) this.templates.splice(index, 1, normalized)
    else this.templates.push(normalized)
    this.persist()
  }

  setEnabled(id: string, enabled: boolean): void {
    const item: RuleTemplate | undefined = this.templates.find((current: RuleTemplate): boolean => current.id === id)
    if (!item) return
    item.enabled = enabled; item.updatedAt = Date.now(); this.persist()
  }

  remove(id: string): boolean {
    const index: number = this.templates.findIndex((item: RuleTemplate): boolean => item.id === id && !item.builtIn)
    if (index < 0) return false
    this.templates.splice(index, 1); this.persist(); return true
  }

  exportJson(): string { return JSON.stringify({ version: 1, templates: this.list() }, null, 2) }

  importJson(content: string): number {
    const parsed: Object = JSON.parse(content) as Object
    const record: Record<string, Object> | undefined = parsed && typeof parsed === 'object' ?
      parsed as Record<string, Object> : undefined
    const values: Object[] = Array.isArray(parsed) ? parsed as Object[] :
      (record && Array.isArray(record.templates) ? record.templates as Object[] : [])
    if (values.length === 0) throw new Error('模板文件格式不正确')
    let count: number = 0
    values.forEach((value: Object): void => {
      const item: RuleTemplate | undefined = this.normalize(value)
      if (!item || item.builtIn) return
      item.builtIn = false
      if (item.id.startsWith('builtin-')) item.id = `custom-${Date.now()}-${count}`
      this.save(item); count++
    })
    return count
  }

  private normalize(value: Object): RuleTemplate | undefined {
    if (!value || typeof value !== 'object') return undefined
    const raw: Record<string, Object> = value as Record<string, Object>
    const name: string = String(raw.name ?? '').trim(); const rules: string[] = cleanRules(raw.rules ?? [])
    if (!name || rules.length === 0) return undefined
    return { id: String(raw.id ?? `custom-${Date.now()}`), name,
      description: String(raw.description ?? '').trim(), enabled: raw.enabled === true, rules,
      builtIn: raw.builtIn === true, updatedAt: Number(raw.updatedAt ?? Date.now()) }
  }

  private persist(): void {
    if (!this.store) return
    this.store.putSync(STORE_KEY, JSON.stringify(this.templates)); this.store.flushSync()
  }
}

export const RuleTemplateService: RuleTemplateManager = new RuleTemplateManager()
