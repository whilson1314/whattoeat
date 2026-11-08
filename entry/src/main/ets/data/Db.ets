// SQLite 持久层（relationalStore）
import { relationalStore } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import {
  Recipe, MealEntry, ShoppingItem, FridgeItem, AchProgress, Ingredient, SyncQueueItem
} from '../model/Models';

const DB_NAME: string = 'whattoeat.db';

const SQL_CREATE: string[] = [
  `CREATE TABLE IF NOT EXISTS recipe (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, emoji TEXT, cuisine TEXT, taste TEXT,
    category TEXT, type TEXT, isQuick INTEGER, durationMin INTEGER, difficulty INTEGER,
    calories INTEGER, protein INTEGER, fat INTEGER, carbs INTEGER,
    ingredients TEXT, steps TEXT, tips TEXT, collections TEXT,
    favorite INTEGER, enabled INTEGER, source TEXT, createdBy TEXT, createdAt INTEGER, dislike INTEGER
  )`,
  `CREATE TABLE IF NOT EXISTS meal_entry (
    id TEXT PRIMARY KEY, date TEXT NOT NULL, mealType TEXT, recipeId TEXT, dishName TEXT,
    emoji TEXT, pickedBy TEXT, status TEXT, rating INTEGER, mood TEXT, note TEXT,
    photoPath TEXT, source TEXT, createdAt INTEGER
  )`,
  `CREATE INDEX IF NOT EXISTS idx_entry_date ON meal_entry(date)`,
  `CREATE TABLE IF NOT EXISTS shopping_item (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, amount TEXT, category TEXT,
    checked INTEGER, inStock INTEGER, addedBy TEXT, fromRecipeId TEXT,
    fromRecipeName TEXT, price REAL, createdAt INTEGER, archivedAt INTEGER
  )`,
  `CREATE TABLE IF NOT EXISTS fridge_item (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, amount TEXT, category TEXT,
    expiryDate TEXT, addedAt INTEGER
  )`,
  `CREATE TABLE IF NOT EXISTS ach_progress (
    id TEXT PRIMARY KEY, unlockedAt INTEGER, unlockedBy TEXT, updated_at INTEGER
  )`,
  `CREATE TABLE IF NOT EXISTS app_setting (
    key TEXT PRIMARY KEY, value TEXT
  )`
];

export class Db {
  private static store: relationalStore.RdbStore | null = null;

  static async init(context: Context): Promise<void> {
    if (Db.store !== null) {
      return;
    }
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store = await relationalStore.getRdbStore(context, config);
    for (let i = 0; i < SQL_CREATE.length; i++) {
      await store.executeSql(SQL_CREATE[i]);
    }
    Db.store = store;
    await Db.migrate();
  }

  // 增量迁移：老库补 updated_at / 新增列 + 建同步队列表
  private static async migrate(): Promise<void> {
    const store = Db.get();
    const tables = ['recipe', 'meal_entry', 'shopping_item', 'fridge_item', 'ach_progress'];
    for (let i = 0; i < tables.length; i++) {
      try {
        await store.executeSql('ALTER TABLE ' + tables[i] + ' ADD COLUMN updated_at INTEGER DEFAULT 0');
      } catch (e) {
        // 列已存在则忽略
      }
    }
    // v2.2 增量列：收藏分组 / 营养字段 / 清单归档
    const colAttempts: string[] = [
      'ALTER TABLE recipe ADD COLUMN collections TEXT',
      'ALTER TABLE recipe ADD COLUMN protein INTEGER DEFAULT 0',
      'ALTER TABLE recipe ADD COLUMN fat INTEGER DEFAULT 0',
      'ALTER TABLE recipe ADD COLUMN carbs INTEGER DEFAULT 0',
      'ALTER TABLE shopping_item ADD COLUMN archivedAt INTEGER DEFAULT 0'
    ];
    for (let i = 0; i < colAttempts.length; i++) {
      try {
        await store.executeSql(colAttempts[i]);
      } catch (e) {
        // 列已存在则忽略
      }
    }
    // 防御清理：历史版本可能写入过空 id 行（无法入同步队列），直接清掉
    const emptyIdTables = ['recipe', 'meal_entry', 'shopping_item', 'fridge_item'];
    for (let i = 0; i < emptyIdTables.length; i++) {
      try {
        await store.executeSql('DELETE FROM ' + emptyIdTables[i] + " WHERE id = ''");
      } catch (e) {
        // 忽略
      }
    }
    try {
      await store.executeSql(`CREATE TABLE IF NOT EXISTS sync_queue (
        table_name TEXT NOT NULL,
        id TEXT NOT NULL,
        PRIMARY KEY (table_name, id)
      )`);
    } catch (e) {
      // 已存在
    }
    try {
      await store.executeSql(`CREATE TABLE IF NOT EXISTS kv_sync (
        key TEXT PRIMARY KEY, value TEXT
      )`);
    } catch (e) {
      // 已存在
    }
  }

  // ---------- 同步队列（写操作统一入队，HttpSync 消费） ----------
  static async queueSync(table: string, id: string): Promise<void> {
    if (Db.store === null || id.length === 0) {
      return;
    }
    try {
      const bucket: relationalStore.ValuesBucket = { 'table_name': table, 'id': id };
      await Db.store.insert('sync_queue', bucket,
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } catch (e) {
      // 队列失败不阻断本地写
    }
  }

  static async getSyncQueue(): Promise<SyncQueueItem[]> {
    const pred = new relationalStore.RdbPredicates('sync_queue');
    const rs = await Db.get().query(pred);
    const out: SyncQueueItem[] = [];
    while (rs.goToNextRow()) {
      const q = new SyncQueueItem();
      q.table = rs.getString(rs.getColumnIndex('table_name'));
      q.id = rs.getString(rs.getColumnIndex('id'));
      out.push(q);
    }
    rs.close();
    return out;
  }

  static async clearSyncQueue(items: SyncQueueItem[]): Promise<void> {
    for (let i = 0; i < items.length; i++) {
      const pred = new relationalStore.RdbPredicates('sync_queue');
      pred.equalTo('table_name', items[i].table).equalTo('id', items[i].id);
      try {
        await Db.get().delete(pred);
      } catch (e) {
        // 忽略
      }
    }
  }

  // ---------- 按 id 读取（同步合并用，含 updatedAt） ----------
  static async getRecipeById(id: string): Promise<Recipe | null> {
    const pred = new relationalStore.RdbPredicates('recipe');
    pred.equalTo('id', id);
    const rs = await Db.get().query(pred);
    let r: Recipe | null = null;
    if (rs.goToFirstRow()) {
      r = Db.recipeFromRow(rs);
    }
    rs.close();
    return r;
  }

  static async getEntryById(id: string): Promise<MealEntry | null> {
    const pred = new relationalStore.RdbPredicates('meal_entry');
    pred.equalTo('id', id);
    const rs = await Db.get().query(pred);
    let e: MealEntry | null = null;
    if (rs.goToFirstRow()) {
      e = Db.entryFromRow(rs);
    }
    rs.close();
    return e;
  }

  static async getItemById(id: string): Promise<ShoppingItem | null> {
    const pred = new relationalStore.RdbPredicates('shopping_item');
    pred.equalTo('id', id);
    const rs = await Db.get().query(pred);
    let it: ShoppingItem | null = null;
    if (rs.goToFirstRow()) {
      it = Db.itemFromRow(rs);
    }
    rs.close();
    return it;
  }

  static async getFridgeById(id: string): Promise<FridgeItem | null> {
    const pred = new relationalStore.RdbPredicates('fridge_item');
    pred.equalTo('id', id);
    const rs = await Db.get().query(pred);
    let f: FridgeItem | null = null;
    if (rs.goToFirstRow()) {
      f = Db.fridgeFromRow(rs);
    }
    rs.close();
    return f;
  }

  static async getAchById(id: string): Promise<AchProgress | null> {
    const pred = new relationalStore.RdbPredicates('ach_progress');
    pred.equalTo('id', id);
    const rs = await Db.get().query(pred);
    let p: AchProgress | null = null;
    if (rs.goToFirstRow()) {
      p = new AchProgress();
      p.id = rs.getString(rs.getColumnIndex('id'));
      p.unlockedAt = rs.getLong(rs.getColumnIndex('unlockedAt'));
      p.unlockedBy = rs.getString(rs.getColumnIndex('unlockedBy'));
      p.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
    }
    rs.close();
    return p;
  }

  static async getRowUpdatedAt(table: string, id: string): Promise<number> {
    let t = table;
    if (t === 'AchievementProgress') {
      t = 'ach_progress';
    } else if (t.length > 0) {
      t = t.charAt(0).toLowerCase() + t.slice(1).replace(/[A-Z]/g, (c: string): string => '_' + c.toLowerCase());
    }
    try {
      const rs = await Db.get().querySql('SELECT updated_at FROM ' + t + ' WHERE id = ?', [id]);
      let v = 0;
      if (rs.goToFirstRow()) {
        v = rs.getLong(rs.getColumnIndex('updated_at'));
      }
      rs.close();
      return v;
    } catch (e) {
      return 0;
    }
  }

  static async getSyncValue(key: string): Promise<string> {
    return Db.getSetting('kv_sync_' + key);
  }

  static async putSyncValue(key: string, value: string): Promise<void> {
    await Db.putSetting('kv_sync_' + key, value);
  }

  static get(): relationalStore.RdbStore {
    if (Db.store === null) {
      throw new Error('Db not initialized');
    }
    return Db.store;
  }

  // ---------- 通用 ----------
  static async rawSql(sql: string, args?: Array<relationalStore.ValueType>): Promise<void> {
    if (args === undefined) {
      await Db.get().executeSql(sql);
    } else {
      await Db.get().executeSql(sql, args);
    }
  }

  static async count(table: string): Promise<number> {
    const pred = new relationalStore.RdbPredicates(table);
    const rs = await Db.get().query(pred, ['COUNT(*) AS c']);
    let n: number = 0;
    if (rs.goToFirstRow()) {
      n = rs.getLong(rs.getColumnIndex('c'));
    }
    rs.close();
    return n;
  }

  // ---------- Recipe ----------
  static recipeFromRow(rs: relationalStore.ResultSet): Recipe {
    const r = new Recipe();
    r.id = rs.getString(rs.getColumnIndex('id'));
    r.name = rs.getString(rs.getColumnIndex('name'));
    r.emoji = rs.getString(rs.getColumnIndex('emoji')) || '🍽️';
    r.cuisine = rs.getString(rs.getColumnIndex('cuisine'));
    r.taste = rs.getString(rs.getColumnIndex('taste'));
    r.category = rs.getString(rs.getColumnIndex('category'));
    r.type = rs.getString(rs.getColumnIndex('type'));
    r.isQuick = rs.getLong(rs.getColumnIndex('isQuick')) === 1;
    r.durationMin = rs.getLong(rs.getColumnIndex('durationMin'));
    r.difficulty = rs.getLong(rs.getColumnIndex('difficulty'));
    r.calories = rs.getLong(rs.getColumnIndex('calories'));
    r.ingredients = Db.parseIngredients(rs.getString(rs.getColumnIndex('ingredients')));
    r.steps = Db.parseStringArr(rs.getString(rs.getColumnIndex('steps')));
    r.tips = Db.parseStringArr(rs.getString(rs.getColumnIndex('tips')));
    r.favorite = rs.getLong(rs.getColumnIndex('favorite')) === 1;
    r.enabled = rs.getLong(rs.getColumnIndex('enabled')) === 1;
    r.source = rs.getString(rs.getColumnIndex('source'));
    r.createdBy = rs.getString(rs.getColumnIndex('createdBy'));
    r.createdAt = rs.getLong(rs.getColumnIndex('createdAt'));
    r.dislike = rs.getLong(rs.getColumnIndex('dislike')) === 1;
    const colText = rs.getString(rs.getColumnIndex('collections'));
    r.collections = colText === null ? [] : Db.parseStringArr(colText);
    r.protein = rs.getLong(rs.getColumnIndex('protein'));
    r.fat = rs.getLong(rs.getColumnIndex('fat'));
    r.carbs = rs.getLong(rs.getColumnIndex('carbs'));
    r.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
    return r;
  }

  static async insertRecipe(r: Recipe): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'id': r.id, 'name': r.name, 'emoji': r.emoji, 'cuisine': r.cuisine,
      'taste': r.taste, 'category': r.category, 'type': r.type,
      'isQuick': r.isQuick ? 1 : 0, 'durationMin': r.durationMin, 'difficulty': r.difficulty,
      'calories': r.calories, 'protein': r.protein, 'fat': r.fat, 'carbs': r.carbs,
      'ingredients': JSON.stringify(r.ingredients), 'steps': JSON.stringify(r.steps),
      'tips': JSON.stringify(r.tips), 'collections': JSON.stringify(r.collections),
      'favorite': r.favorite ? 1 : 0, 'enabled': r.enabled ? 1 : 0,
      'source': r.source, 'createdBy': r.createdBy, 'createdAt': r.createdAt,
      'dislike': r.dislike ? 1 : 0, 'updated_at': Date.now()
    };
    await Db.get().insert('recipe', bucket);
    await Db.queueSync('Recipe', r.id);
  }

  static async updateRecipe(r: Recipe): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'name': r.name, 'emoji': r.emoji, 'cuisine': r.cuisine, 'taste': r.taste,
      'category': r.category, 'type': r.type, 'isQuick': r.isQuick ? 1 : 0,
      'durationMin': r.durationMin, 'difficulty': r.difficulty, 'calories': r.calories,
      'protein': r.protein, 'fat': r.fat, 'carbs': r.carbs,
      'ingredients': JSON.stringify(r.ingredients), 'steps': JSON.stringify(r.steps),
      'tips': JSON.stringify(r.tips), 'collections': JSON.stringify(r.collections),
      'favorite': r.favorite ? 1 : 0, 'enabled': r.enabled ? 1 : 0,
      'dislike': r.dislike ? 1 : 0, 'updated_at': Date.now()
    };
    const pred = new relationalStore.RdbPredicates('recipe');
    pred.equalTo('id', r.id);
    await Db.get().update(bucket, pred);
    await Db.queueSync('Recipe', r.id);
  }

  static async deleteRecipe(id: string): Promise<void> {
    const pred = new relationalStore.RdbPredicates('recipe');
    pred.equalTo('id', id);
    await Db.get().delete(pred);
    await Db.queueSync('Recipe', id);
  }

  static async allRecipes(): Promise<Recipe[]> {
    const pred = new relationalStore.RdbPredicates('recipe');
    pred.orderByAsc('name');
    const rs = await Db.get().query(pred);
    const out: Recipe[] = [];
    while (rs.goToNextRow()) {
      out.push(Db.recipeFromRow(rs));
    }
    rs.close();
    return out;
  }

  // ---------- MealEntry ----------
  static entryFromRow(rs: relationalStore.ResultSet): MealEntry {
    const e = new MealEntry();
    e.id = rs.getString(rs.getColumnIndex('id'));
    e.date = rs.getString(rs.getColumnIndex('date'));
    e.mealType = rs.getString(rs.getColumnIndex('mealType'));
    e.recipeId = rs.getString(rs.getColumnIndex('recipeId'));
    e.dishName = rs.getString(rs.getColumnIndex('dishName'));
    e.emoji = rs.getString(rs.getColumnIndex('emoji')) || '🍽️';
    e.pickedBy = rs.getString(rs.getColumnIndex('pickedBy'));
    e.status = rs.getString(rs.getColumnIndex('status'));
    e.rating = rs.getLong(rs.getColumnIndex('rating'));
    e.mood = rs.getString(rs.getColumnIndex('mood'));
    e.note = rs.getString(rs.getColumnIndex('note'));
    e.photoPath = rs.getString(rs.getColumnIndex('photoPath'));
    e.source = rs.getString(rs.getColumnIndex('source'));
    e.createdAt = rs.getLong(rs.getColumnIndex('createdAt'));
    e.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
    return e;
  }

  static async insertEntry(e: MealEntry): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'id': e.id, 'date': e.date, 'mealType': e.mealType, 'recipeId': e.recipeId,
      'dishName': e.dishName, 'emoji': e.emoji, 'pickedBy': e.pickedBy,
      'status': e.status, 'rating': e.rating, 'mood': e.mood, 'note': e.note,
      'photoPath': e.photoPath, 'source': e.source, 'createdAt': e.createdAt,
      'updated_at': Date.now()
    };
    await Db.get().insert('meal_entry', bucket);
    await Db.queueSync('MealEntry', e.id);
  }

  static async updateEntry(e: MealEntry): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'date': e.date, 'mealType': e.mealType, 'recipeId': e.recipeId,
      'dishName': e.dishName, 'emoji': e.emoji, 'pickedBy': e.pickedBy,
      'status': e.status, 'rating': e.rating, 'mood': e.mood, 'note': e.note,
      'photoPath': e.photoPath, 'source': e.source, 'updated_at': Date.now()
    };
    const pred = new relationalStore.RdbPredicates('meal_entry');
    pred.equalTo('id', e.id);
    await Db.get().update(bucket, pred);
    await Db.queueSync('MealEntry', e.id);
  }

  static async deleteEntry(id: string): Promise<void> {
    const pred = new relationalStore.RdbPredicates('meal_entry');
    pred.equalTo('id', id);
    await Db.get().delete(pred);
    await Db.queueSync('MealEntry', id);
  }

  static async entriesBetween(start: string, end: string): Promise<MealEntry[]> {
    const pred = new relationalStore.RdbPredicates('meal_entry');
    pred.greaterThanOrEqualTo('date', start).lessThanOrEqualTo('date', end);
    pred.orderByDesc('createdAt');
    const rs = await Db.get().query(pred);
    const out: MealEntry[] = [];
    while (rs.goToNextRow()) {
      out.push(Db.entryFromRow(rs));
    }
    rs.close();
    return out;
  }

  static async allEntries(): Promise<MealEntry[]> {
    const pred = new relationalStore.RdbPredicates('meal_entry');
    pred.orderByDesc('createdAt');
    const rs = await Db.get().query(pred);
    const out: MealEntry[] = [];
    while (rs.goToNextRow()) {
      out.push(Db.entryFromRow(rs));
    }
    rs.close();
    return out;
  }

  // ---------- ShoppingItem ----------
  static itemFromRow(rs: relationalStore.ResultSet): ShoppingItem {
    const it = new ShoppingItem();
    it.id = rs.getString(rs.getColumnIndex('id'));
    it.name = rs.getString(rs.getColumnIndex('name'));
    it.amount = rs.getString(rs.getColumnIndex('amount'));
    it.category = rs.getString(rs.getColumnIndex('category')) || '其他';
    it.checked = rs.getLong(rs.getColumnIndex('checked')) === 1;
    it.inStock = rs.getLong(rs.getColumnIndex('inStock')) === 1;
    it.addedBy = rs.getString(rs.getColumnIndex('addedBy'));
    it.fromRecipeId = rs.getString(rs.getColumnIndex('fromRecipeId'));
    it.fromRecipeName = rs.getString(rs.getColumnIndex('fromRecipeName'));
    it.price = rs.getDouble(rs.getColumnIndex('price'));
    it.createdAt = rs.getLong(rs.getColumnIndex('createdAt'));
    it.archivedAt = rs.getLong(rs.getColumnIndex('archivedAt'));
    it.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
    return it;
  }

  static async insertItem(it: ShoppingItem): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'id': it.id, 'name': it.name, 'amount': it.amount, 'category': it.category,
      'checked': it.checked ? 1 : 0, 'inStock': it.inStock ? 1 : 0,
      'addedBy': it.addedBy, 'fromRecipeId': it.fromRecipeId,
      'fromRecipeName': it.fromRecipeName, 'price': it.price, 'createdAt': it.createdAt,
      'archivedAt': it.archivedAt, 'updated_at': Date.now()
    };
    await Db.get().insert('shopping_item', bucket);
    await Db.queueSync('ShoppingItem', it.id);
  }

  static async updateItem(it: ShoppingItem): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'name': it.name, 'amount': it.amount, 'category': it.category,
      'checked': it.checked ? 1 : 0, 'inStock': it.inStock ? 1 : 0,
      'fromRecipeName': it.fromRecipeName, 'price': it.price,
      'archivedAt': it.archivedAt, 'updated_at': Date.now()
    };
    const pred = new relationalStore.RdbPredicates('shopping_item');
    pred.equalTo('id', it.id);
    await Db.get().update(bucket, pred);
    await Db.queueSync('ShoppingItem', it.id);
  }

  static async deleteItem(id: string): Promise<void> {
    const pred = new relationalStore.RdbPredicates('shopping_item');
    pred.equalTo('id', id);
    await Db.get().delete(pred);
    await Db.queueSync('ShoppingItem', id);
  }

  static async deleteItemsByIds(ids: string[]): Promise<void> {
    for (let i = 0; i < ids.length; i++) {
      await Db.deleteItem(ids[i]);
    }
  }

  static async allItems(): Promise<ShoppingItem[]> {
    const pred = new relationalStore.RdbPredicates('shopping_item');
    pred.orderByAsc('createdAt');
    const rs = await Db.get().query(pred);
    const out: ShoppingItem[] = [];
    while (rs.goToNextRow()) {
      out.push(Db.itemFromRow(rs));
    }
    rs.close();
    return out;
  }

  // ---------- FridgeItem ----------
  static fridgeFromRow(rs: relationalStore.ResultSet): FridgeItem {
    const f = new FridgeItem();
    f.id = rs.getString(rs.getColumnIndex('id'));
    f.name = rs.getString(rs.getColumnIndex('name'));
    f.amount = rs.getString(rs.getColumnIndex('amount'));
    f.category = rs.getString(rs.getColumnIndex('category')) || '其他';
    f.expiryDate = rs.getString(rs.getColumnIndex('expiryDate'));
    f.addedAt = rs.getLong(rs.getColumnIndex('addedAt'));
    f.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
    return f;
  }

  static async insertFridge(f: FridgeItem): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'id': f.id, 'name': f.name, 'amount': f.amount, 'category': f.category,
      'expiryDate': f.expiryDate, 'addedAt': f.addedAt, 'updated_at': Date.now()
    };
    await Db.get().insert('fridge_item', bucket);
    await Db.queueSync('FridgeItem', f.id);
  }

  static async updateFridge(f: FridgeItem): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'name': f.name, 'amount': f.amount, 'category': f.category, 'expiryDate': f.expiryDate
    };
    const pred = new relationalStore.RdbPredicates('fridge_item');
    pred.equalTo('id', f.id);
    await Db.get().update(bucket, pred);
  }

  static async deleteFridge(id: string): Promise<void> {
    const pred = new relationalStore.RdbPredicates('fridge_item');
    pred.equalTo('id', id);
    await Db.get().delete(pred);
    await Db.queueSync('FridgeItem', id);
  }

  static async allFridge(): Promise<FridgeItem[]> {
    const pred = new relationalStore.RdbPredicates('fridge_item');
    pred.orderByAsc('expiryDate').orderByAsc('addedAt');
    const rs = await Db.get().query(pred);
    const out: FridgeItem[] = [];
    while (rs.goToNextRow()) {
      out.push(Db.fridgeFromRow(rs));
    }
    rs.close();
    return out;
  }

  // ---------- AchievementProgress ----------
  static async insertAch(p: AchProgress): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'id': p.id, 'unlockedAt': p.unlockedAt, 'unlockedBy': p.unlockedBy,
      'updated_at': Date.now()
    };
    await Db.get().insert('ach_progress', bucket);
    await Db.queueSync('AchievementProgress', p.id);
  }

  static async allAch(): Promise<AchProgress[]> {
    const pred = new relationalStore.RdbPredicates('ach_progress');
    const rs = await Db.get().query(pred);
    const out: AchProgress[] = [];
    while (rs.goToNextRow()) {
      const p = new AchProgress();
      p.id = rs.getString(rs.getColumnIndex('id'));
      p.unlockedAt = rs.getLong(rs.getColumnIndex('unlockedAt'));
      p.unlockedBy = rs.getString(rs.getColumnIndex('unlockedBy'));
      out.push(p);
    }
    rs.close();
    return out;
  }

  // ---------- AppSetting (KV) ----------
  static async getSetting(key: string): Promise<string> {
    const pred = new relationalStore.RdbPredicates('app_setting');
    pred.equalTo('key', key);
    const rs = await Db.get().query(pred, ['value']);
    let v: string = '';
    if (rs.goToFirstRow()) {
      v = rs.getString(rs.getColumnIndex('value'));
    }
    rs.close();
    return v;
  }

  static async putSetting(key: string, value: string): Promise<void> {
    const bucket: relationalStore.ValuesBucket = { 'key': key, 'value': value };
    const pred = new relationalStore.RdbPredicates('app_setting');
    pred.equalTo('key', key);
    const rows = await Db.get().update(bucket, pred);
    if (rows === 0) {
      await Db.get().insert('app_setting', bucket);
    }
  }

  // ---------- JSON 工具 ----------
  static parseStringArr(text: string): string[] {
    if (!text || text.length === 0) {
      return [];
    }
    try {
      const arr: string[] = JSON.parse(text) as string[];
      return arr === null || arr === undefined ? [] : arr;
    } catch (e) {
      return [];
    }
  }

  static parseIngredients(text: string): Ingredient[] {
    if (!text || text.length === 0) {
      return [];
    }
    try {
      const raw: Ingredient[] = JSON.parse(text) as Ingredient[];
      const out: Ingredient[] = [];
      if (raw !== null && raw !== undefined) {
        for (let i = 0; i < raw.length; i++) {
          const c = new Ingredient();
          c.name = raw[i].name === undefined ? '' : raw[i].name;
          c.amount = raw[i].amount === undefined ? '' : raw[i].amount;
          c.category = raw[i].category === undefined ? '其他' : raw[i].category;
          out.push(c);
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }
}
