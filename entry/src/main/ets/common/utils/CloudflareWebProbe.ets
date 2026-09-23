export type CloudflareProbeRunner = (useProxy: boolean, mixedPort: number) => Promise<string>

/**
 * IPPure 的 Cloudflare 系数包含 ArkWeb/Cloudflare 生成的浏览器侧摘要，普通
 * NetworkKit 请求无法得到同口径结果。该协调器把数据层请求交给主页中常驻的
 * 1px ArkWeb 探针，并合并同一时刻的重复刷新。
 */
export class CloudflareWebProbe {
  private static runner: CloudflareProbeRunner | null = null
  private static pending: Promise<string> | null = null
  private static pendingProxy: boolean = false
  private static pendingPort: number = 0

  static register(runner: CloudflareProbeRunner): void {
    CloudflareWebProbe.runner = runner
  }

  static unregister(): void {
    CloudflareWebProbe.runner = null
  }

  static request(useProxy: boolean, mixedPort: number): Promise<string> {
    if (CloudflareWebProbe.pending && CloudflareWebProbe.pendingProxy === useProxy &&
      CloudflareWebProbe.pendingPort === mixedPort) {
      return CloudflareWebProbe.pending
    }
    if (!CloudflareWebProbe.runner) return Promise.reject(new Error('Cloudflare 浏览器探针尚未就绪'))
    CloudflareWebProbe.pendingProxy = useProxy
    CloudflareWebProbe.pendingPort = mixedPort
    CloudflareWebProbe.pending = CloudflareWebProbe.runner(useProxy, mixedPort)
    CloudflareWebProbe.pending.finally((): void => {
      CloudflareWebProbe.pending = null
    })
    return CloudflareWebProbe.pending
  }
}

export default CloudflareWebProbe
