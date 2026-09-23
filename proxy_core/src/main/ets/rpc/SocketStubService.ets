import { socket } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { CommonVpnService } from './CommonVpnService';
import { FlClashVpnService } from './FlClashVpnService';
import { startIpc } from 'libflclash.so';
import fs from '@ohos.file.fs';


export class SocketStubService {
  server: socket.LocalSocketServer = socket.constructLocalSocketServerInstance();
  clientPool: Map<number, socket.LocalSocketConnection>
  vpnService: CommonVpnService
  private initPromise: Promise<void>
  constructor( context: common.Context) {
    this.clientPool = new Map()
    this.vpnService = new FlClashVpnService(context)
    // initClash 会初始化 Go 运行时。旧实现把它当成 fire-and-forget，随后立刻
    // startIpc/listen，两个初始化路径并发时会留下“socket 文件存在但拒绝连接”
    // 的半启动状态。保存 Promise 并在开放 RPC 端口前完成串行初始化。
    this.initPromise = this.vpnService.init()
  }

  async startService(){
    await this.initPromise
    const socketPath = this.vpnService.context.filesDir + '/ClashBox.sock'
    const goPath = this.vpnService.context.filesDir + '/clash_go.sock'

    // Extension 进程被系统强杀时 Unix socket 文件可能残留。只清理这两个
    // 应用私有的运行时文件，避免新 server.listen 命中旧地址。
    for (const path of [socketPath, goPath]) {
      try {
        if (fs.accessSync(path, fs.AccessModeType.EXIST)) fs.unlinkSync(path)
      } catch (_) {
      }
    }
    startIpc(goPath)

    // listen 成功以后才允许 ClashVpnAbility 写握手锁。此前这里吞掉异常，
    // 主进程可能看到“请求 id 正确”却连不上控制 socket，形成假就绪。
    await this.server.listen({ address: socketPath})
    this.server.on('connect', (client: socket.LocalSocketConnection) => {
        this.clientPool.set(client.clientId, client);
        const messageListener = (value: socket.LocalSocketMessageInfo): void => {
          // ClashBox.sock 只承载一次性 start/stop 请求。收到首帧就停止
          // 接收，响应完成后由服务端关闭，避免客户端 GC 与 recv 线程竞争。
          client.off("message", messageListener)
          this.vpnService.onRemoteMessageRequest(client, value).catch((error: Error): void => {
            console.error('ClashBox RPC failed', error?.message ?? error)
          })
        }
        const closeListener = (): void => {
          try {
            client.off("message", messageListener)
          } catch (_) {
          }
          try {
            client.off("close", closeListener)
          } catch (_) {
          }
          this.clientPool.delete(client.clientId);
        }
        client.on("message", messageListener)
        client.on('close', closeListener);
    })
  }
  startVpn(){
    this.vpnService.startVpn()
  }
  stopVpn(){
    this.vpnService.stopVpn()
  }
}
function sleepTime(timeout = 100): Promise<void>{
  return new Promise((resolve)=>{
    setTimeout(resolve, timeout)
  })
}
