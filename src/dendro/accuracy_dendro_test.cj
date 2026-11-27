// accuracy_dendro_test.cj —— 置信度检测器准确性批的判据（每条修复一组：正控 + 负向防线）。
//
// 【这一批判什么】两个真实仓库上的抽样：stub-body 104 条里 103 条是误报、unresolved-call
// 152 条 0 条查实、lock-imbalance / pointer-risk 全是误报、语义层把「下一个符号之前」当函数体。
// 每条用例都钉住「误报不再报」与「真问题照报」两头——只测前一头等于把判据放宽到空转。

package cambium.dendro

import cambium.util.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.posix.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.graph.*

// ── 夹具与辅助 ──

func accRoot(): String {
    return "${tempDirPath()}/cambium-acc-${getpid()}-${nowMillis()}-${testRootSeq.fetchAdd(1)}"
}

/// 某一类疑点的「符号:行」清单（按出现顺序）。
func picks(findings: ArrayList<Finding>, kind: FlawKind): ArrayList<String> {
    let out = ArrayList<String>()
    let kid = flawId(kind)
    for (f in findings) {
        if (flawId(f.kind) == kid) { out.add(f.symbol + ":" + f.line.toString()) }
    }
    return out
}

func hasPick(findings: ArrayList<Finding>, kind: FlawKind, symbol: String): Bool {
    let kid = flawId(kind)
    for (f in findings) {
        if (flawId(f.kind) == kid && f.symbol == symbol) { return true }
    }
    return false
}

func countKind(findings: ArrayList<Finding>, kind: FlawKind): Int64 {
    let kid = flawId(kind)
    var n: Int64 = 0
    for (f in findings) {
        if (flawId(f.kind) == kid) { n += 1 }
    }
    return n
}

func linesOf(text: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (l in text.split("\n")) { out.add(l) }
    return out
}

/// 空图（给只需要 graph 形参的检测器用）。
func emptyGraph(): CodeGraph {
    let root = accRoot()
    ensureDir(root)
    let g = buildGraph(root)
    removePathIfExists(root)
    return g
}

// ── 占位实现：表达式体 / 无体声明 / 初始化列表构造函数不是占位 ──

/// 实测 deepDolphin 语法树档 stub-body 104 条里 103 条是误报：Kotlin 表达式体
/// `fun f(x) = expr`、无体的接口方法、C++ 带初始化列表的构造函数、`= default`、
/// Python 体内出现 `{}` 的函数；空 catch 还被 stub-body 与 swallowed-error 各报一次。
@Test
func testExpressionBodyAndBodylessDeclarationAreNotStubs(): Unit {
    let nodes = ArrayList<AstNode>()
    nodes.add(AstNode("a.kt", 10, 10, "fn", "fun arg(key: String) = obj[key]?.toString() ?: \"\""))
    nodes.add(AstNode("a.kt", 11, 11, "fn", "fun isConfigured(whyNot: (String) -> Unit = {}): Boolean"))
    nodes.add(AstNode("a.kt", 12, 12, "fn", "fun todo(): Int = TODO()"))
    nodes.add(AstNode("a.kt", 13, 15, "fn", "fun empty(): Int {\n\n}"))
    nodes.add(AstNode("w.cpp", 20, 23, "fn", "Widget::Widget(const QString &p) : m_p(p)\n{\n}"))
    nodes.add(AstNode("w.cpp", 30, 30, "fn", "Widget::~Widget() = default;"))
    nodes.add(AstNode("w.cpp", 40, 41, "fn", "void Widget::noop()\n{\n}"))
    nodes.add(AstNode("p.py", 50, 53, "fn", "def scope_files():\n    out = {}\n    return out"))
    nodes.add(AstNode("p.py", 60, 61, "fn", "def log_message(self, *a):\n    pass"))
    nodes.add(AstNode("p.py", 70, 72, "fn", "@tool\ndef decorated():\n    return 1"))
    nodes.add(AstNode("p.py", 80, 80, "fn", "def oneline(x): return x"))
    nodes.add(AstNode("a.kt", 90, 91, "catch", "catch (e: Exception) {\n}"))
    let findings = ArrayList<Finding>()
    detectFromAst(nodes, findings, CapDropCounter())
    // 真占位照报
    @Assert(hasPick(findings, StubBody, "arg") == false)
    @Assert(hasPick(findings, StubBody, "isConfigured") == false)
    @Assert(hasPick(findings, StubBody, "Widget") == false)
    @Assert(hasPick(findings, StubBody, "scope_files") == false)
    @Assert(hasPick(findings, StubBody, "decorated") == false)
    @Assert(hasPick(findings, StubBody, "oneline") == false)
    @Assert(hasPick(findings, StubBody, "todo"))
    @Assert(hasPick(findings, StubBody, "empty"))
    @Assert(hasPick(findings, StubBody, "noop"))
    @Assert(hasPick(findings, StubBody, "log_message"))
    @Assert(countKind(findings, StubBody) == 4)
    // 空 catch 只报一次（swallowed-error），不再另报 stub-body
    @Assert(countKind(findings, SwallowedError) == 1)
    @Assert(countKind(findings, StubBody) == 4)
}

// ── 节点名：取声明名，不是 `fun` ──

/// 原实现取「第一个不在 KEYWORDS 里的 token」：`private fun keyFile()` 报出来的符号是 `fun`。
@Test
func testNodeNameIsTheDeclaredName(): Unit {
    @Assert(nodeName(AstNode("a.kt", 1, 1, "fn", "internal fun keyFile(): File = File(dir(), \"k\")")) == "keyFile")
    @Assert(nodeName(AstNode("a.kt", 1, 1, "fn", "private fun <T> decode(r: MultiResults): List<T> = r.map(::x)")) == "decode")
    @Assert(nodeName(AstNode("m.cj", 1, 1, "fn", "public func mcpCallTool(name: String, args: JsonValue): JsonValue {")) == "mcpCallTool")
    @Assert(nodeName(AstNode("e.cpp", 1, 1, "fn", "bool AgentCore::isConfigured(QString *whyNot) const")) == "isConfigured")
    @Assert(nodeName(AstNode("e.cpp", 1, 1, "fn", "explicit AgentCore(const QString &engineBin) : m_bin(engineBin) {")) == "AgentCore")
    @Assert(nodeName(AstNode("t.cpp", 1, 1, "fn", "QDBusArgument &operator<<(QDBusArgument &arg, const Pixmap &p)")) == "operator<<")
    @Assert(nodeName(AstNode("m.py", 1, 1, "fn", "    def __getitem__(self, k):")) == "__getitem__")
    @Assert(nodeName(AstNode("a.swift", 1, 1, "fn", "static func getDetailed(service: String, account: String) -> (value: String?, status: OSStatus) {")) == "getDetailed")
    @Assert(nodeName(AstNode("a.swift", 1, 1, "type", "class Foo: Base {")) == "Foo")
    @Assert(nodeName(AstNode("b.h", 1, 1, "type", "struct Bar {")) == "Bar")
    @Assert(nodeName(AstNode("a.kt", 1, 1, "type", "enum class WebPhase(val key: String) {")) == "WebPhase")
    @Assert(nodeName(AstNode("a.kt", 1, 1, "fn", "override suspend fun generate(req: GenerateRequest): GenerateResult")) == "generate")
}

/// catch 节点自己没有名字：挂到最内层包住它的函数上。
@Test
func testCatchNodeIsAttributedToEnclosingFunction(): Unit {
    let nodes = ArrayList<AstNode>()
    nodes.add(AstNode("a.kt", 10, 40, "fn", "fun outer() {\n    try {\n        x()\n    } catch (e: Exception) {\n    }\n}"))
    nodes.add(AstNode("a.kt", 20, 30, "fn", "fun inner() {\n    try {\n    } catch (e: Exception) {\n    }\n}"))
    nodes.add(AstNode("a.kt", 25, 26, "catch", "catch (e: Exception) {\n    }"))
    nodes.add(AstNode("a.kt", 35, 36, "catch", "catch (e: Exception) {\n    }"))
    sortAstNodes(nodes)
    let names = enclosingFnNames(nodes)
    // 排序后：outer(10) inner(20) catch(25) catch(35)
    var innerName = ""
    var outerName = ""
    match (names.get(2)) {
        case Some(v) => innerName = v
        case None => ()
    }
    match (names.get(3)) {
        case Some(v) => outerName = v
        case None => ()
    }
    @Assert(innerName == "inner")
    @Assert(outerName == "outer")
}

// ── 圈复杂度：按词匹配 ──

/// `if(x)` / `for(` 要认，`re.match(` / 预处理行 / 注释里的不算。
@Test
func testComplexityMatchesWholeWords(): Unit {
    @Assert(cyclomaticComplexity(linesOf("    if(x) { return 1 }")) == 2)
    @Assert(cyclomaticComplexity(linesOf("    for(x in xs) { y() }")) == 2)
    @Assert(cyclomaticComplexity(linesOf("    verify(x)")) == 1)
    @Assert(cyclomaticComplexity(linesOf("    re.match(x)")) == 1)
    @Assert(cyclomaticComplexity(linesOf("    match (x) {")) == 2)
    @Assert(cyclomaticComplexity(linesOf("#if defined(A) && defined(B)")) == 1)
    @Assert(cyclomaticComplexity(linesOf("    // if (x) { y() }")) == 1)
    @Assert(cyclomaticComplexity(linesOf("    return a && b || c")) == 3)
}

// ── 参数：只数顶层逗号；Bool 只认类型位置 ──

@Test
func testParamsCountTopLevelOnlyAndBoolInTypePosition(): Unit {
    let a = analyzeSig("fun f(m: Map<String, List<Int>>, cb: (Int, String) -> Unit, d: Int = g(1, 2)): Boolean")
    @Assert(a.ok)
    @Assert(a.count == 3)
    @Assert(a.hasBool == false)
    let b = analyzeSig("fun update(project: String, deep: Boolean): UpdateReceipt")
    @Assert(b.count == 2)
    @Assert(b.hasBool)
    let c = analyzeSig("void setTransform(double a, double b, double c, double d, double e, double f)")
    @Assert(c.count == 6)
    @Assert(c.hasBool == false)
    let d = analyzeSig("bool isEnabled(bool enabled, int x)")
    @Assert(d.count == 2)
    @Assert(d.hasBool)
    let e = analyzeSig("fun f(flag: List<Boolean>, cb: (Bool) -> Unit)")
    @Assert(e.count == 2)
    @Assert(e.hasBool == false)
    let f = analyzeSig("def f(self, flag=False)")
    @Assert(f.count == 2)
    @Assert(f.hasBool)
    let g = analyzeSig("fun f()")
    @Assert(g.count == 0)
    let h = analyzeSig("fun f(name: Boolable)")
    @Assert(h.hasBool == false)
    let i = analyzeSig("fun f(a: Int")
    @Assert(i.ok == false)
}

// ── 不可达代码：层级 = 花括号深度 + 缩进 ──

/// 不带花括号的 `if (c)` / `return x;` 之后是下一个 `if`：不是不可达。
@Test
func testDeadBranchRespectsBraceDepthAndIndent(): Unit {
    let braceless = linesOf("func a(): Int64 {\n    if (m_busyAll)\n        return 0\n    return 1\n}")
    @Assert(hasDeadBranch(braceless, 1, false).isNone())
    let dead = linesOf("func b(): Int64 {\n    return 1\n    foo()\n}")
    @Assert(hasDeadBranch(dead, 1, false).isSome())
    @Assert(hasDeadBranch(dead, 1, false).getOrThrow() == 3)
    @Assert(hasDeadBranch(linesOf("    if (x) { throw X() }\n    return y"), 1, false).isNone())
    @Assert(hasDeadBranch(linesOf("    throw X(\n        \"a\",\n        \"b\")\n    return z"), 1, false).isNone())
    @Assert(hasDeadBranch(linesOf("    case 1 =>\n        return 1\n    case 2 =>\n        return 2"), 1, false).isNone())
    @Assert(hasDeadBranch(linesOf("    return QStringLiteral(\"x\")\n        .arg(y)\n    return z"), 1, false).isNone())
    @Assert(hasDeadBranch(linesOf("def f(x):\n    if x:\n        return 1\n    return 2"), 1, true).isNone())
    @Assert(hasDeadBranch(linesOf("def g(x):\n    return 1\n    print(x)"), 1, true).getOrThrow() == 3)
}

// ── 混合职责：既读又写 + 够分量的决策 ──

@Test
func testMixedResponsibilityNeedsReadWriteAndDecisions(): Unit {
    let read = linesOf("    let a = readFileText(p)\n    let b = readFileText(q)")
    let write = linesOf("    writeFileAtomic(p, a)\n    writeFileAtomic(q, b)")
    let both = linesOf("    let a = readFileText(p)\n    writeFileAtomic(p, a)")
    @Assert(hasMixedResponsibility(read, 10) == false)
    @Assert(hasMixedResponsibility(write, 10) == false)
    @Assert(hasMixedResponsibility(both, 4) == false)
    @Assert(hasMixedResponsibility(both, 5))
}

// ── 幻觉调用：本文件里认识的名字不报；`Type name(` 是声明 ──

/// 引擎仓 53 条抽样 6/6 是嵌套的局部函数；deepDolphin 152 条里没有一条查实是编造。
@Test
func testUnresolvedCallSkipsNamesTheFileAlreadyKnows(): Unit {
    let root = accRoot()
    ensureDir(root)
    try {
        writeFileAtomic("${root}/tools.py", """
from collections import Counter

def best(cands):
    def vkey(f):
        return len(f)
    return vkey(cands)

def run(items):
    helper = lambda x: x + 1
    for opener in (items,):
        opener("x")
    helper(1)
    return Counter(items)

def ghost(items):
    ghostCall(items)
""")
        writeFileAtomic("${root}/use.cpp", """
#include <cstdio>

QString currentName()
{
    QFile tar("/tmp/x");
    fflush(stdout);
    ghostCpp(tar);
    return "a";
}
""")
        writeFileAtomic("${root}/ui.kt", """
package p

import a.b.DisposableEffect

enum class Phase(val key: String) {
    LOCATING("a"),
    READY("b");

    fun label(): String = key
}

fun Layer1Card(l1: Int, onVerdict: (String) -> Unit, onRegenerate: (() -> Unit)?) {
    DisposableEffect(Unit) { }
    onVerdict("x")
    onRegenerate?.let { regenKt -> regenKt() }
    val phase = Phase.READY
    ghostKt(1, LOCATING("c"), phase.label())
}
""")
        writeFileAtomic("${root}/model.swift", """
enum ServiceError: Error {
    case badScene(String)
    case offline
}

func run() {
    ServiceError.badScene("x")
    ghostSwift()
}

func view(_ onRegenerate: (() -> Unit)?) {
    if let regenSwift = onRegenerate, !busy {
        regenSwift()
    }
}
""")
        // 仓颉枚举的构造器在 match 模式里长得像调用：`case BadScopeKt(msg) =>`
        writeFileAtomic("${root}/kind.cj", "package p\n\nenum Kind {\n    | WithText(String)\n    | Plain\n}\n\nfunc label(k: Kind): Int64 {\n    match (k) {\n        case WithText(msg) => msg.size\n        case Plain => 0\n    }\n}\n")
        let g = buildGraph(root)
        let rep = analyzeConfidence(g, false)
        @Assert(hasPick(rep.findings, UnresolvedCall, "WithText") == false)
        let names = picks(rep.findings, UnresolvedCall)
        @Assert(hasPick(rep.findings, UnresolvedCall, "vkey") == false)
        @Assert(hasPick(rep.findings, UnresolvedCall, "helper") == false)
        @Assert(hasPick(rep.findings, UnresolvedCall, "opener") == false)
        @Assert(hasPick(rep.findings, UnresolvedCall, "Counter") == false)
        @Assert(hasPick(rep.findings, UnresolvedCall, "tar") == false)
        @Assert(hasPick(rep.findings, UnresolvedCall, "DisposableEffect") == false)
        @Assert(hasPick(rep.findings, UnresolvedCall, "onVerdict") == false)
        // 枚举项带构造实参（`LOCATING("a")` / Swift 的 `case badScene(String)`）不是调用；
        // `if let regen = …` 绑定的局部变量不是幻觉
        @Assert(hasPick(rep.findings, UnresolvedCall, "LOCATING") == false)
        @Assert(hasPick(rep.findings, UnresolvedCall, "READY") == false)
        @Assert(hasPick(rep.findings, UnresolvedCall, "badScene") == false)
        // （两个名字各只出现在一个文件里：跨文件共用的名字在 build.cj 那一层就不进未解析清单）
        @Assert(hasPick(rep.findings, UnresolvedCall, "regenKt") == false)
        @Assert(hasPick(rep.findings, UnresolvedCall, "regenSwift") == false)
        // 真正全仓无定义的自由调用照报（库调用 fflush 也在——它确实是「全仓没有定义」，只是权重低）
        @Assert(hasPick(rep.findings, UnresolvedCall, "ghostCall"))
        @Assert(hasPick(rep.findings, UnresolvedCall, "ghostCpp"))
        @Assert(hasPick(rep.findings, UnresolvedCall, "ghostKt"))
        @Assert(hasPick(rep.findings, UnresolvedCall, "ghostSwift"))
        @Assert(hasPick(rep.findings, UnresolvedCall, "fflush"))
        @Assert(names.size == 5)
    } finally {
        removePathIfExists(root)
    }
}

/// `Type name(…)` 是对象的构造声明，不是调用——探针工程 20 条「幻觉调用」里 3 条是它。
@Test
func testCalleePrecededByTypeIsADeclaration(): Unit {
    @Assert(calleeIsDeclaredName("    const QJsonDocument paramsDoc(QJsonObject { { \"a\", 1 } });", "paramsDoc"))
    @Assert(calleeIsDeclaredName("    static const QRegularExpression kIfaceName(\"x\");", "kIfaceName"))
    @Assert(calleeIsDeclaredName("    const QVector<Milestone> allItems(b, e);", "allItems"))
    @Assert(calleeIsDeclaredName("    QFile tar(tarPath);", "tar"))
    @Assert(calleeIsDeclaredName("    def best(cands):", "best"))
    @Assert(calleeIsDeclaredName("    fun Layer1Card(l1: Int) {", "Layer1Card"))
    @Assert(calleeIsDeclaredName("    fflush(stdout);", "fflush") == false)
    @Assert(calleeIsDeclaredName("    return foo(x);", "foo") == false)
    @Assert(calleeIsDeclaredName("    auto x = Foo(y);", "Foo") == false)
    @Assert(calleeIsDeclaredName("    if (a > foo(x)) {", "foo") == false)
    @Assert(calleeIsDeclaredName("    await foo(x);", "foo") == false)
    @Assert(calleeIsDeclaredName("    bar(foo(x));", "foo") == false)
}

/// 未解析的裸调用按「提示去核对」的强度定权：实测精度接近 0，不再与查实的事实同级。
@Test
func testUnresolvedCallIsAHintNotAConviction(): Unit {
    @Assert(flawWeight(UnresolvedCall) == 3)
    @Assert(flawWeight(UnresolvedCall) < flawWeight(DuplicateBody))
    @Assert(flawWeight(UnresolvedCall) < flawWeight(HighComplexity))
}

// ── 孤儿：框架入口 / 运算符 / 双下划线 / 非限定枚举不报 ──

/// deepDolphin 列出的 114 条 orphan 里约 30 条是 Qt 的 override / 槽 / 信号、运算符重载、
/// Python 的 __getitem__；`emit x(` 还被扫描器编成一个假符号。
@Test
func testOrphanSkipsFrameworkEntries(): Unit {
    let root = accRoot()
    ensureDir(root)
    try {
        writeFileAtomic("${root}/panel.h", """
class Panel : public QWidget {
public:
    void paintEvent(QPaintEvent *e) override;
public slots:
    void onTimeout();
signals:
    void changed(int n);
};
""")
        writeFileAtomic("${root}/panel.cpp", """
void Panel::paintEvent(QPaintEvent *e) { }
void Panel::onTimeout() { }
int orphanFree(const QJsonObject &o) { return 0; }
""")
        writeFileAtomic("${root}/model.py", """
class Box:
    def __getitem__(self, k):
        return k

def orphanPy():
    return 1
""")
        writeFileAtomic("${root}/scope.cpp", """
enum Reason { none, noData, noMatch } reason = none;

void reset() { reason = none; }

void unusedFree() { }
""")
        writeFileAtomic("${root}/delegate.swift", """
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { }
    func applicationWillTerminate(_ notification: Notification) { }
}
""")
        let g = buildGraph(root)
        let fs = ArrayList<Finding>()
        detectOrphans(g, fs, CapDropCounter())
        @Assert(hasPick(fs, Orphan, "applicationDidFinishLaunching") == false)
        @Assert(hasPick(fs, Orphan, "applicationWillTerminate") == false)
        @Assert(hasPick(fs, Orphan, "paintEvent") == false)
        @Assert(hasPick(fs, Orphan, "onTimeout") == false)
        @Assert(hasPick(fs, Orphan, "changed") == false)
        @Assert(hasPick(fs, Orphan, "__getitem__") == false)
        @Assert(hasPick(fs, Orphan, "Reason") == false)
        // 真孤儿照报
        @Assert(hasPick(fs, Orphan, "orphanFree"))
        @Assert(hasPick(fs, Orphan, "orphanPy"))
        @Assert(hasPick(fs, Orphan, "unusedFree"))
    } finally {
        removePathIfExists(root)
    }
}

/// Qt 的 `emit changed(1);` 是信号发射，扫描器不许把它编成一个叫 changed 的函数。
/// 触发条件（deepDolphin SidebarNav.cpp:88 实测、逐段裁到最小）：类定义在别处（本文件只有空的
/// `class X {};` 或根本不在）时，带初始化列表的构造函数 `X::X(…) : Base(…) {` 的函数头之后
/// 仍被当普通代码扫——于是对函数体里的 `emit x(` 这一行试「带返回类型的函数声明」，把 emit 当成返回类型。
@Test
func testEmitLineIsNotASymbol(): Unit {
    let root = accRoot()
    ensureDir(root)
    try {
        writeFileAtomic("${root}/SidebarNav.cpp", """
class SidebarNav {};

SidebarNav::SidebarNav(QWidget *parent)
    : QWidget(parent)
{
    m_search = new DSearchEdit(this);
    connect(m_search, &DLineEdit::textChanged, this, [this](const QString &t) {
        m_query = t;
        emit searchQueryChanged(t);
    });
    Q_EMIT gone(2);
}

void tail() { }
""")
        let g = buildGraph(root)
        var sawTail = false
        for (f in g.files) {
            for (s in f.symbols) {
                @Assert(s.name != "searchQueryChanged")
                @Assert(s.name != "gone")
                @Assert(s.name != "emit")
                if (s.name == "tail") { sawTail = true }
            }
        }
        // 前提守卫：扫描器确实读了这个文件（别让「0 个符号」冒充通过）
        @Assert(sawTail)
    } finally {
        removePathIfExists(root)
    }
}

/// 测试目录里的辅助符号没有调用点是正常的（文件名里未必有 test）。
@Test
func testTestPathIsEntryLike(): Unit {
    @Assert(isTestPath("client/src/jvmTest/kotlin/canopy/ui/SkinContrastAudit.kt"))
    @Assert(isTestPath("a/Tests/Foo.swift"))
    @Assert(isTestPath("a/__tests__/x.ts"))
    @Assert(isTestPath("src/ui/a.kt") == false)
    @Assert(isTestPath("deepin/src/latest/x.cpp") == false)
}

/// 文件名豁免按词判：`spec` / `test` / `demo` 作为子串会命中 inspector、specification、latest。
@Test
func testEntryFileExemptionMatchesWholeWords(): Unit {
    @Assert(isEntryLike("inspector.swift") == false)
    @Assert(isEntryLike("specification.go") == false)
    @Assert(isEntryLike("latest.ts") == false)
    @Assert(isEntryLike("index_store.cj") == false)
    @Assert(isEntryLike("FooTests.swift"))
    @Assert(isEntryLike("test_foo.py"))
    @Assert(isEntryLike("foo_test.go"))
    @Assert(isEntryLike("FooSpec.ts"))
    @Assert(isEntryLike("DemoPanel.swift"))
    @Assert(isEntryLike("main.cj"))
    @Assert(isEntryLike("mod.rs"))
    @Assert(isEntryLike("lib.cj"))
}

/// AST 路径的魔法数不吃字符串里的数字（与词法路径同一口径；12 在豁免表里，所以夹具用 13 / 14 / 15）。
@Test
func testMagicNumbersIgnoreStringContents(): Unit {
    @Assert(countMagicNumbers("fun hex(c: Color): String = String.format(\"#%02x%02x%02x\", c.r, c.g, c.b)") == 0)
    @Assert(countMagicNumbers("fun f(): Int {\n    // 42 43 44\n    return g(13, 14, 15)\n}") == 3)
}

/// 持锁区间里的 `if(x)` / `while(x)` 不是外部调用。
@Test
func testLockCallsIgnoreControlKeywords(): Unit {
    let n = AstNode("g.cj", 1, 7, "fn", "func guarded() {\n    mu.lock()\n    if(x) { known(3) }\n    while(y) { other(4) }\n    mu.unlock()\n}\n")
    let findings = ArrayList<Finding>()
    checkLockCalls(n, 2, 5, findings, HashMap<String, Int64>(), CapDropCounter())
    let hits = picks(findings, LockUnknownCall)
    @Assert(hits.size == 2)
    @Assert(hits[0] == "known:3")
    @Assert(hits[1] == "other:4")
}

// ── 锁：同一行取锁 + defer 释放是平的；行号要对；RAII 语言不判 ──

/// deepDolphin 的 Swift 端 6 条 lock-imbalance 全是 `lock.lock(); defer { lock.unlock() }`。
@Test
func testLockDeferOnSameLineIsBalanced(): Unit {
    let g = emptyGraph()
    let nodes = ArrayList<AstNode>()
    nodes.add(AstNode("a.swift", 100, 104, "fn",
        "func refreshBinary() {\n    pathLock.lock(); defer { pathLock.unlock() }\n    _p = c.first { $0.isEmpty }\n}"))
    nodes.add(AstNode("b.swift", 200, 204, "fn", "func leak() {\n    lock.lock()\n    work()\n}"))
    nodes.add(AstNode("c.rs", 300, 303, "fn", "fn raii() {\n    let g = m.lock().unwrap();\n    work();\n}"))
    nodes.add(AstNode("d.kt", 400, 404, "fn", "fun commented() {\n    // mu.lock()\n    work()\n}"))
    nodes.add(AstNode("e.kt", 500, 504, "fn", "fun region() {\n    mu.lock()\n    work()\n    mu.unlock()\n}"))
    let findings = ArrayList<Finding>()
    detectConcurrencyRisks(g, nodes, true, findings, CapDropCounter())
    let imbalances = picks(findings, LockImbalance)
    @Assert(imbalances.size == 1)
    @Assert(imbalances[0] == "leak:201")
    // 持锁区间内的外部调用照报（既有口径不动）：只有 region 的第 502 行
    let held = picks(findings, LockUnknownCall)
    @Assert(held.size == 1)
    @Assert(held[0] == "work:502")
}

// ── 指针：只有证得是局部变量才报 ──

/// `return &p`：range-for 的引用、函数内 static、参数都不是栈地址。
@Test
func testStackAddressIsReportedOnlyForProvenLocals(): Unit {
    let root = accRoot()
    ensureDir(root)
    try {
        // 一个文件只取第一处 `return &`：四种形态各放一个文件
        writeFileAtomic("${root}/dangling.cpp", """
int *dangling()
{
    int x = 1;
    return &x;
}
""")
        writeFileAtomic("${root}/loop.cpp", """
const Value *byValue(const std::vector<Value> &xs)
{
    for (Value v : xs)
        return &v;
    return nullptr;
}
""")
        writeFileAtomic("${root}/ref.cpp", """
const Value *byRef(const std::vector<Value> &xs)
{
    for (const Value &v : xs)
        return &v;
    return nullptr;
}
""")
        writeFileAtomic("${root}/instance.cpp", """
State *instance()
{
    static State inst;
    return &inst;
}
""")
        let rep = analyzeConfidence(buildGraph(root), false)
        let hits = picks(rep.findings, PointerRisk)
        // dangling 的 `return &x`（局部变量）与 byValue 的 `return &v`（按值的循环变量，函数返回后悬垂）；
        // range-for 的引用 v、函数内 static inst 不报
        @Assert(hits.size == 2)
        @Assert(hits[0] == ":4")
        @Assert(hits[1] == ":4")
    } finally {
        removePathIfExists(root)
    }
}

// ── 注释掉的代码：行号 ──

/// 原实现 lineNo 从不递增，首行恒报第 0 行。
@Test
func testCommentedCodeReportsTheRealLine(): Unit {
    let root = accRoot()
    ensureDir(root)
    try {
        writeFileAtomic("${root}/notes.c", """
int a = 1;

// let x = f(1);
// return x;
// if (x) { y(); }
int b = 2;
""")
        let rep = analyzeConfidence(buildGraph(root), false)
        let hits = picks(rep.findings, CommentedCode)
        @Assert(hits.size == 1)
        @Assert(hits[0] == ":3")
    } finally {
        removePathIfExists(root)
    }
}

// ── 语义层：函数体 = 索引记录的范围 ──

/// 无体声明（接口方法）的「体」原先一路延伸到下一个符号：接口方法被报成高复杂度。
@Test
func testSemanticBodyIsTheIndexedFunctionOnly(): Unit {
    let root = accRoot()
    ensureDir(root)
    try {
        writeFileAtomic("${root}/shape.cj", """
package p

interface Shape {
    func area(): Float64
}

func busy(): Int64 {
    if (a) { return 1 }
    if (a) { return 1 }
    if (a) { return 1 }
    if (a) { return 1 }
    if (a) { return 1 }
    if (a) { return 1 }
    if (a) { return 1 }
    if (a) { return 1 }
    if (a) { return 1 }
    if (a) { return 1 }
    if (a) { return 1 }
    return 0
}

func small(): Int64 { return 1 }
""")
        // 文件里最后一个函数之后还有不带符号的代码（Kotlin 的 init 块）：
        // 原实现把这个函数的「体」一路延伸到文件末尾
        writeFileAtomic("${root}/tail.kt", """
package p

class Tail {
    fun small(): Int { return 1 }

    init {
        if (a) { x() }
        if (a) { x() }
        if (a) { x() }
        if (a) { x() }
        if (a) { x() }
        if (a) { x() }
        if (a) { x() }
        if (a) { x() }
        if (a) { x() }
        if (a) { x() }
        if (a) { x() }
        y()
    }
}
""")
        let rep = analyzeConfidence(buildGraph(root), false)
        let hi = picks(rep.findings, HighComplexity)
        @Assert(hi.size == 1)
        @Assert(hi[0] == "busy:7")
        // 无体声明不参与任何函数体语义检测
        @Assert(hasPick(rep.findings, ParameterAbuse, "area") == false)
        @Assert(hasPick(rep.findings, MixedResponsibility, "area") == false)
        @Assert(hasPick(rep.findings, DeadBranch, "area") == false)
    } finally {
        removePathIfExists(root)
    }
}

/// 近重复：两行的函数天然相同，不是复制粘贴。
@Test
func testNearDuplicateIgnoresTrivialBodies(): Unit {
    let root = accRoot()
    ensureDir(root)
    try {
        writeFileAtomic("${root}/dup.cj", """
package p

func tinyA(): Int64 {
    let x = 1
    return x
}

func tinyB(): Int64 {
    let x = 1
    return x
}

func bigA(a: Int64, b: Int64, c: Int64, d: Int64): Int64 {
    let s = a + b + c + d
    let t = s * 2 + 1
    let u = t * 3 + 2
    let v = u * 4 + 3
    let w = v * 5 + 4
    let x = w * 6 + 5
    let y = x * 7 + 6
    let z = y * 8 + 7
    return z - 1
}

func bigB(a: Int64, b: Int64, c: Int64, d: Int64): Int64 {
    let s = a + b + c + d
    let t = s * 2 + 1
    let u = t * 3 + 2
    let v = u * 4 + 3
    let w = v * 5 + 4
    let x = w * 6 + 5
    let y = x * 7 + 6
    let z = y * 8 + 7
    return z - 1
}
""")
        let rep = analyzeConfidence(buildGraph(root), false)
        @Assert(hasPick(rep.findings, NearDuplicate, "tinyB") == false)
        @Assert(hasPick(rep.findings, NearDuplicate, "bigB"))
    } finally {
        removePathIfExists(root)
    }
}

/// 框架规定的签名（override / 运算符）不报「API 设计缺失」。
@Test
func testParameterAbuseSkipsFrameworkSignatures(): Unit {
    let root = accRoot()
    ensureDir(root)
    try {
        writeFileAtomic("${root}/canvas.h", """
class CanvasSink {
public:
    virtual void setTransform(double a, double b, double c, double d, double e, double f);
    bool operator==(const CanvasSink &o) const;
};
""")
        writeFileAtomic("${root}/canvas.cpp", """
void CanvasSink::setTransform(double a, double b, double c, double d, double e, double f) { }

int wide(int a, int b, int c, int d, int e, int f) { return a; }
""")
        let rep = analyzeConfidence(buildGraph(root), false)
        @Assert(hasPick(rep.findings, ParameterAbuse, "setTransform") == false)
        @Assert(hasPick(rep.findings, ParameterAbuse, "operator==") == false)
        @Assert(hasPick(rep.findings, ParameterAbuse, "wide"))
    } finally {
        removePathIfExists(root)
    }
}

/// Compose 的快照状态不是「无同步的共享状态」。
@Test
func testGlobalMutableIgnoresComposeSnapshotState(): Unit {
    let root = accRoot()
    ensureDir(root)
    try {
        writeFileAtomic("${root}/state.kt", """
package p

var composition12 by mutableStateOf(Composition12())

var plainCount: Int = 0
""")
        let rep = analyzeConfidence(buildGraph(root), false)
        let hits = picks(rep.findings, GlobalMutable)
        @Assert(hits.size == 1)
        @Assert(hits[0] == ":5")
    } finally {
        removePathIfExists(root)
    }
}

// ── 语法树节点：签名必须像签名 ──

/// tree-sitter 的错误恢复把「缺分号的宏 + namespace + 函数」揉成一个 function_definition。
@Test
func testImplausibleSignatureNodesAreDropped(): Unit {
    @Assert(plausibleSignature("DCORE_USE_NAMESPACE\n\nnamespace {\nconstexpr char k[] = \"x\";\nconst S *schema()\n{\n}") == false)
    @Assert(plausibleSignature("const SecretSchema *schema()\n{") )
    @Assert(plausibleSignature("AnthropicEngine::AnthropicEngine(const QString &u, const QString &k,\n    const QString &m)\n    : m_baseURL(u.trimmed())\n{"))
    @Assert(plausibleSignature("fun f(x: Int) = x"))
    @Assert(plausibleSignature("    init {"))
    AST_DROPPED_NODES = 0
    parseAstGrepJson("[{\"ruleId\":\"fn\",\"file\":\"a.cpp\",\"text\":\"MACRO\\nnamespace {\\nvoid f()\\n{\\n}\",\"range\":{\"start\":{\"line\":7,\"column\":0},\"end\":{\"line\":11,\"column\":1}}}," +
        "{\"ruleId\":\"fn\",\"file\":\"b.cpp\",\"text\":\"void g()\\n{\\n}\",\"range\":{\"start\":{\"line\":2,\"column\":0},\"end\":{\"line\":4,\"column\":1}}}]", ArrayList<AstNode>())
    @Assert(AST_DROPPED_NODES == 1)
}

/// C++ 带初始化列表、体为空的构造函数在做数据初始化，不是占位。
@Test
func testInitializingConstructorIsNotAStub(): Unit {
    let n = AstNode("w.cpp", 20, 23, "fn", "Widget::Widget(const QString &p) : m_p(p)\n{\n}")
    @Assert(stubReason(n).isNone())
    let plain = AstNode("w.cpp", 20, 23, "fn", "Widget::Widget()\n{\n}")
    @Assert(stubReason(plain).isSome())
    @Assert(stubReason(plain).getOrThrow() == "函数体为空")
}

// ── 抽样补出来的几处 ──

/// 深嵌套只数控制语句：声明式布局容器、lambda、字面量的花括号不计；类型节点不报。
/// 原实现数所有花括号：SwiftUI 的视图结构体嵌 10 层、3 行的 range-for 被报「嵌套 8 层」。
@Test
func testDeepNestingCountsOnlyControlFlow(): Unit {
    @Assert(maxControlNesting(linesOf("Column {\n    Row {\n        Box {\n            Text(\"a\")\n        }\n    }\n}")) == 0)
    @Assert(maxControlNesting(linesOf("if (a) { for (x in xs) { while (c) { if (b) { try { if (d) { x() } } } } } }")) == 6)
    @Assert(maxControlNesting(linesOf("if (a &&\n    b) {\n    x()\n}")) == 1)
    @Assert(maxControlNesting(linesOf("if (f(x))\n{\n    x()\n}")) == 1)
    // 不带花括号的单语句写完之后，下一行的 `{` 是 lambda 的，不算
    @Assert(maxControlNesting(linesOf("if (x) foo()\nval g = { y: Int -> y }")) == 0)
    let nodes = ArrayList<AstNode>()
    nodes.add(AstNode("v.swift", 1, 30, "type",
        "struct V: View {\n    var body: some View {\n        VStack {\n            HStack {\n                VStack {\n                    HStack {\n                        Text(\"x\")\n                    }\n                }\n            }\n        }\n    }\n}"))
    nodes.add(AstNode("a.kt", 1, 20, "fn",
        "fun f(xs: List<Int>) {\n    Column {\n        Row {\n            Box {\n                for (x in xs) {\n                    if (x > 0) {\n                        while (x < 9) {\n                            try {\n                                if (x == 1) {\n                                    if (x == 2) {\n                                        g()\n                                    }\n                                }\n                            }\n                        }\n                    }\n                }\n            }\n        }\n    }\n}"))
    let findings = ArrayList<Finding>()
    detectFromAst(nodes, findings, CapDropCounter())
    let hits = picks(findings, DeepNesting)
    @Assert(hits.size == 1)
    @Assert(hits[0] == "f:1")
}

/// 讲代码的注释（含中文 / 全角标点）不是注释掉的代码；多行字符串里的行（内嵌的 HTML / CSS）不是注释。
/// ⚠️ 夹具里的注释前缀用拼接（`"/" + "/"`）：检测器读的是原始行，测试源码里整行以 `//` 开头的
/// 夹具数据会被它扫到（不变量 55 / 147：needle 字面量在源码里 ⇒ 匹配到自己）。
@Test
func testCommentedCodeIgnoresProseAboutCode(): Unit {
    let root = accRoot()
    ensureDir(root)
    let c = "/" + "/"
    try {
        writeFileAtomic("${root}/prose.c", "int a = 1;\n" +
            "${c} unreadable = Some(0)（空数组也是恒发）不是披露理由\n" +
            "${c} 一个已知缺陷的原样：AgentCore.run 每次都 `var convo = [ChatMessage.user(question)]`\n" +
            "${c} scale = min((800-2*40)/200, (600-2*40)/100) = min(3.6, 5.2) —— 取小\n" +
            "int b = 2;\n")
        writeFileAtomic("${root}/real.c", "int a = 1;\n" +
            "${c} let x = f(1);\n" +
            "${c} return x;\n" +
            "${c} if (x) { y(); }\n" +
            "int b = 2;\n")
        // 多行字符串里内嵌的样式表：以 # 开头、以 ; 结尾，两条「像代码」的规则都中——不是注释
        writeFileAtomic("${root}/page.cj", "package p\n\nlet js = \"\"\"\n${c} init(1);\n${c} init(2);\n${c} init(3);\n#bar { position:fixed; }\n\"\"\"\n\nfunc render(): String { return js }\n")
        // `#` 注释不以分号收尾（Python / shell）：以 ; 结尾这一条只对 `//` 注释成立
        writeFileAtomic("${root}/hash.c", "int a = 1;\n# bar(1);\n# baz(2);\n# qux(3);\nint b = 2;\n")
        let rep = analyzeConfidence(buildGraph(root), false)
        let hits = picks(rep.findings, CommentedCode)
        @Assert(hits.size == 1)
        @Assert(hits[0] == ":2")
    } finally {
        removePathIfExists(root)
    }
}

/// 近重复与重复体是同一件事：语法树可用时由 duplicate-body 报，不罚两次。
@Test
func testNearDuplicateYieldsToDuplicateBodyWhenAstIsAvailable(): Unit {
    let root = accRoot()
    ensureDir(root)
    try {
        writeFileAtomic("${root}/dup.cj", """
package p

func bigA(a: Int64, b: Int64, c: Int64, d: Int64): Int64 {
    let s = a + b + c + d
    let t = s * 2 + 1
    let u = t * 3 + 2
    let v = u * 4 + 3
    let w = v * 5 + 4
    let x = w * 6 + 5
    let y = x * 7 + 6
    let z = y * 8 + 7
    return z - 1
}

func bigB(a: Int64, b: Int64, c: Int64, d: Int64): Int64 {
    let s = a + b + c + d
    let t = s * 2 + 1
    let u = t * 3 + 2
    let v = u * 4 + 3
    let w = v * 5 + 4
    let x = w * 6 + 5
    let y = x * 7 + 6
    let z = y * 8 + 7
    return z - 1
}
""")
        let g = buildGraph(root)
        let lexical = ArrayList<Finding>()
        detectSemanticIssues(g, lexical, CapDropCounter(), nearDup: true)
        @Assert(hasPick(lexical, NearDuplicate, "bigB"))
        let withAst = ArrayList<Finding>()
        detectSemanticIssues(g, withAst, CapDropCounter(), nearDup: false)
        @Assert(hasPick(withAst, NearDuplicate, "bigB") == false)
    } finally {
        removePathIfExists(root)
    }
}

/// 节点文本以文档注释 / 注解行开头时，名字仍要取到声明行。
@Test
func testNodeNameSkipsLeadingCommentAndAnnotationLines(): Unit {
    @Assert(nodeName(AstNode("a.kt", 1, 3, "fn",
        "/** 窗口最底层的材质装饰。 */\n@Stable\nfun SkinBackdrop(modifier: Modifier = Modifier) {\n}")) == "SkinBackdrop")
    @Assert(nodeName(AstNode("m.swift", 1, 3, "type", "@MainActor\nfinal class Model: ObservableObject {\n}")) == "Model")
    @Assert(nodeName(AstNode("a.kt", 1, 3, "type",
        "object QuickViewTrigger {\n    val open = kotlinx.coroutines.flow.MutableStateFlow(false)\n}")) == "QuickViewTrigger")
}

/// Kotlin 的 object 体里第一个括号是成员初始化：类型节点取体不跳参数表。
@Test
func testTypeWithInitializedMemberIsNotEmpty(): Unit {
    let nodes = ArrayList<AstNode>()
    nodes.add(AstNode("a.kt", 90, 92, "type",
        "object QuickViewTrigger {\n    val open = kotlinx.coroutines.flow.MutableStateFlow(false)\n}"))
    nodes.add(AstNode("hollow.cj", 7, 7, "type", "class Hollow {}"))
    let findings = ArrayList<Finding>()
    detectTypeSignals(nodes, findings)
    let hits = picks(findings, EmptyType)
    @Assert(hits.size == 1)
    @Assert(hits[0] == "Hollow:7")
}

/// 函数类型的参数（`() -> Boolean`）不是 Bool 标志参数。
@Test
func testFunctionTypedParameterIsNotABoolFlag(): Unit {
    let pi = analyzeSig("fun runShortcut(action: Action, focusSearch: () -> Boolean = { false })")
    @Assert(pi.count == 2)
    @Assert(pi.hasBool == false)
    let pj = analyzeSig("fun f(cb: (Int) => Bool, flag: Boolean)")
    @Assert(pj.hasBool)
}
