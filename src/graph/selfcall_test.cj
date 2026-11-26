// graph/selfcall_test.cj — 假自环：显式接收者的同名调用不连回所在函数自身。
//
// `m_autoTimer->stop()` 写在 `AppModel::stop` 里：接收者的类型未知，裸名的唯一候选恰好是所在函数，
// 词法解析会连出一条 resolved 自环（探针工程 51 条自环里 49 条是这种，真递归只有 2 条）。
// 真递归（`this->stop()` / 裸调 `fact()`）必须原样保留。
package cambium.graph

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.util.*

/// 某文件里名字叫 [name] 的调用点（按行序——callSites 出口已排定全序）。
func sitesNamed(g: CodeGraph, file: String, name: String): ArrayList<ResolvedSite> {
    let out = ArrayList<ResolvedSite>()
    for (s in g.callSites) {
        if (s.file == file && s.name == name) { out.add(s) }
    }
    return out
}

/// C++ 形态：`x->stop()` 写在 `AppModel::stop` 里不连回自己；`this->stop()` 与裸调递归照常。
@Test
func testExplicitReceiverCallDoesNotLoopToItsOwnFunction(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/AppModel.cpp", """
void AppModel::stop() {
    m_autoTimer->stop();
    this->stop();
    Base::stop();
}

int fact(int n) {
    if (n <= 0) { return 1 }
    return n * fact(n - 1);
}
""")
        let g = buildGraph(root)
        let stop = sitesNamed(g, "AppModel.cpp", "stop")
        @Assert(stop.size == 3)
        // 负控：修之前这两处 dst == 自己的 id（假自环）——实例接收者与类型限定接收者各一
        @Assert(stop[0].receiver == 1)
        @Assert(stop[0].receiverText == "m_autoTimer")
        @Assert(stop[0].dst.isEmpty())
        // 真递归：显式 self 接收者 ⇒ direct
        @Assert(stop[1].dst == "f:AppModel.cpp:1:stop")
        @Assert(stop[1].tier == "direct")
        @Assert(stop[2].receiver == 2)
        @Assert(stop[2].receiverText == "Base")
        @Assert(stop[2].dst.isEmpty())
        // 真递归：裸调 ⇒ resolved
        let fact = sitesNamed(g, "AppModel.cpp", "fact")
        @Assert(fact.size == 1)
        @Assert(fact[0].dst == "f:AppModel.cpp:7:fact")
        @Assert(fact[0].tier == "resolved")
        // 边的层面：自环只剩真递归那两条
        let edges = callEdgesFrom(g.callSites, { p => true })
        @Assert(edgeTierOf(edges, "f:AppModel.cpp:1:stop", "f:AppModel.cpp:1:stop") == "direct")
        @Assert(edgeTierOf(edges, "f:AppModel.cpp:7:fact", "f:AppModel.cpp:7:fact") == "resolved")
    } finally {
        removeTree(root)
    }
}

/// Kotlin 形态同一口径：`timer.stop()` 不连回自己，`this.stop()` 照常。
@Test
func testExplicitReceiverCallDoesNotLoopToItsOwnFunctionKotlin(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/AppModel.kt", """
class AppModel {
    fun stop() {
        timer.stop()
        this.stop()
    }
}
""")
        let g = buildGraph(root)
        let stop = sitesNamed(g, "AppModel.kt", "stop")
        @Assert(stop.size == 2)
        @Assert(stop[0].receiver == 1)
        @Assert(stop[0].receiverText == "timer")
        @Assert(stop[0].dst.isEmpty())
        @Assert(stop[1].dst == "f:AppModel.kt:2:stop")
        @Assert(stop[1].tier == "direct")
    } finally {
        removeTree(root)
    }
}
