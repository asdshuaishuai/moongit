// 状态聚合：CLI / Web / macOS 菜单栏三端共用的单一事实源。
package moongit.flow

import std.collection.*
import std.env.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.kernel.*
import moongit.util.*

public func projectStatus(project: ProjectEntry, config: Config, journalLimit: Int64): JsonValue {
    let facts = collectFacts(project.path, project.kind, config, 15, false)
    let progress = readProgress(project.id)
    let state = readState(project.id)
    // ⚠️ 多读 1 条只为判断是否被截断。
    // 原来只读 journalLimit 条，于是 status --json 的 journal 数组长度
    // 恰好等于上限时，调用方无法区分「这个项目只有这么多记录」与
    // 「有更多但被砍掉了」—— 而这正是「上限当全量」这一族的第 15 处。
    // 渲染侧（cmdStatus 文本路径）连提示都没有，直接 `if (i >= 5) break` 收工。
    let (journal, journalBad) = readJournalWithStats(project.id, journalLimit + 1)
    let journalTruncated = journal.size > journalLimit
    if (journalTruncated) {
        // 砍掉那条多读出来的探测项，只留 limit 条
        while (journal.size > journalLimit) {
            journal.remove(at: journal.size - 1)
        }
    }

    let o = Json.obj()
    // ⚠️ 存储健康必须随状态一起出去。
    // progress/state 读不出来时，本函数照样返回一份「正常」的状态对象
    // （branches=0、commitCount=0），而告警只走 stderr：
    // MCP 走 stdout、HTTP 走响应体、status --json 走 stdout —— 三边都看不见。
    // 程序化调用方只会得出「这项目是新的」，而事实是历史存在但读不出来。
    // 三态而不是 Bool：Corrupt 至少留了 .corrupt 副本可恢复，Unreadable 没有。
    Json.set(o, "storeHealth", Json.of(storeHealthLabel(storeHealthOf(project.id))))
    Json.set(o, "id", Json.of(project.id))
    Json.set(o, "name", Json.of(project.name))
    Json.set(o, "path", Json.of(project.path))
    Json.set(o, "kind", Json.of(project.kind))
    Json.set(o, "remote", Json.of(facts.remote))
    let tagsArr = ArrayList<JsonValue>()
    for (t in project.tags) {
        tagsArr.add(Json.of(t))
    }
    Json.set(o, "tags", JArr(tagsArr))
    Json.set(o, "headline", Json.of(computeHeadline(facts, progress, config.language)))
    Json.set(o, "currentBranch", Json.of(facts.currentBranch))
    Json.set(o, "defaultBranch", Json.of(facts.defaultBranch))
    Json.set(o, "dirty", facts.dirty.toJson())
    Json.set(o, "userDirtyCount", Json.of(userDirtyCount(facts)))
    Json.set(o, "stashCount", Json.of(facts.stashCount))
    Json.set(o, "commitCount", Json.of(facts.commitCount))
    Json.set(o, "lastCommitAt", Json.of(facts.lastCommitAt))
    Json.set(o, "lastCommitAgo", Json.of(if (facts.lastCommitAt.size > 0) { timeAgo(facts.lastCommitAt, config.language) } else { "" }))

    // 分支视图（含状态刷新）
    //
    // ⚠️ git 现状是唯一权威。progress.json 以分支名为键，而删除分支不会让记录消失，
    // 于是 `git branch -D` 之后 status/list/dashboard 仍把已删分支当现存分支上报，
    // 还带着它自己的摘要和「待记录 N 个提交」—— 三个审计独立复现的同一处错误陈述。
    // 关键点：facts.branches 早就由 collectFacts 采集了（listBranches 走 for-each-ref），
    // 此前却从未被这个循环消费。实时数据一直在手边被丢弃。
    //
    // 已删记录不删数据、不静默丢弃：单列到 staleBranches，用户还能看到「你追踪过的
    // feature-x 已经不在了」，而不是它凭空混在现存分支里冒充一个活跃分支。
    let liveBranches = HashSet<String>()
    for (bi in facts.branches) {
        liveBranches.add(bi.name)
    }
    let branches = ArrayList<JsonValue>()
    let staleBranchNames = ArrayList<String>()
    for ((name, rec) in progressBranches(progress)) {
        if (!liveBranches.contains(name)) {
            staleBranchNames.add(name)
            continue
        }
        let headDate = Json.strAt(rec, "headDate", "")
        let merged = Json.boolAt(rec, "merged", false)
        let isDefault = name == facts.defaultBranch
        let status = if (merged && !isDefault) { "merged" } else { computeBranchStatus(headDate, false) }
        let b = Json.obj()
        Json.set(b, "name", Json.of(name))
        Json.set(b, "status", Json.of(status))
        Json.set(b, "statusLabel", Json.of(statusLabel(status, config.language)))
        Json.set(b, "head", Json.of(Json.strAt(rec, "head", "")))
        Json.set(b, "headShort", Json.of(shortSha(Json.strAt(rec, "head", ""))))
        Json.set(b, "headDate", Json.of(headDate))
        Json.set(b, "headAgo", Json.of(if (headDate.size > 0) { timeAgo(headDate, config.language) } else { "" }))
        Json.set(b, "headSubject", Json.of(Json.strAt(rec, "headSubject", "")))
        Json.set(b, "summary", Json.of(Json.strAt(rec, "summary", "")))
        let hl = ArrayList<JsonValue>()
        for (h in Json.strArrAt(rec, "highlights")) {
            hl.add(Json.of(h))
        }
        Json.set(b, "highlights", JArr(hl))
        let ns = ArrayList<JsonValue>()
        for (h in Json.strArrAt(rec, "nextSteps")) {
            ns.add(Json.of(h))
        }
        Json.set(b, "nextSteps", JArr(ns))
        Json.set(b, "aheadOfDefault", Json.of(Json.intAt(rec, "aheadOfDefault", 0)))
        Json.set(b, "merged", Json.of(merged))
        // ⚠️ pendingCommits 必须**实时**算，不能读进度库里存的那个。
        // 存的那个是 update 运行时算完立刻归零的快照
        // （flow/update.cj:591：本次有提交的分支一律写成 0），
        // 于是 status 报出来实质恒为 0 ——
        // 而这个字段回答的恰恰是「我上次跑完之后又提交了多少，引擎还没记下来」。
        // 引擎自己的注释早就承认了这件事（flow/dashboard.cj:205
        // 「该字段在刚跑过 update 的分支上恒为 0」），
        // dashboard 正因为这句话才把 mergeCandidates 换成了 aheadOfDefault；
        // 但换掉**用法**并不等于**数据**能用。
        //
        // 公式与 update.cj:652 完全一致（`${head}..${name}`，不是 HEAD ——
        // 对当前分支之外的分支，量 HEAD 会量到「当前分支比它多几个提交」）。
        // 两处必须同步，否则会出现「更新日志说 0、状态页说 7」。
        //
        // 三种情况一律报 0，且都说明理由：
        //   · head 为空（还没记过基线）—— 没有基准可比
        //   · baselineReset（rebase/force-push 重建过基线）—— 区间已不可比，
        //     报一个数就是在编
        //   · 计数 > 500（update.cj:653 的同一道闸）—— 异常值不外泄
        let recHead = Json.strAt(rec, "head", "")
        let baselineGone = Json.boolAt(rec, "baselineReset", false)
        var livePending: Int64 = 0
        if (!recHead.isEmpty() && !baselineGone) {
            let n = commitCount(project.path, "${recHead}..${name}")
            livePending = if (n > 500) { 0 } else { n }
        }
        Json.set(b, "pendingCommits", Json.of(livePending))
        // 基线被重建过：原提交区间不再可计算，之前的记录有一部分对不上了
        Json.set(b, "baselineReset", Json.of(Json.boolAt(rec, "baselineReset", false)))
        Json.set(b, "provider", Json.of(Json.strAt(rec, "provider", "rules")))
        Json.set(b, "isCurrent", Json.of(name == facts.currentBranch))
        Json.set(b, "isDefault", Json.of(isDefault))
        Json.set(b, "updatedAt", Json.of(Json.strAt(rec, "updatedAt", "")))
        Json.set(b, "staleDays", Json.of(if (headDate.size > 0) { Int64(daysSince(headDate)) } else { -1 }))
        branches.add(b)
    }
    // 进度库里记着、但 git 里已经不存在的分支。单列披露，不混进现存分支表。
    if (staleBranchNames.size > 0) {
        Json.set(o, "staleBranches", jsonStrArray(staleBranchNames))
    }

    // 排序：当前 > 默认 > 其他（未合并在前）
    let sorted = ArrayList<JsonValue>()
    let remaining = ArrayList<JsonValue>()
    for (b in branches) {
        remaining.add(b)
    }
    // 简单稳定排序
    var i: Int64 = 1
    while (i < remaining.size) {
        let key = remaining[i]
        var j = i - 1
        while (j >= 0 && branchScore(remaining[j]) > branchScore(key)) {
            remaining[j + 1] = remaining[j]
            j -= 1
        }
        remaining[j + 1] = key
        i += 1
    }
    for (b in remaining) {
        sorted.add(b)
    }
    Json.set(o, "branches", JArr(sorted))
    // 分支数分母：branches 是「引擎追踪到基线的分支」，不是仓库的分支。
    // 不给分母的话，status 顶部「N 个分支」会被读成「仓库就 N 个分支」——
    // 与 update 出口是同一个谎，必须一起补，否则修了一处另一处照说。
    match (repoBranchTotal(facts)) {
        case Some(n) => Json.set(o, "repoBranchCount", Json.of(n))
        case None => Json.set(o, "repoBranchCount", Json.of(-1))
    }
    Json.set(o, "overall", Json.getOr(progress, "overall"))

    // 文档
    let docsArr = ArrayList<JsonValue>()
    for (file in facts.docsPresent) {
        let d = Json.obj()
        Json.set(d, "file", Json.of(file))
        Json.set(d, "exists", Json.of(true))
        docsArr.add(d)
    }
    Json.set(o, "docs", JArr(docsArr))
    Json.set(o, "manifests", jsonStrArray(facts.manifests))

    // 浅更新增强：类型分布 / 未跟踪 / 多工作区 / 合入提示
    let ctArr = ArrayList<JsonValue>()
    for ((t, count) in facts.commitTypes) {
        let cto = Json.obj()
        Json.set(cto, "type", Json.of(t))
        Json.set(cto, "count", Json.of(count))
        ctArr.add(cto)
    }
    Json.set(o, "commitTypes", JArr(ctArr))
    // commitTypes 是最近 N 条的样本，commitCount 是真实总数（无上限）。
    // 两者并排出现在同一份 JSON 里却不互相说明，调用方无从判断该信哪个。
    // 实测 23 提交（feat 20/fix 2/chore 1）报成 commitCount=23 + feat×12。
    Json.set(o, "commitTypesTruncated", Json.of(facts.commitTypesTruncated))
    Json.set(o, "untrackedCount", Json.of(facts.untrackedCount))
    Json.set(o, "worktreeCount", Json.of(facts.worktreeCount))
    match (facts.mergeHint) {
        case Some(m) => Json.set(o, "mergeHint", m.toJson())
        case None => ()
    }

    // 进度元信息
    let meta = Json.obj()
    Json.set(meta, "updatedAt", Json.of(Json.strAt(progress, "updatedAt", "")))
    Json.set(meta, "lastUpdateAt", Json.of(Json.strAt(state, "lastUpdateAt", "")))
    Json.set(meta, "lastTrackAt", Json.of(Json.strAt(state, "lastTrackAt", "")))
    Json.set(meta, "lastDeepAt", Json.of(Json.strAt(state, "lastDeepAt", "")))
    // entryCount 必须是**真实条数**，不是 progress.json 里那个被截到 200 的数组长度。
    // 实测跑过 251 次的项目：journal.jsonl 有 251 行，entryCount 报 200 且无任何提示。
    // entriesTotal 由 writeProgress 滚动记账（上次总数 + 本次新增），
    // 旧 progress 文件没有这个键时退回数组长度 —— 行为与从前一致，只是现在能说清。
    let keptEntries = Json.arrAt(progress, "entries").size
    let entryCount = Json.intAt(progress, "entriesTotal", keptEntries)
    Json.set(meta, "entryCount", Json.of(entryCount))
    // 截断与否要和数字成对给出，否则调用方无从判断该信哪个
    Json.set(meta, "entryCountTruncated", Json.of(entryCount > keptEntries))
    Json.set(meta, "entriesKept", Json.of(keptEntries))
    Json.set(meta, "runCount", Json.of(Json.intAt(state, "runCount", 0)))
    Json.set(o, "progress", meta)

    // 日志
    //
    // ⚠️ 这里原来是一份**手挑的 9 键投影**（手写 Json.set 逐个字段），
    // 与 `journal --json` 的出口形状对不上：存储里 17 键，投影只留 9 键，
    // 丢掉的包括 `commitCountScope` / `highlights` / `nextSteps` / `notes` /
    // `source` / `repoBranchCount` / 两个截断标志；还多造了一个恒为 `[]` 的
    // `docs`（浅更新不写这个键，只有 deep 写）——
    // 「本来没写过」被压成「没有变更」，而恒空的假值比缺键更坏。
    //
    // 同一个引擎里同一个概念有两个形状，消费方就得写两套解码分支，
    // 而最容易漏的那一套会把「没数据」显示成「一切正常」。
    // 现在两个出口共用 `journalEntryJson`（store.cj），投影已经不存在。
    let jArr = ArrayList<JsonValue>()
    for (e in journal) {
        jArr.add(journalEntryJson(e))
    }
    Json.set(o, "journal", JArr(jArr))
    // ⚠️ 三个披露键一律**恒发**，不能 `if (truncated) 才加`。
    //
    // 原来的写法是条件性的，于是「journal 数组有 8 条」这句话有两种含义：
    //   · 全部就 8 条
    //   · 只给了最近 8 条，后面还有
    // 消费方（客户端）拿不到任何区分依据，只能把**窗口当全量**渲染 ——
    // 而「上限当全量」已经是本引擎最高发的缺陷族（累计 16 处）。
    //
    // 客户端其实已经在 commitTypesTruncated / progress 上做了同样的披露，
    // 唯独 journal 这一处漏了，于是同一个引擎里两套口径。
    // 现在恒发：没截断时 journalTruncated=false、journalUnparsableLines=0。
    Json.set(o, "journalTruncated", Json.of(journalTruncated))
    Json.set(o, "journalLimit", Json.of(journalLimit))
    Json.set(o, "journalUnparsableLines", Json.of(journalBad))

    // ⚠️ `warnings` 现在**恒发**（原来只在非空时才加键）。
    //
    // 它是披露键，恒发的理由与上面 journalTruncated 那三个完全一样：
    // 键出现与否取决于数据，消费方就得写两套解码分支，
    // 而最容易漏的那一套会把「没有警告」显示成「一切正常」。
    //
    // 真正的问题是这条警告**从来没有被任何消费方显示过**：
    // 实测一个非 git 目录注册成项目后，引擎诚实地给出
    //     warnings = ["非 git 仓库：进度基于文件活动时间，不含提交历史"]
    //     commitCount = 0
    // 而客户端 `ProjectStatus` **压根没有 warnings 字段**，
    // 于是用户看到的是「0 个提交」——把「压根没测过」显示成「一个都没有」。
    // 恒发只是让这个谎话变得**可检测**；真正要补的是消费侧把它显示出来。
    Json.set(o, "warnings", jsonStrArray(facts.warnings))
    Json.set(o, "fetchedAt", Json.of(nowIso()))
    return o
}

func branchScore(b: JsonValue): Int64 {
    if (Json.boolAt(b, "isCurrent", false)) {
        return 0
    }
    if (Json.boolAt(b, "isDefault", false)) {
        return 1
    }
    if (Json.boolAt(b, "merged", false)) {
        return 4
    }
    return 2
}

public func jsonStrArray(items: ArrayList<String>): JsonValue {
    let arr = ArrayList<JsonValue>()
    for (s in items) {
        arr.add(Json.of(s))
    }
    return JArr(arr)
}

func errorStatusJson(p: ProjectEntry, message: String): JsonValue {
    // 错误桩也必须补齐**成功态的全部键**（缺一个键整个 envelope 解码失败）。
    //
    // 这里原来只补了 17 个键，而 projectStatus 产出 26 个 ——
    // 缺 tags / dirty / commitCount / lastCommitAt / overall / docs /
    // manifests / commitTypesTruncated / progress / fetchedAt。
    // 后果不是「少显示几个字段」，而是整个对象解码失败：
    // 客户端看到的是「这个项目加载不出来」，而不是「这个项目采集失败了，
    // 原因是 <message>」—— 唯一有用的那句 error 反而被解码错误一起吞掉。
    // 实测：路径失效的项目，status --json 的条目只有 17 个键，成功态有 26 个。
    let err = Json.obj()
    // 成功态加了 storeHealth，错误桩必须跟上 ——
    // 键集不一致会让整个 envelope 解码失败，唯一有用的那句 error 反而被吞掉
    // （这正是本函数存在的理由，已有测试 testErrorStatusJsonHasEveryKeyOfSuccessShape 锁定）。
    Json.set(err, "storeHealth", Json.of(storeHealthLabel(storeHealthOf(p.id))))
    Json.set(err, "id", Json.of(p.id))
    Json.set(err, "name", Json.of(p.name))
    Json.set(err, "path", Json.of(p.path))
    Json.set(err, "kind", Json.of(p.kind))
    Json.set(err, "remote", Json.of(""))
    Json.set(err, "error", Json.of(message))
    Json.set(err, "headline", Json.of("状态获取失败"))
    Json.set(err, "currentBranch", Json.of(""))
    Json.set(err, "defaultBranch", Json.of(""))
    // ⚠️ 下面 5 个计数与 commitCount 全部是 -1，不是 0。
    //
    // 采集失败意味着这些事实**一个都没读到**。报 0 等于替用户断言
    // 「这个项目 0 个提交 / 工作区干净 / 没有 stash / 不是多 worktree」——
    // 而真相是「整个仓库读不出来」。这是本引擎最高发的那族缺陷
    // （把「读不出来」渲染成「没有」），且与同一个函数里下面 5 行的
    // repoBranchCount 约定**自相矛盾**：那里特意用 -1 并写明「-1 是未知，不是 0」。
    //
    // 实测（路径已删除的项目）：
    //     error           = 路径不存在或卷未挂载：/tmp/…
    //     commitCount     = 0     ← 谎报：这个项目一个提交都没有
    //     userDirtyCount  = 0     ← 谎报：工作区干净（真相是工作区读不出来）
    //     repoBranchCount = -1    ← 唯一守约定的字段
    // userDirtyCount 最危险：客户端拿它决定要不要提示「有未提交改动」，
    // 读不出来时它会显示「干净」，用户据此认为改动已提交。
    //
    // 为什么不能只报 0：这三个 -1 全部有 type-safe 的下游消费方
    // （groupSummary 的 branchUnknownProjects 就是同一套约定）。
    Json.set(err, "userDirtyCount", Json.of(-1))
    Json.set(err, "untrackedCount", Json.of(-1))
    Json.set(err, "stashCount", Json.of(-1))
    Json.set(err, "worktreeCount", Json.of(-1))
    Json.set(err, "lastCommitAgo", Json.of(""))
    Json.set(err, "commitTypes", JArr(ArrayList<JsonValue>()))
    Json.set(err, "branches", JArr(ArrayList<JsonValue>()))
    // 采集失败 ⇒ 仓库真实分支数读不出来。与 groupSummary 的约定一致：
    // -1 是「未知」，**不是** 0 —— 报 0 等于把这个项目的分支说成 0 个，
    // 而 groupSummary 会把它计入 branchUnknownProjects 并在表头披露。
    // 缺这个键更糟：客户端按成功态解码失败项目时直接缺字段崩掉
    // （testErrorStubMirrorsSuccessShape 正是钉这一条的）。
    Json.set(err, "repoBranchCount", Json.of(-1))
    Json.set(err, "journal", JArr(ArrayList<JsonValue>()))
    // 成功态把 journalTruncated / journalLimit / journalUnparsableLines 改成恒发，
    // 错误桩必须跟上 —— 少一个键，整个对象解码失败，
    // 唯一有用的那句 error 反而被吞掉（与本函数存在的理由同一件事）。
    //
    // 取值沿用**这个错误桩自己的既有约定**，不另起一套：
    //   · 布尔量「没有数据 ≠ 数据被截断」⇒ false。
    //     与下面同一桩里的 commitTypesTruncated、progress.entryCountTruncated 同理由。
    //   · 计数「读不出来」⇒ -1。与上面 5 个计数和 commitCount 同一约定。
    //   · journalLimit 0 = 没有取过任何窗口（字面上是真的：采集就没开始）。
    // 混用两套约定看着别扭，但一套是「这个桩原本就有的」，
    // 另起一套只会让三处口径互相打架。
    Json.set(err, "journalTruncated", Json.of(false))
    Json.set(err, "journalLimit", Json.of(0))
    Json.set(err, "journalUnparsableLines", Json.of(-1))

    // warnings 与上面三个同理改成恒发，错误桩必须跟上 ——
    // 少一个键，整个对象解码失败，唯一有用的那句 error 反而被吞掉。
    //
    // ⚠️ 这里**不能**塞采集失败的原因：原因已经在 `error` 键里了，
    // 再塞一遍就是同一个问题两种措辞，日后必然漂移。
    // warnings 的语义是「需要你知道、但不算失败」；采集失败不属于这种性质。
    Json.set(err, "warnings", JArr(ArrayList<JsonValue>()))

    // ↓ 以下为补齐的 10 个键，与 projectStatus 的产出逐一对应
    Json.set(err, "tags", JArr(ArrayList<JsonValue>()))
    Json.set(err, "dirty", Json.obj())
    // 同样是 -1，与上面 4 个计数和 repoBranchCount 同一约定
    Json.set(err, "commitCount", Json.of(-1))
    Json.set(err, "lastCommitAt", Json.of(""))
    // commitTypes 为空 ⇒ 没有采样，截断与否无从谈起；报 false 而不是 true，
    // 否则调用方会显示「类型分布已截断」去解释一个根本没采到样本的列表
    Json.set(err, "commitTypesTruncated", Json.of(false))
    Json.set(err, "overall", Json.obj())
    Json.set(err, "docs", JArr(ArrayList<JsonValue>()))
    Json.set(err, "manifests", JArr(ArrayList<JsonValue>()))
    let meta = Json.obj()
    Json.set(meta, "updatedAt", Json.of(""))
    Json.set(meta, "lastUpdateAt", Json.of(""))
    Json.set(meta, "lastTrackAt", Json.of(""))
    Json.set(meta, "lastDeepAt", Json.of(""))
    Json.set(meta, "entryCount", Json.of(0))
    // 采集失败时我们**没有**读到这个项目的进度，entryCount 不知道就是不知道。
    // 但截断标志要如实报 false —— 没有数据 ≠ 数据被截断。
    Json.set(meta, "entryCountTruncated", Json.of(false))
    Json.set(meta, "entriesKept", Json.of(0))
    Json.set(meta, "runCount", Json.of(0))
    Json.set(err, "progress", meta)
    Json.set(err, "fetchedAt", Json.of(nowIso()))
    return err
}

/// 全部项目状态（含单项目失败隔离）。
/// 每个项目用 std.sync.spawn 并发采集：互为独立的只读 git 子进程，无共享可变状态，
/// 单项目失败只影响自身条目。
public func allProjectStatuses(projects: ArrayList<ProjectEntry>, config: Config, light: Bool): ArrayList<JsonValue> {
    let limit = if (light) { 3 } else { 8 }
    let futures = ArrayList<(ProjectEntry, Future<JsonValue>)>()
    for (p in projects) {
        if (p.disabled) {
            continue
        }
        let target = p
        let cfg = config
        let jl = limit
        futures.add((target, spawn {
            try {
                return projectStatus(target, cfg, jl)
            } catch (e: Exception) {
                return errorStatusJson(target, e.message)
            }
        }))
    }
    let out = ArrayList<JsonValue>()
    for ((p, f) in futures) {
        // 必须带超时。f.get() 无期限阻塞意味着：任何一个 worker 卡住，
        // report / status 就永久挂住 —— 菜单栏转圈、CLI 无响应、HTTP 连接不返回，
        // 而且没有任何错误信息。函数承诺的「单项目失败只影响自身条目」在卡死时不成立。
        // 120s 与内部 git 子进程超时（gitRun 120000ms）对齐：超过它就是真卡住了。
        try {
            out.add(f.get(Duration.second * 120))
        } catch (e: TimeoutException) {
            out.add(errorStatusJson(p, "状态采集超时（120s）"))
        } catch (e: Exception) {
            out.add(errorStatusJson(p, e.message))
        }
    }
    return out
}

/// 项目群总览统计
public func groupSummary(statuses: ArrayList<JsonValue>, config: Config): JsonValue {
    let o = Json.obj()
    var total: Int64 = 0
    var active: Int64 = 0
    var stale: Int64 = 0
    var dirtyProjects: Int64 = 0
    var branchTotal: Int64 = 0
    var repoBranchTotal: Int64 = 0
    var branchTruncatedProjects: Int64 = 0
    var branchUnknownProjects: Int64 = 0
    var failed: Int64 = 0
    for (s in statuses) {
        if (Json.has(s, "error")) {
            // projectCount 只数采集成功的（这个语义有测试锁定，下游靠它区分
            // 「没有项目」和「有项目但采集失败」）。但表格会渲染全部条目，
            // 于是表头写「共 2 个项目」而下面列了 4 行 —— 数字自相矛盾，
            // 用户会以为只注册了 2 个，坏掉的那 2 个就这么消失在视野里。
            // 补两个披露字段，让调用方能把总数和失败数一起报出来。
            failed += 1
            continue
        }
        total += 1
        let branches = Json.arrAt(s, "branches")
        branchTotal += branches.size
        // 仓库真实分支数只累加**读到了**的项目：-1 是「读不出来」，
        // 当 0 累加等于把故障说成「这项目没有分支」。
        // 单项目读不出来时宁可总数偏小并披露，也不能虚报。
        let rbc = Json.intAt(s, "repoBranchCount", -1)
        if (rbc >= 0) {
            repoBranchTotal += rbc
            if (rbc > branches.size) {
                branchTruncatedProjects += 1
            }
        } else {
            branchUnknownProjects += 1
        }
        if (Json.intAt(s, "userDirtyCount", 0) > 0) {
            dirtyProjects += 1
        }
        var hasStale = false
        var hasActive = false
        for (b in branches) {
            let st = Json.strAt(b, "status", "")
            if (st == "stale") {
                hasStale = true
            }
            if (st == "active") {
                hasActive = true
            }
        }
        if (hasStale) {
            stale += 1
        }
        if (hasActive) {
            active += 1
        }
    }
    Json.set(o, "projectCount", Json.of(total))
    // 存储损坏的项目**不算** failedProjects（git 读得到，采集确实成功了），
    // 但必须单独计数并披露 —— 否则 summary 全绿、dashboard 报「一切正常」，
    // 而实际上有几个项目的历史读不出来。
    var degraded: Int64 = 0
    for (s2 in statuses) {
        let sh = Json.strAt(s2, "storeHealth", "ok")
        if (sh != "ok") {
            degraded += 1
        }
    }
    Json.set(o, "degradedStores", Json.of(degraded))
    // listedProjects = 注册表里一共多少条（含采集失败的）；
    // failedProjects = 其中采集失败多少条。projectCount + failedProjects == listedProjects。
    // 有了这两个，调用方不必再拿 projectCount 去和表格行数对账（对不上）。
    Json.set(o, "listedProjects", Json.of(statuses.size))
    Json.set(o, "failedProjects", Json.of(failed))
    Json.set(o, "activeProjects", Json.of(active))
    Json.set(o, "staleProjects", Json.of(stale))
    Json.set(o, "dirtyProjects", Json.of(dirtyProjects))
    Json.set(o, "branchCount", Json.of(branchTotal))
    // branchCount 是「追踪数」，repoBranchTotal 是「仓库真实总数」。
    // 两个数分开的意义：实测 16 个分支的仓库 status 只显示 7 个且零披露。
    // branchTruncatedProjects = 有多少项目的追踪数小于它的真实分支数；
    // branchUnknownProjects = 有多少项目的仓库分支数根本读不出来
    // （非 git 项目 / for-each-ref 失败），它们没有计入 repoBranchTotal。
    Json.set(o, "repoBranchTotal", Json.of(repoBranchTotal))
    Json.set(o, "branchTruncatedProjects", Json.of(branchTruncatedProjects))
    Json.set(o, "branchUnknownProjects", Json.of(branchUnknownProjects))
    Json.set(o, "generatedAt", Json.of(nowIso()))
    return o
}

// ------------------------------ 测试 ------------------------------

@Test
func testProjectStatusOnRealRepo(): Unit {
    let base = "/tmp/deepgit-status-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/README.md", "# x\n")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: x"], false)
    let pid = projectIdFor(base)
    let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)
    let status = projectStatus(project, Config.defaults(), 5)
    @Assert(Json.strAt(status, "name", "") == basename(base))
    @Assert(Json.strAt(status, "kind", "") == "git")
    @Assert(Json.intAt(status, "commitCount", 0) == 1)
    @Assert(Json.strAt(status, "headline", "").size > 0)
    // README 是托管文档，即使被 moonGit 改过也不算用户脏
    @Assert(Json.intAt(status, "userDirtyCount", -1) == 0)
    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
}

@Test
func testGroupSummaryShape(): Unit {
    let statuses = ArrayList<JsonValue>()
    let s = Json.obj()
    Json.set(s, "name", Json.of("a"))
    let branches = ArrayList<JsonValue>()
    let b = Json.obj()
    Json.set(b, "status", Json.of("stale"))
    branches.add(b)
    Json.set(s, "branches", JArr(branches))
    Json.set(s, "userDirtyCount", Json.of(0))
    statuses.add(s)
    let summary = groupSummary(statuses, Config.defaults())
    @Assert(Json.intAt(summary, "projectCount", 0) == 1)
    @Assert(Json.intAt(summary, "staleProjects", 0) == 1)
}

@Test
func testGroupSummarySeparatesTrackedBranchesFromRepoTotal(): Unit {
    // summary.branchCount 是「追踪数」，必须和「仓库真实总数」分开口径。
    // 实测 16 个分支的仓库这行原本只写「7 个分支」，零披露。
    //
    // 三个项目：
    //   A  追踪 7 / 仓库 16   → 追踪数偏小，要计入 branchTruncatedProjects
    //   B  追踪 4 / 仓库 4    → 一致，不算截断
    //   C  repoBranchCount=-1 → 读不出来（非 git 项目或 for-each-ref 失败）
    //                           **不能**当成 0 累加进 repoBranchTotal，
    //                           否则总数会因为「故障」而变小却没人知道
    let statuses = ArrayList<JsonValue>()
    func mk(n: Int64, repo: Int64): JsonValue {
        let s = Json.obj()
        let arr = ArrayList<JsonValue>()
        var i: Int64 = 0
        while (i < n) {
            let b = Json.obj()
            Json.set(b, "status", Json.of("active"))
            arr.add(b)
            i += 1
        }
        Json.set(s, "branches", JArr(arr))
        Json.set(s, "repoBranchCount", Json.of(repo))
        Json.set(s, "userDirtyCount", Json.of(0))
        return s
    }
    statuses.add(mk(7, 16))
    statuses.add(mk(4, 4))
    statuses.add(mk(2, -1))

    let summary = groupSummary(statuses, Config.defaults())
    @Assert(Json.intAt(summary, "branchCount", 0) == 13)
    // -1 的那个不计入真实总数
    @Assert(Json.intAt(summary, "repoBranchTotal", -1) == 20)
    @Assert(Json.intAt(summary, "branchTruncatedProjects", -1) == 1)
    @Assert(Json.intAt(summary, "branchUnknownProjects", -1) == 1)
}

@Test
func testGroupSummaryEmptyIsComplete(): Unit {
    // 客户端契约：零项目 / 全部停用时，summary 必须仍然存在且为全零。
    // 早期 cmdStatus 在 targets 为空时整段跳过 json 分支，stdout 为空；
    // 在 statuses 为空时又条件写入 summary，导致缺键。两者都让客户端解码失败。
    let summary = groupSummary(ArrayList<JsonValue>(), Config.defaults())
    @Assert(Json.has(summary, "projectCount"))
    @Assert(Json.has(summary, "activeProjects"))
    @Assert(Json.has(summary, "staleProjects"))
    @Assert(Json.has(summary, "dirtyProjects"))
    @Assert(Json.has(summary, "branchCount"))
    @Assert(Json.has(summary, "generatedAt"))
    @Assert(Json.intAt(summary, "projectCount", -1) == 0)
    @Assert(Json.intAt(summary, "activeProjects", -1) == 0)
    @Assert(Json.intAt(summary, "staleProjects", -1) == 0)
    @Assert(Json.intAt(summary, "branchCount", -1) == 0)
}

@Test
func testGroupSummarySkipsErroredProjects(): Unit {
    // 计入 projectCount 的只有采集成功的项目；带 error 的条目不计入。
    // 客户端需据此区分"没有项目"与"有项目但采集失败"。
    let statuses = ArrayList<JsonValue>()
    let ok1 = Json.obj()
    Json.set(ok1, "branches", JArr(ArrayList<JsonValue>()))
    Json.set(ok1, "userDirtyCount", Json.of(0))
    statuses.add(ok1)
    let bad = Json.obj()
    Json.set(bad, "error", Json.of("boom"))
    statuses.add(bad)
    let summary = groupSummary(statuses, Config.defaults())
    @Assert(Json.intAt(summary, "projectCount", -1) == 1)
}

@Test
func testAllProjectStatusesIsolatesFailures(): Unit {
    // 失败必须被隔离成一条带 error 的条目，而不是中断整批 —— 这条意图不变。
    // 但注释原先写的「不存在的路径 → 降级为 dir 模式并如实报告」描述的是 bug：
    // collectFacts 的 git 分支查路径存在性，dir 分支不查，
    // 于是不存在的路径被 collectActivity 安静地读成「0 个文件的非 git 项目」，
    // 报出「非 git 项目 · 0 个文件」——把「目录没了」说成「目录是空的」，
    // 而同一时刻 doctor 对同一条目报的是「路径有效 1 个失效」。
    let projects = ArrayList<ProjectEntry>()
    projects.add(ProjectEntry("p_bad", "bad", "/nonexistent/path/xyz", "dir", "", nowIso(), ArrayList<String>(), false))
    projects.add(ProjectEntry("p_disabled", "disabled", "/tmp", "dir", "", nowIso(), ArrayList<String>(), true))
    let out = allProjectStatuses(projects, Config.defaults(), true)
    @Assert(out.size == 1)  // disabled 项目被跳过
    @Assert(Json.strAt(out[0], "name", "") == "bad")
    @Assert(Json.arrAt(out[0], "branches").size == 0)
    // 必须带 error，且原因要指名道姓，不能只是一句「状态获取失败」
    @Assert(!Json.strAt(out[0], "error", "").isEmpty())
    @Assert(Json.strAt(out[0], "error", "").contains("不存在"))
    // 绝不能谎称这是一个「0 个文件的非 git 项目」
    @Assert(!Json.strAt(out[0], "headline", "").contains("非 git 项目"))
}

@Test
func testErrorStatusJsonShape(): Unit {
    let p = ProjectEntry("p_err", "boom", "/tmp/boom", "git", "", nowIso(), ArrayList<String>(), false)
    let j = errorStatusJson(p, "git 坏了")
    @Assert(Json.strAt(j, "error", "") == "git 坏了")
    @Assert(Json.strAt(j, "headline", "") == "状态获取失败")
    @Assert(Json.arrAt(j, "branches").size == 0)
    @Assert(Json.arrAt(j, "journal").size == 0)
}

@Test
func testJsonStrArrayAndBranchScore(): Unit {
    let j = jsonStrArray(ArrayList<String>(["a", "b"]))
    match (Json.asArr(j)) {
        case Some(items) => @Assert(items.size == 2)
        case None => @Assert(false)
    }

    // branchScore 排序权重：当前 > 默认 > 其他
    let cur = Json.obj()
    Json.set(cur, "isCurrent", Json.of(true))
    Json.set(cur, "isDefault", Json.of(false))
    let def = Json.obj()
    Json.set(def, "isCurrent", Json.of(false))
    Json.set(def, "isDefault", Json.of(true))
    let other = Json.obj()
    Json.set(other, "isCurrent", Json.of(false))
    Json.set(other, "isDefault", Json.of(false))
    @Assert(branchScore(cur) < branchScore(def))
    @Assert(branchScore(def) < branchScore(other))
}

@Test
func testGroupSummaryDisclosesFailedProjects(): Unit {
    // 表头写「共 N 个项目」而表格列了更多行 —— 数字自相矛盾，
    // 用户会以为只注册了 N 个，坏掉的那些就这么从视野里消失。
    // 实测：4 个注册项目、2 个路径失效，表头曾写「共 2 个项目」而下面列 4 行。
    // projectCount 的语义（只数采集成功项）有测试锁定，不动它；
    // 改的是补上 listedProjects / failedProjects，让调用方能把总数和失败数一起报出来。
    let statuses = ArrayList<JsonValue>()
    for (_ in 0..2) {
        let ok = Json.obj()
        Json.set(ok, "branches", JArr(ArrayList<JsonValue>()))
        Json.set(ok, "userDirtyCount", Json.of(0))
        statuses.add(ok)
    }
    for (_ in 0..2) {
        let bad = Json.obj()
        Json.set(bad, "error", Json.of("路径不存在或卷未挂载：/gone"))
        statuses.add(bad)
    }
    let summary = groupSummary(statuses, Config.defaults())
    @Assert(Json.intAt(summary, "projectCount", -1) == 2)
    @Assert(Json.intAt(summary, "failedProjects", -1) == 2)
    @Assert(Json.intAt(summary, "listedProjects", -1) == 4)
    // 恒等式：成功数 + 失败数 == 列表行数。不成立就说明又出现对不上的情况
    @Assert(Json.intAt(summary, "projectCount", 0) + Json.intAt(summary, "failedProjects", 0)
        == Json.intAt(summary, "listedProjects", -1))
}

@Test
func testCommitTypesDisclosesSampling(): Unit {
    // commitTypes 只数最近 N 条，commitCount 却是 `git rev-list --count` 的真实总数。
    // 两者并排出现在同一份 JSON 里却从不互相说明，调用方无从判断该信哪个。
    // 实测 23 提交（feat 20/fix 2/chore 1）报成 commitCount=23 + feat×12。
    // 走真实 collectFacts → projectStatus 路径，不构造 RepoFacts 手工拼装。
    let base = "/tmp/dg_ctypes_${nowMillis()}"
    let testHome = "${base}/home"
    enterTestHome(testHome)
    ensureDir(testHome)
    ensureDir(base)

    let big = "${base}/big"
    ensureDir(big)
    gitRun(big, ["init", "-b", "main"], false)
    for (i in 0..20) {
        gitRun(big, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "feat: n${i}"], false)
    }
    for (i in 0..2) {
        gitRun(big, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "fix: n${i}"], false)
    }
    gitRun(big, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "chore: n"], false)

    let pBig = ProjectEntry("p_big", "big", big, "git", "", nowIso(), ArrayList<String>(), false)
    let stBig = projectStatus(pBig, Config.defaults(), 15)
    @Assert(Json.intAt(stBig, "commitCount", -1) == 23)
    let cts = Json.arrAt(stBig, "commitTypes")
    var sampleTotal: Int64 = 0
    for (ct in cts) {
        sampleTotal += Json.intAt(ct, "count", 0)
    }
    // 样本必然小于总数，且必须承认这一点
    @Assert(sampleTotal == 15)
    @Assert(Json.boolAt(stBig, "commitTypesTruncated", false))
    @Assert(sampleSize(cts) == sampleTotal)

    // 对照：提交数没超过上限时必须报 false，否则上面那条断言没有判别力
    let small = "${base}/small"
    ensureDir(small)
    gitRun(small, ["init", "-b", "main"], false)
    for (i in 0..5) {
        gitRun(small, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "feat: n${i}"], false)
    }
    let pSmall = ProjectEntry("p_small", "small", small, "git", "", nowIso(), ArrayList<String>(), false)
    let stSmall = projectStatus(pSmall, Config.defaults(), 15)
    @Assert(!Json.boolAt(stSmall, "commitTypesTruncated", true))
    @Assert(sampleSize(Json.arrAt(stSmall, "commitTypes")) == 5)

    removePathIfExists(base)
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testDeletedBranchIsNotReportedAsExisting(): Unit {
    // progress.json 以分支名为键，删除分支不会让记录消失。
    // 于是 git branch -D 之后 status / list / dashboard 仍把已删分支当现存分支上报，
    // 还带着它自己的摘要和「待记录 N 个提交」—— 三个审计独立复现的同一处错误陈述。
    // 走真实的 add → update → branch -D → update → status 全链路。
    let base = "/tmp/dg_delbranch_${nowMillis()}"
    let testHome = "${base}/home"
    enterTestHome(testHome)
    ensureDir(testHome)
    ensureDir(base)
    let repo = "${base}/repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic("${repo}/a.txt", "x")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: 初始"], false)
    gitRun(repo, ["branch", "feature-x"], false)
    let p = ProjectEntry("p_r", "r", repo, "git", "", nowIso(), ArrayList<String>(), false)
    addProject(repo, "r", ArrayList<String>(), base)

    // 第一轮：记下 main + feature-x
    let opts = UpdateOptions()
    @Assert(runUpdate(p, Config.defaults(), opts).ok)
    @Assert(progressBranches(readProgress("p_r")).size == 2)

    // 删掉 feature-x，再在 main 上提交 3 次
    gitRun(repo, ["branch", "-D", "feature-x"], false)
    for (i in 0..3) {
        writeFileAtomic("${repo}/n${i}.txt", "x")
        gitRun(repo, ["add", "."], false)
        gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "fix: n${i}"], false)
    }
    @Assert(runUpdate(p, Config.defaults(), opts).ok)

    let st = projectStatus(p, Config.defaults(), 8)
    let names = ArrayList<String>()
    for (b in Json.arrAt(st, "branches")) {
        names.add(Json.strAt(b, "name", "?"))
        // pendingCommits 基准曾是 HEAD（当前分支），量到的是「main 相对该分支多几个提交」，
        // 与该分支本身毫无关系。删掉的分支必须报 0。
        @Assert(Json.intAt(b, "pendingCommits", -1) == 0)
    }
    @Assert(names.size == 1)
    @Assert(names[0] == "main")
    // 已删记录不销毁，单列披露
    let stale = Json.strArrAt(st, "staleBranches")
    @Assert(stale.size == 1)
    @Assert(stale[0] == "feature-x")

    // headline 不能把幽灵分支的待记录提交算进去
    @Assert(!Json.strAt(st, "headline", "").contains("待记录"))

    removePathIfExists(base)
    exitTestHome()
    removePathIfExists(testHome)
}

/// statuses 里**没有 error 字段**的条目数。
///
/// 「有没有采集成功」这个判据以前在 groupSummary 里内联写了一遍，
/// 现在 MCP 的 list_projects / get_group_context 又各自要判一次 ——
/// 三处各写一遍必然漂移。收在这里当唯一口径：
/// 一个 status 采集失败时带 `error` 键（errorStatusJson），成功时没有。
public func okCountOf(statuses: ArrayList<JsonValue>): Int64 {
    var n: Int64 = 0
    for (s in statuses) {
        if (!Json.has(s, "error")) {
            n += 1
        }
    }
    return n
}

/// 全部项目采集失败时的退出码。
///
/// 「压根没注册项目」和「注册了 N 个但一个都读不出来」在退出码上原本不可区分：
/// 实测唯一项目 git 索引损坏时，status / dashboard / report / context 全部 exit 0，
/// 报告还写出「0 个项目」—— 看退出码的调用方会以为一切正常。
/// JSON 消费者尚可从 failedProjects / projects.failed 恢复，靠退出码判断的不行。
/// 只有 Ok 的场景返回 0：没项目是合法空状态，不该报错。
public func groupExitCode(ok: Int64, listed: Int64): Int64 {
    if (listed > 0 && ok == 0) {
        return 1
    }
    return 0
}

@Test
func testGroupExitCodeDistinguishesAllFailedFromEmpty(): Unit {
    // 「压根没注册项目」和「注册了 N 个但一个都读不出来」在退出码上原本不可区分：
    // 实测唯一项目 git 索引损坏时，status / dashboard / report / context 全部 exit 0，
    // 报告还写着「0 个项目」。JSON 消费者能从 failedProjects 恢复，靠退出码的不能。
    // 没项目是合法空状态，不该报错。
    @Assert(groupExitCode(0, 0) == 0)      // 没注册任何项目
    @Assert(groupExitCode(3, 3) == 0)      // 全部成功
    @Assert(groupExitCode(2, 5) == 0)      // 部分失败，仍有事实可用
    @Assert(groupExitCode(0, 1) == 1)      // 唯一项目挂了 —— 必须报失败
    @Assert(groupExitCode(0, 5) == 1)      // 全部挂掉
}

@Test
func testStatusReportsRealEntryCountWithTruncationFlag(): Unit {
    // 「上限当全量」第 8 次：status 的 entryCount 原来直接数 progress.entries，
    // 而那个数组在 writeProgress 里被截到 200 且什么都不说。
    // 实测跑过 251 次的项目：journal 有 251 行，entryCount 报 200。
    // 修法：真实总数由 writeProgress 滚动记账（entriesTotal），这里如实上报并配标志位。
    let base = "/tmp/deepgit-entrystatus-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "a")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)
    let (entry, _) = addProject(base, "entrystatus", ArrayList<String>(), testHome)

    // 手工灌一份「已截断」的 progress：entries 只剩 200，真实总数 253
    let st = StorePaths(entry.id)
    ensureDir(st.dir)
    let progress = Json.obj()
    let es = ArrayList<JsonValue>()
    for (i in 0..200) {
        let e = Json.obj()
        Json.set(e, "id", Json.of("e${i}"))
        es.add(e)
    }
    Json.set(progress, "entries", JArr(es))
    Json.set(progress, "entriesTotal", Json.of(253))
    Json.set(progress, "entriesKept", Json.of(200))
    writeFileAtomic(st.progress, Json.pretty(progress))

    let s = projectStatus(entry, Config.defaults(), 3)
    let meta = Json.getOr(s, "progress")
    @Assert(Json.intAt(meta, "entryCount", -1) == 253)            // 真实总数，不是 200
    @Assert(Json.intAt(meta, "entriesKept", -1) == 200)
    @Assert(Json.boolAt(meta, "entryCountTruncated", false))      // 截断被如实披露

    // 旧 progress 文件没有 entriesTotal：退回数组长度，且不得谎称被截断
    let bare = Json.obj()
    Json.set(bare, "entries", JArr(es))
    writeFileAtomic(st.progress, Json.pretty(bare))
    let s2 = projectStatus(entry, Config.defaults(), 3)
    let meta2 = Json.getOr(s2, "progress")
    @Assert(Json.intAt(meta2, "entryCount", -1) == 200)
    @Assert(!Json.boolAt(meta2, "entryCountTruncated", true))

    // 错误桩必须也带这两个键，否则又是一次契约分叉
    let gonePath = "/tmp/deepgit-nonexistent-entryerr-${nowMillis()}"
    let gone = ProjectEntry(
        projectIdFor(gonePath), "entryerr", gonePath, "git", "", nowIso(), ArrayList<String>(), false,
    )
    let bad = allProjectStatuses(ArrayList<ProjectEntry>([gone]), Config.defaults(), false)
    @Assert(bad.size == 1)
    @Assert(Json.has(Json.getOr(bad[0], "progress"), "entryCountTruncated"))
    @Assert(!Json.boolAt(Json.getOr(bad[0], "progress"), "entryCountTruncated", true))

    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", entry.id]))
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testStoreCorruptionIsDisclosedNotReportedAsNoHistory(): Unit {
    // readState / readProgress 把 StoreHealth 丢掉了，于是
    // 「文件坏了、什么也没读到」和「这项目本来就没有历史」在读出口上完全同构：
    // branches=0、commitCount=0、一切正常。
    //
    // 告警只走 stderr：CLI 终端里看得见，但
    //   · MCP 走 stdout —— 模型看不见
    //   · HTTP 走响应体 —— 客户端看不见
    //   · status --json 走 stdout —— 消费者也看不见
    // 而 summary.failedProjects=0，dashboard 还会报「一切正常」。
    //
    // 实测（跑过 3 次 update 的项目，progress.json 写成坏 JSON 后）：
    //   branches=0、failedProjects=0、无任何字段说明存储已损坏。
    // 程序化调用方只会得出「这项目是新的」。
    //
    // 这是 #108（git 层的 gitReadable）在**存储层**的孪生问题。
    let base = "/tmp/deepgit-storehealth-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let repo = base + "/repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic(repo + "/a.txt", "1")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: one"], false)
    let (p, _) = addProject(repo, "sh-demo", ArrayList<String>(), "")
    // 前提：先真的写一份进度出来，否则「读不到」和「本来就没有」分不开
    @Assert(storeHealthLabel(storeHealthOf(p.id)) == "ok")
    @Assert(Json.strAt(projectStatus(p, Config.defaults(), 8), "storeHealth", "??") == "ok")
    // 前提：先真的跑一次 update，否则 progress 里没有分支，
    // 「读不到」和「本来就没有」就分不开（第一版就栽在这里）
    let up = UpdateOptions()
    up.mode = "shallow"
    up.source = "test"
    @Assert(runUpdate(p, Config.defaults(), up).ok)
    @Assert(Json.arrAt(projectStatus(p, Config.defaults(), 8), "branches").size >= 1)

    // 破坏 progress.json
    writeFileAtomic(StorePaths(p.id).progress, "{ this is not valid json")

    let health = storeHealthOf(p.id)
    @Assert(storeHealthLabel(health) == "corrupt")
    // 三态：不能压成 Bool —— corrupt 还有 .corrupt 副本可恢复，unreadable 没有
    @Assert(!storeWritable(health))
    // 前提：副本确实留下来了（这是 corrupt 还有救、unreadable 没救的依据）
    @Assert(globAny(StorePaths(p.id).progress, ".corrupt-"))

    let st = projectStatus(p, Config.defaults(), 8)
    // 关键：状态对象必须带上存储健康
    @Assert(Json.strAt(st, "storeHealth", "") == "corrupt")
    // 且这个字段不能替代 git 可读性判断（那是另一码事）
    @Assert(!Json.has(st, "error"))

    // 汇总必须单独计数 —— 损坏的项目 git 读得到，采集确实「成功」了，
    // 所以不算 failedProjects，但绝不能让 summary 全绿
    let summary = groupSummary(ArrayList<JsonValue>([st]), Config.defaults())
    @Assert(Json.intAt(summary, "degradedStores", -1) == 1)
    @Assert(Json.intAt(summary, "failedProjects", -1) == 0)
    @Assert(Json.intAt(summary, "projectCount", -1) == 1)

    // 存储正常时 degradedStores 必须是 0，不能永远非零
    let okRepo = base + "-ok/repo"
    ensureDir(okRepo)
    gitRun(okRepo, ["init", "-b", "main"], false)
    writeFileAtomic(okRepo + "/a.txt", "1")
    gitRun(okRepo, ["add", "."], false)
    gitRun(okRepo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: two"], false)
    let (po, _) = addProject(okRepo, "sh-ok", ArrayList<String>(), "")
    let okSummary = groupSummary(ArrayList<JsonValue>([projectStatus(po, Config.defaults(), 8)]), Config.defaults())
    @Assert(Json.intAt(okSummary, "degradedStores", -1) == 0)

    // agent 上下文必须在**第一屏**披露（模型只读得到这个）
    let ctx = buildAgentContext(ArrayList<ProjectEntry>([p, po]), Config.defaults(), "group", "", 12000)
    @Assert(ctx.text.contains("进度存储读不出来"))
    @Assert(ctx.text.contains("sh-demo"))
    @Assert(ctx.text.contains("corrupt"))
    // 必须说清「不是 0，是读不到」，否则模型照样会读成「没有历史」
    @Assert(ctx.text.contains("不是 0，是读不到"))
    // 且明确禁止据此新建进度库覆盖
    @Assert(ctx.text.contains("不要据此判断"))

    removePathIfExists(repo)
    removePathIfExists(okRepo)
    // ⚠️ `${base}-ok` 本身也要删：okRepo 在它里面，只删子目录会留一个空壳。
    // 同样的坑还有 testHome（= base + "-home"），是 base 的兄弟。
    removePathIfExists(base + "-ok")
    removePathIfExists(deepgitPath(["store", p.id]))
    removePathIfExists(deepgitPath(["store", po.id]))
    exitTestHome()
    removePathIfExists(testHome)
    removePathIfExists(base)
}

/// <path><mid>* 是否匹配到至少一个文件（用于验证 .corrupt 副本确实留了）。
/// 走 shell glob 而不是逐个枚举 —— 仓里没有现成的目录枚举助手，
/// 而为了验证「副本存在」去新造一个 API 不划算。
private func globAny(path: String, mid: String): Bool {
    let r = execCapture("/bin/sh", ["-c", "set -- ${path}${mid}* 2>/dev/null; [ $# -gt 0 ] && echo yes || echo no"], None, 8000)
    return r.ok() && r.stdout.trimAscii() == "yes"
}

@Test
func testStatusJournalTruncationIsDisclosedNotSilent(): Unit {
    // status 的 journal 数组封顶 8（全量）/ 5（单项目文本）却**无任何披露**，
    // 于是「journal 长度 == 8」这个数字会被读成全量。
    // 「上限当全量」这一族的第 15 处。
    let base = "/tmp/deepgit-jtrunc-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    var projId = ""
    try {
        let repo = base + "/repo"
        ensureDir(repo)
        gitRun(repo, ["init", "-b", "main"], false)
        writeFileAtomic(repo + "/a.txt", "1")
        gitRun(repo, ["add", "."], false)
        gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: one"], false)
        let (p, _) = addProject(repo, "jtrunc", ArrayList<String>(), "")
        projId = p.id

        // 方向 1：条数不足上限 ⇒ 键**仍然在**，但值为 false。
        //
        // ⚠️ 2026-10-01：这条断言原来是 `@Assert(!Json.has(few, "journalTruncated"))`
        // ——「不截断时**不该有这个键**」。那是条件性发键的旧契约，
        // 已按本项目自己的规矩（披露键一律恒发）改成恒发，于是它红了。
        //
        // 改的是**契约**，不是把测试改绿了事：键出现与否取决于数据，
        // 消费方就得写两套解码分支，而两套里最容易漏的那套会把
        // 「键不存在」当成「一切正常」—— 在这里正好是「日志是全量的」，
        // 而真相可能是「我们压根没读到日志」。恒发之后只有一套分支。
        for (i in 0..3) {
            let e = Json.obj()
            Json.set(e, "branch", Json.of("main"))
            Json.set(e, "at", Json.of("2026-03-0${i + 1}T10:00:00+08:00"))
            Json.set(e, "summary", Json.of("e${i}"))
            appendJournal(p.id, e, "jtrunc")
        }
        let few = projectStatus(p, Config.defaults(), 8)
        @Assert(Json.arrAt(few, "journal").size == 3)
        // 恒发：键在、值为 false，且窗口大小也一并给出（见上面方向 1 的注释）
        @Assert(Json.has(few, "journalTruncated"))
        @Assert(!Json.boolAt(few, "journalTruncated", true))
        @Assert(Json.has(few, "journalLimit"))
        @Assert(Json.has(few, "journalUnparsableLines"))

        // 方向 2：条数超过上限 → 标志必须出去，且分母也要出去
        for (i in 0..12) {
            let e = Json.obj()
            Json.set(e, "branch", Json.of("main"))
            Json.set(e, "at", Json.of("2026-04-01T10:00:00+08:00"))
            Json.set(e, "summary", Json.of("many${i}"))
            appendJournal(p.id, e, "jtrunc")
        }
        let many = projectStatus(p, Config.defaults(), 8)
        // 恰好 8 条：多读的那 1 条只能用来判断截断，**不得**混进数组
        @Assert(Json.arrAt(many, "journal").size == 8)
        @Assert(Json.boolAt(many, "journalTruncated", false))
        @Assert(Json.intAt(many, "journalLimit", 0) == 8)

        // 方向 3：边界 —— 恰好等于上限时不算截断（没有第 9 条）
        @Assert(!Json.boolAt(many, "journalTruncated", false) == false)
    } finally {
        exitTestHome()
        if (!projId.isEmpty()) {
            removePathIfExists(deepgitPath(["store", projId]))
        }
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

// #159 回归：错误桩把「读不出来」压成 0，而同一个函数里 repoBranchCount 用 -1。
//
// 实测（路径已删除的项目，经 allProjectStatuses 生产路径）：
//     error           = 路径不存在或卷未挂载：/tmp/…
//     commitCount     = 0     ← 谎报：这个项目一个提交都没有
//     userDirtyCount  = 0     ← 谎报：工作区干净
//     untrackedCount  = 0     ← 谎报：没有未跟踪文件
//     stashCount      = 0     ← 谎报：没有 stash
//     worktreeCount   = 0     ← 谎报：不是多 worktree
//     repoBranchCount = -1    ← 唯一守约定的字段
//
// 同一个错误桩里两种约定并存，是「抄多处就漏一处」的又一例：
// repoBranchCount 那 5 行注释明写「-1 是未知，不是 0」，而这 5 个字段没跟上。
// userDirtyCount 最危险 —— 客户端拿它决定要不要提示「有未提交改动」，
// 读不出来时显示「干净」，用户据此认为改动已提交。
@Test
func testErrorStubReportsUnknownCountsAsMinusOne(): Unit {
    let base = "/tmp/dg_errstub-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)

    // 走生产路径 allProjectStatuses，不直接调私有的 errorStatusJson ——
    // 本会话已多次因为测试没走到生产路径而假绿。
    // 采集必然失败的项目：路径指向一个从未存在过的目录（不去真的移走目录，
    // 移目录会引入额外的文件系统前置条件，而 collectFacts 的闸门只看路径是否存在）。
    let gone = "${base}/nonexistent"
    let doomed = ProjectEntry(projectIdFor(gone), "doomed", gone, "git", "", nowIso(), ArrayList<String>(), false)
    let statuses = allProjectStatuses(
        ArrayList<ProjectEntry>([doomed]),
        Config.defaults(), false,
    )
    @Assert(statuses.size == 1)
    let err = statuses[0]
    // 前提自证：确实走到了错误桩
    @Assert(Json.has(err, "error"))

    // 5 个计数 + commitCount 全部必须是 -1
    @Assert(Json.intAt(err, "commitCount", 0) == -1)
    @Assert(Json.intAt(err, "userDirtyCount", 0) == -1)
    @Assert(Json.intAt(err, "untrackedCount", 0) == -1)
    @Assert(Json.intAt(err, "stashCount", 0) == -1)
    @Assert(Json.intAt(err, "worktreeCount", 0) == -1)
    // repoBranchCount 本来就是 -1，钉住它不被后续改动带偏
    @Assert(Json.intAt(err, "repoBranchCount", 0) == -1)

    removePathIfExists(testHome)
}

// 同一条缺陷的下游不变量。
//
// ⚠️ 诚实标注：这条**测不到**「-1 被当成脏项目」，因为它不可达。
// groupSummary 开头就有 `if (Json.has(s, "error")) { failed += 1; continue }` ——
// 带 error 的条目在到达 `userDirtyCount` 判定之前就被跳过了。
// （第一版负控把 `> 0` 改成 `!= 0`，测试全绿 —— 正是这条不可达的证据。
//  一度以为判定有洞，实测代码才发现 -1 根本走不到那里。）
//
// 所以这里测的是**真正可达且真正重要**的那一格：错误桩项目必须走 continue，
// 绝不能混进 projectCount / dirtyProjects / branchUnknownProjects。
// 负控 = 撤掉那个 continue。
@Test
func testErroredProjectNeverLeaksIntoSuccessStatistics(): Unit {
    let statuses = ArrayList<JsonValue>()
    let bad = Json.obj()
    Json.set(bad, "error", Json.of("路径不存在或卷未挂载：/gone"))
    Json.set(bad, "userDirtyCount", Json.of(-1))
    Json.set(bad, "repoBranchCount", Json.of(-1))
    Json.set(bad, "branches", JArr(ArrayList<JsonValue>()))
    statuses.add(bad)

    let summary = groupSummary(statuses, Config.defaults())
    // 失败数披露、但一个都不进成功态统计
    @Assert(Json.intAt(summary, "failedProjects", -1) == 1)
    @Assert(Json.intAt(summary, "projectCount", -1) == 0)
    @Assert(Json.intAt(summary, "listedProjects", -1) == 1)
    @Assert(Json.intAt(summary, "dirtyProjects", -1) == 0)
    @Assert(Json.intAt(summary, "branchUnknownProjects", -1) == 0)
}

// ---------------------------------------------------------------------------
// 以下三个测试随 HTTP 服务端删除而迁到这里（原在 cli/http.cj）。
//
// 它们测的是**生产路径**（allProjectStatuses / projectStatus / addProject），
// 与 HTTP 无关：HTTP 服务端已按「传输层只在本机进程之间通信、不要 HTTP」的要求整体删除，
// 但错误桩的键集契约、失败形状的识别、add 返回的完整 entry 这三条
// 客户端解码全靠，必须留下。放在 flow 包里也更对 —— 被测函数就在本文件。
// ---------------------------------------------------------------------------

/// 取一个项目的对象键列表（JObj 保持插入序）。
func jsonObjKeys(j: JsonValue): ArrayList<String> {
    let out = ArrayList<String>()
    match (j) {
        case JObj(pairs) =>
            for ((k, _) in pairs) {
                out.add(k)
            }
        case _ => ()
    }
    return out
}

/// 构造一个「采集必然失败」的项目：路径指向一个从未存在过的目录。
/// 不去真的移走目录 —— 移目录会引入额外的文件系统前置条件，
/// 而 collectFacts 的闸门只看路径是否存在，够用。
func goneProjectEntry(name: String): ProjectEntry {
    let gone = "/tmp/deepgit-nonexistent-${name}-${nowMillis()}"
    return ProjectEntry(projectIdFor(gone), name, gone, "git", "", nowIso(), ArrayList<String>(), false)
}

@Test
func testErrorStatusJsonHasEveryKeyOfSuccessShape(): Unit {
    // 回归：错误桩缺 10 个键（tags / dirty / commitCount / lastCommitAt / overall /
    // docs / manifests / commitTypesTruncated / progress / fetchedAt）——
    // 成功态 26 键，错误桩只有 17 键。少一个键整个对象就解码失败，
    // 客户端看到「加载失败」而不是「采集失败：<原因>」，唯一有用的 error 反而被一起吞掉。
    //
    // 错误桩走 allProjectStatuses 这条生产路径获取，不直接调私有的 errorStatusJson ——
    // 本会话已多次因为测试没走到生产路径而假绿。
    let base = "/tmp/deepgit-stubkey-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "x")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)

    let (okEntry, _) = addProject(base, "stubkey", ArrayList<String>(), testHome)
    let ok = projectStatus(okEntry, Config.defaults(), 5)
    let okKeys = jsonObjKeys(ok)
    @Assert(!Json.has(ok, "error"))                       // 对照组：成功态没有 error
    // ⚠️ 必须是**精确**键数，不是 `>= 26`。
    //
    // 原来写的是 `@Assert(okKeys.size >= 26)`，而当时成功态正好 26 键。
    // 后来加 storeHealth、repoBranchCount，成功态涨到 28 —— 这条断言
    // 因为是 `>=` 而毫无反应，也永远不会提醒人去同步错误桩。
    // 这正是它本该抓的那类回归：成功态涨键而错误桩没跟上，客户端解码必崩。
    //
    // 精确值意味着：任何一边涨键都必须回来改这里，改不动就是测试红了。
    //
    // 2026-10-01：28 → 31。journalTruncated / journalLimit / journalUnparsableLines
    // 从「截断时才发」改成恒发，成功态因此多 3 个键。
    // 这条断言又一次发挥了它本来的作用 —— 它红了，逼着人把错误桩一起补上，
    // 而不是让客户端去撞解码失败。
    @Assert(okKeys.size == 32)

    let bad = allProjectStatuses(
        ArrayList<ProjectEntry>([goneProjectEntry("gone")]), Config.defaults(), false,
    )
    @Assert(bad.size == 1)
    @Assert(Json.has(bad[0], "error"))                    // 先确认真走到了错误桩

    let badKeys = jsonObjKeys(bad[0])
    var missing = ArrayList<String>()
    for (k in okKeys) {
        if (!badKeys.contains(k)) {
            missing.add(k)
        }
    }
    // 失败信息：missing = ${missing}
    @Assert(missing.isEmpty())
    // 错误桩必须比成功态恰好多一个 error，否则失败原因无处可读
    @Assert(badKeys.size == okKeys.size + 1)

    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", okEntry.id]))
    removePathIfExists(testHome)
    exitTestHome()
}

@Test
func testIsErrorResultRecognizesBothFailureShapes(): Unit {
    // 失败有两种形状，必须都能被识别：
    //   chainError → {code, message}      写操作失败
    //   errorStatusJson → {error, …}      状态采集失败
    // 漏判任何一种，调用方就会把失败读成成功。
    let ok = Json.obj()
    Json.set(ok, "project", Json.of("p"))
    @Assert(!hasErrorOrCode(ok))

    // 写操作失败：chainError 的形状（code + message）
    @Assert(hasErrorOrCode(DgError("VOLUME_BLOCKED", "路径不存在").toJson()))

    // 状态采集失败：错误桩的形状（error，不是 code）
    let statuses = allProjectStatuses(
        ArrayList<ProjectEntry>([goneProjectEntry("shape")]), Config.defaults(), false,
    )
    @Assert(statuses.size == 1)
    @Assert(Json.has(statuses[0], "error"))
    @Assert(hasErrorOrCode(statuses[0]))

    // ok=false 不是失败：update 用它表达「跑了但没写文档」
    let notOk = Json.obj()
    Json.set(notOk, "ok", Json.of(false))
    @Assert(!hasErrorOrCode(notOk))
}

@Test
func testAddReturnsFullProjectEntry(): Unit {
    // add 必须返回完整 entry（8 键 + created），不能只挑 {created,id,name}。
    // 少了 path，客户端注册完既显示不出路径，也无法在采集失败时提示
    // 「请检查 /path/to/repo」；少了 kind 就区分不了 git / dir。
    // 而且 projectIdFor 对 /tmp 与 /private/tmp 做了 realpath 归一
    // （实测 add 写入 /private/tmp/…），没有 path 连比对都做不了。
    let base = "/tmp/dg_addjson_${nowMillis()}"
    let testHome = "${base}/home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic("${base}/a.txt", "a")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "i"], false)

    let (p, created) = addProject(base, "addjson", ArrayList<String>(), testHome)
    @Assert(created)

    let o = p.toJson()
    Json.set(o, "created", Json.of(created))
    for (k in ["id", "name", "path", "kind", "remote", "addedAt", "tags", "disabled", "created"]) {
        @Assert(Json.has(o, k))
    }
    @Assert(Json.strAt(o, "path", "") == p.path)
    @Assert(Json.strAt(o, "kind", "") == "git")
    @Assert(Json.boolAt(o, "created", false))
    // 重复注册不是错误：created 必须能区分新建与已存在
    let (p2, created2) = addProject(base, "addjson", ArrayList<String>(), testHome)
    @Assert(!created2)
    @Assert(p2.id == p.id)

    removePathIfExists(testHome)
    exitTestHome()
}

// 回归：status 报出去的 pendingCommits 必须能回答
// 「上次跑完之后又提交了多少，引擎还没记下来」。
//
// 原来 status 读的是进度库里**存的**那个值，而那个值是 update 运行时
// 算完立刻归零的快照（update.cj:591）⇒ status 报出来实质恒为 0。
// 后果落在两处：
//   · 客户端顶栏「待记录 N」徽章永远不亮（它等的是一个不会来的数字）
//   · CLI 的「N 待记录」、AI 上下文里的分支表同样恒为 0
// dashboard 早就因为这件事把 mergeCandidates 换成了 aheadOfDefault，
// 但那只是换掉了**用法**，数据本身仍然是死的。
@Test
func testStatusPendingCommitsIsLiveNotStoredSnapshot(): Unit {
    let testHome = "/tmp/deepgit-pendlive-home-${nowMillis()}"
    ensureDir(testHome)
    enterTestHome(testHome)

    let repo = "/tmp/deepgit-pendlive-${nowMillis()}"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic("${repo}/a.txt", "x")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: 初始"], false)
    gitRun(repo, ["branch", "feature-x"], false)
    let p = ProjectEntry("p_p", "r", repo, "git", "", nowIso(), ArrayList<String>(), false)
    addProject(repo, "r", ArrayList<String>(), testHome)

    // 建基线：此刻两个分支的待记录都该是 0
    @Assert(runUpdate(p, Config.defaults(), UpdateOptions()).ok)
    var st = projectStatus(p, Config.defaults(), 8)
    @Assert(Json.intAt(branchRecIn(st, "main"), "pendingCommits", -1) == 0)
    @Assert(Json.intAt(branchRecIn(st, "feature-x"), "pendingCommits", -1) == 0)

    // main 再提交 3 次，**不**跑 update
    for (i in 0..3) {
        writeFileAtomic("${repo}/n${i}.txt", "x")
        gitRun(repo, ["add", "."], false)
        gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "fix: n${i}"], false)
    }
    st = projectStatus(p, Config.defaults(), 8)
    @Assert(Json.intAt(branchRecIn(st, "main"), "pendingCommits", -1) == 3)
    // 基准必须是这个分支**自己**的记录 head，不是 HEAD ——
    // 否则量到的是「main 比 feature-x 多几个提交」，与 feature-x 无关。
    @Assert(Json.intAt(branchRecIn(st, "feature-x"), "pendingCommits", -1) == 0)

    // 基线重建后区间不可比 ⇒ 必须报 0，而不是报一个编出来的数
    let prog = readProgress("p_p")
    let rec = progressBranch(prog, "main")
    match (rec) {
        case Some(r) =>
            Json.set(r, "baselineReset", Json.of(true))
            writeProgress("p_p", prog)
        case None => @Assert(false)
    }
    st = projectStatus(p, Config.defaults(), 8)
    @Assert(Json.intAt(branchRecIn(st, "main"), "pendingCommits", -1) == 0)

    removePathIfExists(testHome)
    removePathIfExists(repo)
    exitTestHome()
}
