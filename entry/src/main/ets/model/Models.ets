// 数据模型定义

export class Ingredient {
  name: string = '';
  amount: string = '';
  category: string = '其他';
}

// 深拷贝菜谱（ArkTS 禁用 Object.assign）
export function copyRecipe(src: Recipe): Recipe {
  const r = new Recipe();
  r.id = src.id;
  r.name = src.name;
  r.emoji = src.emoji;
  r.cuisine = src.cuisine;
  r.taste = src.taste;
  r.category = src.category;
  r.type = src.type;
  r.isQuick = src.isQuick;
  r.durationMin = src.durationMin;
  r.difficulty = src.difficulty;
  r.calories = src.calories;
  r.ingredients = src.ingredients.map((i: Ingredient): Ingredient => {
    const c = new Ingredient();
    c.name = i.name;
    c.amount = i.amount;
    c.category = i.category;
    return c;
  });
  r.steps = src.steps.slice();
  r.tips = src.tips.slice();
  r.favorite = src.favorite;
  r.enabled = src.enabled;
  r.source = src.source;
  r.createdBy = src.createdBy;
  r.createdAt = src.createdAt;
  r.dislike = src.dislike;
  r.collections = src.collections.slice();
  r.protein = src.protein;
  r.fat = src.fat;
  r.carbs = src.carbs;
  return r;
}

// 购物分组固定顺序
export const GROUP_ORDER: string[] = ['蔬菜', '肉类', '水产', '蛋奶豆', '主食', '调味', '其他'];
export const GROUP_ICON: Map<string, string> = new Map([
  ['蔬菜', '🥬'], ['肉类', '🥩'], ['水产', '🐟'], ['蛋奶豆', '🥚'],
  ['主食', '🍚'], ['调味', '🧂'], ['其他', '📦']
]);

export const DISH_CATEGORIES: string[] =
  ['荤菜', '素菜', '水产', '汤粥', '主食', '早餐', '甜品', '饮品', '酱料', '半成品'];
// 推荐候选池默认启用的类型
export const DEFAULT_ENABLED_TYPES: string[] = ['荤菜', '素菜', '水产', '汤粥', '主食'];

export class Recipe {
  id: string = '';
  updatedAt: number = 0;
  name: string = '';
  emoji: string = '🍽️';
  cuisine: string = '家常菜';
  taste: string = '咸鲜';
  category: string = '荤菜';
  type: string = '荤';
  isQuick: boolean = false;
  durationMin: number = -1;   // -1 表示未知
  difficulty: number = 0;     // 0 表示未知
  calories: number = 0;       // 0 表示未知
  protein: number = 0;        // 每份蛋白质克数，0 未知
  fat: number = 0;            // 每份脂肪克数
  carbs: number = 0;          // 每份碳水克数
  ingredients: Ingredient[] = [];
  steps: string[] = [];
  tips: string[] = [];
  favorite: boolean = false;
  enabled: boolean = true;
  source: string = '';
  createdBy: string = '';
  createdAt: number = 0;
  dislike: boolean = false;   // 端侧"不爱吃"标记（本人维度简化为全局）
  collections: string[] = []; // 收藏自定义分组（减脂餐/周末大餐…）
}

export class MealEntry {
  id: string = '';
  updatedAt: number = 0;
  date: string = '';          // yyyy-MM-dd（本地时区）
  mealType: string = 'dinner';// lunch / dinner
  recipeId: string = '';
  dishName: string = '';
  emoji: string = '🍽️';
  pickedBy: string = '';
  status: string = 'planned'; // planned / eaten
  rating: number = 0;         // 0 未评分, 1-5
  mood: string = '';          // 开心/疲惫/想偷懒/想吃辣/想养生/空
  note: string = '';
  photoPath: string = '';     // 沙箱内图片路径，空=无照片
  source: string = 'manual';  // manual/wheel/box/ai/plan
  createdAt: number = 0;
}

export class ShoppingItem {
  id: string = '';
  updatedAt: number = 0;
  name: string = '';
  amount: string = '';
  category: string = '其他';
  checked: boolean = false;
  inStock: boolean = false;   // 家里已有
  addedBy: string = '';
  fromRecipeId: string = '';
  fromRecipeName: string = '';
  price: number = 0;
  createdAt: number = 0;
  archivedAt: number = 0;     // 清空已买时归档时间（0=在册），用于"上周刚买过"对比
}

export class FridgeItem {
  id: string = '';
  updatedAt: number = 0;
  name: string = '';
  amount: string = '';
  category: string = '其他';
  expiryDate: string = '';    // yyyy-MM-dd 或 ''
  addedAt: number = 0;
}

export class AchProgress {
  id: string = '';
  updatedAt: number = 0;
  unlockedAt: number = 0;
  unlockedBy: string = '';
}

// 成就检测用的统计快照
export class AchStats {
  eatenCount: number = 0;
  uniqueDishCount: number = 0;
  streakDays: number = 0;
  spicyCount: number = 0;
  soupCount: number = 0;
  stapleCount: number = 0;
  quickCount: number = 0;
  ratingCount: number = 0;
  photoCount: number = 0;
  favCount: number = 0;
  checkedCount: number = 0;
  wheelAdopted: number = 0;
  planGenerated: number = 0;
  fullClearCount: number = 0;
  cuisineEaten: Map<string, number> = new Map();
}

export class SyncQueueItem {
  table: string = '';
  id: string = '';
}

export class AppSettings {
  repeatDays: number = 3;
  dailyDishes: number = 2;
  enabledTypes: string[] = DEFAULT_ENABLED_TYPES.slice();
  members: string[] = ['我', 'TA'];
  currentMember: string = '我';
  // 华为账号登录：openID -> 称呼 绑定；currentUid = 我的 openID
  uidName: Map<string, string> = new Map();
  currentUid: string = '';
  condimentAutoStock: boolean = true; // 生成清单时调味料默认标记家里已有
  maxDuration: number = 0; // 推荐最长烹饪时长（分钟），0=不限
  lunchRemind: boolean = false;
  dinnerRemind: boolean = true;
  lunchTime: string = '11:30';  // 午饭提醒时刻
  dinnerTime: string = '17:30'; // 晚饭提醒时刻
  planPush: boolean = true;     // 对方点菜推送提醒（华为推送，App 未启动也可达）
  blacklists: Map<string, string[]> = new Map(); // 成员 -> 食材/菜名列表
  wheelLimitCategory: string = '';  // 转盘限定类型，空=不限
  wheelLimitMaxDiff: number = 0;    // 转盘难度上限，0=不限
  weeklyBudget: number = 0;         // 每周买菜预算（元），0=不限
}

export const MOODS: string[] = ['开心', '疲惫', '想偷懒', '想吃辣', '想养生'];

// 工具：本地日期 yyyy-MM-dd
export function todayStr(): string {
  const d = new Date();
  return fmtDate(d);
}

export function fmtDate(d: Date): string {
  const m = d.getMonth() + 1;
  const day = d.getDate();
  return d.getFullYear() + '-' + (m < 10 ? '0' + m : '' + m) + '-' + (day < 10 ? '0' + day : '' + day);
}

export function addDays(base: string, delta: number): string {
  const parts = base.split('-');
  const d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
  d.setDate(d.getDate() + delta);
  return fmtDate(d);
}

// 星期几的中文（周一~周日）
export function weekdayCn(dateStr: string): string {
  const parts = dateStr.split('-');
  const d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
  const names: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
  return names[d.getDay()];
}

export function genId(prefix: string): string {
  return prefix + '_' + Date.now().toString(36) + '_' + Math.floor(Math.random() * 46656).toString(36);
}

export function mealTypeCn(t: string): string {
  return t === 'lunch' ? '午餐' : '晚餐';
}
