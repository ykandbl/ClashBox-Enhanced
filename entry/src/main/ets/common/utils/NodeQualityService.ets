export type NodeQualityMode = 'stability' | 'bandwidth' |
  'bandwidth_economy' | 'bandwidth_standard' | 'bandwidth_full' | 'bandwidth_official'
  | 'bandwidth_peak' | 'bandwidth_single_sustained' | 'bandwidth_multi_sustained'

export interface NodeQualityResult {
  profileId: string
  profileUpdatedAt: number
  group: string
  name: string
  mode: NodeQualityMode
  status: string
  quality: string
  checkedAt: number
  latencyMs: number
  jitterMs: number
  successRate: number
  downloadMbps: number
  uploadMbps: number
  transferredBytes: number
  errorMessage: string
  diagnostic?: string
  reliable?: boolean
  downloadVariationPercent?: number
  uploadVariationPercent?: number
  experienceScore?: number
  experienceRank?: number
}

export interface QualityDelayCandidate {
  name: string
  delay: number
  status: string
}

/**
 * 持久化历史只保留推荐和故障切换真正需要的标量，避免把测速诊断长文本
 * 反复写入 Preferences。一个节点最多保留最近 8 次、7 天内的结果。
 */
export interface NodeQualityHistorySample {
  profileId: string
  profileUpdatedAt: number
  group: string
  name: string
  mode: NodeQualityMode
  status: string
  checkedAt: number
  latencyMs: number
  successRate: number
  downloadMbps: number
  uploadMbps: number
  reliable: boolean
  downloadVariationPercent: number
  uploadVariationPercent: number
  experienceScore: number
}

export interface NodeQualityHistorySummary {
  sampleCount: number
  successfulSamples: number
  successRate: number
  consecutiveFailures: number
  medianDownloadMbps: number
  medianUploadMbps: number
  medianLatencyMs: number
  averageExperienceScore: number
  reliableRate: number
  lastCheckedAt: number
}

export function transferSpeedMbps(bytes: number, elapsedMs: number): number {
  if (!Number.isFinite(bytes) || !Number.isFinite(elapsedMs) || bytes <= 0 || elapsedMs <= 0) return 0
  return Math.round(bytes * 8 / elapsedMs / 1000 * 100) / 100
}

export function medianNumber(values: number[]): number {
  if (values.length === 0) return 0
  const sorted = values.slice().sort((a: number, b: number): number => a - b)
  const middle = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 0 ? Math.round((sorted[middle - 1] + sorted[middle]) / 2) : sorted[middle]
}

export function compactNodeQualitySample(result: NodeQualityResult): NodeQualityHistorySample {
  return {
    profileId: result.profileId,
    profileUpdatedAt: result.profileUpdatedAt,
    group: result.group,
    name: result.name,
    mode: result.mode,
    status: result.status,
    checkedAt: result.checkedAt,
    latencyMs: Math.max(0, result.latencyMs),
    successRate: Math.max(0, result.successRate),
    downloadMbps: Math.max(0, result.downloadMbps),
    uploadMbps: Math.max(0, result.uploadMbps),
    reliable: result.reliable === true,
    downloadVariationPercent: Math.max(0, result.downloadVariationPercent ?? 100),
    uploadVariationPercent: Math.max(0, result.uploadVariationPercent ?? 100),
    experienceScore: Math.max(0, result.experienceScore ?? 0)
  }
}

/** 汇总同一节点最近多次真实测试；速度只统计真正产生吞吐样本的记录。 */
export function summarizeNodeQualityHistory(samples: NodeQualityHistorySample[]): NodeQualityHistorySummary {
  const completed = samples.filter((item: NodeQualityHistorySample): boolean =>
    item.status !== 'testing' && item.checkedAt > 0)
    .slice().sort((a: NodeQualityHistorySample, b: NodeQualityHistorySample): number =>
      a.checkedAt - b.checkedAt)
  const successful = completed.filter((item: NodeQualityHistorySample): boolean => item.status === 'ok')
  const bandwidth = successful.filter((item: NodeQualityHistorySample): boolean =>
    item.downloadMbps > 0 || item.uploadMbps > 0)
  const scored = successful.filter((item: NodeQualityHistorySample): boolean => item.experienceScore > 0)
  let consecutiveFailures = 0
  for (let index = completed.length - 1; index >= 0; index--) {
    if (completed[index].status === 'ok') break
    consecutiveFailures++
  }
  const averageScore = scored.length === 0 ? 0 : Math.round(
    scored.reduce((sum: number, item: NodeQualityHistorySample): number => sum + item.experienceScore, 0) /
      scored.length)
  const reliable = successful.filter((item: NodeQualityHistorySample): boolean => item.reliable).length
  return {
    sampleCount: completed.length,
    successfulSamples: successful.length,
    successRate: completed.length === 0 ? 0 : Math.round(successful.length / completed.length * 100),
    consecutiveFailures: consecutiveFailures,
    medianDownloadMbps: medianNumber(bandwidth.map((item: NodeQualityHistorySample): number => item.downloadMbps)),
    medianUploadMbps: medianNumber(bandwidth.map((item: NodeQualityHistorySample): number => item.uploadMbps)),
    medianLatencyMs: medianNumber(successful.filter((item: NodeQualityHistorySample): boolean => item.latencyMs > 0)
      .map((item: NodeQualityHistorySample): number => item.latencyMs)),
    averageExperienceScore: averageScore,
    reliableRate: successful.length === 0 ? 0 : Math.round(reliable / successful.length * 100),
    lastCheckedAt: completed.length === 0 ? 0 : completed[completed.length - 1].checkedAt
  }
}

/**
 * 故障切换排序使用历史成功率、可靠样本和体验分，不让一次偶然峰值压过
 * 长期稳定节点。返回 0 表示没有足够证据进入自动候选。
 */
export function autoFailoverHistoryScore(summary: NodeQualityHistorySummary): number {
  if (summary.sampleCount === 0 || summary.successfulSamples === 0 || summary.consecutiveFailures >= 2) return 0
  const confidence = Math.min(1, summary.sampleCount / 3)
  const latencyFactor = summary.medianLatencyMs <= 0 ? 0.5 :
    Math.max(0, 1 - Math.min(1200, summary.medianLatencyMs) / 1200)
  const downloadFactor = Math.min(1, Math.log(1 + summary.medianDownloadMbps) / Math.log(81))
  const scoreFactor = summary.averageExperienceScore > 0 ? summary.averageExperienceScore / 100 : 0.5
  const raw = summary.successRate * 0.4 + summary.reliableRate * 0.2 +
    latencyFactor * 15 + downloadFactor * 10 + scoreFactor * 15
  return Math.max(0, Math.min(100, Math.round(raw * (0.65 + confidence * 0.35))))
}

export function selectQualityCandidates(results: QualityDelayCandidate[], limit: number = 3): string[] {
  return results.filter((item: QualityDelayCandidate): boolean => item.status === 'ok' && item.delay > 0)
    .slice()
    .sort((a: QualityDelayCandidate, b: QualityDelayCandidate): number => a.delay - b.delay)
    .slice(0, Math.max(0, limit))
    .map((item: QualityDelayCandidate): string => item.name)
}

/**
 * 轻量真实传输只用于筛选值得继续精测的节点，不当作最终带宽。
 * 使用对数速度分，并让成功率、波动和延迟占主要权重，避免小样本偶然峰值主导候选结果。
 */
export function experienceScreeningScore(result: NodeQualityResult, delayMs: number): number {
  if (result.status !== 'ok' || result.successRate <= 0 || delayMs <= 0) return 0
  const successFactor = Math.max(0, Math.min(1, result.successRate / 100))
  const variation = (Math.max(0, result.downloadVariationPercent ?? 100) +
    Math.max(0, result.uploadVariationPercent ?? 100)) / 2
  const variationFactor = Math.max(0, 1 - Math.min(100, variation) / 100)
  const latencyFactor = Math.max(0, 1 - Math.min(1200, delayMs) / 1200)
  const jitterFactor = Math.max(0, 1 - Math.min(300, result.jitterMs) / 300)
  const downloadFactor = Math.min(1, Math.log(1 + Math.max(0, result.downloadMbps)) / Math.log(81))
  const uploadFactor = Math.min(1, Math.log(1 + Math.max(0, result.uploadMbps)) / Math.log(31))
  return Math.max(0, Math.min(100, Math.round(30 * successFactor + 15 * variationFactor +
    15 * latencyFactor + 10 * jitterFactor + 22 * downloadFactor + 8 * uploadFactor)))
}

/**
 * 优先使用所有可达节点的轻量真实传输结果；若个别测速源与节点不兼容，
 * 再用可达性延迟补齐候选，交给后续双源持续测速复核。
 */
export function selectExperienceCandidates(delays: QualityDelayCandidate[], screenings: NodeQualityResult[],
  limit: number = 5): string[] {
  const count = Math.max(0, limit)
  const delayMap = new Map<string, number>()
  delays.forEach((item: QualityDelayCandidate): void => {
    if (item.status === 'ok' && item.delay > 0) delayMap.set(item.name, item.delay)
  })
  const ranked = screenings.filter((item: NodeQualityResult): boolean =>
    delayMap.has(item.name) && item.status === 'ok')
    .slice()
    .sort((a: NodeQualityResult, b: NodeQualityResult): number =>
      experienceScreeningScore(b, delayMap.get(b.name) ?? 0) -
      experienceScreeningScore(a, delayMap.get(a.name) ?? 0) ||
      (delayMap.get(a.name) ?? 0) - (delayMap.get(b.name) ?? 0))
    .map((item: NodeQualityResult): string => item.name)
  const selected: string[] = ranked.slice(0, count)
  if (selected.length < count) {
    selectQualityCandidates(delays, delays.length).forEach((name: string): void => {
      if (selected.length < count && !selected.includes(name)) selected.push(name)
    })
  }
  return selected
}

/**
 * 日常体验分只用于同一台设备、同一网络环境下的节点横向比较。
 * 连接成功与稳定性占一半权重；延迟和单连接吞吐占另一半。
 * 下载、上传采用对数曲线，避免极高带宽掩盖丢包、波动和交互延迟。
 */
export function dailyExperienceScore(result: NodeQualityResult, delayMs: number): number {
  if (result.status !== 'ok' || result.successRate <= 0 || result.downloadMbps <= 0 ||
    result.uploadMbps <= 0 || delayMs <= 0) return 0
  const successFactor = Math.max(0, Math.min(1, result.successRate / 100))
  const downloadVariation = Math.max(0, result.downloadVariationPercent ?? 100)
  const uploadVariation = Math.max(0, result.uploadVariationPercent ?? 100)
  const variation = (downloadVariation + uploadVariation) / 2
  const variationFactor = Math.max(0, 1 - Math.min(100, variation) / 100)
  const latencyFactor = Math.max(0, 1 - Math.min(1000, delayMs) / 1000)
  const downloadFactor = Math.min(1, Math.log(1 + result.downloadMbps) / Math.log(81))
  const uploadFactor = Math.min(1, Math.log(1 + result.uploadMbps) / Math.log(31))
  const score = 25 * successFactor + 10 * variationFactor +
    (result.reliable === true ? 15 : 0) + 20 * latencyFactor +
    22 * downloadFactor + 8 * uploadFactor
  return Math.max(0, Math.min(100, Math.round(score)))
}

export function nodeQualityCacheKey(profileId: string, group: string, name: string): string {
  // A named proxy is one core adapter even when several policy groups refer to
  // it. Share one result across those groups to avoid repeating paid traffic.
  return `${profileId}|${name}`
}

export function nodeQualityBrief(result?: NodeQualityResult): string {
  if (!result) return ''
  if (isBandwidthMode(result.mode) && result.mode !== 'bandwidth_single_sustained' &&
    result.mode !== 'bandwidth_multi_sustained') return '旧版测速结果，请重测'
  if (result.status === 'testing') return isBandwidthMode(result.mode) ? '持续测速中（约10–15秒）' : '稳定性检测中'
  if (result.status !== 'ok') return result.errorMessage || '质量检测失败'
  if ((result.experienceRank ?? 0) > 0) {
    return `推荐 #${result.experienceRank} · ${result.experienceScore ?? 0}分 · ` +
      `↓${result.downloadMbps} ↑${result.uploadMbps} Mbps`
  }
  if (isBandwidthMode(result.mode)) {
    const warning = result.successRate < 100 ? '·部分失败' : result.reliable === false ? '·波动大' : ''
    return `${bandwidthModeShortName(result.mode)}${warning} · ↓${result.downloadMbps} ↑${result.uploadMbps} Mbps`
  }
  return `${result.quality} · 成功${result.successRate}% · 抖动${result.jitterMs}ms`
}

export function isBandwidthMode(mode: NodeQualityMode): boolean {
  return mode !== 'stability'
}

export function bandwidthModeShortName(mode: NodeQualityMode): string {
  if (mode === 'bandwidth_single_sustained') return '单连接持续'
  if (mode === 'bandwidth_multi_sustained') return '多连接持续'
  if (mode === 'bandwidth_official') return '网页链路'
  if (mode === 'bandwidth_peak') return '峰值带宽'
  if (mode === 'bandwidth_standard') return '标准'
  if (mode === 'bandwidth_full') return '高精度'
  return '快速'
}

export function qualityErrorText(code: string): string {
  if (code.startsWith('http_')) {
    const status = code.substring('http_'.length)
    return `测速服务拒绝请求（HTTP ${status}）`
  }
  switch (code) {
    case 'timeout': return '连接超时'
    case 'dns': return 'DNS解析失败'
    case 'tls': return 'TLS握手失败'
    case 'refused': return '连接被拒绝'
    case 'connection': return '传输连接中断'
    case 'unreachable': return '网络不可达'
    case 'missing': return '节点已变更'
    case 'incomplete': return '传输未完成'
    case 'cancelled': return '测速已停止'
    case 'http': return '测速服务响应异常'
    case 'invalid': return '测速参数异常'
    default: return '质量检测失败'
  }
}

export class NodeQualityService {
  static expectedTrafficBytes(mode: NodeQualityMode): number {
    // stability: 3*192 KiB down + 2*32 KiB up = 640 KiB
    // Bandwidth tests adapt the complete request size to measured speed. A
    // fixed estimate would be misleading: faster links deliberately use more
    // data so each sample lasts long enough to be meaningful.
    if (isBandwidthMode(mode)) return 0
    return 640 * 1024
  }

  static fromCore(profileId: string, profileUpdatedAt: number, group: string,
    name: string, mode: NodeQualityMode, status: string, quality: string,
    latencyMs: number, jitterMs: number, successRate: number,
    downloadMbps: number, uploadMbps: number, transferredBytes: number,
    errorCode: string, diagnostic: string = '', reliable: boolean = false,
    downloadVariationPercent: number = 100, uploadVariationPercent: number = 100): NodeQualityResult {
    return {
      profileId: profileId,
      profileUpdatedAt: profileUpdatedAt,
      group: group,
      name: name,
      mode: mode,
      status: status,
      quality: quality,
      checkedAt: Date.now(),
      latencyMs: latencyMs,
      jitterMs: jitterMs,
      successRate: successRate,
      downloadMbps: downloadMbps,
      uploadMbps: uploadMbps,
      transferredBytes: transferredBytes,
      diagnostic: diagnostic,
      reliable: reliable,
      downloadVariationPercent: downloadVariationPercent,
      uploadVariationPercent: uploadVariationPercent,
      errorMessage: status === 'ok' ? '' : qualityErrorText(errorCode)
    }
  }
}

export default NodeQualityService
