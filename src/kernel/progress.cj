// 进度模型：分支状态判定、delta 计算、状态标签。
package moongit.kernel

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

/// 分支状态：
/// - merged：已合入默认分支
/// - active：3 天内有提交
/// - idle：14 天内
/// - stale：超过 14 天
public func computeBranchStatus(lastCommitAt: String, merged: Bool): String {
    if (merged) {
        return "merged"
    }
    let d = daysSince(lastCommitAt)
    if (d == Float64.Inf) {
        return "unknown"
    }
    // 时间戳晚于当前时间 => 时钟不可信（CI/构建机超前、虚拟机快照恢复后时钟错误、
    // git commit --date 手误、release 提交预置到下个版本日期）。
    // 旧实现让负数落进 `d < 3.0` → "active"，于是 2030 年的提交显示
    // 「刚刚 / 活跃」并会这样持续 3 年多。负的 staleDays 与「活跃」自相矛盾。
    // 超出一天容差就承认时间不可信，而不是替它编一个「刚刚」。
    if (d < -1.0) {
        return "unknown"
    }
    if (d < 3.0) {
        return "active"
    }
    if (d < 14.0) {
        return "idle"
    }
    return "stale"
}

public func statusLabel(status: String, lang: String): String {
    let zh = !isEnglish(lang)
    match (status) {
        case "active" => return if (zh) { "活跃" } else { "active" }
        case "idle" => return if (zh) { "闲置" } else { "idle" }
        case "stale" => return if (zh) { "停滞" } else { "stale" }
        case "merged" => return if (zh) { "已合并" } else { "merged" }
        case "empty" => return if (zh) { "空仓库" } else { "empty" }
        case _ => return if (zh) { "未知" } else { "unknown" }
    }
}

/// 单个分支自上次记录以来的增量
/// 首次建立基线时单个分支最多记录的提交数
public let MAX_BASELINE_COMMITS: Int64 = 30

public class BranchDelta {
    public let branch: String
    public let head: String
    public let from: String  // 空串表示无追踪基线
    public let reset: Bool
    public let commits: ArrayList<CommitInfo>
    public let stats: DiffStats
    /// 首次建立基线时提交数被钳到 30（本文件 branchDelta 里的 MAX_BASELINE_COMMITS）。
    /// 为 true 时 count() 只是「已记录数」，不是该分支的提交总数。
    public let truncated: Bool

    public init(branch: String, head: String, from: String, reset: Bool, commits: ArrayList<CommitInfo>, stats: DiffStats,
                truncated!: Bool = false) {
        this.branch = branch
        this.head = head
        this.from = from
        this.reset = reset
        this.commits = commits
        this.stats = stats
        this.truncated = truncated
    }

    public func count(): Int64 {
        return this.commits.size
    }
}

/// 计算分支增量。若基线与当前 head 无祖先关系（rebase/force-push），
/// 则回退到「最近提交」模式并标记 reset，保持诚实。
public func branchDelta(root: String, branch: String, tracked: String, maxCommits: Int64, maxFiles: Int64): Option<BranchDelta> {
    match (revParse(root, branch)) {
        case None => return None
        case Some(head) =>
            var from = tracked
            var reset = false
            if (!from.isEmpty()) {
                // ⚠️ 这两种情况后果完全不同，不能合成一个标志。
                //
                // 原来写的是 `!isAncestor(from, head) || from == head`，
                // 于是「本次没有新提交」（from == head，每次幂等重跑都成立）
                // 和「历史被改写」（rebase / force-push / 强制回退，
                // 已记录的 head 不再是新 head 的祖先）被一起打成 reset=true。
                //
                // 后果实测：连跑两次 `deep`，第二次的摘要就会多出
                //   ⚠ 检测到历史改写（rebase / force-push / 强制回退），基线已重建
                // —— 而根本什么都没改写，README/AGENTS 因此永远无法幂等。
                //
                // 这也解释了为什么这个字段一直没人消费：一个「有一半时间是 true」
                // 的信号没有信息量。分开之后 reset 只在真正的历史改写时为真。
                if (from == head) {
                    from = ""   // 没有新提交：照样从头列基线，但**不是**历史改写
                } else if (!isAncestor(root, from, head)) {
                    from = ""
                    reset = true
                }
            }
            var commits: ArrayList<CommitInfo>
            var stats: DiffStats
            var wasTruncated = false
            if (from.isEmpty()) {
                let limit = if (maxCommits < MAX_BASELINE_COMMITS) { maxCommits } else { MAX_BASELINE_COMMITS }
                commits = logCommits(root, limit, head, 0)
                // 命中上限 ≠ 真的只有这么多提交。用 hasMoreCommits 判一次，
                // 免得「恰好 30 个提交」的仓库被误标成截断。
                wasTruncated = commits.size >= MAX_BASELINE_COMMITS && hasMoreCommits(root, MAX_BASELINE_COMMITS)
                stats = DiffStats(0, 0, 0, ArrayList<FileStat>())
            } else {
                commits = logRange(root, from, head, maxCommits)
                wasTruncated = commits.size >= maxCommits && maxCommits > 0
                stats = diffStats(root, from, head, maxFiles)
            }
            return Some(BranchDelta(branch, head, from, reset, commits, stats, truncated: wasTruncated))
    }
}

/// 项目一句话状态
/// 「N 个文件」这句话的**唯一口径**。
///
/// `fileCount` 只能数它**看到**的文件。有读不到的地方（stat 失败 / 子目录读不出来）时，
/// 它是**下界**而不是总数 —— 不加限定词就等于把「没看到」说成「没有」。
///
/// 三个出口共用这一个函数：headline（状态列表 / 菜单栏 / MCP / AI 上下文）、
/// `overallLine`（报告总体行）、`renderFacts`（README 托管区的工程规模行）。
/// 各写一遍必然漂移，而 README 那一处是**写进用户仓库的持久文件** —— 谎报会跟着仓库活很久。
public func fileCountLabel(a: ActivitySnapshot, zh: Bool): String {
    // 「没看全」有三种成因（K3 补齐后两种），任一命中 fileCount 都是下界：
    //   unreadable  —— 有地方读不到（我们**看不到**）
    //   fileCapHit  —— 文件数撞采集上限（我们**主动停了**）
    //   depthCapHit —— 目录深度撞采集上限（我们**主动不下了**）
    // 成因可以叠加，各自一句话，不许合并成一个标志 ——
    // 用户据此做的处置完全不同（放权/挂载 vs 无需处置、只是样本）。
    let notes = ArrayList<String>()
    if (a.fileCapHit) {
        notes.add(if (zh) { "文件数达采集上限" } else { "file cap reached" })
    }
    if (a.depthCapHit) {
        notes.add(if (zh) { "目录深度达采集上限" } else { "depth cap reached" })
    }
    if (a.unreadable > 0) {
        notes.add(if (zh) { "另有 ${a.unreadable} 处读不到" } else { "${a.unreadable} unreadable" })
    }
    if (notes.isEmpty()) {
        return if (zh) { "${a.fileCount} 个文件" } else { "${a.fileCount} files" }
    }
    let joined = joinStrings(notes, if (zh) { "，" } else { "; " })
    return if (zh) { "至少 ${a.fileCount} 个文件（${joined}）" }
           else { "at least ${a.fileCount} files (${joined})" }
}

/// 读不到的具体路径（一行，用户知道该去放权/挂载哪）。没有读不到的地方就返回空串。
public func unreadablePathsLine(a: ActivitySnapshot, zh: Bool): String {
    if (a.unreadable <= 0 || a.unreadableSamples.isEmpty()) {
        return ""
    }
    let paths = joinStrings(a.unreadableSamples, "、")
    let more = if (a.unreadable > a.unreadableSamples.size) {
        if (zh) { " 等 ${a.unreadable} 处" } else { " and ${a.unreadable - a.unreadableSamples.size} more" }
    } else {
        ""
    }
    return if (zh) { "读不到的路径：${paths}${more}" } else { "unreadable paths: ${paths}${more}" }
}

public func computeHeadline(facts: RepoFacts, progress: JsonValue, lang: String): String {
    let zh = !isEnglish(lang)
    let parts = ArrayList<String>()
    if (facts.kind != "git") {
        match (facts.activity) {
            case Some(a) =>
                if (!a.newestMtime.isEmpty()) {
                    let d = Int64(daysSince(a.newestMtime))
                    if (d <= 0) {
                        parts.add(if (zh) { "今日有文件改动" } else { "changed today" })
                    } else {
                        parts.add(if (zh) { "${d} 天内有改动" } else { "changed ${d}d ago" })
                    }
                }
                // ⚠️ 有读不到的地方时，fileCount 只是**下界**。
                // 原先无条件报「N 个文件」，等于把「没看到」说成「没有」——
                // 而 headline 是状态列表、报告、README 托管区和 AI 上下文共用的
                // 第一行，谎就谎在最显眼的位置。口径见 fileCountLabel。
                parts.add("非 git 项目 · " + fileCountLabel(a, zh))
            case None => ()
        }
        return joinStrings(parts, " · ")
    }

    // 待记录提交数
    var pending: Int64 = 0
    for ((_, rec) in progressBranches(progress)) {
        pending += Json.intAt(rec, "pendingCommits", 0)
    }
    if (pending > 0) {
        parts.add(if (zh) { "${pending} 个待记录提交" } else { "${pending} pending commits" })
    }
    match (progressBranch(progress, facts.currentBranch)) {
        case Some(rec) =>
            let st = Json.strAt(rec, "status", "")
            if (!st.isEmpty()) {
                parts.add("${facts.currentBranch}: ${statusLabel(st, lang)}")
            }
        case None => ()
    }
    let dirtyCount = userDirtyCount(facts)
    if (dirtyCount > 0) {
        parts.add(if (zh) { "${dirtyCount} 处未提交" } else { "${dirtyCount} uncommitted" })
    }
    if (parts.size == 0) {
        parts.add(if (zh) { "暂无新变化" } else { "no changes" })
    }
    return joinStrings(parts, " · ")
}

// ------------------------------ 测试 ------------------------------

@Test
func testComputeBranchStatus(): Unit {
    @Assert(computeBranchStatus(nowIso(), false) == "active")
    @Assert(computeBranchStatus(nowIso(), true) == "merged")
    @Assert(computeBranchStatus("2020-01-01T00:00:00+08:00", false) == "stale")
    @Assert(computeBranchStatus("bad", false) == "unknown")
}

@Test
func testStatusLabel(): Unit {
    @Assert(statusLabel("active", "zh") == "活跃")
    @Assert(statusLabel("stale", "en") == "stale")
    @Assert(statusLabel("merged", "zh") == "已合并")
}

@Test
func testBranchDeltaOnRealRepo(): Unit {
    let base = "/tmp/deepgit-delta-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "first commit"], false)

    // 首次记录（无基线）：不是 reset，取最近提交
    let d0 = branchDelta(base, "main", "", 50, 50)
    @Assert(d0.isSome())
    @Assert(!d0.getOrThrow().reset)
    @Assert(d0.getOrThrow().from.isEmpty())
    @Assert(d0.getOrThrow().count() == 1)

    // 有基线：增量模式
    let head0 = d0.getOrThrow().head
    writeFileAtomic(base + "/a.txt", "2")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "second commit"], false)
    let d1 = branchDelta(base, "main", head0, 50, 50)
    @Assert(d1.isSome())
    @Assert(!d1.getOrThrow().reset)
    @Assert(d1.getOrThrow().count() == 1)
    @Assert(d1.getOrThrow().stats.files == 1)

    // 基线失效（模拟 force-push / rebase）：应标记 reset 并回退
    let staleBase = d1.getOrThrow().head
    gitRun(base, ["reset", "--hard", "HEAD~1"], false)
    writeFileAtomic(base + "/a.txt", "3")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "rewritten commit"], false)
    let d2 = branchDelta(base, "main", staleBase, 50, 50)
    @Assert(d2.isSome())
    @Assert(d2.getOrThrow().reset)
    @Assert(d2.getOrThrow().from.isEmpty())

    // 不存在的分支
    @Assert(branchDelta(base, "no-such-branch", "", 50, 50).isNone())
    removePathIfExists(base)
}

@Test
func testComputeHeadlineNonGit(): Unit {
    let tmp = "/tmp/deepgit-hl-${nowMillis()}"
    ensureDir(tmp)
    writeFileAtomic(tmp + "/x.txt", "x")
    let facts = collectFacts(tmp, "dir", Config.defaults(), 10, false)
    let headline = computeHeadline(facts, Json.obj(), "zh")
    @Assert(headline.contains("非 git"))
    removePathIfExists(tmp)
}

@Test
func testComputeHeadlineGitNoBranchesTracked(): Unit {
    let base = "/tmp/deepgit-hl2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    let facts = collectFacts(base, "git", Config.defaults(), 10, false)
    let headline = computeHeadline(facts, Json.obj(), "zh")
    @Assert(headline.size > 0)
    removePathIfExists(base)
}

@Test
func testFutureTimestampIsNotReportedAsActive(): Unit {
    // 时钟不可信的场景现实里不少：CI/构建机时钟超前、虚拟机快照恢复后时钟错误、
    // git commit --date 手误、release 提交预置到下个版本日期。
    // 旧实现让负的 daysSince 落进 `d < 3.0` → "active"，
    // 于是 2030 年的提交显示「刚刚 / 活跃」并会这样持续 3 年多，
    // 而同一份 JSON 里 staleDays 是负数，与「活跃」自相矛盾。
    @Assert(computeBranchStatus("2030-01-01T00:00:00+08:00", false) == "unknown")
    // 正常时间戳不能被误伤
    @Assert(computeBranchStatus("2020-01-01T00:00:00+08:00", false) == "stale")
    // merged 优先于一切
    @Assert(computeBranchStatus("2030-01-01T00:00:00+08:00", true) == "merged")
    // 一天内的轻微偏差容忍（毫秒级、时区换算都可能造成），仍按「近期」处理
    @Assert(computeBranchStatus(nowIso(), false) != "unknown")
    // 不可解析的输入本来就是 unknown
    @Assert(computeBranchStatus("bad-date", false) == "unknown")
}

@Test
func testTimeAgoFlagsFutureTimestamps(): Unit {
    let future = timeAgo("2030-01-01T00:00:00+08:00", "zh")
    @Assert(future.contains("时间异常"))
    @Assert(!future.contains("刚刚"))
    @Assert(timeAgo("2030-01-01T00:00:00+08:00", "en").contains("clock skew"))
    // 正常值不受影响
    @Assert(timeAgo("2020-01-01T00:00:00+08:00", "zh").contains("年前"))
    @Assert(timeAgo(nowIso(), "zh") == "刚刚")
    // 不可解析仍然是 "-"
    @Assert(timeAgo("bad-date", "zh") == "-")
}

@Test
func testResetFlagDistinguishesRewriteFromNoNewCommits(): Unit {
    // ⚠️ reset 曾经把两种完全不同的情况混为一谈：
    //   `!isAncestor(from, head) || from == head`
    // 「本次没有新提交」（from == head，每次幂等重跑都成立）
    // 与「历史被改写」（已记录的 head 不再是新 head 的祖先）被一起打成 reset=true。
    //
    // 后果实测：连跑两次 deep，第二次的摘要就多出
    //   ⚠ 检测到历史改写（rebase / force-push / 强制回退），基线已重建
    // —— 而什么都没改写，README/AGENTS 因此永远无法幂等。
    //
    // 这也解释了这个字段为什么一直没人消费：一半时间是 true 的信号没有信息量。
    let base = "/tmp/deepgit-resetflag-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "a")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: a"], false)
    let first = branchDelta(base, "main", "", 200, 200)
    @Assert(first.isSome())
    @Assert(!first.getOrThrow().reset)     // 首次建基线不是改写

    let head = first.getOrThrow().head

    // 情况 A：没有新提交 → 不是改写
    let noNew = branchDelta(base, "main", head, 200, 200)
    @Assert(noNew.isSome())
    @Assert(!noNew.getOrThrow().reset)
    @Assert(noNew.getOrThrow().from.isEmpty())   // 但仍按基线重列

    // 情况 B：新提交 → 不是改写
    writeFileAtomic(base + "/b.txt", "b")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: b"], false)
    let withNew = branchDelta(base, "main", head, 200, 200)
    @Assert(withNew.isSome())
    @Assert(!withNew.getOrThrow().reset)
    @Assert(withNew.getOrThrow().count() == 1)

    // 情况 C：历史被改写 → 这才是 reset。
    //
    // ⚠️ 场景必须让**已记录的 head 本身**被踢出历史，否则不算改写：
    // 先记到 commit(b)，再 reset --hard HEAD~2 回到 commit(a)、提交 c，
    // 此时 commit(b) 仍是新历史的一部分吗？不是 —— 它已被丢弃，
    // isAncestor(b, c) 为假，才是真正的改写。
    // （写成 reset HEAD~1 时新提交的父节点恰好就是被记的那条，
    //   isAncestor 为真、reset 为假，那是正确的判定，不是 bug。）
    let head2 = withNew.getOrThrow().head    // = commit(b)
    writeFileAtomic(base + "/c.txt", "c")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: c"], false)
    gitRun(base, ["reset", "-q", "--hard", "HEAD~2"], false)   // 丢掉 b 和 c
    writeFileAtomic(base + "/d.txt", "d")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: d"], false)
    let rewritten = branchDelta(base, "main", head2, 200, 200)
    @Assert(rewritten.isSome())
    @Assert(rewritten.getOrThrow().reset)

    removePathIfExists(base)
}

// ------------------------------ #199：「N 个文件」的唯一口径 ------------------------------

/// 有读不到的地方时，fileCount 是**下界**，文案必须带限定词。
///
/// 三个出口（headline / overallLine / README 托管区的规模行）共用 `fileCountLabel`，
/// 各写一遍必然漂移；而 README 那一处是写进用户仓库的**持久文件**，谎报会跟着仓库活很久。
@Test
func testFileCountLabelIsLowerBoundWhenUnreadable(): Unit {
    let samples = ArrayList<String>(["/a/closed", "/b/DifferentialPrivacy"])
    let dirty = ActivitySnapshot(12058, 0, ArrayList<(String, String, Int64)>(), ArrayList<(String, Int64)>(), "", 19, samples)
    let clean = ActivitySnapshot(12058, 0, ArrayList<(String, String, Int64)>(), ArrayList<(String, Int64)>(), "", 0, ArrayList<String>())

    let zhDirty = fileCountLabel(dirty, true)
    let enDirty = fileCountLabel(dirty, false)
    let zhClean = fileCountLabel(clean, true)

    // 读得到的地方照常给总数，不能一律改成「至少」——那又变成另一种撒谎
    @Assert(zhClean == "12058 个文件")
    // 下界必须写成「至少」，且读到的处数要一起出现
    @Assert(zhDirty.contains("至少"))
    @Assert(zhDirty.contains("12058"))
    @Assert(zhDirty.contains("19"))
    @Assert(enDirty.contains("at least"))
    @Assert(enDirty.contains("unreadable"))
    // 绝不能**以**「12058 个文件」开头（那才是无限定词地说成了总数）。
    // ⚠️ 不能断言 `!zhDirty.contains("12058 个文件")` ——
    // 「至少 12058 个文件」本身就含这个子串，第一版就是这么把自己写红的。
    @Assert(!zhDirty.startsWith("12058 个文件"))

    // 路径清单：用户要动手就得知道是哪几条
    @Assert(unreadablePathsLine(dirty, true).contains("/a/closed"))
    @Assert(unreadablePathsLine(dirty, true).contains("/b/DifferentialPrivacy"))
    // 一处都没读不到时不许凭空造一行
    @Assert(unreadablePathsLine(clean, true).isEmpty())
}

/// K3 回归：撞采集上限（fileCapHit / depthCapHit）时，fileCount 同样是下界，
/// label 必须带「至少」限定 —— 与 unreadable 的既有措辞同一套。
///
/// 原来只有 unreadable 进了 label 的判据：触顶（我们**主动停了**）被漏掉，
/// 12000 这个采集上限就被当成仓库文件总数写出去。
@Test
func testFileCountLabelIsLowerBoundWhenCapHit(): Unit {
    let empty5 = ArrayList<(String, String, Int64)>()
    let emptyD = ArrayList<(String, Int64)>()
    let fileCapped = ActivitySnapshot(12000, 0, empty5, emptyD, "", 0, ArrayList<String>(),
        fileCapHit: true, depthCapHit: false)
    let depthCapped = ActivitySnapshot(6, 0, empty5, emptyD, "", 0, ArrayList<String>(),
        fileCapHit: false, depthCapHit: true)
    let both = ActivitySnapshot(12000, 0, empty5, emptyD, "", 3, ArrayList<String>(),
        fileCapHit: true, depthCapHit: true)

    let zhFile = fileCountLabel(fileCapped, true)
    @Assert(zhFile.contains("至少"))
    @Assert(zhFile.contains("12000"))
    @Assert(zhFile.contains("文件数达采集上限"))
    @Assert(!zhFile.contains("目录深度"))          // 没撞深度却写深度 = 谎报成因
    @Assert(!zhFile.contains("读不到"))            // unreadable=0 不许凭空造

    let zhDepth = fileCountLabel(depthCapped, true)
    @Assert(zhDepth.contains("至少"))
    @Assert(zhDepth.contains("目录深度达采集上限"))
    @Assert(!zhDepth.contains("文件数达"))

    // 两种上限 + 读不到叠加：三个成因各自出现，不许互相吞并
    let zhBoth = fileCountLabel(both, true)
    @Assert(zhBoth.contains("文件数达采集上限"))
    @Assert(zhBoth.contains("目录深度达采集上限"))
    @Assert(zhBoth.contains("3 处读不到"))

    // 英文侧同判（headline 的 en 出口共用这一个函数）
    @Assert(fileCountLabel(fileCapped, false).contains("at least"))
    @Assert(fileCountLabel(fileCapped, false).contains("file cap reached"))
    @Assert(fileCountLabel(depthCapped, false).contains("depth cap reached"))
}

/// 三个出口必须共用同一个口径函数，不许各自拼一遍字符串。
///
/// ⚠️ 这里踩过一个和「lint 前必须剥注释」同类的坑：**判据会匹配到自己**。
/// ① needle 字面量本身就在源码里 —— 用拼接构造，源码里就永远不出现完整的 needle；
/// ② 唯一合法的实现 `fileCountLabel` 自己就含 needle —— 必须把它整段排除后再数。
/// 少了任何一步，这个 lint 会把自己判成「第二份实现」而恒红（第一版就是这么栽的）。
///
/// 判据是**计数**不是存在性：接缝外出现次数必须恰好为 0，
/// 而「恰好 0」对新增的第二份实现同样敏感。
@Test
func __lintAllFileCountOutletsShareOneLabel(): Unit {
    // 拼接构造 needle：源码里不会出现完整的 needle，lint 匹配不到自己
    let nZh = "fileCount}" + " 个文" + "件"
    let nEn = "fileCount}" + " file" + "s"

    // ⚠️ 第三次自匹配：needle 自己也必须拼接，否则 `func fileCountLabel(`
    // 这个字面量会让 `defined` 数到自己头上（第一版就这么恒红）。
    let needle = "func fileCount" + "Label("
    var outside = 0
    var defined = 0
    for (f in ["src/kernel/progress.cj", "src/kernel/render.cj"]) {
        let raw = readFileTextChecked(f).getOrThrow()
        let sb = StringBuilder()
        var blk = CjStripState.Normal
        for (r in raw.split("\n")) {
            let (l, nb) = stripCjCommentEx(r, blk)
            blk = nb
            sb.append(l)
            sb.append("\n")
        }
        let code = sb.toString()
        // 唯一合法的实现：数它被定义了几次
        var at = 0
        while (true) {
            let k = code.indexOf(needle, at)
            match (k) {
                case None => break
                case Some(i) =>
                    defined += 1
                    at = i + 1
            }
        }
        // 把 fileCountLabel 的函数体整段挖掉，只在剩下的部分里数。
        // render.cj 里没有这个函数（只有调用），那一份不挖。
        let start = code.indexOf(needle)
        if (start.isNone()) {
            // 这个文件只是调用方：直接整份数
            outside += countOccurrences(code, nZh)
            outside += countOccurrences(code, nEn)
            continue
        }
        let cut = match (start) {
            case Some(i) =>
                let rest = code[i..]
                let e = rest.indexOf("\n}")
                if (e.isSome()) { i + e.getOrThrow() + 2 } else { code.size }
            case None => 0
        }
        let i0 = start.getOrThrow()
        let body = code[i0..cut]
        let head = code[0..i0]
        let scanned = head + code[cut..]
        outside += countOccurrences(scanned, nZh)
        outside += countOccurrences(scanned, nEn)
        @Assert(!body.isEmpty())
    }
    // 接缝恰好一份
    @Assert(defined == 1)
    // 接缝之外一份都没有
    @Assert(outside == 0)

    // 三个出口都得真的调用它（收口不是「定义了就完事」）
    let prog = readFileTextChecked("src/kernel/progress.cj").getOrThrow()
    let rend = readFileTextChecked("src/kernel/render.cj").getOrThrow()
    @Assert(prog.contains("fileCountLabel(a, zh)"))
    // overallLine 与 renderFacts 各一处，加起来两处
    @Assert(countOccurrences(rend, "fileCountLabel(a, zh)") == 2)
    @Assert(prog.contains("unreadablePathsLine(a, zh)"))
}

/// 数子串出现次数。仓颉没有内置的 count。
public func countOccurrences(hay: String, needle: String): Int64 {
    if (needle.isEmpty()) {
        return 0
    }
    var n: Int64 = 0
    var at = 0
    while (true) {
        let k = hay.indexOf(needle, at)
        match (k) {
            case None => break
            case Some(i) =>
                n += 1
                at = i + 1
        }
    }
    return n
}
