// minimap_dendro_test.cj —— 从图谱包的 minimap_test.cj 搬来的用例：它们断言的是 Dendro（置信度）的契约，
// 而图谱包的测试不能再引入 Dendro（cjpm：循环依赖）。用例原文未改，只换了所在的包。
// 建图、扫描这类被测能力仍是图谱包的公开接口（import cambium.graph）。

package cambium.dendro

import cambium.util.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.graph.*


/// 产物里带「全图可见就隐藏小地图」的驱动：判定只看世界包围盒与视口（不看节点个数），
/// 隐藏 / 显示只在小地图容器上改 display，重新显示时按容器实尺寸重设 canvas。
@Test
func testIndexHtmlMinimapHidesWhenWholeGraphFits(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/a.kt", "fun twice(x: Int): Int {\n    return x * 2\n}\n")
        let g = buildGraph(root)
        let rep = analyzeConfidence(g, false)
        let payload = indexPayloadForStore(g, 0, rep, sourceProbeNow(root), 0, "2026-11-25T00:00:00Z", false)
        let html = renderIndexHtml(payload, None<JsonValue>, false)
        @Assert(html.contains("function drawMini"))
        @Assert(html.contains("function setMiniVisible"))
        @Assert(html.contains("setMiniVisible(!fits)"))
        // 视口判定的四壁都在（世界坐标）：左 / 上 / 右 / 下；没有节点时也隐藏
        @Assert(html.contains("-panX / zoom <= minX + 1"))
        @Assert(html.contains("-panY / zoom <= minY + 1"))
        @Assert(html.contains("(cssW - panX) / zoom >= maxX - 1"))
        @Assert(html.contains("(cssH - panY) / zoom >= maxY - 1"))
        @Assert(html.contains("worldNodes.length > 0"))
        // 隐藏的是整个容器（含 MINIMAP 标签），不是只藏 canvas；状态没变就不重复改 display
        @Assert(html.contains("miniBox = mini.parentNode"))
        @Assert(html.contains("if (miniShown === visible) { return; }"))
        // 重新显示时重设 canvas 后备存储（隐藏期间窗口变过尺寸会按 0 记）
        @Assert(html.contains("mini.width = Math.round(mini.clientWidth * dpr)"))
    } finally {
        removeTree(root)
    }
}
