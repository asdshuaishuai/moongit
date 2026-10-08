// 深度更新（deep）：手动触发的全量文档重写（overview/history/architecture/commands）。
package moongit.flow

import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.kernel.*
import moongit.util.*

public class DeepOptions {
    public var scope: String = "all"  // all | readme | agent
    public var dryRun: Bool = false
    public var source: String = "cli"
    public var notes: ArrayList<String> = ArrayList<String>()

    public init() {}
}

public class DeepResult {
    public let ok: Bool
    public let projectId: String
    public let projectName: String
    public let provider: String
    public let highlights: ArrayList<String>
    public let docChanges: ArrayList<(String, Bool, Bool, String, String)>
    public let journalEntry: JsonValue
    public let facts: RepoFacts
    public let at: String

    public init(
        ok: Bool, projectId: String, projectName: String, provider: String,
        highlights: ArrayList<String>, docChanges: ArrayList<(String, Bool, Bool, String, String)>,
        journalEntry: JsonValue, facts: RepoFacts, at: String,
    ) {
        this.ok = ok
        this.projectId = projectId
        this.projectName = projectName
        this.provider = provider
        this.highlights = highlights
        this.docChanges = docChanges
        this.journalEntry = journalEntry
        this.facts = facts
        this.at = at
    }
}

/// scope 的唯一合法取值。
///
/// ⚠️ 为什么必须在**这里**校验，而不是只靠各调用面自己校验：
/// runDeep 内部用的是 `opts.scope != "agent"` 和 `opts.scope != "readme"`
/// 这种「排除法」，于是**任何无法识别的值都等同于 "all"** ——
/// 两个分支都跑，README 和 AGENTS/CLAUDE 一起被重写。
/// 也就是说 scope 一旦拼错（"Readme" / "readme " / "agents"），
/// 后果不是「少做一点」，而是**静默升级成破坏性最大的全量重写**。
///
/// CLI（cmdDeep）和 HTTP（/api/deep）早就各自校验了，MCP 的
/// `run_deep_update` 一直没做 —— 同一份校验抄三遍，漏一处就破。
/// 收敛到这里，任何未来的调用点都躲不掉。
public let DEEP_SCOPES: Array<String> = ["all", "readme", "agent"]

public func validateDeepScope(scope: String): Unit {
    for (s in DEEP_SCOPES) {
        if (s == scope) {
            return
        }
    }
    throw DgError.usage("scope 只能是 all | readme | agent，收到：${scope}")
}

public func runDeep(project: ProjectEntry, config: Config, opts: DeepOptions): DeepResult {
    // 早于任何写操作：拼错的 scope 绝不能落到「全量重写」上去
    validateDeepScope(opts.scope)
    let store = ensureStore(project.id)
    let lockFile = "${store.locks}/project.lock"
    let startedAt = nowIso()

    return withLock(lockFile, 900000, { =>
        Log.step("深度采集仓库全量事实：${project.name}")
        let facts = collectFacts(project.path, project.kind, config, 60, true)
        var progress = readProgress(project.id)
        Json.set(progress, "projectId", Json.of(project.id))
        Json.set(progress, "name", Json.of(project.name))

        // 分支基线：与 runUpdate 走**同一个** recordBranchBaseline。
        //
        // 以前这段完全没有，注释写着「deep 隐含 shallow」却从未兑现：
        // deep 的 journal 条目写着 commitCount=N（看起来像「已记录 N 个提交」），
        // 但 progress.branches 始终是空的、overall 是 null。
        // 只跑过 deep 的项目在 status 里长这样：
        //     headline  = 「暂无新变化」
        //     branches  = []
        //     journal   = [{ commitCount: 2 }]      ← 同一屏里自相矛盾
        // 而且下次 update 会把同一批提交当成全新的再数一遍。
        //
        // 上限用 config.maxShallowBranches（不是 deep 自己采的 60）：
        // deep 记 60 个分支、update 记 6 个，两条路径会来回覆盖对方的基线。
        let base = recordBranchBaseline(project, config, facts, progress, config.maxShallowBranches)

        // 章节内容：规则引擎确定性渲染。引擎是 AI 无关的——
        // LLM 增强由上层 AI 实现（deepDolphin.app）基于 /api/context 自行完成。
        let provider = "rules"
        var highlights = ArrayList<String>()
        let (readmeOverview, readmeHistory, agentArch, agentCmds) = rulesDeepSections(facts, progress, config.language)
        let agentOverview = readmeOverview

        // 进度区域也刷新（deep 隐含 shallow）—— 现在是真的了：
        // 用刚记录下来的分支基线和叙述渲染，而不是空 progress + 空叙述。
        let progressReadme = renderProgressReadme(
            facts, progress, base.narratives,
            config.language, "deep", startedAt, config.maxShallowBranches,
        )
        let progressAgent = renderProgressAgent(
            facts, progress, base.narratives,
            config.language, "deep", startedAt,
        )

        // 组装目标文档
        let targets = ArrayList<(String, ArrayList<(String, String)>, String)>()
        var hasReadme = false
        for (f in facts.docsPresent) {
            if (f.toAsciiLower() == "readme.md") {
                hasReadme = true
            }
        }
        if (opts.scope != "agent" && hasReadme) {
            let regions = ArrayList<(String, String)>()
            regions.add(("overview", readmeOverview))
            regions.add(("progress", progressReadme))
            regions.add(("history", readmeHistory))
            targets.add(("README.md", regions, "# ${facts.name}\n\n"))
        }
        if (opts.scope != "readme") {
            for (f in config.agentDocCandidates) {
                var present = false
                for (d in facts.docsPresent) {
                    if (d == f) {
                        present = true
                    }
                }
                if (present) {
                    let regions = ArrayList<(String, String)>()
                    regions.add(("overview", agentOverview))
                    regions.add(("architecture", agentArch))
                    regions.add(("commands", agentCmds))
                    regions.add(("progress", progressAgent))
                    targets.add((f, regions, ""))
                }
            }
        }

        if (targets.size == 0) {
            Log.warn("没有找到可更新的文档（README.md / AGENTS.md / CLAUDE.md）")
        }

        // ⚠️ 写任何文件之前，先把**全部**目标预检一遍（与 runUpdate 同理）。
        // 边遍历边写会在第二个目标失败时留下半成品：文档已声称新状态，
        // 而 store 的 journal / state 一步没动 —— 引擎并不持有文档里写的东西。
        if (!opts.dryRun) {
            for ((file, regions, template) in targets) {
                previewRegions("${project.path}/${file}", regions, template,
                               "${store.backups}/${file.replace("/", "_")}")
            }
        }

        // 写入
        let docChanges = ArrayList<(String, Bool, Bool, String, String)>()
        // 文档写入失败要收集到 store 写完之后再报，不能就地抛。
        // 理由与 flow/update.cj 写循环处完全相同：进度库是事实源、文档是派生视图。
        let docErrors = ArrayList<String>()
        for ((file, regions, template) in targets) {
            let fullPath = "${project.path}/${file}"
            if (opts.dryRun) {
                // 如实报告会不会变，不要硬编码 true
                let p = previewRegions(fullPath, regions, template, "${store.backups}/${file.replace("/", "_")}")
                // dry-run 不写任何文件 ⇒ **没有备份**（同 update.cj 的理由）
                docChanges.add((file, p.changed, p.created, renderPreview(regions), ""))
                continue
            }
            let backupDir = "${store.backups}/${file.replace("/", "_")}"
            // ⚠️ catch Exception 而不是 DgError：真正冒出来的是
            // `Operation not permitted` 这类**标准库 IO 异常**（不可变位、只读挂载、
            // 磁盘满），它不是 DgError。只 catch DgError 等于没写这个 catch。
            try {
                let res = applyRegions(fullPath, regions, backupDir, template)
                // 记录原始相对路径：备份目录名是 file.replace("/", "_")，不可逆
                // （docs/AGENTS.md → docs_AGENTS.md）。verify 靠它找回真正的文档路径。
                writeBackupManifest(backupDir, file)
                // 第 5 位是**真实的备份路径**：引擎改了用户的文档却从不说备份在哪。
                docChanges.add((file, res.changed, res.created, "", res.backup))
                if (res.changed) {
                    Log.ok("已更新 ${file}${if (res.created) { "（新建）" } else { "" }}")
                } else {
                    Log.info("${file} 无变化")
                }
            } catch (e: Exception) {
                docErrors.add("${file}：${oneLineClamped(e.message, 90)}")
                Log.error("${project.name}: ${file} 更新失败 —— ${oneLineClamped(e.message, 90)}")
            }
        }

        // 日志
        let entry = Json.obj()
        Json.set(entry, "id", Json.of(randomId("j")))
        Json.set(entry, "at", Json.of(startedAt))
        Json.set(entry, "project", Json.of(project.name))
        Json.set(entry, "projectId", Json.of(project.id))
        Json.set(entry, "branch", Json.of(if (facts.currentBranch.size > 0) { facts.currentBranch } else { "" }))
        Json.set(entry, "mode", Json.of("deep"))
        Json.set(entry, "source", Json.of(opts.source))
        Json.set(entry, "provider", Json.of(provider))
        Json.set(entry, "commitCount", Json.of(facts.commitCount))
        // 口径自述：deep 这里装的是**仓库提交总数**（rev-list --count HEAD，无上限），
        // 而 update 路径装的是「本轮新记录数」。同名不同义，必须让条目自己说清。
        Json.set(entry, "commitCountScope", Json.of("repoTotal"))
        // ⚠️ 下面三个必须**恒发**（缺陷 #188）。
        // 原来只有浅更新路径写它们，deep 条目一个都没有 ——
        // 消费方于是只能把「缺键」当成 false / 当成「没有截断」，
        // 而 deep 恰恰是最容易让人误读口径的那一类条目
        // （`+100` 在这里是仓库总数，不是本轮新增）。
        // 恒发之后，「这个键在不在」不再是判断依据，只有值本身是。
        //
        // rev-list --count HEAD 没有上限，所以这里恒为 false；
        // 写出来不是为了说「没截断」，而是为了让缺键这件事本身消失。
        Json.set(entry, "commitCountTruncated", Json.of(false))
        // deep 不做逐分支基线，因此不对「追踪分支数 vs 仓库分支数」下判断；
        // 恒发 false 表示「本条目不对分支数作任何声称」，而不是「没截断」。
        Json.set(entry, "branchCountTruncated", Json.of(false))
        // 分母仍然要给：collectFacts 的「读到 0」守卫保证非空，
        // 拿不到时按约定报 -1（读不出来），不是 0。
        Json.set(entry, "repoBranchCount", Json.of(facts.branches.size))
        let summary = if (highlights.size > 0) {
            highlights[0]
        } else {
            "深度更新 ${joinStrings(targetFiles(targets), "、")}（基于 ${facts.commitCount} 个提交）"
        }
        Json.set(entry, "summary", Json.of(summary))
        let hlJson = ArrayList<JsonValue>()
        for (h in highlights) {
            hlJson.add(Json.of(h))
        }
        Json.set(entry, "highlights", JArr(hlJson))
        let docsJson = ArrayList<JsonValue>()
        for (f in targetFiles(targets)) {
            docsJson.add(Json.of(f))
        }
        Json.set(entry, "docs", JArr(docsJson))

        if (!opts.dryRun) {
            Json.set(progress, "lastDeepAt", Json.of(startedAt))
            let entries = Json.arrAt(progress, "entries")
            entries.add(entry)
            Json.set(progress, "entries", JArr(entries))
            writeProgress(project.id, progress)
            // 与 runUpdate 同一判据：没记到新东西就不追加 journal。
            // 否则连跑两次 deep 会在 journal 里留下两条除了 at/id 逐字节相同的记录，
            // 而 `status` 的「最近进度」会把它们并排显示给用户。
            var anyDocChanged = false
            for ((_, changed, _, _, _) in docChanges) {
                if (changed) {
                    anyDocChanged = true
                }
            }
            if (base.newCommits > 0 || anyDocChanged) {
                appendJournal(project.id, entry, project.name)
            }
            var state = readState(project.id)
            Json.set(state, "lastDeepAt", Json.of(startedAt))
            Json.set(state, "lastUpdateAt", Json.of(startedAt))
            Json.set(state, "runCount", Json.of(Json.intAt(state, "runCount", 0) + 1))
            if (base.newCommits > 0 || anyDocChanged) {
                Json.set(state, "lastRecordedAt", Json.of(startedAt))
            }
            writeState(project.id, state)
            for ((file, _, _, _, _) in docChanges) {
                pruneBackups("${store.backups}/${file.replace("/", "_")}", config.backupKeep)
            }
        }

        // ⚠️ 必须在**进度库写完之后**才报，且要报成非零退出。
        //
        // 早先是在写循环里就地抛，于是 store 一次都没写：
        //   chflags uchg AGENTS.md → deep
        //   「✓ 已更新 README.md」→「✗ Operation not permitted」→ exit 1
        //   README 里写了「追踪 N 个分支」，而 store 里 branches=0、journal=0。
        // 文档声称的状态引擎并不持有，且两边无法自洽。
        // 现在 store 一定写成功，这份进度是记下了的；没写成的是那几个文档，
        // 必须点名说是哪几个 —— 笼统说失败会让用户以为整轮白跑，进而重跑。
        if (!docErrors.isEmpty()) {
            throw DgError(
                "DOC_WRITE_FAILED",
                "进度已记录到 ${project.id}，但以下文档未能更新（它们的内容仍是上一轮的）：\n  - " +
                    joinStrings(docErrors, "\n  - "),
                1,
                Some(project.name),
            )
        }

        return DeepResult(
            true, project.id, project.name, provider,
            highlights, docChanges, entry, facts, startedAt,
        )
    })
}

func targetFiles(targets: ArrayList<(String, ArrayList<(String, String)>, String)>): ArrayList<String> {
    let out = ArrayList<String>()
    for ((f, _, _) in targets) {
        out.add(f)
    }
    return out
}

func renderPreview(regions: ArrayList<(String, String)>): String {
    let sb = StringBuilder()
    for ((name, content) in regions) {
        sb.append("<!-- ${name} -->\n")
        sb.append(truncateChars(content, 400))
        sb.append("\n\n")
    }
    return sb.toString()
}

/// 把提示词中的完整事实 JSON 替换为裁剪版（避免重复序列化两遍）
func replaceFactsInPrompt(user: String, fittedJson: String): String {
    let open = "## 仓库事实（JSON）\n```json\n"
    let startIdx = user.indexOf(open)
    match (startIdx) {
        case None => return user
        case Some(si) =>
            let contentStart = si + open.size
            let closeIdx = user.indexOf("\n```", contentStart)
            match (closeIdx) {
                case None => return user
                case Some(ci) =>
                    return user[..contentStart] + fittedJson + user[ci..]
            }
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testRunDeepOnRealRepo(): Unit {
    let base = "/tmp/deepgit-deep-${nowMillis()}"
    // 隔离数据目录。必须放在仓库之外：若置于 base 内部，engine 的 store/ 目录
    // 会让 git 工作区变脏，runDeep 第二次执行就不再幂等（下方的 !anyChanged 断言会红）。
    // 不隔离则 runUpdate/runTrack/runDeep 内部按 projectId 推导出的 store 路径会落到
    // 用户真实的 ~/.deepgit/store，测试失败或被中断时还会留下孤儿目录。
    let testHome = base + "-home"   // 仓库的兄弟目录：唯一，且不在 git 工作区内
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/README.md", "# proj\n\n用户手写开头\n")
    writeFileAtomic(base + "/AGENTS.md", "# Agent 指南\n\n用户手写 agent 内容\n")
    writeFileAtomic(base + "/cjpm.toml", "[package]\nname=\"x\"\nversion=\"1.0.0\"")
    writeFileAtomic(base + "/main.cj", "package x")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: initial"], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "tag", "v1.0.0"], false)

    let pid = projectIdFor(base)
    let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)
    let opts = DeepOptions()
    let result = runDeep(project, Config.defaults(), opts)

    @Assert(result.ok)
    @Assert(result.facts.kind == "git")

    // README 得到 overview/history/progress 三个区域，用户内容保留
    let readme = readFileTextOr(base + "/README.md", "")
    @Assert(readme.contains("用户手写开头"))
    @Assert(readme.contains("deepgit:begin overview"))
    @Assert(readme.contains("deepgit:begin history"))
    @Assert(readme.contains("deepgit:begin progress"))

    // AGENTS 得到 overview/architecture/commands/progress
    let agents = readFileTextOr(base + "/AGENTS.md", "")
    @Assert(agents.contains("用户手写 agent 内容"))
    @Assert(agents.contains("deepgit:begin architecture"))
    @Assert(agents.contains("deepgit:begin commands"))
    // 事实核对：版本标签应出现在 history
    @Assert(readme.contains("v1.0.0") || agents.contains("v1.0.0"))

    // 幂等：重复执行不产生变化
    let r2 = runDeep(project, Config.defaults(), opts)
    var anyChanged = false
    for ((_, changed, _, _, _) in r2.docChanges) {
        if (changed) {
            anyChanged = true
        }
    }
    @Assert(!anyChanged)

    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
    // 复位必须排在所有 deepgitPath(...) 之后：提前复位会让上面的清理打到真实 store
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testRunDeepReadmeOnlyScope(): Unit {
    let base = "/tmp/deepgit-deep2-${nowMillis()}"
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
    writeFileAtomic(base + "/AGENTS.md", "# agents\n")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)
    let pid = projectIdFor(base)
    let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)
    let opts = DeepOptions()
    opts.scope = "readme"
    let result = runDeep(project, Config.defaults(), opts)
    @Assert(result.ok)
    let agents = readFileTextOr(base + "/AGENTS.md", "")
    @Assert(!agents.contains("deepgit:begin"))  // agent 文档未被触碰
    let readme = readFileTextOr(base + "/README.md", "")
    @Assert(readme.contains("deepgit:begin overview"))
    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
    // 复位必须排在所有 deepgitPath(...) 之后：提前复位会让上面的清理打到真实 store
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testRunDeepDryRunWritesNothing(): Unit {
    let base = "/tmp/deepgit-deep3-${nowMillis()}"
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
    let opts = DeepOptions()
    opts.dryRun = true
    let result = runDeep(project, Config.defaults(), opts)
    @Assert(result.ok)
    let readme = readFileTextOr(base + "/README.md", "")
    @Assert(!readme.contains("deepgit:begin"))
    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
    // 复位必须排在所有 deepgitPath(...) 之后：提前复位会让上面的清理打到真实 store
    exitTestHome()
    removePathIfExists(testHome)
}

/// 仓库读不出来时，deep 必须失败且一个字都不能改。
///
/// 这是本轮最严重缺陷的端到端不变量。旧行为链条：
///   .git/index 被截断 → git status rc=128
///   → statusSummary 的 `if (!r.ok()) { return DirtyState(true, 0,...) }` 压成「工作区干净」
///   → trackedFiles=0、commitCount 取到 0
///   → deep 把「**工程规模**：0 个跟踪文件」写进 README 托管区，覆盖掉真实值
///   → exit 0 打印「✓ 深度更新完成」，假记录还持久化进 progress.json 且不自愈。
/// 托管区外的用户内容当时倒是保住了，但被托管区包着的「真实数据」被清零了。
@Test
func testRunDeepRefusesToWriteWhenRepoUnreadable(): Unit {
    let base = "/tmp/deepgit-deepcorrupt-${nowMillis()}"
    // 隔离数据目录，必须在仓库之外（见 testRunDeepOnRealRepo 的注释）
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/README.md", "# proj\n\n用户手写开头\n")
    writeFileAtomic(base + "/a.txt", "1")
    writeFileAtomic(base + "/b.txt", "2")
    writeFileAtomic(base + "/c.txt", "3")
    writeFileAtomic(base + "/d.txt", "4")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: initial"], false)
    let pid = projectIdFor(base)
    let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)
    let opts = DeepOptions()

    // 基线：健康仓库先 deep 一次，README 里应有真实的跟踪文件数
    @Assert(runDeep(project, Config.defaults(), opts).ok)
    let good = readFileTextOr(base + "/README.md", "")
    @Assert(good.contains("deepgit:begin overview"))
    @Assert(good.contains("5 个跟踪文件"))  // README.md + a/b/c/d.txt
    let storeBefore = readFileTextOr(deepgitPath(["store", pid, "progress.json"]), "")

    // 破坏索引，再来一次
    writeFileAtomic(base + "/.git/index", "GARBAGE-NOT-AN-INDEX")
    var threw = false
    var code = ""
    try {
        _ = runDeep(project, Config.defaults(), opts)
    } catch (e: DgError) {
        threw = true
        code = e.code
    }
    @Assert(threw)
    @Assert(code == "REPO_UNREADABLE")
    // 如实报错，不是「0 个文件」这种读不出来的数字
    @Assert(!code.isEmpty())

    // 核心断言：README 与 store 必须逐字节不变，且没有出现「0 个跟踪文件」
    let after = readFileTextOr(base + "/README.md", "")
    @Assert(after == good)
    @Assert(!after.contains("0 个跟踪文件"))
    @Assert(after.contains("用户手写开头"))
    @Assert(readFileTextOr(deepgitPath(["store", pid, "progress.json"]), "") == storeBefore)

    // 索引修好后恢复正常，不留「坏过一次就永久坏」的状态
    removePathIfExists(base + "/.git/index")
    @Assert(runDeep(project, Config.defaults(), opts).ok)

    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testReplaceFactsInPrompt(): Unit {
    let prompt = "before\n## 仓库事实（JSON）\n```json\n{\"big\":1}\n```\nafter"
    let out = replaceFactsInPrompt(prompt, "{\"small\":2}")
    @Assert(out.contains("{\"small\":2}"))
    @Assert(!out.contains("{\"big\":1}"))
    @Assert(out.contains("before"))
    @Assert(out.contains("after"))
}

@Test
func testRunDeepRecordsBranchBaselineLikeUpdate(): Unit {
    // 回归：deep 从不记录分支进度，journal 却声称记录过。
    //
    // 原实现在 runDeep 里完全没有基线逻辑（注释写着「deep 隐含 shallow」，
    // 从未兑现）。只跑过 deep 的项目：
    //     progress.branches = {}   progress.overall = {}
    //     status.headline    = 「暂无新变化」
    //     status.branches    = []
    //     status.journal     = [{ commitCount: 2 }]     ← 同一屏自相矛盾
    // 而且下次 update 会把同一批提交当成全新的再数一遍。
    //
    // 修法：deep 与 update 共用 recordBranchBaseline。
    let base = "/tmp/deepgit-deepbase-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/README.md", "# p\n")
    writeFileAtomic(base + "/a.txt", "x")
    writeFileAtomic(base + "/b.txt", "y")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: init"], false)
    // 第二次提交必须有真实文件变化：--allow-empty 之外的空提交会被 git 拒绝，
    // gitRun 忽略失败，于是仓库里只剩 1 个提交，后面按 2 断言的测试会假红。
    gitRun(base, ["rm", "-q", "--cached", "b.txt"], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "docs: drop b"], false)

    let pid = projectIdFor(base)
    let project = ProjectEntry(pid, basename(base), base, "git", "", nowIso(), ArrayList<String>(), false)
    let result = runDeep(project, Config.defaults(), DeepOptions())
    @Assert(result.ok)

    // 分支基线必须已经落库
    let progress = readProgress(pid)
    let mainRec = progressBranch(progress, "main")
    @Assert(mainRec.isSome())
    match (mainRec) {
        case Some(rec) =>
            // head 是真实存在的提交，不是空串
            @Assert(Json.strAt(rec, "head", "").size >= 7)
            @Assert(Json.strAt(rec, "status", "") == "active")
            @Assert(Json.strAt(rec, "summary", "").size > 0)
        case None => ()
    }
    // overall 也要有摘要，不能是空对象
    @Assert(Json.strAt(Json.getOr(progress, "overall"), "summary", "").size > 0)

    // status 不能再说「暂无新变化」，也不能一个分支都不列
    let st = projectStatus(project, Config.defaults(), 5)
    @Assert(!Json.has(st, "error"))
    @Assert(Json.arrAt(st, "branches").size == 1)
    @Assert(Json.strAt(st, "headline", "") != "暂无新变化")

    // journal 声称的 commitCount 必须有基线兜底：紧接着再跑一次 update，
    // 不能把同一批提交当成新提交再数一遍。
    //
    // ⚠️ 这条断言原先写的是 `== 2`，注释写「应仍是 2，不是 4」。
    // 那是**旧口径**下的答案：commitCount 装的是各分支基线规模之和，
    // deep 已经建过基线，所以 update 拿到的还是 2 —— 恰好等于「没重复计数」，
    // 于是这条测试用一个**间接的证据**表达了它真正想守的东西。
    //
    // 现在 commitCount 的口径是「本轮新记录数」（见 update.cj 的 newCommits），
    // 直接答案就是 0 —— 这比 2 更强：2 需要读者先知道「基线有 2 个」才推得出
    // 「没重复」，0 不需要任何前置知识。
    let after = runUpdate(project, Config.defaults(), UpdateOptions())
    @Assert(after.ok)
    @Assert(after.commitCount == 0)   // deep 已建基线，这轮一个新提交也没有
    @Assert(!Json.boolAt(after.journalEntry, "commitCountTruncated", true))
    // 口径自述：update 路径装的是「本轮新增」
    @Assert(Json.strAt(after.journalEntry, "commitCountScope", "") == "new")

    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
    // 复位必须排在所有 deepgitPath(...) 之后：提前复位会让上面的清理打到真实 store
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testDeepScopeTypoMustNotBecomeFullRewrite(): Unit {
    // runDeep 用的是「排除法」：`scope != "agent"` / `!= "readme"`。
    // 于是任何认不出来的值都等同于 "all" —— README 与 AGENTS/CLAUDE 一起被重写，
    // 是三种 scope 里破坏性最大的那个。拼错的后果不是「少做一点」，
    // 而是**静默升级成全量写**。
    //
    // CLI（cmdDeep）和 HTTP（/api/deep）早就各自校验了，只有 MCP 的
    // run_deep_update 没做 —— 同一份校验抄三遍，漏一处就破。
    // 现在校验收敛到 runDeep 入口，任何调用面都躲不掉。
    for (bad in ["Readme", "readme ", "agents", "AGENT", "alll", "none", "中文"]) {
        var threw = false
        try {
            validateDeepScope(bad)
        } catch (e: DgError) {
            threw = true
            // 错误信息必须带合法取值，否则调用方无从纠正
            @Assert(e.message.contains("all | readme | agent"))
            @Assert(e.message.contains(bad))
        }
        @Assert(threw)
    }
    // 三个合法值必须放行
    validateDeepScope("all")
    validateDeepScope("readme")
    validateDeepScope("agent")

    // 收敛点本身也必须拒：绕开各调用面的校验直接调 runDeep 也不行。
    let base = "/tmp/deepgit-scope-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)
    let (p, _) = addProject(base, "scope-demo", ArrayList<String>(), "")
    var runThrew = false
    try {
        let opts = DeepOptions()
        opts.scope = "Readme"          // 只差首字母大小写
        _ = runDeep(p, Config.defaults(), opts)
    } catch (e: DgError) {
        runThrew = true
    }
    @Assert(runThrew)

    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", p.id]))
    exitTestHome()
    removePathIfExists(testHome)
}

/// #188 回归：深更新条目必须**恒发**三个披露字段。
///
/// 负控（曾真实发红）：deep 路径只写 `commitCount` + `commitCountScope`，
/// `commitCountTruncated` / `branchCountTruncated` / `repoBranchCount` 一个都没有。
/// 于是消费方只能把「缺键」当成 false / 当成「没截断」，
/// 而 deep 恰恰是最容易误读口径的条目（`+100` 在这里是仓库总数，不是本轮新增）。
///
/// ⚠️ 这里还踩过一个更隐蔽的坑：`store.cj` 里那条**手搓的 deep 夹具**
/// 偏偏把三个字段都写全了，于是夹具比现实更完整 ——
/// 用夹具测形状永远测不出「真实路径漏写」。
/// 所以本测试必须走真实的 `runDeep`。
@Test
func testDeepEntryAlwaysCarriesItsScopeAndTruncationFields(): Unit {
    let base = "/tmp/deepgit-deepscope-${nowMillis()}"
    let testHome = "${base}-home"
    let repo = "${base}/repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-q", "-b", "main"], false)
    writeFileAtomic("${repo}/README.md", "# x\n")
    writeFileAtomic("${repo}/a.py", "1\n")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "i"], false)
    enterTestHome(testHome)
    try {
        let p = ProjectEntry("p_deepscope", "ds", repo, "git", "", nowIso(), ArrayList<String>(), false)
        let r = runDeep(p, Config.defaults(), DeepOptions())
        let e = r.journalEntry

        // 口径：deep 装的是仓库提交总数
        @Assert(Json.strAt(e, "commitCountScope", "") == "repoTotal")
        @Assert(Json.intAt(e, "commitCount", -1) == 1)

        // 三个披露字段必须**在**（恒发），值按约定
        @Assert(Json.has(e, "commitCountTruncated"))
        @Assert(!Json.boolAt(e, "commitCountTruncated", true))
        @Assert(Json.has(e, "branchCountTruncated"))
        @Assert(!Json.boolAt(e, "branchCountTruncated", true))
        @Assert(Json.has(e, "repoBranchCount"))
        // 守卫保证 facts.branches 非空，所以这里必须是真实分支数（1），不是 -1
        @Assert(Json.intAt(e, "repoBranchCount", -99) == 1)

        // 键集不得随 mode 变化：浅更新条目有的键，deep 条目也必须有。
        // 这是「恒发」的可测形式 —— 不是逐个查值，是查**键集一致**。
        @Assert(Json.has(e, "commitCountScope"))
        @Assert(Json.has(e, "commitCount"))
        @Assert(Json.has(e, "id"))
        @Assert(Json.has(e, "at"))
        @Assert(Json.has(e, "mode"))
    } finally {
        exitTestHome()
        removePathIfExists(base)
        removePathIfExists(testHome)
    }
}
