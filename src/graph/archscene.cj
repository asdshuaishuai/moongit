// archscene.cj — 语言色值表的唯一构造点（清单与色值只许写这一份）。
//
// ⚠️ 用户定稿 2026-10-27：moongit-graph-scene v1 场景出口（buildArchScene
// 及 shapes/hits/panels 装配）已整体删除——交付正身 = render 的交互 HTML，
// 客户端直接渲染文件；为原生 Canvas 驱动而生的 scene 数据契约随之退役。
// 本文件只剩三处消费方共享的调色板：
//   · archhtml.cj 的 langPaletteJs —— 架构图页内嵌驱动 JS 的 PAL.langs
//   · treehtml.cj 的 langThemesJson —— 图谱页的 langThemes.{dark,light}
// 返回顺序（swift…module）是契约的一部分：输出按此序生成，字节级稳定。

package moongit.graph

import std.collection.*
import std.convert.*
import moongit.util.*

// MARK: - 主题 token

/// 语言 → 色值表的**唯一构造点**（清单与色值只许写这一份）。
/// 三处消费方各自派生输出形态，不许再抄色值字面量（多份手抄副本必然漂移，
/// 漂移的症状是同一语言在 scene / 架构图页 / 图谱页三个画面颜色不一致）：
///   · themeJson()（本文件）—— scene 的 themes.{dark,light}.langs
///   · archhtml.cj 的 langPaletteJs —— 内嵌驱动 JS 的 PAL.{dark,light}.langs
///   · treehtml.cj 的 langThemesJson —— 图谱页的 langThemes.{dark,light}
/// 返回顺序（swift…module）是契约的一部分：三处输出按此序生成，字节级稳定。
public func langThemeColors(dark: Bool): ArrayList<(String, String)> {
    let out = ArrayList<(String, String)>()
    if (dark) {
        out.add(("swift", "#f05138"))
        out.add(("cangjie", "#f7801e"))
        out.add(("ts", "#3178c6"))
        out.add(("python", "#3572a5"))
        out.add(("go", "#00add8"))
        out.add(("rust", "#dea584"))
        out.add(("java", "#b07219"))
        out.add(("kotlin", "#a97bff"))
        out.add(("c", "#555555"))
        out.add(("module", "#94a3b8"))
    } else {
        out.add(("swift", "#f05138"))
        out.add(("cangjie", "#de6d10"))
        out.add(("ts", "#3178c6"))
        out.add(("python", "#3572a5"))
        out.add(("go", "#00869b"))
        out.add(("rust", "#b7410e"))
        out.add(("java", "#b07219"))
        out.add(("kotlin", "#7c4dff"))
        out.add(("c", "#444444"))
        out.add(("module", "#64748b"))
    }
    return out
}

/// langs 主题 token（scene 契约形态）：从 langThemeColors 派生，
/// 键序 = 构造点顺序（JObj 按插入序序列化）。
func langsTokenJson(dark: Bool): JsonValue {
    let o = Json.obj()
    for ((lang, color) in langThemeColors(dark)) {
        Json.set(o, lang, Json.of(color))
    }
    return o
}
