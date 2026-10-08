// 浅更新（update）：记录各分支进度到 store + README/AGENT 托管区域。
package moongit.flow

import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.kernel.*
import moongit.util.*

public class UpdateOptions {
    public var mode: String = "shallow"
    public var docs: String = ""  // "" | readme | agent
    public var dryRun: Bool = false
    public var skipDocs: Bool = false
    public var source: String = "cli"
    public var notes: ArrayList<String> = ArrayList<String>()

    public init() {}
}

public class UpdateResult {
    public let ok: Bool
    public let mode: String
    public let projectId: String
    public let projectName: String
    public let provider: String
    public let branchCount: Int64
    /// 本轮真正新记录的提交数（journal / 文案口径）。
    /// 不是各分支基线规模之和 —— 那个量在无新提交时会退化成整份基线重放。
    public let commitCount: Int64
    /// 仓库真实分支数。None = 读不出来 / 非 git 项目，
    /// 与 branchCount（= 建立了基线的分支数）**不是**同一个口径。
    public let repoBranchCount: Option<Int64>
    public let docChanges: ArrayList<(String, Bool, Bool, String, String)>
    public let journalEntry: JsonValue
    public let facts: RepoFacts
    public let at: String

    public init(
        ok: Bool, mode: String, projectId: String, projectName: String, provider: String,
        branchCount: Int64, commitCount: Int64, repoBranchCount: Option<Int64>,
        docChanges: ArrayList<(String, Bool, Bool, String, String)>, journalEntry: JsonValue, facts: RepoFacts, at: String,
    ) {
        this.ok = ok
        this.mode = mode
        this.projectId = projectId
        this.projectName = projectName
        this.provider = provider
        this.branchCount = branchCount
        this.commitCount = commitCount
        this.repoBranchCount = repoBranchCount
        this.docChanges = docChanges
        this.journalEntry = journalEntry
        this.facts = facts
        this.at = at
    }
}

/// 候选分支集合：已追踪 ∪ 当前 ∪ 默认 ∪ 最近活跃
func collectCandidateBranches(facts: RepoFacts, progress: JsonValue, maxBranches: Int64): ArrayList<String> {
    let names = ArrayList<String>()
    func push(n: String) {
        if (n.isEmpty() || n == "HEAD") {
            return
        }
        for (x in names) {
            if (x == n) {
                return
            }
        }
        names.add(n)
    }
    for ((name, _) in progressBranches(progress)) {
        push(name)
    }
    push(facts.currentBranch)
    push(facts.defaultBranch)
    // 最近提交的分支优先
    let sorted = ArrayList<BranchInfo>()
    for (b in facts.branches) {
        sorted.add(b)
    }
    var i: Int64 = 1
    while (i < sorted.size) {
        let key = sorted[i]
        var j = i - 1
        while (j >= 0 && sorted[j].date < key.date) {
            sorted[j + 1] = sorted[j]
            j -= 1
        }
        sorted[j + 1] = key
        i += 1
    }
    var taken: Int64 = 0
    for (b in sorted) {
        if (taken >= maxBranches) {
            break
        }
        push(b.name)
        taken += 1
    }
    // 上限
    if (names.size > maxBranches * 2) {
        let trimmed = ArrayList<String>()
        var k: Int64 = 0
        for (n in names) {
            if (k >= maxBranches * 2) {
                break
            }
            trimmed.add(n)
            k += 1
        }
        return trimmed
    }
    return names
}

/// 执行浅更新
public func runUpdate(project: ProjectEntry, config: Config, opts: UpdateOptions): UpdateResult {
    // 早于任何写操作：拼错的 docs 绝不能落到「范围最大的那次」上去。
    // 收敛点与 validateDeepScope 同理 —— 各调用面自己校验一定会漏一处。
    validateUpdateDocs(opts.docs)
    let store = ensureStore(project.id)
    // 锁名必须与 runDeep 完全一致。三条路径写的是同一批文件
    // （store 的 progress/state/journal + 用户仓库里 README/AGENTS 的托管区读-改-写），
    // 而以前这里按 opts.mode 分裂成 track.lock / update.lock，runDeep 又用 project.lock ——
    // 三个互不排斥的锁名意味着「防并发更新」根本没生效：
    //   moongit update myproj   （终端 A）
    //   moongit track --quiet   （A 刚 commit 完，post-commit 钩子后台自动触发）
    // 会同时进入临界区，后写者用陈旧快照覆盖 progress.json，state.json 的 runCount 少加。
    // 锁名表达的是「互斥哪个资源」，不是「做哪种操作」。
    let lockFile = "${store.locks}/project.lock"
    let startedAt = nowIso()

    return withLock(lockFile, 600000, { =>
        Log.step("采集仓库事实：${project.name}")
        let facts = collectFacts(project.path, project.kind, config, 30, false)
        var progress = readProgress(project.id)
        Json.set(progress, "projectId", Json.of(project.id))
        Json.set(progress, "name", Json.of(project.name))

        let base = recordBranchBaseline(project, config, facts, progress, config.maxShallowBranches)
        let deltas = base.deltas
        let narratives = base.narratives
        let branchCount = base.branchCount
        let totalCommits = base.totalCommits
        let newCommits = base.newCommits
        let commitsTruncated = base.commitsTruncated
        let overall = base.overall
        let repoBranchCount = base.repoBranchCount
        let provider = "rules"

        // 日志条目
        let entry = Json.obj()
        Json.set(entry, "id", Json.of(randomId("j")))
        Json.set(entry, "at", Json.of(startedAt))
        Json.set(entry, "project", Json.of(project.name))
        Json.set(entry, "projectId", Json.of(project.id))
        Json.set(entry, "branch", Json.of(if (facts.currentBranch.size > 0) { facts.currentBranch } else { facts.defaultBranch }))
        Json.set(entry, "mode", Json.of(opts.mode))
        Json.set(entry, "source", Json.of(opts.source))
        Json.set(entry, "provider", Json.of(provider))
        Json.set(entry, "commitCount", Json.of(newCommits))
        // commitCount 的口径必须**自述**。deep 路径的同一个键装的是
        // `facts.commitCount`（仓库提交总数，无上限），而这里是本轮新增 ——
        // 同名不同义正是本引擎反复栽跟头的地方。靠 mode 字段去猜口径不行：
        // 那是约定不是契约，改个 mode 名就静默错读了。
        Json.set(entry, "commitCountScope", Json.of("new"))
        // 与 engine 其余披露字段同一族（「上限当全量」已栽 7 次）。
        // 首次建基线时每分支只记最近 30 个提交，totalCommits 是这些样本的加总，
        // 不是该项目的提交总数。实测 100 提交的仓库：update 报「30 个提交」，
        // 紧接着 deep 报 100 —— 用户看到数字从 30 跳到 100，像数据丢了。
        // commitCount 现在是「本轮真正新记录的提交数」，不是各分支基线规模之和。
        //
        // 曾经它报的是后者，于是 3 个提交的仓库连跑三次 update 每次都报
        // 「3 个提交」，journal 里三条 commitCount 全是 3，隐含「记了 9 个」。
        //
        // 这里**没有**顺手加一个「基线总数」字段顶上：那个量在本引擎里
        // 根本不存在一致语义 —— 无新提交时 branchDelta 重放整份基线（有真增量时
        // 又只装增量），实测同一项目第一轮报 3、加一个提交后反而报 1。
        // 造一个会随分支状态变义的字段出门，比缺字段更糟。
        Json.set(entry, "commitCountTruncated", Json.of(commitsTruncated))
        // 分支数分母进 journal：只存 branchCount 的话，
        // 半年后回看 journal 只会得到「记录了 7 个分支」，
        // 而当时仓库有 16 个 —— 和 commitCountTruncated 同一族的分母披露
        match (repoBranchCount) {
            case Some(n) => Json.set(entry, "repoBranchCount", Json.of(n))
            case None => Json.set(entry, "repoBranchCount", Json.of(-1))
        }
        // 分支口径是否「追踪数 < 仓库总数」。标志位与数据成对传出去，
        // 消费方才不用自己拿两个数去比（#115/#125 之后的老教训）
        Json.set(entry, "branchCountTruncated", Json.of(match (repoBranchCount) {
            case Some(n) => n > branchCount
            case None => false
        }))
        Json.set(entry, "summary", Json.of(Json.strAt(overall, "summary", "")))
        let hlJson = ArrayList<JsonValue>()
        var hc: Int64 = 0
        for (d in deltas) {
            match (narratives.get(d.branch)) {
                case Some(n) =>
                    for (h in n.highlights) {
                        if (hc >= 6) {
                            break
                        }
                        hlJson.add(Json.of(h))
                        hc += 1
                    }
                case None => ()
            }
        }
        Json.set(entry, "highlights", JArr(hlJson))
        let nsJson = ArrayList<JsonValue>()
        var nsc: Int64 = 0
        for (d in deltas) {
            match (narratives.get(d.branch)) {
                case Some(n) =>
                    for (h in n.nextSteps) {
                        if (nsc >= 5) {
                            break
                        }
                        nsJson.add(Json.of(h))
                        nsc += 1
                    }
                case None => ()
            }
        }
        Json.set(entry, "nextSteps", JArr(nsJson))
        let docsArr = ArrayList<JsonValue>()
        for (n in opts.notes) {
            docsArr.add(Json.of(n))
        }
        Json.set(entry, "notes", JArr(docsArr))

        let entries = Json.arrAt(progress, "entries")
        entries.add(entry)
        Json.set(progress, "entries", JArr(entries))

        // 文档写入
        let docChanges = ArrayList<(String, Bool, Bool, String, String)>()
        // 文档写入失败要收集到 store 写完之后再报，不能就地抛 ——
        // 进度库是事实源，文档是派生视图，详见下面写循环处的注释。
        let docErrors = ArrayList<String>()
        if (!opts.skipDocs) {
            let targets = newDocTargets(config, opts.docs, facts)
            let readmeContent = renderProgressReadme(
                facts, progress, narratives, config.language,
                opts.mode, startedAt, config.maxShallowBranches,
            )
            let agentContent = renderProgressAgent(facts, progress, narratives, config.language, opts.mode, startedAt)

            // ⚠️ 写任何文件之前，先把**全部**目标预检一遍。
            //
            // 旧实现是「边遍历边写」：README 写成功后，遇到结构异常的 AGENTS.md
            // 才抛错，于是留下半成品 ——
            //   README 托管区：已改成「本次记录 2 个提交」
            //   store 的 journal / progress：一字未动，引擎对这次运行毫无记录
            // 结果是 README 声称的状态引擎并不持有：用户读 README 以为记下了，
            // `list`/`status` 却说没记，下次 update 还会把同一批提交再数一遍。
            //
            // previewRegions 与 applyRegions 共用 assertRegionsWritable，
            // 所以对**标记结构**而言「预检通过」等价于「真写不会抛」。
            // ⚠️ 但对**可写性**不成立 —— 下面写循环处的注释有实测反例。
            // 这一层预检仍然值得保留：它挡的是「一个都不写」这种最坏情况。
            if (!opts.dryRun) {
                for ((file, isReadme) in targets) {
                    let fullPath = "${project.path}/${file}"
                    let content = if (isReadme) { readmeContent } else { agentContent }
                    let regions = ArrayList<(String, String)>([("progress", content)])
                    let template = if (isReadme) { "# ${facts.name}\n\n" } else { "" }
                    previewRegions(fullPath, regions, template, "${store.backups}/${file.replace("/", "_")}")
                }
            }

            // 文档写入失败**不得中断**整轮：进度库才是事实源，文档是派生视图。
            //
            // ⚠️ 早先这里写着「previewRegions 与 applyRegions 共用 assertRegionsWritable，
            // 所以『预检通过』等价于『真写不会抛』」—— 这句话对**标记结构**成立，
            // 对**可写性**不成立，而且实测为假：
            //   chflags uchg AGENTS.md      （不可变位；权限位仍是 0644）
            //   deep → 「✓ 已更新 README.md」→「✗ Operation not permitted」→ exit 1
            //   结果 README 里写了「追踪 N 个分支」，而 store 里 branches=0、journal=0。
            // 用户读 README 以为记下了，list/status 却说没记，下次还会把同一批提交再数一遍。
            //
            // 靠「预检可写性」根治行不通：不可变位根本不在权限位里，
            // 只有真正写一次才知道；而且权限预检天然有 TOCTOU 窗口。
            //
            // 方向选择：**store 照写**，失败逐个收集、最后如实报出。
            // 宁可让某个文档这一轮保持陈旧（结果里明说），
            // 也不要制造「文档声称的状态引擎并不持有」这种两边无法自洽的局面。
            for ((file, isReadme) in targets) {
                let fullPath = "${project.path}/${file}"
                let content = if (isReadme) { readmeContent } else { agentContent }
                let regions = ArrayList<(String, String)>([("progress", content)])
                let template = if (isReadme) { "# ${facts.name}\n\n" } else { "" }
                if (opts.dryRun) {
                    // 如实报告会不会变，不要硬编码 true
                    let p = previewRegions(fullPath, regions, template, "${store.backups}/${file.replace("/", "_")}")
                    // dry-run 不写任何文件 ⇒ **没有备份**。第 5 位必须留空，
                    // 报一个不存在的备份比不报更坏（用户会去找那个文件）。
                    docChanges.add((file, p.changed, p.created, content, ""))
                    continue
                }
                let backupDir = "${store.backups}/${file.replace("/", "_")}"
                try {
                    let res = applyRegions(fullPath, regions, backupDir, template)
                    // 记录原始相对路径：备份目录名是 file.replace("/", "_")，不可逆
                    // （docs/AGENTS.md → docs_AGENTS.md）。verify 靠它找回真正的文档路径。
                    writeBackupManifest(backupDir, file)
                    // 第 5 位是**真实的备份路径**。原来 res.backup 在这里被丢掉：
                    // 引擎每次改文档都留了一份、按 backupKeep 裁剪，却从不告诉用户在哪。
                    docChanges.add((file, res.changed, res.created, "", res.backup))
                    if (res.changed) {
                        Log.ok("已更新 ${file}${if (res.created) { "（新建）" } else { "" }}")
                    } else {
                        Log.debug("${file} 无变化")
                    }
                } catch (e: Exception) {
                    // ⚠️ 必须 catch Exception 而不是 DgError：
                    // 真正会在这里冒出来的是 `Operation not permitted` 这类
                    // **标准库 IO 异常**（不可变位、只读挂载、磁盘满），
                    // 它不是 DgError。只 catch DgError 等于这个 catch 根本没写 ——
                    // 实测锁住 AGENTS.md 后 store 依然是 branches=0 / journal=0。
                    //
                    // 宽 catch 的风险是吞掉编程错误；这里通过原样上报 e.message
                    // 和非零退出码来对冲，不静默。
                    docErrors.add("${file}：${oneLineClamped(e.message, 90)}")
                    Log.error("${project.name}: ${file} 更新失败 —— ${oneLineClamped(e.message, 90)}")
                }
            }
        }

        // ⚠️ `docs` 必须在这里补，而不能在上面构造 entry 时就写 ——
        // 上面拿不到：docChanges 是文档写入循环跑完才有的，
        // 而 entry 那时已经定稿并塞进 progress 了。
        //
        // 原来只有 `flow/deep.cj` 往 journal entry 写 `docs`，
        // 于是浅更新的条目**压根没有这个键**。而 `flow/status.cj` 当时
        // 有一份手挑的 9 键投影，对不存在的 docs 硬塞了一个 `[]` ——
        // 「压根没记录」被压成「这次没碰任何文档」。恒空的假值比缺键更坏。
        // 两套形状合并（`journalEntryJson`）后假值没了，键如实变成条件性，
        // 于是浅更新也补上真实数据，两个出口的 `docs` 才是同一回事。
        //
        // ⚠️ 形状必须是**文件名数组**，与 deep.cj 一致。
        // 这里一度写成 `{file, changed, created}` 对象数组 ——
        // 而 deep.cj 发的是字符串数组：同一个键、两套形状，
        // 正是本引擎反复栽的那族（journal 的 9 键 vs 17 键就是同一件事）。
        // per-file 的 changed/created 明细不该在这里另开一份：
        // 它已经在 `update --json` / `deep --json` 的结果 envelope 里
        // （那里本来就是结构化的），在 journal 里再造第三种形状只会让
        // 两处漂移。要细则去看结果，不要看日志。
        //
        // 位置很讲究：必须在 `writeProgress` **之前**。
        // entry 对象是同一个引用，同时存在于 progress 与稍后的 journal，
        // 放在 writeProgress 之后会造成「进度库没有、journal 有」的新不一致。
        if (!opts.skipDocs) {
            let docsOut = ArrayList<JsonValue>()
            for ((file, _, _, _, _) in docChanges) {
                docsOut.add(Json.of(file))
            }
            Json.set(entry, "docs", JArr(docsOut))
        }

        if (!opts.dryRun) {
            writeProgress(project.id, progress)
            // ⚠️ 没记到新东西时不追加 journal 条目。
            //
            // journal 是「进度日志」——「这次记下了什么」。
            // 而「什么时候跑过」由 state.lastUpdateAt / runCount 负责，
            // 两者不必混在一处。
            //
            // 原实现无条件 append，于是 post-commit 钩子每提交一次就多一行，
            // 而那行和上一行逐字节相同（除了 at / id）：实测 3 个提交的仓库
            // 连跑三次 update，journal 里三条 commitCount 全是 3 的记录，
            // `status` 的「最近进度」连着几行一模一样的内容。
            // 后果不只是噪音 —— 任何从 journal 统计「这个项目一共做了多少事」
            // 的调用方都会被灌进几倍虚高。
            //
            // 判据：新提交为 0 且文档一个都没改动。
            // 文档有改动不算 no-op —— 那轮确实产出了用户看得见的变化。
            var anyDocChanged = false
            for ((_, changed, _, _, _) in docChanges) {
                if (changed) {
                    anyDocChanged = true
                }
            }
            let recordedSomething = newCommits > 0 || anyDocChanged
            if (recordedSomething) {
                appendJournal(project.id, entry, project.name)
            }
            var state = readState(project.id)
            Json.set(state, "lastUpdateAt", Json.of(startedAt))
            if (opts.mode == "track") {
                Json.set(state, "lastTrackAt", Json.of(startedAt))
            }
            Json.set(state, "runCount", Json.of(Json.intAt(state, "runCount", 0) + 1))
            // 记下「上一次真正记到东西是什么时候」，让 no-op 轮次可被审计
            if (recordedSomething) {
                Json.set(state, "lastRecordedAt", Json.of(startedAt))
            }
            writeState(project.id, state)
            for ((file, _, _, _, _) in docChanges) {
                pruneBackups("${store.backups}/${file.replace("/", "_")}", config.backupKeep)
            }
        }

        // ⚠️ 必须在**进度库写完之后**才报，而且要报成非零退出。
        //
        // 早先是在写循环里就地抛，于是 store 一次都没写：
        //   README 声称「追踪 N 个分支」，store 里 branches=0、journal=0
        // 文档与事实源互相矛盾，且下次会把同一批提交再数一遍。
        //
        // 现在 store 一定写成功，所以这份进度**是**记下了的；
        // 没写成的是那几个文档，必须点名说是哪几个 —— 「笼统说失败」
        // 会让用户以为整轮白跑了，进而重跑一次把文档重复刷新。
        if (!docErrors.isEmpty()) {
            throw DgError(
                "DOC_WRITE_FAILED",
                "进度已记录到 ${project.id}，但以下文档未能更新（它们的内容仍是上一轮的）：\n  - " +
                    joinStrings(docErrors, "\n  - "),
                1,
                Some(project.name),
            )
        }

        return UpdateResult(
            true, opts.mode, project.id, project.name, provider,
            branchCount, newCommits, repoBranchCount, docChanges, entry, facts, startedAt,
        )
    })
}

/// 快速进度快照：只更新 store，不动文档，不用 AI
public func runTrack(project: ProjectEntry, config: Config, source: String): UpdateResult {
    let opts = UpdateOptions()
    opts.mode = "track"
    opts.skipDocs = true
    opts.source = source
    return runUpdate(project, config, opts)
}

/// 分支基线：把「哪些分支、各自 head 到哪、摘要是什么」写进 progress。
///
/// runUpdate 与 runDeep 都要做这件事，但以前只有 runUpdate 做：
/// runDeep 的 journal 条目写着 commitCount=N，看起来像「已记录 N 个提交」，
/// 却从不写 progress.branches —— 于是只跑过 deep 的项目，
///   status.branches = []、overall = null、headline = 「暂无新变化」，
/// 而 journal 同时声称记了 2 个提交。引擎自相矛盾，且下次 update 会把
/// 同一批提交当成全新的再数一遍。注释里那句「deep 隐含 shallow」从来没兑现。
///
/// 收敛到这一个函数：两条路径共用同一套 delta / 叙述 / 基线逻辑，
/// 以后谁再新增一条写路径也不会漏掉这一步。
public class BaselineResult {
    public let deltas: ArrayList<BranchDelta>
    public let narratives: HashMap<String, BranchNarrative>
    public let branchCount: Int64
    /// 各分支本轮**列出来**的提交数之和。⚠️ 它的口径随分支状态变：
    /// 无新提交时 branchDelta 重放整份基线，有真增量时只装增量。
    /// 所以它只用于推导 commitsTruncated，**不能**拿去当「本轮记录了几个」。
    public let totalCommits: Int64
    /// 本轮真正新记录的提交数。journal 的 commitCount 与 CLI 文案必须用它。
    public let newCommits: Int64
    public let commitsTruncated: Bool
    public let overall: JsonValue
    /// 仓库真实分支数（见 repoBranchTotal）。与 branchCount 并排出门，
    /// 才分得清「追踪了 7 个」和「仓库有 7 个分支」。
    public let repoBranchCount: Option<Int64>

    public init(
        deltas: ArrayList<BranchDelta>,
        narratives: HashMap<String, BranchNarrative>,
        branchCount: Int64,
        totalCommits: Int64,
        commitsTruncated: Bool,
        overall: JsonValue,
        newCommits!: Int64 = 0,
        repoBranchCount!: Option<Int64> = None,
    ) {
        this.deltas = deltas
        this.narratives = narratives
        this.branchCount = branchCount
        this.totalCommits = totalCommits
        this.newCommits = newCommits
        this.commitsTruncated = commitsTruncated
        this.overall = overall
        this.repoBranchCount = repoBranchCount
    }
}

public func recordBranchBaseline(
    project: ProjectEntry,
    config: Config,
    facts: RepoFacts,
    progress: JsonValue,
    maxBranches: Int64,
): BaselineResult {
    let candidates = collectCandidateBranches(facts, progress, maxBranches)

    // 计算各分支增量
    let deltas = ArrayList<BranchDelta>()
    // 该分支**此前是否已有基线记录**。必须在写 progress 之前问，
    // 因为下面那个合并循环会就地把记录覆盖掉。
    //
    // 它是区分「本轮真正记录了新提交」和「只是重放了基线」的唯一依据：
    // branchDelta 在 from == head（无新提交）时会把 from 清空并从 HEAD 重列
    // 整份基线（见 progress.cj），于是 d.count() 每次都等于基线规模。
    // 直接拿它当「本轮记录了几个提交」，实测 3 个提交的仓库连跑三次 update
    // 每次都报「3 个提交」，journal 里三条记录 commitCount 全是 3 ——
    // 隐含「记了 9 个提交」，而实际只有 3 个。
    let hadPriorBaseline = HashSet<String>()
    for (branch in candidates) {
        var tracked = ""
        match (progressBranch(progress, branch)) {
            case Some(rec) =>
                tracked = Json.strAt(rec, "head", "")
                hadPriorBaseline.add(branch)
            case None => ()
        }
        match (branchDelta(project.path, branch, tracked, 200, 200)) {
            case Some(d) => deltas.add(d)
            case None => ()
        }
    }

    // 叙述生成：规则引擎（确定性）。引擎是 AI 无关的——
    // LLM 增强由上层 AI 实现（deepDolphin.app）基于 /api/context 自行完成。
    var narratives = HashMap<String, BranchNarrative>()
    let provider = "rules"
    for (d in deltas) {
        narratives[d.branch] = rulesBranchNarrative(d, facts, config.language)
    }

    // 合并到进度存储
    var branchCount: Int64 = 0
    var totalCommits: Int64 = 0
    var newCommits: Int64 = 0
    var commitsTruncated = false
    for (d in deltas) {
        let headDate = if (d.commits.size > 0) { d.commits[0].date } else { facts.lastCommitAt }

        // ⚠️ aheadOfDefault 必须是「相对**默认分支**」的领先数。
        //
        // 原来直接取 BranchInfo.ahead，而那个字段来自
        // `git for-each-ref --format='%(upstream:track)'` —— 量的是
        // 「本分支比它的**远端跟踪分支**多几个提交」。两个后果：
        //   本地仓库没有 remote → track 为空 → ahead 恒为 0
        //     「领先默认分支 N 个提交」「+N」永远不出现，可合并分支一个都识别不出
        //   有 remote → 报的是「比 origin/xxx 多几个」
        //     实测（feature-x 领先 main 4 个、比 origin/feature-x 多 1 个），
        //     引擎在**同一份 status 响应里**同时给出：
        //         branches[0].aheadOfDefault = 1     ← 装的是 upstream 差
        //         mergeHint.ahead            = 4     ← 同一件事，planMerge 算对了
        //     字段名和内容对不上，且与自己矛盾。
        //
        // 正确来源是 aheadBehind（planMerge 用的同一个函数）：
        // `rev-list --left-right --count default...branch` 的右半边。
        // 分支已删除 / rev-parse 失败时 aheadBehind 安全返回 (0, 0)。
        var aheadOfDefault: Int64 = 0
        if (d.branch != facts.defaultBranch && !facts.defaultBranch.isEmpty()) {
            aheadOfDefault = aheadBehind(project.path, facts.defaultBranch, d.branch)[1]
        }

        // merged 原来带一个 detail.ahead == 0 的前置条件，用的是同一个错字段。
        // 后果：分支「已合入默认分支、但比自己的 upstream 新」时会被判成未合入
        //（upstream 差 > 0 直接短路，isMergedBranch 根本不跑）。
        // 合入与否由 git 的祖先关系说了算，不该再叠加一个无关条件。
        let merged = !facts.defaultBranch.isEmpty() && d.branch != facts.defaultBranch &&
                     isMergedBranch(project.path, facts.defaultBranch, d.branch)
        let status = computeBranchStatus(headDate, merged)
        let patch = Json.obj()
        Json.set(patch, "head", Json.of(d.head))
        Json.set(patch, "headDate", Json.of(headDate))
        Json.set(patch, "headSubject", Json.of(if (d.commits.size > 0) { d.commits[0].subject } else { "" }))
        Json.set(patch, "status", Json.of(status))
        Json.set(patch, "provider", Json.of(provider))
        Json.set(patch, "aheadOfDefault", Json.of(aheadOfDefault))
        Json.set(patch, "merged", Json.of(merged))
        Json.set(patch, "pendingCommits", Json.of(0))
        Json.set(patch, "lastRecordedCount", Json.of(d.count()))
        // 历史被改写（rebase / force-push / 强制回退）时，原基线不再可计算。
        // 以前这个信号只活在 BranchDelta 里、没有任何出口，引擎一边重建基线
        // 一边当无事发生 —— 用户分不清「我新推了 4 个提交」和
        // 「你 3 条已记录提交被踢出基线」。
        Json.set(patch, "baselineReset", Json.of(d.reset))
        match (narratives.get(d.branch)) {
            case Some(n) =>
                Json.set(patch, "summary", Json.of(n.summary))
                let hl = ArrayList<JsonValue>()
                for (h in n.highlights) {
                    hl.add(Json.of(h))
                }
                Json.set(patch, "highlights", JArr(hl))
                let ns = ArrayList<JsonValue>()
                for (h in n.nextSteps) {
                    ns.add(Json.of(h))
                }
                Json.set(patch, "nextSteps", JArr(ns))
            case None => ()
        }
        setProgressBranch(progress, d.branch, patch)
        branchCount += 1
        totalCommits += d.count()
        // 本轮**真正新记录**的提交数（口径说明见上面 newCommits 的注释）。journal 的 commitCount 与 CLI 的
        // 「N 个提交」说的是「本次记下了几个提交」，那就必须是 newCommits，
        // 不能用 totalCommits —— 后者的口径随分支状态变（见字段注释）。
        //
        // 两种情况算 0：
        //   d.from 非空 → 有真增量，count() 就是新增数
        //   d.from 为空 → 此前已有基线且 head 没动（或者历史被改写），
        //                branchDelta 重放了整份基线，一个新的也没记
        // 此前**没有**基线（首轮建档）时 from 也为空，但那时 count() 全是新记的，
        // 所以必须同时看 hadPriorBaseline —— 少了它首轮就会报「0 个提交」。
        if (d.from.isEmpty() && hadPriorBaseline.contains(d.branch)) {
            // 不新增
        } else {
            newCommits += d.count()
        }
        if (d.truncated) {
            commitsTruncated = true
        }
    }

    // 已追踪但本轮无变化的分支：更新待记录计数
    for ((name, rec) in progressBranches(progress)) {
        var inDeltas = false
        for (d in deltas) {
            if (d.branch == name) {
                inDeltas = true
            }
        }
        if (!inDeltas) {
            let head = Json.strAt(rec, "head", "")
            // 基准必须是**这个分支自己**，不是 HEAD（当前分支）。
            // 原来写 `${head}..HEAD`：对当前分支之外的任何分支，量到的都是
            // 「当前分支相对该分支多出几个提交」，与该分支本身毫无关系。
            // 实测删掉 feature-x 后在 main 上提交 3 次：
            // feature-x 报出 pendingCommits=3 —— 那 3 个提交属于 main。
            // 分支已删除时 rev-parse 失败，计数自然是 0，正好。
            let pending = if (head.isEmpty()) { 0 } else { commitCount(project.path, "${head}..${name}") }
            Json.set(rec, "pendingCommits", Json.of(if (pending > 500) { 0 } else { pending }))
        }
    }

    // 项目级备注
    let notesArr = ArrayList<String>()
    match (narratives.get("__overall__")) {
        case Some(n) =>
            for (h in n.highlights) {
                notesArr.add(h)
            }
        case None => ()
    }
    for (n in rulesOverallNotes(facts, config.language)) {
        notesArr.add(n)
    }
    let overall = Json.obj()
    let summaryParts = ArrayList<String>()
    var sc: Int64 = 0
    for (d in deltas) {
        match (narratives.get(d.branch)) {
            case Some(n) =>
                if (n.summary.size > 0 && sc < 3) {
                    summaryParts.add(n.summary)
                    sc += 1
                }
            case None => ()
        }
    }
    Json.set(overall, "summary", Json.of(joinStrings(summaryParts, "；")))
    let notesJson = ArrayList<JsonValue>()
    var nc: Int64 = 0
    for (n in notesArr) {
        if (nc >= 6) {
            break
        }
        notesJson.add(Json.of(n))
        nc += 1
    }
    Json.set(overall, "notes", JArr(notesJson))
    Json.set(progress, "overall", overall)
    // 分支数分母：branchCount 只是「这轮建立了基线的分支数」，
    // 候选集被 maxShallowBranches 限着。仓库真实分支数必须一起出去，
    // 否则 update 的「N 个分支」会被读成「仓库就 N 个分支」
    // （实测 16 个分支的仓库报 7 个）。
    return BaselineResult(
        deltas, narratives, branchCount, totalCommits, commitsTruncated, overall,
        newCommits: newCommits,
        repoBranchCount: repoBranchTotal(facts),
    )
}

/// `docs` 的合法取值。`""` 是「未指定」，与 `"all"` 同义。
///
/// ⚠️ 为什么要在这里校验，而不是只让 cmdUpdate 校验：
/// newDocTargets 用的是 `docs == "readme"` / `docs == "agent"` 的**排除法**，
/// 于是**任何认不出来的值都等同于默认档** —— README 与所有已存在的
/// AGENTS/CLAUDE 一起被注入托管区。
///
/// 也就是说 `--docs` 一旦拼错（"rdame" / "Readme" / "readme "），
/// 后果不是「少做一点」，而是**静默升级成范围最大的那次**：
/// 实测 `--docs readme` 只动 README.md，拼成 `rdame` 之后
/// 用户的 AGENTS.md 和 CLAUDE.md 也都被改了 —— 两个用户根本没点名的文件，
/// 而且改的是 agent 指令文件。
///
/// 这与 validateDeepScope（--scope）是同一个结构性缺陷，
/// 已在 deep 侧收敛过一次；update 侧此前**一次都没校验过**。
/// 同样收敛到 runUpdate 入口，任何未来的调用面都躲不掉。
public let UPDATE_DOCS: Array<String> = ["", "all", "readme", "agent"]

public func validateUpdateDocs(docs: String): Unit {
    for (d in UPDATE_DOCS) {
        if (d == docs) {
            return
        }
    }
    throw DgError.usage("docs 只能是 all | readme | agent，收到：${docs}")
}

func newDocTargets(config: Config, docs: String, facts: RepoFacts): ArrayList<(String, Bool)> {
    let out = ArrayList<(String, Bool)>()
    if (docs == "readme") {
        out.add(("README.md", true))
        return out
    }
    if (docs == "agent") {
        for (f in config.agentDocCandidates) {
            if (isDocPresent(facts, f)) {
                out.add((f, false))
            }
        }
        return out
    }
    // "" / "all"：README 总是更新 —— 没有就新建一个，托管区域需要有地方写进度记录；
    // agent 文档则只在已存在时更新。
    //
    // 原实现在这里算完 hasReadme 之后写了两个**完全相同**的分支，行为上等价于
    // 无条件添加。这不是 bug：testUpdateWritesPulseIntoReadme 明确要求
    // 「无 README 的仓库跑一次 update 会生成 README 并写入脉搏」。
    // 保留行为、去掉会误导后来者的死分支。
    out.add(("README.md", true))
    for (f in config.agentDocCandidates) {
        if (isDocPresent(facts, f)) {
            out.add((f, false))
        }
    }
    return out
}

func isDocPresent(facts: RepoFacts, file: String): Bool {
    for (d in facts.docsPresent) {
        if (d == file) {
            return true
        }
    }
    return false
}

func isMergedBranch(root: String, defaultBranch: String, branch: String): Bool {
    if (defaultBranch.isEmpty() || defaultBranch == branch) {
        return false
    }
    match (revParse(root, branch)) {
        case Some(head) => return isAncestor(root, head, defaultBranch)
        case None => return false
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testRunUpdateOnRealRepoWithRulesEngine(): Unit {
    let base = "/tmp/deepgit-upd-${nowMillis()}"
    // 隔离数据目录。必须放在仓库之外：若置于 base 内部，engine 的 store/ 目录
    // 会让 git 工作区变脏，runDeep 第二次执行就不再幂等（下方的 !anyChanged 断言会红）。
    // 不隔离则 runUpdate/runTrack/runDeep 内部按 projectId 推导出的 store 路径会落到
    // 用户真实的 ~/.deepgit/store，测试失败或被中断时还会留下孤儿目录。
    let testHome = base + "-home"   // 仓库的兄弟目录：唯一，且不在 git 工作区内
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/README.md", "# my proj\n\n用户手写内容\n")
    writeFileAtomic(base + "/main.cj", "package x")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: initial commit"], false)

    // 直接用路径构造 entry（项目注册表在 CLI 层负责）
    let pid = projectIdFor(base)
    let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)

    let config = Config.defaults()
    let opts = UpdateOptions()
    opts.mode = "shallow"
    let result = runUpdate(project, config, opts)

    @Assert(result.ok)
    @Assert(result.branchCount >= 1)
    @Assert(result.commitCount >= 1)
    // README 被写入托管区域，且用户内容保留
    let readme = readFileTextOr(base + "/README.md", "")
    @Assert(readme.contains("用户手写内容"))
    @Assert(readme.contains("deepgit:begin progress"))
    // 进度已落库
    let progress = readProgress(pid)
    @Assert(progressBranch(progress, "main").isSome())
    // 日志已写入
    let journal = readJournal(pid, 10)
    @Assert(journal.size >= 1)

    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
    // 复位必须排在所有 deepgitPath(...) 之后：提前复位会让上面的清理打到真实 store
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testRunTrackSkipsDocs(): Unit {
    let base = "/tmp/deepgit-track-${nowMillis()}"
    // 隔离数据目录。必须放在仓库之外：若置于 base 内部，engine 的 store/ 目录
    // 会让 git 工作区变脏，runDeep 第二次执行就不再幂等（下方的 !anyChanged 断言会红）。
    // 不隔离则 runUpdate/runTrack/runDeep 内部按 projectId 推导出的 store 路径会落到
    // 用户真实的 ~/.deepgit/store，测试失败或被中断时还会留下孤儿目录。
    let testHome = base + "-home"   // 仓库的兄弟目录：唯一，且不在 git 工作区内
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/README.md", "# x\n")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)
    let pid = projectIdFor(base)
    let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)
    let before = readFileTextOr(base + "/README.md", "")
    let result = runTrack(project, Config.defaults(), "test")
    let after = readFileTextOr(base + "/README.md", "")
    @Assert(result.ok)
    @Assert(before == after)  // 文档未被触碰
    @Assert(progressBranch(readProgress(pid), "main").isSome())
    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
    // 复位必须排在所有 deepgitPath(...) 之后：提前复位会让上面的清理打到真实 store
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testRunUpdateDryRunDoesNotWrite(): Unit {
    let base = "/tmp/deepgit-dry-${nowMillis()}"
    // 隔离数据目录。必须放在仓库之外：若置于 base 内部，engine 的 store/ 目录
    // 会让 git 工作区变脏，runDeep 第二次执行就不再幂等（下方的 !anyChanged 断言会红）。
    // 不隔离则 runUpdate/runTrack/runDeep 内部按 projectId 推导出的 store 路径会落到
    // 用户真实的 ~/.deepgit/store，测试失败或被中断时还会留下孤儿目录。
    let testHome = base + "-home"   // 仓库的兄弟目录：唯一，且不在 git 工作区内
    ensureDir(testHome)
    enterTestHome(testHome)
    // ⚠️ 必须 try/finally：原来清理写在**断言之后**且没有 finally，
    // 于是这条测试一失败，`/tmp/deepgit-dry-*` 与它的 `-home` 就永久留下 ——
    // 而负控（NC63-c，注入一条假备份路径让它红）每次都会漏一份。
    //
    // #186 的 `testEveryTestSandboxIsRemovedInTheSameTest` 抓不到这个：
    // 它是**静态**检查，只验「removePathIfExists 的调用存在」，
    // 验不了它在**失败路径**上会不会跑到。
    // 静态守卫能守住「写了没有」，守不住「跑到没跑到」——
    // 后者只有 try/finally 能保证。
    // ⚠️ pid 必须声明在 try **外面**：finally 要用它算 store 路径，
    // 声明在 try 里的话失败路径上直接编译不过（undeclared identifier）。
    let pid = projectIdFor(base)
    try {
        ensureDir(base)
        gitRun(base, ["init", "-b", "main"], false)
        writeFileAtomic(base + "/README.md", "# x\n")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)
        let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)
        let opts = UpdateOptions()
        opts.dryRun = true
        let result = runUpdate(project, Config.defaults(), opts)
        @Assert(result.ok)
        let after = readFileTextOr(base + "/README.md", "")
        @Assert(!after.contains("deepgit:begin"))  // 未写入
        @Assert(result.docChanges.size > 0)
        // ⚠️ dry-run **没有备份**：它压根没写文件，备份位必须是空串。
        // 报一个不存在的备份路径比不报更坏 —— 用户会去找那个文件。
        for ((_, _, _, _, backup) in result.docChanges) {
            @Assert(backup.isEmpty())
        }
    } finally {
        removePathIfExists(base)
        removePathIfExists(deepgitPath(["store", pid]))
        // 复位必须排在所有 deepgitPath(...) 之后：提前复位会让上面的清理打到真实 store
        exitTestHome()
        removePathIfExists(testHome)
    }
}

/// 改了用户的文档就必须说备份在哪（缺陷 #210）。
///
/// 原来 `docChanges` 的第 4 位是 dry-run 的预览文本，而 `ApplyResult.backup`
/// （真正的备份路径）在调用点被**直接丢掉** —— 引擎每轮都留一份备份、
/// 按 `update.backupKeep` 裁剪，而用户从不知道它存在：
///  · 想回滚时无从下手；
///  · 旧版本被静默删掉时也没有任何提示。
/// 三种形状必须分开，合成一句话就会撒谎：
///   · 新建（本来就没有旧版本）⇒ **没有备份**，不许编一个
///   · 改动既有文档             ⇒ 必须是**真实路径**，且落在 backups 目录下
///   · dry-run                  ⇒ 没写文件 ⇒ 没有备份
@Test
func testDocumentBackupPathIsReportedNotDropped(): Unit {
    let base = "/tmp/deepgit-bkpath-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let pid = projectIdFor(base)
    try {
        ensureDir(base)
        gitRun(base, ["init", "-b", "main"], false)
        // ⚠️ 故意**不**预先建 README.md：第 1 次要拿到的是「新建」那一档。
        // 照抄上面 dry-run 测试的搭法（先写个 README.md）会让第 1 次变成「改动」，
        // 于是 createdSeen 永远不成立 —— 前提错了，后面整组断言都在空转。
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "init"], false)
        let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)

        // 第 1 次：文档被**新建** ⇒ 没有旧版本可备份
        let r1 = runUpdate(project, Config.defaults(), UpdateOptions())
        @Assert(r1.ok)
        @Assert(r1.docChanges.size > 0)
        var createdSeen = false
        for ((_, changed, created, _, backup) in r1.docChanges) {
            if (created) {
                createdSeen = true
                @Assert(changed)
                // 凭空编一个备份路径 = 谎报
                @Assert(backup.isEmpty())
            }
        }
        @Assert(createdSeen)

        // 加一个提交，让托管区内容真的变
        writeFileAtomic(base + "/b.txt", "b\n")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: more"], false)

        // 第 2 次：改动既有文档 ⇒ 必须带真实备份路径
        let r2 = runUpdate(project, Config.defaults(), UpdateOptions())
        @Assert(r2.ok)
        var realBackup = ""
        for ((file, changed, created, _, backup) in r2.docChanges) {
            if (changed && !created) {
                @Assert(file.contains(".md"))
                realBackup = backup
            }
        }
        @Assert(!realBackup.isEmpty())
        // 路径必须是真的：落在 store 的 backups 目录里，且文件确实存在
        @Assert(realBackup.contains("/backups/"))
        @Assert(fileExists(realBackup))
        // 备份的内容必须是**改动前**的那一版：含旧特征、不含新提交
        let old = readFileTextOr(realBackup, "")
        @Assert(old.contains("deepgit:begin"))
        @Assert(old.contains("more") == false)   // 新提交不该出现在旧版本里
    } finally {
        exitTestHome()
        removePathIfExists(base)
        removePathIfExists(deepgitPath(["store", pid]))
        removePathIfExists(testHome)
    }
}

@Test
func testBaselineCommitCapIsDisclosedNotSilentlyCapped(): Unit {
    // 首次建立基线时每个分支只记最近 30 个提交，runUpdate 把这些样本加总
    // 当作「本项目记录了多少提交」报出来，没有任何截断标记。
    // 叙述文案写「最近 30 个提交」是诚实的，但**聚合数字**不是 ——
    // 同一个项目先 update 后 deep，用户会看到提交数从 30 跳到 100，
    // 像数据丢了。这是「上限当全量」这一族的第七处。
    let base = "/tmp/dg_baseline_${nowMillis()}"
    let testHome = "${base}/home"
    enterTestHome(testHome)
    ensureDir(testHome)
    ensureDir(base)
    let repo = "${base}/big"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic("${repo}/a.txt", "x")
    gitRun(repo, ["add", "."], false)
    for (i in 0..100) {
        gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "feat: c${i}"], false)
    }
    let (e, _) = addProject(repo, "big", ArrayList<String>(), base)
    let r = runUpdate(e, Config.defaults(), UpdateOptions())
    @Assert(r.ok)
    @Assert(r.commitCount == 30)                              // 只记了 30 条
    @Assert(Json.boolAt(r.journalEntry, "commitCountTruncated", false))
    // 真实提交数是 100，与报出的 30 不等 —— 靠这个字段说清楚
    @Assert(r.facts.commitCount == 100)

    // 对照组：恰好等于上限的仓库不能被误标成截断
    let repo2 = "${base}/exact"
    ensureDir(repo2)
    gitRun(repo2, ["init", "-b", "main"], false)
    writeFileAtomic("${repo2}/a.txt", "x")
    gitRun(repo2, ["add", "."], false)
    for (i in 0..30) {
        gitRun(repo2, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "feat: c${i}"], false)
    }
    let (e2, _) = addProject(repo2, "exact", ArrayList<String>(), base)
    let r2 = runUpdate(e2, Config.defaults(), UpdateOptions())
    @Assert(r2.ok)
    @Assert(r2.commitCount == 30)
    @Assert(!Json.boolAt(r2.journalEntry, "commitCountTruncated", true))

    removePathIfExists(base)
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testUpdatePrechecksAllDocTargetsBeforeWritingAny(): Unit {
    // 回归：多目标文档写入没有回滚。
    //
    // 旧实现是「边遍历边写」：README 写成功后才轮到 AGENTS.md，
    // 而 AGENTS.md 的托管标记被用户改坏（end 标记没了）→ 抛错退出。
    // 结果是半成品：
    //   README 托管区  已经写成「本次记录 2 个提交」
    //   store journal / progress  一字未动
    // README 声称记下了，引擎其实没记 —— 下次 update 会把同一批提交再数一遍。
    //
    // 修法：写任何文件之前先用 previewRegions 把**全部**目标预检一遍
    // （previewRegions 与 applyRegions 共用 assertRegionsWritable，
    //   所以「预检通过」等价于「真写不会抛」）。
    let base = "/tmp/deepgit-atomic-${nowMillis()}"
    let testHome = base + "-home"   // 仓库的兄弟目录：唯一，且不在 git 工作区内
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/README.md", "# p\n\nREADME 用户内容\n")
    writeFileAtomic(base + "/AGENTS.md", "# AGENTS\n\n团队规范。\n")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)

    let (project, _) = addProject(base, "atomic", ArrayList<String>(), testHome)
    let config = Config.defaults()
    // 第一次：两份文档都是普通内容，引擎正常托管它们
    let first = runUpdate(project, config, UpdateOptions())
    @Assert(first.ok)
    let agentsDoc = readFileTextOr(base + "/AGENTS.md", "")
    @Assert(agentsDoc.contains("deepgit:end progress"))

    // 模拟用户（或某个脚本）把 AGENTS.md 的 end 标记删掉
    let broken = agentsDoc.replace("<!-- deepgit:end progress -->", "")
    @Assert(broken != agentsDoc)
    writeFileAtomic(base + "/AGENTS.md", broken)

    // 再加两个提交：本次 update 本该记录它们
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "feat: c3"], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "feat: c4"], false)

    // 关键快照：README 在本次运行前的内容，以及 store 里已有的记录条数
    let readmeBefore = readFileTextOr(base + "/README.md", "")
    let pid = projectIdFor(base)
    let journalCountBefore = readJournal(pid, 500).size
    let progressEntriesBefore = Json.arrAt(readProgress(pid), "entries").size

    // 本次运行必须失败（AGENTS.md 结构异常）
    var threw = false
    try {
        _ = runUpdate(project, config, UpdateOptions())
    } catch (e: DgError) {
        threw = true
        @Assert(e.code == "DOC_REGION_MALFORMED")
        @Assert(e.exitCode == 1)
    }
    @Assert(threw)

    // ⚠️ 核心断言：README 一个字节都不能动。
    // 旧实现下这里必然失败 —— README 已经被写成新内容了。
    let readmeAfter = readFileTextOr(base + "/README.md", "")
    @Assert(readmeAfter == readmeBefore)
    // ⚠️ 断言必须用**渲染后的完整高亮行**（全角引号），不能写 contains("c4")。
    // git 短 SHA 是十六进制，偶然会出现 c4 这两个字符，
    // 于是这条断言随机红过一次（readmeAfter == readmeBefore 和 c3 那条都过了，
    // 只有 c4 挂了 —— README 根本没变，是断言选错了字符串）。
    // 全角引号不可能出现在 hex sha 里，碰撞被彻底排除。
    @Assert(!readmeAfter.contains("新增：“c3”"))
    @Assert(!readmeAfter.contains("新增：“c4”"))

    // store 也不能留下半截记录：失败的运行等于没跑过
    @Assert(readJournal(pid, 500).size == journalCountBefore)
    @Assert(Json.arrAt(readProgress(pid), "entries").size == progressEntriesBefore)

    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
    // 复位必须排在所有 deepgitPath(...) 之后：提前复位会让上面的清理打到真实 store
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testAheadOfDefaultIsRelativeToDefaultNotUpstream(): Unit {
    // 回归：aheadOfDefault 装的是「比远端跟踪分支多几个提交」。
    //
    // BranchInfo.ahead 来自 for-each-ref 的 %(upstream:track)，
    // recordBranchBaseline 却把它直接标成 aheadOfDefault。后果：
    //   本地无 remote → track 为空 → 恒为 0
    //     「领先默认分支 N」「+N」永不出现，可合并分支一个都识别不出
    //   有 remote → 报的是 upstream 差
    //     引擎在**同一份 status 里**同时给出
    //       branches[0].aheadOfDefault = 1   （upstream 差）
    //       mergeHint.ahead            = 4   （同一件事，planMerge 算对了）
    let base = "/tmp/deepgit-ahead-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let remote = base + "-remote.git"
    ensureDir(base)
    // ⚠️ gitRun 的第三个参数是 tolerate（**容忍失败**），不是 mustSucceed。
    // 目录不存在时 `git -C <dir> init --bare` 进不去会失败，
    // 而 tolerate=true 会把失败静默吞掉 —— 裸库根本没建起来，
    // 后面的 push 也一起失败，于是「有 remote」这段前提整段没被跑到。
    // 这不是假设：本轮两个新测试最初都栽在这里，第一个还因此假绿过。
    ensureDir(remote)
    gitRun(remote, ["init", "-q", "--bare"], false)
    gitRun(base, ["init", "-b", "main"], false)
    gitRun(base, ["config", "user.name", "t"], false)
    gitRun(base, ["config", "user.email", "t@t"], false)
    gitRun(base, ["remote", "add", "origin", remote], false)
    writeFileAtomic(base + "/a.txt", "a")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["commit", "-m", "feat: init"], false)
    gitRun(base, ["push", "-q", "-u", "origin", "main"], false)

    // feature-x：先推 1 个，再本地加 3 个 → 领先 main 4 个，比 origin/feature-x 多 3 个
    gitRun(base, ["checkout", "-q", "-b", "feature-x"], false)
    writeFileAtomic(base + "/b.txt", "b")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["commit", "-m", "feat: b1"], false)
    gitRun(base, ["push", "-q", "-u", "origin", "feature-x"], false)
    for (n in 2..5) {
        writeFileAtomic(base + "/f${n}.txt", "f${n}")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["commit", "-m", "feat: b${n}"], false)
    }

    let (project, _) = addProject(base, "ahead", ArrayList<String>(), testHome)
    let r = runUpdate(project, Config.defaults(), UpdateOptions())
    @Assert(r.ok)

    let st = projectStatus(project, Config.defaults(), 5)
    // 4 个提交领先默认分支 —— 不是 3（upstream 差），也不是 0
    @Assert(aheadOfBranch(st, "feature-x") == 4)
    @Assert(aheadOfBranch(st, "main") == 0)

    // 与 mergeHint 必须是同一个数：同一件事不能有两个答案
    match (Json.getOr(st, "mergeHint")) {
        case JObj(_) => @Assert(Json.intAt(Json.getOr(st, "mergeHint"), "ahead", -1) == aheadOfBranch(st, "feature-x"))
        case _ => ()
    }

    removePathIfExists(base)
    removePathIfExists(remote)
    removePathIfExists(deepgitPath(["store", project.id]))
    // 复位必须排在所有 deepgitPath(...) 之后：提前复位会让上面的清理打到真实 store
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testMergedBranchIsNotFalsifiedByBeingAheadOfUpstream(): Unit {
    // 回归：merged 判据里带了个 detail.ahead == 0 的前置条件，用的是 upstream 差。
    // 分支「已合入默认分支、但比自己的 origin/xxx 新」时，
    // ahead=1 直接短路，isMergedBranch 根本不跑 → 明明已合入却报「未合入」。
    let base = "/tmp/deepgit-merged-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let remote = base + "-remote.git"
    ensureDir(base)
    // 见上一个测试的注释：tolerate=true 会把 git -C 失败静默吞掉
    ensureDir(remote)
    gitRun(remote, ["init", "-q", "--bare"], false)
    gitRun(base, ["init", "-b", "main"], false)
    gitRun(base, ["config", "user.name", "t"], false)
    gitRun(base, ["config", "user.email", "t@t"], false)
    gitRun(base, ["remote", "add", "origin", remote], false)
    writeFileAtomic(base + "/a.txt", "a")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["commit", "-m", "feat: init"], false)
    gitRun(base, ["push", "-q", "-u", "origin", "main"], false)
    gitRun(base, ["checkout", "-q", "-b", "feature-x"], false)
    writeFileAtomic(base + "/b.txt", "b")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["commit", "-m", "feat: b1"], false)
    gitRun(base, ["push", "-q", "-u", "origin", "feature-x"], false)   // 此刻 upstream 与本地齐平
    writeFileAtomic(base + "/c.txt", "c")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["commit", "-m", "feat: b2"], false)                    // 比 upstream 新 1 个
    gitRun(base, ["checkout", "-q", "main"], false)
    gitRun(base, ["merge", "-q", "--no-ff", "feature-x", "-m", "merge: feature-x"], false)

    let (project, _) = addProject(base, "merged", ArrayList<String>(), testHome)
    // ⚠️ 前置条件必须先钉住，否则这个测试会**空转绿**：
    // 若 push 没能建立 origin/feature-x 跟踪引用，%(upstream:track) 为空、
    // BranchInfo.ahead = 0，`merged` 判据的旧写法也会算对，测试假绿。
    // 这不是假设：本轮第一次写完时它就是这么绿的（push 静默失败 → ahead=0）。
    let trackAhead = listBranches(base)
    var upstreamDelta = -1
    for (b in trackAhead) {
        if (b.name == "feature-x") {
            upstreamDelta = b.ahead
        }
    }
    @Assert(upstreamDelta == 1)   // feature-x 必须真的比 origin/feature-x 新 1 个

    let r = runUpdate(project, Config.defaults(), UpdateOptions())
    @Assert(r.ok)

    let st = projectStatus(project, Config.defaults(), 5)
    @Assert(isMergedBranchIn(st, "feature-x"))
    @Assert(branchStatusIn(st, "feature-x") == "merged")

    removePathIfExists(base)
    removePathIfExists(remote)
    removePathIfExists(deepgitPath(["store", project.id]))
    // 复位必须排在所有 deepgitPath(...) 之后：提前复位会让上面的清理打到真实 store
    exitTestHome()
    removePathIfExists(testHome)
}

func branchRecIn(st: JsonValue, name: String): JsonValue {
    for (b in Json.arrAt(st, "branches")) {
        if (Json.strAt(b, "name", "") == name) {
            return b
        }
    }
    return Json.obj()
}

func aheadOfBranch(st: JsonValue, name: String): Int64 {
    return Json.intAt(branchRecIn(st, name), "aheadOfDefault", -1)
}

func branchStatusIn(st: JsonValue, name: String): String {
    return Json.strAt(branchRecIn(st, name), "status", "")
}

func isMergedBranchIn(st: JsonValue, name: String): Bool {
    return Json.boolAt(branchRecIn(st, name), "merged", false)
}

@Test
func testBaselineResetIsDisclosedAfterHistoryRewrite(): Unit {
    // 回归：BranchDelta.reset 只有测试在读，没有任何出口。
    // rebase / force-push / 强制回退之后，引擎重建基线却当无事发生：
    // 用户无法区分「我新推了 4 个提交」和「你 3 条已记录提交被踢出基线」。
    //
    // 实测（修复前）：记录 5 个提交 → git reset --hard HEAD~3 → 再提交 2 个
    //   track 报「最近 4 个提交：新增×4」，grep「重置/改写/rebase/基线」零命中，
    //   status 的分支对象里没有 baselineReset，progress 记录里也没有。
    let base = "/tmp/deepgit-baselinereset-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    for (i in 1..6) {
        writeFileAtomic(base + "/f${i}.txt", "f${i}")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: c${i}"], false)
    }
    let (project, _) = addProject(base, "baseline", ArrayList<String>(), testHome)
    let first = runUpdate(project, Config.defaults(), UpdateOptions())
    @Assert(first.ok)

    // 对照组：普通追加提交不得误报
    writeFileAtomic(base + "/ok.txt", "ok")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: ok"], false)
    let normal = runUpdate(project, Config.defaults(), UpdateOptions())
    @Assert(normal.ok)
    // 注意 progress.branches 是**按分支名做键的对象**，baselineReset 在每条分支记录里，
    // 不在 branches 这一层 —— 查错层级只会拿到默认值。
    // 默认值必须取 false：字段「不存在」和「值为 false」在这条断言里都该通过。
    // 若默认取 true，字段缺失会被判成 true，负控会红在这条对照组上
    // 而不是红在真正要验的「改写后必须为 true」那条。
    match (progressBranch(readProgress(project.id), "main")) {
        case Some(rec) => @Assert(!Json.boolAt(rec, "baselineReset", false))
        case None => @Assert(false)
    }

    // 改写历史：丢掉 3 条已记录提交
    gitRun(base, ["reset", "-q", "--hard", "HEAD~3"], false)
    writeFileAtomic(base + "/new.txt", "new")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: new"], false)
    let after = runUpdate(project, Config.defaults(), UpdateOptions())
    @Assert(after.ok)

    // 1) 落库
    match (progressBranch(readProgress(project.id), "main")) {
        case Some(rec) => @Assert(Json.boolAt(rec, "baselineReset", false))
        case None => @Assert(false)
    }
    // 2) 对外字段（CLI / HTTP / MCP 共用）
    let st = projectStatus(project, Config.defaults(), 5)
    var found = false
    for (b in Json.arrAt(st, "branches")) {
        if (Json.strAt(b, "name", "") == "main") {
            found = true
            @Assert(Json.boolAt(b, "baselineReset", false))
            // 3) 叙述文案必须说出口
            @Assert(Json.strAt(b, "summary", "").contains("历史改写"))
        }
    }
    @Assert(found)

    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", project.id]))
    // 复位必须排在所有 deepgitPath(...) 之后：提前复位会让上面的清理打到真实 store
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testDocWriteFailureStillPersistsProgressToStore(): Unit {
    // 文档写失败**不得让 store 一起回滚**。
    //
    // 早先是在写循环里就地抛，于是：
    //   chflags uchg AGENTS.md → deep
    //   「✓ 已更新 README.md」→「✗ Operation not permitted」→ exit 1
    //   README 里写了「追踪 N 个分支」，而 store 里 branches=0、journal=0。
    // 文档声称的状态引擎并不持有，两边无法自洽，
    // 而且下次 update 还会把同一批提交再数一遍。
    //
    // 进度库是事实源、文档是派生视图：宁可让某个文档这一轮陈旧并明说，
    // 也不能造出互相矛盾的两份真相。
    let base = "/tmp/deepgit-docfail-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    var projId = ""
    // 空串表示「还没锁任何文件」，finally 据此决定要不要 nouchg
    var locked = ""
    try {
        let repo = base + "/repo"
        ensureDir(repo)
        gitRun(repo, ["init", "-b", "main"], false)
        writeFileAtomic(repo + "/README.md", "# g\n")
        writeFileAtomic(repo + "/AGENTS.md", "# a\n")
        writeFileAtomic(repo + "/a.py", "q\n")
        gitRun(repo, ["add", "."], false)
        gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: init"], false)
        let (p, _) = addProject(repo, "docfail", ArrayList<String>(), "")
        projId = p.id
        let cfg = Config.defaults()

        // 默认档（docs=""、skipDocs=false）会同时写 README.md 与已存在的 AGENTS.md，
        // 正是要制造「部分文档可写、部分不可写」的场景
        let ok = runUpdate(p, cfg, UpdateOptions())
        @Assert(ok.ok)

        // 第二次 update 之前必须**先有新提交**。
        //
        // 这一条是测试自身的前提，不是顺手写的：applyRegions 在内容没变时
        // 走 `if (!changed) 提前返回`，一个字节都不写，于是不可变位根本
        // 不会被触发 —— 首版测试就栽在这儿：只锁文件不再提交，
        // 第二轮「采集仓库事实」之后连「✓ 已更新 README.md」都没有，
        // code 自然是空串。不是修复无效，是场景没制造出写入。
        // 教训同族：applyRegions 的「无变化不写」是一条真实的短路行为，
        // 任何依赖「文档写失败」的测试都必须先证明自己要写。
        writeFileAtomic(repo + "/b.py", "s\n")
        gitRun(repo, ["add", "."], false)
        gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: two"], false)

        // 锁住 AGENTS.md（不可变位：权限位仍是 0644，查权限位抓不到）
        let agents = repo + "/AGENTS.md"
        let agentsAfterRound1 = readFileTextOr(agents, "")
        @Assert(agentsAfterRound1.contains("moonGit"))
        execCapture("chflags", ["uchg", agents], None, 8000)
        locked = agents

        // 核心：必须以 DOC_WRITE_FAILED 结束，**而不是**在写循环里就抛掉整轮
        var code = ""
        var msg = ""
        try {
            runUpdate(p, cfg, UpdateOptions())
        } catch (e: DgError) {
            code = e.code
            msg = e.message
        }
        @Assert(code == "DOC_WRITE_FAILED")
        // 错误信息必须点名是哪几个文档 —— 笼统说「失败」会让用户以为整轮白跑
        // 并且重跑一次；必须同时说清「进度已经记下了」，否则用户只能重跑，
        // 而重跑并不会让那批提交重新计数（基线已推进）。
        @Assert(msg.contains("AGENTS.md"))
        @Assert(msg.contains("进度已记录"))

        // 关键断言：store **必须**持有这次进度，不能是 0
        let st = readState(p.id)
        @Assert(Json.intAt(st, "runCount", 0) == 2)
        let prog = readProgress(p.id)
        @Assert(Json.arrAt(prog, "entries").size == 2)
        // 文档与 store 必须能对上：README 写了「追踪 N 个分支」，
        // store 里就不能是「从未更新」
        @Assert(readFileTextOr(repo + "/README.md", "").contains("分支"))
        // 反向也成立：没写成的那个文档必须**逐字节保持上一轮的内容**，
        // 不能被半途写坏、也不能被清空 ——
        // 「宁可陈旧并明说」的另一半。整轮只有 AGENTS.md 不可写，
        // 所以这个「未变」不能是「所有文档都没更新」的假象：
        // 上面 README 确实拿到了新内容。
        @Assert(readFileTextOr(agents, "") == agentsAfterRound1)
    } finally {
        if (!locked.isEmpty()) {
            execCapture("chflags", ["nouchg", locked], None, 8000)
        }
        exitTestHome()
        if (!projId.isEmpty()) {
            removePathIfExists(deepgitPath(["store", projId]))
        }
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

@Test
func testBranchCountIsDisclosedAgainstRealRepoBranchTotal(): Unit {
    // 「N 个分支」到底是仓库的分支数，还是引擎追踪到基线的分支数？
    //
    // 原实现只报后者，且**零披露**。候选集被 config.maxShallowBranches
    // （默认 6）限着：已追踪 ∪ 当前 ∪ 默认 ∪ 最近活跃 —— 16 个分支的仓库
    // 实测只报 7 个。命令输出、README 托管区、status 顶部都在说这句话，
    // 读者只会理解成「这仓库就 7 个分支」。
    //
    // 「上限当全量」第 16 次。修法是让口径自己说出来，不改字段名。
    let base = "/tmp/deepgit-bscope-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    var pid = ""
    try {
        gitRun(base, ["init", "-b", "main"], false)
        writeFileAtomic(base + "/README.md", "# p\n")
        writeFileAtomic(base + "/a.py", "q\n")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: init"], false)
        // 15 条特性分支 + main = 16，稳稳超过默认上限 6
        var i: Int64 = 1
        while (i <= 15) {
            gitRun(base, ["branch", "feature/b${i}"], false)
            i += 1
        }

        let project = ProjectEntry(projectIdFor(base), basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)
        pid = project.id
        let config = Config.defaults()
        // 前提必须先钉住，否则「追踪数 < 16」可能是因为上限其实不是 6 而空转绿
        @Assert(config.maxShallowBranches == 6)

        let r = runUpdate(project, config, UpdateOptions())
        @Assert(r.ok)

        // 真实总数来自 for-each-ref refs/heads（无上限），不是候选集
        match (r.repoBranchCount) {
            case Some(n) => @Assert(n == 16)
            case None => @Assert(false)   // 读不出来 ≠ 0，这里必须是 Some
        }
        // 追踪数被上限压住 —— 这正是要披露的事实本身
        @Assert(r.branchCount > 0)
        @Assert(r.branchCount < 16)

        // 分母必须进 journal：只存 branchCount 的话，半年后回看 journal
        // 只会得到「记录了 7 个分支」，而当时仓库有 16 个
        @Assert(Json.intAt(r.journalEntry, "repoBranchCount", -1) == 16)
        @Assert(Json.boolAt(r.journalEntry, "branchCountTruncated", false))

        // 文本出口必须带分母
        let note = branchScopeNote(r.branchCount, r.repoBranchCount, true)
        @Assert(note.contains("16"))
        @Assert(note.contains("${r.branchCount}"))

        // 文档出口（README 托管区）同样不能只说「追踪 N 个分支」
        @Assert(readFileTextOr(base + "/README.md", "").contains("仓库共 16 个"))
    } finally {
        exitTestHome()
        if (!pid.isEmpty()) {
            removePathIfExists(deepgitPath(["store", pid]))
        }
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

@Test
func testBranchScopeNoteTreatsUnknownAsSilenceNotZero(): Unit {
    // 口径函数的两个边界：
    //   相等 → 闭嘴（多说一句「共 7 个」纯属噪音）
    //   未知 → **也**闭嘴，但不能变成「仓库共 0 个分支」
    //        —— 读不出来和没有分支是两件相反的事
    @Assert(branchScopeNote(7, Some(7), true) == "")
    @Assert(branchScopeNote(7, Some(16), true).contains("16"))
    @Assert(branchScopeNote(7, Some(16), true).contains("7"))
    @Assert(branchScopeNote(16, Some(7), true).contains("7"))
    @Assert(branchScopeNote(0, None, true) == "")
    @Assert(branchScopeNote(0, None, false) == "")
    // 英文不能漏分母
    @Assert(branchScopeNote(7, Some(16), false).contains("16"))
    @Assert(branchScopeNote(7, Some(7), false) == "")
}

@Test
func testUpdateDocsTypoMustNotBecomeFullRewrite(): Unit {
    // `--docs` 拼错的后果不是「少做一点」，而是**静默升级成范围最大的那次**。
    //
    // newDocTargets 用的是 `docs == "readme"` / `== "agent"` 的排除法，
    // 任何认不出来的值都落进默认档：README 与所有已存在的 AGENTS/CLAUDE
    // 一起被注入托管区。实测：
    //     --docs readme  → 只动 README.md
    //     --docs rdame   → AGENTS.md 和 CLAUDE.md 也被改了
    // 用户的 agent 指令文件被一个拼写错误动到，且全程没有任何提示。
    //
    // 与 validateDeepScope（--scope）完全同构。deep 侧早已收敛到 runDeep 入口，
    // update 侧此前**一次都没校验过**。现在同样收敛到 runUpdate。
    for (bad in ["Readme", "readme ", "rdame", "AGENT", "alll", "docs", "中文"]) {
        var threw = false
        try {
            validateUpdateDocs(bad)
        } catch (e: DgError) {
            threw = true
            // 错误信息必须带合法取值，否则调用方无从纠正
            @Assert(e.message.contains("all | readme | agent"))
            @Assert(e.message.contains(bad))
        }
        @Assert(threw)
    }
    // 合法值必须放行（含未指定的空串）
    for (ok in ["", "all", "readme", "agent"]) {
        validateUpdateDocs(ok)
    }

    // 收敛点本身也必须拒：绕开 cmdUpdate 直接调 runUpdate 也不行。
    let base = "/tmp/deepgit-docscope-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    var pid = ""
    try {
        ensureDir(base)
        gitRun(base, ["init", "-b", "main"], false)
        writeFileAtomic(base + "/README.md", "# r\n")
        // 关键前提：AGENTS.md 必须**存在但没有托管区** ——
        // 只有这样「被多改了」才看得出来
        writeFileAtomic(base + "/AGENTS.md", "# a\n用户正文\n")
        writeFileAtomic(base + "/a.txt", "1")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)
        let (p, _) = addProject(base, "docscope", ArrayList<String>(), "")
        pid = p.id

        // 对照组：--docs readme 只动 README
        let opts = UpdateOptions()
        opts.docs = "readme"
        _ = runUpdate(p, Config.defaults(), opts)
        @Assert(readFileTextOr(base + "/README.md", "").contains("deepgit:begin progress"))
        @Assert(!readFileTextOr(base + "/AGENTS.md", "").contains("deepgit:begin progress"))
        @Assert(readFileTextOr(base + "/AGENTS.md", "").contains("用户正文"))

        // 收敛点：拼错必须抛，且**一个字节都不能写**
        var threw = false
        try {
            let bad = UpdateOptions()
            bad.docs = "rdame"      // 只差一个字母
            _ = runUpdate(p, Config.defaults(), bad)
        } catch (e: DgError) {
            threw = true
        }
        @Assert(threw)
        @Assert(!readFileTextOr(base + "/AGENTS.md", "").contains("deepgit:begin progress"))
    } finally {
        exitTestHome()
        if (!pid.isEmpty()) {
            removePathIfExists(deepgitPath(["store", pid]))
        }
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

@Test
func testSecondUpdateWithNoNewCommitsRewritesNothing(): Unit {
    // 整轮 update 的端到端幂等。
    //
    // ⚠️ 这条测试**抓不到** normalizeForCompare 那个回归 —— 它的两次 runUpdate
    // 落在同一分钟内，renderBlock 的时间戳是分钟粒度，两侧 stamp 相同，
    // stripUpdateStamp 一命中就相等了。实测把 normalizeForCompare 整个删掉，
    // 这条照样全绿。真正有判别力的是 kernel/docs.cj 里那条
    // testNoOpGuardSurvivesCrossMinuteStampAndTrailingNewlines，
    // 它显式构造跨分钟 + 尾随换行的真实渲染形态。
    //
    // 留这一条的价值在于端到端性质本身：第二轮不得重写文件、不得新增备份、
    // 不得给用户仓库增加待提交改动。这三条任何一条回归（渲染器引入抖动、
    // 备份策略放宽、脏文件过滤失效）都会红，只是与上面那条互补。
    //
    // 审计曾记「AGENTS/CLAUDE 的 no-op 守卫恒不生效，每次跨分钟重写并留备份」，
    // 本轮**复现不出来** —— 真实跑两遍是「无变化」、mtime 不动、备份不增长。
    // 原因是 upsertRegion 两侧已由 normalizeForCompare 归一化。
    // 所以这条是「把已修好的性质钉住」，不是「本轮修好了它」。
    let base = "/tmp/deepgit-noop-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    var pid = ""
    try {
        ensureDir(base)
        gitRun(base, ["init", "-b", "main"], false)
        writeFileAtomic(base + "/README.md", "# r\n")
        // 三个文档都存在：守卫必须对 agent 文档同样生效，
        // 它的渲染路径与 README 不同（尾部换行数不一样），历史上正是这里出问题
        writeFileAtomic(base + "/AGENTS.md", "# a\n")
        writeFileAtomic(base + "/CLAUDE.md", "# c\n")
        writeFileAtomic(base + "/a.txt", "1")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)
        let (p, _) = addProject(base, "noop", ArrayList<String>(), "")
        pid = p.id
        let cfg = Config.defaults()

        // 第一轮：写入三个文档
        let first = runUpdate(p, cfg, UpdateOptions())
        @Assert(first.ok)
        var wroteAll = false
        for ((file, changed, _, _, _) in first.docChanges) {
            if (changed && (file == "AGENTS.md" || file == "CLAUDE.md")) {
                wroteAll = true
            }
        }
        // 前提：首轮必须真的写了 agent 文档，否则下面的「无变化」是空转绿
        @Assert(wroteAll)

        let backupsDir = deepgitPath(["store", p.id, "backups"])
        let snap1 = backupSnapshot(backupsDir)
        let readme1 = readFileTextOr(base + "/README.md", "")
        let agents1 = readFileTextOr(base + "/AGENTS.md", "")
        let claude1 = readFileTextOr(base + "/CLAUDE.md", "")

        // 第二轮：没有新提交，内容应当完全不变
        let second = runUpdate(p, cfg, UpdateOptions())
        @Assert(second.ok)

        // 逐字节不变（含时间戳行 —— stripUpdateStamp 压的就是它）
        @Assert(readFileTextOr(base + "/README.md", "") == readme1)
        @Assert(readFileTextOr(base + "/AGENTS.md", "") == agents1)
        @Assert(readFileTextOr(base + "/CLAUDE.md", "") == claude1)

        // 一个都不能报 changed
        for ((file, changed, _, _, _) in second.docChanges) {
            @Assert(!changed)
        }

        // 备份不得增长：重写即备份，而重写就是仓库变脏的源头
        let snap2 = backupSnapshot(backupsDir)
        @Assert(snap1.size > 0)          // 前提：首轮确实留了备份
        @Assert(snap2.size == snap1.size)
        // 真正让用户仓库变脏的那件事：第二轮**不得新增**任何脏改动。
        // 注意不是「仓库必须干净」—— 首轮本来就该改文档，脏是预期内的；
        // 要防的是第二轮又改一遍，于是待提交改动多一份、提交噪音多一截。
        let dirtyAfter1 = gitTry(base, ["status", "--porcelain"]).stdout
        let dirtyAfter2 = gitTry(base, ["status", "--porcelain"]).stdout
        @Assert(dirtyAfter2 == dirtyAfter1)
    } finally {
        exitTestHome()
        if (!pid.isEmpty()) {
            removePathIfExists(deepgitPath(["store", pid]))
        }
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

/// 备份目录里的实际备份文件名（`.owned` / `.docpath` 是归属凭据，不算备份）。
func backupSnapshot(backupsDir: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (sub in listDir(backupsDir)) {
        // 走 classifyEntry：不抛（#199）。备份目录在「迁移到另一台机器 / 半删」的状态下
        // 会出现 stat 不到的条目，而 verify 的「你之后编辑过」判定完全依赖这份清单。
        let subIsDir = match (classifyEntry(sub)) {
            case EntryKind.Dir => true
            case _ => false
        }
        if (!subIsDir) {
            continue
        }
        let d = "${backupsDir}/${sub.name}"
        for (f in listDir(d)) {
            let fIsDir = match (classifyEntry(f)) {
                case EntryKind.Dir => true
                case _ => false
            }
            if (!fIsDir && !f.name.startsWith(".")) {
                out.add("${sub.name}/${f.name}")
            }
        }
    }
    return out
}

@Test
func testUpdateReportsNewCommitsNotBaselineReplay(): Unit {
    // 「3 个提交的仓库连跑三次 update，每次都报 3 个提交」——
    // journal 里三条记录 commitCount 全是 3，隐含「记了 9 个提交」。
    //
    // 根因：branchDelta 在 from == head（无新提交）时会把 from 清空并从 HEAD
    // 重列**整份基线**（progress.cj），于是 d.count() 每轮都等于基线规模。
    // 而 journal 的 commitCount 与 CLI 的「N 个提交」说的是
    // 「本次记下了几个提交」—— 那个 N 必须是本轮真正新增的。
    //
    // 这里**没有**顺手加一个「基线总数」字段顶上：那个量在本引擎里没有
    // 一致语义（无新提交时是整份基线，有增量时只装增量，实测同一项目
    // 第一轮报 3、加一个提交后反而报 1），造一个会变义的字段出门比缺字段更糟。
    let base = "/tmp/deepgit-newcommits-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    var pid = ""
    try {
        ensureDir(base)
        gitRun(base, ["init", "-b", "main"], false)
        var i: Int64 = 1
        while (i <= 3) {
            writeFileAtomic(base + "/a.txt", "${i}\n")
            gitRun(base, ["add", "."], false)
            gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: c${i}"], false)
            i += 1
        }
        let (p, _) = addProject(base, "newc", ArrayList<String>(), "")
        pid = p.id
        let cfg = Config.defaults()

        // 首轮：建立基线，这 3 个提交全是**新记的**
        let r1 = runUpdate(p, cfg, UpdateOptions())
        @Assert(r1.ok)
        @Assert(r1.commitCount == 3)
        // 口径必须自述，不能靠 mode 字段去猜
        @Assert(Json.strAt(r1.journalEntry, "commitCountScope", "") == "new")

        // 第二、三轮：没有任何新提交
        let r2 = runUpdate(p, cfg, UpdateOptions())
        @Assert(r2.ok)
        @Assert(r2.commitCount == 0)
        let r3 = runUpdate(p, cfg, UpdateOptions())
        @Assert(r3.ok)
        @Assert(r3.commitCount == 0)

        // 真加一个提交 → 1
        writeFileAtomic(base + "/a.txt", "4\n")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: c4"], false)
        let r4 = runUpdate(p, cfg, UpdateOptions())
        @Assert(r4.commitCount == 1)

        @Assert(Json.intAt(r2.journalEntry, "commitCount", -1) == 0)
        @Assert(Json.intAt(r3.journalEntry, "commitCount", -1) == 0)
        var summed: Int64 = 0
        for (e in readJournal(p.id, 100)) {
            summed += Json.intAt(e, "commitCount", 0)
            @Assert(Json.strAt(e, "commitCountScope", "") == "new")
        }
        @Assert(summed == 4)
    } finally {
        exitTestHome()
        if (!pid.isEmpty()) {
            removePathIfExists(deepgitPath(["store", pid]))
        }
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

@Test
func testNoOpUpdateDoesNotAppendDuplicateJournalEntry(): Unit {
    // journal 是「进度日志」——「这次记下了什么」。
    // 「什么时候跑过」由 state.lastUpdateAt / runCount 负责，两者不必混在一处。
    //
    // 原实现无条件 append，于是 post-commit 钩子每提交一次就多一行，
    // 而那行和上一行除了 at/id 逐字节相同。后果不只是噪音：
    // 任何从 journal 统计「这项目一共做了多少事」的调用方都会被灌进几倍虚高。
    let base = "/tmp/deepgit-noopj-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    var pid = ""
    try {
        ensureDir(base)
        gitRun(base, ["init", "-b", "main"], false)
        writeFileAtomic(base + "/a.txt", "1\n")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: x"], false)
        let (p, _) = addProject(base, "noopj", ArrayList<String>(), "")
        pid = p.id
        let cfg = Config.defaults()

        // 先跑到「完全无变化」为止。第 1 轮会新建 README（真实变化），
        // 第 2 轮会报出「1 个未跟踪文件」（引擎自己写的 README，也是真实变化），
        // 第 3 轮起才真正 no-op —— 所以固定跑三轮再开始计数。
        runUpdate(p, cfg, UpdateOptions())
        runUpdate(p, cfg, UpdateOptions())
        runUpdate(p, cfg, UpdateOptions())
        let stable = readJournal(p.id, 100)
        let before = stable.size
        @Assert(before >= 1)   // 前提：前面确实记过东西

        let st0 = readState(p.id)
        let runs0 = Json.intAt(st0, "runCount", 0)

        // 三轮纯 no-op：runCount 必须继续涨（「跑过」要如实记）
        runUpdate(p, cfg, UpdateOptions())
        runUpdate(p, cfg, UpdateOptions())
        runUpdate(p, cfg, UpdateOptions())

        // 但 journal 一条都不能多
        @Assert(readJournal(p.id, 100).size == before)
        let st1 = readState(p.id)
        @Assert(Json.intAt(st1, "runCount", 0) == runs0 + 3)
        // 「最后一次真正记到东西是什么时候」要可供审计
        @Assert(Json.strAt(st1, "lastRecordedAt", "") == Json.strAt(st0, "lastRecordedAt", ""))
        @Assert(!Json.strAt(st1, "lastRecordedAt", "").isEmpty())

        // 反向：真加了提交，journal 必须增长
        writeFileAtomic(base + "/a.txt", "2\n")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: y"], false)
        _ = runUpdate(p, cfg, UpdateOptions())
        @Assert(readJournal(p.id, 100).size == before + 1)
    } finally {
        exitTestHome()
        if (!pid.isEmpty()) {
            removePathIfExists(deepgitPath(["store", pid]))
        }
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}
