// HttpSync：基于自建同步服务的双机同步层
// 策略（App逻辑设计 §0 + W3 定稿）：写后即推、回前台即拉、前台 10 秒轻量轮询；
// 服务端按 updated_at 做 LWW，删除走墓碑记录；本地优先，断网照常用。
// SERVER/TOKEN 定义在 config/ServerConfig.ets（本地私有文件，不入库），
// 同时供 PushService（/register）复用。
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { relationalStore } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { Db } from '../data/Db';
import { AppData } from '../data/AppData';
import { SyncQueueItem, Recipe, MealEntry, ShoppingItem, FridgeItem, AchProgress } from '../model/Models';
import { SERVER, TOKEN } from '../config/ServerConfig';

const TAG: string = 'HttpSync';
const DOMAIN: number = 0x0000;

// 云端行（payload 为 JSON 字符串，键与本地列名一致）
class CloudRow {
  table: string = '';
  id: string = '';
  updated_at: number = 0;
  deleted: number = 0;
  payload: string = '{}';
}

class SyncResp {
  rows: CloudRow[] = [];
  server_time: number = 0;
  applied: number = 0;
}

export class SyncService {
  private static started: boolean = false;
  private static foreground: boolean = false;
  private static syncing: boolean = false;
  private static timerId: number = -1;

  // 设备唯一 ID：本地生成持久化（推送时服务端据此排除发起方），首次访问即生成
  static async ensureDeviceId(): Promise<string> {
    let id = await Db.getSetting('device_push_id');
    if (id === null || id.length === 0) {
      id = util.generateRandomUUID(true);
      await Db.putSetting('device_push_id', id);
    }
    return id;
  }

  static start(): void {
    if (SyncService.started) {
      return;
    }
    SyncService.started = true;
    SyncService.timerId = setInterval((): void => {
      if (SyncService.foreground) {
        SyncService.syncNow();
      }
    }, 10000);
  }

  static setForeground(fg: boolean): void {
    SyncService.foreground = fg;
    if (fg) {
      SyncService.syncNow();
    }
  }

  static stop(): void {
    if (SyncService.timerId >= 0) {
      clearInterval(SyncService.timerId);
      SyncService.timerId = -1;
    }
    SyncService.started = false;
  }

  // 一次完整同步：推本地队列 → 应用远端变更 → 记录 server_time
  static async syncNow(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'syncNow enter: syncing=%{public}s', '' + SyncService.syncing);
    if (SyncService.syncing) {
      return;
    }
    const ad = AppData.getInstance();
    if (!ad.isInited()) {
      hilog.info(DOMAIN, TAG, 'syncNow: not inited, skip');
      return;
    }
    SyncService.syncing = true;
    try {
      const queue: SyncQueueItem[] = await Db.getSyncQueue();
      const pushRows: CloudRow[] = [];
      for (let i = 0; i < queue.length; i++) {
        const row = await SyncService.buildPushRow(queue[i].table, queue[i].id);
        if (row !== null) {
          pushRows.push(row);
        }
      }
      const sinceStr = await Db.getSyncValue('lastSync');
      const since = sinceStr.length > 0 ? Number(sinceStr) : 0;
      // 设备 ID：服务端据此排除发起方，把计划新增推给另一台设备
      const deviceId = await SyncService.ensureDeviceId();

      const body: Record<string, Object> = {
        'since': since as Object,
        'rows': pushRows as Object,
        'device_id': deviceId as Object
      };
      const respText = await SyncService.post(JSON.stringify(body));
      const resp = JSON.parse(respText) as SyncResp;

      const remoteRows: CloudRow[] = resp.rows === undefined || resp.rows === null ? [] : resp.rows;
      for (let i = 0; i < remoteRows.length; i++) {
        try {
          await SyncService.applyCloudRow(ad, remoteRows[i]);
        } catch (e) {
          // 单行失败不影响其余
        }
      }
      await Db.clearSyncQueue(queue);
      await Db.putSyncValue('lastSync', '' + resp.server_time);
      await ad.reloadAll();
      if (pushRows.length > 0 || remoteRows.length > 0) {
        hilog.info(DOMAIN, TAG, 'sync ok: pushed=%{public}d pulled=%{public}d',
          pushRows.length, remoteRows.length);
      }
    } catch (e) {
      // 网络失败静默，下轮重试（本地优先架构的兜底）
      hilog.warn(DOMAIN, TAG, 'sync failed, will retry');
    } finally {
      SyncService.syncing = false;
    }
  }

  private static async post(body: string): Promise<string> {
    const hr = http.createHttp();
    try {
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + TOKEN
        },
        extraData: body,
        connectTimeout: 8000,
        readTimeout: 15000
      };
      const resp = await hr.request(SERVER + '/sync', opt);
      if (resp.responseCode !== 200) {
        throw new Error('http ' + resp.responseCode);
      }
      return resp.result as string;
    } finally {
      hr.destroy();
    }
  }

  // ---------- 推送行构建 ----------
  private static async buildPushRow(table: string, id: string): Promise<CloudRow | null> {
    const row = new CloudRow();
    row.table = table;
    row.id = id;
    row.updated_at = Date.now();
    if (table === 'Recipe') {
      const r = await Db.getRecipeById(id);
      if (r === null) {
        row.deleted = 1;
        row.payload = '{}';
        return row;
      }
      row.updated_at = r.updatedAt;
      const p: Record<string, Object> = {
        'id': r.id, 'name': r.name, 'emoji': r.emoji, 'cuisine': r.cuisine,
        'taste': r.taste, 'category': r.category, 'type': r.type,
        'isQuick': r.isQuick as Object, 'durationMin': r.durationMin as Object,
        'difficulty': r.difficulty as Object, 'calories': r.calories as Object,
        'protein': r.protein as Object, 'fat': r.fat as Object, 'carbs': r.carbs as Object,
        'ingredients': JSON.stringify(r.ingredients), 'steps': JSON.stringify(r.steps),
        'tips': JSON.stringify(r.tips), 'collections': JSON.stringify(r.collections),
        'favorite': r.favorite as Object, 'enabled': r.enabled as Object,
        'source': r.source, 'createdBy': r.createdBy, 'createdAt': r.createdAt as Object,
        'dislike': r.dislike as Object
      };
      row.payload = JSON.stringify(p);
      return row;
    }
    if (table === 'MealEntry') {
      const e = await Db.getEntryById(id);
      if (e === null) {
        row.deleted = 1;
        row.payload = '{}';
        return row;
      }
      row.updated_at = e.updatedAt;
      const p: Record<string, Object> = {
        'id': e.id, 'date': e.date, 'mealType': e.mealType, 'recipeId': e.recipeId,
        'dishName': e.dishName, 'emoji': e.emoji, 'pickedBy': e.pickedBy,
        'status': e.status, 'rating': e.rating as Object, 'mood': e.mood,
        'note': e.note, 'photoPath': '', 'source': e.source,
        'createdAt': e.createdAt as Object
      };
      row.payload = JSON.stringify(p);
      return row;
    }
    if (table === 'ShoppingItem') {
      const it = await Db.getItemById(id);
      if (it === null) {
        row.deleted = 1;
        row.payload = '{}';
        return row;
      }
      row.updated_at = it.updatedAt;
      const p: Record<string, Object> = {
        'id': it.id, 'name': it.name, 'amount': it.amount, 'category': it.category,
        'checked': it.checked as Object, 'inStock': it.inStock as Object,
        'addedBy': it.addedBy, 'fromRecipeId': it.fromRecipeId,
        'fromRecipeName': it.fromRecipeName, 'price': it.price as Object,
        'createdAt': it.createdAt as Object, 'archivedAt': it.archivedAt as Object
      };
      row.payload = JSON.stringify(p);
      return row;
    }
    if (table === 'FridgeItem') {
      const f = await Db.getFridgeById(id);
      if (f === null) {
        row.deleted = 1;
        row.payload = '{}';
        return row;
      }
      row.updated_at = f.updatedAt;
      const p: Record<string, Object> = {
        'id': f.id, 'name': f.name, 'amount': f.amount, 'category': f.category,
        'expiryDate': f.expiryDate, 'addedAt': f.addedAt as Object
      };
      row.payload = JSON.stringify(p);
      return row;
    }
    if (table === 'AchievementProgress') {
      const a = await Db.getAchById(id);
      if (a === null) {
        row.deleted = 1;
        row.payload = '{}';
        return row;
      }
      row.updated_at = a.updatedAt;
      const p: Record<string, Object> = {
        'id': a.id, 'unlockedAt': a.unlockedAt as Object, 'unlockedBy': a.unlockedBy
      };
      row.payload = JSON.stringify(p);
      return row;
    }
    return null;
  }

  // ---------- 远端变更应用（LWW） ----------
  private static async applyCloudRow(ad: AppData, cr: CloudRow): Promise<void> {
    const localUpdatedAt = await Db.getRowUpdatedAt(cr.table, cr.id);
    if (cr.updated_at <= localUpdatedAt) {
      return; // 本地较新或相同，跳过
    }
    if (cr.deleted === 1) {
      await SyncService.cloudDelete(cr.table, cr.id);
      return;
    }
    const o = JSON.parse(cr.payload) as Record<string, Object>;
    const store = Db.get();
    if (cr.table === 'Recipe') {
      const bucket: relationalStore.ValuesBucket = SyncService.bucketOf(o, [
        'name', 'emoji', 'cuisine', 'taste', 'category', 'type', 'ingredients', 'steps',
        'tips', 'collections', 'source', 'createdBy'
      ], ['isQuick', 'favorite', 'enabled', 'dislike'], [
        'durationMin', 'difficulty', 'calories', 'createdAt', 'protein', 'fat', 'carbs'
      ]);
      bucket['id'] = cr.id;
      bucket['updated_at'] = cr.updated_at;
      await store.insert('recipe', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } else if (cr.table === 'MealEntry') {
      let photo = o['photoPath'] === undefined ? '' : String(o['photoPath']);
      if (photo.length > 0) {
        // 照片文件在另一台设备上不存在，置空防裂图
        try {
          fileIo.accessSync(photo);
        } catch (e) {
          photo = '';
        }
      }
      const bucket: relationalStore.ValuesBucket = SyncService.bucketOf(o, [
        'date', 'mealType', 'recipeId', 'dishName', 'emoji', 'pickedBy', 'status',
        'mood', 'note', 'source'
      ], [], ['rating', 'createdAt']);
      bucket['photoPath'] = photo;
      bucket['id'] = cr.id;
      bucket['updated_at'] = cr.updated_at;
      await store.insert('meal_entry', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } else if (cr.table === 'ShoppingItem') {
      const bucket: relationalStore.ValuesBucket = SyncService.bucketOf(o, [
        'name', 'amount', 'category', 'addedBy', 'fromRecipeId', 'fromRecipeName'
      ], ['checked', 'inStock'], ['price', 'createdAt', 'archivedAt']);
      bucket['id'] = cr.id;
      bucket['updated_at'] = cr.updated_at;
      await store.insert('shopping_item', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } else if (cr.table === 'FridgeItem') {
      const bucket: relationalStore.ValuesBucket = SyncService.bucketOf(o, [
        'name', 'amount', 'category', 'expiryDate'
      ], [], ['addedAt']);
      bucket['id'] = cr.id;
      bucket['updated_at'] = cr.updated_at;
      await store.insert('fridge_item', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } else if (cr.table === 'AchievementProgress') {
      const bucket: relationalStore.ValuesBucket = SyncService.bucketOf(o, [
        'unlockedBy'
      ], [], ['unlockedAt']);
      bucket['id'] = cr.id;
      bucket['updated_at'] = cr.updated_at;
      await store.insert('ach_progress', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    }
  }

  // 按类型从 payload 取键构建 ValuesBucket
  private static bucketOf(o: Record<string, Object>,
    strs: string[], bools: string[], nums: string[]): relationalStore.ValuesBucket {
    const bucket: relationalStore.ValuesBucket = {};
    for (let i = 0; i < strs.length; i++) {
      const k = strs[i];
      bucket[k] = o[k] === undefined ? '' : String(o[k]);
    }
    for (let i = 0; i < bools.length; i++) {
      const k = bools[i];
      bucket[k] = Boolean(o[k]);
    }
    for (let i = 0; i < nums.length; i++) {
      const k = nums[i];
      // 老版本设备推送的行可能缺少新字段，NaN 落库会异常，回退 0
      const n = Number(o[k]);
      bucket[k] = isNaN(n) ? 0 : n;
    }
    return bucket;
  }

  private static async cloudDelete(table: string, id: string): Promise<void> {
    let t = 'recipe';
    if (table === 'MealEntry') {
      t = 'meal_entry';
    } else if (table === 'ShoppingItem') {
      t = 'shopping_item';
    } else if (table === 'FridgeItem') {
      t = 'fridge_item';
    } else if (table === 'AchievementProgress') {
      t = 'ach_progress';
    }
    await Db.rawSql('DELETE FROM ' + t + ' WHERE id = ?', [id]);
  }
}
