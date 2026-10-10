// 叙述规则引擎：确定性的提交分类与摘要启发式。
// 引擎是 AI 无关的——LLM 增强由上层 AI 实现（deepDolphin.app）通过引擎的
// 上下文（`context --json`）与工具（`tools --json`）接口完成。
package moongit.kernel

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

let TYPE_PATTERNS: Array<(String, String)> = [
    ("feat", "新增"),
    ("feature", "新增"),
    ("add", "新增"),
    ("fix", "修复"),
    ("bugfix", "修复"),
    ("hotfix", "修复"),
    ("docs", "文档"),
    ("doc", "文档"),
    ("refactor", "重构"),
    ("chore", "构建/依赖"),
    ("build", "构建/依赖"),
    ("deps", "构建/依赖"),
    ("test", "测试"),
    ("perf", "性能"),
    ("style", "样式"),
    ("merge", "合并"),
    ("release", "发版"),
    ("ci", "CI"),
]

/// 中文动词 → 意图（中文项目普遍用描述式提交，需要更宽的匹配）
let CN_KEYWORDS: Array<(Array<String>, String)> = [
    (["收尾", "完成", "实现", "新增", "增加", "支持", "上线", "落地", "接入"], "新增"),
    (["修复", "修正", "解决", "bug", "报错", "崩溃", "crash"], "修复"),
    (["文档", "readme", "注释", "说明", "roadmap", "docs"], "文档"),
    (["重构", "整理", "清理", "抽", "拆分", "迁移"], "重构"),
    (["测试", "test", "断言", "用例", "验收"], "测试"),
    (["性能", "优化", "加速", "缓存"], "性能"),
    (["样式", "格式", "排版", "格式"], "样式"),
    (["构建", "依赖", "升级", "适配", "版本"], "构建/依赖"),
    (["发布", "发版", "release", "tag"], "发版"),
    (["合并", "merge", "同步"], "合并"),
    (["安全", "校验", "guard", "守卫"], "安全"),
    (["界面", "UI", "ui", "布局", "渲染"], "界面"),
]

/// 归类提交意图
/// 前缀后面紧跟的字符是否允许继续认定这是「类型前缀」。
///
/// ⚠️ 必须查词边界。原来只做 startsWith，于是
///   `additional logging`  → "add" 命中 → 判成「新增」
///   `address bar layout`  → "add" 命中 → 判成「新增」
///   `city select widget`   → "ci"  命中 → 判成「CI」
/// 这些是普通英文单词，不是提交类型。后果不是分类粗糙，而是
/// **仪表盘上「新增 ×N」的数字被算错**，而那是给人做决策看的。
///
/// 规则：前缀后面必须是非字母（`: ( ! 空格 - 数字 …`）或者字符串结束。
/// 数字允许 —— `feat2` 之类仍然算 feat。
/// 收紧后 `feature: x` 由 ("feature", …) 命中、`docs: x` 由 ("docs", …) 命中，
/// 因为 TYPE_PATTERNS 里长前缀排在短前缀之后，循环会继续往下走。
private func prefixBoundaryOk(s: String, prefixLen: Int64): Bool {
    if (prefixLen >= s.size) {
        return true
    }
    let c = s[prefixLen]
    // 就地判断：milestones.cj 里的 isAsciiDigitByte 是文件作用域私有，这里够不着。
    // 小写字母 a-z 的字节区间是 0x61..0x7A（s 已 toAsciiLower 过）。
    return !(c >= 0x61u8 && c <= 0x7Au8)
}

public func classifyCommit(subject: String): String {
    let s = oneLine(subject).toAsciiLower()
    for ((prefix, label) in TYPE_PATTERNS) {
        if (s.startsWith(prefix) && prefixBoundaryOk(s, Int64(prefix.size))) {
            return label
        }
    }
    // 中文关键词（在整句任意位置匹配，而不是只看前缀）
    for ((keywords, label) in CN_KEYWORDS) {
        for (kw in keywords) {
            if (s.contains(kw)) {
                return label
            }
        }
    }
    // 无类型信息：用提交尺度判断（短句多为琐碎改动）
    if (oneLine(subject).size <= 6) {
        return "微调"
    }
    return "更新"
}

/// 去掉 conventional commit 前缀，保留可读描述
public func cleanSubject(subject: String): String {
    let s = oneLine(subject)
    // 形如 "feat(scope): message" 或 "fix: message"
    let colon = s.indexOf(":")
    match (colon) {
        case Some(ci) =>
            let head = s[..ci]
            let lower = head.toAsciiLower()
            // 仅当冒号前是 conventional commit 类型标记时才剥离：
            // 全小写、无空格、≤20 字符，且属于已知类型集合
            var isTypeToken = lower.size <= 20 && !lower.contains(" ")
            if (isTypeToken) {
                let base = if (lower.contains("(")) { lower[..indexOfOr(lower, "(")] } else { lower }
                var known = false
                for ((prefix, _) in TYPE_PATTERNS) {
                    if (base == prefix) {
                        known = true
                        break
                    }
                }
                if (!known) {
                    isTypeToken = false
                }
            }
            if (isTypeToken) {
                let rest = s[ci + 1..].trimAscii()
                if (rest.size > 0) {
                    return rest
                }
            }
            return s
        case None => return s
    }
}

func areasOf(stats: DiffStats, top: Int64): ArrayList<String> {
    let names = ArrayList<String>()
    let counts = ArrayList<Int64>()
    for (f in stats.fileList) {
        let seg = if (f.path.contains("/")) { f.path[..indexOfOr(f.path, "/")] } else { "(根目录)" }
        var found = false
        for (i in 0..names.size) {
            if (names[i] == seg) {
                counts[i] = counts[i] + 1
                found = true
                break
            }
        }
        if (!found) {
            names.add(seg)
            counts.add(1)
        }
    }
    // 排序
    let out = ArrayList<String>()
    let idx = ArrayList<Int64>()
    for (i in 0..names.size) {
        idx.add(i)
    }
    var a: Int64 = 1
    while (a < idx.size) {
        let key = idx[a]
        var b = a - 1
        while (b >= 0 && counts[idx[b]] < counts[key]) {
            idx[b + 1] = idx[b]
            b -= 1
        }
        idx[b + 1] = key
        a += 1
    }
    for (i in idx) {
        if (out.size >= top) {
            break
        }
        out.add("${names[i]}（${counts[i]} 文件）")
    }
    // ⚠️ 被截掉的区域必须说出来。7 个区域只列 3 个、另外 4 个凭空消失，
    // 读者会以为「这个项目只动了 3 个地方」——
    // 「上限当全量」这一族已经栽到第 9 次（commitActivity 400 / commitTypes 15 /
    // lsFiles 20000 / 语言 Top12 / scan 20000 目录 / dashboard languages /
    // update 基线 30 / entryCount 200 / 叙述层 3 类+3 区域+5 亮点）。
    if (out.size < idx.size) {
        var restFiles: Int64 = 0
        var k = 0
        for (i in idx) {
            if (k >= top) {
                restFiles += counts[i]
            }
            k += 1
        }
        out.add("等 ${idx.size - top} 个其他区域（共 ${restFiles} 文件）")
    }
    return out
}

func indexOfOr(s: String, needle: String): Int64 {
    match (s.indexOf(needle)) {
        case Some(i) => return i
        case None => return 0
    }
}

/// 单个分支的规则化叙述
public func rulesBranchNarrative(delta: BranchDelta, facts: RepoFacts, lang: String): BranchNarrative {
    let zh = !isEnglish(lang)
    let commits = delta.commits
    if (commits.size == 0) {
        return BranchNarrative(
            if (zh) { "自上次记录以来 `${delta.branch}` 无新提交" } else { "No new commits on ${delta.branch}" },
            ArrayList<String>(),
            ArrayList<String>(),
            computeBranchStatus(facts.lastCommitAt, false),
        )
    }

    // 归类统计
    let typeNames = ArrayList<String>()
    let typeCounts = ArrayList<Int64>()
    for (c in commits) {
        let t = classifyCommit(c.subject)
        var found = false
        for (i in 0..typeNames.size) {
            if (typeNames[i] == t) {
                typeCounts[i] = typeCounts[i] + 1
                found = true
                break
            }
        }
        if (!found) {
            typeNames.add(t)
            typeCounts.add(1)
        }
    }
    // 排序取前 3
    let ti = ArrayList<Int64>()
    for (i in 0..typeNames.size) {
        ti.add(i)
    }
    var x: Int64 = 1
    while (x < ti.size) {
        let key = ti[x]
        var y = x - 1
        while (y >= 0 && typeCounts[ti[y]] < typeCounts[key]) {
            ti[y + 1] = ti[y]
            y -= 1
        }
        ti[y + 1] = key
        x += 1
    }
    let typeParts = ArrayList<String>()
    for (i in ti) {
        if (typeParts.size >= 3) {
            break
        }
        typeParts.add("${typeNames[i]}×${typeCounts[i]}")
    }
    // 同样不能说「3 类」就是「只有 3 类」
    if (typeParts.size < ti.size) {
        var restCount: Int64 = 0
        var k = 0
        for (i in ti) {
            if (k >= 3) {
                restCount += typeCounts[i]
            }
            k += 1
        }
        typeParts.add("其他${ti.size - 3}类×${restCount}")
    }
    let typeSummary = joinStrings(typeParts, "、")

    let areas = areasOf(delta.stats, 3)
    let summaryParts = ArrayList<String>()
    if (!delta.from.isEmpty()) {
        summaryParts.add(if (zh) { "新增 ${commits.size} 个提交（${typeSummary}）" } else { "${commits.size} new commits (${typeSummary})" })
    } else {
        summaryParts.add(if (zh) { "最近 ${commits.size} 个提交：${typeSummary}" } else { "latest ${commits.size} commits: ${typeSummary}" })
    }
    if (areas.size > 0) {
        summaryParts.add((if (zh) { "涉及 " } else { "touching " }) + joinStrings(areas, "、"))
    }
    // ⚠️ 历史被改写必须说出口。
    //
    // delta.reset 只有测试在读，没有任何命令 / JSON 字段 / 叙述文案消费它。
    // 实测：记录 5 个提交 → git reset --hard HEAD~3（踢掉 3 条已记录的）
    // → 再提交 2 个 → track 报「最近 4 个提交：新增×4」，零提示。
    // 用户无法区分「我新推了 4 个提交」和「你 3 条已记录提交被踢出基线」——
    // 后者意味着引擎丢失了一部分它声称记住的历史。
    // ⚠️ 基线被钳到 30 条时，「最近 N 个提交」不是该分支的提交总数，
    // 而 update.cj 已经在算 delta.truncated 了 —— 叙述层却一次都没读过它。
    // 于是首次建基线的 100 提交项目，摘要里写「最近 30 个提交」，
    // 而 commitCount 是 100：同一份 README 里两个数字打架。
    if (delta.truncated) {
        summaryParts.add(if (zh) {
            "（已达 30 条基线上限，此处为样本而非全部提交）"
        } else {
            "(baseline capped at 30 — sample, not all commits)"
        })
    }
    if (delta.reset) {
        summaryParts.add(if (zh) {
            "⚠ 检测到历史改写（rebase / force-push / 强制回退），基线已重建，原提交区间不再可计算"
        } else {
            "history rewritten (rebase / force-push) — baseline rebuilt, previous range no longer computable"
        })
    }
    let summary = joinStrings(summaryParts, "，")

    let highlights = ArrayList<String>()
    var i: Int64 = 0
    for (c in commits) {
        if (i >= 5) {
            break
        }
        let clean = cleanSubject(c.subject)
        let text = if (clean.isEmpty()) { c.subject } else { "：“${clean}”" }
        highlights.add(truncate("${classifyCommit(c.subject)}${text}", 60, "…"))
        i += 1
    }
    // 亮点只列 5 条，但提交可能有几十条。必须写明分母，
    // 否则「近期进展」看起来就是「全部进展」。
    if (commits.size > highlights.size) {
        highlights.add("（另有 ${commits.size - highlights.size} 个提交未展开，见 journal）")
    }

    let nextSteps = ArrayList<String>()
    let st = computeBranchStatus(
        if (commits.size > 0) { commits[0].date } else { facts.lastCommitAt },
        false,
    )
    if (st == "stale") {
        nextSteps.add(if (zh) { "分支已多日无提交，确认是否合并或关闭" } else { "branch is stale — merge or close it" })
    }
    let bn = delta.branch.toAsciiLower()
    if ((bn.startsWith("feat/") || bn.startsWith("fix/") || bn.startsWith("refactor/")) ) {
        nextSteps.add(if (zh) { "推进该分支的收尾与验证，考虑合并回默认分支" } else { "finish and validate, then merge back" })
    }
    if (delta.stats.insertions > 1500) {
        nextSteps.add(if (zh) { "本次改动较大，建议补充测试与文档" } else { "large change — add tests and docs" })
    }

    return BranchNarrative(summary, highlights, nextSteps, st)
}

/// 项目级提醒
public func rulesOverallNotes(facts: RepoFacts, lang: String): ArrayList<String> {
    let zh = !isEnglish(lang)
    let notes = ArrayList<String>()
    if (!facts.dirty.clean) {
        // 排除 moonGit 自己维护的文档，避免自引用噪音
        var userDirty: Int64 = 0
        for (f in facts.dirty.files) {
            if (!isManagedDoc(f)) {
                userDirty += 1
            }
        }
        if (userDirty > 0) {
            notes.add(if (zh) {
                "工作区有 ${userDirty} 处未提交改动"
            } else {
                "${userDirty} uncommitted changes"
            })
        }
    }
    if (facts.stashCount > 0) {
        notes.add(if (zh) { "存在 ${facts.stashCount} 条 stash，注意清理" } else { "${facts.stashCount} stashes" })
    }
    for (w in facts.warnings) {
        notes.add(w)
    }
    return notes
}

/// 深度更新兜底章节
public func rulesDeepSections(facts: RepoFacts, progress: JsonValue, lang: String): (String, String, String, String) {
    // 返回 (readmeOverview, readmeHistory, agentArchitecture, agentCommands)
    let overview = renderOverviewFallback(facts, progress, lang)
    let history = renderHistoryFallback(facts, progress, lang)
    let architecture = renderArchitectureFallback(facts, lang)
    let commands = renderCommandsFallback(facts, lang)
    return (overview, history, architecture, commands)
}

// ------------------------------ 测试 ------------------------------

@Test
func testClassifyCommit(): Unit {
    @Assert(classifyCommit("feat: add user login") == "新增")
    @Assert(classifyCommit("fix(ui): correct layout") == "修复")
    @Assert(classifyCommit("docs: update README") == "文档")
    @Assert(classifyCommit("新增登录功能") == "新增")
    @Assert(classifyCommit("修复崩溃问题") == "修复")
    @Assert(classifyCommit("random message") == "更新")
}

@Test
func testClassifyChineseDescriptionCommits(): Unit {
    @Assert(classifyCommit("审查收尾：/W 按 1000/upem 换算") == "新增")
    @Assert(classifyCommit("PDF 规格收尾（P1–P7 完成）+ roadmap 状态同步") == "新增")
    @Assert(classifyCommit("修复 Windows 下路径分隔符问题") == "修复")
    @Assert(classifyCommit("更新 README 说明") == "文档")
    @Assert(classifyCommit("重构渲染管线，抽取图元") == "重构")
    @Assert(classifyCommit("补充验收测试断言") == "测试")
    @Assert(classifyCommit("fix") != "更新")
    @Assert(classifyCommit("wip") != "")
}

@Test
func testCleanSubject(): Unit {
    @Assert(cleanSubject("feat: add user login") == "add user login")
    @Assert(cleanSubject("fix(ui): correct layout") == "correct layout")
    @Assert(cleanSubject("no prefix here") == "no prefix here")
    @Assert(cleanSubject("A: with colon in sentence") == "A: with colon in sentence")
}

@Test
func testRulesBranchNarrativeWithCommits(): Unit {
    let commits = ArrayList<CommitInfo>()
    commits.add(CommitInfo("s1", "s1", "a", "e", nowIso(), "feat: add x", ""))
    commits.add(CommitInfo("s2", "s2", "a", "e", nowIso(), "fix: fix y", ""))
    let delta = BranchDelta("feat/demo", "head1", "base1", false, commits, DiffStats(3, 20, 5, ArrayList<FileStat>([FileStat("src/a.cj", "M", 20, 5)])))
    let facts = testFactsForRules()
    let n = rulesBranchNarrative(delta, facts, "zh")
    @Assert(n.summary.contains("新增"))
    @Assert(n.summary.contains("修复"))
    @Assert(n.highlights.size == 2)
    @Assert(n.status == "active")
}

@Test
func testRulesBranchNarrativeNoCommits(): Unit {
    let delta = BranchDelta("main", "head1", "base1", false, ArrayList<CommitInfo>(), DiffStats(0, 0, 0, ArrayList<FileStat>()))
    let n = rulesBranchNarrative(delta, testFactsForRules(), "zh")
    @Assert(n.summary.contains("无新提交"))
    @Assert(n.highlights.size == 0)
}

@Test
func testRulesOverallNotes(): Unit {
    // 干净仓库：无提醒
    let cleanFacts = testFactsForRules()
    @Assert(rulesOverallNotes(cleanFacts, "zh").size == 0)
    // 脏仓库（含用户文件）：有提醒
    let dirty = RepoFacts(
        "git", "t", "/tmp/t", "", "main", "main", "a", "s", nowIso(), "2026-01-01T00:00:00Z", 1,
        ArrayList<BranchInfo>(), DirtyState(false, 0, 1, 1, 0, 2, ArrayList<String>(["src/a.cj", "README.md"])), 2,
        ArrayList<(String, String)>(), ArrayList<(Int64, String)>(),
        1, ArrayList<(String, Int64)>(), ArrayList<String>(),
        ArrayList<CommitInfo>(), ArrayList<CommitInfo>(), ArrayList<(String, Int64)>(),
        ArrayList<String>(), ArrayList<String>(),
        Option<ActivitySnapshot>.None, ArrayList<String>(),
        ArrayList<(String, Int64)>(), 0, 1, Option<MergePlan>.None, ArrayList<(String, Int64)>(),
    )
    let notes = rulesOverallNotes(dirty, "zh")
    @Assert(notes.size == 2)  // 未提交 + stash
    // 只有托管文档时不算用户改动
    let onlyDocs = RepoFacts(
        "git", "t", "/tmp/t", "", "main", "main", "a", "s", nowIso(), "2026-01-01T00:00:00Z", 1,
        ArrayList<BranchInfo>(), DirtyState(false, 0, 1, 0, 0, 1, ArrayList<String>(["README.md"])), 0,
        ArrayList<(String, String)>(), ArrayList<(Int64, String)>(),
        1, ArrayList<(String, Int64)>(), ArrayList<String>(),
        ArrayList<CommitInfo>(), ArrayList<CommitInfo>(), ArrayList<(String, Int64)>(),
        ArrayList<String>(), ArrayList<String>(),
        Option<ActivitySnapshot>.None, ArrayList<String>(),
        ArrayList<(String, Int64)>(), 0, 1, Option<MergePlan>.None, ArrayList<(String, Int64)>(),
    )
    @Assert(rulesOverallNotes(onlyDocs, "zh").size == 0)
}

@Test
func testRulesDeepSectionsNonEmpty(): Unit {
    let facts = testFactsForRules()
    let (ov, hist, arch, cmd) = rulesDeepSections(facts, Json.obj(), "zh")
    @Assert(ov.contains("项目概览"))
    @Assert(hist.contains("里程碑"))
    @Assert(arch.contains("架构"))
    @Assert(cmd.size > 0)
}

func testFactsForRules(): RepoFacts {
    return RepoFacts(
        "git", "testproj", "/tmp/testproj", "", "feat/demo", "main",
        "abc1234", "feat: x", nowIso(), "2026-01-01T00:00:00Z", 10,
        ArrayList<BranchInfo>(), DirtyState(false, 0, 0, 0, 0, 0, ArrayList<String>()), 0,
        ArrayList<(String, String)>(), ArrayList<(Int64, String)>(),
        5, ArrayList<(String, Int64)>([("Cangjie", 5)]), ArrayList<String>(["src/ (5)"]),
        ArrayList<CommitInfo>(), ArrayList<CommitInfo>(), ArrayList<(String, Int64)>(),
        ArrayList<String>(["cjpm.toml"]), ArrayList<String>(["README.md"]),
        Option<ActivitySnapshot>.None, ArrayList<String>(),
        ArrayList<(String, Int64)>(), 0, 1, Option<MergePlan>.None, ArrayList<(String, Int64)>(),
    )
}

/// 托管文档不许嵌相对时间（"N 分钟前"）：它随钟表流逝而变，「仅时间戳
/// 不同则不重写」的守卫因此永远失效——跨一分钟重跑 update 必重写、必留
/// 备份（dogfood 实测抓到）。文档里写绝对时间才不腐烂。
@Test
func testBranchBlockUsesAbsoluteNotRelativeTime(): Unit {
    let rec = Json.obj()
    Json.set(rec, "status", Json.of("active"))
    Json.set(rec, "head", Json.of("83023fa8deadbeef"))
    Json.set(rec, "headDate", Json.of("2026-10-10T14:15:00"))
    Json.set(rec, "headSubject", Json.of("merge: 审计修复"))
    Json.set(rec, "pendingCommits", Json.of(0))
    Json.set(rec, "aheadOfDefault", Json.of(3))
    Json.set(rec, "merged", Json.of(false))
    let out = branchBlock("dev", rec, None, testFactsForRules(), "zh")
    @Assert(!out.contains("分钟前"))
    @Assert(!out.contains("小时前"))
    @Assert(!out.contains("天前"))
    @Assert(out.contains("2026-10-10 14:15"))
}

/// 构造一个与真实仓库同形的 RepoFacts（规则引擎只用到分支名与 lastCommitAt）。
func factsForBase(dir: String, branch: String, head: String): RepoFacts {
    return RepoFacts(
        "git", "narr", dir, "", branch, branch,
        head, "feat: x", nowIso(), "2026-01-01T00:00:00Z", 1,
        ArrayList<BranchInfo>(), DirtyState(false, 0, 0, 0, 0, 0, ArrayList<String>()), 0,
        ArrayList<(String, String)>(), ArrayList<(Int64, String)>(),
        1, ArrayList<(String, Int64)>(), ArrayList<String>(),
        ArrayList<CommitInfo>(), ArrayList<CommitInfo>(), ArrayList<(String, Int64)>(),
        ArrayList<String>(), ArrayList<String>(),
        Option<ActivitySnapshot>.None, ArrayList<String>(),
        ArrayList<(String, Int64)>(), 0, 0, Option<MergePlan>.None, ArrayList<(String, Int64)>(),
    )
}

@Test
func testNarrativeDisclosesItsOwnCaps(): Unit {
    // 「上限当全量」第 9 次：叙述层三处上限（3 类 / 3 区域 / 5 亮点）
    // 全部**无披露**地截断，而它的输出会写进用户的 README 托管区。
    //
    // 实测（修复前）：6 种类型、7 个区域、7 个提交 →
    //   summary    : 最近 7 个提交：新增×2、构建/依赖×1、测试×1
    //                 （6 类只列 3 类，且 3 类那一类的提交数也没提）
    //   highlights : 5 条，没有任何「还有 N 条」
    // 区域那处更隐蔽：首轮没有 diff stats，第二轮才有，
    // 于是 7 个区域只列 3 个、另外 4 个凭空消失 ——
    // 读者会以为「这个项目只动了 3 个地方」。
    let base = "/tmp/deepgit-narrcap-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    // 6 个区域
    for (d in ["src", "tests", "ui", "config", "docs", "scripts"]) {
        ensureDir("${base}/${d}")
        writeFileAtomic("${base}/${d}/a.txt", "x")
    }
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: initial"], false)

    // 6 种提交类型
    let kinds = ["feat: a", "fix: b", "refactor: c", "docs: d", "test: e", "chore: f"]
    for (k in kinds) {
        for (d in ["src", "tests", "ui", "config", "docs", "scripts"]) {
            writeFileAtomic("${base}/${d}/x.txt", k)
        }
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", k], false)
    }

    let head = revParse(base, "main").getOrThrow()
    // 首轮基线：有 6 类、7 个提交，**没有** diff stats
    let first = branchDelta(base, "main", "", 200, 200)
    @Assert(first.isSome())
    let d1 = first.getOrThrow()
    @Assert(d1.commits.size == 7)
    let n1 = rulesBranchNarrative(d1, factsForBase(base, "main", head), "zh")
    // 类型：超过 3 类必须出现「其他」
    @Assert(n1.summary.contains("其他"))
    // 亮点：超过 5 条必须写明还剩多少
    @Assert(n1.highlights.size == 6)
    @Assert(n1.highlights[5].contains("另有"))
    @Assert(n1.highlights[5].contains("2"))

    // 第二轮：产生 diff stats，区域超过 3 个
    for (d in ["src", "tests", "ui", "config", "docs", "scripts"]) {
        writeFileAtomic("${base}/${d}/more.txt", "more")
    }
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: round2"], false)
    let second = branchDelta(base, "main", head, 200, 200)
    @Assert(second.isSome())
    let d2 = second.getOrThrow()
    let n2 = rulesBranchNarrative(d2, factsForBase(base, "main", revParse(base, "main").getOrThrow()), "zh")
    // 6 个区域，只列 3 个 → 必须出现「等 3 个其他区域」。
    // 数字必须与实际区域数吻合，不能写死一个跟场景无关的值。
    @Assert(n2.summary.contains("其他区域"))
    @Assert(n2.summary.contains("等 3 个其他区域"))

    removePathIfExists(base)
}

@Test
func testNarrativeDisclosesBaselineTruncation(): Unit {
    // delta.truncated 在叙述层一次都没被读过，而 update.cj 一直在算它。
    // 首次建基线的 100 提交项目，摘要写「最近 30 个提交」，
    // 而同一份 JSON 里 commitCount 是 100 —— 两个数字打架。
    let base = "/tmp/deepgit-narrtrunc-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    for (i in 0..40) {
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "feat: c${i}"], false)
    }
    let head = revParse(base, "main").getOrThrow()
    let d = branchDelta(base, "main", "", 200, 200)
    @Assert(d.isSome())
    @Assert(d.getOrThrow().truncated)          // 前提：确实被钳到 30
    let n = rulesBranchNarrative(d.getOrThrow(), factsForBase(base, "main", head), "zh")
    @Assert(n.summary.contains("基线上限"))
    @Assert(n.summary.contains("样本"))

    removePathIfExists(base)
}

@Test
func testClassifyCommitDoesNotMatchPrefixInsideOrdinaryWord(): Unit {
    // 「把读不出来说成不存在」的近亲：把「不是类型前缀」认成「是类型前缀」。
    //
    // 原来只做 startsWith，于是短前缀会撞上普通英文单词：
    //   `additional logging` → "add" 命中 → 判成「新增」
    //   `address bar layout` → "add" 命中 → 判成「新增」
    //   `city select widget`  → "ci"  命中 → 判成「CI」
    // 后果不是分类粗糙，而是**仪表盘上「新增 ×N」的数字被算错** ——
    // 那是给人做决策看的统计。
    //
    // 收紧后必须仍然认得的（这是反向对照，防止「修过头」）：
    for (good in ["feat: x", "feat x", "feat(x)", "feature: x", "docs: x",
                  "fix(ui): y", "add: z", "ci: build", "hotfix: p", "refactor: q"]) {
        // 这些都该命中某个**真实**前缀，不该被边界规则误伤
        let before = classifyCommit(good)
        @Assert(before != "更新" || good == "random message")
    }
    // 精确断言关键几个
    @Assert(classifyCommit("feat: a") == "新增")
    @Assert(classifyCommit("feature: a") == "新增")
    @Assert(classifyCommit("docs: a") == "文档")
    @Assert(classifyCommit("add: a") == "新增")
    @Assert(classifyCommit("ci: a") == "CI")

    // 撞词的这些必须**不再**命中前缀
    @Assert(classifyCommit("additional logging") != "新增")
    @Assert(classifyCommit("address bar layout") != "新增")
    @Assert(classifyCommit("address book sync") != "新增")
    @Assert(classifyCommit("city select widget") != "CI")
    @Assert(classifyCommit("cite the spec") != "CI")
    // 它们仍要落到某个合理标签（不能变成空串）
    @Assert(classifyCommit("additional logging") == "更新")
    @Assert(classifyCommit("city select widget") == "更新")
    // 中文关键词不受影响（走的是 contains，不是前缀）
    @Assert(classifyCommit("新增登录功能") == "新增")
    @Assert(classifyCommit("修复崩溃问题") == "修复")
}
