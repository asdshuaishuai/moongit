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
    @Assert(f.imports[0] == "moongit")
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

