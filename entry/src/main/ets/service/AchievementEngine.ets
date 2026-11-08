// 成就引擎（App逻辑设计 §5.2/§5.3，v1 共 20 个）
import { Db } from '../data/Db';
import { AppData } from '../data/AppData';
import { AchStats, AchProgress, MealEntry, ShoppingItem, Recipe, genId } from '../model/Models';

export class AchievementDef {
  id: string = '';
  name: string = '';
  desc: string = '';
  icon: string = '';
  target: number = 0; // 0 = 布尔型成就
  check: (s: AchStats) => boolean = (s: AchStats): boolean => false;
  progress: (s: AchStats) => number = (s: AchStats): number => 0;
}

export class AchievementEngine {
  static catalog(): AchievementDef[] {
    const list: AchievementDef[] = [];
    const add = (id: string, icon: string, name: string, desc: string, target: number,
      val: (s: AchStats) => number): void => {
      const d = new AchievementDef();
      d.id = id;
      d.icon = icon;
      d.name = name;
      d.desc = desc;
      d.target = target;
      d.check = (s: AchStats): boolean => val(s) >= target;
      d.progress = (s: AchStats): number => val(s);
      list.push(d);
    };
    add('first_meal', '🍳', '初入厨房', '记下第一顿饭', 1, (s: AchStats): number => s.eatenCount);
    add('meal_10', '🥢', '小试牛刀', '吃过 10 顿', 10, (s: AchStats): number => s.eatenCount);
    add('meal_50', '🍽️', '渐入佳境', '吃过 50 顿', 50, (s: AchStats): number => s.eatenCount);
    add('hundred', '💎', '百菜斩', '吃过 100 种不同的菜', 100, (s: AchStats): number => s.uniqueDishCount);
    add('week7', '🥇', '七日之约', '连续 7 天开饭', 7, (s: AchStats): number => s.streakDays);
    add('month30', '🏆', '三十而立', '连续 30 天开饭', 30, (s: AchStats): number => s.streakDays);
    add('spicy15', '🌶️', '辣不怕', '吃辣 15 次', 15, (s: AchStats): number => s.spicyCount);
    add('soup15', '🍲', '汤司令', '喝汤 15 次', 15, (s: AchStats): number => s.soupCount);
    add('staple15', '🍚', '主食主义', '主食 15 顿', 15, (s: AchStats): number => s.stapleCount);
    add('quick20', '⚡', '快手大师', '快手菜 20 次', 20, (s: AchStats): number => s.quickCount);
    add('sichuan10', '🔥', '川流不息', '川菜 10 次', 10,
      (s: AchStats): number => s.cuisineEaten.get('川菜') === undefined ? 0 : s.cuisineEaten.get('川菜') as number);
    add('yue10', '🦐', '粤菜大师', '粤菜 10 次', 10,
      (s: AchStats): number => s.cuisineEaten.get('粤菜') === undefined ? 0 : s.cuisineEaten.get('粤菜') as number);
    add('xiang10', '🫕', '湘菜大师', '湘菜 10 次', 10,
      (s: AchStats): number => s.cuisineEaten.get('湘菜') === undefined ? 0 : s.cuisineEaten.get('湘菜') as number);
    add('dongbei10', '🥟', '东北银', '东北菜 10 次', 10,
      (s: AchStats): number => s.cuisineEaten.get('东北菜') === undefined ? 0 : s.cuisineEaten.get('东北菜') as number);
    add('rater20', '✍️', '点评家', '评分 20 次', 20, (s: AchStats): number => s.ratingCount);
    add('photo10', '📷', '摄影师', '照片墙 10 张', 10, (s: AchStats): number => s.photoCount);
    add('photo50', '🖼️', '照片墙扛把子', '照片墙 50 张', 50, (s: AchStats): number => s.photoCount);
    add('fav10', '❤️', '收藏家', '收藏 10 道菜', 10, (s: AchStats): number => s.favCount);
    add('buyer50', '🛒', '买手', '勾掉清单 50 项', 50, (s: AchStats): number => s.checkedCount);
    add('clear15', '🎉', '满载而归', '勾掉清单 15 项', 15, (s: AchStats): number => s.checkedCount);
    return list;
  }

  // 汇总统计快照
  static computeStats(ad: AppData): AchStats {
    const s = new AchStats();
    const unique: Set<string> = new Set();
    const eatenDates: Set<string> = new Set();
    for (let i = 0; i < ad.entries.length; i++) {
      const e: MealEntry = ad.entries[i];
      if (e.status !== 'eaten') {
        continue;
      }
      s.eatenCount++;
      unique.add(e.dishName);
      eatenDates.add(e.date);
      if (e.rating > 0) {
        s.ratingCount++;
      }
      if (e.photoPath.length > 0) {
        s.photoCount++;
      }
      const r: Recipe | null = e.recipeId.length > 0 ? ad.recipeById(e.recipeId) : null;
      if (r !== null) {
        if (r.taste === '辣' || r.taste === '酸辣' || r.taste === '香辣' || r.taste === '鱼香') {
          s.spicyCount++;
        }
        if (r.category === '汤粥') {
          s.soupCount++;
        }
        if (r.category === '主食') {
          s.stapleCount++;
        }
        if (r.isQuick) {
          s.quickCount++;
        }
        const c = s.cuisineEaten.get(r.cuisine);
        s.cuisineEaten.set(r.cuisine, (c === undefined ? 0 : c) + 1);
      }
    }
    s.uniqueDishCount = unique.size;
    s.streakDays = AchievementEngine.calcStreak(eatenDates);
    for (let i = 0; i < ad.recipes.length; i++) {
      if (ad.recipes[i].favorite) {
        s.favCount++;
      }
    }
    for (let i = 0; i < ad.items.length; i++) {
      if (ad.items[i].checked) {
        s.checkedCount++;
      }
    }
    for (let i = 0; i < ad.entries.length; i++) {
      if (ad.entries[i].source === 'wheel') {
        s.wheelAdopted++;
      }
      if (ad.entries[i].source === 'plan') {
        s.planGenerated++;
      }
    }
    return s;
  }

  private static calcStreak(dates: Set<string>): number {
    if (dates.size === 0) {
      return 0;
    }
    // 从今天或昨天开始往回数（今天还没吃不打断连胜）
    const now = new Date();
    const fmt = (d: Date): string => {
      const m = d.getMonth() + 1;
      const day = d.getDate();
      return d.getFullYear() + '-' + (m < 10 ? '0' + m : '' + m) + '-' + (day < 10 ? '0' + day : '' + day);
    };
    let cursor = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    if (!dates.has(fmt(cursor))) {
      cursor.setDate(cursor.getDate() - 1);
      if (!dates.has(fmt(cursor))) {
        return 0;
      }
    }
    let streak = 0;
    while (dates.has(fmt(cursor))) {
      streak++;
      cursor.setDate(cursor.getDate() - 1);
    }
    return streak;
  }

  // 事件触发检测：返回本次新解锁的成就
  static async check(ad: AppData): Promise<AchievementDef[]> {
    const stats = AchievementEngine.computeStats(ad);
    const defs = AchievementEngine.catalog();
    const newly: AchievementDef[] = [];
    for (let i = 0; i < defs.length; i++) {
      const d = defs[i];
      if (ad.achUnlocked.has(d.id)) {
        continue;
      }
      let ok = false;
      try {
        ok = d.check(stats);
      } catch (e) {
        ok = false;
      }
      if (ok) {
        const p = new AchProgress();
        p.id = d.id;
        p.unlockedAt = Date.now();
        p.unlockedBy = ad.settings.currentMember;
        await Db.insertAch(p);
        ad.achUnlocked.set(d.id, p);
        newly.push(d);
        ad.pendingAchPopup.push(d.id);
      }
    }
    if (newly.length > 0) {
      ad.notify(6); // EVT_ACH
    }
    return newly;
  }
}
