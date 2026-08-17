# Agent Note: 果冻海主题 —— 透明清亮 + 恢复深色外观

Status: implemented — 用户澄清真正想要的是"果冻海"质感（透明清亮），且"可以有深色"

## Problem

上一轮（2026-08-17-fresh-light-palette.md）把 app 改成了强制浅色的
蓝白配色。用户随后澄清两点：

1. 期望的方向一直是**果冻海**——透明、清亮、有水感的湖水青，而不是
   普通的蓝白办公风；不透明的实色表面出不来这种质感。
2. "可以有深色"——之前反对的不是深色本身，而是**深色底配黑字**那种
   看不清的组合。强制浅色属于矫枉过正。

## Decision

1. **恢复深浅双外观**：撤掉 `DSHNativeApp.init` 里的 `.aqua` 强制；
   `DSHTheme.dynamic()` 回归，且升级为 RGBA 四元组——alpha 通道是
   这套主题的核心表达手段，不再是全不透明色。
2. **两套外观共用同一个"果冻"构造**：最底层是一片不透明的海水色
   canvas（浅色=浅湖水青渐变，深色=深海青渐变，经 `canvasGradient`
   铺在窗口底），其上所有表面（surface/surfaceTint/sidebar/字段/
   按钮 wash）全部是**半透明**白/青薄层，层层叠加时透出海水色，
   叠得越多颜色越深——这就是"果冻"的来源。
3. **色相从天蓝换成湖水青（turquoise）**：accent 浅色模式 #0A7E76
   （做文字/图标），深色模式换成亮水青 #6DE5D8 系；运行指示点用
   accentBright。
4. **硬规则**：深色外观下所有 ink 阶全部是浅色（米白到浅水青），
   任何深色底上不允许出现深色前景——这是用户两轮反馈的根因。
5. 主内容列不再单独铺 canvas，让根部渐变直接透上来；DetailsPanel/
   Sidebar 维持半透明 wash。

## Alternatives considered

- **NSVisualEffectView 毛玻璃（blendingMode: .behindWindow）**：真
  "透明"（透出桌面），但观感完全取决于用户桌面壁纸，果冻海的颜色
  控制不住，还引入窗口不透明度配置的复杂度。改用"窗口内渐变 +
  半透明层叠"，效果确定、可调、代码只是颜色 token。
- **保持强制浅色、只换青色系**：用户明说"可以有深色"，且深海玻璃
  本来就是果冻海在暗环境下的自然延伸。
- **材质（.ultraThinMaterial）做表面**：macOS 材质自带灰调，会把
  湖水青洗灰，且在层叠场景里模糊叠模糊性能与可读性都差；纯 alpha
  色叠加更接近"果冻"而不是"磨砂"。

## Consequences

- token 语义不变（调用方零改动），但多数表面带 alpha：新视图往
  果冻层上再叠自定义底色时要意识到会透色，深一层就多一层青。
- 新增 `canvasGradient`（LinearGradient token），窗口根部使用；
  `DSHTheme.canvas` 仍保留给 sheet 等需要不透明底的场合。
- 上一轮删除的深色 token 全部按果冻海重做，而不是恢复旧海洋值。
