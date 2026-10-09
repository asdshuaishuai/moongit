// Agent 接口：为上层 AI 实现（deepDolphin.app / 未来的 deepDesign 式层）提供
// 「所需的一切」——预算内的 markdown 上下文包 + 可执行工具清单。
// 引擎本身是 AI 无关的：这里只做确定性的事实组装与裁剪。
package moongit.flow

import std.collection.*
import std.env.*
import moongit.kernel.*
import moongit.util.*
import std.unittest.*
import std.unittest.testmacro.*

public let AGENT_DEFAULT_BUDGET: Int64 = 12000
public let AGENT_MIN_BUDGET: Int64 = 500
public let AGENT_MAX_BUDGET: Int64 = 200000

/// 上下文字符预算的唯一收敛点。
///
/// 三个调用面（CLI --budget / HTTP ?budget= / MCP budget）此前各写各的：
///   - HTTP 有 clamp，CLI 和 MCP 都没有；
///   - HTTP 解析失败静默回退默认值，CLI 直接报错。
/// 结果是同一个参数值在不同入口得到不同结果，且越界值无人拦：
/// 实测 MCP 传 budget=0 或 -5000 得到空上下文，却回报 isError=false ——
/// agent 会以为「这个项目没有上下文」，而不是「参数被你悄悄改成了 0」。
///
/// 越界按 clamp 处理（用户意图是「更多」，压回合理区间即可）；
/// 非整数是参数本身写错了，由调用方各自报错，不在这里兜。
public func clampAgentBudget(budget: Int64): Int64 {
    if (budget < AGENT_MIN_BUDGET) {
        return AGENT_MIN_BUDGET
    }
    if (budget > AGENT_MAX_BUDGET) {
        return AGENT_MAX_BUDGET
    }
    return budget
}

func projectByName(projects: ArrayList<ProjectEntry>, idOrName: String): Option<ProjectEntry> {
    for (p in projects) {
        if (p.id == idOrName || p.name == idOrName) {
            return Some(p)
        }
    }
    return None
}

/// 单项目上下文小节（输入为 allProjectStatuses 的条目）
func projectContextSection(s: JsonValue, budget: Int64): String {
    let sb = StringBuilder()
    let name = Json.strAt(s, "name", "")
    sb.append("### ${name}\n\n")
    if (Json.has(s, "error")) {
        sb.append("- 状态获取失败：${Json.strAt(s, "error", "")}\n")
        return truncateContextForBudget(sb.toString(), budget, projectSectionCutNotice(budget))
    }
    sb.append("- 路径：${Json.strAt(s, "path", "")}${if (Json.strAt(s, "kind", "") == "git") { "" } else { "（非 git）" }}\n")
    sb.append("- 现状：${Json.strAt(s, "headline", "")}\n")
    let currentBranch = Json.strAt(s, "currentBranch", "")
    if (!currentBranch.isEmpty()) {
        sb.append("- 分支：当前 ${currentBranch} · 默认 ${Json.strAt(s, "defaultBranch", "")}\n")
    }
    // 脉搏
    let notes = ArrayList<String>()
    let dirty = Json.intAt(s, "userDirtyCount", 0)
    let untracked = Json.intAt(s, "untrackedCount", 0)
    let stash = Json.intAt(s, "stashCount", 0)
    let worktrees = Json.intAt(s, "worktreeCount", 0)
    if (dirty > 0) {
        notes.add("未提交 ${dirty}")
    }
    if (untracked > 0) {
        notes.add("未跟踪 ${untracked}")
    }
    if (stash > 0) {
        notes.add("stash ${stash}")
    }
    if (worktrees > 1) {
        notes.add("工作区 ×${worktrees}")
    }
    match (Json.get(s, "mergeHint")) {
        case Some(mh) =>
            let kind = Json.strAt(mh, "kind", "")
            if (kind == "fast-forward" || kind == "merge") {
                notes.add(Json.strAt(mh, "description", ""))
            }
        case None => ()
    }
    if (notes.size > 0) {
        sb.append("- 脉搏：${joinStrings(notes, " · ")}\n")
    }
    // 提交构成
    let cts = Json.arrAt(s, "commitTypes")
    if (cts.size > 0) {
        let parts = ArrayList<String>()
        for (ct in cts) {
            parts.add("${Json.strAt(ct, "type", "")} ×${Json.intAt(ct, "count", 0)}")
        }
        // 交给 AI 的上下文里必须带上分母。不带的话模型会把这当成项目全貌：
        // 实测 23 提交（feat 20/fix 2/chore 1）报成 feat×12，
        // 模型据此得出「52% 是 feat」，而实际是 87%。
        let scope = if (Json.boolAt(s, "commitTypesTruncated", false)) {
            "近 ${sampleSize(cts)}/${Json.intAt(s, "commitCount", 0)} 条，非全量"
        } else {
            "全部 ${Json.intAt(s, "commitCount", 0)} 条"
        }
        sb.append("- 提交构成（${scope}）：${joinStrings(parts, " · ")}\n")
    }
    // 分支表
    let branches = Json.arrAt(s, "branches")
    if (branches.size > 0) {
        sb.append("\n| 分支 | 状态 | 待记录 | 最近提交 |\n|---|---|---|---|\n")
        for (b in branches) {
            let isCurrent = Json.boolAt(b, "isCurrent", false)
            let isDefault = Json.boolAt(b, "isDefault", false)
            let marker = if (isCurrent) { "▸" } else { if (isDefault) { "★" } else { "" } }
            // 同 report：分支名与提交标题都过 mdCell，防止撑破 4 列表格
            sb.append("| ${marker}${mdCell(Json.strAt(b, "name", ""))} | ${Json.strAt(b, "statusLabel", "")} | ${Json.intAt(b, "pendingCommits", 0)} | ${mdCell(Json.strAt(b, "headAgo", "") + " " + Json.strAt(b, "headSubject", ""))} |\n")
        }
    }
    // ⚠️ 原来这里是裸 `safeSlice(…, budget)`：按字节切，零披露（#190）。
    // 表格被劈成孤零零的 `|`，AI 读成「这个项目没有分支」。
    return truncateContextForBudget(sb.toString(), budget, projectSectionCutNotice(budget))
}

/// 组装 agent 上下文包。
/// scope=group：总览 + 每项目速览；scope=project&name=X：单项目深上下文（含日志/里程碑）。
/// `context --json` 的 scope 合法取值。默认（未给 scope）是 `group`。
/// ⚠️ 必须是 `let` 而不是 `const`：`Array<String>` 不是编译期常量表达式
/// （`const` 会报 "expressions of type 'Array' are not constant"）。
public let AGENT_SCOPES: Array<String> = ["group", "project"]

/// scope + name 组合的校验结果。**纯判定，不碰 IO** ——
/// 调用方只负责把结果翻成自己的退出码/错误文案，判定本身可以单测。
///
/// ⚠️ 原来三个问题叠在一起，且都能让调用方拿到「看起来成功、其实不是要的东西」的响应：
///   1. scope 完全不校验。`?scope=garbage` 落进 `buildAgentContext` 的 else 分支
///      按 group 处理，**并把 "garbage" 原样回显到响应的 scope 字段** ——
///      调用方看到自己传的值，也无从知道引擎实际按 group 跑了。
///   2. 只给 `?name=X` 不给 scope 时，name 被**静默丢弃**，返回全项目群上下文。
///      调用方问的是单个项目，拿到的是整个项目群，预算还可能因此超支。
///   3. `?scope=project&name=<不存在>` 返回 HTTP 200 + `context: "未找到项目：X"`，
///      把「查无此项」包装成成功响应（与 #119 get_project_context 同一族）。
///      —— 这三条描述的是**删除前** HTTP 路由的行为；今天 `cmdContext` 走同一条判定。
public enum ContextScopeCheck {
    | Ok
    | BadScope(String)             // 400
    | MissingName                  // 400：scope=project 却没给 name
    | NameWithoutProjectScope      // 400：给了 name 却没说 scope=project
}

public func checkContextScope(scope: String, name: String): ContextScopeCheck {
    if (!scope.isEmpty() && scope != "group" && scope != "project") {
        return ContextScopeCheck.BadScope(scope)
    }
    // 有效 scope 只有一个：project。它必须配 name。
    let effective = if (scope.isEmpty()) { "group" } else { scope }
    if (effective == "project") {
        return if (name.isEmpty()) { ContextScopeCheck.MissingName } else { ContextScopeCheck.Ok }
    }
    // group 下给 name 是语义冲突：调用方问的是单个项目，
    // 静默按 group 跑就是拿整群答案冒充单项目答案。必须报错，不能装作没看见。
    return if (name.isEmpty()) { ContextScopeCheck.Ok } else { ContextScopeCheck.NameWithoutProjectScope }
}

public func buildAgentContext(
    projects: ArrayList<ProjectEntry>, config: Config,
    scope: String, name: String, budget: Int64,
): String {
    let targets = ArrayList<ProjectEntry>()
    if (scope == "project") {
        match (projectByName(projects, name)) {
            case Some(p) => targets.add(p)
            case None => return "未找到项目：${name}"
        }
    } else {
        for (p in projects) {
            if (!p.disabled) {
                targets.add(p)
            }
        }
    }

    let statuses = allProjectStatuses(targets, config, false)
    let dash = buildDashboard(targets, config)
    let sb = StringBuilder()

    sb.append("# moonGit 项目群上下文\n\n")
    sb.append("> 生成于 ${formatDateTime(nowIso())} · 引擎为 AI 无关内核，以下为确定性事实\n\n")

    // ⚠️ 存储损坏必须在**第一屏**说，不能只躺在某个项目的字段里。
    // progress.json 读不出来时，status 照样给出一份「正常」对象
    // （branches=0、commitCount=0），而告警只走 stderr —— 模型看不见 stderr。
    // 模型于是会读出「这些项目都没有历史」，甚至建议「开始记录进度」。
    // 方向反了：该做的是「先修复存储」，而它更需要知道有东西坏了。
    var degradedNames = ArrayList<String>()
    for (st in statuses) {
        let sh = Json.strAt(st, "storeHealth", "ok")
        if (sh != "ok") {
            degradedNames.add("${Json.strAt(st, "name", "?")}（${sh}）")
        }
    }
    if (!degradedNames.isEmpty()) {
        sb.append("> ⚠ ${degradedNames.size} 个项目的进度存储读不出来（${joinStrings(degradedNames, "、")}）。\n")
        sb.append("> 这些项目的分支/提交数**不是 0，是读不到**。请先按 stderr 里的「已保留副本」提示恢复存储，\n")
        sb.append("> 不要据此判断「这些项目没有历史」，更不要新建进度库覆盖它。\n\n")
    }

    if (scope == "group") {
        let projs = Json.getOr(dash, "projects")
        let work = Json.getOr(dash, "work")
        // ⚠️ dash.projects.total 是**采集成功**的个数，不是注册总数。
        // 直接把它渲染成「项目 N 个」，实测两个项目全部采集失败时：
        //   - 总览写「项目 0 个」
        //   - 紧接着「项目速览」却列出 ### bad / ### good 两个小节
        // 自相矛盾，而 AI 读到的是**第一行** —— 它会认定「这个项目群是空的」，
        // 甚至据此去新建项目。这正是「部分口径被当成全量口径」：
        // 数字本身没错（0 个采集成功），错的是它自称的口径。
        //
        // listed/failed 一直在同一份 JSON 里，只是渲染时没用。
        // 修法是让口径自己说出来，而不是改字段名（改 envelope 是破坏性变更）。
        let okCount = Json.intAt(projs, "total", 0)
        let failed = Json.intAt(projs, "failed", 0)
        let projCountText = if (failed > 0) {
            "项目 ${okCount} 个（另 ${failed} 个采集失败，未计入下列统计）"
        } else {
            "项目 ${okCount} 个"
        }
        sb.append("## 总览\n\n")
        sb.append("- ${projCountText} · 近 7 天活跃 ${Json.intAt(projs, "active7d", 0)} · 有未提交改动 ${Json.intAt(projs, "dirty", 0)}\n")
        sb.append("- 分支 ${Json.intAt(work, "branches", 0)} · 待合入 ${Json.intAt(work, "mergeCandidates", 0)} · 未跟踪文件 ${Json.intAt(work, "untrackedFiles", 0)} · stash ${Json.intAt(work, "stashes", 0)}\n\n")
        sb.append("## 项目速览\n\n")
        // ⚠️ 必须**整段**保留并显式披露舍弃了谁。
        //
        // 旧实现把全部段落拼起来，最后对整体做一次 safeSlice：
        //   - 每段先按 budget/项目数 各自腰斩（5 个项目、600 预算 = 每段 120 字节，
        //     产出「- 提」这种半句残文，AI 会当成事实读）
        //   - 尾部再被整体裁掉：总览写「项目 5 个」而正文只剩 3 个 ### 小节，
        //     p4/p5 彻底消失，全文没有任何省略/截断提示
        // AI 据此会得出「这个项目群只有 3 个项目」—— 而它连被裁掉的事实都没见过。
        //
        // 做法：逐段贪心装配，装不下的**整段跳过并记账**，
        // 尾部统一披露被舍弃的项目名 + 如何单独获取。
        //
        // 预留量不能写死：写死 220 字节时，600 预算下头部就吃掉 300、
        // 5 个项目**一个都放不下**，AI 拿到零内容 —— 诚实但没用。
        // 改成两趟：先按最小预留贪心装，再按**实际**披露长度回退必要的末尾段，
        // 直到「头部 + 正文 + 披露」三者之和确实放得下。
        let NOTICE_BASE: Int64 = 60
        let perBudget = if (statuses.size > 0) { budget / statuses.size } else { budget }
        let headLen: Int64 = sb.toString().size
        let sections = ArrayList<String>()
        let names = ArrayList<String>()
        var used: Int64 = 0
        for (s in statuses) {
            let section = projectContextSection(s, perBudget)
            if (headLen + used + section.size + 1 > budget - NOTICE_BASE) {
                break   // 各段体量相近，后面的只会更装不下
            }
            sections.add(section)
            names.add(Json.strAt(s, "name", "?"))
            used += section.size + 1
        }
        // 尾部披露（列出没装下的项目）
        var omitted = collectOmitted(names.size, statuses)
        // 披露行装不下时往回退段。方向性陷阱：退掉一段会让 omitted 变大、
        // 披露行**变长**，所以「退段腾空间」并不总能收敛。原实现在这里退光所有段后
        // 直接退出，而那恰恰是披露最长的时候 —— 披露随后被 safeSlice 整块裁掉，
        // 也就是下面注释承诺「一定出现」的那句话反而没了。
        //
        // 现在的收敛顺序：退段 → 仍装不下则换更短的披露形态 → 照发。
        while (sections.size > 0 &&
               headLen + used + omittedNotice(omitted, budget).size > budget) {
            sections.remove(at: sections.size - 1)
            names.remove(at: names.size - 1)
            used = 0
            for (sec in sections) {
                used += sec.size + 1
            }
            omitted = collectOmitted(names.size, statuses)
        }
        for (sec in sections) {
            sb.append(sec)
            sb.append("\n")
        }
        if (omitted.size > 0) {
            // assembleOmittedNotice 永远返回非空：披露被静默丢弃
            // = AI 得出「这些项目没有内容」= 事实性谎言；
            // 超出软预算几十字节只是不整齐，代价小得多。
            sb.append(assembleOmittedNotice(omitted, budget, budget - headLen - used))
        }
    } else {
        let ms = buildMilestoneOverview(targets, config)
        let items = Json.arrAt(ms, "items")
        for (s in statuses) {
            let name2 = Json.strAt(s, "name", "")
            sb.append(projectContextSection(s, budget / 2))
            let journal = Json.arrAt(s, "journal")
            if (journal.size > 0) {
                sb.append("\n### ${name2} · 进度日志（最近 ${journal.size} 条）\n\n")
                for (e in journal) {
                    sb.append("- [${Json.strAt(e, "at", "")}] ${Json.strAt(e, "mode", "")} · ${Json.strAt(e, "branch", "")}：${Json.strAt(e, "summary", "")}\n")
                }
            }
            if (items.size > 0) {
                sb.append("\n### ${name2} · 里程碑\n\n")
                for (m in items) {
                    let mProj = Json.strAt(m, "projectName", "")
                    if (mProj == name2) {
                        let target = Json.strAt(m, "targetDate", "")
                        sb.append("- ${Json.strAt(m, "name", "")}：${Json.strAt(m, "status", "")}${if (target.isEmpty()) { "" } else { "（目标 ${target}）" }}\n")
                    }
                }
            }
        }
    }

    // 整体再兜一次底，但**保留末尾若干字节**：上面装配时已经为披露行预留了
    // NOTICE_RESERVE 预算，所以正常路径下这里不会切到实质内容；
    // 这一层只防「单个项目段落本身就超预算」这种极端情况。
    // 用 safeSliceAtLine 而不是 safeSlice —— 按字节切会把最后一行劈成半句，
    // AI 读到残句会当成事实。
    // ⚠️ 原来这里是裸 `safeSliceAtLine(…, budget)`：切在行边界上，但零披露（#190）。
    // project scope 这条路径**完全没有** omittedNotice 那套机制，
    // 所以小预算下它会安静地丢掉日志/里程碑小节，只留一个空标题。
    return truncateContextForBudget(sb.toString(), budget, contextCutNotice(budget))
}

/// 从第 from 个项目起，取出没被装下的项目名（限长，避免披露行自己超预算）
func collectOmitted(from: Int64, statuses: ArrayList<JsonValue>): ArrayList<String> {
    let out = ArrayList<String>()
    for (i in from..statuses.size) {
        out.add(oneLineClamped(Json.strAt(statuses[i], "name", "?"), 24))
    }
    return out
}

/// 「哪些项目没展示」的披露行。内容必须说清两件事：
/// 没展示的是什么、怎么单独取 —— 否则 AI 会把「预算不够」读成「这些项目没内容」。
///
/// 披露分三级，按「还放得下多少」降级（见 assembleOmittedNotice）：
///   全名 → 前几个 + 总数 → 只有总数
/// 三级都带总数，所以无论降到哪一级，AI 都知道**漏了几个**。
///
/// ⚠️ 原实现只有一级（全名），而全名长度与被舍弃的项目数成正比。
/// 调用方的退段循环于是方向反了：退掉一段 → omitted 变大 → 披露变长 → 更装不下，
/// 循环退光所有段后退出时披露恰恰最长，随后被 safeSlice 按行整块裁掉 ——
/// 正是这里承诺「一定出现」的那句话。
///
/// 实测（budget=500）：项目数 1–6 披露完整；≥7 起「用 get_project_context 单独获取」
/// 这半句被裁掉（输出反而从 492 缩到 391 字节）；20 个项目时披露**整行消失**，
/// 只剩 265 字节的头部 + 「项目 20 个」的总览 —— AI 于是得出「这 20 个项目都没有内容」。
private const MAX_OMITTED_NAMES: Int64 = 3

func omittedNotice(omitted: ArrayList<String>, budget: Int64): String {
    if (omitted.size == 0) {
        return ""
    }
    return "\n> ⚠ 上下文预算 ${budget} 字符已用尽，以下 ${omitted.size} 个项目未展示：${joinStrings(omitted, "、")}\n" +
        "> 这不是「这些项目没有内容」—— 请用 get_project_context 单独获取（params: name）。\n"
}

func omittedNoticeBounded(omitted: ArrayList<String>, budget: Int64): String {
    if (omitted.size == 0) {
        return ""
    }
    return "\n> ⚠ 上下文预算 ${budget} 字符已用尽，${omitted.size} 个项目未展示（前几个：" +
        joinStrings(omitted[0..MAX_OMITTED_NAMES], "、") + " 等）。这不是「它们没有内容」—— " +
        "请用 get_project_context 单独获取（params: name）。\n"
}

/// 披露的**兜底**形态：预算已经不允许放任何项目正文时用的一行版。
/// 仍然要说清「有东西没展示 + 去哪拿」—— 这是整个模块存在的理由。
func minimalOmittedNotice(omitted: ArrayList<String>): String {
    if (omitted.size == 0) {
        return ""
    }
    return "\n> ⚠ 预算已用尽，${omitted.size} 个项目未展示（用 get_project_context 按 name 单独获取）\n"
}

/// 按「放得下多少」选披露形态。返回的形态**一定**能放进 remaining。
/// 极端情况下（连一行都放不下）返回极简版 —— 宁可超预算几字节，
/// 也不能把披露丢掉：丢了 AI 就得出「这些项目没有内容」，那是事实性谎言。
private func assembleOmittedNotice(omitted: ArrayList<String>, budget: Int64, remaining: Int64): String {
    if (omitted.size == 0) {
        return ""
    }
    let full = omittedNotice(omitted, budget)
    if (full.size <= remaining) {
        return full
    }
    if (omitted.size > MAX_OMITTED_NAMES) {
        let bounded = omittedNoticeBounded(omitted, budget)
        if (bounded.size <= remaining) {
            return bounded
        }
    }
    return minimalOmittedNotice(omitted)
}

/// 按预算截断并**如实披露**。**纯函数**。
///
/// ⚠️ 这里替换掉的是两处裸切片（缺陷 #190），它们各自都在撒谎：
///   1. `projectContextSection` 末尾的 `safeSlice(…, budget)` —— 按**字节**切，
///      于是 Markdown 表格被劈成一行孤零零的 `|`。
///   2. 整篇的 `safeSliceAtLine(…, budget)` —— 切在行边界上，但**零披露**。
/// 实测（budget=500，单项目，真实二进制）：AI 收到
///     | 分支 | 状态 | 待记录 | 最近提交 |
///     |---|---|---|---|
///     |                                     ← 零行，而该项目实际有 7 个分支
///     ### big · 进度日志（最近 1 条）         ← 声称 1 条，下面却一条都没有
/// 外加没有任何提示说内容被砍过。两张表都在说「这个项目没有这些」。
///
/// 披露行必须**留得下**：先给披露预留字节，再按行边界回退正文。
/// 顺序反了就会退化成「披露被自己挤掉」—— 那正是这里原来什么都不说的原因。
public func truncateContextForBudget(text: String, budget: Int64, notice: String): String {
    if (budget <= 0) {
        return notice
    }
    if (text.size <= budget) {
        return text
    }
    // 披露行本身要算进预算，否则「说了但说不完」等于没说。
    //
    // ⚠️ 极端情况（预算比披露还小）只能二选一：超预算，还是闭嘴。
    // 这里选**超预算** —— 与 assembleOmittedNotice 同一个取舍：
    // 披露被静默丢弃 = AI 得出「这里没有内容」= 事实性谎言；
    // 超出软预算几十字节只是不整齐，代价小得多。
    let room = budget - notice.size - 1
    if (room <= 0) {
        return notice
    }
    var head = safeSliceAtLine(text, room)
    if (head.isEmpty()) {
        // 连第一行都放不下：宁可只给披露，也不要给一句残句冒充事实
        return notice
    }
    // ⚠️ 剥离后若**什么都不剩**，必须保留原样。
    // group 路径的 perBudget 很小时（600/5=120），剥掉悬空标题后整段只剩披露行，
    // 于是「一个项目都不展示」—— 诚实但没用，比不给还糟。
    // 一个只有标题的小节仍然有用：它至少告诉读者「这里有个项目」，
    // 而且披露行照样跟在后面，不会被误读成「这个项目没有内容」。
    let trimmed = dropDanglingBlockStart(head)
    if (!trimmed.isEmpty()) {
        head = trimmed
    }
    return head + "\n" + notice
}

/// 丢掉正文末尾「悬空的结构行」。
///
/// ⚠️ 行边界切**不够**：切点正好落在小节标题之后，就会留下
///     ### big · 进度日志（最近 1 条）
/// 下面什么都没有 —— 而标题里的「1 条」是实打实的断言。
/// 表格同理：留下表头 + 分隔线 + 零数据行，读者只会得出「这个项目没有分支」。
/// 这两种残骸**结构完整、内容说谎**，比半句残文危险得多。
/// 规则：从尾部往前删，删到最后一行不是小节标题、也不是表格行为止。
private func dropDanglingBlockStart(text: String): String {
    var lines = text.split("\n")
    // 去掉尾部空行，否则「最后一行」永远是空串
    while (lines.size > 0 && lines[lines.size - 1].trimAscii().isEmpty()) {
        lines = lines[..lines.size - 1]
    }
    while (lines.size > 0) {
        let t = lines[lines.size - 1].trimAscii()
        if (t.startsWith("###") || t.startsWith("|")) {
            lines = lines[..lines.size - 1]
        } else {
            break
        }
    }
    let sb = StringBuilder()
    for (l in lines) {
        sb.append(l)
        sb.append("\n")
    }
    return sb.toString()
}

/// 项目小节被预算截断时的披露。
public func projectSectionCutNotice(budget: Int64): String {
    return "> ⚠ 预算 ${budget} 字符，本项目小节已截断（下面不是全部）"
}

/// 整篇上下文被预算截断时的披露。
public func contextCutNotice(budget: Int64): String {
    return "> ⚠ 上下文预算 ${budget} 字符已用尽，以上内容不完整（被截掉的部分不会出现在这里）"
}

/// 按行截断：不切断最后一行。
/// safeSlice 按字节切，会把「- 提」这种半句留给 AI；
/// 宁可少给一行，也不能给出读起来完整的假事实。
public func safeSliceAtLine(s: String, maxBytes: Int64): String {
    if (s.size <= maxBytes) {
        return s
    }
    if (maxBytes <= 0) {
        return ""
    }
    let cut = charBoundaryAt(s, maxBytes)
    let head = s[..cut]
    match (head.lastIndexOf("\n")) {
        case Some(i) => return head[..i]
        // 连第一行都放不下完整的时候返回空串，而不是半行 ——
        // 「- 提」这种残句读起来像完整事实，AI 会当成真的。
        case None => return ""
    }
}

/// Agent 可执行的工具清单。上层 AI 把它放进 system prompt；引擎只认请求，不感知 AI。
///
/// ⚠️ 这里**只声明「有什么能力、收什么参数」，不声明「怎么调用」**。
///
/// 原来每个工具带 `method` + `path`（`GET /api/context?scope=group` …），
/// 末尾 note 还写着「由上层 AI 通过 HTTP 调用执行」。
/// HTTP 服务端已按「传输层只在本机进程之间通信、不跨网络」整体删除（AGENTS.md 第一条不变量：
/// **没有 HTTP 服务，没有 `moongit serve`，没有 `/api/*`**），
/// 于是 `moongit tools --json` 每次调用都在教 agent 去打 10 个不存在的端点。
/// 唯一没暴露的原因是客户端 `engineToolDefinitions` 只读 name/description/params，
/// 把这两列丢掉了 —— 那是调用方的将就，不是这里没坏。
///
/// 也不补一列手抄的 CLI 命令行：`git <sub> [项目]`、`milestone <sub> …` 这些
/// 语法抄进来就是**第二份「怎么到达能力 X」的人工副本**，必然和真实 CLI 漂移。
/// 这个函数栽的正是这一跟头，不该换个形式再栽一次。
/// 路由是调用方的事，且已有两处活的实现：客户端 `executeTool` 的 switch、
/// MCP 的 `mcpCallTool` 分支。
public func agentToolsManifest(): JsonValue {
    let arr = ArrayList<JsonValue>()
    func addTool(name: String, desc: String, params: String) {
        let t = Json.obj()
        Json.set(t, "name", Json.of(name))
        Json.set(t, "description", Json.of(desc))
        Json.set(t, "params", Json.of(params))
        arr.add(t)
    }

    addTool("get_group_context", "获取整个项目群的总览上下文（活跃度/改动/分支/待合入）", "")
    addTool("get_project_context", "获取单个项目的深度上下文（分支进度/脉搏/日志/里程碑）。params: name", "name")
    addTool("get_project_docs", "读取项目内 README/AGENTS/CLAUDE 原文。params: name", "name")
    addTool("get_journal", "读取项目的进度日志。params: name", "name")
    addTool("get_milestones", "列出全部里程碑及其 git 感知进度", "")
    addTool("run_shallow_update", "对项目执行浅更新：记录各分支进度并刷新文档托管区域。params: name", "name")
    addTool("run_deep_update", "对项目执行深度更新：重写 overview/architecture/commands/history。params: name", "name")
    addTool("git_commit", "提交项目的全部未提交改动。params: name, message", "name,message")
    addTool("git_pull_push", "对项目执行 git pull（--ff-only）或 push。params: name, op(pull|push)", "name,op")
    addTool("milestone_done", "把里程碑标记为达成。params: project, name", "project,name")
    addTool("codegraph_overview", "代码图谱概览（文件/符号/引用边统计）。params: name", "name")
    addTool("codegraph_tree", "索引关系树 / 全量图 JSON（文件+import边+引用边）。params: name", "name")
    addTool("codegraph_symbol", "符号定位：定义处 + 词法引用。params: name, symbol", "name,symbol")
    addTool("codegraph_impact", "影响面：改这个符号会波及哪些文件与符号（词法文件级粒度）。params: name, symbol", "name,symbol")
    addTool("codegraph_arch", "技术架构图：模块分层依赖（Canvas 交互 HTML / mermaid / dot / json）。params: name, format", "name,format")
    addTool("codegraph_patch_confidence", "补丁级置信度 Layer 1：S1..S10 信号 + uncertain 待办清单（配合 skill 做 Layer 2 复核）。params: name, patch_path", "name,patch_path")
    addTool("codegraph_patch_merge", "补丁级置信度 Layer 3：合并 algorithm+agent 输出。params: algorithm_json, agent_json", "algorithm_json,agent_json")
    addTool("codegraph_confidence", "代码置信度报告：结构性疑点（孤儿/占位/吞错/魔法数/重复体）。被动能力，仅显式调用时分析。params: name, format(json|text|llm)", "name,format")

    let o = Json.obj()
    Json.set(o, "tools", JArr(arr))
    // ⚠️ 这句 note 本身也被 `testAgentToolsManifestCarriesNoDeadEndpoint` 扫。
    // 第一版这里写的是「……没有 HTTP 服务」—— 用一句免责声明安抚读者，
    // 却被自己那条「全文不含 HTTP」的红线当场抓住：这正是它该干的活。
    // 正确的做法是**根本不提那个词**，直接说清现在有什么。
    Json.set(o, "note", Json.of(
        "引擎为 AI 无关内核；以上工具只声明能力与参数，怎么调用由调用方决定"
        + "（客户端工具循环或 MCP 宿主）。本清单不含任何端点地址 —— "
        + "传输层只有 CLI 子进程与 MCP(stdio)。"))
    return o
}

// ------------------------------ 测试 ------------------------------

@Test
func testAgentToolsManifest(): Unit {
    let m = agentToolsManifest()
    let tools = Json.arrAt(m, "tools")
    @Assert(tools.size >= 8)
    var hasContext = false
    var hasUpdate = false
    for (t in tools) {
        if (Json.strAt(t, "name", "") == "get_group_context") {
            hasContext = true
        }
        if (Json.strAt(t, "name", "") == "run_shallow_update") {
            hasUpdate = true
        }
    }
    @Assert(hasContext)
    @Assert(hasUpdate)
}

/// #175 回归：清单里不许再出现已删除的 HTTP 端点。
///
/// 负控（曾真实发红）：修复前 `tools --json` 每个工具带 `method`+`path`，
/// note 还写着「由上层 AI 通过 HTTP 调用执行」—— 10 条 `/api/*` 全部指向
/// 已整体删除的服务端，而 AGENTS.md 第一条不变量明写「没有 /api/*」。
///
/// 断言方式刻意做成**全文扫描**而不是逐字段比较：
/// 将来有人再加一列 `endpoint`/`url`/`base` 照样会被这条抓住。
@Test
func testAgentToolsManifestCarriesNoDeadEndpoint(): Unit {
    let m = agentToolsManifest()
    let text = Json.pretty(m)
    // 前提：清单非空，否则下面全是恒真（空文本当然不含 /api/）。
    @Assert(Json.arrAt(m, "tools").size >= 8)
    @Assert(!text.contains("/api/"))
    @Assert(!text.contains("HTTP"))
    @Assert(!text.contains("http://"))
    @Assert(!text.contains("localhost"))
    @Assert(!text.contains("127.0.0.1"))
    @Assert(!text.contains("serve"))
}

/// 清单的形状锁死：只声明能力与参数，**没有 method/path 两列**。
///
/// 与上一条互补：那条查内容，这条查结构 ——
/// 有人把 `path` 改名成 `endpoint` 时，上一条会红；有人把两列彻底删掉、
/// 却也把 note 里的地址一起删干净时，靠这条守住「不许再加回来」。
@Test
func testAgentToolsManifestDeclaresCapabilityNotTransport(): Unit {
    let tools = Json.arrAt(agentToolsManifest(), "tools")
    @Assert(tools.size >= 8)
    for (t in tools) {
        @Assert(Json.has(t, "name"))
        @Assert(Json.has(t, "description"))
        @Assert(Json.has(t, "params"))
        @Assert(!Json.has(t, "method"))
        @Assert(!Json.has(t, "path"))
    }
}

@Test
func testBuildAgentContextEmpty(): Unit {
    let config = Config.defaults()
    let reg = Registry()
    let ctx = buildAgentContext(reg.projects, config, "group", "", 8000)
    @Assert(ctx.contains("moonGit 项目群上下文"))
    let miss = buildAgentContext(reg.projects, config, "project", "ghost", 8000)
    @Assert(miss.contains("未找到项目"))
}

@Test
func testBuildAgentContextProject(): Unit {
    let base = "/tmp/deepgit-ctx-${nowMillis()}"
    // 隔离数据目录。必须放在仓库之外：若置于 base 内部，engine 的 store/ 目录
    // 会让 git 工作区变脏，runDeep 第二次执行就不再幂等（下方的 !anyChanged 断言会红）。
    // 不隔离则 runUpdate/runTrack/runDeep 内部按 projectId 推导出的 store 路径会落到
    // 用户真实的 ~/.deepgit/store，测试失败或被中断时还会留下孤儿目录。
    let testHome = base + "-home"   // 仓库的兄弟目录：唯一，且不在 git 工作区内
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.cj", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: 上下文测试"], false)

    let config = Config.defaults()
    let reg = Registry()
    reg.projects.add(ProjectEntry("p_ctx", "ctx-demo", base, "git", "", nowIso(), ArrayList<String>(), false))
    // 先 track 一次：分支表的主题来自进度库，从未记录过的仓库只有脉搏没有主题
    let tr = runTrack(reg.projects[0], config, "test")
    @Assert(tr.ok)
    let ctx = buildAgentContext(reg.projects, config, "project", "ctx-demo", 20000)
    @Assert(ctx.contains("ctx-demo"))
    @Assert(ctx.contains("feat: 上下文测试"))
    removePathIfExists(base)
    // 复位必须排在所有 deepgitPath(...) 之后：提前复位会让上面的清理打到真实 store
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testClampAgentBudget(): Unit {
    // 三个调用面（CLI --budget / HTTP ?budget= / MCP budget）共用的唯一收敛点。
    // 修复前只有 HTTP 有 clamp，CLI 与 MCP 越界值直接透传：
    // MCP 传 budget=0 得到空上下文却回报 isError=false。
    @Assert(clampAgentBudget(0) == AGENT_MIN_BUDGET)
    @Assert(clampAgentBudget(-5000) == AGENT_MIN_BUDGET)
    @Assert(clampAgentBudget(499) == AGENT_MIN_BUDGET)
    @Assert(clampAgentBudget(500) == 500)
    @Assert(clampAgentBudget(12000) == 12000)
    @Assert(clampAgentBudget(200000) == 200000)
    @Assert(clampAgentBudget(200001) == AGENT_MAX_BUDGET)
    @Assert(clampAgentBudget(1000000000000000) == AGENT_MAX_BUDGET)
    // 边界关系本身也要成立，否则三处对齐到的是同一个错误区间
    @Assert(AGENT_MIN_BUDGET < AGENT_DEFAULT_BUDGET)
    @Assert(AGENT_DEFAULT_BUDGET < AGENT_MAX_BUDGET)
}

/// 提交类型样本量 = 各类型计数之和（即实际被统计的提交条数）。
/// 渲染「近 N/总 M 条」时用；分母不写出来，读者只能把样本当全量。
public func sampleSize(commitTypes: ArrayList<JsonValue>): Int64 {
    var n: Int64 = 0
    for (ct in commitTypes) {
        n += Json.intAt(ct, "count", 0)
    }
    return n
}

@Test
func testAgentContextDiscardsWholeSectionsAndDiscloses(): Unit {
    // 旧实现把全部段落拼起来最后对整体做一次 safeSlice，尾部项目整段消失：
    // 总览写「项目 5 个」而正文只剩 3 个 ### 小节，全文没有任何省略提示。
    // AI 据此会得出「这个项目群只有 3 个项目」—— 而它连被裁掉的事实都没见过。
    let base = "/tmp/dg_ctx_${nowMillis()}"
    let testHome = "${base}/home"
    enterTestHome(testHome)
    ensureDir(testHome)
    ensureDir(base)
    let names = ArrayList<ProjectEntry>()
    for (i in 0..5) {
        let repo = "${base}/p${i}"
        ensureDir(repo)
        gitRun(repo, ["init", "-b", "main"], false)
        writeFileAtomic("${repo}/a.txt", "x")
        gitRun(repo, ["add", "."], false)
        gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: p${i} 初始"], false)
        let (e, _) = addProject(repo, "p${i}", ArrayList<String>(), base)
        names.add(e)
    }

    // 预算很紧：必须整段取舍 + 明确披露
    let small = buildAgentContext(names, Config.defaults(), "group", "", 600)
    @Assert(small.size <= 600)
    // 披露行必须在，且要说清是预算不够、怎么单独取
    @Assert(small.contains("未展示"))
    @Assert(small.contains("get_project_context"))
    // 总览声称 5 个；实际展示数 + 披露里点名的项目数必须等于 5
    let shown: Int64 = countLinesStartingWith(small, "### ")
    let named: Int64 = countNamesInNotice(small)
    @Assert(shown > 0)          // 不能一个都不给（诚实但没用）
    @Assert(shown + named == 5) // 自洽：不多不少
    // 不能再输出半句残文
    @Assert(!small.contains("- 提\n"))

    // 预算充足时全部展示，且**不该**出现多余的披露
    let big = buildAgentContext(names, Config.defaults(), "group", "", 20000)
    @Assert(!big.contains("未展示"))
    @Assert(countLinesStartingWith(big, "### ") == 5)

    removePathIfExists(base)
    exitTestHome()
    removePathIfExists(testHome)
}

/// 统计以 prefix 开头的行数
func countLinesStartingWith(s: String, prefix: String): Int64 {
    var n: Int64 = 0
    for (line in s.split("\n")) {
        if (line.startsWith(prefix)) {
            n += 1
        }
    }
    return n
}

/// 从披露行里读出被点名的项目个数（数名单里的「、」分隔符，不是解析数字）
func countNamesInNotice(s: String): Int64 {
    for (line in s.split("\n")) {
        if (!line.contains("个项目未展示")) {
            continue
        }
        // 取「未展示：」之后的部分 —— 必须按最后一个「：」切，
        // 前面的「⚠」「以下 4」都不能算进去
        let segs = line.split("：")
        if (segs.size < 2) {
            return 0
        }
        var names: Int64 = 0
        for (nm in segs[segs.size - 1].split("、")) {
            if (!nm.isEmpty()) {
                names += 1
            }
        }
        return names
    }
    return 0
}

@Test
func testSafeSliceAtLineKeepsWholeLines(): Unit {
    // safeSlice 按字节切，会把「- 提」这种半句留给 AI，
    // 读起来像完整事实。宁可少给一行。
    let s = "第一行内容\n第二行内容\n第三行内容\n"
    @Assert(safeSliceAtLine(s, 1000) == s)
    @Assert(safeSliceAtLine(s, 0) == "")
    let cut = safeSliceAtLine(s, 10)
    @Assert(cut.endsWith("\n") || cut.isEmpty())
    @Assert(!cut.contains("第"))
}

@Test
func testAgentDisclosureSurvivesManyProjectsAtMinimumBudget(): Unit {
    // 回归：项目数一多，披露行自己先被预算挤掉 ——
    // 而 agent.cj 的注释白纸黑字写着「必须保证『哪些项目没展示』这句话一定出现在输出里」。
    //
    // 根因是退段循环方向反了：退掉一段 → omitted 变大 → 披露行变长 → 更装不下。
    // 循环退光所有段后退出时，披露恰恰是最长的，随后被 safeSlice 按行整块裁掉。
    //
    // 实测（budget=500，本轮独立复现）：
    //   项目数 1–6  披露完整（带工具提示），输出 452→492 字节
    //   项目数 7    披露的「用 get_project_context 单独获取」半句消失，输出**反而缩到** 391
    //   项目数 20   披露**整行消失**，只剩 265 字节的头部 + 「项目 20 个」总览
    //              → AI 只能得出「这 20 个项目都没有内容」
    //
    // 已有测试用的是 5 个项目 / 600 预算，恰好落在披露放得下的区间，给了假信心。
    let base = "/tmp/dg_ctx_many_${nowMillis()}"
    let testHome = "${base}/home"
    enterTestHome(testHome)
    ensureDir(testHome)
    ensureDir(base)
    let names = ArrayList<ProjectEntry>()
    // 20 个：原实现下披露行整个消失的那个规模
    for (i in 0..20) {
        let repo = "${base}/p${i}"
        ensureDir(repo)
        gitRun(repo, ["init", "-b", "main"], false)
        writeFileAtomic("${repo}/a.txt", "x")
        gitRun(repo, ["add", "."], false)
        gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: p${i}"], false)
        let (e, _) = addProject(repo, "p${i}", ArrayList<String>(), base)
        // 必须先跑一次 update：没有进度时每个小节只有几行，
        // 20 个小节在最小预算下**全部装得下** → omitted 为空 → 本就不该有披露。
        // 披露要出现的前提是「确实装不下」，而这正是真实使用的样子。
        let r = runUpdate(e, Config.defaults(), UpdateOptions())
        @Assert(r.ok)
        names.add(e)
    }

    // 最小预算。注意：buildAgentContext 自身**不**做 clamp（clamp 在调用点），
    // 这里必须直接传 clamp 后的下限值，传 1 会让整个输出被切到 1 字节。
    let out = buildAgentContext(names, Config.defaults(), "group", "", 500)

    // 核心断言：披露与「去哪拿」这句话在任何项目数下都必须在
    @Assert(out.contains("未展示"))
    @Assert(out.contains("get_project_context"))
    // 数量必须如实：20 个项目一个都没展示时要说 20
    @Assert(out.contains("20 个项目未展示"))
    // 总览仍然声称 20 个 —— 披露的作用就是让这两者能对上
    @Assert(out.contains("项目 20 个"))
    // 不能输出半句残文
    @Assert(!out.contains("- 提\n"))

    // 中间规模同样不能塌：7 个是原实现开始丢工具提示的那个点
    let seven = ArrayList<ProjectEntry>()
    for (i in 0..7) {
        seven.add(names[i])
    }
    let out7 = buildAgentContext(seven, Config.defaults(), "group", "", 500)
    @Assert(out7.contains("未展示"))
    @Assert(out7.contains("get_project_context"))
    @Assert(out7.contains("7 个项目未展示"))

    // 预算允许被超出，但只能超一点点 ——
    // 「披露必须发出去」与「输出要受控」两个诉求的平衡点。
    // 披露被静默丢弃的代价（AI 得出事实性谎言）远大于多几十字节。
    @Assert(out.size <= 500 + 96)
    @Assert(out7.size <= 500 + 96)

    // 预算充足时不该出现披露
    let big = buildAgentContext(names, Config.defaults(), "group", "", 200000)
    @Assert(!big.contains("未展示"))
    @Assert(countLinesStartingWith(big, "### ") == 20)

    removePathIfExists(base)
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testGroupContextHeadlineStatesItsOwnDenominator(): Unit {
    // 「项目 N 个」里的 N 是**采集成功数**，不是注册总数 —— 以前没人在渲染时说破。
    //
    // 实测两个项目全部采集失败时，原输出是：
    //     ## 总览
    //     - 项目 0 个 · 近 7 天活跃 0 · 有未提交改动 0
    //     ## 项目速览
    //     ### bad
    //     - 状态获取失败：路径不存在或卷未挂载：…
    // 自相矛盾，而且 AI 读到的是**第一行**：它会认定项目群是空的，
    // 甚至据此去新建项目。数字没错，错的是它自称的口径。
    //
    // 「上限当全量」家族的变体：这次截断的不是条数而是**口径**。
    let base = "/tmp/deepgit-ctxdenom-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let repoA = base + "/a"
    let repoB = base + "/b"
    for (r in [repoA, repoB]) {
        ensureDir(r)
        gitRun(r, ["init", "-b", "main"], false)
        writeFileAtomic(r + "/a.txt", "1")
        gitRun(r, ["add", "."], false)
        gitRun(r, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)
    }
    let (pa, _) = addProject(repoA, "afail", ArrayList<String>(), "")
    let (pb, _) = addProject(repoB, "bfail", ArrayList<String>(), "")
    // 前提：两个项目确实是两个（id 不同），否则后面的「2 个」全无意义
    @Assert(pa.id != pb.id)
    @Assert(pa.path != pb.path)
    removePathIfExists(repoA)
    removePathIfExists(repoB)
    let projects = ArrayList<ProjectEntry>([pa, pb])

    // 前提：确实处于「注册了 2 个、一个都采集不到」的状态
    let st = allProjectStatuses(projects, Config.defaults(), true)
    @Assert(st.size == 2)
    @Assert(okCountOf(st) == 0)

    let ctx = buildAgentContext(projects, Config.defaults(), "group", "", 12000)
    // 旧文案：只说「项目 0 个」，读起来等于「这个项目群是空的」
    @Assert(ctx.contains("项目 0 个"))
    // 修复后必须把被排除的失败项目数说出来
    @Assert(ctx.contains("另 2 个采集失败，未计入下列统计"))
    // 且不得出现「项目 2 个」这种把失败也算进去的总数冒充
    @Assert(!ctx.contains("- 项目 2 个 ·"))

    // 对照组与部分失败组用**各自独立、从不删除**的仓库。
    // 原先在同一测试里「删掉再重建」来切换状态，结果对照组断言恒红 ——
    // 而真实二进制复刻同样的时序是完全正常的（2 成功 → 0 成功 → 2 成功），
    // 说明红的是测试自己的状态切换，不是生产代码。
    // 切换状态靠新建沙箱，不靠删了重建。
    let okA = base + "-ok/a"
    let okB = base + "-ok/b"
    let okProjects = makeTwoProjects(okA, okB, "okA", "okB")
    let okCtx = buildAgentContext(okProjects, Config.defaults(), "group", "", 12000)
    // 全部可读时不得多这句披露（不能制造噪音）
    @Assert(okCtx.contains("项目 2 个"))
    @Assert(!okCtx.contains("采集失败，未计入下列统计"))

    // 部分失败：口径必须同时给全两个数，不能只说成功的那个
    removePathIfExists(okB)
    let partialCtx = buildAgentContext(okProjects, Config.defaults(), "group", "", 12000)
    @Assert(partialCtx.contains("项目 1 个（另 1 个采集失败，未计入下列统计）"))
    // 部分失败**不算**整体失败：还有事实可用
    @Assert(groupExitCode(okCountOf(allProjectStatuses(okProjects, Config.defaults(), true)), 2) == 0)

    removePathIfExists(repoA)
    removePathIfExists(repoB)
    removePathIfExists(okA)
    removePathIfExists(okB)
    // ⚠️ `${base}-ok` 本身也必须删：okA/okB 在它**里面**，
    // 只删子目录会留下一个空的 `-ok`，每轮测试都在 /tmp 攒一个。
    // （`testHome = base + "-home"` 同理 —— 它是 base 的兄弟，不是子目录。）
    removePathIfExists(base + "-ok")
    removePathIfExists(deepgitPath(["store", pa.id]))
    removePathIfExists(deepgitPath(["store", pb.id]))
    exitTestHome()
    removePathIfExists(testHome)
    removePathIfExists(base)
}

/// 建两个各含一次提交的真实 git 仓库并注册，返回它们的 ProjectEntry。
/// 测试里「切到某种状态」的标准做法：建新的，不删了重建。
private func makeTwoProjects(dirA: String, dirB: String, nameA: String, nameB: String): ArrayList<ProjectEntry> {
    for (d in [dirA, dirB]) {
        ensureDir(d)
        gitRun(d, ["init", "-b", "main"], false)
        writeFileAtomic(d + "/a.txt", "1")
        gitRun(d, ["add", "."], false)
        gitRun(d, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)
    }
    let (a, _) = addProject(dirA, nameA, ArrayList<String>(), "")
    let (b, _) = addProject(dirB, nameB, ArrayList<String>(), "")
    return ArrayList<ProjectEntry>([a, b])
}

@Test
func testContextScopeCheckRejectsSilentSubstitution(): Unit {
    // /api/context 的 scope+name 校验。三个方向都必须显式判定，
    // 不能靠 buildAgentContext 的 else 分支「顺带」处理。
    //
    // 关键性质：**没有任何一种输入能被静默换成另一种语义**。
    // 原来 ?scope=garbage 按 group 跑并回显 "garbage"，
    // 只给 ?name=X 不给 scope 时 name 被丢弃、返回整群上下文。

    // 合法组合
    @Assert(match (checkContextScope("", "")) {
        case ContextScopeCheck.Ok => true
        case _ => false
    })
    @Assert(match (checkContextScope("group", "")) {
        case ContextScopeCheck.Ok => true
        case _ => false
    })
    @Assert(match (checkContextScope("project", "alpha")) {
        case ContextScopeCheck.Ok => true
        case _ => false
    })

    // 方向 1：未知 scope 必须判为 BadScope，且**回带原值**（错误信息要能指出传了什么）
    match (checkContextScope("garbage", "")) {
        case ContextScopeCheck.BadScope(s) => @Assert(s == "garbage")
        case _ => @Assert(false)
    }
    // 大小写不同也算非法 —— 不做隐式归一化，否则 scope:Group 与 scope:group 行为不一致
    match (checkContextScope("Group", "")) {
        case ContextScopeCheck.BadScope(_) => ()
        case _ => @Assert(false)
    }

    // 方向 2：scope=project 必须配 name
    match (checkContextScope("project", "")) {
        case ContextScopeCheck.MissingName => ()
        case _ => @Assert(false)
    }

    // 方向 3：给了 name 却没说 scope=project —— 语义冲突，必须报错而不是按 group 跑。
    // 这是最隐蔽的一种：调用方问单个项目，拿到整群答案，预算还可能超支。
    match (checkContextScope("", "alpha")) {
        case ContextScopeCheck.NameWithoutProjectScope => ()
        case _ => @Assert(false)
    }
    match (checkContextScope("group", "alpha")) {
        case ContextScopeCheck.NameWithoutProjectScope => ()
        case _ => @Assert(false)
    }

    // 负控：合法取值清单必须真的被用上，而不是各写各的字面量
    @Assert(AGENT_SCOPES.size == 2)
    @Assert(AGENT_SCOPES.contains("group"))
    @Assert(AGENT_SCOPES.contains("project"))
}

/// #190 回归：预算截断必须**披露**，且不得留下「零行表格 / 空标题」这种
/// 结构完整、内容说谎的残骸。
///
/// 负控（曾真实发红，真实二进制复现）：`context big --scope project --budget 500`
/// 的输出最后三行是
///     | 分支 | 状态 | 待记录 | 最近提交 |
///     |---|---|---|---|
///     |
///     ### big · 进度日志（最近 1 条）
/// —— 一张零行的分支表（该项目实际有 7 个分支）加一个声称 1 条却一条都没有的
/// 日志节，**且全文没有任何提示说内容被砍过**。
/// 根因是两处裸切片：项目小节按**字节**切（劈出孤零零的 `|`），
/// 整篇按行切但零披露；而 project scope 这条路径压根没有 omittedNotice 那套机制。
@Test
func testContextBudgetCutIsDisclosedAndLeavesNoLyingRemnant(): Unit {
    let base = "/tmp/deepgit-ctxcut-${nowMillis()}"
    let testHome = "${base}-home"
    let repo = "${base}/repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-q", "-b", "main"], false)
    writeFileAtomic("${repo}/a.py", "x")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "i"], false)
    enterTestHome(testHome)
    try {
        let (p, _) = addProject(repo, "cut", ArrayList<String>(), "")
        // 必须让上下文**真的**装不下 500 字符预算：原来只建 1 个分支时
        // 整篇才 200 多字节，压根不触发截断，断言「必须披露」就成了一句空话。
        // 8 个长名字分支 → 分支表足够长，正是原事故的形状。
        for (i in 0..8) {
            let bname = "feature/a-fairly-long-branch-name-number-${i}"
            gitRun(repo, ["branch", bname], false)
            gitRun(repo, ["checkout", "-q", bname], false)
            writeFileAtomic("${repo}/f${i}.py", "${i}")
            gitRun(repo, ["add", "."], false)
            gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "work on ${bname}"], false)
        }
        gitRun(repo, ["checkout", "-q", "main"], false)
        _ = runUpdate(p, Config.defaults(), UpdateOptions())   // 建基线，产出分支表与日志

        // ---- 纯函数层 ----
        let fits = truncateContextForBudget("短\n", 1000, projectSectionCutNotice(1000))
        @Assert(fits == "短\n")                     // 装得下就**不许**多嘴
        let notice = contextCutNotice(500)
        // 文本必须**真的**超过预算，否则这条断言测的是「装得下」那条分支
        let long = StringBuilder()
        for (i in 0..60) {
            long.append("第 ${i} 行内容，用来把上下文撑到超过预算的宽度\n")
        }
        let cut = truncateContextForBudget(long.toString(), 500, notice)
        @Assert(cut.contains("已用尽"))
        @Assert(cut.size <= 500)                    // 披露行也必须算进预算
        @Assert(cut.endsWith(notice))                // 披露必须在**结尾**
        @Assert(!cut.contains("第 59 行"))            // 尾部内容确实被砍掉了
        // 预算比披露本身还小：只能超预算，但**必须仍然是披露**。
        // 选「闭嘴」就等于回到缺陷本身。
        let tiny = truncateContextForBudget("aaaa\nbbbb\ncccc\n", 10, contextCutNotice(10))
        @Assert(tiny == contextCutNotice(10))
        @Assert(tiny.contains("不完整"))

        // ---- 端到端：project scope + 最小预算 ----
        let tight = buildAgentContext(ArrayList<ProjectEntry>([p]), Config.defaults(),
                                      "project", "cut", AGENT_MIN_BUDGET)
        @Assert(tight.size <= AGENT_MIN_BUDGET)
        // 关键：必须说出内容不完整
        @Assert(tight.contains("不完整") || tight.contains("已用尽"))
        // 不得留下「只有表头的零行表格」—— 那读起来就是「这个项目没有分支」
        @Assert(!trimmedTableHeaderIsEmpty(tight))
        // 不得留下「标题说 N 条、下面 0 条」的日志节
        @Assert(!emptyJournalSection(tight))

        // ---- 反向：预算充足时不得谎报 ----
        let roomy = buildAgentContext(ArrayList<ProjectEntry>([p]), Config.defaults(),
                                      "project", "cut", 20000)
        @Assert(!roomy.contains("已用尽"))
    } finally {
        exitTestHome()
        removePathIfExists(base)
        removePathIfExists(testHome)
    }
}

/// 输出里有没有「表头 + 分隔线、却零数据行」的表格。
private func trimmedTableHeaderIsEmpty(text: String): Bool {
    let lines = text.split("\n")
    var i = 0
    while (i < lines.size) {
        if (lines[i].trimAscii().startsWith("| 分支 |")) {
            if (i + 1 < lines.size && lines[i + 1].trimAscii().startsWith("|---")) {
                let first = if (i + 2 < lines.size) { lines[i + 2].trimAscii() } else { "" }
                if (!first.startsWith("|") || first == "|") {
                    return true
                }
            }
        }
        i += 1
    }
    return false
}

/// 有没有「### …进度日志（N 条）」这种声称有内容、下面却空着的节。
private func emptyJournalSection(text: String): Bool {
    let lines = text.split("\n")
    var i = 0
    while (i < lines.size) {
        let t = lines[i].trimAscii()
        if (t.startsWith("### ") && t.contains("进度日志")) {
            var j = i + 1
            while (j < lines.size && lines[j].trimAscii().isEmpty()) {
                j += 1
            }
            if (j >= lines.size || !lines[j].startsWith("- ")) {
                return true
            }
        }
        i += 1
    }
    return false
}
