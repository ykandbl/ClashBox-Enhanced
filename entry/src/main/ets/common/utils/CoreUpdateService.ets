import { connection, http } from '@kit.NetworkKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { CORE_VERSION } from 'proxy_core'
import { Xb_PreferenceUtil } from 'xb_components'

const CORE_RELEASE_API: string = 'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest'
export const CORE_RELEASES_URL: string = 'https://github.com/MetaCubeX/mihomo/releases'
const LAST_SUCCESSFUL_CHECK_KEY: string = 'core_update_last_successful_check'
const LAST_PROMPT_TAG_KEY: string = 'core_update_last_prompt_tag'
const LAST_PROMPT_AT_KEY: string = 'core_update_last_prompt_at'
const CHECK_INTERVAL_MS: number = 24 * 60 * 60 * 1000
const PROMPT_INTERVAL_MS: number = 24 * 60 * 60 * 1000
const ATTEMPT_INTERVAL_MS: number = 10 * 60 * 1000

interface GithubRelease {
  tag_name?: string
  name?: string
  published_at?: string
  html_url?: string
  body?: string
  draft?: boolean
  prerelease?: boolean
}

export interface CoreReleaseInfo {
  currentVersion: string
  latestVersion: string
  name: string
  publishedAt: string
  releaseUrl: string
  body: string
}

/** Extract the upstream semantic version from a patched build such as v1.19.30-ohos.r27. */
export function upstreamCoreVersion(version: string): string {
  const match = version.trim().match(/v?\d+\.\d+\.\d+/i)
  return match?.[0]?.startsWith('v') ? match[0] : `v${match?.[0] ?? '0.0.0'}`
}

function semanticParts(version: string): number[] {
  const match = upstreamCoreVersion(version).match(/\d+/g)
  return (match ?? ['0', '0', '0']).slice(0, 3).map((part: string): number => Number(part))
}

export function isNewerStableCore(latest: string, current: string): boolean {
  const latestParts = semanticParts(latest)
  const currentParts = semanticParts(current)
  for (let index = 0; index < 3; index++) {
    const latestPart = latestParts[index] ?? 0
    const currentPart = currentParts[index] ?? 0
    if (latestPart > currentPart) return true
    if (latestPart < currentPart) return false
  }
  return false
}

/**
 * Checks only the upstream stable release. The caller invokes this after the
 * VPN TUN and mixed proxy port are ready, and the request is explicitly sent
 * through that local proxy so GitHub reachability matches the selected node.
 */
export default class CoreUpdateService {
  private static checking: boolean = false
  private static lastAttemptAt: number = 0

  static async checkAfterVpnStarted(mixedPort: number, force: boolean = false,
    currentBuild: string = CORE_VERSION): Promise<CoreReleaseInfo | null> {
    const now = Date.now()
    if (CoreUpdateService.checking) return null
    if (!force && now - CoreUpdateService.lastAttemptAt < ATTEMPT_INTERVAL_MS) return null
    const lastSuccessfulCheck = await Xb_PreferenceUtil.get<number>(LAST_SUCCESSFUL_CHECK_KEY, 0)
    if (!force && now - lastSuccessfulCheck < CHECK_INTERVAL_MS) return null

    CoreUpdateService.checking = true
    CoreUpdateService.lastAttemptAt = now
    try {
      const release = await CoreUpdateService.fetchLatestStable(mixedPort)
      await Xb_PreferenceUtil.put(LAST_SUCCESSFUL_CHECK_KEY, Date.now())
      if (release.draft === true || release.prerelease === true) return null
      const latestVersion = upstreamCoreVersion(release.tag_name ?? '')
      const currentVersion = upstreamCoreVersion(currentBuild)
      if (!isNewerStableCore(latestVersion, currentVersion)) {
        hilog.info(0xC041, 'CoreUpdate',
          `上游稳定版检查完成 current=${currentVersion} latest=${latestVersion}`)
        return null
      }

      const lastPromptTag = await Xb_PreferenceUtil.get<string>(LAST_PROMPT_TAG_KEY, '')
      const lastPromptAt = await Xb_PreferenceUtil.get<number>(LAST_PROMPT_AT_KEY, 0)
      if (!force && lastPromptTag === latestVersion && now - lastPromptAt < PROMPT_INTERVAL_MS) return null

      const releaseUrl = CoreUpdateService.safeReleaseUrl(release.html_url ?? '')
      return {
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        name: `${release.name ?? latestVersion}`.trim() || latestVersion,
        publishedAt: `${release.published_at ?? ''}`.trim(),
        releaseUrl: releaseUrl,
        body: CoreUpdateService.trimBody(`${release.body ?? ''}`)
      }
    } finally {
      CoreUpdateService.checking = false
    }
  }

  static async markPrompted(version: string): Promise<void> {
    await Xb_PreferenceUtil.put(LAST_PROMPT_TAG_KEY, upstreamCoreVersion(version))
    await Xb_PreferenceUtil.put(LAST_PROMPT_AT_KEY, Date.now())
  }

  private static async fetchLatestStable(mixedPort: number): Promise<GithubRelease> {
    const request = http.createHttp()
    try {
      const response = await request.request(CORE_RELEASE_API, {
        method: http.RequestMethod.GET,
        header: {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'ClashBox-Harmony-Core-Update-Checker'
        },
        connectTimeout: 10000,
        readTimeout: 15000,
        usingCache: false,
        usingProxy: CoreUpdateService.httpProxy(mixedPort),
        expectDataType: http.HttpDataType.STRING
      })
      if (response.responseCode !== 200) {
        throw new Error(`GitHub Release API HTTP ${response.responseCode}`)
      }
      const content = typeof response.result === 'string' ? response.result : JSON.stringify(response.result)
      const release = JSON.parse(content) as GithubRelease
      if (!release.tag_name || release.tag_name.trim().length === 0) {
        throw new Error('GitHub Release API 未返回版本标签')
      }
      return release
    } finally {
      request.destroy()
    }
  }

  private static httpProxy(mixedPort: number): connection.HttpProxy {
    return { host: '127.0.0.1', port: mixedPort > 0 ? mixedPort : 7890, exclusionList: [] }
  }

  private static safeReleaseUrl(value: string): string {
    const normalized = value.trim()
    return /^https:\/\/github\.com\/MetaCubeX\/mihomo\/releases\//i.test(normalized) ?
      normalized : CORE_RELEASES_URL
  }

  private static trimBody(value: string): string {
    const normalized = value.trim()
    return normalized.length > 1600 ? `${normalized.slice(0, 1600)}…` : normalized
  }
}
