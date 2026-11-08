// 「今天」页：推荐卡 + 转盘/盲盒/问AI助手 + 今日已点（App逻辑设计 §2）
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { AppData, EVT_ENTRIES, EVT_SETTINGS } from '../data/AppData';
import { RecommendService } from '../service/RecommendService';
import { AiService, RecommendPick, ChefInspiration } from '../service/AiService';
import { Actions, ListAddResult } from '../service/Actions';
import { Recipe, MealEntry, MOODS, todayStr, mealTypeCn } from '../model/Models';
import { SectionHeader, EmptyState, PrimaryButton, Stars } from '../common/Widgets';

// ============ 评分弹窗 ============
@CustomDialog
struct RateDialog {
  controller: CustomDialogController;
  dishName: string = '';
  onConfirm: (rating: number, mood: string, note: string, photoPath: string) => void = () => {};
  @State rating: number = 0;
  @State mood: string = '';
  @State note: string = '';
  @State photoPath: string = '';

  pickPhoto(): void {
    const picker = new photoAccessHelper.PhotoViewPicker();
    const self = this;
    picker.select({
      MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: 1
    }).then((result: photoAccessHelper.PhotoSelectResult) => {
      if (result.photoUris.length > 0) {
          const src: string = result.photoUris[0];
          try {
            const ctx = getContext(self);
            const dest: string = ctx.filesDir + '/photo_' + Date.now() + '.jpg';
            const f = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
            fileIo.copyFile(f.fd, dest).then((): void => {
              fileIo.closeSync(f.fd);
              let size = -1;
              try {
                size = fileIo.statSync(dest).size;
              } catch (e2) {
                console.error('WTE photo stat fail: ' + dest);
              }
              console.info('WTE photo copied: ' + dest + ' size=' + size);
              if (size > 0) {
                self.photoPath = dest;
              } else {
                promptAction.showToast({ message: '照片保存异常，再试一次？', duration: 1500 });
              }
            }).catch((): void => {
              fileIo.closeSync(f.fd);
              console.error('WTE photo copy fail: ' + src);
              promptAction.showToast({ message: '照片读取失败', duration: 1500 });
            });
          } catch (e) {
            promptAction.showToast({ message: '照片读取失败', duration: 1500 });
          }
      }
    }).catch((): void => {});
  }

  build() {
    Column() {
      Text('这顿吃得咋样？')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text(this.dishName)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 4 })
      Stars({ rating: this.rating, editable: true, starSize: 26 })
        .margin({ top: 14 })
      Row({ space: 8 }) {
        ForEach(MOODS, (m: string) => {
          Text(m)
            .fontSize(11)
            .fontColor(this.mood === m ? $r('app.color.green') : $r('app.color.text_secondary'))
            .backgroundColor(this.mood === m ? $r('app.color.green_tint') : $r('app.color.chip_bg'))
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(999)
            .onClick(() => {
              this.mood = this.mood === m ? '' : m;
            })
        }, (m: string) => m)
      }
      .margin({ top: 12 })
      .justifyContent(FlexAlign.Center)

      TextInput({ placeholder: '记一句：今天火候正好 / 咸了…', text: this.note })
        .fontSize(12)
        .height(38)
        .backgroundColor($r('app.color.chip_bg'))
        .borderRadius(10)
        .margin({ top: 12 })
        .onChange((v: string) => {
          this.note = v;
        })
      Row() {
        Text(this.photoPath.length > 0 ? '✅ 已选照片' : '📷 拍照留念（可选）')
          .fontSize(12)
          .fontColor(this.photoPath.length > 0 ? $r('app.color.green') : $r('app.color.primary'))
          .onClick(() => {
            this.pickPhoto();
          })
      }
      .width('100%')
      .height(36)
      .justifyContent(FlexAlign.Center)

      Row({ space: 10 }) {
        Button('先不了')
          .fontSize(13)
          .backgroundColor($r('app.color.chip_bg'))
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
          .height(40)
          .onClick(() => {
            this.controller.close();
          })
        Button('记下这顿 ✓')
          .fontSize(13)
          .backgroundColor($r('app.color.primary'))
          .layoutWeight(1)
          .height(40)
          .onClick(() => {
            this.onConfirm(this.rating, this.mood, this.note, this.photoPath);
            this.controller.close();
          })
      }
      .margin({ top: 14 })
    }
    .padding(20)
    .borderRadius(20)
    .backgroundColor($r('app.color.surface'))
    .width('88%')
  }
}

// ============ 今天页 ============
@Component
export struct TodayPage {
  @State picks: Recipe[] = [];
  @State keptNames: string[] = []; // 标记「想要」的菜名，换一批时保留
  @State mood: string = '';
  @State todayList: MealEntry[] = [];
  @State repeatDays: number = 3;
  @State avoidInfo: string = '';
  private batchSize: number = 6;
  private lastPickAt: number = 0;
  // 自动刷新最小间隔：期间同步/点菜/吃完都不重摇当前一批
  private readonly repickMinMs: number = 30 * 60 * 1000;
  @State showSheet: boolean = false;
  @State sheetKind: string = ''; // wheel / box / chef
  // 转盘
  @State wheelItems: Recipe[] = [];
  @State wheelAngle: number = 0;
  @State wheelBusy: boolean = false;
  @State wheelResult: Recipe | null = null;
  private wheelCtx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  // 盲盒
  @State boxResult: Recipe | null = null;
  @State boxRevealed: boolean = false;
  @State boxShake: boolean = false;
  @State boxAngle: number = 0;
  @State boxTheme: string = '随机'; // 随机/辣盒/快手盒/汤盒/收藏盒
  private boxThemes: string[] = ['随机', '辣盒', '快手盒', '汤盒', '收藏盒'];
  // 问AI助手
  @State chefInput: string = '';
  @State chefThinking: boolean = false;
  @State chefPicks: RecommendPick[] = [];
  @State chefEcho: string = '';
  @State chefSource: string = ''; // ai / local
  @State chefWeb: boolean = false; // 本次提问是否顺便查小红书
  @State chefNotes: ChefInspiration[] = []; // 小红书灵感卡（服务端已校验链接）
  @State xhsChip: boolean = false; // 小红书开关显隐（probe 结果镜像，静态变量不会驱动重渲染）
  // 深度链接弹层（热启动响应）
  @StorageProp('launchSheet') @Watch('onSheetLaunch') launchSheet: string = '';
  // 当前成员显示镜像（ad.settings 非观察对象，切换后需同步刷新）
  @State memberV: string = '我';
  // 评分弹窗
  @State rateTarget: MealEntry | null = null;
  private ad: AppData = AppData.getInstance();
  private listener: ((evt: number) => void) | null = null;
  private rateDialog: CustomDialogController | null = null;

  aboutToAppear(): void {
    this.refresh();
    this.rePick();
    const self = this;
    this.listener = (evt: number): void => {
      self.refresh();
      if (evt === EVT_SETTINGS) {
        // 设置是主动改动（口味/成员/类型），立刻重摇
        self.rePick();
      } else if (evt === EVT_ENTRIES && Date.now() - self.lastPickAt >= self.repickMinMs) {
        // 记录/同步变化不打断当前一批；到间隔才自动换，💚 标记的保留
        if (self.keptCount() > 0) {
          self.swapBatch(false);
        } else {
          self.rePick();
        }
      }
    };
    this.ad.register(this.listener);
    // 小红书灵感开关：主动探测一次（5 分钟缓存），结果镜像到 @State 驱动弹层重渲染
    AiService.probe().then((ok: boolean): void => {
      self.xhsChip = ok && AiService.xhsAvailable;
    });
    // 深度链接调试：--ps sheet wheel|box|chef 直接打开对应弹层
    const sheet = AppStorage.get<string>('launchSheet');
    if (sheet !== undefined && sheet.length > 0) {
      if (sheet === 'wheel') {
        this.openWheel();
      } else if (sheet === 'box') {
        this.openBox();
      } else if (sheet === 'chef') {
        this.sheetKind = 'chef';
        this.showSheet = true;
      }
      AppStorage.setOrCreate('launchSheet', '');
    }
  }

  aboutToDisappear(): void {
    if (this.listener !== null) {
      this.ad.unregister(this.listener);
    }
  }

  onSheetLaunch(): void {
    const s = this.launchSheet;
    if (s.length === 0) {
      return;
    }
    if (s === 'wheel') {
      this.openWheel();
    } else if (s === 'spin') {
      this.openWheel();
      setTimeout((): void => {
        this.spin();
      }, 300);
    } else if (s === 'box') {
      this.openBox();
    } else if (s === 'chef') {
      this.sheetKind = 'chef';
      this.showSheet = true;
    }
    AppStorage.setOrCreate('launchSheet', '');
  }

  refresh(): void {
    this.todayList = this.ad.entriesOn(todayStr());
    this.repeatDays = this.ad.settings.repeatDays;
    this.memberV = this.ad.settings.currentMember;
  }

  rePick(): void {
    const pool = RecommendService.buildPoolWithFallback(this.ad, todayStr(), this.mood);
    this.picks = RecommendService.pickBatch(this.ad, pool, this.batchSize, new Set());
    this.keptNames = [];
    this.lastPickAt = Date.now();
    this.buildAvoidInfo();
  }

  buildAvoidInfo(): void {
    let info = '';
    let hit = false;
    for (let i = 0; i < this.picks.length; i++) {
      if (RecommendService.blacklistHits(this.ad, this.picks[i]) === 1) {
        hit = true;
        break;
      }
    }
    if (hit) {
      info = '尽量避开 TA 不爱吃的口味';
    } else if (this.repeatDays > 0) {
      info = '已避开近 ' + this.repeatDays + ' 天吃过的菜';
    }
    this.avoidInfo = info;
  }

  // ---------- 想要标记 / 换一批 ----------
  isKept(name: string): boolean {
    return this.keptNames.includes(name);
  }

  keptCount(): number {
    return this.keptNames.length;
  }

  toggleKeep(name: string): void {
    if (this.isKept(name)) {
      this.keptNames = this.keptNames.filter((n: string): boolean => n !== name);
    } else {
      this.keptNames = this.keptNames.concat([name]);
    }
  }

  // 换一批：all=true 全换；否则只替换没标记「想要」的
  swapBatch(all: boolean): void {
    const pool = RecommendService.buildPoolWithFallback(this.ad, todayStr(), this.mood);
    let keepNames: string[] = [];
    if (!all) {
      for (let i = 0; i < this.picks.length; i++) {
        if (this.isKept(this.picks[i].name)) {
          keepNames.push(this.picks[i].name);
        }
      }
    }
    // 优先换上没展示过的新菜
    const exclude: Set<string> = new Set(keepNames);
    for (let i = 0; i < this.picks.length; i++) {
      exclude.add(this.picks[i].name);
    }
    const need = this.batchSize - keepNames.length;
    let fresh = RecommendService.pickBatch(this.ad, pool, need, exclude);
    if (fresh.length < need) {
      // 池子不够新菜了，允许出现未保留的旧菜
      const second: Set<string> = new Set(keepNames);
      for (let i = 0; i < fresh.length; i++) {
        second.add(fresh[i].name);
      }
      const more = RecommendService.pickBatch(this.ad, pool, need - fresh.length, second);
      fresh = fresh.concat(more);
    }
    const keptRecipes: Recipe[] = [];
    for (let i = 0; i < this.picks.length; i++) {
      if (keepNames.includes(this.picks[i].name)) {
        keptRecipes.push(this.picks[i]);
      }
    }
    this.picks = keptRecipes.concat(fresh);
    if (all) {
      this.keptNames = [];
    }
    this.lastPickAt = Date.now();
    this.buildAvoidInfo();
  }

  // 两列排布：把一批候选切成一行两张
  pickRows(): Recipe[][] {
    const rows: Recipe[][] = [];
    for (let i = 0; i < this.picks.length; i += 2) {
      const row: Recipe[] = [this.picks[i]];
      if (i + 1 < this.picks.length) {
        row.push(this.picks[i + 1]);
      }
      rows.push(row);
    }
    return rows;
  }

  async confirmPick(r: Recipe, source: string): Promise<void> {
    const mealType = new Date().getHours() < 15 ? 'lunch' : 'dinner';
    await Actions.pickDish(this.ad, r, mealType, source);
    this.showToast('已安排：' + r.name + '（' + mealTypeCn(mealType) + '）');
    this.askAddIngredients(r);
  }

  askAddIngredients(r: Recipe): void {
    AlertDialog.show({
      title: '把食材加进买菜清单？',
      message: '「' + r.name + '」的食材将按分类合并到清单（同名未勾项不会重复）',
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
          Actions.addIngredientsToList(this.ad, r).then((res: ListAddResult): void => {
            let msg = res.added > 0 ? '已加入 ' + res.added + ' 项食材 🛒' : '清单无需新增';
            if (res.skipped.length > 0) {
              msg += '（冰箱已有：' + res.skipped.join('、') + '）';
            }
            if (res.recentBought.length > 0) {
              msg += '（刚买过：' + res.recentBought.join('、') + '）';
            }
            this.showToast(msg, 2800);
          });
        }
      }
    });
  }

  showToast(msg: string, dur: number = 1800): void {
    promptAction.showToast({ message: msg, duration: dur });
  }

  openRate(e: MealEntry): void {
    this.rateTarget = e;
    const self = this;
    this.rateDialog = new CustomDialogController({
      builder: RateDialog({
        dishName: e.dishName,
        onConfirm: (rating: number, mood: string, note: string, photoPath: string): void => {
          const target = self.rateTarget;
          if (target !== null) {
            Actions.markEaten(self.ad, target, rating, mood, note, photoPath);
            self.showToast('记好啦 ✅');
          }
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.rateDialog.open();
  }

  // ---------- 转盘 ----------
  openWheel(): void {
    this.wheelItems = RecommendService.wheelCandidates(this.ad, todayStr());
    this.wheelResult = null;
    this.wheelBusy = false;
    this.sheetKind = 'wheel';
    this.showSheet = true;
  }

  drawWheel(): void {
    const w: number = 296;
    const cx: number = w / 2;
    const cy: number = w / 2;
    const r: number = w / 2 - 3;
    const n: number = Math.max(this.wheelItems.length, 1);
    const colors: string[] = ['#FDEAE3', '#FFF3D6', '#EDF3E4', '#EAF2F7'];
    for (let i = 0; i < n; i++) {
      const start = -Math.PI / 2 + i * (2 * Math.PI / n);
      const end = start + 2 * Math.PI / n;
      this.wheelCtx.beginPath();
      this.wheelCtx.moveTo(cx, cy);
      this.wheelCtx.arc(cx, cy, r, start, end);
      this.wheelCtx.closePath();
      this.wheelCtx.fillStyle = colors[i % 4];
      this.wheelCtx.fill();
      this.wheelCtx.strokeStyle = '#FFFFFF';
      this.wheelCtx.lineWidth = 2;
      this.wheelCtx.stroke();
    }
    this.wheelCtx.beginPath();
    this.wheelCtx.arc(cx, cy, r, 0, 2 * Math.PI);
    this.wheelCtx.strokeStyle = '#FFFFFF';
    this.wheelCtx.lineWidth = 5;
    this.wheelCtx.stroke();
  }

  spin(): void {
    const n = this.wheelItems.length;
    if (n < 2 || this.wheelBusy) {
      return;
    }
    this.wheelBusy = true;
    this.wheelResult = null;
    const sector = 360 / n;
    const idx = Math.floor(Math.random() * n);
    const base = (Math.floor(this.wheelAngle / 360) + 5) * 360;
    // 让选中扇区的中心正好转到正上方（指针处）：扇区角 + 盘面角 ≡ 0 (mod 360)
    const centerAngle = idx * sector + sector / 2;
    const delta = (360 - (centerAngle % 360)) % 360;
    const target = base + delta;
    this.animateWheel(target, idx);
  }

  animateWheel(target: number, idx: number): void {
    this.getUIContext().animateTo({
      duration: 3000,
      curve: Curve.EaseOut,
      onFinish: (): void => {
        this.wheelResult = this.wheelItems[idx];
        this.wheelBusy = false;
      }
    }, (): void => {
      this.wheelAngle = target;
    });
  }

  // TA 否决：把当前结果从盘面移除，重转（夫妻否决权，对照表 #9 P2）
  vetoLast(): void {
    if (this.wheelResult === null || this.wheelBusy) {
      return;
    }
    const vetoed = this.wheelResult.name;
    const rest: Recipe[] = [];
    for (let i = 0; i < this.wheelItems.length; i++) {
      if (this.wheelItems[i].name !== vetoed) {
        rest.push(this.wheelItems[i]);
      }
    }
    this.wheelItems = rest;
    this.wheelResult = null;
    this.drawWheel();
    promptAction.showToast({ message: '已否决「' + vetoed + '」，再转一次', duration: 1800 });
  }

  // ---------- 盲盒 ----------
  openBox(): void {
    this.boxResult = null;
    this.boxRevealed = false;
    this.boxShake = false;
    this.sheetKind = 'box';
    this.showSheet = true;
  }

  shakeBox(): void {
    if (this.boxShake || this.boxRevealed) {
      return;
    }
    this.boxShake = true;
    const self = this;
    this.getUIContext().animateTo({
      duration: 160,
      curve: Curve.EaseInOut,
      onFinish: (): void => {
        self.getUIContext().animateTo({
          duration: 160,
          curve: Curve.EaseInOut,
          onFinish: (): void => {
            self.getUIContext().animateTo({ duration: 160, curve: Curve.EaseInOut }, (): void => {
              self.boxAngle = 0;
            });
            setTimeout((): void => {
              self.boxResult = RecommendService.mysteryCandidate(self.ad,
                self.boxTheme === '随机' ? '' : self.boxTheme);
              self.boxRevealed = true;
              self.boxShake = false;
            }, 180);
          }
        }, (): void => {
          self.boxAngle = -10;
        });
      }
    }, (): void => {
      self.boxAngle = 10;
    });
  }

  // ---------- 问AI助手（LLM 优先，本地规则降级） ----------
  // 打开小红书笔记网页（appLinkingOnly=false：无 App Link 时回落系统浏览器）
  openInspiration(url: string): void {
    if (url.length === 0) {
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.openLink(url, { appLinkingOnly: false });
    } catch (e) {
      promptAction.showToast({ message: '打开失败，稍后再试', duration: 1800 });
    }
  }

  // 照着做：服务端已从笔记挑出具体菜名（dish）时带去 RecipeEditPage 自动 AI 填充；
  // 合集类笔记拿不到具体菜名 → 跳原文让用户自己挑，避免把模糊标题硬塞成菜名
  cookFromNote(n: ChefInspiration): void {
    if (n.dish.length === 0) {
      this.openInspiration(n.url);
      promptAction.showToast({ message: '这是合集笔记，去原文挑一道想做的吧', duration: 2200 });
      return;
    }
    this.showSheet = false;
    router.pushUrl({
      url: 'pages/RecipeEditPage',
      params: {
        'aiName': n.dish,
        'aiHint': '参考小红书笔记《' + n.title + '》里的' + n.dish + '做法'
      } as Record<string, string>
    });
  }

  async askChef(): Promise<void> {
    const q = this.chefInput.trim();
    if (q.length === 0 || this.chefThinking) {
      return;
    }
    this.chefThinking = true;
    this.chefPicks = [];
    this.chefNotes = [];
    this.chefEcho = q;
    // 今天已安排的菜让 AI/本地都避开
    const excluded: Set<string> = new Set();
    const today = this.ad.entriesOn(todayStr());
    for (let i = 0; i < today.length; i++) {
      excluded.add(today[i].dishName);
    }
    if (AiService.can('recommend')) {
      const ans = await AiService.recommend(this.ad, q, this.mood, excluded, this.chefWeb);
      if (ans !== null) {
        this.chefPicks = ans.picks;
        this.chefNotes = ans.inspirations;
        this.chefSource = 'ai';
      } else if (AiService.lastError.length > 0) {
        // 失败原因透出（限流/超时/上游异常），本地兜底照旧
        promptAction.showToast({ message: 'AI 没接上：' + AiService.lastError, duration: 3200 });
      }
    }
    if (this.chefPicks.length === 0) {
      // 本地规则推荐（白名单未含 recommend 时零 token）
      const local = RecommendService.chefLocal(this.ad, q, todayStr());
      const picks: RecommendPick[] = [];
      for (let i = 0; i < local.length; i++) {
        if (excluded.has(local[i].name)) {
          continue;
        }
        const p = new RecommendPick();
        p.recipe = local[i];
        picks.push(p);
      }
      this.chefPicks = picks;
      this.chefSource = 'local';
    }
    this.chefThinking = false;
  }

  dateLine(): string {
    const d = new Date();
    const names: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    return (d.getMonth() + 1) + '月' + d.getDate() + '日 · ' + names[d.getDay()];
  }

  memberColor(name: string): string {
    const idx = this.ad.settings.members.indexOf(name);
    return idx === 1 ? 'green' : 'red';
  }

  cycleMember(): void {
    const members = this.ad.settings.members;
    const idx = members.indexOf(this.ad.settings.currentMember);
    this.ad.settings.currentMember = members[(idx + 1) % members.length];
    this.ad.saveSettings();
    this.memberV = this.ad.settings.currentMember;
    this.rePick();
    this.showToast('现在是「' + this.ad.settings.currentMember + '」在点菜');
  }

  tasteKind(t: string): string {
    if (t === '辣' || t === '酸辣' || t === '香辣' || t === '鱼香') {
      return 'red';
    }
    if (t === '清淡') {
      return 'green';
    }
    return 'gray';
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll() {
        Column() {
          // 头部
          Row() {
            Column() {
              Text(this.dateLine())
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
              Text(new Date().getHours() < 15 ? '今天中午吃啥？🔥' : '今晚吃啥？🔥')
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .margin({ top: 3 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Row({ space: 8 }) {
              // 身份切换：点一下在成员间轮换，双色区分谁点的
              Text(this.memberV + ' 👤')
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.memberColor(this.memberV) === 'red' ?
                $r('app.color.primary_pressed') : $r('app.color.green'))
                .backgroundColor(this.memberColor(this.memberV) === 'red' ?
                $r('app.color.primary_tint') : $r('app.color.green_tint'))
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .borderRadius(999)
                .onClick(() => {
                  this.cycleMember();
                })
              Text('⚙️')
                .fontSize(20)
                .padding(6)
                .onClick(() => {
                  router.pushUrl({ url: 'pages/SettingsPage' });
                })
            }
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .margin({ top: 8 })

          // 心情选择
          Row({ space: 8 }) {
            Text('心情:')
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
            ForEach(MOODS, (m: string) => {
              Text(m)
                .fontSize(10)
                .fontColor(this.mood === m ? $r('app.color.primary_pressed') : $r('app.color.text_secondary'))
                .backgroundColor(this.mood === m ? $r('app.color.primary_tint') : $r('app.color.chip_bg'))
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .borderRadius(999)
                .onClick(() => {
                  this.mood = this.mood === m ? '' : m;
                  this.rePick();
                })
            }, (m: string) => m)
          }
          .width('100%')
          .margin({ top: 12 })

          // 推荐一批候选：点 💚 留住想要的，换一批只换没标记的
          if (this.picks.length > 0) {
            Column() {
              Row() {
                Column() {
                  Text('为你挑了 ' + this.picks.length + ' 道')
                    .fontSize(14)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.text_primary'))
                  Text(this.keptCount() > 0 ? '已留 ' + this.keptCount() + ' 道 💚，换一批只换没标记的' : '点 💚 留住想要的，换一批不换它')
                    .fontSize(10)
                    .fontColor($r('app.color.text_hint'))
                    .margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')

              ForEach(this.pickRows(), (row: Recipe[]) => {
                Row({ space: 10 }) {
                  this.PickCard(row[0])
                  if (row.length > 1) {
                    this.PickCard(row[1])
                  } else {
                    Column().layoutWeight(1)
                  }
                }
                .width('100%')
                .margin({ top: 10 })
              }, (row: Recipe[], idx: number) => {
                let key = 'row' + idx + '_';
                for (let i = 0; i < row.length; i++) {
                  key += row[i].id + (this.isKept(row[i].name) ? 'k' : '');
                }
                return key;
              })

              Row({ space: 10 }) {
                Button(this.keptCount() > 0 ? '🔄 换掉没标记的' : '🔄 换一批')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.primary'))
                  .backgroundColor($r('app.color.surface'))
                  .borderWidth(1.5)
                  .borderColor($r('app.color.primary_border'))
                  .layoutWeight(1)
                  .height(42)
                  .borderRadius(15)
                  .onClick(() => {
                    this.swapBatch(false);
                  })
                Button('全换')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_secondary'))
                  .backgroundColor($r('app.color.chip_bg'))
                  .width(76)
                  .height(42)
                  .borderRadius(15)
                  .onClick(() => {
                    this.swapBatch(true);
                  })
              }
              .margin({ top: 14 })
              .width('100%')

              if (this.avoidInfo.length > 0) {
                Text(this.avoidInfo)
                  .fontSize(10)
                  .fontColor($r('app.color.text_hint'))
                  .margin({ top: 10 })
              }
            }
            .width('100%')
            .padding(16)
            .borderRadius(20)
            .backgroundColor($r('app.color.surface'))
            .margin({ top: 12 })
            .shadow({ radius: 16, color: '#29D6A474', offsetY: 4 })
          } else {
            Column() {
              EmptyState('🧐', '菜谱库里没有能推荐的菜', '去菜谱页添加，或在设置里启用更多类型')
              PrimaryButton({
                text: '重新找找',
                active: true,
                onTap: (): void => {
                  this.rePick();
                }
              })
            }
            .width('100%')
            .padding(16)
            .borderRadius(20)
            .backgroundColor($r('app.color.surface'))
            .margin({ top: 12 })
            .shadow({ radius: 16, color: '#29D6A474', offsetY: 4 })
          }

          // 三联快捷
          Row({ space: 9 }) {
            this.QuickEntry('🎯', '转盘', (): void => {
              this.openWheel();
            })
            this.QuickEntry('🎁', '盲盒', (): void => {
              this.openBox();
            })
            this.QuickEntry('🤖', '问AI助手', (): void => {
              this.chefInput = '';
              this.chefPicks = [];
              this.chefNotes = [];
              this.chefEcho = '';
              this.sheetKind = 'chef';
              this.showSheet = true;
            })
          }
          .width('100%')
          .margin({ top: 12 })

          // 今日已点
          SectionHeader({ title: '今日已点', more: this.todayList.length + ' 道' })
          if (this.todayList.length === 0) {
            Text('还没定，从上面挑一个吧')
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 14, bottom: 14 })
          } else {
            ForEach(this.todayList, (e: MealEntry) => {
              this.TodayRow(e)
            }, (e: MealEntry) => e.id + e.status)
          }
          Column().height(30)
        }
        .padding({ left: 16, right: 16 })
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
      .width('100%')
      .height('100%')

      // 自定义半屏弹层（scrim + 底部面板）
      if (this.showSheet) {
        Column() {
          Column()
            .width('100%')
            .layoutWeight(1)
            .backgroundColor($r('app.color.scrim'))
            .onClick(() => {
              this.showSheet = false;
            })
          Column() {
            this.SheetBuilder()
          }
          .width('100%')
          .height(520)
          .backgroundColor($r('app.color.bg_cream'))
          .borderRadius({ topLeft: 24, topRight: 24 })
          .transition(TransitionEffect.translate({ y: 540 }).animation({ duration: 260, curve: Curve.EaseOut }))
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
      }
    }
    .width('100%')
    .height('100%')
  }

  // 单张候选卡：点 💚 标记想要；点菜名看详情；「就吃它」直接定这道
  @Builder
  PickCard(r: Recipe) {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        Text(r.emoji)
          .fontSize(34)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 2 })
          .onClick(() => {
            if (r.id.length > 0) {
              router.pushUrl({ url: 'pages/RecipeDetailPage', params: { id: r.id } });
            }
          })
        Text(this.isKept(r.name) ? '💚' : '🤍')
          .fontSize(17)
          .padding({ top: 6, right: 6, left: 8, bottom: 8 })
          .onClick(() => {
            this.toggleKeep(r.name);
          })
      }
      .width('100%')

      Text(r.name)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 2 })
        .padding({ left: 4, right: 4 })
        .onClick(() => {
          if (r.id.length > 0) {
            router.pushUrl({ url: 'pages/RecipeDetailPage', params: { id: r.id } });
          }
        })

      Row({ space: 4 }) {
        Text(r.taste)
          .fontSize(9)
          .fontColor(this.tasteKind(r.taste) === 'red' ? $r('app.color.primary_pressed') :
          this.tasteKind(r.taste) === 'green' ? $r('app.color.green') : $r('app.color.text_secondary'))
          .backgroundColor(this.tasteKind(r.taste) === 'red' ? $r('app.color.primary_tint') :
          this.tasteKind(r.taste) === 'green' ? $r('app.color.green_tint') : $r('app.color.chip_bg'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(999)
        Text(r.durationMin > 0 ? r.durationMin + '分钟' : '随时')
          .fontSize(9)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.chip_bg'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(999)
        if (r.isQuick) {
          Text('快手')
            .fontSize(9)
            .fontColor($r('app.color.green'))
            .backgroundColor($r('app.color.green_tint'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(999)
        }
      }
      .margin({ top: 6 })
      .justifyContent(FlexAlign.Center)

      Button(this.isKept(r.name) ? '就吃它 ✓' : '就吃它')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .height(32)
        .borderRadius(999)
        .width('100%')
        .backgroundColor(this.isKept(r.name) ? $r('app.color.primary') : $r('app.color.surface'))
        .fontColor(this.isKept(r.name) ? Color.White : $r('app.color.primary'))
        .borderWidth(1.2)
        .borderColor($r('app.color.primary_border'))
        .margin({ top: 10, bottom: 12 })
        .onClick(() => {
          this.confirmPick(r, 'manual');
        })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 8, right: 8 })
    .borderRadius(16)
    .backgroundColor(this.isKept(r.name) ? $r('app.color.primary_tint') : $r('app.color.surface'))
    .border({
      width: this.isKept(r.name) ? 1.5 : 0.5,
      color: this.isKept(r.name) ? $r('app.color.primary_border') : $r('app.color.divider')
    })
    .shadow({ radius: 8, color: '#1FD6A474', offsetY: 2 })
  }

  @Builder
  QuickEntry(icon: string, label: string, onTap: () => void) {
    Button({ type: ButtonType.Normal }) {
      Column() {
        Text(icon)
          .fontSize(21)
          .onClick(() => {
            onTap();
          })
        Text(label)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ top: 3 })
          .onClick(() => {
            onTap();
          })
      }
      .width('100%')
    }
    .layoutWeight(1)
    .height(64)
    .borderRadius(16)
    .backgroundColor($r('app.color.surface'))
    .shadow({ radius: 10, color: '#21D6A474', offsetY: 3 })
    .id('quick_' + label)
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  TodayRow(e: MealEntry) {
    Row({ space: 10 }) {
      Text(e.emoji).fontSize(19)
      Column() {
        Text(e.dishName)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .decoration({ type: e.status === 'eaten' ? TextDecorationType.LineThrough : TextDecorationType.None })
        Row({ space: 6 }) {
          Text(e.pickedBy + '点的')
            .fontSize(9)
            .fontColor(this.memberColor(e.pickedBy) === 'red' ?
            $r('app.color.primary_pressed') : $r('app.color.green'))
            .backgroundColor(this.memberColor(e.pickedBy) === 'red' ?
            $r('app.color.primary_tint') : $r('app.color.green_tint'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(999)
          Text((e.status === 'eaten' ? '吃过 · ' : '') + mealTypeCn(e.mealType))
            .fontSize(10)
            .fontColor($r('app.color.text_hint'))
          if (e.rating > 0) {
            Text('⭐' + e.rating).fontSize(10)
          }
        }
        .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (e.status === 'planned') {
        Text('✓做完了')
          .fontSize(11)
          .fontColor($r('app.color.green'))
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .borderRadius(999)
          .backgroundColor($r('app.color.green_tint'))
          .onClick(() => {
            this.openRate(e);
          })
        Text('✕')
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
          .padding(6)
          .onClick(() => {
            this.confirmDelete(e);
          })
      } else {
        Text('✓')
          .fontSize(13)
          .fontColor($r('app.color.green'))
      }
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: 10, bottom: 10 })
    .borderRadius(14)
    .backgroundColor($r('app.color.surface'))
    .margin({ bottom: 7 })
    .shadow({ radius: 8, color: '#1FD6A474', offsetY: 2 })
    .onClick(() => {
      if (e.recipeId.length > 0) {
        router.pushUrl({ url: 'pages/RecipeDetailPage', params: { id: e.recipeId } });
      }
    })
  }

  confirmDelete(e: MealEntry): void {
    AlertDialog.show({
      title: '不做了？',
      message: '「' + e.dishName + '」将从今日计划移除。' + (e.recipeId.length > 0 ? '可连带把它未采购的食材移出清单。' : ''),
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

  @Builder
  SheetBuilder() {
    if (this.sheetKind === 'wheel') {
      this.WheelSheetBuilder()
    } else if (this.sheetKind === 'box') {
      this.BoxSheetBuilder()
    } else if (this.sheetKind === 'chef') {
      this.ChefSheetBuilder()
    }
  }

  // ---------- 转盘弹层 ----------
  @Builder
  WheelPosItem(r: Recipe, i: number, n: number) {
    Text(r.emoji)
      .fontSize(22)
      // 固定在各自扇区中心，由 emoji 层整层旋转带着公转；自身反转 -盘面角 抵消旋转，始终保持正立
      .position({
        x: 148 + 118 * Math.sin((i * (360 / n) + 180 / n) * Math.PI / 180) - 14,
        y: 148 - 118 * Math.cos((i * (360 / n) + 180 / n) * Math.PI / 180) - 14
      })
      .rotate({ angle: -this.wheelAngle })
  }

  @Builder
  WheelSheetBuilder() {
    Column() {
      Text('美食转盘 🎯')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 6 })
      if (this.wheelItems.length < 2) {
        Text('菜谱太少了，先去加几道菜吧')
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
          .margin({ top: 40 })
      } else {
        Stack({ alignContent: Alignment.TopStart }) {
          // 旋转部分：扇形 Canvas 绕圆心随盘转动
          Stack() {
            Canvas(this.wheelCtx)
              .width(296)
              .height(296)
              .onReady((): void => {
                this.drawWheel();
              })
          }
          .width(296)
          .height(296)
          .rotate({ angle: this.wheelAngle })
          .clip(true)

          // emoji 层：整层随盘公转，每个 emoji 自身再反转 -盘面角 保持正立
          Stack() {
            ForEach(this.wheelItems, (r: Recipe, i: number) => {
              this.WheelPosItem(r, i, this.wheelItems.length)
            }, (r: Recipe) => r.id)
          }
          .width(296)
          .height(296)
          .rotate({ angle: this.wheelAngle })

          // 中心轴
          Column() {
            Text('🍽️').fontSize(22)
          }
          .width(58)
          .height(58)
          .borderRadius(29)
          .backgroundColor($r('app.color.surface'))
          .justifyContent(FlexAlign.Center)
          .shadow({ radius: 10, color: '#33D6A474', offsetY: 3 })
          .position({ x: 119, y: 119 })

          // 指针（固定在正上方，尖端指向圆心，只有盘转）
          Column() {
            Polygon({ width: 22, height: 16 })
              .points([[4, 0], [18, 0], [11, 16]])
              .fill($r('app.color.primary'))
              .stroke($r('app.color.primary_pressed'))
              .strokeWidth(1)
          }
          .width(30)
          .height(30)
          .borderRadius(15)
          .backgroundColor($r('app.color.surface'))
          .justifyContent(FlexAlign.Center)
          .shadow({ radius: 8, color: '#44E85D3D', offsetY: 3 })
          .position({ x: 133, y: -10 })
        }
        .width(296)
        .height(296)
        .margin({ top: 26 })

        if (this.wheelResult !== null) {
          Row({ space: 8 }) {
            Text(this.wheelResult.emoji).fontSize(18)
            Text('今晚就吃：' + this.wheelResult.name)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.primary'))
          }
          .justifyContent(FlexAlign.Center)
          .margin({ top: 12 })
          .transition(TransitionEffect.OPACITY.animation({ duration: 250 }))
        }
        Row({ space: 10 }) {
          Button(this.wheelBusy ? '转动中…' : this.wheelResult !== null ? '再转一次' : '转！')
            .fontSize(14)
            .backgroundColor(this.wheelBusy ? $r('app.color.strike') : $r('app.color.primary'))
            .layoutWeight(1)
            .height(42)
            .borderRadius(15)
            .onClick(() => {
              this.spin();
            })
          if (this.wheelResult !== null) {
            Button('TA否决 ↺')
              .fontSize(14)
              .fontColor($r('app.color.primary_pressed'))
              .backgroundColor($r('app.color.primary_tint'))
              .layoutWeight(1)
              .height(42)
              .borderRadius(15)
              .onClick(() => {
                this.vetoLast();
              })
            Button('就吃它 ✓')
              .fontSize(14)
              .fontColor($r('app.color.primary'))
              .backgroundColor($r('app.color.surface'))
              .borderWidth(1.5)
              .borderColor($r('app.color.primary_border'))
              .layoutWeight(1)
              .height(42)
              .borderRadius(15)
              .onClick(() => {
                if (this.wheelResult !== null) {
                  this.confirmPick(this.wheelResult, 'wheel');
                  this.showSheet = false;
                }
              })
          }
        }
        .margin({ top: 14, left: 20, right: 20 })
        .width('100%')
      }
      Column().height(16)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  // ---------- 盲盒弹层 ----------
  @Builder
  BoxSheetBuilder() {
    Column() {
      Text('盲盒惊喜 🎁')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 6 })
      Text('从全库随机，偏爱很久没吃的冷门菜')
        .fontSize(10)
        .fontColor($r('app.color.text_hint'))
        .margin({ top: 4 })

      // 主题盲盒（辣盒/快手盒/汤盒/收藏盒）
      Row({ space: 6 }) {
        ForEach(this.boxThemes, (t: string) => {
          Text(t)
            .fontSize(10)
            .fontColor(this.boxTheme === t ? Color.White : $r('app.color.text_secondary'))
            .backgroundColor(this.boxTheme === t ? $r('app.color.primary') : $r('app.color.surface'))
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(999)
            .onClick(() => {
              this.boxTheme = t;
              this.boxResult = null;
              this.boxRevealed = false;
              this.boxShake = false;
            })
        }, (t: string) => t)
      }
      .margin({ top: 8 })
      .justifyContent(FlexAlign.Center)

      Column() {
        if (!this.boxRevealed) {
          Text('🎁')
            .fontSize(64)
            .rotate({ angle: this.boxAngle })
            .scale({ x: this.boxShake ? 1.1 : 1, y: this.boxShake ? 1.1 : 1 })
            .onClick(() => {
              this.shakeBox();
            })
          Text(this.boxShake ? '咔哒咔哒…' : '点我拆盒')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 10 })
        } else if (this.boxResult !== null) {
          Text(this.boxResult.emoji)
            .fontSize(52)
            .transition(TransitionEffect.OPACITY.animation({ duration: 350 }))
          Text(this.boxResult.name)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .margin({ top: 6 })
            .transition(TransitionEffect.OPACITY.animation({ duration: 350 }))
          Text(this.boxResult.taste + ' · ' + this.boxResult.cuisine +
            (this.boxResult.durationMin > 0 ? ' · ' + this.boxResult.durationMin + '分钟' : ''))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 4 })
        } else {
          Text(this.boxTheme === '随机' ? '盒子是空的，去加几道菜吧' : '「' + this.boxTheme + '」里没菜可抽，换主题试试')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
        }
      }
      .width(220)
      .height(180)
      .justifyContent(FlexAlign.Center)
      .margin({ top: 18 })

      Row({ space: 10 }) {
        Button(this.boxRevealed ? '再拆一个' : '拆盒')
          .fontSize(14)
          .backgroundColor($r('app.color.primary'))
          .layoutWeight(1)
          .height(42)
          .borderRadius(15)
          .onClick(() => {
            this.openBox();
            this.shakeBox();
          })
        if (this.boxResult !== null && this.boxRevealed) {
          Button('就吃它 ✓')
            .fontSize(14)
            .fontColor($r('app.color.primary'))
            .backgroundColor($r('app.color.surface'))
            .borderWidth(1.5)
            .borderColor($r('app.color.primary_border'))
            .layoutWeight(1)
            .height(42)
            .borderRadius(15)
            .onClick(() => {
              if (this.boxResult !== null) {
                this.confirmPick(this.boxResult, 'box');
                this.showSheet = false;
              }
            })
        }
      }
      .margin({ top: 14, left: 20, right: 20 })
      .width('100%')
      Column().height(16)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  // ---------- 问AI助手弹层 ----------
  @Builder
  ChefSheetBuilder() {
    Column() {
      Text('问AI助手 🤖')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 6 })
      Text('用自己的话聊聊今晚想吃什么')
        .fontSize(10)
        .fontColor($r('app.color.text_hint'))
        .margin({ top: 4 })

      Row({ space: 8 }) {
        TextInput({ placeholder: '例如：不吃猪肉，想喝点热乎的', text: this.chefInput })
          .fontSize(13)
          .height(42)
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(15)
          .onChange((v: string) => {
            this.chefInput = v;
          })
          .onSubmit(() => {
            this.askChef();
          })
        Button('问')
          .fontSize(14)
          .backgroundColor($r('app.color.primary'))
          .width(64)
          .height(42)
          .borderRadius(15)
          .onClick(() => {
            this.askChef();
          })
      }
      .margin({ top: 12, left: 16, right: 16 })
      .width('100%')

      if (this.xhsChip) {
        Row() {
          Text(this.chefWeb ? '🔎 顺便查查小红书 ✓' : '🔎 顺便查查小红书')
            .fontSize(11)
            .fontColor(this.chefWeb ? $r('app.color.primary') : $r('app.color.text_secondary'))
            .backgroundColor(this.chefWeb ? $r('app.color.primary_tint') : $r('app.color.chip_bg'))
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(999)
            .onClick(() => {
              this.chefWeb = !this.chefWeb;
            })
        }
        .justifyContent(FlexAlign.Start)
        .width('100%')
        .margin({ top: 10, left: 16, right: 16 })
      }

      if (this.chefThinking) {
        Row({ space: 8 }) {
          Text('🤖').fontSize(18)
          Text(this.chefWeb ? 'AI 助手正在翻小红书…' : 'AI 助手想一下…')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .margin({ top: 30 })
        .justifyContent(FlexAlign.Center)
        .width('100%')
      } else if (this.chefPicks.length > 0 || this.chefNotes.length > 0) {
        if (this.chefPicks.length > 0) {
          Text('按「' + this.chefEcho + '」帮你选的：')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 14 })
          ForEach(this.chefPicks, (p: RecommendPick) => {
            Row({ space: 10 }) {
              Text(p.recipe.emoji).fontSize(22)
              Column() {
                Row({ space: 6 }) {
                  Text(p.recipe.name)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  if (p.reason.length > 0) {
                    Text(p.reason)
                      .fontSize(9)
                      .fontColor($r('app.color.primary'))
                      .backgroundColor($r('app.color.primary_tint'))
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .borderRadius(999)
                  }
                }
                Text(p.recipe.taste + ' · ' + p.recipe.cuisine + (p.recipe.durationMin > 0 ? ' · ' + p.recipe.durationMin + '分钟' : ''))
                  .fontSize(10)
                  .fontColor($r('app.color.text_hint'))
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Button('就吃它')
                .fontSize(12)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.primary'))
                .height(32)
                .borderRadius(999)
                .padding({ left: 14, right: 14 })
                .onClick(() => {
                  this.confirmPick(p.recipe, 'ai');
                  this.showSheet = false;
                })
            }
            .width('100%')
            .padding({ left: 14, right: 10, top: 11, bottom: 11 })
            .margin({ top: 8 })
            .borderRadius(14)
            .backgroundColor($r('app.color.surface'))
          }, (p: RecommendPick) => p.recipe.id)
        }
        if (this.chefNotes.length > 0) {
          Text(this.chefPicks.length > 0 ? '📕 顺便从小红书翻的灵感（点卡片看原文）' : '📕 从小红书翻的灵感（点卡片看原文）')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 14 })
          ForEach(this.chefNotes, (n: ChefInspiration) => {
            Column() {
              Row({ space: 8 }) {
                Text('📕').fontSize(18)
                Column() {
                  Text(n.title)
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text((n.author.length > 0 ? '@' + n.author : '') +
                    (n.likes.length > 0 ? (n.author.length > 0 ? ' · ' : '') + n.likes + ' 赞' : ''))
                    .fontSize(10)
                    .fontColor($r('app.color.text_hint'))
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Button(n.dish.length > 0 ? '照着做' : '看原文挑菜')
                  .fontSize(11)
                  .fontColor($r('app.color.primary'))
                  .backgroundColor($r('app.color.primary_tint'))
                  .height(30)
                  .borderRadius(999)
                  .padding({ left: 12, right: 12 })
                  .onClick(() => {
                    this.cookFromNote(n);
                  })
              }
              .width('100%')
              if (n.dish.length > 0) {
                Text('🍽️ 做这道：' + n.dish)
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.primary'))
                  .width('100%')
                  .margin({ top: 6 })
              }
              if (n.summary.length > 0) {
                Text(n.summary)
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 6 })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding({ left: 14, right: 10, top: 11, bottom: 11 })
            .margin({ top: 8 })
            .borderRadius(14)
            .backgroundColor($r('app.color.surface'))
            .onClick(() => {
              this.openInspiration(n.url);
            })
          }, (n: ChefInspiration) => n.url)
        }
        Text(this.chefNotes.length > 0 ? '🤖 AI 推荐 · 含小红书灵感，笔记内容以原文为准'
          : (this.chefSource === 'ai' ? '🤖 AI 推荐 · 由AI 助手根据你们的菜谱挑选' : '🏠 本地推荐 · 网络或 AI 未配置时按标签挑选'))
          .fontSize(9)
          .fontColor($r('app.color.text_hint'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 12 })
      } else if (this.chefEcho.length > 0) {
        Text('没想出合适的，换个说法试试？')
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
          .margin({ top: 30 })
      } else {
        Column({ space: 8 }) {
          Text('试试这样说：').fontSize(11).fontColor($r('app.color.text_hint'))
          Text('“今晚想吃点清淡的”').fontSize(12).fontColor($r('app.color.text_secondary'))
          Text('“不想吃猪肉，简单快手点的”').fontSize(12).fontColor($r('app.color.text_secondary'))
          Text('“想喝汤”').fontSize(12).fontColor($r('app.color.text_secondary'))
        }
        .margin({ top: 26 })
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      Column().height(20)
    }
    .width('100%')
  }
}
