// 菜品详情 + 烹饪模式（含食材替换建议、做菜历史）
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { AppData } from '../data/AppData';
import { Actions, ListAddResult } from '../service/Actions';
import { RecommendService } from '../service/RecommendService';
import { AiService } from '../service/AiService';
import { Db } from '../data/Db';
import { Recipe, Ingredient, MealEntry, copyRecipe, genId, todayStr, addDays, weekdayCn, mealTypeCn } from '../model/Models';
import { Chip } from '../common/Widgets';

// 加入计划：今天/明天 × 午/晚餐 四选一
@CustomDialog
struct PlanPickDialog {
  controller: CustomDialogController;
  onPick: (date: string, mealType: string) => void = () => {};

  build() {
    Column({ space: 12 }) {
      Text('加入哪天的计划？')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Row({ space: 10 }) {
        Button('今天 · 午餐')
          .fontSize(14).fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.primary_tint'))
          .layoutWeight(1).height(44).borderRadius(14)
          .onClick(() => {
            this.onPick(todayStr(), 'lunch');
            this.controller.close();
          })
        Button('今天 · 晚餐')
          .fontSize(14).fontColor(Color.White)
          .backgroundColor($r('app.color.primary'))
          .layoutWeight(1).height(44).borderRadius(14)
          .onClick(() => {
            this.onPick(todayStr(), 'dinner');
            this.controller.close();
          })
      }
      .width('100%')
      Row({ space: 10 }) {
        Button('明天 · 午餐')
          .fontSize(14).fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.primary_tint'))
          .layoutWeight(1).height(44).borderRadius(14)
          .onClick(() => {
            this.onPick(addDays(todayStr(), 1), 'lunch');
            this.controller.close();
          })
        Button('明天 · 晚餐')
          .fontSize(14).fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.primary_tint'))
          .layoutWeight(1).height(44).borderRadius(14)
          .onClick(() => {
            this.onPick(addDays(todayStr(), 1), 'dinner');
            this.controller.close();
          })
      }
      .width('100%')
      Text('取消')
        .fontSize(13)
        .fontColor($r('app.color.text_hint'))
        .padding({ top: 4, bottom: 4, left: 20, right: 20 })
        .onClick(() => {
          this.controller.close();
        })
    }
    .padding(20)
  }
}

@Entry
@Component
struct RecipeDetailPage {
  @State recipe: Recipe = new Recipe();
  @State cooking: boolean = false;
  @State stepIdx: number = 0;
  @State timerRunning: boolean = false;
  @State timerRemain: number = 0;
  @State timerLabel: string = '';
  // 缺食材替换
  @State showSub: boolean = false;
  @State subInput: string = '';
  @State subResults: string[] = [];
  @State subNote: string = '';
  @State subBusy: boolean = false;
  @State version: number = 0;
  private ad: AppData = AppData.getInstance();
  private timerId: number = -1;
  planDialog: CustomDialogController = new CustomDialogController({
    builder: PlanPickDialog({
      onPick: (date: string, mealType: string): void => {
        this.addToPlan(date, mealType);
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  // 从菜谱详情直接加入计划（status=planned，同步后服务端会推送给对方）
  async addToPlan(date: string, mealType: string): Promise<void> {
    const e = new MealEntry();
    e.id = genId('me');
    e.date = date;
    e.mealType = mealType;
    e.recipeId = this.recipe.id;
    e.dishName = this.recipe.name;
    e.emoji = this.recipe.emoji;
    e.pickedBy = this.ad.settings.currentMember;
    e.status = 'planned';
    e.source = 'recipe_detail';
    e.createdAt = Date.now();
    await Db.insertEntry(e);
    await this.ad.reloadEntries();
    promptAction.showToast({
      message: '已加入计划：' + weekdayCn(date) + ' · ' + mealTypeCn(mealType) + ' ✅',
      duration: 1800
    });
    // 与今日页「就吃它」同一交互：问一句食材要不要进买菜清单
    setTimeout((): void => {
      this.offerIngredientAdd();
    }, 900);
  }

  // 加计划后顺带问一句：食材要不要进买菜清单（冰箱已有的自动跳过）
  offerIngredientAdd(): void {
    const self = this;
    AlertDialog.show({
      title: '食材也加进买菜清单？',
      message: '「' + this.recipe.name + '」的食材将按分类合并（同名未勾项不重复，冰箱已有的自动跳过）',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '先不用',
        action: (): void => {}
      },
      secondaryButton: {
        value: '加入清单',
        fontColor: $r('app.color.primary'),
        action: (): void => {
          Actions.addIngredientsToList(self.ad, self.recipe).then((res: ListAddResult): void => {
            let msg = res.added > 0 ? '已加入 ' + res.added + ' 项食材 🛒' : '清单无需新增';
            if (res.skipped.length > 0) {
              msg += '（冰箱已有：' + res.skipped.join('、') + '）';
            }
            if (res.recentBought.length > 0) {
              msg += '（刚买过：' + res.recentBought.join('、') + '）';
            }
            promptAction.showToast({ message: msg, duration: 2800 });
          });
        }
      }
    });
  }

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string>;
    const id = params === undefined ? '' : params.id;
    const r = this.ad.recipeById(id === undefined ? '' : id);
    if (r !== null) {
      // 拷贝一份避免直接改缓存对象
      this.recipe = copyRecipe(r);
    }
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  saveBack(): void {
    const r = this.ad.recipeById(this.recipe.id);
    if (r !== null) {
      r.favorite = this.recipe.favorite;
      r.dislike = this.recipe.dislike;
      r.name = this.recipe.name;
      r.emoji = this.recipe.emoji;
      Actions.saveRecipe(this.ad, r, false);
    }
  }

  parseStepMinutes(text: string): number {
    const m = text.match(/(\d+)\s*[-～~]?\s*\d*\s*分钟/);
    if (m !== null) {
      return Number(m[1]);
    }
    return 0;
  }

  startTimer(min: number, label: string): void {
    this.stopTimer();
    this.timerRemain = Math.max(min * 60, 10);
    this.timerLabel = label;
    this.timerRunning = true;
    this.timerId = setInterval((): void => {
      this.timerRemain--;
      if (this.timerRemain <= 0) {
        this.stopTimer();
        promptAction.showToast({ message: '⏰ 时间到！' + label, duration: 3000 });
      }
    }, 1000);
  }

  stopTimer(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.timerRunning = false;
    this.timerRemain = 0;
  }

  fmtRemain(): string {
    const m = Math.floor(this.timerRemain / 60);
    const s = this.timerRemain % 60;
    return (m < 10 ? '0' + m : '' + m) + ':' + (s < 10 ? '0' + s : '' + s);
  }

  // ---------- 缺食材替换建议（本地词典 → LLM 增强） ----------
  async lookupSubstitute(): Promise<void> {
    const ing = this.subInput.trim();
    if (ing.length === 0 || this.subBusy) {
      return;
    }
    this.subBusy = true;
    this.subResults = [];
    this.subNote = '';
    // 本地词典秒回，作为保底
    const local = RecommendService.substituteLocal(ing);
    if (local.length > 0) {
      this.subResults = local;
      this.subNote = '常见替代';
    }
    // LLM 增强（白名单含 substitute 才调用，失败静默保留本地结果）
    if (AiService.can('substitute')) {
      try {
        const ai = await AiService.substitute(ing, this.recipe.name);
        if (ai !== null && ai.length > 0) {
          this.subResults = ai;
          this.subNote = 'AI 建议';
        }
      } catch (e) {
        // 忽略，用本地结果
      }
    }
    if (this.subResults.length === 0) {
      this.subNote = '没找到现成替代，可以用相近食材试试';
    }
    this.subBusy = false;
    this.version++;
  }

  // 这道菜的历史吃饭记录（新→旧）
  dishHistory(): MealEntry[] {
    const out: MealEntry[] = [];
    for (let i = 0; i < this.ad.entries.length; i++) {
      const e = this.ad.entries[i];
      if (e.status === 'eaten' &&
        (e.recipeId === this.recipe.id || e.dishName === this.recipe.name)) {
        out.push(e);
      }
    }
    out.sort((a: MealEntry, b: MealEntry): number => b.createdAt - a.createdAt);
    return out;
  }

  build() {
    Stack() {
      Column() {
        if (!this.cooking) {
          this.DetailView()
        } else {
          this.CookingView()
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.cooking ? '#2E2119' : $r('app.color.bg_cream'))
  }

  @Builder
  DetailView() {
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
        Blank()
        Text(this.recipe.dislike ? '🙂' : '🙅')
          .fontSize(18)
          .padding(8)
          .onClick(() => {
            this.recipe.dislike = !this.recipe.dislike;
            this.saveBack();
            promptAction.showToast({
              message: this.recipe.dislike ? '已标记不爱吃，推荐会避开' : '已取消不爱吃标记',
              duration: 1500
            });
          })
        Text(this.recipe.favorite ? '❤️' : '🤍')
          .fontSize(18)
          .padding(8)
          .onClick(() => {
            this.recipe.favorite = !this.recipe.favorite;
            this.saveBack();
          })
        Text('✏️')
          .fontSize(17)
          .padding({ left: 4, right: 16, top: 8, bottom: 8 })
          .onClick(() => {
            router.pushUrl({ url: 'pages/RecipeEditPage', params: { id: this.recipe.id } });
          })
      }
      .width('100%')

      Scroll() {
        Column() {
          Text(this.recipe.emoji)
            .fontSize(56)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 8 })
          Text(this.recipe.name)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 6 })
          Row({ space: 6 }) {
            Chip(this.recipe.taste, 'gray')
            Chip(this.recipe.cuisine, 'gray')
            Chip(this.recipe.category, 'gray')
            if (this.recipe.durationMin > 0) {
              Chip(this.recipe.durationMin + '分钟', 'gray')
            }
            if (this.recipe.difficulty > 0) {
              Chip('难度★' + this.recipe.difficulty, 'gray')
            }
            if (this.recipe.calories > 0) {
              Chip(this.recipe.calories + '大卡', 'gray')
            }
            if (this.recipe.protein > 0 || this.recipe.fat > 0 || this.recipe.carbs > 0) {
              Chip('蛋白' + this.recipe.protein + 'g · 脂肪' + this.recipe.fat + 'g · 碳水' + this.recipe.carbs + 'g', 'gray')
            }
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 8 })

          if (this.recipe.source.length > 0) {
            Text('来源：' + this.recipe.source)
              .fontSize(9)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 6 })
          }

          // 食材
          Row() {
            Text('🧺 食材')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Text(this.showSub ? '收起' : '缺食材？')
              .fontSize(11)
              .fontColor($r('app.color.primary'))
              .onClick(() => {
                this.showSub = !this.showSub;
                this.subResults = [];
                this.subNote = '';
                this.subInput = '';
              })
          }
          .width('100%')
          .margin({ top: 18, bottom: 8 })

          // 缺食材替换面板
          if (this.showSub) {
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                TextInput({ placeholder: '缺了什么？如：料酒', text: this.subInput })
                  .fontSize(12)
                  .height(36)
                  .layoutWeight(1)
                  .backgroundColor($r('app.color.surface'))
                  .borderRadius(10)
                  .onChange((v: string) => {
                    this.subInput = v;
                  })
                  .onSubmit(() => {
                    this.lookupSubstitute();
                  })
                Text(this.subBusy ? '查一查…' : '查一查')
                  .fontSize(12)
                  .fontColor(Color.White)
                  .backgroundColor(this.subBusy ? $r('app.color.strike') : $r('app.color.primary'))
                  .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                  .borderRadius(999)
                  .onClick(() => {
                    this.lookupSubstitute();
                  })
              }
              .width('100%')
              if (this.subResults.length > 0) {
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.subResults, (s: string) => {
                    Text('可以换成：' + s)
                      .fontSize(11)
                      .fontColor($r('app.color.green'))
                      .backgroundColor($r('app.color.green_tint'))
                      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                      .borderRadius(999)
                      .margin(4)
                  }, (s: string) => s + this.version)
                }
                .width('100%')
                if (this.subNote.length > 0) {
                  Text(this.subNote)
                    .fontSize(9)
                    .fontColor($r('app.color.text_hint'))
                    .width('100%')
                }
              } else if (this.subNote.length > 0) {
                Text(this.subNote)
                  .fontSize(11)
                  .fontColor($r('app.color.text_hint'))
                  .width('100%')
              }
            }
            .width('100%')
            .padding(12)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface_soft'))
            .borderWidth(1)
            .borderColor($r('app.color.divider'))
            .margin({ bottom: 10 })
          }

          ForEach(this.recipe.ingredients, (ing: Ingredient) => {
            Row() {
              Text(ing.name)
                .fontSize(13)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              Text(ing.amount)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
              Text(ing.category)
                .fontSize(9)
                .fontColor($r('app.color.text_hint'))
                .backgroundColor($r('app.color.chip_bg'))
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                .borderRadius(999)
                .margin({ left: 8 })
            }
            .width('100%')
            .padding({ top: 7, bottom: 7 })
            .borderWidth({ bottom: 0.5 })
            .borderColor($r('app.color.divider'))
          }, (ing: Ingredient) => ing.name + ing.amount)

          // 步骤
          Text('👨‍🍳 做法')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .margin({ top: 18, bottom: 8 })
          ForEach(this.recipe.steps, (s: string, i: number) => {
            Row({ space: 10 }) {
              Text((i + 1) + '')
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
                .width(22)
                .height(22)
                .textAlign(TextAlign.Center)
                .borderRadius(11)
                .backgroundColor($r('app.color.primary'))
              Text(s)
                .fontSize(13)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              if (this.parseStepMinutes(s) > 0) {
                Text('⏱ ' + this.parseStepMinutes(s) + '′')
                  .fontSize(11)
                  .fontColor($r('app.color.primary'))
                  .backgroundColor($r('app.color.primary_tint'))
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .borderRadius(999)
                  .onClick(() => {
                    this.startTimer(this.parseStepMinutes(s), '步骤' + (i + 1));
                  })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ top: 8, bottom: 8 })
          }, (s: string, i: number) => 'step' + i)

          // 贴士
          if (this.recipe.tips.length > 0) {
            Text('💡 小贴士')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .margin({ top: 16, bottom: 8 })
            ForEach(this.recipe.tips, (t: string) => {
              Text('· ' + t)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .margin({ bottom: 5 })
            }, (t: string) => t)
          }

          // 做菜历史（同菜不同次对比）
          if (this.dishHistory().length > 0) {
            Text('📜 做菜历史（' + this.dishHistory().length + ' 次）')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .margin({ top: 16, bottom: 8 })
            ForEach(this.dishHistory(), (e: MealEntry) => {
              Row({ space: 10 }) {
                Column() {
                  Text(e.date.substring(5).replace('-', '/') + (e.pickedBy.length > 0 ? ' · ' + e.pickedBy : ''))
                    .fontSize(11)
                    .fontColor($r('app.color.text_hint'))
                  if (e.note.length > 0) {
                    Text('“' + e.note + '”')
                      .fontSize(11)
                      .fontColor($r('app.color.text_secondary'))
                      .margin({ top: 2 })
                      .maxLines(2)
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (e.rating > 0) {
                  Text('⭐'.repeat(e.rating))
                    .fontSize(11)
                }
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 9, bottom: 9 })
              .borderRadius(12)
              .backgroundColor($r('app.color.surface'))
              .margin({ bottom: 6 })
            }, (e: MealEntry) => e.id)
          }

          Row({ space: 10 }) {
            Button('📅 加入计划')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .backgroundColor($r('app.color.primary'))
              .layoutWeight(1)
              .height(44)
              .borderRadius(15)
              .id('detail_add_plan')
              .onClick(() => {
                this.planDialog.open();
              })
            Button('🛒 食材入清单')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.primary'))
              .backgroundColor($r('app.color.surface'))
              .borderWidth(1.5)
              .borderColor($r('app.color.primary_border'))
              .layoutWeight(1)
              .height(44)
              .borderRadius(15)
              .id('detail_add_list')
              .onClick(() => {
              AlertDialog.show({
                title: '食材加入买菜清单？',
                message: '「' + this.recipe.name + '」的食材将按分类合并（调味料可按设置默认标记家里已有）',
                autoCancel: true,
                alignment: DialogAlignment.Center,
                primaryButton: {
                  value: '取消',
                  action: (): void => {}
                },
                secondaryButton: {
                  value: '加入',
                  fontColor: $r('app.color.primary'),
                  action: (): void => {
                    Actions.addIngredientsToList(this.ad, this.recipe).then((res: ListAddResult): void => {
                      let msg = res.added > 0 ? '已加入 ' + res.added + ' 项 🛒' : '清单无需新增';
                      if (res.skipped.length > 0) {
                        msg += '（冰箱已有：' + res.skipped.join('、') + '）';
                      }
                      if (res.recentBought.length > 0) {
                        msg += '（刚买过：' + res.recentBought.join('、') + '）';
                      }
                      promptAction.showToast({ message: msg, duration: 2800 });
                    });
                  }
                }
              });
              })
          }
          .width('100%')
          .margin({ top: 10 })

          Button('🍳 开始烹饪模式')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.primary'))
            .width('100%')
            .height(46)
            .borderRadius(15)
            .margin({ top: 20 })
            .shadow({ radius: 14, color: '#52E85D3D', offsetY: 6 })
            .onClick(() => {
              this.stepIdx = 0;
              this.cooking = true;
            })
          Column().height(30)
        }
        .padding({ left: 16, right: 16 })
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
      .width('100%')

      // 计时悬浮条
      if (this.timerRunning) {
        Row({ space: 10 }) {
          Text('⏱ ' + this.timerLabel)
            .fontSize(12)
            .fontColor(Color.White)
          Text(this.fmtRemain())
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.accent'))
          Blank()
          Text('取消')
            .fontSize(12)
            .fontColor(Color.White)
            .onClick(() => {
              this.stopTimer();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor('#E62E2119')
        .borderRadius(16)
      }
    }
  }

  @Builder
  CookingView() {
    Column() {
      Row() {
        Text('✕')
          .fontSize(18)
          .fontColor('#F5EAE0')
          .padding(14)
          .onClick(() => {
            this.stopTimer();
            this.cooking = false;
          })
        Blank()
        Text(this.recipe.emoji + ' ' + this.recipe.name)
          .fontSize(14)
          .fontColor('#F5EAE0')
          .padding(14)
      }
      .width('100%')

      Blank()

      Text('第 ' + (this.stepIdx + 1) + ' / ' + this.recipe.steps.length + ' 步')
        .fontSize(12)
        .fontColor('#B8A79A')
      Text(this.recipe.steps[this.stepIdx])
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .textAlign(TextAlign.Center)
        .lineHeight(36)
        .padding({ left: 28, right: 28, top: 16 })

      if (this.timerRunning) {
        Text('⏱ ' + this.fmtRemain())
          .fontSize(44)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent'))
          .margin({ top: 24 })
        Text(this.timerLabel + '计时中')
          .fontSize(12)
          .fontColor('#B8A79A')
          .margin({ top: 4 })
      } else {
        if (this.parseStepMinutes(this.recipe.steps[this.stepIdx]) > 0) {
          Button('⏱ 计时 ' + this.parseStepMinutes(this.recipe.steps[this.stepIdx]) + ' 分钟')
            .fontSize(14)
            .fontColor('#2E2119')
            .backgroundColor($r('app.color.accent'))
            .height(40)
            .borderRadius(999)
            .margin({ top: 24 })
            .onClick(() => {
              this.startTimer(this.parseStepMinutes(this.recipe.steps[this.stepIdx]), '步骤' + (this.stepIdx + 1));
            })
        }
      }

      Blank()

      Row({ space: 12 }) {
        Button('上一步')
          .fontSize(14)
          .fontColor('#F5EAE0')
          .backgroundColor('#4A382E')
          .layoutWeight(1)
          .height(46)
          .borderRadius(15)
          .opacity(this.stepIdx === 0 ? 0.4 : 1)
          .onClick(() => {
            if (this.stepIdx > 0) {
              this.stepIdx--;
            }
          })
        Button(this.stepIdx === this.recipe.steps.length - 1 ? '开吃 🎉' : '下一步')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.primary'))
          .layoutWeight(1)
          .height(46)
          .borderRadius(15)
          .onClick(() => {
            if (this.stepIdx < this.recipe.steps.length - 1) {
              this.stepIdx++;
            } else {
              this.stopTimer();
              this.cooking = false;
              promptAction.showToast({ message: '开吃！记得回来打分 ⭐', duration: 2000 });
            }
          })
      }
      .padding({ left: 20, right: 20, bottom: 30 })
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }
}
