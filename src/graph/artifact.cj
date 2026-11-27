// artifact.cj —— 渲染产物的模板版本标记（热力图与架构图两份产物共用）。
//
// 放在图谱包而不是 Dendro：架构图渲染器（archhtml.cj）也在用，而图谱层不认识 Dendro
// （分层：util ← graph ← dendro ← kernel / flow / cli，见 AGENTS.md）。
// 模板版本号是**两份产物**的，谁改了外壳、样式或驱动都要 +1。

package cambium.graph

import cambium.util.*

/// 渲染模板的版本号：外壳、样式或驱动变了就 +1。
/// 产物以注释行自报（renderTemplateTag），复用判定比对它——否则引擎升级后旧产物会被当成
/// 「输入没变」一直复用，用户永远看不到新外壳（v0.3.0 加嵌入模式时实测抓到）。
/// 3 = 嵌入尺寸融合：泳道折行、按区域选列、色带包住卡片、图例进底条、尺寸契约变量。
/// 4 = 品牌升级：嵌入声明改读 window.CAMBIUM_EMBED（旧名 MOONGIT_EMBED 兜底）、驱动入口全局改 CambiumCodeGraph。
/// 5 = 报告面板跟视口走且可收起（窄视口成抽屉）、项目级疑点数取引擎全量、架构图卡内文字随卡片缩放、
///     泳道标签用文字级颜色、窄视口命令条收成一行（2026-11-27）。
/// 6 = 架构图铺开：嵌入时泳道横向铺到可用宽度、卡片在泳道里对称分布、连线从卡片底/顶边进出并沿
///     卡片之间的空档绕行（架构级与职责视图）；职责泳道行号与卡片对齐；geo 带嵌入间距（2026-11-27）。
/// 7 = 职责视图的角色色读宿主调色板（roleCols / roleTextCols），角色名用文字级（2026-11-27）。
/// 8 = 职责视图单卡行台阶式排列（行序依次右移），同走廊连线按端点对散开（2026-11-28）。
public let RENDER_TEMPLATE: Int64 = 8

/// 产物里自报模板版本的注释行（两份产物同一格式）。
public func renderTemplateTag(): String {
    return "<!-- cambium render · template=" + RENDER_TEMPLATE.toString() + " -->\n"
}

/// 从渲染产物读回模板版本；没有这一行（更早的引擎画的）/ 读不出来 = -1，调用方按不可复用处理。
public func renderEmbeddedTemplate(html: String): Int64 {
    let marker = "<!-- cambium render · template="
    let a = indexOfStrFrom(html, marker, 0)
    if (a < 0) { return -1 }
    let from = a + marker.size
    let end = indexOfStrFrom(html, " -->", from)
    if (end <= from) { return -1 }
    // 版本号是纯 ASCII 数字串，UTF-8 切片安全
    match (metaInt(html[from..end])) {
        case Some(n) => return n
        case None => return -1
    }
}
