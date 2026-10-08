# Graph Scene — 架构图数据契约（v1）与 Canvas 驱动

## 两层契约

**渲染契约 = 标准 Canvas2D API 的一个可审计子集。**
架构图渲染器（Web 驱动）对平台的全部依赖，就是 `getContext('2d')` 对象上的
这些**标准方法**——多一个私有 API 都没有：

```
setTransform  fillRect  beginPath  moveTo  lineTo  arcTo  closePath
fill  stroke  arc  bezierCurveTo  fillText
createLinearGradient  addColorStop
setLineDash  lineDashOffset
shadowBlur  shadowColor  globalAlpha
lineWidth  strokeStyle  fillStyle  font  textAlign
```

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
             "panel": {...文案}, "chips": [{"layer","label","count"}] },
  "themes": { "dark": {...}, "light": {...} },
  "views": {
    "<viewId>": {
      "label","parent","bounds",
      "labels":{...}, "nodeTheme":{...}, "nodeLayer":{...}, "order":{...},
      "shapes":   [ {"t":"frame|rrect|rect|text|edge", ...} ],
      "particles":[ {"p":[8 数],"n","sp","color"} ],
      "hits":     [ {"id","x","y","w","h","drill"?,"jump"?} ]
    }
  },
  "panels": { "<view>:<node>": {"title","sub","stats","langs","out","in"} }
}
```

shape 类型：`frame`（层框）、`rrect`（圆角矩形）、`rect`、`text`、`edge`
（三次贝塞尔 + 渐变 + 箭头）。颜色一律 token（`cols.0`、`text`、`node:<id>`、
`#hex`），驱动绘制时按当前主题解析。

## 动画（声明式）

入场（淡入+上浮，按层错峰）、边生长（dash offset）、流动粒子
（相位 `(i+1)/(n+1)`，零随机数——同一仓库两次导出逐字节一致）。

## 边界如实说

- 图形原语覆盖本图所需子集，**不是** Canvas2D 全集（如 drawImage、
  createPattern 未用；需要时按同形扩展）
- 字体渲染质量取决于驱动宿主；引擎只声明 size/weight/family 栈
- 仓颉语言暂无 tree-sitter 语法包，语法树覆盖边界见 confidence 文档

## 驱动清单

| 驱动 | 状态 |
|---|---|
| Web Canvas2D（单文件 HTML，交互完整） | ✅ |
| 任何 Canvas2D API 移植（注入 ctx） | ✅ 契约级支持 |
| macOS CoreGraphics / Swift | 规划 |
| SVG / PDF 静态导出 | 规划 |
| node-canvas / Skia 服务端栅格 | 规划 |
