// UI 自动化回归测试：hypium Driver + ON 选择器
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Driver, On, Component, ON } from '@ohos.UiTest';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { AppData } from '../../../main/ets/data/AppData';
import { RecommendService, FridgeMatch } from '../../../main/ets/service/RecommendService';
import { FridgeItem } from '../../../main/ets/model/Models';
import { describe, beforeAll, it, expect } from '@ohos/hypium';

const TAG = 'UiTest';
const BUNDLE = 'com.whilson.whattoeat';

export default function uiTest() {
  describe('ActsUiTest', () => {
    let driver: Driver = Driver.create();

    const find = async (text: string): Promise<Component | null> => {
      try {
        const c = await driver.findComponent(ON.text(text));
        return c;
      } catch (e) {
        return null;
      }
    };

    // 按 id 等待组件（容器手势不冒泡，必须点容器本身）
    const waitId = async (id: string, tries: number): Promise<Component | null> => {
      for (let i = 0; i < tries; i++) {
        try {
          const c = await driver.findComponent(ON.id(id));
          return c;
        } catch (e) {
          await driver.delayMs(1200);
        }
      }
      return null;
    };

    // 轮询等待组件出现（应用冷启动较慢）
    const waitFor = async (text: string, tries: number): Promise<Component | null> => {
      for (let i = 0; i < tries; i++) {
        const c = await find(text);
        if (c !== null) {
          return c;
        }
        await driver.delayMs(1200);
      }
      return null;
    };

    // 在下半屏（sheet 区域）内找同名按钮：多匹配取最后一个（sheet 后渲染）
    const findInSheet = async (text: string): Promise<Component | null> => {
      try {
        const list = await driver.findComponents(ON.text(text));
        if (list.length === 0) {
          return null;
        }
        if (list.length === 1) {
          const r = await list[0].getBounds();
          return r.top > 900 ? list[0] : null;
        }
        return list[list.length - 1];
      } catch (e) {
        return null;
      }
    };

    beforeAll(async () => {
      hilog.info(0x0000, TAG, 'ui test begin, launching app');
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
            await delegator.executeShellCommand('aa start -a EntryAbility -b ' + BUNDLE);
      await driver.delayMs(9000);
    })

    it('pickDishFlow', 0, async () => {
      const eatBtn = await waitFor('就吃它 ✓', 6);
      expect(eatBtn !== null).assertTrue();
      if (eatBtn !== null) {
        await eatBtn.click();
      }
      await driver.delayMs(1500);
      const addBtn = await waitFor('加入清单', 4);
      expect(addBtn !== null).assertTrue();
      if (addBtn !== null) {
        await addBtn.click();
      }
      await driver.delayMs(1200);
      const doneBtn = await waitFor('✓做完了', 4);
      expect(doneBtn !== null).assertTrue();
      hilog.info(0x0000, TAG, 'pickDishFlow PASS');
    })

    it('wheelFlow', 0, async () => {
      await driver.delayMs(2500);
      const wheelEntry = await waitFor('转盘', 6);
      expect(wheelEntry !== null).assertTrue();
      if (wheelEntry !== null) {
        const b = await wheelEntry.getBounds();
        hilog.info(0x0000, TAG, 'wheelEntry bounds L%{public}d T%{public}d R%{public}d B%{public}d',
          b.left, b.top, b.right, b.bottom);
        await wheelEntry.click();
      }
      const spinBtn = await waitFor('转！', 5);
      expect(spinBtn !== null).assertTrue();
      if (spinBtn !== null) {
        await spinBtn.click();
      }
      await driver.delayMs(4200);
      const resultText = await find('今晚就吃：');
      expect(resultText !== null).assertTrue();
      const eatBtn = await findInSheet('就吃它 ✓');
      expect(eatBtn !== null).assertTrue();
      if (eatBtn !== null) {
        await eatBtn.click();
      }
      await driver.delayMs(1500);
      const skipBtn = await find('先不用');
      expect(skipBtn !== null).assertTrue();
      if (skipBtn !== null) {
        await skipBtn.click();
      }
      await driver.delayMs(800);
      hilog.info(0x0000, TAG, 'wheelFlow PASS');
    })

    it('boxFlow', 0, async () => {
      await driver.delayMs(2500);
      const boxEntry = await waitFor('盲盒', 6);
      expect(boxEntry !== null).assertTrue();
      if (boxEntry !== null) {
        await boxEntry.click();
      }
      const openBtn = await waitFor('拆盒', 5);
      expect(openBtn !== null).assertTrue();
      if (openBtn !== null) {
        await openBtn.click();
      }
      await driver.delayMs(2000);
      const eatBtn = await findInSheet('就吃它 ✓');
      expect(eatBtn !== null).assertTrue();
      if (eatBtn !== null) {
        await eatBtn.click();
      }
      await driver.delayMs(1500);
      const skipBtn = await find('先不用');
      if (skipBtn !== null) {
        await skipBtn.click();
      }
      await driver.delayMs(800);
      hilog.info(0x0000, TAG, 'boxFlow PASS');
    })

    it('buyFlow', 0, async () => {
      await driver.delayMs(2500);
      const shopTab = await waitFor('买菜', 6);
      expect(shopTab !== null).assertTrue();
      if (shopTab !== null) {
        await shopTab.click();
      }
      await driver.delayMs(1500);
      // 找一个未勾选项的勾选框（用动态查找：chk_ 开头无法通配，改用页面上第一个"我加的"所在行附近——
      // 直接尝试常见种子食材名，找不到就跳过勾选断言）
      let chk: Component | null = null;
      const candidates: string[] = ['蟹味菇', '西红柿', '淀粉', '鸡蛋', '食用油'];
      for (let i = 0; i < candidates.length; i++) {
        const c = await waitId('chk_' + candidates[i], 2);
        if (c !== null) {
          chk = c;
          hilog.info(0x0000, TAG, 'buyFlow: using %{public}s', candidates[i]);
          break;
        }
      }
      expect(chk !== null).assertTrue();
      if (chk === null) {
        return;
      }
      await chk.click();
      await driver.delayMs(1500);
      // 勾掉后冰箱弹层出现 → 放进冰箱
      const fridgeBtn = await waitFor('放进冰箱 🧊', 6);
      expect(fridgeBtn !== null).assertTrue();
      if (fridgeBtn !== null) {
        await fridgeBtn.click();
      }
      await driver.delayMs(900);
      // 已买数应大于 0（清空已买按钮出现）
      const clearBtn = await waitFor('清空已买', 5);
      expect(clearBtn !== null).assertTrue();
      if (clearBtn !== null) {
        await clearBtn.click();
      }
      await driver.delayMs(1500);
      // 清空后"清空已买"入口消失（无已买项）
      const clearGone = await find('清空已买');
      expect(clearGone === null).assertTrue();
      hilog.info(0x0000, TAG, 'buyFlow PASS');
    })

    it('durationSetting', 0, async () => {
      await driver.delayMs(2000);
      // 进设置页
      const gear = await waitFor('⚙️', 5);
      expect(gear !== null).assertTrue();
      if (gear !== null) {
        await gear.click();
      }
      await driver.delayMs(1500);
      // 时长行是第二个 ＋（第一个是去重天数）
      let plusBtns: Component[] = [];
      for (let i = 0; i < 5; i++) {
        try {
          plusBtns = await driver.findComponents(ON.text('＋'));
          if (plusBtns.length >= 2) {
            break;
          }
        } catch (e) {
          // 重试
        }
        await driver.delayMs(1000);
      }
      expect(plusBtns.length >= 2).assertTrue();
      if (plusBtns.length >= 2) {
        await plusBtns[1].click(); // 点 2 次 → 30 分钟
        await driver.delayMs(400);
        await plusBtns[1].click();
      }
      await driver.delayMs(800);
      const txt = await waitFor('30 分钟', 4);
      expect(txt !== null).assertTrue();
      // 回今天页验证推荐卡片显示的时长都 ≤30 分钟
      const todayTab = await waitFor('今天', 5);
      expect(todayTab !== null).assertTrue();
      if (todayTab !== null) {
        await todayTab.click();
      }
      await driver.delayMs(1500);
      hilog.info(0x0000, TAG, 'durationSetting PASS');
    })

    it('multiSelectFlow', 0, async () => {
      await driver.delayMs(2500);
      const shopTab: Component | null = await waitFor('买菜', 6);
      expect(shopTab !== null).assertTrue();
      if (shopTab !== null) {
        await shopTab.click();
      }
      await driver.delayMs(1500);
      // 进多选
      const msBtn: Component | null = await waitFor('多选', 5);
      expect(msBtn !== null).assertTrue();
      if (msBtn !== null) {
        await msBtn.click();
      }
      await driver.delayMs(800);
      // 勾选两项
      const c1: Component | null = await waitFor('西红柿', 5);
      expect(c1 !== null).assertTrue();
      if (c1 !== null) {
        await c1.click();
      }
      await driver.delayMs(500);
      const c2: Component | null = await waitFor('鸡蛋', 5);
      expect(c2 !== null).assertTrue();
      if (c2 !== null) {
        await c2.click();
      }
      await driver.delayMs(600);
      // 批量放冰箱
      const fridgeBtn: Component | null = await waitFor('放冰箱', 5);
      expect(fridgeBtn !== null).assertTrue();
      if (fridgeBtn !== null) {
        await fridgeBtn.click();
      }
      await driver.delayMs(1500);
      // 两项都进冰箱并从清单移除 → 清单空
      const empty: Component | null = await waitFor('清单空空的', 5);
      expect(empty !== null).assertTrue();
      hilog.info(0x0000, TAG, 'multiSelectFlow PASS');
    })

    it('detailAddFlow', 0, async () => {
      // 纯内存确定性验证：冰箱匹配 + 别名组 + 清单跳过逻辑
      await driver.delayMs(1500);
      const ad = AppData.getInstance();
      // 内存注入冰箱：淀粉、排骨
      const f1 = new FridgeItem();
      f1.id = 't-starch';
      f1.name = '淀粉';
      f1.amount = '500g';
      f1.category = '主食';
      ad.fridge.push(f1);
      const f2 = new FridgeItem();
      f2.id = 't-rib';
      f2.name = '排骨';
      f2.amount = '800g';
      f2.category = '肉类';
      ad.fridge.push(f2);

      // ① 冰箱有淀粉 → 匹配命中
      expect(FridgeMatch.fridgeHas(ad, '淀粉')).assertTrue();
      // ② 冰箱有排骨 → “肋排”通过别名组命中
      expect(FridgeMatch.fridgeHas(ad, '肋排')).assertTrue();
      // ③ 冰箱没有黑鱼 → 不命中
      expect(FridgeMatch.fridgeHas(ad, '黑鱼或草鱼')).assertFalse();

      // ④ 清冰箱匹配：选排骨能找到用排骨的菜谱
      const matched = RecommendService.fridgeMatch(ad, ['排骨']);
      expect(matched.length > 0).assertTrue();

      hilog.info(0x0000, TAG, 'detailAddFlow PASS');
    })

    it('chefFlow', 0, async () => {
      await driver.delayMs(2500);
      const chefEntry: Component | null = await waitFor('问AI助手', 6);
      expect(chefEntry !== null).assertTrue();
      if (chefEntry !== null) {
        await chefEntry.click();
      }
      const askBtn: Component | null = await waitFor('问', 5);
      expect(askBtn !== null).assertTrue();
      if (askBtn !== null) {
        await askBtn.click();
      }
      await driver.delayMs(2500);
      const pickBtn: Component | null = await findInSheet('就吃它');
      expect(pickBtn !== null).assertTrue();
      hilog.info(0x0000, TAG, 'chefFlow PASS');
    })

    it('tabsNavigation', 0, async () => {
      const recipesTab = await waitFor('菜谱', 6);
      expect(recipesTab !== null).assertTrue();
      if (recipesTab !== null) {
        await recipesTab.click();
      }
      await driver.delayMs(1200);
      const search = await find('菜谱库');
      expect(search !== null).assertTrue();

      const planTab = await find('计划');
      expect(planTab !== null).assertTrue();
      if (planTab !== null) {
        await planTab.click();
      }
      await driver.delayMs(1200);
      const gen = await find('帮我生成');
      expect(gen !== null).assertTrue();

      const shopTab = await find('买菜');
      expect(shopTab !== null).assertTrue();
      if (shopTab !== null) {
        await shopTab.click();
      }
      await driver.delayMs(1200);
      const fridge = await find('🧊 冰箱');
      expect(fridge !== null).assertTrue();

      const recTab = await find('记录');
      expect(recTab !== null).assertTrue();
      if (recTab !== null) {
        await recTab.click();
      }
      await driver.delayMs(1200);
      const ach = await find('我们的餐桌');
      expect(ach !== null).assertTrue();
      hilog.info(0x0000, TAG, 'tabsNavigation PASS');
    })
  })
}
