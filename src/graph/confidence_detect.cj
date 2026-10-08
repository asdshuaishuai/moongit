// graph/confidence_detect.cj — 置信度检测器集合（每个检测器一个纯函数）。
//
// 【纪律】每个检测器只做一件事，阈值全部引用 confidence.cj 里的常量；
// 证据字符串必须自足（file:line + 为什么可疑的可核验描述）。
package moongit.graph

import std.collection.*
import std.convert.*
import moongit.util.*

// MARK: - ① 孤儿符号

/// 定义了、但全仓没有任何别的文件引用它。复用图已有的引用边。
///
/// ⚠️ 边界如实说：词法级引用（标识符出现）会**高估**引用（同名巧合），
/// 因此这里的「孤儿」是**保守的**——它只报「连名字都没人提」的符号。
/// 真实使用但从未被提及名字的符号（纯入口/反射调用/协议实现）会被误报，
/// 这类噪声在报告里靠 public/大写首字母的过滤降低（入口类符号不报）。
func detectOrphans(graph: CodeGraph, findings: ArrayList<Finding>): Unit {
    // 被引用的文件集合（作为 **目标** 出现在引用边里的文件）
    let referencedFiles = HashSet<String>()
    for ((_, to, _) in graph.refEdges) {
        referencedFiles.add(to)
    }
    for ((from, to) in graph.importEdges) {
        referencedFiles.add(to)
    }
    // 逐符号：定义文件从未作为被引用目标 → 整个文件的符号都算孤儿？
    // 不。逐符号判定做不到（引用边是文件级）。所以判定单位为**文件**：
    // 一个文件从未被引用 = 其所有导出符号都没人提 ⇒ 按文件中符号数计条，
    // 但合并成一条 finding（避免噪声），证据里写符号数与代表性符号名。
    for (f in graph.files) {
        if (referencedFiles.contains(f.relPath)) { continue }
        if (f.symbols.size == 0) { continue }
        // 入口文件豁免：main / 测试文件 / 明确命名的入口
        let base = lastSeg(f.relPath)
        if (isEntryLike(base)) { continue }
        var names = ArrayList<String>()
        for (s in f.symbols) {
            if (!names.contains(s.name)) { names.add(s.name) }
            if (Int64(names.size) >= 4) { break }
        }
        let more = if (Int64(f.symbols.size) > Int64(names.size)) { " 等" } else { "" }
        findings.add(Finding(Orphan, f.relPath, 1,
            names[0],
            "文件内 ${Int64(f.symbols.size)} 个符号（${joinStrings(names, "、")}${more}）"
            + "全仓无任何文件引用——可能从未被接入，或已被替代"))
    }
}

/// 入口/测试/协议实现类文件名豁免（这些「没人引用」是正常的）。
func isEntryLike(base: String): Bool {
    let b = lowerAscii(base)
    let marks = ["main.", "app.", "index.", "entry.", "mod.", "lib.", "package.",
        "test", "spec", "xctest", "demo", "example", "preview"]
    for (m in marks) {
        if (b.contains(m)) { return true }
    }
    return false
}

// MARK: - ② 可疑命名

/// 可疑命名：AI 生成代码的高频命名习惯。
/// 判据全部基于**可核验的字符串事实**（精确名或前缀），不做语义猜测。
func detectSuspiciousNames(graph: CodeGraph, findings: ArrayList<Finding>): Unit {
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
            if (fc >= CONF_MAX_PER_KIND_PER_FILE) { continue }
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

/// TODO 标记判定：**词边界**精确匹配。
/// ⚠️ 首次实跑修：原版 `contains("XXX")` 把注释里的占位符说明
/// （`\uXXXX`、`m_xxx`、`0xxxxxxx`）全报了 9 条假阳性；
/// 中文「未实现/待实现」太宽（正常描述性注释也命中），去掉了。
/// 现在只认大写 TODO/FIXME/HACK，以及**独立成词**的 XXX。
func containsTodo(line: String): Bool {
    let n = Int64(line.size)
    var i: Int64 = 0
    while (i < n) {
        let b = line[i]
        // 词首候选：字母（区分大小写：只认大写形态）
        if (b >= 65 && b <= 90) {
            var j = i
            while (j < n && isIdentByte(line[j])) { j += 1 }
            let word = line[i..j]
            if (word == "TODO" || word == "FIXME" || word == "HACK") { return true }
            if (word == "XXX") {
                // 独立成词才算（前面不能是下划线/字母——已在词首保证）
                return true
            }
            i = j
        } else {
            i += 1
        }
    }
    return false
}

func upperAscii(s: String): String {
    let out = ArrayList<UInt8>()
    for (b in s) {
        if (b >= 97 && b <= 122) { out.add(b - 32) } else { out.add(b) }
    }
    return fromUtf8Lossy(out.toArray())
}

// MARK: - ④ AST 节点信号（空体/长度/嵌套/魔法数/吞错）

func detectFromAst(nodes: ArrayList<AstNode>, findings: ArrayList<Finding>): Unit {
    let perFileKind = HashMap<String, Int64>()   // "file|kind" → count
    for (n in nodes) {
        let lines = n.endLine - n.startLine + 1
        // 空体/占位实现
        match (stubReason(n)) {
            case Some(why) =>
                bumpFinding(findings, perFileKind, StubBody, n.file, n.startLine,
                    nodeName(n), "结构节点（${lines} 行）：${why}")
            case None => ()
        }
        // 超长函数
        if (n.nodeRule == "fn" && lines > CONF_LONG_FUNCTION_LINES) {
            bumpFinding(findings, perFileKind, LongFunction, n.file, n.startLine,
                nodeName(n), "${lines} 行（阈值 ${CONF_LONG_FUNCTION_LINES}）——拆分候选")
        }
        // 深嵌套
        let depth = maxBraceDepth(n.text)
        if (depth > CONF_DEEP_NESTING) {
            bumpFinding(findings, perFileKind, DeepNesting, n.file, n.startLine,
                nodeName(n), "花括号嵌套 ${depth} 层（阈值 ${CONF_DEEP_NESTING}）")
        }
        // 魔法数字（函数体里）
        if (n.nodeRule == "fn") {
            let magic = countMagicNumbers(n.text)
            if (magic >= 3) {
                bumpFinding(findings, perFileKind, MagicNumber, n.file, n.startLine,
                    nodeName(n), "函数体内 ${magic} 处裸数字字面量（≥3 时才报）——建议提取常量")
            }
        }
        // 吞错误：catch 块仅只有注释或空
        if (n.nodeRule == "catch") {
            match (swallowedReason(n.text)) {
                case Some(why) =>
                    bumpFinding(findings, perFileKind, SwallowedError, n.file, n.startLine,
                        nodeName(n), why)
                case None => ()
            }
        }
    }
}

/// 限流 + 加一条 finding。**唯一的 findings.add 路径**（保证限流无法绕过）。
func bumpFinding(findings: ArrayList<Finding>, perFileKind: HashMap<String, Int64>,
                 kind: FlawKind, file: String, line: Int64, symbol: String, evidence: String): Unit {
    let key = "${file}|${flawId(kind)}"
    let c = match (perFileKind.get(key)) {
        case Some(v) => v
        case None => 0
    }
    if (c >= CONF_MAX_PER_KIND_PER_FILE) { return }
    perFileKind[key] = c + 1
    findings.add(Finding(kind, file, line, symbol, evidence))
}

/// 节点名：从文本里抽第一个标识符串（尽力而为，失败给空）
func nodeName(n: AstNode): String {
    // ast-grep 的 text 首行形如 "func foo(...)" / "class Bar {" / "def baz("
    for (line in n.text.lazySplit("\n")) {
        let toks = tokenize(line)
        for (t in toks) {
            if (!KEYWORDS.contains(t) && looksLikeName(t)) {
                return t
            }
        }
        return ""
    }
    return ""
}

/// 提取节点体。**AST 路径的第一处实跑 bug 就出在这里**：
/// 节点 text 是**整段声明**（`func x() {}`），拿整段去剥壳永远是
/// "funcx" 这种非空串 —— 空体检测、吞错检测、重复体哈希全都不触发。
/// 规则：有 `{` 取首 `{` 与末 `}` 之间；没有（Python 缩进体）丢首行取剩余。
func bodyText(text: String): String {
    let n = Int64(text.size)
    var first: Int64 = -1
    var last: Int64 = -1
    var i: Int64 = 0
    while (i < n) {
        if (text[i] == 123) {
            if (first < 0) { first = i }
            last = i
        }
        i += 1
    }
    if (first >= 0 && last > first) {
        return text[first + 1..last]
    }
    // 缩进体：丢首行
    var lineEnd: Int64 = -1
    i = 0
    while (i < n) {
        if (text[i] == 10) {   // '\n'
            lineEnd = i
            break
        }
        i += 1
    }
    if (lineEnd >= 0) { return text[lineEnd + 1..] }
    return ""
}

/// 占位实现判定：结构级空体（不是「短」而是「什么都没有」）。
func stubReason(n: AstNode): Option<String> {
    let body = bodyText(n.text)
    // 空花括号（容许注释）
    let stripped = removeCommentsAndBlanks(body)
    if (stripped.isEmpty()) {
        return Some("函数体为空")
    }
    // 只有 pass / return nil / return None / return / {} / 单条 return
    let t = stripped.trimAscii()
    if (t == "pass" || t == "..." || t == "{}" || t == "()") {
        return Some("占位语句（${t}）")
    }
    if (t == "return" || t == "return nil" || t == "return None" || t == "return null"
        || t == "return undefined" || t == "return 0" || t == "return 1"
        || t == "return false" || t == "return true" || t == "return []"
        || t == "return {}") {
        return Some("常量占位返回（${t}）")
    }
    return None
}

/// 去掉注释行与空白后剩下的内容（用于空体判定）。
/// 启发式：按行过滤「整行注释」与空行，把剩余行拼接。行尾注释不剥 —— 
/// 行尾注释后必然还有代码，不影响「是否为空」的判定。
func removeCommentsAndBlanks(text: String): String {
    let sb = StringBuilder()
    for (line in text.lazySplit("\n")) {
        let t = stripComment(line)
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

/// 花括号最大嵌套深度（跳过字符串里的大括号 —— 简单启发：引号内不计）
func maxBraceDepth(text: String): Int64 {
    var depth: Int64 = 0
    var maxD: Int64 = 0
    var inStr = false
    var quoteCh: UInt8 = 0
    let n = Int64(text.size)
    var i: Int64 = 0
    while (i < n) {
        let b = text[i]
        if (inStr) {
            if (b == 92) {           // 反斜杠转义
                i += 2
                continue
            }
            if (b == quoteCh) { inStr = false }
        } else {
            if (b == 34 || b == 39) {   // " 或 '
                inStr = true
                quoteCh = b
            } else if (b == 123) {
                depth += 1
                if (depth > maxD) { maxD = depth }
            } else if (b == 125) {
                if (depth > 0) { depth -= 1 }
            }
        }
        i += 1
    }
    return maxD
}

/// 魔法数字计数：裸数字字面量（长度 ≥ 2 位，或非 0/1/2/10/100 的常见豁免），
/// 排除注释行。判据：连续数字串且前一个非标识符字符（不是变量名的一部分）
/// 且值不在豁免表（0/1/2/10/100/1000/60/24/1024）。
func countMagicNumbers(text: String): Int64 {
    let exempt = HashSet<String>()
    for (v in ["0", "1", "2", "10", "100", "1000", "60", "24", "1024",
        "255", "360", "365", "12", "7", "30"]) {
        exempt.add(v)
    }
    var count: Int64 = 0
    for (line in text.lazySplit("\n")) {
        let t = stripComment(line)
        if (blankLine(t)) { continue }
        let n = Int64(t.size)
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
                    if (!lit.isEmpty() && !exempt.contains(lit) && !lit.contains(".")) {
                        count += 1
                    }
                }
                i = j
            } else {
                i += 1
            }
        }
    }
    return count
}

/// 吞错误判定：catch 体去掉注释/空白后为空，或只有 pass。
func swallowedReason(text: String): Option<String> {
    let stripped = removeCommentsAndBlanks(bodyText(text))
    let t = stripped.trimAscii()
    if (t.isEmpty() || t == "pass" || t == "...") {
        return Some("catch/except 块内没有任何处理——错误被静默吞掉")
    }
    return None
}

// MARK: - ⑤ 重复函数体

/// 完全相同的函数体（去注释/空白后逐字节相同，长度 ≥ 阈值）。
/// AI 复制粘贴的高频形态；同一个 bug 会有 N 份。
func detectDuplicateBodies(nodes: ArrayList<AstNode>, findings: ArrayList<Finding>): Unit {
    let byHash = HashMap<String, ArrayList<AstNode>>()
    for (n in nodes) {
        if (n.nodeRule != "fn") { continue }
        // 哈希体（不含声明行）——否则函数名不同就哈希不同，重复体永远检测不到
        let body = removeCommentsAndBlanks(bodyText(n.text))
        if (Int64(body.size) < 120) { continue }   // 太短的不算（getter/setter 天然像）
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

/// 无 AST 时的近似：按「声明行 + 花括号配平」推函数体边界（只对
/// C 系花括号语言有效；python 缩进体不在此列，如实少报而不是乱报）。
func detectLexicalFunctionSignals(graph: CodeGraph, findings: ArrayList<Finding>): Unit {
    let perFileKind = HashMap<String, Int64>()
    for (f in graph.files) {
        // 按语法上可能有花括号体的语言做
        if (!braceLang(f.lang)) { continue }
        let content = readFileText("${graph.root}/${f.relPath}")
        match (content) {
            case Some(text) =>
                var lineNo: Int64 = 0
                var pendingStub: Option<(String, Int64)> = None
                var depth: Int64 = 0
                var bodyLines: Int64 = 0
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
                                    bodyHadContent = false
                                    bodyStarted = false
                                }
                            case None => ()
                        }
                    }
                    let opens = braceOpenCount(t)
                    let closes = braceCloseCount(t)
                    // 体开始：第一个 '{' 出现在「待跟随声明之后」的任意行
                    if (!bodyStarted && pendingStub.isSome() && opens > 0 && depth == 0) {
                        bodyStarted = true
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
                    // 收尾：体真的开始过、且配平回 0
                    if (depth == 0 && bodyStarted) {
                        match (pendingStub) {
                            case Some((name, ln)) =>
                                if (!bodyHadContent) {
                                    bumpFinding(findings, perFileKind, StubBody, f.relPath, ln,
                                        name, "函数体（词法判定）内无可执行内容——占位实现候选")
                                } else if (bodyLines > CONF_LONG_FUNCTION_LINES) {
                                    bumpFinding(findings, perFileKind, LongFunction, f.relPath, ln,
                                        name, "约 ${bodyLines} 行（词法近似；阈值 ${CONF_LONG_FUNCTION_LINES}）")
                                }
                            case None => ()
                        }
                        pendingStub = None
                        bodyStarted = false
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

/// 一行的花括号净增量（跳过字符串内）
func braceDelta(line: String): Int64 {
    let t = stripComment(line)
    var d: Int64 = 0
    var inStr = false
    var quoteCh: UInt8 = 0
    let n = Int64(t.size)
    var i: Int64 = 0
    while (i < n) {
        let b = t[i]
        if (inStr) {
            if (b == 92) { i += 2; continue }
            if (b == quoteCh) { inStr = false }
        } else {
            if (b == 34 || b == 39) {
                inStr = true
                quoteCh = b
            } else if (b == 123) {
                d += 1
            } else if (b == 125) {
                d -= 1
            }
        }
        i += 1
    }
    return d
}
