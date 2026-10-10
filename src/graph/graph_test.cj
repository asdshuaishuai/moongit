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
    // pid + 时间戳：只用 pid 时同一进程内多个夹具会互相覆盖，跨次运行也分不清
    let pid = getpid()
    return "${tempDirPath()}/moongit-graph-test-${pid}-${nowMillis()}"
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
    let wantOut = ["let x = 1", "", "", "", "", "", "code ", "let s = ", "let s = ", "let c = ",
        "let s = ", " ; more", "", "*/ tail",
        "a  b", "x = 1  ", "i--; q", "x = base#anchor",
        " let z = 2"]
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
    detectFromAst(stubNodes, stubFindings)
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

/// 代码图谱的 Web 导出（与 arch 同纪律：默认格式即 Web Canvas，引擎零实现
/// 也能直接打开看）。内嵌数据必须就是 `graph tree --json` 的同一份契约。
@Test
func testTreeCanvasHtmlExport(): Unit {
    let root = writeTree()
    try {
        let g = buildGraph(root)
        let conf = analyzeConfidence(g, false)
        let html = treeCanvasHtml(g, 8, false, conf)
        @Assert(html.contains("<canvas"))
        @Assert(html.contains("MoongitCodeGraph"))
        @Assert(html.contains("renderTo"))
        @Assert(html.contains("referenceEdges"))
        @Assert(html.contains("depthOmitted"))
        @Assert(html.contains("functionEdges"))
        @Assert(html.contains("codeSnippets"))
        @Assert(!html.contains("<script src"))
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
    var blk = false
    for (r in raw.split("\n")) {
        let (l, nb) = stripCjComment(r, blk)
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
    var blk = false
    for (r in raw.split("\n")) {
        let (l, nb) = stripCjComment(r, blk)
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

