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

/// 声明关键词的字节表（模块级预计算一次；mayDeclare 热路径上零分配比较用）
func declKeywordBytes(): Array<(UInt8, Array<UInt8>)> {
    let words = ["func", "fn", "def", "function", "class", "struct", "interface",
        "protocol", "trait", "enum", "extension", "impl", "type", "typealias", "typedef"]
    let out = ArrayList<(UInt8, Array<UInt8>)>()
    for (w in words) {
        let b = w.toArray()
        out.add((b[0], b))
    }
    return out.toArray()
}

let DECL_KEYWORDS: Array<(UInt8, Array<UInt8>)> = declKeywordBytes()

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
///       2 = 多行字符串内（碰 """ 才结束）。
/// 返回 (清洗后的代码, 新状态)。
public func stripCode(line: String, inState: Int64): (String, Int64) {
    let trimmed = line.trimAscii()
    // ① 整行注释：不参与剥串、不改状态（文档注释里的引号不该影响代码扫描）
    if (wholeLineComment(trimmed)) {
        return ("", inState)
    }
    let n = Int64(line.size)
    let out = ArrayList<UInt8>()
    var state = inState
    var i: Int64 = 0
    while (i < n) {
        let b = line[i]
        if (state == 0) {
            // 行内注释：截断（②的修法）
            if (b == 47 && i + 1 < n && line[i + 1] == 47) { break }   // //
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
            if (b == 34) {
                state = 0
                i += 1
                continue
            }
            i += 1
        } else {
            if (b == 34 && i + 2 < n && line[i + 1] == 34 && line[i + 2] == 34) {
                state = 0
                i += 3
                continue
            }
            i += 1
        }
    }
    // ③ 单行串不跨行：行尾仍在串内 → 复位（否则一个孤儿引号吞掉整个文件）
    if (state == 1) { state = 0 }
    return (fromUtf8Lossy(out.toArray()), state)
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
    public let lineCount: Int64

    public init(symbols: ArrayList<SymDecl>, imports: ArrayList<String>, lineCount: Int64) {
        this.symbols = symbols
        this.imports = imports
        this.lineCount = lineCount
    }
}

/// 声明关键词 → 符号种类。返回 None = 这行不是声明。
/// go 的 `type X struct` 是双关键词，单独在 scanLine 里特判。
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

/// 扫描整份源码。
public func scanSource(content: String): SourceFacts {
    let symbols = ArrayList<SymDecl>()
    let imports = ArrayList<String>()
    let seenImports = HashSet<String>()
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
        let imp = scanImportLine(raw.trimAscii())
        if (!imp.isEmpty() && !seenImports.contains(imp)) {
            seenImports.add(imp)
            imports.add(imp)
        }
        // stripCode 同时剥注释与字符串字面量（含跨行状态）——见函数头的三个坑
        let (t, nextState) = stripCode(raw, strState)
        strState = nextState
        if (blankLine(t)) { continue }
        // 前置过滤：不含声明关键词的行免去 tokenize 的整行分配
        if (!mayDeclare(t)) {
            continue
        }
        match (scanDeclLine(tokenize(t))) {
            case Some((kind, name)) =>
                symbols.add(SymDecl(kind, name, lineNo))
            case None => ()
        }
    }
    return SourceFacts(symbols, imports, lineCount)
}
