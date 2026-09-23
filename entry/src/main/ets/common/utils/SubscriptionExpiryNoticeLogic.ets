export interface SubscriptionExpiryNotice {
  marker: string
  title: string
  text: string
  severity: 'warning' | 'expired'
}

const DAY_MS: number = 24 * 60 * 60 * 1000

/** Pure decision logic kept separate so expiry thresholds are fixture-testable. */
export function buildSubscriptionExpiryNotice(profileId: string, expireAt: number,
  now: number = Date.now()): SubscriptionExpiryNotice | null {
  if (!profileId || !Number.isFinite(expireAt) || expireAt <= 0) return null
  const expireMs = expireAt > 100000000000 ? expireAt : expireAt * 1000
  const diff = expireMs - now
  const dayBucket = Math.floor(expireMs / DAY_MS)
  if (diff <= 0) {
    return {
      marker: `${profileId}:expired:${dayBucket}`,
      title: '订阅已到期',
      text: '订阅已到期，请续费后重新加载配置。当前仍保留最后可用配置。',
      severity: 'expired'
    }
  }
  const days = Math.ceil(diff / DAY_MS)
  const threshold = days <= 1 ? 1 : days <= 3 ? 3 : days <= 7 ? 7 : 0
  if (threshold === 0) return null
  return {
    marker: `${profileId}:${threshold}:${dayBucket}`,
    title: `订阅将在 ${threshold} 天后到期`,
    text: `订阅有效期不足 ${threshold} 天，请及时续费。`,
    severity: 'warning'
  }
}
