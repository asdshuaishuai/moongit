// graph/members_test.cj — 成员级索引的判据：提取深度 / 调用点解析 / SQLite v2 读路径 / grep。
//
// 【与 graph_test.cj 的分工】那边钉的是旧词法图谱的行为（假符号防线、引用边、
// 置信度、渲染）；这里钉的是「agent 能不能可靠地定位代码」这件事本身：
//   · 符号带 owner/qual/行范围/列/签名/可见性/是否只有声明；
//   · 调用点是解析过的（direct / resolved / guessed / 未解析），带 file:line:col；
//   · 五个查询出口的 JSON 键集恒定。
// 每条判据都配过负控（注入 → 红 → 还原），见提交说明。
package moongit.graph

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

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

let ID_HELPER_A: String = "f:a/helper.kt:3:helper"
let ID_ONLY_B: String = "f:a/only.kt:3:onlyB"
let ID_TWICE: String = "f:a/util.kt:4:twice"
let ID_SELF_CALL: String = "f:a/util.kt:8:selfCall"
let ID_UTIL: String = "f:a/util.kt:3:Util"
let ID_HELPER_B: String = "f:b/helper.kt:3:helper"
let ID_USER_B: String = "f:b/user.kt:3:userB"
let ID_ENTRY: String = "f:main.kt:3:entry"

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
