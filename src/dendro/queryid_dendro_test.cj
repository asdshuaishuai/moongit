// queryid_dendro_test.cj —— 从图谱包的 queryid_test.cj 搬来的用例：它要写带置信度的库（writeDbOf），
// 而 writeDbOf 依赖 Dendro；图谱包的测试不能再引入 Dendro（cjpm：循环依赖）。用例原文未改，只换了所在的包。

package cambium.dendro

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.util.*
import cambium.graph.*

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
