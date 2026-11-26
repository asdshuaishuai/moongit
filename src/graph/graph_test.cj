// graph/graph_test.cj — 图谱包的单测。
//
// 【测试隔离】临时目录按 pid + 时间戳 + 进程内序号命名，用完整树删除；
// 不碰 DEEPGIT_HOME（图谱不依赖引擎配置，天然隔离）。
package cambium.graph

import std.collection.*
import std.env.*
import std.fs.*
import std.posix.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.util.*

// 进程内自增序号：并行用例下 pid + 毫秒会撞出同一路径（同进程同 pid，
// 两次 testRoot() 落进同一毫秒），两个夹具就会写同一棵树——
// 实测 --parallel 下 testTreeThreeViewsAndTierDefault 的 layered 夹具
// 因夹具树里混入 writeTree 的文件而不再是 31 个文件（同 util/hash.cj
// randomId 的口径：时间戳 + 序号，同毫秒内也保证唯一）。
let testRootSeq: AtomicInt64 = AtomicInt64(0)

func testRoot(): String {
    // pid + 时间戳 + 序号：只用 pid 时同一进程内多个夹具会互相覆盖，跨次运行也分不清
    let pid = getpid()
    let seq = testRootSeq.fetchAdd(1)
    return "${tempDirPath()}/moongit-graph-test-${pid}-${nowMillis()}-${seq}"
}

func tempDirPath(): String {
    match (getVariable("TMPDIR")) {
case Some(v) =>
                        if (v.trimAscii().size > 0) { return normalizePath(v) }
        case None => ()
    }
    return "/tmp"
}

func writeTree(): String {
    let root = testRoot()
    ensureDir("${root}/util")
    ensureDir("${root}/flow")
    ensureDir("${root}/cli")
    writeFileAtomic("${root}/util/text.cj", """
package cambium.util

import std.collection.*

public class Text {
    public func trimAll(s: String): String {
        return s
    }
}
""")
    writeFileAtomic("${root}/flow/update.cj", """
package cambium.flow

import cambium.util.*

public func runUpdate(t: Text): Bool {
    let x = t.trimAll("  ")
    return x.isEmpty()
}
""")
    writeFileAtomic("${root}/cli/main.swift", """
import Foundation

public final class Runner {
    public func go() -> Bool { return true }
}

public enum Mode: String {
    case fast
}
""")
    writeFileAtomic("${root}/cli/app.py", """
from flow.update import runUpdate

def main():
    return runUpdate(None)
""")
    writeFileAtomic("${root}/README.md", "# not a source file\n")
    return root
}

// ⚠️ L16（审查）：这个函数原先是 `let _ = dir` 的空操作 —— 每个用例的
// finally 里都在「清理」，而临时目录一直留在 TMPDIR 下越积越多，且**测试全绿**，
// 没有任何断言会发现「残留」本身。util 的 removePathIfExists 早就有公开删除
// 入口（std.fs 的 remove(recursive:)），这里却另写一份假的。
func removeTree(dir: String): Unit {
    removePathIfExists(dir)
}

// MARK: - 语言识别

@Test
func testDetectLang(): Unit {
    @Assert(detectLang("a/b.swift") == "swift")
    @Assert(detectLang("a/b.cj") == "cangjie")
    @Assert(detectLang("a/b.TS") == "ts")
    @Assert(detectLang("a/b.py") == "python")
    @Assert(detectLang("a/b.go") == "go")
    @Assert(detectLang("a/b.rs") == "rust")
    @Assert(detectLang("a/b.md") == "")
    @Assert(detectLang("a/b.json") == "")
}

// MARK: - 词法

@Test
func testTokenizeAsciiAndUtf8(): Unit {
    let t = tokenize("public final class 海豚Runner: Runnable")
    // 多字节中文不是标识符字符 → 天然分隔，且「海豚」后的 Runner 完整保留
    @Assert(t.size == 5)
    @Assert(t[0] == "public")
    @Assert(t[2] == "class")
    @Assert(t[3] == "Runner")
    @Assert(t[4] == "Runnable")
}

@Test
func testScanSwift(): Unit {
    let src = """
import Foundation
// comment: class Fake should not appear
public final class Runner {
    public func go() -> Bool { return true }
}
struct Point { let x = 1 }
protocol Drawable { func draw() }
extension Int { func twice() -> Int { return 2 } }
enum Mode { case fast }
"""
    let f = scanSource(src, "swift")
    @Assert(f.imports.size == 1)
    @Assert(f.imports[0] == "Foundation")
    let names = ArrayList<String>()
    for (s in f.symbols) { names.add(symKindId(s.kind) + ":" + s.name) }
    @Assert(names.contains("class:Runner"))
    @Assert(names.contains("func:go"))
    @Assert(names.contains("struct:Point"))
    @Assert(names.contains("interface:Drawable"))
    @Assert(names.contains("extension:Int"))
    @Assert(names.contains("enum:Mode"))
    @Assert(!names.contains("class:Fake"))
}

@Test
func testScanCangjieAndGo(): Unit {
    let cj = """
package cambium.flow

import cambium.util.*

public func runUpdate(): Bool { return true }
public class Updater { }
"""
    let f = scanSource(cj, "cangjie")
    // ⚠️ 推翻旧断言：这里原本是 `imports[0] == "cambium"`（首段）—— 那是把缺陷
    // 写成了断言（`import cambium.util.*` 的语义在**末段** `util`；取首段 `cambium`
    // 导致整个仓颉仓库 import 边恒为 0）。详见 confidence 修复与下方
    // `testImportSegmentResolution`。
    @Assert(f.imports[0] == "util")
    let names = ArrayList<String>()
    for (s in f.symbols) { names.add(symKindId(s.kind) + ":" + s.name) }
    @Assert(names.contains("func:runUpdate"))
    @Assert(names.contains("class:Updater"))

    let go = """
package main

import "fmt"

type Store struct { }
type Handler interface { Handle() }
func main() { fmt.Println("hi") }
"""
    let g = scanSource(go, "go")
    let gnames = ArrayList<String>()
    for (s in g.symbols) { gnames.add(symKindId(s.kind) + ":" + s.name) }
    @Assert(g.imports[0] == "fmt")
    @Assert(gnames.contains("struct:Store"))
    @Assert(gnames.contains("interface:Handler"))
    @Assert(gnames.contains("func:main"))
}

@Test
func testScanPythonFromImport(): Unit {
    let py = "from flow.update import runUpdate\nimport os\n\nclass App:\n    def start(self):\n        return 1\n"
    let f = scanSource(py, "python")
    @Assert(f.imports.contains("flow"))
    @Assert(f.imports.contains("os"))
    let names = ArrayList<String>()
    for (s in f.symbols) { names.add(symKindId(s.kind) + ":" + s.name) }
    @Assert(names.contains("class:App"))
    @Assert(names.contains("func:start"))
}

// MARK: - 构建 + 引用 + 影响面

@Test
func testBuildGraphAndImpact(): Unit {
    let root = writeTree()
    let graph = buildGraph(root)
    try {
        // README.md 不该进来（语言识别排除）
        @Assert(graph.files.size == 4)
        var symbols: Int64 = 0
        for (f in graph.files) { symbols += Int64(f.symbols.size) }
        @Assert(symbols >= 6)

        // 引用边：flow/update.cj 用了 util 的 Text.trimAll → util 文件被引用
        var hasRefToUtil = false
        for ((from, to, _) in graph.refEdges) {
            if (from.startsWith("flow/") && to.startsWith("util/")) { hasRefToUtil = true }
        }
        @Assert(hasRefToUtil)

        // 影响面：Text 定义在 util/text.cj，引用方是 flow
        match (impactOf(graph, "Text")) {
case Some(res) =>
                                @Assert(res.defs.size == 1)
                                var fromFlow = false
                                for (f in res.refFiles) { if (f.startsWith("flow/")) { fromFlow = true } }
                                @Assert(fromFlow)
                                @Assert(res.impactedSymbols.size >= 1)
            case None => @Assert(false)
        }

        // 未定义符号 → None（不编结果）
        match (impactOf(graph, "NoSuchSymbol")) {
            case Some(_) => @Assert(false)
            case None => @Assert(true)
        }

        // 架构聚合：三个模块（cli/flow/util），分层 cli=3 接口层 flow=2 编排 util=0 基础
        let arch = buildArch(graph)
        @Assert(arch.modules.size == 3)
        @Assert(arch.totalFiles == 4)
        @Assert(arch.edges.size >= 1)

        // 四种渲染都不为空
        @Assert(!archMermaid(arch, false).isEmpty())
        @Assert(!archDot(arch, false).isEmpty())
        @Assert(!Json.pretty(archJson(arch, false)).isEmpty())
        let html = archCanvasHtml(arch, false)
        @Assert(html.contains("window.__ARCH__"))
        @Assert(html.contains("<canvas"))
        // 嵌入安全：JSON 里不允许裸 "</script>"
        @Assert(!html.contains("</script>__ARCH_PLACEHOLDER__"))
        // 面板统计：文件级子视图的节点是 DrillNode（**没有 files 字段**）——
        // 不能无条件用 m.files，否则模块子视图的面板显示 "undefined 文件"。
        @Assert(!html.contains("h += '<div>' + m.files"))
        // 幻影字面量：`'》'.length` 恒等于 1，曾被拼成无意义的 "· L1"。
        @Assert(!html.contains("》"))

        // 场景 JSON 的文件级面板：out/in 必须取自真实文件级边 ——
        // 原实现恒发空数组 = 对驱动谎称「这个文件没有任何依赖」。
        // （夹具里 flow/update.cj 引用了 util/text.cj ⇒ util/text.cj 有入向依赖）
        let scene = buildArchScene(arch, false)
        let fp = Json.getOr(Json.getOr(scene, "panels"), "module:util:util/text.cj")
        @Assert(Json.arrAt(fp, "in").size > 0 || Json.arrAt(fp, "out").size > 0)

        // scene 每个视图必须**恒发** `edgesDropped`（截断要披露；0 也要发）
        match (Json.getOr(scene, "views")) {
            case JObj(vm) =>
                var viewCount: Int64 = 0
                for ((_, vv) in vm) {
                    @Assert(Json.has(vv, "edgesDropped"))
                    viewCount += 1
                }
                @Assert(viewCount > 0)
            case _ => @Assert(false)
        }

        // i18n：英文模式（cli 按 config.language 传 en=true）下内嵌 JS 不得出现中文 ——
        // 原实现把 MODULEW / ROOTW 硬编码成「外部模块」「架构总览」。
        let htmlEn = archCanvasHtml(arch, true)
        @Assert(!htmlEn.contains("外部模块"))
        @Assert(!htmlEn.contains("架构总览"))
        @Assert(htmlEn.contains("external module"))

        // 内嵌 JS 读 `m._ord` 做错峰入场，而 archJson 的节点形状里没有 `ord` ——
        // 必须在初始化时补上，否则 `(m._ord || 1)` 恒为 1、错峰静默退化成常量（同不变量 129）。
        @Assert(html.contains("m._ord = i + 1"))
        @Assert(html.contains("n._ord = i + 1"))
    } finally {
        removeTree(root)
    }
}

@Test
func testTreeAndSymbolOutputs(): Unit {
    let root = writeTree()
    let graph = buildGraph(root)
    try {
        let tree = treeText(graph, 8)
        @Assert(tree.contains("util/"))
        @Assert(tree.contains("text.cj"))
        @Assert(tree.contains("func trimAll"))

        let st = symbolText(graph, "trimAll")
        @Assert(st.contains("trimAll"))
        @Assert(st.contains("util/text.cj"))

        let miss = symbolText(graph, "DefinitelyNotHere")
        @Assert(miss.contains("未找到符号"))
    } finally {
        removeTree(root)
    }
}

// MARK: - 置信度：import 解析 / TODO 标记 / 符号级孤儿 / 词法函数信号 / 全序排序

@Test
func testImportSegmentResolution(): Unit {
    // 仓颉/Swift 的跨包引用语义在**末段**（能命中项目内目录/文件名的才是它）。
    @Assert(scanSource("import cambium.util.*\n", "cangjie").imports[0] == "util")
    @Assert(scanSource("import Foundation\n", "swift").imports[0] == "Foundation")
    // Swift 别名 `import X as Y` → 取 X，不是别名 Y
    @Assert(scanSource("import CoreGraphics as CG\n", "swift").imports[0] == "CoreGraphics")
    @Assert(scanSource("from flow.update import runUpdate\n", "python").imports[0] == "flow")
    @Assert(scanSource("use std::collections::HashMap\n", "rust").imports[0] == "std")
    @Assert(scanSource("import \"net/http\"\n", "go").imports[0] == "http")
}

@Test
func testArchMermaidNodeIdsAreInjective(): Unit {
    // 两个模块 id 在「非法字符 → _」的旧映射下会**折叠**（`a-b` 与 `a_b` 都 → `a_b`），
    // 图上两个模块合并成一个节点且不报错。现在按下标映射，必须是两个不同节点。
    let root = "${tempDirPath()}/cambium-archid-${getpid()}"
    ensureDir("${root}/a-b")
    ensureDir("${root}/a_b")
    writeFileAtomic("${root}/a-b/x.cj", "package p\n\npublic func ax(): Int64 { return 1 }\n")
    writeFileAtomic("${root}/a_b/y.cj", "package q\n\npublic func by(): Int64 { return 2 }\n")
    try {
        let arch = buildArch(buildGraph(root))
        @Assert(Int64(arch.modules.size) == 2)
        let mm = archMermaid(arch, false)
        // 统计节点定义行的**不同 id**
        let ids = HashSet<String>()
        for (line in mm.split("\n")) {
            let parts = line.split("[")
            if (parts.size >= 1 && parts[0].startsWith("    M")) { ids.add(parts[0]) }
        }
        @Assert(Int64(ids.size) == 2)
    } finally {
        removePathIfExists(root)
    }
}

@Test
func testStripCodeFastPathMatchesFullScan(): Unit {
    // stripCode 的快路径：**代码态且整行无引号** ⇒ 结果等价于「只剥注释」（零拷贝）。
    // 它必须与逐字节完整扫描**结果一致**（否则是行为变更，不是优化）。
    // ⚠️ M9 之后 `"/* block"`（整行一个**不闭合**的块注释）会把状态改成 3。
    // 这里钉的是**修好之后**的契约：原先它返回 0，于是下一行的注释内容
    // 全被当成代码 —— 那条输出看起来「注释被剥干净了」，代价在后面几行。
    let ins = ["let x = 1", "// comment", "/* block", "# shell", "  * doc", "-- sql",
        "code // tail", "let s = \"hi\"", "let s = \"hi", "let c = 'x'",
        "let s = \"\"\"abc", "\" ; more", "tail", "*/ tail",
        "a /* inline */ b", "x = 1  # tail", "i--; q", "x = base#anchor",
        "/* only */ let z = 2"]
    // ⚠️ 2026-11-25 显式推翻一处（阶段二 · 扫描器修复）：`"  * doc"` 的输入状态原为 0。
    // 那一项钉的是「行首是 * 就当块注释续行」——按行首字符猜它在不在一个跨行结构里。
    // 真实文件里文档注释续行只会带着状态 3 进来（开注释的那一行已把状态置 3）；
    // 状态 0 + 行首 `*` 是代码（`*errOut = f(x);`，曾被整行剥掉 ⇒ 调用点丢失、
    // 被调函数被报 orphan）。于是把这一项改成真实配对：输入 3、输出仍是空串、
    // 后继状态 3。期望的输出串一个没改；新契约由
    // testStarPrefixedCodeLineIsNotAComment 单独钉。
    let sts: Array<Int64> = [0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 1, 2, 0,
        0, 0, 0, 0, 0]
    // ⚠️ 行内闭合的 `/* ... */` 摘除后以**一个空格占位**（token 边界语义：
    // 注释等价空白，不许让相邻标识符粘连成 ab）。原先是完全消失 ⇒
    // "a /* inline */ b" → "a  b"（两个空格）、"/* only */ let z = 2" →
    // " let z = 2"（一个空格）；契约显式更新为占位后的三个 / 两个空格。
    // 见 testInlineBlockCommentKeepsTokenBoundary。
    let wantOut = ["let x = 1", "", "", "", "", "", "code ", "let s = ", "let s = ", "let c = ",
        "let s = ", " ; more", "", "*/ tail",
        "a   b", "x = 1  ", "i--; q", "x = base#anchor",
        "  let z = 2"]
    let wantSt: Array<Int64> = [0, 0, 3, 0, 3, 0, 0, 0, 0, 0, 2, 0, 2, 0,
        0, 0, 0, 0, 0]
    @Assert(ins.size == 19)
    for (i in 0..ins.size) {
        let (out, ns) = stripCode(ins[i], sts[i])
        @Assert(out == wantOut[i])
        @Assert(ns == wantSt[i])
    }
}

@Test
func testSceneEdgesCapKeepsHeaviestAndDiscloses(): Unit {
    // scene 每条边展开成形状+粒子，上万条会 OOM ⇒ 有上限。上限之外**按权重降序**保留
    // （留最重的依赖），并报出丢弃数（截断必须披露，不能静默）。
    let e = ArrayList<(String, String, Int64)>()
    e.add(("a", "b", 1))
    e.add(("c", "d", 9))
    e.add(("e", "f", 5))
    e.add(("g", "h", 9))
    e.add(("i", "j", 2))
    let (kept, dropped) = sceneEdges(e, 2)
    @Assert(Int64(kept.size) == 2)
    @Assert(dropped == 3)
    // 权重降序；并列按 from↑
    @Assert(kept[0][2] == 9 && kept[0][0] == "c")
    @Assert(kept[1][2] == 9 && kept[1][0] == "g")
    // 未超限：全留、丢弃 0
    let (k2, d2) = sceneEdges(e, 10)
    @Assert(Int64(k2.size) == 5)
    @Assert(d2 == 0)
}

/// H3：引用边物化处必须有全序。原实现直接按两层 HashMap 迭代序输出，
/// render/arch 全部按它派生 ⇒ 出口字节序跟着 HashMap 走，违反
/// 「同一仓库两次导出一致」。
@Test
func testRefEdgesMaterializeInTotalOrder(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        var prev = ""
        for ((a, b, _) in g.refEdges) {
            let key = a + "\u{1f}" + b
            @Assert(key > prev || key == prev)
            prev = key
        }
    } finally {
        removeTree(root)
    }
}

/// M6：import 是**包级**语义，未使用判定也必须是包级。原判据把 import 对账到
/// moduleIndex 解析出的**单个文件** ⇒ 本仓库自身 10 条报告 9 条误报
/// （build.cj:15 用了 paths.cj 的 readFileText，却被拿去和 errors.cj 对账）。
@Test
func testUnusedImportIsModuleLevel(): Unit {
    let root = "${tempDirPath()}/cambium-unused-import-${getpid()}-${nowMillis()}"
    try {
        ensureDir("${root}/util")
        ensureDir("${root}/cli")
        // util 包两个文件，cli 只用**第二个**里的符号
        writeFileAtomic("${root}/util/aaa.cj", """
package p

public func helperA(): Int64 { return 1 }
""")
        writeFileAtomic("${root}/util/zzz.cj", """
package p

public func helperZ(): Int64 { return 2 }
""")
        writeFileAtomic("${root}/cli/main.cj", """
package q

import p.util

public func run(): Int64 { return helperZ() }
""")
        writeFileAtomic("${root}/cli/dead.cj", """
package q

import p.util

public func idle(): Int64 { return 0 }
""")
        let g = buildGraph(root)
        var flaggedDead = false
        var flaggedLive = false
        for ((f, mod, _) in g.unusedImports) {
            if (f == "cli/main.cj") { flaggedLive = true }
            if (f == "cli/dead.cj") { flaggedDead = true }
        }
        // 用了同模块另一个文件的符号 ⇒ 不是未使用
        @Assert(!flaggedLive)
        // 一个符号都没引用 ⇒ 报
        @Assert(flaggedDead)
        @Assert(g.oversizeSkipped == 0)
    } finally {
        removePathIfExists(root)
    }
}

/// M16 回归：`--depth` 必须真的进入 JSON 出口，且截断要说出来。
/// 原实现 MCP codegraph_tree 把 depth 解析、clamp 到 [1,24]，然后**从不使用**
/// （fullGraphJson 没有这个参数）—— schema 却写着「目录深度，默认 6」，
/// 模型传 depth=2 期待小图，实际拿到全量图。
@Test
func testFullGraphJsonHonoursDepthAndDisclosesCut(): Unit {
    let root = writeTree()
    try {
        // 加一个深度 2 的文件：没有它，夹具里最深只有 1，截断分支验不到
        ensureDir("${root}/flow/inner")
        writeFileAtomic("${root}/flow/inner/deep.cj", """
package cambium.flow.inner

public func deepThing(): Int64 { return 1 }
""")
        let g = buildGraph(root)
        // dirDepthOf 的口径：根目录文件 0，一层目录 1，两层 2
        @Assert(dirDepthOf("README.cj") == 0)
        @Assert(dirDepthOf("flow/update.cj") == 1)
        @Assert(dirDepthOf("flow/inner/deep.cj") == 2)

        // 全量：depth=0（不截断）+ depthOmitted=0
        let all = fullGraphJson(g, 0)
        @Assert(Json.intAt(all, "depth", -1) == 0)
        @Assert(Json.intAt(all, "depthOmitted", -1) == 0)
        @Assert(Json.arrAt(all, "files").size >= 5)

        // depth=1：深度 2 的那个必须被剪掉，并且报数
        let cut = fullGraphJson(g, 1)
        @Assert(Json.intAt(cut, "depth", -1) == 1)
        @Assert(Json.intAt(cut, "depthOmitted", -1) >= 1)
        var hasDeep = false
        for (f in Json.arrAt(cut, "files")) {
            if (Json.strAt(f, "path", "") == "flow/inner/deep.cj") { hasDeep = true }
        }
        @Assert(!hasDeep)

        // 没截断时也必须恒发这两个键（缺键会被读成「旧版本没这个字段」）
        for (v in [0, 1, 2, 3]) {
            let j = fullGraphJson(g, v)
            @Assert(Json.has(j, "depth"))
            @Assert(Json.has(j, "depthOmitted"))
        }
        @Assert(Json.intAt(fullGraphJson(g, 3), "depthOmitted", -1) == 0)
    } finally {
        removeTree(root)
    }
}

/// M9 regression: inline `#` / `--` comments and `/* */` block comments must
/// be stripped. The original stripLineComment only recognised `//` (plus
/// whole-line `#`/`*`/`--`), so the `class` inside
/// `x = 1  # class Foo is defined below` became a real symbol.
@Test
func testInlineHashDashAndBlockCommentsAreStripped(): Unit {
    let (a, _) = stripCode("let x = 1  # class Fake1 is defined below", 0)
    @Assert(!a.contains("class"))
    let (b, _) = stripCode("let x = 1  -- class Fake2 is defined below", 0)
    @Assert(!b.contains("class"))
    let (c, _) = stripCode("let x = 1  /* class Fake3 */ + y", 0)
    @Assert(!c.contains("class"))
    @Assert(c.contains("y"))        // after `*/` is still code
    // `i--` / `a--b` are code, not comments
    let (d, _) = stripCode("i--; a--b; let q = 3", 0)
    @Assert(d.contains("i--"))
    @Assert(d.contains("q"))
    let (e, _) = stripCode("let u = base#anchor", 0)
    @Assert(e.contains("base#anchor"))
    // multi-line block comment: the cross-line part must leave the token stream
    let (f1, st1) = stripCode("/* block start class BlockFake", 0)
    @Assert(!f1.contains("class"))
    @Assert(st1 == 3)
    let (f2, st2) = stripCode("class StillInsideFake", st1)
    @Assert(!f2.contains("class"))
    @Assert(st2 == 3)
    let (f3, st3) = stripCode("end */ let real = 1", st2)
    @Assert(!f3.contains("StillInsideFake"))
    @Assert(f3.contains("real"))
    @Assert(st3 == 0)
    // Python triple-single-quote docstring: cross-line content must not enter
    // either (the original had no state for it at all)
    let (g1, gs1) = stripCode("'''", 0)
    @Assert(gs1 == 4)
    let (g2, gs2) = stripCode("class DocFake is only prose", gs1)
    @Assert(!g2.contains("class"))
    @Assert(gs2 == 4)
    let (g3, gs3) = stripCode("'''", gs2)
    @Assert(gs3 == 0)
    // same-line closed triple-single-quote must not leave state behind
    let (g4, gs4) = stripCode("x = '''class InlineFake''' + y", 0)
    @Assert(!g4.contains("class"))
    @Assert(gs4 == 0)
    @Assert(g4.contains("y"))
}

/// M8 regression: the C-shaped function fallback applies to the C family only.
/// The original ran it for all 9 languages while its shape test only checked
/// "first token is not a keyword + second token is followed by ( + line has {",
/// so `it("works", () => { ... })` was fabricated into a symbol named expect.
@Test
func testCStyleFuncNameIsRestrictedToC(): Unit {
    let ts = "it(\"works\", () => { expect(x).toBe(1) })"
    @Assert(cStyleFuncName(ts, "ts").isNone())
    @Assert(cStyleFuncName(ts, "swift").isNone())
    @Assert(cStyleFuncName(ts, "python").isNone())
    // C-family still has to work: that is the whole reason this fallback exists
    let c = "int add(int a, int b) { return a + b; }"
    match (cStyleFuncName(c, "c")) {
        case Some(n) => @Assert(n == "add")
        case None => @Assert(false)
    }
    // scan layer too: a .ts file must not yield an `expect` symbol
    let facts = scanSource("it(\"works\", () => { expect(x).toBe(1) })\n", "ts")
    for (sym in facts.symbols) {
        @Assert(sym.name != "expect")
        @Assert(sym.name != "it")
    }
    // while a .c file must still yield add
    let cf = scanSource(c + "\n", "c")
    var hasAdd = false
    for (sym in cf.symbols) {
        if (sym.name == "add") { hasAdd = true }
    }
    @Assert(hasAdd)
}

// MARK: - 批 Z：C++ 图谱符号提取补全（Allman 风格 / 限定名 / 接收者豁免）

/// 批 Z ①：**Allman 风格**（`{` 另起一行）的 C++ 自由函数必须进符号表。
///
/// ⚠ 修前：cStyleFuncName 要求**行内含 `{`**（那是 K&R 形态）⇒ Allman 的签名行
///   判否 ⇒ 自由函数整个不进符号表 ⇒ 置信度的「幻觉调用」把**对真实自由函数的
///   调用**误报成「全仓无此定义」（实测 deepin 客户端 364 个顶层自由函数漏 363 个）。
@Test
func testAllmanStyleCFunctionIsScanned(): Unit {
    let src = "int add(int a, int b)\n" +
        "{\n" +
        "    return a + b;\n" +
        "}\n" +
        "\n" +
        "int sub(int a, int b)\n" +
        "{\n" +
        "    return a - b;\n" +
        "}\n"
    let facts = scanSource(src, "c")
    var hasAdd = false
    var hasSub = false
    for (sym in facts.symbols) {
        // ⚠ 行号必须是**签名行**（不是 `{` 那一行）—— 符号行号是函数体的起点
        if (sym.name == "add") { hasAdd = true; @Assert(sym.line == 1) }
        if (sym.name == "sub") { hasSub = true; @Assert(sym.line == 6) }
    }
    @Assert(hasAdd)
    @Assert(hasSub)
}

/// 批 Z ①的**负向防线**：原型声明（`;` 结尾）不算**定义** ——
/// 它只能以「只有声明」的身份进表（declOnly），定义仍然只有一个。
///
/// 推翻旧断言：这里原先是「原型根本不进符号表」（addCount == 1 且无 declOnly）。
/// 成员级索引（本轮）要求 agent 能在头文件里**找到声明处**，所以原型入表并带
/// declOnly=true；「它不是定义」这条语义由 declOnly 承担——定义计数不变。
@Test
func testAllmanStyleCPrototypeIsNotScanned(): Unit {
    let src = "int add(int a, int b);\n" +
        "\n" +
        "int add(int a, int b)\n" +
        "{\n" +
        "    return a + b;\n" +
        "}\n"
    let facts = scanSource(src, "c")
    var defCount = 0
    var declCount = 0
    for (sym in facts.symbols) {
        if (sym.name == "add" && sym.declOnly) { declCount += 1 }
        if (sym.name == "add" && !sym.declOnly) { defCount += 1 }
    }
    @Assert(defCount == 1)    // 只认一个定义
    @Assert(declCount == 1)   // 原型 = 声明处（declOnly），行号是签名行
}

/// 批 Z ②：**限定名**的函数定义必须进符号表。
///
/// ⚠ 修前：函数名按「第二个 token」取 ⇒ `bool AgentCore::runEngineRaw(…)` 的
///   第二个 token 是 `AgentCore`（类名）⇒ 真函数名判丢。
///   ⇒ 后果是**函数体边界算错**（边界 = 本符号行 → 下一个符号行）⇒ 中间那些
///   没被认出的定义不占边界 ⇒ 前一个函数的「函数体」把中间函数的 if/for 全吞
///   ⇒ **凭空多出高复杂度告警**（实测 `clipNote`（2 行）被判「圈复杂度 13」）。
@Test
func testQualifiedCFunctionNameIsScanned(): Unit {
    let src = "bool AgentCore::runEngineRaw(const QStringList &args)\n" +
        "{\n" +
        "    return true;\n" +
        "}\n" +
        "\n" +
        "EngineCli::EngineResult classifyResult(QProcess *proc)\n" +
        "{\n" +
        "    return EngineCli::EngineResult();\n" +
        "}\n"
    let facts = scanSource(src, "c")
    var hasRun = false
    var hasClassify = false
    for (sym in facts.symbols) {
        if (sym.name == "runEngineRaw") { hasRun = true }
        if (sym.name == "classifyResult") { hasClassify = true }
    }
    @Assert(hasRun)
    @Assert(hasClassify)
}

/// 批 Z ③：`::` 与 `->` 限定的调用**不许**被报成「幻觉调用」。
///
/// ⚠ 修前：接收者豁免只认 `.`（且**差一位**——读的是前一个 token 的标记），
///   `->` 与 `::` 两种隔断**根本没有豁免规则** ⇒ `QDateTime::currentMSecsSinceEpoch()`
///   这类标准库静态调用被逐条指控（实测 deepin 客户端 106 条）。
///   负向防线：真幻觉名（**裸**自由调用）仍要报。
@Test
func testQualifiedAndArrowCallsAreNotUnresolved(): Unit {
    let root = "${tempDirPath()}/cambium-scan-qualified-${getpid()}-${nowMillis()}"
    ensureDir(root)
    let src = "int main(void) {\n" +
        "    QDateTime::currentMSecsSinceEpoch();\n" +
        "    obj->doThing();\n" +
        "    ghostCall();\n" +
        "    return 0;\n" +
        "}\n"
    writeFileAtomic("${root}/demo.cpp", src)
    try {
        let g = buildGraph(root)
        var sawGhost = false
        for ((_, name, _) in g.unresolvedCalls) {
            // 限定/箭头调用豁免
            @Assert(name != "currentMSecsSinceEpoch")
            @Assert(name != "doThing")
            // 负向防线：真幻觉名照报
            if (name == "ghostCall") { sawGhost = true }
        }
        @Assert(sawGhost)
    } finally {
        removePathIfExists(root)
    }
}

/// 规范层（export.cj）：Canvas2D 子集常量 + 导出格式解析。
/// 方法清单是平台移植的验收标准（文档引用它）——动清单必须过这条测试。
@Test
func testCanvasSubsetAndGraphFormatParsing(): Unit {
    // 清单完整性锚点：26 项，关键项逐一点名
    @Assert(CANVAS2D_SUBSET.size == 26)
    let must = ["beginPath", "fill", "stroke", "bezierCurveTo", "arcTo",
                "setLineDash", "fillText", "globalAlpha", "textAlign"]
    for (m in must) {
        @Assert(CANVAS2D_SUBSET.contains(m))
    }
    // 验收函数：全覆盖 = 合规；缺 bezierCurveTo = 不合规
    let full = ArrayList<String>(CANVAS2D_SUBSET)
    @Assert(canvasSubsetCompliant(full))
    let broken = ArrayList<String>(CANVAS2D_SUBSET)
    broken.remove(at: 12)
    @Assert(!canvasSubsetCompliant(broken))
    // 格式解析：六值 + 空串回落默认 + 未知返回 None
    match (parseGraphFormat("scene", GraphExportFormat.Html)) {
        case Some(f) =>
            match (f) {
                case Scene => ()
                case _ => @Assert(false)
            }
        case None => @Assert(false)
    }
    match (parseGraphFormat("", GraphExportFormat.Html)) {
        case Some(f) =>
            match (f) {
                case Html => ()
                case _ => @Assert(false)
            }
        case None => @Assert(false)
    }
    @Assert(parseGraphFormat("svg", GraphExportFormat.Html).isNone())
    @Assert(graphFormatList(ArrayList<GraphExportFormat>([GraphExportFormat.Html, GraphExportFormat.Scene])) == "html | scene")
}

/// M12 回归：未分层（层 4）的模块不许参与违规判定。
/// 原实现 `la < lb` 把层 4 当成「最高层」⇒ docs / scripts / `(root)`
/// 的全部入边都被记成违规（现实中极常见，等于噪声常态满格）。
@Test
func testLayerViolationIgnoresUnclassifiedModules(): Unit {
    // 已分层之间：低层依赖高层确实是违规
    @Assert(isLayerViolation(0, 1))
    @Assert(isLayerViolation(2, 3))
    // 高层依赖低层不是违规
    @Assert(!isLayerViolation(3, 0))
    @Assert(!isLayerViolation(1, 1))
    // 任一侧未分层（4）⇒ 无法判定，不是违规
    @Assert(!isLayerViolation(0, 4))
    @Assert(!isLayerViolation(4, 0))
    @Assert(!isLayerViolation(4, 4))
    @Assert(!isLayerViolation(3, 4))
}

/// M11：架构图出口的边序必须是全序（物化处不定序 ⇒ 字节序跟着 HashMap 走）。
/// 这条钉的是「出口看起来是确定的」而不是「某一种写法」。
@Test
func testArchEdgesAreInTotalOrder(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let arch = buildArch(g)
        var prev = ""
        for (e in arch.edges) {
            let key = e.fromId + "\u{1f}" + e.toId
            @Assert(key >= prev)
            prev = key
        }
        // 违规对同样要有序
        var prevV = ""
        for ((a, b) in arch.violationPairs) {
            let key = a + "\u{1f}" + b
            @Assert(key >= prevV)
            prevV = key
        }
    } finally {
        removeTree(root)
    }
}

/// H3 源码守卫：引用边的**物化处**必须有一次全序排序。
///
/// 为什么行为断言不够（负控 NC3 实测）：本工具链的 HashMap 迭代序在单进程内
/// 恰好是有序的，于是把排序删掉后 `testRefEdgesMaterializeInTotalOrder` 仍然绿 ——
/// 「当前观察不到违规」不等于「契约被守住」。守约的是**这一段有排序**这个事实，
/// 那就用源码守卫钉它（与 __lintConfigKeyTableMatchesBothAccessors 同一纪律）。
@Test
func __lintRefEdgesMaterializationHasATotalOrder(): Unit {
    let raw = readFileTextChecked("src/graph/build.cj").getOrThrow()
    let sb = StringBuilder()
    var blk = CjStripState.Normal
    for (r in raw.split("\n")) {
        let (l, nb) = stripCjCommentEx(r, blk)
        blk = nb
        sb.append(l)
        sb.append("\n")
    }
    let code = sb.toString()
    // 「物化处」的锚：紧跟两层 HashMap 迭代填 refEdges 之后，必须出现排序调用。
    let anchor = code.indexOf("let refEdges = ArrayList<(String, String, Int64)>()")
    @Assert(anchor.isSome())
    let tail = code[anchor.getOrThrow()..]
    let sortAt = tail.indexOf("insertionSortBy(refEdges")
    @Assert(sortAt.isSome())     // 物化处必须有排序
    // 排序必须在物化之后、且在同一个函数的窗口内（不许挪到别处）
    let addAt = tail.indexOf("refEdges.add((from, to, count))")
    @Assert(addAt.isSome())
    @Assert(sortAt.getOrThrow() > addAt.getOrThrow())
    @Assert(sortAt.getOrThrow() - addAt.getOrThrow() < 200)
    // 全序要补到最后一位：from / to / count 三个键都得出现
    let window = tail[0..(if (sortAt.getOrThrow() + 200 < tail.size) { sortAt.getOrThrow() + 200 } else { tail.size })]
    @Assert(window.contains("a[0] != b[0]"))
    @Assert(window.contains("a[1] != b[1]"))
    @Assert(window.contains("a[2] < b[2]"))
}

/// M11 回归：场景导出必须逐字节一致。
/// archscene.cj 的文件头原来写着「graph_test 有守护」，而**那条测试不存在**
/// —— 声明本身就成了掩盖。这条钉住两件事：边序是排序的、meta 的截断披露在。
@Test
func testSceneExportIsDeterministic(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let s1 = Json.pretty(buildArchScene(buildArch(g), false))
        let s2 = Json.pretty(buildArchScene(buildArch(g), false))
        @Assert(s1 == s2)
        // 场景里的 token 必须是 themes 里存在的键（M13：panel 原先不在表里）
        let j = buildArchScene(buildArch(g), false)
        let th = Json.getOr(j, "themes")
        for (themeName in ["dark", "light"]) {
            let th1 = Json.getOr(th, themeName)
            for (k in ["bg0", "bg1", "grid", "text", "muted", "border", "arrow", "accent", "panel"]) {
                @Assert(Json.has(th1, k))
            }
        }
        // 每视图恒发 edgesDropped（截断披露，不变量 33）
        let views = Json.getOr(j, "views")
        match (views) {
            case JObj(items) =>
                @Assert(items.size > 0)
                for ((_, viewVal) in items) {
                    @Assert(Json.has(viewVal, "edgesDropped"))
                }
            case _ => @Assert(false)
        }
        // chips 必须带独立的 count 数字字段（M14）
        let metaObj = Json.getOr(j, "meta")
        let chipsRaw = Json.getOr(metaObj, "chips")
        let chips = match (chipsRaw) {
            case JArr(items) => items
            case _ => ArrayList<JsonValue>()
        }
        if (chips.size > 0) {
            for (c in chips) {
                @Assert(Json.has(c, "count"))
                @Assert(Json.has(c, "layer"))
                @Assert(Json.has(c, "label"))
            }
        }
    } finally {
        removeTree(root)
    }
}

/// G6 回归（契约A 引擎侧）：walkSources 丢弃 listDirChecked 的 readable
/// 标志 ⇒ 读不到的子树与空目录在图谱里完全同构（root 读不到时产物是
/// 全清空图谱、零披露）。行为测试借 execCapture 调 /bin/chmod 000 造
/// 读不出来的目录（#179 同款先例；仓颉 std 无权限 API）。
@Test
func testWalkSourcesCollectsUnreadableDirs(): Unit {
    let root = "${tempDirPath()}/cambium-unread-${getpid()}-${nowMillis()}"
    ensureDir("${root}/locked")
    ensureDir("${root}/open")
    writeFileAtomic("${root}/locked/hidden.cj", "package p\n\nfunc hidden(): Int64 { return 1 }\n")
    writeFileAtomic("${root}/open/visible.cj", "package p\n\nfunc visible(): Int64 { return 2 }\n")
    // 造读不出来的目录（chmod 000）。测完必须还原，否则删不掉。
    _ = execCapture("/bin/chmod", ["000", "${root}/locked"], None, 5000)
    try {
        let g = buildGraph(root)
        // 字段被填：locked 收进来了（相对路径口径，与 relPath 一致）
        @Assert(Int64(g.unreadableDirs.size) == 1)
        @Assert(g.unreadableDirs[0] == "locked")
        // 可读子树的文件照常进图谱
        var sawVisible = false
        for (f in g.files) {
            if (f.relPath == "open/visible.cj") { sawVisible = true }
        }
        @Assert(sawVisible)
        // 锁住的子树文件静默缺席——这正是必须有披露字段的理由
        var sawHidden = false
        for (f in g.files) {
            if (f.relPath == "locked/hidden.cj") { sawHidden = true }
        }
        @Assert(!sawHidden)
    } finally {
        // 还原权限，否则 removePathIfExists 也清不掉
        _ = execCapture("/bin/chmod", ["755", "${root}/locked"], None, 5000)
        removePathIfExists(root)
    }
}

/// G6 默认态：全部可读 → unreadableDirs 为空（存在且空，不是缺字段）。
@Test
func testUnreadableDirsDefaultsEmptyOnReadableTree(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        @Assert(Int64(g.unreadableDirs.size) == 0)
    } finally {
        removeTree(root)
    }
}

func countOf(hay: String, needle: String): Int64 {
    var n: Int64 = 0
    var from: Int64 = 0
    while (true) {
        let hit = indexOfStrFrom(hay, needle, from)
        if (hit < 0) { break }
        n += 1
        from = hit + needle.size
    }
    return n
}

/// G8 回归（契约B 引擎侧）：impact 采集的上限原先静默截断——「还有更多
/// 没列出」与「只有这些」在结果里同构。可注入小上限验证两个 capped 标志。
/// 走真实路径：buildGraph + impactOf。
@Test
func testImpactCappedFlagsOnSmallBudget(): Unit {
    let root = "${tempDirPath()}/cambium-cap-${getpid()}-${nowMillis()}"
    ensureDir("${root}/util")
    ensureDir("${root}/a1")
    ensureDir("${root}/a2")
    ensureDir("${root}/a3")
    ensureDir("${root}/b")
    writeFileAtomic("${root}/util/core.cj", "package p\n\npublic func core(): Int64 { return 1 }\n")
    writeFileAtomic("${root}/a1/use1.cj", "package q\n\npublic func u1(): Int64 { return core() }\n")
    writeFileAtomic("${root}/a2/use2.cj", "package q\n\npublic func u2(): Int64 { return core() }\n")
    writeFileAtomic("${root}/a3/use3.cj", "package q\n\npublic func u3(): Int64 { return core() }\n")
    // b 一个文件里 5 个符号——供「refFiles 未触顶而 impacted 触顶」的分离场景
    writeFileAtomic("${root}/b/user.cj", "package q\n\npublic func b1(): Int64 { return core() }\npublic func b2(): Int64 { return core() }\npublic func b3(): Int64 { return core() }\npublic func b4(): Int64 { return core() }\npublic func b5(): Int64 { return core() }\n")
    try {
        let g = buildGraph(root)
        // 未触顶（引用文件 4 个、波及符号 8 个，上限 10）：两标志 false
        match (impactOf(g, "core", 10)) {
            case Some(r) =>
                @Assert(!r.refFilesCapped)
                @Assert(!r.impactedCapped)
                @Assert(Int64(r.refFiles.size) == 4)
                @Assert(Int64(r.impactedSymbols.size) == 8)
            case None => @Assert(false)
        }
        // 双触顶（上限 2 < 引用文件数 4）
        match (impactOf(g, "core", 2)) {
            case Some(r) =>
                @Assert(r.refFilesCapped)
                @Assert(r.impactedCapped)
                @Assert(Int64(r.refFiles.size) == 2)
            case None => @Assert(false)
        }
        // 单触顶（上限 5 > 引用文件数 4 但 < 波及符号数 8）：impacted 置位
        match (impactOf(g, "core", 5)) {
            case Some(r) =>
                @Assert(!r.refFilesCapped)
                @Assert(r.impactedCapped)
                @Assert(Int64(r.impactedSymbols.size) == 5)
            case None => @Assert(false)
        }
        // 原签名保持可用（cli.cj / mcp.cj 的既有调用面），默认 200 不触顶
        match (impactOf(g, "core")) {
            case Some(r) =>
                @Assert(!r.refFilesCapped)
                @Assert(!r.impactedCapped)
            case None => @Assert(false)
        }
    } finally {
        removePathIfExists(root)
    }
}

// MARK: - 审查回归（audit-2026-10-11 第三波）：low 级问题修复

/// L1 回归：goReceiverMethodName 的入口 gate 原先只认 `func (` 与 `func(`
/// 两种字面写法——`func\t(…)`（tab）与 `func  (…)`（双空格）落不进任何一支，
/// 方法声明回落旧路径（scanDeclLine 把接收者变量名当 tokens[i+1] 抽成符号，
/// G1 缺陷的残留入口）。修法：入口只判 `func` 前缀，括号定位交给与函数内部
/// 字节循环同一套「任意数量空格/tab 之后紧跟 '('」的判定。
@Test
func testGoReceiverMethodNameAcceptsArbitraryWhitespace(): Unit {
    // 直调判定：tab / 双空格 / 单空格 / 紧贴四种形态都抽方法真名
    match (goReceiverMethodName("func\t(r *Rect) Area() float64 {")) {
        case Some(n) => @Assert(n == "Area")
        case None => @Assert(false)
    }
    match (goReceiverMethodName("func  (q *Rect) Perimeter() float64 {")) {
        case Some(n) => @Assert(n == "Perimeter")
        case None => @Assert(false)
    }
    match (goReceiverMethodName("func (r *Rect) Area() float64 {")) {
        case Some(n) => @Assert(n == "Area")
        case None => @Assert(false)
    }
    match (goReceiverMethodName("func(r *Rect) Area() float64 {")) {
        case Some(n) => @Assert(n == "Area")
        case None => @Assert(false)
    }
    // 负向：非 func 开头、func 后接非空白非括号（如 function make）不误判
    @Assert(goReceiverMethodName("class (x) Foo(").isNone())
    @Assert(goReceiverMethodName("function make(").isNone())
    @Assert(goReceiverMethodName("funcName(self)").isNone())
    // 走真实路径（scanSource）：tab/双空格变体抽出方法真名、接收者不进符号表
    let src = "package main\n" +
        "func\t(r *Rect) Area() float64 {\n\treturn 1\n}\n" +
        "func  (q *Rect) Perimeter() float64 {\n\treturn 2\n}\n"
    let f = scanSource(src, "go")
    let names = ArrayList<String>()
    for (s in f.symbols) { names.add(s.name) }
    @Assert(names.contains("Area"))
    @Assert(names.contains("Perimeter"))
    @Assert(!names.contains("r"))
    @Assert(!names.contains("q"))
}

/// L2 回归（单元层）：行内 `/* ... */` 摘除后必须以一个空格占位——注释在真实
/// 语言里等价空白，是 token 边界。原实现完全消失 ⇒ `a/*c*/b(` 粘连成 `ab(`。
/// 同时钉住「紧贴括号的调用形态不因占位回退」。
@Test
func testInlineBlockCommentKeepsTokenBoundary(): Unit {
    let (t, st) = stripCode("a/*c*/b(", 0)
    @Assert(st == 0)
    @Assert(!t.contains("ab"))      // 粘连名不许出现
    @Assert(t.contains("a b("))     // 注释处是空格，b( 仍是紧贴调用形态
    // 原有 `x(` 调用检测语义不回退：块注释前后的紧贴调用都保留
    let (u, us) = stripCode("x(1) /* tail */ y(2)", 0)
    @Assert(us == 0)
    @Assert(u.contains("x(1)"))
    @Assert(u.contains("y(2)"))
}

/// L2 回归（端到端）：`a/*c*/b(` 不产生 unresolved-call ab（全仓不存在的
/// 编造名）；真幻觉名照报（判据不回退）；有定义的 b 照常解析。
/// 走真实路径：buildGraph（第二遍位置感知扫描）。
@Test
func testInlineBlockCommentGlueDoesNotFabricateCalls(): Unit {
    let root = "${tempDirPath()}/cambium-glue-${getpid()}-${nowMillis()}"
    ensureDir(root)
    writeFileAtomic("${root}/glue.c", """
#include <stdlib.h>

int b(int x) { return x; }

int step(int v) {
    a/*c*/b(1);
    ghost(2);
    return v;
}
""")
    try {
        let g = buildGraph(root)
        var sawGlued = false
        var sawGhost = false
        for ((_, name, _) in g.unresolvedCalls) {
            if (name == "ab") { sawGlued = true }
            if (name == "ghost") { sawGhost = true }
            // b 有定义：注释占位后 b 与 ( 仍紧贴、照常解析为对 b 的调用
            @Assert(name != "b")
        }
        @Assert(!sawGlued)   // 粘连编造名 ab 不许出现（修复前它是唯一报法）
        @Assert(sawGhost)    // 真幻觉名照报（负向防线）
    } finally {
        removePathIfExists(root)
    }
}

// MARK: - 审查回归（audit-2026-10-11 第四波）：扫描器假符号
//
// 两组假符号实证（引擎自身图谱，修前 graph symbol 快照）：
//   · Json —— src/flow/status.cj:703 的 `let def = Json.obj()`（def 撞
//     python 声明词，RHS 的 Json 被取成名字）与 704/705 的
//     `Json.set(def, "isCurrent", …)`（def 是**实参**）各编出一个
//     kind=func、name=Json。三个假符号里只有一个是 let 行：
//     只拦 let 清不了零，声明词还必须按语言门控（def 只属于 python）。
//   · line —— src/cli/cli_test.cj:1685 测试函数体内的 `func line(...)`
//     按文件级入索引，超通用名 + 词法吸附把全仓含 line 一词的文件
//     都吸成了引用边。
// 走真实路径：buildGraph（scanSource）。

@Test
func testLocalBindingsAndNestedFuncsProduceNoSymbols(): Unit {
    let root = "${tempDirPath()}/cambium-scan-fake-${getpid()}-${nowMillis()}"
    ensureDir(root)
    writeFileAtomic("${root}/demo.cj", """
package demo

public class Holder {
    public func fill(): Int64 {
        let def = Json.obj()
        Json.set(def, "isCurrent", Json.of(true))
        let cur = Json.obj()
        return cur.size
    }
}

public func outer(): Int64 {
    func line(s: String): Int64 {
        return s.size
    }
    return line("x")
}

public class Repo {
    public func scanAll(): Int64 { return 1 }
    public func loadAll(): Int64 { return 2 }
}

public func after(): Int64 {
    return 1
}
""")
    try {
        let g = buildGraph(root)
        var names = ArrayList<String>()
        for (f in g.files) {
            for (s in f.symbols) { names.add(s.name) }
        }
        // (a) let/var/const 绑定行与撞名实参行都不产生符号（修前 Json×3）
        @Assert(!names.contains("Json"))
        // (b) 函数体内嵌套的 func 不按文件级入索引（修前 line×1）
        @Assert(!names.contains("line"))
        // 外层声明必须都还在——这既是修复要求，也是前提守卫（不变量 18）：
        // 夹具真的被扫描过，上面的「无」不是空树上的空转绿
        @Assert(names.contains("Holder"))
        @Assert(names.contains("fill"))
        @Assert(names.contains("outer"))
        // (c) 防修过头：类型体内的方法照常入索引
        @Assert(names.contains("Repo"))
        @Assert(names.contains("scanAll"))
        @Assert(names.contains("loadAll"))
        // 防修过头：类体收拢后的文件级函数不受栈残留影响
        @Assert(names.contains("after"))
    } finally {
        removePathIfExists(root)
    }
}

/// (d) 三引号字符串里的 `{` 与声明样文本不污染花括号栈。
/// 若花括号计数用了原始行而不是 stripCode 剥后文本，doc 体里三引号内容
/// 的两个**未闭合** `{` 会把栈顶顶成 Func，afterTail 被误判成嵌套函数
/// 而从符号表消失——「有 afterTail」就是栈未被污染的判据
/// （未闭合的 `{` 比自平衡的 `{ … }` 更狠：自平衡行净零本来就不动栈）。
@Test
func testTripleQuotedBracesDoNotPolluteBraceStack(): Unit {
    let root = "${tempDirPath()}/cambium-scan-triple-${getpid()}-${nowMillis()}"
    ensureDir(root)
    let q = "\"\"\""
    let src = "public func doc(): String {\n" +
        "    let s = " + q + "\n" +
        "func fake(): Int64 {\n" +
        "class FakeBody {\n" +
        q + "\n" +
        "    return s\n" +
        "}\n" +
        "\n" +
        "public func afterTail(): Int64 {\n" +
        "    return 2\n" +
        "}\n"
    writeFileAtomic("${root}/doc.cj", src)
    try {
        let g = buildGraph(root)
        var names = ArrayList<String>()
        for (f in g.files) {
            for (s in f.symbols) { names.add(s.name) }
        }
        // 三引号内的声明样文本不进符号表（stripCode 既有能力，钉住不退化）
        @Assert(!names.contains("fake"))
        @Assert(!names.contains("FakeBody"))
        // doc 与其后的文件级函数都在——afterTail 存在即证明三引号内的
        // 未闭合 `{` 没有把栈顶污染成 Func
        @Assert(names.contains("doc"))
        @Assert(names.contains("afterTail"))
    } finally {
        removePathIfExists(root)
    }
}

// MARK: - 扫描器假符号第二波：假 import 与 cangjie 声明词表修正
//
// 残留违规对实证（修前 cjc 等价扫描器对引擎全仓的 IMP/SYM 清单）：
//   · graph_test.cj:68  —— 三引号夹具内行首 `from flow.update import …`
//     被编成假 import "flow"，命中 src/flow 目录段 → graph_test.cj →
//     src/flow/*.cj 的假 import 边；:57/:163 的 Foundation/fmt 同源；
//   · graph_test.cj:1215 —— 仓颉里 `from` 是合法变量名，
//     `from = hit + open.size` 被编成假 import "hit"；
//   · cangjie 声明词表错放了 swift 的 extension（仓颉保留词是 extend）：
//     `obj.extension(x)` 这类标识符行会编 (Extension, x)，而仓内真实的
//     `extend String {`（text.cj:478、各 strx.cj）反而全部漏出符号索引。
// 走真实路径：buildGraph（scanSource）。

@Test
func testImportsInsideTripleQuotesAndFromBindingAreNotFacts(): Unit {
    let root = "${tempDirPath()}/cambium-scan-imp-${getpid()}-${nowMillis()}"
    ensureDir(root)
    // 夹具内含三引号字符串：仓颉多行字符串不支持转义，用拼接构造
    let q = "\"\"\""
    let src = "package demo\n\n" +
        "import cambium.util\n\n" +
        "public func doc(): String {\n" +
        "    let s = " + q + "\n" +
        "import Foundation\n" +
        "from flow.update import runUpdate\n" +
        "use std::collections::HashMap\n" +
        q + "\n" +
        "    return s\n" +
        "}\n\n" +
        "public func sweep(): Int64 {\n" +
        "    var from = 0\n" +
        "    from = 1\n" +
        "    return from\n" +
        "}\n"
    writeFileAtomic("${root}/demo.cj", src)
    try {
        let g = buildGraph(root)
        var imports = ArrayList<String>()
        for (f in g.files) {
            for (imp in f.imports) { imports.add(imp) }
        }
        // 真 import 必须还在（前提守卫：夹具真的被扫描过）
        @Assert(imports.contains("util"))
        // 三引号字符串里的行首 import/from/use、以及 `from = 1` 变量赋值行，
        // 都不是 import 事实——修前 flow / 1 / Foundation / std 全部混进来
        @Assert(!imports.contains("flow"))
        @Assert(!imports.contains("1"))
        @Assert(!imports.contains("Foundation"))
        @Assert(!imports.contains("std"))
        // 整个文件只有真 import 一条 —— 最强口径：多编任何一条都红
        @Assert(imports.size == 1)
    } finally {
        removePathIfExists(root)
    }
}

@Test
func testCangjieExtendIsIndexedAndExtensionIsNot(): Unit {
    let root = "${tempDirPath()}/cambium-scan-ext-${getpid()}-${nowMillis()}"
    ensureDir(root)
    writeFileAtomic("${root}/demo.cj", """
package demo

extend String {
    public func blankish(): Bool {
        return true
    }
}

public func probe(x: Int64): Int64 {
    let extension = x
    probe2(extension)
    return extension
}

public func probe2(v: Int64): Int64 {
    return v
}
""")
    try {
        let g = buildGraph(root)
        var names = ArrayList<String>()
        for (f in g.files) {
            for (s in f.symbols) {
                names.add(symKindId(s.kind) + ":" + s.name)
            }
        }
        // 仓颉扩展是真模块级声明：`extend String {` 入索引（Extension 种类），
        // 扩展体内的方法照常入索引（栈顶是 Extension，方法不属嵌套）
        @Assert(names.contains("extension:String"))
        @Assert(names.contains("func:blankish"))
        // swift 拼写的 extension 在 cangjie 是合法标识符：
        // `let extension = x` 修前编出 extension:"x"、`probe2(extension)`
        // 修前编出 extension:"probe2"（名字取实参 token），都不得再编
        @Assert(!names.contains("extension:extension"))
        @Assert(!names.contains("extension:x"))
        @Assert(!names.contains("extension:probe2"))
        // 外层函数仍在（前提守卫，同不变量 18）
        @Assert(names.contains("func:probe"))
        @Assert(names.contains("func:probe2"))
    } finally {
        removePathIfExists(root)
    }
}

// MARK: - 扫描器假符号第三波：插值字符串的引号错位泄漏
//
// 实证（cjc 等价扫描器对引擎自身 confidence 复算）：stripCode 的单行字符串
// 状态不感知 `${…}` 插值——`${Json.strAt(status, "name", "")}` 的内嵌引号被
// 当成字符串闭合，`${Json.strAt(status, ` 成为「字符串内容」被吞、name 等片段
// **泄漏进剥后文本**成为假 token，被自由调用扫描编出全仓不存在的
// unresolved-call "namekindgit"（实证 cli.cj:2382，name/kind/git 泄漏片段粘连）。
// 泄漏 token 还会进引用计数污染引用边。修法：state=1 内 `${` 触发花括号深度
// 计数整段跳过（段内嵌套串跳到其闭合引号）。
// 走真实路径：buildGraph（第二遍位置感知扫描消费同一套 stripCode）。

@Test
func testInterpolatedStringQuotesDoNotLeakTokens(): Unit {
    // 真实行转录（cli.cj:2382 的插值形态）。仓颉单行字符串的裸 `${` 会触发
    // 编译期插值解析，引号与 ${ 全部用字节构造。
    let dq = fromUtf8Lossy([UInt8(34)])                    // "
    let dl = fromUtf8Lossy([UInt8(36), UInt8(123)])        // ${
    // tail 在第一个字符串的剩余内容里（"} tail here"）——修前引号错位把它
    // 泄漏进代码区，修后随字符串整段剥除
    let line = "printOut(T(" + dq + dl + "Json.strAt(status, " + dq + "name" + dq + ", " + dq + dq + ")" + dq + "  " + dq + dl + "if (Json.strAt(status, " + dq + "kind" + dq + ", " + dq + dq + ") == " + dq + "git" + dq + ")" + dq + " tail here" + dq + "))"
    let (t, st) = stripCode(line, 0)
    // 修前推演：`${Json.strAt(status, ` 被内嵌引号「闭合」吞掉，name/kind/git
    // 依次泄漏（裸相邻粘连出 namekindgit——真实引擎实证的假指控 token），
    // 尾段 tail here 同样泄漏——三条都是修前红的断言（负控有效）
    @Assert(!t.contains("name"))
    @Assert(!t.contains("namekindgit"))
    @Assert(!t.contains("tail"))
    // 行尾引号配平，状态复位（否则一行泄漏吞掉整个文件的后续扫描）
    @Assert(st == 0)
}

@Test
func testInterpolatedLineYieldsNoFabricatedUnresolvedCall(): Unit {
    let root = "${tempDirPath()}/cambium-scan-ipt-${getpid()}-${nowMillis()}"
    ensureDir(root)
    let dq = fromUtf8Lossy([UInt8(34)])                    // "
    let dl = fromUtf8Lossy([UInt8(36), UInt8(123)])        // ${
    let real = "printOut(T(" + dq + dl + "Json.strAt(status, " + dq + "name" + dq + ", " + dq + dq + ")" + dq + "  " + dq + dl + "if (Json.strAt(status, " + dq + "kind" + dq + ", " + dq + dq + ") == " + dq + "git" + dq + ")" + dq + "))"
    let src = "package demo\n\n" +
        "public func show(): Int64 {\n" +
        "    " + real + "\n" +
        "    return 1\n" +
        "}\n"
    writeFileAtomic("${root}/demo.cj", src)
    try {
        let g = buildGraph(root)
        // 修前推演：泄漏片段里 strAt( 与 if ( 恰成「自由调用」形态——
        // strAt/status/if 全不在夹具定义里，被指控幻觉调用（真实引擎上
        // 同一行族泄漏粘连出全仓不存在的 namekindgit，同族形态）。
        // 修后插值段整段剥净，这些指控全部消失。
        for ((_, name, _) in g.unresolvedCalls) {
            @Assert(name != "strAt")
            @Assert(name != "status")
            @Assert(name != "if")
            @Assert(name != "namekindgit")
        }
    } finally {
        removePathIfExists(root)
    }
}

// MARK: - 图能力重设计第一阶段：探针 / store_meta / index payload / render 两段

/// 探针判据与构建扫描同源（钉子）：sourceProbeNow 与 buildGraphProbed
/// 在同一源状态上必须产出**相等**的探针——两处各一份 skip/识别判定的话，
/// 这里迟早红；而这条绿着才能保证 index update 的「已最新」说的是真话。
@Test
func testSourceProbeMatchesBuildScan(): Unit {
    let root = writeTree()
    try {
        // writeTree：3 个源码文件（.cj×2 + .swift + .py）+ README.md（非源码，不进探针）
        let probeNow = sourceProbeNow(root)
        @Assert(probeNow.files == 4)
        @Assert(probeNow.bytes > 0)
        @Assert(probeNow.maxMtime > 0)
        let (g, probeBuild) = buildGraphProbed(root)
        @Assert(Int64(g.files.size) == 4)
        // 同一源状态：两条路径的探针逐分量相等（判据同源的硬断言）
        @Assert(probeMatches(probeNow, probeBuild))
        // 源未变：两次轻探针相等
        @Assert(probeMatches(probeNow, sourceProbeNow(root)))
        // 源变化（改内容）：bytes 与 maxMtime 至少一个变 → 探针不再相等
        writeFileAtomic("${root}/util/text.cj", "package cambium.util\n\npublic class Text2 {\n    public func trimAll(s: String): String {\n        return s\n    }\n}\n")
        let probeAfter = sourceProbeNow(root)
        @Assert(!probeMatches(probeNow, probeAfter))
        @Assert(probeAfter.bytes != probeNow.bytes)
        // 源变化（新增源码文件）：files 变
        ensureDir("${root}/newpkg")
        writeFileAtomic("${root}/newpkg/extra.cj", "package newpkg\npublic func e(): Int64 { return 1 }\n")
        let probeAdded = sourceProbeNow(root)
        @Assert(probeAdded.files == probeNow.files + 1)
        // 非源码文件不计入：加 README 不动探针
        writeFileAtomic("${root}/README.md", "# longer readme\n")
        @Assert(probeMatches(probeAdded, sourceProbeNow(root)))
        // 跳过目录不计入：node_modules 里的源码不是源状态的一部分（与构建同判据）
        ensureDir("${root}/node_modules")
        writeFileAtomic("${root}/node_modules/x.cj", "package x\npublic func nx(): Int64 { return 2 }\n")
        @Assert(probeMatches(probeAdded, sourceProbeNow(root)))
    } finally {
        removeTree(root)
    }
}

/// 探针的持久化 round-trip：toJson → 文本 → 解析回来逐分量相等；
/// 缺键 / 非法 JSON 必须是 None——「读不出来」不许被当成「源没变」。
@Test
func testSourceProbeJsonRoundTrip(): Unit {
    let p = SourceProbe(3, 456, 1720000000000)
    let text = Json.pretty(p.toJson())
    match (sourceProbeFromText(text)) {
        case Some(back) =>
            @Assert(probeMatches(back, p))
        case None => @Assert(false)
    }
    @Assert(sourceProbeFromText("{").isNone())
    @Assert(sourceProbeFromText("{}").isNone())
    @Assert(sourceProbeFromText("{\"files\":1,\"bytes\":2}").isNone())
    @Assert(sourceProbeFromJson(JNull).isNone())
}

/// 架构图（archhtml.cj 生成）：节点详情面板给模块路径 + 复制，复制带同样的兜底。
@Test
func testArchHtmlModulePathCopyHooks(): Unit {
    let root = writeTree()
    try {
        let arch = buildArch(buildGraph(root))
        layoutArch(arch)
        let json = Json.pretty(archJson(arch, false))
        let html = renderArchHtml(json, false)
        @Assert(html.contains("复制模块路径"))
        @Assert(html.contains("复制文件路径"))
        @Assert(html.contains("data-copy="))
        @Assert(html.contains("class=\"copybtn\""))
        @Assert(html.contains("navigator.clipboard.writeText"))
        @Assert(html.contains("document.execCommand('copy')"))
        @Assert(html.contains("createElement('textarea')"))
        @Assert(html.contains("clip-fallback"))
        @Assert(html == renderArchHtml(json, false))
        @Assert(renderArchHtml(json, true).contains("Copy module path"))
        // 架构产物里没有本机绝对路径
        @Assert(!html.contains(root))
    } finally {
        removeTree(root)
    }
}
