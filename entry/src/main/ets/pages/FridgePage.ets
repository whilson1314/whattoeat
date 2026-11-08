// 清冰箱页：库存列表 + 选食材本地匹配 + LLM 现场生成 + 一键扣减
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { AppData, EVT_FRIDGE } from '../data/AppData';
import { RecommendService } from '../service/RecommendService';
import { AiService } from '../service/AiService';
import { Actions } from '../service/Actions';
import { Recipe, FridgeItem, todayStr, addDays, GROUP_ORDER, genId } from '../model/Models';
import { EmptyState, SectionHeader } from '../common/Widgets';

@Entry
@Component
struct FridgePage {
  @State selected: Set<string> = new Set<string>();
  @State matches: Recipe[] = [];
  @State version: number = 0;
  @State newName: string = '';
  @State newAmount: string = '';
  @State newExpiry: string = '';
  @State newCat: string = '其他';
  // AI 现场生成
  @State aiBusy: boolean = false;
  @State aiRecipe: Recipe | null = null;
  @State aiUses: string[] = [];
  @State showAiGen: boolean = false; // 服务端白名单含 fridge 才显示
  private ad: AppData = AppData.getInstance();
  private listener: ((evt: number) => void) | null = null;

  aboutToAppear(): void {
    const self = this;
    this.listener = (evt: number): void => {
      if (evt === EVT_FRIDGE) {
        self.version++;
      }
    };
    this.ad.register(this.listener);
    AiService.probe().then((ok: boolean): void => {
      self.showAiGen = ok && AiService.can('fridge');
      self.version++;
    });
  }

  aboutToDisappear(): void {
    if (this.listener !== null) {
      this.ad.unregister(this.listener);
    }
  }

  isExpiring(f: FridgeItem): boolean {
    if (f.expiryDate.length === 0) {
      return false;
    }
    return f.expiryDate <= addDays(todayStr(), 1);
  }

  selectedNames(): string[] {
    const out: string[] = [];
    this.ad.fridge.forEach((f: FridgeItem) => {
      if (this.selected.has(f.id)) {
        out.push(f.name);
      }
    });
    return out;
  }

  doMatch(): void {
    this.matches = RecommendService.fridgeMatch(this.ad, this.selectedNames());
  }

  // ---------- AI 现场生成清冰箱菜（LLM接入设计 §5.2） ----------
  async askAiFridge(): Promise<void> {
    const names = this.selectedNames();
    if (names.length === 0 || this.aiBusy) {
      return;
    }
    this.aiBusy = true;
    this.aiRecipe = null;
    this.aiUses = [];
    const r = await AiService.fridgeRecipe(names, '');
    this.aiBusy = false;
    if (r === null) {
      promptAction.showToast({
        message: 'AI 助手暂时不可用（未配置或网络不佳），先用下面的本地匹配吧', duration: 2400
      });
      return;
    }
    this.aiRecipe = r;
    this.aiUses = r.ingredients.map((i): string => i.name);
    this.version++;
  }

  // AI 生成的菜直接安排（自动扣库存）
  async cookAiRecipe(): Promise<void> {
    if (this.aiRecipe === null) {
      return;
    }
    const r = this.aiRecipe;
    await Actions.pickDish(this.ad, r, new Date().getHours() < 15 ? 'lunch' : 'dinner', 'manual');
    await Actions.deductFridgeForRecipe(this.ad, r);
    this.aiRecipe = null;
    this.selected.clear();
    this.matches = [];
    promptAction.showToast({ message: '安排了「' + r.name + '」，食材已扣减', duration: 2000 });
  }

  // AI 生成的菜入库
  saveAiRecipe(): void {
    if (this.aiRecipe === null) {
      return;
    }
    const r = this.aiRecipe;
    r.createdBy = this.ad.settings.currentMember;
    Actions.saveRecipe(this.ad, r, true);
    promptAction.showToast({ message: '「' + r.name + '」已入库 🎉（去编辑页可微调）', duration: 2200 });
  }

  async cookIt(r: Recipe): Promise<void> {
    // 加入今天计划 + 扣库存
    await Actions.pickDish(this.ad, r, new Date().getHours() < 15 ? 'lunch' : 'dinner', 'manual');
    const n = await Actions.deductFridgeForRecipe(this.ad, r);
    promptAction.showToast({
      message: '安排了「' + r.name + '」，扣掉了 ' + n + ' 样冰箱食材',
      duration: 2200
    });
    this.matches = [];
    this.selected.clear();
  }

  build() {
    Column() {
      Row() {
        Text('←')
          .fontSize(20)
          .fontColor($r('app.color.text_primary'))
          .padding({ left: 16, right: 12, top: 10, bottom: 10 })
          .onClick(() => {
            router.back();
          })
        Text('🧊 冰箱')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')

      Scroll() {
        Column() {
          // 添加（食材名 + 量 + 保质期）
          Row({ space: 8 }) {
            TextInput({ placeholder: '食材名', text: this.newName })
              .fontSize(12)
              .height(38)
              .layoutWeight(2)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(10)
              .onChange((v: string) => {
                this.newName = v;
              })
              .onSubmit(() => {
                this.add();
              })
            TextInput({ placeholder: '量（可空）', text: this.newAmount })
              .fontSize(12)
              .height(38)
              .layoutWeight(1)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(10)
              .onChange((v: string) => {
                this.newAmount = v;
              })
            TextInput({ placeholder: '到期日 可空', text: this.newExpiry })
              .fontSize(11)
              .height(38)
              .layoutWeight(1.5)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(10)
              .onChange((v: string) => {
                this.newExpiry = v;
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
                this.add();
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          Text('到期日格式 2026-11-08；临期前一天 9 点会提醒你 🧊')
            .fontSize(9)
            .fontColor($r('app.color.text_hint'))
            .width('100%')
            .margin({ top: 4 })

          if (this.ad.fridge.length === 0) {
            EmptyState('🧊', '冰箱是空的', '买菜勾掉时可以顺手放进冰箱；或在上面手动加')
          } else {
            Text('点选食材 → 匹配能做的菜（临期标红）')
              .fontSize(10)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .margin({ top: 10 })

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.sortedFridge(), (f: FridgeItem) => {
                Column({ space: 2 }) {
                  Text(f.name)
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.selected.has(f.id) ? Color.White :
                      (this.isExpiring(f) ? $r('app.color.primary_pressed') : $r('app.color.text_primary')))
                  Text(f.amount.length > 0 ? f.amount : ' ')
                    .fontSize(9)
                    .fontColor(this.selected.has(f.id) ? '#FFEAE3' : $r('app.color.text_hint'))
                  if (this.isExpiring(f)) {
                    Text('⚠️临期')
                      .fontSize(8)
                      .fontColor(this.selected.has(f.id) ? '#FFEAE3' : $r('app.color.primary_pressed'))
                  }
                }
                .alignItems(HorizontalAlign.Center)
                .padding({ left: 14, right: 14, top: 9, bottom: 9 })
                .borderRadius(14)
                .backgroundColor(this.selected.has(f.id) ? $r('app.color.primary') : $r('app.color.surface'))
                .borderWidth(1)
                .borderColor(this.isExpiring(f) && !this.selected.has(f.id) ?
                  $r('app.color.primary_border') : Color.Transparent)
                .margin(4)
                .shadow({ radius: 6, color: '#1FD6A474', offsetY: 2 })
                .onClick(() => {
                  if (this.selected.has(f.id)) {
                    this.selected.delete(f.id);
                  } else {
                    this.selected.add(f.id);
                  }
                  this.selected = new Set<string>(Array.from(this.selected));
                  this.doMatch();
                })
                .gesture(LongPressGesture().onAction(() => {
                  Actions.deleteFridgeItem(this.ad, f);
                }))
              }, (f: FridgeItem) => f.id + (this.selected.has(f.id) ? 's' : 'u') + this.version)
            }
            .width('100%')
            .margin({ top: 6 })

            Row() {
              Text(this.selected.size + ' 样已选 · 长按删除')
                .fontSize(10)
                .fontColor($r('app.color.text_hint'))
              Blank()
              Text('🗑 清空冰箱')
                .fontSize(10)
                .fontColor($r('app.color.primary'))
                .onClick(() => {
                  this.clearAll();
                })
            }
            .width('100%')
            .margin({ top: 8 })

            // AI 现场生成（白名单未含 fridge 时隐藏，保持零 token）
            if (this.selected.size > 0 && this.showAiGen) {
              Column({ space: 8 }) {
                Text(this.aiBusy ? '🤖 AI 助手正在看你的冰箱…' :
                  (this.aiRecipe === null ? '🤖 让AI 助手现场想一道（AI 生成，可直接入库）' : '🤖 AI 助手想出的新菜'))
                  .fontSize(11)
                  .fontColor($r('app.color.text_hint'))
                  .width('100%')
                  .margin({ top: 12 })
                if (this.aiBusy) {
                  Text('…').fontSize(18).margin({ top: 6 })
                } else if (this.aiRecipe !== null) {
                  Column({ space: 6 }) {
                    Row({ space: 10 }) {
                      Text(this.aiRecipe.emoji).fontSize(30)
                      Column() {
                        Text(this.aiRecipe.name)
                          .fontSize(15)
                          .fontWeight(FontWeight.Bold)
                          .fontColor($r('app.color.text_primary'))
                        Text(this.aiRecipe.taste + ' · ' + this.aiRecipe.cuisine +
                          (this.aiRecipe.durationMin > 0 ? ' · ' + this.aiRecipe.durationMin + '分钟' : '') +
                          ' · 难度★' + this.aiRecipe.difficulty)
                          .fontSize(10)
                          .fontColor($r('app.color.text_hint'))
                          .margin({ top: 2 })
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                    }
                    .width('100%')
                    Flex({ wrap: FlexWrap.Wrap }) {
                      ForEach(this.aiUses, (u: string) => {
                        Text(u)
                          .fontSize(10)
                          .fontColor($r('app.color.green'))
                          .backgroundColor($r('app.color.green_tint'))
                          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                          .borderRadius(999)
                          .margin(3)
                      }, (u: string) => u)
                    }
                    .width('100%')
                    Row({ space: 8 }) {
                      Button('做它 → 扣库存')
                        .fontSize(12)
                        .fontColor(Color.White)
                        .backgroundColor($r('app.color.primary'))
                        .layoutWeight(1)
                        .height(36)
                        .borderRadius(999)
                        .onClick(() => {
                          this.cookAiRecipe();
                        })
                      Button('入库保存')
                        .fontSize(12)
                        .fontColor($r('app.color.primary'))
                        .backgroundColor($r('app.color.surface'))
                        .borderWidth(1.2)
                        .borderColor($r('app.color.primary_border'))
                        .layoutWeight(1)
                        .height(36)
                        .borderRadius(999)
                        .onClick(() => {
                          this.saveAiRecipe();
                        })
                    }
                    .width('100%')
                    .margin({ top: 4 })
                  }
                  .width('100%')
                  .padding(12)
                  .borderRadius(14)
                  .backgroundColor($r('app.color.surface'))
                  .borderWidth(1)
                  .borderColor($r('app.color.primary_border'))
                  .margin({ top: 4 })
                } else {
                  Button('🤖 用选中的食材生成一道新菜')
                    .fontSize(12)
                    .fontColor(Color.White)
                    .backgroundColor($r('app.color.primary'))
                    .width('100%')
                    .height(38)
                    .borderRadius(999)
                    .margin({ top: 6 })
                    .onClick(() => {
                      this.askAiFridge();
                    })
                }
              }
              .width('100%')
            }

            // 匹配结果
            if (this.matches.length > 0) {
              SectionHeader({ title: '这些菜能用上你选的 ' + this.selected.size + ' 样食材', more: '' })
              ForEach(this.matches, (r: Recipe) => {
                Row({ space: 10 }) {
                  Text(r.emoji).fontSize(20)
                  Column() {
                    Text(r.name)
                      .fontSize(13)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                    Text(r.taste + ' · ' + r.cuisine + (r.durationMin > 0 ? ' · ' + r.durationMin + '分钟' : ''))
                      .fontSize(10)
                      .fontColor($r('app.color.text_hint'))
                      .margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Button('做了它')
                    .fontSize(12)
                    .fontColor(Color.White)
                    .backgroundColor($r('app.color.primary'))
                    .height(32)
                    .borderRadius(999)
                    .padding({ left: 14, right: 14 })
                    .onClick(() => {
                      this.cookIt(r);
                    })
                }
                .width('100%')
                .padding({ left: 12, right: 10, top: 10, bottom: 10 })
                .borderRadius(14)
                .backgroundColor($r('app.color.surface'))
                .margin({ bottom: 7 })
                .shadow({ radius: 8, color: '#1FD6A474', offsetY: 2 })
              }, (r: Recipe) => r.id)
            } else if (this.selected.size > 0) {
              Text(this.showAiGen ? '库里没有能匹配上的菜，让AI 助手现场想一道吧' :
                '库里没有能匹配上的菜（AI 生成未启用，仅 AI 加菜/食材替换走 DeepSeek）')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 16 })
            }
          }
          Column().height(30)
        }
        .padding({ left: 16, right: 16 })
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

  sortedFridge(): FridgeItem[] {
    const arr = this.ad.fridge.slice();
    arr.sort((a: FridgeItem, b: FridgeItem): number => {
      const ax = this.isExpiring(a) ? 0 : 1;
      const bx = this.isExpiring(b) ? 0 : 1;
      if (ax !== bx) {
        return ax - bx;
      }
      return a.addedAt - b.addedAt;
    });
    return arr;
  }

  add(): void {
    const n = this.newName.trim();
    if (n.length === 0) {
      promptAction.showToast({ message: '先写食材名', duration: 1200 });
      return;
    }
    let expiry = this.newExpiry.trim();
    // 简单校验 yyyy-MM-dd
    if (expiry.length > 0 && !/^\d{4}-\d{2}-\d{2}$/.test(expiry)) {
      promptAction.showToast({ message: '到期日格式：2026-11-08（留空则不提醒）', duration: 2200 });
      return;
    }
    Actions.addFridge(this.ad, n, this.newAmount, this.newCat, expiry);
    this.newName = '';
    this.newAmount = '';
    this.newExpiry = '';
  }

  clearAll(): void {
    const ids: string[] = [];
    this.ad.fridge.forEach((f: FridgeItem) => {
      ids.push(f.id);
    });
    const self = this;
    AlertDialog.show({
      title: '清空冰箱？',
      message: '所有库存记录将被删除',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '不了',
        action: (): void => {}
      },
      secondaryButton: {
        value: '清空',
        fontColor: $r('app.color.primary_pressed'),
        action: (): void => {
          Actions.deleteFridgeBatch(self.ad, ids);
          self.selected.clear();
        }
      }
    });
  }
}
