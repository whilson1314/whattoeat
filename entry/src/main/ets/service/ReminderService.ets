// 本地提醒（reminderAgentManager，通知经华为运动健康同步手环）
// 1) 饭点提醒：时刻可在设置页调整（对照表 #6 P1 固定饭点可改）
// 2) 冰箱临期提醒（点子#13 P1）：到期前 1 天 09:00 本地通知
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppData } from '../data/AppData';
import { Db } from '../data/Db';
import { FridgeItem, todayStr, addDays } from '../model/Models';

const TAG = 'Reminder';
const DOMAIN = 0x0000;

export class ReminderService {
  // 解析 "HH:mm"，非法回退默认
  private static parseHM(hm: string, defH: number, defM: number): number[] {
    const parts = hm.split(':');
    if (parts.length === 2) {
      const h = Number(parts[0]);
      const m = Number(parts[1]);
      if (h >= 0 && h <= 23 && m >= 0 && m <= 59) {
        return [h, m];
      }
    }
    return [defH, defM];
  }

  // 刷新饭点提醒：取消旧的全部，按设置重建今天剩余饭点的一次性提醒
  static async refresh(ad: AppData): Promise<string> {
    try {
      // 取消自己发布过的
      const savedIds: number[] = await ReminderService.loadIds('reminderIds');
      for (let i = 0; i < savedIds.length; i++) {
        try {
          await reminderAgentManager.cancelReminder(savedIds[i]);
        } catch (e) {
          // 已过期的提醒可能已不存在，忽略
        }
      }
      let added = 0;
      const newIds: number[] = [];
      const now = new Date();
      const hour = now.getHours();
      const lunchHM = ReminderService.parseHM(ad.settings.lunchTime, 11, 30);
      const dinnerHM = ReminderService.parseHM(ad.settings.dinnerTime, 17, 30);
      const lunchLabel = (lunchHM[1] < 10 ? '0' + lunchHM[1] : '' + lunchHM[1]);
      const dinnerLabel = (dinnerHM[1] < 10 ? '0' + dinnerHM[1] : '' + dinnerHM[1]);
      if (ad.settings.lunchRemind && hour < lunchHM[0]) {
        const t = new Date(now.getFullYear(), now.getMonth(), now.getDate(), lunchHM[0], lunchHM[1], 0);
        const id = await ReminderService.addOne(t,
          '午饭想好吃啥了吗？🔥', '打开「今晚吃啥」挑一挑', 1001);
        newIds.push(id);
        added++;
      }
      if (ad.settings.dinnerRemind && hour < dinnerHM[0]) {
        const t = new Date(now.getFullYear(), now.getMonth(), now.getDate(), dinnerHM[0], dinnerHM[1], 0);
        const id = await ReminderService.addOne(t,
          '今晚吃啥？🔥', '打开「今晚吃啥」挑一挑', 1001);
        newIds.push(id);
        added++;
      }
      await Db.putSetting('reminderIds', JSON.stringify(newIds));
      const lunchStr = lunchHM[0] + ':' + lunchLabel;
      const dinnerStr = dinnerHM[0] + ':' + dinnerLabel;
      return added > 0 ? '已设好今天的饭点提醒 ⏰（午 ' + lunchStr + ' / 晚 ' + dinnerStr + '）'
        : '提醒已更新（今天的饭点已过，明天生效）';
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'refresh reminders failed');
      return '提醒设置失败：请在系统设置里允许本应用通知';
    }
  }

  // 冰箱临期提醒：对"明天到期"的食材各设一条次日 09:00 的本地通知
  static async refreshExpiryReminders(ad: AppData): Promise<void> {
    try {
      const savedIds: number[] = await ReminderService.loadIds('expiryReminderIds');
      for (let i = 0; i < savedIds.length; i++) {
        try {
          await reminderAgentManager.cancelReminder(savedIds[i]);
        } catch (e) {
          // 忽略
        }
      }
      const tomorrow = addDays(todayStr(), 1);
      const newIds: number[] = [];
      for (let i = 0; i < ad.fridge.length && newIds.length < 10; i++) {
        const f: FridgeItem = ad.fridge[i];
        if (f.expiryDate !== tomorrow) {
          continue;
        }
        const t = new Date();
        t.setDate(t.getDate() + 1);
        t.setHours(9, 0, 0, 0);
        const nid = 2000 + (Math.abs(ReminderService.hashStr(f.id)) % 40000);
        const id = await ReminderService.addOne(t,
          '🧊 ' + f.name + ' 明天到期', '临期食材优先吃，别浪费啦', nid);
        newIds.push(id);
      }
      await Db.putSetting('expiryReminderIds', JSON.stringify(newIds));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'expiry reminders failed');
    }
  }

  private static hashStr(s: string): number {
    let h = 0;
    for (let i = 0; i < s.length; i++) {
      h = (h * 31 + s.charCodeAt(i)) | 0;
    }
    return h;
  }

  private static async loadIds(key: string): Promise<number[]> {
    const text = await Db.getSetting(key);
    if (text === null || text.length === 0) {
      return [];
    }
    try {
      const arr: number[] = JSON.parse(text) as number[];
      return arr === null || arr === undefined ? [] : arr;
    } catch (e) {
      return [];
    }
  }

  private static async addOne(at: Date, title: string, text: string,
    notificationId: number): Promise<number> {
    const dt: reminderAgentManager.LocalDateTime = {
      year: at.getFullYear(),
      month: at.getMonth() + 1,
      day: at.getDate(),
      hour: at.getHours(),
      minute: at.getMinutes(),
      second: 0
    };
    const request: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: dt,
      title: title,
      content: text,
      expiredContent: '记得看看冰箱和菜单哦',
      notificationId: notificationId,
      slotType: notificationManager.SlotType.SOCIAL_COMMUNICATION
    };
    const id = await reminderAgentManager.publishReminder(request);
    return id;
  }
}
