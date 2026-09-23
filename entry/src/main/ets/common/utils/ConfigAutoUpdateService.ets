import { common, Context, WantAgent, wantAgent } from "@kit.AbilityKit";
import { backgroundTaskManager } from "@kit.BackgroundTasksKit";
import { BusinessError } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import ClashViewModel, { AccountRefreshResult } from "../../entryability/ClashViewModel";
import { Profile, ProfileType } from "proxy_core";
import { convertMillisecondsToTimeGap, DEFAULT_TIMEOUT } from "../entity/Constants";
import { Xb_GetResourceString, Xb_NotificationUtils } from "xb_components";
import { notificationManager } from "@kit.NotificationKit";
import SubscriptionExpiryReminderService from './SubscriptionExpiryReminderService'

/** 默认订阅刷新周期。旧版曾使用 1 分钟，真机会产生大量无意义请求和通知。 */
const DEFAULT_PROFILE_UPDATE_INTERVAL: number = 6 * 60 * 60 * 1000
/** 冷启动和 TUN 恢复窗口优先留给用户前台流量。 */
const INITIAL_BACKGROUND_REFRESH_DELAY: number = 45 * 1000
/** 账号套餐/有效期不需要每分钟轮询；高频轮询会在 DNS 故障时形成请求风暴。 */
const ACCOUNT_REFRESH_INTERVAL: number = 30 * 60 * 1000
const ACCOUNT_FAILURE_BACKOFF_MIN: number = 5 * 60 * 1000
const ACCOUNT_FAILURE_BACKOFF_MAX: number = 60 * 60 * 1000
/** 即使持久化的 retryAt 已经过期，也不允许待修复任务形成秒级热循环。 */
const PENDING_RETRY_MIN_GAP: number = 60 * 1000

function notificationIdForProfile(profileId: string): number {
  let hash = 0
  for (let index = 0; index < profileId.length; index++) {
    hash = ((hash * 31) + profileId.charCodeAt(index)) & 0x7fffffff
  }
  return 10000 + (hash % 1000000)
}

/**
 * 配置自动更新服务
 * 负责定期检查并更新配置文件
 */
export class ConfigAutoUpdateService {
  private context: Context | null = null;
  /** 定时任务ID */
  private updateTimerId?: number = undefined;
  /** 冷启动后的首次 YAML 检查延迟执行，避免与配置/TUN 初始化争用网络。 */
  private initialUpdateTimerId?: number = undefined;
  /** 服务商账号资料使用单次定时器递归调度，以便失败后动态退避。 */
  private accountTimerId?: number = undefined;
  /** Wakes persisted subscription retries without shortening normal update intervals. */
  private retryTimerId?: number = undefined;
  /** 后台任务通知ID */
  private notificationId?: number = undefined;
  /** 是否正在更新 */
  private isUpdating: boolean = false;
  private isRefreshingAccount: boolean = false;
  private accountFailureBackoff: number = 0;
  private backgroundNetworkDeferredUntil: number = 0;
  /** 需要自动更新的配置 */
  private autoUpdateProfiles: Profile[] = [];

  initContext(context: Context): void {
    this.context = context;
    hilog.debug(0xFF00, "ConfigAutoUpdateService", "初始化配置自动更新服务");
  }

  /**
   * 启动配置自动更新服务
   * @param context 应用上下文
   */
  async start(): Promise<void> {
    if (this.updateTimerId !== undefined || this.initialUpdateTimerId !== undefined ||
      this.accountTimerId !== undefined) {
      hilog.debug(0xFF00, "ConfigAutoUpdateService", "配置自动更新服务已在运行");
      return;
    }

    hilog.warn(0xFF00, "ConfigAutoUpdateService", "启动配置自动更新服务");

    // 所有后台联网任务均在启动稳定窗口之后调度。start() 立即返回，不再把
    // 主窗口初始化卡在服务商接口、动态域名发现或订阅下载上。
    this.backgroundNetworkDeferredUntil = Date.now() + INITIAL_BACKGROUND_REFRESH_DELAY
    // 与 YAML 检查错开 15 秒，避免两个后台任务同时抢占 DNS/HTTP 连接。
    this.scheduleAccountRefresh(INITIAL_BACKGROUND_REFRESH_DELAY + 15 * 1000)
    this.initialUpdateTimerId = setTimeout(async (): Promise<void> => {
      this.initialUpdateTimerId = undefined
      try {
        await this.checkAndUpdateConfigs()
      } catch (_) {
        hilog.info(0xFF00, "ConfigAutoUpdateService", "当前没有到期的 YAML 自动更新任务")
      }
      this.scheduleConfigUpdateInterval()
    }, INITIAL_BACKGROUND_REFRESH_DELAY)

    hilog.warn(0xFF00, "ConfigAutoUpdateService", "配置自动更新服务启动成功");
  }

  /**
   * 停止配置自动更新服务
   * @param context 应用上下文
   */
  async stop(): Promise<void> {
    if (!this.context) {
      hilog.error(0xFF00, "ConfigAutoUpdateService", "关闭后台长时任务失败，请检查应用上下文");
      return Promise.reject("请检查应用上下文");
    }

    hilog.error(0xFF00, "ConfigAutoUpdateService", "停止配置自动更新服务");

    // 清除定时器
    if (this.updateTimerId !== undefined) {
      clearInterval(this.updateTimerId);
      this.updateTimerId = undefined;
    }
    if (this.initialUpdateTimerId !== undefined) {
      clearTimeout(this.initialUpdateTimerId)
      this.initialUpdateTimerId = undefined
    }
    if (this.accountTimerId !== undefined) {
      clearTimeout(this.accountTimerId)
      this.accountTimerId = undefined
    }
    if (this.retryTimerId !== undefined) {
      clearTimeout(this.retryTimerId)
      this.retryTimerId = undefined
    }
    this.accountFailureBackoff = 0
    this.backgroundNetworkDeferredUntil = 0

    // 停止后台任务
    // if (this.notificationId) {
    //   try {
    //     await backgroundTaskManager.stopBackgroundRunning(this.context, this.notificationId);
    //     this.notificationId = undefined;
    //     hilog.info(0xFF00, "ConfigAutoUpdateService", "后台任务停止成功");
    //   } catch (err) {
    //     hilog.error(0xFF00, "ConfigAutoUpdateService",
    //       `后台任务停止失败: ${JSON.stringify(err)}`);
    //   }
    // }

    hilog.info(0xFF00, "ConfigAutoUpdateService", "配置自动更新服务已停止");
  }

  /**
   * 重置配置自动更新服务
   */
  async reset() {
    if (this.updateTimerId === undefined && this.initialUpdateTimerId === undefined &&
      this.accountTimerId === undefined) {
      hilog.info(0xFF00, "ConfigAutoUpdateService", "配置自动更新服务已处于停止状态");
      // 没启动过 -> 执行一次检查是否需要开启自动更新
      try {
        await this.start();
      } catch (error) {
        hilog.error(0xFF00, 'ConfigAutoUpdateService',
          `配置自动更新服务启动失败 - ${JSON.stringify(error)}`);
      }
      return;
    }

    hilog.warn(0xFF00, "ConfigAutoUpdateService", "重置配置自动更新服务");

    try {
      await this.stop();
      await this.start();
    } catch (error) {
      hilog.error(0xFF00, 'ConfigAutoUpdateService',
        `配置自动更新服务启动失败 - ${JSON.stringify(error)}`);
    }
  }

  /**
   * 手动触发检查更新（用于应用切回前台时）
   */
  async checkNow(): Promise<void> {
    hilog.info(0xFF00, "ConfigAutoUpdateService", "手动触发配置更新检查");
    await this.checkAndUpdateConfigs();
  }

  async refreshAccountsNow(): Promise<AccountRefreshResult | null> {
    const remaining = this.backgroundNetworkDeferredUntil - Date.now()
    if (remaining > 0) {
      hilog.info(0xFF00, "AccountRefresh", `网络稳定等待期，账号资料刷新延后 ${remaining}ms`)
      return null
    }
    if (this.isRefreshingAccount) {
      hilog.info(0xFF00, "AccountRefresh", "上一轮账号资料刷新仍在进行，跳过重复任务")
      return null
    }
    this.isRefreshingAccount = true
    try {
      // 周期刷新只尝试每个账号最近成功的入口。域名迁移时由用户手动刷新或
      // 订阅更新链执行完整发现，后台任务不再扫描十余个候选域名。
      const result = await ClashViewModel.refreshAccountProfiles(null, true)
      if (result.total > 0) {
        hilog.info(0xFF00, "AccountRefresh",
          `账号资料刷新完成 total=${result.total}, success=${result.refreshed}, failed=${result.failed}`)
      }
      return result
    } finally {
      this.isRefreshingAccount = false
    }
  }

  /** 网络切换/前台恢复期间暂停后台 HTTP，防止抢占客户端的首个重连窗口。 */
  deferForNetworkChange(reason: string, delayMs: number = 60 * 1000): void {
    const nextAt = Date.now() + Math.max(1000, delayMs)
    if (nextAt > this.backgroundNetworkDeferredUntil) {
      this.backgroundNetworkDeferredUntil = nextAt
    }
    hilog.info(0xFF00, "AccountRefresh",
      `后台联网任务因网络代际变化延后 reason=${reason}, delay=${delayMs}ms`)
    if (this.accountTimerId !== undefined) {
      this.scheduleAccountRefresh(delayMs)
    }
    if (this.retryTimerId !== undefined) {
      clearTimeout(this.retryTimerId)
      this.retryTimerId = undefined
      this.schedulePendingRetryWakeup()
    }
  }

  private scheduleAccountRefresh(delayMs: number): void {
    if (this.accountTimerId !== undefined) clearTimeout(this.accountTimerId)
    const deferRemaining = Math.max(0, this.backgroundNetworkDeferredUntil - Date.now())
    const effectiveDelay = Math.max(1000, delayMs, deferRemaining)
    this.accountTimerId = setTimeout(async (): Promise<void> => {
      this.accountTimerId = undefined
      let nextDelay = ACCOUNT_REFRESH_INTERVAL
      try {
        const result = await this.refreshAccountsNow()
        if (result && result.failed > 0) {
          this.accountFailureBackoff = this.accountFailureBackoff === 0 ?
            ACCOUNT_FAILURE_BACKOFF_MIN :
            Math.min(this.accountFailureBackoff * 2, ACCOUNT_FAILURE_BACKOFF_MAX)
          nextDelay = this.accountFailureBackoff
          hilog.warn(0xFF00, "AccountRefresh",
            `后台账号刷新存在网络失败，下一轮全局退避 ${nextDelay}ms`)
        } else if (result) {
          this.accountFailureBackoff = 0
        }
      } catch (error) {
        this.accountFailureBackoff = this.accountFailureBackoff === 0 ?
          ACCOUNT_FAILURE_BACKOFF_MIN :
          Math.min(this.accountFailureBackoff * 2, ACCOUNT_FAILURE_BACKOFF_MAX)
        nextDelay = this.accountFailureBackoff
        hilog.warn(0xFF00, "AccountRefresh",
          `后台账号刷新异常，下一轮全局退避 ${nextDelay}ms, reason=${(error as Error).message}`)
      }
      this.scheduleAccountRefresh(nextDelay)
    }, effectiveDelay)
  }

  private scheduleConfigUpdateInterval(): void {
    if (this.updateTimerId !== undefined) clearInterval(this.updateTimerId)
    const updateIntervals = this.autoUpdateProfiles
      .map((profile: Profile): number => profile.autoUpdateDuration)
      .filter((duration: number): boolean => duration > 0)
    if (updateIntervals.length === 0) {
      this.updateTimerId = undefined
      return
    }
    const updateInterval = Math.min(...updateIntervals)
    this.updateTimerId = setInterval(async (): Promise<void> => {
      await this.checkAndUpdateConfigs()
    }, updateInterval)
  }

  /**
   * 检查并更新所有需要自动更新的配置
   */
  private async checkAndUpdateConfigs(): Promise<void> {
    // 防止重复执行
    if (this.isUpdating) {
      hilog.warn(0xFF00, "ConfigAutoUpdateService", "配置更新正在进行中，跳过本次检查");
      return;
    }

    this.isUpdating = true;

    try {
      hilog.warn(0xFF00, "ConfigAutoUpdateService", "开始检查配置更新");

      // 获取所有配置
      const profiles = await ClashViewModel.getProfiles();
      hilog.info(0xFF00, "ConfigAutoUpdateService", `获取到 ${profiles.length} 个配置`);
      if (this.context) {
        await SubscriptionExpiryReminderService.check(this.context, profiles)
      }

      // 筛选需要自动更新的配置
      this.autoUpdateProfiles = profiles.filter((profile: Profile) => {
        return profile.type === ProfileType.Url &&
          (profile.autoUpdate || profile.subscriptionPendingRepair);
      });

      // 先迁移旧版 1 分钟默认值，再判断本次是否到期，避免应用启动时立刻
      // 触发一次无意义的刷新。
      for (const profile of this.autoUpdateProfiles) {
        if (profile.autoUpdateDuration <= DEFAULT_TIMEOUT) {
          profile.autoUpdateDuration = DEFAULT_PROFILE_UPDATE_INTERVAL
          await ClashViewModel.updateProfile(profile)
        }
      }

      hilog.info(0xFF00, "ConfigAutoUpdateService",
        `需要自动更新的配置数量: ${this.autoUpdateProfiles.length}`);

      if (this.autoUpdateProfiles.length === 0) {
        return Promise.reject("没有需要自动更新的配置");
      }

      // 当前时间
      const now = Date.now();

      // 检查每个配置是否需要更新
      for (const profile of this.autoUpdateProfiles) {
        try {
          const updateInterval = profile.autoUpdateDuration
          // 忽略小于等于0的间隔
          if (updateInterval <= 0) {
            return
          }

          const lastUpdateTime = profile.lastUpdateDate || 0;
          const timeSinceLastUpdate = now - lastUpdateTime;

          // 格式化打印字符串
          let updateIntervalStr = `${updateInterval}毫秒`
          const timeGap = convertMillisecondsToTimeGap(updateInterval)
          switch (timeGap.unit) {
            case 0: // 分钟
              updateIntervalStr = `${timeGap.value}分钟`
              break;
            case 1: // 小时
              updateIntervalStr = `${timeGap.value}小时`
              break;
            case 2: // 天
              updateIntervalStr = `${timeGap.value}天`
              break;
          }

          // 更新间隔 => 允许5秒误差
          const tolerance = 5 * 1000;
          const updateThreshold = updateInterval - tolerance;

          hilog.info(0xFF00, "ConfigAutoUpdateService",
            `配置 [${profile.name}] - 上次更新: ${new Date(lastUpdateTime).toLocaleString()}, ` +
              `更新间隔: ${updateInterval} - ${updateIntervalStr}, 距离上次更新: ${Math.floor(timeSinceLastUpdate /
                1000 / 60)}分钟, ` +
              `允许误差: ${tolerance / 1000}秒`);

          const pendingRetryDue = profile.subscriptionPendingRepair &&
            profile.subscriptionRetryAt > 0 && now >= profile.subscriptionRetryAt
          // A persisted repair is retried even when the user disabled routine
          // refresh. Normal refreshes keep their existing user preference.
          if (pendingRetryDue || (!profile.isUpdating && timeSinceLastUpdate >= updateThreshold)) {
            hilog.info(0xFF00, "ConfigAutoUpdateService",
              `配置 [${profile.name}] 需要更新，开始更新...`);

            // 执行更新
            const updateResult = await ClashViewModel.updateProfileConfig(profile.id, false);
            if (updateResult.updated === 0 && updateResult.failed > 0) {
              throw new Error(`配置 ${profile.name} 更新失败，继续使用上次可用缓存`)
            }

            hilog.info(0xFF00, "ConfigAutoUpdateService",
              `配置 [${profile.name}] 更新完成`);
          } else {
            const remainingTime = Math.floor((updateInterval - timeSinceLastUpdate) / 1000 / 60);
            hilog.info(0xFF00, "ConfigAutoUpdateService",
              `配置 [${profile.name}] 无需更新，还需等待 ${remainingTime} 分钟`);
          }
        } catch (error) {
          hilog.error(0xFF00, "ConfigAutoUpdateService", error);

          // 推送通知消息 - 失败
          if (this.context) {
            await Xb_NotificationUtils.publishTextNotification(
              (this.context as common.UIAbilityContext),
                notificationIdForProfile(profile.id),
                {
                  title: "ClashBox",
                  text: error instanceof Error ? error.message : `${error}`
              },
              notificationManager.SlotType.SERVICE_INFORMATION,
              { abilityName: 'EntryAbility' }
            )
          }
        }
      }

      hilog.info(0xFF00, "ConfigAutoUpdateService", "配置更新检查完成");
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0xFF00, "ConfigAutoUpdateService",
        `配置更新检查失败: ${err.message}`);
      return Promise.reject(err.message);
    } finally {
      this.isUpdating = false;
      this.schedulePendingRetryWakeup()
    }
  }

  private schedulePendingRetryWakeup(): void {
    if (!this.context || this.retryTimerId !== undefined) return
    ClashViewModel.getProfiles().then((profiles: Profile[]) => {
      const now = Date.now()
      const due = profiles
        .filter((profile: Profile): boolean => profile.subscriptionPendingRepair &&
          profile.subscriptionRetryAt > 0)
        .map((profile: Profile): number => profile.subscriptionRetryAt - now)
      if (due.length === 0) return
      const deferRemaining = Math.max(0, this.backgroundNetworkDeferredUntil - Date.now())
      // A due/past-due record is retried at most once per minute. Normal future
      // retry timestamps retain their longer exponential-backoff delay.
      const delay = Math.max(PENDING_RETRY_MIN_GAP, Math.min(...due), deferRemaining)
      this.retryTimerId = setTimeout(async () => {
        this.retryTimerId = undefined
        await this.checkAndUpdateConfigs()
      }, delay)
    }).catch((error: Error) => {
      hilog.debug(0xFF00, 'ConfigAutoUpdateService', `待重试任务调度失败：${error.message}`)
    })
  }

  /**
   *  启动后台长时任务
   * @param context 应用上下文
   * @returns 通知ID
   */
  private async startContinuousTask(): Promise<number> {
    if (!this.context) {
      hilog.error(0xFF00, "ConfigAutoUpdateService", "启动后台长时任务失败，请检查应用上下文");
      return -1;
    }

    const context = this.context;

    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.applicationInfo.name,
          abilityName: "EntryAbility",
        },
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };

    try {
      const wantAgentObj: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      const result = await backgroundTaskManager.startBackgroundRunning(
        context,
        ["dataTransfer"], // 使用数据传输类型
        wantAgentObj
      );
      hilog.info(0xFF00, "ConfigAutoUpdateService",
        `后台长时任务启动成功, notificationId=${result.notificationId}`);
      return result.notificationId;
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0xFF00, "ConfigAutoUpdateService",
        `后台长时任务启动失败: Code=${error.code}, Msg=${error.message}`);
      return -1;
    }
  }
}

export default new ConfigAutoUpdateService();
