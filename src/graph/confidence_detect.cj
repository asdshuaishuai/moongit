// graph/confidence_detect.cj — 置信度检测器集合（每个检测器一个纯函数）。
//
// 【纪律】每个检测器只做一件事，阈值全部引用 confidence.cj 里的常量；
// 证据字符串必须自足（file:line + 为什么可疑的可核验描述）。
package moongit.graph

import std.collection.*
import std.convert.*
import moongit.util.*

// MARK: - ① 孤儿符号

/// 定义了、但全仓没有任何**非声明位置**的标识符引用它（**符号级**）。
/// 数据来自 build.cj 累积的 `graph.referencedNames`（被使用过的符号名集合）。
///
/// ⚠️ 边界如实说：词法级引用会**高估**引用（同名巧合）⇒ 这里的「孤儿」是
/// **保守的**（宁可漏报）。真实使用但从未被提及名字的符号（纯入口 / 反射 /
/// 协议实现）会被误报，靠 `isEntryLike` 豁免入口 / 测试文件降低噪声。
/// 只判「名字从未在非声明处出现」；**传递性**死代码（如仅被同样已死的空壳引用的
/// 类型）不追。
///
/// 早期版本判定单位是**文件**（整个文件无人引用才报）—— 文件里混有活符号与
/// 死符号时漏报（只用到该文件里某一个活符号，整文件就被判为「被引用」）。
func detectOrphans(graph: CodeGraph, findings: ArrayList<Finding>): Unit {
    let perFile = HashMap<String, Int64>()
    for (f in graph.files) {
        if (f.symbols.size == 0) { continue }
        // 入口文件豁免：main / 测试文件 / 明确命名的入口（这些「没人引用」是正常的）
        let base = lastSeg(f.relPath)
        if (isEntryLike(base)) { continue }
        for (s in f.symbols) {
            if (graph.referencedNames.contains(s.name)) { continue }
            // 测试符号豁免：`@Test func testXxx` 由测试框架反射调用，源码里无引用
            if (isTestLike(s.name)) { continue }
            let c = match (perFile.get(f.relPath)) {
                case Some(v) => v
                case None => 0
            }
            if (c >= CONF_MAX_PER_KIND_PER_FILE) { continue }
            perFile[f.relPath] = c + 1
            findings.add(Finding(Orphan, f.relPath, s.line, s.name,
                "${symKindId(s.kind)} ${s.name}：定义后全仓无任何非声明处引用——"
                + "可能从未被接入，或已被替代"))
        }
    }
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

func detectFromAst(nodes: ArrayList<AstNode>, findings: ArrayList<Finding>): Unit {
    sortAstNodes(nodes)
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
func countMagicNumbers(text: String): Int64 {
    var count: Int64 = 0
    for (line in text.lazySplit("\n")) {
        count += magicCountInLine(stripComment(line))
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
    sortAstNodes(nodes)
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

/// 词法级函数信号：按「声明行 + 花括号配平」推函数体边界（只对 C 系花括号
/// 语言有效；python 缩进体不在此列，如实少报而不是乱报）。
///
/// 产出 **长度 / 空体 / 深嵌套 / 魔法数** —— 让**没有 tree-sitter 语法的语言
/// （仓颉！）也能拿到这四种函数级信号**，而不是只剩「超长函数」。
/// 吞错与重复体依赖 AST 节点边界，词法路径不产出（避免乱报）。
///
/// `astUsed=true` 时只补跑 AST **覆盖不到**的语言（否则同一处会被两条路各报一次）。
func detectLexicalFunctionSignals(graph: CodeGraph, findings: ArrayList<Finding>,
                                  astUsed: Bool): Unit {
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
                var maxRel: Int64 = 0
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
                                    maxRel = 0
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
                    // 体内统计：相对嵌套深度 + 魔法数（口径与 AST 路径一致）
                    if (bodyStarted) {
                        let rel = depth - baseDepth
                        if (rel > maxRel) { maxRel = rel }
                        bodyMagic += magicCountInLine(t)
                    }
                    // 收尾：体真的开始过、且配平回 0
                    if (depth == 0 && bodyStarted) {
                        match (pendingStub) {
                            case Some((name, ln)) =>
                                if (!bodyHadContent) {
                                    bumpFinding(findings, perFileKind, StubBody, f.relPath, ln,
                                        name, "函数体（词法判定）内无可执行内容——占位实现候选")
                                } else {
                                    if (bodyLines > CONF_LONG_FUNCTION_LINES) {
                                        bumpFinding(findings, perFileKind, LongFunction, f.relPath, ln,
                                            name, "约 ${bodyLines} 行（词法近似；阈值 ${CONF_LONG_FUNCTION_LINES}）")
                                    }
                                    if (maxRel > CONF_DEEP_NESTING) {
                                        bumpFinding(findings, perFileKind, DeepNesting, f.relPath, ln,
                                            name, "花括号嵌套 ${maxRel} 层（词法近似；阈值 ${CONF_DEEP_NESTING}）")
                                    }
                                    if (bodyMagic >= 3) {
                                        bumpFinding(findings, perFileKind, MagicNumber, f.relPath, ln,
                                            name, "函数体内 ${bodyMagic} 处裸数字字面量（词法近似；≥3 时才报）——建议提取常量")
                                    }
                                }
                            case None => ()
                        }
                        pendingStub = None
                        bodyStarted = false
                        bodyMagic = 0
                        maxRel = 0
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


// MARK: - 内建名表（未解析调用的豁免集）

/// 各语言常见内建函数/类型/命名空间名的**并集**。
/// 判据保守：宁可漏报（它本来就只是启发式信号），不可把合法调用报成幻觉。
func buildBuiltinNames(): HashSet<String> {
    let s = HashSet<String>()
    let words = [
        "print", "println", "printf", "puts", "echo", "log", "error", "warn",
        "info", "debug", "trace", "assert", "throw", "panic",
        "len", "cap", "make", "new", "append", "copy", "delete", "close",
        "recover", "Println", "Printf", "Sprintf",
        "range", "str", "int", "float", "list", "dict", "set", "tuple", "open",
        "type", "super", "isinstance", "enumerate", "zip", "map", "filter",
        "sorted", "sum", "min", "max", "abs", "round", "any", "all", "repr",
        "format", "ord", "chr", "hex", "bin", "bool", "bytes", "setattr",
        "getattr", "hasattr",
        "fatalError", "precondition", "String", "Int", "Double",
        "Bool", "Array", "Dictionary", "Set",
        "console", "fetch", "parseInt", "parseFloat", "Number", "Boolean",
        "Object", "JSON", "Math", "isFinite", "isNaN", "require", "Promise",
        "Symbol", "Error", "TypeError", "Date", "Map",
        "vec", "Some", "None", "Ok", "Err",
        "System", "out", "valueOf",
        "malloc", "free", "memcpy", "strlen", "memset", "exit",
        "ArrayList", "HashMap", "HashSet", "StringBuilder", "Path", "FileInfo",
        "Directory", "Char", "UInt8", "Int64", "Float64", "Float32", "Rune",
        "Unit", "Comparable", "Runnable", "Iterator", "Optional",
        "describe", "it", "expect", "beforeEach", "afterEach", "main",
        // node/Browser API（AI 高频使用、非项目内定义）
        "hypot", "alloc", "writeUInt32BE", "readUInt32BE", "writeInt32BE",
        "concat", "Buffer", "from", "toString", "slice", "splice", "indexOf",
        "includes", "replace", "match", "test", "split", "trim", "padStart",
        "padEnd", "entries", "keys", "values", "forEach", "reduce", "push",
        "pop", "shift", "unshift", "find", "findIndex", "some", "every",
        "flat", "fill", "join", "reverse", "sort", "at", "includes",
        "keys", "assign", "freeze", "create", "defineProperty", "getPrototypeOf",
        "preventExtensions", "isFrozen", "seal",
        "writeFileSync", "readFileSync", "existsSync", "mkdirSync", "readdirSync",
        "statSync", "unlinkSync", "appendFileSync", "copyFileSync", "rmSync",
        "writeFile", "readFile", "mkdir", "readdir", "stat", "unlink",
        "resolve", "join", "dirname", "basename", "extname", "relative",
        "createServer", "listen", "request", "get", "post", "put", "delete",
        "setTimeout", "setInterval", "clearTimeout", "clearInterval",
        "queueMicrotask", "structuredClone", "fetch",
        // Swift 协议必需方法（框架回调，永不显式调用）
        "makeNSView", "updateNSView", "makeCoordinator", "effectValue",
        "body", "onAppear", "onDisappear", "task", "onChange", "deref",
        "hash", "isEqual", "compareTo", "description"
    ]
    for (w in words) {
        let t = w.trimAscii()
        if (!t.isEmpty()) { s.add(t) }
    }
    return s
}

let BUILTIN_NAMES: HashSet<String> = buildBuiltinNames()

func isBuiltinName(name: String): Bool {
    if (BUILTIN_NAMES.contains(name)) { return true }
    let lower = lowerAscii(name)
    return BUILTIN_NAMES.contains(lower)
}


// MARK: - 幻觉调用 / 未使用 import / 注释掉的代码

/// 幻觉调用：自由函数调用 `name(`，名字全仓无定义、非内建、非接收者调用。
/// AI 生成代码的标志性病症——编造不存在的 API。数据来自 buildGraph 第二遍。
func detectUnresolvedCalls(graph: CodeGraph, findings: ArrayList<Finding>): Unit {
    let perFile = HashMap<String, Int64>()
    for ((file, name, line) in graph.unresolvedCalls) {
        // 清单/配置文件豁免：Package.swift 的 Package()/macOS() 是 SwiftPM DSL，
        // build.gradle 的 android() 同理——这些"调用"是宿主框架注入的。
        let base = lastSeg(file)
        if (base == "Package.swift" || base == "Package.resolved"
            || base == "build.gradle" || base == "build.gradle.kts"
            || base == "settings.gradle" || base == "Podfile"
            || base == "Cargo.toml" || base == "Makefile") {
            continue
        }
        let key = file
        let c = match (perFile.get(key)) {
            case Some(v) => v
            case None => 0
        }
        if (c >= CONF_MAX_PER_KIND_PER_FILE) { continue }
        perFile[key] = c + 1
        findings.add(Finding(UnresolvedCall, file, line, name,
            "调用 ${name}(…)：全仓没有该名字的定义，也不是语言内建——"
            + "可能是幻觉 API、拼错的名字，或缺失的依赖"))
    }
}

/// 未使用 import：import 解析到了目标文件，但目标文件的任何符号都没在本文件出现。
func detectUnusedImports(graph: CodeGraph, findings: ArrayList<Finding>): Unit {
    let perFile = HashMap<String, Int64>()
    for ((file, mod, line) in graph.unusedImports) {
        let key = file
        let c = match (perFile.get(key)) {
            case Some(v) => v
            case None => 0
        }
        if (c >= CONF_MAX_PER_KIND_PER_FILE) { continue }
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
                for (line in text.lazySplit("\n")) {
                    let t = line.trimAscii()
                    if (!t.startsWith("//") && !t.startsWith("#")) { continue }
                    let inner = t.trimAscii()
                    // 剥注释前缀（含 "// "、"#"、"* " 续行）
                    var body = inner
                    if (body.startsWith("//")) { body = body[2..].trimAscii() }
                    else if (body.startsWith("#")) { body = body[1..].trimAscii() }
                    else if (body.startsWith("*")) { body = body[1..].trimAscii() }
                    if (body.isEmpty()) { continue }
                    var looksCode = false
                    for (kw in kws) {
                        if (body.startsWith(kw)) { looksCode = true; break }
                    }
                    // 结构特征：以 ; 结尾，或含 " = " 且含 "("
                    if (!looksCode && body.endsWith(";")) { looksCode = true }
                    if (!looksCode && body.contains(" = ") && body.contains("(")) { looksCode = true }
                    if (!looksCode) { continue }
                    codeLines += 1
                    if (firstLine == 0) {
                        firstLine = lineNo
                        firstExcerpt = oneLineClamped(body, 60)
                    }
                }
                if (codeLines >= 3) {
                    findings.add(Finding(CommentedCode, f.relPath, firstLine, "",
                        "${codeLines} 行注释掉的代码（首行：${firstExcerpt}）——确认后应删除而非注释"))
                }
            case None => ()
        }
    }
}

// MARK: - 变量级 / 类型级 / 指针 / 并发（维度补齐：评审要求的完整覆盖）

/// 未使用变量：函数体内 `let/var/val x =` 声明后，同名标识符在该函数体内
/// 再未出现（声明行除外）。AST 函数边界内的词法统计——精确到函数作用域。
func detectUnusedVariables(nodes: ArrayList<AstNode>, findings: ArrayList<Finding>): Unit {
    let perFile = HashMap<String, Int64>()
    for (n in nodes) {
        if (n.nodeRule != "fn") { continue }
        let body = bodyText(n.text)
        if (body.isEmpty()) { continue }
        // 候选声明：逐行扫 let/var/val 前缀
        var lineNo = n.startLine
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
                if (c >= CONF_MAX_PER_KIND_PER_FILE) { continue }
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
/// 判据：声明以 `;` 结尾（没有 `{...}` 成员表）即前置声明。
func isForwardDeclaration(text: String): Bool {
    let t = text.trimAscii()
    if (t.isEmpty()) {
        return false
    }
    // 有成员表就不是前置声明（`{ }` 之间必然有内容）
    if (t.contains("{")) {
        return false
    }
    return t.endsWith(";")
}

/// 类型级信号：空类型（无成员）与上帝类（行数/方法数超阈）。
func detectTypeSignals(nodes: ArrayList<AstNode>, findings: ArrayList<Finding>): Unit {
    for (n in nodes) {
        if (n.nodeRule != "type") { continue }
        let lines = n.endLine - n.startLine + 1
        let body = bodyText(n.text)
        // 方法数：体内 func/def/function 关键词计数
        var methods: Int64 = 0
        for (line in body.lazySplit("\n")) {
            if (mayDeclare(line)) { methods += 1 }
        }
        let name = typeNameOf(n)
        // ⚠️ M3：前置声明不是空类型。它是一种**故意不暴露成员**的声明，
        // 报它「被掏空」是对 C 头文件惯用法的事实性误判。
        if (isForwardDeclaration(n.text)) {
            continue
        }
        if (methods == 0 && lines <= 3) {
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

/// 指针风险（C/C++）：文件级 malloc/calloc 与 free 计数不配对；返回栈地址 `return &`。
/// 词法级——指针语义（别名/所有权）超出静态词法能力，如实标注为启发式。
func detectPointerRisks(graph: CodeGraph, findings: ArrayList<Finding>): Unit {
    for (f in graph.files) {
        if (f.lang != "c") { continue }
        let content = readFileText("${graph.root}/${f.relPath}")
        match (content) {
            case Some(text) =>
                var allocs: Int64 = 0
                var frees: Int64 = 0
                var stackReturnLine: Int64 = 0
                var lineNo: Int64 = 0
                for (line in text.lazySplit("\n")) {
                    lineNo += 1
                    let (t, _) = stripCode(line, 0)
                    if (t.contains("malloc(") || t.contains("calloc(") || t.contains("realloc(")) {
                        allocs += 1
                    }
                    if (t.contains("free(")) { frees += 1 }
                    if (t.trimAscii().startsWith("return &") && stackReturnLine == 0) {
                        stackReturnLine = lineNo
                    }
                }
                if (allocs > frees) {
                    findings.add(Finding(PointerRisk, f.relPath, 1, "",
                        "分配 ${allocs} 次（malloc/calloc/realloc）但 free 仅 ${frees} 次——疑似内存泄漏"))
                }
                if (stackReturnLine > 0) {
                    findings.add(Finding(PointerRisk, f.relPath, stackReturnLine, "",
                        "return &… 返回栈上地址——函数返回后悬垂指针（若取的是参数/堆地址则为误报）"))
                }
            case None => ()
        }
    }
}

/// 并发链路/细节：
///   ① 全局可变状态：顶层 var/static var（无同步的共享状态起点）
///   ② 锁不平衡：同函数内 lock/acquire 无对应 unlock/release
///   ③ 持锁调用：lock 到 unlock 区间内调用**非本函数定义**的函数（死锁经典形态）
/// AST 可用时按函数节点判；降级时按文件词法近似（①仍准确——顶层判定不依赖函数边界）。
func detectConcurrencyRisks(graph: CodeGraph, nodes: ArrayList<AstNode>, astUsed: Bool, findings: ArrayList<Finding>): Unit {
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
                        if (hit) {
                            let c = match (perFile.get(f.relPath)) {
                                case Some(v) => v
                                case None => 0
                            }
                            if (c < 3) {
                                perFile[f.relPath] = c + 1
                                findings.add(Finding(GlobalMutable, f.relPath, lineNo, "",
                                    "顶层可变全局（${oneLineClamped(trimmed, 50)}）——多线程共享状态的起点，需同步或改不可变"))
                            }
                        }
                    }
                    depth += braceDelta(t)
                    if (depth < 0) { depth = 0 }
                }
            case None => ()
        }
    }
    // ② ③ 锁分析（函数边界内）
    if (!astUsed) { return }
    let perFile = HashMap<String, Int64>()
    for (n in nodes) {
        if (n.nodeRule != "fn") { continue }
        let body = bodyText(n.text)
        if (body.isEmpty()) { continue }
        // 找 lock 区间
        var lockLine: Int64 = 0
        var unlockLine: Int64 = 0
        var lineNo = n.startLine
        var locked = false
        for (line in body.lazySplit("\n")) {
            lineNo += 1
            if (!locked) {
                if (containsLockAcquire(line)) {
                    locked = true
                    lockLine = lineNo
                }
            } else {
                if (containsLockRelease(line)) {
                    unlockLine = lineNo
                    // 持锁区间（lockLine..unlockLine）内调用外部函数
                    checkLockCalls(n, lockLine, unlockLine, findings, perFile)
                    locked = false
                }
            }
        }
        if (locked && lockLine > 0) {
            // 函数结束仍持锁：不平衡（泄漏锁 / 死锁风险）
            let c = match (perFile.get(n.file)) {
                case Some(v) => v
                case None => 0
            }
            if (c < CONF_MAX_PER_KIND_PER_FILE) {
                perFile[n.file] = c + 1
                findings.add(Finding(LockImbalance, n.file, lockLine, nodeName(n),
                    "函数 ${nodeName(n)} 在 L${lockLine} 获取锁后到函数结束没有释放——锁泄漏或依赖外部释放"))
            }
        }
    }
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
                    findings: ArrayList<Finding>, perFile: HashMap<String, Int64>): Unit {
    // ⚠️ 仓颉 lambda 不允许写捕获环境——手写扫描，不用闭包。
    var idx: Int64 = 0
    for (line in n.text.lazySplit("\n")) {
        idx += 1
        if (idx < lockLine - n.startLine + 1 || idx > unlockLine - n.startLine + 1) { continue }
        let (t, _) = stripCode(line, 0)
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
                        && name != "lock" && name != "unlock"
                        && name != "acquire" && name != "release"
                        && !n.text.contains("func ${name}(")
                        && !n.text.contains("def ${name}(")) {
                        let c = match (perFile.get(n.file)) {
                            case Some(v) => v
                            case None => 0
                        }
                        if (c < CONF_MAX_PER_KIND_PER_FILE) {
                            perFile[n.file] = c + 1
                            findings.add(Finding(LockUnknownCall, n.file, n.startLine + idx - 1, name,
                                "持锁区间内调用 ${name}(…)（L${lockLine} 获取锁）——若被调方再取同一把锁即死锁"))
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

