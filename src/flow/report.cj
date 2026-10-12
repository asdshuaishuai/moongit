// 报告导出：把项目群进度渲染成一份自包含的 Markdown 报告。
package moongit.flow

import std.collection.*
import std.env.*
import moongit.kernel.*
import moongit.util.*
import std.unittest.*
import std.unittest.testmacro.*

/// 报告里语言分布最多列几种。超过就要写明分母（见下面的截断披露）。
let REPORT_MAX_LANGS: Int64 = 8

/// 里程碑在报告表格里的**状态格**。纯函数。
///
/// ⚠️ 原来是个内联 `match`，只有 `done` / `dropped` 两个分支，
/// `_` 把 `open` 和 **`unknown`** 一起兜成「进行中」。
/// 而 `unknown` 的含义是「仓库读不出来，这条里程碑核验不了」——
/// 报告是人最可能照着做事的文件，在那里写「进行中」是**假事实**：
/// 实测把 `.git/objects` 移走后，dashboard 说「? 无法核验（仓库读不出来）」，
/// 报告那一格却是「进行中」、备注栏空白。
///
/// 「核验不了」必须显示成核验不了，不能显示成任何一种确定状态。
///
/// ⚠️ `case _` 原来同时兜住 `open` 和**一切认不出的 status**（W1）。
/// 认不出的 status（手写 milestones.json / 旧版本数据 / 未来新增枚举）
/// 在 dashboard 计数侧已单列 other 桶（#182：既不并进 open 也不丢弃），
/// 而报告这里把它们渲染成确定状态「进行中」—— 同一份 items，
/// 两个出口两种口径，报告还偏偏是给出确定结论的那个。
/// 现在只有 `open` 才谈进行中/逾期；unknown 与认不出的 status 一律三态文案，
/// 原因写进备注格（见 milestoneCellNote）。
public func milestoneCellStatus(status: String, overdue: Bool): String {
    return match (status) {
        case "done" => "✓ 已达成"
        case "dropped" => "✗ 已放弃"
        case "open" => if (overdue) { "⚠ 已逾期" } else { "进行中" }
        // 认不出的 status 哪怕标了 overdue 也不能渲染成「已逾期」：
        // 逾期判定依赖 status=="open"（milestones.cj），而这里的 status 连认都认不出，
        // 天数与 overdue 都不可信 —— 与上面 unknown 无视 overdue 是同一条理由。
        case _ => "? 无法核验"
    }
}

/// 里程碑的**备注格**。纯函数。
///
/// `unknown` 必须把核验失败的原因写出来 —— 只写「无法核验」等于
/// 告诉读者「有问题」却不告诉他「为什么」，读者无从判断该重试还是该修仓库。
/// 认不出的 status 同族同理（W1）：格子已是「? 无法核验」，备注若空着，
/// 读者只知道「有问题」却不知道「为什么」—— 引擎不认为那是核验失败
/// （数据里的值不在已知枚举里），那就把值本身写出来，读者还能去核对数据。
public func milestoneCellNote(
    tagReached: Bool, status: String, days: Int64, unverifiedReason: String
): String {
    if (tagReached) {
        return "tag 已存在"
    }
    // unknown 与一切认不出的 status（非 open/done/dropped）同族处理，
    // 与 milestoneCellStatus 的三态文案配对。
    let unrecognized = status != "open" && status != "done" && status != "dropped" && status != "unknown"
    if (status == "unknown" || unrecognized) {
        let fallback = if (status == "unknown") {
            "仓库读不出来"
        } else if (status.isEmpty()) {
            "状态为空"
        } else {
            "未知状态：${status}"
        }
        let why = if (unverifiedReason.isEmpty()) { fallback } else { unverifiedReason }
        return "无法核验：${why}"
    }
    // 逾期只对**进行中**的里程碑有意义。
    // 原来这里只看 daysToTarget、不看 status，于是已完成的里程碑
    // 目标日期一过就被标成「逾期 2465 天」—— 而同一份 JSON 里
    // overdue=false（milestones.cj 判定是对的），报告和 JSON 自相矛盾。
    // 实测：2020-01-01 达成的 v1.0，报告显示「✓ 已达成 | 逾期 2465 天」。
    if (status != "open") {
        return ""   // 已完成 / 已放弃：不谈还剩几天，也不谈逾期
    }
    if (days >= 0) {
        return "还剩 ${days} 天"
    }
    if (days != -1) {
        return "逾期 ${-days} 天"
    }
    return ""
}

/// 里程碑小节的开头。**items 为空也必须出小节**，并把「读不出来」与「真的没有」分开。
///
/// ⚠️ 原来是 `if (msItems.size > 0)` —— items 空就整节不输出。
/// 而 items 空有**两种**含义：「确实没有里程碑」和「milestones.json 读不出来」。
/// 实测把 milestones.json 写坏后：dashboard 大声披露
/// 「milestones.json corrupt，里程碑读不出来（读到 0 条），上面的 0 不是『没有』」，
/// 而 `report` exit 0、报告里**一个「里程碑」字都没有**。
/// 披露在一个出口说了、在另一个出口消失 —— 而报告恰恰是人最可能拿去看的那份。
public func milestoneSectionHeader(readCount: Int64, storeHealth: String, orphaned: Int64, degraded: Bool): String {
    var sb = StringBuilder()
    sb.append("## 里程碑\n\n")
    if (storeHealth != "ok" || degraded) {
        let why = if (storeHealth != "ok") { storeHealth } else { "部分降级" }
        sb.append("> ⚠ 里程碑读不出来或已降级（${why}）—— 读到 ${readCount} 条，")
        sb.append("下面的空白**不是「没有里程碑」**，是读不到。\n\n")
    } else if (orphaned > 0) {
        sb.append("> ⚠ 另有 ${orphaned} 条里程碑属于已停用项目，未列入下表（数据仍在 milestones.json 里）。\n\n")
    }
    if (readCount == 0 && storeHealth == "ok" && !degraded) {
        sb.append("_（暂无里程碑）_\n\n")
    }
    return sb.toString()
}

/// 生成 Markdown 报告。statuses 为 allProjectStatuses 结果，dash 为 buildDashboard 结果。
public func renderReportMarkdown(statuses: ArrayList<JsonValue>, dash: JsonValue, lang: String): String {
    let zh = !isEnglish(lang)
    let sb = StringBuilder()
    // ---- 项目群总览 ----
    let projs = Json.getOr(dash, "projects")
    let work = Json.getOr(dash, "work")
    // ⚠️ projs.total 是**采集成功**数，不是注册总数。原实现直接把它当「N 个项目」
    // 写进标题和总览表，于是：
    //   标题  「· 1 个项目」   总览表「| 项目总数 | 1 |」
    //   事实  listed=3、failed=2
    // 同一份报告的「项目详情」里三个小节都在（两个标着「状态获取失败」），
    // 正文和标题**自相矛盾**。#115 已在 status/dashboard/MCP 出口修掉同一族问题，
    // 报告是漏掉的那个调用面 —— 而且报告恰恰是给人读的那份。
    // 标题必须把三个数都说出来。
    let okTotal = Json.intAt(projs, "total", 0)
    let listed = Json.intAt(projs, "listed", 0)
    let failed = Json.intAt(projs, "failed", 0)
    let totalText = if (failed > 0) {
        "已注册 ${listed} 个 · 读取成功 ${okTotal} 个 · **采集失败 ${failed} 个**"
    } else {
        "${okTotal} 个"
    }
    sb.append("# moonGit 进度报告\n\n")
    sb.append("> 生成于 ${formatDateTime(nowIso())} · ${totalText}\n\n")

    sb.append("## 项目群总览\n\n")
    sb.append("| 指标 | 数值 |\n|---|---|\n")
    // 「已注册」必须用 registered（注册表里一共多少条），不能用 listed
    // （参与统计的数，disabled 已被跳过）。详见 dashboard.cj 的 #184 注释。
    let registered = Json.intAt(projs, "registered", listed)
    let excludedDisabled = Json.intAt(projs, "excludedDisabled", 0)
    sb.append("| 项目总数（已注册） | ${registered} |\n")
    if (excludedDisabled > 0) {
        sb.append("| 其中已停用（不参与统计） | ${excludedDisabled} |\n")
    }
    sb.append("| 读取成功 | ${okTotal} |\n")
    // 失败数必须单列一行：没有这一行，读者会把「读取成功」当成总数
    sb.append("| 采集失败 | ${failed} |\n")
    sb.append("| 近 7 天活跃 | ${Json.intAt(projs, "active7d", 0)} |\n")
    sb.append("| 近 30 天活跃 | ${Json.intAt(projs, "active30d", 0)} |\n")
    sb.append("| 有未提交改动 | ${Json.intAt(projs, "dirty", 0)} |\n")
    sb.append("| 待合入分支 | ${Json.intAt(work, "mergeCandidates", 0)} |\n")
    sb.append("| 未跟踪文件 | ${Json.intAt(work, "untrackedFiles", 0)} |\n")
    // 契约C 汇总侧：有项目的未跟踪数读不到时（dashboard 恒发的
    // work.untrackedFailed），上一行不含它们 —— 不说破，读者会把
    // 「N 个未跟踪文件」当成整个项目群的完整口径（不变量 17：
    // 数据里有 ≠ 用户看得到）。与 languageFailed 的披露行同族。
    let untrackedFailed = Json.intAt(work, "untrackedFailed", 0)
    if (untrackedFailed > 0) {
        let untrackedFailedNote = if (zh) {
            "⚠ ${untrackedFailed} 个项目的未跟踪文件数读不到，未计入上一行（不是「没有未跟踪文件」）"
        } else {
            "⚠ untracked file count unreadable for ${untrackedFailed} project(s), excluded from the row above (not \"none\")"
        }
        sb.append("\n_${untrackedFailedNote}_\n")
    }
    sb.append("\n")

    // ---- 语言分布 ----
    let langs = Json.arrAt(dash, "languages")
    // 采集失败也要出小节（#187）：languages 为空时若整节跳过，
    // 失败披露跟着一起消失，读者无从知道「没采到」≠「没有」。
    let langFailed = Json.intAt(dash, "languagesFailed", 0)
    if (langs.size > 0 || langFailed > 0) {
        sb.append("## 语言分布\n\n")
        if (langs.size > 0) {
            let parts = ArrayList<String>()
            var n: Int64 = 0
            for (l in langs) {
                if (n >= REPORT_MAX_LANGS) {
                    break
                }
                parts.add("${Json.strAt(l, "language", "")} (${Json.intAt(l, "count", 0)})")
                n += 1
            }
            sb.append(joinStrings(parts, " · "))
            // 截断必须写分母。这是个**潜在**缺口：目前语言分类器分桶很粗
            // （实测三个多语言项目只产出 3 组），我构造不出能触发它的仓库，
            // 所以没当成已复现缺陷报。但上限写死在这里、又不披露，
            // 哪天分类器变细就会变成第 N 次「上限当全量」。先补上披露。
            if (langs.size > REPORT_MAX_LANGS) {
                sb.append("\n_（共 ${langs.size} 种语言，此处仅列前 ${REPORT_MAX_LANGS} 种）_")
            }
            // dashboard 已经算好的文件上限标志也必须透出：
            // 有项目撞了 20000 文件上限时，被丢掉的文件可能包含整类语言
            if (Json.boolAt(dash, "languagesTruncated", false)) {
                sb.append("\n_⚠ 有项目撞到 ${MAX_TRACKED_FILES} 个跟踪文件的上限，被丢掉的文件里可能还有整类语言_")
            }
        } else {
            sb.append("_（未采集到任何项目的语言数据）_")
        }
        if (langFailed > 0) {
            sb.append("\n_⚠ ${langFailed} 个项目语言采集失败，未计入上面这份分布_")
        }
        sb.append("\n\n")
    }

    // ---- 里程碑 ----
    // ⚠️ 小节**恒发**，不再由 items 是否为空决定（见 milestoneSectionHeader）。
    // items 空可能是「真的没有」，也可能是「读不出来」——
    // 原来 `if (msItems.size > 0)` 把两者混同，于是 dashboard 的披露在报告里消失。
    let ms = Json.getOr(dash, "milestones")
    let msItems = Json.arrAt(ms, "items")
    let msCounts = Json.getOr(ms, "counts")
    sb.append(milestoneSectionHeader(
        Json.intAt(msCounts, "readCount", 0),
        Json.strAt(msCounts, "storeHealth", "ok"),
        Json.intAt(msCounts, "orphaned", 0),
        Json.boolAt(msCounts, "degraded", false)))
    if (msItems.size > 0) {
        sb.append("| 项目 | 里程碑 | 状态 | 目标 | 备注 |\n|---|---|---|---|---|\n")
        for (it in msItems) {
            let status = Json.strAt(it, "status", "")
            let label = milestoneCellStatus(status, Json.boolAt(it, "overdue", false))
            // ⚠️ 仓颉 1.0.5 不支持具名实参，这里只能按位置传
            let note = milestoneCellNote(
                Json.boolAt(it, "tagReached", false),
                status,
                Json.intAt(it, "daysToTarget", -1),
                Json.strAt(it, "unverifiedReason", ""))
            // 里程碑名是任意字符串，mdCell 防止 | 和换行撑破 5 列表格
            sb.append("| ${mdCell(Json.strAt(it, "projectName", ""))} | ${mdCell(Json.strAt(it, "name", ""))} | ${label} | ${Json.strAt(it, "targetDate", "")} | ${note} |\n")
        }
        sb.append("\n")
    }

    // ---- 各项目详情 ----
    sb.append("## 项目详情\n\n")
    for (s in statuses) {
        let name = Json.strAt(s, "name", "")
        if (Json.has(s, "error")) {
            // 只写「状态获取失败」而不说原因，读者无从判断该重试还是该去修路径。
            // 报错原文是这里唯一有用的信息。
            sb.append("### ${name}（状态获取失败）\n\n")
            sb.append("- **原因**：${Json.strAt(s, "error", "未知原因")}\n\n")
            continue
        }
        sb.append("### ${name}\n\n")
        // 存储损坏也必须在这里说：#121 已经把它接进 status/summary/agent 上下文，
        // 报告是第三个出口，不接的话「读不出来」又变回「没有历史」——
        // 而报告恰恰是人最可能拿去看的那份。
        let sh = Json.strAt(s, "storeHealth", "ok")
        if (sh != "ok") {
            sb.append("- ⚠ **进度存储 ${sh}**：下面的分支/提交数读不到，不是 0\n")
        }
        sb.append("- **现状**：${Json.strAt(s, "headline", "")}\n")
        let branch = Json.strAt(s, "currentBranch", "")
        if (!branch.isEmpty()) {
            sb.append("- **当前分支**：${branch} · 默认分支 ${Json.strAt(s, "defaultBranch", "")}\n")
        }
        let dirty = Json.intAt(s, "userDirtyCount", 0)
        let untracked = Json.intAt(s, "untrackedCount", 0)
        let stash = Json.intAt(s, "stashCount", 0)
        sb.append("- **工作区**：${dirty} 个未提交改动 · ${untracked} 个未跟踪文件 · ${stash} 条 stash\n")
        // 契约C（untrackedError，status 恒发）：ls-files --others 采集失败时
        // 上面的 untracked 是 0 —— 那是无知，不是结论。报告是人最可能照着
        // 做事的文件，不说破「0 个未跟踪文件」就成了「工作面干净」的假事实
        // （不变量 17：数据里有 ≠ 用户看得到）。与上面 storeHealth 的 ⚠ 行同族。
        let untrackedErr = Json.strAt(s, "untrackedError", "")
        if (!untrackedErr.isEmpty()) {
            let untrackedNote = if (zh) {
                "- ⚠ **未跟踪文件数读不到**：${oneLineClamped(untrackedErr, 90)}（不是「没有未跟踪文件」）\n"
            } else {
                "- ⚠ **untracked file count unreadable**: ${oneLineClamped(untrackedErr, 90)} (not \"no untracked files\")\n"
            }
            sb.append(untrackedNote)
        }
        match (Json.get(s, "mergeHint")) {
            case Some(mh) =>
                sb.append("- **合入提示**：`${Json.strAt(mh, "target", "")}` ${Json.strAt(mh, "description", "")}\n")
            case None => ()
        }

        let branches = Json.arrAt(s, "branches")
        if (branches.size > 0) {
            sb.append("\n| 分支 | 状态 | 领先 | 最近提交 |\n|---|---|---|---|\n")
            for (b in branches) {
                let marker = if (Json.boolAt(b, "isCurrent", false)) { "▸ " } else { "" }
                // 分支名（git branch 'feat|injected|branch' 合法）和提交标题都含 |
                // 时会把 4 列表格撑成 7 列
                sb.append("| ${marker}${mdCell(Json.strAt(b, "name", ""))} | ${Json.strAt(b, "statusLabel", "")} | ${Json.intAt(b, "pendingCommits", 0)} | ${mdCell(Json.strAt(b, "headAgo", "") + " " + Json.strAt(b, "headSubject", ""))} |\n")
            }
        }

        // 提交构成
        let cts = Json.arrAt(s, "commitTypes")
        if (cts.size > 0) {
            let parts = ArrayList<String>()
            for (ct in cts) {
                parts.add("${Json.strAt(ct, "type", "")} ×${Json.intAt(ct, "count", 0)}")
            }
            // 「（近期）」太含糊：读者无从知道分母是 15 还是 1500。
            // 被截断时直接把分母写出来（近 15/23 条），否则这份构成会被当成项目全貌。
            let scope = if (Json.boolAt(s, "commitTypesTruncated", false)) {
                "近 ${sampleSize(cts)}/${Json.intAt(s, "commitCount", 0)} 条"
            } else {
                "全部 ${Json.intAt(s, "commitCount", 0)} 条"
            }
            sb.append("\n提交构成（${scope}）：${joinStrings(parts, " · ")}\n")
        }
        sb.append("\n")
    }

    sb.append("---\n\n")
    let sourceNote = if (zh) { "本地数据，未出网" } else { "local data only" }
    sb.append("_本报告由 moonGit 自动生成（" + sourceNote + "）_\n")
    return sb.toString()
}

// ------------------------------ 测试 ------------------------------

@Test
func testRenderReportMarkdown(): Unit {
    let config = Config.defaults()
    let reg = Registry()
    let dash = buildDashboard(reg.projects, config)
    let statuses = allProjectStatuses(reg.projects, config, true)
    let md = renderReportMarkdown(statuses, dash, "zh")
    @Assert(md.contains("# moonGit 进度报告"))
    @Assert(md.contains("## 项目群总览"))
    @Assert(md.contains("项目总数"))
    @Assert(md.contains("## 项目详情"))
}

@Test
func testRenderReportWithRealRepo(): Unit {
    let base = "/tmp/deepgit-rep-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.cj", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: first"], false)
    gitRun(base, ["checkout", "-q", "-b", "feat/pending"], false)
    writeFileAtomic(base + "/a.cj", "2")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "fix: pending work"], false)
    gitRun(base, ["checkout", "-q", "main"], false)

    let config = Config.defaults()
    let reg = Registry()
    reg.projects.add(ProjectEntry("p_rep", "rep-demo", base, "git", "", nowIso(), ArrayList<String>(), false))
    let statuses = allProjectStatuses(reg.projects, config, false)
    let dash = buildDashboard(reg.projects, config)
    let md = renderReportMarkdown(statuses, dash, "zh")
    @Assert(md.contains("## 项目详情"))
    @Assert(md.contains("### rep-demo"))
    @Assert(md.contains("**现状**"))
    @Assert(md.contains("**当前分支**：main"))
    @Assert(md.contains("提交构成"))
    @Assert(md.contains("feat ×1"))
    removePathIfExists(base)
}

@Test
func testRenderReportSkipsErrorProjects(): Unit {
    let p = ProjectEntry("p_bad", "bad", "/tmp/definitely-not-a-repo-xx", "git", "", nowIso(), ArrayList<String>(), false)
    let reg = Registry()
    reg.projects.add(p)
    let config = Config.defaults()
    let statuses = allProjectStatuses(reg.projects, config, true)
    let dash = buildDashboard(reg.projects, config)
    let md = renderReportMarkdown(statuses, dash, "zh")
    // 失败项目要么被错误隔离标注，要么根本不出现在详情里，但不能让报告崩掉
    @Assert(md.contains("# moonGit 进度报告"))
}

@Test
func testUpdateWritesPulseIntoReadme(): Unit {
    let base = "/tmp/deepgit-pulse-e2e-${nowMillis()}"
    // 隔离数据目录。必须放在仓库之外：若置于 base 内部，engine 的 store/ 目录
    // 会让 git 工作区变脏，runDeep 第二次执行就不再幂等（下方的 !anyChanged 断言会红）。
    // 不隔离则 runUpdate/runTrack/runDeep 内部按 projectId 推导出的 store 路径会落到
    // 用户真实的 ~/.deepgit/store，测试失败或被中断时还会留下孤儿目录。
    let testHome = base + "-home"   // 仓库的兄弟目录：唯一，且不在 git 工作区内
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: 初始功能"], false)

    let config = Config.defaults()
    let reg = Registry()
    reg.projects.add(ProjectEntry("p_pulse", "pulse-demo", base, "git", "", nowIso(), ArrayList<String>(), false))
    let p = reg.projects[0]
    let opts = UpdateOptions()
    opts.mode = "shallow"
    opts.source = "test"
    let r = runUpdate(p, config, opts)
    @Assert(r.ok)

    let readme = readFileText(base + "/README.md").getOrThrow()
    @Assert(readme.contains("deepgit:begin progress"))
    @Assert(readme.contains("工程脉搏"))
    @Assert(readme.contains("提交构成"))
    @Assert(readme.contains("`feat` ×1"))
    removePathIfExists(base)
    // 复位必须排在所有 deepgitPath(...) 之后：提前复位会让上面的清理打到真实 store
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testReportDoesNotLabelDoneMilestoneOverdue(): Unit {
    // 逾期只对进行中的里程碑有意义。原来这里只看 daysToTarget、不看 status，
    // 于是已完成的里程碑目标日期一过就被标成「逾期 2465 天」——
    // 而同一份 JSON 里 overdue=false（milestones.cj 的判定是对的），
    // 报告和数据自相矛盾。实测：2020-01-01 达成的 v1.0。
    let dash = Json.obj()
    let projs = Json.obj()
    Json.set(projs, "total", Json.of(1))
    Json.set(dash, "projects", projs)

    let statuses = ArrayList<JsonValue>()
    let s1 = Json.obj()
    Json.set(s1, "name", Json.of("demo"))
    Json.set(s1, "branches", JArr(ArrayList<JsonValue>()))
    Json.set(s1, "userDirtyCount", Json.of(0))
    statuses.add(s1)

    let dash2 = Json.obj()
    let ms = Json.obj()
    let counts = Json.obj()
    Json.set(counts, "done", Json.of(1))
    Json.set(counts, "open", Json.of(0))
    Json.set(counts, "dropped", Json.of(0))
    Json.set(ms, "counts", counts)
    let items = ArrayList<JsonValue>()
    let done = Json.obj()
    Json.set(done, "projectName", Json.of("demo"))
    Json.set(done, "name", Json.of("v1.0"))
    Json.set(done, "status", Json.of("done"))
    Json.set(done, "targetDate", Json.of("2020-01-01"))
    Json.set(done, "daysToTarget", Json.of(-2465))
    Json.set(done, "overdue", Json.of(false))
    items.add(done)
    // 对照：进行中且确实逾期
    let open = Json.obj()
    Json.set(open, "projectName", Json.of("demo"))
    Json.set(open, "name", Json.of("v2.0"))
    Json.set(open, "status", Json.of("open"))
    Json.set(open, "targetDate", Json.of("2020-01-01"))
    Json.set(open, "daysToTarget", Json.of(-10))
    Json.set(open, "overdue", Json.of(true))
    items.add(open)
    // 对照：进行中且未到期
    let future = Json.obj()
    Json.set(future, "projectName", Json.of("demo"))
    Json.set(future, "name", Json.of("v3.0"))
    Json.set(future, "status", Json.of("open"))
    Json.set(future, "targetDate", Json.of("2099-01-01"))
    Json.set(future, "daysToTarget", Json.of(100))
    Json.set(future, "overdue", Json.of(false))
    items.add(future)
    Json.set(ms, "items", JArr(items))
    Json.set(dash2, "milestones", ms)
    Json.set(dash2, "projects", projs)
    Json.set(dash2, "languages", JArr(ArrayList<JsonValue>()))

    let md = renderReportMarkdown(statuses, dash2, "zh")
    // 已达成的不能再标逾期
    @Assert(!md.contains("v1.0 | ✓ 已达成 | 2020-01-01 | 逾期"))
    // 但真正逾期的进行中里程碑必须照常标注，否则就是误伤
    @Assert(md.contains("逾期 10 天"))
    @Assert(md.contains("还剩 100 天"))
}

@Test
func testReportDoesNotPresentSuccessCountAsProjectTotal(): Unit {
    // projs.total 是**采集成功**数，不是注册总数。原实现直接把它当「N 个项目」
    // 写进标题和总览表，于是：
    //   标题  「· 1 个项目」   总览表「| 项目总数 | 1 |」
    //   事实  listed=3、failed=2
    // 同一份报告的「项目详情」里三个小节都在（两个标着「状态获取失败」）——
    // 正文和标题自相矛盾。#115 已在 status/dashboard/MCP 出口修掉同一族问题，
    // 报告是漏掉的那个调用面，而且报告恰恰是给人读的那份。
    let base = "/tmp/deepgit-repcount-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let good = base + "/good"
    let bad1 = base + "/bad1"
    let bad2 = base + "/bad2"
    var pgood = ProjectEntry("", "", "", "git", "", "", ArrayList<String>(), false)
    var pbad1 = ProjectEntry("", "", "", "git", "", "", ArrayList<String>(), false)
    var pbad2 = ProjectEntry("", "", "", "git", "", "", ArrayList<String>(), false)
    try {
        ensureDir(good)
        gitRun(good, ["init", "-b", "main"], false)
        writeFileAtomic(good + "/a.txt", "1")
        gitRun(good, ["add", "."], false)
        gitRun(good, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: one"], false)
        let (g, _) = addProject(good, "rep-good", ArrayList<String>(), "")
        pgood = g
        // addProject 要求路径存在（notFound），所以先建目录注册、再删掉 ——
        // 「注册了但路径失效」是稳定的采集失败来源。
        ensureDir(bad1)
        ensureDir(bad2)
        let (b1, _) = addProject(bad1, "rep-bad1", ArrayList<String>(), "")
        pbad1 = b1
        let (b2, _) = addProject(bad2, "rep-bad2", ArrayList<String>(), "")
        pbad2 = b2
        removePathIfExists(bad1)
        removePathIfExists(bad2)

        let projects = ArrayList<ProjectEntry>([g, b1, b2])
        let statuses = allProjectStatuses(projects, Config.defaults(), false)
        // 前提：确实处于「3 个注册、1 个成功、2 个失败」
        @Assert(statuses.size == 3)
        @Assert(okCountOf(statuses) == 1)
        let dash = buildDashboard(projects, Config.defaults())
        @Assert(Json.intAt(Json.getOr(dash, "projects"), "total", -1) == 1)
        @Assert(Json.intAt(Json.getOr(dash, "projects"), "listed", -1) == 3)
        @Assert(Json.intAt(Json.getOr(dash, "projects"), "failed", -1) == 2)

        let md = renderReportMarkdown(statuses, dash, "zh")
        // 标题不得再自称「1 个项目」
        @Assert(!md.contains("· 1 个项目"))
        // 三个数都要出现，读者才可能自己算出「有 2 个没读到」
        @Assert(md.contains("已注册 3 个"))
        @Assert(md.contains("读取成功 1 个"))
        @Assert(md.contains("采集失败 2 个"))
        // 总览表必须把「总数」与「失败数」分开列，不能只有一行「项目总数 1」
        @Assert(md.contains("| 项目总数（已注册） | 3 |"))
        @Assert(md.contains("| 采集失败 | 2 |"))
        // 失败小节必须给原因，不能只有一个空标题
        @Assert(md.contains("rep-bad1（状态获取失败）"))
        // 原因必须紧跟在失败小节里。不要用 md[i1..i1+200] 切一段来断言 ——
        // 切片按**字节**下标，中文 markdown 很容易落在字符中间抛
        // IllegalArgumentException（第一版就这么栽了）。整篇 contains 就够。
        @Assert(md.contains("**原因**：路径不存在"))

        // 对照组：全部可读时不得出现「采集失败」这一行噪音
        ensureDir(bad1)
        gitRun(bad1, ["init", "-b", "main"], false)
        writeFileAtomic(bad1 + "/a.txt", "1")
        gitRun(bad1, ["add", "."], false)
        gitRun(bad1, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: two"], false)
        let okProjects = ArrayList<ProjectEntry>([g])
        let okMd = renderReportMarkdown(allProjectStatuses(okProjects, Config.defaults(), false),
                                        buildDashboard(okProjects, Config.defaults()), "zh")
        @Assert(okMd.contains("| 采集失败 | 0 |"))
        @Assert(!okMd.contains("**采集失败"))
    } finally {
        removePathIfExists(good)
        removePathIfExists(deepgitPath(["store", pgood.id]))
        removePathIfExists(deepgitPath(["store", pbad1.id]))
        removePathIfExists(deepgitPath(["store", pbad2.id]))
        exitTestHome()
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

@Test
func testReportSurfacesStoreCorruption(): Unit {
    // #121 把 storeHealth 接进了 status / summary / agent 上下文，
    // 报告是第三个出口。不接的话，「读不出来」在报告里又变回「没有历史」——
    // 而报告恰恰是人最可能拿去看的那一份。
    let base = "/tmp/deepgit-repstore-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let repo = base + "/repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic(repo + "/a.txt", "1")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: one"], false)
    let (p, _) = addProject(repo, "rep-store", ArrayList<String>(), "")
    try {
        // 前提：先真的写一份进度出来
        let up = UpdateOptions()
        up.mode = "shallow"
        up.source = "test"
        @Assert(runUpdate(p, Config.defaults(), up).ok)
        writeFileAtomic(StorePaths(p.id).progress, "{ broken")

        let projects = ArrayList<ProjectEntry>([p])
        let md = renderReportMarkdown(allProjectStatuses(projects, Config.defaults(), false),
                                      buildDashboard(projects, Config.defaults()), "zh")
        // 必须明说是「读不到」而不是「没有」
        @Assert(md.contains("进度存储 corrupt"))
        @Assert(md.contains("读不到，不是 0"))
    } finally {
        removePathIfExists(repo)
        removePathIfExists(deepgitPath(["store", p.id]))
        exitTestHome()
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

// ------------------------------ 测试 ------------------------------

/// #176 回归：`unknown` 状态不许被渲染成「进行中」。
///
/// 负控（曾真实发红）：把仓库的 `.git/objects` 移走之后，
/// dashboard 说「? 无法核验（仓库读不出来）」，
/// 报告表格那一格却是「进行中」、备注栏空白 —— 假事实。
/// 根因是内联 `match` 的 `_` 分支把 `open` 和 `unknown` 一起兜住了。
@Test
func testMilestoneCellStatusNeverFalsifiesUnknownAsInProgress(): Unit {
    @Assert(milestoneCellStatus("done", false) == "✓ 已达成")
    @Assert(milestoneCellStatus("dropped", false) == "✗ 已放弃")
    @Assert(milestoneCellStatus("open", false) == "进行中")
    @Assert(milestoneCellStatus("open", true) == "⚠ 已逾期")
    // 三种确定状态怎么组合都碰不到 unknown 这一格
    for (ov in [true, false]) {
        for (st in ["done", "dropped", "open"]) {
            @Assert(milestoneCellStatus(st, ov) != "? 无法核验")
        }
    }
    @Assert(milestoneCellStatus("unknown", false) == "? 无法核验")
    // 哪怕同时逾期，也必须是「无法核验」而不是「已逾期」——
    // 逾期是从天数算出来的，而天数在核验失败时不可信
    @Assert(milestoneCellStatus("unknown", true) == "? 无法核验")
    // ⚠️ 2026-10-11 显式推翻（W1）：这条断言原本钉的是 `== "进行中"`，
    // 而它上一行的注释写的恰恰是「未知状态字符串也不能被兜成『进行中』」——
    // 注释说的是对的，断言钉死的却是错误行为，同一行自相矛盾。
    // 推翻理由：dashboard 计数侧 #182 早已把认不出的 status 单列 other 桶
    // （既不并进 open 也不丢弃），同一份 items 在报告表格里却渲染成确定状态
    // 「进行中」—— 两个出口两种口径。按不变量 32（「不知道」和「没有」是
    // 两个状态，渲染层不能合并），格子改发三态文案，原因进备注
    // （milestoneCellNote 的「未知状态：X」）。这是有意的契约变更，不是改绿了事。
    @Assert(milestoneCellStatus("某种没见过的状态", false) == "? 无法核验")
    // 认不出的 status 哪怕 overdue=true 也不能渲染成「已逾期」：
    // 逾期是从 status=="open" 的天数算的，status 连认都认不出时天数不可信
    @Assert(milestoneCellStatus("某种没见过的状态", true) == "? 无法核验")
}

/// 核验失败时备注必须写出**原因**，只写「无法核验」等于让读者猜。
@Test
func testMilestoneCellNoteCarriesUnverifiedReason(): Unit {
    let n = milestoneCellNote(false, "unknown", -1, "仓库读不出来")
    @Assert(n.contains("无法核验"))
    @Assert(n.contains("仓库读出来不来") || n.contains("仓库读不出来"))
    // 原因缺失时也要有话可说，不能变成空备注
    let blank = milestoneCellNote(false, "unknown", -1, "")
    @Assert(!blank.isEmpty())
    @Assert(blank.contains("无法核验"))
    // unknown + tag 已存在：tag 是真的，但它不能掩盖「状态核验不了」
    let tagged = milestoneCellNote(true, "unknown", -1, "仓库读不出来")
    @Assert(!tagged.isEmpty())
    // W1：认不出的 status 备注也不能空着 —— 格子已是「? 无法核验」，
    // 只说「有问题」不说「为什么」，读者无从判断该重试还是该去核对数据。
    let weird = milestoneCellNote(false, "active", -1, "")
    @Assert(weird.contains("无法核验"))
    @Assert(weird.contains("active"))   // 值本身写出来，读者才能去核对 milestones.json
    // 有原因时优先披露原因，与 unknown 的既有处理对齐
    let weirdWhy = milestoneCellNote(false, "active", -1, "仓库读不出来")
    @Assert(weirdWhy.contains("无法核验"))
    @Assert(weirdWhy.contains("仓库读不出来"))
}

/// W1 回归：认不出的 milestone status 在 dashboard 计数单列 other 桶（#182），
/// 报告表格却把它兜成确定状态「进行中」—— 同一份 items 两个出口两种口径。
///
/// 走真实路径，不手搓 dash JSON：setMilestoneStatus 不校验枚举（正是 #182
/// 实测「手写 status:"active"」的入口）→ buildMilestoneOverview 原样透传
/// effectiveStatus → renderReportMarkdown 渲染。纯函数断言钉的是格式，
/// 这条钉的是「数据真的这么流」，两者缺一则负控各漏一半。
@Test
func testReportCellForUnrecognizedMilestoneStatusIsUnverifiable(): Unit {
    let base = "/tmp/deepgit-repunknown-${nowMillis()}"
    let testHome = base + "-home"
    let repo = base + "/repo"
    var pid = ""
    try {
        // setup 必须在 try **内**：gitRun(false) 抛 GIT_FAILED、writeFileAtomic 抛 IO、
        // addProject 抛 notFound 时，沙箱与 DEEPGIT_HOME 都要有 finally 兜底 ——
        // 原来这段在 try 外，setup 一红 /tmp 就漏目录，且 DEEPGIT_HOME
        // 停在 testHome 上不复位（enterTestHome 没有配对的 exitTestHome）。
        ensureDir(repo)
        gitRun(repo, ["init", "-b", "main"], false)
        writeFileAtomic(repo + "/a.txt", "1")
        gitRun(repo, ["add", "."], false)
        gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: one"], false)
        ensureDir(testHome)
        enterTestHome(testHome)
        let (p, _) = addProject(repo, "rep-unknown", ArrayList<String>(), "")
        pid = p.id
        let (_, created) = addMilestone(p.id, "v1.0", "", "", "")
        @Assert(created)
        // 手工塞一个认不出的 status —— 引擎入口不校验枚举，数据里存什么就流什么
        @Assert(setMilestoneStatus(p.id, "v1.0", "active"))

        let projects = ArrayList<ProjectEntry>([p])
        let dash = buildDashboard(projects, Config.defaults())
        // 前提自证（不变量 18）：dashboard 侧确实把它计进 other 桶 ——
        // 没有这个前提，下面的报告断言可能测的根本不是「认不出的 status」路径
        let counts = Json.getOr(Json.getOr(dash, "milestones"), "counts")
        @Assert(Json.intAt(counts, "other", -1) == 1)

        let md = renderReportMarkdown(allProjectStatuses(projects, Config.defaults(), false), dash, "zh")
        // 格子：含「无法核验」，且那条里程碑绝不能被渲染成「进行中」
        @Assert(md.contains("v1.0 | ? 无法核验"))
        @Assert(!md.contains("v1.0 | 进行中"))
        // 备注：披露原因（不变量 32），把值本身写出来供读者核对
        @Assert(md.contains("未知状态：active"))
    } finally {
        removePathIfExists(repo)
        if (!pid.isEmpty()) {
            removePathIfExists(deepgitPath(["store", pid]))
        }
        // setup 中途抛出时 enterTestHome 可能没跑到：exitTestHome 回到兜底沙箱，
        // 绝不回到真实 home（这正是它存在的理由，见 paths.cj）
        exitTestHome()
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

/// #177 回归：里程碑小节恒发，且区分「读不出来」与「真的没有」。
///
/// 负控（曾真实发红）：把 milestones.json 写坏后，
/// dashboard 披露「读到 0 条，上面的 0 不是『没有』」，
/// 而报告里**一个「里程碑」字都没有**、exit 0。
@Test
func testMilestoneSectionHeaderAlwaysEmitsAndDisclosesReadFailure(): Unit {
    // 损坏：必须有小节、有警示、且明说「不是没有」
    let corrupt = milestoneSectionHeader(0, "corrupt", 0, true)
    @Assert(corrupt.contains("## 里程碑"))
    @Assert(corrupt.contains("读不出来"))
    @Assert(corrupt.contains("不是"))
    @Assert(corrupt.contains("corrupt"))
    // 降级但存储本身 ok：也要说
    @Assert(milestoneSectionHeader(3, "ok", 0, true).contains("降级"))
    // 孤儿：披露但不报警
    @Assert(milestoneSectionHeader(2, "ok", 1, false).contains("已停用项目"))
    // 真的没有：明说「暂无」，不能留一段空白让人以为出错了
    let empty = milestoneSectionHeader(0, "ok", 0, false)
    @Assert(empty.contains("## 里程碑"))
    @Assert(empty.contains("暂无"))
    @Assert(!empty.contains("读不出来"))
    // 正常有数据：只有小节标题，不要任何「暂无」
    let normal = milestoneSectionHeader(3, "ok", 0, false)
    @Assert(normal.contains("## 里程碑"))
    @Assert(!normal.contains("暂无"))
}

/// #187 回归：报告里的语言分布小节，采集失败也必须出现（恒发，不靠「有内容才发」）。
///
/// 负控（曾真实发红）：小节写成 `if (langs.size > 0)`，
/// 于是全部项目语言采集失败时**整节连同失败披露一起消失** ——
/// 报告里既没有语言分布，也没有任何「没采到」的痕迹，
/// 读者只能理解成「这个项目群就是没有这些语言」。
@Test
func testReportLanguageSectionSurvivesTotalCollectionFailure(): Unit {
    // 场景一：languages 空 + 全部采集失败 → 小节必须在，且必须写明失败
    let dash = Json.obj()
    Json.set(dash, "languages", JArr(ArrayList<JsonValue>()))
    Json.set(dash, "languagesTruncated", Json.of(false))
    Json.set(dash, "languagesFailed", Json.of(3))
    Json.set(dash, "projects", dashProjectsJson(2, 0))
    let md = renderReportMarkdown(ArrayList<JsonValue>(), dash, "zh")
    @Assert(md.contains("## 语言分布"))
    @Assert(md.contains("3 个项目语言采集失败"))
    @Assert(md.contains("未采集到任何项目的语言数据"))

    // 场景二：真的「一个语言都没有」且没有失败 → 不该凭空造小节
    let dash2 = Json.obj()
    Json.set(dash2, "languages", JArr(ArrayList<JsonValue>()))
    Json.set(dash2, "languagesTruncated", Json.of(false))
    Json.set(dash2, "languagesFailed", Json.of(0))
    Json.set(dash2, "projects", dashProjectsJson(2, 0))
    let md2 = renderReportMarkdown(ArrayList<JsonValue>(), dash2, "zh")
    @Assert(!md2.contains("## 语言分布"))

    // 场景三：有语言 + 部分失败 → 分布照给，失败另起一行
    let dash3 = Json.obj()
    let langs = ArrayList<JsonValue>()
    let one = Json.obj()
    Json.set(one, "language", Json.of("Rust"))
    Json.set(one, "count", Json.of(3))
    langs.add(one)
    Json.set(dash3, "languages", JArr(langs))
    Json.set(dash3, "languagesTruncated", Json.of(false))
    Json.set(dash3, "languagesFailed", Json.of(1))
    Json.set(dash3, "projects", dashProjectsJson(2, 1))
    let md3 = renderReportMarkdown(ArrayList<JsonValue>(), dash3, "zh")
    @Assert(md3.contains("Rust (3)"))
    @Assert(md3.contains("1 个项目语言采集失败"))
}

/// 契约C 消费侧（报告）：untrackedError 非空时，项目详情的未跟踪行与
/// 项目群总览的未跟踪行都必须披露「读不到」—— 采集失败时 untrackedCount=0，
/// 不说破就会被读成「工作面干净」（不变量 17：数据里有 ≠ 用户看得到）。
///
/// 走真实 renderReportMarkdown；statuses / dash 按真实形状手搓 ——
/// 「untrackedError 非空且 status 成功」在磁盘上构造不出来（能让
/// `git ls-files --others` 失败的确定性手段都会先让 `git status --porcelain`
/// 失败 ⇒ REPO_UNREADABLE，status 条目整个变错误桩），与
/// testReportLanguageSectionSurvivesTotalCollectionFailure 的做法同族。
@Test
func testReportDisclosesUntrackedReadFailurePerProjectAndInSummary(): Unit {
    // 项目条目：按 projectStatus 的真实形状（untrackedError 恒发，空串 = 正常）
    let okS = Json.obj()
    Json.set(okS, "name", Json.of("rep-ok"))
    Json.set(okS, "branches", JArr(ArrayList<JsonValue>()))
    Json.set(okS, "userDirtyCount", Json.of(0))
    Json.set(okS, "untrackedCount", Json.of(3))
    Json.set(okS, "untrackedError", Json.of(""))
    Json.set(okS, "stashCount", Json.of(0))
    let badS = Json.obj()
    Json.set(badS, "name", Json.of("rep-ut"))
    Json.set(badS, "branches", JArr(ArrayList<JsonValue>()))
    Json.set(badS, "userDirtyCount", Json.of(0))
    Json.set(badS, "untrackedCount", Json.of(0))
    Json.set(badS, "untrackedError", Json.of("git ls-files --others 失败：fatal: index file corrupt"))
    Json.set(badS, "stashCount", Json.of(0))

    let dash = dashProjectsJson(2, 0)
    let work = Json.obj()
    Json.set(work, "branches", Json.of(0))
    Json.set(work, "mergeCandidates", Json.of(0))
    Json.set(work, "untrackedFiles", Json.of(3))   // 只有 rep-ok 的 3 个
    Json.set(work, "untrackedFailed", Json.of(1))
    let utReasons = ArrayList<JsonValue>()
    utReasons.add(Json.of("git ls-files --others 失败：fatal: index file corrupt"))
    Json.set(work, "untrackedFailedReasons", JArr(utReasons))
    Json.set(work, "stashes", Json.of(0))
    Json.set(dash, "work", work)

    let md = renderReportMarkdown(ArrayList<JsonValue>([okS, badS]), dash, "zh")
    // 项目详情：rep-ut 的 ⚠ 行在，且原因要带上（只说「读不到」等于让读者猜）
    @Assert(md.contains("- ⚠ **未跟踪文件数读不到**"))
    @Assert(md.contains("不是「没有未跟踪文件」"))
    @Assert(md.contains("fatal: index file corrupt"))
    // 汇总行：披露必须在，总览表的「未跟踪文件 | 3」不再是整个项目群的口径
    @Assert(md.contains("1 个项目的未跟踪文件数读不到，未计入上一行"))

    // en 分支（报告的双语另一半）
    let mdEn = renderReportMarkdown(ArrayList<JsonValue>([okS, badS]), dash, "en")
    @Assert(mdEn.contains("- ⚠ **untracked file count unreadable**"))
    @Assert(mdEn.contains("not \"no untracked files\""))
    @Assert(mdEn.contains("unreadable for 1 project"))

    // 对照：健康态（untrackedError 全空 + untrackedFailed=0）两个出口零噪音
    Json.set(badS, "untrackedError", Json.of(""))
    Json.set(work, "untrackedFailed", Json.of(0))
    Json.set(work, "untrackedFailedReasons", JArr(ArrayList<JsonValue>()))
    let mdClean = renderReportMarkdown(ArrayList<JsonValue>([okS, badS]), dash, "zh")
    @Assert(!mdClean.contains("未跟踪文件数读不到"))
    @Assert(!mdClean.contains("未计入上一行"))
}

/// 造一个只够 renderReportMarkdown 用的 projects 摘要块。
private func dashProjectsJson(total: Int64, failed: Int64): JsonValue {
    let p = Json.obj()
    Json.set(p, "total", Json.of(total))
    Json.set(p, "listed", Json.of(total - failed))
    Json.set(p, "registered", Json.of(total))
    Json.set(p, "excludedDisabled", Json.of(0))
    Json.set(p, "failed", Json.of(failed))
    let w = Json.obj()
    Json.set(w, "branches", Json.of(0))
    Json.set(w, "untrackedFiles", Json.of(0))
    Json.set(w, "stashes", Json.of(0))
    Json.set(w, "mergeCandidates", Json.of(0))
    let o = Json.obj()
    Json.set(o, "projects", p)
    Json.set(o, "work", w)
    let ms = Json.obj()
    let counts = Json.obj()
    Json.set(counts, "open", Json.of(0))
    Json.set(counts, "done", Json.of(0))
    Json.set(counts, "dropped", Json.of(0))
    Json.set(counts, "unknown", Json.of(0))
    Json.set(ms, "counts", counts)
    Json.set(ms, "items", JArr(ArrayList<JsonValue>()))
    Json.set(o, "milestones", ms)
    return o
}
