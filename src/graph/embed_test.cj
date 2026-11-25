// graph/embed_test.cj — 嵌入模式（宿主页面内嵌）的契约。
//
// 宿主在产物任何脚本之前注入 window.MOONGIT_EMBED = { chrome: "page", vars: {…}, canvas: {…} }：
// 产物收拢外壳（宿主已有页头与状态条）、改走宿主的主题变量、画在 canvas 上的颜色与圆角跟宿主走。
// 不注入时必须与原先同形：独立打开产物的用户（CLI 渲染出来的单文件 HTML）一个像素都不该变。
package moongit.graph

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

/// 热力图产物：嵌入样式跟在主样式之后、引导脚本在 <body> 开头、画布颜色经 cv(key, 原值) 取；
/// 不注入配置时 <html> 不带 data-embed，独立打开的外壳规则原样都在。
@Test
func testIndexHtmlEmbedModeHooks(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/a.kt", "class Util {\n    fun twice(x: Int): Int {\n        return x * 2\n    }\n}\n")
        let g = buildGraph(root)
        let rep = analyzeConfidence(g, false)
        let payload = indexPayloadForStore(g, 0, rep, sourceProbeNow(root), 0, "2026-11-25T00:00:00Z", false)
        let html = renderIndexHtml(payload, None<JsonValue>, false)
        // 独立打开：没有宿主配置时引导脚本不改 DOM，<html> 上没有 data-embed
        @Assert(html.contains("<html lang=\"zh-CN\">"))
        @Assert(!html.contains("data-embed=\"page\">"))
        // 独立版外壳规则原样都在（嵌入样式只是叠加在后面，同优先级时后者胜）
        @Assert(html.contains(".topbar{height:60px"))
        @Assert(html.contains(".bottom-status{height:25px"))
        // 嵌入样式跟在主样式之后
        let mainEnd = html.indexOf("</style>").getOrThrow()
        let embedAt = html.indexOf("<style id=\"embed-style\">").getOrThrow()
        @Assert(embedAt > mainEnd)
        // 引导脚本：<body> 之后（那时 body 已存在，才写得上内联变量）、驱动脚本之前
        let bodyAt = html.indexOf("<body>").getOrThrow()
        let bootAt = html.indexOf("(function(){var e=window.MOONGIT_EMBED").getOrThrow()
        let drvAt = html.indexOf("var EMB = window.MOONGIT_EMBED").getOrThrow()
        @Assert(bootAt > bodyAt)
        @Assert(bootAt < drvAt)
        // 外壳收拢：三条横杠并成一条命令条，底部技术状态条不显示
        @Assert(html.contains("grid-template-rows:44px minmax(0,1fr)"))
        @Assert(html.contains(".bottom-status{display:none}"))
        @Assert(html.contains(".graph-overlay{display:none}"))
        @Assert(html.contains(".current-path{display:none}"))
        @Assert(html.contains(".toolbar .mode-toggle{display:none}"))
        // 画布颜色与圆角经 cv(key, 原值) 取：独立打开时回落到原值
        @Assert(html.contains("cv('bg', '#0a1017')"))
        @Assert(html.contains("cv('atmosphere', true) !== false"))
        @Assert(html.contains("cv('red', '#ff6b8a')"))
        @Assert(html.contains("cv('nodeModule', '#132134')"))
        @Assert(html.contains("cv('radius', 10)"))
        // 嵌入模式默认关掉呼吸（装饰性动效）
        @Assert(html.contains("var breathEnabled = EMB_ON ? false :"))
        // 模板版本自报（复用判定比对它）：引擎升级后输入没变的旧产物也要重画一次；
        // 更早的引擎画的产物没有这一行 ⇒ 读回 -1 ⇒ 不可复用
        @Assert(renderEmbeddedTemplate(html) == RENDER_TEMPLATE)
        @Assert(html.contains("<!-- moongit render · template=" + RENDER_TEMPLATE.toString() + " -->"))
        @Assert(renderEmbeddedTemplate("<!DOCTYPE html>\n<html><head></head><body>old</body></html>") == -1)
        // 同一份输入两次渲染逐字节一致
        @Assert(html == renderIndexHtml(payload, None<JsonValue>, false))
    } finally {
        removeTree(root)
    }
}

/// 架构图产物：同一契约——引导脚本在 <body> 开头、嵌入样式在后、调色板可被宿主覆盖、
/// 取景避开顶部命令条；不注入时与原先同形。
@Test
func testArchHtmlEmbedModeHooks(): Unit {
    let root = writeTree()
    try {
        let arch = buildArch(buildGraph(root))
        layoutArch(arch)
        let json = Json.pretty(archJson(arch, false))
        let html = renderArchHtml(json, false)
        // 独立打开：不变
        @Assert(html.contains("<html lang=\"zh-CN\" data-theme=\"dark\">"))
        @Assert(!html.contains("data-embed=\"page\">"))
        @Assert(html.contains("#bar { position:fixed; top:12px; left:12px"))
        @Assert(html.contains("class=\"sub-what\""))
        @Assert(html.contains("class=\"sub-count\""))
        // 引导脚本在 <body> 之后、驱动之前；嵌入样式跟在主样式之后
        let mainEnd = html.indexOf("</style>").getOrThrow()
        let embedAt = html.indexOf("<style id=\"embed-style\">").getOrThrow()
        @Assert(embedAt > mainEnd)
        let bodyAt = html.indexOf("<body class=\"dark\">").getOrThrow()
        let bootAt = html.indexOf("(function(){var e=window.MOONGIT_EMBED").getOrThrow()
        let drvAt = html.indexOf("var EMB = window.MOONGIT_EMBED").getOrThrow()
        @Assert(bootAt > bodyAt)
        @Assert(bootAt < drvAt)
        // 调色板 = 暗色 + 宿主覆盖；主题切换不显示；取景避开命令条
        @Assert(html.contains("return EMB_ON ? PAL.embed : (dark ? PAL.dark : PAL.light)"))
        @Assert(html.contains("html[data-embed=\"page\"] #th{display:none}"))
        @Assert(html.contains("html[data-embed=\"page\"] #bar .title{display:none}"))
        @Assert(html.contains("function embTop()"))
        @Assert(html.contains("var pl = EMB_ON ? 24 : 0, pt = embTop()"))
        @Assert(renderEmbeddedTemplate(html) == RENDER_TEMPLATE)
        @Assert(html == renderArchHtml(json, false))
    } finally {
        removeTree(root)
    }
}
