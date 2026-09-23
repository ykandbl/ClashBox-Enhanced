// Pure scheduling/state logic: shared by batch tests and individual node tests.
export interface NodeDelayProbe {
  value: number
  errorCode?: string
  elapsedMs?: number
  source?: string
  fallbackUsed?: boolean
  primaryErrorCode?: string
  fallbackErrorCode?: string
  diagnostic?: string
}

export interface NodeDelayResult {
  name: string
  delay: number
  status: string
  errorCode: string
  checkedAt: number
  elapsedMs: number
  source: string
  fallbackUsed: boolean
  primaryErrorCode: string
  fallbackErrorCode: string
  diagnostic: string
}

interface DelayJob {
  name: string
  epoch: number
  // Batch results are committed together.  This keeps a partially completed
  // run from reordering the list or replacing settled values one by one when
  // the page is recreated in the foreground.
  deferPublish: boolean
  resolve: (result: NodeDelayResult) => void
}

export function emptyNodeDelay(name: string, status: string = 'idle'): NodeDelayResult {
  return {
    name, delay: 0, status, errorCode: '', checkedAt: 0, elapsedMs: 0,
    source: '', fallbackUsed: false, primaryErrorCode: '', fallbackErrorCode: '', diagnostic: ''
  }
}

export function nodeDelayText(result: NodeDelayResult): string {
  if (result.status === 'queued') return '等待测速'
  if (result.status === 'testing') return '测速中'
  if (result.status === 'ok') return `${result.delay}ms`
  if (result.status !== 'failed') return '未测速'
  if (result.errorCode === 'timeout' && result.fallbackUsed) return '主备测速源均超时'
  return nodeDelayErrorText(result.errorCode)
}

export function nodeDelayErrorText(code: string): string {
  switch (code) {
    case 'timeout': return '连接超时'
    case 'dns': return 'DNS失败'
    case 'tls': return 'TLS失败'
    case 'refused': return '连接被拒绝'
    case 'unreachable': return '网络不可达'
    case 'missing': return '节点已变更'
    case 'invalid_url': return '测速地址无效'
    case 'service': return '本地服务异常'
    case 'cancelled': return '检测已取消'
    default: return '连接失败'
  }
}

export function normalizeDelayTestUrl(value: string): string {
  const url = value.trim()
  // Migrate the old misspelled default; other user-entered addresses remain intact.
  return !url || url === 'https://www.gstatic.com/generate204' ?
    'https://www.gstatic.com/generate_204' : url
}

// Diagnostics can correlate a card with a result without logging node names.
export function nodeDelayId(name: string): string {
  let hash = 5381
  for (let i = 0; i < name.length; i++) hash = ((hash << 5) + hash) ^ name.charCodeAt(i)
  return (hash >>> 0).toString(16)
}

export class NodeDelayRunner {
  readonly results: Map<string, NodeDelayResult> = new Map()
  private epoch: number = 0
  private active: number = 0
  private queue: DelayJob[] = []
  private pending: Map<string, Promise<NodeDelayResult>> = new Map()
  private batch: Promise<NodeDelayResult[]> | undefined
  private batchId: number = 0
  private probe: (name: string) => Promise<NodeDelayProbe>
  private onResult: (result: NodeDelayResult) => void
  private onProgress: (running: boolean, completed: number, total: number) => void
  private concurrency: number

  constructor(
    probe: (name: string) => Promise<NodeDelayProbe>,
    onResult: (result: NodeDelayResult) => void,
    onProgress: (running: boolean, completed: number, total: number) => void,
    concurrency: number = 6
  ) {
    this.probe = probe
    this.onResult = onResult
    this.onProgress = onProgress
    this.concurrency = Math.max(1, concurrency)
  }

  // In-flight RPCs finish naturally, but old-profile results never enter a new
  // profile's cache. They still occupy slots until done, preserving the limit.
  invalidate(): void {
    this.epoch++
    this.batchId++
    this.batch = undefined
    this.pending.clear()
    this.results.clear()
    const queued = this.queue
    this.queue = []
    queued.forEach((job: DelayJob) => job.resolve(emptyNodeDelay(job.name, 'cancelled')))
    this.onProgress(false, 0, 0)
  }

  test(name: string): Promise<NodeDelayResult> {
    return this.enqueue(name, false)
  }

  private enqueue(name: string, deferPublish: boolean): Promise<NodeDelayResult> {
    const existing = this.pending.get(name)
    if (existing) return existing
    const epoch = this.epoch
    const promise = new Promise<NodeDelayResult>((resolve) => {
      this.queue.push({ name, epoch, deferPublish, resolve })
    })
    this.pending.set(name, promise)
    if (!deferPublish) this.publishTransient(emptyNodeDelay(name, 'queued'))
    this.pump()
    return promise
  }

  testAll(names: string[], publishResults: boolean = true): Promise<NodeDelayResult[]> {
    if (this.batch) return this.batch
    const unique: string[] = Array.from(new Set(names))
    const id = ++this.batchId
    let completed = 0
    this.onProgress(true, 0, unique.length)
    const tasks = unique.map((name: string) => this.enqueue(name, true).then((result: NodeDelayResult) => {
      if (id === this.batchId) this.onProgress(true, ++completed, unique.length)
      return result
    }))
    const batch = Promise.all(tasks).then((results: NodeDelayResult[]) => {
      if (id === this.batchId && publishResults) {
        this.publishBatch(results)
      }
      return results
    }).finally(() => {
      if (id === this.batchId) {
        this.batch = undefined
        this.onProgress(false, completed, unique.length)
      }
    })
    this.batch = batch
    return batch
  }

  private publish(result: NodeDelayResult): void {
    this.results.set(result.name, result)
    this.onResult(result)
  }

  private publishTransient(result: NodeDelayResult): void {
    // Keep the last settled number visible while a new probe is queued or
    // running.  The progress indicator already communicates the in-flight
    // state, so replacing a stable value with 0 is both noisy and misleading.
    const previous = this.results.get(result.name)
    if (previous && (previous.status === 'ok' || previous.status === 'failed')) return
    this.publish(result)
  }

  publishBatch(results: NodeDelayResult[]): void {
    results.forEach((result: NodeDelayResult): void => {
      if (result.status !== 'cancelled') this.publish(result)
    })
  }

  private pump(): void {
    while (this.active < this.concurrency && this.queue.length > 0) {
      const job = this.queue.shift()!
      this.active++
      this.run(job)
    }
  }

  private async run(job: DelayJob): Promise<void> {
    if (!job.deferPublish) this.publishTransient(emptyNodeDelay(job.name, 'testing'))
    let result = emptyNodeDelay(job.name, 'failed')
    const startedAt = Date.now()
    try {
      const probe = await this.probe(job.name)
      result.delay = Number.isFinite(probe.value) && probe.value > 0 ? probe.value : -1
      result.status = result.delay > 0 ? 'ok' : 'failed'
      result.errorCode = result.delay > 0 ? '' : probe.errorCode || 'connection'
      result.elapsedMs = probe.elapsedMs ?? Date.now() - startedAt
      result.source = probe.source ?? ''
      result.fallbackUsed = probe.fallbackUsed ?? false
      result.primaryErrorCode = probe.primaryErrorCode ?? ''
      result.fallbackErrorCode = probe.fallbackErrorCode ?? ''
      result.diagnostic = probe.diagnostic ?? ''
    } catch (_) {
      // Raw RPC exceptions can contain socket paths or URLs; expose only a code.
      result.delay = -1
      result.errorCode = 'service'
      result.elapsedMs = Date.now() - startedAt
    }
    result.checkedAt = Date.now()
    if (job.epoch === this.epoch) {
      if (!job.deferPublish) this.publish(result)
      this.pending.delete(job.name)
    } else {
      result = emptyNodeDelay(job.name, 'cancelled')
    }
    job.resolve(result)
    this.active--
    this.pump()
  }
}
