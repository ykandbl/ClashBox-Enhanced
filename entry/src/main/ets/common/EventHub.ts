import { emitter } from "@kit.BasicServicesKit";

export enum EventKey{
  FetchProxyGroup = 10000,
  FetchProfile = 10001,
  ProxySort = 10002,
  ChangeProxy = 10003,
  TestDelay = 10004,
  StartLog = 10005,
  SwitchModeCard = 10006,
  ClearLog = 10007,
  ExportLog = 10008,
  ArrayConfigChanged = 10009,
  StartedClash = 10010,
  StopedClash = 10011,
  checkIpInfo = 10012,
  LoadClashConfig = 10013,
  ShareBundle = 10014,
  AddAPP = 10015,
  ProxyDuration = 10016,
  EnabledNotice = 10017,
  StopedClashEntry = 10018,
  LoginWebDav = 10019,
  LoadConfigStr = 10020,
  AddConfig = 10021,
  TestAllDelay = 10022,
  SwitchButtonPosition = 10023,
  ReLoadAccessControl = 10024,
  NodeDelayBatchComplete = 10025,
  NodeDelayReset = 10026,
  NodeQualityUpdated = 10027
}

export class EventHub{
  static sendEvent(key: EventKey, data: any = null){
    emitter.emit({eventId: key}, {data: data})
  }
  static on(key: EventKey,callback: (data: any)=>void, once: boolean = true): () => void {
    if(once)
      emitter.off(key)
    const listener = (data: emitter.EventData): void => {
      callback(data.data)
    }
    emitter.on({eventId: key}, listener)
    return (): void => emitter.off(key, listener)
  }
  static off(key: EventKey) {
    emitter.off(key)
  }
}
