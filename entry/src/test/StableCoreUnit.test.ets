import { describe, it, expect } from '@ohos/hypium'
import { Profile, ProfileType, SubscriptionInfo } from 'proxy_core'
import { formatQuotaBytes } from '../main/ets/common/utils/QuotaFormatUtil'
import { bitzClashSubscriptionUrl, bitzSubscriptionHash, BitzNetQuotaService, normalizeBitzSubscriptionUrl } from '../main/ets/common/utils/BitzNetQuotaService'
import SubscriptionCompatibilityService from '../main/ets/common/utils/SubscriptionCompatibilityService'
import { isYhcRenewalPlaceholderName,
  isYhcSubscriptionExpired } from '../main/ets/common/utils/YhcAccountService'
import NodeQualityService, { medianNumber, nodeQualityCacheKey, selectQualityCandidates,
  autoFailoverHistoryScore, dailyExperienceScore, summarizeNodeQualityHistory,
  transferSpeedMbps } from '../main/ets/common/utils/NodeQualityService'

export default function stableCoreUnitTest() {
  describe('stableCoreUnitTest', () => {
    it('keepsFractionalQuotaInsteadOfRoundingToIntegerGb', 0, () => {
      expect(formatQuotaBytes(1.51 * Math.pow(1024, 3))).assertEqual('1.51 GB')
      expect(formatQuotaBytes(80 * Math.pow(1024, 3))).assertEqual('80 GB')
      expect(formatQuotaBytes(989 * Math.pow(1024, 2))).assertEqual('989 MB')
    })

    it('parsesStandardSubscriptionUserInfoHeader', 0, () => {
      const info = SubscriptionInfo.formHString(
        'upload=536870912; download=1084479242; total=85899345920; expire=1790092800')
      expect(info.upload + info.download).assertEqual(1621350154)
      expect(info.total).assertEqual(85899345920)
      expect(formatQuotaBytes(info.upload + info.download)).assertEqual('1.51 GB')
      expect(info.state).assertEqual('known')
    })

    it('doesNotInventUnlimitedQuotaWhenTotalIsMissing', 0, () => {
      const info = SubscriptionInfo.formHString('upload=1024; download=2048')
      expect(info.total).assertEqual(0)
      expect(info.state).assertEqual('header-no-total')
    })

    it('keepsCoreLoadFailureIndependentFromSubscriptionRepair', 0, () => {
      const profile = new Profile(ProfileType.Url, 'https://example.com/sub')
      profile.subscriptionState = 'ok'
      profile.subscriptionError = ''
      profile.subscriptionPendingRepair = false
      profile.subscriptionRetryAt = 0
      profile.markCoreLoadFailure('fixture core apply failure', 1234)
      expect(profile.coreLoadState).assertEqual('error')
      expect(profile.coreLoadedAt).assertEqual(1234)
      expect(profile.subscriptionState).assertEqual('ok')
      expect(profile.subscriptionError).assertEqual('')
      expect(profile.subscriptionPendingRepair).assertFalse()
      expect(profile.subscriptionRetryAt).assertEqual(0)
    })

    it('detectsYhcExpiryTransitionWithoutTreatingUnknownAsExpired', 0, () => {
      const expired = new SubscriptionInfo()
      expired.state = 'account-expired'
      expect(isYhcSubscriptionExpired(expired, 2000)).assertTrue()
      const renewed = new SubscriptionInfo()
      renewed.state = 'unlimited'
      renewed.expire = 3
      expect(isYhcSubscriptionExpired(renewed, 2000)).assertFalse()
      expect(isYhcSubscriptionExpired(new SubscriptionInfo(), 2000)).assertFalse()
    })

    it('recognizesYhcRenewalPlaceholderNodes', 0, () => {
      expect(isYhcRenewalPlaceholderName('订阅已到期，请充值后使用')).assertTrue()
      expect(isYhcRenewalPlaceholderName('套餐过期，请续费')).assertTrue()
      expect(isYhcRenewalPlaceholderName('Hong Kong 01')).assertFalse()
    })

    it('matchesBitzNetOfficialDjb2SubscriptionHash', 0, () => {
      expect(bitzSubscriptionHash('proxies:\n  - name: fixture\n')).assertEqual('61409a4')
    })

    it('upgradesPanelHttpSubscriptionWithoutChangingItsToken', 0, () => {
      expect(normalizeBitzSubscriptionUrl('http://panel.example/api/sub?token=fixture&flag=clash'))
        .assertEqual('https://panel.example/api/sub?token=fixture&flag=clash')
      expect(normalizeBitzSubscriptionUrl(' HTTPS://panel.example/api/sub?token=fixture '))
        .assertEqual('https://panel.example/api/sub?token=fixture')
      expect(normalizeBitzSubscriptionUrl('file:///config.yaml')).assertEqual('')
      expect(normalizeBitzSubscriptionUrl('https://user@third.example/sub')).assertEqual('')
    })

    it('explicitlyRequestsClashYamlInsteadOfDefaultBase64Links', 0, () => {
      expect(bitzClashSubscriptionUrl('http://panel.example/sub?token=fixture'))
        .assertEqual('https://panel.example/sub?token=fixture&flag=clash')
      expect(bitzClashSubscriptionUrl('https://panel.example/sub?flag=v2ray&token=a%2Bb#ignored'))
        .assertEqual('https://panel.example/sub?token=a%2Bb&flag=clash')
      expect(bitzClashSubscriptionUrl('file:///config.yaml')).assertEqual('')
    })

    it('redactsSubscriptionUrlAndLongTokenFromDiagnosticReason', 0, () => {
      const longToken = 'a'.repeat(160)
      const reason = BitzNetQuotaService.sanitizeLogReason(
        `request https://TARGET.example/sub?token=private failed ${longToken}`)
      expect(reason.includes('TARGET.example')).assertFalse()
      expect(reason.includes(longToken)).assertFalse()
      expect(reason.includes('[url]')).assertTrue()
      expect(reason.includes('[secret]')).assertTrue()
    })

    it('distinguishesTransientBitzGatewayErrorsFromCredentialFailures', 0, () => {
      expect(BitzNetQuotaService.isTransientError('连接超时')).assertTrue()
      expect(BitzNetQuotaService.isTransientError('额度接口 HTTP 429')).assertTrue()
      expect(BitzNetQuotaService.isTransientError('额度接口 HTTP 503')).assertTrue()
      expect(BitzNetQuotaService.isTransientError('Failed to connect to host')).assertTrue()
      expect(BitzNetQuotaService.isTransientError('TLS handshake closed')).assertTrue()
      expect(BitzNetQuotaService.isTransientError('登录接口 HTTP 401')).assertFalse()
      expect(BitzNetQuotaService.isTransientError('账号密码错误')).assertFalse()
    })

    it('keepsHttpStatusWhenBitzGatewayAlsoReturnsAMessage', 0, () => {
      const overloaded = BitzNetQuotaService.httpFailureReason('额度接口', 503, '服务繁忙')
      expect(overloaded).assertEqual('额度接口 HTTP 503：服务繁忙')
      expect(BitzNetQuotaService.isTransientError(overloaded)).assertTrue()
      const unauthorized = BitzNetQuotaService.httpFailureReason('登录接口', 401, '请重新登录')
      expect(BitzNetQuotaService.isTransientError(unauthorized)).assertFalse()
      expect(BitzNetQuotaService.preferredFailureReason(
        '账号登录 HTTP 503：服务繁忙', '账号登录 HTTP 401：账号不存在'))
        .assertEqual('账号登录 HTTP 503：服务繁忙')
    })

    it('recognizesClashYamlAndJsonSubscriptions', 0, () => {
      const yaml = SubscriptionCompatibilityService.inspectClashContent(
        'proxies:\n  - name: fixture-a\n    type: ss\n    server: example.com\n    port: 443\n')
      expect(yaml.valid).assertTrue()
      expect(yaml.format).assertEqual('Clash YAML')
      expect(yaml.proxyCount).assertEqual(1)

      const json = SubscriptionCompatibilityService.inspectClashContent(
        '{"proxies":[{"name":"fixture-b","type":"ss","server":"example.com","port":443}]}')
      expect(json.valid).assertTrue()
      expect(json.format).assertEqual('Clash JSON')
      expect(json.proxyCount).assertEqual(1)
    })

    it('recognizesProviderOnlySubscriptionAndRejectsErrorPages', 0, () => {
      const provider = SubscriptionCompatibilityService.inspectClashContent(
        'proxy-providers:\n  service-a:\n    type: http\n    url: https://example.com/sub\n')
      expect(provider.valid).assertTrue()
      expect(provider.providerCount).assertEqual(1)
      const providers = SubscriptionCompatibilityService.inspectClashContent(
        'proxy-providers:\n  service-a:\n    type: http\n  service-b:\n    type: file\n')
      expect(providers.providerCount).assertEqual(2)
      const jsonProviders = SubscriptionCompatibilityService.inspectClashContent(
        '{"proxy-providers":{"service-a":{"type":"http"},"service-b":{"type":"file"}}}')
      expect(jsonProviders.providerCount).assertEqual(2)
      expect(SubscriptionCompatibilityService.inspectClashContent('<html>captcha</html>').valid).assertFalse()
    })

    it('calculatesNodeTransferSpeedInDecimalMbps', 0, () => {
      expect(transferSpeedMbps(1024 * 1024, 1000)).assertEqual(8.39)
      expect(transferSpeedMbps(0, 1000)).assertEqual(0)
      expect(medianNumber([410, 110, 210])).assertEqual(210)
    })

    it('selectsOnlyTheFastestSuccessfulQualityCandidates', 0, () => {
      const selected = selectQualityCandidates([
        { name: 'slow', delay: 800, status: 'ok' },
        { name: 'failed', delay: -1, status: 'failed' },
        { name: 'fast', delay: 120, status: 'ok' },
        { name: 'middle', delay: 320, status: 'ok' },
        { name: 'fourth', delay: 900, status: 'ok' }
      ], 3)
      expect(selected.join(',')).assertEqual('fast,middle,slow')
      expect(NodeQualityService.expectedTrafficBytes('stability')).assertEqual(640 * 1024)
      expect(NodeQualityService.expectedTrafficBytes('bandwidth')).assertEqual(0)
      expect(NodeQualityService.expectedTrafficBytes('bandwidth_economy')).assertEqual(0)
      expect(NodeQualityService.expectedTrafficBytes('bandwidth_standard')).assertEqual(0)
      expect(NodeQualityService.expectedTrafficBytes('bandwidth_full')).assertEqual(0)
      expect(nodeQualityCacheKey('profile', 'group-a', 'same-node'))
        .assertEqual(nodeQualityCacheKey('profile', 'group-b', 'same-node'))
    })

    it('scoresStableDailyExperienceAboveUnstableRawBandwidth', 0, () => {
      const stable = NodeQualityService.fromCore('p', 1, 'g', 'stable',
        'bandwidth_single_sustained', 'ok', '样本稳定', 0, 0, 100,
        60, 15, 0, '', '', true, 8, 10)
      const unstable = NodeQualityService.fromCore('p', 1, 'g', 'unstable',
        'bandwidth_single_sustained', 'ok', '波动大', 0, 0, 85,
        300, 80, 0, '', '', false, 75, 80)
      expect(dailyExperienceScore(stable, 120) > dailyExperienceScore(unstable, 500)).assertTrue()
    })

    it('prefersRepeatedReliableHistoryForAutomaticFailover', 0, () => {
      const steady = summarizeNodeQualityHistory([
        { profileId: 'p', profileUpdatedAt: 1, group: 'g', name: 'steady',
          mode: 'bandwidth_single_sustained', status: 'ok', checkedAt: 1, latencyMs: 120,
          successRate: 100, downloadMbps: 40, uploadMbps: 12, reliable: true,
          downloadVariationPercent: 8, uploadVariationPercent: 10, experienceScore: 85 },
        { profileId: 'p', profileUpdatedAt: 1, group: 'g', name: 'steady',
          mode: 'bandwidth_single_sustained', status: 'ok', checkedAt: 2, latencyMs: 130,
          successRate: 100, downloadMbps: 42, uploadMbps: 13, reliable: true,
          downloadVariationPercent: 9, uploadVariationPercent: 11, experienceScore: 87 }
      ])
      const broken = summarizeNodeQualityHistory([
        { profileId: 'p', profileUpdatedAt: 1, group: 'g', name: 'broken', mode: 'stability',
          status: 'failed', checkedAt: 1, latencyMs: 0, successRate: 0, downloadMbps: 0,
          uploadMbps: 0, reliable: false, downloadVariationPercent: 100,
          uploadVariationPercent: 100, experienceScore: 0 }
      ])
      expect(autoFailoverHistoryScore(steady) > autoFailoverHistoryScore(broken)).assertTrue()
    })
  })
}
