// members_dendro_test.cj —— 从图谱包的 members_test.cj 搬来的用例：它们断言的是 Dendro（置信度）的契约，
// 而图谱包的测试不能再引入 Dendro（cjpm：循环依赖）。用例原文未改，只换了所在的包。
// 建图、扫描这类被测能力仍是图谱包的公开接口（import cambium.graph）。

package cambium.dendro

import cambium.util.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.graph.*


let ID_HELPER_A: String = "f:a/helper.kt:3:helper"

let ID_ONLY_B: String = "f:a/only.kt:3:onlyB"

let ID_TWICE: String = "f:a/util.kt:4:twice"

let ID_SELF_CALL: String = "f:a/util.kt:8:selfCall"

let ID_UTIL: String = "f:a/util.kt:3:Util"

let ID_HELPER_B: String = "f:b/helper.kt:3:helper"

let ID_USER_B: String = "f:b/user.kt:3:userB"

let ID_ENTRY: String = "f:main.kt:3:entry"


// MARK: - 调用点解析

/// 三种确信度 + 未解析 + 内建丢弃 + 同模块唯一 + 顶层调用点（规则全文见 resolve.cj 头注释）。
@Test
func testCallSiteResolutionTiers(): Unit {
    let root = tierTree()
    try {
        let g = buildGraph(root)
        let edges = callEdgesFrom(g.callSites, { p => true })
        // direct：类型限定 `Util.twice(`；类型体内省略 this 的自身成员
        @Assert(edgeTierOf(edges, ID_HELPER_A, ID_TWICE) == "direct")
        @Assert(edgeTierOf(edges, ID_SELF_CALL, ID_TWICE) == "direct")
        // resolved：跨文件唯一
        @Assert(edgeTierOf(edges, ID_HELPER_A, ID_ONLY_B) == "resolved")
        @Assert(edgeTierOf(edges, ID_HELPER_A, ID_UTIL) == "resolved")   // 构造式调用 `Util(` → 类型
        // 同模块唯一：b/user.kt 的 helper() 只连 b/helper.kt
        @Assert(edgeTierOf(edges, ID_USER_B, ID_HELPER_B) == "resolved")
        @Assert(!hasEdge(edges, ID_USER_B, ID_HELPER_A))
        // guessed：调用者在根模块，a / b 各一个同名 ⇒ 两条都是 guessed
        @Assert(edgeTierOf(edges, ID_ENTRY, ID_HELPER_A) == "guessed")
        @Assert(edgeTierOf(edges, ID_ENTRY, ID_HELPER_B) == "guessed")
        // 每条 (调用方, 被调) 只有一条聚合边；权重 = 调用点数
        var helperToTwice: Int64 = 0
        for (e in edges) {
            if (e.to == ID_TWICE && e.from == ID_HELPER_A) {
                helperToTwice += 1
                @Assert(e.weight == 2)          // u.twice(2) 与 Util.twice(1)
            }
        }
        @Assert(helperToTwice == 1)
        @Assert(Int64(edges.size) == 7)

        // 调用点明细
        var ghost: Int64 = 0
        var printlnSites: Int64 = 0
        var bootSite: Option<ResolvedSite> = None
        for (s in g.callSites) {
            if (s.name == "ghost") {
                ghost += 1
                @Assert(s.dst.isEmpty())
                @Assert(s.tier.isEmpty())
                @Assert(s.caller == ID_HELPER_A)
            }
            if (s.name == "println") { printlnSites += 1 }
            if (s.file == "a/user.kt" && s.name == "onlyB") { bootSite = Some(s) }
        }
        @Assert(ghost == 1)          // 未解析照常入库
        @Assert(printlnSites == 0)   // 内建且全工程无同名定义 ⇒ 丢弃
        match (bootSite) {
            case Some(s) =>
                @Assert(s.caller.isEmpty())    // 顶层属性初始化器：不在任何函数体内
                @Assert(!s.dst.isEmpty())
                @Assert(s.line == 3)
            case None => @Assert(false)
        }
        // 序列化进函数图谱的边与聚合边同一口径
        let fg = functionGraphData(g, analyzeConfidence(g, false), false)
        @Assert(Int64(Json.arrAt(fg, "functionEdges").size) == Int64(edges.size))
    } finally {
        removeTree(root)
    }
}


// MARK: - 置信度检测器吃解析后的调用点（阶段二 B）

/// 孤儿检测的使用证据 = 提及证据 ∪ 调用证据；声明孪生不报。
///
/// ① 声明孪生（双向）：有同 qual 定义的原型不报——调用点连的是定义，原型的入度天然为 0，
///    报它等于把同一个死函数报两遍；只有原型、没有定义的照报。
/// ② 类型被当类型用（`struct Point origin;`，全仓没有一处 `Point(`）、函数被当值用
///    （`int (*g_handler)(int) = usedOnlyByPointer;`）都算使用——只认调用点会把它们
///    全部报成孤儿。真正没人用的（Dead / deadMethod 的定义）照报。
/// ③ finding 的符号键指向定义，不是原型。
@Test
func testOrphanUsesCallEvidenceAndSkipsDeclTwins(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/widget.h", """
class Widget {
public:
    void refresh(int n);
    void deadMethod();
};
int orphanProto(int v);
int usedOnlyByPointer(int v);
struct Point { int x; int y; };
struct Dead { int z; };
""")
        writeFileAtomic("${root}/widget.cpp", """
#include "widget.h"

void Widget::refresh(int n)
{
    (void)n;
}

void Widget::deadMethod()
{
}

int usedOnlyByPointer(int v)
{
    return v;
}

int (*g_handler)(int) = usedOnlyByPointer;

struct Point origin;

int main()
{
    Widget w;
    w.refresh(2);
    return 0;
}
""")
        let g = buildGraph(root)
        let rep = analyzeConfidence(g, false)
        var orphanAt = HashSet<String>()
        var deadMethodId = ""
        for (f in rep.findings) {
            if (flawId(f.kind) != "orphan") { continue }
            orphanAt.add(f.file + ":" + f.line.toString() + ":" + f.symbol)
            if (f.file == "widget.cpp" && f.symbol == "deadMethod") { deadMethodId = f.symId }
        }
        // ① 孪生：原型不报，定义照报，符号键指向定义
        @Assert(!orphanAt.contains("widget.h:4:deadMethod"))
        @Assert(orphanAt.contains("widget.cpp:8:deadMethod"))
        @Assert(deadMethodId == "f:widget.cpp:8:deadMethod")
        //    只有原型、没有定义 ⇒ 照报
        @Assert(orphanAt.contains("widget.h:6:orphanProto"))
        // ② 被调用的、被当值用的、被当类型用的：都不是孤儿
        @Assert(!orphanAt.contains("widget.h:3:refresh"))
        @Assert(!orphanAt.contains("widget.cpp:3:refresh"))
        @Assert(!orphanAt.contains("widget.h:7:usedOnlyByPointer"))
        @Assert(!orphanAt.contains("widget.cpp:12:usedOnlyByPointer"))
        @Assert(!orphanAt.contains("widget.h:8:Point"))
        //    真没人用的照报
        @Assert(orphanAt.contains("widget.h:9:Dead"))
    } finally {
        removeTree(root)
    }
}


/// 调用证据的判定（symbolsWithCallEvidence）：三种 tier 都算；声明位置上的调用点对被
/// 声明的那个符号不算（证据给同址真调用的其他候选）；自调用不算。
@Test
func testCallEvidenceTiersAndExclusions(): Unit {
    // tierTree：onlyB 被跨文件调用（resolved）与顶层调用；twice 限定 / 实例各一处；
    // entry、userB 无人调用。
    let root = tierTree()
    try {
        let g = buildGraph(root)
        let used = symbolsWithCallEvidence(g)
        @Assert(used.contains(ID_ONLY_B))
        @Assert(used.contains(ID_TWICE))
        @Assert(!used.contains(ID_ENTRY))
        @Assert(!used.contains(ID_USER_B))
        // 自调用不算：selfCall 体里只调了 twice
        @Assert(!used.contains(ID_SELF_CALL))
    } finally {
        removeTree(root)
    }
    // 表达体声明行上的同名真调用：`override fun f(): Int = super.f() + 1`
    // —— f( 在 Derived.f 的声明行上，裸名歧义把 Base.f 与 Derived.f 都列为候选；
    // 这一处证据给 Base.f，不给 Derived.f 自己。
    let root2 = testRoot()
    try {
        writeFileAtomic("${root2}/expr.kt", """
open class Base {
    open fun f(): Int = 1
}

class Derived : Base() {
    override fun f(): Int = super.f() + 1
}

fun caller(b: Base): Int {
    return b.f()
}
""")
        let g = buildGraph(root2)
        let baseF = "f:expr.kt:2:f"
        let derivedF = "f:expr.kt:6:f"
        let used = symbolsWithCallEvidence(g)
        @Assert(used.contains(baseF))
        // caller 里的 b.f() 也是歧义候选之一 ⇒ Derived.f 的证据来自 caller，不来自它自己的声明行
        @Assert(used.contains(derivedF))
        // 把 caller 拿掉：Derived.f 只剩自己声明行上的那一处 ⇒ 没有调用证据；Base.f 仍有
        writeFileAtomic("${root2}/expr.kt", """
open class Base {
    open fun f(): Int = 1
}

class Derived : Base() {
    override fun f(): Int = super.f() + 1
}
""")
        let g2 = buildGraph(root2)
        let used2 = symbolsWithCallEvidence(g2)
        @Assert(used2.contains(baseF))
        @Assert(!used2.contains(derivedF))
    } finally {
        removeTree(root2)
    }
}


/// 未解析调用的证据来源 = 解析后的调用点里 dst 为空的行（不是另一遍按行猜调用）。
///
/// 旧证据源（build.cj 里逐行找 `name(`）不认声明：嵌套函数的定义行 `def vkey(f):` 被当成
/// 「调用了全仓不存在的 vkey」——/tmp/itest 的 bootstrap-deps.py 就这样报过一条幻觉调用。
/// 新证据源：def 行不是调用点，不报。正控：真正全仓无定义的自由调用照报。
/// 带接收者的未解析调用点留在 callSites（sites.dst = 0）里，只是不进这份清单；
/// 有定义的成员无论 `obj->m(` 还是裸调 `m(` 都不报。
@Test
func testUnresolvedCallsComeFromResolvedSites(): Unit {
    let root = testRoot()
    try {
        // 与探针工程 bootstrap-deps.py 第 93–96 行同形：嵌套函数 + 按名传参
        writeFileAtomic("${root}/tools.py", """
def best(cands):
    def vkey(f):
        return len(f)
    return max(cands, key=vkey) if cands else None

def run(items):
    ghostCall(items)
    return best(items)
""")
        writeFileAtomic("${root}/card.h", """
class Card {
public:
    void setLevel(int l);
};

inline void Card::setLevel(int l)
{
    (void)l;
}
""")
        writeFileAtomic("${root}/use.cpp", """
#include "card.h"

int apply(Card *obj)
{
    obj->setLevel(2);
    return 0;
}
""")
        let g = buildGraph(root)
        var names = HashSet<String>()
        for ((_, name, _) in g.unresolvedCalls) { names.add(name) }
        // 嵌套函数的定义行不是调用点 ⇒ 旧证据源报的 vkey 不再报
        @Assert(!names.contains("vkey"))
        @Assert(!names.contains("best"))
        // 正控：真正全仓无定义的自由调用照报（判据没有放宽到空转）
        @Assert(names.contains("ghostCall"))
        // 有定义的成员：`obj->setLevel(2)` 解析到 Card.setLevel，不报
        @Assert(!names.contains("setLevel"))
        var sawResolved = false
        for (s in g.callSites) {
            if (s.name == "setLevel") {
                sawResolved = true
                @Assert(s.tier == "resolved")
                @Assert(s.dst == "f:card.h:6:setLevel")
            }
        }
        @Assert(sawResolved)
        // 带接收者的未解析调用点：留在调用点里（dst 为空），只是不进清单、不报疑点
        let rep = analyzeConfidence(g, false)
        var sawGhost = false
        for (f in rep.findings) {
            if (flawId(f.kind) != "unresolved-call") { continue }
            @Assert(f.symbol != "vkey")
            @Assert(f.symbol != "setLevel")
            if (f.symbol == "ghostCall") { sawGhost = true }
        }
        @Assert(sawGhost)
    } finally {
        removeTree(root)
    }
    // 带接收者的未解析调用点不被从索引里删掉
    let root2 = testRoot()
    try {
        writeFileAtomic("${root2}/ui.cpp", """
int paint(Window *w)
{
    w->frameworkOnly(1);
    frameworkFree(2);
    return 0;
}
""")
        let g = buildGraph(root2)
        var sawReceiverSite = false
        var sawFreeSite = false
        for (s in g.callSites) {
            if (s.name == "frameworkOnly") {
                sawReceiverSite = true
                @Assert(s.receiver == 1)
                @Assert(s.dst.isEmpty())
            }
            if (s.name == "frameworkFree") { sawFreeSite = true }
        }
        @Assert(sawReceiverSite)
        @Assert(sawFreeSite)
        var names = HashSet<String>()
        for ((_, name, _) in g.unresolvedCalls) { names.add(name) }
        @Assert(names.contains("frameworkFree"))
        @Assert(!names.contains("frameworkOnly"))
    } finally {
        removeTree(root2)
    }
    // unresolvedCallsFrom 的判据：dst 为空 + 自由调用 + 名字只在一个文件出现；
    // 每个 (file, name) 一条取首现处；输出全序。
    let sites = ArrayList<ResolvedSite>()
    func site(file: String, line: Int64, recv: Int64, name: String, dst: String): Unit {
        sites.add(ResolvedSite(file, line, 1, recv, if (recv == 0) { "" } else { "obj" }, name, "", dst, if (dst.isEmpty()) { "" } else { "resolved" }))
    }
    site("b.kt", 9, 0, "multi", "")
    site("a.kt", 5, 0, "multi", "")
    site("a.kt", 3, 0, "ghost", "")
    site("a.kt", 8, 0, "ghost", "")
    site("a.kt", 4, 1, "member", "")
    site("a.kt", 2, 0, "known", "f:a.kt:1:known")
    let nameFiles = HashMap<String, HashSet<String>>()
    func filesOf(name: String, fs: Array<String>): Unit {
        let set = HashSet<String>()
        for (x in fs) { set.add(x) }
        nameFiles[name] = set
    }
    filesOf("multi", ["a.kt", "b.kt"])
    filesOf("ghost", ["a.kt"])
    filesOf("member", ["a.kt"])
    let out = unresolvedCallsFrom(sites, nameFiles)
    @Assert(out.size == 1)
    @Assert(out[0][0] == "a.kt" && out[0][1] == "ghost" && out[0][2] == 3)
}


/// 检测器真的消费调用证据：名字从未被提及（referencedNames 为空）但有解析后的调用点
/// 连到它 ⇒ 不是孤儿。手工构造图谱，把两路证据拆开——真实代码里两路几乎总是同时出现，
/// 拿真实扫描测不出「少了调用证据这一路会怎样」。
@Test
func testOrphanDetectorConsumesCallEvidence(): Unit {
    let root = testRoot()
    try {
        let syms = ArrayList<SymDecl>()
        syms.add(SymDecl(Func, "called", 1))
        syms.add(SymDecl(Func, "uncalled", 5))
        let fe = FileEntry("g.c", "c", 9, syms, ArrayList<String>(), ArrayList<Int64>())
        let files = ArrayList<FileEntry>()
        files.add(fe)
        let sites = ArrayList<ResolvedSite>()
        sites.add(ResolvedSite("other.c", 2, 1, 0, "", "called", "f:other.c:1:caller", "f:g.c:1:called", "resolved"))
        let g = CodeGraph(root, files, ArrayList<(String, String)>(), ArrayList<(String, String, Int64)>(),
            false, 0, HashSet<String>(), ArrayList<(String, String, Int64)>(),
            ArrayList<(String, String, Int64)>(), 0, ArrayList<String>(),
            ArrayList<(String, String, Int64)>(), callSites: sites)
        let fs = ArrayList<Finding>()
        let cap = CapDropCounter()
        detectOrphans(g, fs, cap)
        @Assert(fs.size == 1)
        @Assert(fs[0].symbol == "uncalled")
        // 自调用不是证据：只被自己调用的函数照报
        sites.clear()
        sites.add(ResolvedSite("g.c", 7, 1, 0, "", "uncalled", "f:g.c:5:uncalled", "f:g.c:5:uncalled", "resolved"))
        let g2 = CodeGraph(root, files, ArrayList<(String, String)>(), ArrayList<(String, String, Int64)>(),
            false, 0, HashSet<String>(), ArrayList<(String, String, Int64)>(),
            ArrayList<(String, String, Int64)>(), 0, ArrayList<String>(),
            ArrayList<(String, String, Int64)>(), callSites: sites)
        let fs2 = ArrayList<Finding>()
        detectOrphans(g2, fs2, CapDropCounter())
        @Assert(fs2.size == 2)
    } finally {
        removeTree(root)
    }
}

// MARK: - helpers

/// JSON 对象的键（升序）。
func jsonKeysOf(o: JsonValue): ArrayList<String> {
    let out = ArrayList<String>()
    match (o) {
        case JObj(m) =>
            for ((k, _) in m) { out.add(k) }
        case _ => ()
    }
    insertionSort(out)
    return out
}

func keysAre(o: JsonValue, expected: String): Bool {
    let want = ArrayList<String>()
    for (k in expected.split(" ")) { want.add(k) }
    insertionSort(want)
    let got = jsonKeysOf(o)
    if (got.size != want.size) { return false }
    var i: Int64 = 0
    while (i < Int64(got.size)) {
        if (got[i] != want[i]) { return false }
        i += 1
    }
    return true
}

func writeDbOf(root: String, graph: CodeGraph): String {
    let dbPath = root + "/codegraph.db"
    @Assert(graphDbWrite(dbPath, graph, functionGraphData(graph, analyzeConfidence(graph, false), false)))
    return dbPath
}

/// 构建解析夹具：三种确信度 + 未解析 + 内建丢弃 + 同模块唯一 + 顶层调用点。
//
//   a/util.kt    class Util { fun twice; fun selfCall（裸调 twice = 自身成员 ⇒ direct） }
//   a/only.kt    fun onlyB（全工程唯一）
//   a/helper.kt  fun helper：Util().twice(2)（限定 ⇒ direct）、onlyB()（跨文件唯一 ⇒ resolved）、
//                ghost(1)（全工程无定义 ⇒ 未解析）、println(…)（内建 ⇒ 丢弃）
//   a/user.kt    顶层属性初始化器里的 onlyB()（不在任何函数体内 ⇒ caller 为空）
//   b/helper.kt  fun helper（与 a/helper.kt 同名 ⇒ 对 module 外的调用者是歧义）
//   b/user.kt    fun userB：helper()（同模块 b 里唯一 ⇒ resolved 到 b/helper.kt）
//   main.kt      fun entry：helper()（a、b 各一个，调用者在根模块 ⇒ guessed 连两条）
func tierTree(): String {
    let root = testRoot()
    ensureDir("${root}/a")
    ensureDir("${root}/b")
    writeFileAtomic("${root}/a/util.kt", """
package a

class Util {
    fun twice(x: Int): Int {
        return x * 2
    }

    fun selfCall(): Int {
        return twice(3)
    }
}
""")
    writeFileAtomic("${root}/a/only.kt", """
package a

fun onlyB(): Int {
    return 3
}
""")
    writeFileAtomic("${root}/a/helper.kt", """
package a

fun helper(): Int {
    val u = Util()
    val r = u.twice(2) + Util.twice(1) + onlyB()
    println("done")
    ghost(1)
    return r
}
""")
    writeFileAtomic("${root}/a/user.kt", """
package a

val boot = onlyB()
""")
    writeFileAtomic("${root}/b/helper.kt", """
package b

fun helper(): Int {
    return 2
}
""")
    writeFileAtomic("${root}/b/user.kt", """
package b

fun userB(): Int {
    return helper()
}
""")
    writeFileAtomic("${root}/main.kt", """
package main

fun entry(): Int {
    return helper()
}
""")
    return root
}

// MARK: - SQLite v2 读路径

/// schema v2：nodes 的成员级列、sites 表、generator；v1 库被判过期。
@Test
func testDbSchemaV2AndStaleV1(): Unit {
    let root = tierTree()
    try {
        let g = buildGraph(root)
        let dbPath = writeDbOf(root, g)
        @Assert(indexDbIsCurrent(dbPath))
        let ro = SqliteDb.openReadonly(dbPath).getOrThrow()
        @Assert(dbScalar(ro, "SELECT value FROM meta WHERE key='generator'") == GRAPH_DB_GENERATOR)
        @Assert(GRAPH_DB_GENERATOR == "moongit graph db v2")
        // 成员级列真的有值
        @Assert(dbScalar(ro, "SELECT qual FROM nodes WHERE sid='f:a/util.kt:4:twice'") == "Util.twice")
        @Assert(dbScalar(ro, "SELECT end_line FROM nodes WHERE sid='f:a/util.kt:4:twice'") == "6")
        @Assert(dbScalar(ro, "SELECT col FROM nodes WHERE sid='f:a/util.kt:4:twice'") == "9")
        @Assert(dbScalar(ro, "SELECT sig FROM nodes WHERE sid='f:a/util.kt:4:twice'") == "fun twice(x: Int): Int")
        @Assert(dbScalar(ro, "SELECT COUNT(*) FROM nodes WHERE sid IS NULL OR sid=''") == "0")
        @Assert(dbScalar(ro, "SELECT COUNT(DISTINCT sid) FROM nodes") == dbScalar(ro, "SELECT COUNT(*) FROM nodes"))
        // sites：每个调用点一行；未解析 dst = 0；顶层调用点 src = 0
        @Assert(dbScalar(ro, "SELECT tier FROM sites WHERE name='twice' AND receiver='Util'") == "direct")
        // 同一条边的另一个调用点是实例接收者（u.twice）⇒ 裸名解析 resolved；聚合边取最确定的一档
        @Assert(dbScalar(ro, "SELECT tier FROM sites WHERE name='twice' AND receiver='u'") == "resolved")
        @Assert(dbScalar(ro, "SELECT COUNT(*) FROM sites WHERE name='ghost' AND dst=0") == "1")
        @Assert(dbScalar(ro, "SELECT COUNT(*) FROM sites WHERE file='a/user.kt' AND name='onlyB' AND src=0") == "1")
        @Assert(dbScalar(ro, "SELECT COUNT(*) FROM sites WHERE name='println'") == "0")
        ro.close()
        match (indexOverviewRead(dbPath)) {
            case Some(ov) =>
                @Assert(ov.sites > 0)
                @Assert(ov.unresolved == 1)
                @Assert(ov.tierDirect + ov.tierResolved + ov.tierGuessed == ov.edges)
                @Assert(ov.tierGuessed == 2)
                @Assert(ov.tierDirect == 2)
            case None => @Assert(false)
        }
        // v1 库：generator 不是当前版本 ⇒ 过期
        let v1 = root + "/v1.db"
        let w = SqliteDb.open(v1).getOrThrow()
        @Assert(w.exec("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)"))
        @Assert(w.exec("CREATE TABLE nodes(id INTEGER PRIMARY KEY, kind TEXT, name TEXT, file TEXT, line INTEGER, lang TEXT, findings INTEGER, max_weight INTEGER)"))
        @Assert(w.exec("INSERT INTO meta(key, value) VALUES('generator', 'moongit graph db v1')"))
        w.close()
        @Assert(!indexDbIsCurrent(v1))
        @Assert(!indexDbIsCurrent(root + "/never-exists.db"))
    } finally {
        removeTree(root)
    }
}

/// 五个查询出口的 JSON 键集恒定——不随「有没有调用方 / 有没有声明处 / 歧不歧义」增减。
@Test
func testIndexQueryJsonKeySetIsConstant(): Unit {
    let root = tierTree()
    try {
        let g = buildGraph(root)
        let dbPath = writeDbOf(root, g)
        let symKeys = "id dbId kind name qual file line endLine col lang sig visibility declOnly findings maxWeight decls"
        let edgeKeys = "name qual file line weight tier sites"
        // ── 有调用方、有被调（helper）／ 没有调用方（userB）／ 歧义 ──
        let cases = ["helper", "onlyB", "userB", "Util.twice", "f:a/only.kt:3:onlyB"]
        for (sym in cases) {
            match (indexQuerySymbol(dbPath, sym)) {
                case Some(q) =>
                    @Assert(keysAre(q, "symbol ambiguous defs callers callees perDef"))
                    for (d in Json.arrAt(q, "defs")) { @Assert(keysAre(d, symKeys)) }
                    for (e in Json.arrAt(q, "callers")) { @Assert(keysAre(e, edgeKeys)) }
                    for (e in Json.arrAt(q, "callees")) { @Assert(keysAre(e, edgeKeys)) }
                    for (pd in Json.arrAt(q, "perDef")) {
                        @Assert(keysAre(pd, "def callers callees"))
                        @Assert(keysAre(Json.getOr(pd, "def"), symKeys))
                    }
                case None => @Assert(false)
            }
        }
        // 歧义的裸名：ambiguous + perDef 逐定义；限定名 / id：单定义
        match (indexQuerySymbol(dbPath, "helper")) {
            case Some(q) =>
                @Assert(Json.boolAt(q, "ambiguous", false))
                @Assert(Int64(Json.arrAt(q, "perDef").size) == 2)
            case None => @Assert(false)
        }
        match (indexQuerySymbol(dbPath, "onlyB")) {
            case Some(q) => @Assert(!Json.boolAt(q, "ambiguous", false))
            case None => @Assert(false)
        }
        match (indexQuerySymbol(dbPath, "f:a/only.kt:3:onlyB")) {
            case Some(q) => @Assert(Int64(Json.arrAt(q, "defs").size) == 1)
            case None => @Assert(false)
        }
        @Assert(indexQuerySymbol(dbPath, "__no_such_symbol__").isNone())
        // ── search ──
        for (pat in ["helper", "zzz-no-match", "only"]) {
            let q = indexSearch(dbPath, pat, "", "", "", 30)
            @Assert(keysAre(q, "query mode total truncated results"))
            for (r in Json.arrAt(q, "results")) {
                @Assert(keysAre(r, symKeys + " score"))
            }
        }
        // ── refs ──
        for (sym in ["onlyB", "helper", "Util.twice"]) {
            match (indexRefs(dbPath, sym)) {
                case Some(q) =>
                    @Assert(keysAre(q, "symbol defs sites"))
                    for (d in Json.arrAt(q, "defs")) { @Assert(keysAre(d, symKeys)) }
                    for (s in Json.arrAt(q, "sites")) {
                        @Assert(keysAre(s, "defId file line col receiver tier caller callerQual callerFile callerLine"))
                    }
                case None => @Assert(false)
            }
        }
        @Assert(indexRefs(dbPath, "__no_such_symbol__").isNone())
        // ── impact ──
        for (sym in ["onlyB", "entry", "Util.twice"]) {
            match (indexImpact(dbPath, sym, 4)) {
                case Some(q) =>
                    @Assert(keysAre(q, "symbol def depth impacted files"))
                    @Assert(keysAre(Json.getOr(q, "def"), symKeys))
                    for (r in Json.arrAt(q, "impacted")) { @Assert(keysAre(r, symKeys + " distance")) }
                    for (f in Json.arrAt(q, "files")) { @Assert(keysAre(f, "file symbols")) }
                case None => @Assert(false)
            }
        }
        // ── file ──
        for (fp in ["a/helper.kt", "b/user.kt", "a/util.kt"]) {
            match (indexQueryFile(dbPath, fp)) {
                case Some(q) =>
                    @Assert(keysAre(q, "file lang lines symbols calledBy calls"))
                    for (s in Json.arrAt(q, "symbols")) { @Assert(keysAre(s, symKeys)) }
                    for (c in Json.arrAt(q, "calledBy")) { @Assert(keysAre(c, "file weight")) }
                    for (c in Json.arrAt(q, "calls")) { @Assert(keysAre(c, "file weight")) }
                case None => @Assert(false)
            }
        }
        // 调用点条目：有接收者 / 无接收者 / 顶层（无 caller）键集一致
        var bare: Option<JsonValue> = None
        var qualified: Option<JsonValue> = None
        match (indexRefs(dbPath, "twice")) {
            case Some(q) =>
                for (s in Json.arrAt(q, "sites")) {
                    if (Json.strAt(s, "receiver", "") == "Util") { qualified = Some(s) }
                    if (Json.strAt(s, "receiver", "").isEmpty() && bare.isNone()) { bare = Some(s) }
                }
            case None => @Assert(false)
        }
        match (indexRefs(dbPath, "onlyB")) {
            case Some(q) =>
                for (s in Json.arrAt(q, "sites")) {
                    if (Json.strAt(s, "caller", "").isEmpty()) {
                        // 顶层调用点：caller 为空，但键在
                        @Assert(keysAre(s, "defId file line col receiver tier caller callerQual callerFile callerLine"))
                    }
                }
            case None => @Assert(false)
        }
        match (bare) {
            case Some(b0) =>
                match (qualified) {
                    case Some(q0) => @Assert(jsonKeysOf(b0).size == jsonKeysOf(q0).size)
                    case None => @Assert(false)
                }
            case None => @Assert(false)
        }
    } finally {
        removeTree(root)
    }
}

/// C++ 的声明连到定义：原型不单独算 def，作为定义的 decls 呈现；文件级调入/调出不含自身。
@Test
func testDeclTwinAttachedAndNoFileSelfLoop(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/app.h", """
class AppModel {
public:
    void start();
    void stop();
};
""")
        writeFileAtomic("${root}/app.cpp", """
#include "app.h"

void AppModel::start() {
    AppModel m;
}

void AppModel::stop() {
}
""")
        let g = buildGraph(root)
        let dbPath = writeDbOf(root, g)
        match (indexQuerySymbol(dbPath, "AppModel.start")) {
            case Some(q) =>
                let defs = Json.arrAt(q, "defs")
                @Assert(defs.size == 1)
                @Assert(Json.strAt(defs[0], "file", "") == "app.cpp")
                @Assert(!Json.boolAt(defs[0], "declOnly", true))
                let decls = Json.arrAt(defs[0], "decls")
                @Assert(decls.size == 1)
                @Assert(Json.strAt(decls[0], "file", "") == "app.h")
                @Assert(Json.intAt(decls[0], "line", 0) == 3)
            case None => @Assert(false)
        }
        // 裸名 start 也只有一个 def（原型不重复计）
        match (indexQuerySymbol(dbPath, "start")) {
            case Some(q) => @Assert(Int64(Json.arrAt(q, "defs").size) == 1)
            case None => @Assert(false)
        }
        // 文件大纲如实列出原型（它就在这个文件里）
        match (indexQueryFile(dbPath, "app.h")) {
            case Some(q) =>
                var proto: Int64 = 0
                for (s in Json.arrAt(q, "symbols")) {
                    if (Json.boolAt(s, "declOnly", false)) { proto += 1 }
                }
                @Assert(proto == 2)
            case None => @Assert(false)
        }
        // 文件级调入/调出不含文件自身（app.cpp 里 start 的函数体属于 app.cpp）
        match (indexQueryFile(dbPath, "app.cpp")) {
            case Some(q) =>
                for (c in Json.arrAt(q, "calls")) { @Assert(Json.strAt(c, "file", "") != "app.cpp") }
                for (c in Json.arrAt(q, "calledBy")) { @Assert(Json.strAt(c, "file", "") != "app.cpp") }
            case None => @Assert(false)
        }
    } finally {
        removeTree(root)
    }
}

/// search：排名规则与过滤。
@Test
func testSearchRankingAndFilters(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/a.kt", """
package a

fun render(): Int { return 1 }
fun renderGraphArtifact(): Int { return 2 }
fun xRender(): Int { return 3 }
fun recent_diner(): Int { return 4 }
""")
        writeFileAtomic("${root}/b.kt", """
package b

class Widget {
    fun render(): Int { return 5 }
}

class Render {
    fun display(): Int { return 6 }
}

fun board(): Int { return 7 }
""")
        let g = buildGraph(root)
        let dbPath = writeDbOf(root, g)
        let q = indexSearch(dbPath, "render", "", "", "", 30)
        @Assert(Json.intAt(q, "total", 0) == 7)          // board 不算
        let res = Json.arrAt(q, "results")
        @Assert(Int64(res.size) == 7)
        @Assert(!Json.boolAt(q, "truncated", true))
        // 100：名字精确（不区分大小写）；并列按名字长度、再按路径、再按行
        @Assert(Json.strAt(res[0], "qual", "") == "render")     // 顶层函数：qual == 裸名
        @Assert(Json.strAt(res[1], "qual", "") == "Widget.render")
        @Assert(Json.strAt(res[2], "qual", "") == "Render")
        @Assert(Json.intAt(res[0], "score", 0) == 100)
        @Assert(Json.intAt(res[1], "score", 0) == 100)
        @Assert(Json.intAt(res[2], "score", 0) == 100)
        // 85：名字前缀
        @Assert(Json.strAt(res[3], "name", "") == "renderGraphArtifact")
        @Assert(Json.intAt(res[3], "score", 0) == 85)
        // 65：名字里的子串
        @Assert(Json.strAt(res[4], "name", "") == "xRender")
        @Assert(Json.intAt(res[4], "score", 0) == 65)
        // 50：限定名里的子串（方法名 display 本身不含）
        @Assert(Json.strAt(res[5], "qual", "") == "Render.display")
        @Assert(Json.intAt(res[5], "score", 0) == 50)
        // ≤ 40：名字的子序列
        @Assert(Json.strAt(res[6], "name", "") == "recent_diner")
        @Assert(Json.intAt(res[6], "score", 0) <= 40)
        // 限定名精确相等高于裸名子串
        let q2 = indexSearch(dbPath, "Widget.render", "", "", "", 30)
        @Assert(Json.strAt(Json.arrAt(q2, "results")[0], "qual", "") == "Widget.render")
        @Assert(Json.intAt(Json.arrAt(q2, "results")[0], "score", 0) == 98)
        // 限流与披露
        let q3 = indexSearch(dbPath, "render", "", "", "", 2)
        @Assert(Int64(Json.arrAt(q3, "results").size) == 2)
        @Assert(Json.intAt(q3, "total", 0) == 7)
        @Assert(Json.boolAt(q3, "truncated", false))
        // 过滤：种类 / 语言 / 文件
        let byKind = indexSearch(dbPath, "render", "class", "", "", 30)
        @Assert(Json.intAt(byKind, "total", 0) == 1)
        @Assert(Json.strAt(Json.arrAt(byKind, "results")[0], "name", "") == "Render")
        @Assert(Json.intAt(indexSearch(dbPath, "render", "func", "", "", 30), "total", 0) == 6)
        @Assert(Json.intAt(indexSearch(dbPath, "render", "", "kotlin", "", 30), "total", 0) == 7)
        @Assert(Json.intAt(indexSearch(dbPath, "render", "", "swift", "", 30), "total", 0) == 0)
        @Assert(Json.intAt(indexSearch(dbPath, "render", "", "", "a.kt", 30), "total", 0) == 4)
        // 无命中：键集不变
        let none = indexSearch(dbPath, "zzz-no-match", "", "", "", 30)
        @Assert(Json.intAt(none, "total", 0) == 0)
        @Assert(keysAre(none, "query mode total truncated results"))
    } finally {
        removeTree(root)
    }
}

/// refs：每个调用点的位置、确信度、所在函数；impact：沿 direct / resolved 反向闭包。
@Test
func testRefsAndImpact(): Unit {
    let root = tierTree()
    try {
        let g = buildGraph(root)
        let dbPath = writeDbOf(root, g)
        match (indexRefs(dbPath, "onlyB")) {
            case Some(q) =>
                let sites = Json.arrAt(q, "sites")
                @Assert(sites.size == 2)
                // a/helper.kt 里的 onlyB()：caller 是 a/helper.kt 的 helper
                @Assert(Json.strAt(sites[0], "file", "") == "a/helper.kt")
                @Assert(Json.strAt(sites[0], "callerFile", "") == "a/helper.kt")
                @Assert(Json.strAt(sites[0], "callerQual", "") == "helper")
                @Assert(Json.strAt(sites[0], "tier", "") == "resolved")
                @Assert(Json.strAt(sites[0], "defId", "") == "f:a/only.kt:3:onlyB")
                @Assert(Json.intAt(sites[0], "line", 0) == 5)
                @Assert(Json.intAt(sites[0], "col", 0) > 0)
                // a/user.kt 顶层属性初始化器：没有 caller，但键在
                @Assert(Json.strAt(sites[1], "file", "") == "a/user.kt")
                @Assert(Json.strAt(sites[1], "caller", "").isEmpty())
            case None => @Assert(false)
        }
        // 裸名歧义的符号：refs 覆盖它的全部定义与全部解析目标
        // （b/user.kt → b 的 helper；main.kt 的 entry 对 a、b 各连一条 guessed）
        match (indexRefs(dbPath, "helper")) {
            case Some(q) => @Assert(Int64(Json.arrAt(q, "sites").size) == 3)
            case None => @Assert(false)
        }
        // impact：onlyB ← helper（resolved）；entry → helper 是 guessed ⇒ 不参与
        match (indexImpact(dbPath, "onlyB", 4)) {
            case Some(q) =>
                let imp = Json.arrAt(q, "impacted")
                @Assert(imp.size == 1)
                @Assert(Json.strAt(imp[0], "qual", "") == "helper")
                @Assert(Json.strAt(imp[0], "file", "") == "a/helper.kt")
                @Assert(Json.intAt(imp[0], "distance", 0) == 1)
                @Assert(Json.intAt(q, "depth", 0) == 4)
                @Assert(Json.intAt(Json.arrAt(q, "files")[0], "symbols", 0) == 1)
            case None => @Assert(false)
        }
        // impact：twice ← selfCall（direct）、helper（direct）
        match (indexImpact(dbPath, "Util.twice", 4)) {
            case Some(q) => @Assert(Int64(Json.arrAt(q, "impacted").size) == 2)
            case None => @Assert(false)
        }
        // 深度截断：depth 1 只到直接调用者；depth 2 再往外没有新的（entry 走的是 guessed）
        match (indexImpact(dbPath, "onlyB", 1)) {
            case Some(q) => @Assert(Int64(Json.arrAt(q, "impacted").size) == 1)
            case None => @Assert(false)
        }
        @Assert(indexImpact(dbPath, "__no_such_symbol__", 4).isNone())
    } finally {
        removeTree(root)
    }
}

/// 查询输出逐字节确定：同一份库两次查询结果相同（HashMap 不参与出口顺序）。
@Test
func testIndexQueriesAreDeterministic(): Unit {
    let root = tierTree()
    try {
        let g = buildGraph(root)
        let dbPath = writeDbOf(root, g)
        for (sym in ["helper", "Util.twice", "onlyB"]) {
            match (indexQuerySymbol(dbPath, sym)) {
                case Some(a) =>
                    match (indexQuerySymbol(dbPath, sym)) {
                        case Some(b) => @Assert(Json.compact(a) == Json.compact(b))
                        case None => @Assert(false)
                    }
                case None => @Assert(false)
            }
        }
        @Assert(Json.compact(indexSearch(dbPath, "e", "", "", "", 30)) ==
            Json.compact(indexSearch(dbPath, "e", "", "", "", 30)))
    } finally {
        removeTree(root)
    }
}

/// 入库层面：sites 里没有「落在某个符号自己声明行上、名字也相同」的行，
/// 没有解析到自己的调用点，没有自环边；`index refs` 不再把定义行报成引用。
@Test
func testSitesNeverPointAtTheSymbolOwnDeclarationLine(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/widget.h", """
class Widget {
public:
    void refresh(int n);
};
""")
        writeFileAtomic("${root}/widget.cpp", """
#include "widget.h"

void Widget::refresh(int n)
{
    (void)n;
}

void use(Widget &w)
{
    w.refresh(2);
}
""")
        writeFileAtomic("${root}/allman.go", """
package main

func wide(
    a int,
    b int,
) int {
    return helper(a, b)
}
""")
        let g = buildGraph(root)
        let dbPath = writeDbOf(root, g)
        let ro = SqliteDb.openReadonly(dbPath).getOrThrow()
        @Assert(dbScalar(ro, "SELECT COUNT(*) FROM sites s JOIN nodes n ON n.file = s.file AND n.line = s.line AND n.name = s.name") == "0")
        @Assert(dbScalar(ro, "SELECT COUNT(*) FROM sites s JOIN nodes n ON n.id = s.dst WHERE n.file = s.file AND n.line = s.line AND n.name = s.name") == "0")
        @Assert(dbScalar(ro, "SELECT COUNT(*) FROM edges WHERE src = dst") == "0")
        // 正控：`w.refresh(2)` 是真调用点，照常入库并解析到 Widget.refresh
        @Assert(dbScalar(ro, "SELECT tier FROM sites WHERE name='refresh' AND receiver='w'") == "resolved")
        // 入库的调用点数 = 扫描器采到的调用点数（没有被丢行去凑数字）
        @Assert(dbScalar(ro, "SELECT COUNT(*) FROM sites") == Int64(g.callSites.size).toString())
        ro.close()
    } finally {
        removeTree(root)
    }
}
