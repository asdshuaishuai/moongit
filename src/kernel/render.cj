// 确定性 Markdown 渲染：事实 + 进度存储 → 稳定骨架，AI 只提供叙述内容。
package moongit.kernel

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

/// AI/规则给出的分支叙述
public class BranchNarrative {
    public let summary: String
    public let highlights: ArrayList<String>
    public let nextSteps: ArrayList<String>
    public let status: String

    public init(summary: String, highlights: ArrayList<String>, nextSteps: ArrayList<String>, status: String) {
        this.summary = summary
        this.highlights = highlights
        this.nextSteps = nextSteps
        this.status = status
    }
}

public func branchNarrativesFromJson(j: JsonValue): HashMap<String, BranchNarrative> {
    let out = HashMap<String, BranchNarrative>()
    match (Json.asObj(j)) {
        case Some(m) =>
            for ((branch, v) in m) {
                out[branch] = BranchNarrative(
                    Json.strAt(v, "summary", ""),
                    Json.strArrAt(v, "highlights"),
                    Json.strArrAt(v, "nextSteps"),
                    Json.strAt(v, "status", ""),
                )
            }
        case None => ()
    }
    return out
}

/// moonGit 自己写的文档不算「用户未提交改动」，否则每轮更新会自引用抖动。
public let DEEPGIT_MANAGED_DOCS = ["README.md", "AGENTS.md", "AGENT.md", "CLAUDE.md"]

public func isManagedDoc(file: String): Bool {
    let base = basename(file)
    for (d in DEEPGIT_MANAGED_DOCS) {
        if (base.toAsciiLower() == d.toAsciiLower()) {
            return true
        }
    }
    return false
}

/// 用户视角的未提交改动（排除 moonGit 托管文档）
public func userDirtyCount(facts: RepoFacts): Int64 {
    var n: Int64 = 0
    for (f in facts.dirty.files) {
        if (!isManagedDoc(f)) {
            n += 1
        }
    }
    return n
}

/// 分支数口径披露：进度库里的 N 个 ≠ 仓库里的 N 个。
///
/// 「上限当全量」这一族已经栽了 15 次，这里是第 16 次。
/// 候选分支集受 `config.maxShallowBranches`（默认 6）限制，所以
/// `progress.branches` 天然是**样本**。把它直接渲染成「追踪 7 个分支」
/// 而不给分母，读者只会理解成「这仓库就 7 个分支」——
/// 实测 16 个分支的仓库正是如此。
///
/// 抽成纯函数是为了能单独测：这种文案一旦内联在渲染的 if 里，
/// 改错了不会有任何测试变红。
///
/// `repoCount` 为 `None` 时返回空串 —— 读不出来**不等于**没有，
/// 这时候闭嘴比编一句「仓库共 0 个分支」诚实。
public func branchScopeNote(tracked: Int64, repoCount: Option<Int64>, zh: Bool): String {
    match (repoCount) {
        case Some(n) =>
            if (n == tracked) {
                return ""
            }
            if (n > tracked) {
                return if (zh) { "（仓库共 ${n} 个，本次只追踪 ${tracked} 个）" }
                       else { "(${tracked} of ${n} branches tracked)" }
            }
            // 反向不一致（进度库里有仓库已删掉的分支）同样要说，
            // 否则用户会反过来怀疑 git 少算了
            return if (zh) { "（仓库共 ${n} 个，进度库里有 ${tracked} 条分支记录）" }
                   else { "(${tracked} recorded, ${n} in repo)" }
        case None => return ""
    }
}

func overallLine(facts: RepoFacts, progress: JsonValue, lang: String): String {
    let zh = !isEnglish(lang)
    if (facts.kind != "git") {
        match (facts.activity) {
            case Some(a) =>
                return "非 git 项目 · " + fileCountLabel(a, zh) + " · 基于文件活动追踪"
            case None =>
                return if (zh) { "非 git 项目 · 0 个文件 · 基于文件活动追踪" } else { "non-git · 0 files · file activity mode" }
        }
    }
    let branchCount = progressBranches(progress).size
    // 「追踪 N 个分支」的 N 是样本，分母必须一起出现，
    // 否则这一行就是本引擎最会骗人的那种事实性陈述
    let note = branchScopeNote(branchCount, repoBranchTotal(facts), zh)
    let parts = ArrayList<String>()
    parts.add(if (zh) { "追踪 ${branchCount} 个分支${note}" } else { "${branchCount} branches tracked${note}" })
    let dirtyCount = userDirtyCount(facts)
    if (dirtyCount > 0) {
        parts.add(if (zh) { "${dirtyCount} 处未提交改动" } else { "${dirtyCount} uncommitted" })
    }
    if (facts.stashCount > 0) {
        parts.add("stash ×${facts.stashCount}")
    }
    return joinStrings(parts, " · ")
}

func branchHeading(name: String, facts: RepoFacts, lang: String): String {
    let zh = !isEnglish(lang)
    let tags = ArrayList<String>()
    if (name == facts.defaultBranch) {
        tags.add(if (zh) { "默认分支" } else { "default" })
    }
    if (name == facts.currentBranch) {
        tags.add(if (zh) { "当前" } else { "current" })
    }
    if (tags.size > 0) {
        return "### `${name}`（${joinStrings(tags, " · ")}）"
    }
    return "### `${name}`"
}

func branchBlock(name: String, rec: JsonValue, narration: Option<BranchNarrative>, facts: RepoFacts, lang: String): String {
    let zh = !isEnglish(lang)
    let sb = StringBuilder()
    sb.append(branchHeading(name, facts, lang))
    sb.append("\n\n")

    let status = Json.strAt(rec, "status", "unknown")
    let headShort = shortSha(Json.strAt(rec, "head", ""))
    let headDate = Json.strAt(rec, "headDate", "")
    // ⚠️ 托管文档里必须写**绝对**时间，不能写 timeAgo 相对时间：
    // "24 分钟前"随钟表流逝而变，跨一分钟重跑 update 内容必然不同，
    // 「仅时间戳不同则不重写」的守卫因此永远失效——必重写、必留备份
    // （dogfood 实测抓到）。绝对时间对同一提交永不变化，文档也不腐烂。
    let when = if (headDate.isEmpty()) { "-" } else { formatDateTime(headDate) }
    let subject = Json.strAt(rec, "headSubject", "")
    let subjectPart = if (subject.isEmpty()) { "" } else { " ${truncate(oneLine(subject), 48, "…")}" }
    sb.append("- **${if (zh) { "状态" } else { "Status" }}**：${statusLabel(status, lang)} · ${if (zh) { "最近提交" } else { "last commit" }} ${when}（`${headShort}`${subjectPart}）\n")

    match (narration) {
        case Some(n) =>
            if (!n.summary.isEmpty()) {
                sb.append("- **${if (zh) { "摘要" } else { "Summary" }}**：${oneLineClamped(n.summary, 160)}\n")
            }
            if (n.highlights.size > 0) {
                sb.append("- **${if (zh) { "近期进展" } else { "Recent work" }}**\n")
                var i: Int64 = 0
                for (h in n.highlights) {
                    if (i >= 6) {
                        break
                    }
                    sb.append("  - ${oneLineClamped(h, 160)}\n")
                    i += 1
                }
            }
            if (n.nextSteps.size > 0) {
                sb.append("- **${if (zh) { "下一步" } else { "Next steps" }}**\n")
                var i: Int64 = 0
                for (h in n.nextSteps) {
                    if (i >= 5) {
                        break
                    }
                    sb.append("  - ${oneLineClamped(h, 160)}\n")
                    i += 1
                }
            }
        case None =>
            let storedSummary = Json.strAt(rec, "summary", "")
            if (!storedSummary.isEmpty()) {
                sb.append("- **${if (zh) { "摘要" } else { "Summary" }}**：${oneLineClamped(storedSummary, 160)}\n")
            }
            let storedHighlights = Json.strArrAt(rec, "highlights")
            if (storedHighlights.size > 0) {
                sb.append("- **${if (zh) { "近期进展" } else { "Recent work" }}**\n")
                for (h in storedHighlights) {
                    sb.append("  - ${oneLineClamped(h, 160)}\n")
                }
            }
    }

    let extras = ArrayList<String>()
    let aheadOfDefault = Json.intAt(rec, "aheadOfDefault", 0)
    let merged = Json.boolAt(rec, "merged", false)
    let pending = Json.intAt(rec, "pendingCommits", 0)
    let lastCount = Json.intAt(rec, "lastRecordedCount", 0)
    if (lastCount > 0) {
        extras.add(if (zh) { "本次记录 ${lastCount} 个提交" } else { "${lastCount} commits recorded" })
    }
    if (merged && name != facts.defaultBranch) {
        extras.add(if (zh) { "已合入默认分支" } else { "merged" })
    }
    if (aheadOfDefault > 0 && name != facts.defaultBranch) {
        extras.add(if (zh) { "领先默认分支 ${aheadOfDefault} 个提交" } else { "${aheadOfDefault} ahead" })
    }
    if (pending > 0 && lastCount == 0) {
        extras.add(if (zh) { "${pending} 个提交待记录" } else { "${pending} pending" })
    }
    if (extras.size > 0) {
        sb.append("- ${joinStrings(extras, " · ")}\n")
    }
    return sb.toString().trimAsciiEnd()
}

/// 分支排序：当前 > 默认 > 活跃 > 闲置 > 停滞 > 已合并
public func sortBranches(names: ArrayList<String>, facts: RepoFacts, progress: JsonValue): ArrayList<String> {
    let out = ArrayList<String>()
    for (n in names) {
        out.add(n)
    }
    // 插入排序（按 score 升序，同分按 headDate 降序）
    var i = 1
    while (i < out.size) {
        let key = out[i]
        var j = i - 1
        while (j >= 0) {
            let sj = branchSortScore(out[j], facts, progress)
            let sk = branchSortScore(key, facts, progress)
            if (sj > sk || (sj == sk && compareHeadDates(out[j], key, progress) < 0)) {
                out[j + 1] = out[j]
                j -= 1
            } else {
                break
            }
        }
        out[j + 1] = key
        i += 1
    }
    return out
}

func branchSortScore(name: String, facts: RepoFacts, progress: JsonValue): Int64 {
    if (name == facts.currentBranch) {
        return 0
    }
    if (name == facts.defaultBranch) {
        return 1
    }
    match (progressBranch(progress, name)) {
        case Some(rec) =>
            let st = Json.strAt(rec, "status", "")
            match (st) {
                case "active" => return 2
                case "idle" => return 3
                case "merged" => return 5
                case _ => return 4
            }
        case None => return 4
    }
}

func compareHeadDates(a: String, b: String, progress: JsonValue): Int64 {
    let da = branchHeadDate(a, progress)
    let db = branchHeadDate(b, progress)
    if (da > db) {
        return 1
    }
    if (da < db) {
        return -1
    }
    return 0
}

func branchHeadDate(name: String, progress: JsonValue): String {
    match (progressBranch(progress, name)) {
        case Some(rec) => return Json.strAt(rec, "headDate", "")
        case None => return ""
    }
}

/// 工程脉搏小节：提交类型构成 + 热点文件 + 工作区注意项（无数据时返回空串）
public func renderPulse(facts: RepoFacts, lang: String): String {
    let zh = !isEnglish(lang)
    let lines = ArrayList<String>()

    if (facts.commitTypes.size > 0) {
        let parts = ArrayList<String>()
        for ((t, count) in facts.commitTypes) {
            parts.add("`" + t + "` ×${count}")
        }
        lines.add("- ${if (zh) { "提交构成" } else { "Commit mix" }}：${joinStrings(parts, " · ")}")
    }

    if (facts.hotFiles.size > 0) {
        let parts = ArrayList<String>()
        var i: Int64 = 0
        for ((f, count) in facts.hotFiles) {
            if (i >= 5) {
                break
            }
            parts.add("`" + f + "` ×${count}")
            i += 1
        }
        lines.add("- ${if (zh) { "热点文件" } else { "Hot files" }}：${joinStrings(parts, "、")}")
    }

    let notes = ArrayList<String>()
    if (facts.untrackedCount > 0) {
        // 同样：采样上限不等于总数，旧实现报「未跟踪 50」（实测真实 317）
        notes.add(if (facts.untrackedTruncated) {
            "${facts.untrackedCount}+ 个未跟踪文件"
        } else {
            "${facts.untrackedCount} 个未跟踪文件"
        })
    }
    if (facts.stashCount > 0) {
        notes.add("${facts.stashCount} 条 stash")
    }
    if (facts.worktreeCount > 1) {
        notes.add("${facts.worktreeCount} 个工作区")
    }
    match (facts.mergeHint) {
        case Some(m) =>
            if (m.kind == "fast-forward") {
                notes.add("`" + m.target + "` 可直接 fast-forward 到 `" + m.defaultBranch + "`")
            } else if (m.kind == "merge") {
                notes.add("`" + m.target + "` 领先 ${m.ahead} / 落后 ${m.behind}，需三方合并")
            }
        case None => ()
    }
    if (notes.size > 0) {
        lines.add("- ${if (zh) { "注意" } else { "Notes" }}：${joinStrings(notes, "；")}")
    }

    if (lines.size == 0) {
        return ""
    }
    let sb = StringBuilder()
    sb.append("### ${if (zh) { "工程脉搏" } else { "Engineering pulse" }}\n\n")
    for (l in lines) {
        sb.append(l + "\n")
    }
    return sb.toString()
}

/// README 进度区域
public func renderProgressReadme(
    facts: RepoFacts, progress: JsonValue, narratives: HashMap<String, BranchNarrative>,
    lang: String, mode: String, at: String, maxBranches: Int64,
): String {
    let zh = !isEnglish(lang)
    let sb = StringBuilder()
    sb.append("## 项目进度\n\n")
    sb.append("> 本区域由 **moonGit** 自动维护（${modeLabel(mode, lang)}）· 更新于 ${formatDateTime(at)}\n")
    sb.append("> ${overallLine(facts, progress, lang)}\n\n")

    let pulse = renderPulse(facts, lang)
    if (!pulse.isEmpty()) {
        sb.append(pulse)
        sb.append("\n")
    }

    let branchNames = ArrayList<String>()
    for ((name, _) in progressBranches(progress)) {
        branchNames.add(name)
    }
    if (branchNames.size == 0) {
        // 注意结尾是单个 \n（换行），不是 \\n —— 后者是「反斜杠 + 字母 n」两个字符，
        // 会被原样写进用户 README 的托管区，每次运行都重现且永不自愈。
        sb.append(if (zh) { "_暂无进度记录，运行 `moongit update` 生成。_\n" } else { "_No progress yet._\n" })
        return sb.toString()
    }

    let sorted = sortBranches(branchNames, facts, progress)
    var i: Int64 = 0
    for (name in sorted) {
        if (i >= maxBranches) {
            break
        }
        match (progressBranch(progress, name)) {
            case Some(rec) =>
                var nar: Option<BranchNarrative> = None
                match (narratives.get(name)) {
                    case Some(n) => nar = Some(n)
                    case None => ()
                }
                sb.append(branchBlock(name, rec, nar, facts, lang))
                sb.append("\n\n")
            case None => ()
        }
        i += 1
    }

    if (sorted.size > maxBranches) {
        sb.append("<details>\n<summary>${if (zh) { "其他分支" } else { "Other branches" }}（${sorted.size - maxBranches}）</summary>\n\n")
        var j: Int64 = 0
        for (name in sorted) {
            if (j < maxBranches) {
                j += 1
                continue
            }
            match (progressBranch(progress, name)) {
                case Some(rec) =>
                    sb.append(branchBlock(name, rec, None, facts, lang))
                    sb.append("\n\n")
                case None => ()
            }
            j += 1
        }
        sb.append("</details>\n")
    }
    return sb.toString()
}

/// AGENT / CLAUDE 进度区域（更紧凑）
public func renderProgressAgent(
    facts: RepoFacts, progress: JsonValue, narratives: HashMap<String, BranchNarrative>,
    lang: String, mode: String, at: String,
): String {
    let zh = !isEnglish(lang)
    let sb = StringBuilder()
    sb.append("## 当前进度（moonGit 维护）\n\n")
    sb.append("> ${modeLabel(mode, lang)} · ${formatDateTime(at)} · ${overallLine(facts, progress, lang)}\n\n")
    let pulse = renderPulse(facts, lang)
    if (!pulse.isEmpty()) {
        sb.append(pulse)
        sb.append("\n")
    }

    let branchNames = ArrayList<String>()
    for ((name, _) in progressBranches(progress)) {
        branchNames.add(name)
    }
    if (branchNames.size == 0) {
        // 同上：单个 \n，不是 \\n
        sb.append(if (zh) { "_暂无记录。_\n" } else { "_No record yet._\n" })
        return sb.toString()
    }

    let sorted = sortBranches(branchNames, facts, progress)
    var i: Int64 = 0
    for (name in sorted) {
        if (i >= 8) {
            break
        }
        match (progressBranch(progress, name)) {
            case Some(rec) =>
                let flags = ArrayList<String>()
                if (name == facts.defaultBranch) {
                    flags.add(if (zh) { "默认" } else { "default" })
                }
                if (name == facts.currentBranch) {
                    flags.add(if (zh) { "当前" } else { "current" })
                }
                let flagStr = if (flags.size > 0) { "（${joinStrings(flags, " · ")}）" } else { "" }
                let head = shortSha(Json.strAt(rec, "head", ""))
                let headDate = Json.strAt(rec, "headDate", "")
                // 同 branchBlock：绝对时间，不写 timeAgo（理由见彼处注释）
                let ago = if (headDate.isEmpty()) { "" } else { "（${formatDateTime(headDate)}）" }
                let extras = ArrayList<String>()
                let pending = Json.intAt(rec, "pendingCommits", 0)
                let ahead = Json.intAt(rec, "aheadOfDefault", 0)
                let merged = Json.boolAt(rec, "merged", false)
                if (pending > 0) {
                    extras.add(if (zh) { "${pending} 个待记录提交" } else { "${pending} pending" })
                }
                if (ahead > 0 && name != facts.defaultBranch && !merged) {
                    extras.add(if (zh) { "领先默认 ${ahead}" } else { "+${ahead}" })
                }
                if (merged && name != facts.defaultBranch) {
                    extras.add(if (zh) { "已合并" } else { "merged" })
                }
                let extraStr = if (extras.size > 0) { " · ${joinStrings(extras, "，")}" } else { "" }
                var summaryStr = ""
                match (narratives.get(name)) {
                    case Some(n) =>
                        if (!n.summary.isEmpty()) {
                            summaryStr = " —— ${oneLineClamped(n.summary, 60)}"
                        }
                    case None =>
                        let s = Json.strAt(rec, "summary", "")
                        if (!s.isEmpty()) {
                            summaryStr = " —— ${oneLineClamped(s, 60)}"
                        }
                }
                sb.append("- **`${name}`**${flagStr}：${statusLabel(Json.strAt(rec, "status", "unknown"), lang)} · head `${head}`${ago}${extraStr}${summaryStr}\n")
            case None => ()
        }
        i += 1
    }

    // 需要注意
    let attention = ArrayList<String>()
    let dirtyCount = userDirtyCount(facts)
    if (dirtyCount > 0) {
        attention.add(if (zh) { "工作区有 ${dirtyCount} 处未提交改动" } else { "${dirtyCount} uncommitted changes" })
    }
    for (name in sorted) {
        match (progressBranch(progress, name)) {
            case Some(rec) =>
                let st = Json.strAt(rec, "status", "")
                let merged = Json.boolAt(rec, "merged", false)
                if (name != facts.defaultBranch && st == "stale" && !merged) {
                    let d = Int64(daysSince(Json.strAt(rec, "headDate", "")))
                    attention.add(if (zh) { "`${name}` 已停滞 ${d} 天（考虑合并或关闭）" } else { "`${name}` stale for ${d} days" })
                }
            case None => ()
        }
    }
    if (attention.size > 0) {
        sb.append("\n**${if (zh) { "需要注意" } else { "Attention" }}**\n")
        var k: Int64 = 0
        for (a in attention) {
            if (k >= 5) {
                break
            }
            sb.append("- ${a}\n")
            k += 1
        }
    }

    // 最近提交
    if (facts.recentCommits.size > 0) {
        sb.append("\n**${if (zh) { "最近提交" } else { "Recent commits" }}**\n")
        var k: Int64 = 0
        for (c in facts.recentCommits) {
            if (k >= 3) {
                break
            }
            sb.append("- `${shortSha(c.sha)}` ${oneLineClamped(c.subject, 120)}（${formatDateOnly(c.date)}）\n")
            k += 1
        }
    }
    return sb.toString()
}

// ------------------------------ 深度更新的兜底渲染 ------------------------------

public func renderOverviewFallback(facts: RepoFacts, progress: JsonValue, lang: String): String {
    let zh = !isEnglish(lang)
    let sb = StringBuilder()
    sb.append("## 项目概览\n\n")
    let manifest = if (facts.manifests.size > 0) { facts.manifests[0] } else { "" }
    if (!manifest.isEmpty()) {
        sb.append("- **构建清单**：`${manifest}`\n")
    }
    if (facts.langStats.size > 0) {
        let parts = ArrayList<String>()
        var i: Int64 = 0
        for ((l, c) in facts.langStats) {
            if (i >= 4) {
                break
            }
            parts.add("`${l}` ${c} 文件")
            i += 1
        }
        sb.append("- **技术构成**：${joinStrings(parts, "、")}\n")
    }
    if (facts.kind == "git") {
        // 触到采集上限时必须说破。trackedFiles 是真实总数，但 langStats / structure
        // 只覆盖了前 N 个文件的名，读者需要知道「技术构成」不是全量口径。
        // 旧实现把上限当总数报出去：25000 个文件的仓库写「20000 个跟踪文件」。
        let trackedText = if (facts.trackedTruncated) {
            "${facts.trackedFiles} 个跟踪文件（以下明细为抽样统计，非全量）"
        } else {
            "${facts.trackedFiles} 个跟踪文件"
        }
        sb.append("- **工程规模**：${trackedText} · ${facts.commitCount} 个提交 · 始于 ${formatDateOnly(facts.firstCommitAt)}\n")
        if (!facts.remote.isEmpty()) {
            sb.append("- **远端**：${facts.remote}\n")
        }
    } else {
        match (facts.activity) {
            case Some(a) =>
                sb.append("- **规模**：${fileCountLabel(a, zh)}（非 git 仓库，基于文件活动追踪）\n")
                // 计数只是下界；用户要动手就得知道是**哪几条路径**读不到。
                // 这一行会写进用户仓库的 README 托管区，长期可见，所以不能只给个数。
                let uLine = unreadablePathsLine(a, zh)
                if (!uLine.isEmpty()) {
                    sb.append("- ${uLine}\n")
                }
            case None => ()
        }
    }
    let branchCount = progressBranches(progress).size
    if (branchCount > 0) {
        let names = ArrayList<String>()
        for ((n, _) in progressBranches(progress)) {
            names.add("`${n}`")
        }
        sb.append("- **分支**：${joinStrings(names, "、")}\n")
    }
    sb.append("\n${if (zh) { "_（本节由 moonGit 依据仓库事实生成，可运行 `moongit update --mode deep` 用 AI 深化）_" } else { "_(generated by moonGit; run deep update with AI to enrich)_" }}\n")
    return sb.toString()
}

public func renderArchitectureFallback(facts: RepoFacts, lang: String): String {
    let zh = !isEnglish(lang)
    let sb = StringBuilder()
    sb.append("## 架构与目录\n\n")
    if (facts.structure.size > 0) {
        sb.append("**${if (zh) { "目录结构（跟踪文件聚合）" } else { "Structure" }}**：\n\n")
        sb.append("```\n")
        var i: Int64 = 0
        for (line in facts.structure) {
            if (i >= 60) {
                break
            }
            sb.append(line)
            sb.append("\n")
            i += 1
        }
        sb.append("```\n\n")
    }
    if (facts.manifests.size > 0) {
        sb.append("**${if (zh) { "构建清单" } else { "Manifests" }}**\n")
        for (m in facts.manifests) {
            sb.append("- `${m}`\n")
        }
        sb.append("\n")
    }
    if (facts.tags.size > 0) {
        sb.append("**${if (zh) { "版本标签" } else { "Tags" }}**\n")
        var i: Int64 = 0
        for ((name, date) in facts.tags) {
            if (i >= 8) {
                break
            }
            sb.append("- `${name}`（${formatDateOnly(date)}）\n")
            i += 1
        }
    }
    return sb.toString()
}

public func renderHistoryFallback(facts: RepoFacts, progress: JsonValue, lang: String): String {
    let zh = !isEnglish(lang)
    let sb = StringBuilder()
    sb.append("## 里程碑与历史\n\n")
    if (facts.tags.size > 0) {
        sb.append("**${if (zh) { "版本标签" } else { "Tags" }}**\n")
        var i: Int64 = 0
        for ((name, _) in facts.tags) {
            if (i >= 10) {
                break
            }
            sb.append("- `${name}`\n")
            i += 1
        }
        sb.append("\n")
    }
    if (facts.commitActivity.size > 0) {
        // 触到采样上限时必须说破。这已经是「上限当全量」的第三处同族缺陷
        // （前两处：跟踪文件数 20000、未跟踪文件数 50）。
        // 危害是自相矛盾：README 声明 450 个提交，月度直方图只加得出 400，
        // 而读者无从分辨 1 月写 100 是真实的还是被砍掉了 50。
        let title = if (facts.activityTruncated) {
            "**${if (zh) { "提交活跃度（按月，仅统计最近 ${ACTIVITY_SCAN_LIMIT} 个提交）" } else { "Commits per month (last ${ACTIVITY_SCAN_LIMIT} commits only)" }}**\n\n"
        } else {
            "**${if (zh) { "提交活跃度（按月）" } else { "Commits per month" }}**\n\n"
        }
        sb.append(title)
        let parts = ArrayList<String>()
        var i: Int64 = 0
        let total = facts.commitActivity.size
        for ((month, count) in facts.commitActivity) {
            if (i >= total - 12) {
                parts.add("${month}: ${count}")
            }
            i += 1
        }
        sb.append(joinStrings(parts, " · "))
        sb.append("\n\n")
    }
    // 只列里程碑型记录（排除 deep 自身产生的记录），保证「无新提交时重复 deep 更新」
    // 内容收敛、不产生文件抖动。
    let milestones = ArrayList<JsonValue>()
    for (e in Json.arrAt(progress, "entries")) {
        if (Json.strAt(e, "mode", "") != "deep") {
            milestones.add(e)
        }
    }
    if (milestones.size > 0) {
        sb.append("**${if (zh) { "进度记录" } else { "Progress entries" }}**\n")
        var i: Int64 = milestones.size - 8
        if (i < 0) {
            i = 0
        }
        while (i < milestones.size) {
            let e = milestones[i]
            sb.append("- ${formatDateTime(Json.strAt(e, "at", ""))} · `${Json.strAt(e, "branch", "-")}` · ${truncate(oneLine(Json.strAt(e, "summary", "")), 80, "…")}\n")
            i += 1
        }
        sb.append("\n")
    }
    if (facts.oldestCommits.size > 0) {
        sb.append("**${if (zh) { "最初提交" } else { "Genesis" }}**\n")
        var i: Int64 = 0
        for (c in facts.oldestCommits) {
            if (i >= 3) {
                break
            }
            sb.append("- `${shortSha(c.sha)}` ${oneLineClamped(c.subject, 120)}（${formatDateOnly(c.date)}）\n")
            i += 1
        }
    }
    return sb.toString()
}

public func renderCommandsFallback(facts: RepoFacts, lang: String): String {
    let zh = !isEnglish(lang)
    let sb = StringBuilder()
    sb.append("## 常用命令\n\n")
    var wrote = false
    for (m in facts.manifests) {
        if (m == "cjpm.toml") {
            sb.append(if (zh) { "仓颉项目：" } else { "Cangjie: " })
            sb.append("`cjpm build` · `cjpm test` · `cjpm run`\n\n")
            wrote = true
        } else if (m == "package.json") {
            sb.append(if (zh) { "Node 项目：" } else { "Node: " })
            sb.append("`npm install` · `npm test` · `npm run build`\n\n")
            wrote = true
        } else if (m == "Cargo.toml") {
            sb.append(if (zh) { "Rust 项目：" } else { "Rust: " })
            sb.append("`cargo build --release` · `cargo test`\n\n")
            wrote = true
        } else if (m == "Package.swift") {
            sb.append(if (zh) { "Swift 项目：" } else { "Swift: " })
            sb.append("`swift build -c release` · `swift test`\n\n")
            wrote = true
        } else if (m == "moon.mod.json") {
            sb.append(if (zh) { "MoonBit 项目：" } else { "MoonBit: " })
            sb.append("`moon check` · `moon test` · `moon build --release`\n\n")
            wrote = true
        }
    }
    if (!wrote) {
        sb.append(if (zh) { "_未检测到标准构建清单，请参考 README。_" } else { "_No standard manifest detected._" })
    }
    return sb.toString()
}

// ------------------------------ 测试 ------------------------------

@Test
func testSortBranchesPriority(): Unit {
    let facts = makeTestFacts("feat/a", "main")
    let progress = Json.obj()
    Json.set(progress, "branches", Json.obj())
    setProgressBranch(progress, "main", jsonPatchOf([("status", Json.of("active")), ("headDate", Json.of("2026-01-01T00:00:00Z"))]))
    setProgressBranch(progress, "feat/a", jsonPatchOf([("status", Json.of("active")), ("headDate", Json.of("2026-02-01T00:00:00Z"))]))
    setProgressBranch(progress, "feat/old", jsonPatchOf([("status", Json.of("merged")), ("headDate", Json.of("2025-01-01T00:00:00Z"))]))
    let names = ArrayList<String>(["feat/old", "main", "feat/a"])
    let sorted = sortBranches(names, facts, progress)
    @Assert(sorted[0] == "feat/a")  // 当前分支
    @Assert(sorted[1] == "main")   // 默认分支
}

@Test
func testRenderProgressReadmeStructure(): Unit {
    let facts = makeTestFacts("main", "main")
    let progress = Json.obj()
    Json.set(progress, "branches", Json.obj())
    setProgressBranch(progress, "main", jsonPatchOf([
        ("status", Json.of("active")),
        ("head", Json.of("abcdef1234567890")),
        ("headDate", Json.of(nowIso())),
        ("headSubject", Json.of("feat: something")),
        ("summary", Json.of("正在开发核心功能")),
    ]))
    let narratives = HashMap<String, BranchNarrative>()
    let md = renderProgressReadme(facts, progress, narratives, "zh", "shallow", nowIso(), 6)
    @Assert(md.contains("## 项目进度"))
    @Assert(md.contains("moonGit"))
    @Assert(md.contains("正在开发核心功能"))
    @Assert(md.contains("abcdef1"))
}

@Test
func testRenderProgressReadmeEmpty(): Unit {
    let facts = makeTestFacts("main", "main")
    let md = renderProgressReadme(facts, Json.obj(), HashMap<String, BranchNarrative>(), "zh", "shallow", nowIso(), 6)
    @Assert(md.contains("暂无进度记录"))
}

@Test
func testRenderAgentCompact(): Unit {
    let facts = makeTestFacts("main", "feat/x")
    let progress = Json.obj()
    Json.set(progress, "branches", Json.obj())
    setProgressBranch(progress, "main", jsonPatchOf([("status", Json.of("active")), ("head", Json.of("aaa11112222"))]))
    setProgressBranch(progress, "feat/x", jsonPatchOf([("status", Json.of("idle")), ("head", Json.of("bbb11112222")), ("pendingCommits", Json.of(3))]))
    let md = renderProgressAgent(facts, progress, HashMap<String, BranchNarrative>(), "zh", "shallow", nowIso())
    @Assert(md.contains("## 当前进度（moonGit 维护）"))
    @Assert(md.contains("feat/x"))
    @Assert(md.contains("3 个待记录提交"))
}

@Test
func testOverallLineNonGit(): Unit {
    let tmp = "/tmp/deepgit-ol-${nowMillis()}"
    ensureDir(tmp)
    let facts = collectFacts(tmp, "dir", Config.defaults(), 5, false)
    let line = overallLine(facts, Json.obj(), "zh")
    @Assert(line.contains("非 git 项目"))
    removePathIfExists(tmp)
}

@Test
func testOverviewFallbackRendersManifest(): Unit {
    let base = "/tmp/deepgit-ov-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/cjpm.toml", "[package]\nname=\"x\"")
    let facts = collectFacts(base, "git", Config.defaults(), 5, true)
    let md = renderOverviewFallback(facts, Json.obj(), "zh")
    @Assert(md.contains("## 项目概览"))
    @Assert(md.contains("cjpm.toml"))
    let cmds = renderCommandsFallback(facts, "zh")
    @Assert(cmds.contains("cjpm build"))
    removePathIfExists(base)
}

/// 测试辅助
func makeTestFacts(currentBranch: String, defaultBranch: String): RepoFacts {
    return RepoFacts(
        "git", "testproj", "/tmp/testproj", "", currentBranch, defaultBranch,
        "abc1234567890", "feat: test", nowIso(), "2026-01-01T00:00:00Z", 10,
        ArrayList<BranchInfo>(), DirtyState(true, 0, 0, 0, 0, 0, ArrayList<String>()), 0,
        ArrayList<(String, String)>(), ArrayList<(Int64, String)>(),
        5, ArrayList<(String, Int64)>([("Swift", 5)]), ArrayList<String>(["src/ (5)"]),
        ArrayList<CommitInfo>(), ArrayList<CommitInfo>(), ArrayList<(String, Int64)>(),
        ArrayList<String>(["cjpm.toml"]), ArrayList<String>(["README.md"]),
        Option<ActivitySnapshot>.None, ArrayList<String>(),
        ArrayList<(String, Int64)>([("feat", 6), ("fix", 4)]), 0, 1, Option<MergePlan>.None,
        ArrayList<(String, Int64)>([("src/main.cj", 9), ("src/util.cj", 4)]),
    )
}

func jsonPatchOf(pairs: Array<(String, JsonValue)>): JsonValue {
    let o = Json.obj()
    for ((k, v) in pairs) {
        Json.set(o, k, v)
    }
    return o
}

@Test
func testRenderPulse(): Unit {
    let facts = makeTestFacts("feat/demo", "main")
    let pulse = renderPulse(facts, "zh")
    @Assert(pulse.contains("工程脉搏"))
    @Assert(pulse.contains("提交构成"))
    @Assert(pulse.contains("feat") && pulse.contains("×6"))
    @Assert(pulse.contains("热点文件"))
    @Assert(pulse.contains("src/main.cj") && pulse.contains("×9"))
    // 空数据：返回空串
    let bare = makeTestFacts("main", "main")
    // bare 的 commitTypes/hotFiles 是 makeTestFacts 填的，手动清空
    let empty = RepoFacts(
        "git", "t", "/tmp/t", "", "main", "main", "a", "s", nowIso(), "", 0,
        ArrayList<BranchInfo>(), DirtyState(false, 0, 0, 0, 0, 0, ArrayList<String>()), 0,
        ArrayList<(String, String)>(), ArrayList<(Int64, String)>(),
        0, ArrayList<(String, Int64)>(), ArrayList<String>(),
        ArrayList<CommitInfo>(), ArrayList<CommitInfo>(), ArrayList<(String, Int64)>(),
        ArrayList<String>(), ArrayList<String>(),
        Option<ActivitySnapshot>.None, ArrayList<String>(),
        ArrayList<(String, Int64)>(), 0, 1, Option<MergePlan>.None, ArrayList<(String, Int64)>(),
    )
    @Assert(renderPulse(empty, "zh") == "")
}

@Test
func testRenderPulseWithMergeHint(): Unit {
    let fastForward = makeTestFactsWithHint("fast-forward", 0, 2, "feat/x", "main")
    let pulse = renderPulse(fastForward, "zh")
    @Assert(pulse.contains("可直接 fast-forward"))

    let merge = makeTestFactsWithHint("merge", 3, 5, "feat/y", "main")
    @Assert(renderPulse(merge, "zh").contains("需三方合并"))
}

/// 带合入提示的测试事实构造
func makeTestFactsWithHint(kind: String, ahead: Int64, behind: Int64, target: String, defBranch: String): RepoFacts {
    let hint = MergePlan(kind, ahead, behind, defBranch, target, "")
    return RepoFacts(
        "git", "t", "/tmp/t", "", target, defBranch,
        "abc1234", "feat: x", nowIso(), "", 1,
        ArrayList<BranchInfo>(), DirtyState(false, 0, 0, 0, 0, 0, ArrayList<String>()), 0,
        ArrayList<(String, String)>(), ArrayList<(Int64, String)>(),
        1, ArrayList<(String, Int64)>(), ArrayList<String>(),
        ArrayList<CommitInfo>(), ArrayList<CommitInfo>(), ArrayList<(String, Int64)>(),
        ArrayList<String>(), ArrayList<String>(),
        Option<ActivitySnapshot>.None, ArrayList<String>(),
        ArrayList<(String, Int64)>(), 0, 1, Some(hint), ArrayList<(String, Int64)>(),
    )
}

@Test
func testRenderPulseEnglish(): Unit {
    let facts = makeTestFacts("feat/demo", "main")
    let pulse = renderPulse(facts, "en")
    @Assert(pulse.contains("Engineering pulse"))
    @Assert(pulse.contains("Commit mix"))
    @Assert(pulse.contains("Hot files"))
    @Assert(!pulse.contains("工程脉搏"))
}

@Test
func testRenderPulseWithNotes(): Unit {
    // untracked / stash / worktree 全部触发注意项
    let facts = RepoFacts(
        "git", "t", "/tmp/t", "", "feat/a", "main", "abc", "feat: x", nowIso(), "", 1,
        ArrayList<BranchInfo>(), DirtyState(false, 0, 0, 0, 0, 0, ArrayList<String>()), 2,
        ArrayList<(String, String)>(), ArrayList<(Int64, String)>(),
        1, ArrayList<(String, Int64)>(), ArrayList<String>(),
        ArrayList<CommitInfo>(), ArrayList<CommitInfo>(), ArrayList<(String, Int64)>(),
        ArrayList<String>(), ArrayList<String>(),
        Option<ActivitySnapshot>.None, ArrayList<String>(),
        ArrayList<(String, Int64)>(), 7, 3, Option<MergePlan>.None, ArrayList<(String, Int64)>(),
    )
    let pulse = renderPulse(facts, "zh")
    @Assert(pulse.contains("7 个未跟踪文件"))
    @Assert(pulse.contains("2 条 stash"))
    @Assert(pulse.contains("3 个工作区"))
}

/// 用户文本写进渲染结果时必须限长。
///
/// 旧代码有两套标准：headSubject 截断到 48，而「最初提交」段的
/// `oneLine(c.subject)` 完全不截断。实测一个 20000 字符的 commit message
/// 让 README 出现**单行 20035 字符**，Markdown 表格与代码块布局被彻底撑坏，
/// 且每次 update 都复现。两套标准并存必然漏点，所以收进 oneLineClamped。
@Test
func testRenderedUserTextIsLengthClamped(): Unit {
    let huge = StringBuilder()
    for (i in 0..20000) {
        huge.append("A")
    }
    let long = huge.toString()
    @Assert(long.size == 20000)
    // 折叠 + 截断后必须短到能放进一行。
    // 注意断的是**显示宽度**而不是 String.size（字节数）——
    // truncate 的契约就是显示宽度，末尾的「…」在 UTF-8 里占 3 字节。
    @Assert(displayWidth(oneLineClamped(long, 120)) <= 120)
    // 正常长度的文本不受影响
    @Assert(oneLineClamped("正常标题", 120) == "正常标题")
    // 换行仍被折叠掉
    @Assert(oneLineClamped("a\nb\tc", 120) == "a b c")
}

/// 真实渲染输出里不得出现超长行。
///
/// 旧代码在「最初提交」段用 `oneLine(c.subject)` 完全不截断，而同一文件的
/// headSubject 截断到 48 —— 两套标准并存。实测一个 20000 字符的 commit message
/// 让 README 出现**单行 20035 字符**，Markdown 表格与代码块布局被撑坏，
/// 且每次 update 都复现。
///
/// ⚠️ 必须走 renderHistoryFallback 真实渲染：只断 oneLineClamped 这个辅助函数
/// 是没用的 —— 辅助函数一直是对的，错的是调用点忘了用它。
@Test
func testRenderedHistoryHasNoRunawayLines(): Unit {
    let base = "/tmp/deepgit-longline-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    let sb = StringBuilder()
    sb.append("feat: ")
    for (i in 0..20000) {
        sb.append("A")
    }
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", sb.toString()], false)

    let facts = collectFacts(base, "git", Config.defaults(), 30, true)
    @Assert(facts.oldestCommits.size > 0)
    @Assert(facts.oldestCommits[0].subject.size > 19000)  // 确认 subject 确实超长
    let out = renderHistoryFallback(facts, Json.obj(), "zh")
    for (line in out.split("\n")) {
        @Assert(displayWidth(line) <= 200)
    }
    removePathIfExists(base)
}

/// oneLineClamped 自身的契约。
/// 注意断的是**显示宽度**而不是 String.size（字节数）——
/// truncate 的契约就是显示宽度，末尾的「…」在 UTF-8 里占 3 字节。
@Test
func testOneLineClampedContract(): Unit {
    let sb = StringBuilder()
    for (i in 0..20000) {
        sb.append("A")
    }
    let long = sb.toString()
    @Assert(long.size == 20000)
    @Assert(displayWidth(oneLineClamped(long, 120)) <= 120)
    @Assert(oneLineClamped("正常标题", 120) == "正常标题")
    @Assert(oneLineClamped("a\nb\tc", 120) == "a b c")
}

@Test
func testEmptyProgressTextHasNoLiteralBackslashN(): Unit {
    // 原文写的是 "_暂无进度记录…_\\n" —— 两个字符：反斜杠 + 字母 n，不是换行符。
    // 它落在托管区内，于是每次 update/deep 都把字面 \n 写进用户的 README/AGENTS，
    // 每次重现且永不自愈。触发条件很常见：git init 后还没提交过任何东西。
    let tmp = "/tmp/dg_emptyrender_${nowMillis()}"
    ensureDir(tmp)
    let facts = collectDirFacts(tmp, Config.defaults())
    let narratives = HashMap<String, BranchNarrative>()
    @Assert(facts.kind == "dir")

    let readme = renderProgressReadme(facts, Json.obj(), narratives, "zh", "shallow", "2026-10-01T04:00:00+08:00", 6)
    @Assert(!readme.contains("\\n"))
    @Assert(readme.contains("暂无进度记录"))

    let agent = renderProgressAgent(facts, Json.obj(), narratives, "zh", "deep", "2026-10-01T04:00:00+08:00")
    @Assert(!agent.contains("\\n"))
    @Assert(agent.contains("暂无记录"))

    // 英文路径同样要干净
    @Assert(!renderProgressReadme(facts, Json.obj(), narratives, "en", "shallow", "2026-10-01T04:00:00+08:00", 6).contains("\\n"))
    @Assert(!renderProgressAgent(facts, Json.obj(), narratives, "en", "deep", "2026-10-01T04:00:00+08:00").contains("\\n"))

    removePathIfExists(tmp)
}
