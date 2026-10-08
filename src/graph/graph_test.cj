// graph/graph_test.cj — 图谱包的单测。
//
// 【测试隔离】临时目录按 pid + 时间戳命名，用完整树删除；
// 不碰 DEEPGIT_HOME（图谱不依赖引擎配置，天然隔离）。
package moongit.graph

import std.collection.*
import std.env.*
import std.fs.*
import std.posix.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

func testRoot(): String {
    let pid = getpid()
    return "${tempDirPath()}/moongit-graph-test-${pid}"
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
package moongit.util

import std.collection.*

public class Text {
    public func trimAll(s: String): String {
        return s
    }
}
""")
    writeFileAtomic("${root}/flow/update.cj", """
package moongit.flow

import moongit.util.*

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

func removeTree(dir: String): Unit {
    // 1.0.5 的 std.fs 没有公开的删除入口（File/Directory 均无 delete/remove）；
    // 测试临时目录残留在 TMPDIR 下无害，交由系统清理。别为删除引入
    // git rm -rf 之类的进程依赖 —— 测试不该反过来依赖引擎的能力。
    let _ = dir
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
    let f = scanSource(src)
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
package moongit.flow

import moongit.util.*

public func runUpdate(): Bool { return true }
public class Updater { }
"""
    let f = scanSource(cj)
    // ⚠️ 推翻旧断言：这里原本是 `imports[0] == "moongit"`（首段）—— 那是把缺陷
    // 写成了断言（`import moongit.util.*` 的语义在**末段** `util`；取首段 `moongit`
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
    let g = scanSource(go)
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
    let f = scanSource(py)
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
    @Assert(scanSource("import moongit.util.*\n").imports[0] == "util")
    @Assert(scanSource("import Foundation\n").imports[0] == "Foundation")
    // Swift 别名 `import X as Y` → 取 X，不是别名 Y
    @Assert(scanSource("import CoreGraphics as CG\n").imports[0] == "CoreGraphics")
    @Assert(scanSource("from flow.update import runUpdate\n").imports[0] == "flow")
    @Assert(scanSource("use std::collections::HashMap\n").imports[0] == "std")
    @Assert(scanSource("import \"net/http\"\n").imports[0] == "http")
}

@Test
func testTodoMarkerShape(): Unit {
    // ⚠️ 标记字面量**必须拼接构造**：直接写出「注释开头的标记」会被本检测器
    // 扫到自己的测试数据（`AGENTS.md` 不变量 55：needle 字面量在源码里 ⇒ 匹配到自己）。
    let td = "TO" + "DO"
    let fx = "FIX" + "ME"
    let hk = "HA" + "CK"
    let xx = "X" + "XX"
    // 可执行标记（注释开头处）
    @Assert(containsTodo("// " + td + ": fix the parser"))
    @Assert(containsTodo("//" + td + "(alice): rework"))
    @Assert(containsTodo("  # " + fx + ": broken"))
    @Assert(containsTodo("/* " + hk + ": temporary */"))
    @Assert(containsTodo("// " + xx))
    // 假阳性回归：描述性文字 / 文档里示范标记写法，都不得命中
    @Assert(!containsTodo("// 魔法数字、TODO 残留。它们单看都不致命"))
    @Assert(!containsTodo("// MARK: - ③ TODO 残留"))
    @Assert(!containsTodo("/// 只认可执行标记：`TODO:` / `TODO(owner)`"))
    @Assert(!containsTodo("let x = 1  // 正文里的 TODO 只是提及"))
    @Assert(!containsTodo("let todo = compute()"))
}

func confFixture(): String {
    let root = "${tempDirPath()}/moongit-conf-test-${getpid()}"
    ensureDir("${root}/util")
    ensureDir("${root}/cli")
    writeFileAtomic("${root}/util/a.cj", """
package p

public func usedElsewhere(): Int64 { return 1 }

func localHelper(): Int64 { return 2 }

public func callerOfLocal(): Int64 { return localHelper() }

public func deadOne(): Int64 { return 3 }
""")
    writeFileAtomic("${root}/cli/b.cj", """
package q

public func run(): Int64 { return usedElsewhere() }
""")
    return root
}

func orphanNames(rep: ConfidenceReport): ArrayList<String> {
    let names = ArrayList<String>()
    for (f in rep.findings) {
        match (f.kind) {
            case Orphan => names.add(f.symbol)
            case _ => ()
        }
    }
    return names
}

@Test
func testOrphanIsSymbolLevel(): Unit {
    let root = confFixture()
    try {
        let rep = analyzeConfidence(buildGraph(root), false)
        let names = orphanNames(rep)
        // 定义了、全仓无任何非声明处引用 → 报
        @Assert(names.contains("deadOne"))
        // 仅在同文件内被调用 → 不算孤儿（符号级判定的关键）
        @Assert(!names.contains("localHelper"))
        // 被**别的文件**引用 → 不算孤儿
        @Assert(!names.contains("usedElsewhere"))
    } finally {
        removePathIfExists(root)
    }
}

@Test
func testLexicalDeepNestingAndMagic(): Unit {
    // 纯仓颉夹具（无 tree-sitter 语法 → 走词法路径）：验证词法路径确实产出
    // 深嵌套与魔法数，而不是只剩「超长函数」。
    let root = "${tempDirPath()}/moongit-conf-lex-${getpid()}"
    ensureDir(root)
    writeFileAtomic("${root}/deep.cj", """
package p

public func deep(): Int64 {
    if (a) {
        if (b) {
            if (c) {
                if (d) {
                    if (e) {
                        return 111
                    }
                }
            }
        }
    }
    let x = 222
    let y = 333
    return x + y
}
""")
    try {
        let rep = analyzeConfidence(buildGraph(root), false)
        var deep = false
        var magic = false
        for (f in rep.findings) {
            match (f.kind) {
                case DeepNesting => deep = true
                case MagicNumber => magic = true
                case _ => ()
            }
        }
        @Assert(deep)
        @Assert(magic)
    } finally {
        removePathIfExists(root)
    }
}

@Test
func testFindingsOrderIsTotalAndDeterministic(): Unit {
    // 旧比较器只按 (权重, file, line)：long-function(4) 与 deep-nesting(4) 在同一
    // file:line 上判等 ⇒ 保留输入序 ⇒ 不同输入序产出不同结果。全序后必须一致。
    let a = ArrayList<Finding>()
    a.add(Finding(DeepNesting, "f.cj", 10, "x", "n"))
    a.add(Finding(LongFunction, "f.cj", 10, "x", "l"))
    let b = ArrayList<Finding>()
    b.add(Finding(LongFunction, "f.cj", 10, "x", "l"))
    b.add(Finding(DeepNesting, "f.cj", 10, "x", "n"))
    sortFindings(a)
    sortFindings(b)
    @Assert(flawId(a[0].kind) == flawId(b[0].kind))
    @Assert(flawId(a[1].kind) == flawId(b[1].kind))
    // 并列时按 flawId 兜底："deep-nesting" < "long-function"
    @Assert(flawId(a[0].kind) == "deep-nesting")
}

@Test
func testScoreIsSizeInvariantAndMonotone(): Unit {
    // 关键性质：**与仓库规模无关**。同样的「每文件密度」，文件数乘 10 不该把分压下去。
    // 旧公式 `100 − 惩罚/√文件数` 恰在此处失败（惩罚随文件数线性长、√ 长更慢）。
    @Assert(confidenceScore(20, 1) == confidenceScore(200, 10))
    @Assert(confidenceScore(60, 3) == confidenceScore(600, 30))
    // 无惩罚 = 满分；极稀疏仍高分；极密趋近 0
    @Assert(confidenceScore(0, 50) == 100)
    @Assert(confidenceScore(1, 1000) >= 95)
    @Assert(confidenceScore(100000, 1) == 0)
    // 单调：惩罚越多分越低
    @Assert(confidenceScore(50, 10) > confidenceScore(150, 10))
}

@Test
func testArchMermaidNodeIdsAreInjective(): Unit {
    // 两个模块 id 在「非法字符 → _」的旧映射下会**折叠**（`a-b` 与 `a_b` 都 → `a_b`），
    // 图上两个模块合并成一个节点且不报错。现在按下标映射，必须是两个不同节点。
    let root = "${tempDirPath()}/moongit-archid-${getpid()}"
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
func testAstDetectionIsOrderIndependent(): Unit {
    // 限流（每文件每类 6 条）与重复体「报哪一条」都取决于**处理顺序** ——
    // 而顺序来自外部 ast-grep 进程。检测必须对输入顺序不敏感（否则报哪几条是外部工具
    // 的偶然顺序决定的，既不确定也无原则）。
    let base = ArrayList<AstNode>()
    var i: Int64 = 0
    while (i < 8) {
        base.add(AstNode("f.cj", 10 + i * 3, 12 + i * 3, "fn", "func f${i}() { }"))
        i += 1
    }
    let reversed = ArrayList<AstNode>()
    var k: Int64 = 7
    while (k >= 0) {
        reversed.add(base[k])
        k -= 1
    }
    let fa = ArrayList<Finding>()
    detectFromAst(base, fa)
    let fb = ArrayList<Finding>()
    detectFromAst(reversed, fb)
    // 限流确实生效：8 条 stub 只留 6 条（否则下面「两者相等」会空转成恒真）
    @Assert(Int64(fa.size) == 6)
    @Assert(Int64(fb.size) == 6)
    var j: Int64 = 0
    while (j < Int64(fa.size)) {
        @Assert(flawId(fa[j].kind) == flawId(fb[j].kind))
        @Assert(fa[j].line == fb[j].line)
        j += 1
    }
    // 按位置取前 6 条（行号 10,13,…,25）
    @Assert(fa[0].line == 10)
    @Assert(fa[5].line == 25)
}

@Test
func testStripCodeFastPathMatchesFullScan(): Unit {
    // stripCode 的快路径：**代码态且整行无引号** ⇒ 结果等价于「只剥注释」（零拷贝）。
    // 它必须与逐字节完整扫描**结果一致**（否则是行为变更，不是优化）。
    let ins = ["let x = 1", "// comment", "/* block", "# shell", "  * doc", "-- sql",
        "code // tail", "let s = \"hi\"", "let s = \"hi", "let c = 'x'",
        "let s = \"\"\"abc", "\" ; more", "tail", "*/ tail"]
    let sts: Array<Int64> = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 0]
    let wantOut = ["let x = 1", "", "", "", "", "", "code ", "let s = ", "let s = ", "let c = ",
        "let s = ", " ; more", "", "*/ tail"]
    let wantSt: Array<Int64> = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 0]
    @Assert(ins.size == 14)
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

