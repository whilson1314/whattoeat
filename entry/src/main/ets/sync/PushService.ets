// 华为推送（Push Kit）注册：对方点菜 → 服务端 → 华为推送 → 本机系统通知（App 未启动也送达）
// 链路：启动时 getToken + /register 上报（设备 UUID + push token + 开关状态）。
// 模拟器/未开通推送权益时 getToken 失败，静默降级不影响其他功能。
import { pushService } from '@kit.PushKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppData } from '../data/AppData';
import { SyncService } from './SyncService';
import { SERVER, TOKEN } from '../config/ServerConfig';

const TAG = 'PushService';
const DOMAIN = 0x0000;

export class PushService {
  private static registering: boolean = false;

  // App 启动调用（幂等）：确保设备 ID 存在 → getToken → 上报
  static async init(): Promise<void> {
    const ad = AppData.getInstance();
    if (!ad.isInited()) {
      return;
    }
    const deviceId = await SyncService.ensureDeviceId();
    let token = '';
    try {
      token = await pushService.getToken();
    } catch (e) {
      const err = e as BusinessError;
      // 1000900012=推送权益未开通 1000900014=设备不支持（模拟器）——都属预期降级
      hilog.warn(DOMAIN, TAG, 'getToken failed: %{public}d, 推送未启用（不影响其他功能）', err.code);
    }
    await PushService.register(deviceId, token, ad.settings.planPush);
  }

  // 开关切换后重报（只同步 enabled，token 可为空）
  static async reRegister(): Promise<boolean> {
    const ad = AppData.getInstance();
    if (!ad.isInited()) {
      return false;
    }
    try {
      const deviceId = await SyncService.ensureDeviceId();
      let token = '';
      try {
        token = await pushService.getToken();
      } catch (e) {
        // 拿不到 token 也上报开关状态；服务端不会用空 token 覆盖旧值
      }
      await PushService.register(deviceId, token, ad.settings.planPush);
      return true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'reRegister failed');
      return false;
    }
  }

  private static async register(deviceId: string, token: string, enabled: boolean): Promise<void> {
    if (PushService.registering) {
      return;
    }
    PushService.registering = true;
    const hr = http.createHttp();
    try {
      const body: Record<string, Object> = {
        'device_id': deviceId as Object,
        'push_token': token as Object,
        'enabled': enabled as Object
      };
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + TOKEN
        },
        extraData: JSON.stringify(body),
        connectTimeout: 8000,
        readTimeout: 8000
      };
      const resp = await hr.request(SERVER + '/register', opt);
      if (resp.responseCode === 200) {
        hilog.info(DOMAIN, TAG, 'registered: enabled=%{public}s tokenLen=%{public}d',
          '' + enabled, token.length);
      } else {
        hilog.warn(DOMAIN, TAG, 'register http %{public}d', resp.responseCode);
      }
    } finally {
      hr.destroy();
      PushService.registering = false;
    }
  }
}
