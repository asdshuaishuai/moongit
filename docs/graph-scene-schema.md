# Graph Scene — 架构图数据契约（v1）与 Canvas 驱动

## 两层契约

**渲染契约 = 标准 Canvas2D API 的一个可审计子集。**
架构图渲染器（Web 驱动）对平台的全部依赖，就是 `getContext('2d')` 对象上的
这些**标准方法**——多一个私有 API 都没有：

```
setTransform  fillRect  beginPath  moveTo  lineTo  arcTo  closePath
fill  stroke  rect  strokeRect  arc  bezierCurveTo  fillText
createLinearGradient  addColorStop
setLineDash  lineDashOffset
shadowBlur  shadowColor  globalAlpha
lineWidth  strokeStyle  fillStyle  font  textAlign
```

（`strokeRect` 在册：自带 Web 驱动的 `archhtml.cj` 用它画侧栏/图例的描边。
清单少一项，照清单移植的驱动就跑不完这个渲染器。）

因此：**任何技术栈，只要它是标准 Canvas API 的移植实现**（浏览器 Canvas2D、
OffscreenCanvas、node-canvas、Skia 绑定、Qt QPainter 包装、CoreGraphics 包装……），
把它的 context 注入渲染器即可驱动整张图——交互逻辑（下钻/选中/动画时序）
与绘制完全分离，移植方零改动复用。

Web 驱动还暴露注入式入口：

```js
MoongitArch.renderTo(ctx, width, height, now)  // 往任何 Canvas2D 兼容 context 画一帧
MoongitArch.draw(now)                          // 驱动自己的画布
MoongitArch.setTheme(dark)                     // 切换主题
MoongitArch.fit()                              // 复位视口
MoongitArch.scene                              // 场景数据
```

**数据契约 = 场景 JSON（moongit-graph-scene v1）。**
`moongit graph arch --format scene` 导出引擎确定性计算的全部几何与语义：
布局坐标、分层、依赖边、命中区域、侧栏数据、动画时序——非 JS 驱动
（如 Swift/CoreGraphics）消费这份数据，用上述 Canvas 子集逐条绘制即可。

## 场景结构

```json
{
  "v": 1, "gen": "moongit-graph",
  "meta":  { "title","sub","stats","hint","root","search","fit","themeBtn",
             "panel": {...文案}, "chips": [{"layer","label","count"}],
             "warnings": {"violations","cycleEdges","violationPairs":[...],"cycleModules":[...]} },
  "themes": { "dark": {...}, "light": {...} },
  "views": {
    "<viewId>": {
      "label","parent","bounds",
      "labels":{...}, "nodeTheme":{...}, "nodeLayer":{...}, "order":{...},
      "shapes":   [ {"t":"frame|rrect|rect|text|edge", ...} ],
      "particles":[ {"p":[8 数],"n","sp","color"} ],
      "hits":     [ {"id","x","y","w","h","drill"?,"jump"?} ],
      "edgesDropped": 0
    }
  },
  "panels": { "<view>:<node>": {"title","sub","stats","langs"?,"out","in"} }
}
```

shape 类型：`frame`（层框）、`rrect`（圆角矩形）、`rect`、`text`、`edge`
（三次贝塞尔 + 渐变 + 箭头）。颜色一律 token（`cols.0`、`text`、`muted`、
`panel`、`node:<id>`、`langs.<lang>`、`#hex`），驱动绘制时按当前主题解析。
token 表即 `themes` 的键（含 `langs` 下的每种语言）—— **引擎只会发 token 表里
存在的键**；遇到不认识的 token 一律按「引擎违约」处理，不要静默回退。

### 恒发字段（截断与降级必须披露，缺键不得当作「没有」）

- `views.<viewId>.edgesDropped`：视图内边数超过上限被丢弃的条数，**恒发**（0 也发）。
- `meta.warnings`：层 4 未分层模块不参与违规判定，这里恒发违规/环的计数与
  具体模块对 —— 空也要发，否则调用方无从区分「没有违规」与「这个版本没这个字段」。
- `chips[*].count`：分层条目的**数字**字段；label 只是给读的人看的文案。
  按数量做布局/汇总一律读 count，不要从 label 里抠数字。

### panels 的两级形状

- 架构级（`arch:<模块>`）：`title / sub / stats / langs / out / in`
- 文件级（`module:<文件>`）：`title / sub / stats / out / in` —— **没有 langs**
  （文件只有一种语言，`sub` 里已经写了）

照抄文档实现驱动时注意这个差异：把 `langs` 读成数组必须允许它缺席。

## 动画（声明式）

入场（淡入+上浮，按层错峰）、边生长（dash offset）、流动粒子
（相位 `(i+1)/(n+1)`，零随机数——同一仓库两次导出逐字节一致）。

## 边界如实说

- 图形原语覆盖本图所需子集，**不是** Canvas2D 全集（如 drawImage、
  createPattern 未用；需要时按同形扩展）
- 字体渲染质量取决于驱动宿主；引擎只声明 size/weight/family 栈
- 仓颉语言暂无 tree-sitter 语法包，语法树覆盖边界见 confidence 文档

## Canvas 分派规则（平台级，2026-10-10 定稿；Web 兜底概念已废除）

**运行时渲染一律走平台 Canvas 实现，没有例外；HTML 只是引擎层的导出交付物。**

| 场景 | Canvas 实现 | 数据 |
|---|---|---|
| macOS（deepDolphin） | **SwiftUI GraphicsContext**（Swift 语言版 Canvas2D 对应物，`ArchCanvasView`） | `--format scene` |
| Linux（deepDolphin/linux，仓颉客户端） | **仓颉 Canvas 移植**（CangjieGUI 宿主，实现同一子集） | `--format scene` |
| DDE / deepin（deepDolphin/deepin，C++ 客户端） | **Qt QPainter Canvas**（C++ 实现同一子集） | `--format scene` |
| Windows / 鸿蒙 PC | **平台 Canvas 实现（排期）**——不做 Web 运行时渲染 | `--format scene` |

**HTML 导出的定位（`graph arch/tree` 默认导出，保留）**：它不是任何平台的渲染
路径，而是**引擎层交付物**——两种消费场景：① 只有引擎层、没有任何客户端的环境
（终端/CI/临时查看）；② 被其他智能体驱动时，agent 拿到的单文件可视化交付。
技术栈仍是 Web（数据 + JS 驱动单文件），但角色是「导出物」，不是某平台的渲染兜底。

分派规则的三条不变量：

1. **数据只有一个来源**：无论哪种 Canvas 或 HTML 导出，消费的都是
   moongit-graph-scene v1（或 tree/arch 内嵌的同契约 JSON）——渲染端换技术栈，
   数据零改动。
2. **平台渲染零外包**：客户端存在的地方不允许「打开浏览器看图」——平台 Canvas
   必须在应用内用本语言版 Canvas API 直接绘制。
3. **平台 Canvas 必须实现同一子集**：本文件上方列出的 Canvas2D 方法清单就是
   移植的验收清单——少实现一项，渲染器就跑不完。

## 驱动清单

| 驱动 | 状态 |
|---|---|
| Web Canvas2D（单文件 HTML，交互完整；tree 与 arch 默认导出） | ✅ |
| 任何 Canvas2D API 移植（注入 ctx） | ✅ 契约级支持 |
| macOS SwiftUI GraphicsContext（deepDolphin `ArchCanvasView`） | ✅ |
| Linux 仓颉 Canvas 移植（deepDolphin/linux，CangjieGUI 宿主） | 📌 指定实现，进行中 |
| DDE / deepin Qt QPainter Canvas（deepDolphin/deepin，C++） | 📌 指定实现，进行中 |
| Windows / 鸿蒙 PC Canvas | 排期（平台实现，不做 Web 运行时渲染） |
| SVG / PDF 静态导出 | 规划 |
| node-canvas / Skia 服务端栅格 | 规划 |
