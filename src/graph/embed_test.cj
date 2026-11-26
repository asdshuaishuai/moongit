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
        // 尺寸融合：嵌入时按可用区域选列数、色带包住卡片、图例并进底条、视口变化重新取景
        // （用户手动定过视角的不抢）；独立版的取景上限与列数形状不变
        @Assert(html.contains("var EMB_FIT_CAP = EMB_ON ? 1.3 : 1.16;"))
        @Assert(html.contains("var laneAvailH = EMB_ON ? Math.max(120, (cssH - 48 - 58 * (groups.length - 1)) / groups.length) : 0;"))
        @Assert(html.contains("var cols = Math.max(1, Math.min(n, Math.ceil(Math.sqrt(n * 1.7))));"))
        @Assert(html.contains("function bandRect(i)"))
        @Assert(html.contains("if (hx1 >= hx0) { bx = hx0 - 20; bw = hx1 - hx0 + 40; }"))
        // 取景范围并入色带（绘制与取景共用 bandRect）
        @Assert(html.contains("var br = bandRect(bi);"))
        @Assert(html.contains("var pad = EMB_ON ? 24 : 36;"))
        @Assert(html.contains("if (lg0 && ft0) { ft0.appendChild(lg0); ft0.title = lg0.textContent; }"))
        // 底条横贯整宽：画布 / 侧栏 / 底条直接排进 .main 的网格，操作按钮挪到同一条的右端
        @Assert(html.contains(".main{grid-area:2/1/3/3;display:grid;grid-template-columns:minmax(0,1fr) 340px;grid-template-rows:minmax(0,1fr) var(--e-foot-h,32px)}"))
        @Assert(html.contains(".graph-area{display:contents}"))
        @Assert(html.contains(".canvas-foot{grid-area:2/1/3/3;height:var(--e-foot-h,32px)"))
        @Assert(html.contains("if (gh0 && ft0) { ft0.appendChild(gh0); }"))
        @Assert(html.contains("if (!userView) { hasFit = false; resize(); fitView(); } else { resize(); keepInView(); }"))
        @Assert(html.contains("height:var(--e-ctl-h,30px)"))
        @Assert(html.contains("border-radius:var(--e-r-ctl,4px)"))
        @Assert(html.contains("border-radius:var(--e-r-card,8px)"))
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

/// 驱动脚本的括号配平（字符串字面量、正则字面量与注释之外）。驱动 JS 是拼在仓颉字符串里的，
/// 多一个右括号编译期与仓颉单测都发现不了——只有浏览器里整段脚本不执行才暴露
/// （加「按区域选列」时手滑过一次：页面停在装载态，一张卡都没有）。
/// 这里做最小词法：跳过 '…' "…" `…` 字符串、/…/ 正则、// 与 /* */ 注释，逐字符压栈配平 () [] {}。
/// 错位探测：引号字符串里出现原始换行 = 词法已经错位，直接判失败——第一版不认正则，
/// 把 `/[&<>"']/g` 里的引号当成了字符串起点，之后括号数碰巧配平，出过一次假通过。
/// 返回第一个不配平处的下标；配平 = -1。
func jsBracketError(js: String): Int64 {
    let cs = js.toRuneArray()
    let n = cs.size
    let stack = ArrayList<Rune>()
    var i = 0
    while (i < n) {
        let c = cs[i]
        if (c == r'\'' || c == r'"' || c == r'`') {
            let q = c
            i += 1
            var closed = false
            while (i < n) {
                if (cs[i] == r'\\') {
                    i += 2
                    continue
                }
                if (cs[i] == q) {
                    closed = true
                    i += 1
                    break
                }
                if (cs[i] == r'\n' && q != r'`') {
                    return i
                }
                i += 1
            }
            if (!closed) {
                return i
            }
            continue
        }
        if (c == r'/' && i + 1 < n && cs[i + 1] == r'/') {
            while (i < n && cs[i] != r'\n') {
                i += 1
            }
            continue
        }
        if (c == r'/' && i + 1 < n && cs[i + 1] == r'*') {
            i += 2
            var closed = false
            while (i + 1 < n) {
                if (cs[i] == r'*' && cs[i + 1] == r'/') {
                    closed = true
                    i += 2
                    break
                }
                i += 1
            }
            if (!closed) {
                return i
            }
            continue
        }
        if (c == r'/' && isRegexStart(cs, i)) {
            i += 1
            var inClass = false
            var closed = false
            while (i < n) {
                let rc = cs[i]
                if (rc == r'\\') {
                    i += 2
                    continue
                }
                // 正则不跨行：碰到换行说明判错了，按除号往下走
                if (rc == r'\n') {
                    break
                }
                if (rc == r'[') {
                    inClass = true
                } else if (rc == r']') {
                    inClass = false
                } else if (rc == r'/' && !inClass) {
                    closed = true
                    i += 1
                    break
                }
                i += 1
            }
            if (closed) {
                continue
            }
        }
        if (c == r'(' || c == r'[' || c == r'{') {
            stack.add(c)
        } else if (c == r')' || c == r']' || c == r'}') {
            if (stack.size == 0) {
                return i
            }
            let o = stack[stack.size - 1]
            let bad = (c == r')' && o != r'(') || (c == r']' && o != r'[') || (c == r'}' && o != r'{')
            if (bad) {
                return i
            }
            stack.remove(at: stack.size - 1)
        }
        i += 1
    }
    return if (stack.size == 0) { -1 } else { n }
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

/// 从驱动脚本的起始标记（必须是脚本的第一个字符）取到它所在的 </script>（不含）。
func driverScriptOf(html: String, marker: String): String {
    let from = html.indexOf(marker).getOrThrow()
    let end = html.indexOf("</script>", from).getOrThrow()
    return html[from..end]
}

/// 两份产物的驱动脚本括号都必须配平；判据自检（多一个右括号要抓得到，字符串里的括号不算）。
@Test
func testDriverScriptsBracketsBalance(): Unit {
    let root = writeTree()
    try {
        writeFileAtomic("${root}/a.kt", "class Util {\n    fun twice(x: Int): Int {\n        return x * 2\n    }\n}\n")
        let g = buildGraph(root)
        let rep = analyzeConfidence(g, false)
        let payload = indexPayloadForStore(g, 0, rep, sourceProbeNow(root), 0, "2026-11-25T00:00:00Z", false)
        let indexHtml = renderIndexHtml(payload, None<JsonValue>, false)
        let arch = buildArch(g)
        layoutArch(arch)
        let archHtml = renderArchHtml(Json.pretty(archJson(arch, false)), false)
        let di = driverScriptOf(indexHtml, "var EMB = window.MOONGIT_EMBED")
        // 从驱动的第一个字符起切：架构图驱动整体包在 (function () { … })(); 里，从里面任何一处起切都少一层括号
        let da = driverScriptOf(archHtml, "(function () {\n  var DATA = window.__ARCH__;")
        @Assert(di.size > 10000)
        @Assert(da.size > 5000)
        @Assert(jsBracketError(di) == -1)
        @Assert(jsBracketError(da) == -1)
        // 判据自检
        @Assert(jsBracketError("f(Math.max(1, Math.min(n, 2))));") >= 0)
        @Assert(jsBracketError("if (a) { g(1; }") >= 0)
        @Assert(jsBracketError("var s = \"a)b\"; // c(d\n/* e{f */ g[\"}\"](); h(')');") == -1)
        @Assert(jsBracketError("var s = \"never closed;") >= 0)
        // 正则字面量里的引号与括号不算；除号后面的 / 不被当成正则
        @Assert(jsBracketError("String(v).replace(/[&<>\"']/g, function (ch) { return { '&': 1 }[ch]; }); f((a + b) / 2);") == -1)
        @Assert(jsBracketError("var m = s.match(/^#module=(.+)$/); if (x) { y(); }") == -1)
        // 错位探测：引号字符串不跨行
        @Assert(jsBracketError("f('a\nb');") >= 0)
    } finally {
        removeTree(root)
    }
}
