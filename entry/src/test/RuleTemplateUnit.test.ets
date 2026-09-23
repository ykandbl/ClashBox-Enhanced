import { describe, it, expect } from '@ohos/hypium'
import { RuleTemplate, RuleTemplateManager } from '../main/ets/common/utils/RuleTemplateService'
import { buildSmartRuntimeConfig } from 'proxy_core'

export default function ruleTemplateUnitTest() {
  describe('ruleTemplateUnitTest', () => {
    it('initializesBuiltInTemplates', 0, () => {
      const manager: RuleTemplateManager = new RuleTemplateManager()
      const templates: RuleTemplate[] = manager.list()
      expect(templates.length).assertEqual(2)
      expect(templates[0].builtIn).assertTrue()
      expect(templates[1].id).assertEqual('builtin-ai-proxy')
    })

    it('filtersMatchRulesWhenTemplateIsEnabled', 0, () => {
      const manager: RuleTemplateManager = new RuleTemplateManager()
      manager.setEnabled('builtin-ai-proxy', true)
      const rules: string[] = manager.enabledRules()
      expect(rules.some((rule: string): boolean => /^MATCH\s*,/i.test(rule))).assertFalse()
      expect(rules.join('\n').includes('openai.com')).assertTrue()
    })

    it('resolvesMatchPlaceholderAgainstSubscriptionProxyGroup', 0, () => {
      const source: string = 'proxies:\n  - name: node-a\n    type: ss\n    server: example.com\n    port: 443\nproxy-groups:\n  - name: PROXY\n    type: select\n    proxies: [node-a]\nrules:\n  - MATCH,PROXY\n'
      const runtime: string = buildSmartRuntimeConfig(source, ['DOMAIN-SUFFIX,chatgpt.com,MATCH'])
      expect(runtime.includes('DOMAIN-SUFFIX,chatgpt.com,PROXY')).assertTrue()
      expect(runtime.includes('MATCH,PROXY')).assertTrue()
      expect(runtime.includes('DOMAIN-SUFFIX,chatgpt.com,MATCH')).assertFalse()
    })

    it('rejectsRemovingBuiltInAndAllowsRemovingCustom', 0, () => {
      const manager: RuleTemplateManager = new RuleTemplateManager()
      expect(manager.remove('builtin-local-direct')).assertFalse()
      manager.save({ id: 'custom-fixture', name: '测试模板', description: '', enabled: false,
        rules: ['DOMAIN,example.com,DIRECT'], builtIn: false, updatedAt: Date.now() })
      expect(manager.remove('custom-fixture')).assertTrue()
      expect(manager.list().some((item: RuleTemplate): boolean => item.id === 'custom-fixture')).assertFalse()
    })

    it('roundTripsImportAndExportFormat', 0, () => {
      const manager: RuleTemplateManager = new RuleTemplateManager()
      manager.save({ id: 'custom-export', name: '导出模板', description: 'fixture', enabled: true,
        rules: ['DOMAIN-SUFFIX,example.com,DIRECT'], builtIn: false, updatedAt: Date.now() })
      const exported: string = manager.exportJson()
      expect(exported.includes('"version": 1')).assertTrue()
      const imported: RuleTemplateManager = new RuleTemplateManager()
      expect(imported.importJson(exported)).assertEqual(1)
      expect(imported.list().some((item: RuleTemplate): boolean => item.id === 'custom-export')).assertTrue()
    })

    it('filtersEmptyAndInvalidRules', 0, () => {
      const manager: RuleTemplateManager = new RuleTemplateManager()
      manager.save({ id: 'custom-invalid', name: '含无效规则', description: '', enabled: true,
        rules: ['', 'DOMAIN,example.com', 'DOMAIN,valid.example,DIRECT', 'MATCH,GLOBAL'],
        builtIn: false, updatedAt: Date.now() })
      const item: RuleTemplate | undefined = manager.list().find((value: RuleTemplate): boolean => value.id === 'custom-invalid')
      expect(item !== undefined).assertTrue()
      expect(item?.rules.join(',')).assertEqual('DOMAIN,valid.example,DIRECT')
    })

    it('doesNotSaveTemplateWithoutAnyValidRule', 0, () => {
      const manager: RuleTemplateManager = new RuleTemplateManager()
      manager.save({ id: 'custom-empty', name: '空模板', description: '', enabled: true,
        rules: ['', 'DOMAIN,example.com', 'MATCH,GLOBAL'], builtIn: false, updatedAt: Date.now() })
      expect(manager.list().some((item: RuleTemplate): boolean => item.id === 'custom-empty')).assertFalse()
    })
  })
}
