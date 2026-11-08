// 推荐引擎（App逻辑设计 §1）
import { AppData } from '../data/AppData';
import { Recipe, MealEntry, AppSettings, addDays, todayStr, MOODS } from '../model/Models';

export interface Weighted {
  recipe: Recipe;
  weight: number;
}

export class ScoredRecipe {
  recipe: Recipe = new Recipe();
  score: number = 0;
}

// 食材别名组：组内任意词互相视作同一食材（排骨/肋排/小排…）
const ALIAS_GROUPS: string[][] = [
  ['排骨', '肋排', '小排', '大排', '猪排'],
  ['鸡蛋', '蛋清', '蛋白', '蛋黄'],
  ['葱', '大葱', '小葱', '香葱', '葱花', '洋葱'],
  ['姜', '姜片', '姜末', '姜丝'],
  ['蒜', '蒜末', '蒜片', '蒜瓣'],
  ['青椒', '尖椒', '螺丝椒', '杭椒', '彩椒', '菜椒'],
  ['蘑菇', '香菇', '金针菇', '杏鲍菇', '平菇', '口蘑'],
  ['酱油', '生抽', '老抽'],
  ['糖', '白糖', '砂糖', '冰糖'],
  ['淀粉', '生粉', '土豆淀粉', '玉米淀粉']
];

// 本地食材替换词典（对照表 #3 兜底层，LLM 不可用时使用）
// 每行为扁平数组：[缺失食材, 替代1, 替代2, …]
const SUBSTITUTE_DICT: string[][] = [
  ['料酒', '黄酒', '白酒少许', '啤酒'],
  ['生抽', '老抽加糖', '盐加糖', '味极鲜'],
  ['老抽', '生抽加糖', '酱油'],
  ['蚝油', '生抽加糖', '酱油加糖'],
  ['淀粉', '玉米淀粉', '面粉', '藕粉'],
  ['小苏打', '泡打粉', '酵母'],
  ['白糖', '冰糖', '红糖', '蜂蜜'],
  ['冰糖', '白糖', '红糖'],
  ['黄油', '食用油加少许盐', '椰子油'],
  ['牛奶', '奶粉冲调', '淡奶油兑水'],
  ['淡奶油', '牛奶加黄油', '椰浆'],
  ['奶油奶酪', '浓酸奶', '马斯卡彭'],
  ['豆腐', '内酯豆腐', '豆干', '鸡蛋'],
  ['猪肉末', '鸡肉末', '牛肉末'],
  ['五花肉', '梅花肉', '瘦肉加肥膘'],
  ['排骨', '肋排', '猪小排', '鸡翅根'],
  ['牛肉', '猪肉', '鸡腿肉'],
  ['虾', '虾仁', '蟹柳'],
  ['紫菜', '海苔', '裙带菜'],
  ['香菜', '芹菜叶', '小葱'],
  ['柠檬', '白醋', '青柠'],
  ['干辣椒', '辣椒粉', '豆瓣酱'],
  ['花椒', '麻椒', '花椒粉'],
  ['芝麻油', '橄榄油', '食用油加芝麻'],
  ['豆豉', '豆瓣酱', '酱油'],
  ['酵母', '泡打粉', '小苏打加柠檬汁']
];

export class FridgeMatch {
  // 食材名 → 别名展开词组（用于冰箱包含判断）
  static expand(name: string): string[] {
    const out: string[] = [name];
    for (let g = 0; g < ALIAS_GROUPS.length; g++) {
      const group = ALIAS_GROUPS[g];
      for (let i = 0; i < group.length; i++) {
        if (name.includes(group[i])) {
          for (let k = 0; k < group.length; k++) {
            if (!out.includes(group[k])) {
              out.push(group[k]);
            }
          }
          break;
        }
      }
    }
    return out;
  }

  // 冰箱里是否已有能覆盖该食材的东西
  static fridgeHas(ad: AppData, ingName: string): boolean {
    const words = FridgeMatch.expand(ingName);
    for (let i = 0; i < ad.fridge.length; i++) {
      const fname = ad.fridge[i].name;
      for (let k = 0; k < words.length; k++) {
        if (fname.includes(words[k]) || words[k].includes(fname)) {
          return true;
        }
      }
    }
    return false;
  }
}

export class RecommendService {
  // 心情过滤（§1.2）
  static matchMood(r: Recipe, mood: string): boolean {
    if (mood.length === 0) {
      return true;
    }
    if (mood === '想偷懒') {
      return r.isQuick || (r.difficulty > 0 && r.difficulty <= 2);
    }
    if (mood === '疲惫') {
      return (r.durationMin > 0 && r.durationMin <= 25) || (r.difficulty > 0 && r.difficulty <= 2);
    }
    if (mood === '想吃辣') {
      return r.taste === '辣' || r.taste === '酸辣' || r.taste === '香辣' || r.taste === '鱼香';
    }
    if (mood === '想养生') {
      return r.category === '汤粥' || r.type === '素' || r.taste === '清淡';
    }
    return true;
  }

  // 黑名单命中检查：返回命中人数
  static blacklistHits(ad: AppData, r: Recipe): number {
    let hits = 0;
    const members = ad.settings.members;
    for (let m = 0; m < members.length; m++) {
      const bl = ad.memberBlacklist(members[m]);
      for (let i = 0; i < bl.length; i++) {
        const w = bl[i];
        if (w.length > 0 && (r.name.includes(w) || RecommendService.ingIncludes(r, w))) {
          hits++;
          break;
        }
      }
    }
    return hits;
  }

  private static ingIncludes(r: Recipe, word: string): boolean {
    for (let i = 0; i < r.ingredients.length; i++) {
      if (r.ingredients[i].name.includes(word)) {
        return true;
      }
    }
    return false;
  }

  // 最近 N 天吃过的菜名集合
  static recentEatenNames(ad: AppData, refDate: string, days: number): Set<string> {
    const out: Set<string> = new Set();
    if (days <= 0) {
      return out;
    }
    const start = addDays(refDate, -(days - 1));
    const list = ad.entriesRange(start, refDate);
    for (let i = 0; i < list.length; i++) {
      if (list[i].status === 'eaten') {
        out.add(list[i].dishName);
      }
    }
    return out;
  }

  // 候选池构建（§1.1），allowRepeatDays<=0 表示忽略去重
  static buildPool(ad: AppData, refDate: string, mood: string,
    ignoreRepeat: boolean, useWheelLimit: boolean, extraExcluded: Set<string>): Recipe[] {
    const s: AppSettings = ad.settings;
    const recent = ignoreRepeat ? new Set<string>() : RecommendService.recentEatenNames(ad, refDate, s.repeatDays);
    const out: Recipe[] = [];
    for (let i = 0; i < ad.recipes.length; i++) {
      const r = ad.recipes[i];
      if (!r.enabled) {
        continue;
      }
      if (!s.enabledTypes.includes(r.category)) {
        continue;
      }
      if (r.dislike) {
        continue;
      }
      // 最大烹饪时长硬上限（0=不限；未知时长不拦）
      if (s.maxDuration > 0 && r.durationMin > 0 && r.durationMin > s.maxDuration) {
        continue;
      }
      if (recent.has(r.name) || extraExcluded.has(r.name)) {
        continue;
      }
      if (useWheelLimit && s.wheelLimitCategory.length > 0 && r.category !== s.wheelLimitCategory) {
        continue;
      }
      if (useWheelLimit && s.wheelLimitMaxDiff > 0 && r.difficulty > s.wheelLimitMaxDiff) {
        continue;
      }
      if (!RecommendService.matchMood(r, mood)) {
        continue;
      }
      out.push(r);
    }
    return out;
  }

  // 降级链（§1.5）
  static buildPoolWithFallback(ad: AppData, refDate: string, mood: string): Recipe[] {
    let pool = RecommendService.buildPool(ad, refDate, mood, false, false, new Set<string>());
    if (pool.length >= 5) {
      return pool;
    }
    pool = RecommendService.buildPool(ad, refDate, mood, false, false, new Set<string>());
    const relaxed = RecommendService.relaxPool(ad, refDate, mood, 1);
    if (relaxed.length > pool.length) {
      pool = relaxed;
    }
    if (pool.length < 5) {
      const ignore = RecommendService.buildPool(ad, refDate, mood, true, false, new Set<string>());
      if (ignore.length > pool.length) {
        pool = ignore;
      }
    }
    return pool;
  }

  private static relaxPool(ad: AppData, refDate: string, mood: string, days: number): Recipe[] {
    const recent = RecommendService.recentEatenNames(ad, refDate, days);
    const out: Recipe[] = [];
    for (let i = 0; i < ad.recipes.length; i++) {
      const r = ad.recipes[i];
      if (!r.enabled || r.dislike) {
        continue;
      }
      if (!ad.settings.enabledTypes.includes(r.category)) {
        continue;
      }
      if (recent.has(r.name)) {
        continue;
      }
      if (!RecommendService.matchMood(r, mood)) {
        continue;
      }
      out.push(r);
    }
    return out;
  }

  // 加权（§1.3）
  static weightOf(ad: AppData, r: Recipe): number {
    let w = 1.0;
    if (r.favorite) {
      w += 3;
    }
    if (r.isQuick || (r.durationMin > 0 && r.durationMin <= 20)) {
      w += 1;
    }
    if (RecommendService.lastEatenDays(ad, r.name) >= 30) {
      w += 1;
    }
    if (RecommendService.avgRating(ad, r.name) >= 4) {
      w += 1;
    }
    const hits = RecommendService.blacklistHits(ad, r);
    if (hits === 1) {
      w *= 0.2;
    }
    // hits >= 2 已在池构建时排除
    return w;
  }

  static lastEatenDays(ad: AppData, dishName: string): number {
    let last = -1;
    for (let i = 0; i < ad.entries.length; i++) {
      const e = ad.entries[i];
      if (e.status === 'eaten' && e.dishName === dishName) {
        const parts = e.date.split('-');
        const t = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2])).getTime();
        if (t > last) {
          last = t;
        }
      }
    }
    if (last < 0) {
      return 9999;
    }
    return Math.floor((Date.now() - last) / 86400000);
  }

  static avgRating(ad: AppData, dishName: string): number {
    let sum = 0;
    let n = 0;
    for (let i = 0; i < ad.entries.length; i++) {
      const e = ad.entries[i];
      if (e.status === 'eaten' && e.dishName === dishName && e.rating > 0) {
        sum += e.rating;
        n++;
      }
    }
    return n === 0 ? 0 : sum / n;
  }

  // 加权随机抽 1 道（从 pool 中排除 excludeNames）
  static pickOne(ad: AppData, pool: Recipe[], excludeNames: Set<string>): Recipe | null {
    const cands: Recipe[] = [];
    for (let i = 0; i < pool.length; i++) {
      if (!excludeNames.has(pool[i].name)) {
        cands.push(pool[i]);
      }
    }
    if (cands.length === 0) {
      return null;
    }
    const weights: number[] = [];
    let total = 0;
    for (let i = 0; i < cands.length; i++) {
      const w = RecommendService.weightOf(ad, cands[i]);
      weights.push(w);
      total += w;
    }
    let dice = Math.random() * total;
    for (let i = 0; i < cands.length; i++) {
      dice -= weights[i];
      if (dice <= 0) {
        return cands[i];
      }
    }
    return cands[cands.length - 1];
  }

  // 一次抽多道（排除 excludeNames，结果自身也去重）
  static pickBatch(ad: AppData, pool: Recipe[], count: number, excludeNames: Set<string>): Recipe[] {
    const used: Set<string> = new Set();
    const init = Array.from(excludeNames);
    for (let i = 0; i < init.length; i++) {
      used.add(init[i]);
    }
    const out: Recipe[] = [];
    for (let i = 0; i < count; i++) {
      const r = RecommendService.pickOne(ad, pool, used);
      if (r === null) {
        break;
      }
      out.push(r);
      used.add(r.name);
    }
    return out;
  }

  // 三选一
  static pickThree(ad: AppData, pool: Recipe[]): Recipe[] {
    return RecommendService.pickBatch(ad, pool, 3, new Set());
  }

  // 转盘候选：8~12 道均匀
  static wheelCandidates(ad: AppData, refDate: string): Recipe[] {
    const pool = RecommendService.buildPoolWithFallback(ad, refDate, '');
    const shuffled = pool.slice();
    for (let i = shuffled.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      const tmp = shuffled[i];
      shuffled[i] = shuffled[j];
      shuffled[j] = tmp;
    }
    const n = Math.min(shuffled.length, 20);
    return shuffled.slice(0, n);
  }

  // 盲盒：全库（不排近3天），冷门×2，不排心情；theme 非空时限定主题（对照表 #8 主题盲盒）
  static mysteryCandidate(ad: AppData, theme: string): Recipe | null {
    const out: Recipe[] = [];
    for (let i = 0; i < ad.recipes.length; i++) {
      const r = ad.recipes[i];
      if (!r.enabled || r.dislike) {
        continue;
      }
      if (RecommendService.blacklistHits(ad, r) >= 2) {
        continue;
      }
      if (theme === '辣盒' &&
        !(r.taste === '辣' || r.taste === '酸辣' || r.taste === '香辣' || r.taste === '鱼香')) {
        continue;
      }
      if (theme === '快手盒' && !(r.isQuick || (r.durationMin > 0 && r.durationMin <= 20))) {
        continue;
      }
      if (theme === '汤盒' && !(r.category === '汤粥' || r.type === '汤')) {
        continue;
      }
      if (theme === '收藏盒' && !r.favorite) {
        continue;
      }
      out.push(r);
    }
    if (out.length === 0) {
      return null;
    }
    const weights: number[] = [];
    let total = 0;
    for (let i = 0; i < out.length; i++) {
      let w = 1;
      if (RecommendService.lastEatenDays(ad, out[i].name) >= 30) {
        w = 2;
      }
      weights.push(w);
      total += w;
    }
    let dice = Math.random() * total;
    for (let i = 0; i < out.length; i++) {
      dice -= weights[i];
      if (dice <= 0) {
        return out[i];
      }
    }
    return out[out.length - 1];
  }

  // ---------- 食材替换（本地词典兜底） ----------
  static substituteLocal(ingredient: string): string[] {
    const key = ingredient.trim();
    if (key.length === 0) {
      return [];
    }
    for (let i = 0; i < SUBSTITUTE_DICT.length; i++) {
      const row = SUBSTITUTE_DICT[i];
      for (let k = 0; k < row.length; k++) {
        if (row[k] === key || (k === 0 && (row[0].includes(key) || key.includes(row[0])))) {
          const out: string[] = [];
          for (let s = 1; s < row.length; s++) {
            out.push(row[s]);
          }
          return out;
        }
      }
    }
    return [];
  }

  // ---------- 料理挑战（对照表 点子#8：每周一道 30 天没做的菜） ----------
  static weeklyChallenge(ad: AppData): Recipe | null {
    const cands: Recipe[] = [];
    for (let i = 0; i < ad.recipes.length; i++) {
      const r = ad.recipes[i];
      if (!r.enabled || r.dislike) {
        continue;
      }
      if (RecommendService.lastEatenDays(ad, r.name) >= 30) {
        cands.push(r);
      }
    }
    if (cands.length === 0) {
      return null;
    }
    // 按周数确定性挑一道：同一周内挑战不变
    const now = new Date();
    const jan1 = new Date(now.getFullYear(), 0, 1);
    const week = Math.floor((now.getTime() - jan1.getTime()) / (7 * 86400000));
    return cands[week % cands.length];
  }

  // ---------- 厨艺进阶（点子#5：下一道挑战） ----------
  static nextSkillRecipe(ad: AppData): Recipe | null {
    // 已做过的最高难度
    let maxDiff = 0;
    for (let i = 0; i < ad.entries.length; i++) {
      const e = ad.entries[i];
      if (e.status !== 'eaten' || e.recipeId.length === 0) {
        continue;
      }
      const r = ad.recipeById(e.recipeId);
      if (r !== null && r.difficulty > maxDiff) {
        maxDiff = r.difficulty;
      }
    }
    if (maxDiff === 0 && ad.entries.length === 0) {
      maxDiff = 0;
    }
    const target = Math.min(maxDiff + 1, 5);
    const cands: Recipe[] = [];
    for (let i = 0; i < ad.recipes.length; i++) {
      const r = ad.recipes[i];
      if (r.enabled && r.difficulty === target) {
        cands.push(r);
      }
    }
    if (cands.length === 0) {
      return null;
    }
    return cands[Math.floor(Math.random() * cands.length)];
  }

  // ---------- 问AI助手（本地规则版；LLM 接入后由云函数替代） ----------
  static chefLocal(ad: AppData, utterance: string, refDate: string): Recipe[] {
    const text = utterance.trim();
    let mood = '';
    for (let i = 0; i < MOODS.length; i++) {
      if (text.includes(MOODS[i])) {
        mood = MOODS[i];
        break;
      }
    }
    if (text.includes('热乎') || text.includes('暖') || text.includes('炖')) {
      mood = '想养生';
    }
    let pool = RecommendService.buildPoolWithFallback(ad, refDate, mood);
    if (pool.length === 0) {
      pool = RecommendService.buildPoolWithFallback(ad, refDate, '');
    }
    // 关键词过滤：食材 / 口味 / 类型
    if (text.includes('不吃猪肉') || text.includes('不要猪肉') || text.includes('没猪肉')) {
      const noPork: Recipe[] = [];
      for (let i = 0; i < pool.length; i++) {
        const r = pool[i];
        let has = false;
        for (let k = 0; k < r.ingredients.length; k++) {
          const n = r.ingredients[k].name;
          if (n.includes('猪肉') || n.includes('五花肉') || n.includes('排骨') ||
            n.includes('猪') || n.includes('肘') || n.includes('培根') || n.includes('腊')) {
            has = true;
            break;
          }
        }
        if (!has) {
          noPork.push(r);
        }
      }
      if (noPork.length >= 3) {
        pool = noPork;
      }
    }
    if (text.includes('喝') || text.includes('汤')) {
      const soup: Recipe[] = [];
      for (let i = 0; i < pool.length; i++) {
        if (pool[i].category === '汤粥' || pool[i].type === '汤') {
          soup.push(pool[i]);
        }
      }
      if (soup.length >= 3) {
        pool = soup;
      }
    }
    if (text.includes('快') || text.includes('简单') || text.includes('懒')) {
      const quick: Recipe[] = [];
      for (let i = 0; i < pool.length; i++) {
        if (pool[i].isQuick || pool[i].difficulty <= 2) {
          quick.push(pool[i]);
        }
      }
      if (quick.length >= 3) {
        pool = quick;
      }
    }
    if (text.includes('辣')) {
      const spicy: Recipe[] = [];
      for (let i = 0; i < pool.length; i++) {
        const t = pool[i].taste;
        if (t === '辣' || t === '酸辣' || t === '香辣' || t === '鱼香') {
          spicy.push(pool[i]);
        }
      }
      if (spicy.length >= 3) {
        pool = spicy;
      }
    }
    return RecommendService.pickThree(ad, pool);
  }

  // ---------- 清冰箱本地匹配 ----------
  static fridgeMatch(ad: AppData, selectedNames: string[]): Recipe[] {
    if (selectedNames.length === 0) {
      return [];
    }
    const scored: ScoredRecipe[] = [];
    for (let i = 0; i < ad.recipes.length; i++) {
      const r = ad.recipes[i];
      if (!r.enabled || r.dislike) {
        continue;
      }
      let cover = 0;
      let hasMain = false;
      for (let k = 0; k < r.ingredients.length; k++) {
        const ing = r.ingredients[k];
        if (ing.category === '调味') {
          continue;
        }
        for (let s = 0; s < selectedNames.length; s++) {
          const words = FridgeMatch.expand(selectedNames[s]);
          let hit = false;
          for (let w = 0; w < words.length && !hit; w++) {
            if (ing.name.includes(words[w]) || words[w].includes(ing.name)) {
              hit = true;
            }
          }
          if (hit) {
            cover++;
            if (ing.category !== '其他') {
              hasMain = true;
            }
            break;
          }
        }
      }
      if (hasMain && cover > 0) {
        const sc = new ScoredRecipe();
        sc.recipe = r;
        sc.score = cover;
        scored.push(sc);
      }
    }
    scored.sort((a: ScoredRecipe, b: ScoredRecipe): number => b.score - a.score);
    const out: Recipe[] = [];
    for (let i = 0; i < scored.length && i < 10; i++) {
      out.push(scored[i].recipe);
    }
    return out;
  }
}
