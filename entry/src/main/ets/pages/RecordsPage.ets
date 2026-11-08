// 「记录」页：统计 + 时间线/日历/日记/照片墙/成就墙 五视图
// 新增（对照表）：历史统计报表（改进#4）、日历视图、做菜日记（点子#12）、
// 每周料理挑战（点子#8）、厨艺进阶挑战（点子#5）
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { AppData, EVT_ENTRIES, EVT_ACH } from '../data/AppData';
import { Db } from '../data/Db';
import { Actions } from '../service/Actions';
import { AchievementEngine, AchievementDef } from '../service/AchievementEngine';
import { RecommendService } from '../service/RecommendService';
import {
  MealEntry, AchStats, Recipe, todayStr, addDays, weekdayCn
} from '../model/Models';
import { fileUri } from '@kit.CoreFileKit';
import { SectionHeader, EmptyState, Stars } from '../common/Widgets';

// 端侧统计报表（改进#4 / 点子#2 的端侧数字部分）
export class StatsReport {
  monthEaten: number = 0;
  monthActiveDays: number = 0;
  monthNewDishes: number = 0;   // 本月第一次做的菜
  monthAvgRating: number = 0;
  meatCount: number = 0;
  vegCount: number = 0;
  soupCount: number = 0;
  stapleCount: number = 0;
  otherCount: number = 0;
  tasteTop: string[] = [];      // 口味名按次数降序
  tasteCounts: number[] = [];
  weekCounts: number[] = [];    // 最近 6 周每周吃饭次数
  weekLabels: string[] = [];    // 周起始 MM/DD
  repeatRate: number = 0;       // 本月重复率（重复做的占比）
}

@Component
struct StatCard {
  @Prop v: string = '';
  @Prop k: string = '';

  build() {
    Column() {
      Text(this.v)
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary'))
      Text(this.k)
        .fontSize(9.5)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .padding({ top: 11, bottom: 9 })
    .borderRadius(15)
    .backgroundColor($r('app.color.surface'))
    .shadow({ radius: 10, color: '#21D6A474', offsetY: 3 })
  }
}
@Component
struct RCard {
  @Prop v: string = '';
  @Prop k: string = '';

  build() {
    Column() {
      Text(this.v)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary'))
      Text(this.k)
        .fontSize(9)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .padding({ top: 10, bottom: 8 })
    .borderRadius(12)
    .backgroundColor($r('app.color.surface'))
  }
}
@Component
struct BarRow {
  @Prop label: string = '';
  @Prop count: number = 0;
  @Prop total: number = 1;
  @Prop barColor: ResourceColor = '#888888';

  build() {
    Row({ space: 8 }) {
      Text(this.label)
        .fontSize(10)
        .fontColor($r('app.color.text_secondary'))
        .width(52)
      Progress({
        value: this.count,
        total: Math.max(this.total, 1),
        type: ProgressType.Linear
      })
        .color(this.barColor)
        .style({ strokeWidth: 6 })
        .layoutWeight(1)
      Text('' + this.count)
        .fontSize(10)
        .fontColor($r('app.color.text_primary'))
        .width(20)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .margin({ top: 7 })
  }
}

@Component
export struct RecordsPage {
  @State view: string = '时间线';
  @State stats: AchStats = new AchStats();
  @State report: StatsReport = new StatsReport();
  @State version: number = 0;
  // 日历视图
  @State calMonth: string = todayStr().substring(0, 7); // yyyy-MM
  @State calSelected: string = '';
  private ad: AppData = AppData.getInstance();
  private listener: ((evt: number) => void) | null = null;
  private views: string[] = ['时间线', '日历', '日记', '统计', '照片墙', '成就墙'];

  aboutToAppear(): void {
    this.recompute();
    const self = this;
    this.listener = (evt: number): void => {
      if (evt === EVT_ENTRIES || evt === EVT_ACH) {
        self.recompute();
      }
    };
    this.ad.register(this.listener);
  }

  aboutToDisappear(): void {
    if (this.listener !== null) {
      this.ad.unregister(this.listener);
    }
  }

  recompute(): void {
    this.stats = AchievementEngine.computeStats(this.ad);
    this.report = this.buildReport();
    this.version++;
  }

  eatenEntries(): MealEntry[] {
    const out: MealEntry[] = [];
    for (let i = 0; i < this.ad.entries.length; i++) {
      if (this.ad.entries[i].status === 'eaten') {
        out.push(this.ad.entries[i]);
      }
    }
    out.sort((a: MealEntry, b: MealEntry): number => b.createdAt - a.createdAt);
    return out;
  }

  photoEntries(): MealEntry[] {
    const out: MealEntry[] = [];
    for (let i = 0; i < this.ad.entries.length; i++) {
      const e = this.ad.entries[i];
      if (e.status === 'eaten' && e.photoPath.length > 0) {
        out.push(e);
      }
    }
    out.sort((a: MealEntry, b: MealEntry): number => b.createdAt - a.createdAt);
    return out;
  }

  diaryEntries(): MealEntry[] {
    const out: MealEntry[] = [];
    for (let i = 0; i < this.ad.entries.length; i++) {
      const e = this.ad.entries[i];
      if (e.status === 'eaten' && (e.note.length > 0 || e.photoPath.length > 0)) {
        out.push(e);
      }
    }
    out.sort((a: MealEntry, b: MealEntry): number => b.createdAt - a.createdAt);
    return out;
  }

  // 端侧统计报表
  private buildReport(): StatsReport {
    const rep = new StatsReport();
    const monthPrefix = todayStr().substring(0, 7);
    // 先算每道菜的首次吃过日期（判断"本月新菜"用）
    const firstEaten: Map<string, string> = new Map();
    for (let i = 0; i < this.ad.entries.length; i++) {
      const e = this.ad.entries[i];
      if (e.status !== 'eaten') {
        continue;
      }
      const known = firstEaten.get(e.dishName);
      if (known === undefined || e.date < known) {
        firstEaten.set(e.dishName, e.date);
      }
    }
    const seen: Set<string> = new Set();
    const monthDates: Set<string> = new Set();
    const tasteCount: Map<string, number> = new Map();
    let ratingSum = 0;
    let ratingN = 0;
    let monthTotal = 0;
    // 最近 6 周
    const today = todayStr();
    const parts = today.split('-');
    const d0 = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
    const dow = d0.getDay() === 0 ? 7 : d0.getDay();
    const monday = addDays(today, -(dow - 1));
    for (let w = 5; w >= 0; w--) {
      const ws = addDays(monday, -7 * w);
      const we = addDays(ws, 6);
      let c = 0;
      for (let i = 0; i < this.ad.entries.length; i++) {
        const e = this.ad.entries[i];
        if (e.status === 'eaten' && e.date >= ws && e.date <= we) {
          c++;
        }
      }
      rep.weekCounts.push(c);
      rep.weekLabels.push(ws.substring(5).replace('-', '/'));
    }
    for (let i = 0; i < this.ad.entries.length; i++) {
      const e = this.ad.entries[i];
      if (e.status !== 'eaten') {
        continue;
      }
      if (e.date.substring(0, 7) !== monthPrefix) {
        continue;
      }
      monthTotal++;
      monthDates.add(e.date);
      rep.monthEaten++;
      if (e.rating > 0) {
        ratingSum += e.rating;
        ratingN++;
      }
      const r: Recipe | null = e.recipeId.length > 0 ? this.ad.recipeById(e.recipeId) : null;
      if (r !== null) {
        if (r.type === '荤' || r.category === '荤菜' || r.category === '水产') {
          rep.meatCount++;
        } else if (r.type === '素') {
          rep.vegCount++;
        } else if (r.type === '汤') {
          rep.soupCount++;
        } else if (r.type === '主食') {
          rep.stapleCount++;
        } else {
          rep.otherCount++;
        }
        const c = tasteCount.get(r.taste);
        tasteCount.set(r.taste, (c === undefined ? 0 : c) + 1);
        if (!seen.has(r.name)) {
          seen.add(r.name);
          const fe = firstEaten.get(r.name);
          if (fe !== undefined && fe.substring(0, 7) === monthPrefix) {
            rep.monthNewDishes++;
          }
        }
      }
    }
    rep.monthActiveDays = monthDates.size;
    rep.monthAvgRating = ratingN === 0 ? 0 : Math.round(ratingSum / ratingN * 10) / 10;
    rep.repeatRate = monthTotal === 0 ? 0 : Math.round((monthTotal - seen.size) / monthTotal * 100);
    // 口味 Top5
    const entries: string[] = Array.from(tasteCount.keys());
    entries.sort((a: string, b: string): number => {
      const ca = tasteCount.get(a) === undefined ? 0 : tasteCount.get(a) as number;
      const cb = tasteCount.get(b) === undefined ? 0 : tasteCount.get(b) as number;
      return cb - ca;
    });
    for (let i = 0; i < entries.length && i < 5; i++) {
      rep.tasteTop.push(entries[i]);
      rep.tasteCounts.push(tasteCount.get(entries[i]) as number);
    }
    return rep;
  }

  // ---------- 日历 ----------
  calFirstDay(): string {
    return this.calMonth + '-01';
  }

  calDays(): string[] {
    // 该月天数
    const y = Number(this.calMonth.substring(0, 4));
    const m = Number(this.calMonth.substring(5, 7));
    const days = new Date(y, m, 0).getDate();
    const out: string[] = [];
    for (let i = 1; i <= days; i++) {
      out.push(this.calMonth + '-' + (i < 10 ? '0' + i : '' + i));
    }
    return out;
  }

  calLeadingBlanks(): number[] {
    const first = this.calFirstDay();
    const parts = first.split('-');
    const d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
    const dow = d.getDay() === 0 ? 7 : d.getDay();
    const out: number[] = [];
    for (let i = 1; i < dow; i++) {
      out.push(i);
    }
    return out;
  }

  eatenOn(date: string): MealEntry[] {
    const out: MealEntry[] = [];
    for (let i = 0; i < this.ad.entries.length; i++) {
      const e = this.ad.entries[i];
      if (e.status === 'eaten' && e.date === date) {
        out.push(e);
      }
    }
    return out;
  }

  shiftMonth(delta: number): void {
    let y = Number(this.calMonth.substring(0, 4));
    let m = Number(this.calMonth.substring(5, 7)) + delta;
    if (m <= 0) {
      m = 12;
      y--;
    } else if (m > 12) {
      m = 1;
      y++;
    }
    this.calMonth = y + '-' + (m < 10 ? '0' + m : '' + m);
    this.calSelected = '';
  }

  // ---------- 挑战 ----------
  challenge(): Recipe | null {
    return RecommendService.weeklyChallenge(this.ad);
  }

  challengeDays(recipe: Recipe): number {
    const days = RecommendService.lastEatenDays(this.ad, recipe.name);
    return days >= 9999 ? -1 : days;
  }

  reportTotal(): number {
    return Math.max(this.report.meatCount + this.report.vegCount + this.report.soupCount +
      this.report.stapleCount + this.report.otherCount, 1);
  }

  skillRecipe(): Recipe | null {
    return RecommendService.nextSkillRecipe(this.ad);
  }

  // 照片文件损坏/丢失时自动摘掉坏路径：回退 emoji 显示，照片墙不再出现灰卡
  healBrokenPhoto(e: MealEntry, from: string): void {
    console.error('WTE img fail (' + from + '), heal: ' + e.photoPath);
    e.photoPath = '';
    Db.updateEntry(e).then((): void => {
      this.version++;
    });
  }

  confirmDelete(e: MealEntry): void {
    AlertDialog.show({
      title: '删掉这条记录？',
      message: '「' + e.dishName + '」将从餐桌记录移除（不影响菜谱和清单）。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '留着',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.primary'),
        action: (): void => {
          Actions.deleteEntry(this.ad, e, false);
          promptAction.showToast({ message: '已删掉这条记录', duration: 1500 });
        }
      }
    });
  }

  defs(): AchievementDef[] {
    return AchievementEngine.catalog();
  }

  moodEmoji(m: string): string {
    if (m === '开心') {
      return '😄';
    }
    if (m === '疲惫') {
      return '🥱';
    }
    if (m === '想偷懒') {
      return '🥴';
    }
    if (m === '想吃辣') {
      return '🌶️';
    }
    if (m === '想养生') {
      return '🧘';
    }
    return '';
  }

  build() {
    Column() {
      Text('我们的餐桌')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ top: 8 })

      // 三格统计
      Row({ space: 8 }) {
        StatCard({ v: this.stats.eatenCount + '', k: '吃过' })
        StatCard({ v: this.stats.streakDays + '', k: '连续天数' })
        StatCard({ v: this.ad.achUnlocked.size + '', k: '成就' })
      }
      .width('100%')
      .margin({ top: 12 })

      // 视图切换
      Scroll() {
        Row({ space: 7 }) {
          ForEach(this.views, (v: string) => {
            Text(v)
              .fontSize(12)
              .fontWeight(this.view === v ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.view === v ? $r('app.color.bg_cream') : $r('app.color.text_secondary'))
              .backgroundColor(this.view === v ? $r('app.color.text_primary') : $r('app.color.surface'))
              .padding({ left: 13, right: 13, top: 7, bottom: 7 })
              .borderRadius(999)
              .onClick(() => {
                this.view = v;
              })
          }, (v: string) => v + (this.version > 0 ? 'v' : ''))
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ top: 12 })

      if (this.view === '时间线') {
        this.TimelineView()
      } else if (this.view === '日历') {
        this.CalendarView()
      } else if (this.view === '日记') {
        this.DiaryView()
      } else if (this.view === '统计') {
        this.ReportView()
      } else if (this.view === '照片墙') {
        this.PhotoView()
      } else {
        this.AchView()
      }
    }
    .padding({ left: 16, right: 16 })
    .width('100%')
    .height('100%')
  }


  // ---------- 料理挑战横幅 ----------
  @Builder
  ChallengeBanner() {
    if (this.challenge() !== null) {
      Row({ space: 10 }) {
        Text('⚔️').fontSize(20)
        Column() {
          Text('本周料理挑战')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.primary'))
          Text(this.challenge() !.name + (this.challengeDays(this.challenge() !) >= 0 ?
            '（' + this.challengeDays(this.challenge() !) + ' 天没做啦）' : '（还没做过）'))
            .fontSize(12)
            .fontColor($r('app.color.text_primary'))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('去看看 →')
          .fontSize(11)
          .fontColor($r('app.color.primary'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/RecipeDetailPage', params: { id: this.challenge() !.id } });
          })
      }
      .width('100%')
      .padding({ left: 14, right: 12, top: 11, bottom: 11 })
      .borderRadius(14)
      .backgroundColor($r('app.color.orange_tint'))
      .margin({ top: 10 })
    }
  }

  @Builder
  TimelineView() {
    Column() {
      this.ChallengeBanner()
      if (this.eatenEntries().length === 0) {
        EmptyState('📔', '还没有吃饭记录', '在「今天」页点「做完了」就会记下来')
      } else {
        List({ space: 7 }) {
          ForEach(this.eatenEntries(), (e: MealEntry) => {
            ListItem() {
              Row({ space: 10 }) {
                if (e.photoPath.length > 0) {
                  Image(fileUri.getUriFromPath(e.photoPath))
                    .width(52)
                    .height(52)
                    .borderRadius(12)
                    .objectFit(ImageFit.Cover)
                    .onError((): void => {
                      this.healBrokenPhoto(e, 'timeline');
                    })
                } else {
                  Text(e.emoji)
                    .fontSize(22)
                    .width(52)
                    .height(52)
                    .textAlign(TextAlign.Center)
                    .borderRadius(12)
                    .backgroundColor($r('app.color.chip_bg'))
                }
                Column() {
                  Text(e.dishName)
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Row({ space: 6 }) {
                    Text(e.date.substring(5).replace('-', '/'))
                      .fontSize(10)
                      .fontColor($r('app.color.text_hint'))
                    if (e.rating > 0) {
                      Text('⭐' + e.rating).fontSize(10)
                    }
                    if (e.mood.length > 0) {
                      Text(this.moodEmoji(e.mood) + e.mood).fontSize(10)
                    }
                  }
                  .margin({ top: 3 })
                  if (e.note.length > 0) {
                    Text('“' + e.note + '”')
                      .fontSize(10)
                      .fontColor($r('app.color.text_secondary'))
                      .margin({ top: 3 })
                      .maxLines(2)
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding(10)
              .borderRadius(14)
              .backgroundColor($r('app.color.surface'))
              .shadow({ radius: 8, color: '#1FD6A474', offsetY: 2 })
              .gesture(LongPressGesture().onAction(() => {
                this.confirmDelete(e);
              }))
            }
          }, (e: MealEntry) => e.id + (this.version > 0 ? 'v' : ''))
        }
        .width('100%')
        .layoutWeight(1)
        .margin({ top: 10 })
      }
    }
    .width('100%')
    .height('100%')
  }

  // ---------- 日历视图（对照表：历史记录日历视图 P2） ----------
  @Builder
  CalendarView() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(18)
          .fontColor($r('app.color.primary'))
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick(() => {
            this.shiftMonth(-1);
          })
        Text(this.calMonth.replace('-', ' 年 ') + ' 月')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.primary'))
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick(() => {
            this.shiftMonth(1);
          })
      }
      .width('100%')

      Row({ space: 4 }) {
        ForEach(['一', '二', '三', '四', '五', '六', '日'], (w: string) => {
          Text(w)
            .fontSize(9)
            .fontColor($r('app.color.text_hint'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
        }, (w: string) => w)
      }
      .width('100%')
      .margin({ top: 6 })

      // 日期网格
      Grid() {
        ForEach(this.calLeadingBlanks(), (n: number) => {
          GridItem() {
            Column().height(40)
          }
        }, (n: number) => 'blank' + n)
        ForEach(this.calDays(), (d: string) => {
          GridItem() {
            Column() {
              Text(String(Number(d.substring(8))))
                .fontSize(11)
                .fontWeight(this.calSelected === d || d === todayStr() ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(d === todayStr() ? $r('app.color.primary') : $r('app.color.text_primary'))
              Row({ space: 2 }) {
                // 当天吃过的小圆点
                if (this.eatenOn(d).length > 0) {
                  ForEach(this.eatenOn(d).slice(0, 3), (e: MealEntry) => {
                    Text(e.emoji).fontSize(9)
                  }, (e: MealEntry) => e.id)
                }
              }
              .height(12)
              .margin({ top: 2 })
            }
            .width('100%')
            .height(40)
            .borderRadius(10)
            .backgroundColor(this.calSelected === d ? $r('app.color.primary_tint') :
              (this.eatenOn(d).length > 0 ? $r('app.color.surface') : Color.Transparent))
            .borderWidth(this.eatenOn(d).length > 0 ? 1 : 0)
            .borderColor($r('app.color.primary_border'))
            .onClick(() => {
              this.calSelected = this.calSelected === d ? '' : d;
            })
          }
        }, (d: string) => d + (this.version > 0 ? 'v' : '') + (this.calSelected === d ? 's' : ''))
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr')
      .rowsGap(3)
      .width('100%')
      .height(this.calDays().length > 35 ? 300 : 260)
      .margin({ top: 6 })

      // 选中日的记录
      if (this.calSelected.length > 0) {
        SectionHeader({
          title: this.calSelected + ' · ' + weekdayCn(this.calSelected),
          more: this.eatenOn(this.calSelected).length + ' 道'
        })
        if (this.eatenOn(this.calSelected).length === 0) {
          Text('这天没下厨记录')
            .fontSize(11)
            .fontColor($r('app.color.text_hint'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 12 })
        } else {
          List({ space: 6 }) {
            ForEach(this.eatenOn(this.calSelected), (e: MealEntry) => {
              ListItem() {
                Row({ space: 10 }) {
                  Text(e.emoji).fontSize(18)
                  Text(e.dishName)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                  if (e.rating > 0) {
                    Text('⭐' + e.rating).fontSize(10)
                  }
                }
                .width('100%')
                .padding(10)
                .borderRadius(12)
                .backgroundColor($r('app.color.surface'))
              }
            }, (e: MealEntry) => e.id)
          }
          .width('100%')
          .layoutWeight(1)
        }
      } else {
        Blank()
      }
    }
    .width('100%')
    .height('100%')
  }

  // ---------- 做菜日记（点子#12：文字+照片时间线，零新表） ----------
  @Builder
  DiaryView() {
    if (this.diaryEntries().length === 0) {
      EmptyState('📖', '日记还空着', '吃完打分时写一句感想或拍张照，就会出现在这里')
    } else {
      List({ space: 10 }) {
        ForEach(this.diaryEntries(), (e: MealEntry) => {
          ListItem() {
            Column() {
              Row({ space: 8 }) {
                Text(e.date.substring(5).replace('-', '/') + ' ' + weekdayCn(e.date))
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.primary'))
                Blank()
                if (e.rating > 0) {
                  Text('⭐'.repeat(e.rating)).fontSize(10)
                }
                Text(e.dishName)
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              if (e.note.length > 0) {
                Text(e.note)
                  .fontSize(13)
                  .fontColor($r('app.color.text_primary'))
                  .lineHeight(20)
                  .margin({ top: 6 })
              }
              if (e.photoPath.length > 0) {
                Image(fileUri.getUriFromPath(e.photoPath))
                  .width('100%')
                  .height(150)
                  .borderRadius(12)
                  .objectFit(ImageFit.Cover)
                  .margin({ top: 8 })
                  .onError((): void => {
                    this.healBrokenPhoto(e, 'diary');
                  })
              }
            }
            .width('100%')
            .padding(14)
            .borderRadius(16)
            .backgroundColor($r('app.color.surface'))
            .shadow({ radius: 8, color: '#1FD6A474', offsetY: 2 })
            .gesture(LongPressGesture().onAction(() => {
              this.confirmDelete(e);
            }))
          }
        }, (e: MealEntry) => e.id + (this.version > 0 ? 'v' : ''))
      }
      .width('100%')
      .layoutWeight(1)
      .margin({ top: 10 })
    }
  }

  // ---------- 统计报表（改进#4：端侧计算，无 LLM） ----------
  @Builder
  ReportView() {
    Scroll() {
      Column() {
        // 本月概览
        Row({ space: 8 }) {
          RCard({ v: this.report.monthEaten + '', k: '本月吃过' })
          RCard({ v: this.report.monthActiveDays + '', k: '活跃天' })
          RCard({ v: this.report.monthNewDishes + '', k: '新菜尝试' })
          RCard({ v: this.report.monthAvgRating > 0 ? this.report.monthAvgRating + '★' : '—', k: '平均评分' })
        }
        .width('100%')
        .margin({ top: 10 })

        // 荤素汤结构
        Column() {
          Text('荤素搭配（本月）')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          BarRow({ label: '🥩 荤', count: this.report.meatCount, total: this.reportTotal(), barColor: $r('app.color.primary') })
          BarRow({ label: '🥬 素', count: this.report.vegCount, total: this.reportTotal(), barColor: $r('app.color.green') })
          BarRow({ label: '🍲 汤', count: this.report.soupCount, total: this.reportTotal(), barColor: $r('app.color.accent') })
          BarRow({ label: '🍚 主食', count: this.report.stapleCount, total: this.reportTotal(), barColor: '#8B7355' })
          if (this.report.meatCount + this.report.vegCount === 0) {
            Text('本月还没记录，吃过就会开始统计')
              .fontSize(10)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .margin({ top: 6 })
          } else if (this.report.meatCount > this.report.vegCount * 2) {
            Text('💡 荤菜偏多，下次试试多来一道素菜')
              .fontSize(10)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .margin({ top: 6 })
          } else {
            Text('👍 荤素搭配挺均衡，继续保持')
              .fontSize(10)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .margin({ top: 6 })
          }
        }
        .width('100%')
        .padding(14)
        .borderRadius(14)
        .backgroundColor($r('app.color.surface'))
        .margin({ top: 10 })

        // 口味 Top5
        if (this.report.tasteTop.length > 0) {
          Column() {
            Text('口味偏好（本月 Top）')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            ForEach(this.report.tasteTop, (t: string, i: number) => {
              BarRow({ label: t, count: this.report.tasteCounts[i], total: this.reportTotal(), barColor: $r('app.color.primary_pressed') })
            }, (t: string, i: number) => t + i + this.version)
          }
          .width('100%')
          .padding(14)
          .borderRadius(14)
          .backgroundColor($r('app.color.surface'))
          .margin({ top: 10 })
        }

        // 周趋势
        Column() {
          Text('最近 6 周开饭次数')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Row({ space: 8 }) {
            ForEach(this.report.weekCounts, (c: number, i: number) => {
              Column() {
                Text(c > 0 ? '' + c : '')
                  .fontSize(9)
                  .fontColor($r('app.color.text_hint'))
                Column()
                  .width(18)
                  .height(Math.min(c * 6, 60))
                  .borderRadius(4)
                  .backgroundColor(c > 0 ? $r('app.color.primary') : $r('app.color.divider'))
                Text(this.report.weekLabels[i])
                  .fontSize(8)
                  .fontColor($r('app.color.text_hint'))
                  .margin({ top: 3 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
            }, (c: number, i: number) => i + '_' + c + '_' + this.version)
          }
          .width('100%')
          .alignItems(VerticalAlign.Bottom)
          .height(90)
          .margin({ top: 8 })
        }
        .width('100%')
        .padding(14)
        .borderRadius(14)
        .backgroundColor($r('app.color.surface'))
        .margin({ top: 10, bottom: 20 })
      }
      .width('100%')
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
    .width('100%')
  }



  @Builder
  PhotoView() {
    if (this.photoEntries().length === 0) {
      EmptyState('📷', '照片墙还空着', '吃完打分时拍一张，这里就热闹了')
    } else {
      Scroll() {
        Grid() {
          ForEach(this.photoEntries(), (e: MealEntry) => {
            GridItem() {
              Stack({ alignContent: Alignment.BottomStart }) {
                Image(fileUri.getUriFromPath(e.photoPath))
                  .width('100%')
                  .aspectRatio(1)
                  .borderRadius(13)
                  .objectFit(ImageFit.Cover)
                  .onError((): void => {
                    this.healBrokenPhoto(e, 'wall');
                  })
                Text(e.emoji + ' ' + (e.rating > 0 ? '⭐' + e.rating : ''))
                  .fontSize(10)
                  .fontColor(Color.White)
                  .padding({ left: 8, bottom: 6 })
                  .shadow({ radius: 4, color: '#80000000', offsetY: 1 })
              }
              .width('100%')
            }
          }, (e: MealEntry) => e.id + (this.version > 0 ? 'v' : ''))
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(7)
        .rowsGap(7)
        .width('100%')
        .margin({ top: 10 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
  }

  @Builder
  AchView() {
    Scroll() {
      Column() {
        Text('一起解锁 ' + this.ad.achUnlocked.size + ' / ' + this.defs().length + ' 个成就')
          .fontSize(11)
          .fontColor($r('app.color.text_hint'))
          .width('100%')
          .margin({ top: 10 })
        Grid() {
          ForEach(this.defs(), (d: AchievementDef) => {
            GridItem() {
              Column() {
                Text(d.icon)
                  .fontSize(24)
                  .rotate({ angle: this.ad.achUnlocked.has(d.id) ? -6 : 0 })
                Text(d.name)
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.ad.achUnlocked.has(d.id) ? $r('app.color.text_primary') : $r('app.color.text_hint'))
                  .margin({ top: 5 })
                Text(d.desc)
                  .fontSize(9)
                  .fontColor($r('app.color.text_hint'))
                  .maxLines(1)
                  .margin({ top: 1 })
                Column() {
                  Progress({
                    value: Math.min(d.progress(this.stats), d.target),
                    total: d.target,
                    type: ProgressType.Linear
                  })
                    .color($r('app.color.accent'))
                    .style({ strokeWidth: 4 })
                    .width('100%')
                }
                .margin({ top: 6, left: 10, right: 10 })

                Text(this.ad.achUnlocked.has(d.id) ?
                  '✅ ' + (this.ad.achUnlocked.get(d.id) !== undefined ? this.ad.achUnlocked.get(d.id) !.unlockedBy : '') + '解锁' :
                  Math.min(d.progress(this.stats), d.target) + '/' + d.target)
                  .fontSize(9)
                  .fontColor(this.ad.achUnlocked.has(d.id) ? $r('app.color.green') : $r('app.color.text_hint'))
                  .margin({ top: 4, bottom: 8 })
              }
              .width('100%')
              .borderRadius(15)
              .backgroundColor($r('app.color.surface'))
              .opacity(this.ad.achUnlocked.has(d.id) ? 1 : 0.62)
              .shadow({ radius: 8, color: '#1FD6A474', offsetY: 2 })
              .margin({ top: 8 })
            }
          }, (d: AchievementDef) => d.id + (this.version > 0 ? 'v' : ''))
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(9)
        .rowsGap(0)
        .width('100%')

        // 厨艺进阶挑战（点子#5）
        if (this.skillRecipe() !== null) {
          Row({ space: 10 }) {
            Text('🧗').fontSize(20)
            Column() {
              Text('下一道挑战 · 厨艺进阶')
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.primary'))
              Text('「' + this.skillRecipe() !.name + '」难度★' + this.skillRecipe() !.difficulty)
                .fontSize(12)
                .fontColor($r('app.color.text_primary'))
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text('去看看 →')
              .fontSize(11)
              .fontColor($r('app.color.primary'))
              .onClick(() => {
                router.pushUrl({ url: 'pages/RecipeDetailPage', params: { id: this.skillRecipe() !.id } });
              })
          }
          .width('100%')
          .padding({ left: 14, right: 12, top: 11, bottom: 11 })
          .borderRadius(14)
          .backgroundColor($r('app.color.blue_tint'))
          .margin({ top: 14, bottom: 20 })
        } else {
          Text('🏆 已挑战完当前最高难度的菜，去菜谱库加新菜吧')
            .fontSize(10)
            .fontColor($r('app.color.text_hint'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 14, bottom: 20 })
        }
      }
      .width('100%')
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
    .width('100%')
  }
}
