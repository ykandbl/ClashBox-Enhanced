import { AbilityConstant, ConfigurationConstant, UIAbility, Want, Configuration, common } from '@kit.AbilityKit';
import { hiAppEvent, hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import ClashViewModel from './ClashViewModel';
import { AppConfig, AppState, ClashCore } from './AppState';
import { EventHub, EventKey } from '../common/EventHub';
import { PipManager } from '../common/utils/PipManager';
import { ClashConfig, SocketStubService } from 'proxy_core';
import { deviceInfo } from '@kit.BasicServicesKit';
import { url } from '@kit.ArkTS';
import { cardManager } from '../common/utils/CardManageUtil';
import { rpc } from '@kit.IPCKit';
import { ProxyActionType } from '../widget/model/FormCardConstant';
import { systemShare } from '@kit.ShareKit';
import { distributedKVStore, uniformTypeDescriptor as utd } from '@kit.ArkData';
import { UrlUtils } from '../common/utils/UrlUtils';
import { BundleInfo, PROXY_STARTED_DURATION_INIT_VALUE } from '../common/entity/Constants'
import { commonEventManager } from '@kit.BasicServicesKit';
import { Timer } from '../common/utils/HHmmssTimer';
import { number2Time } from '../common/utils/TimeConvertUtil';
import { customVibrator } from '../common/utils/VibratorUtil';
import { StatusBarConfig, StatusBarIconResource,
  SmartAvoidance,
  Xb_AvoidanceManager,
  Xb_ColorUtils,
  Xb_Global, Xb_KVdbUtil, Xb_SecureKVdbUtil,
  Xb_StatusBarUtils,
  Xb_ToastUtil,
  Xb_PreferenceUtil} from 'xb_components';
import BackupRestoreUtil from '../common/utils/BackupRestoreUtil';
import ConfigAutoUpdateService from '../common/utils/ConfigAutoUpdateService';
import BackgroundDownService from '../common/utils/BackgroundDownService';
import BuildProfile from 'BuildProfile';
import { accessControlRdb } from '../common/datasources/AccessControlRdb';
import { connection } from '@kit.NetworkKit';
import { RuleTemplateService } from '../common/utils/RuleTemplateService'


export default class EntryAbility extends UIAbility {
  private want?: Want
  private windowMode: boolean = false
  private isFirstStart: boolean = true
  // 设备断点获取
  private uiContext?: UIContext;
  private debugVpn: SocketStubService | null = null
  private onWindowSizeChange: (windowSize: window.Size) => void = (windowSize: window.Size) => {
    let widthBp: WidthBreakpoint = this.uiContext!.getWindowWidthBreakpoint();
    AppStorage.setOrCreate('currentWidthBreakpoint', widthBp);
    Xb_Global.WidthBp = widthBp
    console.log(`断点测试 widthBp: ${widthBp}`)
  };
  /** @description ClashCore是否初始化过 */
  private clashCoreInitialized: boolean = false
  /** @description ClashCore是否初始化过 */
  private cardCoreInitialized: boolean = false
  /** @description 包名信息 */
  private bundleInfo: BundleInfo = new BundleInfo()
  /** @description 卡片延迟定时器 */
  private cardDelayTimer: number = -1
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private windowLimits: window.WindowLimits = {
    minWidth: 1345,
    minHeight: 498,
    maxWidth: 5200,
    maxHeight: 1080
  }
  private subscribeInfo: commonEventManager.CommonEventSubscribeInfo = {
    events: ["VpnServiceTimeEvent"]
  };
  private proxyStartedTimer = new Timer()
  private avoidManager: Xb_AvoidanceManager | undefined = undefined;
  private networkConnection: connection.NetConnection | null = null
  private networkPollTimer: number = -1
  private networkListenerRetryTimer: number = -1
  private coreInitInProgress: boolean = false
  private coreInitRetryTimer: number = -1
  private coreConfigRetryTimer: number = -1
  private coreConfigRetryDelayMs: number = 2500
  private coreHealthTimer: number = -1
  private coreHealthFailures: number = 0
  private coreHealthRecoveryInProgress: boolean = false
  private readonly onNetworkEnvironmentChanged = (): void => {
    // ClashViewModel owns the network-generation token, recovery debounce and
    // the VPN lifecycle queue. Do not start an IP/platform probe here: a
    // netAvailable/property burst can arrive while the old route is still
    // being torn down, and that probe competes with the first real client
    // request after a Wi-Fi/cellular handoff.
    hilog.info(0xA003, 'NetworkRecovery', '系统网络变化回调已进入')
    ConfigAutoUpdateService.deferForNetworkChange('network callback')
    ClashViewModel.scheduleNetworkGenerationRecovery('network callback')
  }
  private avoidListener: (avoidance: SmartAvoidance) => void = (newAvoidance) => {
    AppStorage.setOrCreate('bottomRectHeight', newAvoidance.bottom);
    Xb_Global.BottomRectHeight = newAvoidance.bottom
    AppStorage.setOrCreate('topRectHeight', newAvoidance.top);
    Xb_Global.TopRectHeight = newAvoidance.top
    AppStorage.setOrCreate('LeftAvoidWidth', newAvoidance.left);
    AppStorage.setOrCreate('RightAvoidWidth', newAvoidance.right);
  }

  // 冷启动
  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    hilog.info(0x0000, 'EntryAbility', '%{public}s', 'Ability onCreate');
    // 根页面会先于配置 RDB 完成构建。明确重置就绪状态，避免冷启动期间把
    // “尚未读取”误渲染成“没有配置”。ProfileRepo.init 完成后再由
    // ClashViewModel 发布 true，配置列表无需等待核心和 VPN 恢复链。
    AppStorage.setOrCreate('profileRepoReady', false)
    AppStorage.set('profileRepoReady', false)
    // 赋值临时储存want
    this.want = want
    // ChangeCore 需要用 Context 构造当前应用的 bundleName/filesDir。
    // 冷启动时先绑定 Context，避免系统把空 bundleName 判为其他 VPN 应用。
    ClashViewModel.context = this.context
    // 网络监听不能依赖核心初始化完成。初始化失败或切网发生在冷启动窗口
    // 时，仍要让 VPN/ChatGPT 连接恢复链收到网络变化。
    this.registerNetworkChangeListener()
    // 此处只绑定 Context，不提前启动 VPN Extension。窗口内容加载后会先完成
    // SocketProxyService 初始化，再由 ClashCoreInit 做一次幂等的就绪检查。
    // 旧流程在这里启动一次、ClashCoreInit 随后又 stop/start 一次，两个实例的
    // onDestroy 与握手锁会交叉，是冷启动偶发“VpnAbility 请求失败”的根因。
    // 卡片Id持久化管理 并 监听卡片事件
    cardManager.init(this.context)
    RuleTemplateService.init(this.context)
    this.registerCardEvent()
    // 初始化KV数据库
    await Xb_KVdbUtil.initKVManager(this.context, 'clash_box')
    const credentialStoreOptions: distributedKVStore.Options = {
      createIfMissing: true,
      encrypt: true,
      backup: false,
      autoSync: false,
      kvStoreType: distributedKVStore.KVStoreType.SINGLE_VERSION,
      securityLevel: distributedKVStore.SecurityLevel.S3
    }
    await Xb_SecureKVdbUtil.initKVManager(this.context, 'bitznet_credentials', credentialStoreOptions)
    // 备份恢复工具初始化
    BackupRestoreUtil.init(this.context)
    Xb_ColorUtils.init(this.context)
    // 初始化首选项
    try {
      await Xb_PreferenceUtil.init(this.context, 'clash_box_preference');
      hilog.info(0x0000, 'EntryAbility', 'Xb_PreferenceUtil initialized successfully.');
    } catch (error) {
      hilog.error(0x0000, 'EntryAbility', 'Xb_PreferenceUtil initialization failed.');
    }
    // 初始化访问控制数据库；必须等待表结构就绪，页面和 VPN 启动链才可安全读写。
    try {
      await accessControlRdb.init(this.context)
      hilog.info(0x0000, 'EntryAbility', 'AccessControlRdb initialized successfully.')
    } catch (error) {
      hilog.error(0x0000, 'EntryAbility', `AccessControlRdb initialization failed: ${JSON.stringify(error)}`)
    }
    // 添加崩溃监听
    try {
      hiAppEvent.addWatcher({
        name: "watcher",
        // 订阅崩溃事件
        appEventFilters: [
          {
            domain: hiAppEvent.domain.OS,
            names: [hiAppEvent.event.APP_CRASH]
          }
        ],
        onReceive: (domain: string, appEventGroups: Array<hiAppEvent.AppEventGroup>) => {
          AppStorage.setOrCreate('crash', true)
          AppStorage.setOrCreate('crashEvent', appEventGroups)
        }
      })
    } catch (error) {
      console.error(`崩溃事件监听注册失败，message：${error.message}`)
    }
    // 当前主题模式
    AppStorage.setOrCreate<ConfigurationConstant.ColorMode>('currentColorMode', this.context.config.colorMode)

    // 从want中获取传入的链接信息
    this.getSharedConfigUrl(want)

    // 订阅ClashVpnAbility中的事件 -> 将运行时间同步显示在 卡片
    commonEventManager.createSubscriber(this.subscribeInfo,
      (err: BusinessError, commonEventSubscriber: commonEventManager.CommonEventSubscriber) => {
        if (!err) {
          console.info(`Succeeded in creating subscriber.`);
          this.subscriber = commonEventSubscriber;
          try {
            commonEventManager.subscribe(this.subscriber,
              (err: BusinessError, data: commonEventManager.CommonEventData) => {
                if (err) {
                  console.error(`Failed to subscribe. Code is ${err.code}, message is ${err.message}`);
                } else {
                  console.info(`Succeeded in subscribing, data is ` + JSON.stringify(data));
                  if (data.code === 0) {
                    // 计算时间
                    const vpnServiceStartTime = Number(data.data)
                    // 启动前先初始化卡片显示文本
                    cardManager.pushCartVpnServiceTime(PROXY_STARTED_DURATION_INIT_VALUE)
                    this.proxyStartedTimer.start((time) => {
                      EventHub.sendEvent(EventKey.ProxyDuration, time)
                      cardManager.pushCartVpnServiceTime(number2Time(time))
                    }, vpnServiceStartTime)

                    EventHub.on(EventKey.StopedClashEntry, () => {
                      hilog.info(0x001, "EntryAbility", "StopedClashEntry")
                      this.proxyStartedTimer.reset()
                    })
                  }
                }
              });
          } catch (error) {
            let err: BusinessError = error as BusinessError;
            console.error(`Failed to subscribe. Code is ${err.code}, message is ${err.message}`);
          }
        } else {
          console.error(`Failed to create subscriber. Code is ${err.code}, message is ${err.message}`);
        }
      });

  }

  // 实时监听系统系统配置更新状态
  onConfigurationUpdate(Config: Configuration): void {
  }

  // 热启动
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam) {
    this.getShareData(want, true);

    // 从want中获取传入的链接信息
    this.getSharedConfigUrl(want);
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    // Main window is created, set main page for this ability
    hilog.info(0x0000, 'EntryAbility', '%{public}s', 'Ability onWindowStageCreate');

    // 判断API版本是否满足要求
    const APIVersion = deviceInfo.sdkApiVersion
    console.log(`APIversion 当前系统API版本：${APIVersion}`)
    if (APIVersion >= 20) {
      AppStorage.setOrCreate('EnableAPIVersion', true)
    } else {
      AppStorage.setOrCreate('EnableAPIVersion', false)
    }

    // 设置自动记忆最后关闭的窗口大小(仅2in1设备生效)
    try {
      await windowStage.setWindowRectAutoSave(true);
      hilog.info(0xFF00, "EntryAbility", 'Succeeded in setting window rect auto-save')
    } catch (exception) {
      hilog.error(0xFF00, "EntryAbility", 'Failed to set window rect auto-save. Cause code: %{public}s smessage: %{public}s', exception.code, exception.message)
    }

    const storage = new LocalStorage()
    storage.setOrCreate<BundleInfo>('bundleInfo', this.bundleInfo)

    windowStage.getMainWindow((err, mainWindow) => {
      if (err) return;
      try {
        const mainWindowId = mainWindow.getWindowProperties().id;
        AppStorage.setOrCreate('MainWindowId', mainWindowId) // 主窗口ID
      } catch (error) {
        console.error(`主窗口ID获取失败, name: ${error.name} message: ${error.message}`)
      }
    })

    windowStage.loadContent('pages/Index', storage, async (err) => {
      if (err.code) {
        hilog.error(0x0000, 'EntryAbility', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      // 初始化应用配置
      await AppState.init()

      // 推荐在 DEBUG 模式下使用 - 动态加载
      if (BuildProfile.DEBUG) {
        import('@cxy/sandboxfinder').then(async (ns: ESObject) => {
          // 默认绑定到端口 7777
          ns.SandboxFinder.run(1145)
        });

        // 避免服务挂起，设置不息屏
        windowStage.getMainWindowSync().setWindowKeepScreenOn(true)
      }

      try {
        const data = await windowStage.getMainWindow()
        // 确保UI上下文被赋值
        this.uiContext = data.getUIContext()
        // 设置窗口背景色为透明
        try {
          data.setWindowBackgroundColor('#00000000');
        } catch (exception) {
          console.error(`WindowBackgroundColor  Failed to set the background color. Cause code: ${exception.code}, message: ${exception.message}`);
        };
        if (APIVersion >= 20) {
          try {
            data.setWindowContainerColor('#00000000', '#FFF1F3F5')
          } catch (exception) {
            console.error(`WindowBackgroundColor  Failed to set the container color. code: ${exception.code}, message: ${exception.message}`);
          };
        }
        // 初始化通知工具
        Xb_ToastUtil.initContext(this.uiContext, data.getUIContext().getHostContext() as common.UIAbilityContext)
        // 初始化窗口避让属性
        this.intRectWindow(windowStage)
        // 初始化配置自动更新服务
        ConfigAutoUpdateService.initContext(this.context)

        // NavPathStack 自身带有 Navigation 状态通知。只在入口创建共享实例，
        // 页面通过普通字段读取，避免再套一层 @Provide/@Consume 响应式代理；
        // 双重观察会在 Navigation 初次绑定时产生 changed during render。
        AppStorage.setOrCreate('NavPathStack', new NavPathStack())
        AppStorage.setOrCreate('MoreNavPathStack', new NavPathStack())
        AppStorage.setOrCreate('OnlineSearchPageInfos', new NavPathStack())

        // 设备断点获取
        let widthBp: WidthBreakpoint = this.uiContext.getWindowWidthBreakpoint()
        AppStorage.setOrCreate('currentWidthBreakpoint', widthBp)
        Xb_Global.WidthBp = widthBp
        data.on('windowSizeChange', this.onWindowSizeChange)

        // 卡片初始化过就无须再次初始化
        if (!this.clashCoreInitialized) {
          await ClashViewModel.init(this.context, this.uiContext.getPromptAction()!)
        }

        // 卡片初始化过就无须再次初始化
        if (!this.clashCoreInitialized) {
          await this.ClashCoreInit();
        }
        // onCreate 已经注册过；这里保留幂等调用，覆盖系统重建窗口对象但复用
        // Ability 实例的情况。
        this.registerNetworkChangeListener()

        // 卡片初始化过打开应用获取一次代理节点
        if (this.cardCoreInitialized) {
          ClashViewModel.loadConfig(true, '卡片初始化过打开应用获取一次代理节点')
        }

        // 获取分享的包名信息(初始)
        await this.getShareData(this.want!);

        // 通过主窗口UIContext创建typeNode节点
        PipManager.getInstance().makeTypeNode(this.uiContext)

      } catch (err) {
        console.error(`Failed to obtain the main window. Cause code: ${err.code}, message: ${err.message}`);
      }

      // 执行首次窗口检测
      // this.onWindowModeChange(windowStage, windowClass)

      // 初始化完成标记
      AppStorage.setOrCreate('awaitInit', true)
    });

    let deviceTypeInfo: string = deviceInfo.deviceType;
    if (deviceTypeInfo === '2in1') {
      AppStorage.setOrCreate('2in1', true)
    } else {
      AppStorage.setOrCreate('2in1', false)
    }

  }

  onWindowStageWillDestroy(windowStage: window.WindowStage): void {
    // Main window will destroy, release UI related resources
    // 销毁避让管理器并移除监听
    if (this.avoidManager) {
      this.avoidManager.offChangeListener(this.avoidListener);
      this.avoidManager.destroy();
      this.avoidManager = undefined;
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(0x0000, 'EntryAbility', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    AppStorage.setOrCreate('ForwardState', true)
    hilog.info(0x0000, 'EntryAbility', '%{public}s', 'Ability onForeground');

    this.startNetworkFallbackPoll()
    ConfigAutoUpdateService.deferForNetworkChange('foreground validation')
    ClashViewModel.pollDefaultNetworkGeneration('foreground').catch((error: Error) => {
      hilog.debug(0xA003, 'NetworkRecovery', `前台网络快照读取失败：${error.message}`)
    })

    if (!this.clashCoreInitialized && !this.coreInitInProgress) {
      this.ClashCoreInit().catch((error: Error) => {
        hilog.warn(0xA003, 'VpnLifecycle', `前台补偿初始化失败：${error.message}`)
        this.scheduleCoreInitRetry()
      })
    } else if (this.clashCoreInitialized) {
      this.scheduleCoreConfigRetry(200)
    }

    if (ClashViewModel.vpnStarted) {
      BackgroundDownService.ensureContinuousTask().catch((error: BusinessError) => {
        hilog.warn(0xFF00, 'BackgroundDownService',
          `前台复核长时任务失败: ${error.message}`);
      });
    } else if (this.clashCoreInitialized && cardManager.getVpnDesiredRunning()) {
      ClashViewModel.restoreDesiredVpnState().catch((error: Error) => {
        hilog.warn(0xFF00, 'ClashViewModel', `前台恢复 VPN 失败: ${error.message}`)
      })
    }

    // Telegram 等即时通讯应用可能在后台保留已经失效的长连接。等待窗口
    // 和 VPN 恢复链稳定后，仅清理切后台前已存在且无字节变化的半连接，
    // 让应用在前台重新握手；活跃下载和视频连接不会被打断。
    ClashViewModel.scheduleForegroundConnectionRecovery()

    // 应用切回前台时，触发一次配置更新检查
    // this.checkConfigAutoUpdate();
  }

  /** @description 检查配置自动更新（应用切回前台时调用） */
  private checkConfigAutoUpdate(): void {
    // 只有在核心已初始化的情况下才执行检查
    if (this.clashCoreInitialized) {
      ConfigAutoUpdateService.checkNow().then(() => {
        hilog.info(0xFF00, 'ConfigAutoUpdateService', '前台配置更新检查完成');
      }).catch((error: BusinessError) => {
        hilog.error(0xFF00, 'ConfigAutoUpdateService',
          `前台配置更新检查失败: ${error.message}`);
      });
    }
  }

  onBackground(): void {
    // Ability has back to background
    AppStorage.setOrCreate('ForwardState', false)
    hilog.info(0x0000, 'EntryAbility', '%{public}s', 'Ability onBackground');
    ClashViewModel.markAppBackground()
    // BackgroundDownService is owned by ClashViewModel.markVpnStarted().
    // Keeping a second start entry here races with the first system RPC when
    // the VPN is enabled immediately before the app leaves the foreground.
    this.saveConfigThePreferences();
    Xb_PreferenceUtil.save().then(() => {
      hilog.debug(0xC020, 'EntryAbility',
        `#onBackground ConfigSort Xb_PreferenceUtil 首选项保存成功`)
    }).catch((err: BusinessError) => {
      hilog.error(0xC020, 'EntryAbility',
        `#onBackground ConfigSort Xb_PreferenceUtil 首选项保存失败，message：${err.message}`)
    })
  }

  onDestroy(): void {
    hilog.info(0x0000, 'EntryAbility', '%{public}s', 'Ability onDestroy');
    ClashViewModel.cancelNetworkGenerationRecovery()
    this.saveConfigThePreferences()
    // 移除卡片监听事件
    this.unRegisterCardEvent()
    cardManager.pushCartProxyMode(cardManager.getVpnDesiredRunning())
    // 停止配置自动更新服务
    this.stopConfigAutoUpdateService()
    this.unregisterNetworkChangeListener()
    if (this.networkPollTimer !== -1) clearInterval(this.networkPollTimer)
    this.networkPollTimer = -1
    if (this.networkListenerRetryTimer !== -1) clearTimeout(this.networkListenerRetryTimer)
    this.networkListenerRetryTimer = -1
    if (this.coreInitRetryTimer !== -1) clearTimeout(this.coreInitRetryTimer)
    this.coreInitRetryTimer = -1
    if (this.coreConfigRetryTimer !== -1) clearTimeout(this.coreConfigRetryTimer)
    this.coreConfigRetryTimer = -1
    if (this.coreHealthTimer !== -1) clearInterval(this.coreHealthTimer)
    this.coreHealthTimer = -1
  }

  private registerNetworkChangeListener(): void {
    if (this.networkConnection) return
    try {
      const listener = connection.createNetConnection()
      listener.on('netAvailable', this.onNetworkEnvironmentChanged)
      listener.on('netCapabilitiesChange', this.onNetworkEnvironmentChanged)
      listener.on('netConnectionPropertiesChange', this.onNetworkEnvironmentChanged)
      listener.on('netLost', this.onNetworkEnvironmentChanged)
      listener.on('netUnavailable', this.onNetworkEnvironmentChanged)
      listener.on('netBlockStatusChange', this.onNetworkEnvironmentChanged)
      this.networkConnection = listener
      listener.register((error: BusinessError) => {
        if (error) {
          hilog.warn(0xA003, 'NetworkRecovery',
            `网络变化监听注册失败: ${error.code} ${error.message}`)
          this.networkConnection = null
          this.scheduleNetworkListenerRetry()
        } else {
          hilog.info(0xA003, 'NetworkRecovery', '系统网络变化监听注册成功')
        }
      })
      this.startNetworkFallbackPoll()
    } catch (error) {
      const reason = error as BusinessError
      hilog.warn(0xA003, 'NetworkRecovery',
        `网络变化监听初始化失败: ${reason.code} ${reason.message}`)
      this.networkConnection = null
      this.scheduleNetworkListenerRetry()
    }
  }

  /**
   * Some HarmonyOS builds register NetConnection successfully but omit a
   * default-network callback during Wi-Fi/cellular handoff. The poll only
   * reads NetworkKit state; the expensive RPC/TUN recovery still runs only
   * after ClashViewModel detects that the physical network key changed.
   */
  private startNetworkFallbackPoll(): void {
    if (this.networkPollTimer !== -1) return
    this.networkPollTimer = setInterval(() => {
      ClashViewModel.pollDefaultNetworkGeneration('fallback poll').catch((error: Error) => {
        hilog.debug(0xA003, 'NetworkRecovery', `网络轮询失败：${error.message}`)
      })
    }, 10000)
  }

  private scheduleNetworkListenerRetry(): void {
    if (this.networkListenerRetryTimer !== -1) return
    this.networkListenerRetryTimer = setTimeout(() => {
      this.networkListenerRetryTimer = -1
      this.registerNetworkChangeListener()
    }, 3000)
  }

  private unregisterNetworkChangeListener(): void {
    const listener = this.networkConnection
    this.networkConnection = null
    if (!listener) return
    try {
      listener.unregister((error: BusinessError) => {
        if (error) hilog.warn(0xC031, 'IPPure', `网络变化监听注销失败: ${error.message}`)
      })
    } catch (_) {
    }
  }

  /** @description 停止配置自动更新服务 */
  private stopConfigAutoUpdateService(): void {
    ConfigAutoUpdateService.stop().then(() => {
      hilog.info(0xFF00, 'ConfigAutoUpdateService', '配置自动更新服务已停止');
    }).catch((error: BusinessError) => {
      hilog.error(0xFF00, 'ConfigAutoUpdateService',
        `配置自动更新服务停止失败: ${error.message}`);
    });
  }

  /** @description 获取分享的配置URL */
  private getSharedConfigUrl(want: Want) {
    const uri = want?.uri;
    if (uri) {
      try {
        const urlObject = url.URL.parseURL(want?.uri);
        hilog.info(0x0000, 'EntryAbility', 'AppLink - 已解析导入参数');
        let configUrl = urlObject.params.get('configUrl') || urlObject.params.get('url');
        const configName = urlObject.params.get('configName');

        // flag参数 -> 一般是 clash、shadowrocket 等，机场用于区分软件的
        const flag = urlObject.params.get('flag');
        if (flag) configUrl += `&flag=${flag}`;

        // 处理分享的配置链接
        AppStorage.setOrCreate('appLinkConfigUrl', configUrl);
        AppStorage.setOrCreate('appLinkConfigName', configName);
        hilog.info(0x0000, 'EntryAbility', 'AppLink - 已接收配置链接，长度：%{public}d', configUrl?.length ?? 0);
      } catch (error) {
        hilog.error(0x0000, 'EntryAbility', 'AppLink - 接收分享信息失败，message为：%{public}s', error.message);
      }

    }
  }

  /** @description 存储配置文件到首选项 */
  private saveConfigThePreferences() {
    const appConfig = AppStorage.get<AppConfig>("appConfig");
    const clashConfig = AppStorage.get<ClashConfig>("clashConfig");
    appConfig && cardManager.setAppConfig(appConfig);
    clashConfig && cardManager.setClashConfig(clashConfig);
  }

  /** @description 注册卡片监听事件 */
  private registerCardEvent() {
    try { // 卡片持久化ID
      this.callee.on('updateFormId', (indata: rpc.MessageSequence) => {
        // 获取formId
        const obj = JSON.parse(indata.readString()) as object
        const formId = obj['formId'] as string
        // 持久化卡片Id
        cardManager.addCardId(formId)
        // 触发卡片更新事件
        return new Params()
      })

      // 卡片切换代理
      this.callee.on('cardChangeProxy', (indata: rpc.MessageSequence) => {
        // TODO 卡片开启服务后打开UI会显示 is not callable
        // TODO 后台卡片不走流
        cardManager.pushCartLoading(true)
        hilog.info(0x0000, 'EntryAbility', 'cardChangeProxy');
        const obj = JSON.parse(indata.readString()) as object
        const proxyActionType = obj['proxyActionType'] as ProxyActionType

        this.CardClashCoreEvent(proxyActionType)

        return null
      })

      // 刷新节点状态
      this.callee.on('refreshState', (indata: rpc.MessageSequence) => {
        clearTimeout(this.cardDelayTimer)

        const proxyNodeInfo = cardManager.getSelectedProxyNode()
        this.refreshState(proxyNodeInfo?.p ?? '')

        return new Params()
      })
    } catch (e) {
      hilog.error(0x0000, 'EntryAbility', 'Failed to register card event. Cause: %{public}s', JSON.stringify(e) ?? '');
    }
  }

  /** @description 取消注册卡片监听事件 */
  private unRegisterCardEvent() {
    try {
      this.callee.off('updateFormId')
      this.callee.off('cardChangeProxy')
      this.callee.off('refreshState')
    } catch (e) {
      hilog.error(0x0000, 'EntryAbility', 'Failed to unregister card event. Cause: %{public}s', JSON.stringify(e) ?? '');
    }
  }

  /** @description 初始化Clash核心 */
  private async ClashCoreInit() {
    if (this.clashCoreInitialized) return true
    if (this.coreInitInProgress) return false
    this.coreInitInProgress = true
    try {
    const clashCore = (AppStorage.get<AppConfig>("appConfig") || cardManager.getAppConfig())?.clashCore
    const coreReady = await ClashViewModel.ensureCoreReady()
    if (!coreReady) {
      hilog.error(0xA003, 'ClashViewModel', `冷启动核心自恢复未完成，core=${clashCore}`)
      this.scheduleCoreInitRetry()
      return false
    }
    if (clashCore != ClashCore.mihomo) {
      this.debugVpn = new SocketStubService(this.context)
      await this.debugVpn.startService()
    }
    const configLoaded = await ClashViewModel.initProfile();
    if (!configLoaded) {
      hilog.warn(0xA003, 'ClashViewModel', '核心已就绪但启动配置加载失败，进入后台重试')
      this.scheduleCoreConfigRetry()
    } else {
      this.coreConfigRetryDelayMs = 2500
    }
    EventHub.on(EventKey.LoadClashConfig, (isPatch: boolean) => {
      ClashViewModel.loadConfig(isPatch, 'ClashCoreInit-EventKey.LoadClashConfig');
    });
    this.startCoreHealthMonitor()
    hilog.info(0x0000, 'EntryAbility', 'Succeeded in loading the content.');

    this.clashCoreInitialized = true

    // UI 进程被系统重建时，按用户最后一次成功启动状态自动恢复 TUN。
    try {
      await ClashViewModel.restoreDesiredVpnState()
    } catch (error) {
      // 核心/RPC 已初始化完成。VPN 恢复是下一阶段，失败时由恢复器继续，
      // 不得把整个 ClashCoreInit 标回失败或阻断节点页面交互。
      hilog.warn(0xA003, 'VpnLifecycle',
        `冷启动 VPN 恢复异常：${(error as Error).message ?? JSON.stringify(error)}`)
    }

    // 启动配置自动更新服务
    await this.startConfigAutoUpdateService();
    return true
    } catch (error) {
      hilog.error(0xA003, 'VpnLifecycle', `核心初始化异常：${(error as Error).message}`)
      this.scheduleCoreInitRetry()
      return false
    } finally {
      this.coreInitInProgress = false
    }
  }

  /**
   * 核心失联恢复器。
   *
   * active 会在任意一次短 RPC 错误时变为 false，不能把它当成“Extension 已死”
   * 的单一证据。连续三次真实运行时探针失败后才重建，并用互斥位防止定时器在
   * stop/start 窗口内再次进入；这正是冷启动时节点列表反复冻结的旧回归来源。
   */
  private startCoreHealthMonitor(): void {
    if (this.coreHealthTimer !== -1) return
    this.coreHealthTimer = setInterval(async (): Promise<void> => {
      if (this.coreHealthRecoveryInProgress) return
      try {
        await ClashViewModel.socketProxy.getRuntime(true)
        ClashViewModel.socketProxy.active = true
        this.coreHealthFailures = 0
        return
      } catch (_) {
        this.coreHealthFailures++
      }
      if (this.coreHealthFailures < 3) return

      this.coreHealthRecoveryInProgress = true
      ClashViewModel.socketProxy.offlineTime.push(Date.now())
      Xb_ToastUtil.showToast({
        message: `核心恢复中(${ClashViewModel.socketProxy.offlineTime.length})...`
      })
      try {
        const recovered = await ClashViewModel.ensureCoreReady()
        if (recovered) {
          ClashViewModel.socketProxy.active = true
          this.coreHealthFailures = 0
          if (cardManager.getVpnDesiredRunning()) {
            await ClashViewModel.restoreDesiredVpnState()
          }
        }
      } catch (error) {
        hilog.warn(0xA003, 'VpnLifecycle',
          `核心健康恢复异常：${(error as Error).message ?? JSON.stringify(error)}`)
      } finally {
        this.coreHealthRecoveryInProgress = false
      }
    }, 5000)
  }

  private scheduleCoreInitRetry(delayMs: number = 3000): void {
    if (this.clashCoreInitialized || this.coreInitRetryTimer !== -1) return
    this.coreInitRetryTimer = setTimeout(() => {
      this.coreInitRetryTimer = -1
      this.ClashCoreInit().catch((error: Error) => {
        hilog.warn(0xA003, 'VpnLifecycle', `核心初始化重试异常：${error.message}`)
        this.scheduleCoreInitRetry(Math.min(delayMs * 2, 15000))
      })
    }, delayMs)
  }

  private scheduleCoreConfigRetry(delayMs: number = this.coreConfigRetryDelayMs): void {
    if (!this.clashCoreInitialized || this.coreConfigRetryTimer !== -1) return
    const appConfig = AppStorage.get<AppConfig>('appConfig') || cardManager.getAppConfig()
    const profileId = appConfig?.currentProfileId
    if (!profileId) return
    this.coreConfigRetryTimer = setTimeout(async () => {
      this.coreConfigRetryTimer = -1
      if (!this.clashCoreInitialized) return
      try {
        // onForeground() also enters this path. A successfully loaded profile
        // must not be applied again merely because the user returned to
        // ClashBox: Mihomo config reload tears down long-lived connections and
        // made Telegram briefly cycle through "connecting" on every resume.
        const profile = await ClashViewModel.getProfile(profileId)
        if (profile?.coreLoadState === 'loaded') {
          this.coreConfigRetryDelayMs = 2500
          hilog.info(0xA003, 'ClashViewModel', '核心配置已加载，跳过前台重复重载')
          return
        }
        const loaded = await ClashViewModel.initProfile()
        if (loaded) {
          this.coreConfigRetryDelayMs = 2500
          hilog.info(0xA003, 'ClashViewModel', '启动配置后台重试成功')
          return
        }
        this.coreConfigRetryDelayMs = Math.min(this.coreConfigRetryDelayMs * 2, 15000)
        hilog.warn(0xA003, 'ClashViewModel',
          `启动配置后台重试失败，将在 ${this.coreConfigRetryDelayMs}ms 后继续`)
        this.scheduleCoreConfigRetry()
      } catch (error) {
        this.coreConfigRetryDelayMs = Math.min(this.coreConfigRetryDelayMs * 2, 15000)
        hilog.warn(0xA003, 'ClashViewModel',
          `启动配置后台重试异常：${(error as Error).message}，将在 ${this.coreConfigRetryDelayMs}ms 后继续`)
        this.scheduleCoreConfigRetry()
      }
    }, delayMs)
  }

  /** @description 启动配置自动更新服务 */
  private async startConfigAutoUpdateService(): Promise<void> {
    try {
      await ConfigAutoUpdateService.start();
    } catch (error) {
      hilog.error(0xFF00, 'ConfigAutoUpdateService',
        `配置自动更新服务启动失败 - ${JSON.stringify(error)}`);
    }
  }

  /** @description 卡片Clash核心触发事件 */
  private async CardClashCoreEvent(proxyActionType: ProxyActionType): Promise<void> {
    hilog.info(0x0000, 'EntryAbility', '%{public}s', 'CardClashCoreEvent');
    // 初始化核心
    if (!this.clashCoreInitialized) {
      await ClashViewModel.init(this.context, this.uiContext?.getPromptAction()!)
      await this.ClashCoreInit()
      this.cardCoreInitialized = true
    }

    const flag = await ClashViewModel.vpnConfigIsLoad()
    if (!flag) {
      cardManager.pushCartProxyMode(false, '核心配置未加载成功,请重新启动')
      return
    }

    const proxyNodeInfo = cardManager.getSelectedProxyNode()
    hilog.info(0x0000, 'EntryAbility', '%{public}s', JSON.stringify(proxyNodeInfo))

    // 启动/停止代理
    if (proxyNodeInfo?.profile) {
      ClashViewModel.changeProxy(proxyNodeInfo.profile, proxyNodeInfo.g, proxyNodeInfo.p)

      console.log('卡片 - 启动/停止代理', proxyActionType)

      if (proxyActionType === ProxyActionType.START) {
        await ClashViewModel.StartVpn()
        setTimeout(() => {
          this.refreshState(proxyNodeInfo?.p ?? '')
        }, 500)
      } else {
        await ClashViewModel.StopVpn()
        clearTimeout(this.cardDelayTimer)
      }
      // if (this.uiConfig.isVibrate) {
      customVibrator.vibratorTriggerOfHapticClockTimer()
      // }
    } else {
      cardManager.pushCartProxyMode(false, '请先选中一个节点')
      return
    }
  }

  async refreshState(proxyName: string) {
    // 刷新IP地址
    const remoteIp = await ClashViewModel.checkIpInfo()
    cardManager.pushCartProxyIpInfo(remoteIp);

    // 首次获取延迟
    const delay = await ClashViewModel.testDelay(proxyName)
    hilog.info(0x0000, 'EntryAbility', '延迟：%{public}d ms', delay)
    cardManager.pushCartDelay(delay)

    this.cardDelayTimer = setInterval(async () => {
      // 卡片主动刷新节点延迟
      const delay = await ClashViewModel.testDelay(proxyName)
      hilog.info(0x0000, 'EntryAbility', '延迟：%{public}d ms', delay)
      cardManager.pushCartDelay(delay)
    }, 800)
  }

  /**
   * @description 获取分享的包名信息
   * @param want want
   * @param launchMode true 热启动 false 冷启动
   * */
  private async getShareData(want: Want, launchMode: boolean = false) {
    try {
      // 获取共享数据
      const sharedData = await systemShare.getSharedData(want);
      hilog.info(0x0000, 'EntryAbility', '%{public}s', `getSharedData success: ${JSON.stringify(sharedData)}`);

      // 处理包名
      let records: systemShare.SharedRecord[] = sharedData.getRecords();
      records.forEach(async (record: systemShare.SharedRecord) => {
        switch (record.utd) {
          // 文本类型
          case utd.UniformDataType.TEXT:
            if (record.content) {
              const bundleName = UrlUtils.extractPackageName(record.content, this.uiContext?.getPromptAction()!)
              this.bundleInfo = new BundleInfo(bundleName, record.title ?? '', record.thumbnail)
            }
            break;
          // 超链接类型
          case utd.UniformDataType.HYPERLINK:
            if (record.content) {
              const bundleName = UrlUtils.extractPackageName(record.content, this.uiContext?.getPromptAction()!)
              this.bundleInfo = new BundleInfo(bundleName, record.title ?? '', record.thumbnail)
            }
            break;
          default:
            break;
        }
      })
      if (BundleInfo.isEmpty(this.bundleInfo)) {
        // 热启动 - 处理方式
        if (launchMode) {
          EventHub.sendEvent(EventKey.ShareBundle, this.bundleInfo)
        } else {
          // 冷启动 - 处理方式
          setTimeout(() => {
            EventHub.sendEvent(EventKey.ShareBundle, this.bundleInfo)
          })
        }
      }
    } catch (e) {
      hilog.error(0x0000, 'EntryAbility', '%{public}s', 'getSharedData error: ', JSON.stringify(e));
    }
  }

  private async intRectWindow(windowStage: window.WindowStage) {
    // 获取应用主窗口
    let windowClass: window.Window = windowStage.getMainWindowSync();
    // 设置窗口全屏
    windowClass.setWindowLayoutFullScreen(true).then(() => {
      console.info('Succeeded in setting the window layout to full-screen mode.');
    }).catch((err: BusinessError) => {
      console.error('Failed to set the window layout to full-screen mode. Cause:' + JSON.stringify(err));
    });

    // 缓存window窗口对象
    AppStorage.setOrCreate('WindowClass', windowClass)
    console.info('Succeeded in 保存窗口对象.');

    // 获取布局避让遮挡的区域
    this.avoidManager = new Xb_AvoidanceManager(windowClass, this.uiContext!);
    await this.avoidManager.init();
    // 注册监听器，当避让值变化时，更新UI状态
    this.avoidManager.onChangeListener(this.avoidListener);
    hilog.info(0x0000, 'EntryAbility Avoidance', 'Manager initialized and listener registered.');

    // 应用窗口初始高度和宽度
    try {
      let properties = windowClass.getWindowProperties()
      let rect = properties.windowRect
      let WindowHeight = this.uiContext?.px2vp(rect.height)
      let WindowWidth = this.uiContext?.px2vp(rect.width)
      hilog.info(0x0000, 'WindowLog', '窗口高度：%{public}d px 宽度：%{public}i px', rect.height, rect.width)
      AppStorage.setOrCreate('windowHeight', WindowHeight)
      AppStorage.setOrCreate('windowWidth', WindowWidth)
      // 监听窗口大小变化
      try {
        windowClass.on('windowSizeChange', async (data) => {
          // 动态监听设备窗口模式
          this.onWindowModeChange(windowStage, windowClass)
          console.info('#WindowChange Succeeded in enabling the listener for window size changes. Data: ' +
          JSON.stringify(data))
          WindowWidth = this.uiContext?.px2vp(data.width)!
          WindowHeight = this.uiContext?.px2vp(data.height)!
          AppStorage.setOrCreate('windowWidth', WindowWidth)
          AppStorage.setOrCreate('windowHeight', WindowHeight) // 980px 约等于 512vp
          // 动态监听高度断点
          this.onHeightBpChange(WindowHeight, WindowWidth)
        })
      } catch (exception) {
        console.error(`#EntryAbility Failed to enable the listener for window size changes. Cause code: ${exception.code}, message: ${exception.message}`)
      }
    } catch (error) {
      console.error(`#EntryAbility Failed to getWindowProperties. Cause code: ${error.code}, message: ${error.message}`)
    }
  }

  async onWindowModeChange(windowStage: window.WindowStage, windowClass: window.Window) {
    try {
      // 设置默认标题栏是否显示
      windowClass.setWindowDecorVisible(false)
      // 设置默认标题栏功能按钮是否显示
      windowClass.setWindowTitleButtonVisible(false, false, false)
      // 全屏时鼠标移动至顶部不显示标题栏和dock栏，平板自由多窗则是无法唤起状态栏
      windowClass.setTitleAndDockHoverShown(false, false).catch((err: Error) => {
        console.error(`EntryAbility setTitleAndDockHoverShown 失败, message: ${err.message}`)
      })
      try {
        if (this.isFirstStart) {
          const systemLimits = windowClass.getWindowLimits()
          this.windowLimits.maxWidth = systemLimits.maxWidth
          this.windowLimits.maxHeight = systemLimits.maxHeight
          this.isFirstStart = false
        }
        console.info(`WindowMode  the window limits. FirstLimits: ${JSON.stringify(this.windowLimits)}`);
        let promise = windowClass.setWindowLimits(this.windowLimits, true);
        promise.then((data) => {
          console.info(`WindowMode Succeeded in changing the window limits. limits: ${JSON.stringify(data)}`);
        }).catch((err: BusinessError) => {
          console.error(`WindowMode Failed to change the window limits. Cause code: ${err.code}, message: ${err.message}`);
        });
      } catch (exception) {
        console.error(`WindowMode Failed to change the window limits. Cause code: ${exception.code}, message: ${exception.message}`);
      }
      // 设置标题栏高度
      // windowClass.setWindowDecorHeight(50)
      hilog.info(0xFF00, "EntryAbility", 'WindowMode 当前为PC窗口模式')
      AppStorage.setOrCreate('WindowMode', true)
      this.windowMode = true
      Xb_Global.windowMode = true
    } catch (exception) {
      hilog.error(0xFF00, "EntryAbility",
        'WindowMode 当前为普通模式 Cause code: %{public}s smessage: %{public}s', exception.code, exception.message)
      AppStorage.setOrCreate('WindowMode', false)
      Xb_Global.windowMode = false
      this.windowMode = false
    }
  }

  onHeightBpChange(WindowHeight: number, WindowWidth: number) {
    let heightBp = 0
    const WindowAspectRatio = WindowHeight / WindowWidth // 重写高度断点
    if (WindowAspectRatio < 0.79) {
      heightBp = 0
      console.log(`断点测试 heightBp: ${heightBp} 高宽比：${WindowAspectRatio}`)
    } else if (WindowAspectRatio >= 0.79 && WindowAspectRatio < 1.2) {
      heightBp = 1
      console.log(`断点测试 heightBp: ${heightBp} 高宽比：${WindowAspectRatio}`)
    } else if (WindowAspectRatio >= 1.2) {
      heightBp = 2
      console.log(`断点测试 heightBp: ${heightBp} 高宽比：${WindowAspectRatio}`)
    }
    AppStorage.setOrCreate('currentHeightBreakpoint', heightBp)
    Xb_Global.HeightBp = heightBp
  }
}

class Params implements rpc.Parcelable {
  marshalling(dataOut: rpc.MessageSequence): boolean {
    return true
  }

  unmarshalling(dataIn: rpc.MessageSequence): boolean {
    return true
  }
}

export function sleep(timeout: number): Promise<void> {
  return new Promise((resolve, reject) => {
    setTimeout(() => {
      resolve()
    }, timeout)
  })
}
