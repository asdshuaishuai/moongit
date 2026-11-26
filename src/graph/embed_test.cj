// graph/embed_test.cj — 嵌入模式（宿主页面内嵌）的契约。
//
// 宿主在产物任何脚本之前注入 window.CAMBIUM_EMBED = { chrome: "page", vars: {…}, canvas: {…} }：
// 产物收拢外壳（宿主已有页头与状态条）、改走宿主的主题变量、画在 canvas 上的颜色与圆角跟宿主走。
// 不注入时必须与原先同形：独立打开产物的用户（CLI 渲染出来的单文件 HTML）一个像素都不该变。
package cambium.graph

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.util.*

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
        let bootAt = html.indexOf("(function(){var e=window.CAMBIUM_EMBED").getOrThrow()
        let drvAt = html.indexOf("var EMB = window.CAMBIUM_EMBED").getOrThrow()
        @Assert(bootAt > bodyAt)
        @Assert(bootAt < drvAt)
        // 调色板 = 暗色 + 宿主覆盖；主题切换不显示；取景避开命令条
        @Assert(html.contains("return EMB_ON ? PAL.embed : (dark ? PAL.dark : PAL.light)"))
        @Assert(html.contains("html[data-embed=\"page\"] #th{display:none}"))
        @Assert(html.contains("html[data-embed=\"page\"] #bar .title{display:none}"))
        @Assert(html.contains("function embTop()"))
        // 尺寸融合：取景留白收紧、泳道按视口折行（几何只认 DATA.geo）、视口变化重取景、
        // 底部图例条、连线取相向的两条边
        @Assert(html.contains("var pl = EMB_ON ? 16 : 0, pt = embTop()"))
        @Assert(html.contains("function embLaneCols()"))
        @Assert(html.contains("function embReflow(c)"))
        @Assert(html.contains("if (EMB_ON && isArch()) { embReflow(embLaneCols()); }"))
        @Assert(html.contains("function ends(a, b)"))
        @Assert(html.contains("if (viewFit) { fit(); } else { keepInView(); }"))
        @Assert(html.contains("height:var(--e-foot-h,32px)"))
        @Assert(html.contains("height:var(--e-ctl-h,28px)"))
        @Assert(Json.has(archJson(arch, false), "geo"))
        @Assert(renderEmbeddedTemplate(html) == RENDER_TEMPLATE)
        @Assert(html == renderArchHtml(json, false))
    } finally {
        removeTree(root)
    }
}

/// 这个 / 是正则的起点而不是除号：前一个非空白字符是运算符 / 括号 / 逗号 / 分号 / 冒号，
/// 或是会直接接正则的关键字（return / case / typeof …）。除号前面只会是标识符、数字、) ]。
func isRegexStart(cs: Array<Rune>, i: Int64): Bool {
    var j = i - 1
    while (j >= 0 && (cs[j] == r' ' || cs[j] == r'\t')) {
        j -= 1
    }
    if (j < 0) {
        return true
    }
    let p = cs[j]
    if (p == r'(' || p == r',' || p == r'=' || p == r':' || p == r'[' || p == r'!' || p == r'&' || p == r'|' ||
        p == r'?' || p == r';' || p == r'+' || p == r'-' || p == r'*' || p == r'%' || p == r'^' || p == r'~' ||
        p == r'<' || p == r'>' || p == r'{' || p == r'}' || p == r'\n' || p == r'\r') {
        return true
    }
    var k = j
    while (k >= 0 && ((cs[k] >= r'a' && cs[k] <= r'z') || (cs[k] >= r'A' && cs[k] <= r'Z') || cs[k] == r'_')) {
        k -= 1
    }
    let sb = StringBuilder()
    var t = k + 1
    while (t <= j) {
        sb.append(cs[t])
        t += 1
    }
    let w = sb.toString()
    return w == "return" || w == "case" || w == "typeof" || w == "in" || w == "of" || w == "instanceof" ||
        w == "new" || w == "delete" || w == "void" || w == "do" || w == "else" || w == "yield" || w == "await"
}
