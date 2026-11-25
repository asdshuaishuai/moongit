// graph/queryid_test.cj — 查询语义与稳定 id 的契约。
//
// 【与 members_test.cj 的分工】那边按扫描器语言逐段钉「提取与解析」；这里只钉两件事：
//   · 按声明处的 id 查询，回的是定义——agent 从头文件大纲拿到原型 id 之后的一跳；
//   · 稳定 id 跨两次构建逐项相等（不变量 141：id 不含自增整数、不含迭代序）。
package moongit.graph

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

// MARK: - helpers

/// 文件大纲（`index file`）里第一个叫 [name] 的符号 id；找不到 = ""。
/// 走真实出口而不是手写 `f:app.h:3:start`：agent 就是这么拿到原型 id 的。
func outlineIdOf(dbPath: String, file: String, name: String): String {
    match (indexQueryFile(dbPath, file)) {
        case Some(q) =>
            for (s in Json.arrAt(q, "symbols")) {
                if (Json.strAt(s, "name", "") == name) { return Json.strAt(s, "id", "") }
            }
            return ""
        case None => return ""
    }
}

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

// MARK: - 声明处的 id 回定义

/// 头文件原型的 id ⇒ 回定义（调用方、调用点、影响面都在定义上）；
/// 只有声明、没有定义的照常回声明本身（不是查不到）。
@Test
func testQueryByDeclarationIdResolvesToDefinition(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/app.h", """
class AppModel {
public:
    void start();
    void ghost();
};
""")
        writeFileAtomic("${root}/app.cpp", """
#include "app.h"

void AppModel::start() {
}
""")
        writeFileAtomic("${root}/main.cpp", """
#include "app.h"

int main() {
    AppModel m;
    m.start();
    return 0;
}
""")
        let dbPath = writeDbOf(root, buildGraph(root))
        let protoId = outlineIdOf(dbPath, "app.h", "start")
        let ghostId = outlineIdOf(dbPath, "app.h", "ghost")
        @Assert(protoId.startsWith("f:app.h:"))
        @Assert(ghostId.startsWith("f:app.h:"))

        // 前提：头文件大纲里它确实是「只有声明」的那一条
        match (indexQuerySymbol(dbPath, ghostId)) {
            case Some(q) => @Assert(Json.boolAt(Json.arrAt(q, "defs")[0], "declOnly", false))
            case None => @Assert(false)
        }

        // 原型的 id ⇒ 回定义。修之前这里回的是原型本身：callers 恒空 ⇒
        // agent 会把「没人调用」当成事实（负控：去掉 resolveSymbolRows 里的回定义分支即红）。
        match (indexQuerySymbol(dbPath, protoId)) {
            case Some(q) =>
                let defs = Json.arrAt(q, "defs")
                @Assert(defs.size == 1)
                @Assert(Json.strAt(defs[0], "file", "") == "app.cpp")
                @Assert(Json.strAt(defs[0], "id", "") != protoId)
                @Assert(!Json.boolAt(defs[0], "declOnly", true))
                // 声明处挂在定义上：agent 拿到的 id 对应的那一行还在
                let decls = Json.arrAt(defs[0], "decls")
                @Assert(decls.size == 1)
                @Assert(Json.strAt(decls[0], "file", "") == "app.h")
                @Assert(Json.intAt(decls[0], "line", 0) == 3)
                @Assert(Json.arrAt(q, "callers").size >= 1)
            case None => @Assert(false)
        }

        // 只有声明、没有定义的：照常回声明本身
        match (indexQuerySymbol(dbPath, ghostId)) {
            case Some(q) =>
                let defs = Json.arrAt(q, "defs")
                @Assert(defs.size == 1)
                @Assert(Json.strAt(defs[0], "id", "") == ghostId)
                @Assert(Json.boolAt(defs[0], "declOnly", false))
                @Assert(Json.arrAt(q, "callers").size == 0)
            case None => @Assert(false)
        }

        // refs / impact 与 query 同一口径：原型 id 也拿得到调用点与影响面
        match (indexRefs(dbPath, protoId)) {
            case Some(r) =>
                @Assert(Json.strAt(Json.arrAt(r, "defs")[0], "file", "") == "app.cpp")
                @Assert(Json.arrAt(r, "sites").size >= 1)
            case None => @Assert(false)
        }
        match (indexImpact(dbPath, protoId, 3)) {
            case Some(r) =>
                @Assert(Json.strAt(Json.getOr(r, "def"), "file", "") == "app.cpp")
                @Assert(Json.arrAt(r, "impacted").size >= 1)
            case None => @Assert(false)
        }
    } finally {
        removeTree(root)
    }
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
