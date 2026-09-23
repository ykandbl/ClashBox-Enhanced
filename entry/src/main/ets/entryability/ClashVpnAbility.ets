import {  VpnExtensionAbility } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { SocketStubService } from 'proxy_core';
import { ClashCore } from './AppState';
import fs from  "@ohos.file.fs"
import { writeFile } from 'proxy_core/src/main/ets/fileUtils';
import util from '@ohos.util';
import { hilog } from '@kit.PerformanceAnalysisKit';


export default class ClashVpnAbility extends VpnExtensionAbility {

  clashStubService: SocketStubService | undefined
  private requestId: number = 0
  constructor() {
    super();
  }
  async onCreate(want: Want) {
    try {
      let core = want.parameters?.["ClashCore"] as ClashCore ?? ClashCore.mihomo
      let requestId = want.parameters?.["requestId"] as number
      this.requestId = requestId
      hilog.info(0xA003, 'VpnAbilityLifecycle', `onCreate requestId=${requestId}, core=${core}`)
      if(core == ClashCore.mihomo){
        console.log("ClashBox", `启用核心 mihomo`);
        this.clashStubService = new SocketStubService(this.context)
        await this.clashStubService.startService()
        hilog.info(0xA003, 'VpnAbilityLifecycle', `RPC 服务就绪 requestId=${requestId}`)
        console.log("ClashBox", `启用核心 mihomo 成功`);
      }else{
        console.log("ClashBox", `前台模式`);
      }
      await this.lockVpn(requestId)
      hilog.info(0xA003, 'VpnAbilityLifecycle', `握手锁写入完成 requestId=${requestId}`)
    } catch (e) {
      hilog.error(0xA003, 'VpnAbilityLifecycle', `onCreate 失败 requestId=${this.requestId}, error=${e.message}`)
      console.log("ClashBox", `启用VPN失败 ${e.message} ${e.stack}`);
    }
  }
  async lockVpn(local: number){
    let lockPath = this.context.filesDir + '/vpn_ipc.lock';
    let encoder = new util.TextEncoder()
    writeFile(lockPath, encoder.encodeInto(local + ""))
  }
  onDestroy(){
    hilog.info(0xA003, 'VpnAbilityLifecycle', `onDestroy requestId=${this.requestId}`)
    console.log("ClashBox", `后台vpn服务(ClashVpnAbility) 退出`);
    this.clashStubService?.stopVpn();
    let lockPath = this.context.filesDir + '/vpn_ipc.lock';
    try {
      // stop/start 交叠时，旧实例不得删除新实例刚写入的握手锁。
      if (fs.readTextSync(lockPath) === `${this.requestId}`) {
        fs.unlinkSync(lockPath)
      }
    } catch (_) {
      // 文件已由主进程清理。
    }
  }
};


