import { common } from '@kit.AbilityKit'
import { notificationManager } from '@kit.NotificationKit'
import { Xb_NotificationUtils, Xb_SecureKVdbUtil } from 'xb_components'
import { Profile } from 'proxy_core'
import { buildSubscriptionExpiryNotice } from './SubscriptionExpiryNoticeLogic'

const NOTICE_KEY_PREFIX: string = 'subscription_expiry_notice_'

/** Emits one notice per threshold/day and survives process restarts. */
export class SubscriptionExpiryReminderService {
  static async check(context: common.Context, profiles: Profile[]): Promise<void> {
    for (const profile of profiles) {
      const expire = Number(profile.subscriptionInfo?.expire ?? 0)
      const notice = buildSubscriptionExpiryNotice(profile.id, expire)
      if (!notice) continue
      const key = NOTICE_KEY_PREFIX + profile.id
      let previous = ''
      try {
        const value = await Xb_SecureKVdbUtil.getData(key)
        previous = typeof value === 'string' ? value : ''
      } catch (_) {
      }
      if (previous === notice.marker) continue
      await Xb_NotificationUtils.publishTextNotification(
        context as common.UIAbilityContext,
        2000000 + (SubscriptionExpiryReminderService.hash(profile.id) % 500000),
        { title: 'ClashBox · ' + notice.title, text: notice.text },
        notificationManager.SlotType.SERVICE_INFORMATION,
        { abilityName: 'EntryAbility' }
      )
      try {
        await Xb_SecureKVdbUtil.putData(key, notice.marker)
      } catch (_) {
        // Notification delivery remains useful even if the dedupe store is unavailable.
      }
    }
  }

  private static hash(value: string): number {
    let hash = 0
    for (let index = 0; index < value.length; index++) {
      hash = ((hash * 31) + value.charCodeAt(index)) & 0x7fffffff
    }
    return hash
  }
}

export default SubscriptionExpiryReminderService
