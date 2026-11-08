// 设置页：成员/黑名单/推荐参数/转盘自定义/类型开关/清单偏好与周预算/饭点提醒/数据导入导出
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { AppData } from '../data/AppData';
import { Db } from '../data/Db';
import { ReminderService } from '../service/ReminderService';
import { PushService } from '../sync/PushService';
import { AiService } from '../service/AiService';
import { DISH_CATEGORIES, DEFAULT_ENABLED_TYPES, Recipe, MealEntry, ShoppingItem, FridgeItem } from '../model/Models';
import { authentication } from '@kit.AccountKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SectionHeader } from '../common/Widgets';

@Entry
@Component
struct SettingsPage {
  @State version: number = 0;
  @State newBlackWord: string = '';
  @State editingMember: string = '';
  @State loginState: string = ''; // idle / logging / ok / fail
  @State loginMsg: string = '';
  @State restoring: boolean = false;
  @State restoreMsg: string = '';
  @State aiInfo: string = '';
  // 显示镜像：ad.settings 是非观察对象，直接绑定不会刷新，需同步到 @State
  @State repeatDaysV: number = 3;
  @State maxDurationV: number = 0;
  @State wheelDiffV: number = 0;
  @State budgetV: number = 0;
  @State lunchTimeV: string = '11:30';
  @State dinnerTimeV: string = '17:30';
  private ad: AppData = AppData.getInstance();

  aboutToAppear(): void {
    AiService.info().then((s: string): void => {
      this.aiInfo = s;
      this.version++;
    });
    this.repeatDaysV = this.ad.settings.repeatDays;
    this.maxDurationV = this.ad.settings.maxDuration;
    this.wheelDiffV = this.ad.settings.wheelLimitMaxDiff;
    this.budgetV = this.ad.settings.weeklyBudget;
    this.lunchTimeV = this.ad.settings.lunchTime;
    this.dinnerTimeV = this.ad.settings.dinnerTime;
    // 登录态从持久化的 currentUid 回填（loginState 是页面局部状态，进页需恢复）
    if (this.ad.settings.currentUid.length > 0) {
      this.loginState = 'ok';
      const bound = this.ad.settings.uidName.get(this.ad.settings.currentUid);
      this.loginMsg = '身份：' + (bound !== undefined && bound.length > 0 ? bound : this.ad.settings.currentMember);
    }
  }

  save(): void {
    this.ad.saveSettings();
    this.version++;
    this.repeatDaysV = this.ad.settings.repeatDays;
    this.maxDurationV = this.ad.settings.maxDuration;
    this.wheelDiffV = this.ad.settings.wheelLimitMaxDiff;
    this.budgetV = this.ad.settings.weeklyBudget;
    this.lunchTimeV = this.ad.settings.lunchTime;
    this.dinnerTimeV = this.ad.settings.dinnerTime;
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
        Text('设置')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')

      Scroll() {
        Column() {
          // 华为账号登录
          SectionHeader({ title: '华为账号', more: '同一账号身份永久不变' })
          Row() {
            Column() {
              Text(this.loginState === 'ok' ? '✅ 已绑定华为账号' : '未绑定')
                .fontSize(13)
                .fontColor(this.loginState === 'ok' ? $r('app.color.green') : $r('app.color.text_primary'))
              Text(this.loginMsg.length > 0 ? this.loginMsg : '绑定后点菜自动署名，换手机身份不丢')
                .fontSize(10)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 3 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button(this.loginState === 'logging' ? '授权中…'
              : (this.loginState === 'ok' ? '重新绑定' : '华为账号登录'))
              .fontSize(12)
              .fontColor(Color.White)
              .backgroundColor($r('app.color.primary'))
              .height(34)
              .borderRadius(999)
              .padding({ left: 14, right: 14 })
              .onClick(() => {
                this.loginHuaweiId();
              })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })

          // 我是谁
          SectionHeader({ title: '我是谁', more: '' })
          Row({ space: 8 }) {
            ForEach(this.ad.settings.members, (m: string) => {
              Text(m)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.ad.settings.currentMember === m ? Color.White : $r('app.color.text_secondary'))
                .backgroundColor(this.ad.settings.currentMember === m ? $r('app.color.primary') : $r('app.color.surface'))
                .padding({ left: 20, right: 20, top: 9, bottom: 9 })
                .borderRadius(999)
                .onClick(() => {
                  this.ad.settings.currentMember = m;
                  this.save();
                })
            }, (m: string) => m + this.version)
            Blank()
            Text('改名')
              .fontSize(11)
              .fontColor($r('app.color.primary'))
              .onClick(() => {
                this.editingMember = this.ad.settings.currentMember;
                this.save();
                promptAction.showToast({ message: '点下面的名字输入新名字', duration: 1500 });
              })
          }
          .width('100%')
          Text('点当前名字可改名：')
            .fontSize(10)
            .fontColor($r('app.color.text_hint'))
            .width('100%')
            .margin({ top: 8 })
          TextInput({ placeholder: '新称呼', text: this.editingMember })
            .fontSize(12)
            .height(36)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(10)
            .margin({ top: 4 })
            .onChange((v: string) => {
              const old = this.ad.settings.currentMember;
              const idx = this.ad.settings.members.indexOf(old);
              if (idx >= 0 && v.trim().length > 0) {
                this.ad.settings.members[idx] = v.trim();
                this.ad.settings.currentMember = v.trim();
                const bl = this.ad.settings.blacklists.get(old);
                if (bl !== undefined) {
                  this.ad.settings.blacklists.delete(old);
                  this.ad.settings.blacklists.set(v.trim(), bl);
                }
              }
              this.editingMember = v;
            })
            .onSubmit((): void => {
              this.save();
              promptAction.showToast({ message: '已改名 ✅', duration: 1200 });
            })

          // 口味黑名单
          SectionHeader({ title: '我不爱吃的', more: '点词删除' })
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.ad.memberBlacklist(this.ad.settings.currentMember), (w: string) => {
              Text(w + ' ✕')
                .fontSize(12)
                .fontColor($r('app.color.primary_pressed'))
                .backgroundColor($r('app.color.primary_tint'))
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .borderRadius(999)
                .margin(4)
                .onClick(() => {
                  const bl = this.ad.memberBlacklist(this.ad.settings.currentMember);
                  const idx = bl.indexOf(w);
                  if (idx >= 0) {
                    bl.splice(idx, 1);
                    this.ad.settings.blacklists.set(this.ad.settings.currentMember, bl);
                    this.save();
                  }
                })
            }, (w: string) => w + this.version)
          }
          .width('100%')
          Row({ space: 8 }) {
            TextInput({ placeholder: '如：香菜、动物内脏、折耳根', text: this.newBlackWord })
              .fontSize(12)
              .height(38)
              .layoutWeight(1)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(10)
              .onChange((v: string) => {
                this.newBlackWord = v;
              })
              .onSubmit(() => {
                this.addBlack();
              })
            Text('加入')
              .fontSize(12)
              .fontColor(Color.White)
              .backgroundColor($r('app.color.primary'))
              .padding({ left: 16, right: 16, top: 9, bottom: 9 })
              .borderRadius(10)
              .onClick(() => {
                this.addBlack();
              })
          }
          .width('100%')
          .margin({ top: 6 })

          // 推荐参数
          SectionHeader({ title: '推荐参数', more: '' })
          Row() {
            Text('几天内吃过的不再推荐')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Row({ space: 10 }) {
              Text('−')
                .fontSize(14)
                .width(28)
                .height(28)
                .textAlign(TextAlign.Center)
                .backgroundColor($r('app.color.surface'))
                .borderRadius(14)
                .onClick(() => {
                  if (this.ad.settings.repeatDays > 0) {
                    this.ad.settings.repeatDays--;
                    this.save();
                  }
                })
              Text(this.repeatDaysV + ' 天')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('＋')
                .fontSize(13)
                .width(28)
                .height(28)
                .textAlign(TextAlign.Center)
                .backgroundColor($r('app.color.surface'))
                .borderRadius(14)
                .onClick(() => {
                  if (this.ad.settings.repeatDays < 14) {
                    this.ad.settings.repeatDays++;
                    this.save();
                  }
                })
            }
          }
          .width('100%')

          Row() {
            Text('推荐最长烹饪时长')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Row({ space: 10 }) {
              Text('−')
                .fontSize(14)
                .width(28)
                .height(28)
                .textAlign(TextAlign.Center)
                .backgroundColor($r('app.color.surface'))
                .borderRadius(14)
                .onClick(() => {
                  if (this.ad.settings.maxDuration > 0) {
                    this.ad.settings.maxDuration = Math.max(0, this.ad.settings.maxDuration - 15);
                    this.save();
                  }
                })
              Text(this.maxDurationV === 0 ? '不限' : this.maxDurationV + ' 分钟')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.maxDurationV === 0 ? $r('app.color.text_secondary') : $r('app.color.primary'))
              Text('＋')
                .fontSize(13)
                .width(28)
                .height(28)
                .textAlign(TextAlign.Center)
                .backgroundColor($r('app.color.surface'))
                .borderRadius(14)
                .onClick(() => {
                  if (this.ad.settings.maxDuration < 120) {
                    this.ad.settings.maxDuration = this.ad.settings.maxDuration === 0 ?
                      30 : Math.min(120, this.ad.settings.maxDuration + 15);
                    this.save();
                  }
                })
            }
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })

          // 转盘自定义（对照表 #9 P1）
          SectionHeader({ title: '转盘自定义', more: '只影响美食转盘' })
          Row() {
            Text('限定类型')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
            Blank()
          }
          .width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            Text('不限')
              .fontSize(12)
              .fontColor(this.ad.settings.wheelLimitCategory === '' ? Color.White : $r('app.color.text_secondary'))
              .backgroundColor(this.ad.settings.wheelLimitCategory === '' ? $r('app.color.primary') : $r('app.color.surface'))
              .padding({ left: 13, right: 13, top: 7, bottom: 7 })
              .borderRadius(999)
              .margin(4)
              .onClick(() => {
                this.ad.settings.wheelLimitCategory = '';
                this.save();
              })
            ForEach(DISH_CATEGORIES, (c: string) => {
              Text(c)
                .fontSize(12)
                .fontColor(this.ad.settings.wheelLimitCategory === c ? Color.White : $r('app.color.text_secondary'))
                .backgroundColor(this.ad.settings.wheelLimitCategory === c ? $r('app.color.primary') : $r('app.color.surface'))
                .padding({ left: 13, right: 13, top: 7, bottom: 7 })
                .borderRadius(999)
                .margin(4)
                .onClick(() => {
                  this.ad.settings.wheelLimitCategory =
                    this.ad.settings.wheelLimitCategory === c ? '' : c;
                  this.save();
                })
            }, (c: string) => c + this.version)
          }
          .width('100%')
          Row() {
            Text('难度上限')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Row({ space: 10 }) {
              Text('−')
                .fontSize(14)
                .width(28)
                .height(28)
                .textAlign(TextAlign.Center)
                .backgroundColor($r('app.color.surface'))
                .borderRadius(14)
                .onClick(() => {
                  if (this.ad.settings.wheelLimitMaxDiff > 0) {
                    this.ad.settings.wheelLimitMaxDiff--;
                    this.save();
                  }
                })
              Text(this.wheelDiffV === 0 ? '不限' : '★' + this.wheelDiffV)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.wheelDiffV === 0 ?
                $r('app.color.text_secondary') : $r('app.color.primary'))
              Text('＋')
                .fontSize(13)
                .width(28)
                .height(28)
                .textAlign(TextAlign.Center)
                .backgroundColor($r('app.color.surface'))
                .borderRadius(14)
                .onClick(() => {
                  if (this.ad.settings.wheelLimitMaxDiff < 5) {
                    this.ad.settings.wheelLimitMaxDiff++;
                    this.save();
                  }
                })
            }
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })

          // 启用类型
          SectionHeader({ title: '推荐包含的类型', more: '' })
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(DISH_CATEGORIES, (c: string) => {
              Text(c)
                .fontSize(12)
                .fontColor(this.ad.settings.enabledTypes.includes(c) ? Color.White : $r('app.color.text_hint'))
                .backgroundColor(
                  this.ad.settings.enabledTypes.includes(c) ? $r('app.color.green') : $r('app.color.surface'))
                .padding({ left: 13, right: 13, top: 7, bottom: 7 })
                .borderRadius(999)
                .margin(4)
                .onClick(() => {
                  const list = this.ad.settings.enabledTypes;
                  const idx = list.indexOf(c);
                  if (idx >= 0) {
                    list.splice(idx, 1);
                  } else {
                    list.push(c);
                  }
                  this.save();
                })
            }, (c: string) => c + this.ad.settings.enabledTypes.length)
          }
          .width('100%')

          // 清单偏好 + 周预算
          SectionHeader({ title: '买菜清单偏好', more: '' })
          Row() {
            Column() {
              Text('调味料默认标记家里已有')
                .fontSize(13)
                .fontColor($r('app.color.text_primary'))
              Text('生成清单时，盐油料酒等调味料自动归入"家里已有"')
                .fontSize(10)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.ad.settings.condimentAutoStock })
              .selectedColor($r('app.color.primary'))
              .onChange((on: boolean) => {
                this.ad.settings.condimentAutoStock = on;
                this.save();
              })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })

          // 周预算（对照表 #10/#15 P2）
          Row() {
            Text('每周买菜预算')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Row({ space: 10 }) {
              Text('−')
                .fontSize(14)
                .width(28)
                .height(28)
                .textAlign(TextAlign.Center)
                .backgroundColor($r('app.color.surface'))
                .borderRadius(14)
                .onClick(() => {
                  if (this.ad.settings.weeklyBudget > 0) {
                    this.ad.settings.weeklyBudget = Math.max(0, this.ad.settings.weeklyBudget - 50);
                    this.save();
                  }
                })
              Text(this.budgetV === 0 ? '不限' : '¥' + this.budgetV)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.budgetV === 0 ?
                $r('app.color.text_secondary') : $r('app.color.primary'))
              Text('＋')
                .fontSize(13)
                .width(28)
                .height(28)
                .textAlign(TextAlign.Center)
                .backgroundColor($r('app.color.surface'))
                .borderRadius(14)
                .onClick(() => {
                  this.ad.settings.weeklyBudget = Math.min(2000, this.ad.settings.weeklyBudget + 50);
                  this.save();
                })
            }
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          Text('在买菜清单里随手记价格，快超预算时会提醒你')
            .fontSize(10)
            .fontColor($r('app.color.text_hint'))
            .width('100%')

          // 饭点提醒
          SectionHeader({ title: '饭点提醒', more: '点时间可改' })
          Row() {
            Text('午饭提醒')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Text(this.lunchTimeV)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.primary'))
              .backgroundColor($r('app.color.primary_tint'))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(10)
              .onClick(() => {
                this.pickTime('lunch');
              })
            Toggle({ type: ToggleType.Switch, isOn: this.ad.settings.lunchRemind })
              .selectedColor($r('app.color.primary'))
              .margin({ left: 10 })
              .onChange((on: boolean) => {
                this.ad.settings.lunchRemind = on;
                this.save();
                ReminderService.refresh(this.ad).then((msg: string): void => {
                  if (msg.length > 0) {
                    promptAction.showToast({ message: msg, duration: 2000 });
                  }
                });
              })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          Row() {
            Text('晚饭提醒')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Text(this.dinnerTimeV)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.primary'))
              .backgroundColor($r('app.color.primary_tint'))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(10)
              .onClick(() => {
                this.pickTime('dinner');
              })
            Toggle({ type: ToggleType.Switch, isOn: this.ad.settings.dinnerRemind })
              .selectedColor($r('app.color.primary'))
              .margin({ left: 10 })
              .onChange((on: boolean) => {
                this.ad.settings.dinnerRemind = on;
                this.save();
                ReminderService.refresh(this.ad).then((msg: string): void => {
                  if (msg.length > 0) {
                    promptAction.showToast({ message: msg, duration: 2000 });
                  }
                });
              })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          Text('提醒走系统通知，华为运动健康开启同步后手环/手表也会震动。')
            .fontSize(10)
            .fontColor($r('app.color.text_hint'))
            .width('100%')

          // 对方点菜推送（华为 Push Kit，App 未启动也送达）
          SectionHeader({ title: '对方点菜推送', more: '跨设备' })
          Row() {
            Text('TA把菜加入计划时通知我')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.ad.settings.planPush })
              .selectedColor($r('app.color.primary'))
              .margin({ left: 10 })
              .onChange((on: boolean) => {
                this.ad.settings.planPush = on;
                this.save();
                PushService.reRegister().then((ok: boolean): void => {
                  promptAction.showToast({
                    message: ok ? (on ? '已开启 ✅ 对方点菜会推送提醒' : '已关闭') : '推送状态同步失败，稍后重试',
                    duration: 1800
                  });
                });
              })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          Text('即使 App 没打开也能收到（需两台手机都升级，且系统允许本应用通知）。')
            .fontSize(10)
            .fontColor($r('app.color.text_hint'))
            .width('100%')

          // AI 助手（DeepSeek，白名单动作 + 月度限额）
          SectionHeader({ title: 'AI 助手', more: 'LLM 增强功能' })
          Column() {
            Row() {
              Text('走 AI：加菜一键填充 · 食材替换；走本地（零 token）：问AI助手 · 清冰箱匹配')
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
            }
            .width('100%')
            Text('Key 只保存在自家服务器。限额：本月 30 次 / 15 万 tokens，超限自动恢复本地逻辑，下月 1 日重置。')
              .fontSize(10)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .margin({ top: 4 })
            if (this.aiInfo.length > 0) {
              Text('当前：' + this.aiInfo)
                .fontSize(10)
                .fontColor($r('app.color.primary'))
                .width('100%')
                .margin({ top: 4 })
            }
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })

          // 数据
          SectionHeader({ title: '数据', more: '' })
          Row() {
            Text('菜谱库')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Text(this.ad.recipes.length + ' 道 · 记录 ' + this.ad.entries.length + ' 条')
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          Text('导出全部数据（JSON 备份）')
            .fontSize(13)
            .fontColor($r('app.color.primary'))
            .width('100%')
            .padding({ top: 8, bottom: 8 })
            .onClick(() => {
              this.exportData();
            })
          Text('恢复缺失的数据（从最近一次备份，不覆盖已有）')
            .fontSize(13)
            .fontColor($r('app.color.primary'))
            .width('100%')
            .padding({ top: 8, bottom: 8 })
            .onClick(() => {
              this.confirmRestore();
            })
          if (this.restoreMsg.length > 0) {
            Text(this.restoreMsg)
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          Text('恢复缺失的种子菜谱（不覆盖已有）')
            .fontSize(13)
            .fontColor($r('app.color.primary'))
            .width('100%')
            .padding({ top: 8, bottom: 8 })
            .onClick(() => {
              promptAction.showToast({ message: '种子库导入只在首次安装自动执行；误删的菜去菜谱页手动补录', duration: 2500 });
            })

          Text('今晚吃啥 v1.1 · 本地版（HttpSync 双机同步 + AI 助手）')
            .fontSize(10)
            .fontColor($r('app.color.text_hint'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 24 })
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

  // 调整饭点时间（对照表 #6：固定饭点可改）
  pickTime(kind: string): void {
    const cur = kind === 'lunch' ? this.ad.settings.lunchTime : this.ad.settings.dinnerTime;
    const parts = cur.split(':');
    const sel = new Date();
    sel.setHours(parts.length === 2 && !isNaN(Number(parts[0])) ? Number(parts[0]) : 12,
      parts.length === 2 && !isNaN(Number(parts[1])) ? Number(parts[1]) : 0, 0, 0);
    TimePickerDialog.show({
      selected: sel,
      useMilitaryTime: true,
      onAccept: (value: TimePickerResult): void => {
        const h = value.hour;
        const m = value.minute;
        const hm = (h < 10 ? '0' + h : '' + h) + ':' + (m < 10 ? '0' + m : '' + m);
        if (kind === 'lunch') {
          this.ad.settings.lunchTime = hm;
        } else {
          this.ad.settings.dinnerTime = hm;
        }
        this.save();
        ReminderService.refresh(this.ad).then((msg: string): void => {
          if (msg.length > 0) {
            promptAction.showToast({ message: msg, duration: 2200 });
          }
        });
      }
    });
  }

  loginHuaweiId(): void {
    if (this.loginState === 'logging') {
      return;
    }
    this.loginState = 'logging';
    this.loginMsg = '';
    try {
      // Request 对象必须经 HuaweiIDProvider 工厂创建：直接 new 会得到
      // "Constructor is false" 错误（SDK 限制，见官方文档示例）
      const provider = new authentication.HuaweiIDProvider();
      const request = provider.createAuthorizationWithHuaweiIDRequest();
      request.scopes = ['openid'];
      request.permissions = [];
      request.state = util.generateRandomUUID();
      // 拉起华为授权页必须携带 context，缺省在真机上会崩溃（AccountKit 内部空指针）
      const controller = new authentication.AuthenticationController(
        getContext(this) as common.UIAbilityContext);
      controller.executeRequest(request).then((resp: authentication.AuthenticationResponse) => {
        const respData = resp as authentication.AuthorizationWithHuaweiIDResponse;
        const cred = respData.data;
        if (cred === undefined || cred.openID === undefined || cred.openID.length === 0) {
          this.loginState = 'fail';
          this.loginMsg = '未获取到身份，请重试';
          return;
        }
        // 绑定 openID -> 当前称呼
        const uid = cred.openID;
        const name = this.ad.settings.currentMember;
        this.ad.settings.uidName.set(uid, name);
        this.ad.settings.currentUid = uid;
        this.ad.saveSettings();
        this.loginState = 'ok';
        this.loginMsg = '身份：' + name;
        promptAction.showToast({ message: '华为账号绑定成功 ✅', duration: 1500 });
      }).catch((e: object): void => {
        this.loginState = 'fail';
        this.loginMsg = SettingsPage.authErrorText(e);
        hilog.warn(0x0000, 'Settings', 'login fail: %{public}s', SettingsPage.authErrorText(e));
      });
    } catch (e) {
      // SDK 同步抛错（如设备不支持）也要兜住，避免闪退
      this.loginState = 'fail';
      this.loginMsg = SettingsPage.authErrorText(e);
      hilog.warn(0x0000, 'Settings', 'login sync throw');
    }
  }

  // 把 AccountKit 错误码翻译成用户能看懂、也方便排查的提示
  static authErrorText(e: object): string {
    const err = e as BusinessError;
    const code = err === undefined || err === null ? 0 : err.code;
    const msg = err === undefined || err === null || err.message === undefined ? '' : String(err.message);
    // "Constructor is false"：AGC 未开通账号服务 / 签名 Profile 未包含该服务能力
    if (msg.includes('Constructor') || code === 1001500001) {
      return '未开通华为账号服务：请在 AGC「API管理」开通「账号服务」后重新签名安装';
    }
    switch (code) {
      case 1001500003:
        return '登录失败：不支持的授权范围（scopes 配置有误）';
      case 401:
        return '登录失败：参数错误（请升级版本后重试）';
      default:
        break;
    }
    return msg.length > 0 ? '登录失败：' + msg + '（' + code + '）' : '登录失败（错误码 ' + code + '）';
  }

  addBlack(): void {
    const w = this.newBlackWord.trim();
    if (w.length === 0) {
      return;
    }
    const m = this.ad.settings.currentMember;
    const bl = this.ad.memberBlacklist(m);
    if (!bl.includes(w)) {
      bl.push(w);
      this.ad.settings.blacklists.set(m, bl);
      this.save();
    }
    this.newBlackWord = '';
  }

  exportData(): void {
    const data: Record<string, object> = {
      'recipes': this.ad.recipes as object,
      'entries': this.ad.entries as object,
      'items': this.ad.items as object,
      'fridge': this.ad.fridge as object
    };
    const text = JSON.stringify(data);
    try {
      const path = getContext(this).filesDir + '/export_' + Date.now() + '.json';
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      fileIo.writeSync(f.fd, text);
      fileIo.closeSync(f.fd);
      promptAction.showToast({ message: '已导出到应用目录 export_*.json', duration: 2500 });
    } catch (e) {
      promptAction.showToast({ message: '导出失败', duration: 1500 });
    }
  }

  // ---------- 数据恢复：从最近的备份补回缺失的行（不覆盖已有） ----------
  confirmRestore(): void {
    AlertDialog.show({
      title: '从备份恢复？',
      message: '会读取应用目录里最近一次 export_*.json，把备份中有而当前没有的菜谱/记录/清单/冰箱项补回来，已有的不覆盖。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '先不了',
        action: (): void => {}
      },
      secondaryButton: {
        value: '开始恢复',
        fontColor: $r('app.color.primary'),
        action: (): void => {
          this.restoreData();
        }
      }
    });
  }

  async restoreData(): Promise<void> {
    if (this.restoring) {
      return;
    }
    this.restoring = true;
    this.restoreMsg = '';
    try {
      const dir = getContext(this).filesDir;
      const names: string[] = fileIo.listFileSync(dir);
      let latest = '';
      let latestM = 0;
      for (let i = 0; i < names.length; i++) {
        const n = names[i];
        if (n.startsWith('export_') && n.endsWith('.json')) {
          try {
            const m = fileIo.statSync(dir + '/' + n).mtime;
            if (m > latestM) {
              latestM = m;
              latest = n;
            }
          } catch (e) {
            // 跳过坏文件
          }
        }
      }
      if (latest.length === 0) {
        promptAction.showToast({ message: '没找到备份，先导出一次', duration: 2000 });
        this.restoring = false;
        return;
      }
      const text = fileIo.readTextSync(dir + '/' + latest);
      const data = JSON.parse(text) as Record<string, Object>;
      let rN = 0;
      let eN = 0;
      let iN = 0;
      let fN = 0;
      // 菜谱
      const recipes = data['recipes'] as Object[] ?? [];
      for (let i = 0; i < recipes.length; i++) {
        const r = this.parseRecipe(recipes[i] as Record<string, Object>);
        if (r !== null && this.ad.recipeById(r.id) === null) {
          await Db.insertRecipe(r);
          rN++;
        }
      }
      // 记录
      const entries = data['entries'] as Object[] ?? [];
      for (let i = 0; i < entries.length; i++) {
        const e = this.parseEntry(entries[i] as Record<string, Object>);
        if (e !== null && await Db.getEntryById(e.id) === null) {
          await Db.insertEntry(e);
          eN++;
        }
      }
      // 清单
      const items = data['items'] as Object[] ?? [];
      for (let i = 0; i < items.length; i++) {
        const it = this.parseItem(items[i] as Record<string, Object>);
        if (it !== null && await Db.getItemById(it.id) === null) {
          await Db.insertItem(it);
          iN++;
        }
      }
      // 冰箱
      const fridge = data['fridge'] as Object[] ?? [];
      for (let i = 0; i < fridge.length; i++) {
        const f = this.parseFridge(fridge[i] as Record<string, Object>);
        if (f !== null && await Db.getFridgeById(f.id) === null) {
          await Db.insertFridge(f);
          fN++;
        }
      }
      await this.ad.reloadAll();
      this.restoreMsg = '已从 ' + latest.substring(0, 24) + '… 恢复：菜谱 ' + rN +
        '、记录 ' + eN + '、清单 ' + iN + '、冰箱 ' + fN;
      promptAction.showToast({ message: '恢复完成 ✅', duration: 2000 });
    } catch (e) {
      promptAction.showToast({ message: '恢复失败：备份文件可能损坏', duration: 2200 });
      this.restoreMsg = '恢复失败';
    }
    this.restoring = false;
    this.version++;
  }

  private jStr(o: Record<string, Object> | null, k: string, def: string): string {
    if (o === null) {
      return def;
    }
    const v = o[k];
    return v === undefined || v === null ? def : String(v);
  }

  private jNum(o: Record<string, Object> | null, k: string, def: number): number {
    if (o === null) {
      return def;
    }
    const v = o[k];
    if (typeof v === 'number') {
      return v as number;
    }
    if (typeof v === 'string') {
      const n = Number(v);
      return isNaN(n) ? def : n;
    }
    return def;
  }

  private jBool(o: Record<string, Object> | null, k: string, def: boolean): boolean {
    if (o === null) {
      return def;
    }
    const v = o[k];
    return typeof v === 'boolean' ? v as boolean : def;
  }

  private parseRecipe(o: Record<string, Object>): Recipe | null {
    const id = this.jStr(o, 'id', '');
    const name = this.jStr(o, 'name', '');
    if (id.length === 0 || name.length === 0) {
      return null;
    }
    const r = new Recipe();
    r.id = id;
    r.name = name;
    r.emoji = this.jStr(o, 'emoji', '🍽️');
    r.cuisine = this.jStr(o, 'cuisine', '家常菜');
    r.taste = this.jStr(o, 'taste', '咸鲜');
    r.category = this.jStr(o, 'category', '荤菜');
    r.type = this.jStr(o, 'type', '荤');
    r.isQuick = this.jBool(o, 'isQuick', false);
    r.durationMin = this.jNum(o, 'durationMin', -1);
    r.difficulty = this.jNum(o, 'difficulty', 0);
    r.calories = this.jNum(o, 'calories', 0);
    r.protein = this.jNum(o, 'protein', 0);
    r.fat = this.jNum(o, 'fat', 0);
    r.carbs = this.jNum(o, 'carbs', 0);
    r.ingredients = this.jStr(o, 'ingredients', '[]').length > 0 ?
      Db.parseIngredients(this.jStr(o, 'ingredients', '[]')) : [];
    r.steps = Db.parseStringArr(this.jStr(o, 'steps', '[]'));
    r.tips = Db.parseStringArr(this.jStr(o, 'tips', '[]'));
    r.collections = Db.parseStringArr(this.jStr(o, 'collections', '[]'));
    r.favorite = this.jBool(o, 'favorite', false);
    r.enabled = this.jBool(o, 'enabled', true);
    r.source = this.jStr(o, 'source', '');
    r.createdBy = this.jStr(o, 'createdBy', '');
    r.createdAt = this.jNum(o, 'createdAt', 0);
    r.dislike = this.jBool(o, 'dislike', false);
    return r;
  }

  private parseEntry(o: Record<string, Object>): MealEntry | null {
    const id = this.jStr(o, 'id', '');
    if (id.length === 0) {
      return null;
    }
    const e = new MealEntry();
    e.id = id;
    e.date = this.jStr(o, 'date', '');
    e.mealType = this.jStr(o, 'mealType', 'dinner');
    e.recipeId = this.jStr(o, 'recipeId', '');
    e.dishName = this.jStr(o, 'dishName', '');
    e.emoji = this.jStr(o, 'emoji', '🍽️');
    e.pickedBy = this.jStr(o, 'pickedBy', '');
    e.status = this.jStr(o, 'status', 'planned');
    e.rating = this.jNum(o, 'rating', 0);
    e.mood = this.jStr(o, 'mood', '');
    e.note = this.jStr(o, 'note', '');
    e.photoPath = this.jStr(o, 'photoPath', '');
    e.source = this.jStr(o, 'source', 'manual');
    e.createdAt = this.jNum(o, 'createdAt', 0);
    return e.date.length > 0 ? e : null;
  }

  private parseItem(o: Record<string, Object>): ShoppingItem | null {
    const id = this.jStr(o, 'id', '');
    const name = this.jStr(o, 'name', '');
    if (id.length === 0 || name.length === 0) {
      return null;
    }
    const it = new ShoppingItem();
    it.id = id;
    it.name = name;
    it.amount = this.jStr(o, 'amount', '');
    it.category = this.jStr(o, 'category', '其他');
    it.checked = this.jBool(o, 'checked', false);
    it.inStock = this.jBool(o, 'inStock', false);
    it.addedBy = this.jStr(o, 'addedBy', '');
    it.fromRecipeId = this.jStr(o, 'fromRecipeId', '');
    it.fromRecipeName = this.jStr(o, 'fromRecipeName', '');
    it.price = this.jNum(o, 'price', 0);
    it.createdAt = this.jNum(o, 'createdAt', 0);
    it.archivedAt = this.jNum(o, 'archivedAt', 0);
    return it;
  }

  private parseFridge(o: Record<string, Object>): FridgeItem | null {
    const id = this.jStr(o, 'id', '');
    const name = this.jStr(o, 'name', '');
    if (id.length === 0 || name.length === 0) {
      return null;
    }
    const f = new FridgeItem();
    f.id = id;
    f.name = name;
    f.amount = this.jStr(o, 'amount', '');
    f.category = this.jStr(o, 'category', '其他');
    f.expiryDate = this.jStr(o, 'expiryDate', '');
    f.addedAt = this.jNum(o, 'addedAt', 0);
    return f;
  }
}
