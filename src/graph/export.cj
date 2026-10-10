// graph/export.cj — 图谱导出的**规范实现**（分派规则的代码级落地）。
//
// 【规范是什么】docs/graph-scene-schema.md 的 Canvas 分派规则：
//   - 运行时渲染一律走平台 Canvas 实现（macOS=SwiftUI、Linux=仓颉移植、
//     DDE=Qt/QPainter，Windows/鸿蒙排期）；
//   - HTML 只是**引擎层交付物**（只有引擎层/被 agent 驱动时消费），
//     不是任何平台的渲染路径；
//   - 平台 Canvas 的移植验收清单 = 本文件 `CANVAS2D_SUBSET`（规范的方法
//     清单从此以代码为准，文档引用它，而不是反过来）。
//
// 【为什么是代码】写在文档里的清单会漂（清单少一项，照文档移植的驱动
// 就跑不完这渲染器）；写成引擎常量后被测试钉住，文档 `引用` 它，
// 谁改清单谁就得同时改测试——规范才有约束力。
package moongit.graph

import std.collection.*
import moongit.util.*

// MARK: - 规范一：Canvas2D 方法子集（移植验收清单，唯一来源）

/// 标准 Canvas2D 的可审计子集。任何平台 Canvas 实现（SwiftUI GraphicsContext
/// 包装 / 仓颉 Canvas 移植 / Qt QPainter / Web JS 驱动）必须逐项实现这组方法，
/// 渲染器（archhtml/treehtml 的驱动）只调用这组方法。
/// ⚠️ 顺序即文档顺序：docs/graph-scene-schema.md 的清单**引用**本常量。
public let CANVAS2D_SUBSET: ArrayList<String> = ArrayList<String>([
    "setTransform", "fillRect", "beginPath", "moveTo", "lineTo", "arcTo",
    "closePath", "fill", "stroke", "rect", "strokeRect", "arc",
    "bezierCurveTo", "fillText", "createLinearGradient", "addColorStop",
    "setLineDash", "lineDashOffset",
    "shadowBlur", "shadowColor", "globalAlpha",
    "lineWidth", "strokeStyle", "fillStyle", "font", "textAlign",
])

/// 某实现声称支持的方法集是否覆盖规范子集。平台移植的**验收函数**：
/// 把实现支持的方法名传进来，缺一项就是不合规。
public func canvasSubsetCompliant(supported: ArrayList<String>): Bool {
    for (m in CANVAS2D_SUBSET) {
        if (!supported.contains(m)) { return false }
    }
    return true
}

// MARK: - 规范二：导出格式的统一枚举与分发

/// 图谱命令（arch/tree）的导出格式。**两类语义在类型层面分开**：
///   - `Html` = 引擎层交付物（只有引擎层/被 agent 驱动时消费的单文件可视化）
///   - `Scene` = 平台契约数据（有客户端实现的平台用它喂本平台 Canvas）
///   - `Text` / `Json` / `Mermaid` / `Dot` = agent 与脚本的平面出口
public enum GraphExportFormat {
    | Scene | Html | Text | Json | Mermaid | Dot
}

/// 解析 --format 的原始值。`fallback` = 未传 --format 时的默认
/// （arch/tree 的默认是 `Html`——引擎层交付物即默认出口）。
/// 未知的值返回 None，由调用方生成用法报错（列出该命令支持的集合）。
public func parseGraphFormat(v: String, fallback: GraphExportFormat): Option<GraphExportFormat> {
    let t = v.trimAscii()
    if (t.isEmpty()) { return Some(fallback) }
    match (t) {
        case "scene" => return Some(GraphExportFormat.Scene)
        case "html" => return Some(GraphExportFormat.Html)
        case "text" => return Some(GraphExportFormat.Text)
        case "json" => return Some(GraphExportFormat.Json)
        case "mermaid" => return Some(GraphExportFormat.Mermaid)
        case "dot" => return Some(GraphExportFormat.Dot)
        case _ => return None
    }
}

/// 某命令支持的格式集合的人读清单（用法报错用，顺序即文档顺序）。
public func graphFormatList(allowed: ArrayList<GraphExportFormat>): String {
    let names = ArrayList<String>()
    for (f in allowed) {
        match (f) {
            case Scene => names.add("scene")
            case Html => names.add("html")
            case Text => names.add("text")
            case Json => names.add("json")
            case Mermaid => names.add("mermaid")
            case Dot => names.add("dot")
        }
    }
    return joinStrings(names, " | ")
}
