// graph/graph_test.cj — 图谱包的单测。
//
// 【测试隔离】临时目录按 pid + 时间戳 + 进程内序号命名，用完整树删除；
// 不碰 DEEPGIT_HOME（图谱不依赖引擎配置，天然隔离）。
package moongit.graph

import std.collection.*
import std.env.*
import std.fs.*
import std.posix.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

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
package moongit.flow

import moongit.util.*

public func runUpdate(): Bool { return true }
public class Updater { }
"""
    let f = scanSource(cj, "cangjie")
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
    @Assert(scanSource("import moongit.util.*\n", "cangjie").imports[0] == "util")
    @Assert(scanSource("import Foundation\n", "swift").imports[0] == "Foundation")
    // Swift 别名 `import X as Y` → 取 X，不是别名 Y
    @Assert(scanSource("import CoreGraphics as CG\n", "swift").imports[0] == "CoreGraphics")
    @Assert(scanSource("from flow.update import runUpdate\n", "python").imports[0] == "flow")
    @Assert(scanSource("use std::collections::HashMap\n", "rust").imports[0] == "std")
    @Assert(scanSource("import \"net/http\"\n", "go").imports[0] == "http")
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
    let root = "${tempDirPath()}/moongit-conf-test-${getpid()}-${nowMillis()}"
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
    let capA = CapDropCounter()
    detectFromAst(base, fa, capA)
    let fb = ArrayList<Finding>()
    let capB = CapDropCounter()
    detectFromAst(reversed, fb, capB)
    // 限流确实生效：8 条 stub 只留 6 条（否则下面「两者相等」会空转成恒真）
    @Assert(Int64(fa.size) == 6)
    @Assert(Int64(fb.size) == 6)
    // 丢弃计数在丢弃判定点发生：8 − 6 = 2（cappedKind 真值来源的接缝守卫——
    // counter 没接进 bumpFinding 时这条会恒 0 而上面照样全绿）
    @Assert(capA.kindDrops == 2)
    @Assert(capB.kindDrops == 2)
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
    // ⚠️ M9 之后 `"/* block"`（整行一个**不闭合**的块注释）会把状态改成 3。
    // 这里钉的是**修好之后**的契约：原先它返回 0，于是下一行的注释内容
    // 全被当成代码 —— 那条输出看起来「注释被剥干净了」，代价在后面几行。
    let ins = ["let x = 1", "// comment", "/* block", "# shell", "  * doc", "-- sql",
        "code // tail", "let s = \"hi\"", "let s = \"hi", "let c = 'x'",
        "let s = \"\"\"abc", "\" ; more", "tail", "*/ tail",
        "a /* inline */ b", "x = 1  # tail", "i--; q", "x = base#anchor",
        "/* only */ let z = 2"]
    let sts: Array<Int64> = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 0,
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
    let wantSt: Array<Int64> = [0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 0,
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



// MARK: - 补丁级置信度（三层）

@Test
func testParseUnifiedDiff(): Unit {
    let diff = "--- a/x.c\n+++ b/x.c\n@@ -1,2 +1,3 @@\n ctx\n-old\n+new1\n+new2\n"
    let (files, errs) = parseUnifiedDiff(diff)
    @Assert(errs == 0)
    @Assert(Int64(files.size) == 1)
    @Assert(files[0].newPath == "x.c")
    var added: Int64 = 0
    for (pl in files[0].lines) {
        if (pl.kind == 1) { added += 1 }
    }
    @Assert(added == 2)
    // 新增行行号：new1 在 +1 起 hunk 的第 2 行（ctx 后）
    var firstAdd: Int64 = -1
    for (pl in files[0].lines) {
        if (pl.kind == 1) { firstAdd = pl.newNo; break }
    }
    @Assert(firstAdd == 2)
}

@Test
func testPatchConfidenceLayers(): Unit {
    let root = writeTree()
    let graph = buildGraph(root)
    try {
        // patch：调用了存在的 Text（解析）+ 不存在的幻觉 fn（未解析）
        let diff = "--- a/flow/update.cj\n+++ b/flow/update.cj\n@@ -1,3 +1,7 @@\n" +
            " package moongit.flow\n+\n+public func patchHelper(t: Text): Bool {\n" +
            "+    let ok = t.trimAll(\"x\")\n+    return ok && ghost_fn(t)\n+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        // S1 部分（有解析也有未解析）
        @Assert(pc.overall > 0.0 && pc.overall < 1.0)
        // 幻觉调用进 uncertain
        var hasGhost = false
        for (u in pc.uncertain) {
            if (uncId(u.kind) == "unresolved_call" && u.id.contains("ghost_fn")) { hasGhost = true }
        }
        @Assert(hasGhost)
        // entity：patchHelper 被识别
        var hasEntity = false
        for (e in pc.entities) {
            if (e.name == "patchHelper") { hasEntity = true }
        }
        @Assert(hasEntity)
        // S7 恒 null（词法层如实披露）
        @Assert(pc.nullSignals.contains("S7"))

        // Layer 3：合并（agent 裁决 resolved/unresolved/deferred 三态）
        let alg = patchConfidenceJson(pc)
        let ag = Json.parse("{\"items\": [{\"id\": \"x\", \"verdict\": \"resolved\", \"confidence\": 1.0}]}").getOrThrow()
        match (mergePatchConfidence(alg, ag)) {
            case Some(m) =>
                // x 不在 uncertain → deferred（agent 处理了不存在的项不影响）
                @Assert(m.overall >= 0.0)
                var hasDeferred = false
                for (e in m.entities) {
                    if (Json.strAt(e, "source", "") == "deferred") { hasDeferred = true }
                }
                @Assert(hasDeferred)   // ghost_fn 项没人裁决 → deferred
            case None => @Assert(false)
        }
    } finally {
        removeTree(root)
    }
}

// MARK: - 审查回归（audit-2026-10-09）

/// H1：一个声明只能生成**一个** entity。原实现把 entities.add 写在「前窥 15 行」
/// 的 while 体内 ⇒ 声明后每跟一行非声明代码就多一个同 id 的 entity；而声明紧跟
/// 另一声明行（首轮即 break）时一条都不生成。测试原先只断言 hasEntity，
/// 两种错都兜不住。
@Test
func testPatchEntityIsOnePerDeclaration(): Unit {
    let root = writeTree()
    try {
        let graph = buildGraph(root)
        let diff = "--- a/flow/update.cj\n+++ b/flow/update.cj\n@@ -1,3 +1,10 @@\n" +
            " package moongit.flow\n+\n+public func patchHelper(t: Text): Bool {\n" +
            "+    let a = 1\n+    let b = 2\n+    return second(t)\n+}\n" +
            "+public func second(t: Text): Bool {\n+    return true\n+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        var n1: Int64 = 0
        var n2: Int64 = 0
        for (e in pc.entities) {
            if (e.name == "patchHelper") { n1 += 1 }
            if (e.name == "second") { n2 += 1 }
        }
        // 3 行函数体 ⇒ 恰好一个（不是 3 个）
        @Assert(n1 == 1)
        // 紧跟在前一个声明之后的声明：原先一条都不生成
        @Assert(n2 == 1)
        @Assert(pc.totalEntities == 2)
        // 前窥行不得重复计入统计：patchHelper 体内恰有一个自由调用 second(t)，
        // totalRelations（= totalRefs）必须恰好是 1 —— 前窥重复统计的旧缺陷会让它变 2
        // （原断言 `x == A || x >= 0` 后一析取恒真，什么都没钉——复审 2026-10-10）
        @Assert(pc.totalRelations == 1)
        // 前向引用只走 use-before-def 一条通道：不再同时记 unresolved_call（双罚）
        var ubd: Int64 = 0
        var unresSecond: Int64 = 0
        for (u in pc.uncertain) {
            if (uncId(u.kind) == "use_before_def") { ubd += 1 }
            if (uncId(u.kind) == "unresolved_call" && u.id.contains("second")) { unresSecond += 1 }
        }
        @Assert(ubd == 1)
        @Assert(unresSecond == 0)
    } finally {
        removeTree(root)
    }
}

/// H1 的另 half：同一行引用不得产生两条重复 uncertain ——
/// 合并器（mergePatchConfidence）逐条把 uncertain 计入 conf 均值，重复即双算。
@Test
func testPatchUncertainHasNoDuplicates(): Unit {
    let root = writeTree()
    try {
        let graph = buildGraph(root)
        let diff = "--- a/flow/update.cj\n+++ b/flow/update.cj\n@@ -1,3 +1,7 @@\n" +
            " package moongit.flow\n+\n+public func patchHelper(t: Text): Bool {\n" +
            "+    let ok = t.trimAll(\"x\")\n+    return ok && ghost_fn(t)\n+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        var ghost: Int64 = 0
        for (u in pc.uncertain) {
            if (uncId(u.kind) == "unresolved_call" && u.id.contains("ghost_fn")) { ghost += 1 }
        }
        @Assert(ghost == 1)
    } finally {
        removeTree(root)
    }
}

/// H2：use-before-def 必须真的能触发。原实现用「扫到第 N 行时已知」的 patchDecls
/// 判「声明在后」，条件 n2 > pl.newNo 永假 ⇒ UUseBeforeDef 一条不产生、
/// S5 恒为 1.0 虚抬 overall 约 1/10 标度。
@Test
func testPatchUseBeforeDefFires(): Unit {
    let root = writeTree()
    try {
        let graph = buildGraph(root)
        // 先调用 later()，后声明 later() —— 同一文件内 use-before-def
        let diff = "--- a/flow/update.cj\n+++ b/flow/update.cj\n@@ -1,3 +1,8 @@\n" +
            " package moongit.flow\n+\n+public func patchHelper(t: Text): Bool {\n" +
            "+    return later(t)\n+}\n+\n+public func later(t: Text): Bool {\n" +
            "+    return true\n+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        var ubd: Int64 = 0
        for (u in pc.uncertain) {
            if (uncId(u.kind) == "use_before_def" && u.id.contains("later")) { ubd += 1 }
        }
        @Assert(ubd >= 1)
    } finally {
        removeTree(root)
    }
}

/// H2 负向：先声明后使用不得报 use-before-def（否则这条信号变成噪音，
/// 每条 patch 都被判「先用后声明」）。
@Test
func testPatchDeclaredBeforeUseIsNotFlagged(): Unit {
    let root = writeTree()
    try {
        let graph = buildGraph(root)
        let diff = "--- a/flow/update.cj\n+++ b/flow/update.cj\n@@ -1,3 +1,8 @@\n" +
            " package moongit.flow\n+\n+public func early(t: Text): Bool {\n" +
            "+    return true\n+}\n+\n+public func patchHelper(t: Text): Bool {\n" +
            "+    return early(t)\n+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        for (u in pc.uncertain) {
            @Assert(!(uncId(u.kind) == "use_before_def" && u.id.contains("early")))
        }
    } finally {
        removeTree(root)
    }
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
    let root = "${tempDirPath()}/moongit-unused-import-${getpid()}-${nowMillis()}"
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
package moongit.flow.inner

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

/// 批 Z ①的**负向防线**：原型声明（`;` 结尾）不许进符号表 —— 它不是定义。
@Test
func testAllmanStyleCPrototypeIsNotScanned(): Unit {
    let src = "int add(int a, int b);\n" +
        "\n" +
        "int add(int a, int b)\n" +
        "{\n" +
        "    return a + b;\n" +
        "}\n"
    let facts = scanSource(src, "c")
    var addCount = 0
    for (sym in facts.symbols) {
        if (sym.name == "add") { addCount += 1 }
    }
    @Assert(addCount == 1)   // 只认定义，不认原型
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
    let root = "${tempDirPath()}/moongit-scan-qualified-${getpid()}-${nowMillis()}"
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

// MARK: - 审查回归（audit-2026-10-09）：置信度渲染层

/// M5：渲染层原先**零测试**。三个出口（text/json/llmPrompt）里最容易烂掉的是
/// 「披露字段还在不在」—— 而它没有任何断言盯着。这里用一份手搓报告钉住形状。
private func confReportFixture(astUsed: Bool, astNote: String): ConfidenceReport {
    let findings = ArrayList<Finding>()
    findings.add(Finding(MagicNumber, "a.cj", 3, "v", "17"))
    findings.add(Finding(TodoResidue, "a.cj", 9, "w", "TODO"))
    let byKind = ArrayList<(FlawKind, Int64)>()
    byKind.add((MagicNumber, 1))
    byKind.add((TodoResidue, 1))
    let files = ArrayList<(String, Int64)>()
    // 罚分降序（analyzeConfidence 的既有约定）
    files.add(("b.cj", 7))
    files.add(("a.cj", 4))
    let dims = ArrayList<(ConfDimension, Int64, Int64, Int64)>()
    dims.add((DimStructure, 4, 2, 90))
    return ConfidenceReport("/tmp/x", 88, findings, astUsed, astNote, 2, byKind, files, dims)
}

/// M4 + M5：JSON 出口的键集必须稳定，且两个「files」不许互相覆盖。
/// 原实现把罚分表和 filesAnalyzed 都写成 "files" —— Json.set 同键就地覆盖，
/// 于是罚分表在 JSON 出口里被静默丢掉（MCP codegraph_confidence 同源）。
@Test
func testConfidenceJsonKeySetIsStable(): Unit {
    let j = confidenceJson(confReportFixture(true, "ast-grep 已启用"))
    for (k in ["root", "score", "dimensions", "penaltyByFile", "findings", "byKind", "astUsed", "astNote", "filesAnalyzed", "semantics"]) {
        @Assert(Json.has(j, k))
    }
    // 罚分表必须真的在（不被 filesAnalyzed 覆盖）
    let pf = Json.arrAt(j, "penaltyByFile")
    @Assert(Int64(pf.size) == 2)
    @Assert(Json.strAt(pf[0], "file", "") == "b.cj")
    @Assert(Json.intAt(pf[0], "penalty", 0) == 7)
    @Assert(Json.intAt(j, "filesAnalyzed", 0) == 2)
    // 旧的 "files" 键不许以数组形态回来（那说明有人改回去了）
    match (Json.get(j, "files")) {
        case Some(JArr(_)) => @Assert(false)
        case _ => ()
    }
}

/// M5 + M2：降级披露必须出现在**每一个**出口。
/// 原实现 README 承诺 astNote 降级披露，却没有一条测试钉住它。
@Test
func testConfidenceDegradedNoteAppearsInEveryExit(): Unit {
    let degraded = confReportFixture(false, "ast-grep 不可用，已降级为词法分析")
    let t = confidenceText(degraded)
    @Assert(t.contains("已降级"))
    let j = Json.pretty(confidenceJson(degraded))
    @Assert(j.contains("已降级"))
    let p = confidenceLlmPrompt(degraded, "demo")
    @Assert(p.contains("词法"))
    // 三个出口都要说出「这不是全量」
    @Assert(t.contains("ast-grep"))
    @Assert(j.contains("astUsed"))
    @Assert(p.contains("词法"))
}

/// M5：文本出口必须报分母（分析几个文件）与语义边界。
@Test
func testConfidenceTextStatesScopeAndBoundary(): Unit {
    let t = confidenceText(confReportFixture(true, "ast-grep 已启用"))
    @Assert(t.contains("分析 2 文件"))
    @Assert(t.contains("不是正确性证明"))
    @Assert(t.contains("分数"))
}

/// M5：LLM 提示词必须按维度分节，且每条带证据。
@Test
func testConfidenceLlmPromptGroupsByDimension(): Unit {
    let p = confidenceLlmPrompt(confReportFixture(true, "ast-grep 已启用"), "demo")
    @Assert(p.contains("项目：demo"))
    @Assert(p.contains("## 预检维度分"))
    @Assert(p.contains("结构"))
    @Assert(p.contains("证据："))
    // 红线必须在（不许只复读预检结论）
    @Assert(p.contains("红线"))
    @Assert(p.contains("## 输出格式"))
}

/// M3 回归：C/C++ 的 opaque 前置声明不许被报成「空类型」。
/// ast-grep 对 `struct Fwd;` / `typedef struct Fwd FwdT;` 都跨 1 行命中 type 规则，
/// 而判据 `methods == 0 && lines <= 3` 把每个前置声明都扣 3 分 ——
/// opaque forward decl 是 C 头文件的惯用法，系统性拖低 C/C++ 仓库分数。
@Test
func testForwardDeclarationIsNotReportedAsEmptyType(): Unit {
    // ⚠️ 必须用**真实 CST 形态**：tree-sitter 的 `;` 是 struct_specifier 的兄弟节点，
    // ast-grep 命中的 text 是 `struct Fwd`——**不带分号**。旧测试手写 "struct Fwd;"
    // （集成中不会出现的输入），把恒假的死代码判据 endsWith(";") 钉成了绿的
    // （复审 2026-10-10）。
    @Assert(isForwardDeclaration("struct Fwd"))
    @Assert(isForwardDeclaration("typedef struct Fwd FwdT"))
    // 整行文本（带分号）同样要认得
    @Assert(isForwardDeclaration("struct Fwd;"))
    // 有成员表就不是前置声明；真正的空类型仍然要报（判据不许放宽到恒真）
    @Assert(!isForwardDeclaration("struct Empty { }"))
    @Assert(!isForwardDeclaration("struct Empty {}"))

    let nodes = ArrayList<AstNode>()
    // 真实 CST 形态：不带分号
    nodes.add(AstNode("a.h", 3, 3, "type", "struct Fwd"))
    nodes.add(AstNode("a.h", 4, 4, "type", "struct Fwd"))   // typedef 内层的 struct_specifier
    nodes.add(AstNode("a.cj", 5, 5, "type", "struct Empty {}"))
    let findings = ArrayList<Finding>()
    detectTypeSignals(nodes, findings)
    var reported = ArrayList<String>()
    for (f in findings) {
        if (flawId(f.kind) == "empty-type") { reported.add(f.symbol) }
    }
    @Assert(reported.size == 1)
    @Assert(reported[0] == "Empty")

    // M3 同族漏网（终审实测）：stub 判定也不许抓前置声明——EmptyType 修了，
    // StubBody 从另一个出口继续误报
    let stubNodes = ArrayList<AstNode>()
    stubNodes.add(AstNode("a.h", 3, 3, "type", "struct Fwd"))
    let stubFindings = ArrayList<Finding>()
    detectFromAst(stubNodes, stubFindings, CapDropCounter())
    for (f in stubFindings) {
        @Assert(f.symbol != "Fwd")
    }
}

/// 终审漏网回归：.c 临时副本的路径映回不许产生双重扩展名。
/// 实测：同一份报告里词法路径 findings 是 t.c、AST 路径却是 t.c.c——
/// 编码名已含 .c，还原后再拼一次 ".c" 就重复。
@Test
func testCAstPathMapsBackWithoutDoubleExtension(): Unit {
    // 编码可逆且无碰撞（旧 "/"→"__" 方案的两个碰撞源）
    @Assert(unsanitizePathName(sanitizePathToName("t.c")) == "t.c")
    @Assert(unsanitizePathName(sanitizePathToName("a/b.c")) == "a/b.c")
    @Assert(unsanitizePathName(sanitizePathToName("a%2Fb.c")) == "a%2Fb.c")
    @Assert(unsanitizePathName(sanitizePathToName("a__b.c")) == "a__b.c")
    @Assert(sanitizePathToName("a/b.c") != sanitizePathToName("a__b.c"))

    // parseOneAstNode 的映回走全链路
    let savedScan = AST_SCAN_ROOT
    let savedCpp = C_AS_CPP_ROOT
    try {
        AST_SCAN_ROOT = "/tmp/fake-root"
        C_AS_CPP_ROOT = "/tmp/moongit-c-as-cpp-999"
        let item = Json.obj()
        Json.set(item, "file", Json.of("/tmp/moongit-c-as-cpp-999/sub%2Ft.c.cpp"))
        Json.set(item, "ruleId", Json.of("fn"))
        Json.set(item, "text", Json.of("int f(void) { return 0; }"))
        let start = Json.obj()
        Json.set(start, "line", Json.of(1))
        Json.set(start, "column", Json.of(0))
        let end = Json.obj()
        Json.set(end, "line", Json.of(1))
        Json.set(end, "column", Json.of(20))
        let range = Json.obj()
        Json.set(range, "start", start)
        Json.set(range, "end", end)
        Json.set(item, "range", range)
        let out = ArrayList<AstNode>()
        parseOneAstNode(item, out)
        @Assert(out.size == 1)
        @Assert(out[0].file == "sub/t.c")
    } finally {
        AST_SCAN_ROOT = savedScan
        C_AS_CPP_ROOT = savedCpp
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

/// 代码图谱的 Web 导出（与 arch 同纪律：引擎单独跑或被 agent 驱动时
/// 只产出本 HTML，无其他渲染通道；绘制一律走平台 Canvas API 公共子集）。
/// 内嵌数据必须就是 `graph tree --json` 的同一份契约。
/// 2026-10-11 三轮重构：三个并列 tab（模块/调用树/热力图）合并为单一
/// 「代码图谱」画布——热力呈现就是代码图谱本身的着色系统，不再是独立视图。
/// 旧断言 `data-view="graph"` / `data-view="heat"`（顶栏三按钮）随形态
/// **显式退役**（不是漏改）：并列视图分发没有了，单画布以
/// `data-canvas="codegraph"` 标记钉住。
@Test
func testTreeCanvasHtmlExport(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        let html = treeCanvasHtml(g, 8, false, conf)
        // 单画布版：codegraph 标记 / 旧视图按钮不得残留 / 侧栏 / 数据内嵌
        // （2026-10-12 参考稿重设计：详情侧栏从 data-pane 分隔条布局改为
        // .sidebar 固定栅格——data-pane 标记随之显式退役）
        @Assert(html.contains("data-canvas=\"codegraph\""))
        @Assert(!html.contains("data-view="))
        @Assert(!html.contains("vtabs"))
        @Assert(html.contains("class=\"sidebar\""))
        @Assert(html.contains("<canvas"))
        @Assert(html.contains("MoongitCodeGraph") || html.contains("functionEdges"))
        @Assert(html.contains("referenceEdges"))
        @Assert(html.contains("archRefEdges"))
        @Assert(html.contains("depthOmitted"))
        @Assert(html.contains("codeSnippets"))
        @Assert(html.contains("confidence"))
        @Assert(html.contains("langThemes"))
        @Assert(!html.contains("<script src"))
    } finally {
        removeTree(root)
    }
}

/// 树形交付物的**样式契约**：保证「下一次引擎生成的代码图谱和现在的一样」。
/// 三层锁：
///   ① 确定性——同一项目两次生成交付物逐字节一致（引擎承诺的可复现性）；
///   ② 样式锁定——**不同项目**的 <style> 块与驱动 JS 必须完全相同
///      （样式/交互只由引擎代码决定，不随数据漂移；改样式 = 必须过这条测试）；
///   ③ 结构标记——本轮定稿的设计决策逐项钉死（pill 徽标 / 过滤态覆盖表 /
///      L0 锚点行 / 档位色 / 命中高亮 / 置信度 tab），以及 finding 数据契约
///      （label/dim/evidence 六字段，树节点内嵌与 confidence 内嵌同口径）。
@Test
func testTreeHtmlStyleContract(): Unit {
    func extractBlock(html: String, open: String, close: String, last: Bool): String {
        var a = -1
        var from = 0
        while (true) {
            let hit = indexOfStrFrom(html, open, from)
            if (hit < 0) { break }
            a = hit
            from = hit + open.size
            if (!last) { break }
        }
        if (a < 0) { return "" }
        let bodyFrom = a + open.size
        let b = indexOfStrFrom(html, close, bodyFrom)
        if (b < 0) { return "" }
        // 边界都是 ASCII 标签，UTF-8 切片安全
        return html[bodyFrom..b]
    }

    let root1 = writeTree()
    let root2 = testRoot()
    try {
        // 第二个 fixture：不同目录结构 + 不同语言（ts），代表「另一个项目」
        ensureDir("${root2}/src")
        writeFileAtomic("${root2}/src/only.ts",
            "export function one(a: number): number { return a + 1; }\n")
        let g1 = buildGraph(root1)
        let g2 = buildGraph(root2)

        // ① 确定性：同输入两次生成逐字节一致
        let htmlA = treeCanvasHtml(g1, 8, false, analyzeConfidence(g1, false))
        let htmlB = treeCanvasHtml(g1, 8, false, analyzeConfidence(g1, false))
        @Assert(htmlA == htmlB)

        // ② 样式锁定：不同项目的 <style> 与驱动 JS（最后一个 <script>）完全相同
        let html2 = treeCanvasHtml(g2, 8, false, analyzeConfidence(g2, false))
        let css1 = extractBlock(htmlA, "<style>", "</style>", false)
        let css2 = extractBlock(html2, "<style>", "</style>", false)
        @Assert(css1 != "")
        @Assert(css1 == css2)
        let js1 = extractBlock(htmlA, "<script>", "</script>", true)
        let js2 = extractBlock(html2, "<script>", "</script>", true)
        @Assert(js1 != "")
        @Assert(js1 == js2)

        // ③a 结构标记：本轮定稿的设计决策（改任何一项都应自觉过来看这条）
        // 2026-10-12 参考稿整体重设计（AI 置信度关系图）：旧「模块卡片/文件球/
        // 符号球」三视图退役，换成层级作用域钻取 + 关系驱动分层散带布局 +
        // 端口路由贝塞尔边 + 呼吸氛围。以下逐项钉住新形态的承重接缝。
        @Assert(css1.contains("@keyframes auroraDrift"))  // 呼吸氛围（画布 aurora）
        @Assert(css1.contains(".minimap"))                // 小地图
        @Assert(!css1.contains(".vtabs"))                 // 三按钮 tab 条退役：顶栏无视图切换
        @Assert(css1.contains(".canvas-wrap"))            // 主画布区
        @Assert(js1.contains("function rollUp"))          // roll-up（容器疑点聚合，子树口径）
        @Assert(js1.contains("confidenceColor"))          // 置信度三档色（低红/中黄/高绿）
        @Assert(js1.contains("boundaryOf:"))              // 跨作用域边界披露文案
        @Assert(js1.contains("function cntOf"))           // 徽标计数（与侧栏同口径）
        // 确定性散带布局 + 端口路由（参考稿算法逐段移植，零随机零时间）
        @Assert(js1.contains("function layoutGraph"))
        @Assert(js1.contains("function mapCurrentGraph"))
        @Assert(js1.contains("function settleScatterLayer"))
        @Assert(js1.contains("function routeWorldEdges"))
        @Assert(js1.contains("function drawNode"))
        @Assert(js1.contains("function drawEdge"))
        @Assert(js1.contains("function drawMini"))
        // 一眼可读两支柱（用户验收五轮定稿）：① 边色 = 来源节点身份色
        //（与卡左色条同色，hueCss/hueOf 同源）；② 关系驱动的网格重排
        //（barySweepGrid：强关联卡换到相邻格位，连线变短变直）
        @Assert(js1.contains("function barySweepGrid"))
        @Assert(js1.contains("function hueOf"))
        @Assert(js1.contains("function hueCss"))
        @Assert(js1.contains("hueCss(hueOf(data))"))   // 卡左色条 = 身份色
        @Assert(js1.contains("hueCss(hueOf(srcNode))"))  // 线色 = 来源身份色
        // 旧形态标记退役，不得残留
        @Assert(!js1.contains("buildCallTree"))
        @Assert(!js1.contains("drawGraph"))
        @Assert(!js1.contains("layoutBubbles"))
        @Assert(!js1.contains("drawModules"))
        @Assert(!js1.contains("hitCell"))
        @Assert(js1.contains("getContext('2d')"))      // Canvas 2D（非 SVG/DOM 拼）
        @Assert(htmlA.contains("data-canvas=\"codegraph\""))  // 单画布标记
        @Assert(!htmlA.contains("data-view="))         // 旧视图按钮退役
        @Assert(htmlA.contains("<canvas"))             // 一切通过 canvas 画
        @Assert(htmlA.contains("id=\"canvasWrap\""))   // 主画布容器
        @Assert(htmlA.contains("data-tab=\"confidence\""))  // 置信度 tab（侧栏六 tab）
        // CANVAS2D_SUBSET 纪律（export.cj）：HTML 驱动只许调子集内方法，
        // 同一渲染逻辑才能逐项映射到各平台原生 Canvas（SwiftUI/Qt/仓颉）。
        // 子集外方法一票否决——这是负向断言，往驱动里加新绘制手段必先过这里。
        @Assert(!js1.contains("quadraticCurveTo"))
        @Assert(!js1.contains("measureText"))
        @Assert(!js1.contains("clearRect"))
        @Assert(!js1.contains("createRadialGradient"))
        @Assert(!js1.contains("ctx.save"))
        @Assert(!js1.contains("ctx.restore"))

        // ③b 数据契约：注入一条已知 finding，内嵌函数级数据必须带全六字段
        let conf = analyzeConfidence(g1, false)
        conf.findings.add(Finding(HighComplexity, "util/text.cj",
            7, "trimAll", "契约测试：圈复杂度注入"))
        let fg = functionGraphData(g1, conf, false)
        var sawFinding = false
        for (fn in Json.arrAt(fg, "functions")) {
            for (f in Json.arrAt(fn, "findings")) {
                sawFinding = true
                @Assert(Json.has(f, "kind"))
                @Assert(Json.has(f, "label"))     // 人类可读标签（胶囊文案）
                @Assert(Json.has(f, "dim"))       // 分组维度（tab 分节键）
                @Assert(Json.has(f, "evidence"))  // 自足证据（不打开编辑器可判读）
                @Assert(Json.has(f, "weight"))
                @Assert(Json.has(f, "line"))
                @Assert(Json.strAt(f, "label", "") != "")
            }
        }
        @Assert(sawFinding)
        // 交付物整体内嵌同样带 label（confidence 内嵌与函数级同口径）
        let htmlWithF = treeCanvasHtml(g1, 8, false, conf)
        @Assert(htmlWithF.contains("\"label\""))
        @Assert(htmlWithF.contains("契约测试：圈复杂度注入"))
    } finally {
        removeTree(root1)
        removeTree(root2)
    }
}

/// 调用边的**确信度分层**（codereviewgraph 的 edge confidence 概念落地）：
/// 每条边必须自报它是怎么解析出来的——direct=同文件 / resolved=跨文件且
/// 名字唯一命中 / guessed=重名仅按名匹配（词法近似取首个定义的固有不确定）。
/// 页面把 guessed 画成虚线：不确定的关系必须看起来不确定，
/// 而不是披着确定边的外皮混进图里。热力图着色的按文件罚分表同理：
/// confidence 内嵌必须带 `files`（引擎罚分表原样下发，客户端不许重算第二份口径）。
///
/// T2 回归（第二波）：同文件可见定义**优先于**全库重名判定。原实现
/// defs.size>1 一票判 guessed 且边目标取按序首个定义——同文件调用遇任意
/// 同名定义被画成虚线、边指向另一处文件的定义，与 direct 语义自述矛盾。
@Test
func testFunctionEdgeTierDisclosure(): Unit {
    let root = testRoot()
    try {
        ensureDir("${root}/a")
        ensureDir("${root}/b")
        // helper 在 a 与 b 各有一份定义 → 对 helper 的跨文件调用是 guessed
        writeFileAtomic("${root}/a/helper.cj", """
package a

public func helper(): Int64 { return other() + onlyB() }
public func other(): Int64 { return 1 }
""")
        writeFileAtomic("${root}/b/helper.cj", """
package b

public func helper(): Int64 { return 2 }
""")
        writeFileAtomic("${root}/b/only.cj", """
package b

public func onlyB(): Int64 { return 3 }
""")
        // T2 夹具：implUse 与 helper **同文件**（b/impl.cj），而 helper
        // 全库共三处定义（a/helper.cj / b/helper.cj / b/impl.cj）。
        // 原实现在此夹具上判 guessed 虚线、边指向按序首个 a/helper.cj。
        writeFileAtomic("${root}/b/impl.cj", """
package b

public func helper(): Int64 { return 20 }
public func implUse(): Int64 { return helper() }
""")
        writeFileAtomic("${root}/main.cj", """
package main

public func entry(): Int64 { return helper() }
""")
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        let fg = functionGraphData(g, conf, false)
        var sawDirect = false
        var sawResolved = false
        var sawGuessed = false
        for (e in Json.arrAt(fg, "functionEdges")) {
            let tier = Json.strAt(e, "tier", "")
            @Assert(tier == "direct" || tier == "resolved" || tier == "guessed")
            if (tier == "direct") { sawDirect = true }
            if (tier == "resolved") { sawResolved = true }
            if (tier == "guessed") { sawGuessed = true }
        }
        @Assert(sawDirect)    // a/helper → a/other（同文件，词法可见定义）
        @Assert(sawResolved)  // a/helper → b/onlyB（跨文件唯一命中）
        @Assert(sawGuessed)   // main/entry → helper（无同文件定义，三处重名取首个）
        // T2 断言：同文件调用遇全库重名 ⇒ tier=direct 且边指向同文件定义
        var sawSameFileDirect = false
        for (e in Json.arrAt(fg, "functionEdges")) {
            let from = Json.strAt(e, "from", "")
            if (from.startsWith("f:b/impl.cj:") && from.endsWith(":implUse")) {
                @Assert(Json.strAt(e, "tier", "") == "direct")
                let to = Json.strAt(e, "to", "")
                @Assert(to.startsWith("f:b/impl.cj:"))
                @Assert(to.endsWith(":helper"))
                sawSameFileDirect = true
            }
        }
        @Assert(sawSameFileDirect)   // 前提：这条边真的存在（否则空转绿）
        // 按文件罚分表内嵌（热力图着色的唯一口径来源）
        let emb = confidenceEmbedJson(conf, false)
        @Assert(Json.has(emb, "files"))
    } finally {
        removeTree(root)
    }
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

/// M2 源码守卫：AST 批**全部失败**时必须降级（返回 None），
/// 不能返回 Some(空列表) 让调用方报 astUsed=true。
///
/// 为什么不用行为断言：这条路径需要「ast-grep 能跑但每个批次都失败」，
/// 而测试沙箱里要么 ast-grep 不在、要么全部文件都是仓颉（无 tree-sitter 语法）
/// —— 批次数为 0，分支根本进不去。测不了的路径就用源码守卫钉住接缝，
/// 并在注释里如实说明这是源码级保证、不是行为级保证。
@Test
func __lintAstBatchFailureDegradesInsteadOfClaimingSuccess(): Unit {
    let raw = readFileTextChecked("src/graph/confidence_ast.cj").getOrThrow()
    let sb = StringBuilder()
    var blk = CjStripState.Normal
    for (r in raw.split("\n")) {
        let (l, nb) = stripCjCommentEx(r, blk)
        blk = nb
        sb.append(l)
        sb.append("\n")
    }
    let code = sb.toString()
    // 判据是「全部批失败 ⇒ return None」这个组合
    let guard = code.indexOf("failedBatches == totalBatches")
    @Assert(guard.isSome())
    let after = code[guard.getOrThrow()..]
    let none = after.indexOf("return None")
    @Assert(none.isSome())
    // 同一个 if 块内就要 return None，不许隔到别的分支
    @Assert(none.getOrThrow() < 200)
    // 且清理临时目录必须发生在返回之前（用完即清）
    @Assert(after.indexOf("cleanupAstTmpDirs", 0).isSome())
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

// MARK: - 审查回归（audit-2026-10-11）：图谱核心 G1..G8

/// G1 回归：Go **带接收者**的方法声明不许把接收者变量名抽成符号。
/// `func (r *Rect) Area() float64` tokenize 后 tokens[1] 是接收者名 r——
/// scanDeclLine 的 Some(kind) 分支无条件取 tokens[i+1]，方法真名整体消失、
/// r 成了符号；连锁后果是方法声明行的 `Area(` 形态被报「幻觉 API」
/// （defFiles 里没有 Area），健康 Go 文件被打低分。
/// 走真实路径：buildGraph（scanSource）+ analyzeConfidence。
@Test
func testGoReceiverMethodRealNameIsExtracted(): Unit {
    let root = "${tempDirPath()}/moongit-go-recv-${getpid()}-${nowMillis()}"
    ensureDir(root)
    writeFileAtomic("${root}/shape.go", """
package main

import "fmt"

type Rect struct {
    w float64
    h float64
}

func (r *Rect) Area() float64 {
    return r.w * r.h
}

func (q *Rect) Perimeter() float64 {
    return 2 * (q.w + q.h)
}

func (b *Rect) Dump() {
    fmt.Println("rect")
}
""")
    try {
        let g = buildGraph(root)
        // 符号表：含方法真名，不含接收者变量名
        // （r 不在单字符豁免名单 i/j/k/n/x/y/s/t/e/v/f/p/q/w——未修时
        //  它还会从 suspicious-name 出口再假指控一次）
        var names = ArrayList<String>()
        for (f in g.files) {
            for (s in f.symbols) { names.add(s.name) }
        }
        @Assert(names.contains("Rect"))
        @Assert(names.contains("Area"))
        @Assert(names.contains("Perimeter"))
        @Assert(names.contains("Dump"))
        @Assert(!names.contains("r"))
        @Assert(!names.contains("q"))
        @Assert(!names.contains("b"))
        // 健康 Go 文件：零 unresolved-call（未修时 Area/Perimeter/Dump 的
        // 声明行被报幻觉 API）、零 suspicious-name（未修时 r/b 是单字符符号）
        let rep = analyzeConfidence(g, false)
        for (f in rep.findings) {
            match (f.kind) {
                case UnresolvedCall => @Assert(false)
                case SuspiciousName => @Assert(false)
                case _ => ()
            }
        }
    } finally {
        removePathIfExists(root)
    }
}

/// G2 回归：未解析调用检测不许扫注释与字符串，语言关键字不算调用。
/// `if(x)` / `while(` / `for(` / `malloc(sizeof(int))` / 注释与字符串里的
/// `call(` 都被指控过「幻觉 API」。真幻觉名必须照报（判据不许放宽到空转）。
/// 走真实路径：buildGraph（第二遍位置感知扫描）+ analyzeConfidence。
@Test
func testUnresolvedCallIgnoresKeywordsCommentsAndStrings(): Unit {
    let root = "${tempDirPath()}/moongit-unres-${getpid()}-${nowMillis()}"
    ensureDir(root)
    writeFileAtomic("${root}/k.c", """
#include <stdlib.h>

int step(int v) {
    if(v > 3) { v = v - 1; }
    while(v > 0) { v = v - 2; }
    for(int i = 0; i < 3; i = i + 1) { v = v + 4; }
    void *p = malloc(64 * sizeof(int));
    char *s = "call(1) inside string";
    int t = v; /* call(2) inside block comment */
    ghost_thing(v);
    return v;
}
""")
    try {
        let g = buildGraph(root)
        for ((_, name, _) in g.unresolvedCalls) {
            @Assert(name != "if")
            @Assert(name != "for")
            @Assert(name != "while")
            @Assert(name != "sizeof")
            @Assert(name != "call")
        }
        // 真幻觉名照报（负向防线）
        var ghost = false
        for ((_, name, _) in g.unresolvedCalls) {
            if (name == "ghost_thing") { ghost = true }
        }
        @Assert(ghost)
        // 出口同口径：confidence 的 findings 里没有关键词指控
        let rep = analyzeConfidence(g, false)
        var ghostFinding = false
        for (f in rep.findings) {
            match (f.kind) {
                case UnresolvedCall =>
                    @Assert(f.symbol != "if")
                    @Assert(f.symbol != "for")
                    @Assert(f.symbol != "while")
                    @Assert(f.symbol != "sizeof")
                    @Assert(f.symbol != "call")
                    if (f.symbol == "ghost_thing") { ghostFinding = true }
                case _ => ()
            }
        }
        @Assert(ghostFinding)
    } finally {
        removePathIfExists(root)
    }
}

/// G3 回归（detectPointerRisks）：多行块注释里的 malloc 不许计入
/// 「疑似内存泄漏」。走真实路径：buildGraph + analyzeConfidence。
@Test
func testPointerRiskIgnoresCommentedMalloc(): Unit {
    let root = "${tempDirPath()}/moongit-ptr-${getpid()}-${nowMillis()}"
    ensureDir(root)
    writeFileAtomic("${root}/commented.c", """
#include <stdlib.h>

/*
void *leak(void) {
    return malloc(1024);
}
*/
""")
    writeFileAtomic("${root}/live.c", """
#include <stdlib.h>

int leak(void) {
    void *p = malloc(64);
    return 0;
}
""")
    try {
        let rep = analyzeConfidence(buildGraph(root), false)
        var commentedRisk = false
        var liveRisk = false
        for (f in rep.findings) {
            match (f.kind) {
                case PointerRisk =>
                    if (f.file == "commented.c") { commentedRisk = true }
                    if (f.file == "live.c") { liveRisk = true }
                case _ => ()
            }
        }
        // 注释掉的 malloc 不报；活代码的 malloc/free 不配对照报（负向防线）
        @Assert(!commentedRisk)
        @Assert(liveRisk)
    } finally {
        removePathIfExists(root)
    }
}

/// G3 回归（checkLockCalls）：持锁区间里的**多行块注释**内的调用不许被报
/// 死锁。AST 节点无法在沙箱稳定产出（ast-grep 依赖环境），沿用
/// testForwardDeclarationIsNotReportedAsEmptyType 的同包直调检测器先例。
@Test
func testLockCallCheckIgnoresCommentedCalls(): Unit {
    let fnText = "func guarded() {\n" +
        "    mu.lock()\n" +
        "    /*\n" +
        "    foo(1)\n" +
        "    bar(2)\n" +
        "    */\n" +
        "    known(3)\n" +
        "    mu.unlock()\n" +
        "}\n"
    let n = AstNode("g.cj", 1, 9, "fn", fnText)
    let findings = ArrayList<Finding>()
    let perFile = HashMap<String, Int64>()
    // lock 在第 2 行、unlock 在第 8 行——注释块（3..6 行）在持锁区间内
    checkLockCalls(n, 2, 8, findings, perFile, CapDropCounter())
    var sawKnown = false
    for (f in findings) {
        match (f.kind) {
            case LockUnknownCall =>
                @Assert(f.symbol != "foo")
                @Assert(f.symbol != "bar")
                if (f.symbol == "known") { sawKnown = true }
            case _ => ()
        }
    }
    // 活代码的持锁调用照报（负向防线）
    @Assert(sawKnown)
}

/// G3 回归（patchconf 三处）：多行块注释里的声明不许变成 patchconf 实体。
/// 走真实路径：writeTree + buildGraph + analyzePatchConfidence。
@Test
func testPatchConfidenceIgnoresDeclsInsideBlockComment(): Unit {
    let root = writeTree()
    try {
        let graph = buildGraph(root)
        let diff = "--- a/flow/new.cj\n+++ b/flow/new.cj\n@@ -1,2 +1,8 @@\n" +
            " package q\n" +
            "+/*\n" +
            "+public func commented_out(t: Text): Bool {\n" +
            "+    return true\n" +
            "+}\n" +
            "+*/\n" +
            "+public func liveOne(t: Text): Bool {\n" +
            "+    return true\n" +
            "+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        for (e in pc.entities) {
            @Assert(e.name != "commented_out")
        }
        // 活代码的声明照常成为实体（负向防线）
        var hasLive = false
        for (e in pc.entities) {
            if (e.name == "liveOne") { hasLive = true }
        }
        @Assert(hasLive)
    } finally {
        removeTree(root)
    }
}

/// G4 回归：圈复杂度对原始函数体行计分支——注释与字符串里的英文散文
/// （"if the value…"、"a || b"）被算成决策点，纯注释函数被判「圈复杂度 13」。
/// 走真实路径：buildGraph + analyzeConfidence（detectSemanticIssues）。
@Test
func testComplexityIgnoresCommentedBranches(): Unit {
    let root = "${tempDirPath()}/moongit-cc-${getpid()}-${nowMillis()}"
    ensureDir(root)
    writeFileAtomic("${root}/quiet.cj", """
package p

func quiet(): Int64 {
/*
if a { ... }
if a { ... } if a { ... } if a { ... } if a { ... } if a { ... }
if a { ... } if a { ... } if a { ... } if a { ... } if a { ... }
a || b || a || b
*/
    return 1
}

func busy(): Int64 {
    if (a > 1) { return 2 }
    if (a > 2) { return 3 }
    if (a > 3) { return 4 }
    if (a > 4) { return 5 }
    if (a > 5) { return 6 }
    if (a > 6) { return 7 }
    if (a > 7) { return 8 }
    if (a > 8) { return 9 }
    if (a > 9) { return 10 }
    if (a > 10) { return 11 }
    if (a > 11) { return 12 }
    return 13
}
""")
    try {
        let rep = analyzeConfidence(buildGraph(root), false)
        var quietHigh = false
        var busyHigh = false
        for (f in rep.findings) {
            match (f.kind) {
                case HighComplexity =>
                    if (f.symbol == "quiet") { quietHigh = true }
                    if (f.symbol == "busy") { busyHigh = true }
                case _ => ()
            }
        }
        // 纯注释函数（12 行块注释 + 1 行 return）不是高复杂度
        @Assert(!quietHigh)
        // 真分支函数照报（负向防线：11 个 if ⇒ cc = 12 > 阈值）
        @Assert(busyHigh)
    } finally {
        removePathIfExists(root)
    }
}

/// G5 回归：只有字段没有方法的类型不是空类型。
/// 原实现用 mayDeclare（声明关键词）数成员，字段对它不可见——
/// `type Rect struct { w, h float64 }` 被指控「没有任何成员——占位类型
/// 或被掏空」。AST 节点沿用同包直调检测器先例（ast-grep 依赖环境）。
@Test
func testFieldTypeOnlyStructIsNotEmpty(): Unit {
    let nodes = ArrayList<AstNode>()
    nodes.add(AstNode("shape.go", 3, 3, "type", "type Rect struct { w, h float64 }"))
    nodes.add(AstNode("point.h", 5, 5, "type", "struct Point { int x; int y; }"))
    nodes.add(AstNode("hollow.cj", 7, 7, "type", "class Hollow {}"))
    let findings = ArrayList<Finding>()
    detectTypeSignals(nodes, findings)
    for (f in findings) {
        if (flawId(f.kind) == "empty-type") {
            @Assert(f.symbol != "Rect")
            @Assert(f.symbol != "Point")
        }
    }
    // 真空类型照报（判据不许放宽到恒不报；既有 testForwardDeclaration… 同守）
    var hollow = false
    for (f in findings) {
        if (flawId(f.kind) == "empty-type" && f.symbol == "Hollow") { hollow = true }
    }
    @Assert(hollow)
}

/// G6 回归（契约A 引擎侧）：walkSources 丢弃 listDirChecked 的 readable
/// 标志 ⇒ 读不到的子树与空目录在图谱里完全同构（root 读不到时产物是
/// 全清空图谱、零披露）。行为测试借 execCapture 调 /bin/chmod 000 造
/// 读不出来的目录（#179 同款先例；仓颉 std 无权限 API）。
@Test
func testWalkSourcesCollectsUnreadableDirs(): Unit {
    let root = "${tempDirPath()}/moongit-unread-${getpid()}-${nowMillis()}"
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

/// G7：阈值只许住在 confidence.cj 的常量区——判据与证据文案都从常量派生
/// （confidence_detect.cj 文件头的纪律）。裸字面量判据 = 「一处改了另一处
/// 忘了」的漂移源。为什么读源断言：AST 路径需要 ast-grep 环境，行为测试
/// 在沙箱里覆盖不到它；「两条路径同值」由「引用同一个常量」结构性保证。
/// ⚠️ 先剥注释再匹配（不变量 30：解释性注释长得和缺陷一模一样）。
@Test
func __lintConfidenceThresholdsComeFromConstants(): Unit {
    let raw = readFileTextChecked("src/graph/confidence_detect.cj").getOrThrow()
    let sb = StringBuilder()
    var blk = CjStripState.Normal
    for (r in raw.split("\n")) {
        let (l, nb) = stripCjCommentEx(r, blk)
        blk = nb
        sb.append(l)
        sb.append("\n")
    }
    let code = sb.toString()
    // 判据引用常量：魔法数在 AST 与词法两条路径都引用（≥2 处 = 同值有接缝保证）
    @Assert(countOf(code, ">= CONF_MAGIC_NUMBERS") >= 2)
    @Assert(countOf(code, ">= CONF_COMMENTED_CODE_LINES") >= 1)
    @Assert(countOf(code, "> CONF_COMPLEXITY") >= 1)
    @Assert(countOf(code, "> CONF_PARAMS") >= 1)
    // 裸字面量判据绝迹（防止改回硬编码）
    @Assert(countOf(code, "magic >= 3") == 0)
    @Assert(countOf(code, "bodyMagic >= 3") == 0)
    @Assert(countOf(code, "codeLines >= 3") == 0)
    @Assert(countOf(code, "cc > 10") == 0)
    @Assert(countOf(code, "pCount > 5") == 0)
    // 证据文案也从常量派生（阈值数字不许手抄第二份）：
    // 拼接构造避免本测试自身的字符串插值吃掉花括号
    @Assert(code.contains("$" + "{CONF_MAGIC_NUMBERS}"))
    @Assert(code.contains("$" + "{CONF_COMPLEXITY}"))
    @Assert(code.contains("$" + "{CONF_PARAMS}"))
}

/// G8 回归（契约B 引擎侧）：impact 采集的上限原先静默截断——「还有更多
/// 没列出」与「只有这些」在结果里同构。可注入小上限验证两个 capped 标志。
/// 走真实路径：buildGraph + impactOf。
@Test
func testImpactCappedFlagsOnSmallBudget(): Unit {
    let root = "${tempDirPath()}/moongit-cap-${getpid()}-${nowMillis()}"
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

// MARK: - 审查回归（第二波）：treehtml 单元（热力图口径 / tier 解析 /
// 分隔线拖拽 / depth 双数据域 / 图例 unreadableDirs 消费）

/// 从 treeCanvasHtml 真实产物提取驱动 JS（最后一个 <script> 块）。
/// JS 行为在仓颉测试里没有浏览器执行路径——按样式契约测试（d3918c9）的
/// 先例，对**完整生成路径的产物**做结构断言，而不是拿手搓 JS 夹具冒充。
private func driverJsOf(html: String): String {
    var a = -1
    var from = 0
    while (true) {
        let hit = indexOfStrFrom(html, "<script>", from)
        if (hit < 0) { break }
        a = hit
        from = hit + 8
    }
    if (a < 0) { return "" }
    let bodyFrom = a + 8
    let b = indexOfStrFrom(html, "</script>", bodyFrom)
    if (b < 0) { return "" }
    // 边界都是 ASCII 标签，UTF-8 切片安全
    return html[bodyFrom..b]
}

/// 从 treeCanvasHtml 产物提取内嵌 payload（window.__CODEGRAPH__ = {…};）并解析。
/// 提取失败返回空对象——调用方第一条前提断言（键存在）即红，不会空转绿。
private func treePayloadOf(html: String): JsonValue {
    let marker = "window.__CODEGRAPH__ = "
    let a = indexOfStrFrom(html, marker, 0)
    if (a < 0) { return Json.obj() }
    let from2 = a + marker.size
    let semi = indexOfStrFrom(html, ";\n</script>", from2)
    if (semi <= from2) { return Json.obj() }
    match (Json.parse(html[from2..semi])) {
        case Some(j) => return j
        case None => return Json.obj()
    }
}

/// 驱动 JS 的剥注释（// 与 /* */）。源码断言前必剥——解释性注释里引用
/// 标识符会把「关键点存在」断言变成假绿（不变量 30/47 同一条纪律）。
/// ⚠️ 已知边界：stripCjCommentEx 只跟踪**双引号**字符串，驱动 LANG 表的
/// `lineCm: '//'`（单引号串，8 处）会被当行注释剥掉行尾（kws 关键字表部分）。
/// 这无害的前提是：**被断言的标识符一个都不许写在 LANG 表的 kws 行尾**——
/// 往那几行加断言目标前先挪位置，否则断言静默空转。驱动无模板串、
/// 无跨行块注释序列（`/*`），行状态机逐行独立，不会卡状态。
private func jsNoComment(js: String): String {
    let sb = StringBuilder()
    var blk = CjStripState.Normal
    for (r in js.split("\n")) {
        let (l, nb) = stripCjCommentEx(r, blk)
        blk = nb
        sb.append(l)
        sb.append("\n")
    }
    return sb.toString()
}

/// T1 回归：热力图文件格的 ⚠ 徽标与悬停必须与点击后的 tab / 详情同口径
/// （rollN = 整棵子树，含符号级 findings）。原实现只数直属 fileFindings——
/// 绝大多数 finding 按行号归属到符号体，纯符号级罚分的文件格「颜色说有
/// 罚分、徽标说没有」（43e57a1 修过的同族在新出口复发）。
/// 判据是语义级的：cntOf 容器分支必须用子树口径，且驱动里不许再出现
/// 「数直属 fileFindings 长度」的取数点（数据构建处只 push / forEach，
/// 不会被这条误伤）。
@Test
func testTreeHeatBadgeCountsSubtreeNotDirectFindings(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let js = driverJsOf(treeCanvasHtml(g, 0, false, analyzeConfidence(g, false)))
        // 前提守卫（不变量 22）：提取成功、归属与 roll-up 的数据构建仍在
        @Assert(js.contains("function cntOf"))
        @Assert(js.contains("fileFindings.push"))
        @Assert(js.contains("n.fileFindings.forEach"))
        // cntOf 函数体：容器（file/dir）分支必须返回 rollN
        let a = indexOfStrFrom(js, "function cntOf", 0)
        @Assert(a >= 0)
        let b = indexOfStrFrom(js, "function ", a + 1)
        @Assert(b > a)
        let body = js[a..b]
        @Assert(body.contains("rollN"))
        @Assert(!body.contains("fileFindings.length"))
        // 悬停 tooltip 同口径：全驱动不许再数直属 fileFindings 的长度
        //（该取数点只可能出现在徽标 / tooltip，负向断言精确覆盖缺陷）
        @Assert(!js.contains("fileFindings.length"))
    } finally {
        removeTree(root)
    }
}

/// T3 回归：分隔线拖拽 / 双击复位改变详情栏宽度 ⇒ stage 宽度随之变化，
/// 画布必须 resizeCanvas()+draw()。原实现只改宽度、画布不重设尺寸不重画
/// ——canvas 按旧宽渲染并溢出，反向盖住详情栏，除窗口 resize 外无自愈。
@Test
func testTreeDividerResizeRedrawsCanvas(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let js = driverJsOf(treeCanvasHtml(g, 0, false, analyzeConfidence(g, false)))
        // 2026-10-12 参考稿重设计：旧「拖拽分隔条调侧栏宽度」随 data-pane
        // 布局显式退役（参考稿为固定 368px 栅格侧栏）。保留的契约是
        // 「窗口尺寸变化必须重排 + 重画」——pin resize 监听 → resize() →
        // layoutGraph + fitView 这条链（拖拽没有了，重排红线还在）。
        let a = indexOfStrFrom(js, "window.addEventListener('resize'", 0)
        @Assert(a >= 0)
        let seg = js[a..]
        // 前提：监听体内真的接了重排链，而不是空监听
        //（layoutGraph 在 resize() 内部被调用；fitView 必须在监听链上）
        @Assert(seg.contains("resizeTimer"))
        @Assert(seg.contains("resize()"))
        @Assert(seg.contains("fitView()"))
    } finally {
        removeTree(root)
    }
}

/// T4 回归（契约D）：--depth 必须同时约束文件树域与函数域。
/// 原实现 functionGraphData 遍历全部文件——同一份 HTML 两个数据域口径
/// 不同：depth 外符号画得出、悬停有反馈，而点击 / 回车 / 搜索 / 公开 API
/// setFocus 全部静默无反应。走真实路径：treeCanvasHtml 产物里提取内嵌
/// JSON（经 jsonSafeForEmbed）再解析，断言两域文件集一致、边端点全部落在
/// 函数清单之内（callee 候选同样被 depth 过滤，否则边指向不存在的端点）。
@Test
func testTreeHtmlFunctionDomainMatchesDepth(): Unit {
    let root = writeTree()
    try {
        // 深度 2 的文件（depth=1 时被剪）+ 根目录 entry 调深度外符号
        ensureDir("${root}/flow/inner")
        writeFileAtomic("${root}/flow/inner/deep.cj", """
package moongit.flow.inner

public func deepThing(): Int64 { return 1 }
""")
        writeFileAtomic("${root}/entry.cj", """
package moongit

public func entryCall(): Int64 { return deepThing() }
""")
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        func payloadOf(html: String): JsonValue {
            let marker = "window.__CODEGRAPH__ = "
            let a = indexOfStrFrom(html, marker, 0)
            @Assert(a >= 0)
            let from2 = a + marker.size
            // 产物拼接是 <json>;\n</script>——结束标记必须带换行才贴得上
            let semi = indexOfStrFrom(html, ";\n</script>", from2)
            @Assert(semi > from2)
            match (Json.parse(html[from2..semi])) {
                case Some(j) => return j
                case None => @Assert(false)
            }
            return Json.obj()
        }
        let dj = payloadOf(treeCanvasHtml(g, 1, false, conf))
        // 前提：夹具真的触发了截断（否则「一致」是空转绿——不变量 41）
        @Assert(Json.intAt(dj, "depth", -1) == 1)
        @Assert(Json.intAt(dj, "depthOmitted", 0) >= 1)
        let fileSet = HashMap<String, Bool>()
        for (f in Json.arrAt(dj, "files")) {
            fileSet[Json.strAt(f, "path", "")] = true
        }
        @Assert(!fileSet.contains("flow/inner/deep.cj"))
        let fnFiles = HashMap<String, Bool>()
        var sawDeepFn = false
        match (Json.getOr(dj, "functionGraph")) {
            case JObj(_) =>
                // ⊆：函数域不许超出文件树（depth 外文件不产函数 / 实码）
                for (fn in Json.arrAt(Json.getOr(dj, "functionGraph"), "functions")) {
                    let p = Json.strAt(fn, "file", "")
                    @Assert(fileSet.contains(p))
                    fnFiles[p] = true
                    if (p == "flow/inner/deep.cj") { sawDeepFn = true }
                }
                @Assert(!sawDeepFn)
                // 边端点全部落在函数清单里：entryCall→deepThing（深度 0 调
                // 深度 2）这条边不该存在——to 端不在可见数据域
                let ids = HashMap<String, Bool>()
                for (fn in Json.arrAt(Json.getOr(dj, "functionGraph"), "functions")) {
                    ids[Json.strAt(fn, "id", "")] = true
                }
                for (e in Json.arrAt(Json.getOr(dj, "functionGraph"), "functionEdges")) {
                    @Assert(ids.contains(Json.strAt(e, "from", "")))
                    @Assert(ids.contains(Json.strAt(e, "to", "")))
                }
                // 一致：文件树里每个有符号的文件都有函数节点（entry.cj 在内）
                @Assert(fnFiles.contains("entry.cj"))
                for (f in Json.arrAt(dj, "files")) {
                    if (Int64(Json.arrAt(f, "symbols").size) > 0) {
                        @Assert(fnFiles.contains(Json.strAt(f, "path", "")))
                    }
                }
            case _ => @Assert(false)
        }
        // 对外签名保持全量（契约D：cli.cj / mcp.cj 的既有调用面零改动）：
        // 深度 2 文件的函数与「深度 0 调深度 2」的边都还在（过滤只发生在
        // maxDepth>0，不许把全量路径误杀）
        let full = functionGraphData(g, conf, false)
        var sawDeepInFull = false
        for (fn in Json.arrAt(full, "functions")) {
            if (Json.strAt(fn, "file", "") == "flow/inner/deep.cj") { sawDeepInFull = true }
        }
        @Assert(sawDeepInFull)
        var sawEntryEdge = false
        for (e in Json.arrAt(full, "functionEdges")) {
            if (Json.strAt(e, "from", "").endsWith(":entryCall") && Json.strAt(e, "to", "").endsWith(":deepThing")) {
                sawEntryEdge = true
            }
        }
        @Assert(sawEntryEdge)
    } finally {
        removeTree(root)
    }
}

/// T5 回归（契约A 页面侧）：图例必须消费 D.unreadableDirs——非空 = 有
/// 子树没读到，图谱不是全量。「读不到」与「没有」是两个状态，页面不许把
/// 读不到渲染成没有。核心侧恒发两键由 archfix_test R6 钉住；这条钉住
/// 页面消费点：renderLegend 读 D.unreadableDirs（note 样式，对齐 truncated
/// 披露），截断时（数组只发前 N 条）数量必须带 ≥ 下界前缀。
@Test
func testTreeLegendConsumesUnreadableDirs(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let html = treeCanvasHtml(g, 0, false, analyzeConfidence(g, false))
        let js = driverJsOf(html)
        // 前提：数据侧恒发两键（契约A 引擎侧），页面拿到的是完整 HTML
        @Assert(html.contains("\"unreadableDirs\""))
        @Assert(html.contains("\"unreadableDirsTruncated\""))
        // 图例警示文案随 T 表注入（中文态）；消费点在 integrityNotes 里：
        // 读 D.unreadableDirs，note 样式披露（旧 renderLegend 随参考稿重设计退役）
        @Assert(js.contains("个目录读不到"))
        let a = indexOfStrFrom(js, "function integrityNotes", 0)
        @Assert(a >= 0)
        let b = indexOfStrFrom(js, "function ", a + 1)
        @Assert(b > a)
        let seg = js[a..b]
        @Assert(seg.contains("D.unreadableDirs"))
        @Assert(seg.contains("D.unreadableDirsTruncated"))
        @Assert(seg.contains("noteUnread"))
        @Assert(seg.contains("class=\"note\""))
    } finally {
        removeTree(root)
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
    let root = "${tempDirPath()}/moongit-glue-${getpid()}-${nowMillis()}"
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

/// L3 回归：patchconf 的 entity 关系**前瞻循环**原先对上下文行不推进
/// lookState（主循环推进），块注释横跨「上下文行 → 新增行」时两遍状态发散，
/// 注释残段里的调用被算进关系分。修法：与主循环同一套推进纪律
/// （删除行跳过不推进；上下文行推进、只不产出）。
/// 走真实路径：writeTree + buildGraph + analyzePatchConfidence。
@Test
func testPatchLookaheadAdvancesStateOnContextLines(): Unit {
    let root = writeTree()
    try {
        let graph = buildGraph(root)
        // 注释开始于**上下文行**（" /*"），新增行 main(None) 整行在注释内：
        // 主循环按状态 3 剥掉；前窥循环（修复前状态 0）会把 main( 当活代码。
        let diff = "--- a/flow/new.cj\n+++ b/flow/new.cj\n@@ -1,3 +1,11 @@\n" +
            " package q\n" +
            "+public func live(t: Text): Bool {\n" +
            "+    return runUpdate(t)\n" +
            "+}\n" +
            " /*\n" +
            "+main(None)\n" +
            "+*/\n" +
            "+public func tail(t: Text): Bool {\n" +
            "+    return true\n" +
            "+}\n"
        let pc = analyzePatchConfidence(graph, diff)
        var sawLive = false
        var sawRunUpdateRel = false
        for (e in pc.entities) {
            if (e.name != "live") { continue }
            sawLive = true
            for ((_, target, _) in e.relations) {
                if (target.contains("runUpdate")) { sawRunUpdateRel = true }
                // 注释残段里的 main 不许算进关系（两遍状态发散的后果）
                @Assert(!target.contains("main"))
            }
        }
        @Assert(sawLive)
        // 负向防线：前窥机制本身还在工作——活代码里的 runUpdate 必须算进关系
        @Assert(sawRunUpdateRel)
    } finally {
        removeTree(root)
    }
}

/// L4：flawId 死分支删除后的出口契约钉住（语义层 5 kind 的 id 唯一且稳定；
/// 不可达的重复分支删除是零行为变化，这条防的是 id 字符串被顺手改掉）。
@Test
func testFlawIdCoversSemanticKindsOnce(): Unit {
    @Assert(flawId(HighComplexity) == "high-complexity")
    @Assert(flawId(ParameterAbuse) == "parameter-abuse")
    @Assert(flawId(DeadBranch) == "dead-branch")
    @Assert(flawId(MixedResponsibility) == "mixed-responsibility")
    @Assert(flawId(NearDuplicate) == "near-duplicate")
}

/// capped 契约测试的夹具：一个含 6 个（= CONF_MAX_PER_KIND_PER_FILE）单行
/// 空体函数的仓颉文件——每文件恰好产出 StubBody×6 + Orphan×6，两个上限都
/// **恰好达限而未超**。tag 让函数名跨文件不同（防 NearDuplicate 的同体哈希
/// 干扰计数）。
private func sixStubFile(tag: String): String {
    let sb = StringBuilder()
    sb.append("package p\n\n")
    var k: Int64 = 1
    while (k <= CONF_MAX_PER_KIND_PER_FILE) {
        sb.append("public func s${k}${tag}() { }\n")
        k += 1
    }
    return sb.toString()
}

/// L5 回归（契约C 引擎侧）：cappedKind / cappedTotal 的真值来自**丢弃发生的
/// 判定点**（CapDropCounter / 截断分支），不是拿截断后的结果集反推——
/// 「恰好 6 条同类」与「第 7 条被丢弃」在结果集里同形，反推会把恰好达限
/// 误报成「超出已汇总」。三场景：恰好达限 → 双 false；第 7 条触发每类丢弃 →
/// 仅 cappedKind；多文件堆总量超 CONF_MAX_FINDINGS 而每类不丢 → 仅 cappedTotal。
/// 走真实路径：buildGraph + analyzeConfidence。
@Test
func testConfidenceCappedFlagsComeFromRealDrops(): Unit {
    // 场景一：恰好 6 条同类（两个类别都达限未超）
    let root6 = "${tempDirPath()}/moongit-cap6-${getpid()}-${nowMillis()}"
    ensureDir(root6)
    writeFileAtomic("${root6}/exactly.cj", sixStubFile(""))
    // 场景二：第 7 条触发每文件每类丢弃
    let root7 = "${tempDirPath()}/moongit-cap7-${getpid()}-${nowMillis()}"
    ensureDir(root7)
    writeFileAtomic("${root7}/over.cj", sixStubFile("") + "public func s7() { }\n")
    // 场景三：每文件恰不超限、多文件把总量堆过 CONF_MAX_FINDINGS
    let rootT = "${tempDirPath()}/moongit-capT-${getpid()}-${nowMillis()}"
    ensureDir(rootT)
    let filesNeeded = CONF_MAX_FINDINGS / (2 * CONF_MAX_PER_KIND_PER_FILE) + 2
    var i: Int64 = 0
    while (i < filesNeeded) {
        writeFileAtomic("${rootT}/f${i}.cj", sixStubFile("f${i}"))
        i += 1
    }
    try {
        // 场景一：恰好 6 条 → 双 false（页面拿结果集反推会误报 true 的那种）
        let rep6 = analyzeConfidence(buildGraph(root6), false)
        @Assert(!rep6.cappedKind)
        @Assert(!rep6.cappedTotal)
        // 前提守卫（不变量 18：断言前先确认场景真的成立）：两类都恰好 6 条——
        // 少于 6 条时「未超限」是空转绿
        var stub6: Int64 = 0
        var orph6: Int64 = 0
        for (f in rep6.findings) {
            match (f.kind) {
                case StubBody => stub6 += 1
                case Orphan => orph6 += 1
                case _ => ()
            }
        }
        @Assert(stub6 == CONF_MAX_PER_KIND_PER_FILE)
        @Assert(orph6 == CONF_MAX_PER_KIND_PER_FILE)

        // 场景二：第 7 条触发每类丢弃 → cappedKind=true，总量远未达上限 → false
        let rep7 = analyzeConfidence(buildGraph(root7), false)
        @Assert(rep7.cappedKind)
        @Assert(!rep7.cappedTotal)

        // 场景三：总量超 CONF_MAX_FINDINGS（每文件 12 条 × 35 文件 = 420 > 400）
        // 而每文件每类恰好 6 条不丢弃 → 仅 cappedTotal 置位
        let repT = analyzeConfidence(buildGraph(rootT), false)
        @Assert(repT.cappedTotal)
        @Assert(!repT.cappedKind)
        @Assert(Int64(repT.findings.size) == CONF_MAX_FINDINGS)   // 截断到上限
    } finally {
        removePathIfExists(root6)
        removePathIfExists(root7)
        removePathIfExists(rootT)
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
    let root = "${tempDirPath()}/moongit-scan-fake-${getpid()}-${nowMillis()}"
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
    let root = "${tempDirPath()}/moongit-scan-triple-${getpid()}-${nowMillis()}"
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
    let root = "${tempDirPath()}/moongit-scan-imp-${getpid()}-${nowMillis()}"
    ensureDir(root)
    // 夹具内含三引号字符串：仓颉多行字符串不支持转义，用拼接构造
    let q = "\"\"\""
    let src = "package demo\n\n" +
        "import moongit.util\n\n" +
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
    let root = "${tempDirPath()}/moongit-scan-ext-${getpid()}-${nowMillis()}"
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
    let root = "${tempDirPath()}/moongit-scan-ipt-${getpid()}-${nowMillis()}"
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

// MARK: - 模块层 × 分级 × 置信度指数（三视图改造的回归）

/// 分级纯函数三态（30/600 边界）。口径：文件数与符号数**都不超**阈值 →
/// compact（代码级）；任一严格超 → layered（模块级）。边界归属：恰好等于
/// 阈值 = 不超 = compact（「超」是严格大于）。阈值常量改动必须过这条 +
/// 页面披露文案（tierLf/tierLs/tierC 同步改，否则「分级：…（N 文件 > 30）」
/// 的数字与真阈值脱节）。
@Test
func testTierOfBoundaries(): Unit {
    @Assert(COMPACT_MAX_FILES == 30)
    @Assert(COMPACT_MAX_SYMBOLS == 600)
    @Assert(tierOf(0, 0) == "compact")
    @Assert(tierOf(30, 600) == "compact")    // 恰好达限 = 不超
    @Assert(tierOf(0, 600) == "compact")
    @Assert(tierOf(31, 0) == "layered")      // 文件数严格超
    @Assert(tierOf(0, 601) == "layered")     // 符号数严格超
    @Assert(tierOf(30, 601) == "layered")    // 一维超即 layered
    @Assert(tierOf(31, 601) == "layered")
}

/// 模块层数据的口径同源（走真实路径：treeCanvasHtml 产物提取内嵌 JSON）：
///   · 模块集合 == 对夹具全文件取 moduleOfPath 的集合（划分同源，不许第二份）；
///   · 每模块 confIndex == confidenceScore(penalty, files)（公式同源）；
///   · penalty / findings == conf.files / conf.findings 按模块聚合（输入同源）；
///   · 七键恒发（0 也发）——零罚分/无疑点是「这个模块可信」的证据；
///   · fileModules 逐文件 == moduleOfPath（下钻与热力图标签的单一口径来源）；
///   · graphModuleEdges == archRefEdges 按模块对聚合（架构口径，禁 refEdges），
///     无自模块对，from↑ → to↑ 全序。
@Test
func testTreeModuleLayerPayload(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        let dj = treePayloadOf(treeCanvasHtml(g, 0, false, conf))
        // 前提守卫：提取成功（否则下面全部空转）
        @Assert(Json.has(dj, "files"))
        // 期望值独立重算（与引擎各自的代码路径对账）
        let expectMods = HashMap<String, Int64>()
        for (f in g.files) {
            let m = moduleOfPath(f.relPath)
            match (expectMods.get(m)) {
                case Some(v) => expectMods[m] = v + 1
                case None => expectMods[m] = 1
            }
        }
        @Assert(expectMods.size >= 2)   // 前提：夹具真的有 ≥2 个模块
        let expectPen = HashMap<String, Int64>()
        for ((path, pen) in conf.files) {
            let m = moduleOfPath(path)
            match (expectPen.get(m)) {
                case Some(v) => expectPen[m] = v + pen
                case None => expectPen[m] = pen
            }
        }
        let expectFnd = HashMap<String, Int64>()
        for (fd in conf.findings) {
            let m = moduleOfPath(fd.file)
            match (expectFnd.get(m)) {
                case Some(v) => expectFnd[m] = v + 1
                case None => expectFnd[m] = 1
            }
        }
        // graphModules：集合相等 + 键恒发 + 三条口径逐模块对账
        let seen = HashMap<String, Bool>()
        var totalFiles: Int64 = 0
        var totalSymbols: Int64 = 0
        var totalLines: Int64 = 0
        for (mo in Json.arrAt(dj, "graphModules")) {
            let id = Json.strAt(mo, "id", "")
            @Assert(!id.isEmpty())
            seen[id] = true
            // 七键恒发（0 也发；缺键会被读成旧版本没有该字段）
            @Assert(Json.has(mo, "id"))
            @Assert(Json.has(mo, "files"))
            @Assert(Json.has(mo, "symbols"))
            @Assert(Json.has(mo, "lines"))
            @Assert(Json.has(mo, "penalty"))
            @Assert(Json.has(mo, "findings"))
            @Assert(Json.has(mo, "confIndex"))
            let fc = Json.intAt(mo, "files", -1)
            match (expectMods.get(id)) {
                case Some(v) => @Assert(fc == v)   // 划分同源：模块集合与计数一致
                case None => @Assert(false)
            }
            let pen = Json.intAt(mo, "penalty", -1)
            var expPen: Int64 = 0
            match (expectPen.get(id)) {
                case Some(v) => expPen = v
                case None => ()
            }
            @Assert(pen == expPen)                 // 罚分聚合 == conf.files 输入
            var expFnd: Int64 = 0
            match (expectFnd.get(id)) {
                case Some(v) => expFnd = v
                case None => ()
            }
            @Assert(Json.intAt(mo, "findings", -1) == expFnd)
            // 口径同源：confIndex 必须 == confidenceScore(penalty, files)
            @Assert(Json.intAt(mo, "confIndex", -1) == confidenceScore(pen, fc))
            totalFiles += fc
            totalSymbols += Json.intAt(mo, "symbols", 0)
            totalLines += Json.intAt(mo, "lines", 0)
        }
        var expectCount: Int64 = 0
        for ((m, _) in expectMods) {
            expectCount += 1
            @Assert(seen.contains(m))
        }
        @Assert(Int64(seen.size) == expectCount)
        // 聚合完整性：模块计数加回 == 全量文件事实
        @Assert(totalFiles == Int64(g.files.size))
        var expSymbols: Int64 = 0
        var expLines: Int64 = 0
        for (f in g.files) {
            expSymbols += Int64(f.symbols.size)
            expLines += f.lines
        }
        @Assert(totalSymbols == expSymbols)
        @Assert(totalLines == expLines)
        // fileModules：逐文件 == moduleOfPath（下钻/热力图标签查的是这一份）
        match (Json.getOr(dj, "fileModules")) {
            case JObj(_) =>
                let fm = Json.getOr(dj, "fileModules")
                for (f in Json.arrAt(dj, "files")) {
                    let p = Json.strAt(f, "path", "")
                    @Assert(Json.strAt(fm, p, "@@missing@@") == moduleOfPath(p))
                }
            case _ => @Assert(false)
        }
        // graphModuleEdges：== archRefEdges 按模块对聚合；无自模块对；全序
        let expectEdges = HashMap<String, Int64>()
        for ((from, to, w) in g.archRefEdges) {
            let a = moduleOfPath(from)
            let b = moduleOfPath(to)
            if (a == b) { continue }
            let key = a + "\u{1f}" + b
            match (expectEdges.get(key)) {
                case Some(v) => expectEdges[key] = v + w
                case None => expectEdges[key] = w
            }
        }
        @Assert(expectEdges.size >= 1)   // 前提：夹具真的有跨模块架构引用
        var prevKey = ""
        var edgeCount: Int64 = 0
        for (e in Json.arrAt(dj, "graphModuleEdges")) {
            @Assert(Json.has(e, "from"))
            @Assert(Json.has(e, "to"))
            @Assert(Json.has(e, "w"))
            let a = Json.strAt(e, "from", "")
            let b = Json.strAt(e, "to", "")
            @Assert(a != b)
            let key = a + "\u{1f}" + b
            @Assert(key >= prevKey)      // from↑ → to↑ 全序（M11 纪律）
            prevKey = key
            match (expectEdges.get(key)) {
                case Some(v) => @Assert(Json.intAt(e, "w", -1) == v)
                case None => @Assert(false)
            }
            edgeCount += 1
        }
        @Assert(edgeCount == Int64(expectEdges.size))
    } finally {
        removeTree(root)
    }
}

/// 模块边最小夹具（数据侧 d）：两模块各一文件，b 调 a 的顶格公开函数
/// → 恰一条模块边 b→a 且 w ≥ 1；模块集合 = {a, b}；自模块对不成边。
@Test
func testTreeModuleEdgeFromTinyFixture(): Unit {
    let root = testRoot()
    try {
        ensureDir("${root}/a")
        ensureDir("${root}/b")
        writeFileAtomic("${root}/a/api.cj", """
package a

public func aThing(): Int64 { return 1 }
""")
        writeFileAtomic("${root}/b/use.cj", """
package b

public func useThing(): Int64 { return aThing() }
""")
        let g = buildGraph(root)
        // 前提守卫：架构口径真的解析出了跨文件引用（否则「恰一条」空转绿）
        @Assert(g.archRefEdges.size >= 1)
        let dj = treePayloadOf(treeCanvasHtml(g, 0, false, analyzeConfidence(g, false)))
        @Assert(Json.has(dj, "graphModuleEdges"))
        let es = Json.arrAt(dj, "graphModuleEdges")
        @Assert(es.size == 1)
        @Assert(Json.strAt(es[0], "from", "") == "b")
        @Assert(Json.strAt(es[0], "to", "") == "a")
        @Assert(Json.intAt(es[0], "w", 0) >= 1)
        // 模块集合 = {a, b}（对夹具全文件取 moduleOfPath 的同一集合）
        let mods = Json.arrAt(dj, "graphModules")
        @Assert(mods.size == 2)
        let ids = HashMap<String, Bool>()
        for (m in mods) { ids[Json.strAt(m, "id", "")] = true }
        @Assert(ids.contains("a"))
        @Assert(ids.contains("b"))
    } finally {
        removeTree(root)
    }
}

/// 单画布两级 + 分级入口（走真实产物）：
///   · 顶栏无视图按钮（单画布标记 + 分级 chip + 面包屑容器）；
///   · 驱动消费 graphModules/graphModuleEdges/fileModules/confIndex、
///     模块层绘制（drawModules/drawMCard/drawMEdge）、层级往返（enterCode/
///     backToModules/paintCrumb + 面包屑接线）、代码层文件过滤查引擎下发的
///     划分表（FM[fe.path]）——源码断言，剥注释后仍须命中（不变量 30）；
///   · 分级入口逻辑（layered → 模块层 / compact → 代码层）：DEFAULT_LEVEL
///     判定 + 初始化落点 state.level = DEFAULT_LEVEL + 两阈值键恒发；
///   · compact 夹具（writeTree）projectTier=compact；layered 夹具
///     （31 文件 > 30）projectTier=layered，tierFiles 与阈值键恒发对账。
///   旧名 testTreeThreeViewsAndTierDefault：三视图按钮与调用树下钻
///   （pickModuleFocus/GMIDX[dm]）随单画布重构**显式退役**，不是漏改。
@Test
func testTreeTierEntryAndModuleLayer(): Unit {
    let root = writeTree()
    let big = testRoot()
    try {
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        let html = treeCanvasHtml(g, 0, false, conf)
        // 单画布标记 + 分级 chip + 面包屑容器（旧 data-view 三按钮已退役；
        // 2026-10-12 参考稿重设计：tier-chip/mcrumb 改为 topbar tierChip 与
        // 画布脚注 breadcrumbs）
        @Assert(html.contains("data-canvas=\"codegraph\""))
        @Assert(!html.contains("data-view="))
        @Assert(html.contains("id=\"tierChip\""))
        @Assert(html.contains("id=\"breadcrumbs\""))
        // 驱动关键点（剥注释后断言；抓不到 = 断言空转，先红在前提上）
        let js = jsNoComment(driverJsOf(html))
        @Assert(js.contains("D.graphModules"))
        @Assert(js.contains("D.graphModuleEdges"))
        @Assert(js.contains("D.fileModules"))
        @Assert(js.contains("D.archRefEdges"))      // 文件级调用边数据源
        @Assert(js.contains("confIndex"))           // 模块指数走引擎下发值
        @Assert(js.contains("function layoutGraph"))     // 分层散带布局入口
        @Assert(js.contains("function mapCurrentGraph")) // 作用域 → 可见图映射
        @Assert(js.contains("function drawNode"))        // 节点卡片绘制
        @Assert(js.contains("function drawEdge"))        // 关系边绘制（端口路由）
        @Assert(js.contains("function confidenceColor")) // 置信度三档色阶
        @Assert(js.contains("function enterScope"))      // 点卡片/双击 → 子图
        @Assert(js.contains("function updateBreadcrumbs"))  // 面包屑链
        @Assert(js.contains("FM[fe.path]"))         // 文件归属查引擎下发的划分表
        @Assert(js.contains("D.compactMaxFiles"))
        @Assert(js.contains("D.compactMaxSymbols"))
        // 分级披露：tier 文案三态（layered 文件超限 / 符号超限 / compact）
        @Assert(js.contains("D.projectTier === 'layered'"))
        @Assert(js.contains("T.tierLf"))
        @Assert(js.contains("T.tierLs"))
        @Assert(js.contains("T.tierC"))
        // 入口落点：初始作用域恒为 project（参考稿语义；旧 DEFAULT_LEVEL 退役）
        @Assert(js.contains("var scopeId = 'project'"))
        // 图例：置信度三档 + 关系线型（call 实线 / guessed 虚线）
        @Assert(js.contains("lgLo"))
        @Assert(js.contains("lgMid"))
        @Assert(js.contains("lgHi"))
        // 图例线语义：线色 = 来源节点（身份色左色条）· 虚线 = 词法不确定
        @Assert(js.contains("lgSrc"))
        @Assert(js.contains("T.lgSrc"))
        // compact 夹具：分级 = 代码级，阈值键恒发，tierFiles 与文件集对账
        let dj = treePayloadOf(html)
        @Assert(Json.strAt(dj, "projectTier", "") == "compact")
        @Assert(Json.has(dj, "projectTier"))
        @Assert(Json.has(dj, "compactMaxFiles"))
        @Assert(Json.has(dj, "compactMaxSymbols"))
        @Assert(Json.intAt(dj, "compactMaxFiles", -1) == 30)
        @Assert(Json.intAt(dj, "compactMaxSymbols", -1) == 600)
        @Assert(Json.intAt(dj, "tierFiles", -1) == Int64(g.files.size))
        // layered 夹具：31 个单文件模块（> COMPACT_MAX_FILES）→ 模块级
        var i: Int64 = 0
        while (i <= 30) {
            let dir = "${big}/m${i}"
            ensureDir(dir)
            let sb = StringBuilder()
            sb.append("package m")
            sb.append(i.toString())
            sb.append("\n\npublic func f")
            sb.append(i.toString())
            sb.append("(): Int64 { return ")
            sb.append(i.toString())
            sb.append(" }\n")
            writeFileAtomic(dir + "/f.cj", sb.toString())
            i += 1
        }
        let gb = buildGraph(big)
        @Assert(Int64(gb.files.size) == 31)   // 前提：夹具真的超过阈值
        let djb = treePayloadOf(treeCanvasHtml(gb, 0, false, analyzeConfidence(gb, false)))
        @Assert(Json.strAt(djb, "projectTier", "") == "layered")
        @Assert(Json.intAt(djb, "tierFiles", -1) == 31)
        @Assert(Json.has(djb, "graphModules"))
        @Assert(Json.arrAt(djb, "graphModules").size == 31)
    } finally {
        removeTree(root)
        removeTree(big)
    }
}

/// 单画布产物的结构标记（规格 a）：三视图退役后，产物必须只有一张画布，
/// 且关系散带布局、绘制与路由入口都在。历代退役形态的符号是残留探测器
///（tidy tree / treemap / 模块卡片 / 文件球）——出现任何一个都说明旧视图
/// 没删干净。
@Test
func testTreeSingleCanvasArtifactMarkers(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let html = treeCanvasHtml(g, 0, false, analyzeConfidence(g, false))
        // 单一画布：无 .vtabs / data-view 三按钮；画布容器带 codegraph 标记
        @Assert(!html.contains("vtabs"))
        @Assert(!html.contains("data-view="))
        @Assert(html.contains("data-canvas=\"codegraph\""))
        @Assert(html.contains("<canvas"))
        let js = jsNoComment(driverJsOf(html))
        // 参考稿形态的承重入口：作用域映射 → 分层散带 → 端口路由 → 绘制
        @Assert(js.contains("function mapCurrentGraph"))
        @Assert(js.contains("function layoutGraph"))
        @Assert(js.contains("function settleScatterLayer"))
        @Assert(js.contains("function routeWorldEdges"))
        @Assert(js.contains("function drawNode"))
        @Assert(js.contains("function drawEdge"))
        @Assert(js.contains("function drawMini"))
        @Assert(js.contains("function confScore"))
        // 呼吸动效总闸（reduced-motion 直通终帧）
        @Assert(js.contains("function setBreathEnabled"))
        // 历代退役形态：tidy tree / 模块卡片 / 文件球 / treemap 命中函数
        @Assert(!js.contains("buildCallTree"))
        @Assert(!js.contains("layoutCallTree"))
        @Assert(!js.contains("drawGNode"))
        @Assert(!js.contains("drawGEdge"))
        @Assert(!js.contains("drawModules"))
        @Assert(!js.contains("buildBubbles"))
        @Assert(!js.contains("layoutBubbles"))
        // 旧命中函数名残留 = hover 引用未定义函数（ReferenceError，
        // 2026-10-12 实测抓过一次 hitCell）
        @Assert(!js.contains("hitCell"))
        // 旧三视图分发退役
        @Assert(!js.contains("drawHeat"))
        @Assert(!js.contains("state.view"))
    } finally {
        removeTree(root)
    }
}

/// 文件节点颜色 = confidenceColor(confidenceScore(罚分, 1))（规格 c）：
/// confidence.cj 公开公式的「单文件视角」，驱动侧 confScore 必须是它的
/// 唯一实现——页面另造第二份色阶口径 = 同名不同义的指数（43 号教训的同族）。
/// 源码断言，剥注释后仍须命中（不变量 30：剥注释前断言会假绿）。
@Test
func testTreeFileCellColorUsesConfidenceScoreFormula(): Unit {
    // 引擎侧公式对齐锚点：同一罚分的单文件指数（驱动公式必须与它同值）
    @Assert(confidenceScore(0, 1) == 100)
    @Assert(confidenceScore(20, 1) == 50)    // density=20=S ⇒ 100·S/(S+S)=50
    @Assert(confidenceScore(60, 1) == 25)
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let js = jsNoComment(driverJsOf(treeCanvasHtml(g, 0, false, analyzeConfidence(g, false))))
        // 前提守卫（不变量 22）：公式实现与调用点真的在产物里
        @Assert(js.contains("function confScore"))
        @Assert(js.contains("confScore(HEAT[fe.path] || 0, 1)"))
        // 文件节点置信度调用点：confScore(HEAT[路径] || 0, 1)（2026-10-12
        // 参考稿重设计：scoreHex 退役，色阶出口统一为 confidenceColor）
        @Assert(js.contains("confidenceColor("))
        // 公式体与 confidence.cj:607 对齐：n 下限 1、标度 20、floor 截断、0..100 夹取
        let a = indexOfStrFrom(js, "function confScore", 0)
        @Assert(a >= 0)
        let b = indexOfStrFrom(js, "function ", a + 1)
        @Assert(b > a)
        let body = js[a..b]
        @Assert(body.contains("files < 1 ? 1 : files"))
        @Assert(body.contains("/ (CONF_SCALE + density)"))
        @Assert(body.contains("Math.floor"))
        @Assert(body.contains("sc > 100"))
        @Assert(body.contains("sc < 0"))
        // 全驱动唯一实现：confScore 只定义一次（第二份 = 口径漂移）
        @Assert(countOf(js, "function confScore") == 1)
        // 模块卡片指数走引擎下发值（confIndex），页面不重算模块级第二份
        @Assert(js.contains("m.confIndex"))
        @Assert(!js.contains("confScore(m."))
    } finally {
        removeTree(root)
    }
}

/// 符号级关系源码锁：文件作用域必须画出符号间调用边（FG.functionEdges），
/// guessed（词法不确定）边必须虚线且动画；本作用域外的端点聚合成 boundary
/// 节点而不是静默丢弃。符号级索引是代码图谱的原子层——画布只画到文件级 =
/// 「符号级索引」名不副实（用户验收原话：还是文件级别的索引哦）。
/// 2026-10-12 参考稿重设计：旧「符号层第三视图」（drawSyms/enterSyms）退役，
/// 同一语义改为「文件作用域内的符号节点 + 边界聚合」。
@Test
func testTreeSymbolLayerDrillAndEdges(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let js = jsNoComment(driverJsOf(treeCanvasHtml(g, 0, false, analyzeConfidence(g, false))))
        // 前提守卫（不变量 22）：被断言的接缝真的在产物里
        @Assert(js.contains("FG.functionEdges"))
        // 符号节点进作用域：file 节点的 children = 符号 id（mapCurrentGraph 消费）
        @Assert(js.contains("SYM_OF_FILE"))
        // 符号置信度 = 同一个公式的符号视角（罚分 Σ 符号内 finding 权重）
        @Assert(js.contains("confScore(pen, 1)"))
        // guessed 边独立类型且虚线动画（行军蚁 lineDashOffset）——不确定要看得出来
        @Assert(js.contains("'guessed' ? 'guessed' : 'call'"))
        @Assert(js.contains("guessed: { label: T.relGuessed, color: '#ffc857', dash: [5, 4] }"))
        @Assert(js.contains("setLineDash(rel.dash)"))
        @Assert(js.contains("lineDashOffset"))
        // 作用域外的被调方 = boundary 节点聚合（不得静默丢边），带软上限
        @Assert(js.contains("function ensureBoundary"))
        @Assert(js.contains("boundaryUsed"))
        // 下钻接缝：双击进入子图（时间窗判双击）；单击只选中
        @Assert(js.contains("function handleDoubleClick"))
        @Assert(js.contains("function enterScope"))
        @Assert(js.contains("lastClickTime"))
        // 阈值滑块 = 置信度过滤（节点隐藏 + 边强度下限）
        @Assert(js.contains("n.confidence < threshold"))
        @Assert(js.contains("strengthOf"))
    } finally {
        removeTree(root)
    }
}


// MARK: - SQLite 图库/置信度库（graph db / confidence db）
//
// 【为什么是自由调用夹具】functionGraphData 的边来自 freeCallsIn——它跳过
// 接收者调用（a.b() 的前导点），只有「函数体内裸名字 + (」才算调用边。
// 夹具必须写 `runUpdate(): Bool { return trimAll(" x ").isEmpty() }` 这种
// 无接收者的自由调用；写成 t.trimAll() 不会有边，断言就空转着变绿
//（不变量 22 的形态：抓到 0 个 = 检查不存在）。
func dbTreeFixture(): String {
    let root = testRoot()
    ensureDir("${root}/util")
    ensureDir("${root}/flow")
    writeFileAtomic("${root}/util/text.cj", """
package moongit.util

public func trimAll(s: String): String {
    return s
}
""")
    writeFileAtomic("${root}/flow/update.cj", """
package moongit.flow

import moongit.util.*

public func runUpdate(): Bool {
    return trimAll("  x  ").isEmpty()
}
""")
    return root
}

/// 单值查询 helper。prepare/step 失败时返回带原因的占位文本——
/// 断言会以「值不相等」失败并直接看到原因，而不是静默空串。
func dbScalar(db: SqliteDb, sql: String): String {
    let stOpt = db.prepare(sql)
    if (stOpt.isNone()) { return "<prepare failed: ${sql}>" }
    let st = stOpt.getOrThrow()
    if (!st.stepHasRow()) {
        st.finalize()
        return "<no row: ${sql}>"
    }
    let v = st.columnText(0)
    st.finalize()
    return v
}

@Test
func testGraphDbWriteRoundTrip(): Unit {
    let root = dbTreeFixture()
    try {
        let graph = buildGraph(root)
        // 词法置信度（不依赖 ast-grep 是否安装）：functionGraphData 需要
        // 一份 ConfidenceReport 才能构造——这是公开签名，不是绕路
        let conf = analyzeConfidence(graph, false)
        let payload = functionGraphData(graph, conf, true)
        let fns = match (Json.get(payload, "functions")) {
            case Some(JArr(a)) => a
            case _ => ArrayList<JsonValue>()
        }
        let eds = match (Json.get(payload, "functionEdges")) {
            case Some(JArr(a)) => a
            case _ => ArrayList<JsonValue>()
        }
        // 前提守卫（不变量 18）：夹具必须真的有节点和边，否则下面的
        // round-trip 断言全部空转着变绿
        @Assert(Int64(fns.size) >= 2)
        @Assert(Int64(eds.size) >= 1)

        let dbPath = root + "/codegraph.db"
        @Assert(graphDbWrite(dbPath, graph, payload))

        // 用同一绑定层**只读**重开：写入器产出的库不依赖写权限也可读
        let ro1 = SqliteDb.openReadonly(dbPath)
        @Assert(ro1.isSome())
        let db = ro1.getOrThrow()
        // 行数对齐：nodes == functions 数、edges == functionEdges 数
        @Assert(dbScalar(db, "SELECT COUNT(*) FROM nodes") == Int64(fns.size).toString())
        @Assert(dbScalar(db, "SELECT COUNT(*) FROM edges") == Int64(eds.size).toString())
        // meta 与表行数自洽（agent 速览数字必须对得上表）
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='generator'") == GRAPH_DB_GENERATOR)
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='symbols'") == Int64(fns.size).toString())
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='files'") == Int64(graph.files.size).toString())
        // 按名找符号（idx_nodes_name 服务的查询）
        @Assert(dbScalar(db, "SELECT COUNT(*) FROM nodes WHERE name='trimAll'") == "1")
        // 「查 X 的 callers」：A 调 B ⇒ B 的 callers 含 A（边方向：src=调用方）
        @Assert(dbScalar(db,
            "SELECT COUNT(*) FROM edges e JOIN nodes c ON e.src=c.id JOIN nodes f ON e.dst=f.id WHERE f.name='trimAll' AND c.name='runUpdate'") == "1")
        // tier 确信度分层：跨文件且全库唯一 → resolved
        @Assert(dbScalar(db,
            "SELECT e.tier FROM edges e JOIN nodes c ON e.src=c.id JOIN nodes f ON e.dst=f.id WHERE f.name='trimAll'") == "resolved")
        db.close()

        // 幂等：单文件产物语义——已存在则先删重建，重写后行数不变
        @Assert(graphDbWrite(dbPath, graph, payload))
        let ro2 = SqliteDb.openReadonly(dbPath)
        @Assert(ro2.isSome())
        let db2 = ro2.getOrThrow()
        // ⚠️ 必须用**新连接**查：旧连接的 fd 指向已被 unlink 的旧 inode
        @Assert(dbScalar(db2, "SELECT COUNT(*) FROM nodes") == Int64(fns.size).toString())
        @Assert(dbScalar(db2, "SELECT COUNT(*) FROM edges") == Int64(eds.size).toString())
        db2.close()
    } finally {
        removeTree(root)
    }
}

@Test
func testConfidenceDbWriteRoundTrip(): Unit {
    let root = testRoot()
    try {
        // testRoot() 只返回路径不建目录；sqlite 的 CREATE 只建文件不建父目录
        ensureDir(root)
        // 手工报告（完全确定）：注入的 evidence 必须原样回到列里
        let findings = ArrayList<Finding>()
        findings.add(Finding(MagicNumber, "a.cj", 3, "v", "magic 17 used 3 times"))
        findings.add(Finding(TodoResidue, "a.cj", 9, "w", "TODO fix later"))
        let byKind = ArrayList<(FlawKind, Int64)>()
        byKind.add((MagicNumber, 1))
        byKind.add((TodoResidue, 1))
        let files = ArrayList<(String, Int64)>()
        files.add(("a.cj", 5))
        let dims = ArrayList<(ConfDimension, Int64, Int64, Int64)>()
        dims.add((DimStructure, 5, 2, 80))
        let report = ConfidenceReport(root, 66, findings, false,
            "按调用方要求跳过语法树（--no-ast），仅词法级分析", 2,
            byKind, files, dims, cappedKind: true, cappedTotal: false)

        let dbPath = root + "/confidence.db"
        @Assert(confidenceDbWrite(dbPath, report))

        let ro = SqliteDb.openReadonly(dbPath)
        @Assert(ro.isSome())
        let db = ro.getOrThrow()
        // meta.score 与报告一致；限流披露按真值落库
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='score'") == report.score.toString())
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='ast_used'") == "0")
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='capped_kind'") == "1")
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='capped_total'") == "0")
        @Assert(dbScalar(db, "SELECT value FROM meta WHERE key='root'") == root)
        // findings 行数一致
        @Assert(dbScalar(db, "SELECT COUNT(*) FROM findings") == "2")
        // 注入 finding 的 evidence 原样在列（kind/dim/weight 同口径）
        @Assert(dbScalar(db, "SELECT evidence FROM findings WHERE file='a.cj' AND line=3") == "magic 17 used 3 times")
        @Assert(dbScalar(db, "SELECT kind FROM findings WHERE line=9") == "todo-residue")
        @Assert(dbScalar(db, "SELECT dim FROM findings WHERE line=3") == "function")
        @Assert(dbScalar(db, "SELECT weight FROM findings WHERE line=3") == "3")
        // dimensions / files 行数
        @Assert(dbScalar(db, "SELECT COUNT(*) FROM dimensions") == "1")
        @Assert(dbScalar(db, "SELECT score FROM dimensions WHERE dim='structure'") == "80")
        @Assert(dbScalar(db, "SELECT penalty FROM files WHERE file='a.cj'") == "5")
        db.close()

        // 幂等：重写后行数不变
        @Assert(confidenceDbWrite(dbPath, report))
        let ro2 = SqliteDb.openReadonly(dbPath)
        @Assert(ro2.isSome())
        let db2 = ro2.getOrThrow()
        @Assert(dbScalar(db2, "SELECT COUNT(*) FROM findings") == "2")
        db2.close()
    } finally {
        removeTree(root)
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
        writeFileAtomic("${root}/util/text.cj", "package moongit.util\n\npublic class Text2 {\n    public func trimAll(s: String): String {\n        return s\n    }\n}\n")
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

/// store_meta round-trip：写 → 读 probe/update_count/generated_at/depth。
/// 旧式 graphDbWrite（无 store_meta 行）读出 updateCount = -1（无记录）；
/// 库不存在 → None。
@Test
func testStoreMetaRoundTrip(): Unit {
    let root = writeTree()
    let dbPath = "${root}.db"
    try {
        let g = buildGraph(root)
        let probe = sourceProbeNow(root)
        let rows = ArrayList<(String, JsonValue)>()
        rows.add(("source_probe", probe.toJson()))
        rows.add(("update_count", Json.of(3)))
        rows.add(("generated_at", Json.of("2026-10-12T00:00:00+08:00")))
        rows.add(("depth", Json.of(2)))
        @Assert(graphDbWriteWithMeta(dbPath, g, functionGraphData(g, analyzeConfidence(g, false), false), rows))
        match (indexMetaRead(dbPath)) {
            case Some(m) =>
                @Assert(m.updateCount == 3)
                @Assert(m.generatedAt == "2026-10-12T00:00:00+08:00")
                @Assert(m.depth == 2)
                match (m.probe()) {
                    case Some(back) => @Assert(probeMatches(back, probe))
                    case None => @Assert(false)
                }
            case None => @Assert(false)
        }
        // 数值键以 INTEGER 落库，TEXT 读侧也能取回（sqlite 自动转换）
        let ro = SqliteDb.openReadonly(dbPath)
        @Assert(ro.isSome())
        let db = ro.getOrThrow()
        var ucText = ""
        let stOpt = db.prepare("SELECT value FROM store_meta WHERE key = 'update_count'")
        @Assert(stOpt.isSome())
        let st = stOpt.getOrThrow()
        if (st.stepHasRow()) { ucText = st.columnText(0) }
        st.finalize()
        db.close()
        @Assert(ucText == "3")
        // 旧式写入（无 store_meta 行）：表在、行不在 → 无记录语义
        @Assert(graphDbWrite(dbPath, g, functionGraphData(g, analyzeConfidence(g, false), false)))
        match (indexMetaRead(dbPath)) {
            case Some(m) =>
                @Assert(m.updateCount == -1)
                @Assert(m.probeText.isEmpty())
            case None => @Assert(false)
        }
        // 库不存在
        removePathIfExists(dbPath)
        @Assert(indexMetaRead(dbPath).isNone())
    } finally {
        removePathIfExists(dbPath)
        removeTree(root)
    }
}

/// `index gen --format json` 的键集 = INDEX_JSON_KEYS（11 契约键 + 新增恒发键），
/// 投影不多不少；11 契约键的值与 fullGraphJson 同源同值。
@Test
func testIndexContractJsonKeySetIsExactlyDeclared(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        let payload = indexPayloadForStore(g, 6, conf, sourceProbeNow(root), 0, "T0", false)
        let contract = indexContractJson(payload)
        // 键集精确相等：多一个少一个都红（投影按清单来，清单只有一份）
        var got: Int64 = 0
        match (contract) {
            case JObj(m) =>
                for ((k, _) in m) {
                    got += 1
                    @Assert(INDEX_JSON_KEYS.contains(k))
                }
            case _ => @Assert(false)
        }
        @Assert(got == Int64(INDEX_JSON_KEYS.size))
        for (k in INDEX_JSON_KEYS) {
            @Assert(Json.has(contract, k))
        }
        // 11 契约键与 fullGraphJson 同源同值（键名不动 = 机读出口零破坏）
        let full = fullGraphJson(g, 6)
        for (k in ["root", "files", "importEdges", "referenceEdges", "truncated",
                   "skipped", "oversizeSkipped", "unreadableDirs",
                   "unreadableDirsTruncated", "depth", "depthOmitted"]) {
            @Assert(Json.pretty(Json.getOr(contract, k)) == Json.pretty(Json.getOr(full, k)))
        }
        @Assert(Json.intAt(contract, "updateCount", -1) == 0)
        @Assert(Json.intAt(contract, "tierFiles", -1) == Int64(Json.arrAt(full, "files").size))
        // 持久化 payload 比出口多渲染域键（functionGraph 等），但不串进出口
        @Assert(Json.has(payload, "functionGraph"))
        @Assert(!Json.has(contract, "functionGraph"))
        @Assert(!Json.has(contract, "confidence"))
        @Assert(!Json.has(contract, "langThemes"))
    } finally {
        removeTree(root)
    }
}

/// renderIndexHtml 两段拆分的行为锁：
/// ① 纯函数确定性——同 payload + 同 conf 同 confMissing ⇒ 逐字节一致；
/// ② updateCount/generatedAt 内嵌注释与读取器 round-trip；无 updateCount
///    的 payload（兼容面）没有注释，读取器 None；
/// ③ conf 覆盖改变产物；confMissing 打标记且图例文案在场；
/// ④ treeCanvasHtml ≡ indexPayload + renderIndexHtml 的组合（旧签名零漂移）。
@Test
func testRenderIndexHtmlTwoStageContract(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        let probe = sourceProbeNow(root)
        let p0 = indexPayloadForStore(g, 6, conf, probe, 0, "T0", false)
        let h1 = renderIndexHtml(p0, None<JsonValue>, false, false)
        let h2 = renderIndexHtml(indexPayloadForStore(g, 6, conf, probe, 0, "T0", false), None<JsonValue>, false, false)
        // ① 确定性：同输入重建 payload 再渲染，逐字节一致
        @Assert(h1 == h2)
        // ② 注释内嵌 + 读取器
        @Assert(h1.contains("updateCount=0"))
        @Assert(h1.contains("generatedAt=T0"))
        @Assert(renderIndexEmbeddedUpdateCount(h1) == Some<Int64>(0))
        @Assert(renderIndexEmbeddedGeneratedAt(h1) == "T0")
        @Assert(renderIndexEmbeddedGeneratedAt("<html>plain</html>") == "")
        let h5 = renderIndexHtml(indexPayloadForStore(g, 6, conf, probe, 5, "T5", false), None<JsonValue>, false, false)
        @Assert(renderIndexEmbeddedUpdateCount(h5) == Some<Int64>(5))
        // 无标记的文本（旧产物形状）→ None，绝不猜成 0
        @Assert(renderIndexEmbeddedUpdateCount("<html>plain</html>").isNone())
        // 兼容面（treeCanvasHtml）：payload 无 updateCount → 无注释 → 读取器 None
        let compat = treeCanvasHtml(g, 6, false, conf)
        @Assert(renderIndexEmbeddedUpdateCount(compat).isNone())
        // ④ 兼容面 ≡ 两段组合（临时 payload + 无覆盖 + 无标记）
        @Assert(compat == renderIndexHtml(indexPayload(g, 6, conf, false), None<JsonValue>, false, false))
        // ③ conf 覆盖改变产物（注入一个明显不同的置信度对象）
        let fake = Json.obj()
        Json.set(fake, "score", Json.of(42))
        Json.set(fake, "astUsed", Json.of(false))
        Json.set(fake, "astNote", Json.of("覆盖测试"))
        Json.set(fake, "cappedTotal", Json.of(false))
        Json.set(fake, "cappedKind", Json.of(false))
        Json.set(fake, "files", JArr(ArrayList<JsonValue>()))
        Json.set(fake, "findings", JArr(ArrayList<JsonValue>()))
        let hOverlay = renderIndexHtml(indexPayloadForStore(g, 6, conf, probe, 0, "T0", false), Some<JsonValue>(fake), false, false)
        @Assert(hOverlay != h1)
        @Assert(hOverlay.contains("覆盖测试"))
        // confMissing：payload 打标记 + 图例文案在场（不伪造分数）
        let hMissing = renderIndexHtml(indexPayloadForStore(g, 6, conf, probe, 0, "T0", false), None<JsonValue>, false, true)
        @Assert(hMissing != h1)
        @Assert(hMissing.contains("confMissing"))
        @Assert(hMissing.contains("无置信度数据"))
    } finally {
        removeTree(root)
    }
}
