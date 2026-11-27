// graph/members_test.cj — 成员级索引的判据：提取深度 / 调用点解析 / SQLite v2 读路径 / grep。
//
// 【与 graph_test.cj 的分工】那边钉的是旧词法图谱的行为（假符号防线、引用边、
// 置信度、渲染）；这里钉的是「agent 能不能可靠地定位代码」这件事本身：
//   · 符号带 owner/qual/行范围/列/签名/可见性/是否只有声明；
//   · 调用点是解析过的（direct / resolved / guessed / 未解析），带 file:line:col；
//   · 五个查询出口的 JSON 键集恒定。
// 每条判据都配过负控（注入 → 红 → 还原），见提交说明。
package cambium.graph

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.util.*

func symsNamed(f: SourceFacts, name: String): ArrayList<SymDecl> {
    let out = ArrayList<SymDecl>()
    for (s in f.symbols) {
        if (s.name == name) { out.add(s) }
    }
    return out
}

func symOf(f: SourceFacts, qual: String): Option<SymDecl> {
    for (s in f.symbols) {
        if (s.qual == qual && !s.declOnly) { return Some(s) }
    }
    for (s in f.symbols) {
        if (s.qual == qual) { return Some(s) }
    }
    return None<SymDecl>
}

/// 边的 tier（按两端的稳定 id 找；找不到 = "<no edge>"）。
/// id 是 `f:<file>:<line>:<name>`——按**名字**而不是限定名：同文件同名的方法
/// （App.helper / Other.helper）靠行号区分。
func edgeTierOf(edges: ArrayList<CallEdge>, fromId: String, toId: String): String {
    for (e in edges) {
        if (e.from == fromId && e.to == toId) { return e.tier }
    }
    return "<no edge>"
}

func hasEdge(edges: ArrayList<CallEdge>, fromId: String, toId: String): Bool {
    return edgeTierOf(edges, fromId, toId) != "<no edge>"
}

// MARK: - 提取深度

/// Kotlin：`fun` 进索引（修前 DECL_TABLES 里根本没有 fun ⇒ Kotlin 全仓 0 个函数），
/// 类体成员带 owner/qual，companion object 对属主透明，扩展函数的 owner 是接收者类型。
@Test
func testKotlinFunIsIndexedWithOwner(): Unit {
    let src = """
package demo

internal fun decodeOutcomes(r: MultiResults): List<UpdateOutcome> = r.results.map(::decode)

class AppModel(private val engineBin: String) {
    companion object {
        fun fromConf(text: String): AutoUpdateSettings {
            return AutoUpdateSettings()
        }
    }

    fun renderArtifact(project: String, kind: String) {
        val text = render(kind, project)
    }

    private suspend fun <T> withAction(
        label: String,
        block: suspend () -> T,
    ): T? {
        return block()
    }
}

fun String.blankish(): Boolean {
    return this.isEmpty()
}

sealed interface LoadState {
    data object Loading : LoadState
    data class Failed(val reason: String) : LoadState
}
"""
    let f = scanSource(src, "kotlin")
    // 顶层函数
    match (symOf(f, "decodeOutcomes")) {
        case Some(s) =>
            @Assert(symKindId(s.kind) == "func")
            @Assert(s.owner.isEmpty())
            @Assert(s.endLine == 3)
        case None => @Assert(false)
    }
    // 类体成员：owner / qual / 行范围 / 列 / 签名
    match (symOf(f, "AppModel.renderArtifact")) {
        case Some(s) =>
            @Assert(s.owner == "AppModel")
            @Assert(s.qual == "AppModel.renderArtifact")
            @Assert(s.line == 12)
            @Assert(s.endLine == 14)                       // 闭括号行
            @Assert(s.col == 9)                            // 4 空格 + "fun "
            @Assert(s.sig == "fun renderArtifact(project: String, kind: String)")
            @Assert(!s.declOnly)
        case None => @Assert(false)
    }
    // companion object 不是属主：成员仍属于外层类
    match (symOf(f, "AppModel.fromConf")) {
        case Some(s) =>
            @Assert(s.owner == "AppModel")
            @Assert(s.endLine == 9)
        case None => @Assert(false)
    }
    // 泛型 + 跨行参数表 + 可见性
    match (symOf(f, "AppModel.withAction")) {
        case Some(s) =>
            @Assert(s.owner == "AppModel")
            @Assert(s.visibility == "private")
            @Assert(s.endLine == 21)
            @Assert(s.sig == "private suspend fun <T> withAction( label: String, block: suspend () -> T, ): T?")
        case None => @Assert(false)
    }
    // 扩展函数：owner 是接收者类型
    match (symOf(f, "String.blankish")) {
        case Some(s) => @Assert(s.owner == "String")
        case None => @Assert(false)
    }
    match (symOf(f, "decodeOutcomes")) {
        case Some(s) => @Assert(s.visibility == "internal")
        case None => ()
    }
    // 没有体的类型声明（命名对象 / 主构造器写完即止）也是完整符号
    match (symOf(f, "LoadState.Loading")) {
        case Some(s) =>
            @Assert(s.owner == "LoadState")
            @Assert(s.endLine == s.line)
            @Assert(!s.declOnly)
        case None => @Assert(false)
    }
    match (symOf(f, "LoadState.Failed")) {
        case Some(s) => @Assert(s.owner == "LoadState")
        case None => @Assert(false)
    }
    // 属性 / 参数 / 局部变量不是符号
    for (bad in ["engineBin", "label", "block", "text", "reason"]) {
        @Assert(symsNamed(f, bad).size == 0)
    }
}

/// owner / qual 跨语言：Swift / C++ / Go / Rust / Python / Java / TS / Cangjie。
@Test
func testMemberOwnerAndQualAcrossLanguages(): Unit {
    // Swift：enum 里的 static func
    let swift = scanSource("""
enum ShortcutMap {
    static func view(at index: Int) -> ShortcutTarget? {
        return nil
    }
}
extension Int {
    func twice() -> Int { return 2 }
}
""", "swift")
    match (symOf(swift, "ShortcutMap.view")) {
        case Some(s) =>
            @Assert(s.owner == "ShortcutMap")
            @Assert(s.sig == "static func view(at index: Int) -> ShortcutTarget?")
            @Assert(s.endLine == 4)
            @Assert(s.col == 17)
        case None => @Assert(false)
    }
    match (symOf(swift, "Int.twice")) {
        case Some(s) => @Assert(s.owner == "Int")
        case None => @Assert(false)
    }
    // 扩展体本身是顶层声明：qual 就是类型名，不是 `Int.Int`
    match (symOf(swift, "Int")) {
        case Some(s) => @Assert(symKindId(s.kind) == "extension")
        case None => @Assert(false)
    }
    for (s in swift.symbols) { @Assert(s.qual != "Int.Int") }

    // C++：类体内的内联方法 / 原型 / 访问段，以及类外的限定名定义
    let cpp = scanSource("""
class AppModel {
public:
    void start();
    void stop() { m_timer.stop(); }
private:
    bool engineFound() const { return m_engineFound; }
};

void AppModel::start()
{
    m_cli->callJson("status", 1);
}
""", "c")
    match (symOf(cpp, "AppModel.stop")) {
        case Some(s) =>
            @Assert(s.owner == "AppModel")
            @Assert(s.visibility == "public")
            @Assert(s.endLine == 4)
        case None => @Assert(false)
    }
    match (symOf(cpp, "AppModel.engineFound")) {
        case Some(s) => @Assert(s.visibility == "private")
        case None => @Assert(false)
    }
    // 原型：只有声明
    let starts = symsNamed(cpp, "start")
    @Assert(starts.size == 2)                   // 原型 + 定义，同一文件
    @Assert(starts[0].declOnly)
    @Assert(starts[0].line == 3)
    @Assert(starts[0].sig == "void start()")
    @Assert(!starts[1].declOnly)
    @Assert(starts[1].owner == "AppModel")
    @Assert(starts[1].endLine == 12)            // Allman：闭括号行
    @Assert(starts[1].col == 16)                // "void AppModel::".size + 1
    @Assert(starts[1].sig == "void AppModel::start()")
    // 构造函数 / 析构函数不入表，它们的声明行也不是调用点
    let ctor = scanSource("""
class AppModel {
public:
    explicit AppModel(QObject *parent = nullptr);
    AppModel(const AppModel &o) { x = 1; }
    ~AppModel();
};

AppModel::AppModel(QObject *parent)
    : QObject(parent)
{
}

AppModel::~AppModel()
{
}
""", "c")
    for (s in ctor.symbols) {
        @Assert(s.name != "AppModel" || symKindId(s.kind) == "class")
        @Assert(s.name != "QObject")
    }
    for (r in ctor.refs) {
        @Assert(r.name != "AppModel")
    }

    // Go：接收者方法，owner 是接收者类型（剥掉 * 与包限定）
    let go = scanSource("""
package main

type Rect struct {
	w float64
}

func (r *Rect) Area() float64 {
	return r.w
}

func (q *pkg.Rect) Perimeter() float64 {
	return 2
}
""", "go")
    match (symOf(go, "Rect.Area")) {
        case Some(s) =>
            @Assert(s.owner == "Rect")
            @Assert(s.visibility == "public")  // Go：首字母大写即导出
            @Assert(s.sig == "func (r *Rect) Area() float64")
        case None => @Assert(false)
    }
    match (symOf(go, "Rect.Perimeter")) {
        case Some(s) => @Assert(s.owner == "Rect")
        case None => @Assert(false)
    }

    // Rust：impl Trait for Type 的 owner 是 Type；trait 里没有体的方法是 declOnly
    let rust = scanSource("""
pub trait Shape {
    fn area(&self) -> f64;
    fn name(&self) -> String { String::new() }
}

pub struct Circle { r: f64 }

impl Shape for Circle {
    fn area(&self) -> f64 { 3.14 * self.r * self.r }
}

impl Circle {
    pub fn new(r: f64) -> Circle { Circle { r } }
}
""", "rust")
    match (symOf(rust, "Circle.area")) {
        case Some(s) =>
            @Assert(s.owner == "Circle")
            @Assert(!s.declOnly)
        case None => @Assert(false)
    }
    match (symOf(rust, "Shape.name")) {
        case Some(s) => @Assert(s.owner == "Shape")
        case None => @Assert(false)
    }
    match (symOf(rust, "Shape.area")) {
        case Some(s) => @Assert(s.declOnly)
        case None => @Assert(false)
    }
    match (symOf(rust, "Circle.new")) {
        case Some(s) =>
            @Assert(s.owner == "Circle")
            @Assert(s.visibility == "public")
        case None => @Assert(false)
    }
    for (s in rust.symbols) { @Assert(s.qual != "Circle.Circle") }

    // Python：缩进体定 owner 与末行；main / get 这类旧词表误杀的名字照常入表
    let py = scanSource("class App:\n    def get(self):\n        return self.helper()\n\n    def helper(self):\n        return 1\n\ndef main():\n    return 0\n", "python")
    match (symOf(py, "App.get")) {
        case Some(s) =>
            @Assert(s.owner == "App")
            @Assert(s.endLine == 3)
            @Assert(s.col == 9)
            @Assert(s.sig == "def get(self)")
        case None => @Assert(false)
    }
    match (symOf(py, "App.helper")) {
        case Some(s) => @Assert(s.endLine == 6)
        case None => @Assert(false)
    }
    match (symOf(py, "main")) {
        case Some(s) =>
            @Assert(s.owner.isEmpty())
            @Assert(s.endLine == 9)
        case None => @Assert(false)
    }

    // Java：没有关键字的方法；构造函数不入表
    let java = scanSource("""
public class Foo extends Bar {
    private int count(int a, int b) {
        return helper(a);
    }

    private int helper(int a) { return a; }

    int compute();

    public Foo(int a) { this.x = a; }
}
""", "java")
    match (symOf(java, "Foo.count")) {
        case Some(s) =>
            @Assert(s.owner == "Foo")
            @Assert(s.visibility == "private")
            @Assert(s.endLine == 4)
        case None => @Assert(false)
    }
    match (symOf(java, "Foo.compute")) {
        case Some(s) => @Assert(s.declOnly)
        case None => @Assert(false)
    }
    for (s in java.symbols) {
        @Assert(!(s.name == "Foo" && symKindId(s.kind) == "func"))
    }
    for (r in java.refs) { @Assert(r.name != "Foo") }

    // TS：类方法 / 箭头函数属性；字段与 constructor 不入表
    let ts = scanSource("""
export class Widget {
  private name: string = "";
  constructor(x: number) {}
  render(kind: string): void { this.draw(kind); }
  private draw(kind: string) { console.log(kind); }
  onTap = (e: Event) => { this.render("x"); };
}
""", "ts")
    match (symOf(ts, "Widget.render")) {
        case Some(s) =>
            @Assert(s.owner == "Widget")
            @Assert(s.endLine == 4)
        case None => @Assert(false)
    }
    match (symOf(ts, "Widget.draw")) {
        case Some(s) => @Assert(s.visibility == "private")
        case None => @Assert(false)
    }
    match (symOf(ts, "Widget.onTap")) {
        case Some(s) => @Assert(symKindId(s.kind) == "func")
        case None => @Assert(false)
    }
    for (bad in ["name", "constructor", "x", "e", "kind"]) {
        @Assert(symsNamed(ts, bad).size == 0)
    }

    // Cangjie：extend 体的成员 owner 是被扩展类型
    let cj = scanSource("""
extend String {
    public func blankish(): Bool {
        return this.isEmpty()
    }
}

public class Repo {
    public func scanAll(): Int64 { return 1 }
}
""", "cangjie")
    match (symOf(cj, "String.blankish")) {
        case Some(s) =>
            @Assert(s.owner == "String")
            @Assert(s.visibility == "public")
            @Assert(s.endLine == 4)
        case None => @Assert(false)
    }
    match (symOf(cj, "Repo.scanAll")) {
        case Some(s) => @Assert(s.owner == "Repo")
        case None => @Assert(false)
    }
}

/// C/C++ 的前置声明不是符号（修前 `class QProcess;` 被编成一个类）。
@Test
func testForwardDeclarationProducesNoSymbol(): Unit {
    let src = """
class QProcess;
class QTimer;
struct Notifier;
enum class Color : int;
union Handle;

class Notifier {
public:
    void notify();
};
"""
    let f = scanSource(src, "c")
    for (fwd in ["QProcess", "QTimer", "Color", "Handle"]) {
        @Assert(symsNamed(f, fwd).size == 0)
    }
    let n = symsNamed(f, "Notifier")
    @Assert(n.size == 1)                       // 只有带体的是符号
    @Assert(n[0].endLine == 10)
    // 函数原型同理不是「定义」，但它是声明：见 testMemberOwnerAndQualAcrossLanguages
    let n2 = symsNamed(f, "notify")
    @Assert(n2.size == 1)
    @Assert(n2[0].declOnly)
}

/// 顶层初始化器里的调用不是函数定义。
///
/// 修前（探针工程实测）：`const QStringList kQuiet = { QStringLiteral("--json"), … };`
/// 被编出一个叫 QStringLiteral 的函数——旧兜底规则是「行里有 `{` + 某标识符后面跟 `(`」。
/// 定义必须从**语句起点**开始、带类型 token 序列，并且后面是函数体或原型。
@Test
func testTopLevelInitialiserIsNotAFunction(): Unit {
    let src = """
#include <QStringList>

const QStringList kQuiet = { QStringLiteral("--json"), QStringLiteral("--quiet") };

static const Foo registered
    = registerType<Foo>();

Q_DECLARE_METATYPE(Foo)

int step(int v) {
    if (v > 3) { v = v - 1; }
    void *p = malloc(64 * sizeof(int));
    connect(btn, this, step);
    return helper(v);
}
"""
    let f = scanSource(src, "c")
    for (bad in ["QStringLiteral", "registerType", "Q_DECLARE_METATYPE", "malloc", "connect",
        "helper", "sizeof", "if", "p", "kQuiet", "registered", "Foo"]) {
        @Assert(symsNamed(f, bad).size == 0)
    }
    let st = symsNamed(f, "step")
    @Assert(st.size == 1)
    @Assert(st[0].endLine == 15)
    // 类体里「构造式初始化的成员」也不是原型
    let cls = scanSource("class W {\n    QTimer m_timer(0);\n    void start();\n};\n", "c")
    @Assert(symsNamed(cls, "m_timer").size == 0)
    @Assert(symsNamed(cls, "start").size == 1)
}

/// 调用点的采集与列号：声明自己不算调用；`~Foo(` 不算调用；内建照记（解析阶段再丢）；
/// 列号是**原始行**里的字符列——同一行前面有多字节字符串也不许算错，更不许切坏 UTF-8。
@Test
func testCallSitesColAndUtf8Safety(): Unit {
    // 夹具是那次缺陷的原始行（当时的函数名就叫 deepgitHome）——不随品牌改名变：列号 67/133 是按这一行数出来的。
    // 真实行形态（cli.cj:5329）：标识符首字节撞上另一个词（data / deepgitHome），
    // 修前为找代码位置而切 12 字节，切进了「数据目录」⇒ Invalid utf8 byte sequence。
    let line = "    checks.add([tl(lang, \"data dir\", \"数据目录\"), if (isDirectoryPath(deepgitHome())) { \"OK\" } else { tl(lang, \"not created\", \"未创建\") }, deepgitHome()])"
    let src = "public func cmd(): Unit {\n" + line + "\n}\n"
    let f = scanSource(src, "cangjie")
    // 期望列（按字符数独立数出来）：tl 在 4 空格 + checks.add([ 之后 = 17；
    // deepgitHome 第一次在 16 + 50 个字符的实参段之后 = 67，第二次在行尾 = 133。
    let homeCols = ArrayList<Int64>()
    let tlCols = ArrayList<Int64>()
    for (r in f.refs) {
        @Assert(r.caller == 0)                 // 内层被索引函数 = cmd
        if (r.name == "deepgitHome") { homeCols.add(r.col) }
        if (r.name == "tl") { tlCols.add(r.col) }
    }
    @Assert(homeCols.size == 2)
    @Assert(homeCols[0] == 67)
    @Assert(homeCols[1] == 133)
    @Assert(tlCols.size == 2)
    @Assert(tlCols[0] == 17)
    @Assert(tlCols[1] == 99)

    // 声明行 / 析构 / 控制流关键字：都不是调用
    let cpp = scanSource("""
class W {
public:
    void start();
    W();
    ~W();
};

void W::start() {
    m_timer->start(5);
    start();
    if (ready()) { return; }
    emit changed(1);
}
""", "c")
    var mTimer: Int64 = 0
    var bare: Int64 = 0
    for (r in cpp.refs) {
        @Assert(r.name != "if")
        if (r.name == "start") {
            if (r.receiver == 1 && r.receiverText == "m_timer") {
                mTimer += 1
                @Assert(r.line == 9)
            }
            if (r.receiver == 0) { bare += 1 }
        }
    }
    @Assert(mTimer == 1)
    @Assert(bare == 1)
    // Qt 的 `emit changed(1);` 是信号发射，不是「返回类型为 emit 的函数 changed」
    for (s in cpp.symbols) {
        @Assert(s.name != "changed")
    }
    for (r in cpp.refs) {
        // 发射的信号名照常是一个名字出现处（referencedNames 的来源之一）
        @Assert(r.name != "emit")
    }
}

/// 块注释的续行可以在行尾闭合（Javadoc/KDoc 最常见的收尾 ` * 说明 */`）。
/// 修前整行注释捷径直接返回、不处理 `*/`，状态 3 被带到文件末尾——
/// 之后的整份源码都成了注释（探针工程 Main.kt 从第一个 KDoc 起 0 个符号）。
@Test
func testBlockCommentClosingLineResetsState(): Unit {
    let (a, sa) = stripCode(" * 说明文字 */", 3)
    @Assert(sa == 0)
    @Assert(a.isEmpty())
    let (b, sb) = stripCode(" * text */ let real = 1", 3)
    @Assert(sb == 0)
    @Assert(b.contains("real"))
    let (c, sc) = stripCode(" * 还在注释里", 3)
    @Assert(sc == 3)
    @Assert(c.isEmpty())
    // 端到端：KDoc 之后的一切照常入表
    let f = scanSource("""
package demo

/**
 * 速览触发。
 * 线程安全。
 */
object QuickViewTrigger {
    val open = 1
}

fun App(x: Int) {
    reprobe()
}
""", "kotlin")
    match (symOf(f, "QuickViewTrigger")) {
        case Some(s) => @Assert(s.endLine == 9)
        case None => @Assert(false)
    }
    match (symOf(f, "App")) {
        case Some(s) => @Assert(s.endLine == 13)
        case None => @Assert(false)
    }
}

/// 稳定 id：`f:<file>:<line>:<name>`；同文件同行同名的第 2 个起带 `#n`。
@Test
func testStableSymbolIds(): Unit {
    @Assert(symId("a/b.kt", 12, "foo") == "f:a/b.kt:12:foo")
    let plain = SymDecl(Func, "foo", 12)
    @Assert(plain.id("a/b.kt") == "f:a/b.kt:12:foo")
    let dup = SymDecl(Func, "foo", 12, "", 12, 3, "", "", false, 2)
    @Assert(dup.id("a/b.kt") == "f:a/b.kt:12:foo#2")
    // 三参构造器照旧可用（既有调用面）
    @Assert(plain.owner.isEmpty())
    @Assert(plain.qual == "foo")
    @Assert(plain.endLine == 0)
    @Assert(!plain.declOnly)
}

/// 不跨语言连边：Kotlin 的 `work(` 在全工程没有 Kotlin 定义 ⇒ 未解析，
/// 不去连 Swift 里同名的 work（探针工程实测曾让 Kotlin 文件「调用」C++ 与 Swift 文件）。
/// Kotlin ↔ Java 同族例外。
@Test
func testNoCrossLanguageEdges(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/k.kt", "package k\n\nfun stop(): Int {\n    work()\n    return 1\n}\n")
        writeFileAtomic("${root}/s.swift", "func work() -> Int { return 2 }\n")
        writeFileAtomic("${root}/J.java", """
public class J {
    public static int shared() { return 3 }
}
""")
        writeFileAtomic("${root}/u.kt", "package k\n\nfun useJava(): Int {\n    return J.shared()\n}\n")
        let g = buildGraph(root)
        for (s in g.callSites) {
            if (s.name == "work") { @Assert(s.dst.isEmpty()) }
            if (s.name == "shared") { @Assert(s.dst == "f:J.java:2:shared") }
        }
        let edges = callEdgesFrom(g.callSites, { p => true })
        @Assert(!hasEdge(edges, "f:k.kt:3:stop", "f:s.swift:1:work"))
        @Assert(edgeTierOf(edges, "f:u.kt:3:useJava", "f:J.java:2:shared") == "direct")
    } finally {
        removeTree(root)
    }
}

/// 标准库内建按语言丢弃，但**只在项目没有同名符号时**：项目自己定义的 strip / error
/// 照常解析到项目符号；框架名字（Text / padding）不算内建，仍是未解析。
@Test
func testLangBuiltinsDropOnlyWithoutProjectSymbol(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/a.cpp", """
#include <QStringList>

void f() {
    const QStringList k = { QStringLiteral("--json"), QLatin1String("x") };
    swap(k, k);
    QLabel box;
    box.addWidget(&box);
}
""")
        writeFileAtomic("${root}/b.py", """
class Store:
    def strip(self, v):
        return v

def use(st):
    return st.strip(1)
""")
        // d.py：只调内建 str 方法，项目里……注意 b.py / c.kt 定义了同名符号，
        // 所以内建判定**不会**生效——这正是「按内建丢弃只在无同名符号时成立」的另一面。
        writeFileAtomic("${root}/d.py", """
def run():
    s = " x ".rstrip()
    return s.splitlines()

def other():
    return add_argument()
""")
    // 夹具里的注解不用 Compose 的那个：它的首两字节撞上传输层 lint 逐词封杀的 FFI 标记
    // （util/paths.cj 的 __lintTransportLayerHasOnlyTwoSurfaces）。
        writeFileAtomic("${root}/c.kt", """
package c

fun strip(x: Int): Int { return x }

fun useIt(): Int {
    return strip(1) + listOf(1, 2).size
}

@Stable
fun Screen() {
    Text("hi")
    Spacer()
}
""")
        let g = buildGraph(root)
        var cppBox: Int64 = 0
        var qtLiterals: Int64 = 0
        var pyBuiltinDrop: Int64 = 0
        var pyProjectStrip: Int64 = 0
        var ktProjectStrip: Int64 = 0
        var framework: Int64 = 0
        for (s in g.callSites) {
            if (s.name == "QStringLiteral" || s.name == "QLatin1String" || s.name == "swap") { qtLiterals += 1 }
            if (s.name == "addWidget") { cppBox += 1 }
            if (s.file == "b.py" && s.name == "strip") { pyProjectStrip += 1 }
            if (s.file == "d.py" && (s.name == "rstrip" || s.name == "splitlines"
                || s.name == "add_argument")) { pyBuiltinDrop += 1 }
            if (s.file == "c.kt" && s.name == "strip") { ktProjectStrip += 1 }
            if (s.file == "c.kt" && (s.name == "Text" || s.name == "Spacer")) { framework += 1 }
        }
        @Assert(qtLiterals == 0)            // 标准库 / 字面量宏：项目无同名符号 ⇒ 不入库
        @Assert(pyBuiltinDrop == 0)         // str / argparse 的内建方法：同上
        @Assert(cppBox == 1)                // 框架方法：未解析，如实保留
        @Assert(framework == 2)             // Compose：未解析，如实保留
        // 项目自己定义的 strip：两个语言的调用点都解析到各自语言的定义
        @Assert(pyProjectStrip == 1)
        @Assert(ktProjectStrip == 1)
        let edges = callEdgesFrom(g.callSites, { p => true })
        @Assert(edgeTierOf(edges, "f:c.kt:5:useIt", "f:c.kt:3:strip") == "resolved")
        @Assert(edgeTierOf(edges, "f:b.py:5:use", "f:b.py:2:strip") == "resolved")    // 同文件唯一
        // 如实的边界：项目里存在同名方法时，内建 str.strip(…) 的接收者调用分不出来，
        // 会按裸名连到项目方法（st.strip 那一条是 resolved；词法级没有类型信息）。
        @Assert(hasEdge(edges, "f:b.py:5:use", "f:b.py:2:strip"))
    } finally {
        removeTree(root)
    }
}

/// `self.name(` 等同限定：接收者是 self 时按外层类型的成员解析（direct）。
@Test
func testSelfReceiverResolvesToEnclosingTypeMember(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/app.py", "class App:\n    def get(self):\n        return self.helper()\n\n    def helper(self):\n        return 1\n\nclass Other:\n    def helper(self):\n        return 2\n")
        let g = buildGraph(root)
        let edges = callEdgesFrom(g.callSites, { p => true })
        // 同文件有两个 helper：裸名是歧义，但 self.helper 指向 App 自己的那个 ⇒ direct
        @Assert(edgeTierOf(edges, "f:app.py:2:get", "f:app.py:5:helper") == "direct")
        @Assert(!hasEdge(edges, "f:app.py:2:get", "f:app.py:9:helper"))
        @Assert(Int64(edges.size) == 1)
    } finally {
        removeTree(root)
    }
}

// MARK: - grep

/// 定字符串搜索：大小写、上下文、通配、限流披露；不搜非源码文件；不做正则。
@Test
func testGrepFixedString(): Unit {
    let root = testRoot()
    try {
        ensureDir("${root}/src")
        ensureDir("${root}/docs")
        writeFileAtomic("${root}/src/a.kt", "data class Foo(val a: Int)\n// Data Class in a comment\nfun bar() {}\nabc\n")
        writeFileAtomic("${root}/src/b.py", "x = 'data class'  # before\nDATA CLASS\n")
        writeFileAtomic("${root}/docs/README.md", "data class in docs\n")
        let r = grepSources(root, "data class", false, 200, 0, "")
        @Assert(Int64(r.hits.size) == 2)
        @Assert(!r.truncated)
        @Assert(r.filesScanned == 2)            // README.md 不是源码：不扫
        @Assert(r.hits[0].file == "src/a.kt")
        @Assert(r.hits[0].line == 1)
        @Assert(r.hits[0].col == 1)
        @Assert(r.hits[1].file == "src/b.py")
        @Assert(r.hits[1].line == 1)
        @Assert(r.hits[1].col == 6)             // x = ' 之后
        let ci = grepSources(root, "data class", true, 200, 0, "")
        @Assert(Int64(ci.hits.size) == 4)              // 注释行里的 Data Class 也算
        @Assert(ci.hits[3].file == "src/b.py")
        @Assert(ci.hits[3].line == 2)
        // 上下文：文件末尾的命中没有「之后」行
        let ctx = grepSources(root, "DATA CLASS", false, 200, 1, "")
        @Assert(Int64(ctx.hits.size) == 1)
        @Assert(Int64(ctx.hits[0].before.size) == 1)
        @Assert(ctx.hits[0].before[0].contains("before"))
        // 文件以换行结尾：split 多出一个空尾元素，不是真实的「之后一行」
        @Assert(Int64(ctx.hits[0].after.size) <= 1)
        // glob
        let py = grepSources(root, "data class", false, 200, 0, "*.py")
        @Assert(Int64(py.hits.size) == 1)
        @Assert(py.hits[0].file == "src/b.py")
        @Assert(Int64(grepSources(root, "data class", false, 200, 0, "src/*.kt").hits.size) == 1)
        @Assert(Int64(grepSources(root, "data class", false, 200, 0, "a.kt").hits.size) == 1)
        @Assert(Int64(grepSources(root, "data class", false, 200, 0, "*.rs").hits.size) == 0)
        // 限流：取满且确实还有 ⇒ truncated
        let lim = grepSources(root, "data class", true, 2, 0, "")
        @Assert(Int64(lim.hits.size) == 2)
        @Assert(lim.truncated)
        let exact = grepSources(root, "data class", true, 4, 0, "")
        @Assert(!exact.truncated)                        // 正好取满、后面确实没有了
        @Assert(grepSources(root, "data class", true, 3, 0, "").truncated)
        // 不是正则：`a.c` 不匹配 abc；`ab*` 不匹配 ab
        @Assert(Int64(grepSources(root, "a.c", false, 200, 0, "").hits.size) == 0)
        @Assert(Int64(grepSources(root, "ab*", false, 200, 0, "").hits.size) == 0)
        // 通配匹配器自身
        @Assert(globMatch("a/b/c.kt", "*.kt"))
        @Assert(globMatch("a/b/c.kt", "a/*/c.kt"))
        @Assert(!globMatch("a/b/c.kt", "b/*.kt"))
        @Assert(globMatch("abc", "a?c"))
        @Assert(globMatch("abc", "a??"))         // 两个 ? 恰好吃掉 b、c
        @Assert(!globMatch("abcd", "a??"))       // 多出一个字符 ⇒ 不匹配
        @Assert(globMatch("abc", "*"))
        @Assert(globMatch("", "*"))
        @Assert(!globMatch("", "?"))
        @Assert(!globMatch("abc", "abc*def"))
    } finally {
        removeTree(root)
    }
}

// MARK: - 定义行不是调用点（阶段二 · 扫描器修复）

/// 调用点里有没有某个名字（可选：只在指定行）。
func hasRefNamed(refs: ArrayList<CallSite>, name: String, line: Int64): Bool {
    for (r in refs) {
        if (r.name != name) { continue }
        if (line < 0 || r.line == line) { return true }
    }
    return false
}

/// 声明还在进行中的行（签名行 / 参数续行 / 签名延续）不是调用点：`name(` 里的
/// name 是**被声明的名字**，不是调用。
///
/// ⚠ 修前：花括号另起一行（C++ Allman）或参数表跨行时，签名行整行被扫成代码，
/// 定义行上编出一个 `name(` 调用点——解析后**连到符号自己**（`index refs` 报出
/// 它自己的定义行；入度恒 ≥ 1，Allman 函数永远报不了 orphan）。探针工程实测
/// 19040 个调用点里 744 个是这种、680 个解析到自己。
/// 六种语言各一例，全部走真实扫描路径 scanSource；正控：函数体里的调用照记。
@Test
func testDefinitionLineIsNotACallSite(): Unit {
    // (语言, 源码, 声明行, 被声明的名字, 体里的调用)
    let cases: Array<(String, String, Int64, String, String)> = [
        // C++ Allman：`{` 在签名下一行；前面的类内原型由分号收尾，本来就不采
        ("c", """
class Widget {
public:
    void refresh(int n);
};

void Widget::refresh(int n)
{
    repaint();
}
""", 6, "refresh", "repaint"),
        // C：参数表跨行 + 花括号另起一行
        ("c", """
int wide(int a,
         int b)
{
    return helper(a);
}
""", 1, "wide", "helper"),
        // Kotlin / Swift：参数表跨行，`)` 之后同行开体
        ("kotlin", """
package a

fun wide(
    a: Int,
    b: Int
): Int {
    return helper(a)
}
""", 3, "wide", "helper"),
        ("swift", """
func wide(
    _ a: Int,
    _ b: Int
) -> Int {
    return helper(a)
}
""", 1, "wide", "helper"),
        // Go / Rust：参数表跨行（尾逗号），`) 返回值 {` 同行开体
        ("go", """
package main

func wide(
    a int,
    b int,
) int {
    return helper(a)
}
""", 3, "wide", "helper"),
        ("rust", """
fn wide(
    a: i32,
    b: i32,
) -> i32 {
    helper(a)
}
""", 1, "wide", "helper"),
        // Java：类体内，参数表在下一行闭合
        ("java", """
class W {
    int wide(
        int a,
        int b) {
        return helper(a);
    }
}
""", 2, "wide", "helper"),
        // Kotlin 一行式（表达式体）：`=` 之后才是代码
        ("kotlin", """
fun narrow(x: Int): Int = helper(x)
""", 1, "narrow", "helper")
    ]
    for ((lang, src, declLine, declName, bodyCall) in cases) {
        let refs = scanSource(src, lang).refs
        @Assert(!hasRefNamed(refs, declName, -1))
        // 正控：函数体里的真调用照记（声明感知不许把体里的调用一起吃掉）
        @Assert(hasRefNamed(refs, bodyCall, -1))
    }
    // 构造函数：声明与初始化列表不是调用点（另起一行 / 同行两种写法），`{` 之后照常采。
    // 修前只跳过名字 token，`: m_level(level)` 这类初始化列表行被编成假调用点。
    let ctors = scanSource("""
class Card {
public:
    explicit Card(int level = 0)
        : m_level(level)
    {
        reset();
    }

    Card() : m_level(0) { tick(); }
};
""", "c").refs
    @Assert(!hasRefNamed(ctors, "Card", -1))
    @Assert(!hasRefNamed(ctors, "m_level", -1))
    @Assert(hasRefNamed(ctors, "reset", 6))
    @Assert(hasRefNamed(ctors, "tick", 9))
    let ctorDef = scanSource("Card::Card(int level)\n    : m_level(level)\n{\n    tick();\n}\n", "c").refs
    @Assert(!hasRefNamed(ctorDef, "Card", -1))
    @Assert(!hasRefNamed(ctorDef, "m_level", -1))
    @Assert(hasRefNamed(ctorDef, "tick", 4))
    let javaCtor = scanSource("class App {\n    App() { init(); }\n}\n", "java").refs
    @Assert(!hasRefNamed(javaCtor, "App", -1))
    @Assert(hasRefNamed(javaCtor, "init", 2))
    // K&R 一行式：声明与体同行，体里的调用必须照记（`{` 之后才扫）
    let oneLine = scanSource("int f(int v) { return g(v); }\n", "c").refs
    @Assert(hasRefNamed(oneLine, "g", 1))
    @Assert(!hasRefNamed(oneLine, "f", -1))
    // 同行开体的 C++ 成员定义：`{` 之后照记
    let kr = scanSource("void Widget::tick() { repaint(); }\n", "c").refs
    @Assert(hasRefNamed(kr, "repaint", 1))
    @Assert(!hasRefNamed(kr, "tick", -1))
    // 默认实参 / 尾随限定上的 `ident(` 属于声明，不是调用点（签名行不采）
    let defaulted = scanSource("int f(int a = fallback(3))\n{\n    return a;\n}\n", "c").refs
    @Assert(!hasRefNamed(defaulted, "f", -1))
    @Assert(!hasRefNamed(defaulted, "fallback", -1))
}
