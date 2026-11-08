// 通用 UI 小组件（前端视觉设计.md 组件规格）
import { AppData, EVT_ACH } from '../data/AppData';
import { AchievementEngine } from '../service/AchievementEngine';

// 口味/属性标签 chip
@Builder
export function Chip(text: string, kind: string) {
  Text(text)
    .fontSize(10)
    .fontColor(kind === 'red' ? $r('app.color.primary_pressed') :
      kind === 'green' ? $r('app.color.green') : $r('app.color.text_secondary'))
    .backgroundColor(kind === 'red' ? $r('app.color.primary_tint') :
      kind === 'green' ? $r('app.color.green_tint') : $r('app.color.chip_bg'))
    .padding({ left: 9, right: 9, top: 3, bottom: 3 })
    .borderRadius(999)
}

// 分区标题（@Component 形式：@Builder 按值传参不响应状态变化，动态计数会停留旧值）
@Component
export struct SectionHeader {
  @Prop title: string = '';
  @Prop more: string = '';

  build() {
    Row() {
      Text(this.title)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      if (this.more.length > 0) {
        Text(this.more)
          .fontSize(10)
          .fontColor($r('app.color.text_hint'))
          .margin({ left: 6 })
      }
    }
    .width('100%')
    .margin({ top: 16, bottom: 8 })
  }
}

@Builder
export function EmptyState(emoji: string, line1: string, line2: string) {
  Column() {
    Text(emoji).fontSize(48)
    Text(line1)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .margin({ top: 12 })
    if (line2.length > 0) {
      Text(line2)
        .fontSize(11)
        .fontColor($r('app.color.text_hint'))
        .margin({ top: 4 })
    }
  }
  .width('100%')
  .padding({ top: 60, bottom: 60 })
}

// 主按钮（一屏一个）
@Component
export struct PrimaryButton {
  text: string = '确认';
  active: boolean = true;
  onTap: () => void = () => {};
  @State pressed: boolean = false;

  build() {
    Text(this.text)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(Color.White)
      .backgroundColor(this.active ?
        (this.pressed ? $r('app.color.primary_pressed') : $r('app.color.primary')) : $r('app.color.strike'))
      .textAlign(TextAlign.Center)
      .height(44)
      .borderRadius(15)
      .width('100%')
      .shadow(this.active ? {
        radius: 14, color: '#52E85D3D', offsetY: 6
      } : { radius: 0, color: '#00000000', offsetY: 0 })
      .scale({ x: this.pressed ? 0.97 : 1, y: this.pressed ? 0.97 : 1 })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressed = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressed = false;
        }
      })
      .onClick(() => {
        if (this.active) {
          this.onTap();
        }
      })
      .animation({ duration: 150, curve: Curve.EaseOut })
  }
}

// 次按钮（描边）
@Component
export struct GhostButton {
  text: string = '取消';
  onTap: () => void = () => {};

  build() {
    Text(this.text)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.primary'))
      .backgroundColor($r('app.color.surface'))
      .borderWidth(1.5)
      .borderColor($r('app.color.primary_border'))
      .textAlign(TextAlign.Center)
      .height(44)
      .borderRadius(15)
      .width('100%')
      .onClick(() => {
        this.onTap();
      })
  }
}

// 星级展示/编辑
@Component
export struct Stars {
  @Link rating: number;
  editable: boolean = false;
  starSize: number = 16;

  build() {
    Row({ space: 4 }) {
      ForEach([1, 2, 3, 4, 5], (n: number) => {
        Text(n <= this.rating ? '⭐' : '☆')
          .fontSize(this.starSize)
          .opacity(n <= this.rating ? 1 : 0.35)
          .onClick(() => {
            if (this.editable) {
              this.rating = n;
            }
          })
      }, (n: number) => 'star' + n)
    }
  }
}

// 成就解锁贴纸弹窗
@CustomDialog
struct AchDialog {
  controller: CustomDialogController;
  icon: string = '🏆';
  name: string = '';
  desc: string = '';

  build() {
    Column() {
      Column() {
        Text(this.icon)
          .fontSize(52)
          .rotate({ angle: -8 })
        Text('成就解锁！')
          .fontSize(11)
          .fontColor($r('app.color.primary'))
          .fontWeight(FontWeight.Medium)
          .margin({ top: 10 })
        Text(this.name)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ top: 4 })
        Text(this.desc)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 6 })
        Text('贴纸已贴上成就墙 🎉')
          .fontSize(10)
          .fontColor($r('app.color.text_hint'))
          .margin({ top: 12 })
      }
      .padding(28)
      .borderRadius(24)
      .backgroundColor($r('app.color.surface'))
      .shadow({ radius: 30, color: '#33E85D3D', offsetY: 10 })
    }
    .width('78%')
    .onClick(() => {
      this.controller.close();
    })
  }
}

// 成就弹窗宿主：挂在任何页面根部，轮询 pendingAchPopup
@Component
export struct AchPopupHost {
  @State show: boolean = false;
  @State icon: string = '';
  @State name: string = '';
  @State desc: string = '';
  private ad: AppData = AppData.getInstance();
  dialog: CustomDialogController = new CustomDialogController({
    builder: AchDialog({ icon: '', name: '', desc: '' }),
    autoCancel: true,
    customStyle: true
  });

  aboutToAppear(): void {
    const self = this;
    this.ad.register((evt: number): void => {
      if (evt === EVT_ACH) {
        self.drain();
      }
    });
    this.drain();
  }

  private drain(): void {
    if (this.show) {
      return;
    }
    if (this.ad.pendingAchPopup.length === 0) {
      return;
    }
    const id = this.ad.pendingAchPopup.shift();
    const defs = AchievementEngine.catalog();
    for (let i = 0; i < defs.length; i++) {
      if (defs[i].id === id) {
        this.icon = defs[i].icon;
        this.name = defs[i].name;
        this.desc = defs[i].desc;
        break;
      }
    }
    this.show = true;
    const self = this;
    // 每次重建 controller 以带上最新数据
    this.dialog = new CustomDialogController({
      builder: AchDialog({
        icon: this.icon,
        name: this.name,
        desc: this.desc
      }),
      autoCancel: true,
      customStyle: true
    });
    this.dialog.open();
    setTimeout((): void => {
      // 3.2 秒后自动收起并继续弹下一个
      self.dialog.close();
      self.show = false;
      setTimeout((): void => {
        self.drain();
      }, 200);
    }, 3200);
  }

  build() {
    Column().width(0).height(0)
  }
}
