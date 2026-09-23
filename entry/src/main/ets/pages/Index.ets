// Index
import { curves, LengthMetrics, mediaquery } from '@kit.ArkUI'
import Home from './HomePage'
import ProxyPage from './ProxyPage'
import { util } from "@kit.ArkTS";
import ConfigurationPage from './ConfigurationPage'
import MorePage from './MorePage'
import { hilog } from '@kit.PerformanceAnalysisKit'
import {
  PROXY_STARTED_DURATION_INIT_VALUE,
  ListMoreData,
  moreData,
  AboutListItemProp,
  BIND_SHEET_CONTAINER_HEIGHT,
  DefaultUpdateInfo,
  CHART_NUMBER,
  TheExperimentData,
  TAB_CONTENT_TITLE_HEIGHT,
  LogData,
  showHomeCard,
  NewConfigData,
  BundleInfo,
  HomeCards,
  filterStringsByBooleans,
  convertMillisecondsToTimeGap,
} from '../common/entity/Constants'
import { ProxyItem, ProxyData, ProxyGroupItemDataSource, ProxyItemDataSource } from '../common/datasources/ProxyData'
import { ClashConfig, IpInfo, Profile, ProxyGroup, ProxyMode, ProxyType } from 'proxy_core'
import { EventHub, EventKey } from '../common/EventHub'
import ClashViewModel from '../entryability/ClashViewModel'
import { AppConfig, AppFlowingState, AppState, getPackageInfo, UIConfig } from '../entryability/AppState'
import { common } from '@kit.AbilityKit'
import { ChangeLanguage } from '../common/utils/ChangeLanguageUtil'
import { ConfigData, HomeCardInfo, TabBuild } from '../common/entity/PageArgumentEntity'
import { customAnimationUtil } from '../common/utils/Animation'
import { AppUpdateCustomDialog, CoreUpdateCustomDialog, DisclaimerCustomDialog, EmptyCoreReleaseInfo, icon_tertiary,
  theRowCustomDialog } from '../components/Common/Common'
import { PipManager } from '../common/utils/PipManager'
import { deviceInfo } from '@kit.BasicServicesKit'
import { CrashPage } from '../components/Start/CrashPage'
import { UpdateInfo } from '../common/utils/CheckUpdateUtil'
import { fileUri, picker, ReadOptions } from '@kit.CoreFileKit'
import { fileIo as fs } from '@kit.CoreFileKit';
import { number2Time, timestampToDateTime } from '../common/utils/TimeConvertUtil'
import { PXSecScreen } from './PXSecScreen'
import { getResourceString } from '../common/utils/ResourceStringUtil'
import { ConvertedUnit } from '../common/utils/DataUnitConvertUtils'
import { WelcomeUserAgreement } from '../components/Start/WelcomePage'
import { i18n } from '@kit.LocalizationKit'
import {
  FloatTabBarHeight,
  MoreNavMode,
  TabBarAlignItems,
  TabBarAvoidHeight,
  TabBarHeight,
  TabBarJustifyContent,
  TabBarPosition,
  TabBarVertical,
  TabBarWidth,
  TabIconFontSize,
  TabTitleFontSize,
  WindowTabBarWidth
} from '../common/breakpoint/BreakPoint'
import { WindowTopBar } from '../components/Common/TopBar'
import { ImportConfigFromURL } from '../components/Configuration/ImportConfigFromURL'
import { Xb_ChangeThemeColor } from 'xb_components/src/main/ets/utils/ChangeThemeColorUtil'
import {
  StatusBarConfig,
  StatusBarIconResource,
  Xb_ColorModeManager,
  Xb_FloatTabBarAlignCenter,
  Xb_FloatTabBarAlignEnd,
  Xb_FloatTabBarAlignStart,
  Xb_FloatTabBarDirection,
  Xb_Global,
  Xb_KVdbUtil,
  Xb_PreferenceUtil,
  Xb_ResourceColorUtil,
  Xb_StatusBarUtils,
  Xb_TabBarVertical,
  Xb_TabIconFontSize,
  Xb_TabTitleFontSize
} from 'xb_components'
import { Xb_GoToWeb } from 'xb_components/src/main/ets/utils/JumpTo'
import { notificationManager } from '@kit.NotificationKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { cardManager } from '../common/utils/CardManageUtil'
import { UpdateLog } from '../components/Start/UpdateLog'
import { Xb_AnimationStyle } from 'xb_components';
import { getJsonArrayType } from '../common/entity/utils';
import { holdingHandleUtil } from '../common/utils/HoldingHandleUtil';
import { sortByCustomOrder } from '../common/utils/SortUtil';
import { AccessControlCompatibleMerger } from '../common/utils/AccessControlCompatibleUtil';
import { PCIndex } from './PCIndex';
import { accessControlRdb, AppInfo, ListType } from '../common/datasources/AccessControlRdb';
import { FloatBar } from '../components/Common/FloatBar';
import BackgroundDownService from '../common/utils/BackgroundDownService';
import PlatformConnectivityService, {
  PLATFORM_TARGETS,
  PlatformConnectivityResult
} from '../common/utils/PlatformConnectivityService';
import CoreUpdateService, { CoreReleaseInfo } from '../common/utils/CoreUpdateService';
import AppReleaseUpdateService, { AppReleaseInfo } from '../common/utils/AppReleaseUpdateService';

export const indexController: TabsController = new TabsController()
const swiperController: SwiperController = new SwiperController()

const componentName: string = 'Index'

@Entry
@Component
struct Index {
  /**
   * 窗口
   */
  // 高度断点
  @StorageLink('currentHeightBreakpoint') @Watch('onWindowChange') @Watch('isSecondaryChange') heightBp: HeightBreakpoint = 0
  // 宽度断点
  @StorageLink('currentWidthBreakpoint') @Watch('onWindowChange') @Watch('isSecondaryChange') widthBp: WidthBreakpoint = 1
  // 导航条区域的高度
  @StorageProp('bottomRectHeight') @Watch('onAvoidAreaChange') bottomRectHeight: number = 0
  // 状态栏高度
  @StorageProp('topRectHeight') @Watch('onAvoidAreaChange') topRectHeight: number = 0
  // 应用窗口高度
  @StorageLink('windowHeight') @Watch('onWindowChange') windowHeight: number = 0
  // 应用窗口宽度
  @StorageLink('windowWidth') @Watch('onWindowChange') windowWidth: number = 0
  // 左侧避让宽度
  @StorageProp('LeftAvoidWidth') leftAvoidWidth: number = 0
  // 右侧避让宽度
  @StorageProp('RightAvoidWidth') rightAvoidWidth: number = 0
  // 分屏（正方形窗口）
  @Provide @Watch('isHiddenChange') isSmallSquareScreen: boolean = false
  // 手机横屏判断
  @StorageLink('isLandscapePhone') isLandscapePhone: boolean = false
  @Provide('currentColorMode') currentColorMode: boolean = false
  // 折叠展开状态判断变量
  @StorageLink('isFoldStatus') isFoldStatus: boolean = false
  // 平板竖屏判断变量
  @Provide istabletLandscape: boolean = false
  // px外屏判定
  @Provide isPXSecScreen: boolean = false
  /**
   * 颜色相关变量
   *    示例中主题配置里配置了一个颜色，所以只用`ResourceColor`类型的变量来接收色值，
   *    如果有多个颜色，就把这个变量换成`CustomTheme`类型的变量）
   */
  // 主题色
  @Provide('icon_emphasize') icon_emphasize: ResourceColor = $r('app.color.theme_color_main_cat_blue')
  @StorageLink('ThemeColor') themeColor: string = "#E61E4377"
  // tabs图标文字颜色，修改resources/base(dark)/element/color.json中tabs_icon_text配置选中图标文字深浅模式颜色
  // app.color.tabs_icon_text1配置非选中图标和文字深浅模式颜色
  //  @State fontColorValue:ResourceColor = ($r('app.color.tabs_icon_text'));
  //  @State fontColorValue1:ResourceColor = ($r('app.color.tabs_icon_text1'));

  /**
   * Index相关变量
   */
  // 所有子组件在容器内的对齐方式
  @Provide('stackAlignContentAlignment') stackAlignContentAlignment: Alignment = Alignment.BottomEnd
  @StorageLink('clashConfig') /*@Watch('switchMode')*/clashConfig: ClashConfig = new ClashConfig()
  @StorageProp("appFlowingState") appFlowingState: AppFlowingState = new AppFlowingState()
  // 欢迎页面栈
  @Provide('WelcomeNavPathStack') welcomePageInfos: NavPathStack = new NavPathStack()
  // 主页面栈
  private pageInfos: NavPathStack = AppStorage.get<NavPathStack>('NavPathStack') as NavPathStack
  @StorageLink('appConfig') appConfig: AppConfig = new AppConfig()
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()

  @Provide paddingButtom: number | Resource = $r('app.integer.vp_proxy_start_button_left_right_margin')
  @StorageLink('appLinkConfigUrl') @Watch('onOpenConfigLink') appLinkConfigUrl: string = ''
  @StorageLink('appLinkConfigName') @Watch('onOpenConfigLink') appLinkConfigName: string = ''
  // 系统语言显示副标题
  @Provide SystemLanguageSubtitle: ResourceStr = $r('app.string.SimplifiedChinese')
  // 通知权限跳转授权弹窗提示弹窗标题
  @State theToDialogTitle: ResourceStr = $r('app.string.notice_request_to_settings')
  @State barWidth: string | number | undefined = ''
  @State barHeight: string | number | undefined = 0
  @Provide("currentProfile") currentProfile: Profile | null = null
  @Provide remoteIp: IpInfo | null = null
  // IpInfo is supplied by a HAR class. ArkUI does not reliably observe optional
  // fields added to that class, so keep every value shown by the IPPure card as
  // an independent reactive primitive. This prevents a new IP from being paired
  // with the previous node's location/source/property labels.
  @Provide ipDisplayAddress: string = ''
  @Provide ipDisplayLocation: string = ''
  @Provide ipDisplaySource: string = ''
  @Provide ipDisplayProperty: string = ''
  @Provide ipPureScore: number = -1
  @Provide cloudflareScore: number = -1
  // 是否开启`Index`页面的前景模糊
  @Provide('isEnableIndexForegroundBlur') isEnableIndexForegroundBlur: boolean = false
  // 代理启动变量
  @Provide @Watch('ShowPipChange') proxyEnabled: boolean = false
  // 前台判断变量
  @StorageProp('ForwardState') isForward: boolean = true
  // 配置数据库是否已就绪。配置首屏只依赖 RDB，不再等待核心/VPN 初始化。
  @StorageLink('profileRepoReady') @Watch('onProfileRepoReady') profileRepoReady: boolean = false
  // 窗口模式
  @StorageProp('WindowMode') windowMode: boolean = false
  // 设置模态页控制变量
  @Provide isShowSettings: boolean = false
  // 欢迎页半模态窗口
  @Provide isShowWelcome: boolean = false
  // 是否为免责弹窗
  @Provide isDisclaimer: boolean = false
  // 是否在主页
  @Provide isHomePage: boolean = false

  @StorageProp('EnableAPIVersion') apiVersionEnable: boolean = false
  // 顶部Bar高度
  @Provide heightTop: Length = TAB_CONTENT_TITLE_HEIGHT
  // 主界面当前index
  @Provide tabCurrentPage: number = 0
  // PX外屏-偏移
  @Provide curOffsetRemain: number = 0
  // 恢复时刻
  @Provide theRestoreTime: number = 0
  // 暂停时刻
  @Provide thePauseTime: number = 0
  // 流量任务id
  private trafficJob: number = 0
  private tabList: TabBuild[] = [
    { name: $r('app.string.Home'), icon: $r('sys.symbol.house_fill') },
    { name: $r('app.string.Proxy'), icon: $r('sys.symbol.list_bullet_square_fill') },
    { name: $r('app.string.Configuration'), icon: $r('sys.symbol.folder_fill') },
    { name: $r('app.string.More'), icon: $r('sys.symbol.square_fill_grid_2x2') }
  ]
  private context = this.getUIContext().getHostContext()! as common.UIAbilityContext
  private promptAction = this.getUIContext().getPromptAction()
  private UIContext = this.getUIContext()

  /**
   * 主页相关变量
   */
  @Provide rotateAngle: number = 0
  // 编辑卡片半模态页控制变量
  @Provide isShowCardEdit: boolean = false
  // 编辑按钮点击后显示编辑状态判定
  @Provide isShowHomeEdit: boolean = false
  // 主页删除按钮是否出现判定
  @Provide isShowDeleteButton: boolean = false
  // 当前主页布局
  @Provide theCurrentHomeCard: string[] = showHomeCard
  // 上一次主页布局
  @Provide theLastHomeCard: string[] = showHomeCard
  // 速度卡片图表数据
  @Provide ChartData: number[] | ConvertedUnit[] = []
  // 显示的是更新日志
  @StorageLink('ShowUpdateLog') showUpdateLog: boolean = false
  // 代理启动的计时文本
  @StorageLink('proxyStartingDuration') proxyStartingDuration: string = ''
  // 速度卡片
  @Provide DownloadSpeed: string = ""
  @Provide UploadSpeed: string = ""
  @Provide homeCardList: HomeCardInfo[] = HomeCards
  /**
   * 代理页Provide相关变量
   */
  // 收藏的代理节点
  @StorageLink('favoriteProfiles') favoriteProfiles: Map<string, string> = new Map<string, string>([])
  // 代理页分组数据（懒加载）
  @Provide proxyGroups: ProxyGroupItemDataSource = new ProxyGroupItemDataSource()
  // 节点数据
  @Provide proxyLazyItems: ProxyItemDataSource = new ProxyItemDataSource()
  // 节点数据组
  @Provide items: ProxyItem[] = ProxyData.ProxyItems();
  // 代理页延迟按钮气泡提示
  @Provide isShowDelayPop: boolean = false
  // 当前代理节点长按选择的值
  @Provide ProxyItemLongPressValue: number = -1
  // 当前显示的代理分组
  @Provide currentProxyIndex: number = 0
  /** 丢弃配置切换、模式切换期间乱序返回的旧代理组查询。 */
  private proxyFetchGeneration: number = 0
  // 当前代理节点收藏的值
  @Provide FavoriteProxy: number = -1
  /**
   * 配置页相关变量
   */
  // 配置页模糊变量
  @Provide('isEnableConfigPageBindSheetForegroundBlur') isEnableConfigPageBindSheetForegroundBlur: boolean = false
  // 当前触摸的配置行
  @StorageLink('currentTouchConfigData') currentTouchConfigData: ConfigData = NewConfigData
  // 是否显示配置页bindSheet
  @StorageLink('ShowConfigBindSheet') isShowConfigAddBindSheet: boolean = false
  // 是否为新建配置
  @StorageLink('ConfigNew') isNewConfig: boolean = false
  // 当前选中的配置行
  @Provide currentConfigRadioCheckedConfigData: ConfigData = NewConfigData
  // 路由栈
  @Provide('configAddPageInfos') configAddPageInfos: NavPathStack = new NavPathStack()
  // 配置数据
  @Provide('Configuration') configList: Array<ConfigData> = []
  // 区分“配置尚未读取”和“数据库确实为空”，避免冷启动误报没有配置。
  @Provide('ConfigurationLoaded') configListLoaded: boolean = false
  private profilesFetchGeneration: number = 0
  @StorageLink('ConfigContent') configStr: string = ''
   /**
   * 更多页相关变量
   */
  // 访问控制 -> 在线应用添加
  private addPageInfos: NavPathStack = AppStorage.get<NavPathStack>('OnlineSearchPageInfos') as NavPathStack
  // 更多页面栈
  private morePageInfos: NavPathStack = AppStorage.get<NavPathStack>('MoreNavPathStack') as NavPathStack
  // 更多页面数据
  @Provide moreList: moreData[] = ListMoreData()
  // 日志数据
  @Provide logListData: Array<LogData> = []
  // 更多页标题是否搜索中
  @Provide isSearching: boolean = false
  // 更多页标题是否搜索
  @Provide needSearch: boolean = false
  // 更多页一级页面顶部标题偏移量
  @Provide curYOffsetMore: number = 0
  @Provide curYOffset: number = 0
  // 更多页标题搜索文本
  @Provide searchText: string = ''
  /**
   * 设置页变量
   */
  // 设置页面栈
  @Provide('NavSettingsPathStack') SettingsPageInfos: NavPathStack = new NavPathStack()
  // 设置页语言选中暂存变量
  @Provide currentLanguage: ResourceStr = $r('app.string.Language_Subtitle')
  // 实验功能开关列表行数据
  @Provide ExperimentData: AboutListItemProp = TheExperimentData
  // 应用更新信息
  @Provide theAppVersionInfo: UpdateInfo = DefaultUpdateInfo
  @State private coreUpdateInfo: CoreReleaseInfo = EmptyCoreReleaseInfo
  private pendingCoreUpdateInfo: CoreReleaseInfo | null = null
  private coreUpdateCheckTimer: number = 0
  private coreUpdateDialogVisible: boolean = false
  @State private appReleaseInfo: AppReleaseInfo = {
    currentVersion: '', latestVersion: '', name: '', publishedAt: '',
    releaseUrl: '', downloadUrl: '', body: ''
  }
  private pendingAppReleaseInfo: AppReleaseInfo | null = null
  private appUpdateDialogVisible: boolean = false
  // VPN 启动后先给真实客户端让出连接窗口；仅保留一个可取消的轻量
  // 卡片刷新，避免启动时与 ChatGPT 首个请求争抢本地代理。
  private startedConnectivityRefreshTimer: number = -1
  private navigationResetTimer: number = -1
  // 是否进入二级界面(Tab区)
  @Provide @Watch('isSecondaryChange') isSecondary: boolean = false
  // 列表是否滚动
  @Provide @Watch('isHiddenChange') isRolling: boolean = false
  // 设置 -> 通知 -> 流量提醒启用状态变量
  @Provide EnableCellularDataReminder: boolean = false
  // 判断设置是否清楚数据
  @Provide isClearData: boolean = false
  @StorageProp('VpnServiceStartTime') VpnServiceStartTime: number = 0
  // 设置 -> 外观 -> 按钮位置变量
  @Provide ButtonPositionOffset: number = 0
  @Provide proxyTime: number = 0
  // TODO 6.0(20)光效
  // @Provide lightSourceType: hdsEffect.PointLightSourceType = hdsEffect.PointLightSourceType.NONE;


  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // 窗口控制器(窗口模式显示)
      if (this.windowMode && !this.isSearching) {
        WindowTopBar()
          .zIndex(2)
      }
      // 主内容区
      if (this.uiConfig.tabStyle == 'window') {
        PCIndex()
      } else
      if (!this.isPXSecScreen) {
        Navigation(this.pageInfos) {
          this.MainContent()
        }
        .hideTitleBar(true).hideToolBar(true)
        .height('100%').width('100%')
        .mode(NavigationMode.Stack)
      } else {
        // PX外屏样式
        PXSecScreen()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundBlurStyle(this.uiConfig.tabStyle == 'window' ? BlurStyle.BACKGROUND_THICK : undefined)
    .backgroundColor(this.uiConfig.tabStyle == 'window' ? undefined : $r('app.color.background'))
    .foregroundBlurStyle(this.isEnableIndexForegroundBlur && this.uiConfig.isBlurr ? BlurStyle.Thin : BlurStyle.NONE,
      { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT, scale: 0.3 })
    // 欢迎页&崩溃页
    .bindSheet($$this.isShowWelcome, this.WelcomeSheet(), {
      detents: [BIND_SHEET_CONTAINER_HEIGHT],
      showClose: (AppStorage.get<boolean>('crash') === true && !this.uiConfig.isFirstStart) ||
        this.appLinkConfigUrl != '' || (this.uiConfig.oldVersionCode !== AppState.versionCode && !this.uiConfig.isFirstStart) || this.showUpdateLog,
      dragBar: false,
      backgroundColor: $r('app.color.background'),
      keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
      scrollSizeMode: ScrollSizeMode.CONTINUOUS,
      preferType: SheetType.CENTER,
      onWillDismiss: ((DismissSheetAction: DismissSheetAction) => {
        hilog.debug(0xFF00, "WelcomeTestTag", "弹窗关闭原因：%{public}d", DismissSheetAction.reason)

        // 崩溃报告是一次性诊断页面。用户查看/关闭后清除标记，避免旧的
        // NativeCrash 记录在下一次启动时被误认为是新的崩溃。
        if (AppStorage.get<boolean>('crash') === true) {
          AppStorage.setOrCreate('crash', false)
          AppStorage.setOrCreate('crashEvent', [])
        }

        // 无论什么原因关闭，都重置状态
        this.showUpdateLog = false
        this.isShowWelcome = false
        this.uiConfig.oldVersionCode = AppState.versionCode

        // 清空 AppLink 相关状态，避免重复导入
        if (this.appLinkConfigUrl != '') {
          this.appLinkConfigUrl = ''
          this.appLinkConfigName = ''
        }

        // 重置设置状态
        this.SettingsPageInfos.clear()
        // 关闭背景模糊
        this.isEnableIndexForegroundBlur = false

        hilog.error(0xFF00, "WelcomeTestTag", `Update 历史应用版本更新为：${this.uiConfig.oldVersionCode} showUpdateLog: ${this.showUpdateLog}`)

        DismissSheetAction.dismiss()
        hilog.info(0xFF00, "WelcomeTestTag", "欢迎页启用状态： %{private}s", this.isShowWelcome)
      }),
      onWillAppear: () => {
        // 启用背景模糊
        this.isEnableIndexForegroundBlur = true
        console.error(`Update Index isShowWelcome：${this.isShowWelcome} showUpdateLog: ${this.showUpdateLog}`)
      },
      onDisappear: async () => {
        // 重置设置状态
        this.SettingsPageInfos.clear()
        // 关闭背景模糊
        this.isEnableIndexForegroundBlur = false
        this.openPendingCoreUpdate()
      },
      onWillSpringBackWhenDismiss: () => {} // 注册回调，防止反向回弹
    })
  }

  @Builder
  MainContent() {
    // 主界面
    if (this.uiConfig.tabStyle == 'float' && this.apiVersionEnable) {
      // 悬浮Tab
      this.FloatTab()
    } else {
      // 普通Tab
      this.CustomTab()
    }
  }

  @Builder
  CustomTabBarBuilder(title: ResourceStr, index: number, TabIcon: Resource) {
    Flex({
      direction: FlexDirection.Column,
      justifyContent: TabBarJustifyContent(this.widthBp, this.heightBp),
      alignItems: this.windowMode ? ItemAlign.Center : TabBarAlignItems(this.widthBp, this.heightBp),
      space: { main: LengthMetrics.vp(3) }
    }) {
      SymbolGlyph(TabIcon)
        .fontColor([this.tabCurrentPage === index ? this.icon_emphasize : icon_tertiary])
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY) // 分层颜色
        .fontSize(TabIconFontSize(this.widthBp, this.heightBp))
        //.effectStrategy(customAnimationUtil.isIconEffect(this.uiConfig))
        .transition(customAnimationUtil.isTranslate(this.uiConfig))
        .translate({ y: this.tabCurrentPage == index ? -3 : 0 })

      Text(title)
        .fontColor(this.tabCurrentPage === index ? this.icon_emphasize : icon_tertiary)
        .fontWeight(FontWeight.Medium)
        .fontSize(TabTitleFontSize(this.widthBp, this.heightBp))
        .transition(customAnimationUtil.isTranslate(this.uiConfig))
    }
    .width('100%')
    .height('100%')
    .padding({ top: 8 })
  }
  @Builder
  CustomTab() {
    Tabs({
      barPosition: TabBarPosition(this.widthBp, this.heightBp),
      controller: indexController
    }) {
      ForEach(this.tabList, (item: TabBuild, index: number) => {
        TabContent() {
          this.TabContentBuilder(index)
        }
        .tabBar(this.CustomTabBarBuilder(item.name, index, item.icon))
        .gesture(
          // 二级Tabs第一个页签向左拖动时，触发手势事件，当Tab栏竖排时不触发
          PanGesture({
            direction: !TabBarVertical(this.widthBp, this.heightBp) ? PanDirection.Down : PanDirection.None
          })
            .onActionStart((event?: GestureEvent) => {
              console.info('Pan start')
            })// 通过父组件的TabsController的实例，改变其index，达到跳转一级Tabs（首页）的效果
            .onActionEnd(() => {
              if (this.isLandscapePhone || this.istabletLandscape) {
                if (this.tabCurrentPage == 0) {
                  indexController.changeIndex(1)
                  console.info('Pan end')
                }
              }
            }))
      })
    }
    .zIndex(1)
    .backgroundColor($r('app.color.background'))
    .barOverlap(false)
    .scrollable(!this.isSecondary)
    .vertical(TabBarVertical(this.widthBp, this.heightBp))
    .barWidth(this.windowMode ? WindowTabBarWidth(this.widthBp, this.heightBp) :
      TabBarWidth(this.widthBp, this.heightBp))
    .barHeight((this.isSecondary && this.widthBp <= 2 && !this.windowMode) || this.isSmallSquareScreen ?
      this.barHeight : this.bottomRectHeight == 0 ? TabBarHeight(this.widthBp, this.heightBp) :
        TabBarAvoidHeight(this.widthBp, this.heightBp))
    .onTabBarClick((index: number) => {
      Xb_AnimationStyle.animToAPI18(() => {
        this.tabCurrentPage = index
      },this.uiConfig.animationSpeed, 'app', 0)
    })
    .onChange((index) => {
      Xb_AnimationStyle.animToAPI18(() => {
        this.tabCurrentPage = index
        if (index == 0) {
          this.isHomePage = true
          return
        }
        this.isHomePage = false
      },this.uiConfig.animationSpeed, 'app', 0)
    })
    .onAnimationStart((index: number, targetIndex: number) => {
      Xb_AnimationStyle.animToAPI18(() => {
        this.tabCurrentPage = targetIndex;
      },this.uiConfig.animationSpeed, 'app', 0)
    })
    .onAppear(() => {
      indexController.changeIndex(this.tabCurrentPage)
    })
    .width('100%').height('100%')
    .backgroundColor($r('app.color.background')).fadingEdge(true)
    .padding({ top: this.topRectHeight, bottom: this.bottomRectHeight == 0 ? this.bottomRectHeight / 2 : 0 })
  }

  @Builder
  FloatBarFunctionContentBuilder() {
    if (this.widthBp <= 2 && (this.tabCurrentPage == 0 || this.uiConfig.needProxyStart)) {
      Text(this.proxyStartingDuration)
        .fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor(this.proxyEnabled ? Color.White : Color.Transparent)
    }
  }

  @Builder
  FloatTab() {
    Stack() {
      Swiper(swiperController) {
        ForEach(this.tabList, (item: TabBuild, index: number) => {
          this.TabContentBuilder(index)
        })
      }
      // 渐变模糊
     // .linearGradientBlur(this.uiConfig.isBlurr && !this.isRolling ? 100 : 0,
    //    { fractionStops: [[0, 0.3],[0, 0.85],[0.7, 0.9],[1, 1]], direction: GradientDirection.Bottom })
      .cachedCount(0)
      .indicator(false).loop(false)
      .width('100%').height('100%')
      .padding({
        top: this.topRectHeight,
        left: (Xb_TabBarVertical(this.widthBp, this.heightBp)) ? 69 + ((this.leftAvoidWidth != 0 && this.windowHeight <= 520) ? this.leftAvoidWidth + 19 : 0) : 0
      })
      .vertical(Xb_TabBarVertical(this.widthBp, this.heightBp))
      .onAnimationStart((startIndex: number, targetIndex: number, extraInfo: SwiperAnimationEvent) => {
        this.tabCurrentPage = targetIndex
        swiperController.changeIndex(targetIndex, true)
      })

      // tab栏（抽离成组件）
      FloatBar({ tabList: this.tabList, swiperController: swiperController })
    }
    .width('100%')
    .height('100%')
    .align(this.getFloatAlign())
  }

  @Builder
  TabContentBuilder(index: number) {
    if (index == 0) {
      Home()
    } else if (index == 1) {
      ProxyPage()
    } else if (index == 2) {
      ConfigurationPage()
    } else {
      MorePage()
    }
  }

  @Builder
  WelcomeSheet() {
    if (AppStorage.get<boolean>('crash') == true && !this.uiConfig.isFirstStart) {
      CrashPage()
    } else if (this.appLinkConfigUrl != '') {
      ImportConfigFromURL({
        configData: this.currentTouchConfigData,
      })
    } else if (this.uiConfig.isFirstStart) {
      WelcomeUserAgreement()
    } else {
      // 版本更新后显示更新日志
      UpdateLog()
    }
  }

  @Builder
  toNoticeSettingsBuilder() {
    Button($r('app.string.to'))
      .backgroundColor($r('app.color.container_background'))
      .width('100%')
      .height(39)
      .fontColor(this.icon_emphasize)
  }

  /* // 当手机横屏时条件成立
  deviceHeightListener: mediaquery.MediaQueryListener =
   this.getUIContext().getMediaQuery().matchMediaSync('(320vp< height <= 500vp) and (640vp< width <= 1000vp)');
  */
  private colorModeListener: mediaquery.MediaQueryListener = this.getUIContext().getMediaQuery().matchMediaSync('(dark-mode: true)')

  // 免责声明 & 检查更新 弹窗控制器
  dialogController: CustomDialogController = new CustomDialogController({
    builder: DisclaimerCustomDialog({
      confirm: () => {
        // 关闭背景模糊
        this.isEnableIndexForegroundBlur = false
        if (!this.isDisclaimer) {
          Xb_GoToWeb(this.theAppVersionInfo.browser_download_url)
        }
      },
      cancel: () => {
        if (this.isDisclaimer) {
          // 拒绝并退出
          this.context.terminateSelf().catch(() => {
            console.log(`#DisclaimerCustomDialog 应用已退出`)
          })
        } else {
          // 关闭背景模糊
          this.isEnableIndexForegroundBlur = false
        }
      },
      isDisclaimer: this.isDisclaimer,
      version: this.isDisclaimer ? '' : this.theAppVersionInfo.tag_name,
      body: this.theAppVersionInfo.body
    }),
    autoCancel: false,
    onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
      if (dismissDialogAction.reason == DismissReason.PRESS_BACK) {

      } else if (dismissDialogAction.reason == DismissReason.TOUCH_OUTSIDE) {

      } else {
        dismissDialogAction.dismiss()
        setTimeout(() => {
          this.isDisclaimer = false
        }, 20)
      }
    }
  })

  coreUpdateDialogController: CustomDialogController = new CustomDialogController({
    builder: CoreUpdateCustomDialog({
      releaseInfo: this.coreUpdateInfo,
      later: (): void => {
        this.coreUpdateDialogVisible = false
        this.isEnableIndexForegroundBlur = false
      },
      openRelease: (): void => {
        const releaseUrl = this.coreUpdateInfo.releaseUrl
        this.coreUpdateDialogVisible = false
        this.isEnableIndexForegroundBlur = false
        Xb_GoToWeb(releaseUrl)
      }
    }),
    autoCancel: false
  })

  appUpdateDialogController: CustomDialogController = new CustomDialogController({
    builder: AppUpdateCustomDialog({
      releaseInfo: this.appReleaseInfo,
      later: (): void => {
        this.appUpdateDialogVisible = false
        this.isEnableIndexForegroundBlur = false
        this.openPendingCoreUpdate()
      },
      openRelease: (): void => {
        const releaseUrl = this.appReleaseInfo.releaseUrl
        this.appUpdateDialogVisible = false
        this.isEnableIndexForegroundBlur = false
        Xb_GoToWeb(releaseUrl)
        this.openPendingCoreUpdate()
      }
    }),
    autoCancel: false
  })

  /** VPN 与 mixed 端口就绪后再通过当前节点检查上游稳定版。 */
  private scheduleCoreUpdateCheck(): void {
    clearTimeout(this.coreUpdateCheckTimer)
    this.coreUpdateCheckTimer = setTimeout(async (): Promise<void> => {
      if (!ClashViewModel.vpnStarted) return
      const mixedPort = Number(this.clashConfig['mixed-port'] ?? 7890)
      // App release first: a newer HAP may already include the upstream core.
      // Both checks remain advisory and run only after VPN + mixed-port start.
      try {
        const appRelease = await AppReleaseUpdateService.checkAfterVpnStarted(
          mixedPort, AppState.versionName)
        if (appRelease) {
          this.pendingAppReleaseInfo = appRelease
          this.openPendingAppUpdate()
        }
      } catch (error) {
        hilog.warn(0xC042, 'AppUpdate',
          `应用版本检查失败：${(error as Error).message || 'unknown'}`)
      }
      if (!ClashViewModel.vpnStarted) return
      try {
        const releaseInfo = await CoreUpdateService.checkAfterVpnStarted(mixedPort)
        if (!releaseInfo) return
        this.pendingCoreUpdateInfo = releaseInfo
        this.openPendingCoreUpdate()
      } catch (error) {
        // Update checks are advisory. Keep VPN startup and the rest of the UI
        // independent from GitHub availability.
        hilog.warn(0xC041, 'CoreUpdate',
          `稳定版内核检查失败：${(error as Error).message || 'unknown'}`)
      }
    }, 4000)
  }

  private openPendingAppUpdate(): void {
    if (!this.pendingAppReleaseInfo || this.isShowWelcome ||
      !ClashViewModel.vpnStarted || this.appUpdateDialogVisible ||
      this.coreUpdateDialogVisible) return
    const releaseInfo = this.pendingAppReleaseInfo
    this.pendingAppReleaseInfo = null
    this.appReleaseInfo = releaseInfo
    this.appUpdateDialogVisible = true
    this.isEnableIndexForegroundBlur = true
    void AppReleaseUpdateService.markPrompted(releaseInfo.latestVersion)
    setTimeout((): void => this.appUpdateDialogController.open(), 20)
  }

  private openPendingCoreUpdate(): void {
    if (!this.pendingCoreUpdateInfo || this.isShowWelcome ||
      !ClashViewModel.vpnStarted || this.coreUpdateDialogVisible ||
      this.appUpdateDialogVisible) return
    const releaseInfo = this.pendingCoreUpdateInfo
    this.pendingCoreUpdateInfo = null
    this.coreUpdateInfo = releaseInfo
    this.coreUpdateDialogVisible = true
    this.isEnableIndexForegroundBlur = true
    void CoreUpdateService.markPrompted(releaseInfo.latestVersion)
    // Let ArkUI publish the new release object before the dialog builder reads it.
    setTimeout((): void => this.coreUpdateDialogController.open(), 20)
  }

  // 前往通知设置弹窗
  toDialogController: CustomDialogController = new CustomDialogController({
    builder: theRowCustomDialog({
      theDialogTitle: this.theToDialogTitle,
      contentText: $r('app.string.notice_request_to_settings_text'),
      cancel: ()=> {
        this.uiConfig.Enablednotice = false
      },
      confirm: () => {
        // 跳转至设置界面开启通知权限
        this.context.startAbility({
          bundleName: 'com.huawei.hmos.settings', // 系统设置界面的包名 （固定）
          abilityName: 'com.huawei.hmos.settings.MainAbility', // 系统设置的Ability的名字（固定）
          uri: "application_info_entry", // 系统设置的界面 （固定）
          parameters: {
            pushParams: this.context.applicationInfo.name,
          }
        }).catch(() => {
          console.error(`跳蛛通知权限设置失败`)
        })
      },
      leftButton: this.toNoticeSettingsBuilder
    }),
  })

  /** 获取配置列表 */
  async fetchProfiles(isFirst: boolean = false) {
    const generation = ++this.profilesFetchGeneration
    const startedAt = Date.now()
    console.debug(`Config #fetchProfiles 开始获取配置`)
    let profiles = await ClashViewModel.getProfiles()
    // 真机 RDB 在主从切换/并发查询瞬间可能给出一次空快照。只有再次查询仍为空
    // 才视为真实删除；否则保留当前 UI，避免刷新失败后整栏闪成空白。
    if (profiles.length === 0 && this.configList.length > 0) {
      await new Promise<void>((resolve) => setTimeout(resolve, 120))
      profiles = await ClashViewModel.getProfiles()
      if (profiles.length === 0) {
        await new Promise<void>((resolve) => setTimeout(resolve, 300))
        profiles = await ClashViewModel.getProfiles()
      }
    }
    console.info(`Config #fetchProfiles 配置已获取，数量：${profiles.length}`)
    let nextConfigList = profiles.map((d) => {
      const timeGap = convertMillisecondsToTimeGap(d.autoUpdateDuration)
      return {
        configId: d.id,
        configName: d.name,
        isFavorite: this.favoriteProfiles.has(d.id) ?? false,
        configUrl: d.url,
        sourceType: d.type,
        isConfigAutoUpdate: d.autoUpdate,
        disableUpdate: d.isUpdating,
        configAutoUpdateTimeGapValue: timeGap.value,
        configAutoUpdateTimeGapMs: d.autoUpdateDuration,
        configAutoUpdateTimeGapTextPickerIndex: timeGap.unit,
        lastUpdateDateTime: d.lastUpdateDate,
        subscriptionInfo: d.subscriptionInfo,
        accountProvider: d.accountProvider,
        accountState: d.accountState,
        accountError: d.accountError,
        accountUpdatedAt: d.accountUpdatedAt,
        subscriptionState: d.subscriptionState,
        subscriptionError: d.subscriptionError,
        subscriptionFormat: d.subscriptionFormat,
        subscriptionNodeCount: d.subscriptionNodeCount,
        subscriptionCheckedAt: d.subscriptionCheckedAt,
        subscriptionPendingRepair: d.subscriptionPendingRepair,
        subscriptionRetryAt: d.subscriptionRetryAt,
        lastGoodContentId: d.lastGoodContentId,
        coreLoadState: d.coreLoadState,
        coreLoadedContentId: d.coreLoadedContentId,
        coreLoadedAt: d.coreLoadedAt,
        bitzQuotaEnabled: d.bitzQuotaEnabled,
        bitzQuotaState: d.bitzQuotaState,
        bitzQuotaError: d.bitzQuotaError,
        bitzQuotaUpdatedAt: d.bitzQuotaUpdatedAt
      } as ConfigData
    })
    // 初始化配置项排序列表
    let configSort = await Xb_PreferenceUtil.get<string>('config_sort', '')
    if (!configSort) {
      configSort = JSON.stringify(nextConfigList.map(id => id.configId))
      await Xb_PreferenceUtil.put('config_sort', configSort)
      console.info(`ConfigSort #fetchProfiles Xb_PreferenceUtil config_sort 不存在，进行初始化：${configSort}`)
    } else {
      // 当前的排序表
      nextConfigList = sortByCustomOrder(nextConfigList, JSON.parse(configSort) as string[], 'configId')
    }
    // 多个刷新事件并发时，只允许最新一次完整结果落到 UI，防止较慢的旧查询
    // 在额度刷新完成后又覆盖新卡片。
    if (generation !== this.profilesFetchGeneration) return
    this.configList = nextConfigList
    this.configListLoaded = true
    console.info(`ConfigSort #fetchProfiles Xb_PreferenceUtil config_sort 当前的排序表为，${configSort} 配置列表长度：${this.configList.length}`)
    console.info(`Config #fetchProfiles 首屏读取完成，耗时：${Date.now() - startedAt}ms`)
  }

  onProfileRepoReady(): void {
    if (this.profileRepoReady) {
      this.fetchProfiles(true)
    }
  }

  /**
   *  预留自定义主题，颜色在AppTheme里面修改
   * @param theme
   */
  onWillApplyTheme(theme: Theme) {
    hilog.info(0x1000, componentName, `#onWillApplyTheme`)
    this.icon_emphasize = theme.colors.iconEmphasize;
    // 全局变量同步
    this.themeColor = Xb_ResourceColorUtil(theme.colors.iconEmphasize, this.getUIContext().getHostContext()!)
    // 子模块主题色同步
    Xb_Global.icon_emphasize = theme.colors.iconEmphasize;
    cardManager.pushCartThemeColor(theme.colors.iconEmphasize)
  }

  /**窗口变化监听*/
  onWindowChange(resetNavigation: boolean = true) {
    hilog.info(0xFF00, componentName, `#WindowChange#应用窗口状态 width: ${this.windowWidth} height: ${this.windowHeight} ` + ' tab宽度:' + this.barWidth?.toString())
    // Watch 回调可能在首帧 render 期间执行。NavigationStack 属于组件状态，
    // 此时直接 clear 会触发 “state changed during render”，随后节点页看起来
    // 像是完全点不动。窗口真正变化时仍延迟到下一次任务清理旧路由。
    if (resetNavigation) {
      if (this.navigationResetTimer !== -1) {
        clearTimeout(this.navigationResetTimer)
      }
      this.navigationResetTimer = setTimeout((): void => {
        this.navigationResetTimer = -1
        this.morePageInfos.clear(true)
        if (this.tabCurrentPage === 3) {
          this.pageInfos.clear(true)
        }
      }, 300)
    }
    if (this.windowWidth > 328 || this.windowHeight > 328) {
      if (this.windowHeight === this.windowWidth) {
        hilog.info(0xFF00, componentName,
          `#WindowChange#应用窗口状态 重复执行，跳出`)
        return
      }
    }
    if (320 < this.windowHeight && this.windowHeight <= 500 && 640 < this.windowWidth && this.windowWidth <= 1000) {
      this.isLandscapePhone = true
      hilog.info(0x1000, componentName,
        `#WindowChange#应用窗口状态改变#(320vp< height <= 500vp) and (640vp< width <= 1000vp)手机横屏结果: ${this.isLandscapePhone}`)
    } else if ((640 < this.windowWidth && this.windowWidth < 1000 && 640 < this.windowHeight &&
      this.windowHeight < 1000)) {
      this.isFoldStatus = true
      hilog.info(0xFF00, componentName,
        `#WindowChange#设备折叠状态改变#(640vp< height <= 1000vp) and (640vp< width <= 1000vp)折叠展开结果: ${this.isFoldStatus}`)
    } else if (this.windowWidth > 1000 && this.windowHeight > 530) {
      this.istabletLandscape = true
      hilog.info(0xFF00, componentName,
        `#WindowChange#应用窗口状态改变#(1000vp< width)平板横屏结果: ${this.istabletLandscape}`)
    } else if (328 < this.windowHeight && this.windowHeight < 440 && 328 < this.windowWidth &&
      this.windowWidth <= 440) {
      this.isSmallSquareScreen = true
      hilog.info(0xFF00, componentName,
        `#WindowChange#应用窗口状态改变#(1000vp< width)分屏窗口结果: ${this.isSmallSquareScreen}`)
    } else if (this.windowHeight < 328 && this.windowWidth < 328) {
      this.isPXSecScreen = true
      hilog.info(0xFF00, componentName,
        `#WindowChange#应用窗口状态改变#(328vp< width && 328 < height)PX外屏结果: ${this.isPXSecScreen}`)
    } else {
      this.isLandscapePhone = false
      this.istabletLandscape = false
      this.isSmallSquareScreen = false
      this.isFoldStatus = false
      this.isPXSecScreen = false
      hilog.info(0xFF00, componentName,
        `#WindowChange#设备高度改变，没有命中`)
    }
  }

  async aboutToAppear(): Promise<void> {
    hilog.info(0x1000, componentName, `#aboutToAppear executed`)
    this.registerEvent()

    // 初始化状态栏工具(仅PC设备)
    if (this.windowMode) {
      const iconResource: StatusBarIconResource = {
        white: 'clash_status_white.svg',
        black: 'clash_status_black.svg'
      };
      const statusBarConfig: StatusBarConfig = {
        icon: iconResource,
        title: "entry", // 当前模块的的model-name
        abilityName: '' // 留空，接管并使用默认状态栏图标点击事件
        // menus: [[{
        //   title: "",
        //   menuAction: { abilityName: "" }
        // }]]
      };
      Xb_StatusBarUtils.initStatusBar(this.UIContext, statusBarConfig)
        .then(() => {
          Xb_StatusBarUtils.setIconClickCallback()
        })
        .catch((err: BusinessError) => {
          console.error(`Index #aboutToAppear StatusBarUtils.initStatusBar 状态栏图标初始化失败, Message: ${err.message}`);
        })
    }

    // 首次启动启用通知
    if (!this.uiConfig.isRequestNotification) {
      EventHub.sendEvent(EventKey.EnabledNotice, true)
    }

    // 旧模拟定位/下载保活已下线。VPN 的 dataTransfer 长时任务由启停链自动管理；
    // 画中画只负责显示状态，不再参与后台运行总开关。
    this.uiConfig.Enablebackgrounder = false
    this.uiConfig.backgroundLocateModel = false
    this.uiConfig.backgroundDownModel = false
    this.uiConfig.backgroundKeepTask = false

    // 分享包名
    const localStorage = this.getUIContext().getSharedLocalStorage()
    const bundleInfo = localStorage?.get<BundleInfo>('bundleInfo') || new BundleInfo()
    // 首帧阶段只建立 Navigation；导航栈的 clear/push 必须放到 render 之后，
    // 否则冷启动会出现 pageInfos/morePageInfos changed during render，进而
    // 让节点切换页的触摸命中树失效。
    setTimeout((): void => {
      this.onWindowChange(false)
      if (BundleInfo.isEmpty(bundleInfo)) {
        this.jumpAccessControl(bundleInfo)
      }
      // 除手机外更多页均默认跳转覆写
      if (this.widthBp > 1) {
        this.morePageInfos.pushPathByName('overwrite', null, false)
      }
    }, 500)
    // 启动时检查上一次是否崩溃
    if (AppStorage.get<boolean>('crash') === true && !this.uiConfig.isFirstStart) {
      hilog.info(0x1000, componentName, `进入崩溃日志`)
      this.isShowWelcome = true
    }
    // 首次启动打开欢迎页
    if (this.uiConfig.isFirstStart) {
      this.isShowWelcome = true
    }
    // 在页面build前改变主题颜色
    Xb_ChangeThemeColor(this.uiConfig.themeColor)
    hilog.info(0x1000, componentName, `#aboutToAppear#ThemeControl.setDefaultTheme(${this.uiConfig.themeColor})`)
    // 初始化切换颜色模式(深色模式)
    Xb_ColorModeManager.setThemeColorMode(this.context, this.uiConfig.darkMode)
    // 初始化切换按钮位置
    this.switchButtonPosition(this.uiConfig.buttonPositionIndex)

    // 检查版本更新
    /* if (this.uiConfig.autoCheckUpdate) {
       try {
         const updateInfo = await getUpdateInfo()
         hilog.info(0xFF00, "UpdatetestTag", "Update Info: %{public}s", JSON.stringify(updateInfo))
         const theLatest = extractUpdateInfo(updateInfo)
         if (theLatest) {
           // 查询完成
           if (compareVersions(theLatest.tag_name, AppState.versionName)) {
             this.theAppVersionInfo = theLatest
             this.isDisclaimer = false
             this.dialogController.open()
           }
         } else {
           hilog.info(0xFF00, "UpdatetestTag", "提取更新信息失败")
         }
       } catch (err) {
         // 处理错误情况
         const infoError = `Error:${JSON.stringify(err)}`
         hilog.info(0xFF00, "UpdatetestTag", "Info: %{public}s", infoError)
       }
     }*/

    // if(!this.uiConfig.enabledADvanced || !this.uiConfig.isShowExperimentalFunction) {
    //   // 屏蔽分流策略
    //   this.moreList = removeItemsByIndex(this.moreList, [5])
    // }
    // if(this.appConfig.clashCore !== ClashCore.mihomo) {
    //   // 屏蔽请求与连接
    //   this.moreList = removeItemsByIndex(this.moreList, [2,3])
    // }

    // 根据设备选择性开启change监听
    /*if (deviceInfo.deviceType === 'phone') {
      this.deviceHeightListener.on('change', (mediaQueryResult: mediaquery.MediaQueryResult) => {
        this.isLandscapePhone = mediaQueryResult.matches
        AppStorage.setOrCreate<boolean>('isLandscapePhone', this.isLandscapePhone)
        hilog.info(0x1000, componentName,
          `#媒体查询#设备高度改变#(320vp< height <= 500vp) and (640vp< width <= 1000vp)手机横屏结果: ${this.isLandscapePhone}`)
      })
    }*/

    this.colorModeListener.on('change', (mediaQueryResult: mediaquery.MediaQueryResult) => {
      this.currentColorMode = mediaQueryResult.matches
      // hilog.debug(0x1000, 'Index', `#媒体查询 #深色模式: ${this.currentColorMode}`)
    })

    // 配置 RDB 可能在页面出现前就已就绪，也可能稍后通过 Watch 通知。
    // 两条路径都只等待数据库，不再被内核、VPN 或网络任务阻塞。
    if (this.profileRepoReady) {
      await this.fetchProfiles(true)
    }

    // 初始化实况窗
/*    const isLive = await LiveViewUtil.init(this.getUIContext().getHostContext()!)
    if (isLive) {
      console.log(`LiveViewUtil 实况窗初始化成功`)
    } else {
      console.error(`LiveViewUtil 实况窗初始化失败`)
    }*/

    // 更新应用版本号
    const packageInfo = await getPackageInfo()
    AppState.versionCode = packageInfo.versionCode
    AppState.versionName = packageInfo.versionName
    console.error(`Update 历史应用版本：${this.uiConfig.oldVersionCode} 当前应用版本：${AppState.versionCode}`)

    if (this.uiConfig.oldVersionCode !== AppState.versionCode) {
      this.isEnableIndexForegroundBlur = true
      this.isShowWelcome = true
      this.updateData()   // TODO 强制更新数据函数
    }

    Xb_AnimationStyle.setContext(this.UIContext)
    if (this.apiVersionEnable) {
      // 需要确保兼容最低API版本(17)
      holdingHandleUtil.setContext(this.UIContext)
    }
  }

  /** @description 统一注册事件 */
  registerEvent() {
    AppStorage.setOrCreate('isCheckIpInfo', false)
    AppStorage.setOrCreate('ipCheckError', '')
    AppStorage.setOrCreate('ipPureScore', -1)
    AppStorage.setOrCreate('cloudflareScore', -1)
    AppStorage.setOrCreate('platformCheckState', 'idle')
    AppStorage.setOrCreate('platformCheckSummary', '等待检测')
    AppStorage.setOrCreate('platformCheckResults', '[]')
    AppStorage.setOrCreate('platformCheckNode', '')
    AppStorage.setOrCreate('platformCheckAt', 0)
    AppStorage.setOrCreate('platformCheckRunning', false)
    AppStorage.setOrCreate('platformCheckPending', false)
    AppStorage.setOrCreate('nodeQualityTestRunning', false)
    AppStorage.setOrCreate('nodeQualityTestProgress', '0/0')
    AppStorage.setOrCreate('nodeQualityRevision', 0)
    AppStorage.setOrCreate('nodeQualitySortRevision', 0)
    AppStorage.setOrCreate('nodeQualityNetworkRefreshPending', false)
    EventHub.on(EventKey.checkIpInfo, (data?: Record<string, boolean>) => {
      if (AppStorage.get<boolean>('nodeQualityTestRunning') === true) {
        AppStorage.setOrCreate('nodeQualityNetworkRefreshPending', true)
        return
      }
      this.refreshIpPureInfo()
      // 普通网络/节点变化只跑轻量入口探测；用户在平台检测窗口点击
      // “一键测试”时传 deep=true，才执行上传、会话、媒体和长连接全链路。
      this.refreshPlatformConnectivity(data?.force === true, data?.deep === true)
    })
    // 通知事件
    EventHub.on(EventKey.EnabledNotice, async (enadblNotice: boolean) => {
      try {
        // 先获取最新权限状态
        const currentStatus = await notificationManager.isNotificationEnabled()
        if (currentStatus) {
          // 已有权限时
          // 显示通知设置 显式动画
          this.uiConfig.Enablednotice = enadblNotice ?? true
        } else {
          // 没有授权时
          if (!this.uiConfig.isRequestNotification) {
            // 首次请求权限
            try {
              await notificationManager.requestEnableNotification(this.context)
              this.uiConfig.isRequestNotification = true
              this.uiConfig.Enablednotice = true
            } catch (err) {
              if ((err as BusinessError).code === 1600004) {
                hilog.error(0xFF00, 'Index-Notice', '用户拒绝授权')
                // 关闭总通知
                this.uiConfig.Enablednotice = false
                // 关闭模拟下载
                this.uiConfig.backgroundDownModel = false
                // 标记已经请求过授权
                this.uiConfig.isRequestNotification = true
                this.promptAction.showToast({ message: $r('app.string.enable_notice_failed') })
              }
            }
          } else {
            // 已请求过权限且通知开关未启用，进入跳转设置
            if(!this.uiConfig.Enablednotice) {
              this.toDialogController.open()
            }
          }
        }
      } catch (err) {
        hilog.error(0xFF00, 'Index', `Toggle Error: ${(err as BusinessError).code}, ${(err as BusinessError).message}`);
      }
    })
    const appFlowingState = AppStorage.get<AppFlowingState>("appFlowingState") ?? new AppFlowingState()
    // 启动Clash后
    EventHub.on(EventKey.StartedClash, () => {
      // 自动恢复、访问控制重启与手动启动都从同一事件同步按钮，避免实际
      // TUN 已运行但悬浮按钮仍显示“播放”。
      this.proxyEnabled = true
      const job = async () => {
        const onlyProxy = AppStorage.get<ClashConfig>("clashConfig")?.['only-proxy'] as boolean ?? true
        hilog.info(0xFF00, "EntryAbilityTestTag", 'onlyProxy: %{public}s', onlyProxy)
        const now = await ClashViewModel.getTraffic(onlyProxy)
        const total = await ClashViewModel.getTotalTraffic(onlyProxy)
        appFlowingState.traffics.enqueue(now)
        appFlowingState.totalTraffic = total
        BackgroundDownService.updateTraffic(
          this.appConfig.currentProxyName ?? '代理节点',
          now.up?.toString() ?? '0 B',
          now.down?.toString() ?? '0 B',
          this.uiConfig.EnabledPermanentnotice)
      }
      job()
      this.trafficJob = setInterval(job, 1000)
      // TODO 卡片后台启动服务后拉起应用关闭再开启会出现一秒的时间显示错误
      this.proxyStartingDuration = PROXY_STARTED_DURATION_INIT_VALUE
      // 核心和 mixed 端口完全就绪后自动执行平台真实动作检测。
      // 给首个真实应用请求让出刚建立的隧道。自动检测本身是轻量入口探测，
      // 完整链路只在用户主动点击时执行。
      if (this.startedConnectivityRefreshTimer !== -1) {
        clearTimeout(this.startedConnectivityRefreshTimer)
      }
      this.startedConnectivityRefreshTimer = setTimeout((): void => {
        this.startedConnectivityRefreshTimer = -1
        if (ClashViewModel.vpnStarted && this.isForward) {
          EventHub.sendEvent(EventKey.checkIpInfo, { force: true, deep: false })
        }
      }, 8000)
      this.scheduleCoreUpdateCheck()
      // VPN 启动链已无条件申请 dataTransfer 长时任务。不再叠加模拟
      // 定位/模拟下载，避免多个长时任务争用同一 UIAbility。
    })
    // 停止Clash后
    EventHub.on(EventKey.StopedClash, () => {
      this.proxyEnabled = false
      if (this.startedConnectivityRefreshTimer !== -1) {
        clearTimeout(this.startedConnectivityRefreshTimer)
        this.startedConnectivityRefreshTimer = -1
      }
      clearTimeout(this.coreUpdateCheckTimer)
      // dataTransfer 长时任务已由 ClashViewModel.StopVpn 与 TUN 同步停止。
      clearInterval(this.trafficJob)
      // 代理计时器重置
      this.proxyStartingDuration = ''
      // 速度卡片重置
      this.DownloadSpeed = ''
      this.UploadSpeed = ''
      this.ChartData = CHART_NUMBER
      EventHub.sendEvent(EventKey.checkIpInfo)
    })
    // 代理时长
    EventHub.on(EventKey.ProxyDuration, (time:number) => {
      this.proxyTime = time
      this.proxyStartingDuration = number2Time(time)
    })
    // 热启动 -> 通过事件监听触发
    EventHub.on(EventKey.ShareBundle, (bundleInfo: BundleInfo) => {
      this.jumpAccessControl(bundleInfo)
    })
    // 日志启用事件
    EventHub.on(EventKey.StartLog, async (enable: boolean) => {
      ClashViewModel.startLog(enable, (log) => {
        this.logListData.push({
          logType: log.logLevel,
          logTime: log.time,
          LogDetails: log.payload,
          logSkip: log.payload.length > 30
        })
      })
    })
    // 获取代理分组事件
    EventHub.on(EventKey.FetchProxyGroup, async () => {
      const generation = ++this.proxyFetchGeneration
      const requestedProfileId = this.appConfig.currentProfileId
      const requestedMode = this.clashConfig.mode ?? ProxyMode.Rule
      if (!requestedProfileId) {
        this.currentProfile = null
        this.currentProxyIndex = 0
        this.proxyGroups.replaceData([])
        return
      }
      const previousProfileId = this.currentProfile?.id ?? ''
      const previousGroupName = this.proxyGroups.getData(this.currentProxyIndex)?.name ?? ''
      const profile = await ClashViewModel.getProfile(requestedProfileId)
      if (generation !== this.proxyFetchGeneration ||
        requestedProfileId !== this.appConfig.currentProfileId ||
        requestedMode !== (this.clashConfig.mode ?? ProxyMode.Rule)) {
        hilog.info(0xB000, 'ProxyGroupRefresh',
          `丢弃过期配置查询 generation=${generation}, profileId=${requestedProfileId}`)
        return
      }
      if (!profile) {
        hilog.warn(0xB000, 'ProxyGroupRefresh',
          `配置记录暂不可用，保留上一份节点快照 profileId=${requestedProfileId}`)
        return
      }
      const rawProxyGroups = await ClashViewModel.getProxyGroups(requestedMode)
      if (generation !== this.proxyFetchGeneration ||
        requestedProfileId !== this.appConfig.currentProfileId ||
        requestedMode !== (this.clashConfig.mode ?? ProxyMode.Rule)) {
        hilog.info(0xB000, 'ProxyGroupRefresh',
          `丢弃过期核心查询 generation=${generation}, profileId=${requestedProfileId}`)
        return
      }
      const visibleGroups = rawProxyGroups.filter((item: ProxyGroup): boolean => item.hidden !== true)
      if (visibleGroups.length === 0) {
        hilog.warn(0xB000, 'ProxyGroupRefresh',
          `核心查询为空，保留上一份节点快照 profileId=${requestedProfileId}, mode=${requestedMode}`)
        return
      }

      const profileChanged = previousProfileId !== requestedProfileId
      let targetIndex = visibleGroups.findIndex((group: ProxyGroup): boolean =>
        group.name === profile.currentGroupName)
      if (!profileChanged && previousGroupName) {
        const previousIndex = visibleGroups.findIndex((group: ProxyGroup): boolean =>
          group.name === previousGroupName)
        if (previousIndex >= 0) targetIndex = previousIndex
      }
      if (targetIndex < 0) {
        targetIndex = visibleGroups.findIndex((group: ProxyGroup): boolean =>
          group.type === ProxyType.Selector)
      }
      if (targetIndex < 0 || targetIndex >= visibleGroups.length) targetIndex = 0
      this.currentProfile = profile
      this.currentProxyIndex = targetIndex
      this.proxyGroups.replaceData(visibleGroups)

      const nodeCount = visibleGroups.reduce((total: number, group: ProxyGroup): number =>
        total + group.proxies.length, 0)
      hilog.info(0xB000, 'ProxyGroupRefresh',
        `代理组快照已原子替换 generation=${generation}, groups=${visibleGroups.length}, nodes=${nodeCount}, index=${targetIndex}`)
      const selectedGroup = visibleGroups[targetIndex]
      const selectedName = profile.getSelectedProxy(selectedGroup)
      const selectedItem = selectedGroup.proxies.find((item) => item.name === selectedName) as ProxyItem
      if (selectedItem) {
        this.appConfig.currentProxyName = selectedItem.name
        this.appConfig.currentProxyItem = selectedItem
      } else {
        this.appConfig.currentProxyName = selectedName
        this.appConfig.currentProxyItem = undefined
      }
    })
    // 清理日志事件
    EventHub.on(EventKey.ClearLog, () => {
      this.logListData = []
    })
    // 导出日志事件
    EventHub.on(EventKey.ExportLog, (LogData?: LogData) => {
      try {
        let filePicker = new picker.DocumentViewPicker(this.context)
        let options = new picker.DocumentSaveOptions()
        options.newFileNames = LogData ? [`clash_next_${LogData.logTime}_${Date.now()}.log`] : ["clash_next.log"]
        options.fileSuffixChoices = ["'文档|.txt'"]
        options.pickerMode = picker.DocumentPickerMode.DOWNLOAD
        filePicker.save(options).then(async (result) => {
          const path = new fileUri.FileUri(result[0] + '/' +
            `clash_next${LogData ? '_' + LogData.logTime + '_' + Date.now() : ''}.txt`).path
          await this.saveLog(path, LogData)
        }).catch((e: Error) => {
          hilog.debug(0xFF00, 'ExportLog', 'err： ', e)
        })
      } catch (e) {
        hilog.info(0xFF00, "ExportLog", "err %{public}s", e)
      }

    })
    // 注册配置加载事件
    EventHub.on(EventKey.FetchProfile, async () => {
      this.fetchProfiles()
    })
    console.log(`ConfigSort EventKey.FetchProfile on 获取配置信息事件已注册`)
    // 注册配置详情加载事件
    EventHub.on(EventKey.LoadConfigStr, () => {
      const context = this.getUIContext().getHostContext()!
      const sandPath = context.filesDir + `/ClashBox/profiles/` + this.currentTouchConfigData.configId + '/config.yaml'
      const sandUri = fileUri.getUriFromPath(sandPath)
      try {
        const file = fs.openSync(sandUri, fs.OpenMode.READ_ONLY);
        try {
          console.log('#EditConfigContent.loadConfigContent file fd:', file.fd);
          const stats = fs.statSync(file.path);
          const fileSize = stats.size;
          console.log('#EditConfigContent.loadConfigContentile fileSize:', fileSize);
          let buffer = new ArrayBuffer(fileSize);
          const readOptions: ReadOptions = {
            offset: 0,
            length: fileSize
          };
          console.log('#EditConfigContent.loadConfigContent readOptions:', JSON.stringify(readOptions));
          fs.readSync(file.fd, buffer, readOptions);
          let textDecoder = util.TextDecoder.create("UTF-8", { ignoreBOM: false });
          this.configStr = textDecoder.decodeToString(new Uint8Array(buffer));
          console.debug(`读取配置内容完成，长度：${this.configStr.length}`)
        } catch (err) {
          console.error(`读取配置文件失败，name: ${err.name} message: ${err.message}`)
        } finally {
          // 关闭文件
          fs.closeSync(file)
        }
      } catch (error) {
        console.error(`打开配置文件失败，name: ${error.name} message: ${error.message}`)
      }
    })
    // 注册监听切换按钮位置事件
    EventHub.on(EventKey.SwitchButtonPosition, (buttonPositionIndex: number) => {
      this.getUIContext().animateTo(this.uiConfig.isAnimation ?
        { duration: this.uiConfig.animationSpeed, curve: curves.springMotion() } : null,
        () => {
          this.switchButtonPosition(buttonPositionIndex)
        })
    })
  }

  aboutToDisappear() {
    hilog.info(0x1000, componentName, `#aboutToDisappear executed`)
    clearTimeout(this.coreUpdateCheckTimer)
    // 统一注销根目录事件
    EventHub.off(EventKey.FetchProfile)
    EventHub.off(EventKey.FetchProxyGroup)
    // 纪录软件关闭时间
    this.uiConfig.useTime = new Date().getTime()
    // 解注册画中画生命周期及状态回调
    PipManager.getInstance().unregisterPipStateChangeListener()
    this.unRegisterEvent()
    // 解绑listener中注册的回调函数
    // this.deviceHeightListener.off('change');
    Xb_KVdbUtil.closeKVStore().catch((err: BusinessError) => {
      console.error(`KvDb #aboutToDisappear Xb_KVdbUtil.closeKVStore() 失败，message，${err.message}`)
    })
  }

  /** @description 统一取消监听事件 */
  unRegisterEvent() {
    if (this.startedConnectivityRefreshTimer !== -1) {
      clearTimeout(this.startedConnectivityRefreshTimer)
      this.startedConnectivityRefreshTimer = -1
    }
    EventHub.off(EventKey.checkIpInfo)
    EventHub.off(EventKey.ChangeProxy)
    EventHub.off(EventKey.FetchProxyGroup)
    EventHub.off(EventKey.ShareBundle)
    EventHub.off(EventKey.EnabledNotice)
    EventHub.off(EventKey.StopedClash)
    EventHub.off(EventKey.StartedClash)
    EventHub.off(EventKey.ExportLog)
    EventHub.off(EventKey.ClearLog)
    EventHub.off(EventKey.StartLog)
    EventHub.off(EventKey.LoadConfigStr)
    EventHub.off(EventKey.SwitchButtonPosition)
  }

  /**
   * 平台检测与 IPPure 使用同一组节点/配置/网络变化事件。重复事件会在 15 秒
   * 内合并；检测期间若出口再次变化，则丢弃旧结果并立即补跑最新节点。
   */
  private async refreshPlatformConnectivity(force: boolean = false, deep: boolean = false): Promise<void> {
    if (!ClashViewModel.vpnStarted) {
      AppStorage.setOrCreate('platformCheckState', 'inactive')
      AppStorage.setOrCreate('platformCheckSummary', '代理未连接')
      AppStorage.setOrCreate('platformCheckResults', '[]')
      AppStorage.setOrCreate('platformCheckNode', '')
      AppStorage.setOrCreate('platformCheckAt', Date.now())
      return
    }
    const nodeName = this.appConfig.currentProxyName ?? this.appConfig.currentProxyItem?.name ?? ''
    const previousNode = AppStorage.get<string>('platformCheckNode') ?? ''
    const previousAt = AppStorage.get<number>('platformCheckAt') ?? 0
    if (!force && AppStorage.get<boolean>('platformCheckRunning') !== true &&
      nodeName === previousNode && Date.now() - previousAt < 15000) {
      return
    }
    if (AppStorage.get<boolean>('platformCheckRunning') === true) {
      AppStorage.setOrCreate('platformCheckPending', true)
      return
    }
    AppStorage.setOrCreate('platformCheckRunning', true)
    try {
      do {
        AppStorage.setOrCreate('platformCheckPending', false)
        if (!ClashViewModel.vpnStarted) {
          AppStorage.setOrCreate('platformCheckState', 'inactive')
          AppStorage.setOrCreate('platformCheckSummary', '代理未连接')
          AppStorage.setOrCreate('platformCheckResults', '[]')
          break
        }
        const testingNode = this.appConfig.currentProxyName ?? this.appConfig.currentProxyItem?.name ?? ''
        AppStorage.setOrCreate('platformCheckState', 'testing')
        AppStorage.setOrCreate('platformCheckSummary', `正在检测 0/${PLATFORM_TARGETS.length}`)
        // 新一轮开始时立即移除上一轮结果，避免旧节点/旧测速数据被误认为本轮结果。
        AppStorage.setOrCreate('platformCheckResults', '[]')
        AppStorage.setOrCreate('platformCheckNode', testingNode)
        try {
          const mixedPort = Number(this.clashConfig['mixed-port'] ?? 7890)
          const tester = deep ? PlatformConnectivityService.testAll : PlatformConnectivityService.testQuick
          const results = await tester(true, mixedPort,
            (partialResults: PlatformConnectivityResult[], completed: number, total: number): void => {
              const currentNode = this.appConfig.currentProxyName ?? this.appConfig.currentProxyItem?.name ?? ''
              if (!ClashViewModel.vpnStarted || currentNode !== testingNode ||
                AppStorage.get<boolean>('platformCheckPending') === true) {
                return
              }
              AppStorage.setOrCreate('platformCheckResults', JSON.stringify(partialResults))
              AppStorage.setOrCreate('platformCheckSummary', `正在检测 ${completed}/${total}`)
            })
          const currentNode = this.appConfig.currentProxyName ?? this.appConfig.currentProxyItem?.name ?? ''
          if (!ClashViewModel.vpnStarted || currentNode !== testingNode) {
            AppStorage.setOrCreate('platformCheckPending', true)
            continue
          }
          AppStorage.setOrCreate('platformCheckResults', JSON.stringify(results))
          AppStorage.setOrCreate('platformCheckState', PlatformConnectivityService.overallQuality(results))
          AppStorage.setOrCreate('platformCheckSummary', PlatformConnectivityService.overallSummary(results))
          AppStorage.setOrCreate('platformCheckNode', testingNode)
          AppStorage.setOrCreate('platformCheckAt', Date.now())
        } catch (error) {
          const reason = (error as Error).message || '平台检测失败'
          AppStorage.setOrCreate('platformCheckState', 'error')
          AppStorage.setOrCreate('platformCheckSummary', reason)
          AppStorage.setOrCreate('platformCheckResults', '[]')
          AppStorage.setOrCreate('platformCheckAt', Date.now())
          hilog.warn(0xA020, 'PlatformTest', `自动平台检测失败: ${reason}`)
        }
      } while (AppStorage.get<boolean>('platformCheckPending') === true)
    } finally {
      AppStorage.setOrCreate('platformCheckRunning', false)
    }
  }

  /**
   * IPPure 刷新统一由根页面串行执行。刷新过程中再次收到网络/节点变化时，
   * 记录 pending 并在当前请求结束后立刻补跑一次，保证最终显示最新出口。
   */
  private async refreshIpPureInfo(): Promise<void> {
    if (AppStorage.get<boolean>('isCheckIpInfo') === true) {
      AppStorage.setOrCreate('ipCheckPending', true)
      return
    }
    AppStorage.setOrCreate('isCheckIpInfo', true)
    try {
      do {
        AppStorage.setOrCreate('ipCheckPending', false)
        // 网络、配置或节点已经变化时，旧出口立即失效。先清空所有可见字段，
        // 让卡片在本次请求完成前只显示加载态；若请求失败则保留明确错误态，
        // 绝不把上一节点的国家、IP 或风险系数冒充成当前结果。
        this.remoteIp = null
        this.ipDisplayAddress = ''
        this.ipDisplayLocation = ''
        this.ipDisplaySource = ''
        this.ipDisplayProperty = ''
        this.ipPureScore = -1
        this.cloudflareScore = -1
        AppStorage.setOrCreate('ipCheckError', '')
        try {
          const next = await ClashViewModel.checkIpInfo()
          if (next.ip) {
            this.remoteIp = next
            // Assign every visible field independently and in one UI turn. Some
            // system versions update the original class's required fields but
            // leave optional fields at their previous values.
            this.ipDisplayAddress = next.ip
            this.ipDisplayLocation = next.location ?? next.country ?? ''
            this.ipDisplaySource = next.ipSource ?? '未知'
            this.ipDisplayProperty = next.ipProperty ?? '未知'
            this.ipPureScore = next.ipPureScore ?? -1
            this.cloudflareScore = next.cloudflareScore ?? -1
            hilog.info(0xC031, 'IPPureUI',
              `更新卡片 ip=${this.ipDisplayAddress} source=${this.ipDisplaySource} ` +
              `property=${this.ipDisplayProperty} ippure=${this.ipPureScore} cloudflare=${this.cloudflareScore}`)
            cardManager.pushCartProxyIpInfo(next)
            AppStorage.setOrCreate('ipCheckError', next.qualityError ?? '')
          }
        } catch (error) {
          const reason = (error as Error).message || 'IPPure 请求失败'
          // 再次归零可防止系统在异步请求期间恢复了旧的可观察对象字段。
          this.remoteIp = null
          this.ipDisplayAddress = ''
          this.ipDisplayLocation = ''
          this.ipDisplaySource = ''
          this.ipDisplayProperty = ''
          this.ipPureScore = -1
          this.cloudflareScore = -1
          AppStorage.setOrCreate('ipCheckError', reason)
          hilog.warn(0xC031, 'IPPure', `出口信息刷新失败: ${reason}`)
        }
      } while (AppStorage.get<boolean>('ipCheckPending') === true)
    } finally {
      AppStorage.setOrCreate('isCheckIpInfo', false)
    }
  }

  // 更新后强化赋值一次
  async updateData() {
    if (this.clashConfig.tun && this.clashConfig.tun['tun-ip']) {
      this.clashConfig.tun['tun-ip'] = '172.19.0.1/30'
    }
    const type = getJsonArrayType(this.uiConfig.isShowHomeCard)
    if (type === 'boolean') {
      const str = this.uiConfig.isShowHomeCard
      // 转化字符串
      this.uiConfig.isShowHomeCard = filterStringsByBooleans(str, 'string') as string
      this.theCurrentHomeCard = filterStringsByBooleans(str, 'array') as string[]
    } else if (typeof type == 'undefined') {
      this.uiConfig.isShowHomeCard = JSON.stringify(showHomeCard)
    }
    if (typeof this.uiConfig.editWordWrap != 'boolean') {
      this.uiConfig.editWordWrap = true
    }
    // 确保tabStyle有值
    if (!this.uiConfig.tabStyle) {
      this.uiConfig.tabStyle = 'custom'
    }
    if (this.uiConfig.isHoldingHand === undefined) {
      this.uiConfig.isHoldingHand = false
    }
    if (this.uiConfig.isFloatButtonVisible === undefined) {
      this.uiConfig.isFloatButtonVisible = true
    }

    setTimeout(async () => {
      // 等待 PreferenceUtil 完成初始化后，更新访问控制数据
      console.log(`AccessControl Index #updateData 准备数据迁移`)

      // 读取旧版应用列表
      const appsString = await Xb_PreferenceUtil.get<string>('access_control_apps', "[]")
      let currentApps = JSON.parse(appsString) as AppInfo[]
      let finalAppsString = appsString

      // 处理“列表为空”的情况
      if (currentApps.length === 0) {
        console.log(`AccessControl Index #updateData 列表为空...`)
        // 注入默认应用列表到 Preference
        if (this.appConfig.accessControlAppInfo) {
          await Xb_PreferenceUtil.put('access_control_apps', this.appConfig.accessControlAppInfo)
          finalAppsString = this.appConfig.accessControlAppInfo
        }
        // 注入默认黑白名单到 KVStore (兼容层逻辑)
        const defaultAcceptList = this.appConfig.accessControlAcceptList || "[]"
        const defaultRejectList = this.appConfig.accessControlRejectList || "[]"
        if (defaultAcceptList !== "[]" || defaultRejectList !== "[]") {
          const currentAcceptEntries = await Xb_KVdbUtil.getEntriesByPrefix('accept_');
          const currentRejectEntries = await Xb_KVdbUtil.getEntriesByPrefix('reject_');
          const currentAcceptSet = new Set(currentAcceptEntries.map(entry => entry.key.substring('accept_'.length)));
          const currentRejectSet = new Set(currentRejectEntries.map(entry => entry.key.substring('reject_'.length)));
          // 计算并合并差异
          const mergeResult = AccessControlCompatibleMerger.calculateMergeDifferences(
            currentAcceptSet,
            currentRejectSet,
            defaultAcceptList,
            defaultRejectList
          );
          if (mergeResult.keysToDelete.length > 0) {
            await Xb_KVdbUtil.deleteKeysBatch(mergeResult.keysToDelete);
          }
          if (mergeResult.entriesToAdd.length > 0) {
            await Xb_KVdbUtil.putEntriesBatch(mergeResult.entriesToAdd);
          }
        }
      }

      // 读取最终的旧版黑白名单状态
      const finalAcceptEntries = await Xb_KVdbUtil.getEntriesByPrefix('accept_');
      const finalRejectEntries = await Xb_KVdbUtil.getEntriesByPrefix('reject_');

      // 执行迁移到新数据库 RDB
      // 只要 Preference 或 KVStore 中有任意数据，就执行迁移
      if (finalAppsString !== "[]" || finalAcceptEntries.length > 0 || finalRejectEntries.length > 0) {
        console.log(`AccessControl Index #updateData 检测到旧数据，开始迁移到 RDB...`)
        try {
          await accessControlRdb.migrateFromOldStorage(
            finalAppsString,
            finalAcceptEntries,
            finalRejectEntries,
            this.appConfig.accessControlMode == 'AcceptSelected' ? ListType.WHITE_UNSELECTED : ListType.BLACK_UNSELECTED
          )
          console.log(`AccessControl Index #updateData 迁移完成`)
        } catch (e) {
          console.error(`AccessControl Index #updateData 迁移失败: ${JSON.stringify(e)}`)
        }
      } else {
        console.log(`AccessControl Index #updateData 无旧数据，跳过迁移`)
      }
    }, 3000)

  }

  async saveLog(uri: string, logDdata?: LogData): Promise<void> {
    try {
      const file = fs.openSync(uri, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      // 生成日志内容
      const message = logDdata ?
        [logDdata].map((d) => d.logType + " " + timestampToDateTime(d.logTime * 1000) + "\n" + d.LogDetails)
          .join("\n") :
        this.logListData.map((d) => d.logType + " " + timestampToDateTime(d.logTime * 1000) + "\n" + d.LogDetails)
          .join("\n")
      // hilog.info(0xFF00, "ExportLog", "保存内容: %{public}s", message)
      fs.writeSync(file.fd, message);
      fs.fsync(file.fd);
      this.promptAction.showToast({ message: $r('app.string.saved_download') })
    } catch (e) {
      this.promptAction.showToast({
        message: `${getResourceString($r('app.string.export_failed'), this)} ${e.message}`,
        duration: 3000
      })
      hilog.info(0xFF00, "ExportLog", "Err: %{public}s", e.message)
    }
  }

  /**
   * 分流模式选择数据变化监控
   */
  async switchMode() {
    this.proxyGroups.refresh()
  }

  /**
   * 画中画根据代理启动和后台按钮监听是否开启
   */
  ShowPipChange() {
    if (deviceInfo.deviceType === 'tablet') {
      PipManager.getInstance().updateContentSize(80, 30)
    }
    if (this.uiConfig.backgroundPiPModel && this.proxyEnabled) {
      // 创建画中画控制器
      PipManager.getInstance().init(this.context)
      // 禁用自动启用
      PipManager.getInstance().setAutoStart(true)
      hilog.info(0xFF00, "PipTag", "代理启用状态： %{public}s", this.proxyEnabled)
      hilog.info(0xFF00, "PipTag", "画中画启用状态： %{public}s", this.uiConfig.backgroundPiPModel)
    } else {
      PipManager.getInstance().setAutoStart(false)
    }
  }

  onPageShow(): void {
    hilog.info(0xFF00, "TimertestTag", "#onPageShow")
    hilog.info(0xFF00, "PoptestTag", "startPop: %{public}d", this.uiConfig.ShowStartPop)
    hilog.info(0x0000, 'WindowLog #Index', '窗口顶部避让高度：%{public}d', px2vp(this.topRectHeight))
    if (this.proxyEnabled) {
      this.theRestoreTime = new Date().getTime()
      hilog.info(0xFF00, "TimertestTag", "恢复的时刻： %{public}d", this.theRestoreTime)
    }
    this.proxyEnabled = ClashViewModel.vpnStarted
    console.log(`HomeCard 前后台状态：${this.isForward}`)
    this.ShowPipChange()
    this.initLanguage()
    PipManager.getInstance().stopPip()
    hilog.info(0x1000, componentName, `#aboutToAppear#Language 用户选择语言：${this.uiConfig.userLanguage}`)
    hilog.info(0x1000, componentName,
      `#aboutToAppear#Language 当前语言文本：${getResourceString(this.currentLanguage, this)}`)
    hilog.info(0x1000, componentName,
      `#aboutToAppear#Language 当前系统语言文本：${getResourceString(this.SystemLanguageSubtitle, this)}`)
    this.onOpenConfigLink()
    holdingHandleUtil.start()
  }

  /**通过AppLink导入配置*/
  onOpenConfigLink() {
    // 赋值配置链接
    if (this.appLinkConfigUrl != '') {
      this.currentTouchConfigData.isNewConfig = true
      this.currentTouchConfigData.disableUpdate = false
      this.currentTouchConfigData.isConfigAutoUpdate = false
      this.currentTouchConfigData.configUrl = this.appLinkConfigUrl
      this.isShowWelcome = true
    }
    // 赋值配置名称
    if ( this.appLinkConfigName != '') {
      this.currentTouchConfigData.configName = this.appLinkConfigName
    }
  }

  onPageHide(): void {
    PipManager.getInstance().setAutoStart(true)
    hilog.info(0xFF00, "TimertestTag", "#onPageHide")
    if (this.proxyEnabled) {
      this.thePauseTime = new Date().getTime()
      hilog.info(0xFF00, "TimertestTag", "暂停的时刻： %{public}d", this.thePauseTime)
    }
    console.log(`HomeCard 前后台状态：${this.isForward}`)
    hilog.info(0xFF00, "PipTag", "代理启用状态： %{public}s", this.proxyEnabled)
    hilog.info(0xFF00, "PipTag", "画中画启用状态： %{public}s", this.uiConfig.backgroundPiPModel)
    this.ShowPipChange()
    holdingHandleUtil.stop()
  }

  /**初始化应用语言*/
  initLanguage() {
    const systemLanguage = i18n.System.getSystemLanguage()
    let currentLanguage = ''
    if (this.uiConfig.userLanguage !== 'default') {
      currentLanguage = this.uiConfig.userLanguage
      ChangeLanguage(this.uiConfig.userLanguage)
    } else {
      currentLanguage = systemLanguage
      ChangeLanguage(systemLanguage)
    }
    // 初始化当前语言显示
    switch (currentLanguage) {
      case 'zh-Hans-CN':
      case 'zh-Hans':
        this.currentLanguage = $r('app.string.Language_Subtitle')
        break
      case 'en-Latn-US':
      case 'en-Latn':
        this.currentLanguage = $r('app.string.English_Subtitle')
        break
      case 'zh-Hant-HK':
      case 'zh-Hant':
      case 'zh-HK':
        this.currentLanguage = $r('app.string.TraditionalChinese_HK_Subtitle')
        break
      case 'zh-Hant-TW':
      case 'zh-TW':
        this.currentLanguage = $r('app.string.TraditionalChinese_TW_Subtitle')
        break
      default:
        this.currentLanguage = $r('app.string.Language_Subtitle')
    }
    // 标准化系统语言
    switch (systemLanguage) {
      case 'zh-Hans-CN':
      case 'zh-Hans':
        this.SystemLanguageSubtitle = $r('app.string.Language_Subtitle')
        this.uiConfig.systemLanguage = 'zh-Hans'
        break
      case 'en-Latn-US':
      case 'en-Latn':
        this.SystemLanguageSubtitle = $r('app.string.English_Subtitle')
        this.uiConfig.systemLanguage = 'en-Latn'
        break
      case 'zh-Hant-HK':
      case 'zh-Hant':
      case 'zh-HK':
        this.SystemLanguageSubtitle = $r('app.string.TraditionalChinese_HK_Subtitle')
        this.uiConfig.systemLanguage = 'zh-HK'
        break
      case 'zh-Hant-TW':
      case 'zh-TW':
        this.SystemLanguageSubtitle = $r('app.string.TraditionalChinese_TW_Subtitle')
        this.uiConfig.systemLanguage = 'zh-TW'
        break
      default:
        this.SystemLanguageSubtitle = $r('app.string.Language_Subtitle')
      // 超出范围保存为系统返回值
        this.uiConfig.systemLanguage = systemLanguage
    }
  }

  /**切换按钮位置*/
  switchButtonPosition(index: number) {
    switch (index) {
      case 0:
        // 右侧
        this.ButtonPositionOffset = 16
        this.stackAlignContentAlignment = Alignment.BottomEnd
        break
      case 1:
        // 中间
        this.ButtonPositionOffset = 0
        this.stackAlignContentAlignment = Alignment.Bottom
        break
      case 2:
        // 左侧
        this.ButtonPositionOffset = -16
        this.stackAlignContentAlignment = Alignment.BottomStart
        break
    }
  }

  /**tab移动开始动画*/
  startAnim() {
    indexController.setTabBarTranslate({ y: 0 })
    Xb_AnimationStyle.animToAPI18(()=>{
      indexController.setTabBarTranslate({ y: '100%' })
      this.barHeight = 0
      console.info('tab横竖：', `${TabBarVertical(this.widthBp, this.heightBp)}`)
    },this.uiConfig.animationSpeed, 'app', 0)
  }

  /**tab移动停止动画*/
  stopAnim() {
    Xb_AnimationStyle.animToAPI18(()=>{
      if (!this.isSmallSquareScreen || !this.isRolling) {
        indexController.setTabBarTranslate({ y: 0 })
        this.barHeight = this.bottomRectHeight == 0 ? TabBarHeight(this.widthBp, this.heightBp) :
          TabBarAvoidHeight(this.widthBp, this.heightBp)
      }
    },this.uiConfig.animationSpeed, 'app', 0)
  }

  /**是否进入主二级界面(更多页二级)*/
  isSecondaryChange() {
    // 监听二级页面布尔判定动画是否执行 监听小屏是否滚动
    if (this.isSecondary && MoreNavMode(this.widthBp, this.heightBp) === NavigationMode.Stack) {
      this.stopAnim()
      this.startAnim()
    } else {
      this.stopAnim()
    }
  }

  /*px外屏手势动画*/
  // tab隐藏
  startAnimPX() {
    Xb_AnimationStyle.animToAPI18(()=>{
      indexController.setTabBarTranslate({ y: '100%' })
      this.barHeight = 0

      this.heightTop = -TAB_CONTENT_TITLE_HEIGHT
    },this.uiConfig.animationSpeed, 'app', 0)
  }

  // tab显示
  stopAnimPX() {
    Xb_AnimationStyle.animToAPI18(()=>{
      indexController.setTabBarTranslate({ y: 0 })
      this.barHeight = TabBarHeight(this.widthBp, this.heightBp)
      this.heightTop = 0
    },this.uiConfig.animationSpeed, 'app', 0)
  }

  /**监听上下滚动时，tab是否隐藏*/
  isHiddenChange() {
    if (this.isSmallSquareScreen && this.isRolling) {
      this.stopAnimPX()
      this.startAnimPX()
    } else {
      this.stopAnimPX()
    }
  } // px外屏手势动画 end

  /**避让状态改变*/
  onAvoidAreaChange() {
    hilog.info(0x0000, 'Index', '#onAvoidAreaChange 动态避让高度 Top：%{public}d Bottom: %{public}i', this.topRectHeight, this.bottomRectHeight)
  }

  /**
   * @description 跳转到访问控制添加包名
   */
  jumpAccessControl(bundleInfo: BundleInfo) {
    if (this.uiConfig.tabStyle == 'custom') {
      indexController.changeIndex(3)
    } else if (this.uiConfig.tabStyle == 'float') {
      swiperController.changeIndex(3)
    }
    if (this.widthBp <= 1) {
      const mainPath = this.pageInfos.getAllPathName()
      if (mainPath[0] !== 'access_control' || mainPath.length === 0) {
        this.pageInfos.pushPathByName('access_control', false)
      }
    } else {
      const morePath = this.morePageInfos.getAllPathName()
      if (morePath[0] !== 'access_control' || morePath.length === 0) {
        this.morePageInfos.replacePathByName('access_control', false)
      }
    }

    setTimeout(() => {
      EventHub.sendEvent(EventKey.AddAPP, bundleInfo)
    }, 400)
  }

  /**
   * 获取悬浮tab状态
   */
  getFloatAlign() {
    const value = this.uiConfig.buttonPositionIndex == 0 ? Xb_FloatTabBarAlignEnd(this.widthBp, this.heightBp) :
      (this.uiConfig.buttonPositionIndex == 1 ? Xb_FloatTabBarAlignCenter(this.widthBp, this.heightBp) : Xb_FloatTabBarAlignStart(this.widthBp, this.heightBp))
    // Xb_ToastUtil.showToast({ message: `getFloatAlign: ${value}`})
    return value
  }

  // getFloatBottom() 已迁移至 FloatBar 组件
  // functionButtonStyle @Extend 已迁移至 FloatControlButton 组件
}
