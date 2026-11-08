// 「买菜」页：分组清单 + 多选批量操作（放冰箱/已买/家里已有/删除）+ 手动添加 + 清空已买
// 新增：价格估算与周预算（对照表 #10/#15）、清单分享文本、已买历史归档对比
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppData, EVT_ITEMS } from '../data/AppData';
import { Db } from '../data/Db';
import { Actions } from '../service/Actions';
import { ShoppingItem, GROUP_ORDER, GROUP_ICON } from '../model/Models';
import { SectionHeader, EmptyState } from '../common/Widgets';

@Component
export struct ShoppingPage {
  // 数据快照（@State 驱动刷新）
  @State activeList: ShoppingItem[] = [];
  @State checkedList: ShoppingItem[] = [];
  @State stockList: ShoppingItem[] = [];
  @State historyList: ShoppingItem[] = []; // 已归档（清空已买后）
  @State newName: string = '';
  @State newAmount: string = '';
  @State newCat: string = '其他';
  @State newPrice: string = '';
  @State showCatPicker: boolean = false;
  @State multiSelect: boolean = false;
  @State selectedIds: string[] = [];
  @State priceEdit: ShoppingItem | null = null;
  @State priceInput: string = '';
  @State version: number = 0;
  private ad: AppData = AppData.getInstance();
  private listener: ((evt: number) => void) | null = null;

  aboutToAppear(): void {
    this.refresh();
    const self = this;
    this.listener = (evt: number): void => {
      if (evt === EVT_ITEMS) {
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

  refresh(): void {
    const a: ShoppingItem[] = [];
    const c: ShoppingItem[] = [];
    const s: ShoppingItem[] = [];
    const h: ShoppingItem[] = [];
    for (let i = 0; i < this.ad.items.length; i++) {
      const it = this.ad.items[i];
      if (it.archivedAt > 0) {
        h.push(it);
      } else if (it.checked) {
        c.push(it);
      } else if (it.inStock) {
        s.push(it);
      } else {
        a.push(it);
      }
    }
    this.activeList = a;
    this.checkedList = c;
    this.stockList = s;
    h.sort((x: ShoppingItem, y: ShoppingItem): number => y.archivedAt - x.archivedAt);
    this.historyList = h.slice(0, 10);
    // 清理已不存在的选中项
    this.selectedIds = this.selectedIds.filter((id: string): boolean => {
      for (let i = 0; i < this.ad.items.length; i++) {
        if (this.ad.items[i].id === id) {
          return true;
        }
      }
      return false;
    });
    if (this.selectedIds.length === 0) {
      this.multiSelect = false;
    }
  }

  // 待买+已买的合计金额（家里已有不计入采购）
  totalPrice(): number {
    let t = 0;
    for (let i = 0; i < this.activeList.length; i++) {
      t += this.activeList[i].price;
    }
    for (let i = 0; i < this.checkedList.length; i++) {
      t += this.checkedList[i].price;
    }
    return Math.round(t * 10) / 10;
  }

  budgetExceeded(): boolean {
    const b = this.ad.settings.weeklyBudget;
    return b > 0 && this.totalPrice() > b;
  }

  openPriceEdit(it: ShoppingItem): void {
    this.priceEdit = it;
    this.priceInput = it.price > 0 ? '' + it.price : '';
    this.version++;
  }

  savePrice(): void {
    const it = this.priceEdit;
    if (it === null) {
      return;
    }
    const v = Number(this.priceInput);
    it.price = isNaN(v) || v < 0 ? 0 : v;
    Db.updateItem(it).then((): void => {
      this.ad.reloadItems();
    });
    this.priceEdit = null;
  }

  // 分享清单文本（复制到剪贴板）
  shareList(): void {
    const now = new Date();
    const lines: string[] = ['🛒 买菜清单 · ' + (now.getMonth() + 1) + '/' + now.getDate()];
    const groups = this.groupNames();
    let count = 0;
    for (let g = 0; g < groups.length; g++) {
      const items = this.itemsIn(groups[g]);
      lines.push(GROUP_ICON.get(groups[g]) + ' ' + groups[g]);
      for (let i = 0; i < items.length; i++) {
        const it = items[i];
        count++;
        lines.push('- ' + it.name + (it.amount.length > 0 ? '（' + it.amount + '）' : '') +
          (it.price > 0 ? ' ¥' + it.price : '') + (it.inStock ? ' 🏠' : ''));
      }
    }
    if (this.totalPrice() > 0) {
      lines.push('合计约 ¥' + this.totalPrice());
    }
    if (count === 0) {
      promptAction.showToast({ message: '清单是空的', duration: 1500 });
      return;
    }
    const text = lines.join('\n');
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then((): void => {
      promptAction.showToast({ message: '清单已复制，去粘贴给 TA 吧 📋', duration: 2000 });
    }).catch((): void => {
      promptAction.showToast({ message: '复制失败', duration: 1500 });
    });
  }

  isSelected(id: string): boolean {
    return this.selectedIds.includes(id);
  }

  toggleSelect(id: string): void {
    const idx = this.selectedIds.indexOf(id);
    if (idx >= 0) {
      this.selectedIds.splice(idx, 1);
    } else {
      this.selectedIds.push(id);
    }
    this.selectedIds = this.selectedIds.slice();
  }

  groupNames(): string[] {
    const present: string[] = [];
    for (let g = 0; g < GROUP_ORDER.length; g++) {
      for (let i = 0; i < this.activeList.length; i++) {
        if (this.activeList[i].category === GROUP_ORDER[g]) {
          present.push(GROUP_ORDER[g]);
          break;
        }
      }
    }
    const extra: string[] = [];
    for (let i = 0; i < this.activeList.length; i++) {
      if (!GROUP_ORDER.includes(this.activeList[i].category) && !extra.includes(this.activeList[i].category)) {
        extra.push(this.activeList[i].category);
      }
    }
    return present.concat(extra);
  }

  itemsIn(group: string): ShoppingItem[] {
    const out: ShoppingItem[] = [];
    for (let i = 0; i < this.activeList.length; i++) {
      if (this.activeList[i].category === group) {
        out.push(this.activeList[i]);
      }
    }
    return out;
  }

  // ---------- 批量操作 ----------
  private selectedItems(): ShoppingItem[] {
    const out: ShoppingItem[] = [];
    for (let i = 0; i < this.ad.items.length; i++) {
      if (this.selectedIds.includes(this.ad.items[i].id)) {
        out.push(this.ad.items[i]);
      }
    }
    return out;
  }

  batchFridge(): void {
    const items = this.selectedItems();
    if (items.length === 0) {
      return;
    }
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      Actions.addFridge(this.ad, it.name, it.amount, it.category, '');
      Db.deleteItem(it.id);
    }
    this.ad.reloadItems();
    this.exitMulti();
    promptAction.showToast({ message: items.length + ' 项已入冰箱 🧊', duration: 1500 });
  }

  batchInStock(): void {
    const items = this.selectedItems();
    for (let i = 0; i < items.length; i++) {
      Actions.setInStock(this.ad, items[i], true);
    }
    this.exitMulti();
    promptAction.showToast({ message: items.length + ' 项已标记家里有 🏠', duration: 1500 });
  }

  batchCheck(): void {
    const items = this.selectedItems();
    for (let i = 0; i < items.length; i++) {
      items[i].checked = true;
      Db.updateItem(items[i]);
    }
    this.ad.reloadItems();
    Actions.fireAchievementCheck(this.ad);
    this.exitMulti();
  }

  batchDelete(): void {
    const items = this.selectedItems();
    for (let i = 0; i < items.length; i++) {
      Db.deleteItem(items[i].id);
    }
    this.ad.reloadItems();
    this.exitMulti();
    promptAction.showToast({ message: '已删除 ' + items.length + ' 项', duration: 1500 });
  }

  exitMulti(): void {
    this.multiSelect = false;
    this.selectedIds = [];
  }

  async submitManual(): Promise<void> {
    const name = this.newName.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '先写要买的东西', duration: 1200 });
      return;
    }
    // 7 天内刚买过（归档）的提示
    const now = Date.now();
    for (let i = 0; i < this.ad.items.length; i++) {
      const past = this.ad.items[i];
      if (past.name === name && past.archivedAt > 0 && now - past.archivedAt < 7 * 86400000) {
        promptAction.showToast({ message: '「' + name + '」上周刚买过，确认还要再买？', duration: 2600 });
        break;
      }
    }
    const pv = Number(this.newPrice);
    await Actions.addManualItem(this.ad, name, this.newAmount, this.newCat,
      isNaN(pv) ? 0 : Math.max(0, pv));
    this.newName = '';
    this.newAmount = '';
    this.newPrice = '';
  }

  deleteItem(it: ShoppingItem): void {
    Db.deleteItem(it.id).then((): void => {
      this.ad.reloadItems();
    });
  }

  fmtDay(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d = new Date(ts);
    const m = d.getMonth() + 1;
    const day = d.getDate();
    return (m < 10 ? '0' + m : '' + m) + '/' + (day < 10 ? '0' + day : '' + day);
  }

  build() {
    Column() {
      Row() {
        Text('买菜清单')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('¥' + this.totalPrice())
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.budgetExceeded() ? $r('app.color.primary_pressed') : $r('app.color.green'))
          .margin({ left: 10, top: 6 })
        Text(this.ad.settings.weeklyBudget > 0 ? '/ 预算 ¥' + this.ad.settings.weeklyBudget : '')
          .fontSize(9)
          .fontColor($r('app.color.text_hint'))
          .margin({ left: 2, top: 6 })
        Blank()
        Text('📋 分享')
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.primary_tint'))
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(999)
          .margin({ right: 8 })
          .onClick(() => {
            this.shareList();
          })
        Text('🧊 冰箱')
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.primary_tint'))
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(999)
          .onClick(() => {
            router.pushUrl({ url: 'pages/FridgePage' });
          })
      }
      .width('100%')
      .margin({ top: 8 })

      // 预算超支横幅
      if (this.budgetExceeded()) {
        Row({ space: 6 }) {
          Text('⚠️')
            .fontSize(13)
          Text('本周已花费 ¥' + this.totalPrice() + '，超出预算 ¥' + this.ad.settings.weeklyBudget)
            .fontSize(11)
            .fontColor($r('app.color.primary_pressed'))
          Blank()
          Text('去调整')
            .fontSize(10)
            .fontColor($r('app.color.primary'))
            .onClick(() => {
              router.pushUrl({ url: 'pages/SettingsPage' });
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .borderRadius(12)
        .backgroundColor($r('app.color.orange_tint'))
        .margin({ top: 8 })
      }

      // 进度 + 多选入口
      Row() {
        Text('已买 ' + this.checkedList.length + ' / ' + (this.checkedList.length + this.activeList.length) + ' 项')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        Text(this.multiSelect ? '取消多选' : '多选')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.multiSelect ? $r('app.color.primary_pressed') : $r('app.color.primary'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(999)
          .backgroundColor(this.multiSelect ? $r('app.color.primary_tint') : Color.Transparent)
          .onClick(() => {
            this.multiSelect = !this.multiSelect;
            this.selectedIds = [];
          })
        if (this.checkedList.length > 0 && !this.multiSelect) {
          Text('清空已买')
            .fontSize(11)
            .fontColor($r('app.color.primary'))
            .margin({ left: 10 })
            .onClick(() => {
              Actions.clearChecked(this.ad).then((n: number): void => {
                promptAction.showToast({ message: '清掉了 ' + n + ' 项', duration: 1500 });
              });
            })
        }
      }
      .width('100%')
      .margin({ top: 12 })

      Row() {
        Progress({
          value: this.checkedList.length,
          total: Math.max(this.checkedList.length + this.activeList.length, 1),
          type: ProgressType.Linear
        })
          .color($r('app.color.primary'))
          .backgroundColor($r('app.color.divider'))
          .style({ strokeWidth: 6 })
          .width('100%')
      }
      .width('100%')
      .margin({ top: 8 })

      Scroll() {
        Column() {
          if (this.activeList.length === 0 && this.checkedList.length === 0 && this.stockList.length === 0) {
            EmptyState('🛒', '清单空空的', '在下面手动加，或点菜后食材自动进来')
          }
          // 分组渲染
          ForEach(this.groupNames(), (g: string) => {
            Row({ space: 6 }) {
              Text(GROUP_ICON.get(g) === undefined ? '📦' : GROUP_ICON.get(g) as string)
                .fontSize(13)
              Text(g)
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
              Text(this.itemsIn(g).length + ' 项')
                .fontSize(10)
                .fontColor($r('app.color.text_hint'))
            }
            .width('100%')
            .margin({ top: 12, bottom: 6 })

            ForEach(this.itemsIn(g), (it: ShoppingItem) => {
              this.ItemRow(it)
            }, (it: ShoppingItem) => it.id + (it.checked ? 'c' : 'u'))
          }, (g: string) => g + this.activeList.length)

          // 手动添加
          Row({ space: 8 }) {
            TextInput({ placeholder: '要买点啥？', text: this.newName })
              .fontSize(12)
              .height(38)
              .layoutWeight(2)
              .backgroundColor($r('app.color.chip_bg'))
              .borderRadius(10)
              .onChange((v: string) => {
                this.newName = v;
              })
              .onSubmit(() => {
                this.submitManual();
              })
            TextInput({ placeholder: '量', text: this.newAmount })
              .fontSize(12)
              .height(38)
              .layoutWeight(1)
              .backgroundColor($r('app.color.chip_bg'))
              .borderRadius(10)
              .onChange((v: string) => {
                this.newAmount = v;
              })
            TextInput({ placeholder: '¥', text: this.newPrice })
              .fontSize(12)
              .height(38)
              .width(50)
              .backgroundColor($r('app.color.chip_bg'))
              .borderRadius(10)
              .type(InputType.Number)
              .onChange((v: string) => {
                this.newPrice = v;
              })
            Text(this.newCat === '其他' ? '分类' : this.newCat)
              .fontSize(11)
              .fontColor($r('app.color.primary'))
              .width(52)
              .height(38)
              .textAlign(TextAlign.Center)
              .backgroundColor($r('app.color.primary_tint'))
              .borderRadius(10)
              .onClick(() => {
                this.showCatPicker = true;
              })
              // bindSheet 挂在触发节点上：同一节点链多个 bindSheet 只有最后一个生效，
              // 根节点上还挂着改价格弹层，分类选择必须挪到这里（PlanPage 挑菜同理）
              .bindSheet(this.showCatPicker, this.CatPickerBuilder(), {
                height: 320,
                showClose: true,
                backgroundColor: $r('app.color.bg_cream'),
                onDisappear: (): void => {
                  this.showCatPicker = false;
                }
              })
            Text('加')
              .fontSize(13)
              .fontColor(Color.White)
              .width(44)
              .height(38)
              .textAlign(TextAlign.Center)
              .backgroundColor($r('app.color.primary'))
              .borderRadius(10)
              .onClick(() => {
                this.submitManual();
              })
          }
          .width('100%')
          .margin({ top: 14 })

          // 家里已有
          if (this.stockList.length > 0) {
            SectionHeader({ title: '🏠 家里已有', more: this.stockList.length + ' 项 · 不会重复买' })
            ForEach(this.stockList, (it: ShoppingItem) => {
              Row({ space: 10 }) {
                Text('🏠').fontSize(14)
                Text(it.name)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .layoutWeight(1)
                Text('要买 →')
                  .fontSize(10)
                  .fontColor($r('app.color.primary'))
                  .onClick(() => {
                    Actions.setInStock(this.ad, it, false);
                  })
                Text('✕')
                  .fontSize(11)
                  .fontColor($r('app.color.text_hint'))
                  .padding(4)
                  .onClick(() => {
                    this.deleteItem(it);
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 8, top: 8, bottom: 8 })
              .borderRadius(12)
              .backgroundColor($r('app.color.surface_soft'))
              .margin({ bottom: 5 })
            }, (it: ShoppingItem) => it.id)
          }

          // 已买到（沉底）
          if (this.checkedList.length > 0) {
            SectionHeader({ title: '✅ 已买到', more: '' })
            ForEach(this.checkedList, (it: ShoppingItem) => {
              Row({ space: 10 }) {
                Text('✓').fontSize(12).fontColor($r('app.color.green'))
                Text(it.name)
                  .fontSize(12)
                  .fontColor($r('app.color.strike'))
                  .decoration({ type: TextDecorationType.LineThrough })
                  .layoutWeight(1)
                if (it.price > 0) {
                  Text('¥' + it.price)
                    .fontSize(11)
                    .fontColor($r('app.color.text_hint'))
                    .onClick(() => {
                      this.openPriceEdit(it);
                    })
                }
                Text('↩')
                  .fontSize(12)
                  .fontColor($r('app.color.text_hint'))
                  .padding(4)
                  .onClick(() => {
                    Actions.toggleItem(this.ad, it);
                  })
                Text('✕')
                  .fontSize(11)
                  .fontColor($r('app.color.text_hint'))
                  .padding(4)
                  .onClick(() => {
                    this.deleteItem(it);
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 8, top: 8, bottom: 8 })
              .borderRadius(12)
              .backgroundColor($r('app.color.surface_soft'))
              .margin({ bottom: 5 })
            }, (it: ShoppingItem) => it.id)
          }

          // 已买历史（清空已买后归档，用于"上周刚买过"对比）
          if (this.historyList.length > 0) {
            SectionHeader({ title: '🕘 最近买过', more: '点价格可改' })
            ForEach(this.historyList, (it: ShoppingItem) => {
              Row({ space: 10 }) {
                Text(this.fmtDay(it.archivedAt))
                  .fontSize(10)
                  .fontColor($r('app.color.text_hint'))
                  .width(40)
                Text(it.name)
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .layoutWeight(1)
                Text(it.price > 0 ? '¥' + it.price : '记个价')
                  .fontSize(10)
                  .fontColor(it.price > 0 ? $r('app.color.text_secondary') : $r('app.color.primary'))
                  .onClick(() => {
                    this.openPriceEdit(it);
                  })
                Text('✕')
                  .fontSize(11)
                  .fontColor($r('app.color.text_hint'))
                  .padding(4)
                  .onClick(() => {
                    this.deleteItem(it);
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 8, top: 7, bottom: 7 })
              .borderRadius(10)
              .backgroundColor($r('app.color.surface_soft'))
              .margin({ bottom: 4 })
            }, (it: ShoppingItem) => it.id + this.version)
          }

          Column().height(24)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
      .width('100%')

      // 多选操作栏
      if (this.multiSelect) {
        Row({ space: 8 }) {
          Text('已选 ' + this.selectedIds.length)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text('放冰箱')
            .fontSize(11)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.primary'))
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(999)
            .opacity(this.selectedIds.length > 0 ? 1 : 0.4)
            .onClick(() => {
              this.batchFridge();
            })
          Text('家里有')
            .fontSize(11)
            .fontColor($r('app.color.green'))
            .backgroundColor($r('app.color.green_tint'))
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(999)
            .opacity(this.selectedIds.length > 0 ? 1 : 0.4)
            .onClick(() => {
              this.batchInStock();
            })
          Text('删除')
            .fontSize(11)
            .fontColor($r('app.color.primary_pressed'))
            .backgroundColor($r('app.color.primary_tint'))
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(999)
            .opacity(this.selectedIds.length > 0 ? 1 : 0.4)
            .onClick(() => {
              this.batchDelete();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .backgroundColor($r('app.color.surface'))
        .shadow({ radius: 12, color: '#22D6A474', offsetY: -2 })
        .transition(TransitionEffect.translate({ y: 80 }).animation({ duration: 200 }))
      }
    }
    .padding({ left: 16, right: 16 })
    .width('100%')
    .height('100%')
    .bindSheet(this.priceEdit !== null, this.PriceBuilder(), {
      height: 240,
      showClose: true,
      backgroundColor: $r('app.color.bg_cream'),
      onDisappear: (): void => {
        this.priceEdit = null;
      }
    })
  }

  // 价格编辑弹层
  @Builder
  PriceBuilder() {
    Column() {
      Text('记个价：' + (this.priceEdit === null ? '' : this.priceEdit.name))
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 14 })
      Row({ space: 10 }) {
        Text('¥')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary'))
        TextInput({ placeholder: '0.0', text: this.priceInput })
          .fontSize(16)
          .height(42)
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(12)
          .type(InputType.Number)
          .onChange((v: string) => {
            this.priceInput = v;
          })
        Text('保存')
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.primary'))
          .padding({ left: 18, right: 18, top: 10, bottom: 10 })
          .borderRadius(12)
          .onClick(() => {
            this.savePrice();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20 })
      .margin({ top: 14 })
      Text('价格只用于估算本周伙食费，随手记个大概就行')
        .fontSize(10)
        .fontColor($r('app.color.text_hint'))
        .margin({ top: 12 })
    }
    .width('100%')
  }

  @Builder
  ItemRow(it: ShoppingItem) {
    Row({ space: 10 }) {
      if (this.multiSelect) {
        // 多选模式：左侧为选择框
        Column() {
          if (this.isSelected(it.id)) {
            Text('✓').fontSize(11).fontColor(Color.White)
          }
        }
        .width(19)
        .height(19)
        .borderRadius(7)
        .borderWidth(1.5)
        .borderColor(this.isSelected(it.id) ? $r('app.color.primary') : $r('app.color.divider'))
        .backgroundColor(this.isSelected(it.id) ? $r('app.color.primary') : Color.Transparent)
      } else {
        // 普通模式：购买勾选框
        Column() {
          if (it.checked) {
            Text('✓').fontSize(11).fontColor(Color.White)
          }
        }
        .width(19)
        .height(19)
        .borderRadius(7)
        .borderWidth(1.5)
        .borderColor(it.checked ? $r('app.color.primary') : $r('app.color.divider'))
        .backgroundColor(it.checked ? $r('app.color.primary') : Color.Transparent)
        .onClick(() => {
          Actions.toggleItem(this.ad, it);
        })
      }

      Column() {
        Text(it.name)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(it.checked ? $r('app.color.strike') : $r('app.color.text_primary'))
          .decoration({ type: it.checked ? TextDecorationType.LineThrough : TextDecorationType.None })
        if (it.amount.length > 0 || it.fromRecipeName.length > 0) {
          Text((it.amount.length > 0 ? it.amount : '') +
            (it.amount.length > 0 && it.fromRecipeName.length > 0 ? ' · ' : '') +
            (it.fromRecipeName.length > 0 ? '用于：' + it.fromRecipeName : ''))
            .fontSize(9.5)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => {
        if (this.multiSelect) {
          this.toggleSelect(it.id);
        }
      })

      if (!this.multiSelect) {
        Text(it.price > 0 ? '¥' + it.price : '记价')
          .fontSize(10)
          .fontColor(it.price > 0 ? $r('app.color.green') : $r('app.color.text_hint'))
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .borderRadius(999)
          .backgroundColor(it.price > 0 ? $r('app.color.green_tint') : Color.Transparent)
          .onClick(() => {
            this.openPriceEdit(it);
          })
        Text(it.addedBy + '加的')
          .fontSize(9)
          .fontColor($r('app.color.text_hint'))
        Text('已有')
          .fontSize(10)
          .fontColor($r('app.color.green'))
          .borderWidth(1)
          .borderColor($r('app.color.green'))
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .borderRadius(999)
          .onClick(() => {
            Actions.setInStock(this.ad, it, true);
            promptAction.showToast({ message: '已标记「' + it.name + '」家里有 🏠', duration: 1200 });
          })
        Text('✕')
          .fontSize(11)
          .fontColor($r('app.color.text_hint'))
          .padding(4)
          .onClick(() => {
            this.deleteItem(it);
          })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: 10, bottom: 10 })
    .borderRadius(14)
    .backgroundColor($r('app.color.surface'))
    .margin({ bottom: 7 })
    .shadow({ radius: 8, color: '#1FD6A474', offsetY: 2 })
    .onClick(() => {
      if (this.multiSelect) {
        this.toggleSelect(it.id);
      }
    })
  }

  @Builder
  CatPickerBuilder() {
    Column() {
      Text('分类')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 14 })
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
        ForEach(GROUP_ORDER, (g: string) => {
          Text(g)
            .fontSize(13)
            .fontColor(this.newCat === g ? Color.White : $r('app.color.text_secondary'))
            .backgroundColor(this.newCat === g ? $r('app.color.primary') : $r('app.color.surface'))
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            .borderRadius(999)
            .margin(6)
            .onClick(() => {
              this.newCat = g;
              this.showCatPicker = false;
            })
        }, (g: string) => g)
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
  }
}
