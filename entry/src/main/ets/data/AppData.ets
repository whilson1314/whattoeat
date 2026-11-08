// 全局数据单例：初始化、种子导入、内存缓存、变更通知
import { Context } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Db } from './Db';
import {
  Recipe, MealEntry, ShoppingItem, FridgeItem, AchProgress, AppSettings,
  DEFAULT_ENABLED_TYPES, Ingredient
} from '../model/Models';

// 页面刷新事件类型
export type DataEvent = number;
export const EVT_RECIPES: number = 1;
export const EVT_ENTRIES: number = 2;
export const EVT_ITEMS: number = 3;
export const EVT_FRIDGE: number = 4;
export const EVT_SETTINGS: number = 5;
export const EVT_ACH: number = 6;

interface SeedTag {
  category: string;
  cuisine: string;
  taste: string;
  type: string;
  isQuick: boolean;
}

interface SeedIngredient {
  name: string;
  amount: string;
  category: string;
}

interface SeedRecipe {
  id: string;
  name: string;
  emoji: string;
  tags: SeedTag;
  durationMin: number;
  difficulty: number;
  calories?: number;
  ingredients: SeedIngredient[];
  steps: string[];
  tips?: string[];
  source?: string;
  createdBy?: string;
}

type Listener = (evt: DataEvent) => void;

class BlacklistEntry {
  member: string = '';
  words: string[] = [];
}

class UidNameEntry {
  uid: string = '';
  name: string = '';
}

class SettingsData {
  repeatDays: number = 3;
  dailyDishes: number = 2;
  enabledTypes: string[] = [];
  members: string[] = [];
  currentMember: string = '';
  currentUid: string = '';
  lunchRemind: boolean = false;
  dinnerRemind: boolean = true;
  lunchTime: string = '11:30';
  dinnerTime: string = '17:30';
  planPush: boolean = true;
  wheelLimitCategory: string = '';
  wheelLimitMaxDiff: number = 0;
  condimentAutoStock: boolean = true;
  maxDuration: number = 0;
  weeklyBudget: number = 0;
  blacklists: BlacklistEntry[] = [];
  uidName: UidNameEntry[] = [];
}

export class AppData {
  private static inst: AppData = new AppData();
  static getInstance(): AppData {
    return AppData.inst;
  }

  private inited: boolean = false;
  private listeners: Listener[] = [];

  recipes: Recipe[] = [];
  entries: MealEntry[] = [];
  items: ShoppingItem[] = [];
  fridge: FridgeItem[] = [];
  achUnlocked: Map<string, AchProgress> = new Map();
  settings: AppSettings = new AppSettings();
  // 成就弹窗队列：引擎检测到新解锁时放入，UI 层消费弹出
  pendingAchPopup: string[] = [];

  async init(context: Context): Promise<void> {
    if (this.inited) {
      return;
    }
    await Db.init(context);
    await this.importSeedIfNeeded(context);
    await this.loadSettings();
    await this.reloadAll();
    this.inited = true;
  }

  isInited(): boolean {
    return this.inited;
  }

  private async importSeedIfNeeded(context: Context): Promise<void> {
    const n = await Db.count('recipe');
    if (n > 0) {
      return;
    }
    const raw: Uint8Array = await context.resourceManager.getRawFileContent('seed_recipes.json');
    const decoder = util.TextDecoder.create('utf-8');
    const text = decoder.decodeToString(raw);
    const seeds: SeedRecipe[] = JSON.parse(text) as SeedRecipe[];
    for (let i = 0; i < seeds.length; i++) {
      const s: SeedRecipe = seeds[i];
      const r = new Recipe();
      r.id = s.id;
      r.name = s.name;
      r.emoji = s.emoji === undefined || s.emoji.length === 0 ? '🍽️' : s.emoji;
      r.cuisine = s.tags.cuisine;
      r.taste = s.tags.taste;
      r.category = s.tags.category;
      r.type = s.tags.type;
      r.isQuick = s.tags.isQuick;
      r.durationMin = s.durationMin;
      r.difficulty = s.difficulty;
      r.calories = s.calories === undefined ? 0 : s.calories;
      const ings: Ingredient[] = [];
      for (let k = 0; k < s.ingredients.length; k++) {
        const ing = new Ingredient();
        ing.name = s.ingredients[k].name;
        ing.amount = s.ingredients[k].amount;
        ing.category = s.ingredients[k].category;
        ings.push(ing);
      }
      r.ingredients = ings;
      r.steps = s.steps;
      r.tips = s.tips === undefined ? [] : s.tips;
      r.favorite = false;
      r.enabled = true;
      r.source = s.source === undefined ? 'HowToCook (Unlicense)' : s.source;
      r.createdBy = s.createdBy === undefined ? 'seed' : s.createdBy;
      r.createdAt = 0;
      await Db.insertRecipe(r);
    }
  }

  private async loadSettings(): Promise<void> {
    const text = await Db.getSetting('settings');
    if (text === null || text.length === 0) {
      await this.saveSettings();
      return;
    }
    try {
      const data = JSON.parse(text) as SettingsData;
      const s = this.settings;
      s.repeatDays = data.repeatDays > 0 ? data.repeatDays : 3;
      s.dailyDishes = data.dailyDishes > 0 ? data.dailyDishes : 2;
      s.enabledTypes = data.enabledTypes !== undefined && data.enabledTypes.length > 0 ?
        data.enabledTypes : DEFAULT_ENABLED_TYPES.slice();
      s.members = data.members !== undefined && data.members.length > 0 ? data.members : ['我', 'TA'];
      s.currentMember = data.currentMember === undefined ? '我' : data.currentMember;
      s.lunchRemind = data.lunchRemind === undefined ? false : data.lunchRemind;
      s.dinnerRemind = data.dinnerRemind === undefined ? true : data.dinnerRemind;
      s.lunchTime = data.lunchTime === undefined ? '11:30' : data.lunchTime;
      s.dinnerTime = data.dinnerTime === undefined ? '17:30' : data.dinnerTime;
      s.planPush = data.planPush === undefined ? true : data.planPush;
      s.wheelLimitCategory = data.wheelLimitCategory === undefined ? '' : data.wheelLimitCategory;
      s.wheelLimitMaxDiff = data.wheelLimitMaxDiff === undefined ? 0 : data.wheelLimitMaxDiff;
      s.currentUid = data.currentUid === undefined ? '' : data.currentUid;
      s.condimentAutoStock = data.condimentAutoStock === undefined ? true : data.condimentAutoStock;
      s.maxDuration = data.maxDuration === undefined ? 0 : data.maxDuration;
      s.weeklyBudget = data.weeklyBudget === undefined ? 0 : data.weeklyBudget;
      if (data.uidName !== undefined) {
        for (let i = 0; i < data.uidName.length; i++) {
          s.uidName.set(data.uidName[i].uid, data.uidName[i].name);
        }
      }
      if (data.blacklists !== undefined) {
        for (let i = 0; i < data.blacklists.length; i++) {
          s.blacklists.set(data.blacklists[i].member, data.blacklists[i].words);
        }
      }
    } catch (e) {
      // 设置损坏则重置为默认
      this.settings = new AppSettings();
      await this.saveSettings();
    }
  }

  async saveSettings(): Promise<void> {
    const data = new SettingsData();
    data.repeatDays = this.settings.repeatDays;
    data.dailyDishes = this.settings.dailyDishes;
    data.enabledTypes = this.settings.enabledTypes;
    data.members = this.settings.members;
    data.currentMember = this.settings.currentMember;
    data.lunchRemind = this.settings.lunchRemind;
    data.dinnerRemind = this.settings.dinnerRemind;
    data.lunchTime = this.settings.lunchTime;
    data.dinnerTime = this.settings.dinnerTime;
    data.planPush = this.settings.planPush;
    data.wheelLimitCategory = this.settings.wheelLimitCategory;
    data.wheelLimitMaxDiff = this.settings.wheelLimitMaxDiff;
    data.currentUid = this.settings.currentUid;
    data.condimentAutoStock = this.settings.condimentAutoStock;
    data.maxDuration = this.settings.maxDuration;
    data.weeklyBudget = this.settings.weeklyBudget;
    this.settings.uidName.forEach((name: string, uid: string) => {
      const e = new UidNameEntry();
      e.uid = uid;
      e.name = name;
      data.uidName.push(e);
    });
    this.settings.blacklists.forEach((arr: string[], key: string) => {
      const e = new BlacklistEntry();
      e.member = key;
      e.words = arr;
      data.blacklists.push(e);
    });
    await Db.putSetting('settings', JSON.stringify(data));
    this.notify(EVT_SETTINGS);
  }

  async reloadAll(): Promise<void> {
    this.recipes = await Db.allRecipes();
    this.entries = await Db.allEntries();
    this.items = await Db.allItems();
    this.fridge = await Db.allFridge();
    const ach = await Db.allAch();
    this.achUnlocked.clear();
    for (let i = 0; i < ach.length; i++) {
      this.achUnlocked.set(ach[i].id, ach[i]);
    }
    // 云同步后的变更要广播给所有页面（否则页面拿不到新数据）
    this.notify(EVT_RECIPES);
    this.notify(EVT_ENTRIES);
    this.notify(EVT_ITEMS);
    this.notify(EVT_FRIDGE);
    this.notify(EVT_ACH);
  }

  async reloadRecipes(): Promise<void> {
    this.recipes = await Db.allRecipes();
    this.notify(EVT_RECIPES);
  }

  async reloadEntries(): Promise<void> {
    this.entries = await Db.allEntries();
    this.notify(EVT_ENTRIES);
  }

  async reloadItems(): Promise<void> {
    this.items = await Db.allItems();
    this.notify(EVT_ITEMS);
  }

  async reloadFridge(): Promise<void> {
    this.fridge = await Db.allFridge();
    this.notify(EVT_FRIDGE);
  }

  // ---------- 监听 ----------
  register(listener: Listener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregister(listener: Listener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  notify(evt: DataEvent): void {
    const snapshot = this.listeners.slice();
    for (let i = 0; i < snapshot.length; i++) {
      try {
        snapshot[i](evt);
      } catch (e) {
        // 单个监听异常不阻断其他
      }
    }
  }

  // ---------- 查询助手 ----------
  recipeById(id: string): Recipe | null {
    for (let i = 0; i < this.recipes.length; i++) {
      if (this.recipes[i].id === id) {
        return this.recipes[i];
      }
    }
    return null;
  }

  entriesOn(date: string): MealEntry[] {
    const out: MealEntry[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].date === date) {
        out.push(this.entries[i]);
      }
    }
    out.sort((a: MealEntry, b: MealEntry): number => {
      if (a.status !== b.status) {
        return a.status === 'planned' ? -1 : 1;
      }
      return b.createdAt - a.createdAt;
    });
    return out;
  }

  entriesRange(start: string, end: string): MealEntry[] {
    const out: MealEntry[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      const d = this.entries[i].date;
      if (d >= start && d <= end) {
        out.push(this.entries[i]);
      }
    }
    return out;
  }

  memberBlacklist(member: string): string[] {
    const arr = this.settings.blacklists.get(member);
    return arr === undefined ? [] : arr;
  }
}
