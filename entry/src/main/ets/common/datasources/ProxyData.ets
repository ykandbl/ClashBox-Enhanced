import { ProxyGroup, ProxySort } from "proxy_core"
import { BaseDataSource } from "./BaseDataSource"
import { intl } from "@kit.LocalizationKit"
import ClashViewModel, { DelayInfo } from "../../entryability/ClashViewModel"

// 定义一个接口来描述列表项的数据结构
export interface ProxyItem {
  readonly name: string
  latency: number
  type: string
  network?: string
  udp?: boolean
  id?: string
  g?: string
  isShowFavoriteProxy?: boolean
}

@Observed
// 节点假数据组
export class ProxyData {
  private static items: ProxyItem[] = [
  // ...你的items数据...
  ]

// 延迟颜色设定
  public static ProxyItems(): ProxyItem[] {
    return ProxyData.items;
  }

  public static getColorForLatency(latency: number): ResourceColor {
    if (latency >= 0 && latency <= 500) {
      return '#64BB5C'; // 绿色，表示低延迟
    }

    if (latency > 500 && latency <= 1000) {
      return '#f7ce00'; // 黄色，表示中等延迟
    }

    if (latency > 1000) {
      return '#e84026'; // 红色，表示高延迟
    }

    if (latency < 0) {
      return Color.Red // 超时也是红色
    }

    // 默认情况下，返回系统定义的次要字体颜色，适用于无效或未知的延迟值
    return $r('sys.color.font_secondary');
  }
}

/**
 * 代理页分组数据源
 */
@Observed
export class ProxyGroupItemDataSource extends BaseDataSource<ProxyGroup> {
  private dataArray: ProxyGroup[] = []

  public totalCount(): number {
    return this.dataArray.length
  }

  public getData(index: number): ProxyGroup {
    return this.dataArray[index]
  }

  public getAllData(): ProxyGroup[] {
    return this.dataArray
  }

  public addData(index: number, data: ProxyGroup): void {
    this.dataArray.splice(index, 0, data)
    this.notifyDataAdd(index)
  }

  public pushData(data: ProxyGroup[]): void {
    this.replaceData(data)
  }

  /** 一次性替换快照，LazyForEach 不会观察到中间空列表。 */
  public replaceData(data: ProxyGroup[]): void {
    this.dataArray = data
    this.notifyDataReload()
  }

  //删除全部数据
  public clear(): void {
    this.empty()
    this.refresh()
  }

  public empty(): void {
    this.dataArray = []
  }
  public refresh(): void {
    this.notifyDataReload()
  }
}

/**
 * 代理页节点数据源
 */
@Observed
export class ProxyItemDataSource extends BaseDataSource<ProxyItem> {
  private dataArray: ProxyItem[] = []

  public totalCount(): number {
    return this.dataArray.length
  }

  public getData(index: number): ProxyItem {
    return this.dataArray[index]
  }

  public addData(index: number, data: ProxyItem): void {
    this.dataArray.splice(index, 0, data)
    this.notifyDataAdd(index)
  }

  public pushData(data: ProxyItem[]): void {
    this.dataArray = data
    this.notifyDataAdd(this.dataArray.length - 1)
  }
  // 删除全部数据
  public clear(): void {
    this.empty()
    this.refresh()
  }

  public empty(): void {
    this.dataArray = []
  }
  public refresh(): void {
    this.notifyDataReload()
  }

  // 延迟排序
  public LatencySortItems(data: ProxyItem[]) {
    this.applySortedItems(data.slice().sort((a, b) => {
      const aResult = ClashViewModel.delayMap.get(a.name)
      const bResult = ClashViewModel.delayMap.get(b.name)
      const delayA = aResult?.status === 'ok' ? aResult.delay : Number.MAX_SAFE_INTEGER
      const delayB = bResult?.status === 'ok' ? bResult.delay : Number.MAX_SAFE_INTEGER
      return delayA - delayB
    }))
  }

  // 日常体验推荐排序：完整测试过的节点按名次置顶，其余节点按延迟排列。
  public ExperienceSortItems(data: ProxyItem[]) {
    this.applySortedItems(data.slice().sort((a, b) => {
      const rankA = ClashViewModel.getNodeExperienceRank(a.g ?? '', a.name)
      const rankB = ClashViewModel.getNodeExperienceRank(b.g ?? '', b.name)
      if (rankA > 0 && rankB > 0) return rankA - rankB
      if (rankA > 0) return -1
      if (rankB > 0) return 1
      const aDelay = ClashViewModel.delayMap.get(a.name)
      const bDelay = ClashViewModel.delayMap.get(b.name)
      const delayA = aDelay?.status === 'ok' ? aDelay.delay : Number.MAX_SAFE_INTEGER
      const delayB = bDelay?.status === 'ok' ? bDelay.delay : Number.MAX_SAFE_INTEGER
      return delayA - delayB
    }))
  }

  // 按名称排序
  public NameSortItems(data: ProxyItem[]) {
    this.applySortedItems(data.slice().sort((a, b) => ProxyCollator.compare(a.name, b.name)))
  }

  // 默认排序
  public DefaultSortItems(data: ProxyItem[]) {
    this.applySortedItems(data.slice().sort((a, b) => ProxyCollator.compare(a.id, b.id)))
  }

  private applySortedItems(sorted: ProxyItem[]): void {
    // For the same node set only exchange positions. onDataMove is a swap in
    // ArkUI, not array.splice; stable keys preserve cards and the List scroller.
    const sameNodes = sorted.length === this.dataArray.length &&
      sorted.every((item: ProxyItem) => this.dataArray.some((old: ProxyItem) => old.name === item.name && old.g === item.g))
    if (!sameNodes) {
      this.dataArray = sorted
      this.notifyDataReload()
      return
    }
    for (let target = 0; target < sorted.length; target++) {
      const source = this.dataArray.findIndex((item: ProxyItem) =>
        item.name === sorted[target].name && item.g === sorted[target].g)
      if (source !== target) {
        const displaced = this.dataArray[target]
        this.dataArray[target] = this.dataArray[source]
        this.dataArray[source] = displaced
        this.notifyDataMove(source, target)
      }
    }
  }
}

// 中文排序
let ProxyCollator = new intl.Collator("zh-CN");
