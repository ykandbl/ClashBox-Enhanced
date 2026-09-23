import { connection, http } from '@kit.NetworkKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { Xb_PreferenceUtil } from 'xb_components'

export const APP_REPOSITORY_URL: string = 'https://github.com/ykandbl/ClashBox-Enhanced'
export const APP_RELEASES_URL: string = `${APP_REPOSITORY_URL}/releases`

const APP_RELEASE_API: string = `${APP_REPOSITORY_URL.replace('github.com/', 'api.github.com/repos/')}/releases/latest`
const LAST_SUCCESSFUL_CHECK_KEY: string = 'app_update_last_successful_check'
const LAST_PROMPT_TAG_KEY: string = 'app_update_last_prompt_tag'
const LAST_PROMPT_AT_KEY: string = 'app_update_last_prompt_at'
const CHECK_INTERVAL_MS: number = 24 * 60 * 60 * 1000
const PROMPT_INTERVAL_MS: number = 24 * 60 * 60 * 1000
const ATTEMPT_INTERVAL_MS: number = 10 * 60 * 1000

interface GithubAsset {
  name?: string
  browser_download_url?: string
}

interface GithubRelease {
  tag_name?: string
  name?: string
  published_at?: string
  html_url?: string
  body?: string
  draft?: boolean
  prerelease?: boolean
  assets?: GithubAsset[]
}

export interface AppReleaseInfo {
  currentVersion: string
  latestVersion: string
  name: string
  publishedAt: string
  releaseUrl: string
  downloadUrl: string
  body: string
}

function versionParts(version: string): number[] {
  const match = version.trim().replace(/^v/i, '').match(/\d+/g)
  return (match ?? ['0', '0', '0']).slice(0, 3).map((part: string): number => Number(part))
}

export function isNewerAppVersion(latest: string, current: string): boolean {
  const latestParts = versionParts(latest)
  const currentParts = versionParts(current)
  for (let index = 0; index < 3; index++) {
    const latestPart = latestParts[index] ?? 0
    const currentPart = currentParts[index] ?? 0
    if (latestPart > currentPart) return true
    if (latestPart < currentPart) return false
  }
  return false
}

function normalizedVersion(version: string): string {
  const value = version.trim()
  return value.startsWith('v') ? value : `v${value}`
}

/** 检查自维护仓库的稳定 Release。请求经过当前 VPN 的 mixed-port。 */
export default class AppReleaseUpdateService {
  private static checking: boolean = false
  private static lastAttemptAt: number = 0

  static async checkAfterVpnStarted(mixedPort: number, currentVersion: string,
    force: boolean = false): Promise<AppReleaseInfo | null> {
    const now = Date.now()
    if (AppReleaseUpdateService.checking) return null
    if (!force && now - AppReleaseUpdateService.lastAttemptAt < ATTEMPT_INTERVAL_MS) return null
    const lastSuccessfulCheck = await Xb_PreferenceUtil.get<number>(LAST_SUCCESSFUL_CHECK_KEY, 0)
    if (!force && now - lastSuccessfulCheck < CHECK_INTERVAL_MS) return null

    AppReleaseUpdateService.checking = true
    AppReleaseUpdateService.lastAttemptAt = now
    try {
      const release = await AppReleaseUpdateService.fetchLatest(mixedPort)
      await Xb_PreferenceUtil.put(LAST_SUCCESSFUL_CHECK_KEY, Date.now())
      if (release.draft === true || release.prerelease === true || !release.tag_name) return null

      const latestVersion = normalizedVersion(release.tag_name)
      if (!isNewerAppVersion(latestVersion, currentVersion)) {
        hilog.info(0xC042, 'AppUpdate',
          `自维护版本检查完成 current=${currentVersion} latest=${latestVersion}`)
        return null
      }

      const lastPromptTag = await Xb_PreferenceUtil.get<string>(LAST_PROMPT_TAG_KEY, '')
      const lastPromptAt = await Xb_PreferenceUtil.get<number>(LAST_PROMPT_AT_KEY, 0)
      if (!force && lastPromptTag === latestVersion && now - lastPromptAt < PROMPT_INTERVAL_MS) return null

      const releaseUrl = AppReleaseUpdateService.safeReleaseUrl(release.html_url ?? '')
      const asset = (release.assets ?? []).find((item: GithubAsset): boolean =>
        `${item.name ?? ''}`.toLowerCase().endsWith('.hap'))
      const downloadUrl = AppReleaseUpdateService.safeDownloadUrl(asset?.browser_download_url ?? '')
      return {
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        name: `${release.name ?? latestVersion}`.trim() || latestVersion,
        publishedAt: `${release.published_at ?? ''}`.trim(),
        releaseUrl: releaseUrl,
        downloadUrl: downloadUrl,
        body: AppReleaseUpdateService.trimBody(`${release.body ?? ''}`)
      }
    } finally {
      AppReleaseUpdateService.checking = false
    }
  }

  static async markPrompted(version: string): Promise<void> {
    await Xb_PreferenceUtil.put(LAST_PROMPT_TAG_KEY, normalizedVersion(version))
    await Xb_PreferenceUtil.put(LAST_PROMPT_AT_KEY, Date.now())
  }

  private static async fetchLatest(mixedPort: number): Promise<GithubRelease> {
    const request = http.createHttp()
    try {
      const response = await request.request(APP_RELEASE_API, {
        method: http.RequestMethod.GET,
        header: {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'ClashBox-Enhanced-Update-Checker'
        },
        connectTimeout: 10000,
        readTimeout: 15000,
        usingCache: false,
        usingProxy: AppReleaseUpdateService.httpProxy(mixedPort),
        expectDataType: http.HttpDataType.STRING
      })
      if (response.responseCode !== 200) {
        throw new Error(`自维护 Release API HTTP ${response.responseCode}`)
      }
      const content = typeof response.result === 'string' ? response.result : JSON.stringify(response.result)
      return JSON.parse(content) as GithubRelease
    } finally {
      request.destroy()
    }
  }

  private static httpProxy(mixedPort: number): connection.HttpProxy {
    return { host: '127.0.0.1', port: mixedPort > 0 ? mixedPort : 7890, exclusionList: [] }
  }

  private static safeReleaseUrl(value: string): string {
    const normalized = value.trim()
    return new RegExp(`^${APP_REPOSITORY_URL}/releases/`, 'i').test(normalized) ?
      normalized : APP_RELEASES_URL
  }

  private static safeDownloadUrl(value: string): string {
    const normalized = value.trim()
    return /^https:\/\/github\.com\/ykandbl\/ClashBox-Enhanced\/releases\/download\//i.test(normalized) ?
      normalized : ''
  }

  private static trimBody(value: string): string {
    const normalized = value.trim()
    return normalized.length > 1600 ? `${normalized.slice(0, 1600)}…` : normalized
  }
}
