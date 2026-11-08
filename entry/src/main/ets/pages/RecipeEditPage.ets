// 菜品新增/编辑（含 LLM 智能填充、收藏分组、营养字段）
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { AppData } from '../data/AppData';
import { Db } from '../data/Db';
import { Actions } from '../service/Actions';
import { AiService } from '../service/AiService';
import { Recipe, Ingredient, DISH_CATEGORIES, genId, copyRecipe } from '../model/Models';

@Entry
@Component
struct RecipeEditPage {
  @State recipe: Recipe = new Recipe();
  @State isNew: boolean = true;
  // 编辑中的临时列表
  @State ings: Ingredient[] = [];
  @State steps: string[] = [];
  @State tips: string[] = [];
  @State ingName: string = '';
  @State ingAmount: string = '';
  @State ingCat: string = '其他';
  @State stepInput: string = '';
  @State tipInput: string = '';
  @State emojiInput: string = '';
  // AI 智能填充
  @State aiBusy: boolean = false;
  @State aiHint: string = '';
  // 收藏分组
  @State newGroup: string = '';
  private ad: AppData = AppData.getInstance();
  private cats: string[] = ['蔬菜', '肉类', '水产', '蛋奶豆', '主食', '调味', '其他'];

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string>;
    const id = params === undefined ? '' : (params.id === undefined ? '' : params.id);
    if (id.length > 0) {
      const r = this.ad.recipeById(id);
      if (r !== null) {
        const copy = copyRecipe(r);
        this.recipe = copy;
        this.ings = copy.ingredients.slice();
        this.steps = copy.steps.slice();
        this.tips = copy.tips.slice();
        this.emojiInput = copy.emoji;
        this.isNew = false;
      }
    }
    if (this.recipe.id.length === 0) {
      this.recipe.id = genId('rc');
      this.recipe.emoji = '🍽️';
      this.recipe.enabled = true;
    }
    // 问AI助手「照着做」带入：小红书笔记标题 → 菜名 + AI 提示词，自动填充
    if (params !== undefined && params.aiName !== undefined && params.aiName.length > 0
      && this.recipe.name.length === 0) {
      this.recipe.name = params.aiName;
      this.aiHint = params.aiHint === undefined ? '' : params.aiHint;
      this.aiFill();
    }
  }

  // ---------- LLM 智能填充：菜名 → 类型/口味/食材/步骤等 ----------
  async aiFill(): Promise<void> {
    const name = this.recipe.name.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '先填菜名，AI 才知道做什么菜', duration: 1800 });
      return;
    }
    if (this.aiBusy) {
      return;
    }
    const hasContent = this.ings.length > 0 || this.steps.length > 0;
    if (hasContent) {
      // 已有内容：确认后覆盖
      AlertDialog.show({
        title: '覆盖现有内容？',
        message: 'AI 会按「' + name + '」重新生成类型、口味、食材和步骤，覆盖当前填写。',
        autoCancel: true,
        alignment: DialogAlignment.Center,
        primaryButton: { value: '先不了', action: (): void => {} },
        secondaryButton: {
          value: '覆盖填充',
          fontColor: $r('app.color.primary'),
          action: (): void => {
            this.doAiFill(name);
          }
        }
      });
      return;
    }
    await this.doAiFill(name);
  }

  private async doAiFill(name: string): Promise<void> {
    this.aiBusy = true;
    const r = await AiService.generateRecipe(name, this.aiHint.trim());
    this.aiBusy = false;
    if (r === null) {
      promptAction.showToast({
        message: 'AI 助手暂不可用（服务器未配置 Key 或网络不佳），先手动填吧', duration: 2600
      });
      return;
    }
    // 应用生成结果（保留当前 id / favorite / enabled / collections / 创建信息）
    const keepId = this.recipe.id;
    const keepFav = this.recipe.favorite;
    const keepCol = this.recipe.collections.slice();
    const keepCreated = this.recipe.createdAt;
    const keepBy = this.recipe.createdBy;
    this.recipe = r;
    this.recipe.id = keepId;
    this.recipe.favorite = keepFav;
    this.recipe.collections = keepCol;
    this.recipe.createdAt = keepCreated;
    this.recipe.createdBy = keepBy;
    if (this.aiHint.indexOf('小红书笔记') >= 0) {
      this.recipe.source = 'AI · 小红书灵感';
    }
    this.ings = r.ingredients.slice();
    this.steps = r.steps.slice();
    this.tips = r.tips.slice();
    this.emojiInput = r.emoji;
    promptAction.showToast({ message: 'AI 帮你填好了，检查一下再保存 ✨', duration: 2200 });
  }

  // ---------- 收藏分组 ----------
  knownGroups(): string[] {
    const set: Set<string> = new Set();
    for (let i = 0; i < this.ad.recipes.length; i++) {
      const cs = this.ad.recipes[i].collections;
      for (let k = 0; k < cs.length; k++) {
        set.add(cs[k]);
      }
    }
    return Array.from(set);
  }

  toggleGroup(g: string): void {
    const cs = this.recipe.collections;
    const idx = cs.indexOf(g);
    if (idx >= 0) {
      cs.splice(idx, 1);
    } else {
      cs.push(g);
    }
    this.recipe.collections = cs.slice();
  }

  addGroup(): void {
    const g = this.newGroup.trim();
    if (g.length === 0 || this.recipe.collections.includes(g)) {
      this.newGroup = '';
      return;
    }
    this.recipe.collections = this.recipe.collections.concat([g]);
    this.newGroup = '';
  }

  save(): void {
    const name = this.recipe.name.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '菜名不能为空', duration: 1500 });
      return;
    }
    if (this.steps.length === 0) {
      promptAction.showToast({ message: '至少写一个步骤', duration: 1500 });
      return;
    }
    this.recipe.name = name;
    this.recipe.emoji = this.emojiInput.trim().length > 0 ? this.emojiInput.trim() : '🍽️';
    if (this.recipe.category.length === 0) {
      this.recipe.category = '荤菜';
      this.recipe.type = '荤';
    }
    this.recipe.ingredients = this.ings;
    this.recipe.steps = this.steps;
    this.recipe.tips = this.tips;
    // 保留 AI 生成来源标记；手写菜才标"手写"
    if (this.isNew && this.recipe.source.length === 0) {
      this.recipe.source = '手写';
    }
    this.recipe.createdBy = this.ad.settings.currentMember;
    Actions.saveRecipe(this.ad, this.recipe, this.isNew);
    promptAction.showToast({ message: this.isNew ? '新菜入库 🎉' : '已保存', duration: 1500 });
    router.back();
  }

  build() {
    Column() {
      // 顶栏
      Row() {
        Text('←')
          .fontSize(20)
          .fontColor($r('app.color.text_primary'))
          .padding({ left: 16, right: 12, top: 10, bottom: 10 })
          .onClick(() => {
            router.back();
          })
        Text(this.isNew ? '添加新菜' : '编辑「' + this.recipe.name + '」')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text('保存 ✓')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.primary'))
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(999)
          .margin({ right: 16 })
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')

      Scroll() {
        Column() {
          FieldLabel({ t: '菜名' })
          TextInput({ placeholder: '如：妈妈牌红烧肉', text: this.recipe.name })
            .fontSize(14)
            .height(42)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(12)
            .onChange((v: string) => {
              this.recipe.name = v;
            })
            .onSubmit(() => {
              this.aiFill();
            })

          // ✨ AI 智能填充：菜名 → 类型/口味/食材/步骤/营养
          Column() {
            Row({ space: 8 }) {
              Text(this.aiBusy ? '🤖 AI 助手编写中…' : '✨ AI 帮我填')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
                .backgroundColor(this.aiBusy ? $r('app.color.strike') : $r('app.color.primary'))
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .borderRadius(999)
                .onClick(() => {
                  this.aiFill();
                })
              TextInput({ placeholder: '补充描述（可空）：微辣、少油…', text: this.aiHint })
                .fontSize(11)
                .height(34)
                .layoutWeight(1)
                .backgroundColor($r('app.color.surface_soft'))
                .borderRadius(999)
                .onChange((v: string) => {
                  this.aiHint = v;
                })
            }
            .width('100%')
            Text('输入菜名一键生成类型/口味/食材/步骤/小贴士，生成后可手动改')
              .fontSize(9)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .margin({ top: 5 })
          }
          .width('100%')
          .padding({ top: 10, bottom: 10, left: 12, right: 12 })
          .borderRadius(14)
          .backgroundColor($r('app.color.surface_soft'))
          .borderWidth(1)
          .borderColor($r('app.color.divider'))
          .margin({ top: 10 })

          Row({ space: 10 }) {
            Column() {
              FieldLabel({ t: 'Emoji' })
              TextInput({ placeholder: '🍳', text: this.emojiInput })
                .fontSize(14)
                .height(42)
                .width(80)
                .backgroundColor($r('app.color.surface'))
                .borderRadius(12)
                .maxLength(4)
                .onChange((v: string) => {
                  this.emojiInput = v;
                })
            }
            .alignItems(HorizontalAlign.Start)

            Column() {
              FieldLabel({ t: '时长（分钟，可空）' })
              TextInput({ placeholder: '如 25', text: this.recipe.durationMin > 0 ? '' + this.recipe.durationMin : '' })
                .fontSize(14)
                .height(42)
                .width(120)
                .backgroundColor($r('app.color.surface'))
                .borderRadius(12)
                .type(InputType.Number)
                .onChange((v: string) => {
                  this.recipe.durationMin = v.length === 0 ? -1 : Number(v);
                })
            }
            .alignItems(HorizontalAlign.Start)

            Column() {
              FieldLabel({ t: '难度 ★' })
              Row({ space: 6 }) {
                Text('−')
                  .fontSize(14)
                  .width(30)
                  .height(42)
                  .textAlign(TextAlign.Center)
                  .backgroundColor($r('app.color.surface'))
                  .borderRadius(12)
                  .onClick(() => {
                    if (this.recipe.difficulty > 1) {
                      this.recipe.difficulty--;
                    }
                  })
                Text(this.recipe.difficulty + '')
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .width(30)
                  .textAlign(TextAlign.Center)
                Text('＋')
                  .fontSize(13)
                  .width(30)
                  .height(42)
                  .textAlign(TextAlign.Center)
                  .backgroundColor($r('app.color.surface'))
                  .borderRadius(12)
                  .onClick(() => {
                    if (this.recipe.difficulty < 5) {
                      this.recipe.difficulty++;
                    }
                  })
              }
            }
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .margin({ top: 4 })

          // 营养字段（每份，可空；AI 填充时一并生成）
          Row({ space: 8 }) {
            Text('热量 ' + (this.recipe.calories > 0 ? this.recipe.calories + ' 大卡' : '—'))
              .fontSize(10)
              .fontColor($r('app.color.text_hint'))
            TextInput({ placeholder: '蛋白g', text: this.recipe.protein > 0 ? '' + this.recipe.protein : '' })
              .fontSize(11)
              .height(34)
              .layoutWeight(1)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(8)
              .type(InputType.Number)
              .onChange((v: string) => {
                this.recipe.protein = v.length === 0 ? 0 : Number(v);
              })
            TextInput({ placeholder: '脂肪g', text: this.recipe.fat > 0 ? '' + this.recipe.fat : '' })
              .fontSize(11)
              .height(34)
              .layoutWeight(1)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(8)
              .type(InputType.Number)
              .onChange((v: string) => {
                this.recipe.fat = v.length === 0 ? 0 : Number(v);
              })
            TextInput({ placeholder: '碳水g', text: this.recipe.carbs > 0 ? '' + this.recipe.carbs : '' })
              .fontSize(11)
              .height(34)
              .layoutWeight(1)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(8)
              .type(InputType.Number)
              .onChange((v: string) => {
                this.recipe.carbs = v.length === 0 ? 0 : Number(v);
              })
            TextInput({ placeholder: '大卡', text: this.recipe.calories > 0 ? '' + this.recipe.calories : '' })
              .fontSize(11)
              .height(34)
              .layoutWeight(1)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(8)
              .type(InputType.Number)
              .onChange((v: string) => {
                this.recipe.calories = v.length === 0 ? 0 : Number(v);
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          FieldLabel({ t: '类型' })
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(DISH_CATEGORIES, (c: string) => {
              Text(c)
                .fontSize(12)
                .fontColor(this.recipe.category === c ? Color.White : $r('app.color.text_secondary'))
                .backgroundColor(this.recipe.category === c ? $r('app.color.primary') : $r('app.color.surface'))
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .borderRadius(999)
                .margin(4)
                .onClick(() => {
                  this.recipe.category = c;
                  this.recipe.type = c === '素菜' ? '素' : c === '汤粥' ? '汤' :
                    c === '主食' || c === '早餐' ? '主食' : '荤';
                })
            }, (c: string) => c)
          }
          .width('100%')

          FieldLabel({ t: '口味' })
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(['咸鲜', '辣', '酸辣', '香辣', '清淡', '酸甜', '甜', '鱼香'], (t: string) => {
              Text(t)
                .fontSize(12)
                .fontColor(this.recipe.taste === t ? Color.White : $r('app.color.text_secondary'))
                .backgroundColor(this.recipe.taste === t ? $r('app.color.primary') : $r('app.color.surface'))
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .borderRadius(999)
                .margin(4)
                .onClick(() => {
                  this.recipe.taste = t;
                })
            }, (t: string) => t)
          }
          .width('100%')

          // 收藏分组
          FieldLabel({ t: '收藏分组（可多选）' })
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.recipe.collections, (g: string) => {
              Text(g + ' ✕')
                .fontSize(11)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.green'))
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .borderRadius(999)
                .margin(4)
                .onClick(() => {
                  this.toggleGroup(g);
                })
            }, (g: string) => g + this.recipe.collections.length)
            ForEach(this.knownGroups(), (g: string) => {
              if (!this.recipe.collections.includes(g)) {
                Text('+ ' + g)
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .backgroundColor($r('app.color.surface'))
                  .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                  .borderRadius(999)
                  .margin(4)
                  .onClick(() => {
                    this.toggleGroup(g);
                  })
              }
            }, (g: string) => 'known' + g)
          }
          .width('100%')
          Row({ space: 8 }) {
            TextInput({ placeholder: '新分组名，如：减脂餐', text: this.newGroup })
              .fontSize(11)
              .height(34)
              .layoutWeight(1)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(10)
              .onChange((v: string) => {
                this.newGroup = v;
              })
              .onSubmit(() => {
                this.addGroup();
              })
            Text('加入分组')
              .fontSize(11)
              .fontColor(Color.White)
              .backgroundColor($r('app.color.primary'))
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .borderRadius(10)
              .onClick(() => {
                this.addGroup();
              })
          }
          .width('100%')
          .margin({ top: 4 })

          // 食材
          FieldLabel({ t: '食材（' + this.ings.length + '）' })
          ForEach(this.ings, (ing: Ingredient, i: number) => {
            Row({ space: 8 }) {
              Text(ing.name).fontSize(12).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Text(ing.amount).fontSize(11).fontColor($r('app.color.text_hint'))
              Text(ing.category).fontSize(9).fontColor($r('app.color.text_hint'))
              Text('✕')
                .fontSize(11)
                .fontColor($r('app.color.primary'))
                .padding(4)
                .onClick(() => {
                  this.ings.splice(i, 1);
                  this.ings = this.ings.slice();
                })
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
          }, (ing: Ingredient, i: number) => ing.name + i)
          Row({ space: 8 }) {
            TextInput({ placeholder: '食材名', text: this.ingName })
              .fontSize(12)
              .height(38)
              .layoutWeight(2)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(10)
              .onChange((v: string) => {
                this.ingName = v;
              })
            TextInput({ placeholder: '量', text: this.ingAmount })
              .fontSize(12)
              .height(38)
              .layoutWeight(1)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(10)
              .onChange((v: string) => {
                this.ingAmount = v;
              })
            Select(this.catOptions())
              .selected(this.cats.indexOf(this.ingCat))
              .value(this.ingCat)
              .font({ size: 12 })
              .height(38)
              .onSelect((idx: number) => {
                this.ingCat = this.cats[idx];
              })
            Text('＋')
              .fontSize(15)
              .fontColor(Color.White)
              .width(38)
              .height(38)
              .textAlign(TextAlign.Center)
              .backgroundColor($r('app.color.primary'))
              .borderRadius(10)
              .onClick(() => {
                const n = this.ingName.trim();
                if (n.length === 0) {
                  return;
                }
                const ing = new Ingredient();
                ing.name = n;
                ing.amount = this.ingAmount.trim();
                ing.category = this.ingCat;
                this.ings.push(ing);
                this.ings = this.ings.slice();
                this.ingName = '';
                this.ingAmount = '';
              })
          }
          .width('100%')

          // 步骤
          FieldLabel({ t: '步骤（' + this.steps.length + '）' })
          ForEach(this.steps, (s: string, i: number) => {
            Row({ space: 8 }) {
              Text((i + 1) + '')
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
                .width(18)
                .height(18)
                .textAlign(TextAlign.Center)
                .borderRadius(9)
                .backgroundColor($r('app.color.primary'))
              Text(s)
                .fontSize(12)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
                .maxLines(2)
              Text('✕')
                .fontSize(11)
                .fontColor($r('app.color.primary'))
                .padding(4)
                .onClick(() => {
                  this.steps.splice(i, 1);
                  this.steps = this.steps.slice();
                })
            }
            .width('100%')
            .padding({ top: 5, bottom: 5 })
            .alignItems(VerticalAlign.Top)
          }, (s: string, i: number) => 'st' + i + s.substring(0, 4))
          Row({ space: 8 }) {
            TextInput({ placeholder: '这一步怎么做？', text: this.stepInput })
              .fontSize(12)
              .height(38)
              .layoutWeight(1)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(10)
              .onChange((v: string) => {
                this.stepInput = v;
              })
              .onSubmit(() => {
                this.addStep();
              })
            Text('＋')
              .fontSize(15)
              .fontColor(Color.White)
              .width(38)
              .height(38)
              .textAlign(TextAlign.Center)
              .backgroundColor($r('app.color.primary'))
              .borderRadius(10)
              .onClick(() => {
                this.addStep();
              })
          }
          .width('100%')

          // 贴士
          FieldLabel({ t: '小贴士（可空）' })
          ForEach(this.tips, (t: string, i: number) => {
            Row({ space: 8 }) {
              Text('· ' + t).fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1)
              Text('✕')
                .fontSize(11)
                .fontColor($r('app.color.primary'))
                .padding(4)
                .onClick(() => {
                  this.tips.splice(i, 1);
                  this.tips = this.tips.slice();
                })
            }
            .width('100%')
            .padding({ top: 4, bottom: 4 })
          }, (t: string, i: number) => 'tip' + i + t.substring(0, 4))
          Row({ space: 8 }) {
            TextInput({ placeholder: '一句提醒', text: this.tipInput })
              .fontSize(12)
              .height(38)
              .layoutWeight(1)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(10)
              .onChange((v: string) => {
                this.tipInput = v;
              })
              .onSubmit(() => {
                this.addTip();
              })
            Text('＋')
              .fontSize(15)
              .fontColor(Color.White)
              .width(38)
              .height(38)
              .textAlign(TextAlign.Center)
              .backgroundColor($r('app.color.primary'))
              .borderRadius(10)
              .onClick(() => {
                this.addTip();
              })
          }
          .width('100%')

          if (!this.isNew) {
            Text('删除这道菜')
              .fontSize(13)
              .fontColor($r('app.color.primary_pressed'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 24, bottom: 8 })
              .onClick(() => {
                this.confirmDelete();
              })
          }

          PrimarySaveButton({ onTap: (): void => {
            this.save();
          } })
          Column().height(40)
        }
        .padding({ left: 16, right: 16, top: 8 })
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_cream'))
  }

  catOptions(): SelectOption[] {
    const out: SelectOption[] = [];
    for (let i = 0; i < this.cats.length; i++) {
      out.push({ value: this.cats[i] });
    }
    return out;
  }

  addStep(): void {
    const s = this.stepInput.trim();
    if (s.length === 0) {
      return;
    }
    this.steps.push(s);
    this.steps = this.steps.slice();
    this.stepInput = '';
  }

  addTip(): void {
    const t = this.tipInput.trim();
    if (t.length === 0) {
      return;
    }
    this.tips.push(t);
    this.tips = this.tips.slice();
    this.tipInput = '';
  }

  confirmDelete(): void {
    const self = this;
    AlertDialog.show({
      title: '删除「' + this.recipe.name + '」？',
      message: '删除后不可恢复',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '留着',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.primary_pressed'),
        action: (): void => {
          Db.deleteRecipe(self.recipe.id).then((): void => {
            self.ad.reloadRecipes();
            promptAction.showToast({ message: '已删除', duration: 1500 });
            router.back();
          });
        }
      }
    });
  }

}

// 字段标签（@Component：@Builder 按值传参不响应动态计数变化）
@Component
struct FieldLabel {
  @Prop t: string = '';

  build() {
    Text(this.t)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .margin({ top: 14, bottom: 6 })
  }
}

@Component
struct PrimarySaveButton {
  onTap: () => void = () => {};

  build() {
    Text('保存这道菜 ✓')
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(Color.White)
      .backgroundColor($r('app.color.primary'))
      .textAlign(TextAlign.Center)
      .height(46)
      .borderRadius(15)
      .width('100%')
      .margin({ top: 16 })
      .shadow({ radius: 14, color: '#52E85D3D', offsetY: 6 })
      .onClick(() => {
        this.onTap();
      })
  }
}
