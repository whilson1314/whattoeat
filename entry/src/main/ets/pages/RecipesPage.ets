// 「菜谱」页：搜索（菜名+食材）+ 筛选 + 收藏分组 + 2列网格
import { router } from '@kit.ArkUI';
import { AppData, EVT_RECIPES } from '../data/AppData';
import { Recipe } from '../model/Models';
import { Chip } from '../common/Widgets';

@Component
export struct RecipesPage {
  @State searchText: string = '';
  @State filterKind: string = '全部';
  @State cuisineFilter: string = '';
  @State groupFilter: string = '';
  @State version: number = 0;
  private ad: AppData = AppData.getInstance();
  private listener: ((evt: number) => void) | null = null;
  private filterKinds: string[] = ['全部', '收藏', '辣', '清淡', '快手'];

  aboutToAppear(): void {
    const self = this;
    this.listener = (evt: number): void => {
      if (evt === EVT_RECIPES) {
        self.version++;
      }
    };
    this.ad.register(this.listener);
  }

  aboutToDisappear(): void {
    if (this.listener !== null) {
      this.ad.unregister(this.listener);
    }
  }

  filtered(): Recipe[] {
    const kw = this.searchText.trim();
    const out: Recipe[] = [];
    for (let i = 0; i < this.ad.recipes.length; i++) {
      const r = this.ad.recipes[i];
      if (this.cuisineFilter.length > 0 && r.cuisine !== this.cuisineFilter) {
        continue;
      }
      if (this.filterKind === '收藏' && !r.favorite) {
        continue;
      }
      // 收藏分组过滤（对照表：收藏自定义分组 P1）
      if (this.groupFilter.length > 0 && !r.collections.includes(this.groupFilter)) {
        continue;
      }
      if (this.filterKind === '辣' && !(r.taste === '辣' || r.taste === '酸辣' || r.taste === '香辣' || r.taste === '鱼香')) {
        continue;
      }
      if (this.filterKind === '清淡' && r.taste !== '清淡' && r.taste !== '咸鲜') {
        continue;
      }
      if (this.filterKind === '快手' && !r.isQuick) {
        continue;
      }
      if (kw.length > 0) {
        let hit = r.name.includes(kw);
        if (!hit) {
          for (let k = 0; k < r.ingredients.length; k++) {
            if (r.ingredients[k].name.includes(kw)) {
              hit = true;
              break;
            }
          }
        }
        if (!hit) {
          continue;
        }
      }
      out.push(r);
    }
    out.sort((a: Recipe, b: Recipe): number => {
      if (a.favorite !== b.favorite) {
        return a.favorite ? -1 : 1;
      }
      if (a.enabled !== b.enabled) {
        return a.enabled ? -1 : 1;
      }
      return a.name.localeCompare(b.name, 'zh');
    });
    return out;
  }

  cuisines(): string[] {
    const set: Set<string> = new Set();
    for (let i = 0; i < this.ad.recipes.length; i++) {
      set.add(this.ad.recipes[i].cuisine);
    }
    return Array.from(set);
  }

  // 全库出现过的收藏分组
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

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
      // 头部
      Row() {
        Text('菜谱库')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(this.ad.recipes.length + ' 道')
          .fontSize(11)
          .fontColor($r('app.color.text_hint'))
          .margin({ left: 8, top: 6 })
        Blank()
        Text('⚙️')
          .fontSize(18)
          .padding(4)
          .onClick(() => {
            router.pushUrl({ url: 'pages/SettingsPage' });
          })
      }
      .width('100%')
      .margin({ top: 8 })

      // 搜索
      Row({ space: 6 }) {
        Text('🔍').fontSize(13)
        TextInput({ placeholder: '搜菜名或食材，如：鸡蛋', text: this.searchText })
          .fontSize(13)
          .height(38)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.searchText = v;
          })
        if (this.searchText.length > 0) {
          Text('✕')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .padding(6)
            .onClick(() => {
              this.searchText = '';
            })
        }
      }
      .width('100%')
      .padding({ left: 14, right: 8 })
      .height(44)
      .borderRadius(999)
      .backgroundColor($r('app.color.surface'))
      .margin({ top: 10 })
      .shadow({ radius: 10, color: '#21D6A474', offsetY: 3 })

      // 类型筛选
      Row({ space: 7 }) {
        ForEach(this.filterKinds, (k: string) => {
          Text(k)
            .fontSize(11)
            .fontColor(this.filterKind === k ? $r('app.color.bg_cream') : $r('app.color.text_secondary'))
            .backgroundColor(this.filterKind === k ? $r('app.color.text_primary') : $r('app.color.surface'))
            .padding({ left: 13, right: 13, top: 6, bottom: 6 })
            .borderRadius(999)
            .onClick(() => {
              this.filterKind = k;
              if (k !== '收藏') {
                this.groupFilter = '';
              }
            })
        }, (k: string) => k)
      }
      .width('100%')
      .margin({ top: 10 })

      // 收藏分组过滤（收藏标签选中时出现）
      if (this.filterKind === '收藏' && this.knownGroups().length > 0) {
        Scroll() {
          Row({ space: 7 }) {
            Text('全部分组')
              .fontSize(11)
              .fontColor(this.groupFilter === '' ? $r('app.color.green') : $r('app.color.text_hint'))
              .backgroundColor(this.groupFilter === '' ? $r('app.color.green_tint') : $r('app.color.surface'))
              .padding({ left: 11, right: 11, top: 5, bottom: 5 })
              .borderRadius(999)
            ForEach(this.knownGroups(), (g: string) => {
              Text(g)
                .fontSize(11)
                .fontColor(this.groupFilter === g ? $r('app.color.green') : $r('app.color.text_hint'))
                .backgroundColor(this.groupFilter === g ? $r('app.color.green_tint') : $r('app.color.surface'))
                .padding({ left: 11, right: 11, top: 5, bottom: 5 })
                .borderRadius(999)
                .onClick(() => {
                  this.groupFilter = this.groupFilter === g ? '' : g;
                })
            }, (g: string) => g + this.version)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .margin({ top: 8 })
      }

      // 菜系横滚
      Scroll() {
        Row({ space: 7 }) {
          Text('不限菜系')
            .fontSize(11)
            .fontColor(this.cuisineFilter === '' ? $r('app.color.primary_pressed') : $r('app.color.text_hint'))
            .backgroundColor(this.cuisineFilter === '' ? $r('app.color.primary_tint') : $r('app.color.surface'))
            .padding({ left: 11, right: 11, top: 5, bottom: 5 })
            .borderRadius(999)
          ForEach(this.cuisines(), (c: string) => {
            Text(c)
              .fontSize(11)
              .fontColor(this.cuisineFilter === c ? $r('app.color.primary_pressed') : $r('app.color.text_hint'))
              .backgroundColor(this.cuisineFilter === c ? $r('app.color.primary_tint') : $r('app.color.surface'))
              .padding({ left: 11, right: 11, top: 5, bottom: 5 })
              .borderRadius(999)
              .onClick(() => {
                this.cuisineFilter = this.cuisineFilter === c ? '' : c;
              })
          }, (c: string) => c)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ top: 8 })

      // 网格
      if (this.filtered().length === 0) {
        Column() {
          Text('🍳').fontSize(44)
          Text(this.searchText.length > 0 ? '没找到含「' + this.searchText + '」的菜' : '还没有菜')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 10 })
          Text('点右下角 + 添加你们爱吃的菜')
            .fontSize(10)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 4 })
        }
        .width('100%')
        .padding({ top: 60 })
      } else {
        Grid() {
          ForEach(this.filtered(), (r: Recipe) => {
            GridItem() {
              Column() {
                Stack({ alignContent: Alignment.TopEnd }) {
                  Text(r.emoji)
                    .fontSize(32)
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .padding({ top: 10 })
                  if (r.favorite) {
                    Text('❤️').fontSize(12).margin(8)
                  }
                  if (!r.enabled) {
                    Column() {
                      Text('已停用').fontSize(9).fontColor(Color.White)
                    }
                    .backgroundColor('#99000000')
                    .borderRadius(18)
                    .width('100%')
                    .height('100%')
                    .justifyContent(FlexAlign.Center)
                  }
                }
                .width('100%')

                Text(r.name)
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 6 })
                  .padding({ left: 4, right: 4 })
                Text((['甜品', '饮品', '酱料', '半成品', '早餐'].includes(r.category) ? r.category : r.cuisine)
                  + ' · ' + r.taste + (r.durationMin > 0 ? ' · ' + r.durationMin + 'min' : ''))
                  .fontSize(9.5)
                  .fontColor($r('app.color.text_hint'))
                  .maxLines(1)
                  .margin({ top: 3, bottom: 10 })
              }
              .width('100%')
              .borderRadius(18)
              .backgroundColor($r('app.color.surface'))
              .shadow({ radius: 10, color: '#21D6A474', offsetY: 3 })
              .onClick(() => {
                router.pushUrl({ url: 'pages/RecipeDetailPage', params: { id: r.id } });
              })
              .gesture(LongPressGesture().onAction(() => {
                router.pushUrl({ url: 'pages/RecipeEditPage', params: { id: r.id } });
              }))
            }
          }, (r: Recipe) => r.id + (this.version > 0 ? '_v' + this.version : '') + (r.favorite ? '_f' : ''))
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(10)
        .rowsGap(10)
        .width('100%')
        .layoutWeight(1)
        .margin({ top: 10 })
        .padding({ bottom: 20 })
      }
    }
      .padding({ left: 16, right: 16 })
      .width('100%')
      .height('100%')

      // 浮动新增按钮
      Column() {
        Text('＋')
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
      }
      .width(52)
      .height(52)
      .borderRadius(26)
      .backgroundColor($r('app.color.primary'))
      .justifyContent(FlexAlign.Center)
      .shadow({ radius: 14, color: '#52E85D3D', offsetY: 6 })
      .margin({ right: 18, bottom: 28 })
      .onClick(() => {
        router.pushUrl({ url: 'pages/RecipeEditPage', params: { id: '' } });
      })
    }
    .width('100%')
    .height('100%')
  }
}
