// 「计划」页：周历 + 明天一键生成 + 换一道/手动补菜 + 跨天移动 + 周计划合并清单/分享
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppData, EVT_ENTRIES } from '../data/AppData';
import { Db } from '../data/Db';
import {
  MealEntry, Recipe, todayStr, addDays, weekdayCn, mealTypeCn, genId
} from '../model/Models';
import { Actions, ListAddResult, PREFER_ALL, PREFER_QUICK, PREFER_LIGHT, PREFER_SPICY, PREFER_FAV } from '../service/Actions';
import { SectionHeader, EmptyState } from '../common/Widgets';

@Component
export struct PlanPage {
  @State selectedDate: string = todayStr();
  @State dayList: MealEntry[] = [];
  @State weekDates: string[] = [];
  @State prefer: string = PREFER_ALL;
  @State dishCount: number = 2;
  @State showPicker: boolean = false;
  @State moveTarget: MealEntry | null = null;
  @State version: number = 0;
  private ad: AppData = AppData.getInstance();
  private listener: ((evt: number) => void) | null = null;
  private prefers: string[] = [PREFER_ALL, PREFER_QUICK, PREFER_LIGHT, PREFER_SPICY, PREFER_FAV];

  aboutToAppear(): void {
    this.buildWeek();
    this.refresh();
    const self = this;
    this.listener = (evt: number): void => {
      if (evt === EVT_ENTRIES) {
        self.refresh();
      }
    };
    this.ad.register(this.listener);
  }

  aboutToDisappear(): void {
    if (this.listener !== null) {
      this.ad.unregister(this.listener);
    }
  }

  buildWeek(): void {
    const today = todayStr();
    // 找本周周一
    const parts = today.split('-');
    const d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
    const dow = d.getDay() === 0 ? 7 : d.getDay();
    const monday = addDays(today, -(dow - 1));
    const out: string[] = [];
    for (let i = 0; i < 7; i++) {
      out.push(addDays(monday, i));
    }
    this.weekDates = out;
  }

  refresh(): void {
    this.dayList = this.ad.entriesOn(this.selectedDate);
  }

  plannedDates(): Set<string> {
    const out: Set<string> = new Set();
    for (let i = 0; i < this.ad.entries.length; i++) {
      if (this.ad.entries[i].status === 'planned') {
        out.add(this.ad.entries[i].date);
      }
    }
    return out;
  }

  // ---------- 跨天移动（对照表 #7 周计划拖拽调换的可靠实现） ----------
  async moveTo(e: MealEntry, targetDate: string): Promise<void> {
    if (targetDate === e.date) {
      this.moveTarget = null;
      return;
    }
    e.date = targetDate;
    e.mealType = 'dinner';
    await Db.updateEntry(e);
    await this.ad.reloadEntries();
    this.moveTarget = null;
    promptAction.showToast({ message: '「' + e.dishName + '」已移到 ' + weekdayCn(targetDate), duration: 1600 });
  }

  // ---------- 本周计划食材合并进清单（对照表 #7 跨天合并清单） ----------
  async mergeWeekToList(): Promise<void> {
    const seen: Set<string> = new Set();
    const recipes: Recipe[] = [];
    let plannedCount = 0;
    for (let i = 0; i < this.weekDates.length; i++) {
      const list = this.ad.entriesOn(this.weekDates[i]);
      for (let k = 0; k < list.length; k++) {
        const e = list[k];
        if (e.status === 'planned' && e.recipeId.length > 0 && !seen.has(e.recipeId)) {
          const r = this.ad.recipeById(e.recipeId);
          if (r !== null) {
            recipes.push(r);
            seen.add(e.recipeId);
          }
        }
        if (e.status === 'planned') {
          plannedCount++;
        }
      }
    }
    if (recipes.length === 0) {
      promptAction.showToast({ message: '本周还没有带菜谱的计划', duration: 1800 });
      return;
    }
    let added = 0;
    const skipped: string[] = [];
    const recent: string[] = [];
    for (let i = 0; i < recipes.length; i++) {
      const res: ListAddResult = await Actions.addIngredientsToList(this.ad, recipes[i]);
      added += res.added;
      for (let k = 0; k < res.skipped.length; k++) {
        if (!skipped.includes(res.skipped[k])) {
          skipped.push(res.skipped[k]);
        }
      }
      for (let k = 0; k < res.recentBought.length; k++) {
        if (!recent.includes(res.recentBought[k])) {
          recent.push(res.recentBought[k]);
        }
      }
    }
    let msg = '已把本周 ' + recipes.length + ' 道菜的食材加进清单（' + plannedCount + ' 个计划，新增 ' + added + ' 项）🛒';
    if (skipped.length > 0) {
      msg += '，冰箱已有：' + skipped.join('、');
    }
    if (recent.length > 0) {
      msg += '，刚买过：' + recent.join('、');
    }
    promptAction.showToast({ message: msg, duration: 3600 });
  }

  // ---------- 分享周计划（文本） ----------
  shareWeek(): void {
    const lines: string[] = ['🍽️ 本周计划'];
    let count = 0;
    for (let i = 0; i < this.weekDates.length; i++) {
      const d = this.weekDates[i];
      const list = this.ad.entriesOn(d);
      if (list.length === 0) {
        continue;
      }
      const names: string[] = [];
      for (let k = 0; k < list.length; k++) {
        names.push(list[k].dishName);
        count++;
      }
      lines.push(weekdayCn(d) + ' ' + d.substring(5).replace('-', '/') + '：' + names.join('、'));
    }
    if (count === 0) {
      promptAction.showToast({ message: '这周还没安排，先生成计划吧', duration: 1800 });
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, lines.join('\n'));
    pasteboard.getSystemPasteboard().setData(data).then((): void => {
      promptAction.showToast({ message: '周计划已复制，粘贴分享给 TA 📋', duration: 2000 });
    }).catch((): void => {
      promptAction.showToast({ message: '复制失败', duration: 1500 });
    });
  }

  async generate(replace: boolean): Promise<void> {
    const tomorrow = addDays(todayStr(), 1);
    const target = this.selectedDate;
    if (target < todayStr()) {
      return;
    }
    const list = this.ad.entriesOn(target);
    let hasPlan = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].status === 'planned') {
        hasPlan = true;
        break;
      }
    }
    if (hasPlan && !replace) {
      // 追加或替换
      AlertDialog.show({
        title: target === tomorrow ? '明天已有安排' : '这天已有安排',
        message: '要替换掉已有的菜，还是追加？',
        autoCancel: true,
        alignment: DialogAlignment.Center,
        primaryButton: {
          value: '追加',
          action: (): void => {
            Actions.generatePlan(this.ad, target, this.prefer, this.dishCount, false);
          }
        },
        secondaryButton: {
          value: '替换',
          fontColor: $r('app.color.primary'),
          action: (): void => {
            Actions.generatePlan(this.ad, target, this.prefer, this.dishCount, true);
          }
        }
      });
      return;
    }
    await Actions.generatePlan(this.ad, target, this.prefer, this.dishCount, replace);
  }

  build() {
    Column() {
      Text('这周计划')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ top: 8 })

      // 周历条
      Row({ space: 6 }) {
        ForEach(this.weekDates, (d: string) => {
          Column() {
            Text(weekdayCn(d))
              .fontSize(9)
              .fontWeight(this.selectedDate === d ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.selectedDate === d ? $r('app.color.primary') : $r('app.color.text_hint'))
            Column() {
              Text(String(Number(d.substring(8))))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.selectedDate === d ? Color.White :
                  (d === todayStr() ? $r('app.color.primary') : $r('app.color.text_primary')))
            }
            .width(32)
            .height(32)
            .borderRadius(16)
            .backgroundColor(this.selectedDate === d ? $r('app.color.primary') : $r('app.color.surface'))
            .justifyContent(FlexAlign.Center)
            .margin({ top: 3 })

            Circle()
              .width(5)
              .height(5)
              .fill($r('app.color.accent'))
              .opacity(this.plannedDates().has(d) && this.selectedDate !== d ? 1 : 0)
              .margin({ top: 2 })
          }
          .layoutWeight(1)
          .onClick(() => {
            this.selectedDate = d;
            this.refresh();
          })
        }, (d: string) => d + (this.plannedDates().has(d) ? '_p' : '') + (this.version > 0 ? 'v' : ''))
      }
      .width('100%')
      .margin({ top: 12 })

      // 选中日的安排
      SectionHeader({
        title: (this.selectedDate === todayStr() ? '今天' :
          (this.selectedDate === addDays(todayStr(), 1) ? '明天' : this.selectedDate.substring(5))) +
          ' · ' + weekdayCn(this.selectedDate),
        more: this.dayList.length + ' 道'
      })

      if (this.dayList.length === 0) {
        Column() {
          EmptyState('🗓️', '这天还没安排', '点下面一键生成，或从菜谱手动挑')
        }
      } else {
        ForEach(this.dayList, (e: MealEntry) => {
          Row({ space: 10 }) {
            Text(e.emoji).fontSize(19)
            Column() {
              Text(e.dishName)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .decoration({ type: e.status === 'eaten' ? TextDecorationType.LineThrough : TextDecorationType.None })
              Text((e.status === 'eaten' ? '吃过 · ' : e.status === 'planned' ? '计划中 · ' : '') +
                e.pickedBy + ' · ' + mealTypeCn(e.mealType) +
                (e.rating > 0 ? ' · ⭐' + e.rating : ''))
                .fontSize(10)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            if (e.status === 'planned') {
              Text('→')
                .fontSize(11)
                .fontColor($r('app.color.green'))
                .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                .borderRadius(999)
                .backgroundColor($r('app.color.green_tint'))
                .onClick(() => {
                  this.moveTarget = e;
                  this.version++;
                })
              Text('换')
                .fontSize(11)
                .fontColor($r('app.color.primary'))
                .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                .borderRadius(999)
                .backgroundColor($r('app.color.primary_tint'))
                .onClick(() => {
                  Actions.regenerateOne(this.ad, e, this.prefer).then((r: MealEntry | null): void => {
                    if (r === null) {
                      promptAction.showToast({ message: '没有可换的菜了，换个偏好试试', duration: 1800 });
                    } else {
                      promptAction.showToast({
                        message: '已换菜，旧菜的食材移出清单；新菜的食材可在详情页加入清单', duration: 2800
                      });
                    }
                  });
                })
              Text('✕')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .padding(6)
                .onClick(() => {
                  this.confirmDelete(e);
                })
            } else {
              Text('✓').fontSize(13).fontColor($r('app.color.green'))
            }
          }
          .width('100%')
          .padding({ left: 12, right: 8, top: 10, bottom: 10 })
          .borderRadius(14)
          .backgroundColor($r('app.color.surface'))
          .margin({ bottom: 7 })
          .shadow({ radius: 8, color: '#1FD6A474', offsetY: 2 })
        }, (e: MealEntry) => e.id + e.status + (this.version > 0 ? 'v' : ''))
      }

      // 手动补一行
      Row() {
        Text('＋ 从菜谱挑一道加上')
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 12 })
          .onClick(() => {
            this.showPicker = true;
          })
          // bindSheet 挂在触发节点上：同一节点链多个 bindSheet 只有最后一个生效，
          // 会顶掉根节点上的移动弹层绑定，故不能都挂 build 根容器（ShoppingPage 分类同理）
          .bindSheet(this.showPicker, this.PickerBuilder(), {
            height: 500,
            showClose: true,
            backgroundColor: $r('app.color.bg_cream'),
            onDisappear: (): void => {
              this.showPicker = false;
            }
          })
      }
      .width('100%')
      .borderRadius(14)
      .backgroundColor($r('app.color.surface_soft'))
      .borderWidth(1.5)
      .borderColor($r('app.color.divider'))
      .borderStyle(BorderStyle.Dashed)

      // 周计划工具：合并清单 / 分享
      Row({ space: 8 }) {
        Text('🛒 本周食材并入清单')
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.surface'))
          .padding({ left: 14, right: 14, top: 9, bottom: 9 })
          .borderRadius(999)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.mergeWeekToList();
          })
        Text('📋 分享周计划')
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.surface'))
          .padding({ left: 14, right: 14, top: 9, bottom: 9 })
          .borderRadius(999)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.shareWeek();
          })
      }
      .width('100%')
      .margin({ top: 12 })

      // 生成器
      SectionHeader({ title: '帮我生成', more: this.selectedDate < todayStr() ? '已过去的日子' : '' })
      Row({ space: 6 }) {
        Scroll() {
          Row({ space: 7 }) {
            ForEach(this.prefers, (p: string) => {
              Text(p)
                .fontSize(11)
                .fontColor(this.prefer === p ? $r('app.color.green') : $r('app.color.text_secondary'))
                .backgroundColor(this.prefer === p ? $r('app.color.green_tint') : $r('app.color.surface'))
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(999)
                .onClick(() => {
                  this.prefer = p;
                })
            }, (p: string) => p)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        Row({ space: 6 }) {
          Text('−')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
            .width(26)
            .height(26)
            .textAlign(TextAlign.Center)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(13)
            .onClick(() => {
              if (this.dishCount > 1) {
                this.dishCount--;
              }
            })
          Text(this.dishCount + '道')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text('＋')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width(26)
            .height(26)
            .textAlign(TextAlign.Center)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(13)
            .onClick(() => {
              if (this.dishCount < 5) {
                this.dishCount++;
              }
            })
        }
      }
      .width('100%')

      Button('✨ 一键生成' + (this.selectedDate === addDays(todayStr(), 1) ? '明天' : this.selectedDate.substring(5)) + '菜单')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor(this.selectedDate < todayStr() ? $r('app.color.strike') : $r('app.color.primary'))
        .width('100%')
        .height(44)
        .borderRadius(15)
        .margin({ top: 12 })
        .shadow({ radius: 14, color: '#52E85D3D', offsetY: 6 })
        .onClick(() => {
          this.generate(false);
        })

      Column().height(30)
    }
    .padding({ left: 16, right: 16 })
    .width('100%')
    .height('100%')
    .bindSheet(this.moveTarget !== null, this.MoveBuilder(), {
      height: 330,
      showClose: true,
      backgroundColor: $r('app.color.bg_cream'),
      onDisappear: (): void => {
        this.moveTarget = null;
      }
    })
  }

  // 移动到某天的弹层
  @Builder
  MoveBuilder() {
    Column() {
      Text('把「' + (this.moveTarget === null ? '' : this.moveTarget.dishName) + '」移到哪天？')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 14 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
        ForEach(this.weekDates, (d: string) => {
          Column() {
            Text(weekdayCn(d))
              .fontSize(11)
              .fontColor(this.moveTarget !== null && this.moveTarget.date === d ?
              Color.White : $r('app.color.text_secondary'))
            Text(d.substring(5).replace('-', '/'))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.moveTarget !== null && this.moveTarget.date === d ?
              Color.White : $r('app.color.text_primary'))
              .margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.Center)
          .width(76)
          .padding({ top: 12, bottom: 12 })
          .borderRadius(14)
          .backgroundColor(this.moveTarget !== null && this.moveTarget.date === d ?
          $r('app.color.primary') : $r('app.color.surface'))
          .margin(6)
          .onClick(() => {
            if (this.moveTarget !== null) {
              this.moveTo(this.moveTarget, d);
            }
          })
        }, (d: string) => d + (this.moveTarget !== null ? this.moveTarget.date : ''))
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
  }

  @Builder
  PickerBuilder() {
    Column() {
      Text('挑一道加上')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 10 })
      List({ space: 6 }) {
        ForEach(this.pickable(), (r: Recipe) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(r.emoji).fontSize(19)
              Text(r.name)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              Text(r.taste + ' · ' + r.durationMin + 'min')
                .fontSize(10)
                .fontColor($r('app.color.text_hint'))
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 11, bottom: 11 })
            .borderRadius(12)
            .backgroundColor($r('app.color.surface'))
            .onClick(() => {
              const r2: Recipe = r;
              this.addDirect(r2);
            })
          }
        }, (r: Recipe) => r.id)
      }
      .width('100%')
      .layoutWeight(1)
      .margin({ top: 10 })
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
  }

  confirmDelete(e: MealEntry): void {
    AlertDialog.show({
      title: '不做了？',
      message: '「' + e.dishName + '」将从这天计划移除，未采购的食材也会移出清单。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '留着',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删（含食材）',
        fontColor: $r('app.color.primary'),
        action: (): void => {
          Actions.deleteEntry(this.ad, e, true);
        }
      }
    });
  }

  pickable(): Recipe[] {
    const out: Recipe[] = [];
    for (let i = 0; i < this.ad.recipes.length; i++) {
      const r = this.ad.recipes[i];
      if (r.enabled) {
        out.push(r);
      }
    }
    return out;
  }

  async addDirect(r: Recipe): Promise<void> {
    const e = new MealEntry();
    e.id = genId('me');
    e.date = this.selectedDate;
    e.mealType = this.selectedDate === todayStr() && new Date().getHours() < 15 ? 'lunch' : 'dinner';
    e.recipeId = r.id;
    e.dishName = r.name;
    e.emoji = r.emoji;
    e.pickedBy = this.ad.settings.currentMember;
    e.status = 'planned';
    e.source = 'manual';
    e.createdAt = Date.now();
    await Db.insertEntry(e);
    await this.ad.reloadEntries();
    this.showPicker = false;
    promptAction.showToast({ message: '已加上：' + r.name, duration: 1500 });
    // 与今日页「就吃它」同一交互：问一句食材要不要进买菜清单
    setTimeout((): void => {
      this.offerIngredientAdd(r);
    }, 900);
  }

  // 加计划后顺带问一句：食材要不要进买菜清单（冰箱已有的自动跳过）
  offerIngredientAdd(r: Recipe): void {
    const self = this;
    AlertDialog.show({
      title: '食材也加进买菜清单？',
      message: '「' + r.name + '」的食材将按分类合并（同名未勾项不重复，冰箱已有的自动跳过）',
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
          Actions.addIngredientsToList(self.ad, r).then((res: ListAddResult): void => {
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
}
