export interface DiagnosticProfileSnapshot {
  id: string
  provider: string
  accountState: string
  subscriptionState: string
  subscriptionFormat: string
  subscriptionNodeCount: number
  lastGoodContentId: string
  subscriptionPendingRepair: boolean
  subscriptionRetryAt: number
  coreLoadState: string
  coreLoadedContentId: string
  coreLoadedAt: number
  lastError: string
}

export interface DiagnosticSnapshot {
  generatedAt: string
  appVersion: string
  coreVersion: string
  vpnRunning: boolean
  tunHealthy: boolean
  backgroundTaskRunning: boolean
  offlineRecordCount: number
  profiles: DiagnosticProfileSnapshot[]
  recentErrors: string[]
}

interface RedactedDiagnosticPackage {
  schema: string
  generatedAt: string
  appVersion: string
  coreVersion: string
  vpnRunning: boolean
  tunHealthy: boolean
  backgroundTaskRunning: boolean
  offlineRecordCount: number
  profiles: DiagnosticProfileSnapshot[]
  recentErrors: string[]
}

function redact(value: string): string {
  return value
    .replace(/https?:\/\/[^\s)]+/gi, '[redacted-url]')
    .replace(/(?:authorization|token|password|secret|cookie)\s*[:=]\s*[^,;\s]+/gi, '$1=[redacted]')
    .replace(/[A-Za-z0-9+/=_-]{48,}/g, '[redacted-value]')
    .slice(0, 240)
}

/** JSON package intentionally contains identifiers and state, never config/URL/credential data. */
export function buildRedactedDiagnostics(snapshot: DiagnosticSnapshot): string {
  const profiles: DiagnosticProfileSnapshot[] = snapshot.profiles.map(
    (profile: DiagnosticProfileSnapshot): DiagnosticProfileSnapshot => ({
      id: profile.id,
      provider: profile.provider,
      accountState: profile.accountState,
      subscriptionState: profile.subscriptionState,
      subscriptionFormat: profile.subscriptionFormat,
      subscriptionNodeCount: profile.subscriptionNodeCount,
      lastGoodContentId: profile.lastGoodContentId,
      subscriptionPendingRepair: profile.subscriptionPendingRepair,
      subscriptionRetryAt: profile.subscriptionRetryAt,
      coreLoadState: profile.coreLoadState,
      coreLoadedContentId: profile.coreLoadedContentId,
      coreLoadedAt: profile.coreLoadedAt,
      lastError: redact(profile.lastError)
    }))
  const safe: RedactedDiagnosticPackage = {
    schema: 'clashbox-diagnostics/v1',
    generatedAt: snapshot.generatedAt,
    appVersion: snapshot.appVersion,
    coreVersion: snapshot.coreVersion,
    vpnRunning: snapshot.vpnRunning,
    tunHealthy: snapshot.tunHealthy,
    backgroundTaskRunning: snapshot.backgroundTaskRunning,
    offlineRecordCount: snapshot.offlineRecordCount,
    profiles: profiles,
    recentErrors: snapshot.recentErrors.map((value: string) => redact(value)).filter((value: string) => value.length > 0)
  }
  return JSON.stringify(safe, null, 2)
}
