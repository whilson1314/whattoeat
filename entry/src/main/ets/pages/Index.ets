// 主框架：5 Tab + 成就弹窗宿主 + 首次成员选择
import { AppData, EVT_SETTINGS } from '../data/AppData';
import { AchPopupHost } from '../common/Widgets';
import { TodayPage } from './TodayPage';
import { RecipesPage } from './RecipesPage';
import { PlanPage } from './PlanPage';
import { ShoppingPage } from './ShoppingPage';
import { RecordsPage } from './RecordsPage';

@Entry
@Component
struct Index {
  @State cur: number = 0;
  @State showMemberDialog: boolean = false;
  @State members: string[] = ['我', 'TA'];
  private ad: AppData = AppData.getInstance();

  aboutToAppear(): void {
    const launchTab = AppStorage.get<number>('launchTab');
    if (launchTab !== undefined && launchTab >= 0 && launchTab <= 4) {
      this.cur = launchTab;
      AppStorage.setOrCreate('launchTab', -1);
    }
    this.members = this.ad.settings.members.slice();
    const self = this;
    this.ad.register((evt: number): void => {
      if (evt === EVT_SETTINGS) {
        self.members = self.ad.settings.members.slice();
      }
    });
    // 未选过成员则弹首次选择
    const chosen = this.ad.settings.currentMember;
    if (chosen === undefined || chosen.length === 0) {
      this.showMemberDialog = true;
    }
  }

  @Builder
  TabBarItem(idx: number, icon: string, label: string) {
    Column() {
      Text(icon)
        .fontSize(17)
        .padding({ left: 16, right: 16, top: 4, bottom: 2 })
        .backgroundColor(this.cur === idx ? $r('app.color.primary_tint') : Color.Transparent)
        .borderRadius(11)
      Text(label)
        .fontSize(10)
        .fontWeight(this.cur === idx ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.cur === idx ? $r('app.color.primary') : $r('app.color.text_hint'))
        .margin({ top: 1 })
    }
    .width('100%')
  }

  build() {
    Stack() {
      Column() {
        Tabs({ index: this.cur, barPosition: BarPosition.End }) {
          TabContent() {
            TodayPage()
          }
          .tabBar(this.TabBarItem(0, '🔥', '今天'))

          TabContent() {
            RecipesPage()
          }
          .tabBar(this.TabBarItem(1, '📖', '菜谱'))

          TabContent() {
            PlanPage()
          }
          .tabBar(this.TabBarItem(2, '📅', '计划'))

          TabContent() {
            ShoppingPage()
          }
          .tabBar(this.TabBarItem(3, '🛒', '买菜'))

          TabContent() {
            RecordsPage()
          }
          .tabBar(this.TabBarItem(4, '📸', '记录'))
        }
        .barMode(BarMode.Fixed)
        .scrollable(false)
        .onChange((idx: number) => {
          this.cur = idx;
        })
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')

      AchPopupHost()

      if (this.showMemberDialog) {
        Column() {
          Column() {
            Text('👋 开饭啦')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text('你是家里哪位？（可以稍后在设置里改名）')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 8 })
            Row({ space: 12 }) {
              ForEach(this.members, (m: string) => {
                Text(m)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.primary'))
                  .backgroundColor($r('app.color.primary_tint'))
                  .padding({ left: 28, right: 28, top: 12, bottom: 12 })
                  .borderRadius(15)
                  .onClick(() => {
                    this.ad.settings.currentMember = m;
                    this.ad.saveSettings();
                    this.showMemberDialog = false;
                  })
              }, (m: string) => m)
            }
            .margin({ top: 20 })
            .justifyContent(FlexAlign.Center)
          }
          .padding(28)
          .borderRadius(24)
          .backgroundColor($r('app.color.surface'))
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.scrim'))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_cream'))
  }
}
