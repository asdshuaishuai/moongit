// graph/extract.cj — 词法提取：语言识别 + 符号声明 + import。
//
// 【零正则的取舍】仓颉标准库没有正则；与其引入依赖或自研正则引擎，
// 这里用「字节级 tokenizer + 关键词规则表 + 穷尽 match」——
// 对标识符提取这个场景，ASCII 词法与正则等价，且每条规则可单测。
// 多字节 UTF-8（中文注释等）在字节层天然不是标识符字符，
// 会正确地被当成分隔符 —— 这个「巧合」是 UTF-8 编码的性质，可依赖。
//
// 【AI 原生的落点】关键词 → SymKind 的映射是**穷尽 match + 规则表**：
// 新语言 = 往词表加几个词，种类语义轴由类型系统保证不会写错。
package moongit.graph

import std.collection.*
import moongit.util.*

// MARK: - 语言识别

/// ASCII 小写（扩展名识别用；不做完整 Unicode case 映射 —— 没必要）
func lowerAscii(s: String): String {
    let bytes = s.toArray()
    let out = ArrayList<UInt8>()
    for (b in bytes) {
        if (b >= 65 && b <= 90) {
            out.add(b + 32)
        } else {
            out.add(b)
        }
    }
    return fromUtf8Lossy(out.toArray())
}

/// 按扩展名识别语言。返回空串 = 图谱不覆盖（文档/配置/二进制…）。
public func detectLang(path: String): String {
    let p = lowerAscii(path)
    if (p.endsWith(".swift")) { return "swift" }
    if (p.endsWith(".cj")) { return "cangjie" }
    if (p.endsWith(".ts") || p.endsWith(".tsx") || p.endsWith(".js")
        || p.endsWith(".jsx") || p.endsWith(".mjs") || p.endsWith(".cjs")) {
        return "ts"
    }
    if (p.endsWith(".py")) { return "python" }
    if (p.endsWith(".go")) { return "go" }
    if (p.endsWith(".rs")) { return "rust" }
    if (p.endsWith(".java")) { return "java" }
    if (p.endsWith(".kt") || p.endsWith(".kts")) { return "kotlin" }
    if (p.endsWith(".c") || p.endsWith(".h") || p.endsWith(".cc")
        || p.endsWith(".cpp") || p.endsWith(".hpp")) {
        return "c"
    }
    return ""
}

// MARK: - 词法

func buildKeywords(): HashSet<String> {
    let s = HashSet<String>()
    let words = ["func", "fn", "def", "function", "class", "struct", "interface", "protocol",
        "trait", "enum", "extension", "impl", "type", "typealias", "typedef",
        "let", "var", "const", "return", "if", "else", "for", "while", "in",
        "public", "private", "internal", "fileprivate", "static", "final",
        "abstract", "async", "open", "mut", "pub", "export", "default",
        "sealed", "data", "readonly", "unsafe", "extern", "suspend", "inline",
        "override", "virtual", "partial", "where", "get", "set", "init", "new",
        "case", "match", "try", "catch", "throw", "throws", "rethrows", "self",
        "super", "this", "nil", "null", "true", "false", "import", "from", "use",
        "package", "namespace", "operator", "prop", "companion", "object"]
    for (w in words) { s.add(w) }
    return s
}

let KEYWORDS: HashSet<String> = buildKeywords()

/// 判断 ASCII 字节是否属于标识符（[A-Za-z0-9_]）
func isIdentByte(b: UInt8): Bool {
    return (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || b == 95
}

/// 流式 token 遍历：**热路径专用**。tokenize 会为每行分配一个
/// ArrayList + 每个标识符一个 String；遍历整棵仓库时那是每行一次的临时分配
/// （性能审查 §5.1/§6.1 的「中间集合与循环内分配」）。
/// 本函数只分配被消费的 token 字符串本身，不物化数组。
public func forEachToken(line: String, action: (String) -> Unit): Unit {
    var cur = ArrayList<UInt8>()
    for (b in line) {
        if (isIdentByte(b)) {
            cur.add(b)
        } else if (cur.size > 0) {
            action(fromUtf8Lossy(cur.toArray()))
            cur = ArrayList<UInt8>()
        }
    }
    if (cur.size > 0) {
        action(fromUtf8Lossy(cur.toArray()))
    }
}

/// 声明关键词的字节表（模块级预计算一次；mayDeclare 热路径上零分配比较用）。
/// ⚠️ 必须覆盖各语言表（DECL_TABLES）的全部声明词：仓颉的扩展关键词是
/// extend（漏了它，`extend String {` 在 mayDeclare 前置过滤就被短路，
/// 根本走不到 gateDeclTokens 的声明提取）。
func declKeywordBytes(): Array<(UInt8, Array<UInt8>)> {
    let words = ["func", "fn", "def", "function", "class", "struct", "interface",
        "protocol", "trait", "enum", "extension", "impl", "type", "typealias", "typedef",
        "extend"]
    let out = ArrayList<(UInt8, Array<UInt8>)>()
    for (w in words) {
        let b = w.toArray()
        out.add((b[0], b))
    }
    return out.toArray()
}

let DECL_KEYWORDS: Array<(UInt8, Array<UInt8>)> = declKeywordBytes()

/// C 系函数名的**唯一取法**：**紧跟参数列表 `(` 的那个标识符**。
///
/// ⚠ 为什么不能按「第二个 token」取：C++ 的函数名前面可以带
///   · **作用域限定**：`EngineCli::EngineResult classifyResult(…)`
///   · **const / 指针 / 引用限定**：`const EngineDoctor::Report *doctorReport() const`
///   · **类名（成员函数定义）**：`bool AgentCore::runEngineRaw(…)`
///   这三种形态里「第二个 token」都是**类型名的一部分**（`EngineResult` /
///   `Report` / `AgentCore`），不是函数名 ⇒ 按第二个 token 取会把真函数名判丢。
///   ⇒ 后果不是「少一个符号」那么简单：**函数体边界是按「本符号行 → 下一个
///   符号行」算的**（置信度的圈复杂度/参数滥用都靠它）⇒ 中间那些没被认出的
///   定义不占边界 ⇒ 前一个函数的「函数体」把中间函数的 if/for 全吞进去
///   ⇒ **凭空多出高复杂度告警**（实测：`clipNote`（2 行）被判「圈复杂度 13」，
///   因为它后面那个 `AgentCore::runEngineRaw` 没被认出来）。
///
/// 判定：
///   · 只对 C 系语言生效（M8 纪律）；
///   · 预处理器行不算（`#define FOO(x)` 长得像函数）；
///   · `(` 紧跟标识符（允许空白）；**`(` 紧跟在 `>` 之后是模板实参转换**
///     （`static_cast<QString>(x)`）⇒ 不算；
///   · 名字**前面至少要有一个标识符**（返回类型）——`foo(1);` 是调用不是定义；
///   · 名字前面那个标识符**不能是关键字**（return / if / while / for / catch …）
///     ——`return foo(x);` 是返回语句不是定义；
///   · 名字本身不能是关键字。
func cFuncNameBeforeParen(line: String, lang: String): Option<String> {
    if (lang != "c") { return None }
    // 预处理器行不是函数定义
    if (line.trimAscii().startsWith("#")) { return None }
    let lb = line.toArray()
    let n = Int64(lb.size)
    var i: Int64 = 0
    var lastIdent: String = ""
    var hasLast = false
    while (i < n) {
        let b = lb[i]
        if (isIdentByte(b)) {
            let st = i
            while (i < n && isIdentByte(lb[i])) { i += 1 }
            let tok = fromUtf8Lossy(lb[st..i])
            // 跳过空白，看下一个字节是不是 '('
            var j = i
            while (j < n && (lb[j] == 32 || lb[j] == 9)) { j += 1 }
            if (j < n && lb[j] == 40) {
                // `(` 紧跟在 '>' 之后 = 模板实参转换（static_cast<T>(x)）⇒ 不是定义
                if (j > 0 && lb[j - 1] == 62) { return None }
                if (!hasLast) { return None }                       // 前面没有返回类型
                if (KEYWORDS.contains(lastIdent)) { return None }    // return / if / …
                if (KEYWORDS.contains(tok)) { return None }
                if (!looksLikeName(tok)) { return None }
                return Some(tok)
            }
            lastIdent = tok
            hasLast = true
        } else {
            i += 1
        }
    }
    return None
}

/// C 系函数定义的词法识别：C 没有函数关键字（`type name(args) {`），
/// 关键词表扫不到 ⇒ 同文件函数互调全被幻觉调用误报（实测 conc-demo）。
/// 形态判定：剥注释后行匹配「返回类型 name(」且行含 `{`（定义而非声明）。
/// 声明（以 ; 结尾）不算。
func cStyleFuncName(line: String, lang: String): Option<String> {
    // ⚠️ M8：C 形态兜底只对 **C 系**语言生效。原来它对全部 9 种语言都生效，
    // 而形态判定只看「首 token 非关键字 + 次 token 后跟 ( + 行含 {」——
    // 于是 `it("works", () => { ... })` 这种「方法调用 + 花括号块」被编出
    // 一个叫 expect 的假符号（推演见审查记录）。假符号还会进 defFiles，
    // 把真实的调用点掩盖掉，让 unresolved 检测漏报。
    // 与 extract.cj 自己写的那句「误截的后果是少一个符号，不会编一个」相反。
    // 只有 C/C++（无函数关键字）需要这个兜底；其余语言有 func/fn/def/...
    // ⚠️ 函数名的取法见 cFuncNameBeforeParen（限定名/限定返回类型都在那里处理）
    // 必须是定义（含 {）而非声明（; 结尾）
    if (!line.contains("{")) { return None }
    match (cFuncNameBeforeParen(line, lang)) {
        case Some(name) => return Some(name)
        case None => return None
    }
}

/// C 系函数**签名**（行内**没有** `{`）的词法识别 —— 支撑 **Allman 风格**
/// （`{` 另起一行）。
///
/// ⚠ 为什么必须有它：cStyleFuncName 要求**行内含 `{`**，那是 K&R 风格
///   （`Type name(args) {`）。而 Allman 风格把 `{` 放到**下一行**：
///   ```
///   Type name(args)
///   {
///   ```
///   ⇒ 签名行里没有 `{` ⇒ cStyleFuncName 判否 ⇒ **自由函数整个不进符号表**。
///   ⇒ 后果不是「少一个符号」那么简单：置信度的 unresolved-call（幻觉调用）
///   判据是「调用了全仓没有定义的名字」⇒ **对真实自由函数的调用被误报成幻觉 API**。
///   ⇒ 实测（deepin 客户端，`src/**/*.cpp` 顶层自由函数 364 个）：**只有 1 个**
///   是 `{` 同行，其余 **363 个（99.7%）全部漏扫** ⇒ 置信度报告里 295 条
///   「幻觉调用」是假的（实测 `clipNote` / `runOne` / `defaultToolName`
///   这些**确实存在**的函数被点名）。
///
/// 判定与 cStyleFuncName **同源**（同一个取名函数 cFuncNameBeforeParen ⇒
/// 两种写法（`{` 同行 / `{` 另起一行）的口径**必须一致**），但：
///   · **不要求行内含 `{`**（那是下一行的事 —— 由调用方的待定状态定性）；
///   · **要求行不以 `;` 结尾**（`;` 结尾 = 原型声明，不是定义）。
///
/// 返回 Some(name) = 这一行**疑似**函数签名的开头；「是不是定义」由调用方看
/// 下一行是不是 `{` 来定（见 scanSource 的 pendingCSig 状态）。
func cStyleFuncSignature(line: String, lang: String): Option<String> {
    if (lang != "c") { return None }
    // 行内已有 `{` ⇒ 那是 cStyleFuncName 的同行形态，不走这条
    if (line.contains("{")) { return None }
    // 以 `;` 结尾 = 声明（原型），不是定义
    if (line.trimAscii().endsWith(";")) { return None }
    return cFuncNameBeforeParen(line, lang)
}

/// Go **带接收者**的方法声明：`func (r *Rect) Area() float64`。
///
/// ⚠️ G1：tokenize 后接收者变量名（r）紧跟在 `func` 之后，而 scanDeclLine 的
/// `Some(kind)` 分支无条件取 `tokens[i+1]` —— 方法真名（Area）整体从符号索引
/// 消失、接收者被抽成符号。连锁后果：方法声明行里 `Area(` 恰好是「自由调用」
/// 形态，而 defFiles 里没有 Area ⇒ 幻觉 API 假指控（健康 Go 文件被打低分）。
///
/// 判定用剥过注释的行：trim 后以 `func` 开头、且 `func` 之后只跟空白（空格/tab，
/// 任意数量）直到接收者的 `(`，即方法声明；方法名 = 接收者右括号之后、
/// 第一个 `(` 之前的**最后一个**标识符
/// （`func (r *Rect) Area() float64` → Area；跨行参数签名同样成立）。
/// 接收者内的变量名（r/q/…）绝不进符号表。
///
/// ⚠️ 入口只判 `func` 前缀，括号定位全部交给下面的字节循环——它本来就只容忍
/// 「任意数量的空格/tab 之后紧跟 '('」。原先这里硬判 startsWith("func (") /
/// startsWith("func(") 两种写法当 gate，`func\t(…)`（tab）与 `func  (…)`
/// （双空格）落不进任何一支，方法声明回落旧路径（scanDeclLine 把接收者变量名
/// 抽成符号，G1 缺陷的残留入口）。`func` 后接非空白非括号（如 `function make(`）
/// 仍会被字节循环拒绝，不会误判。
func goReceiverMethodName(line: String): Option<String> {
    let t = line.trimAscii()
    if (!t.startsWith("func")) { return None }
    let b = t.toArray()
    let n = Int64(b.size)
    // 接收者左括号：func 之后只许空白，然后是 '('
    var open1: Int64 = -1
    var i: Int64 = 4   // 跳过 "func"
    while (i < n) {
        if (b[i] == 40) { open1 = i; break }
        if (b[i] != 32 && b[i] != 9) { return None }
        i += 1
    }
    if (open1 < 0) { return None }
    // 接收者右括号：接收者类型里不会有嵌套括号，取第一个 ')' 即可
    var close1: Int64 = -1
    var j: Int64 = open1 + 1
    while (j < n) {
        if (b[j] == 41) { close1 = j; break }
        j += 1
    }
    if (close1 < 0) { return None }
    // 接收者之后到第一个 '('（方法参数表）之间取最后一个标识符 = 方法名
    var open2: Int64 = -1
    var k: Int64 = close1 + 1
    while (k < n) {
        if (b[k] == 40) { open2 = k; break }
        k += 1
    }
    if (open2 < 0) { return None }
    var name = ""
    var st: Int64 = -1
    var m: Int64 = close1 + 1
    while (m < open2) {
        if (isIdentByte(b[m])) {
            if (st < 0) { st = m }
        } else {
            if (st >= 0) {
                name = fromUtf8Lossy(b[st..m])
                st = -1
            }
        }
        m += 1
    }
    if (st >= 0) { name = fromUtf8Lossy(b[st..open2]) }
    if (name.isEmpty()) { return None }
    if (!looksLikeName(name)) { return None }
    return Some(name)
}

func findSubstr(hay: String, needle: String): Option<Int64> {
    let h = hay.toArray()
    let nd = needle.toArray()
    let n = Int64(h.size)
    let m = Int64(nd.size)
    if (m == 0 || m > n) { return None }
    var i: Int64 = 0
    while (i + m <= n) {
        var ok = true
        var j: Int64 = 0
        while (j < m) {
            if (h[i + j] != nd[j]) { ok = false; break }
            j += 1
        }
        if (ok) { return Some(i) }
        i += 1
    }
    return None
}

/// 这一行**可能**含声明关键词（字节级词扫描，零分配）。
/// scanSource 用它做前置过滤：绝大多数代码行直接跳过 tokenize，
/// 把「每行一个 ArrayList」的分配压到只剩候选行。
public func mayDeclare(line: String): Bool {
    let n = Int64(line.size)
    var i: Int64 = 0
    while (i < n) {
        var b0 = line[i]
        if (b0 >= 65 && b0 <= 90) { b0 = b0 + 32 }
        // 词首字节不匹配任何关键词的首字节 → 跳到词尾
        var j = i
        while (j < n && isIdentByte(line[j])) { j += 1 }
        if (j > i) {
            for ((first, kb) in DECL_KEYWORDS) {
                if (first == b0 && kwMatchAt(line, i, j, kb)) {
                    return true
                }
            }
        }
        i = if (j > i) { j } else { i + 1 }
    }
    return false
}

/// 比较 line[start..end)（大小写不敏感）是否等于关键词字节
func kwMatchAt(line: String, start: Int64, end: Int64, kb: Array<UInt8>): Bool {
    if (end - start != Int64(kb.size)) { return false }
    var k: Int64 = 0
    while (k < Int64(kb.size)) {
        var b = line[start + k]
        if (b >= 65 && b <= 90) { b = b + 32 }
        if (b != kb[k]) { return false }
        k += 1
    }
    return true
}

/// 把一行切成标识符 token 序列。字节级扫描：
/// 非 ASCII 字节（中文注释等）天然是分隔符，不会被误认成标识符。
public func tokenize(line: String): ArrayList<String> {
    let out = ArrayList<String>()
    var cur = ArrayList<UInt8>()
    for (b in line) {
        if (isIdentByte(b)) {
            cur.add(b)
        } else {
            if (cur.size > 0) {
                out.add(fromUtf8Lossy(cur.toArray()))
                cur = ArrayList<UInt8>()
            }
        }
    }
    if (cur.size > 0) {
        out.add(fromUtf8Lossy(cur.toArray()))
    }
    return out
}

/// 代码清洗：把注释与字符串字面量从扫描视野里摘掉。
///
/// ⚠️ 两轮实跑暴露的三个坑，全在这里修：
///   ① 内嵌 JS 的大段字符串：`function m()` 被当成仓颉声明（假阳性「单字符名」）
///   ② 文档注释里的裸 `"`（如「遇未转义 " 结束」）把状态机带进字符串状态，
///      后续所有行被误吞 —— 所以**整行注释必须先行跳过**，不参与剥串
///   ③ 行尾注释里的引号同理 —— 代码态遇到 `//` 直接截断，不再向后看
///
/// 状态：0 = 代码；1 = 单行字符串内（EOL 自动复位——常规串不跨行）；
///       2 = 多行字符串内（碰 """ 才结束）；3 = 块注释内（碰 */ 才结束）；
///       4 = Python 三单引号字符串内（碰 ''' 才结束）。
/// 后两个是 M9 补的：原先块注释与 `'''` 完全没接，
/// 注释里的“代码”被提成真符号、跨行 docstring 把后续整段拉进 token 流。
/// 返回 (清洗后的代码, 新状态)。
public func stripCode(line: String, inState: Int64): (String, Int64) {
    let n = Int64(line.size)
    // ⚡ 零拷贝快路径：**代码态且整行无引号** ⇒ 结果等价于「只剥注释」，
    // 用字节切片直接给出，不再分配一个 `ArrayList<UInt8>` + 拷一份字符串。
    // 覆盖绝大多数代码行（纯代码行、以及带 `//` / `#` 注释的行）。
    // 实测动机：`graph tree deepAutoTest --json` 仅 0.25s，却在一次构建里吃掉 137 MB ——
    // 峰值不是「算得慢」，是**逐行分配**把 GC 峰值推上去的（并发只会同时放大它）。
    if (inState == 0) {
        var special = false
        var i: Int64 = 0
        while (i < n) {
            let b = line[i]
            if (b == 34 || b == 39) { special = true; break }   // " 或 '
            if (b == 47 && i + 1 < n && line[i + 1] == 42) { special = true; break }   // /*
            i += 1
        }
        if (!special) { return (stripLineComment(line), 0) }
    }
    let trimmed = line.trimAscii()
    // ① 整行注释：不参与剥串、不改状态（文档注释里的引号不该影响代码扫描）
    //
    // ⚠️ M9 的例外：「整行就是一个**不闭合**的 /*」必须把状态改成 3。
    // 否则这一行之后的所有内容都被当成代码，块注释里的“代码”全进 token 流。
    if (wholeLineComment(trimmed)) {
        if (inState == 0 && trimmed.startsWith("/*")) {
            // 整行以 `/*` 开头有两种：不闭合（要置状态 3），以及**同行闭合**
            // —— 后者后面可能还有代码（`/* 注 */ let z = 2`），整行丢弃会把
            // 真代码吃掉。所以只有不闭合的那种提前返回，其余交给下面的状态机。
            if (findSubstr(trimmed[2..], "*/").isNone()) {
                return ("", 3)
            }
        } else {
            return ("", inState)
        }
    }
    let out = ArrayList<UInt8>()
    var state = inState
    var i: Int64 = 0
    while (i < n) {
        let b = line[i]
        if (state == 0) {
            // 行内注释：截断（②的修法）
            if (b == 47 && i + 1 < n && line[i + 1] == 47) { break }   // //
            // M9：`/* */` 块注释原先完全没接 —— 注释里的代码被当成真符号。
            // 同行闭合就跳过去（后面的仍是代码）；不闭合则进入块注释状态。
            // ⚠️ 闭合跨度以**一个空格字节占位**，不是让它完全消失：注释在真实
            // 语言里等价于空白，是 token 边界。直接跳过会把 `a/*c*/b(` 拼成
            // `ab(` —— 相邻标识符粘连后 unresolved-call 检测编造一个全仓不存在
            // 的 ab。与无引号快路径 stripLineComment 的「`*/` 之后拼一个空格」
            // 逐字等价（两条路径同一语义）。
            if (b == 47 && i + 1 < n && line[i + 1] == 42) {
                match (findSubstr(line[i + 2..], "*/")) {
                    case Some(rel) =>
                        out.add(UInt8(32))
                        i = i + 2 + rel + 2
                        continue
                    case None => state = 3; break
                }
            }
            // M9：行内 `#` / `--` 注释也没剥（`x = 1  # class Foo ...`
            // 里的 class 被提成真符号）。**必须前导空白才认** ——
            // `i--` / `a--b` 是合法代码，见到就切会把代码吃掉。
            if (i > 0 && (line[i - 1] == 32 || line[i - 1] == 9)) {
                if (b == 35) { break }
                if (b == 45 && i + 1 < n && line[i + 1] == 45) { break }
            }
            // 多行字符串开
            if (b == 34 && i + 2 < n && line[i + 1] == 34 && line[i + 2] == 34) {
                var closedSameLine = false
                var j = i + 3
                while (j + 2 < n) {
                    if (line[j] == 34 && line[j + 1] == 34 && line[j + 2] == 34) {
                        closedSameLine = true
                        break
                    }
                    j += 1
                }
                if (closedSameLine) {
                    i = j + 3
                    continue
                }
                state = 2
                i += 3
                continue
            }
            // M9：Python 的三单引号字符串原先只按单引号处理 —— 跨行 docstring
            // 的后续整段内容进入 token 流，把里面的英文词当标识符。
            if (b == 39 && i + 2 < n && line[i + 1] == 39 && line[i + 2] == 39) {
                var closedSameLine4 = false
                var j4 = i + 3
                while (j4 + 2 < n) {
                    if (line[j4] == 39 && line[j4 + 1] == 39 && line[j4 + 2] == 39) {
                        closedSameLine4 = true
                        break
                    }
                    j4 += 1
                }
                if (closedSameLine4) {
                    i = j4 + 3
                    continue
                }
                state = 4
                i += 3
                continue
            }
            if (b == 34) {
                state = 1
                i += 1
                continue
            }
            if (b == 39) {
                var j = i + 1
                var done = false
                while (j < n) {
                    if (line[j] == 92) { j += 2; continue }
                    if (line[j] == 39) { done = true; break }
                    j += 1
                }
                i = if (done) { j + 1 } else { n }
                continue
            }
            out.add(b)
            i += 1
        } else if (state == 1) {
            if (b == 92) { i += 2; continue }
            // ⚠️ 插值字符串感知：`${…}` 段内的引号不参与外层配对。
            // 原实现不认插值——`${Json.strAt(s, "name", "")}` 的内嵌引号被当成
            // 字符串闭合，name/kind/git 等片段泄漏进剥后文本成为**假 token**，
            // 被 buildGraph 的自由调用扫描编出全仓不存在的幻觉指控（实证
            // cli.cj:2382 的 unresolved-call "namekindgit"，name=泄漏 token 粘连）。
            // 跳过策略：花括号深度计数到配平；段内嵌套串跳到其闭合引号
            // （转义与 `${` 不再递归——两层插值在仓内无实例，近似可接受）。
            // 取舍：Cangjie/Swift/Kotlin/TS 的 `${…}` 都是插值，统一按插值处理；
            // 无插值语义的语言（C/Go）里 `${x}` 是字面文本，多剥的代价是
            // 少一个 token（漏引用），不剥的代价是多一个假 token（假指控）——
            // 假指控更糟，与 stripCode 的既有一贯方向（误截的后果是少不是编）相反处
            // 在这里必须选剥。
            if (b == 36 && i + 1 < n && line[i + 1] == 123) {
                var depth: Int64 = 1
                i += 2
                while (i < n && depth > 0) {
                    let c = line[i]
                    if (c == 123) {
                        depth += 1
                    } else if (c == 125) {
                        depth -= 1
                    } else if (c == 34) {
                        // 插值内的嵌套字符串：跳到其闭合引号（转义跳 2）
                        i += 1
                        while (i < n) {
                            if (line[i] == 92) { i += 2; continue }
                            if (line[i] == 34) { break }
                            i += 1
                        }
                    }
                    i += 1
                }
                continue
            }
            if (b == 34) {
                state = 0
                i += 1
                continue
            }
            i += 1
        } else if (state == 2) {
            if (b == 34 && i + 2 < n && line[i + 1] == 34 && line[i + 2] == 34) {
                state = 0
                i += 3
                continue
            }
            i += 1
        } else if (state == 4) {
            // 三单引号字符串内
            if (b == 39 && i + 2 < n && line[i + 1] == 39 && line[i + 2] == 39) {
                state = 0
                i += 3
                continue
            }
            i += 1
        } else {
            // state == 3：块注释内。只找 */，其余一律不当代码。
            if (b == 42 && i + 1 < n && line[i + 1] == 47) {
                state = 0
                i += 2
                continue
            }
            i += 1
        }
    }
    // ③ 单行串不跨行：行尾仍在串内 → 复位（否则一个孤儿引号吞掉整个文件）
    if (state == 1) { state = 0 }
    return (fromUtf8Lossy(out.toArray()), state)
}

/// 只剥注释、不处理字符串状态 —— 供 `stripCode` 的**无引号快路径**使用。
/// 规则必须与 `stripCode` 状态 0 逐字等价（尤其 `*/` 开头**不算**整行注释，
/// 那是它与 `stripComment` 的一处既有差异）。零拷贝：无注释时原样返回。
func stripLineComment(line: String): String {
    let n = Int64(line.size)
    var s: Int64 = 0
    while (s < n && (line[s] == 32 || line[s] == 9)) { s += 1 }
    if (s < n) {
        let b0 = line[s]
        let b1: UInt8 = if (s + 1 < n) { line[s + 1] } else { 0 }
        // 注：本函数唯一调用点（stripCode 快路径入口）已把含 `/*` 的行走慢路径，
        // 故下面的行首 `/*` 半支与行内 `/*...*/` 闭合支当前不可达——保留作
        // 镜像防御（本函数若被独立复用仍语义完整），勿据「没被执行」删除。
        if (b0 == 47 && (b1 == 47 || b1 == 42)) { return "" }   // // 或 /*
        if (b0 == 42 && b1 != 47) { return "" }                 // * 续行（`*/` 不算）
        if (b0 == 35) { return "" }                             // #
        if (b0 == 45 && b1 == 45) { return "" }                 // --
    }
    var i: Int64 = 0
    while (i + 1 < n) {
        if (line[i] == 47 && line[i + 1] == 47) { return line[0..i] }   // 行内 //
        // M9：同行闭合的 `/* ... */`（不闭合的那种走 stripCode 的块注释状态）
        if (line[i] == 47 && line[i + 1] == 42) {
            match (findSubstr(line[i + 2..], "*/")) {
                case Some(rel) =>
                    // `*/` 之后仍是代码：拼回来继续剥（尾部可能还有 // 或 # 注释）
                    return stripLineComment(line[0..i] + " " + line[i + 2 + rel + 2..])
                case None => return line[0..i]
            }
        }
        // M9：行内 `#` / `--`。前导空白才认 —— `i--` 与 URL 里的 `#`
        // 都不该切（那会把代码吃掉）。
        if (i > 0 && (line[i - 1] == 32 || line[i - 1] == 9)) {
            if (line[i] == 35) { return line[0..i] }
            if (line[i] == 45 && line[i + 1] == 45) { return line[0..i] }
        }
        i += 1
    }
    return line
}

/// 整行注释前缀判定（与 stripComment 的入口条件一致）
func wholeLineComment(trimmed: String): Bool {
    if (trimmed.isEmpty()) { return false }
    let b0 = trimmed[0]
    let b1: UInt8 = if (trimmed.size > 1) { trimmed[1] } else { 0 }
    if (b0 == 47 && (b1 == 47 || b1 == 42)) { return true }   // // /*
    if (b0 == 42 && b1 != 47) { return true }                  // * 续行
    if (b0 == 35) { return true }                              // #
    if (b0 == 45 && b1 == 45) { return true }                  // --
    return false
}

/// 去掉行内注释（启发式：整行注释前缀 + `//` 截断）。
/// 字符串里的 `//`（如 URL）会被误截 —— 词法级提取可接受的噪音，
/// 换取的是零字符串状态机复杂度；误截的后果是**少**一个符号，不会编一个。
///
/// ⚠️ 性能审查 §5.2/§6.1：原实现上来就 `line.toArray()` ——
/// 100k 行仓库 = 100k 次整行字节数组分配，而**绝大多数行没有注释**，
/// 结果原样返回。现在零拷贝快路径：按字节索引扫描，未命中 `//` 时原样返回。
func stripComment(line: String): String {
    let n = Int64(line.size)
    // 行首注释前缀（跳前导空白后判首个非空白字节）
    var s: Int64 = 0
    while (s < n) {
        let b = line[s]
        if (b != 32 && b != 9) { break }   // ' ' / '\t'
        s += 1
    }
    if (s < n) {
        let b0 = line[s]
        let b1: UInt8 = if (s + 1 < n) { line[s + 1] } else { 0 }
        if (b0 == 47 && (b1 == 47 || b1 == 42)) { return "" }   // // 或 /*
        if (b0 == 35 || b0 == 42) { return "" }                  // # 或 *
        if (b0 == 45 && b1 == 45) { return "" }                  // --
    }
    // 行内 "//"（切片点落在 ASCII '/' 上，天然是合法 UTF-8 边界）
    var i: Int64 = 0
    while (i + 1 < n) {
        if (line[i] == 47 && line[i + 1] == 47) {
            return line[0..i]
        }
        i += 1
    }
    return line
}

/// 行是否全空白（零分配；替代 trimAscii().isEmpty() 的两次分配）
func blankLine(line: String): Bool {
    for (b in line) {
        if (b != 32 && b != 9 && b != 13) { return false }
    }
    return true
}

/// token 是否像符号名（字母或下划线开头，非关键词/修饰符）。
func looksLikeName(t: String): Bool {
    if (t.isEmpty()) { return false }
    let b0 = t.toArray()[0]
    let letter = (b0 >= 97 && b0 <= 122) || (b0 >= 65 && b0 <= 90) || b0 == 95
    if (!letter) { return false }
    // 出现在声明位置的次 token 若是关键词，说明刚才匹配的不是声明（如 `type` 后跟 `of`）
    return !KEYWORDS.contains(t)
}


// MARK: - 提取

/// 单次源码扫描的全部产出。
public struct SourceFacts {
    public let symbols: ArrayList<SymDecl>
    public let imports: ArrayList<String>
    /// 与 imports 平行的行号数组（未使用 import 的证据定位用）
    public let importLines: ArrayList<Int64>
    public let lineCount: Int64

    public init(symbols: ArrayList<SymDecl>, imports: ArrayList<String>,
                importLines: ArrayList<Int64>, lineCount: Int64) {
        this.symbols = symbols
        this.imports = imports
        this.importLines = importLines
        this.lineCount = lineCount
    }
}

/// 声明关键词 → 符号种类。返回 None = 这行不是声明。
/// go 的 `type X struct` 是双关键词，单独在 scanLine 里特判。
///
/// ⚠️ 本函数的词表是**跨语言混编**的（fn/def/function/trait/protocol 同为
/// Func/Interface），只保留给 scanDeclLine 的包内既有调用点
/// （patchconf.cj / confidence_detect.cj）用；scanSource 的声明提取走
/// DECL_TABLES 的**语言感知**版本（gateDeclTokens）——`def` 只在 python
/// 是函数声明词，在仓颉/TS/Go 里是合法标识符，混编词表把
/// `Json.set(def, …)` 这类调用行编成了 func:Json（实证见 DECL_TABLES）。
func kindOf(word: String): Option<SymKind> {
    match (word) {
        case "func" => Some(Func)
        case "fn" => Some(Func)
        case "def" => Some(Func)
        case "function" => Some(Func)
        case "class" => Some(Class)
        case "struct" => Some(Struct)
        case "interface" => Some(Interface)
        case "protocol" => Some(Interface)
        case "trait" => Some(Interface)
        case "enum" => Some(Enum)
        case "extension" => Some(Extension)
        case "impl" => Some(Extension)
        case _ => None
    }
}

// MARK: - 语言门控与作用域（假符号根治）

/// 每种语言**真正认**的声明词表（scanSource 专用）。
///
/// ⚠️ 假符号 (a) 的根因：kindOf 的混编词表让「声明词后第一个像名字的
/// token」在撞名时把 RHS/实参顶成名字。实证（引擎自身图谱，graph symbol Json）：
/// src/flow/status.cj:703 的 `let def = Json.obj()`（def 撞 python 声明词，
/// 取 RHS 的 Json）与 704/705 的 `Json.set(def, "isCurrent", …)`（def 是
/// **实参**，tokens[3] 恰是 Json）各编出一个 kind=func、name=Json 的假符号
/// ——三个假符号里只有一个是 let 行，只拦 let 清不了零。门控原则与 M8
/// （cStyleFuncName 只对 C 生效）一致：为 A 语言写的规则不得在 B 语言编符号。
/// 各表只收该语言的保留/声明词（python 不认 interface/enum —— 那两个在
/// python 是合法标识符）。
func buildDeclTables(): HashMap<String, HashSet<String>> {
    let tables = HashMap<String, Array<String>>()
    tables["cangjie"] = ["func", "class", "struct", "interface", "enum", "extend"]
    tables["swift"] = ["func", "class", "struct", "interface", "protocol", "enum", "extension", "typealias"]
    tables["ts"] = ["function", "class", "interface", "enum", "type"]
    tables["python"] = ["def", "class"]
    tables["go"] = ["func", "type", "struct", "interface"]
    tables["rust"] = ["fn", "struct", "enum", "trait", "impl", "type"]
    tables["java"] = ["class", "interface", "enum"]
    tables["kotlin"] = ["class", "interface", "enum"]
    // ⚠ C 系的表**必须含 `class`**：C++ 的类声明 `class Foo {` 用的就是
    //   这个词，而 C++ 的 .h/.cpp 与 C 共用这张表（detectLang 把 .c/.h/.cc/.cpp/.hpp
    //   一律判成 "c"）⇒ 漏了 `class` ⇒ **C++ 的类整个不进符号表**。
    //   实测（deepin 客户端 479 个 C++ 符号）：加之前 `class` 计数为 **0**，
    //   而 `struct` 有 165 个 —— 客户端的 `TrayController` / `PanelWindow` /
    //   `AppModel` 这些类在图谱里**根本不存在**。
    //   ⚠ 代价：C 源码里 `class` 会从普通标识符变成声明词 —— C 里没有
    //   名为 `class` 的标识符（C++ 里它是保留字），实际无碰撞。
    tables["c"] = ["struct", "enum", "typedef", "class"]
    let m = HashMap<String, HashSet<String>>()
    for ((lang, words) in tables) {
        let s = HashSet<String>()
        for (w in words) { s.add(w) }
        m[lang] = s
    }
    return m
}

let DECL_TABLES: HashMap<String, HashSet<String>> = buildDeclTables()

/// kindOf 词表与 type 系特判（type/typealias/typedef）的并集：
/// 「这词在**某个**受支持语言里是声明词」的全集。门控判定 = 在全集里
/// 但不在本语言表里 ⇒ 在这门语言里它是标识符，不是声明。
func buildCrossLangDeclWords(): HashSet<String> {
    let s = HashSet<String>()
    let words = ["func", "fn", "def", "function", "class", "struct", "interface",
        "protocol", "trait", "enum", "extension", "impl", "type", "typealias", "typedef"]
    for (w in words) { s.add(w) }
    return s
}

let CROSS_LANG_DECL_WORDS: HashSet<String> = buildCrossLangDeclWords()

/// 被门控替换掉的 token。必须是 looksLikeName 为 false 的形态
/// （"0" 以数字开头），scanDeclLine 才既不当名字也不当声明词。
let DECL_SENTINEL: String = "0"

/// 扫一行声明。返回 Some((kind, name))。
func scanDeclLine(tokens: ArrayList<String>): Option<(SymKind, String)> {
    var i: Int64 = 0
    while (i < Int64(tokens.size)) {
        let t = tokens[i]
        // go 风格：type X struct / type X interface
        if (t == "type" || t == "typealias" || t == "typedef") {
            if (i + 2 < Int64(tokens.size)) {
                let n = tokens[i + 1]
                let k2 = tokens[i + 2]
                if (n != "=" && looksLikeName(n)) {
                    if (k2 == "struct") { return Some((Struct, n)) }
                    if (k2 == "interface") { return Some((Interface, n)) }
                    return Some((TypeAlias, n))
                }
            } else if (i + 1 < Int64(tokens.size)) {
                let n = tokens[i + 1]
                if (n != "=" && looksLikeName(n)) {
                    return Some((TypeAlias, n))
                }
            }
            i += 1
            continue
        }
        match (kindOf(t)) {
case Some(kind) =>
                                // 名字 = 声明词后第一个像名字的 token；跨过 `(` 之类的空档由
                                // tokenize 天然处理（括号不是标识符字符，不会出现在 token 流里）
                                if (i + 1 < Int64(tokens.size)) {
                                    let n = tokens[i + 1]
                                    if (looksLikeName(n)) {
                                        return Some((kind, n))
                                    }
                                    // ts：`export default function(`（匿名）—— 放弃这行，不编名字
                                }
                                return None
            case None => i += 1
        }
    }
    return None
}

/// 带语言门控的 import 检测（scanSource 专用；原 scanImportLine 签名不动，
/// patchconf.cj 的既有调用点行为不变）。
///
/// ⚠️ 前缀判定按语言门控（与 DECL_TABLES 同一原则）：
///   · `from ` 只属 python —— 仓颉里 `from` 是合法变量名，实证
///     graph_test.cj:1215 的 `from = hit + open.size` 被编出假 import "hit"；
///   · `use ` 只属 rust、`#include` 只属 c —— python 的 `#include "x"`
///     行首注释同理会被编出假 import；
///   · `import ` 保留给全部语言（各语言保留词，import/引号形态不撞名）。
func scanImportLineForLang(t: String, lang: String): String {
    if (t.startsWith("#include") && lang != "c") { return "" }
    if (t.startsWith("from ") && lang != "python") { return "" }
    if (t.startsWith("use ") && lang != "rust") { return "" }
    return scanImportLine(t)
}

/// 从一行里取 import 的模块名。返回空串 = 不是 import 行。
func scanImportLine(t: String): String {
    // C/C++ `#include "x.h"` → x.h 的文件名键（系统头 <...> 不在仓内，跳过）
    if (t.startsWith("#include")) {
        let q = quotedPart(t)
        if (!q.isEmpty()) {
            let segs = q.split("/")
            let base = segs[segs.size - 1]
            // 去扩展名：与 moduleIndex 的「文件名去扩展」键一致（Util.h → Util）
            let dot = base.lastIndexOf(".")
            match (dot) {
                case Some(i) => if (i > 0) { return base[0..i] }
                case None => ()
            }
            return base
        }
        return ""
    }
    if (t.startsWith("import ")) {
        // go：import "a/b/c" → 取引号内最后一段
        let q = quotedPart(t)
        if (!q.isEmpty()) {
            let segs = q.split("/")
            return segs[segs.size - 1]
        }
        // 仓颉/swift 的跨包引用语义在**末段**（import moongit.util → util），
        // 这才是能命中项目内目录/文件名的那一段。
        // ⚠️ tokenize 已把 `.` 当分隔符，所以 `toks[1]` 只是首段 —— 必须收集
        // 「`import` 之后、`as` 之前」的**最后一个**标识符。原实现取 `toks[1]`
        // 得 `moongit`（仓里无此目录）⇒ 整个仓颉仓库 import 边恒为 0。
        // 边界：`import struct Foundation.Date` 这类修饰形态会取到 `Date`，
        // 解析不到目录 ⇒ 不加边（不会编出错边）。
        let toks = tokenize(t)
        var cand = ""
        var i: Int64 = 1
        while (i < Int64(toks.size)) {
            let tk = toks[i]
            if (tk == "as") { break }   // Swift 别名 `import X as Y` → 取 X
            cand = tk
            i += 1
        }
        if (!cand.isEmpty() && cand != "_" && cand != "}") { return cand }
        return ""
    }
    if (t.startsWith("from ")) {
        // python `from a.b import c` → a
        let toks = tokenize(t)
        if (toks.size >= 2) {
            let segs = toks[1].split(".")
            return segs[0]
        }
        return ""
    }
    if (t.startsWith("use ")) {
        // rust `use a::b::c` → a
        let toks = tokenize(t)
        if (toks.size >= 2) {
            let segs = toks[1].split("::")
            return segs[0]
        }
        return ""
    }
    return ""
}

/// 行内第一个引号串（go import "path" 用）。
func quotedPart(t: String): String {
    let bytes = t.toArray()
    var i: Int64 = 0
    while (i < Int64(bytes.size)) {
        if (bytes[i] == 34) {   // '"'
            var j = i + 1
            let out = ArrayList<UInt8>()
            while (j < Int64(bytes.size) && bytes[j] != 34) {
                out.add(bytes[j])
                j += 1
            }
            return fromUtf8Lossy(out.toArray())
        }
        i += 1
    }
    return ""
}

/// (a) 局部绑定行拦截 + 声明词语言门控。scanSource 专用的 tokens 预处理。
///
/// 返回 None = 这行是 let/var/const 绑定行，**不产生任何符号**——符号索引的
/// 语义是模块级声明，不是局部绑定（status.cj 的 `let def = Json.obj()`）。
/// 判「绑定行」按 token 顺序找**第一个关键词事件**：绑定词先于声明词出现
/// 才算绑定行；`func f() { let x = 1 }` 的 func 在前，照常按声明处理。
///
/// 返回 Some(tokens) = 门控后的 tokens：不在本语言表里的跨语言声明词替换成
/// 哨兵，`Json.set(def, …)` 这类**调用行**（def 是实参）不再被编成声明。
/// scanDeclLine 签名未动 —— patchconf.cj / confidence_detect.cj 的四个
/// 既有调用点行为不变。
func gateDeclTokens(toks: ArrayList<String>, lang: String): Option<ArrayList<String>> {
    let table = match (DECL_TABLES.get(lang)) {
        case Some(t) => t
        case None => return Some(toks)   // 未知语言不做门控（detectLang 只产已知值）
    }
    var bound = false
    var i: Int64 = 0
    while (i < Int64(toks.size)) {
        let w = toks[i]
        if (table.contains(w)) { break }   // 本语言的声明词在前 → 声明行
        if (w == "let" || w == "var" || w == "const") {
            bound = true
            break
        }
        i += 1
    }
    if (bound) { return None }
    let out = ArrayList<String>()
    for (w in toks) {
        if (lang == "cangjie" && w == "extend") {
            // 仓颉的扩展关键词是 extend（extension 是 swift 的拼写）。
            // 归一化到 kindOf 认的 Extension 声明词——kindOf 是与
            // patchconf/confidence_detect 共享的混编表，不动它
            // （改一个 case 会改变并行调用点的运行时行为）。
            // 实证：src/util/text.cj:478 等多处 `extend String {`
            // 在旧词表下整条路 None，扩展声明全部漏出符号索引。
            out.add("extension")
        } else if (CROSS_LANG_DECL_WORDS.contains(w) && !table.contains(w)) {
            out.add(DECL_SENTINEL)
        } else {
            out.add(w)
        }
    }
    return Some(out)
}

/// (b) 花括号深度栈的「外层种类」：从栈顶向下找最近的声明种类。
/// None 项（if/for/闭包等匿名块）要穿透——函数体内 if 块里的嵌套函数
/// 仍然是嵌套函数。
func enclosingDecl(stack: ArrayList<Option<SymKind>>): Option<SymKind> {
    var i: Int64 = Int64(stack.size) - 1
    while (i >= 0) {
        match (stack[i]) {
            case Some(k) => return Some(k)
            case None => ()
        }
        i -= 1
    }
    return None
}

/// (b) 声明入索引判定：函数体内（栈上最近的声明种类是 Func）出现的
/// 嵌套 func **不入符号索引**（模块级声明的语义；实证 cli_test.cj:1685 的
/// `func line(...)` 成为符号 line 后，超通用名 + 词法吸附把全仓含 line
/// 一词的文件都吸成了引用边）。类型体内的方法（enclosing=Class/Struct/…）
/// 照常入索引。当前只拦 func 嵌 func——函数体内的局部 class 是既有行为，
/// 不在本次范围。
func admitDecl(kind: SymKind, enclosing: Option<SymKind>): Bool {
    match (enclosing) {
        case Some(Func) =>
            // 仓颉 enum 无自动 !=（cjc 实证），按项目惯例用 match
            match (kind) {
                case Func => return false
                case _ => return true
            }
        case _ => return true
    }
}

/// 剥后文本的字节计数（`{` / `}` 用），零分配。必须喂 stripCode 的输出：
/// 三引号字符串/注释里的 `{` 与声明样文本不参与计数，否则栈被污染，
/// 后续文件级声明会被误判成嵌套。
func countByte(s: String, target: UInt8): Int64 {
    var n: Int64 = 0
    for (b in s) {
        if (b == target) { n += 1 }
    }
    return n
}

/// 扫描整份源码。
///
/// ⚠️ (a)+(b) 两类假符号的修复都落在本函数：
///   (a) 局部 let/var/const 绑定行不产生符号（gateDeclTokens 返回 None），
///       且声明词按语言门控（`def` 只属于 python）——实证三假符号见
///       DECL_TABLES 注释；
///   (b) 花括号深度栈（braceKinds）跟踪每行的声明种类，函数体内嵌套的
///       func 不入符号索引（admitDecl），类型体内方法照常入。
public func scanSource(content: String, lang: String): SourceFacts {
    let symbols = ArrayList<SymDecl>()
    let imports = ArrayList<String>()
    let importLines = ArrayList<Int64>()
    let seenImports = HashSet<String>()
    // (b) 花括号深度栈：每个已开 `{` 的所属声明种类（None = if/for/闭包等
    // 匿名块）。记账只基于 stripCode 剥后文本——三引号字符串/注释里的
    // 花括号与声明样文本天然出局。
    let braceKinds = ArrayList<Option<SymKind>>()
    let noKind: Option<SymKind> = None
    // ⚠ C 系函数签名的**待定状态**（Allman 风格：签名行与 `{` 行不在同一行）。
    //   Some((函数名, 签名行号, 括号余额))；余额 > 0 = 签名还没写完（跨行）。
    //   ⚠ 跨行迭代器（lazySplit）没有前瞻 ⇒ 用「上一行留状态、这一行定性」实现。
    var pendingCSig: Option<(String, Int64, Int64)> = None
    var lineNo: Int64 = 0
    var lineCount: Int64 = 0
    var strState: Int64 = 0
    // lazySplit：不物化全部行（split 会为整文件一次性分配全部行字符串）
    for (raw in content.lazySplit("\n")) {
        lineNo += 1
        lineCount = lineNo
        // ⚠️ import 检测用**原始行**：import 是行锚定语句，go 的 import "fmt"
        // 会被 stripCode 剥成裸 "import" 而丢失模块名。行首判定保证
        // 字符串里的 "import x"（非行首）不会误报。
        // ⚠️ 但三引号字符串/块注释里的行**本身就是独立的一行**，行首判定拦不住
        // 它们（实证 graph_test.cj:68 夹具内 `from flow.update import …` 被编成
        // 假 import flow、命中 src/flow 目录段造出假 import 边）。上一行结束时
        // 的跨行状态（strState，2=三引号串 3=块注释 4=三单引号串）内的行一律
        // 不做 import 检测；state 0 时行首必是代码（单行串不跨行，行尾已复位）。
        if (strState == 0) {
            let imp = scanImportLineForLang(raw.trimAscii(), lang)
            if (!imp.isEmpty() && !seenImports.contains(imp)) {
                seenImports.add(imp)
                imports.add(imp)
                importLines.add(lineNo)
            }
        }
        // stripCode 同时剥注释与字符串字面量（含跨行状态）——见函数头的三个坑
        let (t, nextState) = stripCode(raw, strState)
        strState = nextState
        if (blankLine(t)) { continue }
        // (b) 本行花括号记账：净开 = push（首项记本行声明种类），净收 = pop；
        // 单行自平衡（net == 0，如 `func f() { … }`）不动栈——否则自平衡
        // 声明的种类永远留在栈上，后续声明全被误判成嵌套（栈污染）。
        let opens = countByte(t, 123)    // '{'
        let closes = countByte(t, 125)   // '}'
        // 符号判定用**记账前**的栈：本行 `{` 尚未 push，栈顶正是声明所属的外层体
        let enclosing = enclosingDecl(braceKinds)
        var declKind: Option<SymKind> = None
        // ── 待定的 C 系函数签名（Allman 风格）────────────────────────────
        //   上一行疑似「返回类型 name(」的签名头 ⇒ 这一行若是 `{` 就是函数定义。
        //   ⚠ 空行/纯注释行在上面的 `continue` 就走了 ⇒ 签名与 `{` 之间夹着
        //   注释行也不影响判定（待定状态跨空行保留）。
        if (pendingCSig.isSome()) {
            let (pname, pline, pbal) = pendingCSig.getOrThrow()
            let tt = t.trimAscii()
            if (tt.startsWith("{")) {
                // 定义成立（不论签名此前写完没有）
                if (admitDecl(Func, enclosing)) {
                    symbols.add(SymDecl(Func, pname, pline))
                }
                // ⚠ 花括号记账要记成 Func —— 与「`{` 同行」形态保持一致，
                //   否则函数体里的嵌套声明会被误当成外层声明（栈污染）
                declKind = Some(Func)
                pendingCSig = None
            } else if (pbal > 0) {
                // 签名跨行：这一行是续行
                let nbal = pbal + countByte(t, 40) - countByte(t, 41)
                if (nbal <= 0) {
                    // 签名收口：以 `;` 结尾 ⇒ 那是**声明**（原型）⇒ 丢弃
                    if (tt.endsWith(";")) {
                        pendingCSig = None
                    } else {
                        pendingCSig = Some((pname, pline, 0))
                    }
                } else {
                    pendingCSig = Some((pname, pline, nbal))
                }
            } else {
                // 签名已写完但下一行不是 `{` ⇒ 不是定义（丢弃待定状态）
                pendingCSig = None
            }
        }
        // ⚠️ G1：go 带接收者的方法声明必须在 scanDeclLine 之前特判——
        // tokenize 会把接收者变量名顶到 tokens[1]，通用路径抽出的「函数名」
        // 是接收者而不是方法（见 goReceiverMethodName 的注释）。命中即取真名、
        // 不再走后续扫描（同一行不可能再含别的声明）。
        if (lang == "go") {
            match (goReceiverMethodName(t)) {
                case Some(name) =>
                    if (admitDecl(Func, enclosing)) {
                        symbols.add(SymDecl(Func, name, lineNo))
                    }
                    declKind = Some(Func)
                case None => ()
            }
        }
        if (declKind.isNone() && mayDeclare(t)) {
            // (a) 先做绑定行拦截与语言门控，再交给 scanDeclLine
            match (gateDeclTokens(tokenize(t), lang)) {
                case Some(gated) =>
                    match (scanDeclLine(gated)) {
                        case Some((kind, name)) =>
                            if (admitDecl(kind, enclosing)) {
                                symbols.add(SymDecl(kind, name, lineNo))
                            }
                            declKind = Some(kind)
                        case None =>
                            // C 系函数没有声明关键字——形态兜底（否则同文件互调全成幻觉调用）
                            match (cStyleFuncName(t, lang)) {
                                case Some(name) =>
                                    if (admitDecl(Func, enclosing)) {
                                        symbols.add(SymDecl(Func, name, lineNo))
                                    }
                                    declKind = Some(Func)
                                case None =>
                                    // Allman 风格：签名行没有 `{` ⇒ 留待下一行定性
                                    match (cStyleFuncSignature(t, lang)) {
                                        case Some(name) =>
                                            pendingCSig = Some((name, lineNo,
                                                countByte(t, 40) - countByte(t, 41)))
                                        case None => ()
                                    }
                            }
                    }
                case None =>
                    // let/var/const 绑定行：不产生任何符号；也不是函数定义，
                    // C 形态兜底同样不适用
                    ()
            }
        } else if (declKind.isNone()) {
            // 不含声明关键词的行：只保留 C 形态兜底
            match (cStyleFuncName(t, lang)) {
                case Some(name) =>
                    if (admitDecl(Func, enclosing)) {
                        symbols.add(SymDecl(Func, name, lineNo))
                    }
                    declKind = Some(Func)
                case None =>
                    // Allman 风格：签名行没有 `{` ⇒ 留待下一行定性
                    match (cStyleFuncSignature(t, lang)) {
                        case Some(name) =>
                            pendingCSig = Some((name, lineNo,
                                countByte(t, 40) - countByte(t, 41)))
                        case None => ()
                    }
            }
        }
        // (b) 记账（在符号判定之后：栈顶在判定时必须是外层体）
        let net = opens - closes
        if (net > 0) {
            braceKinds.add(declKind)
            var k: Int64 = 1
            while (k < net) { braceKinds.add(noKind); k += 1 }
        } else if (net < 0) {
            var k: Int64 = 0
            while (k < -net && braceKinds.size > 0) {
                braceKinds.remove(at: braceKinds.size - 1)
                k += 1
            }
        }
    }
    return SourceFacts(symbols, imports, importLines, lineCount)
}
