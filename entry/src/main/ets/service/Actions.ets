// 业务动作层：点菜/吃完/计划生成/清单合并/冰箱（App逻辑设计 §2/§3/§4/§11）
import { Db } from '../data/Db';
import { AppData } from '../data/AppData';
import { RecommendService, FridgeMatch } from './RecommendService';
import { AchievementEngine } from './AchievementEngine';
import { ReminderService } from './ReminderService';
import {
  Recipe, MealEntry, ShoppingItem, FridgeItem, todayStr, addDays, genId
} from '../model/Models';

export class ListAddResult {
  added: number = 0;
  skipped: string[] = [];
  recentBought: string[] = []; // 7 天内刚买过的（提示防重复采购）
}

export const PREFER_ALL: string = '不限';
export const PREFER_QUICK: string = '快速';
export const PREFER_LIGHT: string = '清淡';
export const PREFER_SPICY: string = '想吃辣';
export const PREFER_FAV: string = '都是收藏';

export class Actions {
  // ---------- 点菜 ----------
  static async pickDish(ad: AppData, r: Recipe, mealType: string, source: string): Promise<MealEntry> {
    const e = new MealEntry();
    e.id = genId('me');
    e.date = todayStr();
    e.mealType = mealType;
    e.recipeId = r.id;
    e.dishName = r.name;
    e.emoji = r.emoji;
    e.pickedBy = ad.settings.currentMember;
    e.status = 'planned';
    e.source = source;
    e.createdAt = Date.now();
    await Db.insertEntry(e);
    await ad.reloadEntries();
    return e;
  }

  static async pickFreeDish(ad: AppData, dishName: string, mealType: string): Promise<MealEntry> {
    const e = new MealEntry();
    e.id = genId('me');
    e.date = todayStr();
    e.mealType = mealType;
    e.dishName = dishName.trim();
    e.emoji = '🍽️';
    e.pickedBy = ad.settings.currentMember;
    e.status = 'planned';
    e.source = 'manual';
    e.createdAt = Date.now();
    await Db.insertEntry(e);
    await ad.reloadEntries();
    return e;
  }

  // ---------- 吃完（评分卡） ----------
  static async markEaten(ad: AppData, e: MealEntry, rating: number, mood: string,
    note: string, photoPath: string): Promise<void> {
    e.status = 'eaten';
    e.rating = rating;
    e.mood = mood;
    if (note.length > 0) {
      e.note = note;
    }
    if (photoPath.length > 0) {
      e.photoPath = photoPath;
    }
    await Db.updateEntry(e);
    await ad.reloadEntries();
    Actions.fireAchievementCheck(ad);
  }

  static async deleteEntry(ad: AppData, e: MealEntry, cleanup: boolean): Promise<void> {
    await Db.deleteEntry(e.id);
    if (cleanup && e.recipeId.length > 0 && e.status === 'planned') {
      await Actions.cleanupShoppingForRecipe(ad, e.recipeId, e.id, e.dishName);
    }
    await ad.reloadEntries();
  }

  // 计划删除/换菜后的清单联动清理：
  // 该菜谱不再被任何其他条目引用时，移除它带入且未采购、未归档的清单项；
  // 若某项食材同时被其他仍在计划中的菜谱使用（同名食材，如生抽），保留并把本菜名移出"用于"
  static async cleanupShoppingForRecipe(ad: AppData, recipeId: string,
    excludeEntryId: string, removedName: string): Promise<number> {
    let stillUsed = false;
    // 其他仍在计划中的菜谱 id 集合
    const otherPlanned: string[] = [];
    for (let i = 0; i < ad.entries.length; i++) {
      const other = ad.entries[i];
      if (other.id === excludeEntryId) {
        continue;
      }
      if (other.recipeId === recipeId) {
        stillUsed = true;
      }
      if (other.status === 'planned' && other.recipeId.length > 0 &&
        other.recipeId !== recipeId && !otherPlanned.includes(other.recipeId)) {
        otherPlanned.push(other.recipeId);
      }
    }
    if (stillUsed) {
      return 0;
    }
    // 其他计划中菜谱的食材名集合（同名食材共用，不删）
    const needed: string[] = [];
    for (let i = 0; i < otherPlanned.length; i++) {
      const r = ad.recipeById(otherPlanned[i]);
      if (r === null) {
        continue;
      }
      for (let k = 0; k < r.ingredients.length; k++) {
        if (!needed.includes(r.ingredients[k].name)) {
          needed.push(r.ingredients[k].name);
        }
      }
    }
    const toDel: string[] = [];
    for (let i = 0; i < ad.items.length; i++) {
      const it = ad.items[i];
      // 所有存活项都把已删菜名移出"用于"（含本菜谱借给别的项的：如食用油记在蛏抱蛋名下）
      if (it.fromRecipeName.includes(removedName)) {
        const parts = it.fromRecipeName.split('、').filter((n: string): boolean => n !== removedName);
        it.fromRecipeName = parts.join('、');
        await Db.updateItem(it);
      }
      if (it.fromRecipeId !== recipeId || it.checked || it.archivedAt > 0) {
        continue;
      }
      if (needed.includes(it.name)) {
        // 其他计划中的菜也用它：保留
        continue;
      }
      toDel.push(it.id);
    }
    if (toDel.length > 0) {
      await Db.deleteItemsByIds(toDel);
    }
    await ad.reloadItems();
    return toDel.length;
  }

  // ---------- 明天一键生成（§3.1） ----------
  static preferFilter(pool: Recipe[], prefer: string): Recipe[] {
    if (prefer === PREFER_ALL) {
      return pool;
    }
    const out: Recipe[] = [];
    for (let i = 0; i < pool.length; i++) {
      const r = pool[i];
      if (prefer === PREFER_QUICK && (r.isQuick || r.difficulty <= 2)) {
        out.push(r);
      } else if (prefer === PREFER_LIGHT && r.taste !== '辣' && r.taste !== '酸辣' && r.taste !== '香辣') {
        out.push(r);
      } else if (prefer === PREFER_SPICY &&
        (r.taste === '辣' || r.taste === '酸辣' || r.taste === '香辣' || r.taste === '鱼香')) {
        out.push(r);
      } else if (prefer === PREFER_FAV && r.favorite) {
        out.push(r);
      }
    }
    return out;
  }

  private static inPool(pool: Recipe[], r: Recipe): boolean {
    return pool.indexOf(r) >= 0;
  }

  // 返回本次生成的条目；refDate 一般为明天
  static async generatePlan(ad: AppData, refDate: string, prefer: string, count: number,
    replace: boolean): Promise<MealEntry[]> {
    if (replace) {
      const existing = ad.entriesOn(refDate);
      for (let i = 0; i < existing.length; i++) {
        if (existing[i].status === 'planned') {
          await Db.deleteEntry(existing[i].id);
        }
      }
    }
    const pool = RecommendService.buildPool(ad, refDate, '', false, false, new Set<string>());
    const filtered = Actions.preferFilter(pool, prefer);
    const base = filtered.length >= 3 ? filtered : pool;
    // 均衡分池
    const meat: Recipe[] = [];
    const veg: Recipe[] = [];
    const soup: Recipe[] = [];
    for (let i = 0; i < base.length; i++) {
      const r = base[i];
      if (r.category === '汤粥' || r.type === '汤') {
        soup.push(r);
      } else if (r.type === '素' || r.category === '素菜') {
        veg.push(r);
      } else {
        meat.push(r);
      }
    }
    const targetMeat = Math.max(1, Math.ceil(count / 2));
    const used: Set<string> = new Set();
    const chosen: Recipe[] = [];
    const pools: Recipe[] = [];
    for (let i = 0; i < Math.min(targetMeat, count); i++) {
      const r = RecommendService.pickOne(ad, meat, used);
      if (r === null) {
        break;
      }
      chosen.push(r);
      used.add(r.name);
    }
    const restCount = count - chosen.length;
    const halfRest = Math.floor(restCount / 2);
    for (let i = 0; i < halfRest; i++) {
      const r = RecommendService.pickOne(ad, soup, used);
      if (r === null) {
        break;
      }
      chosen.push(r);
      used.add(r.name);
    }
    while (chosen.length < count) {
      const r = RecommendService.pickOne(ad, veg, used);
      if (r === null) {
        break;
      }
      chosen.push(r);
      used.add(r.name);
    }
    while (chosen.length < count) {
      const r = RecommendService.pickOne(ad, base, used);
      if (r === null) {
        break;
      }
      chosen.push(r);
      used.add(r.name);
    }
    void pools;
    // 写入
    const out: MealEntry[] = [];
    for (let i = 0; i < chosen.length; i++) {
      const r = chosen[i];
      const e = new MealEntry();
      e.id = genId('me');
      e.date = refDate;
      e.mealType = 'dinner';
      e.recipeId = r.id;
      e.dishName = r.name;
      e.emoji = r.emoji;
      e.pickedBy = ad.settings.currentMember;
      e.status = 'planned';
      e.source = 'plan';
      e.createdAt = Date.now() + i;
      await Db.insertEntry(e);
      out.push(e);
    }
    await ad.reloadEntries();
    return out;
  }

  // 换一道（保留其余，替换指定条目）
  static async regenerateOne(ad: AppData, old: MealEntry, prefer: string): Promise<MealEntry | null> {
    const excluded: Set<string> = new Set();
    const sameDay = ad.entriesOn(old.date);
    for (let i = 0; i < sameDay.length; i++) {
      if (sameDay[i].id !== old.id) {
        excluded.add(sameDay[i].dishName);
      }
    }
    let pool = RecommendService.buildPool(ad, old.date, '', false, false, excluded);
    pool = Actions.preferFilter(pool, prefer);
    if (pool.length === 0) {
      pool = RecommendService.buildPool(ad, old.date, '', true, false, excluded);
    }
    const r = RecommendService.pickOne(ad, pool, excluded);
    if (r === null) {
      return null;
    }
    // 旧菜不再被其他条目引用时，把它带入且未采购的食材移出清单
    const oldRecipeId = old.recipeId;
    const oldDishName = old.dishName;
    if (oldRecipeId.length > 0) {
      await Actions.cleanupShoppingForRecipe(ad, oldRecipeId, old.id, oldDishName);
    }
    old.recipeId = r.id;
    old.dishName = r.name;
    old.emoji = r.emoji;
    old.source = 'plan';
    await Db.updateEntry(old);
    await ad.reloadEntries();
    return old;
  }

  // ---------- 购物清单（§4.1） ----------
  static async addIngredientsToList(ad: AppData, r: Recipe): Promise<ListAddResult> {
    const result = new ListAddResult();
    const now = Date.now();
    for (let i = 0; i < r.ingredients.length; i++) {
      const ing = r.ingredients[i];
      // 冰箱里已有的食材自动跳过，不再进待买清单
      if (FridgeMatch.fridgeHas(ad, ing.name)) {
        if (result.skipped.length < 6) {
          result.skipped.push(ing.name);
        }
        continue;
      }
      // 7 天内刚买过（已归档）的同名项：提醒防重复采购
      for (let k = 0; k < ad.items.length; k++) {
        const past = ad.items[k];
        if (past.name === ing.name && past.archivedAt > 0 &&
          now - past.archivedAt < 7 * 86400000) {
          if (result.recentBought.length < 4) {
            result.recentBought.push(ing.name);
          }
          break;
        }
      }
      let merged = false;
      for (let k = 0; k < ad.items.length; k++) {
        const it = ad.items[k];
        if (it.name === ing.name && !it.checked && it.archivedAt === 0) {
          // 已有同名未勾项：追加"用于"
          if (!it.fromRecipeName.includes(r.name) && it.fromRecipeName.length < 40) {
            it.fromRecipeName = it.fromRecipeName.length === 0 ? r.name : it.fromRecipeName + '、' + r.name;
            await Db.updateItem(it);
          }
          merged = true;
          break;
        }
      }
      if (!merged) {
        const it = new ShoppingItem();
        it.id = genId('si');
        it.name = ing.name;
        it.amount = ing.amount;
        it.category = ing.category;
        it.checked = false;
        // 调味料默认家里已有（设置可关），归入"家里已有"区不重复采购
        it.inStock = ad.settings.condimentAutoStock && ing.category === '调味';
        it.addedBy = ad.settings.currentMember;
        it.fromRecipeId = r.id;
        it.fromRecipeName = r.name;
        it.createdAt = now;
        await Db.insertItem(it);
        result.added++;
      }
    }
    await ad.reloadItems();
    Actions.fireAchievementCheck(ad);
    return result;
  }

  static async addManualItem(ad: AppData, name: string, amount: string,
    category: string, price: number = 0): Promise<void> {
    const it = new ShoppingItem();
    it.id = genId('si');
    it.name = name.trim();
    it.amount = amount.trim();
    it.category = category.length === 0 ? '其他' : category;
    it.price = price > 0 ? price : 0;
    it.addedBy = ad.settings.currentMember;
    it.createdAt = Date.now();
    await Db.insertItem(it);
    await ad.reloadItems();
  }

  static async toggleItem(ad: AppData, it: ShoppingItem): Promise<void> {
    it.checked = !it.checked;
    await Db.updateItem(it);
    await ad.reloadItems();
    Actions.fireAchievementCheck(ad);
  }

  static async setInStock(ad: AppData, it: ShoppingItem, v: boolean): Promise<void> {
    it.inStock = v;
    await Db.updateItem(it);
    await ad.reloadItems();
  }

  // 清空已买：归档而非删除（保留价格/时间用于清单对比"上周刚买过"）
  static async clearChecked(ad: AppData): Promise<number> {
    let n = 0;
    const now = Date.now();
    for (let i = ad.items.length - 1; i >= 0; i--) {
      const it = ad.items[i];
      if (it.checked && it.archivedAt === 0) {
        it.archivedAt = now;
        await Db.updateItem(it);
        n++;
      }
    }
    await ad.reloadItems();
    return n;
  }

  // ---------- 冰箱（§11） ----------
  static async addFridge(ad: AppData, name: string, amount: string,
    category: string, expiryDate: string): Promise<void> {
    const f = new FridgeItem();
    f.id = genId('fr');
    f.name = name.trim();
    f.amount = amount.trim();
    f.category = category.length === 0 ? '其他' : category;
    f.expiryDate = expiryDate.trim();
    f.addedAt = Date.now();
    await Db.insertFridge(f);
    await ad.reloadFridge();
    ReminderService.refreshExpiryReminders(ad).catch((): void => {
      // 临期提醒失败不影响入库
    });
  }

  static async deductFridgeForRecipe(ad: AppData, r: Recipe): Promise<number> {
    let n = 0;
    for (let i = ad.fridge.length - 1; i >= 0; i--) {
      const f = ad.fridge[i];
      let matched = false;
      for (let k = 0; k < r.ingredients.length; k++) {
        const ing = r.ingredients[k];
        if (f.name.includes(ing.name) || ing.name.includes(f.name)) {
          matched = true;
          break;
        }
      }
      if (matched) {
        await Db.deleteFridge(f.id);
        n++;
      }
    }
    if (n > 0) {
      await ad.reloadFridge();
    }
    return n;
  }

  static async deleteFridgeItem(ad: AppData, f: FridgeItem): Promise<void> {
    await Db.deleteFridge(f.id);
    await ad.reloadFridge();
    ReminderService.refreshExpiryReminders(ad).catch((): void => {
      // 忽略
    });
  }

  static async deleteFridgeBatch(ad: AppData, ids: string[]): Promise<void> {
    for (let i = 0; i < ids.length; i++) {
      await Db.deleteFridge(ids[i]);
    }
    await ad.reloadFridge();
    ReminderService.refreshExpiryReminders(ad).catch((): void => {
      // 忽略
    });
  }

  // ---------- 菜谱 CRUD ----------
  static async saveRecipe(ad: AppData, r: Recipe, isNew: boolean): Promise<void> {
    if (isNew) {
      r.createdAt = Date.now();
      await Db.insertRecipe(r);
    } else {
      await Db.updateRecipe(r);
    }
    await ad.reloadRecipes();
  }

  static async toggleFavorite(ad: AppData, r: Recipe): Promise<void> {
    r.favorite = !r.favorite;
    await Db.updateRecipe(r);
    await ad.reloadRecipes();
    Actions.fireAchievementCheck(ad);
  }

  // ---------- 成就异步检测 ----------
  static fireAchievementCheck(ad: AppData): void {
    AchievementEngine.check(ad).then((): void => {
      // 新解锁通过 pendingAchPopup 队列由 UI 消费
    }).catch((): void => {
      // 忽略成就检测异常
    });
  }
}
