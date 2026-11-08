// LLM 服务客户端：统一走自建同步服务的 /llm 代理（Key 只在服务端）。
// 任一失败（未配 Key / 超时 / 校验失败）返回 null，由调用方降级为本地逻辑。
// 设计对应《LLM接入设计.md》：generate（新菜填充）/ recommend（问AI助手）/
// fridge（清冰箱生成）/ substitute（食材替换）。
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppData } from '../data/AppData';
import { Recipe, Ingredient, genId } from '../model/Models';
// 服务地址与令牌统一在 config/ServerConfig.ets（本地私有文件，不入库）
import { SERVER, TOKEN } from '../config/ServerConfig';

const TAG: string = 'AiService';
const DOMAIN: number = 0x0000;

class AiIngredient {
  name: string = '';
  amount: string = '';
  category: string = '其他';
}

class GenRecipeData {
  name: string = '';
  emoji: string = '';
  cuisine: string = '';
  taste: string = '';
  category: string = '';
  type: string = '';
  isQuick: boolean = false;
  durationMin: number = 0;
  difficulty: number = 0;
  calories: number = 0;
  protein: number = 0;
  fat: number = 0;
  carbs: number = 0;
  ingredients: AiIngredient[] = [];
  steps: string[] = [];
  tips: string[] = [];
  uses: string[] = [];
}

class LlmResp {
  ok: boolean = false;
  error: string = '';
  code: string = '';
  data: Record<string, Object> | null = null;
}

export class RecommendPick {
  recipe: Recipe = new Recipe();
  reason: string = '';
}

// 小红书灵感卡（服务端只透出标题/作者/点赞/链接/AI 提炼摘要，不含笔记正文）
export class ChefInspiration {
  title: string = '';
  url: string = '';
  summary: string = '';
  author: string = '';
  likes: string = '';
  dish: string = ''; // 合集类笔记里 LLM 挑出的具体菜名；空=拿不到，走「看原文挑菜」
}

// 问AI助手回答：库内推荐 + 小红书灵感（至少一项非空）
export class ChefAnswer {
  picks: RecommendPick[] = [];
  inspirations: ChefInspiration[] = [];
}

// 生成结果 → 本地 Recipe（已入库前草稿）
function toRecipe(g: Record<string, Object>): Recipe {
  const r = new Recipe();
  r.id = genId('rc');
  r.name = str(g, 'name');
  r.emoji = str(g, 'emoji').length > 0 ? str(g, 'emoji') : '🍽️';
  r.cuisine = str(g, 'cuisine');
  r.taste = str(g, 'taste');
  r.category = str(g, 'category');
  r.type = str(g, 'type');
  r.isQuick = bool(g, 'isQuick');
  r.durationMin = num(g, 'durationMin');
  r.difficulty = num(g, 'difficulty');
  r.calories = num(g, 'calories');
  r.protein = num(g, 'protein');
  r.fat = num(g, 'fat');
  r.carbs = num(g, 'carbs');
  const ings = arr(g, 'ingredients');
  const out: Ingredient[] = [];
  for (let i = 0; i < ings.length; i++) {
    const im = ings[i] as Record<string, Object>;
    if (im === undefined || im === null) {
      continue;
    }
    const ing = new Ingredient();
    ing.name = str(im, 'name');
    ing.amount = str(im, 'amount');
    ing.category = str(im, 'category').length > 0 ? str(im, 'category') : '其他';
    if (ing.name.length > 0) {
      out.push(ing);
    }
  }
  r.ingredients = out;
  r.steps = strArr(g, 'steps');
  r.tips = strArr(g, 'tips');
  r.enabled = true;
  r.source = 'AI 生成';
  r.createdAt = Date.now();
  return r;
}

function str(o: Record<string, Object>, k: string): string {
  const v = o[k];
  return v === undefined || v === null ? '' : String(v);
}

function num(o: Record<string, Object>, k: string): number {
  const v = o[k];
  if (typeof v === 'number') {
    return v as number;
  }
  if (typeof v === 'string') {
    return Number(v);
  }
  return 0;
}

function bool(o: Record<string, Object>, k: string): boolean {
  const v = o[k];
  return typeof v === 'boolean' ? v as boolean : false;
}

function arr(o: Record<string, Object>, k: string): Object[] {
  const v = o[k];
  return Array.isArray(v) ? v as Object[] : [];
}

function strArr(o: Record<string, Object>, k: string): string[] {
  const v = arr(o, k);
  const out: string[] = [];
  for (let i = 0; i < v.length; i++) {
    const s = String(v[i]);
    if (s.length > 0) {
      out.push(s);
    }
  }
  return out;
}

export class AiService {
  static lastError: string = ''; // 最近一次服务端拒绝/失败原因（供调用方提示）
  private static allowedActions: string[] = []; // 服务端动作白名单

  // 是否允许该动作走 LLM：白名单未知时先尝试，由服务端裁决
  static can(action: string): boolean {
    if (AiService.allowedActions.length === 0) {
      return true;
    }
    return AiService.allowedActions.includes(action);
  }

  // 底层：POST /llm {action, data}，失败/未配置/被白名单拒绝返回 null。
  // readTimeout：web 模式（多轮工具循环）需放宽，普通动作保持 20s。
  private static async post(action: string, body: Record<string, Object>,
    readTimeout: number = 20000): Promise<Record<string, Object> | null> {
    const hr = http.createHttp();
    try {
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + TOKEN
        },
        extraData: JSON.stringify({ 'action': action, 'data': body } as Record<string, Object>),
        connectTimeout: 8000,
        readTimeout: readTimeout
      };
      const resp = await hr.request(SERVER + '/llm', opt);
      if (resp.responseCode !== 200) {
        hilog.warn(DOMAIN, TAG, 'llm http %{public}d', resp.responseCode);
        return null;
      }
      const parsed = JSON.parse(resp.result as string) as LlmResp;
      if (!parsed.ok || parsed.data === null) {
        hilog.info(DOMAIN, TAG, 'llm not ok: %{public}s', parsed.error);
        AiService.lastError = parsed.error;
        return null;
      }
      AiService.lastError = '';
      return parsed.data;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'llm request failed');
      AiService.lastError = '网络不佳，稍后再试';
      return null;
    } finally {
      hr.destroy();
    }
  }

  // 是否可用（服务端已配 Key）——惰性探测结果缓存 5 分钟
  private static lastProbeAt: number = 0;
  private static probeOk: boolean = false;
  static xhsAvailable: boolean = false; // 服务端已配置小红书灵感（问AI助手开关显隐）

  static available(): boolean {
    return AiService.probeOk;
  }

  static async probe(): Promise<boolean> {
    const now = Date.now();
    if (now - AiService.lastProbeAt < 5 * 60 * 1000) {
      return AiService.probeOk;
    }
    const hr = http.createHttp();
    try {
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: { 'Authorization': 'Bearer ' + TOKEN },
        connectTimeout: 6000,
        readTimeout: 8000
      };
      const resp = await hr.request(SERVER + '/health', opt);
      if (resp.responseCode === 200) {
        const o = JSON.parse(resp.result as string) as Record<string, Object>;
        AiService.probeOk = o['llm'] === true;
        AiService.xhsAvailable = o['xhs'] === true;
        const acts = o['actions'];
        const list: string[] = [];
        if (Array.isArray(acts)) {
          const arr = acts as Object[];
          for (let i = 0; i < arr.length; i++) {
            list.push(String(arr[i]));
          }
        }
        AiService.allowedActions = list;
      } else {
        AiService.probeOk = false;
        AiService.allowedActions = [];
      }
    } catch (e) {
      AiService.probeOk = false;
    } finally {
      hr.destroy();
      AiService.lastProbeAt = now;
    }
    return AiService.probeOk;
  }

  // ---------- 新菜智能填充 ----------
  static async generateRecipe(name: string, hint: string): Promise<Recipe | null> {
    const body: Record<string, Object> = { 'name': name, 'hint': hint };
    const data = await AiService.post('generate', body);
    if (data === null) {
      return null;
    }
    const r = toRecipe(data);
    return r.name.length > 0 && r.steps.length > 0 && r.ingredients.length > 0 ? r : null;
  }

  // ---------- 清冰箱 AI 生成（白名单未含 fridge 时直接走本地） ----------
  static async fridgeRecipe(ingredients: string[], hint: string): Promise<Recipe | null> {
    if (ingredients.length === 0 || !AiService.can('fridge')) {
      return null;
    }
    const body: Record<string, Object> = { 'ingredients': ingredients as Object, 'hint': hint };
    const data = await AiService.post('fridge', body);
    if (data === null) {
      return null;
    }
    const r = toRecipe(data);
    return r.name.length > 0 && r.steps.length > 0 ? r : null;
  }

  // ---------- 问AI助手（对话点菜，可选小红书灵感） ----------
  // useWeb=true 时服务端允许 LLM 调小红书搜索工具（超时放宽到 90s）；
  // 返回库内推荐 + 小红书灵感（服务端已做 ref 硬映射校验，至少一项非空才非 null）
  static async recommend(ad: AppData, utterance: string, mood: string,
    excludeNames: Set<string>, useWeb: boolean): Promise<ChefAnswer | null> {
    // 候选库：enabled + 非不爱吃；注入摘要字段
    const lib: Record<string, Object>[] = [];
    for (let i = 0; i < ad.recipes.length && lib.length < 500; i++) {
      const r = ad.recipes[i];
      if (!r.enabled || r.dislike) {
        continue;
      }
      lib.push({
        'id': r.id as Object, 'name': r.name as Object, 'cuisine': r.cuisine as Object,
        'taste': r.taste as Object, 'category': r.category as Object, 'isQuick': r.isQuick as Object
      });
    }
    // 近 7 天吃过的菜名
    const recentNames: Object[] = [];
    const weekAgo = new Date(Date.now() - 7 * 86400000);
    const m = weekAgo.getMonth() + 1;
    const d = weekAgo.getDate();
    const start = weekAgo.getFullYear() + '-' + (m < 10 ? '0' + m : '' + m) + '-' + (d < 10 ? '0' + d : '' + d);
    const entries = ad.entriesRange(start, '2999-12-31');
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].status === 'eaten') {
        recentNames.push(entries[i].dishName as Object);
      }
    }
    const planned: Object[] = [];
    for (let i = 0; i < ad.entries.length; i++) {
      if (ad.entries[i].status === 'planned') {
        planned.push(ad.entries[i].dishName as Object);
      }
    }
    const body: Record<string, Object> = {
      'utterance': utterance as Object, 'mood': mood as Object,
      'recent': recentNames as Object, 'planned': planned as Object,
      'web': useWeb as Object, 'recipes': lib as Object
    };
    const data = await AiService.post('recommend', body, useWeb ? 90000 : 20000);
    if (data === null) {
      return null;
    }
    const ans = new ChefAnswer();
    const picks = arr(data, 'picks');
    for (let i = 0; i < picks.length; i++) {
      const pm = picks[i] as Record<string, Object>;
      if (pm === undefined || pm === null) {
        continue;
      }
      const id = str(pm, 'recipeId');
      const r = ad.recipeById(id);
      if (r === null || excludeNames.has(r.name)) {
        continue; // 防幻觉：库外 id 丢弃
      }
      const p = new RecommendPick();
      p.recipe = r;
      p.reason = str(pm, 'reason');
      ans.picks.push(p);
      if (ans.picks.length >= 3) {
        break;
      }
    }
    // 小红书灵感（服务端保证 url 来自真实搜索结果；此处仅容错解析）
    const insp = arr(data, 'inspirations');
    for (let i = 0; i < insp.length && ans.inspirations.length < 3; i++) {
      const im = insp[i] as Record<string, Object>;
      if (im === undefined || im === null) {
        continue;
      }
      const title = str(im, 'title');
      const url = str(im, 'url');
      if (title.length === 0 || url.length === 0) {
        continue;
      }
      const c = new ChefInspiration();
      c.title = title;
      c.url = url;
      c.summary = str(im, 'summary');
      c.author = str(im, 'author');
      c.likes = str(im, 'likes');
      c.dish = str(im, 'dish');
      ans.inspirations.push(c);
    }
    return (ans.picks.length > 0 || ans.inspirations.length > 0) ? ans : null;
  }

  // 服务端 AI 状态与用量（设置页展示用）
  static async info(): Promise<string> {
    const hr = http.createHttp();
    try {
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: { 'Authorization': 'Bearer ' + TOKEN },
        connectTimeout: 6000,
        readTimeout: 8000
      };
      const resp = await hr.request(SERVER + '/health', opt);
      if (resp.responseCode !== 200) {
        return 'AI 状态获取失败';
      }
      const o = JSON.parse(resp.result as string) as Record<string, Object>;
      if (o['llm'] !== true) {
        return 'AI 未启用（服务器未配置 Key），全部功能走本地逻辑';
      }
      const u = o['usage'] as Record<string, Object>;
      const mc = u === undefined || u === null ? 0 : Number(u['month_count']);
      const ml = u === undefined || u === null ? 0 : Number(u['month_limit']);
      const tin = u === undefined || u === null ? 0 : Number(u['tokens_in']);
      const tout = u === undefined || u === null ? 0 : Number(u['tokens_out']);
      const tl = u === undefined || u === null ? 0 : Number(u['tokens_limit']);
      return String(o['model']) + ' · 本月 ' + mc + '/' + ml + ' 次 · tokens ' +
        (tin + tout) + '/' + tl;
    } catch (e) {
      return 'AI 状态获取失败（网络）';
    } finally {
      hr.destroy();
    }
  }

  // ---------- 食材替换建议 ----------
  static async substitute(ingredient: string, dish: string): Promise<string[] | null> {
    const body: Record<string, Object> = { 'ingredient': ingredient, 'dish': dish };
    const data = await AiService.post('substitute', body);
    if (data === null) {
      return null;
    }
    const subs = strArr(data, 'substitutes');
    return subs.length > 0 ? subs : null;
  }
}
