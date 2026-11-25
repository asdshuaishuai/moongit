// graph/resolve.cj — 调用点的工程级解析：scanSource 采到的 CallSite → ResolvedSite。
//
// 【为什么必须在扫完全部文件之后】一个名字是不是「全工程唯一」、有没有同文件的
// 定义、是不是某个类型的成员，都要看完整张符号表——逐文件解析做不到。
// 这一步**没有第二份词法扫描**：输入只有 FileEntry.symbols 与 scanSource 的 refs。
//
// 【解析规则】（tier 是给 agent 的确信度分层，不是装饰）
//   direct    限定命中：`Type.name(` / `Type::name(` 的 `Type.name` 是一个已知限定名；
//             以及三种「词法上等同限定」的形态——`self.name(` / `this.name(`、
//             以及（类型体内、语言允许省略 `this` 的那些语言）裸 `name(` 恰好是
//             外层类型自己的成员。它们都**先于**裸名解析，命中即不再猜。
//   resolved  裸名唯一：同文件恰一个同名定义；否则全工程（同语言优先）恰一个；
//             否则同模块恰一个。
//   guessed   裸名歧义：同文件多个，或（同语言的）候选跨文件且同模块也不唯一——
//             **全部连边**，如实说「不确定是哪一个」。
//   未解析    全工程没有该名字的定义且不是内建：dst 为空，照常入库（sites.dst = 0）。
//   丢弃      内建名/宏样名且全工程无同名定义：不是这条索引能回答的问题，不入库。
//
// 【同语言才解析】多语言工程里同名符号很常见（探针工程的 AppModel 同时有 C++ 头、
// Kotlin 类、Swift 扩展）。裸名只在**与调用点同语言**的定义之间解析——Kotlin 的
// `AppModel(` 不会连到 C++ 的类上；同语言一个候选都没有就记为**未解析**，不退到
// 别的语言。探针工程实测：退到别的语言会让 Kotlin 的 AppModel.kt「调用」一个 C++
// 文件和两个 Swift 文件——那是三个各自独立的平台实现，彼此不可能直接调用。
// 唯一放行的是同一运行时的语言族：Kotlin ↔ Java（JVM 互调是源码级直接调用）。
//
// 【如实说的边界】这是词法级解析：没有类型信息，实例接收者 `obj.load(` 不知道 obj
// 的类型，只能按裸名走。所以 guessed 边是真实的不确定，不是可以后期消掉的噪声。
package moongit.graph

import std.collection.*
import moongit.util.*

/// 一个有效定义的位置：(文件下标, 符号下标)。
struct DefRef {
    let file: Int64
    let sym: Int64
    init(file: Int64, sym: Int64) {
        this.file = file
        this.sym = sym
    }
}

/// 类型体内的裸调用可以解析到自身成员的语言（省略了 `this`）。
/// Python / Go / Rust / TS 不在此列：它们的类体成员**不**在裸名查找链上
/// （Python 要 self.，Go 要接收者，TS 要 this.）。
func buildImplicitMemberLangs(): HashSet<String> {
    let s = HashSet<String>()
    for (l in ["swift", "kotlin", "java", "cangjie", "c"]) { s.add(l) }
    return s
}

let IMPLICIT_MEMBER_LANGS: HashSet<String> = buildImplicitMemberLangs()

/// 语言族：同一运行时、源码级可以直接互调的语言归一族（Kotlin ↔ Java）。
/// 调用点的解析只认同族的定义。
func langFamily(lang: String): String {
    if (lang == "kotlin" || lang == "java") { return "jvm" }
    return lang
}

/// 宏样名：全大写 + 数字/下划线（`Q_ASSERT` / `DCHECK` / `MPI_INIT`）。
/// 这类 `NAME(` 是预处理宏或日志宏，不是可解析的函数调用；只在**全工程无同名定义**
/// 时丢弃（工程真定义了同名函数就照常解析）。
func macroLikeName(name: String): Bool {
    if (name.size < 2) { return false }
    var upper: Int64 = 0
    var under: Int64 = 0
    for (b in name.toArray()) {
        if (b >= 65 && b <= 90) {
            upper += 1
        } else if (b == 95) {
            under += 1
        } else if (!(b >= 48 && b <= 57)) {
            return false
        }
    }
    return upper > 0 && under > 0
}

/// 各语言**标准库**的自由函数 / 字面量构造。全工程没有同名定义时，这些调用按
/// 「已知的外部内建」丢弃，不计入未解析——未解析是想回答「有没有拼错的名字、
/// 幻觉 API、缺失的依赖」，`QStringLiteral(…)` 回答不了这个问题。
///
/// 【只在没有任何同名项目符号时才丢弃】判定落在解析阶段而不是扫描阶段（见
/// ResolveIndex.resolve 的第一步）：项目真定义了 `strip` / `error` / `swap`
/// 这样的名字，调用点照常解析到它，一个都不会丢。
///
/// 【只收标准库，不收框架】Compose / SwiftUI / Qt 的类与方法（Text、Row、padding、
/// isEmpty、addWidget…）**不在列**：这些名字项目自己完全可能定义，而且它们在
/// 探针工程里正是未解析的大头——那是「调用了外部框架」的如实记录，不是噪音。
/// 唯一的例外是 Qt 的四个字面量宏（QStringLiteral 等）：它们是字符串字面量的
/// 构造形态，Q 前缀 + 全大写的词干，项目不会自定义。
func buildLangBuiltins(): HashMap<String, HashSet<String>> {
    let tables = HashMap<String, Array<String>>()
    tables["c"] = ["QStringLiteral", "QLatin1String", "QByteArrayLiteral", "QLatin1Char",
        "swap", "to_string", "getline", "fprintf", "sprintf", "snprintf", "vsnprintf",
        "calloc", "realloc", "strcmp", "strncmp", "strcpy", "strncpy", "strcat", "strncat",
        "strstr", "strchr", "strrchr", "atoi", "atol", "atoll", "strtol", "strtoll", "strtod",
        "abort", "fabs", "floor", "ceil", "sqrt", "pow", "fmod"]
    tables["kotlin"] = ["listOf", "mutableListOf", "mapOf", "mutableMapOf", "setOf",
        "mutableSetOf", "arrayOf", "arrayOfNulls", "intArrayOf", "longArrayOf", "doubleArrayOf",
        "floatArrayOf", "booleanArrayOf", "stringArrayOf", "shortArrayOf", "byteArrayOf",
        "charArrayOf", "arrayListOf", "hashMapOf", "hashSetOf", "linkedMapOf", "linkedSetOf",
        "sortedMapOf", "sortedSetOf", "buildList", "buildMap", "buildSet", "buildString",
        "sequenceOf", "withTimeout", "repeat", "lazy", "enumValues", "enumValueOf", "TODO",
        "error", "check", "require", "println", "print", "stackTraceToString"]
    tables["swift"] = ["print", "debugPrint", "dump", "precondition", "preconditionFailure",
        "assertionFailure", "fatalError", "repeatElement", "stride", "withExtendedLifetime"]
    tables["python"] = ["strip", "lstrip", "rstrip", "startswith", "endswith", "splitlines",
        "read_text", "write_text", "read_bytes", "write_bytes", "setdefault", "popitem",
        "add_argument", "parse_args", "check_output", "check_call", "check_returncode",
        "splitext", "dirname", "basename", "isabs", "joinpath", "is_file", "is_dir", "iterdir",
        "lower", "upper", "title", "capitalize", "casefold", "encode", "decode", "zfill",
        "rjust", "ljust", "center", "partition", "rpartition", "rsplit", "removeprefix",
        "removesuffix", "isalnum", "isalpha", "isdigit", "isnumeric", "isidentifier",
        "isspace", "islower", "isupper", "istitle", "format_map", "maketrans", "translate"]
    let m = HashMap<String, HashSet<String>>()
    for ((lang, words) in tables) {
        let s = HashSet<String>()
        for (w in words) { s.add(w) }
        m[lang] = s
    }
    return m
}

let LANG_BUILTINS: HashMap<String, HashSet<String>> = buildLangBuiltins()

func isLangBuiltin(lang: String, name: String): Bool {
    match (LANG_BUILTINS.get(lang)) {
        case Some(s) => return s.contains(name)
        case None => return false
    }
}

/// 解析索引：全工程符号表的两个视图。
class ResolveIndex {
    let files: ArrayList<FileEntry>
    let ids: ArrayList<ArrayList<String>>
    let modules: ArrayList<String>
    let byName: HashMap<String, ArrayList<DefRef>>
    let byQual: HashMap<String, ArrayList<DefRef>>
    let implicitLangs: HashSet<String>

    init(files: ArrayList<FileEntry>) {
        this.files = files
        this.ids = ArrayList<ArrayList<String>>()
        this.modules = ArrayList<String>()
        this.byName = HashMap<String, ArrayList<DefRef>>()
        this.byQual = HashMap<String, ArrayList<DefRef>>()
        this.implicitLangs = IMPLICIT_MEMBER_LANGS
        // ① 稳定 id 与模块
        for (f in files) {
            let row = ArrayList<String>()
            for (s in f.symbols) { row.add(s.id(f.relPath)) }
            ids.add(row)
            modules.add(moduleOfPath(f.relPath))
        }
        // ② 只有声明、没有体的符号：同语言另有同 qual 的定义 ⇒ 它是该定义的「声明处」，
        //    不作为独立解析目标（调用点连到定义，不连到原型）。
        let hasDef = HashSet<String>()
        for (f in files) {
            for (s in f.symbols) {
                if (!s.declOnly) { hasDef.add(f.lang + "\u{1f}" + s.qual) }
            }
        }
        // ③ 两个视图（文件按 relPath 排定、符号按出现顺序 ⇒ 候选序确定）
        for (fi in 0..files.size) {
            let f = files[fi]
            for (si in 0..f.symbols.size) {
                let s = f.symbols[si]
                if (s.declOnly && hasDef.contains(f.lang + "\u{1f}" + s.qual)) { continue }
                let ref = DefRef(fi, si)
                match (byName.get(s.name)) {
                    case Some(list) => list.add(ref)
                    case None =>
                        let list = ArrayList<DefRef>()
                        list.add(ref)
                        byName[s.name] = list
                }
                match (byQual.get(s.qual)) {
                    case Some(list) => list.add(ref)
                    case None =>
                        let list = ArrayList<DefRef>()
                        list.add(ref)
                        byQual[s.qual] = list
                }
            }
        }
    }

    func idOf(ref: DefRef): String {
        return ids[ref.file][ref.sym]
    }

    func fileOf(ref: DefRef): String {
        return files[ref.file].relPath
    }

    /// 候选里与调用点**同语言族**的（Kotlin 与 Java 同族）。一个都没有 = 空表。
    func sameLang(cands: ArrayList<DefRef>, fi: Int64): ArrayList<DefRef> {
        let fam = langFamily(files[fi].lang)
        let out = ArrayList<DefRef>()
        for (c in cands) {
            if (langFamily(files[c.file].lang) == fam) { out.add(c) }
        }
        return out
    }

    /// 解析一处调用点。返回 (目标, tier) 列表；空列表 = 未解析或丢弃（见第二个返回值）。
    func resolve(fi: Int64, site: CallSite): (ArrayList<(DefRef, String)>, Bool) {
        let out = ArrayList<(DefRef, String)>()
        let name = site.name
        var cands = ArrayList<DefRef>()
        match (byName.get(name)) {
            case Some(list) => cands = list
            case None => ()
        }
        if (cands.size == 0) {
            // 全工程没有这个名字：内建 / 宏样 ⇒ 丢弃；否则照常记为未解析。
            // 走到这里意味着项目里没有任何同名符号——所以「按内建丢弃」不可能吞掉
            // 一个真实的项目符号。
            let drop = isBuiltinName(name) || macroLikeName(name) || isLangBuiltin(files[fi].lang, name)
            return (out, drop)
        }
        let lang = files[fi].lang
        var callerOwner = ""
        if (site.caller >= 0 && site.caller < Int64(files[fi].symbols.size)) {
            callerOwner = files[fi].symbols[site.caller].owner
        }
        // ── 限定解析（direct）──
        var q = ""
        if (site.receiver == 2) {
            q = site.receiverText + "." + name
        } else if (site.receiver == 1 && (site.receiverText == "self" || site.receiverText == "this")) {
            if (!callerOwner.isEmpty()) { q = callerOwner + "." + name }
        } else if (site.receiver == 0 && !callerOwner.isEmpty() && implicitLangs.contains(lang)) {
            q = callerOwner + "." + name
        }
        if (!q.isEmpty()) {
            match (byQual.get(q)) {
                case Some(list) =>
                    // 限定命中**只在同语言里认**：`AppModel.start(` 出自 Kotlin 就不去连
                    // Swift/C++ 里的同名限定符——类型限定是比裸名强得多的证据，拿它跨语言
                    // 连边是把最确定的一档用来犯错。同语言没有就走裸名解析。
                    for (c in sameLang(list, fi)) { out.add((c, "direct")) }
                    if (out.size > 0) { return (out, false) }
                case None => ()
            }
        }
        // ── 裸名解析 ──
        // 显式接收者（不是 self / this）的调用不连回所在函数自身：`m_autoTimer->stop()` 写在
        // `AppModel::stop` 里，接收者的类型未知，裸名的唯一候选恰好是所在函数 ⇒ 连回去是一条假自环
        // （探针工程 51 条自环里 49 条是这种，真递归只有 2 条）。真递归不经过这里：
        // `this->stop()` / `self.stop()` 上面已走限定解析，裸调 `stop()` 的接收者为空。
        // 代价：委托给同类另一个实例的调用（`other.copy()` 写在 `copy()` 里）会被记成未解析——
        // 词法上分不出它和前者，宁可少连、不假连。
        if (site.receiver != 0 && site.caller >= 0
            && !(site.receiver == 1 && (site.receiverText == "self" || site.receiverText == "this"))) {
            let rest = ArrayList<DefRef>()
            for (c in cands) {
                if (!(c.file == fi && c.sym == site.caller)) { rest.add(c) }
            }
            cands = rest
            if (cands.size == 0) { return (out, false) }
        }
        let sameFile = ArrayList<DefRef>()
        for (c in cands) {
            if (c.file == fi) { sameFile.add(c) }
        }
        if (sameFile.size == 1) {
            out.add((sameFile[0], "resolved"))
            return (out, false)
        }
        if (sameFile.size > 1) {
            for (c in sameFile) { out.add((c, "guessed")) }
            return (out, false)
        }
        let langCands = sameLang(cands, fi)
        if (langCands.size == 0) {
            // 同语言一个候选都没有：未解析（不跨语言连边，见文件头）
            return (out, false)
        }
        if (langCands.size == 1) {
            out.add((langCands[0], "resolved"))
            return (out, false)
        }
        let mod = modules[fi]
        let modCands = ArrayList<DefRef>()
        for (c in langCands) {
            if (modules[c.file] == mod) { modCands.add(c) }
        }
        if (modCands.size == 1) {
            out.add((modCands[0], "resolved"))
            return (out, false)
        }
        for (c in langCands) { out.add((c, "guessed")) }
        return (out, false)
    }
}

/// 解析全部调用点。refsOf[relPath] = 该文件的 SourceFacts.refs。
/// 输出按全序排定（file ↑ → line ↑ → col ↑ → name ↑ → dst ↑），出口字节序确定。
public func resolveCallSites(files: ArrayList<FileEntry>,
                             refsOf: HashMap<String, ArrayList<CallSite>>): ArrayList<ResolvedSite> {
    let ix = ResolveIndex(files)
    let out = ArrayList<ResolvedSite>()
    for (fi in 0..files.size) {
        let f = files[fi]
        var refs = ArrayList<CallSite>()
        match (refsOf.get(f.relPath)) {
            case Some(list) => refs = list
            case None => ()
        }
        for (site in refs) {
            let (targets, drop) = ix.resolve(fi, site)
            if (drop) { continue }
            var callerId = ""
            if (site.caller >= 0 && site.caller < Int64(f.symbols.size)) {
                callerId = ix.ids[fi][site.caller]
            }
            if (targets.size == 0) {
                out.add(ResolvedSite(f.relPath, site.line, site.col, site.receiver,
                    site.receiverText, site.name, callerId, "", ""))
                continue
            }
            for ((ref, tier) in targets) {
                out.add(ResolvedSite(f.relPath, site.line, site.col, site.receiver,
                    site.receiverText, site.name, callerId, ix.idOf(ref), tier,
                    dstFile: ix.fileOf(ref)))
            }
        }
    }
    insertionSortBy(out, { a, b =>
        if (a.file != b.file) { return a.file < b.file }
        if (a.line != b.line) { return a.line < b.line }
        if (a.col != b.col) { return a.col < b.col }
        if (a.name != b.name) { return a.name < b.name }
        return a.dst < b.dst
    })
    return out
}

/// tier 的确定度（越小越确定）；聚合同一条边上的多个调用点时取最确定的那个。
func tierRank(tier: String): Int64 {
    if (tier == "direct") { return 0 }
    if (tier == "resolved") { return 1 }
    if (tier == "guessed") { return 2 }
    return 3
}

/// 函数级调用边（caller → callee 聚合）。weight = 调用点个数。
public struct CallEdge {
    public let from: String
    public let to: String
    public let tier: String
    public let weight: Int64

    public init(from: String, to: String, tier: String, weight: Int64) {
        this.from = from
        this.to = to
        this.tier = tier
        this.weight = weight
    }
}

/// 把解析后的调用点聚合成边。keep(file) = 该文件是否在当前数据域里（depth 截断）；
/// 两端都在域内的调用点才成边——否则边会指向清单里不存在的端点。
/// 排序 (from ↑ → to ↑)，出口确定。
public func callEdgesFrom(sites: ArrayList<ResolvedSite>, keep: (String) -> Bool): ArrayList<CallEdge> {
    let weight = HashMap<String, Int64>()
    let tierOf = HashMap<String, String>()
    for (s in sites) {
        if (s.caller.isEmpty() || s.dst.isEmpty()) { continue }
        if (!keep(s.file) || !keep(s.dstFile)) { continue }
        let key = s.caller + "=>" + s.dst
        match (weight.get(key)) {
            case Some(w) => weight[key] = w + 1
            case None => weight[key] = 1
        }
        match (tierOf.get(key)) {
            case Some(t) =>
                if (tierRank(s.tier) < tierRank(t)) { tierOf[key] = s.tier }
            case None => tierOf[key] = s.tier
        }
    }
    let keys = ArrayList<String>()
    for ((k, _) in weight) { keys.add(k) }
    insertionSortBy(keys, { a, b => a < b })
    let out = ArrayList<CallEdge>()
    for (k in keys) {
        var tier = ""
        match (tierOf.get(k)) {
            case Some(t) => tier = t
            case None => ()
        }
        let segs = k.split("=>")
        if (segs.size == 2) {
            out.add(CallEdge(segs[0], segs[1], tier, weight.get(k).getOrThrow()))
        }
    }
    return out
}
