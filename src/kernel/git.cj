// git 封装：所有 git 访问都经此处，返回结构化数据。
package moongit.kernel

import std.collection.*
import std.fs.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

/// 记录分隔符（与 util/exec 的 git 调用配合）
/// 字段分隔符。**必须**是 NUL：git 只禁止提交信息含 NUL，对 0x1f/0x1e 毫无限制，
/// 用它们当分隔符等于把解析权交给用户（实测见 logCommits 的注释）。
let NUL = "\u{0}"
/// 旧分隔符，仅保留给尚未迁移的调用点。新代码不要用。
let UNIT = "\u{1f}"
let REC = "\u{1e}"

public class BranchInfo {
    public let name: String
    public let head: String
    public let date: String
    public let subject: String
    public let upstream: String
    public let ahead: Int64
    public let behind: Int64
    public let upstreamGone: Bool

    public init(name: String, head: String, date: String, subject: String, upstream: String, ahead: Int64, behind: Int64, upstreamGone: Bool) {
        this.name = name
        this.head = head
        this.date = date
        this.subject = subject
        this.upstream = upstream
        this.ahead = ahead
        this.behind = behind
        this.upstreamGone = upstreamGone
    }
}

public class CommitInfo {
    public let sha: String
    public let short: String
    public let author: String
    public let email: String
    public let date: String
    public let subject: String
    public let body: String

    public init(sha: String, short: String, author: String, email: String, date: String, subject: String, body: String) {
        this.sha = sha
        this.short = short
        this.author = author
        this.email = email
        this.date = date
        this.subject = subject
        this.body = body
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "sha", Json.of(this.sha))
        Json.set(o, "short", Json.of(this.short))
        Json.set(o, "author", Json.of(this.author))
        Json.set(o, "date", Json.of(this.date))
        Json.set(o, "subject", Json.of(this.subject))
        if (!this.body.isEmpty()) {
            Json.set(o, "body", Json.of(this.body))
        }
        return o
    }
}

public class FileStat {
    public let path: String
    public let status: String
    public let additions: Int64
    public let deletions: Int64

    public init(path: String, status: String, additions: Int64, deletions: Int64) {
        this.path = path
        this.status = status
        this.additions = additions
        this.deletions = deletions
    }
}

public class DiffStats {
    public let files: Int64
    public let insertions: Int64
    public let deletions: Int64
    public let fileList: ArrayList<FileStat>

    public init(files: Int64, insertions: Int64, deletions: Int64, fileList: ArrayList<FileStat>) {
        this.files = files
        this.insertions = insertions
        this.deletions = deletions
        this.fileList = fileList
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "files", Json.of(this.files))
        Json.set(o, "insertions", Json.of(this.insertions))
        Json.set(o, "deletions", Json.of(this.deletions))
        return o
    }
}

/// 计数聚合器：O(n)，并保留首次出现顺序。
///
/// 为什么不能直接用无序 map 了事：这几个函数的并列名次全靠「谁先出现」定 ——
/// fileHeatmap / langStats 按计数降序做插入排序，而插入排序是稳定的，
/// 所以计数相同时保留首次出现顺序。换成无序 HashMap 会让同一份数据
/// 每次渲染出不同的 README，对一个「记录工程现状」的工具来说不可接受。
///
/// 为什么值得专门写：原来的实现是在两个平行 ArrayList 上线性扫 key，
/// 复杂度 O(输入量 × key 数)：
///   fileHeatmap     key 数 = 改动过的不同文件数（实测 12 万 → deep 挂死 >200s）
///   buildStructure  key 数 = 不同目录前缀数
///   langStats       key 数 = 语言数（十几种）
///   commitActivity  key 数 = 月份数
///   commitTypeStats key 数 = 提交类型数（8 种）
/// 后三个 key 集合小，扫描本身不致命，但同一种写法留着就是下一次踩坑的种子。
public class Counter {
    private let counts = HashMap<String, Int64>()
    private let order = ArrayList<String>()

    public init() {}

    /// 计数 +1；首次出现时记录顺序。
    public func add(key: String): Unit {
        match (counts.get(key)) {
            case Some(v) => counts[key] = v + 1
            case None =>
                counts[key] = 1
                order.add(key)
        }
    }

    public func countOf(key: String): Int64 {
        match (counts.get(key)) {
            case Some(v) => return v
            case None => return 0
        }
    }

    /// 按首次出现顺序返回全部 key。
    public func keys(): ArrayList<String> {
        return order
    }

    public func size(): Int64 {
        return order.size
    }
}

/// 工作区状态。
public class DirtyState {
    public let clean: Bool
    public let staged: Int64
    public let modified: Int64
    public let untracked: Int64
    public let conflicts: Int64
    public let total: Int64
    public let files: ArrayList<String>
    // 读取本身是否成功。false 表示这些数字全是占位 0，不是「工作区确实为空」。
    // 没有这两个字段时，git 读失败会被压成 clean=true / 全 0，
    // deep 就会把「0 个跟踪文件、暂无新变化」当真实事实写进 README 托管区并 exit 0 谎报成功。
    public let ok: Bool
    public let err: String

    public init(clean: Bool, staged: Int64, modified: Int64, untracked: Int64, conflicts: Int64, total: Int64, files: ArrayList<String>) {
        this(clean, staged, modified, untracked, conflicts, total, files, true, "")
    }

    public init(
        clean: Bool, staged: Int64, modified: Int64, untracked: Int64, conflicts: Int64, total: Int64,
        files: ArrayList<String>, ok: Bool, err: String,
    ) {
        this.clean = clean
        this.staged = staged
        this.modified = modified
        this.untracked = untracked
        this.conflicts = conflicts
        this.total = total
        this.files = files
        this.ok = ok
        this.err = err
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "clean", Json.of(this.clean))
        Json.set(o, "ok", Json.of(this.ok))
        if (!this.ok) {
            Json.set(o, "err", Json.of(this.err))
        }
        Json.set(o, "staged", Json.of(this.staged))
        Json.set(o, "modified", Json.of(this.modified))
        Json.set(o, "untracked", Json.of(this.untracked))
        Json.set(o, "conflicts", Json.of(this.conflicts))
        Json.set(o, "total", Json.of(this.total))
        let arr = ArrayList<JsonValue>()
        var i: Int64 = 0
        for (f in this.files) {
            if (i >= 30) {
                break
            }
            arr.add(Json.of(f))
            i += 1
        }
        Json.set(o, "files", JArr(arr))
        return o
    }
}

// ------------------------------ 基础查询 ------------------------------

public func isGitRepo(dir: String): Bool {
    let r = gitTry(dir, ["rev-parse", "--git-dir"])
    return r.ok()
}

public func repoRoot(dir: String): Option<String> {
    let r = gitTry(dir, ["rev-parse", "--show-toplevel"])
    if (r.ok() && !r.stdout.isBlank()) {
        return Some(r.stdout.trimAscii())
    }
    return None
}

public func revParse(dir: String, ref: String): Option<String> {
    let r = gitTry(dir, ["rev-parse", "--verify", "${ref}^{commit}"])
    if (r.ok()) {
        return Some(r.stdout.trimAscii())
    }
    return None
}

public func currentBranch(dir: String): String {
    let r = gitTry(dir, ["symbolic-ref", "--short", "-q", "HEAD"])
    if (r.ok() && !r.stdout.isBlank()) {
        return r.stdout.trimAscii()
    }
    return "HEAD"
}

public func defaultBranch(dir: String): String {
    let remoteHead = gitTry(dir, ["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"])
    if (remoteHead.ok() && !remoteHead.stdout.isBlank()) {
        let name = remoteHead.stdout.trimAscii()
        if (name.startsWith("origin/")) {
            return name[7..]
        }
        return name
    }
    let branches = ArrayList<String>()
    let r = gitTry(dir, ["branch", "--format=%(refname:short)"])
    if (r.ok()) {
        for (line in r.stdout.split("\n")) {
            let t = line.trimAscii()
            if (!t.isEmpty()) {
                branches.add(t)
            }
        }
    }
    for (cand in ["main", "master", "develop", "dev"]) {
        for (b in branches) {
            if (b == cand) {
                return cand
            }
        }
    }
    if (!branches.isEmpty()) {
        return branches[0]
    }
    // 空仓库：用 HEAD 指向的分支名（init 后即存在），否则如实回报空
    let sym = gitTry(dir, ["symbolic-ref", "--short", "-q", "HEAD"])
    if (sym.ok() && !sym.stdout.isBlank()) {
        return sym.stdout.trimAscii()
    }
    return ""
}

/// 分支列表（for-each-ref 用 %1f 作字段分隔）
public func listBranches(dir: String): ArrayList<BranchInfo> {
    let out = ArrayList<BranchInfo>()
    // ⚠️ 分隔符必须是 NUL，不能用 0x1f。
    // %(contents:subject) 是用户可控的提交标题，git 不会拦 0x1f：
    // 实测标题里塞 0x1f 会让本行被切成 7 段，字段整体错位
    // （parts.size < 6 的分支直接 continue，那一行分支就整个消失了）。
    // 分支名本身是安全的（check-ref-format 禁止 ref 名含控制字符），
    // 但同一行里的 subject 不是，所以整行统一用 NUL。
    // 注意：for-each-ref 的 %x00 不展开，必须写 %00（%x1f 同样不展开，只能写 %1f）。
    let fmt = "%(refname:short)%00%(objectname)%00%(committerdate:iso-strict)%00%(contents:subject)%00%(upstream:short)%00%(upstream:track)"
    let r = gitTry(dir, ["for-each-ref", "--format=${fmt}", "refs/heads"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    // for-each-ref 的**记录分隔符是换行**、**字段分隔符是 NUL** ——
    // 与 `git stash list -z`（两者都是 NUL，见 listStashes）正好相反，
    // 别照抄那边。按字段切完还要用 parts.size < 6 兜住标题里的换行。
    for (rec in r.stdout.split("\n")) {
        let line = rec.trimAscii()
        if (line.isEmpty()) {
            continue
        }
        let parts = line.split(NUL)
        if (parts.size < 6 || parts[0].isEmpty()) {
            continue
        }
        let name = parts[0]
        let head = parts[1]
        let date = parts[2]
        let subject = parts[3]
        let upstream = parts[4]
        let track = parts[5]
        var ahead: Int64 = 0
        var behind: Int64 = 0
        var gone = false
        if (!track.isEmpty()) {
            ahead = extractCount(track, "ahead ")
            behind = extractCount(track, "behind ")
            gone = track.contains("gone")
        }
        out.add(BranchInfo(name, head, date, subject, upstream, ahead, behind, gone))
    }
    return out
}

func extractCount(s: String, prefix: String): Int64 {
    let idx = s.indexOf(prefix)
    match (idx) {
        case Some(i) =>
            let rest = s[i + prefix.size..]
            let sb = StringBuilder()
            for (r in rest.runes()) {
                let c = r.toString()
                if (c >= "0" && c <= "9") {
                    sb.append(c)
                } else {
                    break
                }
            }
            let numStr = sb.toString()
            if (numStr.isEmpty()) {
                return 0
            }
            try {
                return Int64.parse(numStr)
            } catch (e: Exception) {
                return 0
            }
        case None => return 0
    }
}

/// 把 git 失败压成一行可读原因（给用户看的，不是给日志看的）。
private func gitErrorText(r: ExecResult): String {
    if (r.timedOut) {
        return "git 子进程超时（120s）"
    }
    let e = r.stderr.trimAscii()
    if (!e.isEmpty()) {
        for (line in e.split("\n")) {
            let t = line.trimAscii()
            if (!t.isEmpty()) {
                return t
            }
        }
    }
    return "git 退出码 ${r.exitCode}"
}

///
/// ⚠️ git 读失败绝不能压成 clean=true / 全 0。
/// 旧实现是 `if (!r.ok()) { return DirtyState(true, 0, 0, 0, 0, 0, ...) }` ——
/// 索引损坏（.git/index 被截断）、.git/config 语法错误、对象库损坏、非仓库目录，
/// 全都走这一条路，向上报「工作区干净、0 处改动」。
/// 后果是 deep 把这批清零事实写进 README 托管区（覆盖掉真实的「N 个跟踪文件」）
/// 并 exit 0 打印「✓ 深度更新完成」；假记录还会持久化进 progress.json 且不自愈。
/// 现在如实标记 ok=false + err，由 collectFacts 决定怎么处理。
public func statusSummary(dir: String): DirtyState {
    let r = gitTry(dir, ["status", "--porcelain"])
    if (!r.ok()) {
        // clean 保持 false：「读不到」不等于「干净」。下游任何把 clean 当作
        // 「可以放心跳过」的地方，此时都会多问一次，而不是默默放行。
        return DirtyState(false, 0, 0, 0, 0, 0, ArrayList<String>(), false, gitErrorText(r))
    }
    var staged: Int64 = 0
    var modified: Int64 = 0
    var untracked: Int64 = 0
    var conflicts: Int64 = 0
    var total: Int64 = 0
    let files = ArrayList<String>()
    for (line in r.stdout.split("\n")) {
        if (line.isEmpty()) {
            continue
        }
        total += 1
        let xy = if (line.size >= 2) { line[..2] } else { line }
        let file = if (line.size > 3) { line[3..].trimAscii() } else { "" }
        if (!file.isEmpty()) {
            files.add(file)
        }
        if (xy == "??") {
            untracked += 1
        } else if (xy == "DD" || xy == "AU" || xy == "UD" || xy == "UA" || xy == "DU" || xy == "AA" || xy == "UU") {
            conflicts += 1
        } else {
            if (xy.size >= 1 && xy[0..1] != " " && xy[0..1] != "?") {
                staged += 1
            }
            if (xy.size >= 2 && xy[1..2] != " " && xy[1..2] != "?") {
                modified += 1
            }
        }
    }
    return DirtyState(total == 0, staged, modified, untracked, conflicts, total, files)
}

/// 提交日志。
///
/// ⚠️ 字段与记录都必须用 NUL（\0）分隔，不能用 \x1f / \x1e。
/// 分隔符的选取标准只有一个：**用户能不能把它写进字段值里**。
/// git 只禁止提交信息含 NUL（`fatal: a NUL byte in commit log message not allowed`），
/// 但对 \x1f / \x1e 毫无限制 —— 实测 `git log` 会把它们原样透传。
/// 旧格式 `%H%x1f...%b%x1e` 的实测后果：
///   subject 含 \x1f → 标题在该处被截断，剩下的被当成 body
///   subject 含 \x1e → 整条记录被劈成两半，后半截变成一条**身份凭空捏造的幽灵提交**
///     （3 条真实提交被引擎记成「更新×2、微调×1」，真实类型应全是 other）
/// 这些字段会流进 README 托管区、进度 journal 和喂给 AI 的上下文，污染是全链路的。
///
/// `-z` 下每条提交固定产出 7 个 NUL 结尾的字段（实测 3 条提交 = 21 个 NUL），
/// 记录之间不额外加分隔符，所以按 7 个一组切就是无歧义的。
private const LOG_FIELDS: Int64 = 7

public func logCommits(dir: String, limit: Int64, ref: String, skip: Int64): ArrayList<CommitInfo> {
    let out = ArrayList<CommitInfo>()
    let fmt = "%H%x00%h%x00%an%x00%ae%x00%aI%x00%s%x00%b"
    let args = ArrayList<String>()
    args.add("log")
    args.add("-z")
    args.add("--format=${fmt}")
    args.add("-n")
    args.add("${limit}")
    if (skip > 0) {
        args.add("--skip=${skip}")
    }
    args.add(ref)
    let r = gitTry(dir, args.toArray())
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    let parts = r.stdout.split("\u{0}")
    var i: Int64 = 0
    while (i + LOG_FIELDS <= parts.size) {
        let sha = parts[i]
        if (!sha.isEmpty()) {
            // body 保留原始换行：它本来就是多行的，截断成单行会丢信息。
            // 上限 800 是为了不让超长 commit message 撑爆 README。
            out.add(CommitInfo(
                sha, parts[i + 1], parts[i + 2], parts[i + 3], parts[i + 4],
                parts[i + 5].trimAscii(), safeSlice(parts[i + 6].trimAscii(), 800),
            ))
        }
        i += LOG_FIELDS
    }
    return out
}

/// from..to 的提交（from 不含，to 含）
public func logRange(dir: String, from: String, to: String, limit: Int64): ArrayList<CommitInfo> {
    if (from.isEmpty()) {
        return logCommits(dir, limit, to, 0)
    }
    return logCommits(dir, limit, "${from}..${to}", 0)
}

public func commitCount(dir: String, range: String): Int64 {
    let r = gitTry(dir, ["rev-list", "--count", range])
    if (!r.ok()) {
        return 0
    }
    try {
        return Int64.parse(r.stdout.trimAscii())
    } catch (e: Exception) {
        return 0
    }
}

/// maybeAncestor 是否为 descendant 的祖先
public func isAncestor(dir: String, maybeAncestor: String, descendant: String): Bool {
    let r = gitTry(dir, ["merge-base", "--is-ancestor", maybeAncestor, descendant])
    return r.ok()
}

/// base...branch 的 (behind, ahead)
public func aheadBehind(dir: String, base: String, branch: String): (Int64, Int64) {
    let r = gitTry(dir, ["rev-list", "--left-right", "--count", "${base}...${branch}"])
    if (!r.ok()) {
        return (0, 0)
    }
    let parts = r.stdout.trimAscii().split("\t")
    if (parts.size < 2) {
        let sp = r.stdout.trimAscii().split(" ")
        if (sp.size >= 2) {
            return (parseIntOr(sp[0], 0), parseIntOr(sp[1], 0))
        }
        return (0, 0)
    }
    return (parseIntOr(parts[0], 0), parseIntOr(parts[1], 0))
}

func parseIntOr(s: String, fallback: Int64): Int64 {
    try {
        return Int64.parse(s.trimAscii())
    } catch (e: Exception) {
        return fallback
    }
}

/// diff 统计（-M 归一化改名）
///
/// ⚠️ 必须用 -z 解析。实测两种不用 -z 就必然出错的情况：
///  1. 改名：`git diff --numstat -M` 输出 `1\t0\tsrc/{old/name.txt => new/renamed.txt}`，
///     那个 `{old => new}` 被当成完整路径。于是 statusMap 查不到 → 状态回落成 "M"（明明是改名），
///     areasOf 还会把 `{old => new}` 当成一个顶层目录名写进分支摘要。
///     `-z` 下改名的记录是 `adds\tdels\t\0<old>\0<new>\0`，两个路径分字段给出，无歧义。
///  2. 文件名里带 TAB：git 把它引用成 `"weird\tname.txt"`（字面反斜杠 t），
///     按 TAB 切分就切不准。`-z` 下路径是原样未引用的，`weird<TAB>name.txt` 完整保留。
public func diffStats(dir: String, from: String, to: String, maxFiles: Int64): DiffStats {
    if (from.isEmpty() || to.isEmpty() || from == to) {
        return DiffStats(0, 0, 0, ArrayList<FileStat>())
    }
    let numstat = gitTry(dir, ["diff", "--numstat", "-M", "-z", from, to])
    if (!numstat.ok()) {
        return DiffStats(0, 0, 0, ArrayList<FileStat>())
    }
    let nameStatus = gitTry(dir, ["diff", "--name-status", "-M", "-z", from, to])
    let statusMap = HashMap<String, String>()
    if (nameStatus.ok()) {
        let toks = nameStatus.stdout.split("\u{0}")
        var i: Int64 = 0
        while (i < toks.size) {
            let status = toks[i]
            if (status.isEmpty()) {
                i += 1
                continue
            }
            let kind = status[..1]
            if (kind == "R" || kind == "C") {
                // 记录后跟 old / new 两个路径字段，以新路径为 key
                if (i + 2 < toks.size) {
                    statusMap[toks[i + 2]] = kind
                }
                i += 3
            } else {
                if (i + 1 < toks.size) {
                    statusMap[toks[i + 1]] = kind
                }
                i += 2
            }
        }
    }
    var files: Int64 = 0
    var insertions: Int64 = 0
    var deletions: Int64 = 0
    let list = ArrayList<FileStat>()
    let toks = numstat.stdout.split("\u{0}")
    var i: Int64 = 0
    while (i < toks.size) {
        let rec = toks[i]
        if (rec.isEmpty()) {
            i += 1
            continue
        }
        // 记录头是 `adds\tdels\t`，后面可能直接跟路径，也可能（改名）为空、
        // 真正的 old/new 路径在紧随其后的两个 NUL 字段里。
        let t1 = rec.indexOf("\t")
        if (t1.isNone()) {
            i += 1
            continue
        }
        let p1 = t1.getOrThrow()
        if (p1 + 1 >= rec.size) {
            i += 1
            continue
        }
        let rest = rec[p1 + 1..]
        let t2 = rest.indexOf("\t")
        if (t2.isNone()) {
            i += 1
            continue
        }
        let p2 = t2.getOrThrow()
        let addStr = rec[..p1]
        let delStr = rest[..p2]
        var filePath = rest[p2 + 1..]
        var status = ""
        if (filePath.isEmpty()) {
            // 改名/复制：路径在后续两个字段里，取新路径
            if (i + 2 >= toks.size) {
                i += 1
                continue
            }
            filePath = toks[i + 2]
            status = "R"
            i += 3
        } else {
            // 路径里可能带 TAB：这里取的是第二个 TAB 之后的全部原文，未做任何切分
            i += 1
        }
        if (filePath.isEmpty()) {
            continue
        }
        let adds = if (addStr == "-") { 0 } else { parseIntOr(addStr, 0) }
        let dels = if (delStr == "-") { 0 } else { parseIntOr(delStr, 0) }
        files += 1
        insertions += adds
        deletions += dels
        if (list.size < maxFiles) {
            let st = if (!status.isEmpty()) {
                status
            } else {
                match (statusMap.get(filePath)) {
                    case Some(v) => v
                    case None => "M"
                }
            }
            list.add(FileStat(filePath, st, adds, dels))
        }
    }
    return DiffStats(files, insertions, deletions, list)
}

/// 跟踪文件清单：真实总数 + 受上限约束的样本名。
///
/// total 与 names 是两件事。以前只返回 names，调用方拿 names.size 当总数，
/// 于是 25000 个文件的仓库报「20000 个跟踪文件」—— 那是采集上限，不是事实，
/// README 托管区里就这么写着，读者无从分辨。langStats / buildStructure 确实
/// 只需要一份样本，但「工程规模」这一行需要真数。
public class FileListing {
    public let names: ArrayList<String>
    public let total: Int64
    public let truncated: Bool
    /// 采集失败原因；空串表示成功。**恒发**（缺陷 #187）。
    ///
    /// ⚠️ 原来失败时返回 `FileListing([], 0, false)` —— 把「读不出来」
    /// 编码成了「这个仓库零个跟踪文件」，而且 `truncated: false` 反而
    /// **声称没截断**。调用方拿它去汇报「工程规模 / 语言分布」时，
    /// 失败与真的空仓库完全同形，读者无从分辨。
    public let error: String

    public init(names: ArrayList<String>, total: Int64, truncated: Bool) {
        this.names = names
        this.total = total
        this.truncated = truncated
        this.error = ""
    }

    public init(names: ArrayList<String>, total: Int64, truncated: Bool, error: String) {
        this.names = names
        this.total = total
        this.truncated = truncated
        this.error = error
    }
}

public func lsFiles(dir: String, maxFiles: Int64): ArrayList<String> {
    return listFiles(dir, maxFiles).names
}

public func listFiles(dir: String, maxFiles: Int64): FileListing {
    let out = ArrayList<String>()
    let r = gitTry(dir, ["ls-files", "-z"])
    if (!r.ok()) {
        // 失败 ≠ 空仓库。必须把原因带出去（#187）：
        //   · 真的 0 个文件 → 仓库确实是空的
        //   · 采集失败     → ls-files 挂了（index 损坏 / 120s 超时 / 仓库不可达）
        // 两者在下游（语言分布、结构树、「工程规模 N 个跟踪文件」）完全同形，
        // 混作一谈就等于把「核验不了」说成「没有」。
        let reason = if (r.timedOut) {
            "git ls-files 超时（120s）"
        } else {
            oneLineClamped(if (r.stderr.trimAscii().isEmpty()) { "git ls-files 失败" } else {
                "git ls-files 失败：${r.stderr.trimAscii()}"
            }, 120)
        }
        return FileListing(out, 0, false, reason)
    }
    // 一次遍历同时数总数和取样本：总数必须数完，不能在 maxFiles 处提前 break。
    var total: Int64 = 0
    for (f in r.stdout.split("\u{0}")) {
        if (f.isEmpty()) {
            continue
        }
        if (out.size < maxFiles) {
            out.add(f)
        }
        total += 1
    }
    return FileListing(out, total, total > Int64(out.size))
}

public func tags(dir: String, limit: Int64): ArrayList<(String, String)> {
    let out = ArrayList<(String, String)>()
    // 同样改用 NUL 分隔（见 listBranches 的注释：0x1f 会被字段内容里的同字节击穿）
    let r = gitTry(dir, ["for-each-ref", "--sort=-creatordate", "--count=${limit}", "--format=%(refname:short)%00%(creatordate:iso-strict)", "refs/tags"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    // 记录按换行切、字段按 NUL 切（同上：for-each-ref 的两个分隔符不是一回事）
    for (rec in r.stdout.split("\n")) {
        let line = rec.trimAscii()
        if (line.isEmpty()) {
            continue
        }
        let parts = line.split(NUL)
        if (parts.size >= 2 && !parts[0].isEmpty()) {
            out.add((parts[0], parts[1]))
        }
    }
    return out
}

/// 项目起点：最早的根提交（无父提交）的作者日期。
///
/// ⚠️ 必须按绝对时间取最小值，不能对 ISO 串做字典序排序。
/// ISO-8601 带时区偏移时，字符串序 ≠ 时间序：
///   `2026-01-01T10:00:00+14:00` 实际比 `2026-01-01T01:00:00+00:00` 早 5 小时，
///   但字符串比较里前者更大。跨时区协作的仓库（作者在 +14、别人在 +00）
///   字典序取第一个会选错根提交，README 里「始于」跟着错一天。
public func firstCommitDate(dir: String): Option<String> {
    let r = gitTry(dir, ["log", "--max-parents=0", "--format=%aI", "HEAD"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return None
    }
    var bestIso = ""
    var bestMs: Int64 = 0
    for (line in r.stdout.split("\n")) {
        let iso = line.trimAscii()
        if (iso.isEmpty()) {
            continue
        }
        match (parseIsoMillis(iso)) {
            case Some(ms) =>
                if (bestIso.isEmpty() || ms < bestMs) {
                    bestIso = iso
                    bestMs = ms
                }
            case None => ()
        }
    }
    if (bestIso.isEmpty()) {
        return None
    }
    return Some(bestIso)
}

/// 真正的项目起点提交（root commit，无父提交）
public func genesisCommits(dir: String, limit: Int64): ArrayList<CommitInfo> {
    let out = ArrayList<CommitInfo>()
    let r = gitTry(dir, ["log", "--max-parents=0", "--format=%H", "HEAD"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    let shas = ArrayList<String>()
    for (line in r.stdout.split("\n")) {
        let t = line.trimAscii()
        if (!t.isEmpty() && shas.size < limit) {
            shas.add(t)
        }
    }
    for (sha in shas) {
        match (lastCommit(dir, sha)) {
            case Some(c) => out.add(c)
            case None => ()
        }
    }
    return out
}

public func lastCommit(dir: String, ref: String): Option<CommitInfo> {
    let list = logCommits(dir, 1, ref, 0)
    if (list.isEmpty()) {
        return None
    }
    return Some(list[0])
}

public func authorStats(dir: String, limit: Int64): ArrayList<(Int64, String)> {
    let out = ArrayList<(Int64, String)>()
    let r = gitTry(dir, ["shortlog", "-sn", "--no-merges", "HEAD"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    for (line in r.stdout.split("\n")) {
        let t = line.trimAscii()
        if (t.isEmpty()) {
            continue
        }
        let tabIdx = t.indexOf("\t")
        match (tabIdx) {
            case Some(i) =>
                let countStr = t[..i].trimAscii()
                let name = t[i + 1..].trimAscii()
                let count = parseIntOr(countStr, 0)
                out.add((count, name))
                if (out.size >= limit) {
                    break
                }
            case None => ()
        }
    }
    return out
}

public func stashCount(dir: String): Int64 {
    let r = gitTry(dir, ["stash", "list"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return 0
    }
    var n: Int64 = 0
    for (line in r.stdout.split("\n")) {
        if (!line.isBlank()) {
            n += 1
        }
    }
    return n
}

public func remoteUrl(dir: String): String {
    let r = gitTry(dir, ["config", "--get", "remote.origin.url"])
    if (r.ok()) {
        return r.stdout.trimAscii()
    }
    return ""
}

/// 月度提交活跃度（最近 limit 个提交聚合）
public func commitActivity(dir: String, limit: Int64): ArrayList<(String, Int64)> {
    let r = gitTry(dir, ["log", "-n", "${limit}", "--format=%aI"])
    let out = ArrayList<(String, Int64)>()
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    let counter = Counter()
    for (line in r.stdout.split("\n")) {
        let t = line.trimAscii()
        if (t.size < 7) {
            continue
        }
        counter.add(t[..7])
    }
    let months = counter.keys()
    let counts = ArrayList<Int64>()
    for (m in months) {
        counts.add(counter.countOf(m))
    }
    // 按月排序
    let idx = ArrayList<Int64>()
    for (i in 0..months.size) {
        idx.add(i)
    }
    // 简单插入排序（数据量小）
    for (i in 1..idx.size) {
        let key = idx[i]
        var j = i - 1
        while (j >= 0 && months[idx[j]] > months[key]) {
            idx[j + 1] = idx[j]
            j -= 1
        }
        idx[j + 1] = key
    }
    for (i in idx) {
        out.add((months[i], counts[i]))
    }
    return out
}

// ------------------------------ 提交类型统计（Conventional Commits） ------------------------------

let COMMIT_TYPE_ORDER: Array<String> = ["feat", "fix", "perf", "refactor", "docs", "test", "build", "ci", "style", "chore", "revert", "other"]

/// 从提交 subject 提取类型：feat(x): … → feat；无前缀 → other
public func commitTypeOf(subject: String): String {
    let s = subject.trimAscii().toAsciiLower()
    var head = s
    // 去掉可选的 scope：feat(api): → feat:
    let paren = s.indexOf("(")
    if (paren.isSome()) {
        let p = paren.getOrThrow()
        // scope 必须紧跟在 type 后面且 type 本身无空格
        if (p > 0 && !s[..p].contains(" ") && !s[..p].contains(":")) {
            let close = s.indexOf(")")
            if (close.isSome() && close.getOrThrow() > p) {
                head = s[..p] + s[close.getOrThrow() + 1..]
            }
        }
    }
    let colon = head.indexOf(":")
    if (colon.isSome()) {
        head = head[..colon.getOrThrow()].trimAscii()
    }
    for (t in COMMIT_TYPE_ORDER) {
        if (t == "other") {
            continue
        }
        if (head == t) {
            return t
        }
        // 常见别名归并
        if (t == "feat" && (head == "feature" || head == "add")) {
            return "feat"
        }
        if (t == "fix" && (head == "bugfix" || head == "hotfix" || head == "bug")) {
            return "fix"
        }
        if (t == "perf" && head == "performance") {
            return "perf"
        }
        if (t == "test" && (head == "tests" || head == "tst")) {
            return "test"
        }
    }
    return "other"
}

/// 统计 ref 最近 maxCommits 条提交的类型分布（按固定类别顺序输出，零值类别省略）
public func commitTypeStats(root: String, ref: String, maxCommits: Int64): ArrayList<(String, Int64)> {
    let out = ArrayList<(String, Int64)>()
    let r = gitTry(root, ["log", "--pretty=format:%s", "-n", "${maxCommits}", ref])
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    let counter = Counter()
    for (line in r.stdout.split("\n")) {
        if (line.isBlank()) {
            continue
        }
        counter.add(commitTypeOf(line))
    }
    for (t in COMMIT_TYPE_ORDER) {
        let n = counter.countOf(t)
        if (n > 0) {
            out.add((t, n))
        }
    }
    // COMMIT_TYPE_ORDER 之外的类型（旧分类法遗留）也必须报出来，不能静默丢弃
    for (k in counter.keys()) {
        var known = false
        for (t in COMMIT_TYPE_ORDER) {
            if (t == k) {
                known = true
                break
            }
        }
        if (!known) {
            out.add((k, counter.countOf(k)))
        }
    }
    return out
}

// ------------------------------ 测试 ------------------------------

@Test
func testExtractCount(): Unit {
    @Assert(extractCount("[ahead 3]", "ahead ") == 3)
    @Assert(extractCount("[behind 12, ahead 5]", "behind ") == 12)
    @Assert(extractCount("[gone]", "ahead ") == 0)
}

@Test
func testDefaultBranchOnEmptyRepo(): Unit {
    let base = "/tmp/deepgit-defbr-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    // 空仓库（无提交）应返回 HEAD 指向的分支名，而不是字面 "HEAD"
    @Assert(defaultBranch(base) == "main")
    removePathIfExists(base)
}

@Test
func testGenesisCommitsFindsRoot(): Unit {
    let base = "/tmp/deepgit-genesis-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "the very first"], false)
    writeFileAtomic(base + "/a.txt", "2")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "second"], false)
    let g = genesisCommits(base, 5)
    @Assert(g.size == 1)
    @Assert(g[0].subject == "the very first")
    removePathIfExists(base)
}

@Test
func testNonGitDirReturnsEmpty(): Unit {
    let tmp = "/tmp/deepgit-git-${nowMillis()}"
    ensureDir(tmp)
    @Assert(!isGitRepo(tmp))
    @Assert(listBranches(tmp).isEmpty())
    // 非仓库目录：git status 失败。这里必须报 ok=false，
    // 而旧实现会压成 clean=true —— 对着一个根本不是仓库的目录说「工作区干净」。
    let s = statusSummary(tmp)
    @Assert(!s.ok)
    @Assert(!s.clean)
    @Assert(!s.err.isEmpty())
    removePathIfExists(tmp)
}

/// 索引损坏时 git status 失败 —— 必须如实报失败，不能压成「工作区干净」。
///
/// 旧实现 `if (!r.ok()) { return DirtyState(true, 0, 0, 0, 0, 0, ...) }` 让
/// 下面这些场景全都被报成「干净、0 处改动」，deep 随后把清零事实写进 README 托管区
/// 并 exit 0 谎报成功。实测过这四种破坏方式，`git status --porcelain` 全部 rc=128。
@Test
func testStatusSummaryMarksGitFailureInsteadOfReportingClean(): Unit {
    let base = "/tmp/deepgit-dirtyfail-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)
    // 健康基线
    @Assert(statusSummary(base).ok)

    // 1) 索引文件损坏
    writeFileAtomic(base + "/.git/index", "GARBAGE-NOT-AN-INDEX")
    let d1 = statusSummary(base)
    @Assert(!d1.ok)
    @Assert(!d1.clean)  // 读不到 ≠ 干净
    @Assert(d1.total == 0)
    @Assert(!d1.err.isEmpty())

    // 2) config 语法错误
    removePathIfExists(base + "/.git/index")
    gitRun(base, ["reset", "-q"], false)
    writeFileAtomic(base + "/.git/config", "[core\n  bork = true\n")
    @Assert(!statusSummary(base).ok)
    removePathIfExists(base)
}

/// 断链符号链接不得掀翻整条命令。
///
/// FileInfo 对 `ln -s /nonexistent/x` 抛 "Failed to get last modification time"，
/// 旧代码没有 try/catch，异常穿透 collectFacts 让 update / track / deep 全部 exit 1。
/// track 又是 post-commit 钩子 —— 仓库里有一个断链，就意味着用户每次提交都报错。
@Test
func testUntrackedFilesSurvivesDanglingSymlink(): Unit {
    let base = "/tmp/deepgit-dangle-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/real.txt", "x")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)
    // 断链：目标不存在
    let ln = execCapture("ln", ["-s", "/nonexistent-target-xyz/deepgit", base + "/dangling.lnk"], None, 8000)
    @Assert(ln.ok())
    // 指向存在文件的软链是正常路径，必须照常拿到大小
    let lnOk = execCapture("ln", ["-s", base + "/real.txt", base + "/good.lnk"], None, 8000)
    @Assert(lnOk.ok())

    let uts = untrackedFiles(base, 50)
    // 断链不能抛异常，且仍要出现在未跟踪清单里（它确实是个未跟踪条目）
    var sawDangling = false
    var sawGood = false
    for (u in uts) {
        if (u.path == "dangling.lnk") {
            sawDangling = true
            // 实测：FileInfo 的 size 走 lstat（返回链接目标串的长度，正常），
            // lastModificationTime 走 stat —— 跟随到不存在的目标就抛异常。
            // 这正是必须 try/catch 的那个调用；取不到就留空，不能编一个数。
            @Assert(u.mtime.isEmpty())
        }
        if (u.path == "good.lnk") {
            sawGood = true
            @Assert(!u.mtime.isEmpty())  // 指向真实文件的软链照常取到时间
        }
    }
    @Assert(sawDangling)
    @Assert(sawGood)
    removePathIfExists(base)
}

@Test
func testSelfRepoIfAvailable(): Unit {
    // 在 moonGit 仓库自身运行时验证真实 git 读取
    let here = "/Volumes/data/dev/coding/deepcodeUI/deepGit"
    if (isGitRepo(here)) {
        let branch = currentBranch(here)
        @Assert(!branch.isEmpty())
        let s = statusSummary(here)
        @Assert(s.total >= 0)
    }
}

@Test
func testDirtyStateJson(): Unit {
    let d = DirtyState(false, 1, 2, 3, 0, 6, ArrayList<String>(["a", "b"]))
    let j = d.toJson()
    @Assert(Json.boolAt(j, "clean", true) == false)
    @Assert(Json.boolAt(j, "ok", false) == true)  // 手工构造的默认可信
    @Assert(Json.intAt(j, "untracked", 0) == 3)
    @Assert(Json.arrAt(j, "files").size == 2)

    // 失败态必须把原因带出去，否则调用方只看到一堆 0，无从判断该不该信
    let bad = DirtyState(false, 0, 0, 0, 0, 0, ArrayList<String>(), false, "index file smaller than expected")
    let jb = bad.toJson()
    @Assert(Json.boolAt(jb, "ok", true) == false)
    @Assert(Json.strAt(jb, "err", "").contains("index"))
}

@Test
func testDiffStatsJson(): Unit {
    let ds = DiffStats(3, 10, 5, ArrayList<FileStat>())
    let j = ds.toJson()
    @Assert(Json.intAt(j, "files", 0) == 3)
    @Assert(Json.intAt(j, "insertions", 0) == 10)
}

// =============================== Worktree 增强 ===============================

public class WorktreeInfo {
    public let path: String
    public let headShort: String
    public let branch: String
    public let isBare: Bool
    public let isCurrent: Bool

    public init(path: String, headShort: String, branch: String, isBare: Bool, isCurrent: Bool) {
        this.path = path
        this.headShort = headShort
        this.branch = branch
        this.isBare = isBare
        this.isCurrent = isCurrent
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "path", Json.of(this.path))
        Json.set(o, "headShort", Json.of(this.headShort))
        Json.set(o, "branch", Json.of(this.branch))
        Json.set(o, "isBare", Json.of(this.isBare))
        Json.set(o, "isCurrent", Json.of(this.isCurrent))
        return o
    }
}

/// 列出所有 worktree（含主工作区）
public func listWorktrees(root: String): ArrayList<WorktreeInfo> {
    let out = ArrayList<WorktreeInfo>()
    let r = gitTry(root, ["worktree", "list", "--porcelain"])
    if (!r.ok() || r.stdout.isEmpty()) {
        // 兜底：至少包含主工作区
        match (revParse(root, "HEAD")) {
            case Some(h) =>
                let b = currentBranch(root)
                out.add(WorktreeInfo(root, shortSha(h), if (b == "HEAD") { "(detached)" } else { b }, false, true))
            case None => ()
        }
        return out
    }
    // porcelain 格式：worktree <path> / HEAD <sha> / branch refs/heads/<b> | bare | detached
    // 每条记录以 "worktree " 开头，先收集再统一映射，避免闭包捕获 var
    let recs = ArrayList<(String, String, String, Bool, Bool)>()
    var curPath = ""
    var curHead = ""
    var curBranch = ""
    var curBare = false
    var curDetached = false
    var have = false
    for (line in r.stdout.split("\n")) {
        if (line.startsWith("worktree ")) {
            if (have) {
                recs.add((curPath, curHead, curBranch, curBare, curDetached))
            }
            have = true
            curPath = line[9..]
            curHead = ""
            curBranch = ""
            curBare = false
            curDetached = false
        } else if (line.isEmpty()) {
            continue
        } else if (line.startsWith("HEAD ")) {
            curHead = line[5..]
        } else if (line.startsWith("branch ")) {
            curBranch = line[7..]
        } else if (line == "bare") {
            curBare = true
        } else if (line == "detached") {
            curDetached = true
        }
    }
    if (have) {
        recs.add((curPath, curHead, curBranch, curBare, curDetached))
    }
    for (rec in recs) {
        var branch = rec[2]
        if (branch.startsWith("refs/heads/")) {
            branch = branch[11..]
        }
        if (rec[4] && branch.isEmpty()) {
            branch = "(detached)"
        }
        if (rec[3] && branch.isEmpty()) {
            branch = "(bare)"
        }
        out.add(WorktreeInfo(rec[0], shortSha(rec[1]), branch, rec[3], sameDir(rec[0], root)))
    }
    return out
}

/// 目录等价判断：macOS 上 /tmp 是 /private/tmp 的符号链接，git 输出真实路径
func sameDir(a: String, b: String): Bool {
    return samePath(a, b)
}

/// 合并建议：当前分支相对默认分支的 ahead/behind + 是否可以 fast-forward
public class MergePlan {
    public let kind: String  // "fast-forward" | "merge" | "rebase" | "no-default" | "merged"
    public let ahead: Int64
    public let behind: Int64
    public let defaultBranch: String
    public let target: String
    public let description: String

    public init(kind: String, ahead: Int64, behind: Int64, defaultBranch: String, target: String, description: String) {
        this.kind = kind
        this.ahead = ahead
        this.behind = behind
        this.defaultBranch = defaultBranch
        this.target = target
        this.description = description
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "kind", Json.of(this.kind))
        Json.set(o, "ahead", Json.of(this.ahead))
        Json.set(o, "behind", Json.of(this.behind))
        Json.set(o, "defaultBranch", Json.of(this.defaultBranch))
        Json.set(o, "target", Json.of(this.target))
        Json.set(o, "description", Json.of(this.description))
        return o
    }
}

/// 计算合并策略：ahead/behind 是否 fast-forward、是否已合并
public func planMerge(root: String, branch: String): MergePlan {
    let defBranch = defaultBranch(root)
    if (defBranch == branch) {
        return MergePlan("no-default", 0, 0, defBranch, branch, "当前分支即默认分支")
    }
    let ab = aheadBehind(root, defBranch, branch)  // (behind, ahead)
    let behind = ab[0]
    let ahead = ab[1]
    // ahead = branch 领先默认分支的提交数（独有提交）；behind = 落后数
    if (ahead == 0) {
        // 分支无独有提交 = 已完全包含于默认分支
        return MergePlan("merged", 0, behind, defBranch, branch, "${branch} 已合入 ${defBranch}")
    }
    if (behind == 0) {
        // 默认分支无新提交，可直接快进到 branch
        return MergePlan("fast-forward", ahead, 0, defBranch, branch, "${defBranch} 可直接 fast-forward 到 ${branch}（${ahead} 个新提交）")
    }
    return MergePlan("merge", ahead, behind, defBranch, branch, "需三方合并（领先 ${ahead} / 落后 ${behind}）")
}

/// 列出 stash（含简短预览）
public class StashInfo {
    public let index: String
    public let branch: String
    public let message: String
    public let date: String

    public init(index: String, branch: String, message: String, date: String) {
        this.index = index
        this.branch = branch
        this.message = message
        this.date = date
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "index", Json.of(this.index))
        Json.set(o, "branch", Json.of(this.branch))
        Json.set(o, "message", Json.of(this.message))
        Json.set(o, "date", Json.of(this.date))
        return o
    }
}

public func listStashes(root: String): ArrayList<StashInfo> {
    let out = ArrayList<StashInfo>()
    // %s 是 stash 的说明文字，用户可控，0x1f 会被原样透传 → 改用 -z + NUL
    let r = gitTry(root, ["stash", "list", "-z", "--pretty=format:%gd%x00%s%x00%as"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return out
    }
    // ⚠️ L11：**字段分隔符与条目分隔符都是 NUL**（`-z` 把条目终止符换成 NUL，
    // 而 --pretty 里的 %x00 也是 NUL）⇒ 输出是一条扁平的 NUL token 流，
    // 每条 stash 占 3 个 token：%gd / %s / %as。
    // 原实现先按 "\n" 切行（多条目时整条只有一行）、再按 NUL 切，
    // 于是**只有第一条被解析**（实测 od -c 证实）。既有测试只造 1 条 stash，
    // 结构上测不出这个错 —— 与 #188 的「夹具比现实更完整」同一族。
    let toks = r.stdout.split(NUL)
    var ti: Int64 = 0
    while (ti + 2 < Int64(toks.size)) {
        let idx = toks[ti]
        let subject = toks[ti + 1]
        let date = toks[ti + 2]
        ti += 3
        if (idx.isEmpty()) {
            continue
        }
        out.add(stashEntryOf(idx, subject, date))
    }
    return out
}

/// 一条 stash 的 (%gd, %s, %as) → StashInfo。抽成函数是因为解析循环里
/// 不能再套一个裸块（仓颉会把 `{` 当 lambda 开头）。
private func stashEntryOf(idx: String, subject: String, date: String): StashInfo {
    // subject 形如 "On main: xxx" / "WIP on main: sha xxx"，从中拆出分支
    var branchName = ""
    var msg = subject
    if (subject.startsWith("On ")) {
        let rest = subject[3..]
        let colon = rest.indexOf(": ")
        if (colon.isSome()) {
            let c = colon.getOrThrow()
            branchName = rest[..c]
            msg = rest[c + 2..]
        }
    } else if (subject.startsWith("WIP on ")) {
        let rest = subject[7..]
        let colon = rest.indexOf(": ")
        if (colon.isSome()) {
            let c = colon.getOrThrow()
            branchName = rest[..c]
            msg = rest[c + 2..]
        }
    }
    return StashInfo(idx, branchName, msg, date)
}

/// 非跟踪文件独立列表（含 mtime / 大小，便于浅更新增量跟踪）
public class UntrackedFile {
    public let path: String
    public let sizeBytes: Int64
    public let mtime: String

    public init(path: String, sizeBytes: Int64, mtime: String) {
        this.path = path
        this.sizeBytes = sizeBytes
        this.mtime = mtime
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "path", Json.of(this.path))
        Json.set(o, "size", Json.of(this.sizeBytes))
        Json.set(o, "mtime", Json.of(this.mtime))
        return o
    }
}

public func untrackedFiles(root: String, maxFiles: Int64): ArrayList<UntrackedFile> {
    return listUntrackedFiles(root, maxFiles).names
}

/// 未跟踪文件：与 listFiles 同理，names 是样本，total 才是真实总数。
/// 旧实现在 maxFiles 处 break，返回值直接被当成「未跟踪文件数」——
/// 实测 317 个未跟踪文件时，context 输出「未跟踪 50」。
public class UntrackedListing {
    public let names: ArrayList<UntrackedFile>
    public let total: Int64
    public let truncated: Bool

    public init(names: ArrayList<UntrackedFile>, total: Int64, truncated: Bool) {
        this.names = names
        this.total = total
        this.truncated = truncated
    }
}

public func listUntrackedFiles(root: String, maxFiles: Int64): UntrackedListing {
    let out = ArrayList<UntrackedFile>()
    let r = gitTry(root, ["ls-files", "--others", "--exclude-standard", "-z"])
    if (!r.ok() || r.stdout.isEmpty()) {
        return UntrackedListing(out, 0, false)
    }
    var total: Int64 = 0
    for (path in r.stdout.split("\u{0}")) {
        if (path.isEmpty()) {
            continue
        }
        total += 1
        if (out.size >= maxFiles) {
            continue
        }
        let absPath = "${root}/${path}"
        // FileInfo 的 lastModificationTime 走 stat（跟随链接），对断链符号链接
        // （ln -s /nonexistent/x）直接抛异常；size 走 lstat 所以不抛。
        // 这里原来没有 try/catch，异常一路穿透 collectFacts，掀翻整个 update /
        // track / deep —— 而 track 是 post-commit 钩子，
        // 意味着「仓库里有一个断链，每次提交都报错」。
        // 未跟踪文件清单是事实增强项，某个文件取不到 stat 不该让整条命令失败。
        //
        // ⚠️ 顺序是承重的：size 必须在 mtime 之前赋值。反过来的话 mtime 先抛，
        // size 会连同默认值一起被丢掉，明明 lstat 拿得到却记成 0。
        var size: Int64 = 0
        var mtime = ""
        try {
            let info = FileInfo(Path(absPath))
            size = info.size
            mtime = info.lastModificationTime.toString()
        } catch (e: Exception) {
            ()  // 断链 / 权限不足 / 刚被删除：保留条目，时间留空
        }
        out.add(UntrackedFile(path, size, mtime))
    }
    return UntrackedListing(out, total, total > Int64(out.size))
}

/// 文件热力（按文件聚合计修改次数）：用于发现真正活跃的工作面
public func fileHeatmap(dir: String, ref: String, maxCommits: Int64, top: Int64): ArrayList<(String, Int64)> {
    let counter = Counter()
    let r = gitTry(dir, ["log", "--name-only", "--format=", "-n", "${maxCommits}", ref])
    if (!r.ok() || r.stdout.isEmpty()) {
        return ArrayList<(String, Int64)>()
    }
    for (path in r.stdout.split("\n")) {
        // 只跳过空行，不做 trimAscii。git log --name-only 会在每个 commit 前留一个空行，
        // 但路径两端可能有真实字符（" x.txt"、以空格结尾的文件名）——
        // trimAscii 会把两个不同的文件合并成一个，热力数据从此失真。
        if (path.isEmpty()) {
            continue
        }
        counter.add(path)
    }
    let names = counter.keys()
    let counts = ArrayList<Int64>()
    for (n in names) {
        counts.add(counter.countOf(n))
    }
    // 简单排序（稳定：并列时保留首次出现顺序）
    let out = ArrayList<(String, Int64)>()
    for (i in 0..names.size) {
        out.add((names[i], counts[i]))
    }
    // 计数降序
    var a: Int64 = 1
    while (a < out.size) {
        let key = out[a]
        var b = a - 1
        while (b >= 0 && out[b][1] < key[1]) {
            out[b + 1] = out[b]
            b -= 1
        }
        out[b + 1] = key
        a += 1
    }
    if (out.size > top) {
        let trimmed = ArrayList<(String, Int64)>()
        for (i in 0..top) {
            trimmed.add(out[i])
        }
        return trimmed
    }
    return out
}

// ---------------- 测试 ----------------

@Test
func testListWorktreesOnMainRepo(): Unit {
    let base = "/tmp/deepgit-wt-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/x.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "first"], false)
    let wts = listWorktrees(base)
    @Assert(wts.size >= 1)
    @Assert(wts[0].isCurrent)
    removePathIfExists(base)
}

@Test
func testListWorktreesWithWorktree(): Unit {
    let base = "/tmp/deepgit-wt2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/x.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)
    let wtPath = "/tmp/deepgit-wt2-wt-${nowMillis()}"
    let r = gitTry(base, ["worktree", "add", "-b", "feat/exp", wtPath])
    @Assert(r.ok())
    let wts = listWorktrees(base)
    var seenExp = false
    var seenMain = false
    for (w in wts) {
        if (w.branch == "feat/exp") {
            seenExp = true
        }
        if (w.branch == "main") {
            seenMain = true
        }
    }
    @Assert(seenExp && seenMain)
    // 清理
    gitRun(base, ["worktree", "remove", wtPath], false)
    removePathIfExists(base)
    removePathIfExists(wtPath)
}

@Test
func testPlanMergeStrategies(): Unit {
    let base = "/tmp/deepgit-mp-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/x.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "main1"], false)
    gitRun(base, ["checkout", "-q", "-b", "feat/x"], false)
    writeFileAtomic(base + "/x.txt", "2")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat"], false)
    let p = planMerge(base, "feat/x")
    @Assert(p.kind == "fast-forward")  // feat/x 领先 main 1 提交、main 无新提交
    // 再让 main 推进一提交，让 feat/x 落后
    gitRun(base, ["checkout", "-q", "main"], false)
    writeFileAtomic(base + "/x.txt", "3")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "main2"], false)
    let p2 = planMerge(base, "feat/x")
    @Assert(p2.behind == 1)
    @Assert(p2.kind == "merge")
    removePathIfExists(base)
}

@Test
func testListStashes(): Unit {
    let base = "/tmp/deepgit-st-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/x.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)
    writeFileAtomic(base + "/x.txt", "WIP change")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["stash", "push", "-m", "wip: testing"], false)
    let stashes = listStashes(base)
    @Assert(stashes.size == 1)
    @Assert(stashes[0].message.contains("wip"))
    removePathIfExists(base)
}

@Test
func testUntrackedFiles(): Unit {
    let base = "/tmp/deepgit-ut-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/tracked.txt", "1")
    writeFileAtomic(base + "/untracked.txt", "x")
    gitRun(base, ["add", "tracked.txt"], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)
    let uts = untrackedFiles(base, 50)
    @Assert(uts.size >= 1)
    var seen = false
    for (u in uts) {
        if (u.path == "untracked.txt") {
            seen = true
        }
    }
    @Assert(seen)
    removePathIfExists(base)
}

@Test
func testFileHeatmap(): Unit {
    let base = "/tmp/deepgit-hm-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/hot.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "1"], false)
    writeFileAtomic(base + "/hot.txt", "2")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "2"], false)
    writeFileAtomic(base + "/hot.txt", "3")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "3"], false)
    writeFileAtomic(base + "/cold.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "4"], false)
    let hm = fileHeatmap(base, "HEAD", 50, 10)
    @Assert(hm.size >= 2)
    @Assert(hm[0][0] == "hot.txt")  // 最热文件排第一
    removePathIfExists(base)
}

@Test
func testCommitTypeOf(): Unit {
    @Assert(commitTypeOf("feat: add x") == "feat")
    @Assert(commitTypeOf("feat(api): add x") == "feat")
    @Assert(commitTypeOf("FIX: broken thing") == "fix")
    @Assert(commitTypeOf("hotfix: urgent") == "fix")
    @Assert(commitTypeOf("refactor(core): cleanup") == "refactor")
    @Assert(commitTypeOf("docs: update readme") == "docs")
    @Assert(commitTypeOf("perf: speed up") == "perf")
    @Assert(commitTypeOf("chore: bump deps") == "chore")
    @Assert(commitTypeOf("tests: more coverage") == "test")
    @Assert(commitTypeOf("just a plain message") == "other")
    @Assert(commitTypeOf("feature: big thing") == "feat")
}

@Test
func testCommitTypeStats(): Unit {
    let base = "/tmp/deepgit-ct-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    let subjects = ["feat: a", "feat: b", "fix: c", "docs: d", "plain work"]
    for (s in subjects) {
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-q", "-m", "${s}"], false)
    }
    let stats = commitTypeStats(base, "HEAD", 20)
    // 顺序固定：feat 在前
    @Assert(stats[0][0] == "feat")
    @Assert(stats[0][1] == 2)
    var total = 0
    for ((t, c) in stats) {
        total += c
    }
    @Assert(total == 5)
    removePathIfExists(base)
}

@Test
func testToJsonValueClasses(): Unit {
    let wf = WorktreeInfo("/tmp/wt", "abc1234", "feat/x", false, true)
    let wj = wf.toJson()
    @Assert(Json.strAt(wj, "path", "") == "/tmp/wt")
    @Assert(Json.boolAt(wj, "isCurrent", false))

    let mp = MergePlan("fast-forward", 0, 3, "main", "feat/x", "可直接 fast-forward")
    let mj = mp.toJson()
    @Assert(Json.strAt(mj, "kind", "") == "fast-forward")
    @Assert(Json.intAt(mj, "behind", 0) == 3)

    let sf = StashInfo("stash@{0}", "main", "wip stuff", "2026-09-30")
    let sj = sf.toJson()
    @Assert(Json.strAt(sj, "message", "") == "wip stuff")

    let uf = UntrackedFile("a/b.txt", 1024, "2026-09-30")
    let uj = uf.toJson()
    @Assert(Json.intAt(uj, "size", 0) == 1024)
}

@Test
func testPlanMergeSameBranch(): Unit {
    let base = "/tmp/deepgit-pm-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    gitRun(base, ["commit", "--allow-empty", "-q", "-m", "init"], false)
    let p = planMerge(base, "main")
    @Assert(p.kind == "no-default")
    removePathIfExists(base)
}

@Test
func testListWorktreesAndStashesOnNonRepo(): Unit {
    let base = "/tmp/deepgit-nonrepo-${nowMillis()}"
    ensureDir(base)
    @Assert(listWorktrees(base).size == 0)
    @Assert(listStashes(base).size == 0)
    removePathIfExists(base)
}

@Test
func testCommitTypeStatsOnEmptyRepo(): Unit {
    let base = "/tmp/deepgit-empty-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    @Assert(commitTypeStats(base, "HEAD", 10).size == 0)
    removePathIfExists(base)
}

@Test
func testFileHeatmapTopLimit(): Unit {
    let base = "/tmp/deepgit-hm2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    for (i in 1..4) {
        writeFileAtomic(base + "/f${i}.txt", "1")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "c${i}"], false)
    }
    let hm = fileHeatmap(base, "HEAD", 50, 2)
    @Assert(hm.size <= 2)
    removePathIfExists(base)
}

@Test
func testCommitTypeOfScopeWithoutColon(): Unit {
    // "feat(scope)" 后无冒号 → 畸形 conventional commit，归为 other
    @Assert(commitTypeOf("feat(scope) missing colon") == "other")
    @Assert(commitTypeOf("  feat: padded  ") == "feat")
    @Assert(commitTypeOf("REVERT: rollback") == "revert")
    @Assert(commitTypeOf("build(deps): bump") == "build")
}

@Test
func testUntrackedFilesOnCleanRepo(): Unit {
    let base = "/tmp/deepgit-ut2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    // 空仓库：无未跟踪
    @Assert(untrackedFiles(base, 50).size == 0)
    gitRun(base, ["commit", "--allow-empty", "-q", "-m", "init"], false)
    @Assert(untrackedFiles(base, 50).size == 0)
    removePathIfExists(base)
}

@Test
func testWorktreePorcelainParsesMain(): Unit {
    let base = "/tmp/deepgit-wt3-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    gitRun(base, ["commit", "--allow-empty", "-q", "-m", "init"], false)
    let wts = listWorktrees(base)
    @Assert(wts.size == 1)
    @Assert(wts[0].isCurrent)   // /tmp 与 /private/tmp 的符号链接差异被 samePath 容忍
    @Assert(wts[0].branch == "main")
    @Assert(!wts[0].isBare)
    removePathIfExists(base)
}

// ------------------------------ 通用 git 操作（客户端驱动） ------------------------------

public class GitOpResult {
    public let op: String
    public let ok: Bool
    public let output: String

    public init(op: String, ok: Bool, output: String) {
        this.op = op
        this.ok = ok
        this.output = output
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "op", Json.of(this.op))
        Json.set(o, "ok", Json.of(this.ok))
        Json.set(o, "output", Json.of(this.output))
        return o
    }
}

func gitOpExec(root: String, op: String, args: Array<String>): GitOpResult {
    let r = gitTry(root, args)
    var out = r.stdout
    if (!r.stderr.isEmpty()) {
        let sep = if (out.isEmpty()) { "" } else { "\n" }
        out = out + sep + r.stderr
    }
    return GitOpResult(op, r.ok() && !r.timedOut, out.trimAscii())
}

/// 面板级 git 操作：pull / push / commit / stash / unstash / fetch。
/// 刻意不提供 reset/clean 等破坏性操作；commit 需要显式 message。
public func runGitOp(root: String, op: String, message: String): GitOpResult {
    let inside = gitTry(root, ["rev-parse", "--is-inside-work-tree"])
    if (!inside.ok()) {
        return GitOpResult(op, false, "不是 git 仓库：${root}")
    }
    match (op) {
        case "pull" => return gitOpExec(root, op, ["pull", "--ff-only"])
        case "fetch" => return gitOpExec(root, op, ["fetch", "--prune"])
        case "push" =>
            // 无 upstream 时自动补 -u origin <branch>
            let cur = currentBranch(root)
            let branches = listBranches(root)
            var upstream = ""
            for (b in branches) {
                if (b.name == cur) {
                    upstream = b.upstream
                }
            }
            if (upstream.isEmpty() && !cur.isEmpty() && cur != "HEAD") {
                // `--` 是承重的：refspec 位置上的名字若以 `-` 开头，git 会当成选项。
                // 实测 `git push -u origin --mirror` 会被解释成镜像推送 ——
                // 远端所有本地没有的分支会被删除，对用户仓库是不可逆的数据损失。
                // 加 `--` 后 git 把它当普通 refspec，匹配不到就报错退出，无任何副作用：
                //   error: src refspec --mirror does not match any
                // 可达性确实低（git check-ref-format 本就拒绝以 - 开头的分支名），
                // 但 `--` 零成本，堵掉整类「位置参数变选项」的注入面。
                return gitOpExec(root, op, ["push", "-u", "origin", "--", cur])
            }
            return gitOpExec(root, op, ["push"])
        case "commit" =>
            if (message.isBlank()) {
                return GitOpResult(op, false, "需要提交信息（--message）")
            }
            let add = gitTry(root, ["add", "-A"])
            if (!add.ok()) {
                return GitOpResult(op, false, ("add 失败\n" + add.stderr).trimAscii())
            }
            let r = gitTry(root, ["-c", "user.name=${gitUserName()}", "-c", "user.email=${gitUserEmail()}", "commit", "-m", message])
            var out = r.stdout
            if (!r.stderr.isEmpty()) {
                let sep = if (out.isEmpty()) { "" } else { "\n" }
                out = out + sep + r.stderr
            }
            return GitOpResult(op, r.ok() && !r.timedOut, out.trimAscii())
        case "stash" =>
            let m = if (message.isBlank()) { "moongit stash ${nowIso()}" } else { message }
            return gitOpExec(root, op, ["stash", "push", "-m", m])
        case "unstash" => return gitOpExec(root, op, ["stash", "pop"])
        case _ => return GitOpResult(op, false, "未知操作：${op}（支持 pull/push/commit/stash/unstash/fetch）")
    }
}

/// commit 时的身份兜底：优先全局配置，没有则用占位身份，避免 commit 直接失败
func gitUserName(): String {
    let r = gitTry(".", ["config", "--global", "user.name"])
    let v = r.stdout.trimAscii()
    return if (v.isEmpty()) { "deepgit" } else { v }
}

func gitUserEmail(): String {
    let r = gitTry(".", ["config", "--global", "user.email"])
    let v = r.stdout.trimAscii()
    return if (v.isEmpty()) { "deepgit@local" } else { v }
}

@Test
func testRunGitOpCommitAndStash(): Unit {
    let base = "/tmp/deepgit-op-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    gitRun(base, ["commit", "--allow-empty", "-q", "-m", "init"], false)
    // commit：无 message → 失败
    let bad = runGitOp(base, "commit", "")
    @Assert(!bad.ok)
    // commit：干净仓库 → 无可提交
    let nothing = runGitOp(base, "commit", "空提交")
    @Assert(!nothing.ok)
    // commit：有改动 → 成功且工作区变干净
    writeFileAtomic(base + "/a.txt", "1")
    let c = runGitOp(base, "commit", "feat: op commit")
    @Assert(c.ok)
    @Assert(c.output.contains("op commit"))
    // stash → unstash 往返
    writeFileAtomic(base + "/a.txt", "2")
    let s = runGitOp(base, "stash", "wip via op")
    @Assert(s.ok)
    @Assert(listStashes(base).size == 1)
    let u = runGitOp(base, "unstash", "")
    @Assert(u.ok)
    @Assert(listStashes(base).size == 0)
    removePathIfExists(base)
}

@Test
func testRunGitOpUnknownAndPull(): Unit {
    let base = "/tmp/deepgit-op2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    // 未知操作
    @Assert(!runGitOp(base, "rebase-hard", "").ok)
    // 无远端的 pull：失败但要有可读输出
    let p = runGitOp(base, "pull", "")
    @Assert(!p.ok)
    @Assert(!p.output.isEmpty())
    removePathIfExists(base)
}


/// git 的大输出必须完整解析 —— 跟踪文件数是写进 README 托管区的数字，不能是编的。
///
/// 实测 20001 个文件的仓库：修复前 git ls-files -z 只拿到 16899 条 / 278528 字节，
/// 引擎在 README 里写下「16834 个跟踪文件」（既非真实 20001，也非采集上限 20000）。
@Test
func testLsFilesIsNotTruncatedOnLargeRepo(): Unit {
    let base = "/tmp/deepgit-lsbig-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    for (d in 0..20) {
        let sub = "${base}/d${d}"
        ensureDir(sub)
        for (i in 0..500) {
            File.writeTo(Path("${sub}/f${i}.txt"), "x".toArray())
        }
    }
    gitRun(base, ["add", "."], false)
    // 10000 个文件，输出约 170KB —— 远超 64KB 管道缓冲
    @Assert(lsFiles(base, 20000).size == 10000)
    @Assert(collectFacts(base, "git", Config.defaults(), 5, false).trackedFiles == 10000)
    removePathIfExists(base)
}

/// fileHeatmap：计数相同必须保留「git 首次列出的顺序」。
///
/// 这是改成 Counter（HashMap + 首次出现顺序表）的核心风险点：
/// 无序 map 会让同一份数据每次渲染出不同的热力榜，README 跟着抖动。
/// 构造一个「字典序与出现序相反」的平局：最新提交先动 zz.txt，较早的提交先动 aa.txt，
/// 两个文件计数都是 2。若实现按字典序或按 map 迭代序输出，这里会红。
@Test
func testFileHeatmapTieKeepsFirstSeenOrder(): Unit {
    let base = "/tmp/deepgit-heat-tie-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    // commit 1：两个文件都加入
    writeFileAtomic(base + "/aa.txt", "1")
    writeFileAtomic(base + "/zz.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "c1"], false)
    // commit 2：先动 aa.txt
    writeFileAtomic(base + "/aa.txt", "2")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "c2"], false)
    // commit 3（最新）：先动 zz.txt
    writeFileAtomic(base + "/zz.txt", "2")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "c3"], false)

    let h = fileHeatmap(base, "HEAD", 200, 8)
    @Assert(h.size == 2)
    @Assert(h[0][1] == 2)
    @Assert(h[1][1] == 2)
    // git log 由新到旧：最新提交里出现的是 zz.txt，所以它应排在前面
    @Assert(h[0][0] == "zz.txt")
    @Assert(h[1][0] == "aa.txt")

    // 重复执行必须完全一致（无序 map 会在这里露馅）
    let h2 = fileHeatmap(base, "HEAD", 200, 8)
    @Assert(h2[0][0] == h[0][0])
    @Assert(h2[1][0] == h[1][0])
    removePathIfExists(base)
}

/// fileHeatmap 不得因 trimAscii 把两个不同的文件合并。
/// "x.txt" 与 " x.txt" 是两个文件，合并后热力数据直接失真。
@Test
func testFileHeatmapDoesNotMergeWhitespacePaths(): Unit {
    let base = "/tmp/deepgit-heat-ws-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/x.txt", "1")
    writeFileAtomic(base + "/ x.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "c1"], false)
    let h = fileHeatmap(base, "HEAD", 200, 8)
    @Assert(h.size == 2)  // 合并的话这里只有 1
    removePathIfExists(base)
}

/// 大仓库必须在有界时间内完成 —— 这是 O(n²) 的回归护栏，不是性能基准。
///
/// 旧实现对每个路径线性扫一遍已见文件名数组：2 万个不同文件 = 2×10^8 次
/// 字符串比较，实测 12 万文件的仓库 deep 要 125s（而 execCapture 的 git 超时是
/// 120s —— 再大一点 git log 直接被 kill，整条 deep 失败）。改成 Counter 后同规模 <1s。
/// 阈值给得很宽（30s），只为区分「分钟级」和「秒级」，不做精细计时。
@Test
func testFileHeatmapScalesToLargeRepo(): Unit {
    let base = "/tmp/deepgit-heat-scale-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    for (d in 0..30) {
        let sub = "${base}/d${d}"
        ensureDir(sub)
        for (i in 0..1000) {
            File.writeTo(Path("${sub}/f${i}.txt"), "x".toArray())
        }
    }
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "bulk"], false)
    let t0 = nowMillis()
    let h = fileHeatmap(base, "HEAD", 200, 8)
    let elapsed = nowMillis() - t0
    @Assert(h.size == 8)
    @Assert(h[0][1] == 1)   // 每个文件只在这个提交里出现过
    // 阈值是量出来的，不是拍的：
    //   修复后 3 万个不同文件 ≈ 20ms（余量 150 倍，慢机器/并发测试也不会误红）
    //   旧 O(n²) 同一输入 ≈ 6.8s（负控实测）→ 会红
    // 2 万文件那次负控只多花 3s、落在 30s 阈值内，护栏形同虚设，所以输入和阈值都收紧了。
    @Assert(elapsed < 3000)
    removePathIfExists(base)
}

/// commitTypeStats 必须报出 COMMIT_TYPE_ORDER 之外的类型。
/// 旧实现只遍历固定顺序表，表外的分类会被静默丢弃 —— 提交类型统计凭空少一块。
@Test
func testCommitTypeStatsIncludesUnknownTypes(): Unit {
    let base = "/tmp/deepgit-ctype-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: one"], false)
    writeFileAtomic(base + "/a.txt", "2")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "某种不认识的分类"], false)
    let s = commitTypeStats(base, "HEAD", 10)
    var total: Int64 = 0
    for ((_, n) in s) {
        total += n
    }
    @Assert(total == 2)  // 两条提交都必须在某个分类里，不许丢
    removePathIfExists(base)
}

/// commitTypes 的**条数**上界 = COMMIT_TYPE_ORDER 的长度。
///
/// 这不是内部实现细节，而是一条**跨进程契约**：macOS 客户端的提交构成卡片
/// 用 12 色的色板给每一类上色（`CommitTypeColor.capacity`），
/// 引擎一旦能发出第 13 类，客户端就会用同一种颜色画两类 ——
/// 分段条上两段糊在一起、图例里两行同色圆点，读者无从分辨。
/// 引擎侧钉住上界，客户端契约检查钉住「实测条数 ≤ 色板容量」，两端合起来
/// 才不会有人悄悄把色板用穿。
///
/// 之所以能成立：表外的旧分类法名称全部聚进 `other` 桶
/// （见 commitTypeStats 结尾那段），所以**未知类型再多也不加条数**。
@Test
func testCommitTypeCountIsBoundedByVocabulary(): Unit {
    let base = "/tmp/deepgit-ctbound-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    // 11 个已知类型 + 4 个表外旧分类法 = 15 条提交、15 种写法。
    // 预期结果：11 类 + other 桶 = COMMIT_TYPE_ORDER.size = 12。
    let known = ["feat", "fix", "perf", "refactor", "docs", "test", "build", "ci", "style", "chore", "revert"]
    for (t in known) {
        writeFileAtomic(base + "/${t}.txt", t)
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "${t}: n"], false)
    }
    for (t in ["wip", "temp", "misc", "zzz"]) {
        writeFileAtomic(base + "/${t}.txt", t)
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "${t}: n"], false)
    }
    let s = commitTypeStats(base, "HEAD", 50)
    // 上界：任何输入下都不许超过词表长度
    @Assert(s.size <= COMMIT_TYPE_ORDER.size)
    // 锚点：把词表能填满的形状真的造出来一次（否则上面那条没有判别力，
    // 一个恒真的断言和没有断言一样）。12 = 11 个已知 + other 桶。
    @Assert(known.size + 1 == COMMIT_TYPE_ORDER.size)
    @Assert(s.size == COMMIT_TYPE_ORDER.size)
    // 表外那 4 种必须聚进 other，而不是各自多占一个位置
    var otherN: Int64 = 0
    for ((t, n) in s) {
        if (t == "other") {
            otherN = n
        }
    }
    @Assert(otherN == 4)
    // 对照：条数不超过采样窗口时上界更紧 —— 5 条提交给不出 12 类。
    // 没有这条，上面那个 == 12 可能只是「窗口给够了」而不是「词表决定上界」。
    @Assert(commitTypeStats(base, "HEAD", 5).size <= 5)
    removePathIfExists(base)
}

/// Counter 自身：不重复计数、保留首次出现顺序。
@Test
func testCounterKeepsFirstSeenOrderAndCounts(): Unit {
    let c = Counter()
    c.add("b")
    c.add("a")
    c.add("b")
    c.add("c")
    c.add("a")
    let ks = c.keys()
    @Assert(c.size() == 3)
    @Assert(ks[0] == "b")
    @Assert(ks[1] == "a")
    @Assert(ks[2] == "c")
    @Assert(c.countOf("b") == 2)
    @Assert(c.countOf("a") == 2)
    @Assert(c.countOf("c") == 1)
    @Assert(c.countOf("nope") == 0)
}

/// 改名必须被解析成新路径 + R 状态，不能变成 `{old => new}`。
///
/// 旧实现按 TAB 切分非 -z 输出，改名行是
///   `1\t0\tsrc/{old/name.txt => new/renamed.txt}`
/// 于是 filePath 变成 "{old/name.txt => new/renamed.txt}"：
///   - statusMap 查不到 → 状态回落成 "M"（明明是改名）
///   - areasOf 把它当成一个顶层目录名写进分支摘要
@Test
func testDiffStatsParsesRenamesWithZFormat(): Unit {
    let base = "/tmp/deepgit-rename-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    ensureDir(base + "/src/old")
    writeFileAtomic(base + "/src/old/name.txt", "a\nb\nc\n")
    gitRun(base, ["add", "."], false)
    let c1 = commitHead(base, "init")
    ensureDir(base + "/src/new")
    gitRun(base, ["mv", "src/old/name.txt", "src/new/renamed.txt"], false)
    writeFileAtomic(base + "/src/new/renamed.txt", "a\nb\nc\nd\n")
    gitRun(base, ["add", "."], false)
    let c2 = commitHead(base, "rename")

    let ds = diffStats(base, c1, c2, 50)
    @Assert(ds.files == 1)
    // 路径必须是新路径，不能出现 {old => new}
    @Assert(ds.fileList[0].path == "src/new/renamed.txt")
    @Assert(!ds.fileList[0].path.contains("=>"))
    @Assert(!ds.fileList[0].path.contains("{"))
    // 状态必须是 R
    @Assert(ds.fileList[0].status == "R")
    @Assert(ds.insertions == 1)
    removePathIfExists(base)
}

/// 文件名里带 TAB 必须完整保留。
///
/// 非 -z 输出里 git 把它引用成 `"weird\tname.txt"`（字面反斜杠 + t），
/// 按 TAB 切分切不准；`-z` 下是原样未引用的。
@Test
func testDiffStatsKeepsTabInFilename(): Unit {
    let base = "/tmp/deepgit-tabname-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    let tabName = "weird\tname.txt"
    writeFileAtomic(base + "/" + tabName, "x\n")
    gitRun(base, ["add", "."], false)
    let c1 = commitHead(base, "init")
    writeFileAtomic(base + "/" + tabName, "x\ny\n")
    gitRun(base, ["add", "."], false)
    let c2 = commitHead(base, "tab")

    let ds = diffStats(base, c1, c2, 50)
    @Assert(ds.files == 1)
    @Assert(ds.fileList[0].path == tabName)  // 完整、未被切成两半、也不是带引号的
    @Assert(ds.insertions == 1)
    removePathIfExists(base)
}

/// 普通增删改不能因为换成 -z 解析而退化。
@Test
func testDiffStatsStillHandlesAddModifyDelete(): Unit {
    let base = "/tmp/deepgit-ds3-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/keep.txt", "1\n2\n")
    writeFileAtomic(base + "/gone.txt", "x\n")
    gitRun(base, ["add", "."], false)
    let c1 = commitHead(base, "init")
    writeFileAtomic(base + "/keep.txt", "1\n2\n3\n4\n")
    writeFileAtomic(base + "/new.txt", "n\n")
    gitRun(base, ["rm", "-q", "gone.txt"], false)
    gitRun(base, ["add", "."], false)   // new.txt 必须入暂存区，否则不算进本次 diff
    let c2 = commitHead(base, "change")

    let ds = diffStats(base, c1, c2, 50)
    @Assert(ds.files == 3)
    @Assert(ds.insertions == 3)   // keep +2、new +1
    @Assert(ds.deletions == 1)    // gone 整文件删除算 1 行
    var sawA = false
    var sawD = false
    for (f in ds.fileList) {
        if (f.path == "new.txt") { sawA = true; @Assert(f.status == "A") }
        if (f.path == "gone.txt") { sawD = true; @Assert(f.status == "D") }
    }
    @Assert(sawA)
    @Assert(sawD)
    removePathIfExists(base)
}

/// firstCommitDate 必须按绝对时间取最早，不能按 ISO 字符串序。
///
/// 构造两个根提交：作者时间 +14:00 的「晚 9 小时」和 +00:00 的「早 9 小时」。
/// 字符串序会选 `T12:00:00+14:00`（实际比 `T03:00:00+00:00` 晚 5 小时），
/// 于是「始于」报错。
@Test
func testFirstCommitDateUsesAbsoluteTimeNotLexicographic(): Unit {
    let base = "/tmp/deepgit-firstdate-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    // 根提交 A：2026-01-01T12:00:00+14:00 == 2026-01-01T03:00:00Z
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    let a = commitHeadAt(base, "root A", "2026-01-01T12:00:00+14:00")
    // 根提交 B：2026-01-01T03:00:00+00:00（绝对时间更早，但字符串更小）
    gitRun(base, ["checkout", "-q", "--orphan", "other"], false)
    gitRun(base, ["rm", "-rq", "--cached", "."], false)
    writeFileAtomic(base + "/b.txt", "1")
    gitRun(base, ["add", "."], false)
    let b = commitHeadAt(base, "root B", "2026-01-01T03:00:00+00:00")
    // 把两个根提交接起来：merge 之后 --max-parents=0 会同时看到 A 和 B
    gitRun(base, ["checkout", "-q", "main"], false)
    gitRun(base, ["merge", "-q", "--no-ff", "--allow-unrelated-histories", "-m", "merge", "other"], false)
    @Assert(a != b)

    let d = firstCommitDate(base)
    @Assert(d.isSome())
    // 换算成 UTC：12:00+14:00 == 12-31T22:00Z，比 01-01T03:00Z 早 5 小时 → 它才是起点。
    // 字典序会选 "…T03:00:00Z"（同一个日期前缀下 "03" < "12"），整整差一天。
    // 顺带：git 会把 +00:00 规范成 Z，所以两条分别是 …+14:00 和 …Z。
    @Assert(d.getOrThrow() == "2026-01-01T12:00:00+14:00")
    removePathIfExists(base)
}

/// 测试辅助：提交并返回 HEAD 的 sha（作者时间为 now）
private func commitHead(base: String, msg: String): String {
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", msg], false)
    return gitRun(base, ["rev-parse", "HEAD"], false).trimAscii()
}

/// 测试辅助：提交并返回 HEAD 的 sha，显式指定作者时间（ISO-8601）
private func commitHeadAt(base: String, msg: String, authorDate: String): String {
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--date=" + authorDate, "-m", msg], false)
    return gitRun(base, ["rev-parse", "HEAD"], false).trimAscii()
}

/// push 的 refspec 位置必须加 `--`，否则以 `-` 开头的分支名会被 git 当成选项。
///
/// 实测复现（HEAD 指向一个名为 `--mirror` 的分支，git symbolic-ref 可造）：
///   旧写法 `git push -u origin --mirror` → git 执行的是**镜像推送**，
///     输出里有 `- [deleted]         doomed`，远端分支被删掉且不可逆。
///   新写法 `git push -u origin -- --mirror` → git 把它当普通 refspec，
///     报 "src refspec --mirror does not match any"，远端一个分支都不动。
///
/// 这条测的是「远端分支必须还在」——保护的是数据，不是退出码。
/// 场景是可达的：git check-ref-format 拒绝用 branch 命令建这种分支，
/// 但 `git update-ref refs/heads/--mirror` + `git symbolic-ref HEAD` 可以，
/// 而 currentBranch 会原样返回它。
@Test
func testPushDoesNotLetBranchNameBecomeOption(): Unit {
    let root = "/tmp/deepgit-pushopt-${nowMillis()}"
    let remote = root + "-remote.git"
    ensureDir(root)
    // 远端先有 main + doomed
    gitRun(root, ["init", "--bare", remote], false)
    gitRun(root, ["init", "-b", "main"], false)
    writeFileAtomic(root + "/a.txt", "1")
    gitRun(root, ["add", "."], false)
    commitHead(root, "init")
    gitRun(root, ["remote", "add", "origin", remote], false)
    gitRun(root, ["push", "-q", "-u", "origin", "main"], false)
    gitRun(root, ["branch", "doomed"], false)
    gitRun(root, ["push", "-q", "origin", "doomed"], false)
    gitRun(root, ["branch", "-q", "-D", "doomed"], false)   // 只删本地，远端留着

    // 把 HEAD 指到一个名为 --mirror 的分支（它没有 upstream，走 push -u 分支）
    gitRun(root, ["update-ref", "refs/heads/--mirror", "HEAD"], false)
    gitRun(root, ["symbolic-ref", "HEAD", "refs/heads/--mirror"], false)
    @Assert(currentBranch(root) == "--mirror")

    let r = runGitOp(root, "push", "")
    // 核心断言：远端的 doomed 分支必须还在
    let after = gitTry(remote, ["branch", "--format=%(refname:short)"]).stdout
    @Assert(after.contains("doomed"))
    @Assert(after.contains("main"))
    // 不变量只有一条：远端分支一个都不能少。
    // push 本身可能成功也可能失败（本地确实存在 refs/heads/--mirror，
    // git 会把它当普通 refspec 推上去），那都是安全的；危险的是「被当成选项」。
    @Assert(r.op == "push")

    removePathIfExists(root)
    removePathIfExists(remote)
}

/// 正常的 push 路径不能被 `--` 破坏。
@Test
func testPushNormalBranchStillWorks(): Unit {
    let root = "/tmp/deepgit-pushok-${nowMillis()}"
    let remote = root + "-remote.git"
    ensureDir(root)
    gitRun(root, ["init", "--bare", remote], false)
    gitRun(root, ["init", "-b", "main"], false)
    writeFileAtomic(root + "/a.txt", "1")
    gitRun(root, ["add", "."], false)
    commitHead(root, "init")
    gitRun(root, ["remote", "add", "origin", remote], false)

    let r = runGitOp(root, "push", "")
    @Assert(r.ok)
    let after = gitTry(remote, ["branch", "--format=%(refname:short)"]).stdout
    @Assert(after.contains("main"))
    removePathIfExists(root)
    removePathIfExists(remote)
}

/// 提交标题里的控制字符不得击穿记录解析。
///
/// git 只禁止提交信息含 NUL，对 0x1f / 0x1e 毫无限制，`git log` 会原样透传。
/// 旧格式用它们做分隔符，实测后果（3 条真实提交）：
///   subject 含 0x1f → 标题在该处被截断，剩余部分被当成 body
///   subject 含 0x1e → 整条记录被劈两半，后半截变成一条**身份捏造的幽灵提交**
///     引擎把 3 条提交记成「更新×2、微调×1」，真实类型应全是 other
@Test
func testLogCommitsSurvivesControlCharsInSubject(): Unit {
    let base = "/tmp/deepgit-ctrlchar-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    // 标题含 0x1f
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "unit${UNIT}inside"], false)
    writeFileAtomic(base + "/b.txt", "2")
    gitRun(base, ["add", "."], false)
    // 标题含 0x1e
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "rec${REC}inside"], false)
    writeFileAtomic(base + "/c.txt", "3")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "plain subject"], false)

    let logs = logCommits(base, 50, "HEAD", 0)
    // 3 条提交必须还是 3 条：0x1e 曾把一条劈成「一条真 + 一条幽灵」
    @Assert(logs.size == 3)
    var sawUnit = false
    var sawRec = false
    var sawPlain = false
    for (c in logs) {
        if (c.subject == "unit${UNIT}inside") { sawUnit = true }
        if (c.subject == "rec${REC}inside") { sawRec = true }
        if (c.subject == "plain subject") { sawPlain = true }
        // 每条都必须有合法 sha，不能是幽灵记录
        @Assert(c.sha.size == 40)
    }
    @Assert(sawUnit)    // 0x1f 曾把标题截断成 "unit"
    @Assert(sawRec)     // 0x1e 曾导致这条消失
    @Assert(sawPlain)
    // 类型统计不能被幽灵提交污染
    let types = commitTypeStats(base, "HEAD", 50)
    var featOrUpdate: Int64 = 0
    for ((_, n) in types) {
        if (n > 0) { featOrUpdate += n }
    }
    @Assert(featOrUpdate == 3)  // 三条都是 other（无 feat:/fix: 前缀）
    removePathIfExists(base)
}

/// 多行 commit body 必须原样保留换行（它本来就是多行的，压成单行会丢信息）。
@Test
func testLogCommitsKeepsMultilineBody(): Unit {
    let base = "/tmp/deepgit-body-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "subject line", "-m", "body one\nbody two"], false)
    let logs = logCommits(base, 10, "HEAD", 0)
    @Assert(logs.size == 1)
    @Assert(logs[0].subject == "subject line")
    @Assert(logs[0].body.contains("body one"))
    @Assert(logs[0].body.contains("body two"))
    @Assert(logs[0].body.contains("\n"))  // 换行必须还在
    removePathIfExists(base)
}

/// 分支列表不能因为标题里的 0x1f 而丢条目。
/// 旧实现 parts.size < 6 就 continue —— 标题多一个 0x1f 就多切出一段，
/// 结果这一行分支直接从列表里消失。
@Test
func testListBranchesSurvivesControlCharInSubject(): Unit {
    let base = "/tmp/deepgit-brctrl-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "subj${UNIT}ctrl"], false)
    let branches = listBranches(base)
    @Assert(branches.size == 1)
    @Assert(branches[0].name == "main")
    @Assert(branches[0].subject.contains("ctrl"))  // 标题完整保留
    removePathIfExists(base)
}

/// L11 回归：**多条** stash 必须全部解析出来。
/// 原实现用 `-z` 取回输出却按 "\n" 切行 —— 而 `git stash list -z` 的多条目输出
/// 全以 NUL 相连在一行里 ⇒ 只解析第一条（实测 od -c 证实）。
/// 既有测试只造 1 条 stash，结构上测不出这个错。
@Test
func testListStashesParsesEveryEntry(): Unit {
    let base = "/tmp/deepgit-stashmulti-${nowMillis()}"
    ensureDir(base)
    try {
        gitRun(base, ["init", "-b", "main"], false)
        writeFileAtomic(base + "/a.txt", "1")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)
        var i: Int64 = 0
        while (i < 3) {
            writeFileAtomic(base + "/a.txt", "v${i}")
            gitRun(base, ["stash", "-q", "-m", "lab${i}"], false)
            i += 1
        }
        let st = listStashes(base)
        @Assert(st.size == 3)
        @Assert(st[0].message.contains("lab2"))
        @Assert(st[2].message.contains("lab0"))
    } finally {
        removePathIfExists(base)
    }
}

/// stash 说明文字含 0x1f 时不得解析错位。
@Test
func testListStashesSurvivesControlCharInMessage(): Unit {
    let base = "/tmp/deepgit-stashctrl-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)
    writeFileAtomic(base + "/a.txt", "2")
    gitRun(base, ["stash", "-q", "-m", "stash${UNIT}msg"], false)
    let st = listStashes(base)
    @Assert(st.size == 1)
    @Assert(st[0].message.contains("msg"))
    removePathIfExists(base)
}
