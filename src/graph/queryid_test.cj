// graph/queryid_test.cj — 查询语义与稳定 id 的契约。
//
// 【与 members_test.cj 的分工】那边按扫描器语言逐段钉「提取与解析」；这里只钉两件事：
//   · 按声明处的 id 查询，回的是定义——agent 从头文件大纲拿到原型 id 之后的一跳；
//   · 稳定 id 跨两次构建逐项相等（不变量 141：id 不含自增整数、不含迭代序）。
package cambium.graph

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.util.*

/// 整个图按「文件|id」排序后的清单——两次构建各取一份，逐项比对。
func sortedSymbolIds(root: String): ArrayList<String> {
    let out = ArrayList<String>()
    let g = buildGraph(root)
    for (f in g.files) {
        for (s in f.symbols) { out.add(f.relPath + "|" + s.id(f.relPath)) }
    }
    insertionSort(out)
    return out
}

// MARK: - 稳定 id

/// 同一份源码建两次图，id 清单逐项相等。
/// （`#n` 后缀在 `Scanner.finish()` 里按扫描顺序递增，本就不看迭代序；扫描器一行只记一个符号起点，
/// 所以「同文件同行同名」造不出真实样例——这里不假装钉住了它。）
@Test
func testSymbolIdsAreIdenticalAcrossTwoBuilds(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/a.ts", "export function pick(a: number): number { return a }\n")
        writeFileAtomic("${root}/b.kt", "class Util {\n    fun twice(): Int64 { return 2 }\n}\n")
        writeFileAtomic("${root}/c.py", "class Box:\n    def open(self):\n        return 1\n")
        let first = sortedSymbolIds(root)
        let second = sortedSymbolIds(root)
        @Assert(first.size >= 3)
        @Assert(first.size == second.size)
        for (i in 0..first.size) {
            @Assert(first[i] == second[i])
        }
        // id 是坐标的纯函数：不带随机、不带时间、不带机器信息
        @Assert(first.contains("a.ts|f:a.ts:1:pick"))
        @Assert(first.contains("b.kt|f:b.kt:2:twice"))
        @Assert(first.contains("c.py|f:c.py:2:open"))
    } finally {
        removeTree(root)
    }
}
