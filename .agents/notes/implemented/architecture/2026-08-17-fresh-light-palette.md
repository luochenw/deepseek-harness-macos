# Agent Note: 清新明亮浅色主题（取消深色外观）

Status: implemented — 同日被 2026-08-17-jelly-sea-theme.md 部分推翻：用户澄清要的是"果冻海"质感且"可以有深色"，强制浅色与蓝白色板被替换；"深色底不配深色字"的硬规则保留

## Problem

海洋主题经过两轮"调淡"后（见 2026-08-17-ocean-design-system.md 与
f64d5e3），用户仍然反馈：

1. 整体"还是太颜色了"——浅色模式下所有表面都带一层灰绿调
   （canvas/sidebar/surfaceTint 全是 G 分量偏高的暖灰绿），叠起来仍是
   "整屏都被染过色"的观感，而不是清新明亮。
2. "深色底还是黑色字"——两处来源：
   - 系统处于深色模式时整个 app 跟随成深色底，与"清新明亮"的期望相反；
   - 主按钮是中明度青绿底（light: 0.247/0.612/0.565）配近黑前景
     （accentContrast 0.043/0.129/0.122），在浅色界面里是一块
     "深色底 + 黑字"的色块。

## Decision

1. **全 app 强制浅色外观**：`DSHNativeApp.init` 里
   `NSApplication.shared.appearance = NSAppearance(named: .aqua)`，
   一行覆盖所有窗口/sheet/alert。深色模式不再出现，"深色底"从根上消失。
2. **DSHTheme 去掉 light/dark 双轨**：强制浅色后 `dynamic()` 的 dark
   三元组永远不会被解析，保留只会误导后续维护者以为深色仍在支持；
   全部 token 改为单一 `Color(red:green:blue:)` 字面量。
3. **色板从"灰绿海洋"换成"蓝白清爽"**：
   - 表面：接近纯白、只带一丝冷蓝（canvas #F8FBFD、sidebar #F3F8FB、
     tint #F1F6FA/#E7F0F6），不再有可感知的"染色"。
   - 文字：深蓝灰 #2B3A49 系，明确不是纯黑。
   - 主色：清爽天蓝家族（accent #0E6FA9 只做文字/图标色，accentBright
     #27A0DE 承载运行指示点）。
   - 语义色：warm 改亮琥珀、coral 改亮珊瑚，soft 底同步提亮。
4. 主按钮不再用色块当底（实现后用户追加反馈"按钮的颜色太深了"）：
   新增 accentWash（#CFE9F7 浅天蓝）做主按钮底色，前景用 accent 深蓝字
   ——填充控件保持浅色身体，只有文字带色。原 accentContrast token 随之
   删除（唯一使用点就是主按钮前景）。

## Alternatives considered

- **保留深色模式、只调浅色色板**：用户明确表达了"不要深色底"；而且
  双轨色板意味着每次调色都要维护一套从未被验收过的深色值，负担大于价值。
  真要恢复，git 历史里有完整双轨实现。
- **`.preferredColorScheme(.light)` 挂在 ContentView 上**：只影响主窗口，
  独立 NSAlert / 菜单等 AppKit 面板仍跟随系统深色，会出现半深半浅。
  `NSApp.appearance` 一行覆盖全部。
- **只改主按钮、不动整体色板**：解决不了"整体还是太颜色"的主诉求，
  用户已经是第三次反馈同一方向。
- **换成薄荷绿/暖米白等其他"清新"色相**：蓝白是"清新明亮"最不会跑偏的
  解，且与既有"海洋"命名延续性最好；绿色系刚被否掉两轮，不再赌。

## Consequences

- app 内不再响应系统深色模式；`DSHTheme.dynamic()` 被移除，token 全部
  是静态浅色值，后续调色只需要改一处字面量。
- `accentContrast` 被移除；accent 底色的填充控件不再存在，主按钮是
  accentWash 浅底 + accent 深蓝字。
- 附件灯箱（NativeAttachmentPreview）的黑色遮罩是照片查看器惯例，
  不属于"深色底"问题，保留不动。
