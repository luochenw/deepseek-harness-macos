# Agent Note: 果冻海第二笔 —— 主色克制，结构性背景全部退中性

Status: implemented — 用户认可湖水青主色本身，但反馈"有点滥用了，哪里都是主色调，背景颜色太多了，不高级了"

## Problem

果冻海第一版（2026-08-17-jelly-sea-theme.md）把青色铺进了所有层级：
surfaceTint/surfaceTint2（次级按钮、徽章、面板底）、fieldStroke、
sidebarSelected、canvas 渐变全是带明显青调的色值，且每张工具卡片的
头部图标也是 accent 青。结果整屏到处是主色，主色反而失去了"贵"的
稀缺感。

## Decision

确立一条硬规则并落进 DSHTheme 的注释里：**背景只有"结构"和"状态"
两种身份——结构一律中性（白/灰的半透明 wash，无可感知青调），青色
只允许出现在承载状态的地方**（主按钮 wash、运行/选中指示、accent
徽章、语义色）。具体：

- surfaceTint / surfaceTint2 / fieldStroke：浅色模式从青色 wash 换成
  深灰绿 @ 极低 alpha（渲染成中性浅灰），深色模式一律白 @ 低 alpha。
- canvas 与 canvasGradient：压到"若有若无"——只在窗口最底透出一丝
  水色，果冻感改由半透明层叠承担，不再靠水色浓度。
- sidebarSelected 是选中状态，保留一丝 accent（alpha 0.16/0.13），
  是中性区里唯一带色的背景。
- accentWash/accentSoft 改成"accent 色相 @ 低 alpha"的统一写法，
  warm/coral 的 soft 底同步；色块更干净且叠加行为可预测。
- 工具卡片头部图标、终端卡 "$" 提示符从 accent 降为 inkSoft/inkFaint
  ——它们是结构装饰，不是状态，且在会话流里一屏重复几十次，是
  "哪里都是主色"的另一大来源。"展开 N 行"按钮保留 accent（可点的
  操作 affordance）。

## Alternatives considered

- **只调低青色背景的 alpha、不改色相**：更淡的青还是青，大面积重复
  之下依旧是"整屏主色"，解决不了稀缺感问题；中性化才是根治。
- **把 accent 前景（图标/链接）也全部中性化**：过头了——用户明确
  说主色本身是满意的；把可交互 affordance 和状态色也拔掉会让界面
  失去层次和品牌感。只拔"重复出现的纯装饰"。
- **砍掉渐变回平色 canvas**：渐变留着——它是果冻海的"海面"，压淡
  之后不参与"太多背景色"的问题。

## Consequences

- DSHBadge 的 neutral 徽章、次级按钮从淡青块变成中性浅灰块。
- 今后新增视图的判断标准写在 DSHTheme 表面区注释里：背景是结构就用
  中性 token，是状态才允许 accent 家族。
