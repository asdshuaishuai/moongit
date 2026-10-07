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

/// 把一行切成标识符 token 序列。字节级扫描：
/// 非 ASCII 字节（中文注释等）天然是分隔符，不会被误认成标识符。
public func tokenize(line: String): ArrayList<String> {
    let out = ArrayList<String>()
    let bytes = line.toArray()
    var cur = ArrayList<UInt8>()
    for (b in bytes) {
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

/// 去掉行内注释（启发式：整行注释前缀 + `//` 截断）。
/// 字符串里的 `//`（如 URL）会被误截 —— 词法级提取可接受的噪音，
/// 换取的是零字符串状态机复杂度；误截的后果是**少**一个符号，不会编一个。
func stripComment(line: String): String {
    let t = line.trimAscii()
    if (t.startsWith("//") || t.startsWith("#") || t.startsWith("/*")
        || t.startsWith("*") || t.startsWith("--")) {
        return ""
    }
    let bytes = line.toArray()
    var i: Int64 = 0
    while (i + 1 < Int64(bytes.size)) {
        if (bytes[i] == 47 && bytes[i + 1] == 47) {   // '/'
            return fromUtf8Lossy(bytes[0..i])
        }
        i += 1
    }
    return line
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
    if (t.startsWith("import ")) {
        // go：import "a/b/c" → 取引号内最后一段
        let q = quotedPart(t)
        if (!q.isEmpty()) {
            let segs = q.split("/")
            return segs[segs.size - 1]
        }
        let toks = tokenize(t)
        if (toks.size >= 2) {
            // 仓颉/swift 的跨包引用语义在**末段**（import moongit.util → util），
            // 这才是能命中项目内目录/文件名的那一段；python 无此写法不受影响
            let segs = toks[1].split(".")
            var cand = segs[segs.size - 1]
            if (cand == "*") {
                cand = if (segs.size >= 2) { segs[segs.size - 2] } else { "" }
            }
            if (cand != "_" && cand != "as" && cand != "}") { return cand }
        }
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
    for (raw in content.split("\n")) {
        lineNo += 1
        lineCount = lineNo
        let t = stripComment(raw)
        if (t.trimAscii().isEmpty()) { continue }
        match (scanDeclLine(tokenize(t))) {
            case Some((kind, name)) =>
                symbols.add(SymDecl(kind, name, lineNo))
            case None => ()
        }
        let imp = scanImportLine(t.trimAscii())
        if (!imp.isEmpty() && !seenImports.contains(imp)) {
            seenImports.add(imp)
            imports.add(imp)
        }
    }
    return SourceFacts(symbols, imports, lineCount)
}
