// graph/minimap_test.cj — 热力图小地图：全图已在视口里时整块隐藏。
//
// 小地图是给「图比视口大」时导航用的。项目级只有一张模块卡时它被放大铺满整块小地图，
// 低置信度的仓库看上去就是右下角一坨实心色块（打包态实拍确认）。这里钉住产物里的驱动。
package moongit.graph

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

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
