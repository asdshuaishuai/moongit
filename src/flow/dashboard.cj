// 跨项目聚合仪表盘：项目群健康度 + 里程碑总览 + 语言分布 + 合入候选。
package moongit.flow

import std.collection.*
import std.convert.*
import std.env.*
import std.sync.*
import std.time.*
import moongit.kernel.*
import moongit.util.*
import std.unittest.*
import std.unittest.testmacro.*

/// 单个项目的语言采样结果 + 该项目是否撞到文件数上限。
/// 必须成对传递：只有统计数字而没有截断标志，调用方无从判断这是全量还是样本
/// ——「上限当全量」这一族已经栽过四次（commitActivity 400 / commitTypes 15 /
/// lsFiles 20000 / 语言 Top 12），每次都是标志位在中间某一层被丢掉。
class LangSample {
    let stats: ArrayList<(String, Int64)>
    let truncated: Bool
    /// 本项目语言采集失败的原因；空串表示成功（缺陷 #187）。
    let error: String
    /// **语言条数本身**被 top 上限砍掉了（缺陷 #205）。
    /// 与 `truncated` 是两回事：那个是「文件被砍」，这个是「语言种类被砍」。
    /// 两者都不披露的话，读者会把 8 条当成 14 条。
    let topCut: Bool

    init(stats: ArrayList<(String, Int64)>, truncated: Bool) {
        this(stats, truncated, "")
    }

    init(stats: ArrayList<(String, Int64)>, truncated: Bool, topCut: Bool) {
        this.stats = stats
        this.truncated = truncated
        this.error = ""
        this.topCut = topCut
    }

    init(stats: ArrayList<(String, Int64)>, truncated: Bool, error: String) {
        this.stats = stats
        this.truncated = truncated
        this.error = error
        this.topCut = false
    }

    init(stats: ArrayList<(String, Int64)>, truncated: Bool, topCut: Bool, error: String) {
        this.stats = stats
        this.truncated = truncated
        this.error = error
        this.topCut = topCut
    }
}

/// dashboard 语言分布的展示上限（**唯一来源**，缺陷 #205）。
public let DASH_LANG_TOP: Int64 = 12

/// 语言条数是否真的被上限砍掉了。**纯函数**，不碰文件系统。
///
/// `stats` 必须是**已经剔除 Markdown 之后**的统计（见 `langTopFilter` 的说明），
/// 且最多取 `top + 1` 条 —— 多取一条正好用来判断「有没有被砍」。
///
/// ⚠️ 返回的 `truncated` 是**独立于** `languagesTruncated`（文件被砍）的第二个轴。
/// 缺陷 #205：两者都不披露时，一个 14 种语言的仓库只显示 8 条，
/// 卡片却什么都不说，读者会把 8 条当成全量画像。
public func langTopCut(stats: ArrayList<(String, Int64)>, top: Int64): Bool {
    return stats.size > top
}

/// 截取出要展示的条目（纯函数）。
public func langTopSlice(stats: ArrayList<(String, Int64)>, top: Int64): ArrayList<(String, Int64)> {
    if (stats.size <= top) {
        return stats
    }
    let out = ArrayList<(String, Int64)>()
    for (i in 0..top) {
        out.add(stats[i])
    }
    return out
}

/// 剔除「文档」文件。**必须在 langStats 的 top 上限之前调用。**
///
/// ⚠️ 缺陷 #205 的直接成因：原来是在 `langStats(names, 12)` **之后**才
/// `if (lang == "Markdown") continue` 过滤 Markdown。于是：
///   · Markdown 白占了一个名额，然后被丢掉 —— 上限 12 实际只出 **11** 条；
///   · 第 12 种**真实**语言被静默吞掉（实测 Shell / Swift / TypeScript 三种）；
///   · 而 `languagesTruncated` 仍然是 false（它只反映 20000 文件上限，与此无关），
///     等于**反过来告诉读者「这份画像是完整的」**。
///
/// 判据复用 `languageOf` 而不是自己列一遍扩展名：扩展名表只有一份，
/// 这里再抄一份必然漂移。
public func langTopFilter(files: ArrayList<String>): ArrayList<String> {
    let out = ArrayList<String>()
    for (f in files) {
        if (languageOf(f) == "Markdown") {
            continue
        }
        out.add(f)
    }
    return out
}

/// 契约C 汇总侧的**唯一判定**（纯函数）：statuses 里有多少项目的未跟踪数
/// 读不到、原因样本、以及把读得到的项目加总后的未跟踪文件数。
///
/// 判据与 status.cj 恒发的 `untrackedError` 键同一口径：**非空 = 读不到**。
/// 读不到的项目不把 0 累进总数 —— 与 groupSummary 对 repoBranchCount=-1
/// 的处理同一条纪律：故障不冒充数据（#187 languagesFailed 判例）。
///
/// ⚠️ 抽成纯函数是因为「untrackedError 非空且 status 成功」**在磁盘上构造
/// 不出来**：能让 `git ls-files --others` 失败的确定性手段（坏 index、
/// exclude 变目录、权限收回）都会先让 `git status --porcelain` 失败 ⇒
/// collectFacts 抛 REPO_UNREADABLE ⇒ status 条目整个变错误桩。
/// 非空路径只能对 statuses 直接断言；接线由 lint 钉住（见
/// testBuildDashboardWiresUntrackedFailureAggregates）。
public func untrackedFailureAggregates(
    statuses: ArrayList<JsonValue>,
): (Int64, ArrayList<String>, Int64) {
    var failed: Int64 = 0
    let samples = ArrayList<String>()
    var total: Int64 = 0
    for (s in statuses) {
        // 采集失败的项目不参与（错误桩的 untrackedCount=-1，加进去会把总数拉低）
        if (Json.has(s, "error")) {
            continue
        }
        let uerr = Json.strAt(s, "untrackedError", "")
        if (!uerr.isEmpty()) {
            failed += 1
            samples.add(oneLineClamped(uerr, 120))
        } else {
            total += Json.intAt(s, "untrackedCount", 0)
        }
    }
    return (failed, samples, total)
}

public func buildDashboard(projects: ArrayList<ProjectEntry>, config: Config): JsonValue {
    let o = Json.obj()
    let statuses = allProjectStatuses(projects, config, true)

    var total: Int64 = 0
    var dirtyProjects: Int64 = 0
    var branchTotal: Int64 = 0
    var mergeCandidates: Int64 = 0
    var stashTotal: Int64 = 0
    var commits7d: Int64 = 0
    var commits30d: Int64 = 0
    var allFailed: Int64 = 0

    // 契约C（untrackedError）汇总侧：读不到未跟踪数的项目单列（恒发，
    // #187 languagesFailed 判例）。聚合走 untrackedFailureAggregates 这个
    // 唯一判定 —— 接线由 testBuildDashboardWiresUntrackedFailureAggregates 钉住。
    let (untrackedFailed, untrackedErrorSamples, untrackedTotal) = untrackedFailureAggregates(statuses)

    let langCounts = ArrayList<(String, Int64)>()
    let hotProjects = ArrayList<JsonValue>()  // 近 7 天有提交的项目
    var langTruncated = false
    // 语言**条数**被上限砍掉（#205）。与 langTruncated（文件被砍）是两个独立轴。
    var langTopCutFlag = false
    // #187：语言采集失败的项目数与样例原因。恒发，不靠「有内容才发」。
    var langFailed: Int64 = 0
    let langErrorSamples = ArrayList<String>()

    // 语言分布：每项目并发采集（ls-files 是重操作，串行会在项目多时拖垮 dashboard）。
    // 卷不可达（TCC 未授权）的项目直接跳过——否则每个 ls-files 都要等满 git 超时。
    let langFutures = ArrayList<Future<LangSample>>()
    for (p in projects) {
        if (p.disabled || p.kind != "git" || !volumeAccessible(p.path)) {
            continue
        }
        let target = p
        langFutures.add(spawn {
            // 单个项目失败只影响它自己的语言分布条目。以前这里没有 try/catch，
            // lsFiles/langStats 抛任何异常都会从下面的 f.get() 冒泡出 buildDashboard，
            // 让整个 dashboard 因一个项目失败而返回 500 —— 而同一份数据在
            // /api/status 里是通过 allProjectStatuses 的逐项目隔离正常降级的。
            try {
                // 必须用 listFiles 而不是 lsFiles：后者 return ...names，
                // 把已经算好的 truncated 标志直接扔掉。实测 20002 个 .py + 3 个 .rs
                // 的仓库，dashboard 报「Python 20000」而 Rust 整类消失、无任何提示 ——
                // 客户端会得出「这项目 100% 是 Python」。
                let listing = listFiles(target.path, 20000)
                // 失败原因必须上行（#187）。原来这里只 catch 成空列表，
                // 失败的项目与「零个文件的项目」在语言分布里完全同形。
                // ⚠️ 剔 Markdown 必须在 top 上限**之前**（#205），且多取一条
                // 用来判断有没有被上限砍掉 —— 砍了却不说 = 谎报完整。
                let stats = langStats(langTopFilter(listing.names), DASH_LANG_TOP + 1)
                return LangSample(
                    langTopSlice(stats, DASH_LANG_TOP),
                    listing.truncated,
                    langTopCut(stats, DASH_LANG_TOP),
                    listing.error
                )
            } catch (e: Exception) {
                return LangSample(ArrayList<(String, Int64)>(), false, false, oneLineClamped(e.message, 120))
            }
        })
    }
    for (f in langFutures) {
        // 超时兜底，与 allProjectStatuses 的 120s 对齐。裸 f.get() 意味着
        // 任何一个 ls-files 卡住，整个 dashboard（以及 /api/dashboard 连接）就永久挂住。
        var one = LangSample(ArrayList<(String, Int64)>(), false, "语言采集超时（120s）")
        try {
            one = f.get(Duration.second * 120)
        } catch (e: Exception) {
            one = LangSample(ArrayList<(String, Int64)>(), false, "语言采集失败：${oneLineClamped(e.message, 100)}")
        }
        // ⚠️ 失败的项目不能算进「已统计」，也不许被 truncated 掩盖（#187）。
        // 少一个项目的语言，读者就会把剩下的当成整个项目群的画像。
        if (!one.error.isEmpty()) {
            langFailed += 1
            langErrorSamples.add(one.error)
            continue
        }
        if (one.truncated) {
            langTruncated = true
        }
        if (one.topCut) {
            langTopCutFlag = true
        }
        for ((lang, count) in one.stats) {
            bumpCount(langCounts, lang, count)
        }
    }

    for (s in statuses) {
        if (Json.has(s, "error")) {
            allFailed += 1
            continue
        }
        total += 1
        if (Json.intAt(s, "userDirtyCount", 0) > 0) {
            dirtyProjects += 1
        }
        stashTotal += Json.intAt(s, "stashCount", 0)
        let branches = Json.arrAt(s, "branches")
        branchTotal += branches.size
        for (b in branches) {
            // 判据必须是 aheadOfDefault（相对默认分支的领先数），
            // 不能用 pendingCommits（引擎还没记录的提交数）——
            // 两者毫无关系：前者回答「这个分支能不能合」，后者回答「我记了没」。
            // 原实现用 pendingCommits，而该字段在刚跑过 update 的分支上恒为 0，
            // 于是「可合并分支」永远是 0，哪怕仓库里躺着一个领先 main 20 个提交的分支。
            let ahead = Json.intAt(b, "aheadOfDefault", 0)
            if (ahead > 0 && !Json.boolAt(b, "isDefault", false) && !Json.boolAt(b, "merged", false)) {
                mergeCandidates += 1
            }
        }

        // 近 7/30 天活跃：由 lastCommitAt 推算
        let lastAt = Json.strAt(s, "lastCommitAt", "")
        if (!lastAt.isEmpty()) {
            match (parseIsoMillis(lastAt)) {
                case Some(ms) =>
                    let nowMs = nowMillis()
                    let ageDays = (nowMs - ms) / 86400000
                    if (ageDays <= 7) {
                        commits7d += 1
                        hotProjects.add(s)
                    }
                    if (ageDays <= 30) {
                        commits30d += 1
                    }
                case None => ()
            }
        }
    }

    // 活跃项目统计
    let projs = Json.obj()
    Json.set(projs, "total", Json.of(total))
    // total 只数采集成功的项目。与 status 的 summary 保持同一套披露字段，
    // 否则「共 N 个项目」又是一个和实际注册数对不上的数字。
    Json.set(projs, "listed", Json.of(statuses.size))
    // ⚠️ listed 是「**参与统计**的」，不等于「注册表里一共多少条」——
    // allProjectStatuses 会跳过 disabled 的项目（status.cj 那道闸门）。
    // 少了这两个字段，报告就会把参与统计的数**标成**「已注册」：
    // 实测停用 1 个后，`list` 文本诚实地说「共 3 个项目（1 个已停用）」，
    // 而报告写「项目总数（已注册）| 2」—— 3 个注册的，报 2（缺陷 #184）。
    // 里程碑侧早就有 excludedDisabled（#158 修的），项目侧一直没有 ——
    // 同一份报告里两半口径不一致。
    var disabledCount: Int64 = 0
    for (pp in projects) {
        if (pp.disabled) {
            disabledCount += 1
        }
    }
    Json.set(projs, "registered", Json.of(projects.size))
    Json.set(projs, "excludedDisabled", Json.of(disabledCount))
    Json.set(projs, "failed", Json.of(allFailed))
    Json.set(projs, "dirty", Json.of(dirtyProjects))
    Json.set(projs, "active7d", Json.of(commits7d))
    Json.set(projs, "active30d", Json.of(commits30d))
    Json.set(o, "projects", projs)

    let work = Json.obj()
    Json.set(work, "branches", Json.of(branchTotal))
    Json.set(work, "mergeCandidates", Json.of(mergeCandidates))
    Json.set(work, "untrackedFiles", Json.of(untrackedTotal))
    // 契约C（untrackedError）汇总侧，恒发（对齐 languagesFailed / #187 的判例）：
    // 失败与「真的没有」必须分得开 —— 采集失败时 untrackedCount=0，
    // 不加这两个键，work.untrackedFiles 的 0 就会被读成「项目群没有未跟踪文件」，
    // 而那是无知不是结论（不变量 17：数据里有 ≠ 用户看得到）。
    Json.set(work, "untrackedFailed", Json.of(untrackedFailed))
    let uerrArr = ArrayList<JsonValue>()
    for (e in untrackedErrorSamples) {
        uerrArr.add(Json.of(e))
    }
    Json.set(work, "untrackedFailedReasons", JArr(uerrArr))
    Json.set(work, "stashes", Json.of(stashTotal))
    Json.set(o, "work", work)

    // 语言分布（降序）
    let langs = ArrayList<(String, Int64)>(langCounts)
    var a: Int64 = 1
    while (a < langs.size) {
        let key = langs[a]
        var b = a - 1
        while (b >= 0 && langs[b][1] < key[1]) {
            langs[b + 1] = langs[b]
            b -= 1
        }
        langs[b + 1] = key
        a += 1
    }
    let langArr = ArrayList<JsonValue>()
    for ((lang, count) in langs) {
        // Markdown 已由 langTopFilter 在**截断之前**剔除（#205）。
        // 这里再过滤一次只会掩盖「剔在截断后」这个缺陷本身。
        let lo = Json.obj()
        Json.set(lo, "language", Json.of(lang))
        Json.set(lo, "count", Json.of(count))
        langArr.add(lo)
    }
    Json.set(o, "languages", JArr(langArr))
    // 任一项目撞到 20000 文件上限就必须披露：被丢掉的文件可能包含整类语言，
    // 客户端只看到 languages 数组会以为这就是全量画像。
    Json.set(o, "languagesTruncated", Json.of(langTruncated))
    // ⚠️ #205：恒发。少了它，客户端无法区分「这就是全部语言」与
    // 「只给了前 N 种」—— 而两者在数组形状上完全相同。
    Json.set(o, "languagesTopCut", Json.of(langTopCutFlag))
    // ⚠️ 采集失败与截断是两回事，缺一不可（#187）。
    // 截断 = 看了但只留一部分；失败 = 压根没看成。
    // 少了这个字段，失败的项目会静默消失，而 languagesTruncated 仍是 false，
    // 等于反过来告诉读者「这份画像是完整的」。
    Json.set(o, "languagesFailed", Json.of(langFailed))
    let langErrArr = ArrayList<JsonValue>()
    for (e in langErrorSamples) {
        langErrArr.add(Json.of(e))
    }
    Json.set(o, "languagesFailedReasons", JArr(langErrArr))

    // 里程碑总览
    let ms = buildMilestoneOverview(projects, config)
    Json.set(o, "milestones", ms)

    let hot = ArrayList<JsonValue>()
    for (h in hotProjects) {
        let ho = Json.obj()
        Json.set(ho, "name", Json.of(Json.strAt(h, "name", "")))
        Json.set(ho, "lastCommitAgo", Json.of(Json.strAt(h, "lastCommitAgo", "")))
        Json.set(ho, "headline", Json.of(Json.strAt(h, "headline", "")))
        hot.add(ho)
    }
    Json.set(o, "activeProjects", JArr(hot))
    Json.set(o, "fetchedAt", Json.of(nowIso()))
    return o
}

/// 里程碑总览：各项目 open/done/overdue 统计 + 即将到期列表
public func buildMilestoneOverview(projects: ArrayList<ProjectEntry>, config: Config): JsonValue {
    let o = Json.obj()
    var open: Int64 = 0
    var done: Int64 = 0
    var dropped: Int64 = 0
    // 仓库读不出来的里程碑单列。它们既不是「没达成」也不是「已达成」，
    // 混进任一侧都是谎报 —— 而这恰恰发生在磁盘满 / 卷掉线 / .git 损坏时。
    var unknown: Int64 = 0
    // ⚠️ 认不出来的 status 单列（缺陷 #182）。原来 `case _ => ()` 直接丢弃，
    // 于是那条里程碑**从每个桶里都消失**，而 readCount 照算它 ——
    // 实测手写 status:"active" 后 readCount=2、open+done+dropped+unknown=1，
    // 对账等式失真；终端更直接自相矛盾：「里程碑：进行中 1 · 已达成 0 · 已放弃 0」
    // 而下面列了 2 条。
    var other: Int64 = 0
    let items = ArrayList<JsonValue>()

    // ⚠️ milestones.json 损坏必须在这里说，不能让它退化成「0 个里程碑」。
    //
    // 里程碑是**用户手写**的数据，损坏 = 一整段历史读不出来。
    // 而 milestonesFor 走的是 loadMilestones，它把 loadMilestonesChecked
    // 返回的 StoreHealth 直接扔掉 —— 于是：
    //     dashboard → 「里程碑：进行中 0 · 已达成 0 · 已放弃 0」
    //     stderr    → 0 字节
    //     exit code → 0
    // 全部损坏被读成「这个项目群一个里程碑都没有」。
    //
    // 这是 #108/#121（git 层 gitReadable、存储层 storeHealth）在
    // **第三类存储**上的同一个洞：progress/state 已经接到 status / summary /
    // report / agent 四个出口，milestones.json 是漏掉的那个。
    let (allMilestones, msHealth) = loadMilestonesChecked()
    let msDegraded = !storeWritable(msHealth) && storeHealthLabel(msHealth) != "ok"

    // ⚠️ disabled 项目必须在这里被排除，否则 dashboard 同一屏给出两套项目口径。
    //
    // 引擎全代码的 disabled 约定是「不参与默认处理」：
    //   allProjectStatuses (flow/status.cj:328) → 跳过
    //   buildDashboard 的语言采样 (本文件上方)  → 跳过
    //   report / docs / resolveTargets (cli)   → 跳过
    //   requireWorkableTargets (cli)           → 全部停用时报错并说明去手改 registry.json
    // 而本函数直接遍历 projects，把停用项目的里程碑照样计进 open/done/dropped，
    // 还会对它们跑 `milestoneProgress` → `commitsSince`（真去执行 git rev-list）。
    //
    // 实测（2 个项目，on2 手工置 disabled:true，各 1 条 open 里程碑）：
    //     项目群：共 1 个 · …              ← on2 被排除
    //     里程碑：进行中 2 · …             ← on2 照计
    //       on1｜启用项目的里程碑 · 进行中 · …
    //       on2｜已停用项目的里程碑 · 进行中 · 创建以来 1 提交   ← 项目群外的东西
    // 字面含义是「这个项目群只有 1 个项目，却有 2 个里程碑，其中一个属于不存在的项目」。
    // 而且 JSON 侧同样错位：projects.total=1 而 milestones.items 含 on2。
    //
    // 但**不能只过滤不披露**：全停用时 counts 会变成全 0，items 空，
    // 用户读到的还是「这个项目群一个里程碑都没有」—— 把「筛掉了」说成「没有」，
    // 正是本引擎最高发的那族缺陷。所以被筛掉的条数必须成对传出去。
    var excludedDisabled: Int64 = 0
    var orphanCount: Int64 = 0
    for (m in allMilestones) {
        match (projectById(projects, m.projectId)) {
            case Some(hit) =>
                if (hit.disabled) {
                    excludedDisabled += 1
                }
            // projectId 指向一个已不存在的项目（项目被 `remove` 过）。
            // #154 已经在 `milestone list` 侧披露过，dashboard 侧此前同样沉默：
            // 孤儿条目既不计入 open 也不计入 items，读到的是「项目群只有 1 个里程碑」。
            case None => orphanCount += 1
        }
    }

    for (p in projects) {
        // 与 allProjectStatuses 同一处闸门（status.cj:328）
        if (p.disabled) {
            continue
        }
        for (m in milestonesOf(allMilestones, p.id)) {
            let prog = milestoneProgress(m, p.path, "")
            match (prog.effectiveStatus) {
                case "open" => open += 1
                case "done" => done += 1
                case "dropped" => dropped += 1
                // unknown = 仓库读不出来，我们**不知道**它达没达成。
                // 单列计数，不并入 open 也不并入 done：
                // 并入 open 就是谎报「没达成」，并入 done 是在故障时虚报成就。
                case "unknown" => unknown += 1
                // 认不出来的状态既不能并进 open（谎报「没达成」）也不能丢掉
                // （丢掉 = 它从统计里人间蒸发，而列表里还在）。
                case _ => other += 1
            }
            // 条目形状**只此一份**，在 kernel.milestoneJson。
            //
            // 原来这里是手抄的第三份，于是栽过三次：
            //   1. 少 id / createdAt / completedAt → 同一个结构体在
            //      milestone list 下能解、在 dashboard 下必然崩；
            //   2. 把 tag 写成 tagName、且没有 tagName 键 → `tag` 同名不同义；
            //   3. 压根没有 unverifiedReason，而 CLI 侧是「git 读不出来才加」——
            //      降级态下 CLI 18 键、dashboard 17 键。
            // 三次都是「手抄的那份忘了同步」。改形状请改 kernel 那一处。
            items.add(milestoneJson(p, prog))
        }
    }

    // 排序：overdue 在前，然后按 targetDate 升序
    var i: Int64 = 1
    while (i < items.size) {
        let key = items[i]
        var j = i - 1
        while (j >= 0 && milestoneSortKey(items[j]) > milestoneSortKey(key)) {
            items[j + 1] = items[j]
            j -= 1
        }
        items[j + 1] = key
        i += 1
    }

    let counts = Json.obj()
    Json.set(counts, "open", Json.of(open))
    Json.set(counts, "done", Json.of(done))
    Json.set(counts, "dropped", Json.of(dropped))
    Json.set(counts, "unknown", Json.of(unknown))
    // 恒发：认不出来的状态有多少必须能被对账（见上面 #182）
    Json.set(counts, "other", Json.of(other))
    // 恒发，不能「只在坏的时候才带上」：键出现与否取决于数据，
    // 消费方就得写两套解码分支 —— 那正是 envelope 分歧的来源。
    // 恒发，不能「筛掉了才带」：键出现与否取决于数据，
    // 消费方就得写两套解码分支 —— 那正是 envelope 分歧的来源。
    Json.set(counts, "storeHealth", Json.of(storeHealthLabel(msHealth)))
    Json.set(counts, "degraded", Json.of(msDegraded))
    // 读到了多少条，用来和「本来就有多少条」对照：
    // 损坏时是 0，而它**不是**「没有里程碑」的证据
    Json.set(counts, "readCount", Json.of(allMilestones.size))
    // readCount 的去向必须能对账，否则「计入数 < 读到数」的差额是隐形黑洞：
    //     readCount = open + done + dropped + unknown + other + excludedDisabled + orphaned
    // （other 是认不出的 status 的单列桶，#182 加上时同步进这条等式 ——
    //   同文件的测试 sum 已含 other，注释漏了它就与实现矛盾。）
    // 两个计数器恒发，即使为 0 —— 上面那条等式才是消费方能自证的前提。
    Json.set(counts, "excludedDisabled", Json.of(excludedDisabled))
    Json.set(counts, "orphaned", Json.of(orphanCount))
    Json.set(o, "counts", counts)
    Json.set(o, "items", JArr(items))
    return o
}

func milestoneSortKey(item: JsonValue): Int64 {
    let overduePenalty = if (Json.boolAt(item, "overdue", false)) { 0 } else { 100000 }
    let days = Json.intAt(item, "daysToTarget", -1)
    // 未设置日期的排最后
    let d = if (days == -1) { 99999 } else { days }
    return overduePenalty + d
}

func projectById(projects: ArrayList<ProjectEntry>, id: String): Option<ProjectEntry> {
    for (p in projects) {
        if (p.id == id) {
            return Some(p)
        }
    }
    return None
}

func bumpCount(list: ArrayList<(String, Int64)>, key: String, amount: Int64): Unit {
    var found = false
    for (i in 0..list.size) {
        if (list[i][0] == key) {
            list[i] = (key, list[i][1] + amount)
            found = true
            break
        }
    }
    if (!found) {
        list.add((key, amount))
    }
}

@Test
func testBumpCountAndProjectById(): Unit {
    let list = ArrayList<(String, Int64)>([("Swift", 2)])
    bumpCount(list, "Swift", 3)
    bumpCount(list, "Cangjie", 5)
    @Assert(list.size == 2)
    @Assert(list[0] == ("Swift", 5))
    @Assert(list[1] == ("Cangjie", 5))

    let reg = Registry()
    let p = ProjectEntry("p_x", "demo", "/tmp/demo", "git", "", nowIso(), ArrayList<String>(), false)
    reg.projects.add(p)
    @Assert(projectById(reg.projects, "p_x").isSome())
    @Assert(projectById(reg.projects, "p_none").isNone())
}

@Test
func testMilestoneSortKeyOrdering(): Unit {
    // 构造：逾期(应最前)、未来 10 天、未来 3 天、无日期(最后)
    let overdue = Json.obj()
    Json.set(overdue, "overdue", Json.of(true))
    Json.set(overdue, "daysToTarget", Json.of(-5))
    let soon = Json.obj()
    Json.set(soon, "overdue", Json.of(false))
    Json.set(soon, "daysToTarget", Json.of(3))
    let later = Json.obj()
    Json.set(later, "overdue", Json.of(false))
    Json.set(later, "daysToTarget", Json.of(10))
    let noDate = Json.obj()
    Json.set(noDate, "overdue", Json.of(false))
    Json.set(noDate, "daysToTarget", Json.of(-1))
    @Assert(milestoneSortKey(overdue) < milestoneSortKey(soon))
    @Assert(milestoneSortKey(soon) < milestoneSortKey(later))
    @Assert(milestoneSortKey(later) < milestoneSortKey(noDate))
}

@Test
func testBuildDashboardOnEmptyRegistry(): Unit {
    let config = Config.defaults()
    let reg = Registry()
    let d = buildDashboard(reg.projects, config)
    @Assert(Json.intAt(Json.getOr(d, "projects"), "total", -1) == 0)
    @Assert(Json.arrAt(d, "languages").size == 0)
    @Assert(Json.arrAt(d, "activeProjects").size == 0)
    let ms = Json.getOr(d, "milestones")
    @Assert(Json.intAt(Json.getOr(ms, "counts"), "open", -1) == 0)
    @Assert(Json.arrAt(ms, "items").size == 0)
}

@Test
func testDashboardDisclosesLanguageTruncation(): Unit {
    // 必须走真实的 buildDashboard → listFiles 路径。
    // 真实事故：dashboard.cj 用的是 lsFiles()，而 lsFiles 就是 `return listFiles(...).names`
    // —— 把已经算好的 truncated 标志直接扔掉。实测 20002 个 .py + 3 个 .rs 的仓库，
    // dashboard 报「Python 20000」而 Rust 整类消失，且没有任何字段提示这是样本。
    // 客户端只会得出「这项目 100% 是 Python」。
    let base = "/tmp/dg_dash_lang_${nowMillis()}"
    let testHome = "${base}/home"
    enterTestHome(testHome)
    ensureDir(testHome)
    ensureDir(base)

    // 大仓库：超过 lsFiles 的 20000 上限，且混一门小众语言用于验证「整类消失」
    let big = "${base}/big"
    ensureDir(big)
    gitRun(big, ["init", "-b", "main"], false)
    for (i in 0..20002) {
        writeFileAtomic("${big}/f${i}.py", "x")
    }
    for (i in 0..3) {
        writeFileAtomic("${big}/g${i}.rs", "x")
    }
    gitRun(big, ["add", "."], false)
    gitRun(big, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "big"], false)

    // 对照：小仓库必须报 false，否则这条断言没有判别力
    let small = "${base}/small"
    ensureDir(small)
    gitRun(small, ["init", "-b", "main"], false)
    writeFileAtomic("${small}/a.rs", "x")
    writeFileAtomic("${small}/b.py", "x")
    gitRun(small, ["add", "."], false)
    gitRun(small, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "small"], false)

    let reg = Registry()
    reg.projects.add(ProjectEntry("p_big", "big", big, "git", "", nowIso(), ArrayList<String>(), false))
    let dBig = buildDashboard(reg.projects, Config.defaults())
    @Assert(Json.boolAt(dBig, "languagesTruncated", false))

    reg.projects.add(ProjectEntry("p_small", "small", small, "git", "", nowIso(), ArrayList<String>(), false))
    let dBoth = buildDashboard(reg.projects, Config.defaults())
    // 聚合语义：只要有任一项目被截断，合计 languages 就不完整
    @Assert(Json.boolAt(dBoth, "languagesTruncated", false))

    // 只剩小仓库时必须为 false
    let reg2 = Registry()
    reg2.projects.add(ProjectEntry("p_small", "small", small, "git", "", nowIso(), ArrayList<String>(), false))
    let dSmall = buildDashboard(reg2.projects, Config.defaults())
    @Assert(!Json.boolAt(dSmall, "languagesTruncated", true))
    // 小仓库的两种语言都要在，不能被上限吃掉
    @Assert(Json.arrAt(dSmall, "languages").size == 2)

    removePathIfExists(base)
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testDashboardMergeCandidatesUsesAheadOfDefaultNotPending(): Unit {
    // 回归：mergeCandidates 原来数的是 pendingCommits > 0 的分支。
    //
    // pendingCommits 是「引擎还没记录的提交数」，刚跑过 update 的分支恒为 0，
    // 于是「可合并分支」永远是 0 —— 哪怕仓库里躺着一个领先 main 20 个提交的分支。
    // 真正的判据是 aheadOfDefault（相对默认分支的领先数）。
    let base = "/tmp/deepgit-mergecand-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    gitRun(base, ["config", "user.name", "t"], false)
    gitRun(base, ["config", "user.email", "t@t"], false)
    writeFileAtomic(base + "/a.txt", "a")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["commit", "-m", "feat: init"], false)
    // 一个纯本地的领先分支：没有 remote，upstream 差恒为 0 ——
    // 这正是旧判据永远数不出候选分支的原因
    gitRun(base, ["checkout", "-q", "-b", "feature-x"], false)
    for (n in 1..4) {
        writeFileAtomic(base + "/b${n}.txt", "b${n}")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["commit", "-m", "feat: b${n}"], false)
    }

    let (project, _) = addProject(base, "mergecand", ArrayList<String>(), testHome)
    let r = runUpdate(project, Config.defaults(), UpdateOptions())
    @Assert(r.ok)

    // 先确认底层事实：分支确实领先默认分支，而 pendingCommits 确实是 0
    let st = projectStatus(project, Config.defaults(), 5)
    @Assert(aheadOfBranch(st, "feature-x") == 3)
    @Assert(Json.intAt(branchRecIn(st, "feature-x"), "pendingCommits", -1) == 0)

    // 旧判据在这里必然得到 0
    let dash = buildDashboard(ArrayList<ProjectEntry>([project]), Config.defaults())
    @Assert(Json.intAt(Json.getOr(dash, "work"), "mergeCandidates", -1) == 1)

    // 反向：全部已合入时不能有候选分支
    gitRun(base, ["checkout", "-q", "main"], false)
    gitRun(base, ["merge", "-q", "--no-ff", "feature-x", "-m", "merge: feature-x"], false)
    let r2 = runUpdate(project, Config.defaults(), UpdateOptions())
    @Assert(r2.ok)
    let dash2 = buildDashboard(ArrayList<ProjectEntry>([project]), Config.defaults())
    @Assert(Json.intAt(Json.getOr(dash2, "work"), "mergeCandidates", -1) == 0)

    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", project.id]))
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testMilestoneCorruptionIsDisclosedNotReportedAsZero(): Unit {
    // milestones.json 是**用户手写**的数据。损坏 = 一整段历史读不出来。
    //
    // 修复前：loadMilestones 把 loadMilestonesChecked 返回的 StoreHealth
    // 直接扔掉，于是
    //     dashboard → 「里程碑：进行中 0 · 已达成 0 · 已放弃 0」
    //     stderr    → 0 字节
    //     exit      → 0
    // 一条也没读到，被读成「这个项目群一个里程碑都没有」。
    // 而 milestone list 说的是「（无里程碑）」，同样零披露。
    //
    // 这是 #108（gitReadable）/ #121（storeHealth）在**第三类存储**上的同一个洞：
    // progress/state 早已接到 status / summary / report / agent 四个出口，
    // milestones.json 是漏掉的那个。
    let home = "/tmp/deepgit-mscorr-${nowMillis()}"
    ensureDir(home)
    enterTestHome(home)
    let repo = home + "-repo"
    try {
        ensureDir(repo)
        gitRun(repo, ["init", "-b", "main"], false)
        writeFileAtomic(repo + "/a.txt", "1")
        gitRun(repo, ["add", "."], false)
        gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: x"], false)
        let (p, _) = addProject(repo, "mscorr", ArrayList<String>(), "")
        let (_, _) = addMilestone(p.id, "v1.0", "手写的里程碑", "2027-01-01", "")

        // 前提：健康时确实读得到、且 JSON 里 degraded=false
        let healthy = buildMilestoneOverview(ArrayList<ProjectEntry>([p]), Config.defaults())
        @Assert(Json.intAt(Json.getOr(healthy, "counts"), "open", 0) == 1)
        @Assert(!Json.boolAt(Json.getOr(healthy, "counts"), "degraded", true))
        @Assert(Json.strAt(Json.getOr(healthy, "counts"), "storeHealth", "") == "ok")

        // 损坏
        writeFileAtomic(deepgitPath(["milestones.json"]), "{\"milestones\": [ {\"id\": \"m1\", \"name\":")
        let broken = buildMilestoneOverview(ArrayList<ProjectEntry>([p]), Config.defaults())
        let bc = Json.getOr(broken, "counts")
        // 核心：degraded 必须为 true，且健康度必须被说出来
        @Assert(Json.boolAt(bc, "degraded", false))
        @Assert(Json.strAt(bc, "storeHealth", "ok") == "corrupt")
        // readCount 用来和「本来就有多少条」对照
        @Assert(Json.intAt(bc, "readCount", -1) == 0)
        // 三态键必须**恒发**：键出现与否取决于数据的话，消费方得写两套解码分支
        let okCounts = Json.getOr(healthy, "counts")
        @Assert(Json.has(okCounts, "storeHealth"))
        @Assert(Json.has(okCounts, "degraded"))
        @Assert(Json.has(okCounts, "readCount"))
    } finally {
        exitTestHome()
        removePathIfExists(repo)
        removePathIfExists(home)
    }
}

@Test
func testDashboardTextUsesListedNotSuccessfulCount(): Unit {
    // 「上限/子集当全量」这一族：status 修过（#115）、summary 修过（#125），
    // 这里是**第三处** —— 同一个毛病从同一个数据源的另一个出口钻出来。
    //
    // projects.total / listed / failed 三个字段 JSON 里一直是齐的，
    // **只有 cmdDashboard 的文本用了 total**（采集成功数）：
    // 实测注册 3 个项目、其中 1 个路径失效，文本写「共 2 个」而注册表里有 3 个，
    // 那个坏掉的项目就这么从视野里消失，零披露。
    //
    // 这里只测数据源侧的字段语义（文本渲染在 cli 包，跨包不便断言），
    // 但必须钉住「listed 才是注册表条数」这个前提，否则下一个人又会去用 total。
    let home = "/tmp/deepgit-dashlisted-${nowMillis()}"
    ensureDir(home)
    enterTestHome(home)
    let r1 = home + "-r1"
    let r2 = home + "-r2"
    try {
        ensureDir(r1)
        ensureDir(r2)
        for (r in [r1, r2]) {
            gitRun(r, ["init", "-b", "main"], false)
            writeFileAtomic(r + "/a.txt", "1")
            gitRun(r, ["add", "."], false)
            gitRun(r, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: x"], false)
        }
        let (p1, _) = addProject(r1, "d1", ArrayList<String>(), "")
        let (p2, _) = addProject(r2, "d2", ArrayList<String>(), "")
        // 把一个项目的目录搬走 → 采集失败
        let stash = home + "-stash"
        // 搬走目录制造「路径失效」：flow 包调不到 kernel 的 moveDirForTest，
        // 这里直接走同样的 execCapture("mv") 路子
        let mvRes = execCapture("mv", [r2, stash], None, 8000)
        @Assert(mvRes.ok())

        let dash = buildDashboard(
            ArrayList<ProjectEntry>([p1, p2]), Config.defaults()
        )
        let projs = Json.getOr(dash, "projects")
        // 前提：确实一个成功一个失败
        @Assert(Json.intAt(projs, "failed", 0) == 1)
        @Assert(Json.intAt(projs, "total", 0) == 1)
        // listed 才是注册表里一共多少条 —— 文本必须用它
        @Assert(Json.intAt(projs, "listed", 0) == 2)
    } finally {
        exitTestHome()
        removePathIfExists(home + "-stash")
        removePathIfExists(r1)
        removePathIfExists(r2)
        removePathIfExists(home)
    }
}

// #158 回归：dashboard 同屏两套项目口径。
//
// 真实故障：2 个项目，on2 手工置 disabled:true（引擎没有 enable/disable 子命令，
// disabled 只能手改 registry.json），各 1 条 open 里程碑。修之前：
//     项目群：共 1 个 · …                ← allProjectStatuses 跳过停用项目
//     里程碑：进行中 2 · …               ← buildMilestoneOverview 不过滤
//       on2｜已停用项目的里程碑 · 进行中 · 创建以来 1 提交   ← 项目群外的东西
// 同一屏里两个数字直接打架，而且里程碑的 commitsSince 还为停用项目真跑了 git rev-list。
//
// 这条测试断言三件事，缺一件都留缺口：
//   1. 停用项目的里程碑不计入 counts、不进 items
//   2. 被筛掉的条数**恒发**在 excludedDisabled 里（否则全停用时又变回「一个都没有」）
//   3. readCount 能与各分桶对账 —— 消费方据此自证没有隐形黑洞
@Test
func testMilestoneOverviewExcludesDisabledProjectsAndAccountsForThem(): Unit {
    let base = "/tmp/dg_dash_disabled_${nowMillis()}"
    let testHome = "${base}/home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)

    // 启用的项目必须是**真实可采集的 git 仓库**：里程碑进度要看 commitsSince，
    // 路径不存在会走 unknown（仓库读不出来），那 open 就不是 1，断言会失去意义。
    let repo = "${base}/repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic("${repo}/a.txt", "a")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)

    let on = ProjectEntry("p_on", "on1", repo, "git", "", nowIso(), ArrayList<String>(), false)
    // 停用项目刻意指向不存在的路径：万一哪天闸门被撤掉、又去采集它，
    // 这条会变 unknown，open 就不再是 1 —— 负控有地方红。
    let off = ProjectEntry("p_off", "on2", "${base}/gone", "git", "", nowIso(), ArrayList<String>(), true)
    let both = ArrayList<ProjectEntry>([on, off])

    // 前提先自证：两条里程碑确实写进去了，且一条属停用项目
    let (m1, ok1) = addMilestone("p_on", "启用项目的里程碑", "", "2027-01-01", "")
    let (m2, ok2) = addMilestone("p_off", "已停用项目的里程碑", "", "2027-06-01", "")
    @Assert(ok1 && ok2)
    @Assert(loadMilestones().size == 2)

    let counts = Json.getOr(buildMilestoneOverview(both, Config.defaults()), "counts")

    // 1. 停用项目不计入
    @Assert(Json.intAt(counts, "open", -1) == 1)
    @Assert(Json.intAt(counts, "done", -1) == 0)
    @Assert(Json.intAt(counts, "dropped", -1) == 0)
    @Assert(Json.intAt(counts, "unknown", -1) == 0)

    // 2. 筛掉的必须说出来。「进行中 0」配「无里程碑」是谎报。
    @Assert(Json.intAt(counts, "excludedDisabled", -1) == 1)
    @Assert(Json.has(counts, "orphaned"))
    @Assert(Json.intAt(counts, "orphaned", -1) == 0)

    // items 里不能出现停用项目的里程碑
    let items = Json.arrAt(buildMilestoneOverview(both, Config.defaults()), "items")
    @Assert(items.size == 1)
    @Assert(Json.strAt(items[0], "projectName", "") == "on1")
    @Assert(Json.strAt(items[0], "name", "") == "启用项目的里程碑")

    // 3. 对账：readCount = 计入 + 停用 + 孤儿。
    //    没有这条，前两个断言可以靠「把读到的条数悄悄扔掉」同时成立。
    let c2 = Json.getOr(buildMilestoneOverview(both, Config.defaults()), "counts")
    let accounted = Json.intAt(c2, "open", 0) + Json.intAt(c2, "done", 0) +
        Json.intAt(c2, "dropped", 0) + Json.intAt(c2, "unknown", 0) +
        Json.intAt(c2, "excludedDisabled", 0) + Json.intAt(c2, "orphaned", 0)
    @Assert(Json.intAt(c2, "readCount", -1) == 2)
    @Assert(accounted == Json.intAt(c2, "readCount", -1))

    removePathIfExists(base)
    exitTestHome()
    removePathIfExists(testHome)
}

/// milestones.items 必须是**完整**列表：条目数 == 计入数，一条都不许少。
///
/// 缺陷 #207 的引擎侧那一半。那边是客户端的仪表盘卡片写了 `items.prefix(5)`
/// 却不披露（已修），但它成立的前提是**引擎给的是全量** —— 一旦哪天有人
/// 在这里给 items 加个上限（省流量、怕太大），客户端那句「共 N 条」就会
/// 跟着变成假话，而两边都不会红：引擎测试只看 counts（counts 仍然是全量），
/// 客户端只看 items（items 已经少了几条但看不出少了几条）。
/// 客户端契约检查【14】拿真实引擎数据对这条等式，两端合起来才关得严。
///
/// 顺带钉住另一件已经成立的事：**items 没有任何条数上限**。
/// 1 个项目 8 条里程碑 ⇒ items 8 条。哪天引入上限，这条会先红。
@Test
func testDashboardMilestoneItemsAreCompleteAndUncapped(): Unit {
    let base = "/tmp/dg_msitems-${nowMillis()}"
    let testHome = "${base}/home"
    enterTestHome(testHome)
    let repo = "${base}/repo"
    try {
        ensureDir(repo)
        gitRun(repo, ["init", "-b", "main"], false)
        writeFileAtomic(repo + "/a.txt", "1")
        gitRun(repo, ["add", "."], false)
        gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: x"], false)
        let (p, _) = addProject(repo, "msitems", ArrayList<String>(), "")

        // 8 条：客户端卡片的上限是 5，8 > 5 才有判别力
        let n: Int64 = 8
        var i: Int64 = 1
        while (i <= n) {
            let (_, ok) = addMilestone(p.id, "v${i}.0", "", "", "")
            @Assert(ok)
            i += 1
        }

        let ms = buildMilestoneOverview(ArrayList<ProjectEntry>([p]), Config.defaults())
        let counts = Json.getOr(ms, "counts")
        let items = Json.arrAt(ms, "items")

        @Assert(Json.intAt(counts, "open", -1) == n)
        @Assert(Json.intAt(counts, "readCount", -1) == n)
        // 核心：条目数 == 计入数。少一条就是静默截断。
        @Assert(items.size == n)
        // 对照：客户端的上限是 5，而引擎给的必须比它多 ——
        // 少了这条，上面那条可能只是「恰好都在上限内」。
        @Assert(items.size > 5)
        // 条名不许重复（4 个同名 + 4 个不同名是更容易被误当成「去重了」的形状）
        var names = ArrayList<String>()
        for (it in items) {
            let nm = Json.strAt(it, "name", "")
            @Assert(!names.contains(nm))
            names.add(nm)
        }
        @Assert(names.size == n)
    } finally {
        exitTestHome()
        removePathIfExists(repo)
        removePathIfExists(testHome)
        removePathIfExists(base)
        removePathIfExists(deepgitPath(["store", "msitems"]))
    }
}

// 孤儿（项目已 remove）也必须恒发。#154 已在 `milestone list` 侧披露过，
// dashboard 侧此前同样沉默 —— 读到的是「这个项目群只有 1 个里程碑」。
// 负控：撤掉 case None 分支的 orphanCount += 1，这条必须红在 orphaned == 1。
@Test
func testMilestoneOverviewReportsOrphanedEntries(): Unit {
    let base = "/tmp/dg_dash_orphan_${nowMillis()}"
    let testHome = "${base}/home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)

    let repo = "${base}/repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic("${repo}/a.txt", "a")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)

    let live = ProjectEntry("p_live", "live", repo, "git", "", nowIso(), ArrayList<String>(), false)
    let (m1, ok1) = addMilestone("p_live", "活着的里程碑", "", "2027-01-01", "")
    // projectId 指向一个不存在的项目
    let (m2, ok2) = addMilestone("p_gone", "孤儿里程碑", "", "2027-02-01", "")
    @Assert(ok1 && ok2)

    let ov = buildMilestoneOverview(ArrayList<ProjectEntry>([live]), Config.defaults())
    let counts = Json.getOr(ov, "counts")
    @Assert(Json.intAt(counts, "open", -1) == 1)
    @Assert(Json.intAt(counts, "orphaned", -1) == 1)
    @Assert(Json.arrAt(ov, "items").size == 1)
    let c2 = Json.getOr(ov, "counts")
    let accounted = Json.intAt(c2, "open", 0) + Json.intAt(c2, "done", 0) +
        Json.intAt(c2, "dropped", 0) + Json.intAt(c2, "unknown", 0) +
        Json.intAt(c2, "excludedDisabled", 0) + Json.intAt(c2, "orphaned", 0)
    @Assert(accounted == Json.intAt(c2, "readCount", -1))

    removePathIfExists(base)
    exitTestHome()
    removePathIfExists(testHome)
}

/// #182 回归：认不出来的 status 不得从统计里人间蒸发。
///
/// 负控（曾真实发红）：计数用 `case _ => ()`，于是手写一条
/// `status:"active"` 的里程碑后，它**从每个桶里都消失**：
///   readCount = 2，而 open+done+dropped+unknown+excluded+orphan = 1
/// 对账等式失真；终端更直接自相矛盾 ——
///   「里程碑：进行中 1 · 已达成 0 · 已放弃 0」而下面列了 2 条。
@Test
func testUnrecognizedMilestoneStatusIsCountedNotDropped(): Unit {
    let home = "/tmp/dg_msother-${nowMillis()}"
    let repo = "${home}-repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic("${repo}/a.txt", "a")
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "i"], false)
    enterTestHome(home)
    try {
        let (p, _) = addProject(repo, "other", ArrayList<String>(), "")
        // 一条正常 + 一条认不出来的状态
        writeFileAtomic("${home}/milestones.json", buildTwoMilestones(p.id))
        let dash = buildDashboard(ArrayList<ProjectEntry>([p]), Config.defaults())
        let counts = Json.getOr(Json.getOr(dash, "milestones"), "counts")
        // other 必须恒发
        @Assert(Json.has(counts, "other"))
        @Assert(Json.intAt(counts, "other", -1) == 1)
        // 对账必须平：各桶之和 == readCount
        let sum = Json.intAt(counts, "open", 0) + Json.intAt(counts, "done", 0)
            + Json.intAt(counts, "dropped", 0) + Json.intAt(counts, "unknown", 0)
            + Json.intAt(counts, "excludedDisabled", 0) + Json.intAt(counts, "other", 0)
            + Json.intAt(counts, "orphaned", 0)
        @Assert(sum == Json.intAt(counts, "readCount", -1))
        // 文本披露由 cli 包的 testDashboardMilestoneLineDisclosesOtherStatus 覆盖
        // （dashboardMilestoneLine 在 moongit.cli，这里跨包访问不到）
    } finally {
        exitTestHome()
        removePathIfExists(repo)
        removePathIfExists(home)
    }
}

/// 造两份里程碑：一条 open、一条 status 是没见过的 "active"。
private func buildTwoMilestones(projectId: String): String {
    let o = Json.obj()
    let arr = ArrayList<JsonValue>()
    for ((id, st) in [("m1", "open"), ("m2", "active")]) {
        let m = Json.obj()
        Json.set(m, "id", Json.of(id))
        Json.set(m, "projectId", Json.of(projectId))
        Json.set(m, "name", Json.of("v-${id}"))
        Json.set(m, "targetDate", Json.of("2027-06-01"))
        Json.set(m, "status", Json.of(st))
        Json.set(m, "createdAt", Json.of("2026-01-01T00:00:00+08:00"))
        arr.add(m)
    }
    Json.set(o, "milestones", JArr(arr))
    return Json.pretty(o)
}

/// #184 回归：报告里的「已注册」必须是注册表里一共多少条，不是参与统计的数。
///
/// 负控（曾真实发红）：停用 1 个项目后，
/// `moongit list` 诚实地说「共 3 个项目（1 个已停用，不参与统计）」，
/// 而报告写「项目总数（已注册） | 2」—— 3 个注册的报成 2。
/// 而同一份报告的里程碑小节**却**披露了停用项目（#158 只修了那一半）。
///
/// ⚠️ 本条只覆盖**渲染函数**（给什么数写什么数）。
/// `cmdReport` 那个「整群报告该传谁」的接缝在另一个包里，本测试结构上走不到，
/// 由 `moongit.cli` 的 `testCmdReportGroupReportCountsDisabledAsRegistered`
/// 端到端调用 `cmdReport` 后断言落盘文件来钉住。
/// 别因为这条绿就以为接线也绿了 —— 负控 NC35-c 实测：接线退回错误版本时本条照样全绿。
@Test
func testReportRegisteredCountIncludesDisabledProjects(): Unit {
    let home = "/tmp/dg_regcnt-${nowMillis()}"
    let r1 = "${home}-a"
    let r2 = "${home}-b"
    ensureDir(r1)
    ensureDir(r2)
    for (r in [r1, r2]) {
        gitRun(r, ["init", "-b", "main"], false)
        writeFileAtomic("${r}/a.txt", "a")
        gitRun(r, ["-c", "user.name=t", "-c", "user.email=t@t", "add", "."], false)
        gitRun(r, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "i"], false)
    }
    enterTestHome(home)
    try {
        let (pa, _) = addProject(r1, "aa", ArrayList<String>(), "")
        let (_, _) = addProject(r2, "bb", ArrayList<String>(), "")
        // 手工停用（引擎没有 enable/disable 子命令，手改 registry 是既定用法）
        let reg0 = loadRegistry()
        for (e in reg0.projects) {
            if (e.id == pa.id) {
                e.disabled = true
            }
        }
        saveRegistry(reg0)

        let reg = loadRegistry()
        let dash = buildDashboard(reg.projects, Config.defaults())
        let projs = Json.getOr(dash, "projects")
        @Assert(Json.intAt(projs, "registered", -1) == 2)
        @Assert(Json.intAt(projs, "excludedDisabled", -1) == 1)
        @Assert(Json.intAt(projs, "listed", -1) == 1)   // 参与统计的确实只有 1

        let statuses = allProjectStatuses(reg.projects, Config.defaults(), false)
        let md = renderReportMarkdown(statuses, dash, "zh")
        @Assert(md.contains("| 项目总数（已注册） | 2 |"))
        @Assert(md.contains("其中已停用（不参与统计） | 1"))
    } finally {
        exitTestHome()
        removePathIfExists(r1)
        removePathIfExists(r2)
        removePathIfExists(home)
    }
}

/// #187 回归：语言采集**失败**必须与「截断」分开披露，且不许被当成「没有语言」。
///
/// 负控（曾真实发红）：失败的项目被 catch 成空 stats、truncated 仍是 false，
/// 于是 `languagesFailed` 根本不存在（键都取不到），
/// 报告写「语言分布：Python 1 · Rust 1」而其中 1 个项目压根没被看过。
@Test
func testLanguageCollectionFailureIsDisclosedNotSilentlyDropped(): Unit {
    let base = "/tmp/dg_dash_langfail_${nowMillis()}"
    let testHome = "${base}/home"
    let good = "${base}/good"
    let bad = "${base}/bad"
    ensureDir(good)
    ensureDir(bad)
    for (r in [good, bad]) {
        gitRun(r, ["init", "-q", "-b", "main"], false)
        writeFileAtomic("${r}/a.py", "x")
        gitRun(r, ["add", "."], false)
        gitRun(r, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "i"], false)
    }
    writeFileAtomic("${good}/b.rs", "y")
    gitRun(good, ["add", "."], false)
    gitRun(good, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "j"], false)
    // 把 bad 的 index 截断：git ls-files 与 git status 都会失败，
    // 但语言采集的失败是**独立**的一条路（buildDashboard 自己 spawn 了 ls-files），
    // 正是「status 那边已经报了错，语言这边却静悄悄」的场景。
    writeFileAtomic("${bad}/.git/index", "xx")

    enterTestHome(testHome)
    try {
        let reg = Registry()
        reg.projects.add(ProjectEntry("p_good", "good", good, "git", "", nowIso(), ArrayList<String>(), false))
        reg.projects.add(ProjectEntry("p_bad", "bad", bad, "git", "", nowIso(), ArrayList<String>(), false))
        let d = buildDashboard(reg.projects, Config.defaults())

        // 恒发：不是「有失败才发」，是每次都发，0 也要在
        @Assert(Json.has(d, "languagesFailed"))
        @Assert(Json.intAt(d, "languagesFailed", -1) == 1)
        // 失败原因必须能读出来，不能是个空串
        let reasons = Json.arrAt(d, "languagesFailedReasons")
        @Assert(reasons.size == 1)
        match (Json.asStr(reasons[0])) {
            case Some(r) => @Assert(r.contains("ls-files"))
            case None => @Assert(false)
        }
        // 关键：languagesTruncated 仍是 false —— 正因为如此，
        // 光靠它读者会以为「这份分布是完整的」。失败必须另有其字段。
        @Assert(!Json.boolAt(d, "languagesTruncated", true))
        // 好项目的语言不能被坏项目连累
        @Assert(Json.arrAt(d, "languages").size == 2)

        // 反向：全部正常时 languagesFailed 必须是 0（不是缺键）
        let reg2 = Registry()
        reg2.projects.add(ProjectEntry("p_good", "good", good, "git", "", nowIso(), ArrayList<String>(), false))
        let d2 = buildDashboard(reg2.projects, Config.defaults())
        @Assert(Json.has(d2, "languagesFailed"))
        @Assert(Json.intAt(d2, "languagesFailed", -1) == 0)
        @Assert(Json.arrAt(d2, "languagesFailedReasons").size == 0)
    } finally {
        exitTestHome()
        removePathIfExists(base)
    }
}

// ------------------------------ #205：语言分布的截断必须披露 ------------------------------

/// 剔 Markdown 必须在 top 上限**之前**。
///
/// 缺陷 #205 的直接后果：原来先 `langStats(names, 12)` 再过滤 Markdown，
/// 于是 Markdown 白占一个名额又被丢掉 —— 上限 12 实际只出 11 条，
/// 第 12 种**真实**语言被静默吞掉，而 `languagesTruncated` 仍是 false
/// （它只反映 20000 文件上限，与这条无关），等于反过来声称「这份画像是完整的」。
///
/// 实测：14 种真实语言 + 10 个 .md 的仓库
///   修复前 → 11 条，Shell/Swift/TypeScript 三种消失，languagesTopCut 无此键
///   修复后 → 12 条，languagesTopCut = true
@Test
func testLangTopFilterDropsMarkdownBeforeTheCap(): Unit {
    // Markdown 必须在统计之前就没了，而不是统计完再丢
    let files = ArrayList<String>(["a.py", "README.md", "b.rs", "docs/x.mdx", "c.go"])
    let kept = langTopFilter(files)
    @Assert(kept.size == 3)
    for (f in kept) {
        @Assert(languageOf(f) != "Markdown")
    }
    // 判据复用 languageOf，不另抄一份扩展名表 —— 这里锁住这个复用
    @Assert(kept[0] == "a.py")
    @Assert(kept[1] == "b.rs")
    @Assert(kept[2] == "c.go")
    // 空输入不炸
    @Assert(langTopFilter(ArrayList<String>()).isEmpty())
}

/// 截断判定与切片的纯函数。
@Test
func testLangTopCutAndSlice(): Unit {
    let three = ArrayList<(String, Int64)>([("a", 3), ("b", 2), ("c", 1)])
    // 不到上限：不砍
    @Assert(!langTopCut(three, 3))
    @Assert(!langTopCut(three, 10))
    @Assert(langTopSlice(three, 3).size == 3)
    @Assert(langTopSlice(three, 10).size == 3)
    // 超过上限：砍，并如实说砍了
    @Assert(langTopCut(three, 2))
    let sliced = langTopSlice(three, 2)
    @Assert(sliced.size == 2)
    // 保留的是**排名靠前**的（langStats 已按计数排序）
    @Assert(sliced[0][0] == "a")
    @Assert(sliced[1][0] == "b")
    // 空数组
    let none = ArrayList<(String, Int64)>()
    @Assert(!langTopCut(none, 3))
    @Assert(langTopSlice(none, 3).isEmpty())
    @Assert(DASH_LANG_TOP == 12)
}

/// 端到端：语言种类超上限时，`languagesTopCut` 必须为 true，
/// 且展示条数真的到上限（而不是被 Markdown 吃掉一个名额）。
/// 走 buildDashboard 这条生产路径。
@Test
func testDashboardDisclosesLanguageTopCut(): Unit {
    let base = "/tmp/deepgit-langtop-${nowMillis()}"
    let repo = base + "/poly"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    // 10 个 .md —— 保证 Markdown 稳定进入 top 12，白占名额（缺陷的成因）
    for (i in 0..10) {
        writeFileAtomic("${repo}/doc${i}.md", "x")
    }
    // 14 种真实语言（languageOf 能全部区分）
    let exts = ["mbt", "ts", "js", "swift", "rs", "cj", "go", "py", "kt", "c", "css", "html", "json", "sh"]
    for (e in exts) {
        writeFileAtomic("${repo}/f.${e}", "x")
    }
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "poly"], false)

    let reg = Registry()
    reg.projects.add(ProjectEntry("p_poly", "poly", repo, "git", "", nowIso(), ArrayList<String>(), false))
    let d = buildDashboard(reg.projects, Config.defaults())

    let langs = Json.arrAt(d, "languages")
    // 展示条数真的到上限 12（修复前是 11）
    @Assert(langs.size == 12)
    // ⚠️ 恒发 + 如实为 true。修复前这个键**根本不存在**，
    // 而 languagesTruncated 是 false —— 界面据此以为这是完整画像。
    @Assert(Json.has(d, "languagesTopCut"))
    @Assert(Json.boolAt(d, "languagesTopCut", false))
    // 被砍掉的是**真实**语言，不是 Markdown（Markdown 不该占名额）
    var hasMarkdown = false
    for (e in langs) {
        if (Json.strAt(e, "language", "") == "Markdown") {
            hasMarkdown = true
        }
    }
    @Assert(!hasMarkdown)
    removePathIfExists(base)
}

/// 语言种类**没**超上限时不能谎报截断（否则披露就成了噪声）。
@Test
func testDashboardDoesNotClaimTopCutWhenComplete(): Unit {
    let base = "/tmp/deepgit-langfull-${nowMillis()}"
    let repo = base + "/small"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic("${repo}/a.py", "x")
    writeFileAtomic("${repo}/b.rs", "x")
    writeFileAtomic("${repo}/README.md", "x")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "small"], false)

    let reg = Registry()
    reg.projects.add(ProjectEntry("p_small", "small", repo, "git", "", nowIso(), ArrayList<String>(), false))
    let d = buildDashboard(reg.projects, Config.defaults())

    @Assert(Json.arrAt(d, "languages").size == 2)
    @Assert(Json.has(d, "languagesTopCut"))
    @Assert(!Json.boolAt(d, "languagesTopCut", true))
    removePathIfExists(base)
}

// ------------------------------ 契约C：untrackedError 的汇总侧消费 ------------------------------

/// 剥注释后的源码（测试用）。复用 util 的 stripCjCommentEx ——
/// 剥法只允许有一份，自己再写第二份必踩「字符串里的 //」与
/// 「字节拼接成数字串」两个坑（AGENTS.md 不变量 45 的血泪）。
private func dashCodeOnly(src: String): String {
    let sb = StringBuilder()
    var st = CjStripState.Normal
    for (line in src.split("\n")) {
        let (stripped, next) = stripCjCommentEx(line, st)
        st = next
        sb.append(stripped)
        sb.append("\n")
    }
    return sb.toString()
}

/// 聚合判定的纯函数路径：读不到的项目单列、不把 0 冒充数据。
///
/// 「untrackedError 非空且 status 成功」在磁盘上构造不出来（见
/// untrackedFailureAggregates 的注释），所以非空路径对 statuses 直接断言 ——
/// statuses 按 projectStatus 的真实形状手搓（该键恒发，空串 = 正常）。
@Test
func testUntrackedFailureAggregatesSeparatesUnreadableFromZero(): Unit {
    let okS = Json.obj()
    Json.set(okS, "name", Json.of("ok"))
    Json.set(okS, "untrackedCount", Json.of(3))
    Json.set(okS, "untrackedError", Json.of(""))
    let badS = Json.obj()
    Json.set(badS, "name", Json.of("bad"))
    Json.set(badS, "untrackedCount", Json.of(0))
    Json.set(badS, "untrackedError", Json.of("git ls-files --others 失败：fatal: index file corrupt"))
    // 错误桩形状：整个 status 采集失败（untrackedCount=-1），不参与统计
    let errS = Json.obj()
    Json.set(errS, "name", Json.of("err"))
    Json.set(errS, "error", Json.of("路径不存在或卷未挂载"))
    Json.set(errS, "untrackedCount", Json.of(-1))
    Json.set(errS, "untrackedError", Json.of(""))

    let (failed, samples, total) = untrackedFailureAggregates(
        ArrayList<JsonValue>([okS, badS, errS]))
    @Assert(failed == 1)
    @Assert(samples.size == 1)
    @Assert(samples[0].contains("ls-files"))
    // 只累加读得到的：失败项与错误桩都不把 0 / -1 冒充进总数
    @Assert(total == 3)
    // 全健康：failed=0、samples 空 —— 披露键恒发但值如实为空
    let (f0, s0, t0) = untrackedFailureAggregates(ArrayList<JsonValue>([okS]))
    @Assert(f0 == 0)
    @Assert(s0.isEmpty())
    @Assert(t0 == 3)
}

/// 恒发 + 接线的端到端一半：健康项目群走真实 buildDashboard，
/// work.untrackedFailed / untrackedFailedReasons 两个键必须在且如实为 0 / 空
/// （恒发，不靠「有失败才发」—— 那正是键集随数据漂的来源）。
@Test
func testDashboardAlwaysEmitsUntrackedFailureFields(): Unit {
    let base = "/tmp/dg_dash_utok-${nowMillis()}"
    let repo = "${base}/repo"
    try {
        ensureDir(repo)
        gitRun(repo, ["init", "-q", "-b", "main"], false)
        writeFileAtomic("${repo}/a.py", "x")
        // 留一个未提交文件：前提自证「健康路径下未跟踪数是真实值（1），不是 0」，
        // 否则下面的 untrackedFiles==1 可能只是占位 0 碰巧相等
        writeFileAtomic("${repo}/loose.txt", "y")
        gitRun(repo, ["add", "a.py"], false)
        gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "i"], false)
        let reg = Registry()
        reg.projects.add(ProjectEntry("p_utok", "utok", repo, "git", "", nowIso(), ArrayList<String>(), false))
        let d = buildDashboard(reg.projects, Config.defaults())
        let work = Json.getOr(d, "work")
        @Assert(Json.intAt(work, "untrackedFiles", -1) == 1)
        @Assert(Json.has(work, "untrackedFailed"))
        @Assert(Json.intAt(work, "untrackedFailed", -1) == 0)
        @Assert(Json.has(work, "untrackedFailedReasons"))
        @Assert(Json.arrAt(work, "untrackedFailedReasons").size == 0)
    } finally {
        removePathIfExists(repo)
        removePathIfExists(base)
    }
}

/// 接线 lint（不变量 28）：判定抽成纯函数后，buildDashboard 必须真的走它 ——
/// 否则纯函数测试再绿，测的也是没人调用的代码，而恒发测试分不清
/// 「真实聚合出 0」与「硬编码 0」。剥注释后匹配（AGENTS.md 不变量 30）。
@Test
func testBuildDashboardWiresUntrackedFailureAggregates(): Unit {
    let srcOpt = readFileTextChecked("src/flow/dashboard.cj")
    @Assert(srcOpt.isSome())   // 前提：真的读到了源码，不是空跑
    match (srcOpt) {
        case Some(raw) =>
            let code = dashCodeOnly(raw)
            // 前提：剥注释器没退化成恒等函数 —— 注释里的字面量必须已消失。
            // 金丝雀用拼接构造：断言自己的字符串字面量会保留在剥离结果里，
            // 写成整串字面量就成了「检查咬到自己」（不变量 30 的变体）。
            let canary = "剥法只允" + "许有一份"
            @Assert(!code.contains(canary))
            // 定义在
            @Assert(code.contains("func untrackedFailureAggregates"))
            // 调用点在（buildDashboard 内拿 statuses 喂它，不是只有定义没人用）
            @Assert(code.contains("untrackedFailureAggregates(statuses)"))
        case None => ()
    }
}
