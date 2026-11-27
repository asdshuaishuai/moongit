// graph/confidence_detect.cj — 置信度检测器集合（每个检测器一个纯函数）。
//
// 【纪律】每个检测器只做一件事，阈值全部引用 confidence.cj 里的常量；
// 证据字符串必须自足（file:line + 为什么可疑的可核验描述）。
package cambium.dendro

import std.collection.*
import std.convert.*
import cambium.util.*
import cambium.graph.*

// MARK: - 常量表（顶层 let 必须先定义后使用：全部集中在文件头）

/// 声明行上**不是名字**的词：修饰词、类型词、声明关键词。
/// `private fun keyFile(): File` 的 token 是 [private, fun, keyFile, File]——
/// 原实现取「第一个不在 KEYWORDS 里的 token」，`fun` 不在 KEYWORDS 里，于是报告里的符号列
/// 整列都是 `fun`（实测 deepDolphin：stub-body 104 条里 70 条的符号是 `fun`）。
func declNoise(): HashSet<String> {
    let s = HashSet<String>()
    for (w in KEYWORDS) { s.add(w) }
    for (w in ["fun", "function", "mut", "pub", "extern", "required", "convenience", "lazy",
        "unowned", "override", "virtual", "explicit", "async", "await", "yield",
        "get", "set", "subscript", "deinit", "constructor", "companion", "record",
        "delegate", "event", "partial", "constexpr", "noexcept", "consteval", "constinit",
        "signal", "signals", "slot", "slots", "Q_SIGNAL", "Q_SLOT", "Q_INVOKABLE",
        "void", "bool", "boolean", "BOOL", "int", "long", "short", "char", "float", "double",
        "auto", "unsigned", "signed", "size_t", "string", "var", "val", "out", "ref",
        "params", "self", "static", "typealias", "typedef", "struct", "class",
        "interface", "enum", "protocol", "trait", "impl", "extend", "extension", "init", "new",
        "namespace", "using", "template", "inline", "sealed", "abstract",
        "suspend", "infix", "unsafe", "readonly", "throws", "rethrows"]) {
        s.add(w)
    }
    return s
}

let NODE_NAME_NOISE: HashSet<String> = declNoise()

/// 参数表与块体之间有成员初始化列表（`Foo::Foo() : m_x(x), m_y(y) {`）：`:` 之后、`{` 之前有内容。
func hasInitializerList(text: String): Bool {
    let close = paramListClose(text)
    if (close < 0) { return false }
    let open = codeIndexOf(text, close + 1, 123)
    if (open < 0) { return false }
    let b = text.toArray()
    var i = close + 1
    while (i < open) {
        // `::` 是限定名，不是初始化列表
        if (b[i] == 58 && (i + 1 >= open || b[i + 1] != 58) && (i == close + 1 || b[i - 1] != 58)) {
            return true
        }
        i += 1
    }
    return false
}

/// 常量占位返回的既有清单（原判定逐个 == 比较，口径不变）。
func placeholderReturns(): HashSet<String> {
    let s = HashSet<String>()
    for (t in ["return", "return nil", "return None", "return null", "return undefined",
        "return 0", "return 1", "return false", "return true", "return []", "return {}"]) {
        s.add(t)
    }
    return s
}

let PLACEHOLDER_RETURNS: HashSet<String> = placeholderReturns()

/// 各语言「未实现」的惯用调用（带参的也认，所以是前缀）。
let PLACEHOLDER_CALLS: Array<String> = ["unimplemented!(", "todo!(", "unreachable!(",
    "fatalError(", "notImplemented()", "NotImplementedError(", "NotImplemented(",
    "TODO()", "todo()", "raise NotImplementedError", "throw NotImplementedError("]

/// 表达式体的占位值（已去空白与结尾分号）。
func placeholderExprs(): HashSet<String> {
    let s = HashSet<String>()
    for (t in ["TODO()", "todo()", "NotImplemented()", "NotImplementedError()",
        "notImplemented()", "undefined", "null", "nil", "None", "Unit"]) {
        s.add(t)
    }
    return s
}

let PLACEHOLDER_EXPRS: HashSet<String> = placeholderExprs()

/// `return x;` / `case x:` / `delete x`——这些词后面的 x 是用法，不是声明。
func cStmtWords(): HashSet<String> {
    let s = HashSet<String>()
    for (w in ["return", "case", "delete", "throw", "co_return", "co_yield", "sizeof", "alignof",
        "decltype", "typeid", "new", "goto", "else", "using", "typedef", "friend", "extern"]) { s.add(w) }
    return s
}

let C_STMT_WORDS: HashSet<String> = cStmtWords()

/// 取锁 / 释放锁的调用写法（Swift / Kotlin / Java 的 NSLock 与 ReentrantLock、Python threading、
/// Cangjie sync.Mutex、Win32 CRITICAL_SECTION、objc_sync；Go 的 Lock / Unlock 首字母大写）。
let LOCK_ACQUIRE: Array<String> = [".lock(", ".acquire(", ".Lock(", ".RLock(", "pthread_mutex_lock",
    "EnterCriticalSection", "objc_sync_enter"]
let LOCK_RELEASE: Array<String> = [".unlock(", ".release(", ".Unlock(", ".RUnlock(", "pthread_mutex_unlock",
    "LeaveCriticalSection", "objc_sync_exit"]

/// 上一行出现即视为「框架回调」的注解片段。
let CALLBACK_ANNOTATIONS: Array<String> = ["@Override", "@objc", "@IBAction", "@OnClick",
    "@OnLongClick", "@Subscribe", "@EventListener", "@ExceptionHandler", "@Bean", "@Route"]

/// Swift 里由协议 / 框架按名字调用的方法（声明处没有 `override` 关键字）。
let SWIFT_WITNESS_NAMES: Array<String> = ["makeNSView", "updateNSView", "makeCoordinator",
    "makeUIViewController", "updateUIViewController", "userNotificationCenter", "application",
    "scene", "makeBody"]


/// Compose 快照状态的委托写法。
let SNAPSHOT_STATE_MARKS: Array<String> = ["mutableStateOf(", "mutableIntStateOf(", "mutableLongStateOf(",
    "mutableFloatStateOf(", "mutableDoubleStateOf(", "derivedStateOf("]

/// 输入侧 I/O 的调用标记（读文件 / 起进程；引擎自家工具函数 + 各语言的常见写法）。
let IO_READ_MARKS: Array<String> = ["readFile", "readFileText", "readFileChecked", "execCapture",
    "subprocess.", "ifstream", "QFile(", ".readText(", "readAllText", "fs.read", "indexMetaRead"]
/// 输出侧 I/O 的调用标记。
let IO_WRITE_MARKS: Array<String> = ["writeFile", "ensureDir", "deleteFile", "copyFile", "moveFile",
    "ofstream", ".writeText(", "writeAllText", "fs.write"]

/// 声明关键词（各语言的函数与类型声明）。
let DECL_NAME_WORDS: Array<String> = ["func", "fun", "def", "fn", "function", "class", "struct",
    "enum", "interface", "protocol", "trait", "extension", "object"]

/// lambda / 闭包的写法标记。
let LAMBDA_MARKS: Array<String> = ["=>", "->", "lambda ", "fun ", "function", "[&", "[=", "[](",
    "[this]", "|"]


// MARK: - ① 孤儿符号

/// 有**调用证据**的符号集合：解析后的调用点（graph.callSites，与 codegraph.db 的 sites
/// 表同一批行）里，dst 指向它、tier 为 direct / resolved / guessed 的都算「有人用」
/// （guessed 是裸名歧义的全部候选——词法级分不清是哪一个，宁可都算用过）。
/// 构造调用 `Foo(` 也在这里：它解析到 Class 本身。
///
/// 两类不算：
///   · **声明位置上的调用点对被声明的那个符号不算**：`name(` 落在某个符号自己的声明行
///     上、名字也相同——对它而言这是被声明的名字，不是调用（不变量 125：声明位置不算
///     使用，否则「定义即使用」）。扫描器已不再采这种行（阶段二 · 扫描器修复）；但表达式体
///     `fun f() = cfg.f()` 的真调用恰好也在 f 的声明行上，裸名歧义时 f 自己也是候选之一——
///     这一处的证据给别的候选，不给 f 自己。
///   · **自调用**：caller == dst。函数只被自己调用，等于没人用。
func symbolsWithCallEvidence(graph: CodeGraph): HashSet<String> {
    // (文件, 行, 名字) → 声明在这个位置上的符号 id
    let declPos = HashMap<String, HashSet<String>>()
    for (f in graph.files) {
        for (s in f.symbols) {
            let key = f.relPath + "\u{1f}" + s.line.toString() + "\u{1f}" + s.name
            match (declPos.get(key)) {
                case Some(ids) => ids.add(s.id(f.relPath))
                case None =>
                    let ids = HashSet<String>()
                    ids.add(s.id(f.relPath))
                    declPos[key] = ids
            }
        }
    }
    let used = HashSet<String>()
    for (site in graph.callSites) {
        if (site.dst.isEmpty()) { continue }
        if (site.caller == site.dst) { continue }
        var onOwnDecl = false
        match (declPos.get(site.file + "\u{1f}" + site.line.toString() + "\u{1f}" + site.name)) {
            case Some(ids) => onOwnDecl = ids.contains(site.dst)
            case None => ()
        }
        if (onOwnDecl) { continue }
        used.add(site.dst)
    }
    return used
}

/// 定义了、但全仓没有任何**使用证据**（**符号级**）。
///
/// 【使用证据是两路的并集（阶段二 B）】
///   · 提及证据：名字在某个非声明位置作为标识符出现过（build.cj 累积的
///     `graph.referencedNames`，剥注释、保留字符串——`${…}` 插值里嵌的是代码）；
///   · 调用证据：有解析后的调用点连到它（symbolsWithCallEvidence）。
/// 为什么不是「只认调用点」：调用点看不见三种真实使用——类型被当类型用（声明 / 泛型 /
/// 返回类型，`struct Foo` 全仓没有一处 `Foo(`）、函数被当值用（`&AgentDialog::resendLast`
/// 槽函数引用、回调传名）、只在字符串插值里被调用（不变量 125 记过这个坑）。拿
/// /tmp/itest 实测（扫描器修复之后、同样套孪生规则）：只认调用点时 orphan 是 410 条
/// （每文件封顶后；496 个候选里 358 个是 struct / enum / class / interface——被当类型用），
/// 并集是 72 条。并集只增不减证据 ⇒ 相对「只认提及」孤儿只减不增；调用点那一路让
/// 判定与索引说同一件事，并兜住提及证据自己的盲区（见 symbolsWithCallEvidence）。
///
/// 【声明孪生】只有声明没有体的符号（C/C++ 头文件原型、接口 / 抽象方法签名），同语言里
/// 另有同 qual 的定义 ⇒ 不报：调用点连的是定义，原型的入度天然是 0，报它等于把同一个
/// 死函数报两遍（/tmp/itest 实测 8 对）。只有原型、没有定义的照报。
///
/// ⚠️ 边界如实说：提及证据是词法级的，会**高估**引用（同名巧合）⇒ 这里的「孤儿」是
/// **保守的**（宁可漏报）。真实使用但从未被提及名字的符号（纯入口 / 反射 /
/// 协议实现）会被误报，靠 `isEntryLike` 豁免入口 / 测试文件降低噪声。
/// 传递性死代码（如仅被同样已死的空壳引用的类型）不追。
///
/// 早期版本判定单位是**文件**（整个文件无人引用才报）—— 文件里混有活符号与
/// 死符号时漏报（只用到该文件里某一个活符号，整文件就被判为「被引用」）。
func detectOrphans(graph: CodeGraph, findings: ArrayList<Finding>,
                   cap: CapDropCounter): Unit {
    let usedByCall = symbolsWithCallEvidence(graph)
    // 有定义的限定名（同语言）：声明孪生的判定键，与 resolve.cj 的 ResolveIndex 同口径
    let definedQuals = HashSet<String>()
    for (f in graph.files) {
        for (s in f.symbols) {
            if (!s.declOnly) { definedQuals.add(f.lang + "\u{1f}" + s.qual) }
        }
    }
    // 框架入口：override / virtual / Qt 槽与信号 / 回调注解——由框架调用，源码里没有调用点是正常的
    let entryKeys = frameworkEntryKeys(graph)
    let perFile = HashMap<String, Int64>()
    var cCounts: Option<HashMap<String, Int64>> = None
    for (f in graph.files) {
        if (f.symbols.size == 0) { continue }
        // 入口文件豁免：main / 测试文件 / 明确命名的入口（这些「没人引用」是正常的）
        let base = lastSeg(f.relPath)
        if (isEntryLike(base) || isTestPath(f.relPath)) { continue }
        for (s in f.symbols) {
            if (graph.referencedNames.contains(s.name)) { continue }
            if (usedByCall.contains(s.id(f.relPath))) { continue }
            // C/C++ 的非限定枚举：枚举项不带枚举名就能用（`PageIndex::X` 不必写），
            // 枚举名「无人引用」不代表它没被接入——有任何一个枚举项被引用就不报
            var isEnum = false
            match (s.kind) {
                case Enum => isEnum = true
                case _ => ()
            }
            if (isEnum && f.lang == "c") {
                if (cCounts == None) {
                    cCounts = Some(cIdentifierCounts(graph))
                }
                var used = false
                match (cCounts) {
                    case Some(cc) => used = unscopedEnumIsUsed(graph.root, cc, f, s)
                    case None => ()
                }
                if (used) { continue }
            }
            // 声明孪生：有同 qual 的定义 ⇒ 不报（定义那一处照常判）
            if (s.declOnly && definedQuals.contains(f.lang + "\u{1f}" + s.qual)) { continue }
            // 框架入口不报（声明与定义同一把钥匙）
            if (entryKeys.contains(f.lang + "\u{1f}" + s.qual)) { continue }
            if (isFrameworkCallbackName(s.name, f.lang, s.owner)) { continue }
            // 测试符号豁免：`@Test func testXxx` 由测试框架反射调用，源码里无引用
            if (isTestLike(s.name)) { continue }
            let c = match (perFile.get(f.relPath)) {
                case Some(v) => v
                case None => 0
            }
            if (c >= CONF_MAX_PER_KIND_PER_FILE) {
                // 丢弃发生点：CapDropCounter 递增（cappedKind 真值，见 confidence.cj）
                cap.drop(Orphan, f.relPath)   // 丢弃发生点（cappedKind 真值 + 罚分计入总分）
                continue
            }
            perFile[f.relPath] = c + 1
            findings.add(Finding(Orphan, f.relPath, s.line, s.name,
                "${symKindId(s.kind)} ${s.name}：定义后全仓无任何非声明处引用，"
                + "也没有调用点连到它——可能从未被接入，或已被替代"))
        }
    }
}

/// 框架入口的限定名键（lang + U+001F + qual）。这些符号由框架 / 运行时调用，
/// 「全仓没有非声明处引用」对它们不成立为「孤儿」的证据。实测 deepDolphin 列出的 114 条
/// orphan 里约 30 条是这一类（Qt 的 paintEvent / wheelEvent / dropEvent、运算符重载、
/// Python 的 __getitem__、Qt 信号与 D-Bus 槽、Swift 的 NSViewRepresentable 见证方法）。
///
/// 判据（任一成立，看声明行或它的上一行；C 系还看所在的访问段）：
///   · 声明行有 `override` / `virtual` / `Q_INVOKABLE` / `Q_SLOT`；
///   · 上一行是回调注解（Java 的 `@Override`、`@objc` / `@IBAction`、`@OnClick`、事件订阅）；
///   · C++：声明在 `signals:` / `slots:` 段里（Qt 信号由 emit 触发、槽由 connect 接线）。
/// 符合的符号连同它同 qual 的声明 / 定义一起豁免。
func frameworkEntryKeys(graph: CodeGraph): HashSet<String> {
    let keys = HashSet<String>()
    for (f in graph.files) {
        if (f.lang != "c" && f.lang != "kotlin" && f.lang != "swift" && f.lang != "java") { continue }
        let content = readFileText(graph.root + "/" + f.relPath)
        match (content) {
            case Some(text) =>
                let code = ArrayList<String>()
                let sectionAt = ArrayList<String>()   // C++：该行所在的访问段（signals / slots / 空）
                let sections = ArrayList<String>()    // 按花括号深度的当前访问段
                var strState: Int64 = 0
                var depth: Int64 = 0
                for (line in text.lazySplit("\n")) {
                    let (t0, ns) = stripCode(line, strState)
                    strState = ns
                    let t = t0.trimAscii()
                    if (f.lang == "c") {
                        match (qtSectionLabel(t)) {
                            case Some(label) =>
                                while (Int64(sections.size) <= depth) { sections.add("") }
                                sections[depth] = label
                            case None => ()
                        }
                    }
                    code.add(t)
                    var sec = ""
                    if (f.lang == "c" && depth < Int64(sections.size)) { sec = sections[depth] }
                    sectionAt.add(sec)
                    var d: Int64 = 0
                    for (c in t) {
                        if (c == 123) { d += 1 }
                        else if (c == 125) { d -= 1 }
                    }
                    depth += d
                    if (depth < 0) { depth = 0 }
                    // 离开一层：这一层的访问段作废
                    while (Int64(sections.size) > depth + 1) { sections.remove(at: sections.size - 1) }
                }
                for (s in f.symbols) {
                    let ln = s.line
                    if (ln < 1 || ln > Int64(code.size)) { continue }
                    let own = code[ln - 1]
                    var prev = ""
                    if (ln >= 2) { prev = code[ln - 2] }
                    var entry = hasWord(own, "override") || hasWord(own, "virtual")
                        || own.contains("Q_INVOKABLE") || own.contains("Q_SLOT")
                    if (!entry && prev.contains("@")) {
                        for (a in CALLBACK_ANNOTATIONS) {
                            if (prev.contains(a)) { entry = true; break }
                        }
                    }
                    if (!entry && (sectionAt[ln - 1] == "signals" || sectionAt[ln - 1] == "slots")) {
                        entry = true
                    }
                    if (entry) { keys.add(f.lang + "\u{1f}" + s.qual) }
                }
            case None => ()
        }
    }
    return keys
}

/// 整词匹配（字节级；非 ASCII 字节天然是分隔符）。
func hasWord(t: String, w: String): Bool {
    var from: Int64 = 0
    while (true) {
        match (t.indexOf(w, from)) {
            case Some(k) =>
                let e = k + w.size
                if ((k == 0 || !isIdentByte(t[k - 1])) && (e >= Int64(t.size) || !isIdentByte(t[e]))) {
                    return true
                }
                from = k + 1
            case None => return false
        }
    }
    return false
}

/// C++ 访问段标签行：`signals:` / `Q_SIGNALS:` / `public slots:` / `private Q_SLOTS:` → Some("signals" / "slots")；
/// 普通的 `public:` / `protected:` / `private:` → Some("")（清掉本层的段）；不是标签 → None。
func qtSectionLabel(t: String): Option<String> {
    if (blankLine(t) || !t.endsWith(":")) { return None }
    let toks = tokenize(t)
    if (toks.size == 0 || toks.size > 3) { return None }
    let last = toks[toks.size - 1]
    if (last == "signals" || last == "Q_SIGNALS") { return Some("signals") }
    if (last == "slots" || last == "Q_SLOTS") { return Some("slots") }
    if (toks.size == 1) {
        if (last == "public" || last == "private" || last == "protected") { return Some("") }
    }
    return None
}

/// 按名字认的框架回调：运算符重载与双下划线方法由语法 / 解释器调用；
/// Python HTTP 处理器的 `do_*` / `log_*`、Swift 协议见证方法（没有 override 关键字）、
/// Qt 的 `*Event` 虚函数（头文件里未必写 override）。
func isFrameworkCallbackName(name: String, lang: String, owner: String): Bool {
    if (name.startsWith("operator")) { return true }
    if (lang == "python") {
        if (name.startsWith("__") && name.endsWith("__")) { return true }
        if (name.startsWith("do_") || name.startsWith("log_") || name == "handle_one_request") { return true }
    }
    if (lang == "c" && owner != "" && name.endsWith("Event")) { return true }
    if (lang == "swift") {
        for (w in SWIFT_WITNESS_NAMES) {
            if (name == w) { return true }
        }
        // NSApplicationDelegate 的回调方法没有 override 关键字：`applicationDidFinishLaunching`、
        // `applicationWillTerminate`、`applicationShouldTerminate`…——按前缀 + 紧跟的大写字母认
        if (name.startsWith("application") && name.size > 11) {
            let b0 = name.toArray()[11]
            if (b0 >= 65 && b0 <= 90) { return true }
        }
    }
    return false
}

/// 测试符号豁免：由测试框架**反射调用**、源码里无引用的函数 ——
/// `@Test func testXxx` 与 `@Test func __lintXxx`（本项目用 `__lint` 前缀
/// 命名正则守卫，参考 kernel/scanner.cj 的同一约定）。这是「没人引用」的正常
/// 形态，不是孤儿。
func isTestLike(name: String): Bool {
    if (name.startsWith("__lint")) { return true }
    if (name.size < 4) { return false }
    let head = name[0..4]
    return head == "test" || head == "Test"
}

/// 测试 / 演示类文件名词。
let TESTISH_WORDS: Array<String> = ["test", "tests", "spec", "specs", "xctest", "unittest", "testcase",
    "fixture", "fixtures", "demo", "demos", "example", "examples", "sample", "samples", "preview", "previews"]
/// 入口类文件名词（文件名最后一段）。
let ENTRY_WORDS: Array<String> = ["main", "app", "index", "entry", "mod", "lib", "package"]

/// 入口 / 测试 / 演示类文件的豁免（这些「没人引用」是正常的）。
/// 按**词**判，不按子串：`spec`、`test`、`demo` 作为子串会命中 `inspector.swift`、`specification.go`、
/// `latest.ts`（评估文档 B7）。
///   · 测试 / 演示词（test、tests、spec、xctest、demo、example、preview…）：文件名里的任何一个词相等；
///   · 入口词（main、app、index、entry、mod、lib、package）：文件名（去扩展名后的最后一段）就是它。
func isEntryLike(base: String): Bool {
    // 先按原大小写切词（驼峰边界靠大小写），切完再统一小写
    var stem = base
    match (stem.lastIndexOf(".")) {
        case Some(k) => stem = stem[0..k]
        case None => ()
    }
    let toks = nameTokens(stem)
    for (t in toks) {
        for (w in TESTISH_WORDS) {
            if (t == w) { return true }
        }
    }
    var lastSeg = lowerAscii(stem)
    match (lastSeg.lastIndexOf(".")) {
        case Some(k) => lastSeg = lastSeg[k + 1..]
        case None => ()
    }
    for (w in ENTRY_WORDS) {
        if (lastSeg == w) { return true }
    }
    return false
}

/// 把标识符样的名字切成小写词：先按 `_` `-` `.` 空格切，再按驼峰边界切
/// （`FooTests` → foo / tests，`HTTPServer` → http / server，`test_foo` → test / foo）。
func nameTokens(stem: String): ArrayList<String> {
    let rough = ArrayList<String>()
    for (w in stem.split("_")) {
        for (w2 in w.split("-")) {
            for (w3 in w2.split(".")) {
                for (w4 in w3.split(" ")) {
                    if (!w4.isEmpty()) { rough.add(w4) }
                }
            }
        }
    }
    let out = ArrayList<String>()
    for (w in rough) {
        let wb = w.toArray()
        var st: Int64 = 0
        var k: Int64 = 1
        while (k <= Int64(wb.size)) {
            var boundary = k == Int64(wb.size)
            if (!boundary) {
                let cur = wb[k]
                if (cur >= 65 && cur <= 90) {
                    let prev = wb[k - 1]
                    if ((prev >= 97 && prev <= 122) || (prev >= 48 && prev <= 57)) { boundary = true }
                    else if (prev >= 65 && prev <= 90 && k + 1 < Int64(wb.size) && wb[k + 1] >= 97 && wb[k + 1] <= 122) { boundary = true }
                }
            }
            if (boundary) {
                if (k > st) { out.add(lowerAscii(fromUtf8Lossy(wb[st..k]))) }
                st = k
            }
            k += 1
        }
    }
    return out
}

// MARK: - ② 可疑命名

/// 可疑命名：AI 生成代码的高频命名习惯。
/// 判据全部基于**可核验的字符串事实**（精确名或前缀），不做语义猜测。
func detectSuspiciousNames(graph: CodeGraph, findings: ArrayList<Finding>,
                           cap: CapDropCounter): Unit {
    // 精确可疑名（小写比较）
    let exact = HashSet<String>()
    for (n in ["tmp", "temp", "foo", "bar", "baz", "dummy", "placeholder",
        "todo", "fixme", "xxx", "hack", "test1", "test2", "newvar", "oldvar",
        "data1", "data2", "value1", "value2", "func1", "func2"]) {
        exact.add(n)
    }
    let perFile = HashMap<String, Int64>()
    for (f in graph.files) {
        for (s in f.symbols) {
            let lower = lowerAscii(s.name)
            var hit = false
            var why = ""
            if (exact.contains(lower)) {
                hit = true
                why = "占位名"
            } else if (lower.startsWith("new") && lower.size > 3
                && containsUpperHint(s.name, "new")
                && hasCounterpartInFile(f, s.name)) {
                // ⚠️ 首次实跑修：`newDocTargets` 这类合法命名被误报。
                // 收窄为「同文件真的存在去掉 new 后的对应名」才报——
                // 那才是 newXxx/xxx 并存（AI 改代码的痕迹）。
                hit = true
                why = "与既有实现并存的 new 前缀命名（同文件存在对应名）"
            } else if (lower.size == 1 && lower != "i" && lower != "j"
                && lower != "k" && lower != "n" && lower != "x" && lower != "y"
                && lower != "s" && lower != "t" && lower != "e" && lower != "v"
                && lower != "f" && lower != "p" && lower != "q" && lower != "w") {
                hit = true
                why = "单字符名"
            }
            if (!hit) { continue }
            // 每文件限流
            let fc = match (perFile.get(f.relPath)) {
                case Some(v) => v
                case None => 0
            }
            if (fc >= CONF_MAX_PER_KIND_PER_FILE) {
                cap.drop(SuspiciousName, f.relPath)   // 丢弃发生点（cappedKind 真值 + 罚分计入总分）
                continue
            }
            perFile[f.relPath] = fc + 1
            findings.add(Finding(SuspiciousName, f.relPath, s.line, s.name,
                "${symKindId(s.kind)} ${s.name}：${why}"))
        }
    }
}

/// 同文件是否存在去掉 `new` 前缀后的对应名（首字母小写形态）。
/// `newHandler` ↔ `handler`、`new_handler` ↔ `_handler` 都算。
func hasCounterpartInFile(f: FileEntry, name: String): Bool {
    if (name.size <= 3) { return false }
    let rest = name[3..]
    let lowerRest = lowerAscii(rest)
    for (s in f.symbols) {
        let sl = lowerAscii(s.name)
        if (sl == lowerRest || sl == "_" + lowerRest) { return true }
    }
    return false
}

/// 名字里带大小写切换的新/旧前缀判断（newHandler / new_handler）
func containsUpperHint(name: String, prefix: String): Bool {
    if (name.size <= prefix.size) { return false }
    let bytes = name.toArray()
    let p = prefix.toArray()
    var i: Int64 = 0
    while (i < Int64(p.size)) {
        var b = bytes[i]
        if (b >= 65 && b <= 90) { b = b + 32 }
        if (b != p[i]) { return false }
        i += 1
    }
    // 前缀之后是 大写字母（驼峰）或 _ （蛇形）
    let next = bytes[Int64(p.size)]
    return next == 95 || (next >= 65 && next <= 90)
}

// MARK: - ③ TODO 残留

func detectTodos(graph: CodeGraph, findings: ArrayList<Finding>): Unit {
    for (f in graph.files) {
        let content = readFileText("${graph.root}/${f.relPath}")
        match (content) {
            case Some(text) =>
                var todoCount: Int64 = 0
                var firstLine: Int64 = 0
                var firstExcerpt = ""
                var lineNo: Int64 = 0
                for (line in text.lazySplit("\n")) {
                    lineNo += 1
                    if (containsTodo(line)) {
                        todoCount += 1
                        if (firstLine == 0) {
                            firstLine = lineNo
                            firstExcerpt = oneLineClamped(line.trimAscii(), 70)
                        }
                    }
                }
                if (todoCount > 0) {
                    findings.add(Finding(TodoResidue, f.relPath, firstLine, "",
                        "${todoCount} 处 TODO/FIXME/XXX/HACK（首处 L${firstLine}：${firstExcerpt}）"))
                }
            case None => ()
        }
    }
}

/// TODO 标记判定：**注释开头处的可执行标记**。
/// ⚠️ 两版假阳性教训（`AGENTS.md` 不变量 25：禁令词会连自己的免责声明一起抓）：
///   ① 认「独立成词的 TODO」⇒ 命中描述性注释（`// 魔法数字、TODO 残留。`、`// MARK: - ③ TODO 残留`）。
///   ② 只加「后跟 `:`/`(`」⇒ 仍命中**文档里示范标记写法**的行。
/// 现在把判定锚在**结构位置**上：标记必须是注释体（`//`、`#`、`/*`、行首 `*`、`--` 之后）
/// 跳过空白后的**第一个词**，且后跟 `:` 或 `(` 或行尾。这样描述性文字与文档示范都不再命中。
func containsTodo(line: String): Bool {
    let n = Int64(line.size)
    var i: Int64 = 0
    while (i < n) {
        let b = line[i]
        // 注释开头检测
        var after: Int64 = -1
        if (b == 47 && i + 1 < n && line[i + 1] == 47) { after = i + 2 }        // //
        else if (b == 47 && i + 1 < n && line[i + 1] == 42) { after = i + 2 }   // /*
        else if (b == 35) { after = i + 1 }                                     // #
        else if (b == 45 && i + 1 < n && line[i + 1] == 45) { after = i + 2 }   // --
        else if (b == 42 && i == 0) { after = i + 1 }                           // 行首 *
        if (after >= 0) {
            // 跳过空白与装饰字符（/// 的第三个 /、* 装饰）
            var k = after
            while (k < n && (line[k] == 32 || line[k] == 9 || line[k] == 13
                || line[k] == 47 || line[k] == 42)) { k += 1 }
            if (k < n) {
                var j = k
                while (j < n && isIdentByte(line[j])) { j += 1 }
                let word = line[k..j]
                if (word == "TODO" || word == "FIXME" || word == "HACK" || word == "XXX") {
                    var m = j
                    while (m < n && (line[m] == 32 || line[m] == 9 || line[m] == 13)) { m += 1 }
                    if (m >= n) { return true }                 // 行尾裸标记
                    let nb = line[m]
                    if (nb == 58 || nb == 40) { return true }   // ':' 或 '('
                }
            }
        }
        i += 1
    }
    return false
}

// MARK: - ④ AST 节点信号（空体/长度/嵌套/魔法数/吞错）

/// AST 节点按 (file, startLine, endLine, nodeRule) 排序。
/// ⚠️ 必须：限流「每文件每类留哪 6 条」与重复体「报哪一条」都取决于**处理顺序**，
/// 而顺序来自外部 `ast-grep` 进程 —— 不排序的话，报出来的那几条是**外部工具的偶然顺序**决定的
/// （既不确定，也没有原则）。排序后按**代码位置**取前几条，可复现且符合直觉。
func sortAstNodes(nodes: ArrayList<AstNode>): Unit {
    insertionSortBy(nodes, { a, b =>
        if (a.file != b.file) { return a.file < b.file }
        if (a.startLine != b.startLine) { return a.startLine < b.startLine }
        if (a.endLine != b.endLine) { return a.endLine < b.endLine }
        return a.nodeRule < b.nodeRule
    })
}

func detectFromAst(nodes: ArrayList<AstNode>, findings: ArrayList<Finding>,
                   cap: CapDropCounter): Unit {
    sortAstNodes(nodes)
    let perFileKind = HashMap<String, Int64>()   // "file|kind" → count
    // catch 节点自己没有名字：挂到最内层包住它的函数上（原先取到的是 `catch` / `_`）。
    let ownerOfCatch = enclosingFnNames(nodes)
    for (i in 0..Int64(nodes.size)) {
        let n = nodes[i]
        let lines = n.endLine - n.startLine + 1
        // M3 同族：前置声明「无体」是**故意的**，不是占位实现——EmptyType
        // 在 detectTypeSignals 里跳过，stub 判定这里同样要跳过（实测漏网：
        // struct Fwd 不报空类型了，却从 stub-body 出口继续误报）。
        // 前置声明也不可能超长/深嵌套/含魔法数，整节点跳过是安全的。
        if (n.nodeRule == "type" && isForwardDeclaration(n.text)) { continue }
        let name = if (n.nodeRule == "catch") {
            match (ownerOfCatch.get(i)) {
                case Some(v) => v
                case None => ""
            }
        } else {
            nodeName(n)
        }
        // 空体/占位实现：**只看函数节点**。
        // 一个节点原先对所有种类都跑：空 catch 同时报 stub-body + swallowed-error、
        // 空类型同时报 stub-body + empty-type——同一处扣两次分。类型由
        // detectTypeSignals 管（empty-type），catch 由下面的吞错判定管。
        if (n.nodeRule == "fn") {
            match (stubReason(n)) {
                case Some(why) =>
                    bumpFinding(findings, perFileKind, cap, StubBody, n.file, n.startLine,
                        name, "结构节点（${lines} 行）：${why}")
                case None => ()
            }
        }
        // 超长函数
        if (n.nodeRule == "fn" && lines > CONF_LONG_FUNCTION_LINES) {
            bumpFinding(findings, perFileKind, cap, LongFunction, n.file, n.startLine,
                nodeName(n), "${lines} 行（阈值 ${CONF_LONG_FUNCTION_LINES}）——拆分候选")
        }
        // 深嵌套：只数控制语句打开的花括号（函数节点；类型节点的花括号是成员布局）
        if (n.nodeRule == "fn") {
            // 层数从函数体算起（体 = 1 层）：与 CONF_DEEP_NESTING 的既有标度一致（原实现数所有花括号，也含体）
            let depth = maxControlNesting(strippedLines(n.text)) + 1
            if (depth > CONF_DEEP_NESTING) {
                bumpFinding(findings, perFileKind, cap, DeepNesting, n.file, n.startLine,
                    name, "控制流嵌套 ${depth} 层（阈值 ${CONF_DEEP_NESTING}）——if / for / while / try 等控制语句的嵌套；lambda 与字面量的花括号不计")
            }
        }
        // 魔法数字（函数体里）
        if (n.nodeRule == "fn") {
            let magic = countMagicNumbers(n.text)
            if (magic >= CONF_MAGIC_NUMBERS) {
                bumpFinding(findings, perFileKind, cap, MagicNumber, n.file, n.startLine,
                    nodeName(n), "函数体内 ${magic} 处裸数字字面量（≥${CONF_MAGIC_NUMBERS} 时才报）——建议提取常量")
            }
        }
        // 吞错误：catch 块仅只有注释或空
        if (n.nodeRule == "catch") {
            match (swallowedReason(n)) {
                case Some(why) =>
                    bumpFinding(findings, perFileKind, cap, SwallowedError, n.file, n.startLine,
                        name, why)
                case None => ()
            }
        }
    }
}

/// 限流 + 加一条 finding。**唯一的 findings.add 路径**（保证限流无法绕过）。
/// 超限丢弃时递增 cap（cappedKind 的真值来源——只在丢弃判定行计数）。
func bumpFinding(findings: ArrayList<Finding>, perFileKind: HashMap<String, Int64>,
                 cap: CapDropCounter,
                 kind: FlawKind, file: String, line: Int64, symbol: String, evidence: String): Unit {
    let key = "${file}|${flawId(kind)}"
    let c = match (perFileKind.get(key)) {
        case Some(v) => v
        case None => 0
    }
    if (c >= CONF_MAX_PER_KIND_PER_FILE) {
        cap.drop(kind, file)   // 丢弃发生点（cappedKind 真值 + 罚分计入总分）
        return
    }
    perFileKind[key] = c + 1
    findings.add(Finding(kind, file, line, symbol, evidence))
}

/// 节点名：**参数表之前的最后一个标识符**（`fun foo(` / `Type Class::foo(` / `explicit Foo(` /
/// `def __getitem__(` / `fun <T> foo(`）。没有参数表时退到「第一个不是修饰词的标识符」。
/// C++ 运算符重载取 `operator<<` 这样的整体。catch 节点返回空（名字由调用方挂靠所属函数）。
func nodeName(n: AstNode): String {
    if (n.nodeRule == "catch") { return "" }
    // 节点文本可能以文档注释 / 注解 / 修饰符行开头（`/** … */`、`@Composable`、`@MainActor`）：
    // 只看首行会取到 `Composable`、`Main` 这样的词。逐行（最多 12 行）找：
    //   · 函数节点：参数表 `(` 所在的代码行上，`(` 之前的最后一个标识符；
    //   · 类型节点：声明关键词之后的那个词（体里的成员初始化也有括号，不能按括号找）。
    let lines = ArrayList<String>()
    for (l in n.text.lazySplit("\n")) {
        lines.add(l)
        if (Int64(lines.size) >= 12) { break }
    }
    if (n.nodeRule == "type") {
        let byDecl = nameByDeclKeyword(lines)
        if (!byDecl.isEmpty()) { return byDecl }
        return nameByParen(lines)
    }
    let byParen = nameByParen(lines)
    if (!byParen.isEmpty()) { return byParen }
    return nameByDeclKeyword(lines)
}

/// 这一行是不是不算「代码行」：注解、块注释的正文或起始、行注释。
func isNonCodeLine(l: String): Bool {
    let t = l.trimAscii()
    return t.startsWith("@") || t.startsWith("*") || t.startsWith("/*") || t.startsWith("//")
}

/// 参数表 `(` 之前的最后一个标识符（`fun foo(` / `Type Class::foo(` / `explicit Foo(` / `def f(` /
/// `fun <T> foo(`）；C++ 的运算符重载取 `operator<<` 这样的整体。找不到返回空串。
func nameByParen(lines: ArrayList<String>): String {
    for (l in lines) {
        if (isNonCodeLine(l)) { continue }
        let line = stripComment(l)
        var paren: Int64 = -1
        var i: Int64 = 0
        let nb = Int64(line.size)
        while (i < nb) {
            if (line[i] == 40) { paren = i; break }
            i += 1
        }
        if (paren < 0) { continue }
        var j = paren - 1
        while (j >= 0 && (line[j] == 32 || line[j] == 9)) { j -= 1 }
        var k = j
        while (k >= 0 && isIdentByte(line[k])) { k -= 1 }
        let hasWord = k < j
        if (hasWord && line[k + 1..j + 1] == "operator") {
            // `operator()(`
            return line[k + 1..paren]
        }
        if (!hasWord) {
            // `operator<<(` / `operator==(`：标识符被运算符符号隔开，再往前找一个词
            var m = j
            while (m >= 0 && !isIdentByte(line[m])) { m -= 1 }
            var ms = m
            while (ms >= 0 && isIdentByte(line[ms])) { ms -= 1 }
            if (m >= 0 && line[ms + 1..m + 1] == "operator") {
                return line[ms + 1..paren]
            }
        }
        if (hasWord) {
            let cand = line[k + 1..j + 1]
            if (!NODE_NAME_NOISE.contains(cand)) { return cand }
        }
    }
    return ""
}

/// 声明关键词之后的第一个不是修饰词的标识符（`class Foo` / `object Bar` / `enum class P` /
/// `struct S`）。找不到返回空串。
func nameByDeclKeyword(lines: ArrayList<String>): String {
    for (l in lines) {
        let t = l.trimAscii()
        if (t.startsWith("*") || t.startsWith("/*") || t.startsWith("//")) { continue }
        let toks = tokenize(stripComment(l))
        var k: Int64 = 0
        while (k < Int64(toks.size)) {
            var isDecl = false
            for (d in DECL_NAME_WORDS) {
                if (toks[k] == d) { isDecl = true; break }
            }
            if (isDecl) {
                var m = k + 1
                while (m < Int64(toks.size)) {
                    if (!NODE_NAME_NOISE.contains(toks[m])) { return toks[m] }
                    m += 1
                }
            }
            k += 1
        }
    }
    return ""
}

/// 每个 catch 节点 → 最内层包住它的函数的名字（键 = 排序后 nodes 的下标）。
func enclosingFnNames(nodes: ArrayList<AstNode>): HashMap<Int64, String> {
    let out = HashMap<Int64, String>()
    let fnIdxByFile = HashMap<String, ArrayList<Int64>>()
    for (i in 0..Int64(nodes.size)) {
        if (nodes[i].nodeRule != "fn") { continue }
        match (fnIdxByFile.get(nodes[i].file)) {
            case Some(l) => l.add(i)
            case None =>
                let l = ArrayList<Int64>()
                l.add(i)
                fnIdxByFile[nodes[i].file] = l
        }
    }
    for (i in 0..Int64(nodes.size)) {
        if (nodes[i].nodeRule != "catch") { continue }
        let c = nodes[i]
        var best: Int64 = -1
        var bestSpan: Int64 = 0
        match (fnIdxByFile.get(c.file)) {
            case Some(list) =>
                for (j in list) {
                    let f = nodes[j]
                    if (f.startLine <= c.startLine && f.endLine >= c.endLine) {
                        let span = f.endLine - f.startLine
                        if (best < 0 || span < bestSpan) {
                            best = j
                            bestSpan = span
                        }
                    }
                }
            case None => ()
        }
        if (best >= 0) { out[i] = nodeName(nodes[best]) }
    }
    return out
}

/// 路径里有测试目录段（test / tests / jvmTest / __tests__ / Tests …）：测试代码由测试框架驱动，
/// 里面的辅助符号没有调用点是正常的（与 isEntryLike 的文件名豁免同一条政策的路径版——
/// 只看文件名会漏掉 `jvmTest/…/SkinContrastAudit.kt` 这种文件名里没有 test 的测试类）。
func isTestPath(relPath: String): Bool {
    let lower = lowerAscii(relPath)
    var start: Int64 = 0
    let n = Int64(lower.size)
    var i: Int64 = 0
    while (i <= n) {
        if (i == n || lower[i] == 47) {
            let seg = lower[start..i]
            if (seg == "test" || seg == "tests" || seg == "jvmtest" || seg == "unittest"
                || seg == "testing" || seg == "__tests__" || seg == "xctest" || seg == "specs"
                || seg == "spec" || seg == "testdata" || seg == "fixtures") {
                return true
            }
            start = i + 1
        }
        i += 1
    }
    return false
}

/// C 系文件里每个标识符的出现次数（注释与字符串不算）。只在遇到非限定枚举时才懒算一次。
func cIdentifierCounts(graph: CodeGraph): HashMap<String, Int64> {
    let counts = HashMap<String, Int64>()
    for (f in graph.files) {
        if (f.lang != "c") { continue }
        let content = readFileText(graph.root + "/" + f.relPath)
        match (content) {
            case Some(text) =>
                var strState: Int64 = 0
                for (line in text.lazySplit("\n")) {
                    let (t, ns) = stripCode(line, strState)
                    strState = ns
                    for (tok in tokenize(t)) {
                        match (counts.get(tok)) {
                            case Some(v) => counts[tok] = v + 1
                            case None => counts[tok] = 1
                        }
                    }
                }
            case None => ()
        }
    }
    return counts
}

/// 非限定枚举（`enum Color { Red, Green }`，没有 class）的任一枚举项在枚举体**之外**出现过。
/// 限定枚举（`enum class`）必须写类型名，不适用。
func unscopedEnumIsUsed(root: String, counts: HashMap<String, Int64>, f: FileEntry, s: SymDecl): Bool {
    let content = readFileText(root + "/" + f.relPath)
    match (content) {
        case Some(text) =>
            let lines = text.split("\n")
            var i = s.line - 1
            var strState: Int64 = 0
            var started = false
            var scoped = false
            var guardN: Int64 = 0
            let bodySb = StringBuilder()
            while (i < Int64(lines.size) && guardN < 80) {
                guardN += 1
                let (t0, ns) = stripCode(lines[i], strState)
                strState = ns
                var t = t0
                if (!started) {
                    if (hasWord(t, "class")) { scoped = true }
                    var brace: Int64 = -1
                    match (t.indexOf("{")) {
                        case Some(k) => brace = k
                        case None => ()
                    }
                    if (brace < 0) {
                        i += 1
                        continue
                    }
                    started = true
                    t = t[brace + 1..]
                }
                bodySb.append(t)
                bodySb.append("\n")
                if (t.contains("}")) { break }
                i += 1
            }
            let body = bodySb.toString()
            if (!started || scoped) { return false }
            for (part in body.split(",")) {
                // 每一段开头的标识符就是枚举项（`Red`、`Green = 3`；`} reason = none;` 不算）
                let pb = part.trimAscii().toArray()
                var en: Int64 = 0
                while (en < Int64(pb.size) && isIdentByte(pb[en])) { en += 1 }
                if (en == 0) { continue }
                let name = fromUtf8Lossy(pb[0..en])
                var total: Int64 = 0
                match (counts.get(name)) {
                    case Some(v) => total = v
                    case None => ()
                }
                var inBody: Int64 = 0
                for (tok in tokenize(body)) {
                    if (tok == name) { inBody += 1 }
                }
                if (total > inBody) { return true }
            }
        case None => ()
    }
    return false
}

/// 节点的块体与它在节点文本里的起点。
/// 起点用来把块体内的行号映回文件行号（原实现把块体首行一律记成 startLine + 1，
/// 头部与 `{` 同行时整体错一行）。
struct NodeBody {
    let text: String
    let startOffset: Int64
    init(text: String, startOffset: Int64) {
        this.text = text
        this.startOffset = startOffset
    }
}

/// 节点有没有块体、块体是什么——**三种形态必须分开**：
///   · 花括号块：参数表 `)` 之后的第一个 `{` 到末 `}`；
///   · 缩进块（Python）：`def` / `except` 行之后缩进更深的连续行；
///   · 没有块体：表达式体（`fun f(x) = expr`、`(x) => expr`）或无体声明（接口 / 抽象方法）。
///
/// 【为什么必须有这一步】旧 bodyText 的规则是「有 `{` 取花括号之间，否则丢首行取剩余，再否则
/// 空串」。实测 deepDolphin 语法树档：stub-body 104 条里 76 条是 Kotlin——
/// 表达式体 `fun f(x) = expr` 与无体的接口方法签名都没有 `{`，体被取成空串，整类报成
/// 「函数体为空」（权重 12，占列出罚分 31%）；Python 函数体里的 `x = {}` / f-string
/// 让花括号分支命中，97 行的函数也被报「函数体为空」。
func bodyOf(text: String, file: String, skipParams!: Bool = true): Option<NodeBody> {
    let r = if (file.endsWith(".py")) { pythonBodyRange(text) } else { blockBodyRange(text, skipParams) }
    if (r[0] >= 0) { return Some(NodeBody(text[r[0]..r[1]], r[0])) }
    return None
}

/// 块体首行所在的文件行号。
func bodyFirstLine(n: AstNode): Int64 {
    match (bodyOf(n.text, n.file)) {
        case Some(b) =>
            var nl: Int64 = 0
            for (i in 0..b.startOffset) {
                if (n.text[i] == 10) { nl += 1 }
            }
            return n.startLine + nl
        case None => n.startLine
    }
}

/// 代码区（跳过字符串 / 字符字面量 / 行注释 / 块注释）里从 [from] 起找 `want` 字节；-1 = 没有。
func codeIndexOf(text: String, from: Int64, want: UInt8): Int64 {
    let b = text.toArray()
    let n = Int64(b.size)
    var i = from
    var state: Int64 = 0   // 0 代码；1 "串；2 '串
    while (i < n) {
        let c = b[i]
        if (state == 0) {
            if (c == 34 && i + 2 < n && b[i + 1] == 34 && b[i + 2] == 34) {
                // Kotlin 原始串 """…"""（Python 不走这条路）
                i += 3
                while (i + 2 < n && !(b[i] == 34 && b[i + 1] == 34 && b[i + 2] == 34)) { i += 1 }
                i += 3
                continue
            }
            if (c == 34) { state = 1 }
            else if (c == 39) { state = 2 }
            else if (c == 47 && i + 1 < n && b[i + 1] == 47) {
                while (i < n && b[i] != 10) { i += 1 }
                continue
            } else if (c == 47 && i + 1 < n && b[i + 1] == 42) {
                i += 2
                while (i + 1 < n && !(b[i] == 42 && b[i + 1] == 47)) { i += 1 }
                i += 2
                continue
            } else if (c == want) { return i }
        } else {
            if (c == 92) { i += 2; continue }
            if ((state == 1 && c == 34) || (state == 2 && c == 39)) { state = 0 }
        }
        i += 1
    }
    return -1
}

/// 参数表右括号 `)` 的位置（首个顶层 `(` 的配对）；没有参数表 = -1。
func paramListClose(text: String): Int64 {
    let b = text.toArray()
    let n = Int64(b.size)
    var i: Int64 = 0
    var depth: Int64 = 0
    var state: Int64 = 0
    while (i < n) {
        let c = b[i]
        if (state == 0) {
            if (c == 34) { state = 1 }
            else if (c == 39) { state = 2 }
            else if (c == 47 && i + 1 < n && b[i + 1] == 47) {
                while (i < n && b[i] != 10) { i += 1 }
                continue
            } else if (c == 40) {
                depth += 1
            } else if (c == 41) {
                depth -= 1
                if (depth == 0) { return i }
            }
        } else {
            if (c == 92) { i += 2; continue }
            if ((state == 1 && c == 34) || (state == 2 && c == 39)) { state = 0 }
        }
        i += 1
    }
    return -1
}

/// 花括号块的范围 [start, end)：**参数表之后**的第一个 `{` 的下一个字节，到末 `}`。
/// 先跳过参数表：TS 的 `function f(a: {x: number} = {}): void {`、Kotlin 的
/// `whyNot: (String) -> Unit = {}` 参数表里就有花括号，从全文本的首 `{` 起切会把
/// 参数表当成体、真正的体当成「体之后的东西」。
func blockBodyRange(text: String, skipParams: Bool): Array<Int64> {
    // 类型节点不跳参数表：Kotlin 的 object / class 体里第一个括号可能是成员初始化
    // （`val open = MutableStateFlow(false)`）——跳过它就再也找不到 `{`，整个类型被报成空类型
    let close = if (skipParams) { paramListClose(text) } else { -1 }
    let from = if (close >= 0) { close + 1 } else { 0 }
    let open = codeIndexOf(text, from, 123)
    if (open < 0) { return [-1, -1] }
    let b = text.toArray()
    var last: Int64 = -1
    var i = Int64(b.size) - 1
    while (i > open) {
        if (b[i] == 125) { last = i; break }
        i -= 1
    }
    if (last <= open) { return [-1, -1] }
    return [open + 1, last]
}

/// Python 缩进块的范围 [start, end)：`def` / `class` / `except` 行之后、缩进更深的连续行。
/// 节点文本可能带着装饰器（`@foo` 是 function_definition 的子节点）：声明行不是首行时
/// 缩进基准取声明行，否则基准 0 立刻终止、体又被取成空串。
func pythonBodyRange(text: String): Array<Int64> {
    let b = text.toArray()
    let n = Int64(b.size)
    // 行表：行首 / 行尾（行尾不含换行）
    let starts = ArrayList<Int64>()
    let ends = ArrayList<Int64>()
    var i: Int64 = 0
    var st: Int64 = 0
    while (i <= n) {
        if (i == n || b[i] == 10) {
            starts.add(st)
            ends.add(i)
            st = i + 1
        }
        i += 1
    }
    if (starts.size == 1) {
        // 单行：最后一个 ':' 之后（注解里的冒号在左，体在右）
        var last: Int64 = -1
        i = 0
        while (i < n) {
            if (b[i] == 58) { last = i }
            i += 1
        }
        if (last < 0 || last + 1 >= n) { return [-1, -1] }
        return [last + 1, n]
    }
    var header: Int64 = 0
    for (k in 0..Int64(starts.size)) {
        var j = starts[k]
        while (j < ends[k] && (b[j] == 32 || b[j] == 9)) { j += 1 }
        if (codeStartsWith(b, j, "def ") || codeStartsWith(b, j, "class ")
            || codeStartsWith(b, j, "except") || codeStartsWith(b, j, "async def ")) {
            header = k
            break
        }
    }
    let base = indentWidth(b, starts[header], ends[header])
    var lastKept = header
    for (k in header + 1..Int64(starts.size)) {
        if (indentWidth(b, starts[k], ends[k]) <= base) { break }
        lastKept = k
    }
    if (lastKept == header) { return [ends[header] + 1, ends[header] + 1] }
    return [starts[header + 1], ends[lastKept]]
}

func codeStartsWith(b: Array<UInt8>, at: Int64, word: String): Bool {
    let w = word.toArray()
    if (at < 0 || at + Int64(w.size) > Int64(b.size)) { return false }
    for (k in 0..Int64(w.size)) {
        if (b[at + k] != w[k]) { return false }
    }
    return true
}

/// 行首缩进宽度（Tab 记 8）。全空白的行返回一个极大值——空行不终止块。
func indentWidth(b: Array<UInt8>, from: Int64, to: Int64): Int64 {
    var w: Int64 = 0
    var i = from
    while (i < to) {
        if (b[i] == 32) { w += 1 }
        else if (b[i] == 9) { w += 8 }
        else { return w }
        i += 1
    }
    return 1 << 40
}

/// 占位实现判定：结构级空体（不是「短」而是「什么都没有」）。
/// 块体为空、只有占位语句、或只有常量占位返回 ⇒ 占位实现。
/// 没有块体时只有「整个表达式就是占位值」（`= TODO()`、`=> undefined`）才算。
func stubReason(n: AstNode): Option<String> {
    match (bodyOf(n.text, n.file)) {
        case Some(body) =>
            // 空花括号（容许注释）
            let stripped = removeCommentsAndBlanks(body.text)
            if (stripped.isEmpty()) {
                // C++ 带成员初始化列表、体为空的构造函数（`AgentCore(const QString &bin) : m_bin(bin) { }`）
                // 是在做数据初始化，不是占位——实测 deepDolphin 剩余 stub-body 里 13/14 是它
                if (detectLang(n.file) == "c" && hasInitializerList(n.text)) { return None }
                return Some("函数体为空")
            }
            // 只有 pass / return nil / return None / return / {} / 单条 return
            let t = stripped.trimAscii()
            if (t == "pass" || t == "..." || t == "{}" || t == "()") {
                return Some("占位语句（${t}）")
            }
            if (PLACEHOLDER_RETURNS.contains(t)) {
                return Some("常量占位返回（${t}）")
            }
            for (call in PLACEHOLDER_CALLS) {
                if (t.startsWith(call)) {
                    return Some("占位调用（${call}…）")
                }
            }
            return None
        case None =>
            match (expressionBodyOf(n.text)) {
                case Some(expr) =>
                    if (PLACEHOLDER_EXPRS.contains(expr)) {
                        return Some("占位表达式（${expr}）")
                    }
                    return None
                case None => return None
            }
    }
}

/// 表达式体：参数表之后以 `=` 起头的那个表达式（去掉空白与结尾分号）。
/// C++ 的 `= 0` / `= default` / `= delete` 是声明，不是表达式体；`->` 是返回类型。
func expressionBodyOf(text: String): Option<String> {
    let close = paramListClose(text)
    let b = text.toArray()
    let n = Int64(b.size)
    var i = if (close >= 0) { close + 1 } else { 0 }
    while (i < n && (b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13)) { i += 1 }
    if (i >= n) { return None }
    // Kotlin / Swift 的返回类型标注 `): Map<String, Int> = expr`：跳到类型之后的顶层等号
    if (b[i] == 58 && (i + 1 >= n || b[i + 1] != 58)) {
        var depth: Int64 = 0
        var state: Int64 = 0
        i += 1
        while (i < n) {
            let c = b[i]
            if (state == 0) {
                if (c == 34 || c == 39) { state = Int64(c) }
                else if (c == 60 || c == 40 || c == 91 || c == 123) { depth += 1 }
                else if (c == 62 || c == 41 || c == 93 || c == 125) {
                    if (depth > 0) { depth -= 1 }
                } else if (c == 61 && depth == 0) { break }
            } else {
                if (c == 92) { i += 2; continue }
                if (Int64(c) == state) { state = 0 }
            }
            i += 1
        }
        while (i < n && (b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13)) { i += 1 }
    }
    if (i >= n) { return None }
    if (b[i] != 61) { return None }
    // `==` / `=>` 不是表达式体的等号
    if (i + 1 < n && (b[i + 1] == 61 || b[i + 1] == 62)) { return None }
    var j = i + 1
    while (j < n && (b[j] == 32 || b[j] == 9 || b[j] == 10 || b[j] == 13)) { j += 1 }
    var e = n
    while (e > j && (b[e - 1] == 32 || b[e - 1] == 9 || b[e - 1] == 10 || b[e - 1] == 13
        || b[e - 1] == 59)) { e -= 1 }
    if (e <= j) { return None }
    let raw = fromUtf8Lossy(b[j..e])
    for (w in ["0", "default", "delete", "pure", "NULL", "std::nullptr"]) {
        if (raw == w) { return None }
    }
    let rb = raw.toArray()
    let sb = ArrayList<UInt8>()
    for (c in rb) {
        if (c != 32 && c != 9 && c != 10 && c != 13) { sb.add(c) }
    }
    return Some(fromUtf8Lossy(sb.toArray()))
}

/// 去掉注释行与空白后剩下的内容（用于空体判定）。
/// 启发式：按行过滤「整行注释」与空行，把剩余行拼接。行尾注释不剥 ——
/// 行尾注释后必然还有代码，不影响「是否为空」的判定。
/// 是否在块注释里由跨行状态决定（stripCommentTracked）：块注释里的行整行是注释，
/// 块注释外的行首 `*`（`*out = x;`）是代码。
func removeCommentsAndBlanks(text: String): String {
    let sb = StringBuilder()
    var inBlock = false
    for (line in text.lazySplit("\n")) {
        let (stripped, stillInBlock) = stripCommentTracked(line, inBlock)
        inBlock = stillInBlock
        let t = stripped
        if (blankLine(t)) { continue }
        for (c in t) {
            let ch = Int64(c)
            // 括号与空格不算「内容」；只要有别的可打印字符就算非空
            if (c == 123 || c == 125 || c == 40 || c == 41 || c == 32 || c == 9 || c == 13) {
                continue
            }
            sb.append(fromUtf8Lossy([c]))
        }
    }
    return sb.toString()
}

/// 打开控制语句花括号的关键词。
let CONTROL_KEYWORDS: Array<String> = ["if", "else", "for", "while", "when", "switch", "try", "catch",
    "match", "do", "loop", "elif", "select", "except"]

/// 控制流嵌套深度：只数由控制语句（if / else / for / while / when / switch / try / catch / match / do）
/// 打开的花括号；lambda 容器、集合 / 对象字面量、SwiftUI 的 `VStack { }`、Compose 的 `Column { }` 不计。
///
/// 【为什么】原实现数**所有**花括号：SwiftUI 的视图结构体嵌 10 层（`ProjectDetailView`）、
/// 3 行的 range-for 被报「嵌套 8 层」（deepDolphin 抽样 8 条里 3 条是类型节点、其余是声明式布局）。
/// 「深嵌套」说的是命令式控制流绕晕了人，不是布局容器摞得高。
/// 输入是**已剥注释与字符串**的代码行。
func maxControlNesting(codeLines: ArrayList<String>): Int64 {
    var best: Int64 = 0
    var ctrl: Int64 = 0                 // 当前未闭合的控制花括号数
    let stack = ArrayList<Bool>()       // 每个未闭合的 `{` 是不是控制语句打开的
    var pending = false                 // 见过控制关键词、还没等到它的 `{`（条件可以跨行）
    for (t in codeLines) {
        let b = t.toArray()
        let n = Int64(b.size)
        var i: Int64 = 0
        var sawKeywordAt: Int64 = -1
        while (i < n) {
            let c = b[i]
            if (isIdentByte(c)) {
                let st = i
                while (i < n && isIdentByte(b[i])) { i += 1 }
                let w = fromUtf8Lossy(b[st..i])
                for (k in CONTROL_KEYWORDS) {
                    if (w == k) {
                        if (sawKeywordAt < 0) { sawKeywordAt = st }
                        pending = true
                        break
                    }
                }
                continue
            }
            if (c == 123) {
                stack.add(pending)
                if (pending) {
                    ctrl += 1
                    if (ctrl > best) { best = ctrl }
                }
                pending = false
            } else if (c == 125) {
                if (stack.size > 0) {
                    let wasCtrl = stack[stack.size - 1]
                    stack.remove(at: stack.size - 1)
                    if (wasCtrl) {
                        ctrl -= 1
                        if (ctrl < 0) { ctrl = 0 }
                    }
                }
            }
            i += 1
        }
        // 行尾还挂着「待开」的控制标记：只有条件确实跨行（`if (a &&`、`if (f(x))`）才带到下一行；
        // 不带花括号的单语句 `if (x) foo()` 已经写完，下一行的 `{` 多半是 lambda 的，不算
        if (pending && sawKeywordAt >= 0) {
            let tail = t.trimAscii()
            var keep = false
            if (tail.endsWith("&&") || tail.endsWith("||") || tail.endsWith("?:") || tail.endsWith("->")
                || tail.endsWith("=>") || tail.endsWith(",")) { keep = true }
            if (tail == "else" || tail == "do" || tail == "try" || tail == "loop"
                || tail == "finally" || tail.endsWith(" else")) { keep = true }
            if (tail.endsWith(")") && conditionOnlyAfter(t, sawKeywordAt)) { keep = true }
            pending = keep
        }
    }
    return best
}

/// 关键词之后是不是只有一个完整的括号组（条件本身），并且一直延伸到行尾。
func conditionOnlyAfter(t: String, from: Int64): Bool {
    let b = t.toArray()
    let n = Int64(b.size)
    var depth: Int64 = 0
    var groups: Int64 = 0
    var afterGroup = false
    var i = from
    while (i < n) {
        let c = b[i]
        if (c == 40) {
            if (depth == 0) { groups += 1 }
            depth += 1
        } else if (c == 41) {
            depth -= 1
            if (depth == 0) { afterGroup = true }
        } else if (depth == 0 && c != 32 && c != 9) {
            if (afterGroup) { return false }     // 括号组之后还有别的东西（一条语句）
        }
        i += 1
    }
    return depth == 0 && groups == 1
}

/// 逐行剥注释与字符串（跨行携带状态）。
func strippedLines(text: String): ArrayList<String> {
    let out = ArrayList<String>()
    var strState: Int64 = 0
    for (raw in text.lazySplit("\n")) {
        let (t, ns) = stripCode(raw, strState)
        strState = ns
        out.add(t)
    }
    return out
}

/// 豁免值（不属于「魔法数」的常见常量）。模块级预计算一次。
func buildMagicExempt(): HashSet<String> {
    let exempt = HashSet<String>()
    for (v in ["0", "1", "2", "10", "100", "1000", "60", "24", "1024",
        "255", "360", "365", "12", "7", "30"]) {
        exempt.add(v)
    }
    return exempt
}

let MAGIC_EXEMPT: HashSet<String> = buildMagicExempt()

/// 逐行魔法数计数（输入必须是**已剥注释**的代码行）。AST 与词法路径共用同一口径。
/// 判据：连续数字串、前一个字符非标识符、非小数尾、值不在豁免表。
func magicCountInLine(t: String): Int64 {
    if (blankLine(t)) { return 0 }
    let n = Int64(t.size)
    var count: Int64 = 0
    var i: Int64 = 0
    while (i < n) {
        let b = t[i]
        if (b >= 48 && b <= 57) {
            // 前一个字符若是标识符字符或 '.'（如 x2 / 1.5 的小数部分）→ 跳过
            let prevIdent = if (i > 0) {
                let p = t[i - 1]
                isIdentByte(p) || p == 46    // '.'
            } else { false }
            var j = i
            while (j < n && ((t[j] >= 48 && t[j] <= 57) || t[j] == 46 || t[j] == 95)) { j += 1 }
            if (!prevIdent) {
                let lit = t[i..j]
                // 十六进制/后缀不算（0x、f16），浮点小数尾不算（前有 '.' 已排）
                if (!lit.isEmpty() && !MAGIC_EXEMPT.contains(lit) && !lit.contains(".")) {
                    count += 1
                }
            }
            i = j
        } else {
            i += 1
        }
    }
    return count
}

/// 魔法数字计数：裸数字字面量，排除注释行（供 AST 路径对节点文本计数）。
/// 块注释状态跨行跟踪（`/* 42\n * 7\n */` 两行都是注释）。
func countMagicNumbers(text: String): Int64 {
    // 剥注释**和字符串**（与词法路径同一口径）：原先只剥注释，`"#%02x%02x%02x"` 里的 02 被数成
    // 3 个魔法数（评估文档 B10——两条路径对同一个函数给出不同结论）
    var count: Int64 = 0
    var strState: Int64 = 0
    for (line in text.lazySplit("\n")) {
        let (stripped, nextState) = stripCode(line, strState)
        strState = nextState
        count += magicCountInLine(stripped)
    }
    return count
}

/// 吞错误判定：catch 体去掉注释/空白后为空，或只有 pass。
func swallowedReason(n: AstNode): Option<String> {
    // 没有块体就没有「吞」可言
    match (bodyOf(n.text, n.file)) {
        case Some(body) =>
            let stripped = removeCommentsAndBlanks(body.text)
            let t = stripped.trimAscii()
            if (t.isEmpty() || t == "pass" || t == "...") {
                return Some("catch/except 块内没有任何处理——错误被静默吞掉")
            }
            return None
        case None => return None
    }
}

// MARK: - ⑤ 重复函数体

/// 完全相同的函数体（去注释/空白后逐字节相同，长度 ≥ 阈值）。
/// AI 复制粘贴的高频形态；同一个 bug 会有 N 份。
func detectDuplicateBodies(nodes: ArrayList<AstNode>, findings: ArrayList<Finding>): Unit {
    sortAstNodes(nodes)
    let byHash = HashMap<String, ArrayList<AstNode>>()
    for (n in nodes) {
        if (n.nodeRule != "fn") { continue }
        // 哈希体（不含声明行）——否则函数名不同就哈希不同，重复体永远检测不到
        // 没有块体（表达式体 / 无体声明）不参与重复体比较
        var body = ""
        match (bodyOf(n.text, n.file)) {
            case Some(b) => body = removeCommentsAndBlanks(b.text)
            case None => continue
        }
        if (Int64(body.size) < CONF_DUP_BODY_BYTES) { continue }   // 太短的不算（getter/setter 天然像）
        let h = sha256HexOf(body)
        match (byHash.get(h)) {
            case Some(list) => list.add(n)
            case None =>
                let list = ArrayList<AstNode>()
                list.add(n)
                byHash[h] = list
        }
    }
    for ((_, group) in byHash) {
        if (group.size < 2) { continue }
        // 报第一条，证据里列其余位置
        let first = group[0]
        let others = ArrayList<String>()
        var i = 1
        while (i < Int64(group.size) && i < 5) {
            others.add("${group[i].file}:${group[i].startLine}")
            i += 1
        }
        let more = if (Int64(group.size) > 5) { " 等 ${Int64(group.size) - 1} 处" } else { "" }
        findings.add(Finding(DuplicateBody, first.file, first.startLine, nodeName(first),
            "与该函数体完全相同的还有：${joinStrings(others, "、")}${more}——"
            + "同体多份，修 bug 时要改 N 个地方"))
    }
}

// MARK: - 降级路径：词法级函数信号（无 AST 时）

/// 词法级函数信号：按「声明行 + 花括号配平」推函数体边界（只对 C 系花括号
/// 语言有效；python 缩进体不在此列，如实少报而不是乱报）。
///
/// 产出 **长度 / 空体 / 深嵌套 / 魔法数** —— 让**没有 tree-sitter 语法的语言
/// （仓颉！）也能拿到这四种函数级信号**，而不是只剩「超长函数」。
/// 吞错与重复体依赖 AST 节点边界，词法路径不产出（避免乱报）。
///
/// `astUsed=true` 时只补跑 AST **覆盖不到**的语言（否则同一处会被两条路各报一次）。
func detectLexicalFunctionSignals(graph: CodeGraph, findings: ArrayList<Finding>,
                                  astUsed: Bool, cap: CapDropCounter): Unit {
    let perFileKind = HashMap<String, Int64>()
    for (f in graph.files) {
        // 按语法上可能有花括号体的语言做
        if (!braceLang(f.lang)) { continue }
        // 有 AST 覆盖（且本轮 AST 可用）的语言交给 detectFromAst，避免重复
        if (astUsed && !astGrepLang(f.lang).isEmpty()) { continue }
        let content = readFileText("${graph.root}/${f.relPath}")
        match (content) {
            case Some(text) =>
                var lineNo: Int64 = 0
                var pendingStub: Option<(String, Int64)> = None
                var depth: Int64 = 0
                var baseDepth: Int64 = 0
                // 函数体的代码行（已剥注释与字符串）——收尾时数控制流嵌套
                var bodyCode = ArrayList<String>()
                var bodyLines: Int64 = 0
                var bodyMagic: Int64 = 0
                var bodyHadContent = false
                var bodyStarted = false
                var strState: Int64 = 0
                for (line in text.lazySplit("\n")) {
                    lineNo += 1
                    // stripCode 同时剥注释与字符串（含跨行状态），花括号计数才准
                    let (t, nextState) = stripCode(line, strState)
                    strState = nextState
                    // 声明行（在深度 0 处、且当前没有待跟随的声明）
                    if (depth == 0 && !bodyStarted) {
                        match (scanDeclLine(tokenize(t))) {
                            case Some((kind, name)) =>
                                var isFunc = false
                                match (kind) {
                                    case Func => isFunc = true
                                    case _ => ()
                                }
                                if (isFunc) {
                                    pendingStub = Some((name, lineNo))
                                    bodyLines = 0
                                    bodyMagic = 0
                                    bodyHadContent = false
                                    bodyStarted = false
                                    bodyCode = ArrayList<String>()
                                }
                            case None => ()
                        }
                    }
                    let opens = braceOpenCount(t)
                    let closes = braceCloseCount(t)
                    // 体开始：第一个 '{' 出现在「待跟随声明之后」的任意行
                    if (!bodyStarted && pendingStub.isSome() && opens > 0 && depth == 0) {
                        bodyStarted = true
                        baseDepth = depth
                        // 同行体（func f() { ... }）：只取 { 与 } 之间的部分判内容
                        if (opens == closes) {
                            let inner = betweenBraces(t)
                            if (!blankLine(inner) && !inner.trimAscii().isEmpty()) {
                                bodyHadContent = true
                            }
                        } else {
                            let after = afterFirstBrace(t)
                            if (!blankLine(after) && !after.trimAscii().isEmpty()) {
                                bodyHadContent = true
                            }
                        }
                    } else if (bodyStarted) {
                        bodyLines += 1
                        let trimmed = t.trimAscii()
                        if (!blankLine(t) && trimmed != "{" && trimmed != "}") {
                            bodyHadContent = true
                        }
                    }
                    depth += opens - closes
                    if (depth < 0) { depth = 0 }
                    // 体内统计 + 魔法数（口径与 AST 路径一致）；嵌套深度在收尾时按控制流数
                    if (bodyStarted) {
                        bodyCode.add(t)
                        bodyMagic += magicCountInLine(t)
                    }
                    // 收尾：体真的开始过、且配平回 0
                    if (depth == 0 && bodyStarted) {
                        match (pendingStub) {
                            case Some((name, ln)) =>
                                if (!bodyHadContent) {
                                    bumpFinding(findings, perFileKind, cap, StubBody, f.relPath, ln,
                                        name, "函数体（词法判定）内无可执行内容——占位实现候选")
                                } else {
                                    if (bodyLines > CONF_LONG_FUNCTION_LINES) {
                                        bumpFinding(findings, perFileKind, cap, LongFunction, f.relPath, ln,
                                            name, "约 ${bodyLines} 行（词法近似；阈值 ${CONF_LONG_FUNCTION_LINES}）")
                                    }
                                    // 层数从函数体算起（体 = 1 层），与 AST 路径同一标度
                                    let maxRel = maxControlNesting(bodyCode) + 1
                                    if (maxRel > CONF_DEEP_NESTING) {
                                        bumpFinding(findings, perFileKind, cap, DeepNesting, f.relPath, ln,
                                            name, "控制流嵌套 ${maxRel} 层（词法近似；阈值 ${CONF_DEEP_NESTING}）——if / for / while / try 等控制语句的嵌套；lambda 与字面量的花括号不计")
                                    }
                                    if (bodyMagic >= CONF_MAGIC_NUMBERS) {
                                        bumpFinding(findings, perFileKind, cap, MagicNumber, f.relPath, ln,
                                            name, "函数体内 ${bodyMagic} 处裸数字字面量（词法近似；≥${CONF_MAGIC_NUMBERS} 时才报）——建议提取常量")
                                    }
                                }
                            case None => ()
                        }
                        pendingStub = None
                        bodyStarted = false
                        bodyMagic = 0
                        bodyCode = ArrayList<String>()
                    }
                }
            case None => ()
        }
    }
}

/// 行内 `{` 个数（已剥注释与字符串）
func braceOpenCount(t: String): Int64 {
    var n: Int64 = 0
    for (b in t) {
        if (b == 123) { n += 1 }
    }
    return n
}

/// 行内 `}` 个数
func braceCloseCount(t: String): Int64 {
    var n: Int64 = 0
    for (b in t) {
        if (b == 125) { n += 1 }
    }
    return n
}

/// 第一个 `{` 之后的内容
func afterFirstBrace(t: String): String {
    let n = Int64(t.size)
    var i: Int64 = 0
    while (i < n) {
        if (t[i] == 123) { return t[i + 1..] }
        i += 1
    }
    return ""
}

/// 首对 `{ ... }` 之间的内容（同行体）
func betweenBraces(t: String): String {
    let n = Int64(t.size)
    var open: Int64 = -1
    var close: Int64 = -1
    var i: Int64 = 0
    while (i < n) {
        if (open < 0 && t[i] == 123) { open = i }
        if (t[i] == 125 && open >= 0) { close = i }
        i += 1
    }
    if (open >= 0 && close > open) { return t[open + 1..close] }
    return ""
}

func braceLang(lang: String): Bool {
    // python 无花括号体；ts 的箭头函数混排这里近似会误报，只收「结构清晰」的几种
    return lang == "c" || lang == "java" || lang == "kotlin" || lang == "rust"
        || lang == "go" || lang == "swift" || lang == "cangjie" || lang == "ts"
}

// MARK: - 幻觉调用 / 未使用 import / 注释掉的代码

/// 幻觉调用：自由函数调用 `name(`，名字全仓没有同语言的定义、非内建。
/// AI 生成代码的标志性病症——编造不存在的 API。
///
/// 【证据来源（阶段二 B）】`graph.unresolvedCalls` = 解析后的调用点里 dst 为空的那些行
/// （build.cj 的 unresolvedCallsFrom；与 codegraph.db 的 sites.dst = 0 同一批行）。
/// 此前这里是 build.cj 里另一遍「按行猜调用」的扫描：不认声明——嵌套函数的 `def f(`、
/// 默认实参里的 `frozenset(`、关键字 `def` 后面的名字都被当成调用；自带的关键词 / 内建
/// 表也和解析阶段的那份不一致。现在只有一份口径，置信度与索引对「未解析」的说法一致。
func detectUnresolvedCalls(graph: CodeGraph, findings: ArrayList<Finding>,
                           cap: CapDropCounter): Unit {
    let perFile = HashMap<String, Int64>()
    if (graph.unresolvedCalls.size == 0) { return }
    // 本文件里「已经认识」的名字与剥过注释的代码行——按文件懒算
    let lexByFile = HashMap<String, FileLexicon>()
    for ((file, name, line) in graph.unresolvedCalls) {
        // 清单/配置文件豁免：Package.swift 的 Package()/macOS() 是 SwiftPM DSL，
        // build.gradle 的 android() 同理——这些"调用"是宿主框架注入的。
        let base = lastSeg(file)
        if (base == "Package.swift" || base == "Package.resolved"
            || base == "build.gradle" || base == "build.gradle.kts"
            || base == "settings.gradle" || base == "settings.gradle.kts" || base == "Podfile"
            || base == "Cargo.toml" || base == "Makefile") {
            continue
        }
        // 「全仓没有该名字的定义」必须是真的才报。索引只收顶层 / 成员级符号：函数里嵌套的
        // 局部函数（Cangjie / Kotlin / Python 的缩进 def、Swift 的嵌套 func）不在索引里，
        // 对它们的调用于是 dst 为空。实测引擎仓 53 条 unresolved-call 抽样 6/6 都是这种
        // （mcp.cj 的 boolArg / getStr、cli.cj 的 milestoneMaxPositionals …），没有一条是幻觉 API。
        var lex: Option<FileLexicon> = None
        match (lexByFile.get(file)) {
            case Some(lx) => lex = Some(lx)
            case None =>
                let lx = fileLexicon(graph, file)
                lexByFile[file] = lx
                lex = Some(lx)
        }
        var skip = false
        match (lex) {
            case Some(lx) =>
                if (lx.names.contains(name)) {
                    skip = true
                } else if (line >= 1 && line <= Int64(lx.lines.size)) {
                    if (calleeIsDeclaredName(lx.lines[line - 1], name)) { skip = true }
                }
            case None => ()
        }
        if (skip) { continue }
        let key = file
        let c = match (perFile.get(key)) {
            case Some(v) => v
            case None => 0
        }
        if (c >= CONF_MAX_PER_KIND_PER_FILE) {
            cap.drop(UnresolvedCall, file)   // 丢弃发生点（cappedKind 真值 + 罚分计入总分）
            continue
        }
        perFile[key] = c + 1
        findings.add(Finding(UnresolvedCall, file, line, name,
            "调用 ${name}(…)：全仓没有该名字的定义，也不是语言内建——"
            + "最常见的是库 / 框架调用（先 index grep 或查依赖确认这个名字存在），其次才是拼错或编造"))
    }
}

/// 一个文件的词表：认识的名字 + 剥过注释与字符串的代码行。
struct FileLexicon {
    let names: HashSet<String>
    let lines: ArrayList<String>
    init(names: HashSet<String>, lines: ArrayList<String>) {
        this.names = names
        this.lines = lines
    }
}

/// 一个文件里「已经认识」的名字——裸调用它们**不是幻觉**：
///   · 声明关键词之后的那个词（`func f(` / `fun f(` / `def f(` / `fn f(` / `class C` / `struct S` …，
///     含索引不到的嵌套函数）与绑定到 lambda 的局部变量；
///   · 显式 import 进来的名字（`import a.b.Name [as Alias]` / `from x import a, b` / `use a::b::c`）；
///   · 文件里被赋值过的名字（`x = f`、`for x in xs`、`val x = …`：绑定了可调用对象的变量、循环变量）；
///   · 函数类型的参数（`onVerdict: (String) -> Unit`）；
///   · 枚举项（`enum class P(val key: String) { LOCATING("…") }`——构造枚举项不是调用）。
///
/// 【为什么】unresolved-call 的证据只是「全仓没有该名字的定义」。索引只收顶层 / 成员级符号，
/// 上面这些名字全都不在索引里，于是对它们的调用 dst 为空、被报成「幻觉 API」。实测：
/// 引擎仓 53 条抽样 6/6 是嵌套的局部函数；deepDolphin 152 条里 Kotlin 的 36 条是 Compose /
/// 标准库与函数类型参数、C++ 的一批是同文件里的 lambda。
func fileLexicon(graph: CodeGraph, file: String): FileLexicon {
    let out = HashSet<String>()
    let lines = ArrayList<String>()
    let content = readFileText(graph.root + "/" + file)
    match (content) {
        case Some(text) =>
            var strState: Int64 = 0
            var depth: Int64 = 0
            var enumDepth: Int64 = -1     // 枚举体所在的花括号深度；-1 = 不在枚举体里
            var pendingEnum = false       // 见到 `enum X` 声明、还没等到它的 `{`
            for (line in text.lazySplit("\n")) {
                let (t0, nextState) = stripCode(line, strState)
                strState = nextState
                let t = t0.trimAscii()
                lines.add(t)
                collectDeclaredNames(t, out)
                collectImportedNames(t, out)
                collectAssignedNames(t, out)
                collectFunctionTypedNames(t, out)
                collectEnumCaseLine(t, out)
                // 先判声明再看花括号：`enum class P(…) {` 的 `{` 就在声明这一行
                if (isEnumDeclaration(t)) { pendingEnum = true }
                if (depth == enumDepth) {
                    collectEnumEntryName(t, out)
                } else if (pendingEnum && t.contains("{")) {
                    enumDepth = depth + 1
                    pendingEnum = false
                    collectEnumEntryName(afterFirst(t, 123), out)
                }
                var d: Int64 = 0
                for (c in t) {
                    if (c == 123) { d += 1 }
                    else if (c == 125) { d -= 1 }
                }
                depth += d
                if (depth < 0) { depth = 0 }
                if (enumDepth >= 0 && depth < enumDepth) { enumDepth = -1 }
            }
        case None => ()
    }
    return FileLexicon(out, lines)
}

/// 声明关键词之后的那个词（含嵌套在函数体里的）与绑定到 lambda 的局部变量。
func collectDeclaredNames(t: String, out: HashSet<String>): Unit {
    let b = t.toArray()
    let n = Int64(b.size)
    var i: Int64 = 0
    while (i < n) {
        if (isIdentByte(b[i])) {
            let st = i
            while (i < n && isIdentByte(b[i])) { i += 1 }
            let w = fromUtf8Lossy(b[st..i])
            var isDecl = false
            for (k in DECL_NAME_WORDS) {
                if (w == k) { isDecl = true; break }
            }
            if (isDecl) {
                var j = i
                // 接收者链上的每一段都收：`fun <T> List<T>.foo(` 的名字是最后一段，
                // `fun <T> foo(` 前面是类型参数
                var more = true
                while (more && j < n) {
                    while (j < n && (b[j] == 32 || b[j] == 9)) { j += 1 }
                    if (j < n && b[j] == 60) {
                        var d: Int64 = 0
                        while (j < n) {
                            if (b[j] == 60) { d += 1 }
                            else if (b[j] == 62) {
                                d -= 1
                                if (d == 0) { j += 1; break }
                            }
                            j += 1
                        }
                        while (j < n && (b[j] == 32 || b[j] == 9)) { j += 1 }
                    }
                    if (j < n && isIdentByte(b[j])) {
                        let s2 = j
                        while (j < n && isIdentByte(b[j])) { j += 1 }
                        out.add(fromUtf8Lossy(b[s2..j]))
                    }
                    if (j < n && b[j] == 46) { j += 1 } else { more = false }
                }
            }
        } else {
            i += 1
        }
    }
    collectLocalCallables(t, out)
}

/// 绑定到 lambda / 闭包的局部变量名：`let/var/val/const/auto/mut/static x = <lambda>`、
/// `const auto x = [&]…`、Python 的 `x = lambda …`。
func collectLocalCallables(t: String, out: HashSet<String>): Unit {
    let toks = tokenize(t)
    let nt = Int64(toks.size)
    if (nt < 2) { return }
    var isLambda = false
    for (m in LAMBDA_MARKS) {
        if (indexOfStr(t, m) >= 0) { isLambda = true; break }
    }
    if (!isLambda) { return }
    let head = toks[0]
    if (head == "let" || head == "var" || head == "val" || head == "const" || head == "auto"
        || head == "mut" || head == "local" || head == "static" || head == "final") {
        // `const auto rowOf = [&](…) {…}`：名字在 auto 之后；`let f = …`：名字就在声明词之后
        var k: Int64 = 1
        while (k + 1 < nt && (toks[k] == "auto" || toks[k] == "const" || toks[k] == "mut")) { k += 1 }
        out.add(toks[k])
        return
    }
    // Python：`x = lambda …`（行首是名字，第二个 token 是 lambda）
    if (nt >= 3 && toks[1] == "lambda") { out.add(toks[0]) }
}

/// 类型声明行：`enum class P(…)` / `enum P {` / `public indirect enum P`——不是 `class Color(enum.Enum):` 里的 enum。
func isEnumDeclaration(t: String): Bool {
    let toks = tokenize(t)
    if (toks.size < 2) { return false }
    var k: Int64 = 0
    let mods = ["public", "private", "internal", "protected", "final", "indirect", "sealed", "data"]
    var isMod = true
    while (isMod && k < Int64(toks.size)) {
        isMod = false
        for (m in mods) {
            if (toks[k] == m) {
                k += 1
                isMod = true
                break
            }
        }
    }
    if (k >= Int64(toks.size)) { return false }
    if (toks[k] != "enum") { return false }
    if (k + 1 >= Int64(toks.size)) { return false }
    // `enum class P` / `enum P`：后面跟的是新名字（不是 `.` —— enum.Enum 是限定名）
    return toks[k + 1] != "."
}

/// 某个字节之后的内容（没有该字节 = 空串）。
func afterFirst(t: String, want: UInt8): String {
    let b = t.toArray()
    var i: Int64 = 0
    while (i < Int64(b.size)) {
        if (b[i] == want) { return t[i + 1..] }
        i += 1
    }
    return ""
}

/// 枚举体里一行的枚举项名：行首（或 `case` 之后）的标识符，后面紧跟 `(` / `,` / `;` / 行尾。
/// 带构造实参的枚举项 `LOCATING("…")` 在调用点提取里长得像一次调用。
func collectEnumEntryName(t: String, out: HashSet<String>): Unit {
    let b = t.trimAscii().toArray()
    var st: Int64 = 0
    if (codeStartsWith(b, 0, "case ")) { st = 5 }
    if (st >= Int64(b.size) || !isIdentByte(b[st])) { return }
    var en = st
    while (en < Int64(b.size) && isIdentByte(b[en])) { en += 1 }
    if (en < Int64(b.size) && b[en] != 40 && b[en] != 44 && b[en] != 59 && b[en] != 32 && b[en] != 9) { return }
    out.add(fromUtf8Lossy(b[st..en]))
}

/// 仓颉枚举的构造器声明：`| BadScope(String)`、`| Ok`（`|| cond` 这种续行运算符后面不是标识符，不算）。
func collectEnumCaseLine(t: String, out: HashSet<String>): Unit {
    let tt = t.trimAscii()
    if (!tt.startsWith("|")) { return }
    let b = tt.toArray()
    var k: Int64 = 1
    while (k < Int64(b.size) && (b[k] == 32 || b[k] == 9)) { k += 1 }
    if (k < Int64(b.size) && isIdentByte(b[k])) {
        let st = k
        while (k < Int64(b.size) && isIdentByte(b[k])) { k += 1 }
        out.add(fromUtf8Lossy(b[st..k]))
    }
}

/// 显式 import 的名字：`import a.b.Name`、`import a.b.Name as Alias`、`from x import a, b as c`、`use a::b::c`。
/// 路径上的每一段都收（模块段做函数名的情况可以忽略）。
func collectImportedNames(t: String, out: HashSet<String>): Unit {
    if (!t.startsWith("import ") && !t.startsWith("from ") && !t.startsWith("use ")) { return }
    let toks = tokenize(t)
    var started = false
    for (w in toks) {
        if (!started) {
            if (w == "import" || w == "use") { started = true }
            continue
        }
        if (w != "as") { out.add(w) }
    }
}

/// 赋值语句左部的名字：`x = …`、`x: T = …`、`a, b = …`、`let x = …`、`for a, b in xs`。
/// 成员 / 下标赋值（`x.y = …`、`a[i] = …`）不算。
func collectAssignedNames(t: String, out: HashSet<String>): Unit {
    let b = t.toArray()
    let n = Int64(b.size)
    var depth: Int64 = 0
    var lhsEnd: Int64 = -1
    var i: Int64 = 0
    var stop = false
    while (i < n && !stop) {
        let c = b[i]
        if (c == 40 || c == 91 || c == 123) { depth += 1 }
        else if (c == 41 || c == 93 || c == 125) {
            if (depth > 0) { depth -= 1 }
        } else if (depth == 0 && c == 61) {
            let prevCh = if (i > 0) { b[i - 1] } else { UInt8(32) }
            let nextCh = if (i + 1 < n) { b[i + 1] } else { UInt8(32) }
            let compound = nextCh == 61 || prevCh == 61 || prevCh == 33 || prevCh == 60
                || prevCh == 62 || prevCh == 43 || prevCh == 45 || prevCh == 42 || prevCh == 47
                || prevCh == 37 || prevCh == 38 || prevCh == 124 || nextCh == 62
            if (!compound) {
                lhsEnd = i
                stop = true
            }
        }
        i += 1
    }
    if (lhsEnd < 0) {
        // `for a, b in xs`：in 之前的都是被绑定的名字（C 系的 `for (int i = 0; …)` 走不进来：= 在括号里）
        if (!codeStartsWith(b, 0, "for ")) { return }
        let toks = tokenize(t)
        if (toks.size < 3 || toks[1] == "(") { return }
        for (k in 1..Int64(toks.size)) {
            if (toks[k] == "in") {
                for (m in 1..k) {
                    if (toks[m] != "," && toks[m] != ")" && toks[m] != ":") { out.add(toks[m]) }
                }
                return
            }
        }
        return
    }
    var lhs = fromUtf8Lossy(b[0..lhsEnd])
    // 解构 `[a, b] = …` / `(a, b) = …`：取括号里的
    let lb = lhs.toArray()
    if (lb.size > 0 && (lb[0] == 91 || lb[0] == 40)) {
        lhs = fromUtf8Lossy(lb[1..Int64(lb.size) - 1])
    }
    for (part in lhs.split(",")) {
        let p = part.trimAscii()
        if (p.isEmpty()) { continue }
        let toks = tokenize(p)
        if (toks.size == 0) { continue }
        // 冒号之前的那一个词是名字：`x: Int = …`、`var plainCount: Int = …`
        var colon: Int64 = -1
        match (p.indexOf(":")) {
            case Some(k) => colon = k
            case None => ()
        }
        if (colon >= 0) {
            var k = colon - 1
            while (k >= 0 && (p[k] == 32 || p[k] == 9)) { k -= 1 }
            var e = k
            while (e >= 0 && isIdentByte(p[e])) { e -= 1 }
            if (k > e) { out.add(p[e + 1..k + 1]) }
            continue
        }
        // 整段只有标识符：取最后一个词（`x`、`if let regen`、`const auto rowOf`、`let x`）；
        // `obj.field`、`a[i]`、`*p` 带别的字符 ⇒ 是用法不是绑定，跳过
        let pb = p.toArray()
        var onlyIdent = true
        for (c in pb) {
            if (!isIdentByte(c) && c != 32 && c != 9) { onlyIdent = false; break }
        }
        if (onlyIdent && toks.size > 0) { out.add(toks[toks.size - 1]) }
    }
}

/// 函数类型的参数 / 属性与 lambda 参数：`onVerdict: (String) -> Unit`（名字后面紧跟冒号）、
/// `{ regen -> regen() }`（名字后面紧跟箭头）——行内有 `->` / `=>`。
func collectFunctionTypedNames(t: String, out: HashSet<String>): Unit {
    if (!t.contains("->") && !t.contains("=>")) { return }
    let b = t.toArray()
    let n = Int64(b.size)
    var i: Int64 = 0
    while (i < n) {
        if (isIdentByte(b[i]) && (i == 0 || !isIdentByte(b[i - 1]))) {
            let st = i
            while (i < n && isIdentByte(b[i])) { i += 1 }
            var j = i
            while (j < n && (b[j] == 33 || b[j] == 63)) { j += 1 }
            if (j < n && b[j] == 58 && (j + 1 >= n || b[j + 1] != 58)) {
                out.add(fromUtf8Lossy(b[st..i]))
            } else {
                // lambda 的参数：`{ regen -> regen() }`、`x => x + 1`
                var k = j
                while (k < n && (b[k] == 32 || b[k] == 9)) { k += 1 }
                if (k + 1 < n && ((b[k] == 45 && b[k + 1] == 62) || (b[k] == 61 && b[k + 1] == 62))) {
                    out.add(fromUtf8Lossy(b[st..i]))
                }
            }
        } else {
            i += 1
        }
    }
}

/// 后面跟的是表达式（其中的调用是真调用）的词。
let EXPR_LEAD_WORDS: Array<String> = ["await", "yield", "raise", "delete", "co_return", "co_await",
    "co_yield", "and", "or", "not", "del", "assert", "elif", "print", "defined"]

/// 调用行上的 `name(` 其实是**声明**：`Type name(…)` 是对象的构造声明
/// （C/C++ 的 `QFile tar(path);`、`const QRegularExpression pxRe(…)`——探针工程 20 条幻觉调用里有 3 条是它），
/// 声明词之后的 `name(` 是函数 / 类型声明。`return foo(`、`new Foo(`、`foo(bar(` 不是。
func calleeIsDeclaredName(t: String, name: String): Bool {
    let b = t.toArray()
    let n = Int64(b.size)
    var i: Int64 = 0
    while (i < n) {
        if (codeStartsWith(b, i, name) && (i == 0 || !isIdentByte(b[i - 1]))) {
            var j = i + name.size
            while (j < n && (b[j] == 32 || b[j] == 9)) { j += 1 }
            if (j < n && b[j] == 40) {
                // name 之前（跳过空白）是不是一个标识符的结尾
                var k = i - 1
                while (k >= 0 && (b[k] == 32 || b[k] == 9)) { k -= 1 }
                if (k < 0) { return false }
                if (b[k] == 62 || b[k] == 42 || b[k] == 38) {
                    // `std::vector<T> name(` / `char *name(`：但 `a > name(`、`x = y * name(` 是表达式——
                    // 只认「前面有类型词、且这一行在 name 之前没有 = ( ,」的写法
                    if (k == 0 || !isIdentByte(b[k - 1])) { return false }
                    var q: Int64 = 0
                    while (q < k) {
                        if (b[q] == 61 || b[q] == 40 || b[q] == 44) { return false }
                        q += 1
                    }
                    return true
                }
                if (!isIdentByte(b[k])) { return false }
                var e = k
                while (e >= 0 && isIdentByte(b[e])) { e -= 1 }
                let w = fromUtf8Lossy(b[e + 1..k + 1])
                var isDeclWord = false
                for (d in DECL_NAME_WORDS) {
                    if (w == d) { isDeclWord = true; break }
                }
                if (isDeclWord) { return true }
                if (KEYWORDS.contains(w) || C_STMT_WORDS.contains(w)) { return false }
                // `await f(` / `yield f(` / `not f(`：这些词后面是表达式里的调用
                for (x in EXPR_LEAD_WORDS) {
                    if (w == x) { return false }
                }
                return true
            }
            i = j
        } else {
            i += 1
        }
    }
    return false
}

/// 未使用 import：import 解析到了目标文件，但目标文件的任何符号都没在本文件出现。
func detectUnusedImports(graph: CodeGraph, findings: ArrayList<Finding>,
                         cap: CapDropCounter): Unit {
    let perFile = HashMap<String, Int64>()
    for ((file, mod, line) in graph.unusedImports) {
        let key = file
        let c = match (perFile.get(key)) {
            case Some(v) => v
            case None => 0
        }
        if (c >= CONF_MAX_PER_KIND_PER_FILE) {
            cap.drop(UnusedImport, file)   // 丢弃发生点（cappedKind 真值 + 罚分计入总分）
            continue
        }
        perFile[key] = c + 1
        findings.add(Finding(UnusedImport, file, line, mod,
            "import ${mod} 后从未使用其任何符号——死引用（AI 常顺手带上标准导入块）"))
    }
}

/// 注释掉的代码块：注释行**长得像代码**且一个文件里 ≥3 行。
/// AI 生成后被手动禁用的代码是最典型的残留形态。
/// 启发式（按序）：剥掉注释前缀后，行内出现「关键词 + 结构特征」。
/// 误报方向：被注释的自然语言句子不含这些组合——偏保守。
func detectCommentedCode(graph: CodeGraph, findings: ArrayList<Finding>): Unit {
    // 代码关键词（大小写敏感的常见形态）
    let kws = ["let ", "var ", "const ", "func ", "def ", "class ", "struct ",
        "return ", "if (", "if(", "for (", "for(", "while (", "while(",
        "println(", "print(", "console.log(", "fmt.Print", "self.", "import "]
    for (f in graph.files) {
        let content = readFileText("${graph.root}/${f.relPath}")
        match (content) {
            case Some(text) =>
                var codeLines: Int64 = 0
                var firstLine: Int64 = 0
                var firstExcerpt = ""
                var lineNo: Int64 = 0
                // 多行字符串里的行不是注释：内嵌的 HTML / CSS 里 `#bar { position:fixed; … }` 以 # 开头、以 ; 结尾，
                // 两条「像代码」的规则都中（实测引擎仓 archhtml.cj 的样式表被报了 8 行「注释掉的代码」）
                var strState: Int64 = 0
                for (line in text.lazySplit("\n")) {
                    // 行号先推进再筛：原实现 continue 在前、lineNo 从不递增，首行恒报第 0 行
                    lineNo += 1
                    let (_, nextState) = stripCode(line, strState)
                    let inString = strState != 0
                    strState = nextState
                    if (inString) { continue }
                    let t = line.trimAscii()
                    if (!t.startsWith("//") && !t.startsWith("#")) { continue }
                    let inner = t.trimAscii()
                    // 剥注释前缀（含 "// "、"#"、"* " 续行）
                    var body = inner
                    if (body.startsWith("//")) { body = body[2..].trimAscii() }
                    else if (body.startsWith("#")) { body = body[1..].trimAscii() }
                    else if (body.startsWith("*")) { body = body[1..].trimAscii() }
                    if (body.isEmpty()) { continue }
                    // 「讲代码的注释」不是注释掉的代码：`// unreadable = Some(0)（…）不是披露理由`、
                    // `/// \`let env = try expectDecode(...\`。…`——含中文或全角标点的行是散文。
                    // 实测 deepDolphin 抽到的 5 条全是这一种。被注释掉的代码后面拖一句中文注释的会漏报，
                    // 宁可漏报。
                    if (!isAsciiOnly(body)) { continue }
                    var looksCode = false
                    for (kw in kws) {
                        if (body.startsWith(kw)) { looksCode = true; break }
                    }
                    // 结构特征：以 ; 结尾（只对 `//` 注释——Python / shell 的 `#` 注释不以分号收尾），
                    // 或含 " = " 且含 "("
                    if (!looksCode && t.startsWith("//") && body.endsWith(";")) { looksCode = true }
                    if (!looksCode && body.contains(" = ") && body.contains("(")) { looksCode = true }
                    if (!looksCode) { continue }
                    codeLines += 1
                    if (firstLine == 0) {
                        firstLine = lineNo
                        firstExcerpt = oneLineClamped(body, 60)
                    }
                }
                if (codeLines >= CONF_COMMENTED_CODE_LINES) {
                    findings.add(Finding(CommentedCode, f.relPath, firstLine, "",
                        "${codeLines} 行注释掉的代码（首行：${firstExcerpt}）——确认后应删除而非注释"))
                }
            case None => ()
        }
    }
}

/// 全部是 ASCII 字节（没有任何中文 / 全角标点）。
func isAsciiOnly(t: String): Bool {
    for (c in t) {
        if (c >= 128) { return false }
    }
    return true
}

// MARK: - 变量级 / 类型级 / 指针 / 并发（维度补齐：评审要求的完整覆盖）

/// 未使用变量：函数体内 `let/var/val x =` 声明后，同名标识符在该函数体内
/// 再未出现（声明行除外）。AST 函数边界内的词法统计——精确到函数作用域。
func detectUnusedVariables(nodes: ArrayList<AstNode>, findings: ArrayList<Finding>,
                           cap: CapDropCounter): Unit {
    let perFile = HashMap<String, Int64>()
    for (n in nodes) {
        if (n.nodeRule != "fn") { continue }
        // 候选声明：逐行扫 let/var/val 前缀。没有块体的（表达式体 / 无体声明）没有局部变量。
        var body = ""
        var lineNo = n.startLine
        match (bodyOf(n.text, n.file)) {
            case Some(b) =>
                body = b.text
                // 块体首行 = `{` 所在的那一行（原实现一律记成 startLine + 1：
                // 头部与 `{` 同行时整份行号错一行）
                lineNo = bodyFirstLine(n) - 1
            case None => continue
        }
        if (body.isEmpty()) { continue }
        for (line in body.lazySplit("\n")) {
            lineNo += 1
            let t = line.trimAscii()
            var name = ""
            if (t.startsWith("let ")) { name = firstIdentAfter(t, 4) }
            else if (t.startsWith("var ")) { name = firstIdentAfter(t, 4) }
            else if (t.startsWith("val ")) { name = firstIdentAfter(t, 4) }
            if (name.isEmpty()) { continue }
            // 计数：函数体内该名字的出现次数（含声明行）。1 次 = 声明后从未使用。
            // ⚠️ 仓颉 lambda 不能捕获可变局部变量——用可变集合容器绕（容器本身是引用）。
            // ⚠️ 仓颉 lambda 不能捕获可变绑定（容器下标写也算）——手写扫描循环
            var hits: Int64 = 0
            for (l2 in body.lazySplit("\n")) {
                let b2 = l2.toArray()
                let n2 = Int64(b2.size)
                var i2: Int64 = 0
                while (i2 < n2) {
                    if (isIdentByte(b2[i2])) {
                        let st2 = i2
                        while (i2 < n2 && isIdentByte(b2[i2])) { i2 += 1 }
                        if (fromUtf8Lossy(b2[st2..i2]) == name) { hits += 1 }
                    } else {
                        i2 += 1
                    }
                }
            }
            if (hits <= 1) {
                let key = n.file
                let c = match (perFile.get(key)) {
                    case Some(v) => v
                    case None => 0
                }
                if (c >= CONF_MAX_PER_KIND_PER_FILE) {
                    cap.drop(UnusedVariable, n.file)   // 丢弃发生点（cappedKind 真值 + 罚分计入总分）
                    continue
                }
                perFile[key] = c + 1
                findings.add(Finding(UnusedVariable, n.file, lineNo, name,
                    "变量 ${name} 声明后在本函数体内未再出现——死变量（AI 常留的中间产物）"))
            }
        }
    }
}

/// 行内第 n 个字符后的第一个标识符
func firstIdentAfter(line: String, fromByte: Int64): String {
    let b = line.toArray()
    var i = fromByte
    let n = Int64(b.size)
    while (i < n && !isIdentByte(b[i])) { i += 1 }
    let st = i
    while (i < n && isIdentByte(b[i])) { i += 1 }
    if (i > st) { return fromUtf8Lossy(b[st..i]) }
    return ""
}

/// C/C++ 的**前置声明**形态（opaque forward declaration）。
/// ast-grep 的 type 规则对 `struct Fwd;` 与 `typedef struct Fwd FwdT;`
/// 都跨 1 行命中，于是每个前置声明都被判成「空类型」扣 3 分 ——
/// 而 opaque 前向声明是 C 头文件的**惯用法**（隐藏实现细节），
/// 它系统性地拖低整个 C/C++ 仓库的分数（审查 M3）。
/// 判据：**节点文本无 `{` 即前置声明**。注意不能判 `endsWith(";")`：
/// tree-sitter 的 CST 里 `;` 是 struct_specifier 的**兄弟节点**，命中
/// text 是 `struct Fwd`（实测 ast-grep 0.41.0），不带分号——按分号判
/// 恒为 false，等于没修（复审 2026-10-10）。走到这里说明没有 `{`，
/// 而 AST type 节点不会有无成员表的真实定义。
func isForwardDeclaration(text: String): Bool {
    let t = text.trimAscii()
    if (t.isEmpty()) {
        return false
    }
    return !t.contains("{")
}

/// 类型级信号：空类型（无成员）与上帝类（行数/方法数超阈）。
func detectTypeSignals(nodes: ArrayList<AstNode>, findings: ArrayList<Finding>): Unit {
    for (n in nodes) {
        if (n.nodeRule != "type") { continue }
        let lines = n.endLine - n.startLine + 1
        var body = ""
        match (bodyOf(n.text, n.file, skipParams: false)) {
            case Some(b) => body = b.text
            case None => body = ""
        }
        // ⚠️ G5：成员计数必须纳入**字段行**——原实现只用 mayDeclare（声明
        // 关键词）数成员，字段对它不可见，于是只有字段没有方法的类型
        // （`type Rect struct { w, h float64 }`）被指控「没有任何成员——
        // 占位类型或被掏空」。口径：大括号体内非空、剥注释后仍有内容的行
        // 都算成员（字段行 + 方法声明行）；零成员才报 empty-type——
        // 文案「没有任何成员」只有在真的一个成员都没有时才许说。
        // methods 仍按声明关键词行计数（上帝类的口径是方法数，不是字段数）。
        var methods: Int64 = 0
        var members: Int64 = 0
        var strState: Int64 = 0
        for (line in body.lazySplit("\n")) {
            let (t, nextState) = stripCode(line, strState)
            strState = nextState
            if (blankLine(t)) { continue }
            if (mayDeclare(t)) { methods += 1 }
            members += 1
        }
        let name = typeNameOf(n)
        // ⚠️ M3：前置声明不是空类型。它是一种**故意不暴露成员**的声明，
        // 报它「被掏空」是对 C 头文件惯用法的事实性误判。
        if (isForwardDeclaration(n.text)) {
            continue
        }
        if (members == 0 && lines <= 3) {
            findings.add(Finding(EmptyType, n.file, n.startLine, name,
                "类型 ${name} 没有任何成员（${lines} 行）——占位类型或被掏空"))
        } else if (lines > CONF_GOD_CLASS_LINES || methods > CONF_GOD_CLASS_METHODS) {
            findings.add(Finding(GodClass, n.file, n.startLine, name,
                "类型 ${name}：${lines} 行 / ${methods} 个声明（阈值 ${CONF_GOD_CLASS_LINES} 行或 ${CONF_GOD_CLASS_METHODS} 个）——拆分候选"))
        }
    }
}

/// 类型名：文本首个标识符（class Foo → Foo）
func typeNameOf(n: AstNode): String {
    for (tok in tokenize(n.text)) {
        if (looksLikeName(tok)) { return tok }
    }
    return ""
}

/// 指针风险（C/C++）：文件级 malloc/calloc 与 free 计数不配对；返回**局部变量**的地址。
/// 词法级——指针语义（别名/所有权）超出静态词法能力，如实标注为启发式。
func detectPointerRisks(graph: CodeGraph, findings: ArrayList<Finding>): Unit {
    for (f in graph.files) {
        if (f.lang != "c") { continue }
        let content = readFileText("${graph.root}/${f.relPath}")
        match (content) {
            case Some(text) =>
                let src = ArrayList<String>()
                for (l in text.split("\n")) { src.add(l) }
                var allocs: Int64 = 0
                var frees: Int64 = 0
                var stackLine: Int64 = 0
                var stackName = ""
                // ⚠️ G3：注释状态跨行携带（同 detectConcurrencyRisks ① 的先例）——
                // 原实现每行独立以状态 0 调 stripCode，多行块注释里的 malloc(
                // 被计入「疑似内存泄漏」。
                var strState: Int64 = 0
                var lineNo: Int64 = 0
                for (line in src) {
                    lineNo += 1
                    let (t, nextState) = stripCode(line, strState)
                    strState = nextState
                    if (t.contains("malloc(") || t.contains("calloc(") || t.contains("realloc(")) {
                        allocs += 1
                    }
                    if (t.contains("free(")) { frees += 1 }
                    if (stackLine == 0) {
                        match (returnsAddressOf(t)) {
                            case Some(x) =>
                                stackLine = lineNo
                                stackName = x
                            case None => ()
                        }
                    }
                }
                if (allocs > frees) {
                    findings.add(Finding(PointerRisk, f.relPath, 1, "",
                        "分配 ${allocs} 次（malloc/calloc/realloc）但 free 仅 ${frees} 次——疑似内存泄漏"))
                }
                // 只有 x 被证得是「包住这条 return 的函数里声明的、非静态、非引用的局部变量」才报。
                // 原实现见 `return &` 就报，证据里自己写着「若取的是参数/堆地址则为误报」——
                // 实测 deepDolphin 6 条全是误报：range-for 的引用（`for (const T &p : xs)`）
                // 与函数内 static（`static Foo inst; return &inst;`）。
                if (stackLine > 0 && returnsStackLocal(src, f, stackLine, stackName)) {
                    findings.add(Finding(PointerRisk, f.relPath, stackLine, "",
                        "return &${stackName}：${stackName} 是本函数内的局部变量，函数返回后地址悬垂"))
                }
            case None => ()
        }
    }
}

/// `return &x;` 里的 x；不是这个写法返回 None。
func returnsAddressOf(t: String): Option<String> {
    // 名字要从去空白后的行上取（原实现按原行的第 8 个字节起找：`    return &x;` 取到的是 rn）
    let tt = t.trimAscii()
    if (!tt.startsWith("return &")) { return None }
    let name = firstIdentAfter(tt, 8)
    if (name.isEmpty()) { return None }
    return Some(name)
}

/// `return &x` 里的 x 是不是「包住这条 return 的函数」内声明的局部变量：
/// 在最内层函数符号的范围内找 `Type x` 形态的声明——类型在前、x 后面紧跟 `; = [ ,`，
/// 前面不是 `&`（引用：range-for 的 `const T &p`）、不是参数表里的（函数头一行只看 `{` 之后）、
/// 同一行没有 `static`。找不到声明（成员 / 全局 / 参数）就不下结论。
func returnsStackLocal(src: ArrayList<String>, f: FileEntry, ln: Int64, name: String): Bool {
    var from = ln
    var to = ln
    var found = false
    for (s in f.symbols) {
        var isFunc = false
        match (s.kind) {
            case Func => isFunc = true
            case _ => ()
        }
        if (!isFunc || s.declOnly) { continue }
        if (s.line <= ln && ln <= s.endLine && (!found || (s.endLine - s.line) < (to - from))) {
            from = s.line
            to = s.endLine
            found = true
        }
    }
    if (!found) { return false }
    let (headerEnd0, bodyStart0, gotBrace0) = braceHeaderEnd(src, from, to)
    var headerEnd = headerEnd0
    let bodyStart = bodyStart0
    let gotBrace = gotBrace0
    var i = if (gotBrace) { headerEnd } else { from }
    var strState: Int64 = 0
    while (i <= to && i <= Int64(src.size)) {
        let (t0, nextState) = stripCode(src[i - 1], strState)
        strState = nextState
        var t = t0
        if (i == headerEnd && gotBrace) {
            t = t[bodyStart..]
        }
        if (isLocalDeclOf(t, name)) { return true }
        i += 1
    }
    return false
}

/// 函数头的结束位置：(头部的最后一行, 该行 `{` 之后的位置, 有没有找到块体)。
/// 函数头可能跨多行（参数表、构造函数的初始化列表）：参数表配平之后的第一个 `{` 所在的行
/// 是头部的最后一行。头部里的 `Type x` 都是参数 / 基类 / 成员初始化，不是局部变量。
func braceHeaderEnd(src: ArrayList<String>, from: Int64, to: Int64): (Int64, Int64, Bool) {
    var headerEnd = from
    var bodyStart: Int64 = -1
    var depth: Int64 = 0
    var h = from
    var hState: Int64 = 0
    var gotBrace = false
    while (h <= to && h <= Int64(src.size)) {
        let (t0, ns) = stripCode(src[h - 1], hState)
        hState = ns
        let bb = t0.toArray()
        var k: Int64 = 0
        while (k < Int64(bb.size)) {
            if (bb[k] == 40) { depth += 1 }
            else if (bb[k] == 41) { depth -= 1 }
            else if (bb[k] == 123 && depth <= 0) {
                headerEnd = h
                bodyStart = k + 1
                gotBrace = true
                break
            }
            k += 1
        }
        if (gotBrace) { break }
        h += 1
    }
    return (headerEnd, bodyStart, gotBrace)
}

/// 只含函数体（不含声明头）的源码行：近重复比较用——声明行带着各自的名字，
/// 连声明行一起哈希的话两个不同名的函数永远「不重复」（原实现就是这个毛病）。
func pureBodyLines(srcLines: ArrayList<String>, s: SymDecl, last: Int64, python: Bool): ArrayList<String> {
    let out = ArrayList<String>()
    if (python) {
        var i = s.line + 1
        while (i <= last) {
            out.add(srcLines[i - 1])
            i += 1
        }
        return out
    }
    let (headerEnd, bodyStart, gotBrace) = braceHeaderEnd(srcLines, s.line, last)
    if (!gotBrace) {
        // 没有块体（表达式体 / 无体声明）：头之后没有体
        return out
    }
    let first = srcLines[headerEnd - 1]
    let fb = first.toArray()
    if (bodyStart < Int64(fb.size)) { out.add(first[bodyStart..]) }
    var i = headerEnd + 1
    while (i <= last) {
        out.add(srcLines[i - 1])
        i += 1
    }
    return out
}

/// 行内有没有 `Type x` 形态的局部声明（x 后面紧跟 `;` `=` `[` `,`）。
func isLocalDeclOf(t: String, name: String): Bool {
    let b = t.toArray()
    let n = Int64(b.size)
    let nb = name.toArray()
    var i: Int64 = 0
    while (i < n) {
        // 整词匹配
        if (codeStartsWith(b, i, name) && (i == 0 || !isIdentByte(b[i - 1]))
            && (i + Int64(nb.size) >= n || !isIdentByte(b[i + Int64(nb.size)]))) {
            let after = i + Int64(nb.size)
            var j = after
            while (j < n && (b[j] == 32 || b[j] == 9)) { j += 1 }
            // `Foo f{…}`（花括号初始化）也是声明
            let okTail = j < n && (b[j] == 59 || b[j] == 61 || b[j] == 91 || b[j] == 44 || b[j] == 123
                || b[j] == 58)
            // 前面：空白之后是类型的最后一个字符（标识符 / `*`），不是 `&`（引用）`.` `(` `,`
            var k = i - 1
            while (k >= 0 && (b[k] == 32 || b[k] == 9)) { k -= 1 }
            var okHead = k >= 0 && (isIdentByte(b[k]) || b[k] == 42)
            if (okHead && isIdentByte(b[k])) {
                var e = k
                while (e >= 0 && isIdentByte(b[e])) { e -= 1 }
                let typeWord = fromUtf8Lossy(b[e + 1..k + 1])
                if (KEYWORDS.contains(typeWord) || C_STMT_WORDS.contains(typeWord)) { okHead = false }
            }
            if (okHead && okTail && indexOfStr(t, "static") < 0) { return true }
            i = after
        } else {
            i += 1
        }
    }
    return false
}

/// 并发链路/细节：
///   ① 全局可变状态：顶层 var/static var（无同步的共享状态起点）
///   ② 锁不平衡：同函数内 lock/acquire 无对应 unlock/release
///   ③ 持锁调用：lock 到 unlock 区间内调用**非本函数定义**的函数（死锁经典形态）
/// AST 可用时按函数节点判；降级时按文件词法近似（①仍准确——顶层判定不依赖函数边界）。
func detectConcurrencyRisks(graph: CodeGraph, nodes: ArrayList<AstNode>, astUsed: Bool,
                            findings: ArrayList<Finding>, cap: CapDropCounter): Unit {
    // ① 全局可变（语言关键词：Swift/Cangjie var、Rust static mut、Kotlin var）
    for (f in graph.files) {
        let content = readFileText("${graph.root}/${f.relPath}")
        match (content) {
            case Some(text) =>
                var depth: Int64 = 0
                var strState: Int64 = 0
                var lineNo: Int64 = 0
                let perFile = HashMap<String, Int64>()
                for (line in text.lazySplit("\n")) {
                    lineNo += 1
                    let (t, nextState) = stripCode(line, strState)
                    strState = nextState
                    if (depth == 0) {
                        let trimmed = t.trimAscii()
                        var hit = false
                        if (trimmed.startsWith("var ") || trimmed.startsWith("public var ")
                            || trimmed.startsWith("static var ") || trimmed.startsWith("internal var ")) {
                            hit = true
                        }
                        if (trimmed.startsWith("static mut ")) { hit = true }
                        // Compose 的快照状态（`var x by mutableStateOf(…)`）：写入有快照系统管一致性，
                        // 不是「无同步的共享状态」——按定义就是给多线程读写用的
                        for (m in SNAPSHOT_STATE_MARKS) {
                            if (trimmed.contains(m)) { hit = false }
                        }
                        if (hit) {
                            let c = match (perFile.get(f.relPath)) {
                                case Some(v) => v
                                case None => 0
                            }
                            if (c < 3) {
                                perFile[f.relPath] = c + 1
                                findings.add(Finding(GlobalMutable, f.relPath, lineNo, "",
                                    "顶层可变全局（${oneLineClamped(trimmed, 50)}）——多线程共享状态的起点，需同步或改不可变"))
                            } else {
                                // 丢弃发生点（GlobalMutable 的每文件上限是历史口径 3，
                                // 与 CONF_MAX_PER_KIND_PER_FILE 不同值，但同属
                                // 「因限流被丢弃」——cappedKind 的判据）
                                cap.drop(GlobalMutable, f.relPath)   // 丢弃发生点（cappedKind 真值 + 罚分计入总分）
                            }
                        }
                    }
                    depth += braceDelta(t)
                    if (depth < 0) { depth = 0 }
                }
            case None => ()
        }
    }
    // ② ③ 锁分析（函数节点内）。行号 = startLine + 节点文本内的行下标：原实现从「体」的
    // 首行起数、先加后用，头部与 `{` 同行时报出来的行号整体偏一行（实测 lock 在 126 行、
    // 报的是 127）；而且看的是原始行，注释里的 `.lock(` 也算。
    if (!astUsed) { return }
    let perFile = HashMap<String, Int64>()
    for (n in nodes) {
        if (n.nodeRule != "fn") { continue }
        // RAII 锁不判「没释放」：Rust 的 lock() 返回守卫、离域即释放；
        // C++ 的 lock_guard / unique_lock / scoped_lock 同理。
        let raii = detectLang(n.file) == "rust" || n.text.contains("lock_guard")
            || n.text.contains("unique_lock") || n.text.contains("scoped_lock")
        var lockLine: Int64 = 0
        var locked = false
        var idx: Int64 = 0
        var strState: Int64 = 0
        for (line in n.text.lazySplit("\n")) {
            let (t, nextState) = stripCode(line, strState)
            strState = nextState
            idx += 1
            let ln = n.startLine + idx - 1
            var acq: Int64 = -1
            var rel: Int64 = -1
            match (lockOpAt(t, true)) {
                case Some(p) => acq = p
                case None => ()
            }
            match (lockOpAt(t, false)) {
                case Some(p) => rel = p
                case None => ()
            }
            if (!locked) {
                // 同一行先取锁、后面登记了释放（Swift `lock.lock(); defer { lock.unlock() }`）：
                // 释放由 defer 保证，不是「到函数结束没释放」。原实现只在「已持锁」的分支里
                // 找释放，同一行的释放被漏看——实测 deepDolphin 的 Swift 端 lock-imbalance
                // 全是这一种。
                if (acq >= 0 && !(rel > acq)) {
                    locked = true
                    lockLine = ln
                }
            } else if (rel >= 0) {
                checkLockCalls(n, lockLine, ln, findings, perFile, cap)
                locked = false
            }
        }
        if (locked && lockLine > 0 && !raii) {
            // 函数结束仍持锁：不平衡（泄漏锁 / 死锁风险）
            let c = match (perFile.get(n.file)) {
                case Some(v) => v
                case None => 0
            }
            if (c < CONF_MAX_PER_KIND_PER_FILE) {
                perFile[n.file] = c + 1
                let fnName = nodeName(n)
                findings.add(Finding(LockImbalance, n.file, lockLine, fnName,
                    "函数 ${fnName} 在 L${lockLine} 获取锁后到函数结束没有释放——锁泄漏或依赖外部释放"))
            } else {
                cap.drop(LockImbalance, n.file)   // 丢弃发生点（cappedKind 真值 + 罚分计入总分）
            }
        }
    }
}

/// `if(x)`、`while(x)`、`switch(x)`：不带空格时 `name(` 的形态与调用无异——关键字不是外部调用
/// （评估文档 B14）。
func isKeywordName(name: String): Bool {
    if (KEYWORDS.contains(name) || C_STMT_WORDS.contains(name)) { return true }
    for (k in CONTROL_KEYWORDS) {
        if (name == k) { return true }
    }
    return name == "switch" || name == "sizeof" || name == "return" || name == "catch"
}

/// 行内第一处取锁 / 释放锁的调用位置（输入是已剥注释与字符串的代码行）。
func lockOpAt(t: String, acquire: Bool): Option<Int64> {
    let pats = if (acquire) { LOCK_ACQUIRE } else { LOCK_RELEASE }
    var best: Int64 = -1
    for (p in pats) {
        match (t.indexOf(p)) {
            case Some(k) => if (best < 0 || k < best) { best = k }
            case None => ()
        }
    }
    if (best < 0) { return None }
    return Some(best)
}

/// 行内花括号净增量（剥注释/字符串后）——与 build.cj 的 braceDelta 同语义。
func braceDelta(line: String): Int64 {
    let (t, _) = stripCode(line, 0)
    var d: Int64 = 0
    for (b in t) {
        if (b == 123) { d += 1 }
        if (b == 125) { d -= 1 }
    }
    return d
}

func containsLockAcquire(line: String): Bool {
    return line.contains(".lock(") || line.contains(".acquire(") || line.contains("pthread_mutex_lock")
        || line.contains("EnterCriticalSection") || line.contains("mutex.lock")
}

func containsLockRelease(line: String): Bool {
    return line.contains(".unlock(") || line.contains(".release(") || line.contains("pthread_mutex_unlock")
        || line.contains("LeaveCriticalSection") || line.contains("mutex.unlock")
}

/// 持锁区间内的外部调用：调用名既非语言内建、也非本函数内定义、也非锁 API 本身。
func checkLockCalls(n: AstNode, lockLine: Int64, unlockLine: Int64,
                    findings: ArrayList<Finding>, perFile: HashMap<String, Int64>,
                    cap: CapDropCounter): Unit {
    // ⚠️ 仓颉 lambda 不允许写捕获环境——手写扫描，不用闭包。
    var idx: Int64 = 0
    // ⚠️ G3：注释状态跨行携带，且**每行先推进状态再做区间过滤**——
    // 若先 continue 再 stripCode，被跳过的行会丢状态，持锁区间里
    // 跨行块注释的后半段就漏剥了（注释里的调用被报死锁）。
    var strState: Int64 = 0
    for (line in n.text.lazySplit("\n")) {
        idx += 1
        let (t, nextState) = stripCode(line, strState)
        strState = nextState
        if (idx < lockLine - n.startLine + 1 || idx > unlockLine - n.startLine + 1) { continue }
        let b = t.toArray()
        let ln = Int64(b.size)
        var i: Int64 = 0
        var prevDot = false
        while (i < ln) {
            let ch = b[i]
            if (isIdentByte(ch)) {
                let st = i
                while (i < ln && isIdentByte(b[i])) { i += 1 }
                let isCall = i < ln && b[i] == 40
                if (isCall && !prevDot) {
                    let name = fromUtf8Lossy(b[st..i])
                    if (!isBuiltinName(name)
                        && !isKeywordName(name)
                        && name != "lock" && name != "unlock"
                        && name != "acquire" && name != "release"
                        && !n.text.contains("func ${name}(")
                        && !n.text.contains("def ${name}(")
                        && !n.text.contains("fun ${name}(")) {
                        let c = match (perFile.get(n.file)) {
                            case Some(v) => v
                            case None => 0
                        }
                        if (c < CONF_MAX_PER_KIND_PER_FILE) {
                            perFile[n.file] = c + 1
                            findings.add(Finding(LockUnknownCall, n.file, n.startLine + idx - 1, name,
                                "持锁区间内调用 ${name}(…)（L${lockLine} 获取锁）——若被调方再取同一把锁即死锁"))
                        } else {
                            cap.drop(LockUnknownCall, n.file)   // 丢弃发生点（cappedKind 真值 + 罚分计入总分）
                        }
                    }
                }
                prevDot = false
            } else {
                prevDot = (ch == 46)
                i += 1
            }
        }
    }
}


// MARK: - 语义层检测（圈复杂度/参数滥用/不可达代码/混合职责/近重复）
//
// 【设计哲学】这五种检测回答的不是「语法对不对」而是「AI 写的这段代码
// 可不可信」：圈复杂度 >10 是缺陷的统计预测器（McCabe 1976，96% 准确率）；
// 参数滥用 = God 签名违反 SRP；不可达代码 = AI 残余；混合职责 = 不可组合。
// 数据来源：索引记录的函数体边界（声明行 + endLine）+ 签名 + 源码行。

/// 圈复杂度：函数体内 if / elif / while / for / case / match 与 && / || 的决策点计数 + 1。
/// 阈值 >10 = 缺陷统计预测器（McCabe 1976，2023 IEEE 96% 准确率确认）。
/// ⚠️ 匹配前先剥注释与字符串（跨行携带状态，复用 stripCode）：注释与字符串里的英文散文
/// 不是决策点（G4）。
///
/// 【按词匹配】原实现按子串数 `"if "` / `"while "`：`if (x)` 认、`if(x)` 不认，`verify ` /
/// `endif ` 被当成 if。关键字现在走分词器（词界有保证）；`match` 只认关键字用法
/// （`re.match(` 是方法调用：前面有 `.`，或后面紧跟 `;` `,` `)` `=`）。
func cyclomaticComplexity(bodyLines: ArrayList<String>): Int64 {
    var cc: Int64 = 1  // 基础路径
    var strState: Int64 = 0
    for (line in bodyLines) {
        let (stripped, nextState) = stripCode(line, strState)
        strState = nextState
        let t = stripped.trimAscii()
        if (blankLine(t)) { continue }
        // 预处理行（`#if defined(A) && defined(B)`）不是运行期分支
        if (t.startsWith("#")) { continue }
        let b = t.toArray()
        let n = Int64(b.size)
        var i: Int64 = 0
        while (i < n) {
            let c = b[i]
            if (isIdentByte(c)) {
                let st = i
                while (i < n && isIdentByte(b[i])) { i += 1 }
                let w = fromUtf8Lossy(b[st..i])
                if (w == "if" || w == "while" || w == "for" || w == "case" || w == "elif") {
                    cc += 1
                } else if (w == "match") {
                    let prevDot = st > 0 && b[st - 1] == 46
                    var j = i
                    while (j < n && (b[j] == 32 || b[j] == 9)) { j += 1 }
                    let nxt = if (j < n) { b[j] } else { UInt8(59) }
                    if (!prevDot && nxt != 59 && nxt != 44 && nxt != 41 && nxt != 61 && nxt != 46) {
                        cc += 1
                    }
                }
            } else if (c == 38 && i + 1 < n && b[i + 1] == 38) {
                cc += 1
                i += 2
                continue
            } else if (c == 124 && i + 1 < n && b[i + 1] == 124) {
                cc += 1
                i += 2
                continue
            }
            i += 1
        }
    }
    return cc
}

/// 辅助：子串搜索（返回起始偏移，-1 = 未找到）。
func indexOfStr(s: String, target: String): Int64 {
    return indexOfStrFrom(s, target, 0)
}

/// 参数表的解析结果。
struct ParamInfo {
    /// 顶层逗号分隔出的参数个数（空表 = 0）
    let count: Int64
    /// 有没有 Bool 标志参数（类型位置是布尔，或默认值是 true / false）
    let hasBool: Bool
    /// 找到了完整的参数表（左右括号配平）；false = 调用方不要下结论
    let ok: Bool
    init(count: Int64, hasBool: Bool, ok: Bool) {
        this.count = count
        this.hasBool = hasBool
        this.ok = ok
    }
}

/// 参数滥用：参数数超阈值或存在 Bool 标志参数。
///
/// 【只数顶层逗号】原实现对签名行里的每一个逗号都 +1：泛型 `Map<String, Int>`、默认实参
/// `g(1, 2)`、函数类型 `(Int, String) -> Unit` 全被算成参数；而且只读声明那一行，
/// 多行签名的参数表只数到第一行。现在吃的是索引记录的整段签名，按嵌套深度数。
/// Bool 只认**类型位置**（`flag: Bool` / `bool flag`）或默认值 `= true / false`——
/// 原实现是子串匹配，参数名叫 `Boolable` 也算。
func analyzeSig(sig: String): ParamInfo {
    let b = sig.toArray()
    let n = Int64(b.size)
    var open: Int64 = -1
    var i: Int64 = 0
    while (i < n) {
        if (b[i] == 40) { open = i; break }
        i += 1
    }
    if (open < 0) { return ParamInfo(0, false, false) }
    var paren: Int64 = 1
    var bracket: Int64 = 0   // [ ] { }
    var angle: Int64 = 0     // < >（泛型）
    var state: Int64 = 0     // 0 代码；否则是当前字符串的引号字节
    var count: Int64 = 0
    var hasBool = false
    var segStart = open + 1
    i = open + 1
    while (i < n) {
        let c = b[i]
        if (state == 0) {
            if (c == 34 || c == 39) {
                state = Int64(c)
            } else if (c == 40) {
                paren += 1
            } else if (c == 41) {
                paren -= 1
                if (paren == 0) {
                    if (i > segStart) {
                        count += 1
                        if (paramIsBoolFlag(fromUtf8Lossy(b[segStart..i]))) { hasBool = true }
                    }
                    return ParamInfo(count, hasBool, true)
                }
            } else if (c == 91 || c == 123) {
                bracket += 1
            } else if (c == 93 || c == 125) {
                if (bracket > 0) { bracket -= 1 }
            } else if (c == 60) {
                // `Map<` 才是泛型；`a < b` 两侧有空格的 comparison 不算
                if (i > open + 1 && (isIdentByte(b[i - 1]) || b[i - 1] == 62)) { angle += 1 }
            } else if (c == 62) {
                if (angle > 0 && i > open + 1 && (isIdentByte(b[i - 1]) || b[i - 1] == 62)) { angle -= 1 }
            } else if (c == 44 && paren == 1 && bracket == 0 && angle == 0) {
                if (i > segStart) {
                    count += 1
                    if (paramIsBoolFlag(fromUtf8Lossy(b[segStart..i]))) { hasBool = true }
                }
                segStart = i + 1
            }
        } else {
            if (c == 92) { i += 2; continue }
            if (Int64(c) == state) { state = 0 }
        }
        i += 1
    }
    return ParamInfo(count, hasBool, false)
}

/// 布尔类型词（各语言写法）。
func boolTypeWords(): HashSet<String> {
    let s = HashSet<String>()
    for (w in ["bool", "Bool", "boolean", "Boolean", "BOOL", "_Bool"]) { s.add(w) }
    return s
}

let BOOL_TYPE_WORDS: HashSet<String> = boolTypeWords()

func boolDefaultWords(): HashSet<String> {
    let s = HashSet<String>()
    for (w in ["true", "false", "True", "False", "TRUE", "FALSE"]) { s.add(w) }
    return s
}

let BOOL_DEFAULT_WORDS: HashSet<String> = boolDefaultWords()

/// 一个参数是不是 Bool 标志参数。只看**顶层**（嵌套括号 / 尖括号里的类型词是别的参数的类型的一部分，
/// 如 `cb: (Bool) -> Unit`、`flags: List<Boolean>`）；参数名本身（`:` / `=` 之前那个词，
/// C 系写法里是最后一个词）不算。
func paramIsBoolFlag(seg: String): Bool {
    // 函数类型（`focusSearch: () -> Boolean`、`cb: (Int) => Bool`）：箭头后面的 Boolean 是返回类型
    if (seg.contains("->") || seg.contains("=>")) { return false }
    let b = seg.toArray()
    let n = Int64(b.size)
    let starts = ArrayList<Int64>()
    let ends = ArrayList<Int64>()
    var i: Int64 = 0
    var paren: Int64 = 0
    var bracket: Int64 = 0
    var angle: Int64 = 0
    var mark: Int64 = -1      // 第一个顶层 `:` / `=`
    while (i < n) {
        let c = b[i]
        if (c == 40) { paren += 1 }
        else if (c == 41) { if (paren > 0) { paren -= 1 } }
        else if (c == 91 || c == 123) { bracket += 1 }
        else if (c == 93 || c == 125) { if (bracket > 0) { bracket -= 1 } }
        else if (c == 60) {
            if (i > 0 && (isIdentByte(b[i - 1]) || b[i - 1] == 62)) { angle += 1 }
        } else if (c == 62) {
            if (angle > 0 && i > 0 && (isIdentByte(b[i - 1]) || b[i - 1] == 62)) { angle -= 1 }
        } else if (isIdentByte(c) && (i == 0 || !isIdentByte(b[i - 1]))) {
            if (paren == 0 && bracket == 0 && angle == 0) {
                let st = i
                while (i < n && isIdentByte(b[i])) { i += 1 }
                starts.add(st)
                ends.add(i)
                continue
            }
        } else if (mark < 0 && paren == 0 && bracket == 0 && angle == 0) {
            // `::` 不是类型标注；`=>` / `==` 不是默认值
            if (c == 58 && (i + 1 >= n || b[i + 1] != 58) && (i == 0 || b[i - 1] != 58)) { mark = i }
            else if (c == 61 && (i + 1 >= n || b[i + 1] != 62)) { mark = i }
        }
        i += 1
    }
    if (starts.size < 2) { return false }
    var nameIdx: Int64 = starts.size - 1
    if (mark >= 0) {
        // 冒号 / 等号之前的那一个词是参数名
        var found = false
        var k = Int64(starts.size) - 1
        while (k >= 0) {
            if (ends[k] <= mark) {
                nameIdx = k
                found = true
                break
            }
            k -= 1
        }
        if (!found) { return false }
    }
    for (k in 0..Int64(starts.size)) {
        if (k == nameIdx) { continue }
        let w = fromUtf8Lossy(b[starts[k]..ends[k]])
        if (BOOL_TYPE_WORDS.contains(w)) { return true }
        if (mark >= 0 && b[mark] == 61 && starts[k] > mark && BOOL_DEFAULT_WORDS.contains(w)) { return true }
    }
    return false
}

/// 独占一行、且本行自洽（花括号 / 括号 / 方括号都配平）的终止语句：return / throw / raise /
/// break / continue。多行的 `return foo(`、`return a &&` 不算——它们的后续行是同一条语句。
func isTerminatorStatement(t: String): Bool {
    for (w in ["return", "throw", "raise", "break", "continue"]) {
        if (t.startsWith(w)) {
            if (Int64(t.size) == w.size) { return true }
            let nx = t[w.size]
            // `return;` `return x` `return(x)`；`throws` / `throwing` 不算
            if (nx == 32 || nx == 9 || nx == 59 || nx == 40) { return true }
        }
    }
    return false
}

/// 终止语句之后的第一条非空行：这一行是「同一块的延续」而不是被挡住的语句——
/// 块的收尾、分支的头（else / elif / except / catch / case / default / finally）、
/// 分支臂（Kotlin when 的 `A ->`、Rust match 的 `X =>`）。
func continuesBlock(t: String): Bool {
    if (t.startsWith("}") || t.startsWith(")") || t.startsWith("]")) { return true }
    // 链式 / 续行的开头：`return x("…")` 的下一行 `.arg(y);`、`return a &&` 的下一行 `b`
    if (t.startsWith(".") || t.startsWith("?.") || t.startsWith("?:") || t.startsWith("&&")
        || t.startsWith("||") || t.startsWith("+") || t.startsWith("::")) { return true }
    for (w in ["else", "elif", "except", "catch", "case", "default", "finally"]) {
        if (t.startsWith(w)) {
            if (Int64(t.size) == w.size) { return true }
            if (!isIdentByte(t[w.size])) { return true }
        }
    }
    if (t.contains("->") || t.contains("=>")) { return true }
    return false
}

/// 不可达代码：终止语句之后、**同一层级**上还有语句。
///
/// 【层级】花括号语言 = 花括号深度 + 缩进，Python = 缩进。两样都要相等：
///   · 只看「下一行非空且不是 `}`」（原实现）：`if (x) { throw … }` 之后的代码、`throw X(` 的
///     多行实参、`return` 后面的 `case` 臂全被判成不可达（实测引擎仓 39 条 dead-branch，
///     抽样的头 6 条全是这三种）；
///   · 只看花括号深度：不带花括号的 `if (c)` / `return x;` 的 return 与后面的语句同深度——
///     实测 deepDolphin 53 条全是这一种（`return false;` 之后是下一个 `if`）。它比 `if` 缩进更深，
///     而真正被挡住的语句与终止语句是同一列。
func hasDeadBranch(bodyLines: ArrayList<String>, bodyStart: Int64, python: Bool): ?Int64 {
    var level: Int64 = 0
    var pending = false
    var pendingDepth: Int64 = 0
    var pendingIndent: Int64 = 0
    var strState: Int64 = 0
    let n = Int64(bodyLines.size)
    var i: Int64 = 0
    while (i < n) {
        let (stripped, nextState) = stripCode(bodyLines[i], strState)
        strState = nextState
        let t = stripped.trimAscii()
        if (!blankLine(t)) {
            let here = indentOf(bodyLines[i])
            if (pending) {
                if (level == pendingDepth && here == pendingIndent && !continuesBlock(t)) {
                    return bodyStart + i
                }
                pending = false
            }
            var opens: Int64 = 0
            var closes: Int64 = 0
            var po: Int64 = 0
            var pc: Int64 = 0
            var bo: Int64 = 0
            var bc: Int64 = 0
            for (c in t) {
                if (c == 123) { opens += 1 }
                else if (c == 125) { closes += 1 }
                else if (c == 40) { po += 1 }
                else if (c == 41) { pc += 1 }
                else if (c == 91) { bo += 1 }
                else if (c == 93) { bc += 1 }
            }
            if (opens == closes && po == pc && bo == bc && isTerminatorStatement(t)) {
                pending = true
                pendingDepth = level
                pendingIndent = here
            }
            if (!python) { level += opens - closes }
        }
        i += 1
    }
    return None
}

/// 行首缩进宽度（Tab 记 8）。
func indentOf(line: String): Int64 {
    var w: Int64 = 0
    for (c in line) {
        if (c == 32) { w += 1 }
        else if (c == 9) { w += 8 }
        else { break }
    }
    return w
}

/// 混合职责：函数体**既读又写**（输入侧与输出侧的 I/O 都有），中间还夹着够分量的计算逻辑
/// （决策点 ≥ CONF_MIXED_DECISIONS）。AI 只实现功能不考虑设计 → 一个函数既读盘又算数又写结果。
/// 「计算逻辑」的门槛：原实现是「含 for / match / JSON. 就算」——读个文件循环一遍也报，
/// 实测引擎仓 78 个文件报 77 条（占列出罚分 16%）；只读不写的（读配置再分支）也不算混合职责。
func hasMixedResponsibility(bodyLines: ArrayList<String>, decisions: Int64): Bool {
    if (decisions < CONF_MIXED_DECISIONS) { return false }
    var hasRead = false
    var hasWrite = false
    var strState: Int64 = 0
    for (line in bodyLines) {
        let (t, nextState) = stripCode(line, strState)
        strState = nextState
        if (!hasRead) {
            for (mark in IO_READ_MARKS) {
                if (indexOfStr(t, mark) >= 0) { hasRead = true; break }
            }
        }
        if (!hasWrite) {
            for (mark in IO_WRITE_MARKS) {
                if (indexOfStr(t, mark) >= 0) { hasWrite = true; break }
            }
        }
        if (hasRead && hasWrite) { return true }
    }
    return false
}

/// 归一化函数体：去空白与注释后的拼接及其字节数。
struct NormalizedBody {
    let hash: String
    let bytes: Int64
    init(hash: String, bytes: Int64) {
        this.hash = hash
        this.bytes = bytes
    }
}

/// 归一化函数体哈希（去空白+注释后的 SHA-256 前 16 字符）与字节数。
/// 两个函数 hash 相同 = 体完全一样 = 复制粘贴（**完全一致**，不是相似度）。
func normalizedBodyHash(bodyLines: ArrayList<String>): NormalizedBody {
    let sb = StringBuilder()
    for (line in bodyLines) {
        let t = line.trimAscii()
        if (t.isEmpty() || t.startsWith("//") || t.startsWith("#")) { continue }
        sb.append(t)
        sb.append("\n")
    }
    let text = sb.toString()
    return NormalizedBody(sha256HexOf(text)[..16], Int64(text.size))
}

/// 语义层检测主入口：圈复杂度 / 参数滥用 / 不可达代码 / 混合职责 / 近重复。
///
/// 【函数体 = 索引记录的范围】声明行到扫描器定下的 `endLine`（闭合花括号那一行）。
/// 原实现把「声明行到**下一个符号**的声明行」当函数体：
///   ① 无体声明（接口 / 抽象方法）的「体」是下一段毫不相干的代码；
///   ② 索引不到的嵌套函数整段算给外层函数（实测 mcpCallTool 被报圈复杂度 267）；
///   ③ 文件里最后一个符号的「体」一直延伸到文件末尾。
/// 范围未知（endLine = 0）的符号不下结论。
func detectSemanticIssues(graph: CodeGraph, findings: ArrayList<Finding>,
                          cap: CapDropCounter, nearDup!: Bool): Unit {
    let perFile = HashMap<String, Int64>()
    // 归一化哈希 → 首个相同哈希的函数 id（近重复检测）
    let bodyHash = HashMap<String, String>()
    // 框架入口（override / 虚函数 / 槽）与运算符重载的签名由基类 / 语言规定：
    // 「God 签名，API 设计缺失」对它们不成立（Canvas 的 setTransform(6 个 double) 是规范定的）
    let entryKeys = frameworkEntryKeys(graph)
    for (fe in graph.files) {
        let content = readFileText(graph.root + "/" + fe.relPath)
        let srcLines = ArrayList<String>()
        match (content) {
            case Some(t) =>
                for (l in t.split("\n")) { srcLines.add(l) }
            case None => ()
        }
        if (srcLines.size == 0) { continue }
        let python = fe.lang == "python"
        for (s in fe.symbols) {
            var isFunc = false
            match (s.kind) {
                case Func => isFunc = true
                case _ => ()
            }
            if (!isFunc || s.declOnly) { continue }
            if (s.endLine < s.line || s.endLine == 0) { continue }
            let last = if (s.endLine <= Int64(srcLines.size)) { s.endLine } else { Int64(srcLines.size) }
            let body = ArrayList<String>()
            var cl = s.line
            while (cl <= last) {
                body.add(srcLines[cl - 1])
                cl += 1
            }
            let sig = if (s.sig.isEmpty()) { srcLines[s.line - 1] } else { s.sig }
            let id = "f:" + fe.relPath + ":" + s.line.toString() + ":" + s.name
            // 单函数粒度兜底：一个函数的异常只跳过它自己，
            // 不再把整层语义检测清空（此前 Invalid range 一抛全仓丢失）。
            try {
                // ① 圈复杂度 >阈值 → HighComplexity
                let cc = cyclomaticComplexity(body)
                if (cc > CONF_COMPLEXITY) {
                    bumpFinding(findings, perFile, cap, HighComplexity, fe.relPath, s.line, s.name,
                        "圈复杂度 ${cc}（阈值 ${CONF_COMPLEXITY}）——决策路径爆炸，难测试/易藏 bug")
                }
                // ② 参数数超阈值或 Bool 标志参 → ParameterAbuse
                let pi = analyzeSig(sig)
                var fixedSignature = entryKeys.contains(fe.lang + "\u{1f}" + s.qual)
                if (!fixedSignature && hasWord(srcLines[s.line - 1], "operator")) { fixedSignature = true }
                if (pi.ok && !fixedSignature) {
                    if (pi.count > CONF_PARAMS) {
                        bumpFinding(findings, perFile, cap, ParameterAbuse, fe.relPath, s.line, s.name,
                            "${pi.count} 个参数（阈值 ${CONF_PARAMS}）——God 签名，API 设计缺失")
                    } else if (pi.hasBool && pi.count >= 2) {
                        bumpFinding(findings, perFile, cap, ParameterAbuse, fe.relPath, s.line, s.name,
                            "Bool 标志参控制分支——违反 SRP，应拆分为两个函数")
                    }
                }
                // ③ 不可达代码 → DeadBranch
                match (hasDeadBranch(body, s.line, python)) {
                    case Some(ln) =>
                        bumpFinding(findings, perFile, cap, DeadBranch, fe.relPath, ln, s.name,
                            "return/throw 后同层级仍有语句——不可达代码残余")
                    case None => ()
                }
                // ④ 混合职责 → MixedResponsibility
                if (hasMixedResponsibility(body, cc - 1)) {
                    bumpFinding(findings, perFile, cap, MixedResponsibility, fe.relPath, s.line, s.name,
                        "同函数内混合文件 I/O 与 ${cc - 1} 个决策点——不可组合/不可测试")
                }
                // ⑤ 近重复 → NearDuplicate（归一化哈希比较；太短的体不比；只比声明头之后的体）。
                // ⚠️ 它与 AST 路径的 duplicate-body 是同一件事（去注释 / 空白后逐字节相同）：
                // 语法树可用时那边按准确的节点边界报，这里不再报第二遍——原先同一对函数被
                // 罚两次（8 + 5），实测 deepDolphin 的 showReceipt / stateTone 同时出现在两份清单里。
                let nb = normalizedBodyHash(pureBodyLines(srcLines, s, last, python))
                if (nearDup && nb.bytes >= CONF_NEAR_DUP_MIN_BYTES) {
                    match (bodyHash.get(nb.hash)) {
                        case Some(firstId) =>
                            if (firstId != id) {
                                bumpFinding(findings, perFile, cap, NearDuplicate, fe.relPath, s.line, s.name,
                                    "函数体与 ${firstId} 归一化后完全一致——应提取共享逻辑")
                            }
                        case None => bodyHash[nb.hash] = id
                    }
                }
            } catch (e: Exception) {
                Log.warn("语义检测跳过单函数 ${id}: ${e.message}")
            }
        }
    }
}
