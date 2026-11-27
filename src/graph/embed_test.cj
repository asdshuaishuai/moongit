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
        @Assert(html.contains("if (EMB_ON && (isArch() || isRole())) { embReflow(embLaneCols()); }"))
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

/// 架构图铺开（嵌入模式）。原先嵌入时泳道宽度钉死成「标签列 + 列数 × 卡槽」，页面里又宽又矮的画布上
/// 整叠泳道只占中间一列，卡片贴着标签列挤成一团，连线从卡片侧面中点进出、大半压在卡片后面。
/// 现在：泳道横向铺到可用宽度，卡片在泳道里对称分布，连线从卡片底边出、顶边入，跨行时沿卡片之间的
/// 空档绕行；架构级与职责视图同一套。每条断言钉的是「改坏之后会红」的那根线（负控见 PLAN 的记录）。
@Test
func testArchEmbedSpreadsLanesAndRoutesEdges(): Unit {
    let root = writeTree()
    try {
        let arch = buildArch(buildGraph(root))
        let html = archCanvasHtml(arch, false)
        // ① 取景先铺开；职责视图同样铺开（原先只管架构级）
        @Assert(html.contains("if (EMB_ON && (isArch() || isRole())) { embReflow(embLaneCols()); }"))
        // ② 泳道宽度跟可用区域与取景倍率走，最宽到卡槽名义宽的 spread 倍；旧的定宽泳道不许回来
        @Assert(html.contains("var laneW = Math.min(Math.max(av.aw / k, m.W), embLay(geo, P, c, geo.spread).W) - 24;"))
        @Assert(!html.contains("var laneW = g.labelW + Math.min(c, maxN) * g.slotW;"))
        // ③ 卡片对称分布；偶数张时正中让出一张卡的宽度——单卡居中的那些行两侧才有连线走的水道
        @Assert(html.contains("function embPlaceRow(row, x0, w, y, geo)"))
        @Assert(html.contains("gap = Math.max(0, (w - (n + (odd ? 0 : 1)) * cw) / (n + (odd ? 1 : 2)));"))
        // ④ 连线：底边出、顶边入；中间夹着别的卡片行时沿一条贯穿的空档竖直走，堵死才退回 S 形
        @Assert(html.contains("function vRoute(a, b)"))
        @Assert(html.contains("if (spreadEdges() && (RT = vRoute(a, b)))"))
        @Assert(html.contains("if (bd >= 1e9) { mid = []; }"))
        @Assert(html.contains("RT.segs.forEach(function (g) { var gm = w2sy((g.y1 + g.y2) / 2);"))
        // 空档按「卡片行」找而不是按泳道：泳道折成多行时同一泳道的下一行也是障碍
        @Assert(html.contains("if (spreadEdges()) { EMB_ROWS = embRows(); }"))
        // 粒子与边标签走同一条路线（各画各的 = 粒子穿墙、标签落在空处）
        @Assert(html.contains("if (spreadEdges()) { var vr = vRoute(a, b); if (vr) { return vPoint(vr, t); } }"))
        @Assert(html.contains("if (RT) { var lp = vPoint(RT, RT.lt); mx = w2sx(lp.x); my2 = w2sy(lp.y); }"))
        // ⑤ 间距只认 DATA.geo 的 emb* 键（与常量同值）；旧产物没带这些键时回落到定稿值
        @Assert(html.contains("slotW: g.embSlotW || g.slotW, padV: g.embPadV || g.padV, laneGap: g.embLaneGap || g.laneGap, spread: g.embSpread || 1"))
        let geo = Json.getOr(archJson(arch, false), "geo")
        @Assert(Json.numAt(geo, "embSlotW", -1.0) == ARCH_EMB_SLOT_W)
        @Assert(Json.numAt(geo, "embPadV", -1.0) == ARCH_EMB_PAD_V)
        @Assert(Json.numAt(geo, "embLaneGap", -1.0) == ARCH_EMB_LANE_GAP)
        @Assert(Json.numAt(geo, "embSpread", -1.0) == ARCH_EMB_SPREAD)
        // 嵌入的纵向开销必须比定稿小（否则铺开反而把卡片缩小），且层间水道比层内留白宽
        @Assert(ARCH_CARD_H + ARCH_EMB_PAD_V * 2.0 + ARCH_EMB_LANE_GAP < ARCH_CARD_H + ARCH_LANE_PAD_V * 2.0 + ARCH_LANE_GAP)
        @Assert(ARCH_EMB_LANE_GAP > ARCH_EMB_PAD_V)
        // 名义卡槽要放得下「两张卡 + 正中让出的一张」外加两侧的间隙
        @Assert(ARCH_EMB_SLOT_W * 2.0 > ARCH_CARD_W * 3.0)
        @Assert(ARCH_EMB_SPREAD > 1.0)
        // ⑥ 独立打开不变：侧边连线的 ends() 还在；铺开只在嵌入的架构级 / 职责视图接管
        @Assert(html.contains("function ends(a, b)"))
        @Assert(html.contains("var SPREAD = false;"))
        @Assert(html.contains("return SPREAD && (isArch() || isRole());"))
        // ⑦ 职责视图的角色色：宿主给了就用宿主的（填充级 roleCols / 文字级 roleTextCols），角色名用文字级；
        //    没有宿主值回落到自带色板——独立版不变。原先标签直接拿泳道底那一档填充色，浅色皮肤下 1.4–2.2:1
        @Assert(html.contains("var c = P().roleCols || ROLEPAL[dark ? 'dark' : 'light']; return c[role % c.length];"))
        @Assert(html.contains("function roleText(role) { var t = P().roleTextCols; return t ? t[role % t.length] : roleColor(role); }"))
        @Assert(html.contains("ctx.globalAlpha = ap; ctx.fillStyle = roleText(L.role);"))
        @Assert(!html.contains("ctx.globalAlpha = ap; ctx.fillStyle = rc;"))   // 角色名不许再拿填充色当文字色
        // ⑧ 职责视图的台阶式（2026-11-28 第二轮，用户实拍指出连线堆积）：单卡行按行序依次右挪——
        //    全部居中 = 上下卡片同轴，每条跨行线都挤在同一条走廊里。行表收平 + 行序位移
        @Assert(html.contains("var allRows = [];"))
        @Assert(html.contains("if (isRole() && row.length === 1) {"))
        @Assert(html.contains("var f = allRows.length > 1 ? rowIdx / (allRows.length - 1) : 0.5;"))
        @Assert(html.contains("row[0].x = g.margin + g.labelW + (laneW - g.labelW - geo.cardW) * f;"))
        @Assert(html.contains("y += L.h + geo.laneGap;"))
        // 同走廊的线按端点对散开：a→b 与 b→a 的哈希不同，双向线不再叠成一条
        @Assert(html.contains("want += (h01(a.id + '>' + b.id) - 0.5) * 36;"))
    } finally {
        removeTree(root)
    }
}
