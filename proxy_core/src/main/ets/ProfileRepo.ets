import { relationalStore, ValuesBucket } from '@kit.ArkData'
import { common } from '@kit.AbilityKit';
import { Profile } from './Profile';
import { SubscriptionInfo } from './models/Common';
import { BusinessError } from '@kit.BasicServicesKit';
import { JSON } from '@kit.ArkTS';

export class ProfileRepo {
  store: relationalStore.RdbStore | undefined
  /**
   * Profiles 表只有几条记录，但 HarmonyOS 真机的共享 ResultSet 在应用运行一段
   * 时间后会持有失效的 SharedBlock fd，随后所有定时读取都报 SQLITE_IOERR。
   * 启动时完整装载一次，之后运行期读取内存镜像；所有写操作成功后同步镜像。
   */
  private profileCache: Map<string, Profile> = new Map<string, Profile>()
  private cacheReady: boolean = false
  /**
   * HarmonyOS 的共享 ResultSet 与紧随其后的同表写入偶发返回 SQLITE_IOERR。
   * 配置、额度定时刷新、节点选择都会访问 Profiles，统一排队可避免读游标
   * 尚未完全释放时另一条异步链抢先写库。
   */
  private operationQueue: Promise<void> = Promise.resolve()
  constructor() {
  }

  private async runSerialized<T>(operation: () => Promise<T>): Promise<T> {
    const previous = this.operationQueue
    let release: () => void = () => {}
    this.operationQueue = new Promise<void>((resolve) => {
      release = resolve
    })
    await previous
    try {
      return await operation()
    } finally {
      release()
    }
  }

  async init(context: common.Context) {
    const STORE_CONFIG: relationalStore.StoreConfig = {
      name: 'fsclash.db', // 数据库文件名
      securityLevel: relationalStore.SecurityLevel.S1 // 数据库安全级别
    };
    try {
      this.store = await relationalStore.getRdbStore(context, STORE_CONFIG)
      await this.initDb()
      const initialProfiles = await this.readAllFromStoreUnlocked()
      if (initialProfiles !== null) {
        this.replaceCache(initialProfiles)
        console.error(`ProfileRepo profile cache ready, count=${initialProfiles.length}`)
      }
    } catch (error) {
      this.store = undefined
      console.error(`ProfileRepo.queryAll 获取store失败, code is ${error.code}, message is ${error.message}`);
      throw new Error((error as Error).message)
    }
  }

  async initDb(): Promise<void> {
    try {
      const SQL_CREATE_TABLE = "CREATE TABLE IF NOT EXISTS Profiles(id TEXT PRIMARY KEY, name TEXT, type INTEGER NOT NULL, url TEXT, currentGroupName TEXT, isUpdating INTEGER,autoUpdate INTEGER, lastUpdateDate INTEGER, autoUpdateDuration INTEGER, subscriptionInfo TEXT, proxySelected Text)"
      await this.store!.executeSql(SQL_CREATE_TABLE); // 创建数据表
      await this.ensureColumn("bitzQuotaEnabled", "INTEGER DEFAULT 0")
      await this.ensureColumn("bitzQuotaState", "TEXT DEFAULT 'idle'")
      await this.ensureColumn("bitzQuotaError", "TEXT DEFAULT ''")
      await this.ensureColumn("bitzQuotaUpdatedAt", "INTEGER DEFAULT 0")
      await this.ensureColumn("accountProvider", "TEXT DEFAULT 'none'")
      await this.ensureColumn("accountState", "TEXT DEFAULT 'idle'")
      await this.ensureColumn("accountError", "TEXT DEFAULT ''")
      await this.ensureColumn("accountUpdatedAt", "INTEGER DEFAULT 0")
      await this.ensureColumn("subscriptionState", "TEXT DEFAULT 'idle'")
      await this.ensureColumn("subscriptionError", "TEXT DEFAULT ''")
      await this.ensureColumn("subscriptionFormat", "TEXT DEFAULT ''")
      await this.ensureColumn("subscriptionNodeCount", "INTEGER DEFAULT 0")
      await this.ensureColumn("subscriptionCheckedAt", "INTEGER DEFAULT 0")
      await this.ensureColumn("lastGoodContentId", "TEXT DEFAULT ''")
      await this.ensureColumn("subscriptionPendingRepair", "INTEGER DEFAULT 0")
      await this.ensureColumn("subscriptionRetryAt", "INTEGER DEFAULT 0")
      await this.ensureColumn("subscriptionRetryCount", "INTEGER DEFAULT 0")
      await this.ensureColumn("coreLoadState", "TEXT DEFAULT 'unknown'")
      await this.ensureColumn("coreLoadedContentId", "TEXT DEFAULT ''")
      await this.ensureColumn("coreLoadedAt", "INTEGER DEFAULT 0")
      console.error("ProfileRepo.initDb初始化成功");
    } catch (e) {
      console.error("initDb failure", e)
      throw new Error((e as Error).message)
    }
  }

  private async ensureColumn(name: string, definition: string): Promise<void> {
    // Read the schema before issuing ALTER TABLE. The previous “try ALTER and
    // swallow duplicate-column” migration was functionally harmless but
    // emitted a wall of database errors on every cold start. On the affected
    // device that noise obscured the actual startup failure notification.
    try {
      const schema = await this.store!.querySql('PRAGMA table_info(Profiles)')
      try {
        const columns = schema.getColumnNames()
        const nameIndex = columns.indexOf('name')
        while (schema.goToNextRow()) {
          if (nameIndex >= 0 && schema.getString(nameIndex) === name) {
            return
          }
        }
      } finally {
        schema.close()
      }
    } catch (_) {
      // Older relational-store implementations may reject PRAGMA. Keep the
      // ALTER fallback for those versions; its duplicate result is contained.
    }
    try {
      await this.store!.executeSql(`ALTER TABLE Profiles ADD COLUMN ${name} ${definition}`)
      console.info(`ProfileRepo added column ${name}`)
    } catch (_) {
      // 已存在列时数据库会返回重复列错误，旧安装升级路径可直接继续。
    }
  }
  async delete(uuid: string) {
    return await this.runSerialized(async (): Promise<number> => {
      const predicates = new relationalStore.RdbPredicates('Profiles')
      predicates.equalTo('id', uuid)
      const deleted = await this.store!.delete(predicates)
      if (this.cacheReady) {
        this.profileCache.delete(uuid)
      }
      return deleted
    })
  }
  async ClearAll(context: Context){
    const list = await this.queryAll()
    for (let d of list) {
      d.loadContext(context)
      await this.delete(d.id)
      await d.delete()
    }
  }
  async query(uuid: string | undefined) {
    if(uuid == undefined)
      return null
    return await this.runSerialized(async (): Promise<Profile | null> => {
      return await this.queryUnlocked(uuid)
    })
  }

  private async queryUnlocked(uuid: string): Promise<Profile | null> {
    if (!this.cacheReady) {
      const profiles = await this.readAllFromStoreUnlocked()
      if (profiles !== null) {
        this.replaceCache(profiles)
      }
    }
    const cached = this.profileCache.get(uuid)
    return cached ? this.cloneProfile(cached) : null
  }

  async queryAll(): Promise<Profile[]> {
    return await this.runSerialized(async (): Promise<Profile[]> => {
      return await this.queryAllUnlocked()
    })
  }

  private async queryAllUnlocked(): Promise<Profile[]> {
    if (!this.cacheReady) {
      const profiles = await this.readAllFromStoreUnlocked()
      if (profiles !== null) {
        this.replaceCache(profiles)
      }
    }
    return Array.from(this.profileCache.values()).map((profile: Profile): Profile =>
      this.cloneProfile(profile))
  }

  /** 仅在进程初始化/初始化失败后的首次读取调用，不参与每分钟定时刷新。 */
  private async readAllFromStoreUnlocked(): Promise<Profile[] | null> {
    if (!this.store) {
      console.error(`ProfileRepo.readAll store 不存在`)
      return null
    }
    const retryDelays: number[] = [0, 120, 300]
    let lastError: Error | null = null
    for (const delay of retryDelays) {
      if (delay > 0) {
        await new Promise<void>((resolve) => setTimeout(resolve, delay))
      }
      const predicates = new relationalStore.RdbPredicates('Profiles')
      try {
        const cursor = this.store.querySync(predicates)
        try {
          const list: Profile[] = []
          while (cursor.goToNextRow()) {
            list.push(this.getFromCursor(cursor))
          }
          return list
        } finally {
          cursor.close()
        }
      } catch (error) {
        lastError = error as Error
      }
    }
    console.error(`ProfileRepo.readAll failed after retry: ${lastError?.message ?? 'unknown'}`)
    return null
  }

  private replaceCache(profiles: Profile[]): void {
    this.profileCache.clear()
    for (const profile of profiles) {
      this.profileCache.set(profile.id, this.cloneProfile(profile))
    }
    this.cacheReady = true
  }

  private cloneProfile(source: Profile): Profile {
    const copy = new Profile(source.type, source.name ?? "")
    copy.id = source.id
    copy.name = source.name
    copy.url = source.url
    copy.currentGroupName = source.currentGroupName
    copy.isUpdating = source.isUpdating
    copy.autoUpdate = source.autoUpdate
    copy.lastUpdateDate = source.lastUpdateDate
    copy.autoUpdateDuration = source.autoUpdateDuration
    copy.subscriptionInfo = source.subscriptionInfo === null ? null :
      JSON.parse(JSON.stringify(source.subscriptionInfo)) as SubscriptionInfo
    copy.accountProvider = source.accountProvider
    copy.accountState = source.accountState
    copy.accountError = source.accountError
    copy.accountUpdatedAt = source.accountUpdatedAt
    copy.subscriptionState = source.subscriptionState
    copy.subscriptionError = source.subscriptionError
    copy.subscriptionFormat = source.subscriptionFormat
    copy.subscriptionNodeCount = source.subscriptionNodeCount
    copy.subscriptionCheckedAt = source.subscriptionCheckedAt
    copy.lastGoodContentId = source.lastGoodContentId
    copy.subscriptionPendingRepair = source.subscriptionPendingRepair
    copy.subscriptionRetryAt = source.subscriptionRetryAt
    copy.subscriptionRetryCount = source.subscriptionRetryCount
    copy.coreLoadState = source.coreLoadState
    copy.coreLoadedContentId = source.coreLoadedContentId
    copy.coreLoadedAt = source.coreLoadedAt
    copy.bitzQuotaEnabled = source.bitzQuotaEnabled
    copy.bitzQuotaState = source.bitzQuotaState
    copy.bitzQuotaError = source.bitzQuotaError
    copy.bitzQuotaUpdatedAt = source.bitzQuotaUpdatedAt
    const selected = new Map<string, string>()
    source.proxySelected.forEach((value: string, key: string): void => {
      selected.set(key, value)
    })
    copy.proxySelected = selected
    return copy
  }


  async addOrUpdate(details: Profile): Promise<number> {
    return await this.runSerialized(async (): Promise<number> => {
      return await this.addOrUpdateUnlocked(details)
    })
  }

  private async addOrUpdateUnlocked(details: Profile): Promise<number> {
    const predicates = new relationalStore.RdbPredicates('Profiles')
    predicates.equalTo('id', details.id);
    // 额度定时刷新、订阅更新与配置页编辑可能同时持有同一配置的不同快照。
    // 写队列只能保证落库顺序，仍需避免较早读出的快照在网络请求结束后把
    // 较新的订阅诊断/更新时间覆盖回“待检测”。以各自时间戳做字段级合并。
    const cached = this.profileCache.get(details.id)
    if (cached) {
      if (cached.lastUpdateDate > details.lastUpdateDate) {
        details.lastUpdateDate = cached.lastUpdateDate
      }
      const cachedSubscriptionIsNewer = cached.subscriptionCheckedAt > details.subscriptionCheckedAt
      if (cachedSubscriptionIsNewer) {
        details.subscriptionState = cached.subscriptionState
        details.subscriptionError = cached.subscriptionError
        details.subscriptionFormat = cached.subscriptionFormat
        details.subscriptionNodeCount = cached.subscriptionNodeCount
        details.subscriptionCheckedAt = cached.subscriptionCheckedAt
        // Retry state belongs to the same subscription-check generation. The
        // previous unconditional max(retryAt) merge resurrected an old failed
        // generation after a newer successful download had cleared it. That
        // left the retry timestamp permanently in the past and caused a
        // one-second download/reload/probe loop.
        details.subscriptionPendingRepair = cached.subscriptionPendingRepair
        details.subscriptionRetryAt = cached.subscriptionRetryAt
        details.subscriptionRetryCount = cached.subscriptionRetryCount
      }
      if (cached.coreLoadedAt > details.coreLoadedAt) {
        details.coreLoadState = cached.coreLoadState
        details.coreLoadedContentId = cached.coreLoadedContentId
        details.coreLoadedAt = cached.coreLoadedAt
      }
      if (cached.accountProvider === details.accountProvider &&
        cached.accountUpdatedAt > details.accountUpdatedAt) {
        details.subscriptionInfo = cached.subscriptionInfo
        details.accountState = cached.accountState
        details.accountError = cached.accountError
        details.accountUpdatedAt = cached.accountUpdatedAt
      }
    }
    const jsonObject = details.getSelectedMap()
    if ((!details.accountProvider || details.accountProvider === "none") && details.bitzQuotaEnabled) {
      details.accountProvider = "bitznet"
      details.accountState = details.bitzQuotaState
      details.accountError = details.bitzQuotaError
      details.accountUpdatedAt = details.bitzQuotaUpdatedAt
    }
    details.bitzQuotaEnabled = details.accountProvider === "bitznet"
    details.bitzQuotaState = details.bitzQuotaEnabled ? details.accountState : "idle"
    details.bitzQuotaError = details.bitzQuotaEnabled ? details.accountError : ""
    details.bitzQuotaUpdatedAt = details.bitzQuotaEnabled ? details.accountUpdatedAt : 0
    const input: ValuesBucket = {
      id: details.id,
      name: details.name ,
      type: details.type,
      url: details.url,
      currentGroupName: details.currentGroupName,
      isUpdating: details.isUpdating ? 1 : 0,
      autoUpdate: details.autoUpdate ? 1 : 0,
      lastUpdateDate: details.lastUpdateDate,
      autoUpdateDuration: details.autoUpdateDuration,
      subscriptionInfo: JSON.stringify(details.subscriptionInfo),
      proxySelected: JSON.stringify(jsonObject),
      bitzQuotaEnabled: details.bitzQuotaEnabled ? 1 : 0,
      bitzQuotaState: details.bitzQuotaState,
      bitzQuotaError: details.bitzQuotaError,
      bitzQuotaUpdatedAt: details.bitzQuotaUpdatedAt,
      accountProvider: details.accountProvider,
      accountState: details.accountState,
      accountError: details.accountError,
      accountUpdatedAt: details.accountUpdatedAt,
      subscriptionState: details.subscriptionState,
      subscriptionError: details.subscriptionError,
      subscriptionFormat: details.subscriptionFormat,
      subscriptionNodeCount: details.subscriptionNodeCount,
      subscriptionCheckedAt: details.subscriptionCheckedAt,
      lastGoodContentId: details.lastGoodContentId,
      subscriptionPendingRepair: details.subscriptionPendingRepair ? 1 : 0,
      subscriptionRetryAt: details.subscriptionRetryAt,
      subscriptionRetryCount: details.subscriptionRetryCount,
      coreLoadState: details.coreLoadState,
      coreLoadedContentId: details.coreLoadedContentId,
      coreLoadedAt: details.coreLoadedAt
    }
    console.debug(`ProfileRepo.addOrUpdate profileId=${details.id} hasSubscriptionInfo=${!!details.subscriptionInfo}`)
    // 不再用共享 ResultSet 先判断是否存在。真机在结果集仍打开时紧接着写同一张表，
    // 偶发会得到 rowCount=-1 / SQLITE_IOERR，随后把已有记录误走成 INSERT，
    // 最终表现为“缓存失败”。直接 UPDATE，未命中时再 INSERT，可避免这条竞态。
    const retryDelays: number[] = [0, 120, 300]
    let lastError: Error | null = null
    for (const delay of retryDelays) {
      if (delay > 0) {
        await new Promise<void>((resolve) => setTimeout(resolve, delay))
      }
      try {
        const changed = await this.store!.update(input, predicates)
        if (changed > 0) {
          if (this.cacheReady) this.profileCache.set(details.id, this.cloneProfile(details))
          return 1
        }
        await this.store!.insert("Profiles", input)
        if (this.cacheReady) this.profileCache.set(details.id, this.cloneProfile(details))
        return 0
      } catch (error) {
        lastError = error as Error
      }
    }
    console.error(`ProfileRepo.addOrUpdate failed after retry: ${lastError?.message ?? 'unknown'}`)
    throw lastError ?? new Error('配置数据库写入失败')
  }

  getFromCursor(c: relationalStore.ResultSet | relationalStore.LiteResultSet): Profile {
    const details = new Profile(0,"");
    try {
      details.id = c.getString(0);
      details.name = c.getString(1);
      details.type = c.getLong(2);
      details.url = c.getString(3);
      details.currentGroupName = c.getString(4);
      details.isUpdating = c.getLong(5) == 1;
      details.autoUpdate = c.getLong(6) == 1;
      details.lastUpdateDate = c.getLong(7);
      details.autoUpdateDuration = c.getLong(8);
      details.subscriptionInfo = JSON.parse(c.getString(9)) as SubscriptionInfo;

      const map = new Map<string, string>();
      let json = JSON.parse(c.getString(10)) as Record<string, string>
      Object.keys(json).forEach((key) => {
        map.set(key, json[key]);
      });
      details.proxySelected = map;
      const bitzEnabledIndex = c.getColumnIndex("bitzQuotaEnabled")
      const bitzStateIndex = c.getColumnIndex("bitzQuotaState")
      const bitzErrorIndex = c.getColumnIndex("bitzQuotaError")
      const bitzUpdatedAtIndex = c.getColumnIndex("bitzQuotaUpdatedAt")
      details.bitzQuotaEnabled = bitzEnabledIndex >= 0 && c.getLong(bitzEnabledIndex) === 1
      details.bitzQuotaState = bitzStateIndex >= 0 ? c.getString(bitzStateIndex) : "idle"
      details.bitzQuotaError = bitzErrorIndex >= 0 ? c.getString(bitzErrorIndex) : ""
      details.bitzQuotaUpdatedAt = bitzUpdatedAtIndex >= 0 ? c.getLong(bitzUpdatedAtIndex) : 0
      const accountProviderIndex = c.getColumnIndex("accountProvider")
      const accountStateIndex = c.getColumnIndex("accountState")
      const accountErrorIndex = c.getColumnIndex("accountError")
      const accountUpdatedAtIndex = c.getColumnIndex("accountUpdatedAt")
      details.accountProvider = accountProviderIndex >= 0 ? c.getString(accountProviderIndex) : "none"
      details.accountState = accountStateIndex >= 0 ? c.getString(accountStateIndex) : "idle"
      details.accountError = accountErrorIndex >= 0 ? c.getString(accountErrorIndex) : ""
      details.accountUpdatedAt = accountUpdatedAtIndex >= 0 ? c.getLong(accountUpdatedAtIndex) : 0
      const subscriptionStateIndex = c.getColumnIndex("subscriptionState")
      const subscriptionErrorIndex = c.getColumnIndex("subscriptionError")
      const subscriptionFormatIndex = c.getColumnIndex("subscriptionFormat")
      const subscriptionNodeCountIndex = c.getColumnIndex("subscriptionNodeCount")
      const subscriptionCheckedAtIndex = c.getColumnIndex("subscriptionCheckedAt")
      details.subscriptionState = subscriptionStateIndex >= 0 ? c.getString(subscriptionStateIndex) : "idle"
      details.subscriptionError = subscriptionErrorIndex >= 0 ? c.getString(subscriptionErrorIndex) : ""
      details.subscriptionFormat = subscriptionFormatIndex >= 0 ? c.getString(subscriptionFormatIndex) : ""
      details.subscriptionNodeCount = subscriptionNodeCountIndex >= 0 ? c.getLong(subscriptionNodeCountIndex) : 0
      details.subscriptionCheckedAt = subscriptionCheckedAtIndex >= 0 ? c.getLong(subscriptionCheckedAtIndex) : 0
      const lastGoodContentIdIndex = c.getColumnIndex("lastGoodContentId")
      const subscriptionPendingRepairIndex = c.getColumnIndex("subscriptionPendingRepair")
      const subscriptionRetryAtIndex = c.getColumnIndex("subscriptionRetryAt")
      const subscriptionRetryCountIndex = c.getColumnIndex("subscriptionRetryCount")
      const coreLoadStateIndex = c.getColumnIndex("coreLoadState")
      const coreLoadedContentIdIndex = c.getColumnIndex("coreLoadedContentId")
      const coreLoadedAtIndex = c.getColumnIndex("coreLoadedAt")
      details.lastGoodContentId = lastGoodContentIdIndex >= 0 ? c.getString(lastGoodContentIdIndex) : ""
      details.subscriptionPendingRepair = subscriptionPendingRepairIndex >= 0 &&
        c.getLong(subscriptionPendingRepairIndex) === 1
      details.subscriptionRetryAt = subscriptionRetryAtIndex >= 0 ? c.getLong(subscriptionRetryAtIndex) : 0
      details.subscriptionRetryCount = subscriptionRetryCountIndex >= 0 ? c.getLong(subscriptionRetryCountIndex) : 0
      details.coreLoadState = coreLoadStateIndex >= 0 ? c.getString(coreLoadStateIndex) : "unknown"
      details.coreLoadedContentId = coreLoadedContentIdIndex >= 0 ? c.getString(coreLoadedContentIdIndex) : ""
      details.coreLoadedAt = coreLoadedAtIndex >= 0 ? c.getLong(coreLoadedAtIndex) : 0
      // 旧安装只有 bitzQuota* 列：首次读取时直接映射到新的服务商模型。
      if ((!details.accountProvider || details.accountProvider === "none") && details.bitzQuotaEnabled) {
        details.accountProvider = "bitznet"
        details.accountState = details.bitzQuotaState
        details.accountError = details.bitzQuotaError
        details.accountUpdatedAt = details.bitzQuotaUpdatedAt
      }
    } catch (e) {
      details.subscriptionInfo = null
      details.proxySelected = new Map()
    }
    return details;
  }
}
