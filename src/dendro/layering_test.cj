// layering_test.cj —— Dendro 的分层守卫（品牌升级：置信度从图谱包剥离成独立包时立）。
//
// 分层：util ← graph ← dendro ← kernel / flow / cli，单向、无环。
//   · 图谱层与工具层不认识 Dendro：它们一旦引入 cambium.dendro 就是循环依赖（cjpm 直接拒绝编译）；
//   · Dendro 只引入 std、cambium.util、cambium.graph——它建在图谱之上，不该反过来被更上层的
//     kernel / flow 牵着走（否则「置信度」又和进度内核缠在一起）；
//   · 置信度的实现只在 src/dendro 里：图谱包里不许再长出第二份 ConfidenceReport / analyzeConfidence
//     （两份实现必然漂移，同不变量 26/43 同族）。
package cambium.dendro

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.util.*

private let GRAPH_DIR = "src/graph"
private let UTIL_DIR = "src/util"
private let DENDRO_DIR = "src/dendro"

/// 目录下的 .cj 源文件（不含测试文件），路径形如 src/graph/a.cj。
private func sourceFiles(dir: String): ArrayList<String> {
    let out = ArrayList<String>()
    let (entries, _) = listDirChecked(dir)
    for (e in entries) {
        if (!e.name.endsWith(".cj") || e.name.endsWith("_test.cj")) { continue }
        out.add(dir + "/" + e.name)
    }
    return out
}

@Test
func testDendroLayeringIsOneWay(): Unit {
    // ① 下层不认识 Dendro
    for (dir in [GRAPH_DIR, UTIL_DIR]) {
        for (p in sourceFiles(dir)) {
            let raw = readFileTextChecked(p).getOrThrow()
            @Assert(!raw.contains("import cambium.dendro"))
        }
    }
    // ② Dendro 只引入 std / util / graph
    for (p in sourceFiles(DENDRO_DIR)) {
        let raw = readFileTextChecked(p).getOrThrow()
        for (line in raw.split("\n")) {
            let l = line.trimAscii()
            if (!l.startsWith("import ")) { continue }
            let ok = l.startsWith("import std.") || l == "import cambium.util.*" || l == "import cambium.graph.*"
            @Assert(ok)
        }
    }
    // ③ 置信度的实现只在 Dendro 里
    let lowerDirs = [GRAPH_DIR, UTIL_DIR]
    for (dir in lowerDirs) {
        for (p in sourceFiles(dir)) {
            let raw = readFileTextChecked(p).getOrThrow()
            @Assert(!raw.contains("class ConfidenceReport"))
            @Assert(!raw.contains("func analyzeConfidence("))
        }
    }
}

/// 上层（kernel / flow / cli）认识 Dendro 是允许的（命令面要调它），但 kernel / flow 只许经 cli 之外的
/// 公开接口——这里只钉「cli 一定引入了 Dendro」：命令面 `cambium dendro …` 的实现就在 cli 里。
@Test
func testCliImportsDendro(): Unit {
    var any = false
    for (p in sourceFiles("src/cli")) {
        if (readFileTextChecked(p).getOrThrow().contains("import cambium.dendro.*")) { any = true }
    }
    @Assert(any)
}
