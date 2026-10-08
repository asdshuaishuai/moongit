// graph/confidence_ast.cj — 语法树层：调用开源 ast-grep（tree-sitter 内核）。
//
// 【不造轮子的落点】本引擎**不自研 parser**：语法树由外部开源工具 ast-grep
// 提供（brew install ast-grep；tree-sitter 语法包已内置于该二进制）。
// 可执行文件探测顺序：环境变量 → PATH 常见位置。
//
// 【降级语义】找不到 ast-grep 时返回 None，由调用方降级为词法级分析并
// **如实披露**（不许把降级说成全量）。仓颉语言没有 tree-sitter 语法包，
// ast-grep 直接拒绝；因此 .cj 文件始终走词法降级——这是覆盖边界，不是 bug。
package moongit.graph

import std.collection.*
import std.convert.*
import std.env.*
import std.posix.*
import moongit.util.*

// MARK: - 工具发现

/// ast-grep 可执行文件路径（None = 不可用）。
public func findAstGrep(): Option<String> {
    match (getVariable("MOONGIT_AST_GREP")) {
        case Some(p) =>
            if (!p.trimAscii().isEmpty()) { return Some(p.trimAscii()) }
        case None => ()
    }
    for (cand in ["/opt/homebrew/bin/ast-grep", "/usr/local/bin/ast-grep",
        "/usr/bin/ast-grep", "/home/linuxbrew/.linuxbrew/bin/ast-grep"]) {
        if (fileExists(cand)) { return Some(cand) }
    }
    return None
}

func fileExists(p: String): Bool {
    let (_, ok) = listDirChecked(dirNameOf(p))
    if (!ok) { return false }
    let base = lastSeg(p)
    let (entries, _) = listDirChecked(dirNameOf(p))
    for (e in entries) {
        if (e.name == base) { return true }
    }
    return false
}

func dirNameOf(p: String): String {
    let idx = p.lastIndexOf("/")
    match (idx) {
        case Some(i) => if (i <= 0) { return "/" } else { return p[0..i] }
        case None => return "."
    }
}

// MARK: - 语言映射

/// 图谱语言标识 → ast-grep 语言名。空串 = ast-grep 不支持（走词法降级）。
func astGrepLang(lang: String): String {
    match (lang) {
        case "swift" => "swift"
        case "ts" => "typescript"
        case "python" => "python"
        case "go" => "go"
        case "rust" => "rust"
        case "java" => "java"
        case "kotlin" => "kotlin"
        case "c" => "cpp"
        case _ => ""   // cangjie 等：tree-sitter 无语法包
    }
}

/// 每种语言的**函数/方法节点 kind**（用于规则集）。
/// 有些语言的 kind 名与其它语言不同（go 是 function_declaration、
/// rust 是 function_item、java 是 method_declaration）——探针实测所得。
func fnKindsFor(astLang: String): Array<String> {
    match (astLang) {
        case "swift" => ["function_declaration"]
        case "typescript" => ["function_declaration", "method_definition", "arrow_function"]
        case "python" => ["function_definition"]
        case "go" => ["function_declaration", "method_declaration"]
        case "rust" => ["function_item"]
        case "java" => ["method_declaration", "constructor_declaration"]
        case "kotlin" => ["function_declaration"]
        case "cpp" => ["function_definition"]
        case _ => []
    }
}

/// 每种语言的 catch 节点 kind（没有的返回空 → 该语言不做吞错检测）。
func catchKindsFor(astLang: String): Array<String> {
    match (astLang) {
        case "swift" => ["catch_block"]
        case "typescript" => ["catch_clause"]
        case "python" => ["except_clause"]
        case "go" => []   // go 的 err 模式不同，语法上无 catch 节点
        case "rust" => []
        case "java" => ["catch_clause"]
        case "kotlin" => ["catch_block"]
        case "cpp" => ["catch_clause"]
        case _ => []
    }
}

// MARK: - 规则集与调用

/// AST 分析的覆盖度事实（诚实披露用）。
public struct AstCoverage {
    public let astFiles: Int64       // 真的走了 AST 的文件数
    public let fallbackFiles: Int64  // 因语言无 tree-sitter 语法而降级的文件数
    public let fallbackLangs: String // 降级语言（去重列出）

    public init(astFiles: Int64, fallbackFiles: Int64, fallbackLangs: String) {
        this.astFiles = astFiles
        this.fallbackFiles = fallbackFiles
        this.fallbackLangs = fallbackLangs
    }
}

/// 一次 ast-grep scan 的产出（结构化节点，按文件分组好了）。
///
/// 实现：把规则集写成临时 YAML（ast-grep 的规则语法比 --pattern 表达力强，
/// 且 kind 级查询最稳），按语言分组调用 `ast-grep scan --config`，
/// 解析 JSON 输出为 AstNode。
func runAstGrep(graph: CodeGraph): Option<ArrayList<AstNode>> {
    let bin = match (findAstGrep()) {
        case Some(b) => b
        case None => return None
    }
    // 按 ast-grep 语言分组文件（一次 scan 处理一种语言，规则集按语言生成）
    let byLang = HashMap<String, ArrayList<String>>()
    for (f in graph.files) {
        let al = astGrepLang(f.lang)
        if (al.isEmpty()) { continue }
        match (byLang.get(al)) {
            case Some(list) => list.add("${graph.root}/${f.relPath}")
            case None =>
                let list = ArrayList<String>()
                list.add("${graph.root}/${f.relPath}")
                byLang[al] = list
        }
    }
    if (byLang.isEmpty()) {
        // 没有任何文件能走 AST（如全仓仓颉）——诚实：调用方必须按 None 处理降级
        return None
    }

    let all = ArrayList<AstNode>()
    // ⚠️ 确定性：HashMap 迭代顺序不定，会让命中节点的收集顺序在两次运行间变化，
    // 进而使权重并列的 findings 顺序翻转（违反「逐字节一致」契约）。按语言名排序后迭代。
    let groups = ArrayList<(String, ArrayList<String>)>()
    for ((al, files) in byLang) { groups.add((al, files)) }
    insertionSortBy(groups, { a, b => a[0] < b[0] })
    for ((al, files) in groups) {
        let rules = rulesYamlFor(al)
        if (rules.isEmpty()) { continue }
        // 临时规则文件
        let tmpDir = "${tempBase()}/moongit-conf-${getpid()}-${Int64(graph.files.size)}-${al}"
        ensureDir(tmpDir)
        let rulePath = "${tmpDir}/rule.yml"
        writeFileAtomic(rulePath, rules)
        // 文件列表分批传给 ast-grep（argv 有长度上限，500 个一批）
        var start = 0
        while (start < Int64(files.size)) {
            let batch = ArrayList<String>()
            var i = start
            while (i < Int64(files.size) && i < start + 500) {
                batch.add(files[i])
                i += 1
            }
            let args = ArrayList<String>()
            args.add("scan")
            args.add("-r")
            args.add(rulePath)
            args.add("--json=compact")
            // ⚠️ 不许加 --no-ignore：它在 ast-grep 里是**带值**参数
            // （--no-ignore <FILE_TYPE>），会把下一个参数（文件路径）当值吃掉，
            // 导致 scan 报 exit 2、stdout 全空 —— 首次实跑「命中 0 节点」的根因。
            for (p in batch) { args.add(p) }
            let r = execCapture(bin, args.toArray(), None, 120000)
            if (!r.ok() && r.stdout.trimAscii().isEmpty()) {
                // 单批失败不炸整体：继续其它批（覆盖度由 astNote 之外的总数对账）
                start = i
                continue
            }
            parseAstGrepJson(r.stdout, all)
            start = i
        }
    }
    return Some(all)
}

func tempBase(): String {
    match (getVariable("TMPDIR")) {
        case Some(v) => if (!v.trimAscii().isEmpty()) { return normalizePath(v) }
        case None => ()
    }
    return "/tmp"
}

/// 按语言生成规则集：函数/方法节点 + catch 节点。
/// 规则 id 约定：`fn` / `catch`（消费方按 id 分派语义）。
func rulesYamlFor(astLang: String): String {
    let sb = StringBuilder()
    let fns = fnKindsFor(astLang)
    if (fns.size > 0) {
        let ymlLang = yamlLang(astLang)
        if (!ymlLang.isEmpty()) {
            sb.append("id: fn\n")
            sb.append("language: ${ymlLang}\n")
            sb.append("rule:\n")
            sb.append("  any:\n")
            for (k in fns) {
                sb.append("    - kind: ${k}\n")
            }
            sb.append("message: fn\n")
            sb.append("severity: info\n")
        }
    }
    let catches = catchKindsFor(astLang)
    if (catches.size > 0) {
        let ymlLang = yamlLang(astLang)
        if (!ymlLang.isEmpty()) {
            if (sb.toString().size > 0) { sb.append("---\n") }
            sb.append("id: catch\n")
            sb.append("language: ${ymlLang}\n")
            sb.append("rule:\n")
            sb.append("  any:\n")
            for (k in catches) {
                sb.append("    - kind: ${k}\n")
            }
            sb.append("message: catch\n")
            sb.append("severity: info\n")
        }
    }
    return sb.toString()
}

/// ast-grep YAML 里的语言写法（大写驼峰）
func yamlLang(astLang: String): String {
    match (astLang) {
        case "swift" => "Swift"
        case "typescript" => "TypeScript"
        case "python" => "Python"
        case "go" => "Go"
        case "rust" => "Rust"
        case "java" => "Java"
        case "kotlin" => "Kotlin"
        case "cpp" => "Cpp"
        case _ => ""
    }
}

/// 解析 ast-grep --json=compact 输出为 AstNode 列表。
/// JSON 数组形如 [{text, range:{start:{line,column}, end:{...}}, file, ruleId, ...}]
func parseAstGrepJson(raw: String, out: ArrayList<AstNode>): Unit {
    let text = raw.trimAscii()
    if (text.isEmpty() || !text.startsWith("[")) { return }
    match (Json.parse(text)) {
        case Some(arr) =>
            let items = Json.asArr(arr)
            match (items) {
                case Some(list) =>
                    for (item in list) { parseOneAstNode(item, out) }
                case None => ()
            }
        case None => ()
    }
}

func parseOneAstNode(item: JsonValue, out: ArrayList<AstNode>): Unit {
    let file = Json.strAt(item, "file", "")
    let rule = Json.strAt(item, "ruleId", "")
    let text = Json.strAt(item, "text", "")
    if (file.isEmpty() || rule.isEmpty()) { return }
    let rng = Json.getOr(item, "range")
    let start = Json.getOr(rng, "start")
    let end = Json.getOr(rng, "end")
    // ast-grep 行号 0-based → 1-based
    let sl = Json.intAt(start, "line", 0) + 1
    let el = Json.intAt(end, "line", 0) + 1
    out.add(AstNode(file, sl, el, rule, text))
}
