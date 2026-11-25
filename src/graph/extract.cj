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
        } else if (inState != 3) {
            return ("", inState)
        }
        // ⚠️ 块注释**续行**不能走整行注释捷径：它可能在行尾把注释闭合
        //   （Javadoc/KDoc 最常见的收尾写法 ` * 说明文字 */`）。提前返回会把
        //   状态 3 一路带到文件末尾，后面的整份源码都被当成注释——
        //   实测 Kotlin Main.kt 从第一个 KDoc 之后 0 个符号（旧扫描器同中招）。
        //   交给状态机：它认得 `*/`，其后的内容照常是代码。
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
    /// 调用点（见 CallSite）。caller 是 symbols 的下标。
    public let refs: ArrayList<CallSite>

    public init(symbols: ArrayList<SymDecl>, imports: ArrayList<String>,
                importLines: ArrayList<Int64>, lineCount: Int64) {
        this(symbols, imports, importLines, lineCount, ArrayList<CallSite>())
    }

    public init(symbols: ArrayList<SymDecl>, imports: ArrayList<String>,
                importLines: ArrayList<Int64>, lineCount: Int64, refs: ArrayList<CallSite>) {
        this.symbols = symbols
        this.imports = imports
        this.importLines = importLines
        this.lineCount = lineCount
        this.refs = refs
    }
}

/// 声明关键词 → 符号种类。返回 None = 这行不是声明。
/// go 的 `type X struct` 是双关键词，单独在 scanLine 里特判。
///
/// ⚠️ 本函数的词表是**跨语言混编**的（fn/def/function/trait/protocol 同为
/// Func/Interface），只保留给 scanDeclLine 的包内既有调用点
/// （patchconf.cj / confidence_detect.cj）用；scanSource 的声明提取走
/// 下面的 Scanner——按语言门控、带作用域栈的成员级扫描。
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

// MARK: - 语言门控（声明词表）

/// 每种语言**真正认**的声明词表。
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
///
/// 两个调用方：
///   · collectArchDecls（build.cj）的顶层声明收集间接依赖本表的门控语义；
///   · Scanner.detect（成员级扫描）：某词在这门语言里是不是声明词，只认本表。
func buildDeclTables(): HashMap<String, HashSet<String>> {
    let tables = HashMap<String, Array<String>>()
    tables["cangjie"] = ["func", "class", "struct", "interface", "enum", "extend"]
    tables["swift"] = ["func", "class", "struct", "interface", "protocol", "enum", "extension", "typealias"]
    tables["ts"] = ["function", "class", "interface", "enum", "type"]
    tables["python"] = ["def", "class"]
    tables["go"] = ["func", "type", "struct", "interface"]
    tables["rust"] = ["fn", "struct", "enum", "trait", "impl", "type"]
    tables["java"] = ["class", "interface", "enum"]
    // ⚠️ kotlin 的表原来缺 `fun`（只有 class / interface / enum）——
    //   **整个 Kotlin 仓库没有一个函数进符号表**（连顶层的都没有）。
    //   `object` 同批补上：命名对象是类级声明，`companion object` 只作属主域。
    tables["kotlin"] = ["fun", "class", "interface", "enum", "object"]
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

// MARK: - 成员级扫描器（scanSource 的实现）
//
// 【一句话】scanSource 不再是「逐行找声明关键词」，而是一台**带作用域栈的
// 线性扫描器**：每一行先定性（是不是声明 / 是不是上一条声明的签名延续），
// 再采调用点，最后按出现顺序记账花括号。三件事的次序不能换——
//   ① 声明判定必须看**记账前**的栈（栈顶正是声明所属的外层体）；
//   ② 调用点的 caller 必须是「本行开始时最内层的被索引函数」，同行开体的
//      声明例外（它自己就是本行调用点的 caller）；
//   ③ 花括号记账放在最后：同一行里 `{ … }` 的开闭按出现顺序进出栈，
//      净额记账（旧实现）会把「`} void f() {`」这种行算成零。
//
// 【为什么每行只认一个声明、且必须在行首（修饰符/注解之后）】
// `protocol P { func draw() }` 这种单行体里的第二个声明会漏——如实少报。
// 换取的是**零假符号**：初始化器、实参表、返回语句里的 `name(` 一律没有
// 「语句起点」这个身份。旧实现在整行任意位置找声明词，`const T k = { f(…) }`
// 就这样编出过一个叫 f 的函数。

/// 剥后文本里的一个词法符号：标识符，或单个可打印 ASCII 标点。[s, e) 是字节区间。
struct Tok {
    let s: Int64
    let e: Int64
    init(s: Int64, e: Int64) {
        this.s = s
        this.e = e
    }
}

func lexLine(t: String): ArrayList<Tok> {
    let out = ArrayList<Tok>()
    let n = Int64(t.size)
    var i: Int64 = 0
    while (i < n) {
        let c = t[i]
        if (isIdentByte(c)) {
            let s = i
            while (i < n && isIdentByte(t[i])) { i += 1 }
            out.add(Tok(s, i))
        } else if (c > 32 && c < 127) {
            out.add(Tok(i, i + 1))
            i += 1
        } else {
            i += 1
        }
    }
    return out
}

func tokIsCh(t: String, k: Tok, c: UInt8): Bool {
    return k.e - k.s == 1 && t[k.s] == c
}

func tokIsIdent(t: String, k: Tok): Bool {
    return isIdentByte(t[k.s])
}

func tokText(t: String, k: Tok): String {
    return t[k.s..k.e]
}

/// 从 toks[i]（必须是 open）起跳过一个配平的括号组，返回闭合符之后的下标；
/// 不配平返回 toks.size（调用方据此判「后面没有想要的符号」）。
func skipBalanced(t: String, toks: ArrayList<Tok>, i: Int64, open: UInt8, close: UInt8): Int64 {
    let nt = Int64(toks.size)
    var depth: Int64 = 0
    var k = i
    while (k < nt) {
        if (tokIsCh(t, toks[k], open)) { depth += 1 }
        else if (tokIsCh(t, toks[k], close)) {
            depth -= 1
            if (depth == 0) { return k + 1 }
        }
        k += 1
    }
    return nt
}

/// 从 toks[i]（必须是 `<`）起跳过一段泛型实参/形参，返回闭合 `>` 之后的下标。
/// 配不平、或先遇到 `;` ⇒ 不是泛型，原样返回 i（调用方随后找不到 `(`，自然放弃）。
/// `->` 里的 `>` 不算闭合（Kotlin 函数类型 `Map<String, (Int) -> Int>`）。
func skipAngle(t: String, toks: ArrayList<Tok>, i: Int64): Int64 {
    let nt = Int64(toks.size)
    var depth: Int64 = 0
    var k = i
    while (k < nt) {
        if (tokIsCh(t, toks[k], 60)) { depth += 1 }
        else if (tokIsCh(t, toks[k], 62)) {
            let arrow = k > i && toks[k - 1].e == toks[k].s && tokIsCh(t, toks[k - 1], 45)
            if (!arrow) {
                depth -= 1
                if (depth == 0) { return k + 1 }
            }
        } else if (tokIsCh(t, toks[k], 40)) {
            k = skipBalanced(t, toks, k, 40, 41)
            continue
        } else if (tokIsCh(t, toks[k], 91)) {
            k = skipBalanced(t, toks, k, 91, 93)
            continue
        } else if (tokIsCh(t, toks[k], 123)) {
            k = skipBalanced(t, toks, k, 123, 125)
            continue
        } else if (tokIsCh(t, toks[k], 59)) {
            return i
        }
        k += 1
    }
    return i
}

/// 从 toks[i] 起读一条「限定名链」：Ident [<…>] (sep Ident [<…>]])*。
/// sep 是 `::`（两枚相邻的 `:`），dotted = true 时也认 `.`。
/// 返回 (链上各段的 [名字, 起点字节偏移]，链结束后的下标)。泛型实参剥掉。
func readChain(t: String, toks: ArrayList<Tok>, i: Int64, dotted: Bool): (ArrayList<(String, Int64)>, Int64) {
    let out = ArrayList<(String, Int64)>()
    let nt = Int64(toks.size)
    var k = i
    while (k < nt) {
        if (!tokIsIdent(t, toks[k])) { break }
        out.add((tokText(t, toks[k]), toks[k].s))
        k += 1
        if (k < nt && tokIsCh(t, toks[k], 60)) { k = skipAngle(t, toks, k) }
        var sep = false
        if (k + 1 < nt && tokIsCh(t, toks[k], 58) && toks[k].e == toks[k + 1].s && tokIsCh(t, toks[k + 1], 58)) {
            k += 2
            sep = true
        } else if (dotted && k < nt && tokIsCh(t, toks[k], 46)) {
            k += 1
            sep = true
        }
        if (!sep) { break }
    }
    return (out, k)
}

/// C++ 运算符重载的名字：`operator==` / `operator[]` / `operator()` …
/// toks[i] 必须是 `operator`。返回 (名字，参数表 `(` 的下标)；读不出来下标为 -1。
func readOperatorName(t: String, toks: ArrayList<Tok>, i: Int64): (String, Int64) {
    let nt = Int64(toks.size)
    var k = i + 1
    var ops = ""
    var guardN: Int64 = 0
    while (k < nt && guardN < 4) {
        guardN += 1
        if (tokIsCh(t, toks[k], 40)) {
            if (k + 1 < nt && tokIsCh(t, toks[k + 1], 41)) {
                ops += "()"
                k += 2
                continue
            }
            break
        }
        if (tokIsIdent(t, toks[k])) { break }
        ops += tokText(t, toks[k])
        k += 1
    }
    if (ops.isEmpty() || k >= nt || !tokIsCh(t, toks[k], 40)) { return ("", -1) }
    return ("operator" + ops, k)
}

func lastDotSeg(s: String): String {
    match (s.lastIndexOf(".")) {
        case Some(i) => return s[i + 1..]
        case None => return s
    }
}

func joinChain(chain: ArrayList<(String, Int64)>, count: Int64): String {
    let parts = ArrayList<String>()
    var i: Int64 = 0
    while (i < count && i < Int64(chain.size)) {
        parts.add(chain[i][0])
        i += 1
    }
    return joinStrings(parts, ".")
}

// MARK: - 词表

func buildModifiers(): HashMap<String, HashSet<String>> {
    let tables = HashMap<String, Array<String>>()
    tables["swift"] = ["public", "private", "fileprivate", "internal", "open", "package", "static", "final",
        "override", "mutating", "nonmutating", "dynamic", "required", "convenience", "lazy", "weak",
        "unowned", "indirect", "optional", "class"]
    tables["kotlin"] = ["public", "private", "protected", "internal", "open", "abstract", "final",
        "override", "sealed", "data", "inner", "value", "annotation", "inline", "suspend", "operator",
        "infix", "external", "expect", "actual", "tailrec", "const", "lateinit", "companion", "vararg",
        "reified", "noinline", "crossinline"]
    tables["ts"] = ["export", "declare", "default", "abstract", "async", "public", "private", "protected",
        "static", "readonly", "override", "get", "set", "accessor"]
    tables["java"] = ["public", "private", "protected", "static", "final", "abstract", "synchronized",
        "native", "strictfp", "default", "transient", "volatile", "sealed", "non"]
    // ⚠️ 不收 Cangjie 的 FFI 声明修饰符（`foreign func`）：那类声明没有函数体，
    // 本引擎不索引它；而且该词被源码守卫 __lintTransportLayerHasOnlyTwoSurfaces
    // 逐词封杀（util/paths.cj），写进词表会直接把那条 lint 打红。
    tables["cangjie"] = ["public", "private", "protected", "internal", "static", "open", "abstract",
        "const", "unsafe", "macro"]
    tables["rust"] = ["pub", "async", "unsafe", "const", "extern", "default"]
    tables["python"] = ["async"]
    tables["go"] = []
    tables["c"] = []
    let m = HashMap<String, HashSet<String>>()
    for ((lang, words) in tables) {
        let s = HashSet<String>()
        for (w in words) { s.add(w) }
        m[lang] = s
    }
    return m
}

let MODIFIERS: HashMap<String, HashSet<String>> = buildModifiers()

/// 修饰符 → 可见性（按语言：`open` 只在 swift/cangjie 是访问级别，kotlin 的 `open`
/// 是「可继承」；`export` 属 ts，`pub` 属 rust）。不是访问修饰符的返回 ""。
func visForWord(lang: String, w: String): String {
    match (w) {
        case "public" => return "public"
        case "private" => return "private"
        case "fileprivate" => return "private"
        case "protected" => return "protected"
        case "internal" => return "internal"
        case "package" => return "package"
        case "export" => return "public"
        case "pub" => return "public"
        case "open" => return if (lang == "swift" || lang == "cangjie") { "public" } else { "" }
        case _ => return ""
    }
}

/// 各语言的**硬保留字**（不能当声明名的词）。只收硬保留字——
/// `get` / `set` / `init` / `data` / `from` / `open` 这类软关键字或上下文关键字
/// 在多数语言里是合法名字（`def get(self)`、`fun data()`、TS 的 `init()`、
/// Swift 的 `func open(`——探针工程里就有），旧词表把它们一律判「不像名字」，
/// 于是这些函数整个不进索引。修饰符位置的 `open func` 由修饰符循环先消费，
/// 不受这里放宽的影响。
func buildReserve(): HashMap<String, HashSet<String>> {
    let tables = HashMap<String, Array<String>>()
    tables["swift"] = ["if", "else", "for", "while", "return", "switch", "case", "class", "struct", "enum",
        "protocol", "extension", "func", "var", "let", "init", "deinit", "subscript", "operator", "typealias",
        "defer", "guard", "repeat", "in", "is", "as", "nil", "self", "Self", "super", "static", "public",
        "private", "fileprivate", "internal", "where", "throws", "rethrows", "associatedtype",
        "any", "some", "fallthrough", "default", "import", "true", "false", "break", "continue", "do",
        "catch", "throw", "inout"]
    tables["kotlin"] = ["as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in",
        "interface", "is", "null", "object", "package", "return", "super", "this", "throw", "true", "try",
        "typealias", "typeof", "val", "var", "when", "while"]
    tables["ts"] = ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete",
        "do", "else", "enum", "export", "extends", "false", "finally", "for", "function", "if", "import",
        "in", "instanceof", "new", "null", "return", "super", "switch", "this", "throw", "true", "try",
        "typeof", "var", "void", "while", "with", "let", "static", "yield", "await", "implements",
        "interface", "package", "private", "protected", "public", "constructor"]
    tables["java"] = ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class",
        "const", "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally",
        "float", "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long",
        "native", "new", "package", "private", "protected", "public", "return", "short", "static",
        "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try",
        "void", "volatile", "while", "true", "false", "null", "var", "record", "sealed", "permits", "yield"]
    tables["cangjie"] = ["if", "else", "for", "while", "return", "switch", "case", "class", "struct", "enum",
        "interface", "extend", "func", "var", "let", "const", "import", "package", "true", "false", "try",
        "catch", "finally", "in", "is", "match", "break", "continue", "throw", "static", "public",
        "private", "protected", "internal", "override", "abstract", "operator", "mut", "super",
        "this", "init", "type", "prop", "macro", "unsafe", "where", "do"]
    tables["go"] = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
        "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return",
        "select", "struct", "switch", "type", "var"]
    tables["rust"] = ["as", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
        "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
        "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use",
        "where", "while", "async", "await"]
    tables["python"] = ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class",
        "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
        "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while",
        "with", "yield"]
    tables["c"] = ["alignas", "alignof", "and", "asm", "auto", "bool", "break", "case", "catch", "char",
        "class", "const", "constexpr", "const_cast", "continue", "decltype", "default", "delete", "do",
        "double", "dynamic_cast", "else", "enum", "explicit", "export", "extern", "false", "float", "for",
        "friend", "goto", "if", "inline", "int", "long", "mutable", "namespace", "new", "noexcept",
        "nullptr", "operator", "private", "protected", "public", "register", "reinterpret_cast", "return",
        "short", "signed", "sizeof", "static", "static_assert", "static_cast", "struct", "switch",
        "template", "this", "thread_local", "throw", "true", "try", "typedef", "typeid", "typename",
        "union", "unsigned", "using", "virtual", "void", "volatile", "wchar_t", "while"]
    let m = HashMap<String, HashSet<String>>()
    for ((lang, words) in tables) {
        let s = HashSet<String>()
        for (w in words) { s.add(w) }
        m[lang] = s
    }
    return m
}

let RESERVE: HashMap<String, HashSet<String>> = buildReserve()

/// 名字像不像声明名：字母/下划线开头，且不是本语言的硬保留字。
func nameOk(lang: String, w: String): Bool {
    if (w.isEmpty()) { return false }
    let b0 = w.toArray()[0]
    if (!((b0 >= 97 && b0 <= 122) || (b0 >= 65 && b0 <= 90) || b0 == 95)) { return false }
    match (RESERVE.get(lang)) {
        case Some(s) => return !s.contains(w)
        case None => return true
    }
}

/// 位置上紧跟 `(` 却**不是调用**的词：控制流关键字与语言结构词。
/// 内建函数（print/len/append…）**不在此列**——它们是不是内建由解析阶段判定。
func buildCallSkip(): HashMap<String, HashSet<String>> {
    let common = ["if", "for", "while", "switch", "catch", "return", "sizeof", "typeof", "alignof",
        "offsetof", "decltype", "typeid", "noexcept", "goto", "throw", "super", "this", "self", "new",
        "delete", "elif", "except", "synchronized", "using", "case", "else", "static_assert",
        "forward", "move", "declval", "requires", "contract", "unchecked"]
    let tables = HashMap<String, Array<String>>()
    tables["swift"] = ["init", "subscript", "guard", "defer", "repeat", "fallthrough", "await", "async",
        "rethrows", "protocol", "extension", "typealias", "any", "some", "actor", "nonisolated", "inout"]
    tables["kotlin"] = ["constructor", "companion", "suspend", "typeof", "by", "when", "infix", "tailrec"]
    tables["ts"] = ["function", "async", "await", "yield", "constructor", "declare", "implements", "extends"]
    tables["java"] = ["instanceof", "assert", "record", "sealed", "strictfp"]
    tables["cangjie"] = ["init", "prop", "macro", "spawn", "unsafe"]
    tables["go"] = ["go", "chan", "map", "defer", "select", "range", "func", "type", "var", "const",
        "interface", "struct"]
    tables["rust"] = ["impl", "trait", "match", "loop", "as", "dyn", "box", "ref", "pub", "unsafe", "async",
        "await", "vec", "format", "write", "writeln", "panic", "unreachable", "todo", "dbg"]
    tables["python"] = ["lambda", "with", "assert", "del", "not", "and", "or", "in", "is"]
    tables["c"] = ["namespace", "template", "typename", "typedef", "union", "alignas", "static_cast",
        "dynamic_cast", "const_cast", "reinterpret_cast", "qobject_cast", "static_assert", "__attribute__",
        "__declspec", "defined", "Q_UNUSED", "Q_ASSERT"]
    let m = HashMap<String, HashSet<String>>()
    for ((lang, extra) in tables) {
        let s = HashSet<String>()
        for (w in common) { s.add(w) }
        for (w in extra) { s.add(w) }
        m[lang] = s
    }
    return m
}

let CALL_SKIP: HashMap<String, HashSet<String>> = buildCallSkip()
func isInterfaceKind(k: Option<SymKind>): Bool {
    match (k) {
        case Some(Interface) => return true
        case _ => return false
    }
}

/// 签名延续行可能以这些词开头（跨行的 where / throws / 父类型 / 初始化列表）。
func buildSigCont(): HashSet<String> {
    let s = HashSet<String>()
    for (w in ["where", "throws", "rethrows", "async", "noexcept", "override", "impl", "on",
        "extends", "implements", "requires"]) { s.add(w) }
    return s
}

let SIG_CONT_WORDS: HashSet<String> = buildSigCont()

/// C 系语句首词的停用词：出现在「返回类型」位置即判否（这些行不可能在声明函数）。
func buildStop(words: Array<String>): HashSet<String> {
    let s = HashSet<String>()
    for (w in words) { s.add(w) }
    return s
}

let C_STOP: HashSet<String> = buildStop(["if", "for", "while", "switch", "return", "else", "do",
    "case", "goto", "sizeof", "new", "delete", "throw", "catch", "try", "using", "namespace",
    "template", "typedef", "friend", "union", "alignof", "alignas", "decltype", "typeid",
    "static_assert", "defined", "public", "private", "protected", "operator", "class", "struct",
    "enum", "noexcept", "virtual", "constexpr", "co_return", "co_await", "co_yield"])
// ⚠️ `explicit` 不在停用词里：它只出现在构造函数声明之前（`explicit AppModel(…);`）。
//   当成停用词会让这一行在走到「构造函数」判定**之前**就被放弃，名字 token 来不及
//   标成「不是调用点」——头文件里每个带 explicit 的构造函数都会多出一个假调用点。

let JAVA_STOP: HashSet<String> = buildStop(["if", "for", "while", "switch", "return", "else", "do",
    "case", "new", "throw", "try", "catch", "finally", "synchronized", "class", "interface",
    "enum", "break", "continue", "instanceof", "assert", "this", "super"])


func isTypeAliasKind(k: SymKind): Bool {
    match (k) {
        case TypeAlias => return true
        case _ => return false
    }
}

/// 声明关键字之后的名字：[泛型] 标识符 [泛型]。读不出来时下标为 -1。
func readDeclName(lang: String, t: String, toks: ArrayList<Tok>, k0: Int64): (String, Int64, Int64) {
    let nt = Int64(toks.size)
    var k = k0
    if (k < nt && tokIsCh(t, toks[k], 60)) { k = skipAngle(t, toks, k) }
    if (k >= nt || !tokIsIdent(t, toks[k])) { return ("", -1, -1) }
    let nm = tokText(t, toks[k])
    if (!nameOk(lang, nm)) { return ("", -1, -1) }
    let st = toks[k].s
    k += 1
    if (k < nt && tokIsCh(t, toks[k], 60)) { k = skipAngle(t, toks, k) }
    return (nm, st, k)
}


// MARK: - 扫描器

/// 扫描期间的符号记录（可变；扫描结束才定稿成不可变的 SymDecl）。
class SymRec {
    var kind: SymKind = Func
    var name: String = ""
    var line: Int64 = 0
    var owner: String = ""
    var endLine: Int64 = 0
    var col: Int64 = 0
    var sig: String = ""
    var vis: String = ""
    var declOnly: Bool = false
    init() {}
}

/// 一个打开的作用域。花括号语言 = 一对花括号；Python = 一个缩进体。
/// kind None = 匿名块（if/for/闭包/namespace/mod/init/companion object…）——
/// 匿名块对 owner 查找是**透明**的：类体里的计算属性闭包、init 块之内声明的
/// 类型，属主仍是外层类型；只有隔着**函数体**才算局部声明（owner 为空）。
class Frame {
    var kind: Option<SymKind> = None
    var sym: Int64 = -1          // 该作用域所属符号在 recs 里的下标；-1 = 匿名/未入表
    var owner: String = ""       // 类型体的限定名（直接成员的 owner）；其余 ""
    var access: String = ""      // C++：当前访问段（class 默认 private，struct 默认 public）
    var indent: Int64 = 0        // Python：缩进列
    init() {}
}

/// 一条**待定**的声明：签名可能跨行、函数体可能另起一行（Allman）、也可能没有体。
class Pending {
    var kind: SymKind = Func
    var anonOwner: Bool = false  // companion object：只开匿名属主域，不入符号表
    var name: String = ""
    var owner: String = ""       // 显式属主（限定名 / 接收者 / 扩展类型 / impl 类型）
    var qual: String = ""        // 本声明的限定名（类型体用它当成员的 owner）
    var vis: String = ""
    var sigStart: Int64 = 0      // 声明起点在本行剥后文本里的字节偏移
    var declLine: Int64 = 0
    var lastLine: Int64 = 0      // 签名已经写到的最后一行
    var col: Int64 = 0
    var sigParts: ArrayList<String>
    var parenDepth: Int64 = 0    // 参数表括号余额（>0 = 还没闭合）
    var parenOpen: Int64 = -1    // 参数表 `(` 的字节偏移
    var nameStart: Int64 = -1    // 名字 token 在本行剥后文本里的起点
    var afterName: Int64 = 0     // 名字（含泛型）之后的偏移；无参数表时尾部判定从这里开始
    var ownerChain: String = ""  // 显式限定属主链（C++ `Outer::Inner::f` → Outer.Inner）
    var frameOwner: String = ""  // 体作为「属主域」时的限定名（扩展/impl 体 = 被扩展的类型）；空 = 同 qual
    var paramsClosed: Bool = false
    var hasParen: Bool = false
    var bodylessComplete: Bool = false   // 没有体也是完整声明（TS 箭头函数属性的表达式体）
    var admitted: Bool = false    // 是否入符号表（函数体内嵌套函数 = false）
    var sym: Int64 = -1
    init() {
        sigParts = ArrayList<String>()
    }
}

func isTypeKind(k: Option<SymKind>): Bool {
    match (k) {
        case Some(Class) => return true
        case Some(Struct) => return true
        case Some(Interface) => return true
        case Some(Enum) => return true
        case Some(Extension) => return true
        case _ => return false
    }
}

func isFuncOpt(k: Option<SymKind>): Bool {
    match (k) {
        case Some(Func) => return true
        case _ => return false
    }
}

func isFuncKind(k: SymKind): Bool {
    match (k) {
        case Func => return true
        case _ => return false
    }
}

func isUpperFirst(s: String): Bool {
    if (s.isEmpty()) { return false }
    let b0 = s.toArray()[0]
    return b0 >= 65 && b0 <= 90
}

/// [from, to) 里圆括号深度的变化。返回 (结束深度, 深度回到 0 的那个 `)` 的位置；没回到 0 为 -1)。
func parenScan(t: String, from: Int64, to: Int64, depth0: Int64): (Int64, Int64) {
    var d = depth0
    var closePos: Int64 = -1
    var i = from
    while (i < to) {
        let c = t[i]
        if (c == 40) { d += 1 }
        else if (c == 41) {
            if (d > 0) { d -= 1 }
            if (d == 0 && closePos < 0) { closePos = i }
        }
        i += 1
    }
    return (d, closePos)
}

/// [from, to) 里三种括号的净余额（开 - 闭）。
func bracketDelta(t: String, from: Int64, to: Int64): Int64 {
    var d: Int64 = 0
    var i = from
    while (i < to) {
        let c = t[i]
        if (c == 40 || c == 91 || c == 123) { d += 1 }
        else if (c == 41 || c == 93 || c == 125) { d -= 1 }
        i += 1
    }
    return d
}

/// 声明尾部 [from, to) 的定性：(函数体 `{` 的位置, 第一个顶层 `;`, 第一个顶层 `=`)；没有的为 -1。
///
/// 函数体 = 行尾仍然开着的**最外层**花括号；整行配平时退回「第一个顶层 `{`」。
/// 不能简单取第一个 `{`：TS 的返回类型可以是对象字面量
/// `function parse(s: string): { ok: number } {`——前一对花括号是类型，体是后一对。
func tailScan(t: String, from: Int64, to: Int64): (Int64, Int64, Int64) {
    var depth: Int64 = 0
    var firstBrace: Int64 = -1
    var outerOpen: Int64 = -1
    var stack: Int64 = 0
    var semi: Int64 = -1
    var eq: Int64 = -1
    var i = from
    while (i < to) {
        let c = t[i]
        if (c == 40 || c == 91) { depth += 1 }
        else if (c == 41 || c == 93) {
            if (depth > 0) { depth -= 1 }
        } else if (c == 123) {
            if (depth == 0) {
                if (firstBrace < 0) { firstBrace = i }
                if (stack == 0) { outerOpen = i }
                stack += 1
            }
        } else if (c == 125) {
            if (depth == 0 && stack > 0) {
                stack -= 1
                if (stack == 0) { outerOpen = -1 }
            }
        } else if (c == 59) {
            if (depth == 0 && semi < 0) { semi = i }
        } else if (c == 61) {
            let prevCmp = i > from && (t[i - 1] == 61 || t[i - 1] == 33 || t[i - 1] == 60 || t[i - 1] == 62)
            let nextEq = i + 1 < to && t[i + 1] == 61
            if (depth == 0 && eq < 0 && !prevCmp && !nextEq) { eq = i }
        }
        i += 1
    }
    let body = if (stack > 0 && outerOpen >= 0) { outerOpen } else { firstBrace }
    return (body, semi, eq)
}

/// 签名里的空白折叠：连续空白并成一个空格，两端不留。
func collapseWs(s: String): String {
    let out = ArrayList<UInt8>()
    var sp = false
    for (c in s) {
        if (c == 32 || c == 9 || c == 10 || c == 13) {
            sp = true
            continue
        }
        if (sp && out.size > 0) { out.add(32) }
        sp = false
        out.add(c)
    }
    return fromUtf8Lossy(out.toArray())
}

func sigPart(t: String, from: Int64, to: Int64): String {
    let n = Int64(t.size)
    var f = from
    var e = to
    if (f < 0) { f = 0 }
    if (e > n) { e = n }
    if (f >= e) { return "" }
    return collapseWs(t[f..e])
}

func sigJoin(parts: ArrayList<String>): String {
    return safeSlice(joinStrings(parts, " ").trimAscii(), SIG_MAX_BYTES)
}

/// 字符数（UTF-8 码点数）：首字节是 0xxxxxxx 或 11xxxxxx。
func runeCountOf(s: String): Int64 {
    var n: Int64 = 0
    for (b in s) {
        if (b < 128 || b >= 192) { n += 1 }
    }
    return n
}

/// s[i..] 是不是以 name 开头（**逐字节比**，不切片）。
///
/// ⚠️ 不能先切 `s[i..i + name.size]` 再比较：name 的首字节对上、后面不是它时，
/// 切片会落进紧随其后的多字节字符中间，直接抛 `Invalid utf8 byte sequence`。
/// 实证：cli.cj 的 `tl(lang, "data dir", "数据目录") … deepgitHome()`——为
/// deepgitHome 找第一个代码位置时扫到 `data`，按 12 字节切片切进了「数据目录」。
func startsWithAt(s: String, i: Int64, name: String): Bool {
    let m = Int64(name.size)
    let n = Int64(s.size)
    if (i + m > n) { return false }
    let nb = name.toArray()
    var j: Int64 = 0
    while (j < m) {
        if (s[i + j] != nb[j]) { return false }
        j += 1
    }
    return true
}

/// t[0..to) 里 name 以整词形态（两侧不是标识符字符）出现的次数。
func countWordBefore(t: String, to0: Int64, name: String): Int64 {
    if (name.isEmpty()) { return 0 }
    let n = Int64(t.size)
    var to: Int64 = to0
    if (to > n) { to = n }
    let m = Int64(name.size)
    if (to < m) { return 0 }
    let b0 = name.toArray()[0]
    var cnt: Int64 = 0
    var i: Int64 = 0
    while (i + m <= to) {
        if (t[i] == b0 && (i == 0 || !isIdentByte(t[i - 1])) && (i + m >= to || !isIdentByte(t[i + m]))) {
            if (startsWithAt(t, i, name)) { cnt += 1 }
        }
        i += 1
    }
    return cnt
}

/// raw 行里 name 的第 k 个**代码位置**整词出现的起始字节偏移（k 从 1 起）；找不到 → -1。
///
/// 剥后文本 `t` 与原始行 `raw` 的下标在行内出现注释/字符串之后就对不上了，而 `col`
/// 必须是原始源码的列。「是不是代码位置」以 stripCode 为准：把 raw 截到该出现的末尾
/// 再剥一遍，剥后文本必须正好以 name 结尾——注释/字符串里的同名出现剥后不在文本里，
/// 天然出局。只有声明与调用点会走到这里（不是逐字节热路径）。
func rawCodeOffset(raw: String, st: Int64, name: String, k: Int64): Int64 {
    if (k <= 0 || name.isEmpty()) { return -1 }
    let n = Int64(raw.size)
    let m = Int64(name.size)
    if (m > n) { return -1 }
    let b0 = name.toArray()[0]
    var seen: Int64 = 0
    var i: Int64 = 0
    while (i + m <= n) {
        if (raw[i] == b0 && (i == 0 || !isIdentByte(raw[i - 1])) && (i + m >= n || !isIdentByte(raw[i + m]))
            && startsWithAt(raw, i, name)) {
            // 切片终点 i + m 是标识符的末尾（ASCII），落在字符边界上
            let (out, _) = stripCode(raw[0..i + m], st)
            if (out.endsWith(name)) {
                seen += 1
                if (seen == k) { return i }
            }
        }
        i += 1
    }
    return -1
}

/// 行尾（忽略 CR 与尾随空白）是不是续行反斜杠。
func endsWithBackslash(t: String): Bool {
    var e = Int64(t.size)
    while (e > 0 && (t[e - 1] == 13 || t[e - 1] == 32 || t[e - 1] == 9)) { e -= 1 }
    return e > 0 && t[e - 1] == 92
}

func leadWs(s: String): Int64 {
    let n = Int64(s.size)
    var i: Int64 = 0
    while (i < n && (s[i] == 32 || s[i] == 9)) { i += 1 }
    return i
}

// MARK: - 扫描器主体

/// 单文件扫描器：一台带作用域栈的线性状态机（见本节顶部的设计说明）。
/// 用类而不是嵌套函数：仓颉闭包/参数捕获是值语义，跨行状态只有放在引用类型里
/// 才能一路带下去（同 ReferVar 的存在理由）。
class Scanner {
    let lang: String
    let recs: ArrayList<SymRec>
    let refs: ArrayList<CallSite>
    let frames: ArrayList<Frame>
    let imports: ArrayList<String>
    let importLines: ArrayList<Int64>
    let seenImports: HashSet<String>
    var pending: Option<Pending> = None
    // Kotlin 表达式体 / 别名右值的跨行跟踪：`fun x() = when (y) {` 的体没有「函数体花括号」
    // 可认，只能按括号余额跟到配平为止。
    var exprSym: Int64 = -1
    var exprDepth: Int64 = 0
    var exprBase: Int64 = 0
    var lastCodeLine: Int64 = 0
    var lineCount: Int64 = 0
    var pyDepth: Int64 = 0
    var pyContinue: Bool = false
    // ── 行内一次性状态（每行开头复位）──
    var scanFrom: Int64 = 0      // 调用点扫描区间 [scanFrom, scanTo)
    var scanTo: Int64 = 0
    var skipNameAt: Int64 = -1   // 本行声明的名字 token 起点（它自己不是调用）
    var bodyPos: Int64 = -1      // 本行声明的体 `{` 位置（-1 = 本行没有开体）
    var declKind: Option<SymKind> = None
    var declSym: Int64 = -1
    var declOwner: String = ""
    var scanCaller: Int64 = -1   // 本行调用点的 caller（recs 下标）
    var lineConsumed: Bool = false   // 本行整行属于某条声明，不再做声明检测
    var companion: Bool = false

    init(lang: String) {
        this.lang = lang
        this.recs = ArrayList<SymRec>()
        this.refs = ArrayList<CallSite>()
        this.frames = ArrayList<Frame>()
        this.imports = ArrayList<String>()
        this.importLines = ArrayList<Int64>()
        this.seenImports = HashSet<String>()
    }

    func scan(content: String): Unit {
        var lineNo: Int64 = 0
        var strState: Int64 = 0
        // lazySplit：不物化全部行（split 会为整文件一次性分配全部行字符串）
        for (raw in content.lazySplit("\n")) {
            lineNo += 1
            lineCount = lineNo
            // ⚠️ import 检测用**原始行**：import 是行锚定语句，go 的 import "fmt"
            // 会被 stripCode 剥成裸 "import" 而丢失模块名。行首判定保证
            // 字符串里的 "import x"（非行首）不会误报。
            // ⚠️ 但三引号字符串/块注释里的行**本身就是独立的一行**，行首判定拦不住
            // 它们——上一行结束时的跨行状态（strState）内的行一律不做 import 检测。
            if (strState == 0) {
                let imp = scanImportLineForLang(raw.trimAscii(), lang)
                if (!imp.isEmpty() && !seenImports.contains(imp)) {
                    seenImports.add(imp)
                    imports.add(imp)
                    importLines.add(lineNo)
                }
            }
            let stIn = strState
            // stripCode 同时剥注释与字符串字面量（含跨行状态）——见函数头的三个坑
            let (t, nextState) = stripCode(raw, stIn)
            strState = nextState
            if (blankLine(t)) { continue }
            if (lang == "python") {
                pyLine(raw, t, lineNo, stIn)
            } else {
                braceLine(raw, t, lineNo, stIn)
            }
        }
        // Python：文件末尾仍然开着的缩进体，末行就是最后一个代码行。
        // 花括号语言不这样做：文件结束时还没闭合的体是**未知**（endLine = 0），
        // 括号栈被 `#if` 之类的预处理分支带偏时，「末行」会是一个很远的错答案。
        if (lang == "python") {
            var k: Int64 = Int64(frames.size) - 1
            while (k >= 0) {
                let f = frames[k]
                if (f.sym >= 0 && recs[f.sym].endLine == 0) { recs[f.sym].endLine = lastCodeLine }
                k -= 1
            }
        }
    }

    /// 定稿：记录 → 不可变符号。同文件同 (line, name) 的第 2 个起 dup 递增。
    func finish(): ArrayList<SymDecl> {
        let seen = HashMap<String, Int64>()
        let out = ArrayList<SymDecl>()
        for (r in recs) {
            let key = r.line.toString() + "\u{1f}" + r.name
            var d: Int64 = 1
            match (seen.get(key)) {
                case Some(v) => d = v + 1
                case None => ()
            }
            seen[key] = d
            out.add(SymDecl(r.kind, r.name, r.line, r.owner, r.endLine, r.col, r.sig, r.vis,
                r.declOnly, d))
        }
        return out
    }

    // MARK: 作用域

    /// 自栈顶向下第一个带种类的帧（匿名块穿透）。
    func enclosingKind(): Option<SymKind> {
        var i: Int64 = Int64(frames.size) - 1
        while (i >= 0) {
            if (frames[i].kind.isSome()) { return frames[i].kind }
            i -= 1
        }
        return None
    }

    /// 内层被索引函数（recs 下标）；不在任何函数体里 = -1。
    /// 没入表的嵌套函数（sym = -1）穿透——它的函数体仍然在外层函数体内。
    func innerFunc(): Int64 {
        var i: Int64 = Int64(frames.size) - 1
        while (i >= 0) {
            if (frames[i].sym >= 0 && isFuncOpt(frames[i].kind)) { return frames[i].sym }
            i -= 1
        }
        return -1
    }

    /// 声明的 owner：自栈顶向下找第一个类型体；**先碰到函数体 ⇒ 局部声明**（owner 为空）。
    func ownerFor(): String {
        var i: Int64 = Int64(frames.size) - 1
        while (i >= 0) {
            match (frames[i].kind) {
                case Some(Func) => return ""
                case Some(_) => return frames[i].owner
                case None => ()
            }
            i -= 1
        }
        return ""
    }

    /// 直接位于类型体之下（成员位置）：Java/TS 无关键字成员语法只在此时启用。
    func atMemberPos(): Bool {
        if (frames.size == 0) { return false }
        return isTypeKind(frames[frames.size - 1].kind)
    }

    /// C++ 成员的可见性 = 所在访问段（隔着的匿名块透明；函数体之内不是成员）。
    func cMemberAccess(): String {
        var i: Int64 = Int64(frames.size) - 1
        while (i >= 0) {
            if (isFuncOpt(frames[i].kind)) { return "" }
            if (frames[i].kind.isSome()) { return frames[i].access }
            i -= 1
        }
        return ""
    }

    func admit(kind: SymKind, name: String, owner: String, line: Int64, endLine: Int64,
               col: Int64, sig: String, vis: String, declOnly: Bool): Int64 {
        let r = SymRec()
        r.kind = kind
        r.name = name
        r.line = line
        r.owner = owner
        r.endLine = endLine
        r.col = col
        r.sig = sig
        r.vis = vis
        r.declOnly = declOnly
        recs.add(r)
        return Int64(recs.size) - 1
    }

    func pushFrame(kind: Option<SymKind>, sym: Int64, owner: String): Unit {
        let f = Frame()
        f.kind = kind
        f.sym = sym
        f.owner = owner
        if (lang == "c" && !owner.isEmpty()) {
            match (kind) {
                case Some(Class) => f.access = "private"
                case _ => f.access = "public"
            }
        }
        frames.add(f)
    }

    func popFrame(lineNo: Int64): Unit {
        if (frames.size == 0) { return }
        let f = frames[frames.size - 1]
        frames.remove(at: frames.size - 1)
        if (f.sym >= 0 && recs[f.sym].endLine == 0) { recs[f.sym].endLine = lineNo }
        // 表达式体的括号余额如果被带偏了，不能让它把后面的声明全吞掉：
        // 外层作用域一闭合就强制收尾。
        if (exprSym >= 0 && Int64(frames.size) < exprBase) {
            if (recs[exprSym].endLine == 0) { recs[exprSym].endLine = lineNo }
            exprSym = -1
        }
    }

    // MARK: 花括号语言：一行

    func braceLine(raw: String, t: String, lineNo: Int64, strIn: Int64): Unit {
        scanFrom = 0
        scanTo = Int64(t.size)
        skipNameAt = -1
        bodyPos = -1
        declKind = None
        declSym = -1
        declOwner = ""
        scanCaller = innerFunc()
        lineConsumed = false
        // ① 上一条声明还在待定：本行先归它
        if (pending.isSome()) {
            let p = pending.getOrThrow()
            if (advancePending(p, t, lineNo)) { lineConsumed = true }
        }
        // ② 表达式体 / 别名右值的后续行：既不是新声明，调用点也归它自己
        if (!lineConsumed && exprSym >= 0) {
            lineConsumed = true
            scanCaller = exprSym
            exprDepth += bracketDelta(t, 0, Int64(t.size))
            if (exprDepth <= 0) {
                recs[exprSym].endLine = lineNo
                exprSym = -1
            }
        }
        // ③ 声明检测（看的是记账前的栈）
        if (!lineConsumed) {
            detect(t, raw, lineNo, strIn)
        }
        lastCodeLine = lineNo
        // ④ 调用点
        if (scanFrom < scanTo) {
            collectCalls(raw, t, strIn, lineNo)
        }
        // ⑤ 花括号记账（按出现顺序）
        applyBraces(t, lineNo)
    }

    /// 本行归待定声明处理。返回 true = 本行整行属于它（不再做声明检测）。
    func advancePending(p: Pending, t: String, lineNo: Int64): Bool {
        let n = Int64(t.size)
        if (!p.paramsClosed) {
            // ⚠️ 判「参数表闭合」看的是**深度回到 0 的那个 `)`**，不是行尾余额：
            //   `): BulkReport = BulkReport(` ——参数表在行中闭合，行尾的 `(` 是
            //   表达式体里的新调用。按行尾余额判会把这种行当成「参数还没写完」。
            let (d, closePos) = parenScan(t, 0, n, p.parenDepth)
            if (closePos < 0) {
                p.parenDepth = d
                p.sigParts.add(sigPart(t, 0, n))
                p.lastLine = lineNo
                return true
            }
            // 参数表在本行闭合：闭合括号之后的部分交给尾部判定
            p.parenDepth = 0
            p.paramsClosed = true
            tailCheck(p, t, lineNo, closePos + 1, 0)
            return true
        }
        let toks = lexLine(t)
        if (toks.size == 0) { return true }
        let f0 = toks[0]
        // Allman 风格：函数体另起一行
        if (tokIsCh(t, f0, 123)) {
            armBody(p, f0.s, Int64(t.size))
            return true
        }
        if (!sigContinues(t, toks)) {
            // 上一行就是签名的最后一行：没有体的声明
            finishBodyless(p)
            pending = Option<Pending>.None
            return false
        }
        // 签名延续（`: Base` / `-> T` / `where …` / 初始化列表 …）
        tailCheck(p, t, lineNo, 0, 0)
        return true
    }

    /// 声明在本行开体：定稿、指定体花括号、把本行其后的调用点归它。
    func armBody(p: Pending, pos: Int64, n: Int64): Unit {
        finalize(p, sigJoin(p.sigParts), 0, false)
        pending = Option<Pending>.None
        bodyPos = pos
        declKind = if (p.anonOwner) { None } else { Some(p.kind) }
        declSym = p.sym
        declOwner = if (p.anonOwner) {
            ""
        } else {
            if (p.frameOwner.isEmpty()) { p.qual } else { p.frameOwner }
        }
        scanFrom = pos + 1
        scanTo = n
        skipNameAt = -1
        lineConsumed = true
        scanCaller = if (p.sym >= 0 && isFuncKind(p.kind)) { p.sym } else { innerFunc() }
    }

    /// 参数表之后的尾部判定：`{`（体）/ `;`（原型或 Rust 单元结构体）/ `=`（表达式体、
    /// 别名右值、C++ 纯虚）/ 都没有（签名跨行，继续待定）。
    /// tailFrom = 从哪里找这三个符号；sigFrom = 本行签名文本的起点。
    func tailCheck(p: Pending, t: String, lineNo: Int64, tailFrom0: Int64, sigFrom: Int64): Unit {
        let n = Int64(t.size)
        let tailFrom = if (tailFrom0 < 0) { n } else { tailFrom0 }
        let (bp, sp, ep) = tailScan(t, tailFrom, n)
        var cut = n
        var hit = 0
        if (bp >= 0) { cut = bp; hit = 1 }
        if (sp >= 0 && (hit == 0 || sp < cut)) { cut = sp; hit = 2 }
        if (ep >= 0 && (hit == 0 || ep < cut)) { cut = ep; hit = 3 }
        p.sigParts.add(sigPart(t, sigFrom, cut))
        p.lastLine = lineNo
        if (hit == 0) {
            pending = Some(p)
            lineConsumed = true
            return
        }
        let sigText = sigJoin(p.sigParts)
        pending = Option<Pending>.None
        lineConsumed = true
        if (hit == 1) {
            armBody(p, bp, n)
            return
        }
        if (hit == 2) {
            // 整行是声明（分号收尾），不采调用点
            scanTo = scanFrom
            if (isFuncKind(p.kind)) {
                if (lang == "c" && !protoParamsOk(t, p.parenOpen)) { return }
                finalize(p, sigText, lineNo, true)
            } else if (lang == "c" && !isTypeAliasKind(p.kind)) {
                // C/C++ 类型的前置声明（`class X;` / `struct X;`）：不是符号。
                // 实证：`class QProcess;` 曾被编成一个类，置信度随即把它报成「空类型」。
            } else {
                finalize(p, sigText, lineNo, false)
            }
            return
        }
        // hit == 3：`=`
        // C++ 里声明之后的 `=` 只可能是纯虚 / = default / = delete ⇒ 仍然只有声明
        let asDeclOnly = isFuncKind(p.kind) && lang == "c"
        finalize(p, sigText, lineNo, asDeclOnly)
        if (asDeclOnly) {
            scanTo = scanFrom
            return
        }
        if (p.sym >= 0) { scanCaller = p.sym }
        scanFrom = ep + 1
        scanTo = n
        let d = bracketDelta(t, ep + 1, n)
        if (d > 0 && p.sym >= 0) {
            exprSym = p.sym
            exprDepth = d
            exprBase = Int64(frames.size)
        }
    }

    /// 没有体的声明怎么收尾：函数 = 只有签名（declOnly）；C/C++ 类型 = 前置声明（不入表）；
    /// 其余语言的类型可以是「主构造器 + 父类型」就写完（Kotlin `class Failed(val r: String) : S`）。
    func finishBodyless(p: Pending): Unit {
        let sigText = sigJoin(p.sigParts)
        if (p.anonOwner) { return }
        if (p.bodylessComplete) {
            finalize(p, sigText, p.lastLine, false)
            return
        }
        if (isFuncKind(p.kind)) {
            finalize(p, sigText, p.lastLine, true)
            return
        }
        if (lang == "c" && !isTypeAliasKind(p.kind)) { return }
        finalize(p, sigText, p.lastLine, false)
    }

    /// 定稿：把待定声明落成符号（未获准入 / 匿名属主域的不落）。endLine = 0 表示待闭括号时再定。
    func finalize(p: Pending, sigText: String, endLine: Int64, declOnly: Bool): Unit {
        if (p.anonOwner || !p.admitted) { return }
        p.sym = admit(p.kind, p.name, p.owner, p.declLine, endLine, p.col, sigText, p.vis, declOnly)
    }

    /// 声明起手：算列号，然后看参数表是否在本行闭合。
    func start(p: Pending, raw: String, t: String, lineNo: Int64, strIn: Int64): Unit {
        let n = Int64(t.size)
        p.declLine = lineNo
        p.lastLine = lineNo
        p.admitted = !p.anonOwner && admitDecl(p.kind, enclosingKind())
        if (!p.anonOwner && !p.name.isEmpty()) {
            let k = countWordBefore(t, p.nameStart, p.name)
            let off = rawCodeOffset(raw, strIn, p.name, k + 1)
            if (off >= 0) { p.col = runeCountOf(raw[0..off]) + 1 }
        }
        p.paramsClosed = true
        if (p.hasParen) {
            // 判「参数表闭合」看深度回到 0 的那个 `)`（同 advancePending）：行尾余额可能
            // 因为表达式体里的新调用而 >0——`fun of(…): T = BulkReport(`。
            let (d, closePos) = parenScan(t, p.parenOpen + 1, n, 1)
            if (closePos < 0) {
                // 参数表跨行：余额带走，下一行从「参数续行」接起
                p.parenDepth = d
                p.paramsClosed = false
                p.sigParts.add(sigPart(t, p.sigStart, n))
                pending = Some(p)
                lineConsumed = true
                return
            }
            tailCheck(p, t, lineNo, closePos + 1, p.sigStart)
            return
        }
        tailCheck(p, t, lineNo, p.afterName, p.sigStart)
    }

    /// 调用点扫描区间 [scanFrom, scanTo)。
    func collectCalls(raw: String, t: String, strIn: Int64, lineNo: Int64): Unit {
        let n = Int64(t.size)
        var to: Int64 = scanTo
        if (to > n) { to = n }
        var i: Int64 = scanFrom
        if (i < 0) { i = 0 }
        let skipAt = skipNameAt
        let caller = scanCaller
        let skipSet = CALL_SKIP.get(lang)
        while (i < to) {
            if (!isIdentByte(t[i])) { i += 1; continue }
            let st = i
            while (i < to && isIdentByte(t[i])) { i += 1 }
            if (i >= to || t[i] != 40) { continue }
            if (st == skipAt) { continue }
            // `~AppModel(`：析构函数的声明/定义（或显式析构调用），不是对 AppModel 的调用
            if (st > 0 && t[st - 1] == 126) { continue }
            let name = t[st..i]
            var drop = false
            match (skipSet) {
                case Some(s) => drop = s.contains(name)
                case None => ()
            }
            if (drop) { continue }
            // 接收者：回看分隔符 `.` / `->` / `::`，再回读一个标识符
            var recv: Int64 = 0
            var recvText = ""
            var q: Int64 = st - 1
            while (q >= 0 && (t[q] == 32 || t[q] == 9)) { q -= 1 }
            if (q >= 0) {
                let c = t[q]
                if (c == 46) {
                    recv = 1
                } else if (c == 62 && q > 0 && t[q - 1] == 45) {
                    recv = 1
                    q -= 1
                } else if (c == 58 && q > 0 && t[q - 1] == 58) {
                    recv = 1
                    q -= 1
                }
                if (recv != 0) {
                    var e: Int64 = q
                    while (e > 0 && (t[e - 1] == 32 || t[e - 1] == 9)) { e -= 1 }
                    var s2: Int64 = e
                    while (s2 > 0 && isIdentByte(t[s2 - 1])) { s2 -= 1 }
                    if (s2 < e) {
                        recvText = t[s2..e]
                        if (isUpperFirst(recvText)) { recv = 2 }
                    }
                }
            }
            // Kotlin/Swift 属性访问器 `get() = …`：不是调用
            if (recv == 0 && i + 1 < n && t[i + 1] == 41 && (name == "get" || name == "set")
                && (lang == "kotlin" || lang == "swift")) { continue }
            var col: Int64 = 0
            let k = countWordBefore(t, st, name)
            let off = rawCodeOffset(raw, strIn, name, k + 1)
            if (off >= 0) { col = runeCountOf(raw[0..off]) + 1 }
            refs.add(CallSite(name, lineNo, col, recv, recvText, caller))
        }
    }

    /// 花括号按出现顺序进出栈——**每一个**花括号都记账，不看圆括号深度。
    ///
    /// ⚠️ 不能「括号里的花括号不算作用域」：实参表里的 lambda 是
    /// `start([this] {` … `});`——开括号那一行它在圆括号里，闭括号那一行
    /// `}` 排在 `)` **之前**。只跳过前者、却按后者出栈，整棵栈从此错位一层：
    /// 实测 AppModel.cpp 的函数体被提前 50 行收掉，函数体深处的
    /// `QPointer<AppModel> guard(this);` 被当成顶层原型。合法代码里花括号
    /// 永远正确嵌套（与圆括号无关），全部记账就是自洽的；lambda 体是匿名帧。
    func applyBraces(t: String, lineNo: Int64): Unit {
        let n = Int64(t.size)
        var i: Int64 = 0
        var armed = false
        while (i < n) {
            let c = t[i]
            if (c == 123) {
                if (!armed && bodyPos >= 0 && i == bodyPos) {
                    pushFrame(declKind, declSym, declOwner)
                    armed = true
                } else {
                    pushFrame(None, -1, "")
                }
            } else if (c == 125) {
                popFrame(lineNo)
            }
            i += 1
        }
    }

    // MARK: 声明检测

    /// 待定声明遇到下一行时，这一行是不是**签名的延续**（而不是一条新语句）。
    /// 只有在签名里合法出现的词/符号才算：`: Base`、`,`、`-> T`、`where …`、`throws …`。
    func sigContinues(t: String, toks: ArrayList<Tok>): Bool {
        let f0 = toks[0]
        if (tokIsCh(t, f0, 44) || tokIsCh(t, f0, 58) || tokIsCh(t, f0, 38)) { return true }
        if (tokIsCh(t, f0, 45) && toks.size > 1 && tokIsCh(t, toks[1], 62) && f0.e == toks[1].s) { return true }
        if (!tokIsIdent(t, toks[0])) { return false }
        return SIG_CONT_WORDS.contains(tokText(t, f0))
    }

    /// C++ 访问段：`public:` / `private slots:` / `signals:`。改写最内层类型体的当前访问段。
    /// 返回 true = 本行是访问段，不是声明。
    func cAccessSpecifier(t: String, toks: ArrayList<Tok>): Bool {
        if (toks.size < 2 || !tokIsIdent(t, toks[0]) || !tokIsCh(t, toks[1], 58)) { return false }
        let w = tokText(t, toks[0])
        var v = ""
        if (w == "public") { v = "public" }
        else if (w == "private") { v = "private" }
        else if (w == "protected") { v = "protected" }
        else { return false }
        if (toks.size >= 3 && tokIsIdent(t, toks[2])) {
            let nx = tokText(t, toks[2])
            if (nx == "signals" || nx == "Q_SIGNALS") { v = "public" }
        }
        if (atMemberPos()) { frames[frames.size - 1].access = v }
        return true
    }

    /// C/C++ 类型关键字打头的**函数**：`struct Point *make(void) {`。
    /// 名字之后、第一个 `{ ; : =` 之前出现「标识符 + (」就是这种形态。
    func cTaggedReturn(t: String, toks: ArrayList<Tok>, k0: Int64): Bool {
        let nt = Int64(toks.size)
        var depth: Int64 = 0
        var k = k0
        while (k < nt) {
            let tk = toks[k]
            if (tokIsCh(t, tk, 40) || tokIsCh(t, tk, 91)) { depth += 1 }
            else if (tokIsCh(t, tk, 41) || tokIsCh(t, tk, 93)) {
                if (depth > 0) { depth -= 1 }
            } else if (depth == 0) {
                if (tokIsCh(t, tk, 123) || tokIsCh(t, tk, 59) || tokIsCh(t, tk, 58) || tokIsCh(t, tk, 61)) {
                    return false
                }
                if (tokIsIdent(t, toks[k]) && k + 1 < nt && tokIsCh(t, toks[k + 1], 40)) { return true }
            }
            k += 1
        }
        return false
    }

    /// C 系原型声明的参数表得像原型：每个非空参数段里至少有一个标识符（类型/名字）。
    /// 挡的是类体内「构造式初始化的成员」`QTimer m_timer(0);`——它与原型只差这一点。
    func protoParamsOk(t: String, open: Int64): Bool {
        let n = Int64(t.size)
        let (d, closePos) = parenScan(t, open + 1, n, 1)
        if (d > 0 || closePos < 0) { return false }
        // 「有标识符」= 段里出现一个**以字母/下划线开头**的词。数字也算标识符字节，
        // 只认字节的话 `m_timer(0)` 的 0 会被当成类型——它恰恰是这条判据要挡的东西。
        var segIdent = false
        var segContent = false
        var i = open + 1
        while (i < closePos) {
            let c = t[i]
            if (c == 44) {
                if (segContent && !segIdent) { return false }
                segIdent = false
                segContent = false
            } else if (isIdentByte(c)) {
                segContent = true
                if (!isIdentByte(t[i - 1]) && (c >= 65 && c <= 90 || c >= 97 && c <= 122 || c == 95)) {
                    segIdent = true
                }
            } else if (c != 32 && c != 9) {
                segContent = true
            }
            i += 1
        }
        if (segContent && !segIdent) { return false }
        return true
    }

    /// Go 接收者类型：`(r *Rect)` / `(q *pkg.Rect)` / `(t T)` / `(T)`。取点分链的末段，剥掉 `*`。
    func goReceiverType(t: String, toks: ArrayList<Tok>, open: Int64, close: Int64): String {
        if (close - open < 2) { return "" }
        var k = open + 1
        if (k + 1 <= close && tokIsCh(t, toks[k + 1], 42)) {
            k += 2
        } else if (k + 1 < close && tokIsIdent(t, toks[k + 1])) {
            k += 1
        }
        var last = ""
        while (k < close) {
            if (tokIsCh(t, toks[k], 91)) { break }
            if (tokIsIdent(t, toks[k])) { last = tokText(t, toks[k]) }
            k += 1
        }
        return last
    }

    /// 有返回类型的无关键字函数/方法（C/C++ 的 `Type name(`、Java 的成员方法）。
    ///
    /// 判定是一条**语句级**的规则，不是「行里有没有 `name(`」：
    ///   · 必须从语句起点开始：`返回类型 … 名字 (`，返回类型 token 序列至少一个；
    ///   · 语句里出现 `=` / `;` / `{` / `,` 而还没走到名字 ⇒ 放弃（初始化器、字段、赋值）；
    ///   · 返回类型里的词不得是停用词（return / if / using / namespace …）。
    /// 实证（修前）：`const QStringList kQuiet = { QStringLiteral("--json"), … };` 被编出一个
    /// 叫 QStringLiteral 的函数；`return foo(x);`、`connect(a, b, this, &C::f);` 同族。
    func parseCFunc(t: String, toks: ArrayList<Tok>, i0: Int64, p: Pending, tagType: Bool): Bool {
        let nt = Int64(toks.size)
        var i = i0
        if (i >= nt) { return false }
        if (!tagType && tokText(t, toks[i]) == "template") {
            i += 1
            if (i < nt && tokIsCh(t, toks[i], 60)) { i = skipAngle(t, toks, i) }
        }
        if (i >= nt) { return false }
        if (tokIsCh(t, toks[i], 60)) { i = skipAngle(t, toks, i) }   // Java 泛型方法 `<T> T foo(`
        var typeSeen = tagType
        let stop = if (lang == "java") { JAVA_STOP } else { C_STOP }
        var guardN: Int64 = 0
        while (i < nt && guardN < 400) {
            guardN += 1
            if (!tokIsIdent(t, toks[i])) {
                let c = t[toks[i].s]
                if (c == 42 || c == 38 || c == 91 || c == 93) {   // * & [ ]
                    typeSeen = true
                    i += 1
                    continue
                }
                return false
            }
            // C++ 运算符重载：`bool operator==(…) const {`
            if (typeSeen && tokText(t, toks[i]) == "operator") {
                let (opName, k2) = readOperatorName(t, toks, i)
                if (k2 < 0) { return false }
                p.name = opName
                p.nameStart = toks[i].s
                p.hasParen = true
                p.parenOpen = toks[k2].s
                p.afterName = p.parenOpen + 1
                return true
            }
            let (chain, ni) = readChain(t, toks, i, false)
            if (chain.size == 0) { return false }
            i = ni
            if (i < nt && tokIsCh(t, toks[i], 40)) {
                // 这一段就是函数名链
                let last = chain[chain.size - 1]
                if (!typeSeen) {
                    // 没有返回类型 ⇒ 调用 / 宏 / 构造函数。两种构造函数写法都不入表，
                    // 它们的声明行也不是调用点：
                    //   · 类体内「与类同名 + (」：`AppModel(QObject *parent);`
                    //   · 类外的限定名定义：`AppModel::AppModel(QObject *parent)`
                    //     （链的最后两段同名——成员函数不可能与类同名）
                    var isCtor = atMemberPos() && last[0] == lastDotSeg(frames[frames.size - 1].owner)
                    if (chain.size >= 2 && chain[chain.size - 2][0] == last[0]) { isCtor = true }
                    if (isCtor) { skipNameAt = last[1] }
                    return false
                }
                if (!nameOk(lang, last[0])) { return false }
                p.name = last[0]
                p.nameStart = last[1]
                if (chain.size > 1) { p.ownerChain = joinChain(chain, Int64(chain.size) - 1) }
                p.hasParen = true
                p.parenOpen = toks[i].s
                p.afterName = p.parenOpen + 1
                return true
            }
            // 链尾是 operator：`AppModel &operator=(…)` / `EngineCli::operator<<`
            if (chain[chain.size - 1][0] == "operator") {
                let (opName, k2) = readOperatorName(t, toks, i)
                if (k2 < 0) { return false }
                p.name = opName
                p.nameStart = chain[chain.size - 1][1]
                if (chain.size > 1) { p.ownerChain = joinChain(chain, Int64(chain.size) - 1) }
                p.hasParen = true
                p.parenOpen = toks[k2].s
                p.afterName = p.parenOpen + 1
                return true
            }
            // 否则这一段是返回类型的一部分
            if (stop.contains(chain[0][0])) { return false }
            typeSeen = true
        }
        return false
    }

    /// TS/JS 类体成员（无关键字）：`name(` / `name<T>(` / `name?(`，
    /// 或箭头函数属性 `name = [async] (…) [: Type] =>`（可选形态）。
    /// 返回名字之后的扫描起点；-1 = 不是成员声明。hasParen / parenOpen 写在 p 上。
    func parseTsMember(t: String, toks: ArrayList<Tok>, i: Int64, p: Pending): Int64 {
        let nt = Int64(toks.size)
        if (!tokIsIdent(t, toks[i])) { return -1 }
        let w = tokText(t, toks[i])
        if (!nameOk(lang, w)) { return -1 }
        p.name = w
        p.nameStart = toks[i].s
        var k = i + 1
        if (k < nt && tokIsCh(t, toks[k], 63)) { k += 1 }
        if (k < nt && tokIsCh(t, toks[k], 60)) { k = skipAngle(t, toks, k) }
        if (k < nt && tokIsCh(t, toks[k], 40)) {
            p.hasParen = true
            p.parenOpen = toks[k].s
            return toks[k].s + 1
        }
        if (k < nt && tokIsCh(t, toks[k], 61)) {
            k += 1
            if (k < nt && tokText(t, toks[k]) == "async") { k += 1 }
            if (k < nt && tokIsCh(t, toks[k], 40)) {
                k = skipBalanced(t, toks, k, 40, 41)
                var guardN: Int64 = 0
                var arrowAt: Int64 = -1
                while (k < nt && guardN < 40) {
                    guardN += 1
                    if (tokIsCh(t, toks[k], 123) || tokIsCh(t, toks[k], 59) || tokIsCh(t, toks[k], 44)) {
                        return -1   // 本行已经是函数体或语句结束，没见到 =>
                    }
                    if (tokIsCh(t, toks[k], 61) && k + 1 < nt && toks[k].e == toks[k + 1].s
                        && tokIsCh(t, toks[k + 1], 62)) {
                        arrowAt = k
                        break
                    }
                    k += 1
                }
                if (arrowAt >= 0) {
                    p.hasParen = false
                    p.bodylessComplete = true
                    return toks[arrowAt + 1].e
                }
            }
        }
        return -1
    }

    /// 行首声明检测。命中则建立待定记录并进入 start（可能当行定稿，也可能留待下一行）。
    func detect(t: String, raw: String, lineNo: Int64, strIn: Int64): Unit {
        let n = Int64(t.size)
        let toks = lexLine(t)
        let nt = Int64(toks.size)
        var i: Int64 = 0
        // 注解 / 装饰器前缀：`@Name` / `@Name(…)`（C/Go/Rust 没有）
        let usesAt = lang != "c" && lang != "go" && lang != "rust"
        while (usesAt && i < nt && tokIsCh(t, toks[i], 64)) {
            var k: Int64 = i + 1
            if (k < nt && tokIsIdent(t, toks[k])) {
                k += 1
                if (k < nt && tokIsCh(t, toks[k], 40)) { k = skipBalanced(t, toks, k, 40, 41) }
                i = k
            } else {
                break
            }
        }
        if (i >= nt) { return }
        if (lang == "c" && cAccessSpecifier(t, toks)) { return }
        companion = false
        // 签名从第一个修饰符起（`static func view(…)`、`sealed interface …`），注解不算
        let sigStart = if (i < nt) { toks[i].s } else { 0 }
        var vis = ""
        let mods = match (MODIFIERS.get(lang)) {
            case Some(m) => m
            case None => HashSet<String>()
        }
        while (i < nt && tokIsIdent(t, toks[i])) {
            let w0 = tokText(t, toks[i])
            if (!mods.contains(w0)) { break }
            if (lang == "rust" && w0 == "pub" && i + 1 < nt && tokIsCh(t, toks[i + 1], 40)) {
                vis = "internal"
                i = skipBalanced(t, toks, i + 1, 40, 41)
                continue
            }
            if (lang == "swift" && w0 == "private" && i + 1 < nt && tokIsCh(t, toks[i + 1], 40)) {
                i = skipBalanced(t, toks, i + 1, 40, 41)
                continue
            }
            // Swift 的 `class func` / `class var` 是修饰符；`class Foo` 才是类型声明
            if (lang == "swift" && w0 == "class") {
                var isMod = false
                if (i + 1 < nt && tokIsIdent(t, toks[i + 1])) {
                    let nx = tokText(t, toks[i + 1])
                    isMod = nx == "func" || nx == "var" || nx == "let"
                }
                if (!isMod) { break }
                i += 1
                continue
            }
            if (lang == "kotlin" && w0 == "companion") { companion = true }
            let v = visForWord(lang, w0)
            if (!v.isEmpty()) { vis = v }
            i += 1
        }
        if (i >= nt || !tokIsIdent(t, toks[i])) { return }
        let w = tokText(t, toks[i])
        let inFunc = isFuncOpt(enclosingKind())
        if (lang == "c") { vis = cMemberAccess() }
        let table = match (DECL_TABLES.get(lang)) {
            case Some(x) => x
            case None => return
        }

        let p = Pending()
        p.vis = vis
        p.sigStart = sigStart
        var kind: SymKind = Func
        var explicitOwner = ""
        var anonOwner = false
        var matched = false
        var j: Int64 = i + 1

        if (table.contains(w)) {
            if (w == "func" && lang != "c") {
                var k = j
                if (lang == "go" && k < nt && tokIsCh(t, toks[k], 40)) {
                    let endR = skipBalanced(t, toks, k, 40, 41)
                    explicitOwner = goReceiverType(t, toks, k, endR - 1)
                    k = endR
                }
                let (nm, st, k2) = readDeclName(lang, t, toks, k)
                var kk = k2
                if (lang == "go" && kk >= 0 && kk < nt && tokIsCh(t, toks[kk], 91)) {
                    kk = skipBalanced(t, toks, kk, 91, 93)   // Go 泛型 func name[T any](
                }
                if (kk >= 0 && kk < nt && tokIsCh(t, toks[kk], 40)) {
                    kind = Func
                    p.name = nm
                    p.nameStart = st
                    p.hasParen = true
                    p.parenOpen = toks[kk].s
                    p.afterName = p.parenOpen + 1
                    matched = true
                }
            } else if (w == "fun") {
                // fun [<T>] [Receiver.]name( —— 扩展函数的 owner 是接收者类型
                var k = j
                if (k < nt && tokIsCh(t, toks[k], 60)) { k = skipAngle(t, toks, k) }
                let (chain, k2) = readChain(t, toks, k, true)
                if (chain.size > 0 && k2 < nt && tokIsCh(t, toks[k2], 40)) {
                    let last = chain[chain.size - 1]
                    if (nameOk(lang, last[0])) {
                        kind = Func
                        p.name = last[0]
                        p.nameStart = last[1]
                        if (chain.size > 1) { explicitOwner = chain[chain.size - 2][0] }
                        p.hasParen = true
                        p.parenOpen = toks[k2].s
                        p.afterName = p.parenOpen + 1
                        matched = true
                    }
                }
            } else if (w == "fn" || w == "function") {
                var k = j
                if (w == "function" && k < nt && tokIsCh(t, toks[k], 42)) { k += 1 }   // function*
                let (nm, st, k2) = readDeclName(lang, t, toks, k)
                if (k2 >= 0 && k2 < nt && tokIsCh(t, toks[k2], 40)) {
                    kind = Func
                    p.name = nm
                    p.nameStart = st
                    p.hasParen = true
                    p.parenOpen = toks[k2].s
                    p.afterName = p.parenOpen + 1
                    matched = true
                }
            } else if (w == "class" || w == "struct" || w == "enum" || w == "interface"
                || w == "protocol" || w == "trait") {
                var k = j
                if (w == "enum" && k < nt && tokIsIdent(t, toks[k])) {
                    let nx = tokText(t, toks[k])
                    if (nx == "class" || nx == "struct") { k += 1 }   // C++ / Kotlin 的 enum class
                }
                let (nm, st, k2) = readDeclName(lang, t, toks, k)
                if (k2 >= 0) {
                    if (lang == "c" && cTaggedReturn(t, toks, k2)) {
                        matched = parseCFunc(t, toks, i, p, true)
                    } else {
                        kind = match (w) {
                            case "class" => Class
                            case "struct" => Struct
                            case "enum" => Enum
                            case _ => Interface
                        }
                        p.name = nm
                        p.nameStart = st
                        if (k2 < nt && tokIsCh(t, toks[k2], 40)) {
                            // 主构造器 / 注解实参：按参数表处理（签名可以跨行）
                            p.hasParen = true
                            p.parenOpen = toks[k2].s
                            p.afterName = p.parenOpen + 1
                        } else {
                            p.afterName = if (k2 < nt) { toks[k2].s } else { n }
                        }
                        matched = true
                    }
                }
            } else if (w == "extend" || w == "extension") {
                // 扩展体：owner 是被扩展的类型；成员的 owner 也跟着是它
                let (chain, k2) = readChain(t, toks, j, true)
                if (chain.size > 0 && nameOk(lang, chain[chain.size - 1][0])) {
                    kind = Extension
                    p.name = chain[chain.size - 1][0]
                    p.nameStart = chain[chain.size - 1][1]
                    // 扩展体本身是**顶层**声明（名字就是被扩展的类型），不是该类型的
                    // 名为「类型名」的成员——qual 必须是 `AppModel` 而不是 `AppModel.AppModel`；
                    // 嵌套类型的扩展（`extension Outer.Inner`）qual 是 Outer.Inner。
                    explicitOwner = joinChain(chain, Int64(chain.size) - 1)
                    // 体的属主域 = 被扩展类型的完整限定名：成员的 owner 跟着它走
                    p.frameOwner = joinChain(chain, Int64(chain.size))
                    p.afterName = if (k2 < nt) { toks[k2].s } else { n }
                    matched = true
                }
            } else if (w == "impl") {
                // impl Type { … } / impl Trait for Type { … }：owner 是 impl 的那个类型
                var k = j
                if (k < nt && tokIsCh(t, toks[k], 60)) { k = skipAngle(t, toks, k) }
                let (c1, k1) = readChain(t, toks, k, false)
                if (c1.size > 0) {
                    var ty = c1[c1.size - 1]
                    var k2 = k1
                    if (k1 < nt && tokIsIdent(t, toks[k1]) && tokText(t, toks[k1]) == "for") {
                        let (c2, k3) = readChain(t, toks, k1 + 1, false)
                        if (c2.size > 0) {
                            ty = c2[c2.size - 1]
                            k2 = k3
                        }
                    }
                    if (nameOk(lang, ty[0])) {
                        kind = Extension
                        p.name = ty[0]
                        p.nameStart = ty[1]
                        // impl 块是顶层声明（名字 = 实现的类型）；体的属主域 = 该类型
                        explicitOwner = ""
                        p.frameOwner = ty[0]
                        p.afterName = if (k2 < nt) { toks[k2].s } else { n }
                        matched = true
                    }
                }
            } else if (w == "object") {
                // Kotlin：命名对象是类级声明；`companion object` / 匿名 `object :` 只开属主域
                if (companion || (j < nt && !tokIsIdent(t, toks[j]))) {
                    anonOwner = true
                    p.afterName = if (j < nt) { toks[j].s } else { n }
                    matched = true
                } else {
                    let (nm, st, k2) = readDeclName(lang, t, toks, j)
                    if (k2 >= 0) {
                        kind = Class
                        p.name = nm
                        p.nameStart = st
                        p.afterName = if (k2 < nt) { toks[k2].s } else { n }
                        matched = true
                    }
                }
                if (companion && !anonOwner) { anonOwner = true }
            } else if (w == "type") {
                let (nm, st, k2) = readDeclName(lang, t, toks, j)
                if (k2 >= 0) {
                    p.name = nm
                    p.nameStart = st
                    if (lang == "go" && k2 < nt && tokIsIdent(t, toks[k2])) {
                        let nx = tokText(t, toks[k2])
                        if (nx == "struct" || nx == "interface") {
                            kind = if (nx == "struct") { Struct } else { Interface }
                            p.afterName = toks[k2].e
                        } else {
                            kind = TypeAlias
                            p.afterName = toks[k2].s
                        }
                    } else {
                        kind = TypeAlias
                        p.afterName = if (k2 < nt) { toks[k2].s } else { n }
                        if (k2 < nt && tokIsCh(t, toks[k2], 40)) {
                            p.hasParen = true
                            p.parenOpen = toks[k2].s
                            p.afterName = p.parenOpen + 1
                        }
                    }
                    matched = true
                }
            } else if (w == "typealias") {
                let (nm, st, k2) = readDeclName(lang, t, toks, j)
                if (k2 >= 0) {
                    kind = TypeAlias
                    p.name = nm
                    p.nameStart = st
                    p.afterName = if (k2 < nt) { toks[k2].s } else { n }
                    matched = true
                }
            } else if (w == "typedef") {
                // `typedef unsigned long long u64;`：名字是分号前的最后一个标识符。
                // 带括号的（函数指针 `typedef void (*Cb)(int);`）形态复杂，不收。
                var semi: Int64 = -1
                var hasParen = false
                var q: Int64 = j
                while (q < nt) {
                    if (tokIsCh(t, toks[q], 59)) { semi = q; break }
                    if (tokIsCh(t, toks[q], 40)) { hasParen = true }
                    q += 1
                }
                if (semi > j && !hasParen && tokIsIdent(t, toks[semi - 1])) {
                    let nm = tokText(t, toks[semi - 1])
                    if (nameOk(lang, nm)) {
                        kind = TypeAlias
                        p.name = nm
                        p.nameStart = toks[semi - 1].s
                        p.afterName = toks[semi].s
                        matched = true
                    }
                }
            }
        }
        if (!matched && !inFunc) {
            // ── 没有声明关键字的形态 ──
            if (lang == "c" || (lang == "java" && atMemberPos())) {
                matched = parseCFunc(t, toks, i, p, false)
            } else if (lang == "ts" && atMemberPos()) {
                let an = parseTsMember(t, toks, i, p)
                if (an >= 0) {
                    kind = Func
                    p.afterName = an
                    matched = true
                }
            } else if (lang == "go" && atMemberPos() && nt >= 2 && tokIsCh(t, toks[1], 40)
                && isInterfaceKind(frames[frames.size - 1].kind)) {
                // Go 接口体内的方法签名：`Handle(ctx context.Context) error`（没有体）
                if (nameOk(lang, w)) {
                    kind = Func
                    p.name = w
                    p.nameStart = toks[0].s
                    p.hasParen = true
                    p.parenOpen = toks[1].s
                    p.afterName = p.parenOpen + 1
                    matched = true
                }
            }
        }
        if (!matched) { return }
        if (anonOwner) {
            p.anonOwner = true
            start(p, raw, t, lineNo, strIn)
            return
        }
        p.kind = kind
        let scopeOwner = ownerFor()
        p.owner = if (explicitOwner.isEmpty()) { scopeOwner } else { explicitOwner }
        if (!p.ownerChain.isEmpty()) { p.owner = p.ownerChain }
        p.qual = if (p.owner.isEmpty()) { p.name } else { p.owner + "." + p.name }
        // 构造函数不入表：调用点 `Foo(` 解析到类型定义本身。
        // 但它的**声明行**不是调用点——把名字 token 标成「跳过」，否则头文件里的
        // `explicit AppModel(…);` 与源文件里的 `AppModel::AppModel(…) {` 会各编出
        // 一个「在类体层构造了 AppModel」的假调用点（探针工程实测）。
        if (!p.owner.isEmpty() && lastDotSeg(p.owner) == p.name && (lang == "c" || lang == "java")) {
            skipNameAt = p.nameStart
            return
        }
        if (p.vis.isEmpty()) {
            if (lang == "go") {
                p.vis = if (isUpperFirst(p.name)) { "public" } else { "private" }
            } else if (lang == "rust") {
                p.vis = "private"
            }
        }
        start(p, raw, t, lineNo, strIn)
    }

    // MARK: Python

    func pyLine(raw: String, t: String, lineNo: Int64, strIn: Int64): Unit {
        let n = Int64(t.size)
        if (pyContinue || pyDepth > 0) {
            // 续行（括号未配平 / 行尾反斜杠）：不判缩进、不判声明；调用点照常归内层函数
            scanFrom = 0
            scanTo = n
            skipNameAt = -1
            scanCaller = innerFunc()
            collectCalls(raw, t, strIn, lineNo)
            pyContinue = endsWithBackslash(t)
            let (d, _) = parenScan(t, 0, n, pyDepth)
            pyDepth = d
            lastCodeLine = lineNo
            return
        }
        let indent = leadWs(raw)
        // 回缩：缩进 >= 当前的开着的体都收尾，末行 = 上一个代码行（空行/注释行/文档串不算）
        while (frames.size > 0 && frames[frames.size - 1].indent >= indent) {
            let f = frames[frames.size - 1]
            frames.remove(at: frames.size - 1)
            if (f.sym >= 0 && recs[f.sym].endLine == 0) { recs[f.sym].endLine = lastCodeLine }
        }
        scanFrom = 0
        scanTo = n
        skipNameAt = -1
        scanCaller = innerFunc()
        lineConsumed = false
        pyDecl(t, raw, lineNo, strIn)
        lastCodeLine = lineNo
        if (!lineConsumed) { collectCalls(raw, t, strIn, lineNo) }
        pyContinue = endsWithBackslash(t)
        let (d2, _) = parenScan(t, 0, n, 0)
        pyDepth = d2
    }

    func pyDecl(t: String, raw: String, lineNo: Int64, strIn: Int64): Unit {
        let toks = lexLine(t)
        let nt = Int64(toks.size)
        if (nt < 2) { return }
        var i: Int64 = 0
        if (tokIsIdent(t, toks[0]) && tokText(t, toks[0]) == "async") { i = 1 }
        if (i + 1 >= nt || !tokIsIdent(t, toks[i]) || !tokIsIdent(t, toks[i + 1])) { return }
        let w = tokText(t, toks[i])
        var kind: SymKind = Func
        if (w == "class") {
            kind = Class
        } else if (w != "def") {
            return
        }
        let name = tokText(t, toks[i + 1])
        if (!nameOk(lang, name)) { return }
        lineConsumed = true
        // 签名：到头部那个**顶层**冒号为止（参数注解、lambda、字典字面量都在括号里）
        let n = Int64(t.size)
        var colon: Int64 = n
        var depth: Int64 = 0
        var k2 = toks[i + 1].e
        while (k2 < n) {
            let c = t[k2]
            if (c == 40 || c == 91 || c == 123) { depth += 1 }
            else if (c == 41 || c == 93 || c == 125) {
                if (depth > 0) { depth -= 1 }
            } else if (c == 58 && depth == 0) {
                colon = k2
                break
            }
            k2 += 1
        }
        let sig = safeSlice(collapseWs(t[toks[0].s..colon]), SIG_MAX_BYTES)
        var sym: Int64 = -1
        var owner = ""
        var qual = name
        if (admitDecl(kind, enclosingKind())) {
            owner = ownerFor()
            qual = if (owner.isEmpty()) { name } else { owner + "." + name }
            var col: Int64 = 0
            let kk = countWordBefore(t, toks[i + 1].s, name)
            let off = rawCodeOffset(raw, strIn, name, kk + 1)
            if (off >= 0) { col = runeCountOf(raw[0..off]) + 1 }
            // 社区约定：下划线前缀 = 内部/私有
            let vis = if (name.startsWith("_")) { "private" } else { "public" }
            sym = admit(kind, name, owner, lineNo, 0, col, sig, vis, false)
        }
        let f = Frame()
        f.kind = Some(kind)
        f.sym = sym
        f.indent = leadWs(raw)
        match (kind) {
            case Class => f.owner = qual
            case _ => ()
        }
        frames.add(f)
    }
}

///
/// ⚠️ 既有的三类假符号防线全部保留，只是换了个更严的落点：
///   (a) 局部 let/var/const 绑定行不产生符号——声明只认「行首（修饰符/注解之后）的
///       声明关键字」或「语句起点的类型序列 + 名字 + (」，绑定行两种都不是；
///       声明词按语言门控（DECL_TABLES）；
///   (b) 函数体内嵌套的 func 不入符号索引（admitDecl），类型体内方法照常入；
///   (c) Allman 风格（签名行与 `{` 不同行）由待定状态跨行定性。
public func scanSource(content: String, lang: String): SourceFacts {
    let s = Scanner(lang)
    s.scan(content)
    return SourceFacts(s.finish(), s.imports, s.importLines, s.lineCount, s.refs)
}
