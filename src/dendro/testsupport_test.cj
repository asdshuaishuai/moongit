// testsupport_test.cj —— Dendro 测试用的夹具：从图谱包的测试文件**复制**来的（测试构建专用，不进库）。
// 为什么是复制：图谱包与 Dendro 是两个包，测试文件不能互相引入（cjpm：循环依赖），
// 夹具又太小不值得进正式代码。改一处记得两处——每段前面标了来处。

package cambium.dendro

import cambium.util.*
import std.collection.*
import cambium.graph.*
import std.convert.*
import std.fs.*
import std.sync.*
import std.posix.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*

// ── 复制自 src/graph/graph_test.cj（countOf）

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

// ── 复制自 src/graph/members_test.cj（edgeTierOf）

/// 边的 tier（按两端的稳定 id 找；找不到 = "<no edge>"）。
/// id 是 `f:<file>:<line>:<name>`——按**名字**而不是限定名：同文件同名的方法
/// （App.helper / Other.helper）靠行号区分。
func edgeTierOf(edges: ArrayList<CallEdge>, fromId: String, toId: String): String {
    for (e in edges) {
        if (e.from == fromId && e.to == toId) { return e.tier }
    }
    return "<no edge>"
}

// ── 复制自 src/graph/members_test.cj（hasEdge）

func hasEdge(edges: ArrayList<CallEdge>, fromId: String, toId: String): Bool {
    return edgeTierOf(edges, fromId, toId) != "<no edge>"
}

// ── 复制自 src/graph/graph_test.cj（removeTree）

// ⚠️ L16（审查）：这个函数原先是 `let _ = dir` 的空操作 —— 每个用例的
// finally 里都在「清理」，而临时目录一直留在 TMPDIR 下越积越多，且**测试全绿**，
// 没有任何断言会发现「残留」本身。util 的 removePathIfExists 早就有公开删除
// 入口（std.fs 的 remove(recursive:)），这里却另写一份假的。
func removeTree(dir: String): Unit {
    removePathIfExists(dir)
}

// ── 复制自 src/graph/graph_test.cj（testRootSeq）
// 进程内自增序号：并行用例下 pid + 毫秒会撞出同一路径（同进程同 pid，
// 两次 testRoot() 落进同一毫秒），两个夹具就会写同一棵树——
// 实测 --parallel 下 testTreeThreeViewsAndTierDefault 的 layered 夹具
// 因夹具树里混入 writeTree 的文件而不再是 31 个文件（同 util/hash.cj
// randomId 的口径：时间戳 + 序号，同毫秒内也保证唯一）。
let testRootSeq: AtomicInt64 = AtomicInt64(0)

// ── 复制自 src/graph/graph_test.cj（testRoot）

func testRoot(): String {
    // pid + 时间戳 + 序号：只用 pid 时同一进程内多个夹具会互相覆盖，跨次运行也分不清
    let pid = getpid()
    let seq = testRootSeq.fetchAdd(1)
    return "${tempDirPath()}/moongit-graph-test-${pid}-${nowMillis()}-${seq}"
}

// ── 复制自 src/graph/graph_test.cj（writeTree）

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

// ── 复制自 src/graph/embed_test.cj（isRegexStart）
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

// ── 复制自 src/graph/graph_test.cj（tempDirPath）
func tempDirPath(): String {
    match (getVariable("TMPDIR")) {
case Some(v) =>
                        if (v.trimAscii().size > 0) { return normalizePath(v) }
        case None => ()
    }
    return "/tmp"
}

