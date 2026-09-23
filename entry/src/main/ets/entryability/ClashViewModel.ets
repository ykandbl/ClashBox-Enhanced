import { ProfileRepo } from "proxy_core/src/main/ets/ProfileRepo";
import { Context, Want } from "@kit.AbilityKit";
import { SocketProxyService, Profile, ProfileType, UpdateConfigParams, ClashConfig, getHome,
  LogInfo,
  Provider,
  ProxyMode,
  ProxySort} from "proxy_core";
import { connection, socket, vpnExtension } from "@kit.NetworkKit";
import { ConfigData } from "../common/entity/PageArgumentEntity";
import { convertTimeGapToMilliseconds } from "../common/entity/Constants";
import { PromptAction } from "@kit.ArkUI";
import { ProxyGroup } from "proxy_core/src/main/ets/models/Common";
import { ConfigExtendedParams } from "proxy_core/src/main/ets/models/ClashConfig";
import { EventHub, EventKey } from "../common/EventHub";
import { AppConfig, AppState, ClashCore, getPackageInfo } from "./AppState";
import  fs from  "@ohos.file.fs"
import { sleep } from "./EntryAbility";
import { ProxyItem } from "../common/datasources/ProxyData";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { readText } from "proxy_core/src/main/ets/fileUtils";
import { AccessControl, VpnRawOptions } from "proxy_core/src/main/ets/rpc/IClashManager";
import { cardManager } from "../common/utils/CardManageUtil";
import { PROXY_STARTED_DURATION_INIT_VALUE } from "../common/entity/Constants";
import { Timer } from "../common/utils/HHmmssTimer";
import { number2Time } from "../common/utils/TimeConvertUtil";
import { picker } from "@kit.CoreFileKit"
import { Xb_GetResourceString, Xb_ToastUtil } from "xb_components";
import { accessControlRdb } from "../common/datasources/AccessControlRdb";
import BackgroundDownService from "../common/utils/BackgroundDownService";
import { RuleTemplateService } from '../common/utils/RuleTemplateService'
import BitzNetQuotaService, { BitzNetCredentialStore,
  BitzNetValidationResult, bitzSubscriptionHash } from "../common/utils/BitzNetQuotaService";
import YhcAccountService, { YhcCredentialStore,
  YhcValidationResult, isYhcRenewalPlaceholderName,
  isYhcSubscriptionExpired } from "../common/utils/YhcAccountService";
import IpPureService from "../common/utils/IpPureService";
import SubscriptionCompatibilityService, {
  CompatibleSubscriptionDownload
} from "../common/utils/SubscriptionCompatibilityService";
import { NodeDelayRunner, NodeDelayResult, NodeDelayProbe, normalizeDelayTestUrl, nodeDelayId,
  nodeDelayErrorText } from '../common/utils/NodeDelayRunner';
import NodeQualityService, { NodeQualityMode, NodeQualityResult, nodeQualityCacheKey,
  NodeQualityHistorySample, NodeQualityHistorySummary, autoFailoverHistoryScore,
  compactNodeQualitySample, dailyExperienceScore,
  selectQualityCandidates, summarizeNodeQualityHistory } from '../common/utils/NodeQualityService';

export type DelayInfo = NodeDelayResult

export interface ProfileUpdateResult {
  total: number
  updated: number
  failed: number
  changed: number
  unchanged: number
  reloaded: number
}

export interface ProfileQuotaRefreshResult {
  total: number
  refreshed: number
  failed: number
  unavailable: number
}

export interface AccountRefreshResult {
  total: number
  refreshed: number
  failed: number
}

export interface NodeQualityBatchResult {
  results: NodeQualityResult[]
  candidates: number
  cached: number
  transferredBytes: number
  ranked?: number
  screened?: number
  screeningSucceeded?: number
}

interface NodeQualityBatchExecution {
  result: NodeQualityResult
  cached: boolean
}

interface ActiveNodeFailoverContext {
  profile: Profile
  group: ProxyGroup
  currentName: string
}

interface AutoFailoverCandidate {
  item: ProxyItem
  score: number
  delay: number
}

interface NetworkIpAddressSnapshot {
  address: string
  family: number
  port: number
}

interface NetworkInterfaceSnapshot {
  iface: string
  macAddress: string
  ipAddress: NetworkIpAddressSnapshot
}

export class ClashViewModel {
  vpnRequestId = 0;
  profileRepo = new ProfileRepo()
  socketProxy = new SocketProxyService()
  context: Context | undefined
  proxyStartedTimer = new Timer()
  private coreStarting: boolean = false
  private vpnOptionsRestartTimer: number = -1
  private vpnOptionsRestarting: boolean = false
  private vpnOptionsRestartPending: boolean = false
  private vpnWatchdogTimer: number = -1
  private vpnExpectedRunning: boolean = false
  private vpnWatchdogRecovering: boolean = false
  private vpnWatchdogProbeRunning: boolean = false
  private vpnWatchdogGeneration: number = 0
  private vpnWatchdogFailures: number = 0
  private lastVpnHealthAt: number = 0
  private nodeFailoverChecking: boolean = false
  private nodeFailoverFailures: number = 0
  private nodeFailoverLastProbeAt: number = 0
  private nodeFailoverLastSwitchAt: number = 0
  private nodeFailoverLastUserChangeAt: number = 0
  private vpnBackgroundRetryTimer: number = -1
  private vpnBackgroundEpoch: number = 0
  private vpnRestoreInProgress: boolean = false
  private vpnRestoreRetryTimer: number = -1
  private vpnRestoreRetryAttempts: number = 0
  /**
   * Start/stop touches one process-wide HarmonyOS VpnConnection.  Serialize the
   * complete lifecycle, not just individual socket RPCs, so a delayed start
   * response can never overlap a restore, watchdog recovery, access-control
   * restart, or a user's next button press.
   */
  private vpnLifecycleQueue: Promise<void> = Promise.resolve()
  /**
   * 所有页面、自动故障转移和恢复逻辑共用同一个节点切换队列。此前每个
   * ProxyGroupItem 只在自身内部排队，快速点击或页面切换时仍可能让多个
   * changeProxy RPC 同时进入原生内核，造成选择器和配置持久化交叉写入。
   */
  private proxyChangeQueue: Promise<void> = Promise.resolve()
  /** Config generation is process-wide. Serialize cold-start, subscription,
   * mode-switch and manual reload requests before they reach native applyConfig. */
  private configLoadQueue: Promise<void> = Promise.resolve()
  /**
   * 记录 UI Ability 进入后台的时刻。Telegram 等即时通讯应用会保留长
   * 连接；物理网络或代理出口在后台期间变化后，旧会话可能停在半连接状态，
   * 应用回到前台却没有收到足够明确的 socket 错误。恢复前台时只淘汰这类
   * “后台前已存在且连续无字节变化”的旧会话，避免粗暴清空所有应用连接。
   */
  private appBackgroundAt: number = 0
  private foregroundRecoveryTimer: number = -1
  private foregroundRecoveryRunning: boolean = false
  /** 避免异常订阅在修复未成功时每分钟重复下载；正常重载后节点占位会消失。 */
  private yhcRenewalRepairAt: Map<string, number> = new Map<string, number>()
  /**
   * 续费修复的下载或核心重载失败后保留待重试标记。账号元数据已经恢复为
   * 有效时，单靠“过期 -> 有效”的瞬时变化无法在下一轮再次进入修复链。
   */
  private yhcRenewalRepairPending: Set<string> = new Set<string>()
  /** Network callbacks arrive in bursts. A generation token makes stale
   * callbacks and a user stop harmless while one recovery is in flight. */
  private networkGeneration: number = 0
  private networkRecoveryTimer: number = -1
  private networkRecoveryRunning: boolean = false
  private networkRecoveryPending: boolean = false
  /** Last physical default network applied to the native route table. */
  private activePhysicalNetworkKey: string = ''
  static promptAction: PromptAction
  async init(context: Context, promptAction: PromptAction) {
    AppState.globalUA =  "clash.meta/1.19.5"
    this.context = context
    ClashViewModel.promptAction = promptAction
    await this.profileRepo.init(context)
    // 配置表此刻已经可以安全读取。GeoIP 文件准备、核心握手和 VPN 状态恢复
    // 都不应阻塞配置页首屏。
    AppStorage.setOrCreate('profileRepoReady', true)
    AppStorage.set('profileRepoReady', true)
    this.socketProxy.init(context, ClashViewModel.promptAction)
    await this.initGeoIp()
  }
  // 添加配置 url
  async addOrUpdateProfileByUrl(data: ConfigData, id: string | null) {
    const ua = AppStorage.get<ClashConfig>("clashConfig")?.["global-ua"]
    const accountProvider = data.accountProvider ?? (data.bitzQuotaEnabled ? 'bitznet' : 'none')
    let bitzValidation: BitzNetValidationResult | null = null
    let yhcValidation: YhcValidationResult | null = null
    if (accountProvider === 'bitznet') {
      try {
        bitzValidation = await BitzNetQuotaService.validateCredentials(
          data.accountUsername?.trim() ?? '', data.accountPassword ?? '', data.configUrl.trim())
      } catch (error) {
        throw new Error(`BitzNet 账号验证失败：${(error as Error).message}`)
      }
    } else if (accountProvider === 'yhc') {
      try {
        yhcValidation = await YhcAccountService.validateCredentials(
          data.accountUsername?.trim() ?? '', data.accountPassword ?? '')
      } catch (error) {
        throw new Error(`萤火虫账号验证失败：${(error as Error).message}`)
      }
    } else if (accountProvider !== 'none') {
      throw new Error('请选择有效的账号服务商')
    }
    let profile = new Profile(ProfileType.Url, data.configUrl.trim())
    if(id) {
      const old = await this.profileRepo.query(id)
      if(old)
        profile = old
    } else {
      // 同一订阅链接误从“新增”入口再次保存时复用原记录，避免生成两张配置卡。
      const normalizedUrl = data.configUrl.trim()
      const duplicate = (await this.profileRepo.queryAll()).find((item: Profile): boolean =>
        item.type === ProfileType.Url && item.url.trim() === normalizedUrl)
      if (duplicate) profile = duplicate
    }
    // 编辑已有配置时，账号验证会先拿到新的有效期；记录旧状态用于识别
    // “过期后续费”场景。仅更新账号元数据而不重新下载 YAML，会让核心继续
    // 使用过期期间生成的单节点充值提示配置。
    const hadExpiredSubscription = isYhcSubscriptionExpired(profile.subscriptionInfo)
    profile.loadContext(this.context, ua)
    profile.url = data.configUrl.trim()
    profile.name = data.configName
    profile.isUpdating = data.disableUpdate
    profile.autoUpdate = data.isConfigAutoUpdate
    profile.accountProvider = accountProvider
    profile.accountState = accountProvider === 'none' ? 'idle' : profile.accountState
    profile.accountError = accountProvider === 'none' ? '' : profile.accountError
    profile.accountUpdatedAt = accountProvider === 'none' ? 0 : profile.accountUpdatedAt
    // 保持旧版数据库字段同步，升级/降级时不会丢失 BitzNet 状态。
    profile.bitzQuotaEnabled = accountProvider === 'bitznet'
    if (!profile.bitzQuotaEnabled) {
      profile.bitzQuotaState = "idle"
      profile.bitzQuotaError = ""
      profile.bitzQuotaUpdatedAt = 0
    }
    // 转换为毫秒
    profile.autoUpdateDuration = convertTimeGapToMilliseconds(
      data.configAutoUpdateTimeGapValue ?? 10,
      data.configAutoUpdateTimeGapTextPickerIndex
    )
    const hasLocalConfig = await profile.check()
    const shouldRefreshRenewedYhc = accountProvider === 'yhc' && !!yhcValidation &&
      hadExpiredSubscription && hasLocalConfig
    let renewedYhcConfigChanged = false
    if (!hasLocalConfig || shouldRefreshRenewedYhc) {
      try {
        if (accountProvider === 'bitznet' && bitzValidation) {
          const download = await BitzNetQuotaService.downloadValidatedSubscription(
            bitzValidation, data.configUrl.trim())
          if (download.format === 'v2ray') {
            download.content = await this.socketProxy.convertV2RaySubscription(download.content)
            download.proxyCount = BitzNetQuotaService.validateSubscriptionContent(download.content)
            download.contentHash = bitzSubscriptionHash(download.content)
          }
          await profile.saveIfChanged(download.content, async (c) => await this.VailConfig(c))
          this.markSubscriptionSuccess(profile, 'Clash YAML', download.proxyCount)
        } else {
          renewedYhcConfigChanged = await this.updateCompatibleSubscription(profile)
        }
      } catch (error) {
        if (shouldRefreshRenewedYhc) {
          const reason = SubscriptionCompatibilityService.sanitizeReason((error as Error).message)
          this.markSubscriptionFailure(profile, reason)
          hilog.warn(0xC012, 'AccountRefresh',
            `萤火虫续费后编辑路径订阅刷新失败，保留旧配置 profileId=${profile.id}, reason=${reason}`)
        } else {
          throw error instanceof Error ? error : new Error(`${error}`)
        }
      }
    }
    const isExists = await profile.check();
    let value: number
    if (isExists) { // 本地文件存在
      if (accountProvider === 'bitznet' && bitzValidation) {
        profile.subscriptionInfo = bitzValidation.subscriptionInfo
        profile.accountState = hadExpiredSubscription ? "restored" : "ok"
        profile.accountError = ""
        profile.accountUpdatedAt = bitzValidation.subscriptionInfo.updatedAt
        profile.bitzQuotaState = profile.accountState
        profile.bitzQuotaError = profile.accountError
        profile.bitzQuotaUpdatedAt = profile.accountUpdatedAt
        await BitzNetCredentialStore.save(profile.id, data.accountUsername?.trim() ?? '',
          data.accountPassword ?? '', bitzValidation.authorization, bitzValidation.apiBase,
          bitzValidation.subscriptionUrl)
        await YhcCredentialStore.remove(profile.id)
      } else if (accountProvider === 'yhc' && yhcValidation) {
        profile.subscriptionInfo = yhcValidation.subscriptionInfo
        profile.accountState = hadExpiredSubscription ? "restored" : "ok"
        profile.accountError = ""
        profile.accountUpdatedAt = yhcValidation.subscriptionInfo.updatedAt
        await YhcCredentialStore.save(profile.id, data.accountUsername?.trim() ?? '',
          data.accountPassword ?? '', yhcValidation.accessToken, yhcValidation.apiBase,
          yhcValidation.tokenExpiresAt)
        await BitzNetCredentialStore.remove(profile.id)
      } else {
        await BitzNetCredentialStore.remove(profile.id)
        await YhcCredentialStore.remove(profile.id)
      }
      value = await this.profileRepo.addOrUpdate(profile)
      if (shouldRefreshRenewedYhc) {
        const appConfig = AppStorage.get<AppConfig>('appConfig') || cardManager.getAppConfig()
        if (appConfig?.currentProfileId === profile.id) {
          const loaded = await this.loadConfig(false, '萤火虫续费-编辑保存')
          hilog.info(0xC012, 'AccountRefresh',
            `萤火虫续费编辑保存后重载 profileId=${profile.id}, changed=${renewedYhcConfigChanged}, loaded=${loaded}`)
        }
      }
    } else {
      value = -1
      console.error("ClashBox文件保存失败");
      Xb_ToastUtil.showToast({message: "文件保存失败！"})
    }
    EventHub.sendEvent(EventKey.FetchProfile, null)
    console.info("EditConfig&UpdateConfig&ConfigSort", `文件名${profile.name} 保存结果: ${value}`)
  }

  // 批量插入配置
  async addOrUpdateProfiles(data: Profile[]) {
    for (const profile of data) {
      let newProfile = new Profile(profile.type, profile.url)
      const old = await this.profileRepo.query(profile.id)
      console.log(`old配置 ${old ? old.name : '本地没有old配置'}`)
      if (old) {
        console.log(`配置${profile.name}在数据库中已存在`)
        newProfile = old
      }
      if (profile.type === ProfileType.Url) {
        // URL配置
        newProfile.loadContext(this.context)
        newProfile.name = profile.name
        newProfile.autoUpdate = profile.autoUpdate
        newProfile.autoUpdateDuration = profile.autoUpdateDuration ?? 10
        console.log(`配置${profile.name}基础设置完成`)
        newProfile.url = profile.url
        await this.updateCompatibleSubscription(newProfile)
      } else {
        // 本地文件配置
        try {
          let filePicker = new picker.DocumentViewPicker(this.context!)
          let options = new picker.DocumentSelectOptions()
          ClashViewModel.promptAction.showToast({ message: `${Xb_GetResourceString($r('app.string.file_config_restore_toast_1'), this.context)} ${profile.name}` })
          const documentSelectResult = await filePicker.select(options)
          newProfile.url = documentSelectResult[0]
          newProfile.name = decodeURIComponent(newProfile.url.substring(newProfile.url.lastIndexOf('/') + 1)) ?? profile.name
          console.log(`ClashBox Restore 配置${newProfile.name} 地址: ${newProfile.url} 选择完成`)
        } catch (err) {
          console.error(`ClashBox Restore 文件选择失败 ${err.name} ${err.message}`)
          // 导入失败后跳过
          continue
        }
        newProfile.loadContext(this.context)
        console.log(`配置${profile.name}基础设置完成`)
        try {
          await newProfile.saveByUri(profile.url)
        } catch (err) {
          console.error(`ClashBox Restore 配置移动读取失败 ${err.name} ${err.message}`)
        }
      }
      const isExists = await newProfile.check();
      if (isExists) {
        console.log(`配置${newProfile.name}已发现`)
        this.profileRepo.addOrUpdate(newProfile)
          .then((value) => {
            hilog.info(0xFF00, "Restore configSaveTestTag", `文件名${newProfile.name} 保存结果${value}`)
            EventHub.sendEvent(EventKey.FetchProfile, null)
          })
          .catch((err: Error) => {
            console.error(`ClashBox Restore 配置插入失败 ${err.name} ${err.message}`)
          })
      } else {
        console.error("ClashBox 配置文件不存在，保存失败");
        ClashViewModel.promptAction.showToast({message: "文件保存失败！"})
      }
    }
  }

  async addOrUpdateProfileByFile(name: string, path: string, id: string | null) {
    let profile = new Profile(ProfileType.File, path)
    if (id) {
      const old = await this.profileRepo.query(id)
      if (old)
        profile = old
    }
    profile.loadContext(this.context)
    profile.name = name // decodeURIComponent(path.substring(path.lastIndexOf('/') + 1))
    await profile.saveByUri(path);
    const isExists = await profile.check();
    if (isExists) {
      try {
        const value = await this.profileRepo.addOrUpdate(profile)
        hilog.info(0xFF00, "EditConfig configSaveTestTag", `文件名${profile.name} 保存结果${value}`)
        EventHub.sendEvent(EventKey.FetchProfile, null)
      } catch (err) {
        throw new Error(err.message)
      }
    } else {
      ClashViewModel.promptAction.showToast({message: "文件保存失败！"})
    }
  }

  async updateProfileConfig(id: string | null, showToast: boolean = true): Promise<ProfileUpdateResult> {
    const ua = AppStorage.get<ClashConfig>("clashConfig")?.["global-ua"]
    const result: ProfileUpdateResult = {
      total: 0, updated: 0, failed: 0, changed: 0, unchanged: 0, reloaded: 0
    }
    const appConfig = AppStorage.get<AppConfig>("appConfig") || cardManager.getAppConfig()
    let currentProfileChanged = false
    if (id) {
      result.total = 1
      const profile = await this.getProfile(id)
      if (profile && profile.type == ProfileType.Url && !profile.isUpdating) {
        try {
          profile.subscriptionState = 'downloading'
          profile.subscriptionError = ''
          profile.subscriptionCheckedAt = Date.now()
          await this.profileRepo.addOrUpdate(profile)
          profile.loadContext(this.context, ua)
          let changed: boolean
          if (profile.accountProvider === 'bitznet') {
            const download = await BitzNetQuotaService.downloadSubscription(profile.id, profile.url)
            if (download.format === 'v2ray') {
              download.content = await this.socketProxy.convertV2RaySubscription(download.content)
              download.proxyCount = BitzNetQuotaService.validateSubscriptionContent(download.content)
              download.contentHash = bitzSubscriptionHash(download.content)
            }
            hilog.warn(0xC012, 'BitzSubscription',
              `stage=atomic_save_start profileId=${profile.id}`)
            changed = await profile.saveIfChanged(download.content, (c) => this.VailConfig(c))
            hilog.warn(0xC012, 'BitzSubscription',
              `stage=atomic_save_ok profileId=${profile.id}, changed=${changed}`)
            profile.subscriptionInfo = download.subscriptionInfo
            this.markSubscriptionSuccess(profile, 'Clash YAML', download.proxyCount)
            hilog.info(0xC012, 'BitzSubscription',
              `稳定订阅校验成功 profileId=${profile.id}, nodes=${download.proxyCount}, ` +
              `hash=${download.contentHash}, changed=${changed}`)
          } else {
            changed = await this.updateCompatibleSubscription(profile)
          }
          await this.profileRepo.addOrUpdate(profile)
          result.updated = 1
          result.changed = changed ? 1 : 0
          result.unchanged = changed ? 0 : 1
          currentProfileChanged = changed && appConfig?.currentProfileId === profile.id
          if (this.context && showToast) {
            ClashViewModel.promptAction.showToast({ message: `${Xb_GetResourceString($r('app.string.Configuration'), this.context)} ${profile.name} ${Xb_GetResourceString($r('app.string.update_success'), this.context)}`})
          }
        } catch (e) {
          result.failed = 1
          const reason = SubscriptionCompatibilityService.sanitizeReason((e as Error)?.message ?? `${e}`)
          this.markSubscriptionFailure(profile, reason)
          await this.profileRepo.addOrUpdate(profile)
          EventHub.sendEvent(EventKey.FetchProfile, null)
          hilog.error(0xC012, 'BitzSubscription',
            `stage=profile_update_failed profileId=${profile.id}, reason=${reason}`)
          console.error(`BitzSubscription stage=profile_update_failed profileId=${profile.id}, reason=${reason}`)
          if (this.context && showToast) {
            Xb_ToastUtil.showToast({
              message: `${Xb_GetResourceString($r('app.string.Configuration'), this.context)} ${profile.name} ` +
                `更新订阅失败：${reason}；继续使用上次可用配置`,
              duration: 5000
            })
          }
        }
      } else {
        result.failed = 1
        const reason = profile ? '当前配置未启用在线订阅更新' : '配置数据库暂时未返回目标配置'
        console.error(`BitzSubscription stage=profile_lookup_failed profileId=${id}, reason=${reason}`)
        if (this.context && showToast) {
          Xb_ToastUtil.showToast({ message: `订阅更新失败：${reason}；本地配置保持不变`, duration: 5000 })
        }
      }
    } else {
      const list = (await this.getProfiles()).filter(d => d.type == ProfileType.Url)
      result.total = list.length
      for(let p of list) {
        if (!p.isUpdating) {
          try {
            p.subscriptionState = 'downloading'
            p.subscriptionError = ''
            p.subscriptionCheckedAt = Date.now()
            await this.profileRepo.addOrUpdate(p)
            p.loadContext(this.context, ua)
            let changed: boolean
            if (p.accountProvider === 'bitznet') {
              const download = await BitzNetQuotaService.downloadSubscription(p.id, p.url)
              if (download.format === 'v2ray') {
                download.content = await this.socketProxy.convertV2RaySubscription(download.content)
                download.proxyCount = BitzNetQuotaService.validateSubscriptionContent(download.content)
                download.contentHash = bitzSubscriptionHash(download.content)
              }
              hilog.warn(0xC012, 'BitzSubscription',
                `stage=atomic_save_start profileId=${p.id}`)
              changed = await p.saveIfChanged(download.content, async (c) => await this.VailConfig(c))
              hilog.warn(0xC012, 'BitzSubscription',
                `stage=atomic_save_ok profileId=${p.id}, changed=${changed}`)
              p.subscriptionInfo = download.subscriptionInfo
              this.markSubscriptionSuccess(p, 'Clash YAML', download.proxyCount)
              hilog.info(0xC012, 'BitzSubscription',
                `稳定订阅校验成功 profileId=${p.id}, nodes=${download.proxyCount}, ` +
                `hash=${download.contentHash}, changed=${changed}`)
            } else {
              changed = await this.updateCompatibleSubscription(p)
            }
            await this.profileRepo.addOrUpdate(p)
            result.updated++
            if (changed) {
              result.changed++
              if (appConfig?.currentProfileId === p.id) currentProfileChanged = true
            } else {
              result.unchanged++
            }
          } catch (error) {
            // 单条订阅失败不阻断后续订阅；原配置文件采用临时校验后覆盖，仍可继续使用。
            result.failed++
            const reason = SubscriptionCompatibilityService.sanitizeReason((error as Error)?.message ?? `${error}`)
            this.markSubscriptionFailure(p, reason)
            await this.profileRepo.addOrUpdate(p)
            hilog.error(0xC012, 'BitzSubscription',
              `stage=profile_update_failed profileId=${p.id}, reason=${reason}`)
          }
        }
      }
    }
    // 成功或失败都刷新状态小框；失败只更新诊断字段，不碰上次可用配置文件。
    if (result.updated > 0 || result.failed > 0) {
      EventHub.sendEvent(EventKey.FetchProfile, null)
    }
    // 只有实际变化、当前配置且 VPN 正在运行时才热重载；相同哈希保持当前
    // 连接不动。selected-map 从 ProfileRepo 恢复用户原来的节点选择。
    if (currentProfileChanged && this.vpnStarted) {
      const loaded = await this.loadConfig(false, '订阅兼容链热重载')
      if (loaded) {
        result.reloaded = 1
      } else {
        hilog.error(0xC012, 'BitzSubscription', '新配置已原子保存，但运行中核心热重载失败')
      }
    }
    return result
  }

  async refreshProfileSubscriptionInfo(id: string | null = null): Promise<ProfileQuotaRefreshResult> {
    const ua = AppStorage.get<ClashConfig>("clashConfig")?.["global-ua"]
    const profiles = id ? [await this.getProfile(id)] : await this.getProfiles()
    const targets: Profile[] = []
    for (const profile of profiles) {
      if (profile && profile.type === ProfileType.Url) {
        targets.push(profile)
      }
    }
    const result: ProfileQuotaRefreshResult = {
      total: targets.length,
      refreshed: 0,
      failed: 0,
      unavailable: 0
    }
    for (const profile of targets) {
      try {
        profile.loadContext(this.context, ua)
        const refreshed = await profile.refreshSubscriptionInfo()
        if (refreshed) {
          await this.profileRepo.addOrUpdate(profile)
          result.refreshed++
        } else {
          result.unavailable++
        }
      } catch (error) {
        result.failed++
        hilog.warn(0xC012, 'ClashViewModel',
          `额度刷新失败，保留上次数据，profileId=${profile.id}, reason=${(error as Error).message}`)
      }
    }
    if (result.refreshed > 0) {
      EventHub.sendEvent(EventKey.FetchProfile, null)
    }
    return result
  }

  async refreshAccountProfiles(id: string | null = null,
    backgroundPreferredOnly: boolean = false): Promise<AccountRefreshResult> {
    const profiles = id ? [await this.getProfile(id)] : await this.getProfiles()
    const targets: Profile[] = []
    for (const profile of profiles) {
      if (profile && profile.type === ProfileType.Url && profile.accountProvider !== 'none') {
        targets.push(profile)
      }
    }
    const result: AccountRefreshResult = { total: targets.length, refreshed: 0, failed: 0 }
    // 账号资料刷新是轻量接口，订阅 YAML 刷新则是重操作。只有检测到
    // “之前已过期、现在恢复有效”时才触发一次订阅重下载，避免每分钟
    // 账号保活都重复拉取订阅，同时修复续费后核心仍停留在过期占位节点的问题。
    const profilesNeedingSubscriptionRepair: string[] = []
    for (let targetIndex = 0; targetIndex < targets.length; targetIndex++) {
      const profile = targets[targetIndex]
      const previousAccountState: string = profile.accountState
      const previousSubscriptionExpired = isYhcSubscriptionExpired(profile.subscriptionInfo)
      let stopBackgroundScan = false
      try {
        if (profile.accountProvider === 'yhc') {
          const refreshed = await YhcAccountService.refresh(profile.id, backgroundPreferredOnly)
          profile.subscriptionInfo = refreshed.subscriptionInfo
        } else {
          profile.subscriptionInfo = await BitzNetQuotaService.refresh(
            profile.id, profile.url, !backgroundPreferredOnly, backgroundPreferredOnly)
        }
        profile.accountState = "ok"
        profile.accountError = ""
        profile.accountUpdatedAt = profile.subscriptionInfo.updatedAt
        const renewed = profile.accountProvider === 'yhc' && previousSubscriptionExpired &&
          !isYhcSubscriptionExpired(profile.subscriptionInfo)
        if (renewed) profile.accountState = 'restored'
        const retryPendingRepair = profile.accountProvider === 'yhc' &&
          (this.yhcRenewalRepairPending.has(profile.id) || profile.subscriptionPendingRepair) &&
          (profile.subscriptionRetryAt === 0 || Date.now() >= profile.subscriptionRetryAt) &&
          Date.now() - (this.yhcRenewalRepairAt.get(profile.id) ?? 0) >= 10 * 60 * 1000
        const staleRenewalNode = !renewed && !retryPendingRepair &&
          await this.hasStaleYhcRenewalPlaceholder(profile)
        if (renewed || retryPendingRepair || staleRenewalNode) {
          this.yhcRenewalRepairPending.add(profile.id)
          profilesNeedingSubscriptionRepair.push(profile.id)
          hilog.info(0xC012, 'AccountRefresh',
            `检测到萤火虫续费恢复、待重试任务或旧占位节点，排队刷新订阅 profileId=${profile.id}`)
        }
        result.refreshed++
      } catch (error) {
        const reason: string = (error as Error).message || '账号资料刷新失败'
        const transientFailure = BitzNetQuotaService.isTransientError(reason)
        // API 节点偶发超时/限流时保留已确认的登录状态，避免把有效账号
        // 短暂刷成“登录异常”。BitzNet 服务内部已做一次延迟重试，仍失败
        // 才进入这里；明确的 401/403 和凭据错误仍然显示异常。
        if (transientFailure) {
          if (previousAccountState === 'ok' || previousAccountState === 'restored') {
            profile.accountState = previousAccountState
            profile.accountError = ''
          } else {
            // 首次读取尚未成功时也不要把网关故障称作登录失败；保留真实的
            // “服务暂不可用”状态，下一轮定时刷新成功后自然切换为 ok。
            profile.accountState = 'unavailable'
            profile.accountError = reason
          }
          hilog.warn(0xc012, 'AccountRefresh',
            `账号资料暂时不可达，未判定为凭据失效，profileId=${profile.id}, reason=${reason}`)
          // DNS、路由和 TLS 连接故障通常影响整个当前网络。周期任务在首个
          // 临时故障后结束本轮，避免继续扫描其他账号和备用域名。
          stopBackgroundScan = backgroundPreferredOnly
        } else {
          profile.accountState = "error"
          profile.accountError = reason
        }
        result.failed++
        hilog.warn(0xC012, 'AccountRefresh',
          `账号资料刷新失败，保留上次数据，provider=${profile.accountProvider}, ` +
          `profileId=${profile.id}, reason=${BitzNetQuotaService.sanitizeLogReason(reason)}`)
      }
      profile.bitzQuotaEnabled = profile.accountProvider === 'bitznet'
      profile.bitzQuotaState = profile.bitzQuotaEnabled ? profile.accountState : 'idle'
      profile.bitzQuotaError = profile.bitzQuotaEnabled ? profile.accountError : ''
      profile.bitzQuotaUpdatedAt = profile.bitzQuotaEnabled ? profile.accountUpdatedAt : 0
      await this.profileRepo.addOrUpdate(profile)
      if (stopBackgroundScan) {
        hilog.warn(0xC012, 'AccountRefresh',
          `后台刷新遇到全局网络故障，停止本轮剩余 ${targets.length - targetIndex - 1} 个账号`)
        break
      }
    }
    // 先把最新账号状态落库，再下载订阅，避免下载期间另一条刷新链将旧状态
    // 写回数据库。updateProfileConfig 内部会在当前 VPN 运行时自动热重载。
    for (const profileId of profilesNeedingSubscriptionRepair) {
      this.yhcRenewalRepairAt.set(profileId, Date.now())
      try {
        const updateResult = await this.updateProfileConfig(profileId, false)
        const appConfig = AppStorage.get<AppConfig>('appConfig') || cardManager.getAppConfig()
        // updateProfileConfig 仅在 VPN 运行且文件变化时自动热重载；续费修复还要
        // 覆盖“文件已是34节点、核心/UI仍是旧占位节点”和“VPN当前关闭”两种情况。
        let coreReloaded = updateResult.reloaded > 0
        if (appConfig?.currentProfileId === profileId && !coreReloaded && updateResult.failed === 0) {
          coreReloaded = await this.loadConfig(false, '萤火虫续费自动修复')
        }
        if (updateResult.failed > 0) {
          hilog.warn(0xC012, 'AccountRefresh',
            `萤火虫续费后订阅刷新失败，保留原配置 profileId=${profileId}`)
        } else if (appConfig?.currentProfileId === profileId && !coreReloaded) {
          hilog.warn(0xC012, 'AccountRefresh',
            `萤火虫续费后核心重载失败，保留自动重试 profileId=${profileId}`)
        } else {
          this.yhcRenewalRepairPending.delete(profileId)
          hilog.info(0xC012, 'AccountRefresh',
            `萤火虫续费后订阅刷新完成 profileId=${profileId}, changed=${updateResult.changed}, ` +
            `reloaded=${coreReloaded}`)
        }
      } catch (error) {
        hilog.warn(0xC012, 'AccountRefresh',
          `萤火虫续费后订阅刷新异常，保留原配置 profileId=${profileId}, reason=${(error as Error).message}`)
      }
    }
    if (targets.length > 0) {
      EventHub.sendEvent(EventKey.FetchProfile, null)
    }
    return result
  }

  /**
   * 兼容修复安装前已经出现的状态，以及首次续费刷新失败后的重启状态：账号
   * 已有效，但当前核心仍展示服务商下发的“续费/充值”占位节点。只按核心中
   * 的明确占位文案触发，不依赖可能已被失败请求改写的订阅诊断字段。
   */
  private async hasStaleYhcRenewalPlaceholder(profile: Profile): Promise<boolean> {
    if (profile.accountProvider !== 'yhc' || isYhcSubscriptionExpired(profile.subscriptionInfo)) return false
    const previousAttempt = this.yhcRenewalRepairAt.get(profile.id) ?? 0
    if (Date.now() - previousAttempt < 10 * 60 * 1000) return false
    const appConfig = AppStorage.get<AppConfig>('appConfig') || cardManager.getAppConfig()
    if (appConfig?.currentProfileId !== profile.id || !await this.socketProxy.isCoreReady()) return false
    try {
      const clashConfig = AppStorage.get<ClashConfig>('clashConfig') || cardManager.getClashConfig()
      const groups = await this.getProxyGroups(clashConfig?.mode ?? ProxyMode.Rule)
      const names: string[] = []
      for (const group of groups) {
        for (const item of group.proxies) {
          if (!names.includes(item.name)) names.push(item.name)
        }
      }
      const hasRenewalPlaceholder = names.some((name: string): boolean =>
        isYhcRenewalPlaceholderName(name))
      return hasRenewalPlaceholder
    } catch (_) {
      return false
    }
  }

  /** 兼容旧调用入口。 */
  async refreshBitzNetQuota(id: string | null = null): Promise<AccountRefreshResult> {
    return await this.refreshAccountProfiles(id)
  }
  async VailConfig(config: string): Promise<string>{
    return await this.socketProxy.vailConfig(config)
  }

  private async updateCompatibleSubscription(profile: Profile): Promise<boolean> {
    const download: CompatibleSubscriptionDownload =
      await SubscriptionCompatibilityService.download(profile.url)
    let content = download.content
    let format = download.format
    let proxyCount = download.proxyCount
    if (download.format === 'URI/base64') {
      content = await this.socketProxy.convertV2RaySubscription(download.content)
      const structure = SubscriptionCompatibilityService.inspectClashContent(content)
      if (!structure.valid) throw new Error('URI/base64 已转换，但没有得到可用代理节点')
      format = structure.format
      proxyCount = structure.proxyCount
    }
    const changed = await profile.saveIfChanged(content, (path: string) => this.VailConfig(path))
    if (download.subscriptionInfo) profile.subscriptionInfo = download.subscriptionInfo
    this.markSubscriptionSuccess(profile, format, proxyCount)
    hilog.info(0xC012, 'SubscriptionCompat',
      `profileId=${profile.id}, format=${format}, nodes=${proxyCount}, changed=${changed}`)
    return changed
  }

  private markSubscriptionSuccess(profile: Profile, format: string, nodeCount: number): void {
    profile.subscriptionState = 'ok'
    profile.subscriptionError = ''
    profile.subscriptionFormat = format
    profile.subscriptionNodeCount = nodeCount
    profile.subscriptionCheckedAt = Date.now()
  }

  private markSubscriptionFailure(profile: Profile, reason: string): void {
    profile.markSubscriptionRetry(reason)
  }
  async changeProxy(profile: Profile, g:string, p: string,
    origin: 'user' | 'auto' | 'system' = 'user'): Promise<boolean> {
    const previous = this.proxyChangeQueue
    let release: () => void = () => {}
    this.proxyChangeQueue = new Promise<void>((resolve) => {
      release = resolve
    })
    await previous
    try {
      try {
        let result = await this.socketProxy.changeProxy(g, p)
        // A config reload that is just finishing is recoverable. Retry once
        // after its bounded native lock response; all other errors remain
        // immediate and are reported unchanged.
        if (result === '核心正在重载，请稍后重试') {
          await sleep(350)
          result = await this.socketProxy.changeProxy(g, p)
        }
        if (result) {
          throw new Error(result)
        }
        profile.proxySelected?.set(g, p)
        await this.profileRepo.addOrUpdate(profile)
        if (origin === 'user') {
          this.nodeFailoverLastUserChangeAt = Date.now()
          this.nodeFailoverFailures = 0
          this.publishNodeFailoverState('monitoring', `已手动选择 ${p}，2分钟内不自动切换`)
        }
        EventHub.sendEvent(EventKey.checkIpInfo, { force: true })
        return true
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e)
        ClashViewModel.promptAction.showToast({message: message, duration:3000})
        hilog.error(0xA003, 'ClashViewModel', `changeProxy failed group=${g} node=${p}: ${message}`)
        return false
      }
    } finally {
      release()
    }
  }

  /**
   * 沿代理组当前选择向下解析，直到得到真实节点。
   * GLOBAL 不应停在 DIRECT/REJECT，也不应只停在“自动选择”等嵌套组上。
   */
  private resolveLeafProxy(profile: Profile, groups: ProxyGroup[], preferredName?: string): string | undefined {
    let candidate = preferredName
    const visited: string[] = []
    for (let index = 0; index <= groups.length; index++) {
      if (!candidate || visited.includes(candidate)) {
        return undefined
      }
      visited.push(candidate)
      const nestedGroup = groups.find((group: ProxyGroup) => group.name === candidate)
      if (!nestedGroup) {
        return candidate
      }
      candidate = profile.getSelectedProxy(nestedGroup) ?? nestedGroup.now
    }
    return undefined
  }

  /**
   * 确保全局模式最终选择真实代理节点。
   * 放在统一配置加载链路中，覆盖模式切换、订阅切换、更新订阅和 VPN 重启。
   */
  async ensureUsableGlobalProxy(profile: Profile, preferredName?: string): Promise<string | undefined> {
    const groups = await this.getProxyGroups(ProxyMode.Global)
    const globalGroup = groups.find((group: ProxyGroup) => group.name === 'GLOBAL')
    if (!globalGroup) {
      hilog.warn(0xA003, 'ClashViewModel', '当前配置没有 GLOBAL 代理组')
      return undefined
    }

    const isUsableTarget = (name?: string): boolean => !!name && name !== 'DIRECT' && name !== 'REJECT' &&
      globalGroup.proxies.some((item) => item.name === name)
    // 优先恢复该订阅自己保存的 GLOBAL 选择，避免从另一个订阅切换过来时串用节点名。
    let target = this.resolveLeafProxy(profile, groups,
      profile.getSelectedProxy(globalGroup) ?? globalGroup.now)

    if (!isUsableTarget(target) && preferredName) {
      target = this.resolveLeafProxy(profile, groups, preferredName)
    }

    if (!isUsableTarget(target)) {
      for (const group of groups) {
        if (group.name === 'GLOBAL') {
          continue
        }
        const resolved = this.resolveLeafProxy(profile, groups, group.name)
        if (isUsableTarget(resolved)) {
          target = resolved
          break
        }
      }
    }
    if (!isUsableTarget(target)) {
      target = globalGroup.proxies.find((item) => item.name !== 'DIRECT' && item.name !== 'REJECT')?.name
    }
    if (!target) {
      hilog.warn(0xA003, 'ClashViewModel', 'GLOBAL 中没有真实可用节点')
      return undefined
    }

    const switched = await this.changeProxy(profile, 'GLOBAL', target, 'system')
    if (!switched) {
      return undefined
    }
    const appConfig = AppStorage.get<AppConfig>('appConfig') || cardManager.getAppConfig()
    if (appConfig) {
      appConfig.currentProxyName = target
      appConfig.currentProxyItem = globalGroup.proxies.find((item) => item.name === target) as ProxyItem
    }
    hilog.info(0xA003, 'ClashViewModel', `GLOBAL 已自动选择真实节点：${target}`)
    return target
  }
  async setVpnOptions(options: VpnRawOptions){
    try {
      let result = await this.socketProxy.setOptionStates(options)
      console.log("setVpnOptions", result)
    } catch (e) {
      ClashViewModel.promptAction.showToast({message: e.message, duration:3000})
    }
  }


  private delayContextKey: string = ''
  private delayRunner: NodeDelayRunner = new NodeDelayRunner(
    async (name: string): Promise<NodeDelayProbe> => this.probeNodeDelayWithFallback(name),
    (result: NodeDelayResult): void => {
      EventHub.sendEvent(EventKey.TestDelay, result)
      AppStorage.setOrCreate('nodeDelayRevision', (AppStorage.get<number>('nodeDelayRevision') ?? 0) + 1)
    },
    (running: boolean, completed: number, total: number): void => {
      AppStorage.setOrCreate('nodeDelayBatchRunning', running)
      AppStorage.setOrCreate('nodeDelayBatchProgress', `${completed}/${total}`)
      if (AppStorage.get<boolean>('nodeQualityTestRunning') === true && total > 0) {
        const percent = Math.round(completed / total * 25)
        AppStorage.setOrCreate('nodeQualityTestProgress', `连通性 ${completed}/${total} · ${percent}%`)
      }
      if (!running && total > 0) EventHub.sendEvent(EventKey.NodeDelayBatchComplete)
    })
  delayMap: Map<string, DelayInfo> = this.delayRunner.results

  private async probeNodeDelayWithFallback(name: string): Promise<NodeDelayProbe> {
    const primaryUrl = normalizeDelayTestUrl(AppStorage.get<AppConfig>('appConfig')?.testUrl ?? '')
    // A batch probe is a quick reachability filter, not a full bandwidth test.
    // Five seconds keeps a dead node from holding one of six slots for too long;
    // the independent fallback still protects nodes whose first target is
    // incompatible with the exit path.
    const primary = await this.socketProxy.healthCheckDetailed(name, primaryUrl, 5000)
    if (primary.value > 0) {
      return {
        value: primary.value, elapsedMs: primary.elapsedMs, source: '主测速源',
        fallbackUsed: false, diagnostic: '主测速源连接成功'
      }
    }
    const fallbackUrl = primaryUrl.includes('cloudflare.com') ?
      'https://www.gstatic.com/generate_204' : 'https://cp.cloudflare.com/generate_204'
    const fallback = await this.socketProxy.healthCheckDetailed(name, fallbackUrl, 5000)
    const primaryCode = primary.errorCode ?? 'connection'
    const fallbackCode = fallback.errorCode ?? 'connection'
    if (fallback.value > 0) {
      return {
        value: fallback.value,
        elapsedMs: (primary.elapsedMs ?? 0) + (fallback.elapsedMs ?? 0),
        source: '备用测速源', fallbackUsed: true, primaryErrorCode: primaryCode,
        fallbackErrorCode: '',
        diagnostic: `主测速源${nodeDelayErrorText(primaryCode)}，备用测速源连接成功`
      }
    }
    return {
      value: -1, errorCode: this.preferredDelayError(primaryCode, fallbackCode),
      elapsedMs: (primary.elapsedMs ?? 0) + (fallback.elapsedMs ?? 0),
      source: '主备测速源', fallbackUsed: true, primaryErrorCode: primaryCode,
      fallbackErrorCode: fallbackCode,
      diagnostic: `主测速源${nodeDelayErrorText(primaryCode)}；备用测速源${nodeDelayErrorText(fallbackCode)}`
    }
  }

  private preferredDelayError(primary: string, fallback: string): string {
    const priority = ['missing', 'service', 'refused', 'tls', 'dns', 'unreachable', 'timeout', 'connection']
    for (const code of priority) {
      if (primary === code || fallback === code) return code
    }
    return fallback || primary || 'connection'
  }

  private resetNodeDelays(): void {
    this.delayRunner.invalidate()
    EventHub.sendEvent(EventKey.NodeDelayReset)
    AppStorage.setOrCreate('nodeDelayRevision', (AppStorage.get<number>('nodeDelayRevision') ?? 0) + 1)
  }

  private syncDelayContext(): void {
    const config = AppStorage.get<AppConfig>('appConfig')
    const key = `${config?.currentProfileId ?? ''}|${normalizeDelayTestUrl(config?.testUrl ?? '')}`
    if (key !== this.delayContextKey) {
      this.delayContextKey = key
      this.resetNodeDelays()
    }
  }

  async testDelay(proxyName: string): Promise<number> {
    this.syncDelayContext()
    return (await this.delayRunner.test(proxyName)).delay
  }

  async testAllDelay(list: ProxyItem[], publishResults: boolean = true): Promise<NodeDelayResult[]> {
    this.syncDelayContext()
    // Strategy groups and DIRECT are not subscription nodes. Testing a group
    // again duplicates its selected node and can perturb automatic selection.
    const nonNodes = ['Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay', 'Direct', 'Reject', 'RejectDrop']
    const names = list.filter((item: ProxyItem) => !nonNodes.includes(item.type)).map((item: ProxyItem) => item.name)
    const results = await this.delayRunner.testAll(names, publishResults)
    const ok = results.filter((item: NodeDelayResult) => item.status === 'ok').length
    const failed = results.filter((item: NodeDelayResult) => item.status === 'failed').length
    console.error(`[NodeDelay] batch complete total=${results.length} ok=${ok} failed=${failed}`)
    results.forEach((item: NodeDelayResult, index: number): void => {
      console.error(`[NodeDelay] result index=${index} id=${nodeDelayId(item.name)} state=${item.status} delay=${item.delay} code=${item.errorCode} elapsed=${item.elapsedMs}`)
    })
    return results
  }

  getFailedDelayItems(list: ProxyItem[]): ProxyItem[] {
    this.syncDelayContext()
    return list.filter((item: ProxyItem): boolean => this.delayMap.get(item.name)?.status === 'failed')
  }

  async retestFailedDelays(list: ProxyItem[]): Promise<NodeDelayResult[]> {
    this.syncDelayContext()
    const failed = this.getFailedDelayItems(list)
    if (failed.length === 0) return []
    return await this.delayRunner.testAll(failed.map((item: ProxyItem): string => item.name))
  }

  private nodeQualityLoaded: boolean = false
  private nodeQualityRunning: boolean = false
  nodeQualityMap: Map<string, NodeQualityResult> = new Map<string, NodeQualityResult>()
  private nodeQualityHistoryLoaded: boolean = false
  private nodeQualityHistoryMap: Map<string, NodeQualityHistorySample[]> =
    new Map<string, NodeQualityHistorySample[]>()

  private ensureNodeQualityCache(): void {
    if (this.nodeQualityLoaded) return
    this.nodeQualityLoaded = true
    const expiresAt = Date.now() - 24 * 60 * 60 * 1000
    try {
      const records = JSON.parse(cardManager.getNodeQualityCache()) as NodeQualityResult[]
      for (const record of records) {
        if (record.checkedAt >= expiresAt && record.status === 'ok') {
          this.nodeQualityMap.set(nodeQualityCacheKey(record.profileId, record.group, record.name), record)
        }
      }
    } catch (_) {
      this.nodeQualityMap.clear()
    }
    this.persistNodeQualityCache()
  }

  private persistNodeQualityCache(): void {
    const expiresAt = Date.now() - 24 * 60 * 60 * 1000
    const records: NodeQualityResult[] = []
    this.nodeQualityMap.forEach((record: NodeQualityResult): void => {
      if (record.checkedAt >= expiresAt && record.status === 'ok') records.push(record)
    })
    cardManager.setNodeQualityCache(JSON.stringify(records))
  }

  private ensureNodeQualityHistory(): void {
    if (this.nodeQualityHistoryLoaded) return
    this.nodeQualityHistoryLoaded = true
    const expiresAt = Date.now() - 7 * 24 * 60 * 60 * 1000
    try {
      const records = JSON.parse(cardManager.getNodeQualityHistory()) as NodeQualityHistorySample[]
      for (const record of records) {
        if (!record.profileId || !record.name || record.checkedAt < expiresAt || record.status === 'testing') continue
        const key = nodeQualityCacheKey(record.profileId, record.group, record.name)
        const history = this.nodeQualityHistoryMap.get(key) ?? []
        history.push(record)
        this.nodeQualityHistoryMap.set(key, history)
      }
      this.nodeQualityHistoryMap.forEach((history: NodeQualityHistorySample[], key: string): void => {
        history.sort((a: NodeQualityHistorySample, b: NodeQualityHistorySample): number =>
          a.checkedAt - b.checkedAt)
        this.nodeQualityHistoryMap.set(key, history.slice(-8))
      })
    } catch (_) {
      this.nodeQualityHistoryMap.clear()
    }
    this.persistNodeQualityHistory()
  }

  private persistNodeQualityHistory(): void {
    const expiresAt = Date.now() - 7 * 24 * 60 * 60 * 1000
    const records: NodeQualityHistorySample[] = []
    this.nodeQualityHistoryMap.forEach((history: NodeQualityHistorySample[]): void => {
      history.filter((item: NodeQualityHistorySample): boolean => item.checkedAt >= expiresAt)
        .slice(-8).forEach((item: NodeQualityHistorySample): void => {
          records.push(item)
        })
    })
    // 订阅很多时仍设置全局上限，优先保留最新记录。
    records.sort((a: NodeQualityHistorySample, b: NodeQualityHistorySample): number =>
      b.checkedAt - a.checkedAt)
    cardManager.setNodeQualityHistory(JSON.stringify(records.slice(0, 320)))
  }

  private appendNodeQualityHistory(result: NodeQualityResult): void {
    if (result.status === 'testing' || result.checkedAt <= 0) return
    this.ensureNodeQualityHistory()
    const key = nodeQualityCacheKey(result.profileId, result.group, result.name)
    const history = this.nodeQualityHistoryMap.get(key) ?? []
    const sample = compactNodeQualitySample(result)
    const duplicate = history.findIndex((item: NodeQualityHistorySample): boolean =>
      item.checkedAt === sample.checkedAt && item.mode === sample.mode)
    if (duplicate >= 0) history[duplicate] = sample
    else history.push(sample)
    history.sort((a: NodeQualityHistorySample, b: NodeQualityHistorySample): number =>
      a.checkedAt - b.checkedAt)
    this.nodeQualityHistoryMap.set(key, history.slice(-8))
    this.persistNodeQualityHistory()
  }

  getNodeQualityHistorySummary(profile: Profile | null, group: string,
    name: string): NodeQualityHistorySummary {
    this.ensureNodeQualityHistory()
    if (!profile) return summarizeNodeQualityHistory([])
    return summarizeNodeQualityHistory(
      this.nodeQualityHistoryMap.get(nodeQualityCacheKey(profile.id, group, name)) ?? [])
  }

  getNodeQualityResult(profile: Profile | null, group: string, name: string): NodeQualityResult | undefined {
    if (!profile) return undefined
    this.ensureNodeQualityCache()
    const result = this.nodeQualityMap.get(nodeQualityCacheKey(profile.id, group, name))
    if (!result || result.profileUpdatedAt !== profile.lastUpdateDate) return undefined
    return result
  }

  getNodeExperienceRank(group: string, name: string): number {
    this.ensureNodeQualityCache()
    const profileId = AppStorage.get<AppConfig>('appConfig')?.currentProfileId ?? ''
    if (!profileId) return 0
    const result = this.nodeQualityMap.get(nodeQualityCacheKey(profileId, group, name))
    return result?.experienceRank ?? 0
  }

  recordNodeQualityResult(result: NodeQualityResult): void {
    this.ensureNodeQualityCache()
    this.nodeQualityMap.set(nodeQualityCacheKey(result.profileId, result.group, result.name), result)
    this.appendNodeQualityHistory(result)
    this.persistNodeQualityCache()
    AppStorage.setOrCreate('nodeQualityRevision',
      (AppStorage.get<number>('nodeQualityRevision') ?? 0) + 1)
    EventHub.sendEvent(EventKey.NodeQualityUpdated, result)
  }

  /**
   * Commit the visible part of a daily run as one transaction.  Exploratory
   * samples are intentionally kept out of the card cache; otherwise a node
   * changes from the previous Mbps value to `testing`, then to a screening
   * value, and finally to the sustained value while the user is watching.
   */
  private commitDailyExperienceResults(profile: Profile, items: ProxyItem[],
    results: NodeQualityResult[]): void {
    this.ensureNodeQualityCache()
    const names = new Set<string>(items.map((item: ProxyItem): string => item.name))
    this.nodeQualityMap.forEach((value: NodeQualityResult, key: string): void => {
      if (value.profileId === profile.id && names.has(value.name) && (value.experienceRank ?? 0) > 0) {
        value.experienceRank = 0
        value.experienceScore = 0
        this.nodeQualityMap.set(key, value)
      }
    })
    results.forEach((result: NodeQualityResult): void => {
      this.nodeQualityMap.set(nodeQualityCacheKey(result.profileId, result.group, result.name), result)
      this.appendNodeQualityHistory(result)
    })
    this.persistNodeQualityCache()
    AppStorage.setOrCreate('nodeQualityRevision',
      (AppStorage.get<number>('nodeQualityRevision') ?? 0) + 1)
    results.forEach((result: NodeQualityResult): void => {
      EventHub.sendEvent(EventKey.NodeQualityUpdated, result)
    })
  }

  async testQualityCandidates(profile: Profile, group: ProxyGroup,
    list: ProxyItem[]): Promise<NodeQualityBatchResult> {
    if (this.nodeQualityRunning) throw new Error('已有节点质量测试正在运行')
    if (!this.vpnStarted) throw new Error('请先启动VPN')
    this.nodeQualityRunning = true
    AppStorage.setOrCreate('nodeQualityTestRunning', true)
    AppStorage.setOrCreate('nodeQualityTestProgress', '准备中 · 0%')
    try {
      await this.waitForAutomaticNetworkChecks(8, false)
      AppStorage.setOrCreate('nodeQualityTestProgress', '检测延迟 · 0–25%')
      const delays = await this.testAllDelay(list)
      const names = selectQualityCandidates(delays, 3)
      const candidates = names.map((name: string): ProxyItem | undefined =>
        list.find((item: ProxyItem): boolean => item.name === name))
        .filter((item: ProxyItem | undefined): boolean => item !== undefined) as ProxyItem[]
      return await this.runNodeQualityBatchLocked(profile, group, candidates, 'stability', true)
    } finally {
      this.nodeQualityRunning = false
      AppStorage.setOrCreate('nodeQualityTestRunning', false)
      if (AppStorage.get<boolean>('nodeQualityNetworkRefreshPending') === true) {
        AppStorage.setOrCreate('nodeQualityNetworkRefreshPending', false)
        EventHub.sendEvent(EventKey.checkIpInfo, { force: true })
      }
    }
  }

  async testDailyExperience(profile: Profile, group: ProxyGroup,
    list: ProxyItem[], candidateLimit: number = 3,
    measurementMode: NodeQualityMode = 'bandwidth_economy'): Promise<NodeQualityBatchResult> {
    if (this.nodeQualityRunning) throw new Error('已有节点质量测试正在运行')
    if (!this.vpnStarted) throw new Error('请先启动VPN')
    this.nodeQualityRunning = true
    AppStorage.setOrCreate('nodeQualityTestRunning', true)
    AppStorage.setOrCreate('nodeQualityTestProgress', '准备中 · 0%')
    let pendingDelayResults: NodeDelayResult[] = []
    let delayResultsCommitted = false
    try {
      // 进度先展示，等待其他网络探测最多 2 秒，避免点击后长时间没有反馈。
      await this.waitForAutomaticNetworkChecks(8, false)
      AppStorage.setOrCreate('nodeQualityTestProgress', '检测延迟 · 0–25%')
      this.ensureNodeQualityCache()
      // Keep both the old delay values and the old quality values visible until
      // the entire run is ready to commit.  This is important when the user
      // leaves and re-enters the page halfway through the run.
      const delays = await this.testAllDelay(list, false)
      pendingDelayResults = delays
      const reachableItems = list.filter((item: ProxyItem): boolean =>
        delays.some((delay: NodeDelayResult): boolean => delay.name === item.name && delay.status === 'ok'))
      if (reachableItems.length === 0) {
        this.delayRunner.publishBatch(delays)
        delayResultsCommitted = true
        return { results: [], candidates: 0, cached: 0, transferredBytes: 0, ranked: 0,
          screened: 0, screeningSucceeded: 0 }
      }

      // 快速路径：延迟阶段已经是全节点并发筛选，最多准备 5 个候选，
      // 其中最多拿到 3 个成功的轻量吞吐样本。前面的节点失败时会自动
      // 用后备候选补位，避免一次失败把整轮测试拖长或让推荐数量不足。
      const successLimit = Math.max(1, Math.min(3, candidateLimit))
      const candidatePoolLimit = Math.max(successLimit, Math.min(5, successLimit + 2))
      const names = selectQualityCandidates(delays, candidatePoolLimit)
      const candidates = names.map((name: string): ProxyItem | undefined =>
        list.find((item: ProxyItem): boolean => item.name === name))
        .filter((item: ProxyItem | undefined): boolean => item !== undefined) as ProxyItem[]
      if (candidates.length === 0) {
        this.delayRunner.publishBatch(delays)
        delayResultsCommitted = true
        return { results: [], candidates: 0, cached: 0, transferredBytes: 0, ranked: 0 }
      }

      AppStorage.setOrCreate('nodeQualityTestProgress', `快速实测 0/${candidates.length} · 25%`)
      const batch = await this.runNodeQualityBatchLocked(profile, group, candidates,
        measurementMode, false, '快速实测', 25, 75, false, successLimit, 3)
      const ranked = batch.results.filter((result: NodeQualityResult): boolean => result.status === 'ok')
      ranked.forEach((result: NodeQualityResult): void => {
        const delay = delays.find((item: NodeDelayResult): boolean => item.name === result.name)
        result.latencyMs = delay?.status === 'ok' ? delay.delay : 0
        result.experienceScore = dailyExperienceScore(result, result.latencyMs)
        result.experienceRank = 0
      })
      ranked.sort((a: NodeQualityResult, b: NodeQualityResult): number =>
        (b.experienceScore ?? 0) - (a.experienceScore ?? 0) || a.latencyMs - b.latencyMs)
      ranked.forEach((result: NodeQualityResult, index: number): void => {
        result.experienceRank = index + 1
      })
      // Delay and quality results become visible together.  The page can be
      // rebuilt at any point before this line without observing half a run.
      this.delayRunner.publishBatch(delays)
      delayResultsCommitted = true
      this.commitDailyExperienceResults(profile, list, batch.results)
      if (ranked.length > 0) {
        const config = AppStorage.get<AppConfig>('appConfig') || cardManager.getAppConfig()
        if (config) {
          config.proxySort = ProxySort.Experience
          AppStorage.setOrCreate('appConfig', config)
          AppStorage.set('appConfig', config)
          cardManager.setAppConfig(config)
        }
        // 使用单调递增版本号而非一次性 boolean；页面离开/返回后仍能按最新结果排序。
        AppStorage.setOrCreate('nodeQualitySortRevision',
          (AppStorage.get<number>('nodeQualitySortRevision') ?? 0) + 1)
      }
      return { results: batch.results, candidates: batch.candidates, cached: batch.cached,
        transferredBytes: batch.transferredBytes, ranked: ranked.length,
        screened: reachableItems.length,
        screeningSucceeded: reachableItems.length }
    } finally {
      if (!delayResultsCommitted && pendingDelayResults.length > 0) {
        this.delayRunner.publishBatch(pendingDelayResults)
      }
      this.nodeQualityRunning = false
      AppStorage.setOrCreate('nodeQualityTestRunning', false)
      if (AppStorage.get<boolean>('nodeQualityNetworkRefreshPending') === true) {
        AppStorage.setOrCreate('nodeQualityNetworkRefreshPending', false)
        EventHub.sendEvent(EventKey.checkIpInfo, { force: true })
      }
    }
  }

  async testNodeBandwidth(profile: Profile, group: ProxyGroup,
    item: ProxyItem, mode: NodeQualityMode = 'bandwidth_single_sustained'): Promise<NodeQualityResult> {
    if (this.nodeQualityRunning) throw new Error('已有节点质量测试正在运行')
    if (!this.vpnStarted) throw new Error('请先启动VPN')
    this.nodeQualityRunning = true
    AppStorage.setOrCreate('nodeQualityTestRunning', true)
    try {
      // A manually requested bandwidth run takes priority over the automatic
      // IPPure/platform probes. Lock new probes immediately, give an already
      // active request a brief chance to finish, then measure. The deferred
      // refresh below runs after the test, so no card state is lost and the UI
      // never sits at 0 Mbps for the former twenty-second wait.
      await this.waitForAutomaticNetworkChecks(8, false)
      const batch = await this.runNodeQualityBatchLocked(profile, group, [item], mode, false)
      if (batch.results.length === 0) throw new Error('节点带宽测试没有返回结果')
      return batch.results[0]
    } finally {
      this.nodeQualityRunning = false
      AppStorage.setOrCreate('nodeQualityTestRunning', false)
      if (AppStorage.get<boolean>('nodeQualityNetworkRefreshPending') === true) {
        AppStorage.setOrCreate('nodeQualityNetworkRefreshPending', false)
        EventHub.sendEvent(EventKey.checkIpInfo, { force: true })
      }
    }
  }

  async waitForAutomaticNetworkChecks(maxPolls: number = 80, strict: boolean = true): Promise<void> {
    for (let index = 0; index < maxPolls; index++) {
      if (AppStorage.get<boolean>('platformCheckRunning') !== true &&
        AppStorage.get<boolean>('isCheckIpInfo') !== true) return
      await sleep(250)
    }
    if (strict) throw new Error('网络状态检测仍在运行，请稍后重试')
    AppStorage.setOrCreate('nodeQualityNetworkRefreshPending', true)
  }

  private async runNodeQualityBatchLocked(profile: Profile, group: ProxyGroup, items: ProxyItem[],
    mode: NodeQualityMode, allowCache: boolean, progressPrefix: string = '',
    progressStart: number = 0, progressWeight: number = 100,
    publishResults: boolean = true, successLimit: number = 0, parallelism: number = 1): Promise<NodeQualityBatchResult> {
    this.ensureNodeQualityCache()
    const results: NodeQualityResult[] = []
    let cached = 0
    let transferredBytes = 0
    let successful = 0
    const publishProgress = (completed: number): void => {
      const fraction = items.length === 0 ? 1 : Math.max(0, Math.min(1, completed / items.length))
      const percent = Math.round(progressStart + progressWeight * fraction)
      AppStorage.setOrCreate('nodeQualityTestProgress',
        `${progressPrefix || '测试'} ${completed}/${items.length} · ${percent}%`)
    }
    publishProgress(0)
    const execute = async (item: ProxyItem): Promise<NodeQualityBatchExecution> => {
      const key = nodeQualityCacheKey(profile.id, group.name, item.name)
      const previous = this.nodeQualityMap.get(key)
      if (allowCache && previous && previous.status === 'ok' && previous.mode === mode &&
        previous.profileUpdatedAt === profile.lastUpdateDate &&
        Date.now() - previous.checkedAt < 24 * 60 * 60 * 1000) {
        return { result: previous, cached: true }
      }
      const testing: NodeQualityResult = {
        profileId: profile.id, profileUpdatedAt: profile.lastUpdateDate, group: group.name,
        name: item.name, mode: mode, status: 'testing', quality: '检测中', checkedAt: Date.now(),
        latencyMs: 0, jitterMs: 0, successRate: 0, downloadMbps: 0, uploadMbps: 0,
        transferredBytes: 0, errorMessage: ''
      }
      if (publishResults) {
        this.nodeQualityMap.set(key, testing)
        AppStorage.setOrCreate('nodeQualityRevision',
          (AppStorage.get<number>('nodeQualityRevision') ?? 0) + 1)
        EventHub.sendEvent(EventKey.NodeQualityUpdated, testing)
      }
      let result: NodeQualityResult
      try {
        const probe = await this.socketProxy.nodeQualityCheck(item.name, mode)
        result = NodeQualityService.fromCore(profile.id, profile.lastUpdateDate,
          group.name, item.name, mode, probe.status, probe.quality, probe.latencyMs,
          probe.jitterMs, probe.successRate, probe.downloadMbps, probe.uploadMbps,
          probe.transferredBytes, probe.errorCode, probe.diagnostic ?? '', probe.reliable,
          probe.downloadVariationPercent, probe.uploadVariationPercent)
        console.info(`[NodeQuality] mode=${mode} status=${result.status} ` +
          `success=${result.successRate}% down=${result.downloadMbps} up=${result.uploadMbps} ` +
          `bytes=${result.transferredBytes}`)
      } catch (_) {
        result = {
          profileId: profile.id, profileUpdatedAt: profile.lastUpdateDate, group: group.name,
          name: item.name, mode: mode, status: 'failed', quality: '异常', checkedAt: Date.now(),
          latencyMs: 0, jitterMs: 0, successRate: 0, downloadMbps: 0, uploadMbps: 0,
          transferredBytes: 0, errorMessage: '内核质量测试异常'
        }
      }
      return { result: result, cached: false }
    }
    let index = 0
    while (index < items.length) {
      const width = Math.max(1, Math.min(Math.floor(parallelism), items.length - index))
      const currentItems = items.slice(index, index + width)
      const current = await Promise.all(currentItems.map((item: ProxyItem): Promise<NodeQualityBatchExecution> =>
        execute(item)))
      current.forEach((entry: NodeQualityBatchExecution): void => {
        const result = entry.result
        results.push(result)
        if (entry.cached) {
          cached++
          AppStorage.setOrCreate('nodeQualityRevision',
            (AppStorage.get<number>('nodeQualityRevision') ?? 0) + 1)
        } else {
          transferredBytes += result.transferredBytes
          if (publishResults) this.recordNodeQualityResult(result)
        }
        if (result.status === 'ok') successful++
      })
      index += current.length
      publishProgress(index)
      if (successLimit > 0 && successful >= successLimit) break
    }
    return { results: results, candidates: results.length, cached: cached,
      transferredBytes: transferredBytes }
  }

  async updateGeoData( geoType: string, geoName: string): Promise<string>{
    return this.socketProxy.updateGeoData(geoType, geoName)
  }
  async getTraffic(onlyProxy: boolean){
    return await this.socketProxy.queryTrafficNow(onlyProxy)
  }
  async getTotalTraffic(onlyProxy: boolean){
    return await this.socketProxy.queryTrafficTotal(onlyProxy)
  }
  async getProviders(): Promise<Provider[]>{
    return await this.socketProxy.queryProviders()
  }
  async checkIpInfo(){
    const clashConfig = AppStorage.get<ClashConfig>('clashConfig') || cardManager.getClashConfig()
    const mixedPort = Number(clashConfig?.['mixed-port'] ?? 7890)
    // IP 卡片必须反映“当前真实连接”，不能把上一次持久化的开启意图当成
    // 已连接状态；否则启动恢复失败后，播放按钮仍会检测出代理节点 IP。
    const useProxy = this.vpnStarted
    return await IpPureService.query(useProxy, mixedPort)
  }
  async queryProviders(){
    return this.socketProxy.queryProviders()
  }
  async updateProvider(provider: Provider){
    let result = await this.socketProxy.updateProvider(provider)
    if(result && result != ""){
      ClashViewModel.promptAction.showToast({message: provider.name + ":" + result})
    }
  }
  async upLoadProvider(provider: Provider, fileUri: string) {
    if(!fileUri){
      return
    }
    let result = await this.socketProxy.upLoadProvider(provider, fileUri)
    if (result && result != ""){
      ClashViewModel.promptAction.showToast({message: provider.name + ":" + result})
    }
  }

  job?: (()=>void)
  async startLog(enable: boolean, callback: (d: LogInfo) => void){
      if(enable){
        this.job = await this.socketProxy.setLogObserver((message)=>{
          callback(message)
        })
      }else{
        this.job?.()
      }
  }

  async updateProfile(profile: Profile){
    await this.profileRepo.addOrUpdate(profile)
  }
  async getProfiles(): Promise<Profile[]>{
    return await this.profileRepo.queryAll()
  }
  async getProfile(id: string): Promise<Profile | null>{
    return await this.profileRepo.query(id)
  }
  async deleteProfile(id: string): Promise<void>{
    let p = await this.getProfile(id)
    if (p) {
      // 从 RDB 恢复的 Profile 不带 Context，删除文件前必须重新绑定应用目录。
      p.loadContext(this.context)
      try {
        await p.delete()
      } catch (_) {
        // 数据库记录仍继续删除，避免已损坏/残留目录让配置永久卡在列表中。
        hilog.warn(0xC016, 'ClashViewModel', `配置文件清理异常，继续删除数据库记录，profileId=${id}`)
      }
    }
    await this.profileRepo.delete(id)
    await BitzNetCredentialStore.remove(id)
    await YhcCredentialStore.remove(id)
    EventHub.sendEvent(EventKey.FetchProfile, null)
  }
  async getConnections(){
     return await this.socketProxy.queryConnections()
  }
  async closeConnection(id:string){
    return await this.socketProxy.closeConnection(id)
  }
  async clearConnections(){
    return await this.socketProxy.clearConnections()
  }
  async getRequestList(){
    return await this.socketProxy.getRequestList()
  }
  async clearRequestList(){
    return await this.socketProxy.clearRequestList()
  }
  async getProxyGroups(model: ProxyMode): Promise<ProxyGroup[]>{
    try {
      let list = await this.socketProxy.queryProxyGroups(model)
      let favoriteProxys = AppStorage.get<Map<string, string>>("favoriteProxys")
      const groups = list.map((g)=>{
        g.proxies = g.proxies.map((p) => {
          p.isShowFavoriteProxy = favoriteProxys?.get(g.name + "|" + p.name) != null
          p.latency = -1
          p.g = g.name
          return p
        })
        return g
      })
      return groups
    } catch (e) {
      // 代理组刷新是后台/事件驱动操作。查询短暂失败时由页面保留上一份快照，
      // 不再弹出会被用户误解为配置丢失的冷启动 Toast。
      hilog.warn(0xB000, 'ProxyGroupRefresh', `核心代理组查询失败：${(e as Error).message}`)
    }
    return []
  }
  //BUG 第一次启动，参数传不过去
  // 第一次要权限弹窗
  async ChangeCore(coreType: ClashCore | undefined = undefined, restart: boolean = true) {
    if (!this.context) {
      hilog.error(0xA003, 'VpnAbilityHandshake', 'VPN Extension 启动前 Context 尚未绑定')
      return false
    }

    // 冷启动/前台恢复时若旧 VPN Extension 仍然健康，直接复用，避免为了检查
    // 状态先拆掉一个正在工作的 TUN。只有明确切换内核时 restart 才强制重建。
    if (!restart && await this.coreIsResponsive()) {
      hilog.info(0xA003, 'VpnAbilityHandshake', '复用已就绪的 VPN Extension')
      return true
    }

    const core = coreType ?? ClashCore.mihomo
    for (let attempt = 0; attempt < 3; attempt++) {
      const requestId = Date.now() + attempt
      this.vpnRequestId = requestId
      const vpnWant = {
        deviceId: "",
        bundleName: this.context.applicationInfo.name,
        abilityName: "ClashVpnAbility",
        parameters: { "ClashCore": core, requestId: requestId }
      } as Want

      // 每轮都先收敛可能残留的旧实例。stop 的 Promise 返回后仍给系统一点时间
      // 完成进程 onDestroy；新实例的锁带 requestId，旧实例也只清理自己的锁。
      try {
        await vpnExtension.stopVpnExtensionAbility(vpnWant)
      } catch (error) {
        hilog.warn(0xA003, 'VpnAbilityHandshake',
          `停止旧 VPN Extension 返回异常 attempt=${attempt + 1}, error=${JSON.stringify(error)}`)
      }
      await this.removeStaleVpnHandshake()
      await sleep(300 + attempt * 250)

      const startAccepted = await Promise.race<boolean>([
        vpnExtension.startVpnExtensionAbility(vpnWant)
          .then((): boolean => true)
          .catch((error: Error): boolean => {
            hilog.warn(0xA003, 'VpnAbilityHandshake',
              `系统拒绝启动 VPN Extension attempt=${attempt + 1}, message=${error.message}`)
            return false
          }),
        new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 6000))
      ])
      // 真机首次装载 100MB 级 HAP 的原生库可能需要约 8~10 秒。此前 8 秒
      // 截止点恰好在核心即将就绪前把进程杀掉，重试反而放大了偶发失败。
      if (startAccepted && await this.waitForVpnAbilityReady(
        requestId, 20000, core === ClashCore.mihomo)) {
        this.socketProxy.active = true
        hilog.info(0xA003, 'VpnAbilityHandshake',
          `VPN Extension 就绪 attempt=${attempt + 1}, requestId=${requestId}`)
        return true
      }
      hilog.warn(0xA003, 'VpnAbilityHandshake',
        `VPN Extension 握手未完成，准备自恢复 attempt=${attempt + 1}`)
    }

    hilog.error(0xA003, 'VpnAbilityHandshake', 'VPN Extension 连续三次启动握手失败')
    return false
  }

  private async checkVpnVpnAbility(reqId: number): Promise<boolean>{
    let lockPath = this.context?.filesDir + '/vpn_ipc.lock';
    try {
      if (!await fs.access(lockPath, fs.AccessModeType.EXIST)) {
        return false;
      } else {
        let requestId = await readText(lockPath)
        console.log('ClashViewModel.checkVpnVpnAbility 检查文件vpn_ipc.lock是否存在 readText成功：', requestId == reqId + "")
        return requestId == reqId + "";
      }
    } catch (error) {
      console.error('ClashViewModel.checkVpnVpnAbility 检查文件vpn_ipc.lock是否存在失败：', error)
      return false
    }
  }

  private async waitForVpnAbilityReady(
    requestId: number,
    timeoutMs: number,
    requireCoreRpc: boolean
  ): Promise<boolean> {
    const deadline = Date.now() + timeoutMs
    while (Date.now() < deadline) {
      if (await this.checkVpnVpnAbility(requestId)) {
        // ClashMeta/ClashRs 的调试架构只让 VPN Ability 完成系统握手，RPC
        // 服务随后由 EntryAbility 在 UI 进程创建；这里若提前要求 RPC，启动
        // 链会循环等待一个按设计尚未创建的端口。
        if (!requireCoreRpc) return true
        if (!await this.socketProxy.isCoreReady()) {
          await sleep(400)
          continue
        }
        // 文件存在只是第一层证据；再做一次真实 RPC，排除异常退出遗留的 socket。
        try {
          await this.socketProxy.getRuntime(true)
          return true
        } catch (_) {
        }
      }
      await sleep(400)
    }
    return false
  }

  private async removeStaleVpnHandshake(): Promise<void> {
    const lockPath = this.context?.filesDir + '/vpn_ipc.lock'
    if (!lockPath) return
    try {
      if (await fs.access(lockPath, fs.AccessModeType.EXIST)) {
        fs.unlinkSync(lockPath)
      }
    } catch (_) {
      // onDestroy 可能正好先一步删除；目标状态已经达到。
    }
  }

  async ensureCoreReady(): Promise<boolean> {
    if (await this.coreIsResponsive()) {
      return true
    }
    if (this.coreStarting) {
      for (let index = 0; index < 20; index++) {
        await sleep(200)
        if (await this.coreIsResponsive()) {
          return true
        }
      }
      return false
    }
    this.coreStarting = true
    try {
      const core = (AppStorage.get<AppConfig>("appConfig") || cardManager.getAppConfig())?.clashCore
      // 文件可能在异常退出后残留，核心无响应时强制重建 VPN Extension。
      const started = await this.ChangeCore(core, true)
      if (!started) {
        return false
      }
      // 非 mihomo 模式的 RPC 服务由 ClashCoreInit 紧接着在 UI 进程创建。
      // VPN Ability 的带 requestId 握手完成即代表这一阶段成功。
      if (core !== ClashCore.mihomo) return true
      for (let index = 0; index < 20; index++) {
        if (await this.coreIsResponsive()) {
          this.socketProxy.active = true
          return true
        }
        await sleep(200)
      }
      return false
    } finally {
      this.coreStarting = false
    }
  }

  /** 静默验证本地 RPC；requireTunnel=true 时还要求 Go TUN 已记录运行时间。 */
  private async coreIsResponsive(requireTunnel: boolean = false,
    requestTimeoutMs: number = 10000): Promise<boolean> {
    if (!await this.socketProxy.isCoreReady()) return false
    try {
      const runtime = await this.socketProxy.getRuntime(true, requestTimeoutMs)
      return !requireTunnel || (Number.isFinite(Number(runtime)) && Number(runtime) > 0)
    } catch (_) {
      return false
    }
  }

  async loadProfileAndConfig(id: string, config: ClashConfig | null = null, params: ConfigExtendedParams | null= null){
    // A same-named node in a new or refreshed profile is not the old endpoint.
    this.delayContextKey = ''
    this.resetNodeDelays()
    let result = await this.socketProxy.loadConfig({
      "profile-id": id,
      config: config ?? new ClashConfig(),
      params: params ?? {} as ConfigExtendedParams
    } as UpdateConfigParams)
    if (result != ""){
      ClashViewModel.promptAction.showToast({message: result, duration: 3000 })
      throw new Error(result)
    }
    EventHub.sendEvent(EventKey.FetchProxyGroup, null)
  }
  async ReStartVpn(){
    if(this.vpnStarted){
      await this.loadConfig(false, 'ReStartVpn')
      await this.loadVpnOptions()
      await this.socketProxy.stopClash()
      await this.socketProxy.startClash()
    }
  }

  /**
   * VPN 选项（例如访问控制名单）变更后防抖重建系统隧道。
   * VPN 原本未运行时只保存选项，不会自动启动。
   */
  scheduleVpnOptionsRestart(reason: string): boolean {
    if (!this.vpnStarted && !this.vpnOptionsRestarting) {
      hilog.info(0xA003, 'ClashViewModel', `VPN 未运行，${reason}已保存，下次启动时生效`)
      return false
    }

    this.vpnOptionsRestartPending = true
    hilog.info(0xA003, 'ClashViewModel', `已排队 VPN 选项重启：${reason}`)

    // 重启期间的新变更由 pending 标记合并，当前轮完成后再重建一次。
    if (this.vpnOptionsRestarting) {
      return true
    }

    if (this.vpnOptionsRestartTimer !== -1) {
      clearTimeout(this.vpnOptionsRestartTimer)
    }
    this.vpnOptionsRestartTimer = setTimeout(async () => {
      this.vpnOptionsRestartTimer = -1
      await this.applyPendingVpnOptionsRestart()
    }, 700)
    return true
  }

  private async applyPendingVpnOptionsRestart(): Promise<void> {
    if (this.vpnOptionsRestarting || !this.vpnStarted) {
      if (!this.vpnStarted) this.vpnOptionsRestartPending = false
      return
    }

    this.vpnOptionsRestarting = true
    let restartSucceeded = true
    try {
      while (this.vpnOptionsRestartPending) {
        this.vpnOptionsRestartPending = false
        await this.StopVpn(true)
        restartSucceeded = await this.StartVpn()
        if (!restartSucceeded) {
          this.vpnOptionsRestartPending = false
          break
        }
      }
    } catch (error) {
      restartSucceeded = false
      this.vpnOptionsRestartPending = false
      hilog.error(0xA003, 'ClashViewModel', `VPN 选项自动重启异常：${JSON.stringify(error)}`)
    } finally {
      this.vpnOptionsRestarting = false
    }

    Xb_ToastUtil.showToast({
      message: restartSucceeded ? '访问控制已自动生效' : '访问控制已保存，VPN 自动重启失败'
    })
  }

  /**
   * TUN 成功即代表 VPN 已启动；dataTransfer 只是额外的后台保活层。
   * HarmonyOS 偶尔会让 startBackgroundRunning 卡到系统 RPC 超时，不能因此
   * 把已经建立的 TUN 回滚成“启动失败”。保活申请改为异步、限次重试。
   */
  private startVpnBackgroundKeepAlive(epoch: number, attempt: number = 0): void {
    const context = this.context
    if (!context || !this.vpnStarted || epoch !== this.vpnBackgroundEpoch) return

    BackgroundDownService.start(context).then((started: boolean) => {
      if (!this.vpnStarted || epoch !== this.vpnBackgroundEpoch) return
      if (started) {
        hilog.info(0xA003, 'ClashViewModel', 'VPN dataTransfer 长时保活已就绪')
        return
      }
      hilog.warn(0xA003, 'ClashViewModel', `VPN dataTransfer 长时保活未就绪 attempt=${attempt + 1}`)
      this.scheduleVpnBackgroundKeepAliveRetry(epoch, attempt)
    }).catch((error: Error) => {
      if (!this.vpnStarted || epoch !== this.vpnBackgroundEpoch) return
      hilog.warn(0xA003, 'ClashViewModel',
        `VPN dataTransfer 长时保活请求异常 attempt=${attempt + 1}, message=${error.message}`)
      this.scheduleVpnBackgroundKeepAliveRetry(epoch, attempt)
    })
  }

  private scheduleVpnBackgroundKeepAliveRetry(epoch: number, attempt: number): void {
    if (attempt >= 2 || !this.vpnStarted || epoch !== this.vpnBackgroundEpoch) return
    if (this.vpnBackgroundRetryTimer !== -1) clearTimeout(this.vpnBackgroundRetryTimer)
    this.vpnBackgroundRetryTimer = setTimeout(() => {
      this.vpnBackgroundRetryTimer = -1
      this.startVpnBackgroundKeepAlive(epoch, attempt + 1)
    }, 1500)
  }
  vpnStarted = false

  /** 清理启动失败后可能已经创建的半连接 TUN，并同步所有 UI 为关闭。 */
  private async cleanupFailedVpnStart(clearDesiredState: boolean): Promise<void> {
    this.vpnStarted = false
    this.vpnExpectedRunning = false
    this.lastVpnHealthAt = 0
    this.stopVpnWatchdog()
    this.vpnBackgroundEpoch++
    if (this.vpnBackgroundRetryTimer !== -1) clearTimeout(this.vpnBackgroundRetryTimer)
    this.vpnBackgroundRetryTimer = -1
    if (clearDesiredState) cardManager.setVpnDesiredRunning(false)
    try {
      await this.socketProxy.stopClash()
    } catch (error) {
      hilog.warn(0xA003, 'ClashViewModel', `清理启动失败的 TUN 时子进程已失联=${JSON.stringify(error)}`)
    }
    try {
      await BackgroundDownService.stop(this.context!)
    } catch (error) {
      hilog.warn(0xA003, 'ClashViewModel', `清理启动失败的后台任务异常=${JSON.stringify(error)}`)
    }
    EventHub.sendEvent(EventKey.StopedClash)
    EventHub.sendEvent(EventKey.StopedClashEntry)
    EventHub.sendEvent(EventKey.checkIpInfo)
    cardManager.pushCartProxyMode(false)
  }

  // 启动前要加载配置
  // loadConfig
  async StartVpn(silent: boolean = false): Promise<boolean>{
    const operation: Promise<boolean> = this.vpnLifecycleQueue.then(async (): Promise<boolean> => {
      // Repeated restore/foreground/button requests converge on the already
      // healthy tunnel instead of creating a second system VPN connection.
      if (this.vpnStarted && await this.coreIsResponsive(true)) {
        hilog.info(0xA003, 'VpnLifecycle', '忽略重复启动请求：当前 TUN 已健康运行')
        return true
      }
      return await this.startVpnOnce(silent)
    })
    this.vpnLifecycleQueue = operation.then((): void => {}, (): void => {})
    return await operation
  }

  private markVpnStarted(appConfig: AppConfig): void {
    this.vpnStarted = true
    this.vpnExpectedRunning = true
    this.lastVpnHealthAt = Date.now()
    this.nodeFailoverFailures = 0
    this.nodeFailoverLastProbeAt = 0
    this.vpnRestoreRetryAttempts = 0
    if (this.vpnRestoreRetryTimer !== -1) clearTimeout(this.vpnRestoreRetryTimer)
    this.vpnRestoreRetryTimer = -1
    cardManager.setVpnDesiredRunning(true)
    this.publishNodeFailoverState(appConfig.autoFailoverEnabled === false ? 'disabled' : 'monitoring',
      appConfig.autoFailoverEnabled === false ? '已关闭' : 'VPN 已连接，等待首轮节点健康检查')
    this.startVpnWatchdog()
    // VPN 与系统 dataTransfer 长时任务及实况窗进度绑定，避免应用退到后台后
    // 代理内核被冻结、停止读取 TUN。保活接口不阻塞已经成功的 TUN 启动。
    const backgroundEpoch = ++this.vpnBackgroundEpoch
    this.startVpnBackgroundKeepAlive(backgroundEpoch)
    EventHub.sendEvent(EventKey.StartedClash)
  }

  /**
   * startClash 的控制 socket 回包偶尔丢失，但 Go RPC 与 TUN 已经可用。并行
   * 观察真实运行时间，避免健康隧道仍等待完整 45 秒控制超时，连带延迟
   * dataTransfer 保活通知与配置定时任务启动。
   */
  private async startClashWithRuntimeWitness(silent: boolean): Promise<boolean> {
    const startRequest = this.socketProxy.startClash(silent)
    return await Promise.race<boolean>([
      startRequest,
      this.waitForStartedTunnelOrRequest(startRequest)
    ])
  }

  private async waitForStartedTunnelOrRequest(startRequest: Promise<boolean>): Promise<boolean> {
    for (let attempt = 0; attempt < 48; attempt++) {
      await sleep(250)
      if (await this.coreIsResponsive(true)) {
        hilog.info(0xA003, 'VpnLifecycle', 'TUN 已运行，提前完成启动等待')
        return true
      }
    }
    return await startRequest
  }

  private async startVpnOnce(silent: boolean): Promise<boolean>{
    const appConfig = AppStorage.get<AppConfig>("appConfig") || cardManager.getAppConfig()
    if (!appConfig?.currentProfileId) {
      if (!silent) ClashViewModel.promptAction.showToast({message: "请先选择配置"})
      return false
    }
    try {
      hilog.info(0xA003, 'ClashViewModel', 'StartVpn 阶段1：检查内核')
      if (!await this.ensureCoreReady()) {
        if (!silent) ClashViewModel.promptAction.showToast({message: "代理核心启动失败"})
        return false
      }
      hilog.info(0xA003, 'ClashViewModel', 'StartVpn 阶段2：检查配置')
      if (!await this.vpnConfigIsLoad()) {
        const loaded = await this.loadConfig(false, 'StartVpn')
        if (!loaded || !await this.vpnConfigIsLoad()) {
          if (!silent) ClashViewModel.promptAction.showToast({message: "当前配置加载失败"})
          return false
        }
      }
      hilog.info(0xA003, 'ClashViewModel', 'StartVpn 阶段3：加载 VPN 选项')
      await this.loadVpnOptions()
      // Prime Mihomo's physical-interface table before installing the TUN.
      // Otherwise a process restored directly onto cellular can retain the
      // previous wlan0 snapshot until a later network callback happens.
      await this.refreshPhysicalInterfaces(this.networkGeneration)
      hilog.info(0xA003, 'ClashViewModel', 'StartVpn 阶段4：创建 TUN')
      let result = await this.startClashWithRuntimeWitness(silent)
      // 核心崩溃 小钥匙一直在，要重启两量变
      if (!result){
        result = await this.startClashWithRuntimeWitness(silent)
      }
      if (result){
        this.markVpnStarted(appConfig)
      } else {
        await this.cleanupFailedVpnStart(!silent)
        if (!silent) ClashViewModel.promptAction.showToast({message: "VPN TUN 创建失败"})
        return false
      }
    } catch (error) {
      // The start request and its response use different local sockets.  If the
      // response is delayed/lost after HarmonyOS has already installed the TUN,
      // runtime is the authoritative result.  Preserve that live tunnel instead
      // of turning a control-plane timeout into a user-visible data-plane reset.
      if (await this.coreIsResponsive(true)) {
        hilog.warn(0xA003, 'VpnLifecycle',
          `启动 RPC 返回异常但 TUN 已运行，按真实运行状态接管：${JSON.stringify(error)}`)
        this.markVpnStarted(appConfig)
      } else {
        await this.cleanupFailedVpnStart(!silent)
        hilog.error(0xA003, 'ClashViewModel',
          `StartVpn RPC 或 VPN Extension 通信失败：${JSON.stringify(error)}`)
        if (!silent) ClashViewModel.promptAction.showToast({message: "VPN 启动失败：服务通信异常，请重试"})
        return false
      }
    }
    // VPN Extension 的 startClash 返回与 Go TUN 写入运行时间之间可能只差数毫秒。
    // 访问控制自动重启很快时不要把“服务未启动”写进计时器。
    let runTime = await this.getRuntime()
    for (let index = 0; index < 20 &&
      (!Number.isFinite(Number(runTime)) || Number(runTime) <= 0); index++) {
      await sleep(50)
      runTime = await this.getRuntime()
    }
    if (!Number.isFinite(Number(runTime)) || Number(runTime) <= 0) {
      runTime = new Date().getTime()
      hilog.warn(0xA003, 'ClashViewModel', 'TUN 已启动但运行时间尚未就绪，使用当前时间初始化计时器')
    }
    hilog.info(0x001, "EntryAbility", "StartVpn时间戳: " + runTime)
    // 启动前先初始化卡片显示文本
    cardManager.pushCartVpnServiceTime(PROXY_STARTED_DURATION_INIT_VALUE)
    // 计算时间
    const vpnServiceStartTime = Number(runTime)
    this.proxyStartedTimer.start((time)=>{
      EventHub.sendEvent(EventKey.ProxyDuration, time)
      cardManager.pushCartVpnServiceTime(number2Time(time))
    },vpnServiceStartTime)

    EventHub.on(EventKey.StopedClashEntry,()=>{
      hilog.info(0x001, "ClashViewModel", "StopedClashEntry事件")
      this.proxyStartedTimer.reset()
    })

    cardManager.pushCartProxyMode(this.vpnStarted)
    return true
  }
  async loadVpnOptions(){
    // 使用首选项持久化单个节点信息供卡片拉起服务
    let appConfig = AppStorage.get<AppConfig>("appConfig") || cardManager.getAppConfig()
    let clashConfig = AppStorage.get<ClashConfig>("clashConfig") || cardManager.getClashConfig()
    if (appConfig == null)
      return
    if (appConfig!.accessControl) {
      // 从数据库加载白名单
      const whiteApps = await accessControlRdb.getAppsByDomain('WHITE', 'name');
      // 提取出处于“选中”状态的包名
      let acceptList = whiteApps.filter(a => a.isSelected).map(a => a.package_name);
      // 补充强制放行的包名
      const protectedPackages = [
        this.context?.applicationInfo.name as string,
        'com.atomicservice.5765880207855877209'
      ];
      // 去重并加入保护列表
      protectedPackages.forEach(pkg => {
        if (pkg && !acceptList.includes(pkg)) {
          acceptList.push(pkg);
        }
      });
      // 从数据库加载黑名单
      const blackApps = await accessControlRdb.getAppsByDomain('BLACK', 'name');
      // 提取出处于“选中”状态的包名
      const rejectList = blackApps.filter(a => a.isSelected).map(a => a.package_name);
      console.log(`AccessControl 将加载 acceptList ${acceptList.length} 个，rejectList ${rejectList.length} 个`)
      const accessControl = {
        tunIp : clashConfig?.tun?.["tun-ip"],
        // Keep the VPN address family aligned with the loaded Mihomo profile.
        // Capturing ::/0 while the runtime resolver/outbound has IPv6 disabled
        // creates a black-hole path: dual-stack apps wait for the IPv6 attempt
        // to time out before retrying OpenAI/Telegram traffic over IPv4.
        ipv6: clashConfig?.ipv6 === true,
        routeAddress: clashConfig?.["route-address"] ?? [],
        accessControl: { mode:appConfig?.accessControlMode ?? "", acceptList: acceptList, rejectList: rejectList } as AccessControl
      } as VpnRawOptions
      // 必须等 VPN 进程确认写入后再创建 TUN；否则自动重启可能读到上一轮空名单。
      await this.socketProxy.setOptionStates(accessControl)
    } else {
      const accessControl = {
        tunIp : clashConfig?.tun?.["tun-ip"],
        // Do not advertise/capture IPv6 unless the active profile can carry it.
        ipv6: clashConfig?.ipv6 === true,
        routeAddress: clashConfig?.["route-address"] ?? [],
        accessControl: { mode:appConfig?.accessControlMode ?? "", acceptList: [], rejectList: [] } as AccessControl } as VpnRawOptions
      await this.socketProxy.setOptionStates(accessControl)
    }
    // 在日志控制台 过滤关键字 vpnConfig, 验证是否配置成功

  }

  async StopVpn(preserveDesiredState: boolean = false){
    // Invalidate an in-flight watchdog probe before it reaches the lifecycle
    // queue. Otherwise a user stop queued behind a slow probe could be
    // followed by a stale automatic StartVpn request.
    this.vpnWatchdogGeneration++
    this.vpnExpectedRunning = false
    const operation: Promise<void> = this.vpnLifecycleQueue.then(async (): Promise<void> => {
      await this.stopVpnOnce(preserveDesiredState)
    })
    this.vpnLifecycleQueue = operation.then((): void => {}, (): void => {})
    await operation
  }

  private async stopVpnOnce(preserveDesiredState: boolean): Promise<void> {
    if (!preserveDesiredState) {
      cardManager.setVpnDesiredRunning(false)
    }
    this.vpnExpectedRunning = false
    this.lastVpnHealthAt = 0
    this.vpnRestoreRetryAttempts = 0
    if (this.vpnRestoreRetryTimer !== -1) clearTimeout(this.vpnRestoreRetryTimer)
    this.vpnRestoreRetryTimer = -1
    this.stopVpnWatchdog()
    this.nodeFailoverFailures = 0
    this.nodeFailoverLastProbeAt = 0
    this.publishNodeFailoverState('inactive', 'VPN 未连接')
    this.vpnBackgroundEpoch++
    if (this.vpnBackgroundRetryTimer !== -1) clearTimeout(this.vpnBackgroundRetryTimer)
    this.vpnBackgroundRetryTimer = -1
    this.vpnStarted = false
    try {
      await this.socketProxy.stopClash()
    } catch (error) {
      hilog.warn(0xA003, 'ClashViewModel', `停止 VPN 时子进程已失联=${JSON.stringify(error)}`)
    } finally {
      await BackgroundDownService.stop(this.context!)
    }
    // Index里的停止后操作
    EventHub.sendEvent(EventKey.StopedClash)
    // EntryAbility里的停止后操作
    EventHub.sendEvent(EventKey.StopedClashEntry)
    EventHub.sendEvent(EventKey.checkIpInfo)
    cardManager.pushCartProxyMode(this.vpnStarted)
    this.proxyStartedTimer.reset()
  }

  /**
   * Coalesce Wi-Fi/cellular availability, capability and property callbacks
   * into one network generation.  A healthy TUN/core only receives the new
   * physical-interface snapshot and a small stale-connection probe; a full
   * VPN rebuild is the escalation path when the real runtime check fails.
   */
  scheduleNetworkGenerationRecovery(reason: string = 'network event'): void {
    hilog.info(0xA003, 'NetworkRecovery',
      `收到网络环境事件 reason=${reason}, vpn=${this.vpnStarted}, expected=${this.vpnExpectedRunning}`)
    this.networkGeneration++
    this.networkRecoveryPending = true
    if (this.networkRecoveryTimer !== -1) clearTimeout(this.networkRecoveryTimer)
    this.networkRecoveryTimer = setTimeout(() => {
      this.networkRecoveryTimer = -1
      this.runNetworkGenerationRecovery().catch((error: Error) => {
        hilog.warn(0xA003, 'NetworkRecovery', `网络代际恢复异常：${error.message}`)
      })
    }, 1200)
  }

  cancelNetworkGenerationRecovery(): void {
    this.networkGeneration++
    this.networkRecoveryPending = false
    if (this.networkRecoveryTimer !== -1) clearTimeout(this.networkRecoveryTimer)
    this.networkRecoveryTimer = -1
  }

  /**
   * Fallback for devices that do not emit a default-network callback during a
   * Wi-Fi/cellular handoff. This method intentionally performs no native RPC
   * when the key is unchanged; the recovery path is scheduled only after the
   * physical interface snapshot differs from the one installed in mihomo.
   */
  async pollDefaultNetworkGeneration(reason: string = 'network poll'): Promise<void> {
    if (!this.vpnStarted || !this.vpnExpectedRunning) return
    try {
      const netHandle = await connection.getDefaultNet()
      const properties = await connection.getConnectionProperties(netHandle)
      const capabilities = await connection.getNetCapabilities(netHandle)
      const interfaceName = properties.interfaceName
      if (!interfaceName) return
      const addresses = properties.linkAddresses
        .filter((item) => item.address.family === 1)
        .map((item): string => item.address.address)
      if (addresses.length === 0) return
      const bearer = capabilities.bearerTypes.map((item): string => `${item}`).join(',')
      const networkKey = `${netHandle.netId}|${interfaceName}|${bearer}|${addresses.join(',')}`
      if (!this.activePhysicalNetworkKey) {
        hilog.info(0xA003, 'NetworkRecovery',
          `网络轮询发现当前 VPN 尚无物理接口快照 reason=${reason}, key=${networkKey}`)
        this.scheduleNetworkGenerationRecovery(reason)
        return
      }
      if (networkKey !== this.activePhysicalNetworkKey) {
        hilog.warn(0xA003, 'NetworkRecovery',
          `网络轮询发现物理网络变化 reason=${reason}, old=${this.activePhysicalNetworkKey}, new=${networkKey}`)
        this.scheduleNetworkGenerationRecovery(reason)
      }
    } catch (error) {
      hilog.debug(0xA003, 'NetworkRecovery',
        `网络轮询读取默认网络失败 reason=${reason}, message=${(error as Error).message}`)
    }
  }

  private async runNetworkGenerationRecovery(): Promise<void> {
    if (this.networkRecoveryRunning) return
    this.networkRecoveryRunning = true
    this.networkRecoveryPending = false
    const generation = this.networkGeneration
    try {
      if (!this.vpnExpectedRunning || !this.vpnStarted) return
      const networkChanged = await this.refreshPhysicalInterfaces(generation)
      if (generation !== this.networkGeneration) return
      if (networkChanged) {
        // Every TCP/UDP flow is bound to the old physical network. Waiting for
        // byte counters to stop misses half-open ChatGPT HTTP/2/WebSocket
        // sessions, which then remain at "正在发送". Drop the old generation
        // atomically and let clients reconnect through the new interface.
        await this.socketProxy.clearConnections()
        hilog.info(0xA003, 'NetworkRecovery',
          `网络代际 ${generation} 已清理旧物理网络连接`)
        await sleep(250)
      } else {
        await this.recoverStaleNetworkConnections(generation)
      }
      const controlHealthy = generation === this.networkGeneration && await this.coreIsResponsive(true)
      const dataHealthy = !networkChanged || (controlHealthy && await this.activeNodeDataPlaneResponsive())
      const healthy = controlHealthy && dataHealthy
      if (healthy) {
        this.lastVpnHealthAt = Date.now()
        hilog.info(0xA003, 'NetworkRecovery',
          `网络代际 ${generation} 已恢复 changed=${networkChanged}，保持 TUN`)
        // 网络回调发生时应用经常正处于 ChatGPT 等前台客户端。不要在
        // 物理网络刚恢复的窗口里并发发起 IP/平台诊断；先让真实客户端
        // 占用连接窗口。回到 ClashBox 前台时再由 Started/foreground 链
        // 刷新卡片，后台场景直接跳过本次诊断。
        if (AppStorage.get<boolean>('ForwardState') !== false) {
          EventHub.sendEvent(EventKey.checkIpInfo, { force: true, reason: 'network recovered' })
        }
        return
      }
      // Do not rebuild after a newer event or a user stop. StopVpn's lifecycle
      // queue remains the single teardown barrier for rapid stop/start races.
      if (generation !== this.networkGeneration || !this.vpnExpectedRunning ||
        !cardManager.getVpnDesiredRunning()) return
      const restoreAfterStop = cardManager.getVpnDesiredRunning()
      hilog.warn(0xA003, 'NetworkRecovery',
        `网络代际 ${generation} 健康检查失败 control=${controlHealthy} data=${dataHealthy}，升级为完整 VPN 重建`)
      await this.StopVpn(true)
      // stopVpnOnce intentionally clears the in-memory expected-running bit,
      // so testing that bit here made this branch permanently unreachable.
      // The persisted user intent is the authoritative restart condition.
      if (generation === this.networkGeneration && restoreAfterStop &&
        cardManager.getVpnDesiredRunning()) {
        await this.StartVpn(true)
      }
    } finally {
      this.networkRecoveryRunning = false
      if (this.networkRecoveryPending && this.networkRecoveryTimer === -1) {
        this.networkRecoveryTimer = setTimeout(() => {
          this.networkRecoveryTimer = -1
          this.runNetworkGenerationRecovery().catch(() => {})
        }, 300)
      }
    }
  }

  private async refreshPhysicalInterfaces(generation: number): Promise<boolean> {
    try {
      const netHandle = await connection.getDefaultNet()
      // ArkTS does not support destructuring declarations. These two reads
      // describe the same immutable NetHandle and are cheap compared with the
      // following native RPC.
      const properties = await connection.getConnectionProperties(netHandle)
      const capabilities = await connection.getNetCapabilities(netHandle)
      if (generation !== this.networkGeneration) return false
      const interfaceName = properties.interfaceName
      if (!interfaceName) return false
      // The native bridge intentionally receives IPv4 addresses only. Runtime
      // IPv6 remains disabled for the validated ChatGPT path, while the
      // physical interface snapshot still updates on every network handoff.
      const addresses: NetworkInterfaceSnapshot[] = properties.linkAddresses
        .filter((item) => item.address.family === 1)
        .map((item): NetworkInterfaceSnapshot => {
          const ipAddress: NetworkIpAddressSnapshot = {
            address: item.address.address,
            family: 4,
            port: 0
          }
          return { iface: interfaceName, macAddress: '', ipAddress: ipAddress }
        })
      if (addresses.length === 0) {
        hilog.warn(0xA003, 'NetworkRecovery',
          `默认网络没有可用 IPv4 iface=${interfaceName}, netId=${netHandle.netId}`)
        return false
      }
      const bearer = capabilities.bearerTypes.map((item): string => `${item}`).join(',')
      const networkKey = `${netHandle.netId}|${interfaceName}|${bearer}|` +
        addresses.map((item): string => item.ipAddress.address).join(',')
      const previousKey = this.activePhysicalNetworkKey
      const changed = previousKey.length > 0 && previousKey !== networkKey
      const interfaceError = await this.socketProxy.setNetInterfaces(addresses)
      if (interfaceError) throw new Error(interfaceError)
      this.activePhysicalNetworkKey = networkKey
      hilog.info(0xA003, 'NetworkRecovery',
        `网络接口已更新 generation=${generation}, netId=${netHandle.netId}, iface=${interfaceName}, ` +
        `bearer=${bearer}, ipv4=${addresses.length}, changed=${changed}`)
      return changed
    } catch (error) {
      hilog.debug(0xA003, 'NetworkRecovery', `读取物理接口快照失败：${(error as Error).message}`)
      return false
    }
  }

  /** Verify one real outbound after a physical handoff, not merely the RPC socket. */
  private async activeNodeDataPlaneResponsive(): Promise<boolean> {
    try {
      const context = await this.activeNodeFailoverContext()
      if (!context) return true
      const result = await this.socketProxy.healthCheckDetailed(
        context.currentName, 'https://www.gstatic.com/generate_204', 3500)
      hilog.info(0xA003, 'NetworkRecovery',
        `网络切换出口探测 node=${context.currentName}, delay=${result.value}, code=${result.errorCode ?? ''}`)
      return result.value > 0
    } catch (error) {
      hilog.warn(0xA003, 'NetworkRecovery',
        `网络切换出口探测异常：${(error as Error).message}`)
      return false
    }
  }

  private async recoverStaleNetworkConnections(generation: number): Promise<void> {
    const first = await this.socketProxy.queryConnections()
    if (generation !== this.networkGeneration || first.length === 0) return
    await sleep(700)
    const second = await this.socketProxy.queryConnections()
    if (generation !== this.networkGeneration) return
    const stale = first.filter((item) => {
      const current = second.find((next) => next.id === item.id)
      return current !== undefined && current.upload === item.upload &&
        current.download === item.download
    })
    for (const item of stale) {
      try { await this.socketProxy.closeConnection(item.id) } catch (_) {}
    }
    if (stale.length > 0) {
      hilog.info(0xA003, 'NetworkRecovery',
        `网络代际清理静止旧连接 generation=${generation}, count=${stale.length}`)
    }
  }

  /** 标记 UI 离开前台；VPN Extension 和核心继续独立运行。 */
  markAppBackground(): void {
    this.appBackgroundAt = this.vpnStarted ? Date.now() : 0
    hilog.info(0xA003, 'VpnConnectionRecovery',
      `应用进入后台，记录旧连接边界 vpn=${this.vpnStarted}`)
  }

  /**
   * 应用回到前台后延迟清理疑似半连接。
   *
   * 先取一次连接快照，等待 800ms 再取一次；只有连接在进入后台前就已
   * 建立、年龄超过 15 秒且上下行字节完全没有变化时才关闭。这样 Telegram
   * 的旧长连接会被迫重新握手，但正在播放视频、下载文件或有其他流量的
   * 连接不会因切换应用而中断。
   */
  scheduleForegroundConnectionRecovery(delayMs: number = 1500): void {
    if (this.foregroundRecoveryTimer !== -1) clearTimeout(this.foregroundRecoveryTimer)
    this.foregroundRecoveryTimer = setTimeout(() => {
      this.foregroundRecoveryTimer = -1
      this.recoverStaleForegroundConnections().catch((error: Error) => {
        hilog.warn(0xA003, 'VpnConnectionRecovery',
          `前台旧连接恢复检查异常：${error.message}`)
      })
    }, delayMs)
  }

  private connectionStartMillis(value: number): number {
    const numeric = Number(value)
    if (Number.isFinite(numeric) && numeric > 0) return numeric
    const parsed = Date.parse(String(value))
    return Number.isFinite(parsed) ? parsed : 0
  }

  private async recoverStaleForegroundConnections(): Promise<void> {
    if (this.foregroundRecoveryRunning) return
    const backgroundAt = this.appBackgroundAt
    this.appBackgroundAt = 0
    if (!backgroundAt || !this.vpnStarted || !this.vpnExpectedRunning) return

    const awayMs = Date.now() - backgroundAt
    // 短暂切换应用不触发连接淘汰，避免频繁前后台造成不必要的重连。
    if (awayMs < 5000) return

    this.foregroundRecoveryRunning = true
    try {
      const first = await this.socketProxy.queryConnections()
      const cutoff = backgroundAt - 1000
      const candidates = first.filter((item) => {
        const startedAt = this.connectionStartMillis(item.start)
        return startedAt > 0 && startedAt < cutoff &&
          Date.now() - startedAt >= 15000
      })
      if (candidates.length === 0) return

      await sleep(800)
      const second = await this.socketProxy.queryConnections()
      const stale = candidates.filter((item) => {
        const current = second.find((next) => next.id === item.id)
        return current !== undefined && current.upload === item.upload &&
          current.download === item.download
      })
      if (stale.length === 0) return

      let closed = 0
      for (const item of stale) {
        try {
          await this.socketProxy.closeConnection(item.id)
          closed++
        } catch (error) {
          hilog.debug(0xA003, 'VpnConnectionRecovery',
            `旧连接关闭失败 id=${item.id}, message=${(error as Error).message}`)
        }
      }
      hilog.info(0xA003, 'VpnConnectionRecovery',
        `前台恢复已清理疑似半连接 stale=${stale.length}, closed=${closed}, awayMs=${awayMs}`)
    } finally {
      this.foregroundRecoveryRunning = false
    }
  }

  /**
   * 主进程冷启动后恢复用户最后一次成功开启的 VPN。VPN Extension 与主 UI
   * 属于不同进程，系统重建 UI 时内存中的 vpnStarted 会回到 false；此前这会
   * 让代理永久停在关闭状态，直到用户再次手动点击。
   */
  async restoreDesiredVpnState(): Promise<boolean> {
    if (!cardManager.getVpnDesiredRunning()) {
      this.vpnRestoreRetryAttempts = 0
      if (this.vpnRestoreRetryTimer !== -1) clearTimeout(this.vpnRestoreRetryTimer)
      this.vpnRestoreRetryTimer = -1
      return false
    }
    if (this.vpnStarted && await this.coreIsResponsive(true)) {
      this.vpnRestoreRetryAttempts = 0
      return true
    }
    if (this.vpnRestoreInProgress) return false

    this.vpnRestoreInProgress = true
    try {
      hilog.info(0xA003, 'ClashViewModel', '检测到持久化 VPN 开启意图，开始自动恢复')
      const restored = await this.StartVpn(true)
      hilog.info(0xA003, 'ClashViewModel', `持久化 VPN 自动恢复结果=${restored}`)
      if (!restored) this.scheduleVpnRestoreRetry()
      return restored
    } finally {
      this.vpnRestoreInProgress = false
    }
  }

  /** 安装升级或异常退出后系统可能仍在释放旧 TUN，按退避间隔自动重试。 */
  private scheduleVpnRestoreRetry(): void {
    if (!cardManager.getVpnDesiredRunning() || this.vpnRestoreRetryTimer !== -1 ||
      this.vpnRestoreRetryAttempts >= 3) return
    const delay = 1500 * (this.vpnRestoreRetryAttempts + 1)
    this.vpnRestoreRetryAttempts++
    hilog.warn(0xA003, 'ClashViewModel',
      `持久化 VPN 将自动重试 attempt=${this.vpnRestoreRetryAttempts}, delay=${delay}`)
    this.vpnRestoreRetryTimer = setTimeout(async (): Promise<void> => {
      this.vpnRestoreRetryTimer = -1
      await this.restoreDesiredVpnState()
    }, delay)
  }

  private publishNodeFailoverState(state: string, detail: string): void {
    AppStorage.setOrCreate('autoFailoverState', state)
    AppStorage.setOrCreate('autoFailoverFailures', this.nodeFailoverFailures)
    AppStorage.setOrCreate('autoFailoverDetail', detail)
    AppStorage.setOrCreate('autoFailoverUpdatedAt', Date.now())
  }

  setAutoFailoverEnabled(enabled: boolean): void {
    const appConfig = AppStorage.get<AppConfig>('appConfig') || cardManager.getAppConfig() || new AppConfig()
    appConfig.autoFailoverEnabled = enabled
    AppStorage.setOrCreate('appConfig', appConfig)
    AppStorage.set('appConfig', appConfig)
    cardManager.setAppConfig(appConfig)
    this.nodeFailoverFailures = 0
    this.nodeFailoverLastProbeAt = 0
    this.publishNodeFailoverState(enabled ? 'monitoring' : 'disabled',
      enabled ? '已开启，连续3次双源检测失败后才会自动切换' : '已关闭')
  }

  private isConcreteProxyItem(item: ProxyItem): boolean {
    const nonNodes = ['Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay',
      'Direct', 'Reject', 'RejectDrop']
    return !nonNodes.includes(item.type) && item.name !== 'DIRECT' && item.name !== 'REJECT'
  }

  private async activeNodeFailoverContext(): Promise<ActiveNodeFailoverContext | undefined> {
    const appConfig = AppStorage.get<AppConfig>('appConfig') || cardManager.getAppConfig()
    if (!appConfig?.currentProfileId) return undefined
    const profile = await this.profileRepo.query(appConfig.currentProfileId)
    if (!profile) return undefined
    const clashConfig = AppStorage.get<ClashConfig>('clashConfig') || cardManager.getClashConfig()
    const groups = await this.getProxyGroups(clashConfig?.mode ?? ProxyMode.Rule)
    if (groups.length === 0) return undefined
    const preferredGroup = appConfig.currentProxyItem?.g ?? profile.currentGroupName ?? ''
    const configuredName = appConfig.currentProxyName ?? appConfig.currentProxyItem?.name ?? ''
    let group = groups.find((item: ProxyGroup): boolean => item.name === preferredGroup &&
      item.proxies.some((proxy): boolean => proxy.name === configuredName))
    if (!group) {
      group = groups.find((item: ProxyGroup): boolean => {
        const selected = profile.getSelectedProxy(item) ?? item.now
        return selected === configuredName && item.proxies.some((proxy): boolean => proxy.name === configuredName)
      })
    }
    if (!group) return undefined
    const selectedName = configuredName || profile.getSelectedProxy(group) || group.now
    const selected = group.proxies.find((item): boolean => item.name === selectedName) as ProxyItem
    if (!selected || !this.isConcreteProxyItem(selected)) return undefined
    return { profile: profile, group: group, currentName: selectedName }
  }

  private rankedAutoFailoverCandidates(context: ActiveNodeFailoverContext): AutoFailoverCandidate[] {
    const candidates: AutoFailoverCandidate[] = []
    for (const raw of context.group.proxies) {
      const item = raw as ProxyItem
      if (item.name === context.currentName || !this.isConcreteProxyItem(item)) continue
      const summary = this.getNodeQualityHistorySummary(context.profile, context.group.name, item.name)
      let score = autoFailoverHistoryScore(summary)
      const delayResult = this.delayMap.get(item.name)
      const delay = delayResult?.status === 'ok' ? delayResult.delay : 0
      // 没有持续测速历史时，只接纳本轮一键检测已经成功的节点作为低优先级候选。
      if (score <= 0 && delay > 0) score = Math.max(1, 35 - Math.min(30, Math.round(delay / 40)))
      if (score > 0) candidates.push({ item: item, score: score, delay: delay })
    }
    return candidates.sort((a: AutoFailoverCandidate, b: AutoFailoverCandidate): number =>
      b.score - a.score || (a.delay || Number.MAX_SAFE_INTEGER) - (b.delay || Number.MAX_SAFE_INTEGER))
      .slice(0, 5)
  }

  private async closeConnectionsFromNode(nodeName: string): Promise<number> {
    let closed = 0
    try {
      const connections = await this.socketProxy.queryConnections()
      for (const connection of connections) {
        if (!connection.chains.includes(nodeName)) continue
        try {
          await this.socketProxy.closeConnection(connection.id)
          closed++
        } catch (_) {
        }
      }
    } catch (_) {
    }
    return closed
  }

  /**
   * 当前节点连续三轮主备 204 检测失败才进入接管；候选节点还会现场复核一次。
   * 人工切换保护 2 分钟、自动切换冷却 5 分钟，避免弱网时来回振荡。
   */
  private async maybeCheckActiveNodeHealth(): Promise<void> {
    const appConfig = AppStorage.get<AppConfig>('appConfig') || cardManager.getAppConfig()
    if (appConfig?.autoFailoverEnabled === false) {
      this.nodeFailoverFailures = 0
      this.publishNodeFailoverState('disabled', '已关闭')
      return
    }
    if (this.nodeFailoverChecking || this.nodeQualityRunning ||
      AppStorage.get<boolean>('platformCheckRunning') === true ||
      AppStorage.get<boolean>('isCheckIpInfo') === true ||
      Date.now() - this.nodeFailoverLastProbeAt < 45000) return

    this.nodeFailoverChecking = true
    this.nodeFailoverLastProbeAt = Date.now()
    try {
      const context = await this.activeNodeFailoverContext()
      if (!context) {
        this.publishNodeFailoverState('idle', '当前代理组没有可监测的真实节点')
        return
      }
      const currentDelay = await this.testDelay(context.currentName)
      if (currentDelay > 0) {
        this.nodeFailoverFailures = 0
        this.publishNodeFailoverState('healthy', `${context.currentName} · 双源链路正常 ${currentDelay}ms`)
        return
      }

      this.nodeFailoverFailures++
      this.publishNodeFailoverState('warning',
        `${context.currentName} · 连续失败 ${this.nodeFailoverFailures}/3`)
      if (this.nodeFailoverFailures < 3) return
      if (Date.now() - this.nodeFailoverLastUserChangeAt < 2 * 60 * 1000) {
        this.publishNodeFailoverState('protected', `${context.currentName} · 人工选择保护期，暂不切换`)
        return
      }
      if (Date.now() - this.nodeFailoverLastSwitchAt < 5 * 60 * 1000) {
        this.publishNodeFailoverState('cooldown', `${context.currentName} · 自动切换冷却中`)
        return
      }

      const candidates = this.rankedAutoFailoverCandidates(context)
      if (candidates.length === 0) {
        this.publishNodeFailoverState('no_candidate', '当前节点异常，但没有经过历史验证的候选节点')
        return
      }
      for (const candidate of candidates) {
        this.publishNodeFailoverState('checking_candidate',
          `正在复核 ${candidate.item.name} · 历史评分 ${candidate.score}`)
        const candidateDelay = await this.testDelay(candidate.item.name)
        if (candidateDelay <= 0) continue
        const switched = await this.changeProxy(context.profile, context.group.name,
          candidate.item.name, 'auto')
        if (!switched) continue
        const oldName = context.currentName
        const currentConfig = AppStorage.get<AppConfig>('appConfig') || appConfig || new AppConfig()
        currentConfig.currentProxyName = candidate.item.name
        currentConfig.currentProxyItem = candidate.item
        AppStorage.setOrCreate('appConfig', currentConfig)
        AppStorage.set('appConfig', currentConfig)
        cardManager.setAppConfig(currentConfig)
        cardManager.setSelectedProxyNode(context.profile, context.group.name, candidate.item.name)
        cardManager.pushCartCurrentProxyName(candidate.item.name)
        const closed = await this.closeConnectionsFromNode(oldName)
        this.nodeFailoverLastSwitchAt = Date.now()
        this.nodeFailoverFailures = 0
        this.publishNodeFailoverState('switched',
          `${oldName} → ${candidate.item.name} · ${candidateDelay}ms · 已重建${closed}条旧连接`)
        EventHub.sendEvent(EventKey.FetchProxyGroup, null)
        try {
          ClashViewModel.promptAction.showToast({
            message: `节点故障，已自动切换到 ${candidate.item.name}`,
            duration: 4000
          })
        } catch (_) {
        }
        hilog.warn(0xA003, 'NodeAutoFailover',
          `自动切换 ${oldName} -> ${candidate.item.name}, delay=${candidateDelay}, closed=${closed}`)
        return
      }
      this.publishNodeFailoverState('failed', '当前节点及历史候选节点复核均失败，保持原节点')
    } catch (error) {
      this.publishNodeFailoverState('error', `健康检查异常：${(error as Error).message}`)
      hilog.warn(0xA003, 'NodeAutoFailover', `健康检查异常=${JSON.stringify(error)}`)
    } finally {
      this.nodeFailoverChecking = false
    }
  }

  /** UI 长时任务中的第二层保活：VPN 子进程或 TUN 丢失时自动完整重建。 */
  private startVpnWatchdog(): void {
    if (this.vpnWatchdogTimer !== -1) clearInterval(this.vpnWatchdogTimer)
    const generation = ++this.vpnWatchdogGeneration
    this.vpnWatchdogFailures = 0
    this.vpnWatchdogTimer = setInterval(async (): Promise<void> => {
      await this.checkVpnHealth(generation)
    }, 30000)
  }

  private stopVpnWatchdog(): void {
    this.vpnWatchdogGeneration++
    if (this.vpnWatchdogTimer !== -1) clearInterval(this.vpnWatchdogTimer)
    this.vpnWatchdogTimer = -1
    this.vpnWatchdogFailures = 0
  }

  private async checkVpnHealth(generation: number): Promise<void> {
    // setInterval does not await an async callback. A slow local-socket probe
    // must never overlap with the next probe or with a second recovery.
    if (!this.vpnExpectedRunning || this.vpnWatchdogRecovering ||
      this.vpnWatchdogProbeRunning || generation !== this.vpnWatchdogGeneration) return
    this.vpnWatchdogProbeRunning = true
    try {
      // A backgrounded UIAbility can briefly delay the local RPC response.
      // Bound only this health probe; the normal business RPC deadline stays
      // unchanged. Three serialized failures are required before rebuilding.
      if (await this.coreIsResponsive(true, 5000)) {
        this.vpnWatchdogFailures = 0
        this.lastVpnHealthAt = Date.now()
        hilog.info(0xA003, 'VpnWatchdog', 'VPN Extension 与 TUN 健康')
        await this.maybeCheckActiveNodeHealth()
        return
      }

      this.vpnWatchdogFailures++
      hilog.warn(0xA003, 'VpnWatchdog',
        `VPN 健康检查失败 count=${this.vpnWatchdogFailures}, generation=${generation}`)
      if (this.vpnWatchdogFailures < 3 || generation !== this.vpnWatchdogGeneration ||
        !this.vpnExpectedRunning || !cardManager.getVpnDesiredRunning()) return

      this.vpnWatchdogRecovering = true
      this.vpnStarted = false
      try {
        const recovered = await this.StartVpn(true)
        // 用户期望仍是开启状态；本轮失败时保留 watchdog，下一周期继续恢复。
        this.vpnExpectedRunning = true
        if (!recovered) this.startVpnWatchdog()
        hilog.info(0xA003, 'VpnWatchdog', `VPN 自动恢复结果=${recovered}`)
      } catch (error) {
        this.vpnExpectedRunning = true
        this.startVpnWatchdog()
        hilog.error(0xA003, 'VpnWatchdog', `VPN 自动恢复异常=${JSON.stringify(error)}`)
      } finally {
        this.vpnWatchdogRecovering = false
        this.vpnWatchdogFailures = 0
      }
    } finally {
      this.vpnWatchdogProbeRunning = false
    }
  }

  /** 最近一次启动链或 watchdog 已完成真实核心 RPC + TUN 运行时间验证。 */
  isVpnRuntimeHealthy(): boolean {
    return this.vpnStarted && this.vpnExpectedRunning && this.lastVpnHealthAt > 0 &&
      Date.now() - this.lastVpnHealthAt <= 65000
  }

  async getRuntime(){
    return await this.socketProxy.getRuntime()
  }
  // 校验是否配置成功
  async vpnConfigIsLoad(){
    const flag = await this.socketProxy.vpnConfigIsLoad()
    return flag
  }

  async initProfile(): Promise<boolean> {
    let appConfig = AppStorage.get<AppConfig>("appConfig") || cardManager.getAppConfig()
    EventHub.sendEvent(EventKey.StartLog, appConfig?.enableLogger)
    const loaded = await this.loadConfig(false, 'initProfile')
    if (loaded) {
      EventHub.sendEvent(EventKey.FetchProxyGroup)
      console.error("ClashViewModel.initProfile 初始化成功");
    } else {
      console.error("ClashViewModel.initProfile 配置尚未加载成功");
    }
    return loaded
  }

  proxyGroups :ProxyGroup[] = []

  private async verifyCoreProxySnapshot(mode: ProxyMode): Promise<void> {
    const groups = await this.socketProxy.queryProxyGroups(mode)
    const proxyCount = groups.reduce((total: number, group: ProxyGroup): number =>
      total + group.proxies.filter((item): boolean =>
        item.name !== 'DIRECT' && item.name !== 'REJECT').length, 0)
    if (groups.length === 0 || proxyCount === 0) {
      throw new Error('核心已响应，但代理组/节点快照为空')
    }
  }

  /**
   * 配置应用阶段的本地 RPC 断开通常是 Extension 重建、系统切后台或
   * LocalSocket 收尾顺序造成的瞬态故障。只对可恢复的传输层错误自动重试，
   * YAML 解析、节点为空等真实配置错误仍直接保留为待重载。
   */
  private isTransientCoreLoadFailure(reason: string): boolean {
    const normalized = reason.toLowerCase()
    return normalized.includes('rpc连接已关闭') ||
      normalized.includes('rpc connection closed') ||
      normalized.includes('connection reset') ||
      normalized.includes('broken pipe') ||
      normalized.includes('请求超时') ||
      normalized.includes('request timeout') ||
      normalized.includes('vpn服务未启动') ||
      normalized.includes('vpn service is not running')
  }

  async loadConfig(patch: boolean = true, name?: string): Promise<boolean> {
    const operation = this.configLoadQueue.then(async (): Promise<boolean> =>
      await this.loadConfigOnce(patch, name))
    this.configLoadQueue = operation.then((): void => {}, (): void => {})
    return await operation
  }

  private async loadConfigOnce(
    patch: boolean = true,
    name?: string,
    recoveryAttempt: number = 0
  ): Promise<boolean> {
    console.error(`ClashViewModel.loadConfig 调用方：${name} patch：${patch} 配置开始加载`)
    let appConfig = AppStorage.get<AppConfig>("appConfig") || cardManager.getAppConfig()
    let clashConfig = AppStorage.get<ClashConfig>("clashConfig") || cardManager.getClashConfig()
    const profile = await this.profileRepo.query(appConfig?.currentProfileId)
    if (!appConfig?.currentProfileId || !profile) {
      console.error(`ClashViewModel.loadConfig 调用方：${name} 未选择有效配置`)
      return false
    }
    profile.coreLoadState = 'loading'
    await this.profileRepo.addOrUpdate(profile)
    try {
      if (!await this.ensureCoreReady()) {
        throw new Error('核心未就绪')
      }
      profile.loadContext(this.context)
      profile.setCustomRuntimeRules(RuleTemplateService.enabledRules())
      // 运行时 DNS 绑定订阅规则的最终 selector，会自动跟随该组节点切换。
      if (!await profile.prepareRuntimeConfig()) {
        throw new Error('本地配置文件不存在，运行时配置生成失败')
      }
      await this.loadProfileAndConfig(appConfig?.currentProfileId ?? "", clashConfig, {
        "is-patch": patch,
        "is-compatible": true,
        "override-dns": clashConfig?.overrideDns,
        "selected-map": profile?.getSelectedMap()
      } as ConfigExtendedParams)
      // Do not commit the durable coreLoaded marker until the query side has
      // observed a real group/node snapshot. This blocks the historical state
      // where the configuration page showed many nodes while the core held a
      // single expiry placeholder (or no loaded nodes at all).
      await this.verifyCoreProxySnapshot(clashConfig?.mode ?? ProxyMode.Rule)
      if (clashConfig?.mode === ProxyMode.Global) {
        await this.ensureUsableGlobalProxy(profile)
        EventHub.sendEvent(EventKey.FetchProxyGroup, null)
      }
      console.log(`ClashViewModel.loadConfig 调用方：${name} patch：${patch} 配加载成功`)
      profile.markCoreLoaded()
      await this.profileRepo.addOrUpdate(profile)
      EventHub.sendEvent(EventKey.FetchProfile, null)
      // 冷启动先加载配置、随后才恢复 TUN。此时发起直连探测会正好撞上
      // VPN 路由切换，既必然失败，也会与客户端首个 HTTP/2 请求竞争。
      // 运行中的配置/规则切换仍需立即刷新；冷启动由 StartedClash 延迟刷新。
      if (this.vpnStarted) {
        EventHub.sendEvent(EventKey.checkIpInfo, { force: true })
      }
      return true
    } catch (e) {
      console.error('ClashViewModel.loadConfig 配置加载失败：', e)
      const failureReason = SubscriptionCompatibilityService.sanitizeReason(
        (e as Error)?.message ?? `${e}`)
      // A single RPC close must not immediately persist the red badge. First
      // verify/recover the local core, then retry the exact same runtime config
      // once under the existing configLoadQueue. The queue prevents this retry
      // from racing another page or startup load.
      if (recoveryAttempt === 0 && this.isTransientCoreLoadFailure(failureReason)) {
        hilog.warn(0xA003, 'CoreLoadRecovery',
          `配置加载遇到瞬态 RPC 故障，准备恢复并重试：${failureReason}`)
        this.socketProxy.active = false
        try {
          if (await this.ensureCoreReady()) {
            await sleep(250)
            return await this.loadConfigOnce(patch, name, recoveryAttempt + 1)
          }
          hilog.warn(0xA003, 'CoreLoadRecovery', '核心恢复检查未通过，不再重复重试')
        } catch (recoveryError) {
          hilog.warn(0xA003, 'CoreLoadRecovery',
            `核心恢复异常，不再重复重试：${JSON.stringify(recoveryError)}`)
        }
      }
      profile.markCoreLoadFailure(failureReason)
      await this.profileRepo.addOrUpdate(profile)
      EventHub.sendEvent(EventKey.FetchProfile, null)
      return false
    }
  }

  async initGeoIp(){
    let geoIp = await readFile(this.context?.resourceDir + "/geoip.metadb")
    let home = await getHome(this.context)
    writeFile(home+ "/geoip.metadb", geoIp)
    let geoip = await readFile(this.context?.resourceDir + "/GeoIP.dat")
    writeFile(home + "/GeoIP.dat", geoip)
    let geoSite = await readFile(this.context?.resourceDir + "/GeoSite.dat")
    writeFile(home + "/GeoSite.dat", geoSite)
    let Country = await readFile(this.context?.resourceDir + "/ASN.mmdb")
    writeFile(home + "/ASN.mmdb", Country)

  }
}
export async  function readFile(filePath: string): Promise<Uint8Array | null> {
  if(!await fs.access(filePath))
    return null;
  const file = await fs.open(filePath)
  const stats = await fs.stat(filePath)
  let bufSize = stats.size;
  let buf = new ArrayBuffer(bufSize);
  await fs.read(file.fd, buf, { offset: 0, length: bufSize });
  await fs.close(file);
  return new Uint8Array(buf);
}
export function writeFile(filePath: string, data: Uint8Array | null) {
  try {
    // 防止资源被覆盖
    if (fs.accessSync(filePath, fs.AccessModeType.EXIST))
      return;
    if(data != null && data.byteLength > 0){
      const file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE| fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, data.buffer);
      fs.fsyncSync(file.fd)
      fs.closeSync(file);
    }
  }catch (e) {
    hilog.error(0x0000, 'EntryAbility', '%{public}s', 'write ' + filePath + ' failure: ' + e.message + e.stack);
  }

}

export default new ClashViewModel()
