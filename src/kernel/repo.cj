// 仓库事实采集：把 git 数据规整成 AI 可读的结构化事实。
package moongit.kernel

import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

/// 单个仓库最多纳入多少个跟踪文件。
///
/// ⚠️ 必须是**同一个常量**：真实上限在这里，而提示文案
/// （flow/report.cj、cli/cli.cj）原先各自硬编码 20000。
/// 上限一改，两条「撞到 N 个跟踪文件的上限」就都变成假话 ——
/// 而这类错误的症状是「上限早就调了，提示还在报旧数」，极难发现。
public const MAX_TRACKED_FILES: Int64 = 20000

public class RepoFacts {
    public let kind: String  // git | dir
    public let name: String
    public let path: String
    public let remote: String
    public let currentBranch: String
    public let defaultBranch: String
    public let headShort: String
    public let headSubject: String
    public let lastCommitAt: String
    public let firstCommitAt: String
    public let commitCount: Int64
    public let branches: ArrayList<BranchInfo>
    public let dirty: DirtyState
    public let stashCount: Int64
    public let tags: ArrayList<(String, String)>
    public let authors: ArrayList<(Int64, String)>
    public let trackedFiles: Int64
    public let langStats: ArrayList<(String, Int64)>
    public let structure: ArrayList<String>
    public let recentCommits: ArrayList<CommitInfo>
    public let oldestCommits: ArrayList<CommitInfo>
    public let commitActivity: ArrayList<(String, Int64)>
    public let manifests: ArrayList<String>
    public let docsPresent: ArrayList<String>
    public let activity: Option<ActivitySnapshot>
    public let warnings: ArrayList<String>
    public let commitTypes: ArrayList<(String, Int64)>
    public let untrackedCount: Int64
    public let worktreeCount: Int64
    // 采集是否触到上限。为 true 时上面两个 count 是真实总数，
    // 但依赖它们的明细（langStats / structure / 未跟踪清单）只覆盖了样本。
    public let trackedTruncated: Bool
    public let untrackedTruncated: Bool
    // 月度活跃度只统计最近 N 个提交；为 true 时下面的直方图不是全量口径。
    // 与 trackedTruncated / untrackedTruncated 同族 —— 「采样上限当全量」这一类
    // 缺陷已经犯过两次（跟踪文件数、未跟踪文件数），这里补齐第三处。
    public let activityTruncated: Bool
    // commitTypes 只统计最近 N 个提交；为 true 时它是样本而非全量分布。
    // 与上面三个同族，是这一族的第四处。危害最直接：
    // commitCount 走 `git rev-list --count` 是真实总数（无上限），
    // commitTypes 却只数最近 15 条，两者并排出现在同一份 JSON 里却从不互相说明。
    // 实测 23 个提交（feat 20 / fix 2 / chore 1）的仓库报成
    // commitCount=23 + feat×12，AI 会得出「52% 是 feat」而实际是 87%。
    public let commitTypesTruncated: Bool
    public let mergeHint: Option<MergePlan>
    public let hotFiles: ArrayList<(String, Int64)>
    /// 未跟踪文件采集失败原因；空串表示成功。**恒发**（K4，契约C kernel 侧）。
    ///
    /// ⚠️ 原来 listUntrackedFiles 失败被编码成 `untrackedCount=0 +
    /// untrackedTruncated=false`（#187 在 listFiles 上修掉的同族），
    /// 下游把「采集失败」读成「工作区干净」。空串=正常，非空=失败原因。
    public let untrackedError: String

    public init(
        kind: String, name: String, path: String, remote: String, currentBranch: String, defaultBranch: String,
        headShort: String, headSubject: String, lastCommitAt: String, firstCommitAt: String, commitCount: Int64,
        branches: ArrayList<BranchInfo>, dirty: DirtyState, stashCount: Int64, tags: ArrayList<(String, String)>,
        authors: ArrayList<(Int64, String)>, trackedFiles: Int64, langStats: ArrayList<(String, Int64)>,
        structure: ArrayList<String>, recentCommits: ArrayList<CommitInfo>, oldestCommits: ArrayList<CommitInfo>,
        commitActivity: ArrayList<(String, Int64)>, manifests: ArrayList<String>, docsPresent: ArrayList<String>,
        activity: Option<ActivitySnapshot>, warnings: ArrayList<String>,
        commitTypes: ArrayList<(String, Int64)>, untrackedCount: Int64, worktreeCount: Int64,
        mergeHint: Option<MergePlan>, hotFiles: ArrayList<(String, Int64)>,
        trackedTruncated!: Bool = false, untrackedTruncated!: Bool = false,
        activityTruncated!: Bool = false,
        commitTypesTruncated!: Bool = false,
        untrackedError!: String = "",
    ) {
        this.kind = kind
        this.name = name
        this.path = path
        this.remote = remote
        this.currentBranch = currentBranch
        this.defaultBranch = defaultBranch
        this.headShort = headShort
        this.headSubject = headSubject
        this.lastCommitAt = lastCommitAt
        this.firstCommitAt = firstCommitAt
        this.commitCount = commitCount
        this.branches = branches
        this.dirty = dirty
        this.stashCount = stashCount
        this.tags = tags
        this.authors = authors
        this.trackedFiles = trackedFiles
        this.langStats = langStats
        this.structure = structure
        this.recentCommits = recentCommits
        this.oldestCommits = oldestCommits
        this.commitActivity = commitActivity
        this.manifests = manifests
        this.docsPresent = docsPresent
        this.activity = activity
        this.warnings = warnings
        this.commitTypes = commitTypes
        this.untrackedCount = untrackedCount
        this.worktreeCount = worktreeCount
        this.mergeHint = mergeHint
        this.hotFiles = hotFiles
        this.trackedTruncated = trackedTruncated
        this.untrackedTruncated = untrackedTruncated
        this.activityTruncated = activityTruncated
        this.commitTypesTruncated = commitTypesTruncated
        this.untrackedError = untrackedError
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "kind", Json.of(this.kind))
        Json.set(o, "name", Json.of(this.name))
        Json.set(o, "path", Json.of(this.path))
        Json.set(o, "remote", Json.of(this.remote))
        Json.set(o, "currentBranch", Json.of(this.currentBranch))
        Json.set(o, "defaultBranch", Json.of(this.defaultBranch))
        Json.set(o, "head", Json.of(this.headShort))
        Json.set(o, "headSubject", Json.of(this.headSubject))
        Json.set(o, "lastCommitAt", Json.of(this.lastCommitAt))
        Json.set(o, "firstCommitAt", Json.of(this.firstCommitAt))
        Json.set(o, "commitCount", Json.of(this.commitCount))
        let brArr = ArrayList<JsonValue>()
        for (b in this.branches) {
            let bo = Json.obj()
            Json.set(bo, "name", Json.of(b.name))
            Json.set(bo, "head", Json.of(shortSha(b.head)))
            Json.set(bo, "date", Json.of(b.date))
            Json.set(bo, "subject", Json.of(b.subject))
            Json.set(bo, "upstream", Json.of(b.upstream))
            Json.set(bo, "ahead", Json.of(b.ahead))
            Json.set(bo, "behind", Json.of(b.behind))
            brArr.add(bo)
        }
        Json.set(o, "branches", JArr(brArr))
        Json.set(o, "dirty", this.dirty.toJson())
        Json.set(o, "stashCount", Json.of(this.stashCount))
        let tagArr = ArrayList<JsonValue>()
        for ((name, date) in this.tags) {
            let to = Json.obj()
            Json.set(to, "name", Json.of(name))
            Json.set(to, "date", Json.of(date))
            tagArr.add(to)
        }
        Json.set(o, "tags", JArr(tagArr))
        let authorArr = ArrayList<JsonValue>()
        for ((count, name) in this.authors) {
            let ao = Json.obj()
            Json.set(ao, "name", Json.of(name))
            Json.set(ao, "commits", Json.of(count))
            authorArr.add(ao)
        }
        Json.set(o, "authors", JArr(authorArr))
        let fs = Json.obj()
        Json.set(fs, "trackedFiles", Json.of(this.trackedFiles))
        let langArr = ArrayList<JsonValue>()
        for ((lang, count) in this.langStats) {
            let lo = Json.obj()
            Json.set(lo, "language", Json.of(lang))
            Json.set(lo, "count", Json.of(count))
            langArr.add(lo)
        }
        Json.set(fs, "byLanguage", JArr(langArr))
        Json.set(o, "fileStats", fs)
        let stArr = ArrayList<JsonValue>()
        for (s in this.structure) {
            stArr.add(Json.of(s))
        }
        Json.set(o, "structure", JArr(stArr))
        let rcArr = ArrayList<JsonValue>()
        for (c in this.recentCommits) {
            rcArr.add(c.toJson())
        }
        Json.set(o, "recentCommits", JArr(rcArr))
        let ocArr = ArrayList<JsonValue>()
        for (c in this.oldestCommits) {
            ocArr.add(c.toJson())
        }
        Json.set(o, "oldestCommits", JArr(ocArr))
        let caArr = ArrayList<JsonValue>()
        for ((month, count) in this.commitActivity) {
            let ao = Json.obj()
            Json.set(ao, "month", Json.of(month))
            Json.set(ao, "count", Json.of(count))
            caArr.add(ao)
        }
        Json.set(o, "commitActivity", JArr(caArr))
        let mArr = ArrayList<JsonValue>()
        for (m in this.manifests) {
            mArr.add(Json.of(m))
        }
        Json.set(o, "manifests", JArr(mArr))
        let dArr = ArrayList<JsonValue>()
        for (d in this.docsPresent) {
            dArr.add(Json.of(d))
        }
        Json.set(o, "docsPresent", JArr(dArr))
        match (this.activity) {
            case Some(a) => Json.set(o, "activity", a.toJson())
            case None => ()
        }
        let wArr = ArrayList<JsonValue>()
        for (w in this.warnings) {
            wArr.add(Json.of(w))
        }
        Json.set(o, "warnings", JArr(wArr))
        let ctArr = ArrayList<JsonValue>()
        for ((t, count) in this.commitTypes) {
            let cto = Json.obj()
            Json.set(cto, "type", Json.of(t))
            Json.set(cto, "count", Json.of(count))
            ctArr.add(cto)
        }
        Json.set(o, "commitTypes", JArr(ctArr))
        Json.set(o, "untrackedCount", Json.of(this.untrackedCount))
        // 恒发（K4，契约C）：空串=正常。「有失败原因」与「没有」是两个状态，
        // 键集不得随数据漂 —— 条件性发键会把故障藏进「键不在」里。
        Json.set(o, "untrackedError", Json.of(this.untrackedError))
        Json.set(o, "trackedTruncated", Json.of(this.trackedTruncated))
        Json.set(o, "untrackedTruncated", Json.of(this.untrackedTruncated))
        Json.set(o, "activityTruncated", Json.of(this.activityTruncated))
        Json.set(o, "commitTypesTruncated", Json.of(this.commitTypesTruncated))
        Json.set(o, "worktreeCount", Json.of(this.worktreeCount))
        match (this.mergeHint) {
            case Some(m) => Json.set(o, "mergeHint", m.toJson())
            case None => ()
        }
        let hfArr = ArrayList<JsonValue>()
        for ((f, count) in this.hotFiles) {
            let hfo = Json.obj()
            Json.set(hfo, "file", Json.of(f))
            Json.set(hfo, "count", Json.of(count))
            hfArr.add(hfo)
        }
        Json.set(o, "hotFiles", JArr(hfArr))
        return o
    }
}

// ------------------------------ 语言识别 ------------------------------

public func languageOf(file: String): String {
    let f = file.toAsciiLower()
    if (f.endsWith(".mbt.md")) {
        return "MoonBit"
    }
    if (f.endsWith(".mbt")) {
        return "MoonBit"
    }
    if (f.endsWith(".ts") || f.endsWith(".tsx") || f.endsWith(".mts") || f.endsWith(".cts")) {
        return "TypeScript"
    }
    if (f.endsWith(".js") || f.endsWith(".jsx") || f.endsWith(".mjs") || f.endsWith(".cjs")) {
        return "JavaScript"
    }
    if (f.endsWith(".swift")) {
        return "Swift"
    }
    if (f.endsWith(".rs")) {
        return "Rust"
    }
    if (f.endsWith(".cj")) {
        return "Cangjie"
    }
    if (f.endsWith(".go")) {
        return "Go"
    }
    if (f.endsWith(".py")) {
        return "Python"
    }
    if (f.endsWith(".java") || f.endsWith(".kt") || f.endsWith(".kts")) {
        return "JVM"
    }
    if (f.endsWith(".c") || f.endsWith(".h") || f.endsWith(".cc") || f.endsWith(".cpp") || f.endsWith(".hpp")) {
        return "C/C++"
    }
    if (f.endsWith(".css") || f.endsWith(".scss") || f.endsWith(".less")) {
        return "CSS"
    }
    if (f.endsWith(".html") || f.endsWith(".htm")) {
        return "HTML"
    }
    if (f.endsWith(".json") || f.endsWith(".yaml") || f.endsWith(".yml") || f.endsWith(".toml")) {
        return "配置"
    }
    if (f.endsWith(".md") || f.endsWith(".mdx")) {
        return "Markdown"
    }
    if (f.endsWith(".sh") || f.endsWith(".bash") || f.endsWith(".zsh")) {
        return "Shell"
    }
    return "其他"
}

public func langStats(files: ArrayList<String>, top: Int64): ArrayList<(String, Int64)> {
    let counter = Counter()
    for (f in files) {
        counter.add(languageOf(f))
    }
    let langs = counter.keys()
    let counts = ArrayList<Int64>()
    for (l in langs) {
        counts.add(counter.countOf(l))
    }
    // 按计数排序（插入排序，稳定：并列时保留首次出现顺序）
    let idx = ArrayList<Int64>()
    for (i in 0..langs.size) {
        idx.add(i)
    }
    for (i in 1..idx.size) {
        let key = idx[i]
        var j = i - 1
        while (j >= 0 && counts[idx[j]] < counts[key]) {
            idx[j + 1] = idx[j]
            j -= 1
        }
        idx[j + 1] = key
    }
    let out = ArrayList<(String, Int64)>()
    for (i in idx) {
        if (out.size >= top) {
            break
        }
        out.add((langs[i], counts[i]))
    }
    return out
}

/// 目录树聚合（前 maxDepth 层）
public func buildStructure(files: ArrayList<String>, maxLines: Int64, maxDepth: Int64): ArrayList<String> {
    let out = ArrayList<String>()
    let counter = Counter()
    var rootCount: Int64 = 0
    for (f in files) {
        if (!f.contains("/")) {
            rootCount += 1
            continue
        }
        let parts = f.split("/")
        var prefix = ""
        var depth: Int64 = 0
        for (i in 0..parts.size - 1) {
            if (depth >= maxDepth) {
                break
            }
            let seg = parts[i]
            let key = if (prefix.isEmpty()) { seg } else { "${prefix}/${seg}" }
            counter.add(key)
            prefix = key
            depth += 1
        }
    }
    let keys = counter.keys()
    let counts = ArrayList<Int64>()
    for (k in keys) {
        counts.add(counter.countOf(k))
    }
    if (rootCount > 0) {
        out.add("(根目录 ${rootCount} 个文件)")
    }
    // 排序
    let idx = ArrayList<Int64>()
    for (i in 0..keys.size) {
        idx.add(i)
    }
    for (i in 1..idx.size) {
        let key = idx[i]
        var j = i - 1
        while (j >= 0 && keys[idx[j]] > keys[key]) {
            idx[j + 1] = idx[j]
            j -= 1
        }
        idx[j + 1] = key
    }
    for (i in idx) {
        if (out.size >= maxLines) {
            out.add("…（更多目录省略）")
            break
        }
        let key = keys[i]
        let depth = countChar(key, 0x2fu8)
        let sb = StringBuilder()
        for (_ in 0..depth) {
            sb.append("  ")
        }
        sb.append(basename(key))
        sb.append("/ (${counts[i]})")
        out.add(sb.toString())
    }
    return out
}

func countChar(s: String, ch: Byte): Int64 {
    var n: Int64 = 0
    for (b in s.toArray()) {
        if (b == ch) {
            n += 1
        }
    }
    return n
}

// ------------------------------ 事实采集 ------------------------------

let MANIFEST_FILES = ["package.json", "moon.mod.json", "Cargo.toml", "Package.swift", "pyproject.toml", "go.mod", "pubspec.yaml", "pom.xml", "cjpm.toml"]

// 缓存：TCC 场景每次 stat 都要吃满超时并泄漏一个 stat 子进程（SubProcess 无 kill API），
// 缓存让长驻服务（serve/mcp）的泄漏有界且大幅加速
//
// ⚠️ 这张表是进程级共享可变状态，而 allProjectStatuses 用 spawn 并发采集，
// 多个 worker 会同时读写它。无锁的 HashMap 在并发写下是数据竞争：桶链被写坏后
// 遍历会自旋在环里，表现为 report / status 整个命令永久挂死（已实测复现，
// 栈停在 volumeAccessibleEx 内的缓存操作）。所以读写都必须持锁。
let volumeCache = HashMap<String, (Bool, Bool, Int64)>()  // (可达, 是否超时, 写入时刻)
let volumeCacheLock = Mutex()
let VOLUME_CACHE_TTL: Int64 = 60000

/// 卷可达性预检：区分「路径不存在」与「TCC 访问阻塞（超时）」。
/// 返回 (可达, 是否超时)；结果缓存 60s。
public func volumeAccessibleEx(path: String): (Bool, Bool) {
    let now = nowMillis()
    // 锁只护住缓存表本身，绝不跨越 execCapture —— 否则并发采集退化成串行 stat
    volumeCacheLock.lock()
    let hit = volumeCache.get(path)
    volumeCacheLock.unlock()
    match (hit) {
        case Some((ok, timedOut, at)) =>
            if (now - at < VOLUME_CACHE_TTL) {
                // timedOut 必须一起缓存：以前只存 ok，于是同一个被 TCC 阻塞的卷，
                // 第一次调用提示「访问被持续阻塞」，60 秒内的后续调用却变成
                // 「路径不存在或卷未挂载」—— 同一状态给出两种互相矛盾的解释。
                return (ok, timedOut)
            }
        case None => ()
    }
    let r = execCapture("stat", [path], None, 1200)
    let ok = r.ok() && !r.timedOut
    volumeCacheLock.lock()
    volumeCache[path] = (ok, r.timedOut, now)
    volumeCacheLock.unlock()
    return (ok, r.timedOut)
}

public func volumeAccessible(path: String): Bool {
    let (ok, _) = volumeAccessibleEx(path)
    return ok
}

/// 月度活跃度统计的提交条数上限。
const ACTIVITY_SCAN_LIMIT: Int64 = 400

/// 提交总数是否超过 limit（用来披露「直方图是抽样」）。
/// 单独一次 git 调用，很便宜 —— 比在渲染时靠猜「月份加总对不上 commitCount」
/// 可靠得多：后者在提交均匀分布时完全看不出问题。
public func hasMoreCommits(dir: String, limit: Int64): Bool {
    let r = gitTry(dir, ["rev-list", "--count", "--max-count=${limit + 1}", "HEAD"])
    if (!r.ok() || r.stdout.isBlank()) {
        return false
    }
    let n = parseIntOr(r.stdout.trimAscii(), 0)
    return n > limit
}

/// 仓库真实分支数。`None` = **读不出来**，不能当成 0。
///
/// 进度库里的分支数是「引擎建立了基线的分支」，天然受
/// `config.maxShallowBranches`（默认 6）限制；而仓库真实分支数来自
/// `for-each-ref refs/heads`，**没有上限**。两者不是一回事：
/// 实测 16 个分支的仓库，update 报「7 个分支」，且零披露。
///
/// 常见路径直接复用 collectFacts 已经取好的 `facts.branches`
/// （for-each-ref 本来就跑过一遍，不重复付这次 git 调用的钱）；
/// 只有它为空时才再问一次 git —— 因为「空」有两种完全不同的含义：
///   rc=0 且没有 ref   → 仓库确实一个分支都没有
///   rc≠0（对象库坏）  → 读不出来
/// 把后者渲染成「仓库共 0 个分支」就是本引擎最高发的那族缺陷：
/// 把「读不出来」说成「不存在」。
public func repoBranchTotal(facts: RepoFacts): Option<Int64> {
    if (facts.kind != "git") {
        // 非 git 项目谈分支数没有意义，报 0 会被读成「这项目 0 个分支」
        return None
    }
    if (!facts.branches.isEmpty()) {
        return Some(facts.branches.size)
    }
    let r = gitTry(facts.path, ["for-each-ref", "--format=%(refname)", "refs/heads"])
    if (!r.ok()) {
        return None
    }
    var n: Int64 = 0
    for (line in r.stdout.split("\n")) {
        if (!line.isEmpty()) {
            n += 1
        }
    }
    return Some(n)
}

public func collectFacts(root: String, kind: String, config: Config, commits: Int64, deep: Bool): RepoFacts {
    // 存在性检查必须盖住两条分支。原先只有 git 分支查，kind="dir" 直接进 collectDirFacts，
    // 而 collectActivity 对不存在的路径安静地返回 0 个文件 ——
    // 于是 status / list 报「非 git 项目 · 0 个文件」，
    // 把「目录已经没了」说成「目录是空的」；同一时刻 doctor 对同一条目报的是
    // 「路径有效 1 个失效」。两个命令对同一事实给出互相矛盾的结论。
    // 放在分支之前，两个 kind 共用同一个闸门，不会再漏。
    let (accessible, timedOut) = volumeAccessibleEx(root)
    if (!accessible) {
        let hint = if (timedOut) {
            "无法访问 ${root} —— 访问被持续阻塞，很可能是 macOS 未授予「可移除宗卷」访问权限（系统设置 → 隐私与安全性 → 文件与文件夹 → moonGit）"
        } else {
            "路径不存在或卷未挂载：${root}"
        }
        throw DgError("VOLUME_BLOCKED", hint, 1, None)
    }
    if (kind != "git") {
        return collectDirFacts(root, config)
    }

    let branches = listBranches(root)
    let dirty = statusSummary(root)
    // 读不到 = 不知道，不等于「什么都没有」。
    // 继续往下走会把「git status 失败」翻译成「工作区干净、0 个提交、0 个跟踪文件」，
    // 而这些数字会被 deep 写进用户 README 的托管区，覆盖掉真实数据。
    // 探测点选 status 而不是 rev-parse：实测索引损坏 / config 语法错 / 对象库损坏 /
    // 非仓库目录都让 `git status --porcelain` rc=128，唯独「刚 git init 还没有提交」
    // 这个合法状态返回 0（ls-files、rev-list 在同一批场景里失败模式各不相同，
    // 单看它们会漏判对象库损坏）。而且这次调用本来就要跑，探测零额外开销。
    if (!dirty.ok) {
        throw DgError(
            "REPO_UNREADABLE",
            "无法读取仓库状态，本次不生成任何事实：${root}\n  git 报告：${dirty.err}\n" +
            "  （读到 0 和真的 0 无法区分；继续写下去只会用假数据覆盖已有的记录）",
            1,
            None,
        )
    }
    let stash = stashCount(root)
    let remote = remoteUrl(root)
    let tagList = tags(root, 10)
    let authors = authorStats(root, 8)
    let firstAt = firstCommitDate(root)
    let recent = logCommits(root, commits, "HEAD", 0)
    let fileList = listFiles(root, MAX_TRACKED_FILES)
    let files = fileList.names
    let defBranch = defaultBranch(root)
    let curBranch = currentBranch(root)

    var headShort = ""
    var headSubject = ""
    var lastAt = ""
    if (recent.size > 0) {
        headShort = recent[0].sha
        headSubject = recent[0].subject
        lastAt = recent[0].date
    }

    var oldest = ArrayList<CommitInfo>()
    let total = commitCount(root, "HEAD")
    var activity: ArrayList<(String, Int64)> = ArrayList<(String, Int64)>()
    var structure: ArrayList<String> = ArrayList<String>()
    var hot: ArrayList<(String, Int64)> = ArrayList<(String, Int64)>()
    if (deep) {
        // 项目起点用真正的 root commit，而不是"最早的若干条"
        oldest = genesisCommits(root, 5)
        activity = commitActivity(root, ACTIVITY_SCAN_LIMIT)
        structure = buildStructure(files, 100, 3)
        hot = fileHeatmap(root, "HEAD", 200, 8)
    } else {
        structure = buildStructure(files, 40, 2)
    }

    let manifests = detectManifests(root, config)
    let docsPresent = detectDocsPresent(root, config)

    // 浅更新增强数据：提交类型分布 / 未跟踪文件 / 多工作区 / 合入提示
    let types = commitTypeStats(root, "HEAD", commits)
    let uts = listUntrackedFiles(root, 50)
    let wts = listWorktrees(root)
    var mergeHint: Option<MergePlan> = Option<MergePlan>.None
    if (curBranch != defBranch && curBranch != "HEAD" && !curBranch.isEmpty()) {
        mergeHint = Some(planMerge(root, curBranch))
    }

    return RepoFacts(
        "git", basename(root), root, remote, curBranch, defBranch,
        headShort, headSubject, lastAt, optionOr(firstAt, ""), total,
        branches, dirty, stash, tagList, authors,
        fileList.total, langStats(files, 12), structure,
        recent, oldest, activity, manifests, docsPresent,
        Option<ActivitySnapshot>.None, ArrayList<String>(),
        types, uts.total, wts.size, mergeHint, hot,
        trackedTruncated: fileList.truncated, untrackedTruncated: uts.truncated,
        activityTruncated: hasMoreCommits(root, ACTIVITY_SCAN_LIMIT),
        commitTypesTruncated: hasMoreCommits(root, commits),
        untrackedError: uts.error,
    )
}

func optionOr(o: Option<String>, fallback: String): String {
    match (o) {
        case Some(s) => return s
        case None => return fallback
    }
}

func detectManifests(root: String, config: Config): ArrayList<String> {
    let out = ArrayList<String>()
    for (m in MANIFEST_FILES) {
        if (fileExists("${root}/${m}")) {
            out.add(m)
        }
    }
    return out
}

public func detectDocsPresent(root: String, config: Config): ArrayList<String> {
    let out = ArrayList<String>()
    let candidates = ArrayList<String>()
    for (d in config.docs) {
        candidates.add(d)
    }
    for (d in config.agentDocCandidates) {
        var dup = false
        for (c in candidates) {
            if (c == d) {
                dup = true
                break
            }
        }
        if (!dup) {
            candidates.add(d)
        }
    }
    for (c in candidates) {
        if (fileExists("${root}/${c}")) {
            out.add(c)
        }
    }
    return out
}

// ------------------------------ 非 git 活动模式 ------------------------------

public class ActivitySnapshot {
    public let fileCount: Int64
    public let totalBytes: Int64
    public let newest: ArrayList<(String, String, Int64)>  // rel, mtime, size
    public let topDirs: ArrayList<(String, Int64)>
    public let newestMtime: String
    /// 有多少条目 / 子目录**读不出来**（stat 失败）。
    ///
    /// ⚠️ 这个字段是 fileCount 的诚实性前提，不是可选的补充信息：
    /// `fileCount` 只能数它**看到**的文件，读不到的那些一条也没少，
    /// 于是「12000 个文件」是**下界**而不是总数。
    /// 不带这个字段出去，调用方（包括 headline 和 AI 上下文）会把下界当总数。
    /// 与 trackedTruncated / untrackedTruncated 同族 —— 那是「触顶当全量」，
    /// 这一处是「没看到当不存在」，成因不同但危害同构。
    public let unreadable: Int64
    /// 读不到的路径样本（上限 5 条），让用户知道该去放权/挂载哪。
    public let unreadableSamples: ArrayList<String>
    /// 文件数撞采集上限（maxFiles）**主动停了** —— 队列里还有没走到的目录。
    ///
    /// ⚠️ K3（审查）：unreadable 早就把「没看到」披露出去了，
    /// 而触顶是**第三种独立的**覆盖不完整成因（采样上限，见 collectActivity
    /// 头部注释「触顶是我们主动停了，读不到是我们看不到」），却零披露 ——
    /// 假总数「12000 个文件」就这么写进 README 托管区与 headline。
    /// 与 unreadable 一样，命中时 fileCount 是**下界**不是总数。
    public let fileCapHit: Bool
    /// 目录深度撞采集上限（maxDepth）**主动不往下走** ——
    /// 被跳过的那个目录条目本身就是一棵没被看过的子树。
    public let depthCapHit: Bool

    public init(fileCount: Int64, totalBytes: Int64, newest: ArrayList<(String, String, Int64)>, topDirs: ArrayList<(String, Int64)>, newestMtime: String) {
        this(fileCount, totalBytes, newest, topDirs, newestMtime, 0, ArrayList<String>())
    }

    public init(fileCount: Int64, totalBytes: Int64, newest: ArrayList<(String, String, Int64)>, topDirs: ArrayList<(String, Int64)>, newestMtime: String, unreadable: Int64, unreadableSamples: ArrayList<String>, fileCapHit!: Bool = false, depthCapHit!: Bool = false) {
        this.fileCount = fileCount
        this.totalBytes = totalBytes
        this.newest = newest
        this.topDirs = topDirs
        this.newestMtime = newestMtime
        this.unreadable = unreadable
        this.unreadableSamples = unreadableSamples
        this.fileCapHit = fileCapHit
        this.depthCapHit = depthCapHit
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "fileCount", Json.of(this.fileCount))
        Json.set(o, "totalBytes", Json.of(this.totalBytes))
        // 恒发：这两个键缺席时，「没看到」和「不存在」就无法区分。
        // 客户端拿 fileCount 当总数用，缺席就等于默认 0，也就是默认「全都看到了」。
        Json.set(o, "unreadable", Json.of(this.unreadable))
        // 恒发（K3）：这两个键缺席时，「触顶停了」和「看全了」就无法区分 ——
        // 调用方会把 12000 这个采集上限当成仓库的文件总数。
        Json.set(o, "fileCapHit", Json.of(this.fileCapHit))
        Json.set(o, "depthCapHit", Json.of(this.depthCapHit))
        let unreadArr = ArrayList<JsonValue>()
        for (p in this.unreadableSamples) {
            unreadArr.add(Json.of(p))
        }
        Json.set(o, "unreadableSamples", JArr(unreadArr))
        let arr = ArrayList<JsonValue>()
        for ((rel, mtime, size) in this.newest) {
            let e = Json.obj()
            Json.set(e, "rel", Json.of(rel))
            Json.set(e, "mtime", Json.of(mtime))
            Json.set(e, "size", Json.of(size))
            arr.add(e)
        }
        Json.set(o, "newest", JArr(arr))
        let dirArr = ArrayList<JsonValue>()
        for ((name, count) in this.topDirs) {
            let e = Json.obj()
            Json.set(e, "name", Json.of(name))
            Json.set(e, "count", Json.of(count))
            dirArr.add(e)
        }
        Json.set(o, "topDirs", JArr(dirArr))
        Json.set(o, "newestMtime", Json.of(this.newestMtime))
        return o
    }
}

let SKIP_DIRS = ["node_modules", ".git", ".svn", ".hg", ".build", ".swiftpm", "build", "dist", "target", "__pycache__", ".venv", "venv", ".next", ".cache", ".gradle", ".idea", "_build", "coverage", "DerivedData", "renders", "snapshots", ".playwright-mcp", ".zcode"]

func shouldSkipDir(name: String): Bool {
    for (s in SKIP_DIRS) {
        if (s == name) {
            return true
        }
    }
    return false
}

/// 撞界目录里是否还有**会被采集的**条目（#197 scanner 同款判据）。
///
/// 一见边界就置位 = 谎报「没看完」：边界处常常是叶子目录（空的、或只有
/// 点开头 / skip 名单里的东西），那种情况是**真的看全了**，置位反而骗人。
/// 必须确认被跳过的子树里还有会被采集的条目（文件、或未入 skip 名单的目录），
/// 才算真的被截断。
///
/// 判定与主循环逐条对齐（否则确认就与采集口径漂移）：
///   · 点开头 → 主循环直接 continue，不算「会被采集」；
///   · skip 名单目录 → 主循环跳过，不算；
///   · Unreadable → 保守算「有」：读不出来 = 可能有没看过的文件，
///     宁可说「可能没看完」（对齐 scanner 的 hasUnexploredSubdir 取向）；
///   · 读不到目录本身 → 同上，保持置位。
/// 每个边界目录只付一次 listDir 的代价。
func hasCollectibleEntry(dir: String): Bool {
    let (entries, readable) = listDirChecked(dir)
    if (!readable) {
        return true
    }
    for (info in entries) {
        if (info.name.startsWith(".")) {
            continue
        }
        match (classifyEntry(info)) {
            case EntryKind.Unreadable => return true
            case EntryKind.Dir =>
                if (!shouldSkipDir(info.name)) {
                    return true
                }
            case EntryKind.Regular => return true
            case EntryKind.Other => continue
        }
    }
    return false
}

/// 扫描目录活动（基于 mtime，深度有界）
///
/// ⚠️ 这个遍历里原来有**两个**独立缺陷，都表现为「一棵树里只要有一个读不到的
/// 地方，整个项目就废了或说谎」，实测路径 `/private/var/db`、`/`：
///
/// 1. **崩溃**：`info.isDirectory()` / `isRegular()` / `lastModificationTime` 走 stat，
///    stat 不到就**抛异常**（SIP 保护目录、`/dev/fd/20`、权限不足），
///    而整个循环体没有任何 try/catch —— 异常一路穿透 `collectFacts`、
///    `projectStatus`、`allProjectStatuses`，最后只剩一句
///    `error='Native function error.'` + `commitCount=-1`。
///    即：**一个只读属性取不到，整个项目的状态面板全黑**。
///    现在统一走 `classifyEntry` / `entryMtime` / `entrySize`（paths.cj 的唯一口径）。
///
/// 2. **静默少算**：`listDir` 吞掉异常返回空数组，于是「子目录读不出来」
///    与「这个子目录真的是空的」完全同构 —— 前者少算一整个子树，
///    `fileCount` 变成下界，headline 却照报「N 个文件」。
///    现在改用 `listDirChecked`，读不出来的子目录计入 `unreadable`。
///
/// 采样上限（maxFiles / maxDepth）之外，这是第三种「覆盖不完整」的成因，
/// 但它必须单独披露：触顶是**我们主动停了**，读不到是**我们看不到**。
public func collectActivity(dir: String, maxFiles: Int64, maxDepth: Int64): ActivitySnapshot {
    let files = ArrayList<(String, String, Int64)>()  // rel, mtime, size
    let dirCounts = ArrayList<(String, Int64)>()
    var totalBytes: Int64 = 0
    var unreadable: Int64 = 0
    let unreadableSamples = ArrayList<String>()
    // K3：触顶是第三种「覆盖不完整」成因，必须与 unreadable 一样被披露。
    //   fileCapHit  —— 文件数撞 maxFiles 主动停了，队列里还有没走的目录；
    //   depthCapHit —— 深度撞 maxDepth 主动不下了，被跳过的目录本身是没看过的子树。
    // 不置位 ⇒ fileCount 被下游当总数（headline / README 托管区）⇒ 假总数。
    var hitFileCap = false
    var hitDepthCap = false
    let queue = ArrayList<(String, Int64)>()
    queue.add((dir, 0))
    var head = 0
    while (head < queue.size && files.size < maxFiles) {
        let (cur, depth) = queue[head]
        head += 1
        let (entries, dirReadable) = listDirChecked(cur)
        if (!dirReadable) {
            // 目录读不出来同样是一棵没被走过的树，不是一棵空树
            unreadable += 1
            if (unreadableSamples.size < 5) {
                unreadableSamples.add(cur)
            }
            continue
        }
        for (info in entries) {
            let nm = info.name
            if (nm.startsWith(".")) {
                continue
            }
            // ⚠️ 顺序是承重的：Unreadable 单列，不能落到 Other 里去，
            // 也不能因为「不是目录」就当它不存在。
            match (classifyEntry(info)) {
                case EntryKind.Unreadable =>
                    unreadable += 1
                    if (unreadableSamples.size < 5) {
                        unreadableSamples.add(cur + "/" + nm)
                    }
                    continue
                case EntryKind.Dir =>
                    if (shouldSkipDir(nm)) {
                        continue
                    }
                    if (depth >= maxDepth) {
                        // 这个目录条目本身就是一棵没被看过的子树 —— 但要先确认
                        // 它非空才算「被截断」（#197 scanner 同款判据）：
                        // 边界处常常是叶子目录，一见边界就置位 = 谎报「没看完」，
                        // 读者于是不信「看全了」的那次真话。
                        // 只在尚未置位时才付确认的代价；读不到时按「有」处理。
                        if (!hitDepthCap && hasCollectibleEntry(cur + "/" + nm)) {
                            hitDepthCap = true
                        }
                        continue
                    }
                    queue.add((cur + "/" + nm, depth + 1))
                    continue
                case EntryKind.Regular => ()
                case EntryKind.Other => continue
            }
            let rel = relativeTo(dir, cur + "/" + nm)
            let size = entrySize(info)
            files.add((rel, entryMtime(info), if (size >= 0) { size } else { 0 }))
            // size 读不出来时不能把 0 加进总字节数 —— 那是编一个数出来。
            if (size >= 0) {
                totalBytes += size
            }
            let top = if (rel.contains("/")) { rel[..indexOfStr(rel, "/")] } else { "" }
            if (top.size > 0) {
                var found = false
                for (i in 0..dirCounts.size) {
                    let (n, c) = dirCounts[i]
                    if (n == top) {
                        dirCounts[i] = (n, c + 1)
                        found = true
                        break
                    }
                }
                if (!found) {
                    dirCounts.add((top, 1))
                }
            }
        }
    }

    // 按 mtime 倒序（插入排序）
    let sorted = ArrayList<(String, String, Int64)>()
    for (f in files) {
        sorted.add(f)
    }
    var i = 1
    while (i < sorted.size) {
        let key = sorted[i]
        var j = i - 1
        while (j >= 0 && sorted[j][1] < key[1]) {
            sorted[j + 1] = sorted[j]
            j -= 1
        }
        sorted[j + 1] = key
        i += 1
    }

    let newest = ArrayList<(String, String, Int64)>()
    for (k in 0..if (sorted.size > 20) { 20 } else { sorted.size }) {
        newest.add(sorted[k])
    }

    // topDirs 排序
    var topDirs = ArrayList<(String, Int64)>()
    for (d in dirCounts) {
        topDirs.add(d)
    }
    var a = 1
    while (a < topDirs.size) {
        let key = topDirs[a]
        var b = a - 1
        while (b >= 0 && topDirs[b][1] < key[1]) {
            topDirs[b + 1] = topDirs[b]
            b -= 1
        }
        topDirs[b + 1] = key
        a += 1
    }
    if (topDirs.size > 15) {
        let trimmed = ArrayList<(String, Int64)>()
        for (k in 0..15) {
            trimmed.add(topDirs[k])
        }
        topDirs = trimmed
    }

    // 循环退出有两种成因：队列排空（看全了），或文件数撞上限主动停了。
    // 只有**队列里还有会被采集的条目**时才算触顶 —— 恰好数到 maxFiles 且队列
    // 同时排空的情况下没有遗漏任何目录，不置位（对齐 #48「到边界 ≠ 被截断」）。
    // 队列非空也不够：剩余目录可能全是空的（或只剩点开头 / skip 名单里的东西），
    // 那也是真的看全了。从队首开始逐个确认，找到第一个还有可采集条目的目录
    // 才置位并停止（每个目录一次 listDir，通常第一个就有结论）；
    // 读不到的目录按「有」处理 —— 宁可说「可能没看完」。
    if (files.size >= maxFiles && head < queue.size) {
        var k = head
        while (k < queue.size) {
            if (hasCollectibleEntry(queue[k][0])) {
                hitFileCap = true
                break
            }
            k += 1
        }
    }
    let newestMtime = if (newest.isEmpty()) { "" } else { newest[0][1] }
    return ActivitySnapshot(files.size, totalBytes, newest, topDirs, newestMtime, unreadable, unreadableSamples,
        fileCapHit: hitFileCap, depthCapHit: hitDepthCap)
}

func relativeTo(base: String, abs: String): String {
    let b = if (base.endsWith("/")) { base } else { base + "/" }
    if (abs.startsWith(b)) {
        return abs[b.size..]
    }
    return abs
}

func indexOfStr(s: String, needle: String): Int64 {
    match (s.indexOf(needle)) {
        case Some(i) => return i
        case None => return 0
    }
}

/// maxFiles / maxDepth 做成可注入（K3）：生产值仍是 (12000, 6)，
/// 测试用小上限就能真实触顶，不必真造一万个文件（触顶路径本身要被测到）。
func collectDirFacts(root: String, config: Config, maxFiles!: Int64 = 12000, maxDepth!: Int64 = 6): RepoFacts {
    let activity = collectActivity(root, maxFiles, maxDepth)
    let manifests = detectManifests(root, config)
    let docsPresent = detectDocsPresent(root, config)
    let structure = ArrayList<String>()
    for ((name, count) in activity.topDirs) {
        structure.add("${name}/ (${count})")
    }
    let warnings = ArrayList<String>()
    warnings.add("非 git 仓库：进度基于文件活动时间，不含提交历史")
    return RepoFacts(
        "dir", basename(root), root, "", "", "",
        "", "", activity.newestMtime, "", 0,
        ArrayList<BranchInfo>(), DirtyState(true, 0, 0, 0, 0, 0, ArrayList<String>()), 0,
        ArrayList<(String, String)>(), ArrayList<(Int64, String)>(),
        activity.fileCount, langStats(ArrayList<String>(), 12), structure,
        ArrayList<CommitInfo>(), ArrayList<CommitInfo>(), ArrayList<(String, Int64)>(),
        manifests, docsPresent, Some(activity), warnings,
        ArrayList<(String, Int64)>(), 0, 1, Option<MergePlan>.None, ArrayList<(String, Int64)>(),
    )
}

// ------------------------------ 测试 ------------------------------

@Test
func testLanguageOf(): Unit {
    @Assert(languageOf("src/main.swift") == "Swift")
    @Assert(languageOf("moonGit/src/main.cj") == "Cangjie")
    @Assert(languageOf("a/b.mbt.md") == "MoonBit")
    @Assert(languageOf("x.tsx") == "TypeScript")
    @Assert(languageOf("README.md") == "Markdown")
    @Assert(languageOf("unknown.xyz") == "其他")
}

@Test
func testLangStatsOrdering(): Unit {
    let files = ArrayList<String>(["a.swift", "b.swift", "c.rs", "d.md"])
    let stats = langStats(files, 12)
    @Assert(stats[0][0] == "Swift")
    @Assert(stats[0][1] == 2)
}

@Test
func testBuildStructure(): Unit {
    let files = ArrayList<String>(["src/a.cj", "src/util/b.cj", "README.md", "src/util/c.cj"])
    let s = buildStructure(files, 20, 3)
    let joined = joinStrings(s, "\n")
    @Assert(joined.contains("src/"))
    @Assert(joined.contains("util/"))
    @Assert(joined.contains("根目录 1 个文件"))
}

@Test
func testCollectDirFactsNonGit(): Unit {
    let tmp = "/tmp/deepgit-facts-${nowMillis()}"
    ensureDir(tmp + "/src")
    writeFileAtomic(tmp + "/README.md", "# test")
    writeFileAtomic(tmp + "/src/a.cj", "package a")
    let facts = collectFacts(tmp, "dir", Config.defaults(), 10, false)
    @Assert(facts.kind == "dir")
    @Assert(facts.activity.isSome())
    @Assert(facts.warnings.size > 0)
    @Assert(facts.docsPresent.size > 0)
    removePathIfExists(tmp)
}

@Test
func testRepoFactsJsonShape(): Unit {
    let tmp = "/tmp/deepgit-fj-${nowMillis()}"
    ensureDir(tmp)
    let facts = collectFacts(tmp, "dir", Config.defaults(), 10, false)
    let j = facts.toJson()
    @Assert(Json.strAt(j, "kind", "") == "dir")
    @Assert(Json.get(j, "activity").isSome())
    removePathIfExists(tmp)
}

@Test
func testShortSha(): Unit {
    @Assert(shortSha("0123456789abcdef") == "01234567")
    @Assert(shortSha("abc") == "abc")
}

@Test
func testCommitTypesAndHotFilesInFacts(): Unit {
    let base = "/tmp/deepgit-facts2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/hot.cj", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: one"], false)
    writeFileAtomic(base + "/hot.cj", "2")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "fix: two"], false)
    writeFileAtomic(base + "/loose.txt", "x")  // 未跟踪

    let facts = collectFacts(base, "git", Config.defaults(), 10, true)
    @Assert(facts.commitTypes.size >= 2)
    @Assert(facts.commitTypes[0][0] == "feat")
    @Assert(facts.untrackedCount >= 1)
    @Assert(facts.hotFiles.size >= 1)
    @Assert(facts.hotFiles[0][0] == "hot.cj")
    @Assert(facts.hotFiles[0][1] == 2)
    // toJson 一致性
    let j = facts.toJson()
    @Assert(Json.arrAt(j, "commitTypes").size >= 2)
    @Assert(Json.intAt(j, "untrackedCount", 0) >= 1)
    @Assert(Json.arrAt(j, "hotFiles").size >= 1)
    removePathIfExists(base)
}

@Test
func testVolumeCacheIsSafeUnderConcurrentAccess(): Unit {
    // volumeCache 是进程级共享可变状态，而 allProjectStatuses 用 spawn 并发采集。
    // 无锁 HashMap 在并发写下是数据竞争：桶链被写坏后遍历会自旋在环里，
    // 表现为 report / status 整个命令永久挂死（实测 40 次里复现 1 次，
    // 栈停在 volumeAccessibleEx 内的缓存操作）。
    // 竞态本身无法用单次断言稳定复现，这里断言的是「并发下语义仍然自洽」：
    // 所有调用都能返回，且同一路径的结论一致。
    let existing = "/tmp/deepgit-vol-${nowMillis()}"
    let missing = existing + "-no-such-dir"
    ensureDir(existing)

    let futures = ArrayList<Future<Bool>>()
    for (i in 0..8) {
        let p = if (i % 2 == 0) { existing } else { missing }
        futures.add(spawn {
            // 同一路径反复取，既覆盖并发读也覆盖并发写同一 key
            for (_ in 0..5) {
                let (ok, _) = volumeAccessibleEx(p)
                if (ok != (p == existing)) {
                    return false
                }
            }
            return true
        })
    }
    for (f in futures) {
        @Assert(f.get(Duration.second * 60))
    }

    // timedOut 必须进缓存：以前只缓存 ok，同一个被 TCC 阻塞的卷
    // 第一次提示「访问被持续阻塞」，60 秒内的后续调用却变成「路径不存在或卷未挂载」。
    let (ok1, t1) = volumeAccessibleEx(missing)
    let (ok2, t2) = volumeAccessibleEx(missing)
    @Assert(!ok1)
    @Assert(!ok2)
    @Assert(t1 == t2)

    removePathIfExists(existing)
}

/// 仓库读不出来时 collectFacts 必须抛错，而不是返回一批清零的「事实」。
///
/// 这是本轮修的最严重的数据完整性缺陷：读失败被压成 clean + 全 0，
/// deep 拿着这批假事实去改写用户 README 托管区，还 exit 0 报成功。
/// 「读到 0」和「真的是 0」在下游完全无法区分 —— 所以必须在上游就断掉。
@Test
func testCollectFactsThrowsWhenRepoUnreadable(): Unit {
    let base = "/tmp/deepgit-unreadable-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)
    // 健康基线：能采集到真实事实
    @Assert(collectFacts(base, "git", Config.defaults(), 10, false).trackedFiles == 1)

    // 索引损坏 → 必须抛 REPO_UNREADABLE
    writeFileAtomic(base + "/.git/index", "GARBAGE-NOT-AN-INDEX")
    var threw = false
    try {
        _ = collectFacts(base, "git", Config.defaults(), 10, true)
    } catch (e: DgError) {
        threw = e.code == "REPO_UNREADABLE"
        @Assert(e.message.contains(base))       // 说清是哪个仓库
        @Assert(e.message.contains("index"))     // 把 git 的原话带出来
    }
    @Assert(threw)

    // config 语法错误同样要断
    removePathIfExists(base + "/.git/index")
    gitRun(base, ["reset", "-q"], false)
    writeFileAtomic(base + "/.git/config", "[core\n  bork = true\n")
    var threw2 = false
    try {
        _ = collectFacts(base, "git", Config.defaults(), 10, false)
    } catch (e: DgError) {
        threw2 = e.code == "REPO_UNREADABLE"
    }
    @Assert(threw2)
    removePathIfExists(base)
}

/// 断链符号链接不得让 collectFacts 整体失败。
///
/// 旧实现里 untrackedFiles 的 FileInfo(Path) 对 `ln -s /nonexistent/x` 抛异常，
/// 无 try/catch 直接穿透 collectFacts，update / track / deep 全部 exit 1。
/// track 是 post-commit 钩子 —— 仓库里有一个断链，用户每次提交都会看到报错。
@Test
func testCollectFactsSurvivesDanglingSymlink(): Unit {
    let base = "/tmp/deepgit-danglefacts-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)
    let ln = execCapture("ln", ["-s", "/nonexistent-target-xyz/deepgit", base + "/dangling.lnk"], None, 8000)
    @Assert(ln.ok())

    // 关键：这里不能抛。断链是一个未跟踪条目，不是致命错误。
    let facts = collectFacts(base, "git", Config.defaults(), 10, true)
    @Assert(facts.untrackedCount >= 1)
    @Assert(facts.trackedFiles == 1)   // 断链不影响已跟踪文件数
    @Assert(facts.dirty.ok)
    removePathIfExists(base)
}

/// 「刚 git init、还没有任何提交」是合法状态，不能被探针误伤。
///
/// git rev-list / rev-parse 在这种仓库里都返回非零，只有 git status 返回 0 ——
/// 这正是把探针选在 status 上的原因。
@Test
func testCollectFactsWorksOnRepoWithoutCommits(): Unit {
    let base = "/tmp/deepgit-nocommits-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/draft.txt", "wip")
    let facts = collectFacts(base, "git", Config.defaults(), 10, true)
    @Assert(facts.commitCount == 0)
    @Assert(facts.trackedFiles == 0)   // 真的 0，不是读失败
    @Assert(facts.untrackedCount == 1)
    @Assert(facts.dirty.ok)
    @Assert(!facts.dirty.clean)
    removePathIfExists(base)
}

/// 触到采集上限时必须报真实总数 + 明确的截断标记。
///
/// 旧实现把 lsFiles 的样本长度（上限 20000）直接当「跟踪文件总数」，
/// 未跟踪文件同理（上限 50）。实测 20001 个跟踪文件的仓库报「20000 个」，
/// 317 个未跟踪文件报「50 个」—— 两个数字都不是事实，却都写进了 README 托管区。
@Test
func testFactsReportRealTotalsNotSampleSizeWhenTruncated(): Unit {
    let base = "/tmp/deepgit-truncfact-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    // 超过 20000 的跟踪文件太多太慢，这里直接验证语义：上限内不标截断
    for (i in 0..5) {
        File.writeTo(Path("${base}/t${i}.txt"), "x".toArray())
    }
    gitRun(base, ["add", "."], false)
    let small = collectFacts(base, "git", Config.defaults(), 5, false)
    @Assert(small.trackedFiles == 5)
    @Assert(!small.trackedTruncated)

    // 未跟踪超过 maxFiles=50 时：总数是真数，标记为已截断
    for (i in 0..80) {
        File.writeTo(Path("${base}/u${i}.txt"), "x".toArray())
    }
    let big = collectFacts(base, "git", Config.defaults(), 5, false)
    @Assert(big.untrackedCount == 80)   // 不是 50
    @Assert(big.untrackedTruncated)
    @Assert(big.trackedFiles == 5)
    @Assert(!big.trackedTruncated)
    removePathIfExists(base)
}

/// listFiles 必须数完整个输出，而不是在 maxFiles 处就 break。
@Test
func testListFilesCountsBeyondSampleCap(): Unit {
    let base = "/tmp/deepgit-listcap-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    for (i in 0..120) {
        File.writeTo(Path("${base}/f${i}.txt"), "x".toArray())
    }
    gitRun(base, ["add", "."], false)
    let l = listFiles(base, 50)
    @Assert(l.names.size == 50)          // 样本按上限给
    @Assert(l.total == 120)              // 总数数完
    @Assert(l.truncated)
    removePathIfExists(base)
}

/// listUntrackedFiles 同理。
@Test
func testListUntrackedCountsBeyondSampleCap(): Unit {
    let base = "/tmp/deepgit-utcap-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    File.writeTo(Path("${base}/seed.txt"), "x".toArray())
    gitRun(base, ["add", "."], false)
    for (i in 0..70) {
        File.writeTo(Path("${base}/u${i}.txt"), "x".toArray())
    }
    let l = listUntrackedFiles(base, 20)
    @Assert(l.names.size == 20)
    @Assert(l.total == 70)
    @Assert(l.truncated)
    removePathIfExists(base)
}

/// K4 回归：ls-files --others 失败必须带出原因，不许编码成「0 个未跟踪且未截断」。
///
/// 原实现把 `!r.ok() || r.stdout.isEmpty()` 合并成一个分支，返回
/// `UntrackedListing(out, 0, false)` —— 「采集失败」与「真的没有未跟踪文件」
/// 在下游完全同形，untrackedCount=0 会被读成「工作区干净」（#187 在 listFiles
/// 上修掉的同族，UntrackedListing 没跟上）。
///
/// 走真实失败路径：损坏 .git/index（实测 rc=128、stderr「fatal: index file corrupt」，
/// 本轮在 /tmp 沙箱用系统 git 验证过），不是手搓返回值。
@Test
func testListUntrackedReportsErrorInsteadOfZeroOnFailure(): Unit {
    let base = "/tmp/deepgit-uterr-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    File.writeTo(Path("${base}/seed.txt"), "x".toArray())
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)
    File.writeTo(Path("${base}/u.txt"), "x".toArray())

    // 对照：健康仓库 —— 真的 1 个未跟踪，error 必须是空串（0 是结论不是失败）
    let healthy = listUntrackedFiles(base, 20)
    @Assert(healthy.total == 1)
    @Assert(healthy.error.isEmpty())

    // 真空对照：一个未跟踪都没有的仓库，error 也必须是空串 ——
    // 「没有」与「读不出来」两个状态都要钉住，不许修一边坏一边
    let clean = "/tmp/deepgit-uterr-clean-${nowMillis()}"
    ensureDir(clean)
    gitRun(clean, ["init", "-b", "main"], false)
    File.writeTo(Path("${clean}/seed.txt"), "x".toArray())
    gitRun(clean, ["add", "."], false)
    gitRun(clean, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)
    let empty = listUntrackedFiles(clean, 20)
    @Assert(empty.total == 0)
    @Assert(empty.error.isEmpty())
    @Assert(!empty.truncated)
    removePathIfExists(clean)

    // 损坏 index：ls-files --others 真实失败（fatal: index file corrupt）
    File.writeTo(Path("${base}/.git/index"), "GARBAGENOTANINDEXxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx".toArray())
    let broken = listUntrackedFiles(base, 20)
    @Assert(!broken.error.isEmpty())          // 关键：原因必须带出来
    @Assert(broken.error.contains("失败"))     // 文案能指导下一步
    @Assert(broken.total == 0)                // 形状保持（0 是无知，靠 error 区分）
    removePathIfExists(base)
}

/// K4 回归（契约C kernel 侧）：RepoFacts.toJson 恒发 untrackedError，空串也发。
/// 键集不得随数据漂 —— 条件性发键会把「采集失败」藏进「键不在」里。
/// 走真实 collectFacts 路径（git 与 dir 两种 kind），不是手搓 RepoFacts。
@Test
func testFactsAlwaysEmitUntrackedErrorKey(): Unit {
    let base = "/tmp/deepgit-utkey-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    File.writeTo(Path("${base}/seed.txt"), "x".toArray())
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)
    let gitFacts = collectFacts(base, "git", Config.defaults(), 10, false)
    let j = gitFacts.toJson()
    @Assert(Json.has(j, "untrackedError"))
    @Assert(Json.strAt(j, "untrackedError", "MISSING") == "")

    // dir 分支（collectDirFacts）同样恒发：非 git 项目没有 untracked 概念，
    // 但键必须在 —— 消费方（契约C 的 flow 侧）按同一形状解码
    let dirBase = "/tmp/deepgit-utkey-dir-${nowMillis()}"
    ensureDir(dirBase + "/sub")
    writeFileAtomic(dirBase + "/a.txt", "a")
    let dirFacts = collectFacts(dirBase, "dir", Config.defaults(), 10, false)
    let jd = dirFacts.toJson()
    @Assert(Json.has(jd, "untrackedError"))
    @Assert(Json.strAt(jd, "untrackedError", "MISSING") == "")
    removePathIfExists(dirBase)
    removePathIfExists(base)
}

/// langStats 并列时保留首次出现顺序 —— 改成 Counter 后最容易悄悄丢掉的性质。
@Test
func testLangStatsTieKeepsFirstSeenOrder(): Unit {
    let a = langStats(ArrayList<String>(["a.cj", "b.py"]), 10)
    let b = langStats(ArrayList<String>(["b.py", "a.cj"]), 10)
    @Assert(a.size == 2)
    @Assert(a[0][1] == 1)
    // 同样的计数下，输入顺序决定名次；两次调用各自稳定即可（不能被 map 序打乱）
    @Assert(a[0][0] != b[0][0] || a[1][0] != b[1][0] || a.size == 1)
    let a2 = langStats(ArrayList<String>(["a.cj", "b.py"]), 10)
    @Assert(a2[0][0] == a[0][0])
    @Assert(a2[1][0] == a[1][0])
}

/// buildStructure 必须给出与输入一致的目录计数。
@Test
func testBuildStructureCountsAreCorrect(): Unit {
    let files = ArrayList<String>()
    for (i in 0..5) {
        files.add("src/core/mod${i}.cj")
    }
    for (i in 0..3) {
        files.add("src/util/mod${i}.cj")
    }
    files.add("README.md")
    let s = buildStructure(files, 50, 3)
    // 注意：ArrayList.contains 是「元素相等」，不是子串匹配；
    // 子目录行带缩进，所以必须 join 之后再找子串。
    let joined = joinStrings(s, "\n")
    @Assert(joined.contains("src/ (8)"))
    @Assert(joined.contains("core/ (5)"))
    @Assert(joined.contains("util/ (3)"))
    @Assert(joined.contains("根目录 1 个文件"))
    @Assert(s.contains("…（更多目录省略）") == false)
}

/// 大仓库的 buildStructure 也要有界 —— 旧的线性去重是 O(文件数 × 目录数)。
@Test
func testBuildStructureScalesToLargeRepo(): Unit {
    let files = ArrayList<String>()
    for (d in 0..500) {
        for (i in 0..40) {
            files.add("d${d}/f${i}.txt")
        }
    }
    let t0 = nowMillis()
    let s = buildStructure(files, 50, 3)
    let elapsed = nowMillis() - t0
    // 截断到 maxLines 后还会追加一行「更多目录省略」标记，所以是 51 不是 50
    @Assert(s.size == 51)
    @Assert(s[50] == "…（更多目录省略）")
    @Assert(joinedHas(s, "d0/ (40)"))
    @Assert(elapsed < 20000)
}

private func joinedHas(items: ArrayList<String>, needle: String): Bool {
    return joinStrings(items, "\n").contains(needle)
}

/// 月度活跃度触到采样上限时必须披露，不得当成全量。
///
/// 这是「上限当全量」这一类缺陷的第三处（前两处：跟踪文件 20000、
/// 未跟踪文件 50 —— 都已加 truncated 标志并在渲染时披露）。
/// 危害是 README 自相矛盾：声明 450 个提交，月度直方图只加得出 400，
/// 而被砍掉的那 50 条落在哪个月完全看不出来。
@Test
func testActivityTruncationIsDisclosed(): Unit {
    let base = "/tmp/deepgit-act-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "c1"], false)
    // 1 条提交、上限 2 → 没有更多，不得标记截断
    @Assert(!hasMoreCommits(base, 2))
    // 1 条提交、上限 400 → 同样没有更多
    @Assert(!hasMoreCommits(base, 400))
    let small = collectFacts(base, "git", Config.defaults(), 10, true)
    @Assert(!small.activityTruncated)
    @Assert(!small.commitActivity.isEmpty())

    // 再加两条 → 共 3 条，上限 2 时必须判定为「还有更多」
    for (i in 2..4) {
        writeFileAtomic(base + "/a.txt", "${i}")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "c${i}"], false)
    }
    @Assert(hasMoreCommits(base, 2))   // 3 > 2 → 还有更多
    @Assert(!hasMoreCommits(base, 3))  // 3 > 3 不成立 → 恰好等于上限，没有更多
    @Assert(!hasMoreCommits(base, 4))
    removePathIfExists(base)
}

@Test
func testCollectFactsRejectsMissingPathForBothKinds(): Unit {
    // 存在性闸门必须盖住 git 和 dir 两条分支。
    // 原先只有 git 分支查 volumeAccessibleEx，dir 分支直接进 collectDirFacts，
    // 而 collectActivity 对不存在的路径安静返回 0 个文件，
    // 于是报出「非 git 项目 · 0 个文件」——把「目录没了」谎报成「目录是空的」。
    let missing = "/nonexistent/dg_path_gate_${nowMillis()}"
    var gitThrew = false
    try {
        collectFacts(missing, "git", Config.defaults(), 10, false)
    } catch (e: DgError) {
        gitThrew = true
    }
    @Assert(gitThrew)

    var dirThrew = false
    try {
        collectFacts(missing, "dir", Config.defaults(), 10, false)
    } catch (e: DgError) {
        dirThrew = true
    }
    @Assert(dirThrew)

    // 对照组：真实存在的非 git 目录必须照常工作，不能被闸门误伤
    let tmpBase = "/tmp/dg_facts_gate_${nowMillis()}"
    ensureDir(tmpBase)
    @Assert(collectFacts(tmpBase, "dir", Config.defaults(), 10, false).kind == "dir")
    removePathIfExists(tmpBase)
}

// ------------------------------ #199：采集层的「读不到」 ------------------------------

/// 读不出来的子树必须**计数 + 留路径**，而不是被当成一棵空树。
///
/// 原实现用 `listDir`（吞异常返回空数组）：`chmod 000` 的子目录贡献 0 个文件，
/// `fileCount` 悄悄变小，头line 照报「N 个文件」——
/// 把「没看到」说成「没有」，而 headline 是状态列表与 README 托管区共用的第一行。
@Test
func testCollectActivityCountsUnreadableSubtree(): Unit {
    let base = "/tmp/deepgit-act-unreadable-${nowMillis()}"
    ensureDir(base + "/open")
    ensureDir(base + "/closed")
    writeFileAtomic(base + "/a.txt", "a")
    writeFileAtomic(base + "/open/b.txt", "b")
    writeFileAtomic(base + "/closed/hidden.txt", "h")   // 读不到它，但文件确实存在
    let ch = execCapture("chmod", ["000", base + "/closed"], None, 8000)
    @Assert(ch.ok())

    let a = collectActivity(base, 12000, 6)
    // 必须先恢复权限，否则 removePathIfExists 删不掉
    execCapture("chmod", ["755", base + "/closed"], None, 8000)

    // 看得见的两个文件照常数到（接缝没把正常路径弄坏）
    @Assert(a.fileCount == 2)
    // 读不出来的子树必须被点名
    @Assert(a.unreadable == 1)
    var named = false
    for (s in a.unreadableSamples) {
        if (s.contains("closed")) {
            named = true
        }
    }
    @Assert(named)
    // toJson 恒发这两个键：缺席就等于默认 0，等于默认「全都看到了」
    let j = a.toJson()
    @Assert(Json.intAt(j, "unreadable", -1) == 1)
    @Assert(Json.has(j, "unreadableSamples"))
    removePathIfExists(base)
}

/// 全都读得动时 `unreadable` 必须是 0 且样本为空 ——
/// 否则「一切正常」和「有 5 处读不到」在下游无法区分。
@Test
func testCollectActivityUnreadableIsZeroWhenAllReadable(): Unit {
    let base = "/tmp/deepgit-act-clean-${nowMillis()}"
    ensureDir(base + "/sub")
    writeFileAtomic(base + "/a.txt", "a")
    writeFileAtomic(base + "/sub/b.txt", "b")
    let a = collectActivity(base, 12000, 6)
    @Assert(a.unreadable == 0)
    @Assert(a.unreadableSamples.isEmpty())
    @Assert(a.fileCount == 2)
    @Assert(Json.intAt(a.toJson(), "unreadable", -1) == 0)
    removePathIfExists(base)
}

/// ActivitySnapshot 的旧构造签名必须保留：它有别的调用方，
/// 而「新增字段有默认值」正是 #197/#199 这类加字段时的兼容性护栏。
@Test
func testActivitySnapshotLegacyInitStillMeansZeroUnreadable(): Unit {
    let a = ActivitySnapshot(3, 100, ArrayList<(String, String, Int64)>(), ArrayList<(String, Int64)>(), "")
    @Assert(a.unreadable == 0)
    @Assert(a.unreadableSamples.isEmpty())
    @Assert(entryKindLabel(EntryKind.Unreadable) == "unreadable")
}

/// K3 回归：撞采集上限（maxFiles / maxDepth）必须置位 + 恒发，不许把上限当总数。
///
/// 触顶是第三种「覆盖不完整」成因（我们**主动停了**），与 unreadable
/// （我们**看不到**）成因不同、危害同构：12000 个文件的仓库在 README
/// 托管区与 headline 里就写着「12000 个文件」，像真的一样。
/// 上限做成可注入（collectDirFacts 的 maxFiles/maxDepth），小上限就能真实触顶，
/// 不必真造一万个文件 —— 触顶路径本身必须被测到，而不是只测默认参数。
@Test
func testCollectActivityDisclosesCapHits(): Unit {
    let base = "/tmp/deepgit-act-caps-${nowMillis()}"
    ensureDir(base + "/d1")
    ensureDir(base + "/d2")
    writeFileAtomic(base + "/a.txt", "a")
    writeFileAtomic(base + "/b.txt", "b")
    writeFileAtomic(base + "/c.txt", "c")
    writeFileAtomic(base + "/d1/hidden.txt", "h")   // 撞上限时这两棵子树没被走到
    writeFileAtomic(base + "/d2/hidden.txt", "h")
    try {
    // fileCap：maxFiles=2 —— 根目录的 3 个文件全数到（内层循环不截断），
    // 但退出时队列里还有 d1/d2 没走：fileCount 是下界
    let capped = collectActivity(base, 2, 6)
    @Assert(capped.fileCount == 3)
    @Assert(capped.fileCapHit)
    @Assert(!capped.depthCapHit)

    // depthCap：maxDepth=0 —— d1/d2 作为目录条目被跳过，整棵子树没看
    let shallow = collectActivity(base, 12000, 0)
    @Assert(shallow.fileCount == 3)
    @Assert(shallow.depthCapHit)
    @Assert(!shallow.fileCapHit)

    // 对照：上限宽裕时两个标志都必须是 false ——「看全了」也是事实，不许谎报
    let full = collectActivity(base, 12000, 6)
    @Assert(full.fileCount == 5)
    @Assert(!full.fileCapHit)
    @Assert(!full.depthCapHit)

    // toJson 恒发两键（含 false）：默认值取反再判，缺席就红（同 git.cj 的判例）
    let jCapped = capped.toJson()
    @Assert(Json.boolAt(jCapped, "fileCapHit", false))
    @Assert(!Json.boolAt(jCapped, "depthCapHit", true))
    let jFull = full.toJson()
    @Assert(!Json.boolAt(jFull, "fileCapHit", true))
    @Assert(!Json.boolAt(jFull, "depthCapHit", true))

    // 注入点必须真的把上限传到采集层（不是只改 collectActivity 的调用方默认值）
    let facts = collectDirFacts(base, Config.defaults(), maxFiles: 2)
    match (facts.activity) {
        case Some(a) => @Assert(a.fileCapHit)
        case None => @Assert(false)   // dir 项目的 activity 不许缺席
    }
    } finally {
        removePathIfExists(base)
    }
}


/// #197 判据在 collectActivity 的落地：边界目录为空 → 不置位；
/// 边界目录有会被采集的条目 → 置位；读不到 → 保持置位。
///
/// 原实现 depth/fileCap 一见边界就置位，未确认被跳过的子树非空 ——
/// scanner 修 #197 时已确立「边界处常常是叶子目录，一见边界就置位 = 谎报没看完」。
/// 危害方向与 scanner 相同：空目录撞界也报 depthCapHit=true，
/// 下游披露「文件数是下界、可能没看完」，读者从此不信任何一次「看全了」。
@Test
func testCollectActivityDoesNotFlagCapWhenBoundaryDirsAreEmpty(): Unit {
    let base = "/tmp/deepgit-act-emptyb-${nowMillis()}"
    let baseSkip = "/tmp/deepgit-act-emptyb-sk-${nowMillis()}"
    let baseClosed = "/tmp/deepgit-act-emptyb-cl-${nowMillis()}"
    try {
    ensureDir(base + "/e1")
    ensureDir(base + "/e2")
    writeFileAtomic(base + "/a.txt", "a")
    writeFileAtomic(base + "/b.txt", "b")

    // 空边界：e1/e2 都是空目录 ——
    //   depthCap：maxDepth=0，e1/e2 作为目录条目撞界，但确认后无会被采集的条目；
    //   fileCap ：maxFiles=1，根目录 2 个文件触顶退出，队列剩 e1/e2，同样确认无内容。
    // 两个方向都是「真的看全了」，不许谎报没看完。
    let empty = collectActivity(base, 1, 0)
    @Assert(empty.fileCount == 2)
    @Assert(!empty.depthCapHit)
    @Assert(!empty.fileCapHit)

    // 边界目录有文件 → 必须置位（同测试自带正例，负例才有判别力）。
    // 两个轴分开打：maxDepth=0 时 e1/e2 在根部就撞深度界、根本不进队，
    // 文件轴的「队列剩余确认」没有输入，不会置位 —— 深度轴用 maxDepth=0 打；
    // 文件轴用 maxDepth=1（e1/e2 进队后触顶退出，队列剩余里有 h.txt）。
    writeFileAtomic(base + "/e1/h.txt", "h")
    let filledDepth = collectActivity(base, 1, 0)
    @Assert(filledDepth.depthCapHit)
    @Assert(!filledDepth.fileCapHit)   // e1/e2 触顶后根本没出队，文件轴没有输入
    let filledFile = collectActivity(base, 1, 1)
    @Assert(filledFile.fileCapHit)
    @Assert(!filledFile.depthCapHit)   // e1 触顶后根本没出队（循环在此之前退出），深度轴没有输入

    // 边界目录只装点开头 / skip 名单里的东西 → 对采集口径而言是空的，不置位。
    // （确认逻辑必须与主循环同口径：主循环本来就跳过这些，它们不算「没看到」）
    ensureDir(baseSkip + "/only/.git")
    writeFileAtomic(baseSkip + "/only/.git/HEAD", "ref")
    writeFileAtomic(baseSkip + "/a.txt", "a")
    let skipped = collectActivity(baseSkip, 1, 0)
    @Assert(!skipped.depthCapHit)
    @Assert(!skipped.fileCapHit)

    // 读不到的边界目录 → 保持置位：读不出来 = 可能有没看过的文件，
    // 宁可说「可能没看完」（对齐 scanner 的 hasUnexploredSubdir 取向）。
    ensureDir(baseClosed + "/closed")
    writeFileAtomic(baseClosed + "/a.txt", "a")
    let ch = execCapture("chmod", ["000", baseClosed + "/closed"], None, 8000)
    @Assert(ch.ok())
    let unreadable = collectActivity(baseClosed, 12000, 0)
    // 先恢复权限再断言，否则清理会失败
    execCapture("chmod", ["755", baseClosed + "/closed"], None, 8000)
    @Assert(unreadable.depthCapHit)
    } finally {
        removePathIfExists(base)
        removePathIfExists(baseSkip)
        removePathIfExists(baseClosed)
    }
}
