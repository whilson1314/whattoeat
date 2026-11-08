import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { router } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { AppData } from '../data/AppData';
import { SyncService } from '../sync/SyncService';
import { PushService } from '../sync/PushService';
import { ReminderService } from '../service/ReminderService';

const DOMAIN = 0x0000;
const TAG = 'WhatToEat';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    this.parseWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onNewWant');
    const nav = this.parseWant(want);
    hilog.info(DOMAIN, TAG, 'onNewWant nav=%{public}s', nav);
    if (nav.length > 0) {
      router.pushUrl({ url: 'pages/' + nav, params: { id: this.pendingId } })
        .then((): void => {
          hilog.info(DOMAIN, TAG, 'onNewWant pushUrl ok');
        })
        .catch((e: object): void => {
          hilog.error(DOMAIN, TAG, 'onNewWant pushUrl fail');
        });
    }
  }

  private pendingId: string = '';

  private parseWant(want: Want): string {
    if (want.parameters === undefined) {
      return '';
    }
    const p = want.parameters as Record<string, string>;
    const tab = p['tab'];
    if (tab !== undefined && tab !== null) {
      AppStorage.setOrCreate('launchTab', Number(tab));
    }
    const sheet = p['sheet'];
    if (sheet !== undefined && sheet !== null && sheet.length > 0) {
      AppStorage.setOrCreate('launchSheet', sheet);
    }
    const nav = p['nav'];
    if (nav !== undefined && nav !== null && nav.length > 0) {
      const rid = p['id'];
      this.pendingId = rid === undefined || rid === null ? '' : rid;
      return nav;
    }
    return '';
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  // 窗口底色与页面 bg_cream 一致：非沉浸式下状态栏/导航条区域显示窗口底色，
  // 统一后真机上不再出现上下白色"边框"。必须在 loadContent 成功后调用（窗口就绪），
  // 且捕获异常——窗口态异常时该调用会同步抛错（1300002），不能影响启动。
  // 深色模式跟随系统：窗口底色按当前 colorMode 选择（v1.1）。
  private windowColor(): string {
    try {
      const cfg = this.context.getApplicationContext().resourceManager.getConfigurationSync();
      // resourceManager.ColorMode: DARK=0, LIGHT=1
      if (cfg.colorMode === 0) {
        return '#201713';
      }
    } catch (e) {
      // 读不到就按浅色处理
    }
    return '#FFF8F0';
  }

  private applyWindowBackground(windowStage: window.WindowStage): void {
    const color = this.windowColor();
    try {
      windowStage.getMainWindow((werr: BusinessError, win: window.Window) => {
        if (werr.code !== 0) {
          hilog.error(DOMAIN, TAG, 'getMainWindow failed: %{public}s', JSON.stringify(werr));
          return;
        }
        try {
          win.setWindowBackgroundColor(color);
        } catch (e) {
          hilog.error(DOMAIN, TAG, 'setWindowBackgroundColor threw');
        }
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getMainWindow threw');
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    AppData.getInstance().init(this.context).then((): void => {
      SyncService.start();
      SyncService.syncNow(); // 初始化完成后立即首同步（不依赖前台定时器）
      // 推送注册（getToken + /register）：模拟器/未开通时降级静默
      PushService.init().catch((e: object): void => {
        hilog.warn(DOMAIN, TAG, 'push init failed: %{public}s', JSON.stringify(e));
      });
      // 通知授权：系统推送/饭点提醒/临期提醒都依赖通知开关，首次启动弹授权框
      this.requestNotifyAuth();
      // 冰箱临期提醒按最新库存重建（fire and forget）
      ReminderService.refreshExpiryReminders(AppData.getInstance()).catch((): void => {
        hilog.warn(DOMAIN, TAG, 'expiry reminders refresh failed');
      });
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, TAG, 'Succeeded in loading content.');
        this.applyWindowBackground(windowStage);
        // 处理深度链接导航
        const nav = AppStorage.get<string>('launchNav');
        if (nav !== undefined && nav.length > 0) {
          const rid = AppStorage.get<string>('launchId');
          router.pushUrl({
            url: 'pages/' + nav,
            params: { id: rid === undefined ? '' : rid }
          });
          AppStorage.setOrCreate('launchNav', '');
        }
      });
    }).catch((e: object): void => {
      hilog.error(DOMAIN, TAG, 'AppData init failed: %{public}s', JSON.stringify(e));
      // 数据层失败也加载页面，页面内有兜底提示
      windowStage.loadContent('pages/Index', () => {});
    });
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode.');
    }
  }

  // 通知授权（幂等）：用户拒绝过则不再弹，需去系统设置手动开
  private requestNotifyAuth(): void {
    try {
      notificationManager.requestEnableNotification(this.context).catch((e: BusinessError): void => {
        hilog.info(DOMAIN, TAG, 'notify auth not granted: %{public}d', e.code);
      });
    } catch (e) {
      // 不影响启动
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 系统深浅色切换时同步窗口底色
    try {
      window.getLastWindow(this.context).then((win: window.Window): void => {
        try {
          win.setWindowBackgroundColor(this.windowColor());
        } catch (e) {
          // 忽略
        }
      }).catch((): void => {
        // 忽略
      });
    } catch (e) {
      // 忽略
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
    SyncService.setForeground(true);
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
    SyncService.setForeground(false);
  }
}
