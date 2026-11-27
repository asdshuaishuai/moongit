// graph/confidence_ast.cj — 语法树层：调用开源 ast-grep（tree-sitter 内核）。
//
// 【不造轮子的落点】本引擎**不自研 parser**：语法树由外部开源工具 ast-grep
// 提供（brew install ast-grep；tree-sitter 语法包已内置于该二进制；没有 root 时
// `npm install -g @ast-grep/cli` 或 `cargo install ast-grep` 装进用户目录即可）。
// 可执行文件探测顺序：环境变量 CAMBIUM_AST_GREP → PATH → 用户目录的常见安装位置 → 系统级固定路径。
// 原先只查 4 个固定路径、不查 PATH（注释里却写着「PATH 常见位置」）：cargo / npm 装的 ast-grep 引擎看不到，
// 装了也白装——本机就是这样，置信度一直跑在词法档。
//
// 【降级语义】找不到 ast-grep 时返回 None，由调用方降级为词法级分析并
// **如实披露**（不许把降级说成全量）。仓颉语言没有 tree-sitter 语法包，
// ast-grep 直接拒绝；因此 .cj 文件始终走词法降级——这是覆盖边界，不是 bug。
package cambium.dendro

import std.collection.*
import std.convert.*
import std.env.*
import std.posix.*
import cambium.util.*
import cambium.graph.*

// MARK: - 工具发现

/// tmpDirRoot 的包级持有（runAstGrep 设置；parse 阶段做路径映回）
var C_AS_CPP_ROOT: String = ""
/// 仓库根的包级持有：parse 阶段把绝对路径映回 relPath 用（M1）
var AST_SCAN_ROOT: String = ""
/// 本次运行创建的临时目录（扫完即清，M2）
let tmpDirs = ArrayList<String>()
/// 批失败统计的包级持有（复审 M2 残留：批失败要进报告的 astNote，
/// 不能只进日志——读报告的人无从分辨「覆盖不完整」与「没有疑点」。
/// 0/0 = ast-grep 未运行或无批次）
var AST_FAILED_BATCHES: Int64 = 0
var AST_TOTAL_BATCHES: Int64 = 0
/// 本次运行里因 ast-grep 版本不认而被剔除的节点种类（"swift.struct_declaration"），写进 astNote。
var AST_DROPPED_KINDS = ArrayList<String>()
/// 本次运行里因签名不成其为签名而被丢弃的函数节点数（tree-sitter 错误恢复的产物），写进 astNote。
var AST_DROPPED_NODES: Int64 = 0

/// ast-grep 可执行文件路径（None = 不可用）。环境变量 → PATH → 用户目录常见位置 → 系统级固定路径。
public func findAstGrep(): Option<String> {
    match (getVariable("CAMBIUM_AST_GREP")) {
        case Some(p) =>
            if (!p.trimAscii().isEmpty()) { return Some(p.trimAscii()) }
        case None => ()
    }
    match (findOnPath("ast-grep")) {
        case Some(p) => return Some(p)
        case None => ()
    }
    match (getVariable("HOME")) {
        case Some(h) =>
            let home = h.trimAscii()
            if (!home.isEmpty()) {
                for (d in [".local/bin", ".cargo/bin", ".npm-global/bin", ".linuxbrew/bin"]) {
                    let cand = home + "/" + d + "/ast-grep"
                    if (fileExists(cand)) { return Some(cand) }
                }
            }
        case None => ()
    }
    for (cand in ["/opt/homebrew/bin/ast-grep", "/usr/local/bin/ast-grep",
        "/usr/bin/ast-grep", "/home/linuxbrew/.linuxbrew/bin/ast-grep"]) {
        if (fileExists(cand)) { return Some(cand) }
    }
    return None
}

/// 在 PATH 的每个目录里找 [name]：与 shell 的解析一致——按 PATH 顺序，找到的第一个为准（装了多个版本时由顺序决定）。
/// 空目录段跳过（shell 把空段当当前目录，这里不认：cwd 上恰好有个同名文件不该被当成装了工具）。
func findOnPath(name: String): Option<String> {
    match (getVariable("PATH")) {
        case Some(path) =>
            for (seg in path.split(":")) {
                let d = seg.trimAscii()
                if (d.isEmpty()) { continue }
                let cand = d + "/" + name
                if (fileExists(cand)) { return Some(cand) }
            }
        case None => ()
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

/// 每种语言的**类型声明节点 kind**（类/结构体/接口/枚举）——类型级检测用。
/// 之前只抓 fn/catch，类级信号（空类、上帝类）没有数据源。
func typeKindsFor(astLang: String): Array<String> {
    match (astLang) {
        case "swift" => ["class_declaration", "struct_declaration", "protocol_declaration", "enum_declaration"]
        case "typescript" => ["class_declaration", "interface_declaration", "type_alias_declaration"]
        case "python" => ["class_definition"]
        case "go" => ["type_declaration"]
        case "rust" => ["struct_item", "enum_item", "trait_item"]
        case "java" => ["class_declaration", "interface_declaration", "enum_declaration"]
        case "kotlin" => ["class_declaration", "object_declaration"]
        case "cpp" => ["class_specifier", "struct_specifier"]
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
    // .c 文件 ast-grep 只认后缀（Cpp 规则不扫 .c）——复制为 .cpp 临时副本再扫，
    // 扫完把结果里的 .cpp 路径映回原 .c（Cpp 是 C 的超集，解析结果可靠）。
    let tmpDirRoot = "${tempBase()}/cambium-c-as-cpp-${getpid()}"
    C_AS_CPP_ROOT = tmpDirRoot
    // 批失败统计复位必须在**一切早退之前**（含 byLang 空仓的 return None）：
    // 否则同进程二次分析会读到上一次的脏值，把「语言无覆盖」误说成「批次失败」
    AST_FAILED_BATCHES = 0
    AST_TOTAL_BATCHES = 0
    AST_DROPPED_KINDS.clear()
    AST_DROPPED_NODES = 0
    var tmpPrepared = false
    for (f in graph.files) {
        var al = astGrepLang(f.lang)
        if (al.isEmpty()) { continue }
        var scanPath = "${graph.root}/${f.relPath}"
        if (f.lang == "c") {
            al = "cpp"
            if (!tmpPrepared) {
                ensureDir(tmpDirRoot)
                tmpPrepared = true
            }
            let dst = "${tmpDirRoot}/${sanitizePathToName(f.relPath)}.cpp"
            match (readFileText(scanPath)) {
                case Some(text) => writeFileAtomic(dst, text)
                case None => continue
            }
            scanPath = dst
        }
        match (byLang.get(al)) {
            case Some(list) => list.add(scanPath)
            case None =>
                let list = ArrayList<String>()
                list.add(scanPath)
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
    // M2：批失败的计数。原来 `!ok && stdout 空` 就静默 continue ——
    // 全部批失败时仍返回 Some(空列表)，调用方于是报 astUsed=true、
    // astNote 只说「命中 0 个结构节点」：读者无从分辨「没有疑点」与
    // 「工具根本没跑成」。「降级必须如实披露」在这里被违反。
    var totalBatches: Int64 = 0
    var failedBatches: Int64 = 0
    AST_SCAN_ROOT = graph.root
    for ((al, files) in groups) {
        let rules = rulesYamlFor(bin, al)
        if (rules.isEmpty()) { continue }
        // 临时规则文件
        let tmpDir = "${tempBase()}/cambium-conf-${getpid()}-${Int64(graph.files.size)}-${al}"
        ensureDir(tmpDir)
        let rulePath = "${tmpDir}/rule.yml"
        writeFileAtomic(rulePath, rules)
        tmpDirs.add(tmpDir)
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
            totalBatches += 1
            if (!r.ok() && r.stdout.trimAscii().isEmpty()) {
                // 单批失败不炸整体：继续其它批，但要计数 —— 计数决定
                // 最后是「降级」还是「照常」。
                failedBatches += 1
                start = i
                continue
            }
            parseAstGrepJson(r.stdout, all)
            start = i
        }
    }
    // 复审 M2 残留：批失败情况带回给调用方（confidence.cj 写进 astNote——
    // 只进日志的话，读报告的人仍无从分辨「覆盖不完整」与「没有疑点」）
    AST_TOTAL_BATCHES = totalBatches
    AST_FAILED_BATCHES = failedBatches
    // M2：全部批都失败 ⇒ 这不是「没有疑点」，是「AST 这一路没跑成」。
    // 返回 None 让调用方如实降级（astUsed=false + astNote 说清原因）。
    if (totalBatches > 0 && failedBatches == totalBatches) {
        Log.warn("ast-grep 全部 ${totalBatches} 个批次失败，本次降级为纯词法分析")
        cleanupAstTmpDirs()
        return None
    }
    if (failedBatches > 0) {
        Log.warn("ast-grep ${failedBatches}/${totalBatches} 个批次失败，AST 覆盖面不完整")
    }
    cleanupAstTmpDirs()
    return Some(all)
}

/// M2：临时目录（.c→.cpp 副本 + 每语言规则目录）扫完即清。
/// 原来没有任何清理路径 —— 每次进程运行在 /tmp 残留一组（含 pid，非无限累积），
/// 而没人会去扫 /tmp 里的 cambium-* 目录。用完即清才是「工具」的礼貌。
func cleanupAstTmpDirs(): Unit {
    for (d in tmpDirs) {
        removePathIfExists(d)
    }
    tmpDirs.clear()
    if (!C_AS_CPP_ROOT.isEmpty()) {
        removePathIfExists(C_AS_CPP_ROOT)
    }
}

/// 路径 → 文件名安全编码。**可逆且无碰撞**：先转义 `%`（→`%25`）再转义
/// `/`（→`%2F`）。旧方案 "/"→"__" 不闭合：`a/b.c` 与字面 `a__b.c` 编码后
/// 同名互覆，还原时 replace("__","/") 还会破坏含字面 `__` 的路径
/// （复审 2026-10-10 新问题 3）。
func sanitizePathToName(relPath: String): String {
    return relPath.replace("%", "%25").replace("/", "%2F")
}

/// sanitizePathToName 的逆（按编码的逆序替换）
func unsanitizePathName(name: String): String {
    return name.replace("%2F", "/").replace("%25", "%")
}

func tempBase(): String {
    match (getVariable("TMPDIR")) {
        case Some(v) => if (!v.trimAscii().isEmpty()) { return normalizePath(v) }
        case None => ()
    }
    return "/tmp"
}

/// 按语言生成规则集：函数/方法 + 类型声明 + catch 节点。
/// 规则 id 约定：`fn` / `type` / `catch`（消费方按 id 分派语义）。
func rulesYamlFor(bin: String, astLang: String): String {
    let ymlLang = yamlLang(astLang)
    if (ymlLang.isEmpty()) { return "" }
    let sb = StringBuilder()
    appendRule(sb, "fn", validKinds(bin, astLang, ymlLang, fnKindsFor(astLang)), ymlLang)
    appendRule(sb, "type", validKinds(bin, astLang, ymlLang, typeKindsFor(astLang)), ymlLang)
    appendRule(sb, "catch", validKinds(bin, astLang, ymlLang, catchKindsFor(astLang)), ymlLang)
    return sb.toString()
}

/// 一条规则（kind 的「任一」）；这一组没有可用种类就不写。
func appendRule(sb: StringBuilder, rid: String, kinds: ArrayList<String>, ymlLang: String): Unit {
    if (kinds.size == 0) { return }
    if (sb.toString().size > 0) { sb.append("---\n") }
    sb.append("id: ${rid}\n")
    sb.append("language: ${ymlLang}\n")
    sb.append("rule:\n")
    sb.append("  any:\n")
    for (k in kinds) {
        sb.append("    - kind: ${k}\n")
    }
    sb.append("message: ${rid}\n")
    sb.append("severity: info\n")
}

/// 规则里的每一种节点先拿 ast-grep 本人验证，不认的剔除并记进 [AST_DROPPED_KINDS]。
///
/// 【为什么必须有这一步】节点种类名跟着 ast-grep 内置的 tree-sitter 语法版本走，各版本会变：
/// Swift 的 `struct_declaration` / `enum_declaration` 在 0.51 上已并入 `class_declaration`
/// （macOS 上 brew 装的旧版两者都认，探针实测所得的那张表就是那时记下的）。
/// 而规则是「任一命中」的一整份——混进一个不认的种类，ast-grep **整份规则拒绝**，
/// 这一语言的语法树信号就全丢了。实测 deepDolphin：Swift 那一批整个失败，
/// 只在 astNote 里留下一句「1/4 个批次失败」。
/// 验证方法与正式扫描同构：单种类的规则、空的输入跑一次，退出码 0 才算认。
func validKinds(bin: String, astLang: String, ymlLang: String, kinds: Array<String>): ArrayList<String> {
    let out = ArrayList<String>()
    if (kinds.size == 0) { return out }
    let tmpDir = "${tempBase()}/cambium-conf-${getpid()}-probe-${astLang}"
    ensureDir(tmpDir)
    tmpDirs.add(tmpDir)
    for (k in kinds) {
        let probe = "${tmpDir}/probe.yml"
        writeFileAtomic(probe, "id: probe\nlanguage: ${ymlLang}\nrule:\n  kind: ${k}\nmessage: probe\nseverity: info\n")
        let args = ArrayList<String>()
        args.add("scan")
        args.add("-r")
        args.add(probe)
        args.add("--json=compact")
        let r = execCapture(bin, args.toArray(), None, 20000)
        if (r.ok()) {
            out.add(k)
        } else {
            AST_DROPPED_KINDS.add("${astLang}.${k}")
        }
    }
    return out
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
    var file = Json.strAt(item, "file", "")
    let rule = Json.strAt(item, "ruleId", "")
    let text = Json.strAt(item, "text", "")
    if (file.isEmpty() || rule.isEmpty()) { return }
    // ⚠️ M1：AstNode.file 必须是**统一的 relPath**。原来只有 .c→.cpp 那条
    // 做了映回，其余语言把绝对路径原样带出 ⇒ 同一份报告里 findings.file 与
    // 罚分表（用 relPath）混着两种形态，与 graph tree/symbol 出口对不上账；
    // 一个被 AST 和词法同时命中的文件还会在罚分表里拆成两行、罚分被分散。
    if (!AST_SCAN_ROOT.isEmpty() && file.startsWith(AST_SCAN_ROOT + "/")) {
        file = file[AST_SCAN_ROOT.size + 1..]
    }
    // .c → .cpp 临时副本的映回：tmp/x_y.cpp → 原始 x/y.c（目录名即路径编码）
    if (!C_AS_CPP_ROOT.isEmpty() && file.startsWith(C_AS_CPP_ROOT + "/")) {
        let stem = lastSeg(file)
        let dot = stem.lastIndexOf(".")
        if (dot.isSome()) {
            let encoded = stem[0..dot.getOrThrow()]
            // sanitizePathToName 是百分号转义（%25/%2F），按逆序还原。
            // ⚠️ 不能再拼 ".c"：编码名保留的是原始 relPath 全名（含 .c），
            // 再拼一次就是 "t.c.c" —— 实测漏网：同一份报告里词法路径的
            // findings 是 t.c、AST 路径却是 t.c.c（终审抓到）。
            file = unsanitizePathName(encoded)
        }
    }
    // 函数节点的签名必须像签名（见 plausibleSignature）：错误恢复揉出来的假节点不进任何检测器
    if (rule == "fn" && !plausibleSignature(text)) {
        AST_DROPPED_NODES += 1
        return
    }
    let rng = Json.getOr(item, "range")
    let start = Json.getOr(rng, "start")
    let end = Json.getOr(rng, "end")
    // ast-grep 行号 0-based → 1-based
    let sl = Json.intAt(start, "line", 0) + 1
    let el = Json.intAt(end, "line", 0) + 1
    out.add(AstNode(file, sl, el, rule, text))
}

/// 函数节点的签名是否成其为签名：参数表之前（没有参数表 = 块体 `{` 之前）不得出现
/// `{` `}` `;` `#`（字符串与注释里的不算）。Python 的体是缩进块、头里没有这些字符，原样放行。
///
/// 【为什么】tree-sitter 的错误恢复会把「缺分号的宏 + 后面的声明 + 函数」揉成一个
/// function_definition：实测 SecretStore.cpp 的 `DCORE_USE_NAMESPACE` 被报成一个 884 字节的
/// 函数（包着 namespace 头、四个常量与 schema() 本身），还和自己包住的 schema() 互报「重复体」。
/// 这种节点的「签名」里混着别的语句，一律不是函数。
func plausibleSignature(text: String): Bool {
    var limit = paramListClose(text)
    if (limit < 0) { limit = codeIndexOf(text, 0, 123) }
    if (limit < 0) { return true }     // 表达式体 / 无体声明
    let b = text.toArray()
    var i: Int64 = 0
    var state: Int64 = 0     // 0 代码；否则是当前字符串的引号字节
    while (i < limit) {
        let c = b[i]
        if (state == 0) {
            if (c == 34 || c == 39) { state = Int64(c) }
            else if (c == 47 && i + 1 < Int64(b.size) && b[i + 1] == 47) {
                while (i < limit && b[i] != 10) { i += 1 }
                continue
            } else if (c == 47 && i + 1 < Int64(b.size) && b[i + 1] == 42) {
                i += 2
                while (i + 1 < limit && !(b[i] == 42 && b[i + 1] == 47)) { i += 1 }
                i += 2
                continue
            } else if (c == 123 || c == 125 || c == 59 || c == 35) {
                return false
            }
        } else {
            if (c == 92) { i += 2; continue }
            if (Int64(c) == state) { state = 0 }
        }
        i += 1
    }
    return true
}
