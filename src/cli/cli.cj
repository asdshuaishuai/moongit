// CLI 命令层：解析参数并分派到各模块。
package moongit.cli

import std.collection.*
import std.convert.*
import std.env.*
import moongit.flow.*
import moongit.graph.*
import moongit.kernel.*
import moongit.util.*

public class CliContext {
    public let args: ArrayList<String>
    public var json: Bool = false
    public var quiet: Bool = false
    public var verbose: Bool = false
    public var cwd: String = "."

    public init(args: ArrayList<String>) {
        this.args = args
    }
}

/// 解析全局 flag，返回位置参数
/// `--` 之后的 token 全部按字面量处理（项目名/路径可能以 - 开头）。
func parseFlags(args: ArrayList<String>, ctx: CliContext): ArrayList<String> {
    let positionals = ArrayList<String>()
    var i: Int64 = 0
    var literal = false
    while (i < args.size) {
        let a = args[i]
        if (literal) {
            positionals.add(a)
            i += 1
            continue
        }
        if (a == "--") {
            literal = true
            positionals.add(a)
            i += 1
            continue
        }
        match (a) {
            case "--json" =>
                ctx.json = true
                i += 1
            case "-q" => 
                ctx.quiet = true
                i += 1
            case "--quiet" =>
                ctx.quiet = true
                i += 1
            case "-v" =>
                ctx.verbose = true
                i += 1
            case "--verbose" =>
                ctx.verbose = true
                i += 1
            case "--help" =>
                positionals.add("--help")
                i += 1
            case "-h" =>
                positionals.add("--help")
                i += 1
            case _ =>
                positionals.add(a)
                i += 1
        }
    }
    return positionals
}

/// 取 flag 值（支持 --flag value 与 --flag=value）
/// `--` 之后的 token 是字面量，不参与 flag 查找。
func flagValue(args: ArrayList<String>, name: String): Option<String> {
    var i: Int64 = 0
    for (a in args) {
        if (a == "--") {
            return None
        }
        if (a == name) {
            if (i + 1 < args.size) {
                return Some(args[i + 1])
            }
            return None
        }
        if (a.startsWith("${name}=")) {
            return Some(a[name.size + 1..])
        }
        i += 1
    }
    return None
}

func hasFlag(args: ArrayList<String>, name: String): Bool {
    for (a in args) {
        if (a == "--") {
            return false
        }
        if (a == name || a.startsWith("${name}=")) {
            return true
        }
    }
    return false
}

/// 参数中用 -- 分隔后要剔除 flag 对
///
/// `--` 之后一律按字面量处理。以前 `--` 只是被当成一个无值 flag 跳过，
/// 后面仍然是 flag 空间，于是 `moongit update -- --note "v2"` 里的 --note
/// 照样被解析成 flag，项目名/路径以 `-` 开头时根本没有表达方式。
func positionalsOnly(args: ArrayList<String>, valueFlags: Array<String>): ArrayList<String> {
    let out = ArrayList<String>()
    var i: Int64 = 0
    var literal = false
    while (i < args.size) {
        let a = args[i]
        if (literal) {
            out.add(a)
            i += 1
            continue
        }
        if (a == "--") {
            literal = true
            i += 1
            continue
        }
        if (a.startsWith("--") || (a.startsWith("-") && a.size == 2 && !isNumericLike(a))) {
            var needsValue = false
            for (vf in valueFlags) {
                if (a == vf) {
                    needsValue = true
                }
            }
            if (needsValue) {
                i += 2
            } else {
                i += 1
            }
        } else {
            out.add(a)
            i += 1
        }
    }
    return out
}

func isNumericLike(s: String): Bool {
    return s.size > 1 && s[1] >= 0x30u8 && s[1] <= 0x39u8
}

public func main2(argv: ArrayList<String>): Int64 {
    let ctx = CliContext(argv)
    var positionals = parseFlags(argv, ctx)
    validateKnownFlags(positionals)
    validateValueFlags(positionals)
    Log.setQuiet(ctx.quiet)
    Log.setVerbose(ctx.verbose)
    if (ctx.json) {
        Log.setColor(false)
    }
    // ⚠️ M20：界面语言必须在**任何文案渲染之前**落到 util 的那个进程级信号上。
    // 下沉到 util 是因为 util 自己的错误/告警也是用户可见的（internalErrorMessage /
    // execCapture 超时 / removePathIfExists），而 util 是叶子层、拿不到 cli 的 T()。
    // 漏了这一步的症状很安静：数据层按 config.language 出英文，util 层的错误仍是中文。
    try {
        setUiLanguage(loadConfig().language)
    } catch (e: Exception) {
        // 配置读不出来不让语言信号拦住命令：回落默认（中文）继续跑，
        // 真正的配置错误会在各自的命令里再报一次。
        setUiLanguage("zh")
    }

    if (positionals.size == 0) {
        printHelp()
        return 0
    }
    let command = positionals[0]
    let rest = ArrayList<String>()
    for (i in 1..positionals.size) {
        rest.add(positionals[i])
    }

    match (command) {
        case "--help" => printHelp(); return 0
        case "help" => printHelp(); return 0
        case "version" => printOut("moonGit Engine 0.1.0 (Cangjie 1.0.5 LTS)"); return 0
        case "list" => return cmdList(rest, ctx)
        case "add" => return cmdAdd(rest, ctx)
        case "remove" => return cmdRemove(rest, ctx)
        case "scan" => return cmdScan(rest, ctx)
        case "status" => return cmdStatus(rest, ctx)
        case "track" => return cmdTrack(rest, ctx)
        case "update" => return cmdUpdate(rest, ctx)
        case "deep" => return cmdDeep(rest, ctx)
        case "journal" => return cmdJournal(rest, ctx)
        case "hook" => return cmdHook(rest, ctx)
        case "config" => return cmdConfig(rest, ctx)
        case "doctor" => return cmdDoctor(rest, ctx)
        case "verify" => return cmdVerify(rest, ctx)
        case "milestone" => return cmdMilestone(rest, ctx)
        case "git" => return cmdGit(rest, ctx)
        case "dashboard" => return cmdDashboard(rest, ctx)
        case "mcp" => return mcpRun()
        case "context" => return cmdContext(rest, ctx)
        case "docs" => return cmdDocs(rest, ctx)
        case "tools" => return cmdTools(rest, ctx)
        case "skill" => return cmdSkill(rest, ctx)
        case "report" => return cmdReport(rest, ctx)
        case "graph" => return cmdGraph(rest, ctx)
        case _ =>
            Log.error(T("Unknown command: ${command}", "未知命令：${command}"))
            printHelp()
            return 2
    }
}


let HOOK_KINDS: Array<String> = ["post-commit", "post-merge"]

/// 所有带值的 flag（positionalsOnly 据此跳过 flag 及其值，避免值被当成位置参数）
// 带值 flag 全集：positionalsOnly 据此剔除「flag 及其值」，避免值被当成项目名；
// validateValueFlags 据此要求每个带值 flag 必须真的带值。
// ⚠️ 维护要求：本清单必须与 `flagValue("…")` 的调用点保持一致。
// 新增任何 `flagValue(x, "--foo")` 时必须同步加到此处，否则 --foo 的值会被 resolveTargets
// 当成项目名（表现为「未找到项目：<flag 的值>」；若该值恰好是某项目名的子串，
// 还会被 findProjectIn 的子串兜底静默解析成另一个项目），且缺值不会被拦下。
let VALUE_FLAGS: Array<String> = [
    "--name", "--depth", "--docs", "--scope", "--branch", "--port",
    "--source", "--tag", "--date", "--desc", "--out", "--message", "--budget",
    "--dir", "--limit", "--note", "--host", "--format", "--patch",
]

/// 全部 CLI flag 白名单：全局 + 带值 + 布尔。
///
/// ⚠️ 维护要求：新增任何 flag 必须同时加进这里，否则用户一用就报「未知 flag」。
/// 布尔 flag 分散在各命令里（hasFlag 调用点），这里按「值一次也不改」的约定手工枚举。
///
/// 已知取舍：这是**全局**白名单，不是 per-command 的。所以 `report --purge` 会被接受
/// （--purge 对 remove 有效），只是被忽略 —— 它抓的是拼写错误（--limti / --dryrun /
/// --jsonn），那才是真正会静默跑错参数的场景。做成 per-command 需要为 20 个命令
/// 各维护一张表，收益不抵维护成本。
let KNOWN_FLAGS: Array<String> = [
    // 全局（parseFlags）
    "--json", "-q", "--quiet", "-v", "--verbose", "--help", "-h",
    // 带值（与 VALUE_FLAGS 一致）
    "--name", "--depth", "--docs", "--scope", "--branch", "--port",
    "--source", "--tag", "--date", "--desc", "--out", "--message", "--budget",
    "--dir", "--limit", "--note", "--host", "--format", "--patch",
    // 布尔
    "--dry-run", "--git-only", "--open", "--purge",
    // confidence 专用（被动能力开关）
    "--no-ast", "--llm", "--skill", "--merge",
]

/// token 是否长得像 flag。负数（-5）不是 flag。
private func looksLikeFlag(s: String): Bool {
    if (s.startsWith("--")) {
        return true
    }
    return s.startsWith("-") && s.size == 2 && !isNumericLike(s)
}

/// 未知 flag 必须报错。
///
/// 旧实现里未知 flag 落进 positionals 后被 positionalsOnly 无声丢弃：
/// `moongit status --bogus` 照常 exit 0，`--limti 5` 照常用默认 20 条。
/// 打错一个字母的结果是「命令成功执行，但用的是默认值」—— 自动化脚本里最难查的一类。
func validateKnownFlags(args: ArrayList<String>): Unit {
    for (a in args) {
        if (a == "--") {
            return
        }
        if (!looksLikeFlag(a)) {
            continue
        }
        // --flag=value 形式：只校验 flag 名
        var name = a
        match (a.indexOf("=")) {
            case Some(eq) => name = a[..eq]
            case None => ()
        }
        if (!KNOWN_FLAGS.contains(name)) {
            throw DgError.usage(T("Unknown flag: ${a} (run moongit --help for supported options; when a value starts with -, use --flag=value)", "未知 flag：${a}（moongit --help 查看支持的参数；值以 - 开头时用 --flag=值 形式）"))
        }
    }
}

/// 带值 flag 必须紧跟一个真正的值，缺值一律报错，不允许静默取到下一个 flag。
///
/// 旧实现里 flagValue() 只看下一个 token，于是 `moongit add <path> --name --note`
/// 会把 "--note" 当成项目名写进 registry（已实证：项目真的被注册成 "--note"）；
/// 而 `moongit report --out` 缺值时静默回落到默认路径，用户以为指定了输出位置。
/// 报错文案引导改用 `--flag=值` 形式 —— 该形式是单个 token，不受此校验影响，
/// 因此确实需要传 `--` 开头的值时仍然可用。`--` 之后的 token 是字面量，不校验。
func validateValueFlags(args: ArrayList<String>): Unit {
    var i: Int64 = 0
    while (i < args.size) {
        let a = args[i]
        if (a == "--") {
            return
        }
        var isValueFlag = false
        for (vf in VALUE_FLAGS) {
            if (a == vf) {
                isValueFlag = true
            }
        }
        if (isValueFlag) {
            if (i + 1 >= args.size) {
                throw DgError.usage(T("${a} is missing a value (if the value itself starts with -, use ${a}=value)", "${a} 缺少取值（值确实以 - 开头时用 ${a}=值 形式）"))
            }
            if (args[i + 1].startsWith("--")) {
                throw DgError.usage(T("${a} is missing a value (the next argument is a flag: ${args[i + 1]}; if it really is the value, use ${a}=${args[i + 1]})", "${a} 缺少取值（下一个参数是 flag：${args[i + 1]}；若确为取值请用 ${a}=${args[i + 1]} 形式）"))
            }
        }
        i += 1
    }
}

func cmdGit(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    if (refs.size == 0) {
        throw DgError.usage(T("Usage: moongit git <pull|push|commit|stash|unstash|fetch> [project] [--message M]", "用法：moongit git <pull|push|commit|stash|unstash|fetch> [项目] [--message M]"))
    }
    let op = refs[0]
    var message = ""
    match (flagValue(rest, "--message")) {
        case Some(v) => message = v
        case None => ()
    }
    // 去掉操作词，resolveTargets 只应看到项目引用
    let restNoOp = ArrayList<String>()
    var skipped = false
    for (a in rest) {
        if (!skipped && a == op) {
            skipped = true
            continue
        }
        restNoOp.add(a)
    }
    let targets = resolveTargets(restNoOp, false)
    var failed = false
    // ⚠️ 收集而不是就地打印：旧实现在项目循环里逐个 printOut，于是
    // `moongit git log`（不指定项目 → 全部项目）输出 N 份首尾相接的 JSON 文档，
    // 整份 stdout 非法，任何 JSONDecoder 都解不出来。
    // 单项目正常、一多项目就崩，症状是「偶发」，最难查。
    let gitResults = ArrayList<JsonValue>()
    for (p in targets) {
        try {
            let r = runGitOp(p.path, op, message)
            if (!r.ok) {
                // 失败必须体现在退出码上，与是否 --json 无关。
                // 原实现在 --json 分支只打印结果、不置 failed，于是
                // `git push` 被拒也返回 0，CI/脚本会把失败当成功。
                failed = true
            }
            if (ctx.json) {
                let o = r.toJson()
                Json.set(o, "project", Json.of(p.name))
                gitResults.add(o)
            } else if (r.ok) {
                if (!ctx.quiet) {
                    Log.ok(T("${p.name}: ${op} done", "${p.name}：${op} 完成"))
                    if (!r.output.isEmpty()) {
                        printOut(r.output)
                    }
                }
            } else {
                Log.error(T("${p.name}: ${op} failed", "${p.name}：${op} 失败"))
                if (!r.output.isEmpty()) {
                    printOut(r.output)
                }
            }
        } catch (e: Exception) {
            failed = true
            if (ctx.json) {
                // 异常路径也必须产出 JSON：原来只走 Log.error（stderr），
                // --json 下 stdout 完全是空的，调用方连失败原因都拿不到。
                let o = Json.obj()
                Json.set(o, "op", Json.of(op))
                Json.set(o, "ok", Json.of(false))
                Json.set(o, "output", Json.of(e.message))
                Json.set(o, "project", Json.of(p.name))
                gitResults.add(o)
            } else {
                Log.error("${p.name}: ${e.message}")
            }
        }
    }
    if (ctx.json) {
        printMultiProjectJson(gitResults)
    }
    return if (failed) { 1 } else { 0 }
}

/// 改完状态后**回读**实际生效的状态。**纯函数**。
///
/// 为什么必须回读而不是报「请求写入的状态」：
/// reopen 把 status 写回 open 后，若同名/绑定 tag 仍存在，
/// milestoneProgress 会按「tag 达成即自动完成」把它算回 done ——
/// 这时报「→ open」等于报告了一个根本没有生效的结果。
///
/// 实测（里程碑绑 tag v9.9 且该 tag 已达成，手动 reopen）：
///     CLI : {"requested":"open","status":"done","applied":false}   ← 如实说
///     HTTP: 409 + {"applied":false}                               ← 如实说
///     MCP : {"text":"自动完成 → open","isError":false}            ← 谎报，且 isError=false
/// MCP 侧原实现只回 setMilestoneStatus 的返回值，恒成功即报成功。
/// 三个出口里只有 MCP 还留着这个缺陷。
///
/// 抽成纯函数是因为三个出口要共用；内联在任一处都会重演「抄多处漏一处」。
func effectiveMilestoneStatus(project: ProjectEntry, name: String, requested: String): String {
    var effective = requested
    for (m in milestonesFor(project.id)) {
        if (m.name == name) {
            effective = milestoneProgress(m, project.path, "").effectiveStatus
        }
    }
    return effective
}

func cmdMilestone(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    let msl = loadConfig().language
    if (refs.size == 0) {
        throw DgError.usage(T("Usage: moongit milestone <add|list|done|reopen|drop|remove> [project] [name] [--tag T] [--date YYYY-MM-DD] [--desc S]", "用法：moongit milestone <add|list|done|reopen|drop|remove> [项目] [名称] [--tag T] [--date YYYY-MM-DD] [--desc S]"))
    }
    // ⚠️ #196：各子命令原来只查「至少 3 个」，多出来的位置参数被静默吞掉
    // （`moongit milestone add alpha v1 extra` → 「✓ 已创建」rc=0，extra 蒸发）。
    // 里程碑的元数是**固定**的（项目 + 名称），第 4 个参数不可能有别的含义，
    // 吞掉它等于把拼写错误变成一次「成功」。
    //
    // ⚠️ M17：上限不能对所有子命令统一取 3 —— `list` 只消费 2 个（动作 + 项目），
    // 第 3 个位置参数在 list 下没有含义，照样被吞成 rc=0
    // （实测 `milestone list alpha extra` → 正常列出 alpha 的里程碑，extra 蒸发）。
    // 上限必须按**子命令实际消费的个数**给，否则那道守卫只挡 add 那一支。
    func milestoneMaxPositionals(action: String): Int64 {
        // list：动作 + 项目（名称不参与筛选）
        if (action == "list") {
            return 2
        }
        // add / done / drop / remove / reopen：动作 + 项目 + 名称
        return 3
    }
    rejectExtraPositionals("milestone ${refs[0]}", refs, milestoneMaxPositionals(refs[0]))
    let action = refs[0]
    match (action) {
        case "add" =>
            if (refs.size < 3) {
                throw DgError.usage(T("Usage: moongit milestone add <project> <name> [--tag T] [--date YYYY-MM-DD] [--desc S]", "用法：moongit milestone add <项目> <名称> [--tag T] [--date YYYY-MM-DD] [--desc S]"))
            }
            let p = requireProject(refs[1])
            let name = refs[2]
            let tag = match (flagValue(rest, "--tag")) {
                case Some(v) => v
                case None => ""
            }
            let date = match (flagValue(rest, "--date")) {
                case Some(v) => v
                case None => ""
            }
            let desc = match (flagValue(rest, "--desc")) {
                case Some(v) => v
                case None => ""
            }
            let (m, created) = addMilestone(p.id, name, desc, date, tag)
            if (ctx.json) {
                let o = Json.obj()
                Json.set(o, "project", Json.of(p.name))
                Json.set(o, "milestone", m.toJson())
                Json.set(o, "created", Json.of(created))
                printOut(Json.pretty(o))
            } else {
                if (created) {
                    Log.ok(T("${p.name}: milestone ${name} created", "${p.name}：里程碑「${name}」已创建"))
                } else {
                    Log.warn(T("${p.name}: milestone ${name} already exists", "${p.name}：里程碑「${name}」已存在"))
                }
            }
            return 0
        case "list" =>
            let target: Option<ProjectEntry> = if (refs.size >= 2) { Some(requireProject(refs[1])) } else { Option<ProjectEntry>.None }
            let projects = ArrayList<ProjectEntry>()
            match (target) {
                case Some(p) => projects.add(p)
                case None =>
                    for (p in loadRegistry().projects) {
                        projects.add(p)
                    }
            }
            let items = ArrayList<JsonValue>()
            // 读一次、带健康度，避免下面 milestonesFor 再读一遍把健康度丢掉
            let (allMs, msHealth) = loadMilestonesChecked()
            let sel = milestoneListSelection(projects, allMs)
            let excludedDisabled = sel.excludedDisabled
            let orphans = sel.orphans
            for (m in sel.matched) {
                let mp = m[0]
                let ms = m[1]
                items.add(milestoneJson(mp, milestoneProgress(ms, mp.path, "")))
            }

            let msLabel = storeHealthLabel(msHealth)
            if (ctx.json) {
                let arr = JArr(items)
                let o = Json.obj()
                Json.set(o, "milestones", arr)
                // 恒发：空数组 + storeHealth=corrupt 与「真的没有里程碑」
                // 在下游必须能被区分开，否则客户端会显示「还没设里程碑」
                Json.set(o, "storeHealth", Json.of(msLabel))
                Json.set(o, "readCount", Json.of(allMs.size))
                // 孤儿必须进 envelope。客户端若只渲染 milestones 数组，
                // 就会继续对用户说「你没有里程碑」。
                let orphanArr = ArrayList<JsonValue>()
                for (m in orphans) {
                    let oj = Json.obj()
                    Json.set(oj, "id", Json.of(m.id))
                    Json.set(oj, "projectId", Json.of(m.projectId))
                    Json.set(oj, "name", Json.of(m.name))
                    Json.set(oj, "description", Json.of(m.description))
                    Json.set(oj, "targetDate", Json.of(m.targetDate))
                    Json.set(oj, "status", Json.of(m.status))
                    Json.set(oj, "orphaned", Json.of(true))
                    orphanArr.add(oj)
                }
                Json.set(o, "orphaned", JArr(orphanArr))
                // 已停用项目的条数恒发，与 dashboard.counts.excludedDisabled 同名同义。
                // 少了它，客户端同时读这两个接口时会拿到
                // 「列表 2 条 / dashboard 进行中 1」这种互相矛盾的结论而无法解释。
                Json.set(o, "excludedDisabled", Json.of(excludedDisabled))
                printOut(Json.pretty(o))
                // 存储损坏时不能 exit 0：与「没有里程碑」在退出码上必须可区分
                return (if (msLabel == "ok") { 0 } else { 1 })
            }
            // 「列不出来」不能被说成「不存在」。四种看起来都是 0 的情况分开处理。
            let (emptyLine, emptyRc) = milestoneEmptyState(items.size, orphans.size, msLabel, excludedDisabled, msl)
            if (!emptyLine.isEmpty()) {
                printOut(emptyLine)
                if (msLabel != "ok") {
                    Log.error(T("milestones.json is unreadable (a .corrupt copy has been kept). Writes are rejected; restore the file, or delete it after confirming.", "milestones.json 读不出来（已留 .corrupt 副本）。写操作会被拒绝，先恢复或确认后删除该文件。"))
                }
                return emptyRc
            }
            for (it in items) {
                printOut(milestoneLine(it, msl))
            }
            if (excludedDisabled > 0) {
                Log.info(T("${excludedDisabled} milestones belong to disabled projects and are not listed (same rule as dashboard).", "${excludedDisabled} 条里程碑属于已停用项目，未列出（与 dashboard 同口径）。"))
            }
            if (!orphans.isEmpty()) {
                Log.warn(T("${orphans.size} milestones point to deregistered projects and cannot be listed (data still in milestones.json):", "${orphans.size} 条里程碑指向已取消注册的项目，列不出来（数据仍在 milestones.json 里）："))
                for (m in orphans) {
                    Log.info("  ${m.name}（projectId=${m.projectId}）")
                }
                Log.info(T("  Re-register the same path to show them again; to delete for good, run moongit milestone remove <project> <milestone>", "  重新注册同一路径即可恢复显示；确认要删就用 moongit milestone remove <项目> <里程碑>"))
            }
            return 0
        case "done" | "drop" | "reopen" =>
            if (refs.size < 3) {
                throw DgError.usage(T("Usage: moongit milestone ${action} <project> <name>", "用法：moongit milestone ${action} <项目> <名称>"))
            }
            let p = requireProject(refs[1])
            let status = match (action) {
                case "done" => "done"
                case "drop" => "dropped"
                case _ => "open"
            }
            if (!setMilestoneStatus(p.id, refs[2], status)) {
                if (ctx.json) {
                    printOut(Json.pretty(errJson("MILESTONE_NOT_FOUND", T("Milestone not found: ${refs[2]}", "未找到里程碑：${refs[2]}"))))
                } else {
                    Log.error(T("${p.name}: milestone not found: ${refs[2]}", "${p.name}：未找到里程碑「${refs[2]}」"))
                }
                return 1
            }
            // 报告「实际生效状态」而不是「请求写入的状态」。见 effectiveMilestoneStatus。
            let effective = effectiveMilestoneStatus(p, refs[2], status)
            if (ctx.json) {
                // 这组动作以前在 --json 下什么都不输出（stdout 空），
                // 调用方连是否成功都判断不了。
                let o = Json.obj()
                Json.set(o, "project", Json.of(p.name))
                Json.set(o, "milestone", Json.of(refs[2]))
                Json.set(o, "requested", Json.of(status))
                Json.set(o, "status", Json.of(effective))
                Json.set(o, "applied", Json.of(effective == status))
                printOut(Json.pretty(o))
                return 0
            }
            if (effective == status) {
                // 叙述层：--quiet 门控它是对的
                if (!ctx.quiet) {
                    Log.ok(T("${p.name}: milestone ${refs[2]} -> ${status}", "${p.name}：里程碑「${refs[2]}」→ ${status}"))
                }
            } else {
                // ⚠️ 这一支不能被 --quiet 吞掉。
                // 原来 `if (!ctx.quiet) { if (...) ok else warn }` 把两种结果
                // 一起关掉了，于是 `moongit milestone set X done -q` 在
                // 「写入没生效」时**什么都不打**、退出码仍是 0 ——
                // 用户以为里程碑达成，实际被 tag 规则压回 open。
                // 这不是日志安静，是谎报结果。
                // 告警留在告警通道（Log.warn 本身也不再受 quiet 门控），
                // 让「--quiet 下仍要如实告知数据/环境有问题」成为全局一致的行为。
                Log.warn(T("${p.name}: wrote ${status}, but ${refs[2]} remains effectively ${effective} (a same-name tag exists; the tag-reached-auto-completes rule applies)", "${p.name}：已写入 ${status}，但「${refs[2]}」当前生效状态仍是 ${effective}（同名 tag 已存在，按「tag 达成即自动完成」规则判定）"))
            }
            return 0
        case "remove" =>
            if (refs.size < 3) {
                throw DgError.usage(T("Usage: moongit milestone remove <project> <name>", "用法：moongit milestone remove <项目> <名称>"))
            }
            let p = requireProject(refs[1])
            if (!removeMilestone(p.id, refs[2])) {
                if (ctx.json) {
                    printOut(Json.pretty(errJson("MILESTONE_NOT_FOUND", T("Milestone not found: ${refs[2]}", "未找到里程碑：${refs[2]}"))))
                } else {
                    Log.error(T("${p.name}: milestone not found: ${refs[2]}", "${p.name}：未找到里程碑「${refs[2]}」"))
                }
                return 1
            }
            if (ctx.json) {
                let o = Json.obj()
                Json.set(o, "project", Json.of(p.name))
                Json.set(o, "milestone", Json.of(refs[2]))
                Json.set(o, "removed", Json.of(true))
                printOut(Json.pretty(o))
                return 0
            }
            if (!ctx.quiet) {
                Log.ok(T("${p.name}: milestone ${refs[2]} deleted", "${p.name}：里程碑「${refs[2]}」已删除"))
            }
            return 0
        case _ =>
            throw DgError.usage(T("Unknown milestone subcommand: ${action}", "未知 milestone 子命令：${action}"))
    }
}

// 里程碑条目的 JSON 形状已下沉到 kernel.milestoneJson ——
// 三个出口（milestone list / dashboard / MCP list_milestones）共用它。
// 别在这里再写一份：dashboard 之前就因为手抄第三份栽过两次。

func milestoneLine(it: JsonValue, lang: String): String {
    let name = Json.strAt(it, "name", "")
    let proj = Json.strAt(it, "projectName", "")
    let status = Json.strAt(it, "status", "")
    let date = Json.strAt(it, "targetDate", "")
    let days = Json.intAt(it, "daysToTarget", -1)
    let commits = Json.intAt(it, "commitsSince", 0)
    let tagReached = Json.boolAt(it, "tagReached", false)
    let overdue = Json.boolAt(it, "overdue", false)
    // M15 残留：本行被 milestone list 与 dashboard 文本路径直接打印，
    // 原先整行硬编码中文 —— DEEPGIT_LANG=en 下表头英文、行内容中文同屏。
    let statusLabel = match (status) {
        case "done" => tl(lang, "✓ done", "✓ 已达成")
        case "dropped" => tl(lang, "✗ dropped", "✗ 已放弃")
        // 仓库读不出来 ≠ 没达成。这两种混同会让「系统坏了」被读成「进度没了」。
        case "unknown" => tl(lang, "? unverifiable (repo unreadable)", "? 无法核验（仓库读不出来）")
        case _ => if (overdue) { tl(lang, "⚠ overdue", "⚠ 已逾期") } else { tl(lang, "in progress", "进行中") }
    }
    var when = ""
    if (!date.isEmpty()) {
        // ⚠️ days == -1 是「未设置**或日期无效**」，绝不能掉进 else 变成
        // 「逾期 1 天」—— 那是在为一个不存在的日子编一个精确的天数。
        // 修 #180 之前这里会显示「逾期 212 天」（2026-02-31 被 clamp 后的结果），
        // 修完 isIsoDate 变成 -1，不补这一档就会变成「逾期 1 天」：假数字没了，
        // 假断言还在。
        when = if (days == -1) {
            tl(lang, "target ${date} (invalid date, cannot count remaining days)", "目标 ${date}（日期无效，算不出还剩天数）")
        } else if (days >= 0) {
            tl(lang, "target ${date} (${days} days left)", "目标 ${date}（还剩 ${days} 天）")
        } else {
            tl(lang, "target ${date} (${-days} days overdue)", "目标 ${date}（逾期 ${-days} 天）")
        }
    }
    let tagPart = if (tagReached) { "tag ✓" } else { "" }
    let parts = ArrayList<String>()
    parts.add("${proj}｜${name}")
    parts.add(statusLabel)
    if (!when.isEmpty()) {
        parts.add(when)
    }
    if (commits >= 0) {
        parts.add(tl(lang, "${commits} commits since creation", "创建以来 ${commits} 提交"))
    } else {
        // -1 是「没查出来」。说成 0 或者干脆不提，用户会以为这个里程碑
        // 创建以来一个提交都没有 —— 而实际上我们只是查不到。
        parts.add(tl(lang, "commits since creation unknown", "创建以来提交数未知"))
    }
    if (tagReached) {
        parts.add(tagPart)
    }
    let sb = StringBuilder()
    var i: Int64 = 0
    for (pt in parts) {
        if (i > 0) {
            sb.append(" · ")
        }
        sb.append(pt)
        i += 1
    }
    return sb.toString()
}

/// 报告默认文件名：同一天内两次生成绝不重名。
///
/// 旧实现用 nowMillis() % 100000 做后缀，而该值每 100 秒回绕一次 —— 相隔 100 秒、
/// 毫秒偏移相同的两次生成会得到完全相同的文件名，后一次静默覆盖前一份。
/// 定时任务按整点/整分跑最容易踩到：每次都写进同一个文件，历史报告全部丢失。
/// 改用完整 epoch 毫秒，并再兜一层定宽序号（与 kernel/docs.cj 的 uniqueBackupPath 同一策略）。
func defaultReportPath(): String {
    let dir = deepgitPath(["reports"])
    let base = "report-${nowIso()[..10]}-${nowMillis()}"
    var candidate = "${dir}/${base}.md"
    var n: Int64 = 2
    while (fileExists(candidate) && n < 100) {
        candidate = "${dir}/${base}-${pad2(n)}.md"
        n += 1
    }
    return candidate
}

func cmdReport(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    let config = loadConfig()
    let reg = loadRegistry()

    // report 一次只出一份报告，第二个项目名以前被静默忽略：
    // 用户以为导出的是两个项目的全景，实际只有第一个，报告里也不会有任何提示。
    if (refs.size > 1) {
        throw DgError.usage(T("report accepts at most one project name (got ${refs.size}: ${joinStrings(refs, " ")})", "report 最多接受一个项目名（收到 ${refs.size} 个：${joinStrings(refs, " ")}）"))
    }
    var targets = ArrayList<ProjectEntry>()
    if (refs.size > 0) {
        targets.add(requireProject(refs[0]))
    } else {
        for (p in reg.projects) {
            if (!p.disabled) {
                targets.add(p)
            }
        }
    }
    if (targets.size == 0) {
        Log.error(T("No registered projects; run moongit scan first", "没有已注册项目，先运行 moongit scan"))
        return 1
    }

    let statuses = allProjectStatuses(targets, config, false)
    // ⚠️ 整群报告时必须传**完整注册表**（缺陷 #184）。
    // 上面 `targets` 已经把 disabled 滤掉了，而 `buildDashboard` 内部
    // （dashboard.cj）本来就会跳过 disabled 做统计 —— 于是把完整列表传进去
    // 既不改变任何统计口径，又让它能报出真实的「注册数 / 已停用数」。
    // 原来传 targets，报告于是把「参与统计的数」标成「已注册」：
    // 停用 1 个后 `list` 说「共 3 个（1 个已停用）」，报告写「已注册 2」。
    //
    // 指定单个项目时仍传 targets：单项目报告的「总数」本来就该是 1。
    let dashProjects = if (refs.size > 0) { targets } else { reg.projects }
    let dash = buildDashboard(dashProjects, config)
    let md = renderReportMarkdown(statuses, dash, config.language)

    var outPath = ""
    match (flagValue(rest, "--out")) {
        case Some(v) => outPath = expandHome(v)
        case None => outPath = defaultReportPath()
    }
    ensureDir(dirname(outPath))
    writeFileAtomic(outPath, md)

    if (ctx.json) {
        let o = Json.obj()
        Json.set(o, "file", Json.of(outPath))
        Json.set(o, "projects", Json.of(targets.size))
        Json.set(o, "bytes", Json.of(md.size))
        printOut(Json.pretty(o))
    } else {
        Log.ok(T("Report written: ${outPath} (${targets.size} projects)", "报告已生成：${outPath}（${targets.size} 个项目）"))
    }
    // 全部采集失败时不能 exit 0：报告写着「0 个项目」却报成功，调用方无从分辨
    var okCount: Int64 = 0
    for (st in statuses) {
        if (!Json.has(st, "error")) {
            okCount += 1
        }
    }
    return groupExitCode(okCount, statuses.size)
}


/// 把命令行给的项目名**逐个**解析成注册表条目。名字不存在即 NOT_FOUND。
///
/// ⚠️ 这是 #196 的接缝。原来 `cmdDocs` / `cmdRemove` 各写了一份
/// `targets.add(requireProject(refs[0]))` —— **只取第一个**，
/// 其余项目名静默丢弃，退出码还是 0：
///   `moongit docs alpha beta --json` → rc=0，输出只有 alpha 的 envelope
///   `moongit remove alpha beta`      → rc=0，beta 原封不动留在注册表里
/// `remove` 那个尤其恶劣：取消注册是破坏性操作，
/// 「要注销两个、只注销一个、还告诉我成功了」会让用户把 beta 也划掉。
///
/// 抽成纯函数是因为「哪些参数变成了目标」正是缺陷本身，
/// 内联在命令里时运行时抓不到 —— 而它**不需要**打印任何东西就能断言。
func namedTargets(refs: ArrayList<String>): ArrayList<ProjectEntry> {
    let out = ArrayList<ProjectEntry>()
    for (r in refs) {
        out.add(requireProject(r))
    }
    return out
}

/// 位置参数的元数上限检查。**只**用于元数固定的命令（add / milestone）：
/// 多出来的参数不可能有别的含义，吞掉它等于把拼写错误变成一次「成功」。
///
/// 会接受多个项目的命令（docs / remove / status / update / deep / journal / git）
/// 走 `namedTargets` 循环，不该用这个。
func rejectExtraPositionals(action: String, refs: ArrayList<String>, max: Int64): Unit {
    if (refs.size > max) {
        throw DgError.usage(T("${action} accepts at most ${max} positional arguments, got ${refs.size}: ${joinStrings(refs, " ")}", "${action} 最多接受 ${max} 个位置参数，收到 ${refs.size} 个：${joinStrings(refs, " ")}"))
    }
}

func cmdDocs(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    let config = loadConfig()
    let reg = loadRegistry()
    let targets = ArrayList<ProjectEntry>()
    if (refs.size > 0) {
        // ⚠️⚠️ #196：原来这里是 `targets.add(requireProject(refs[0]))` ——
        // **只取第一个**，其余项目名静默丢弃，退出码还是 0。
        // 实测 `moongit docs alpha beta --json`：
        //     rc=0, 输出 = {"project":"alpha","docs":[…],"unreadable":[]}
        // beta 一个字都没出现，也没有任何「已忽略」提示。
        // 用户（和 agent）会以为这就是两个项目的完整答案。
        //
        // 而 docsPayload **本来就是为多项目设计的**（有 project 键 = 单项目
        // envelope，键不在 = 多项目平铺，每条自带 project），
        // 只是从 CLI 上用项目名**永远走不到**那条分支 ——
        // 能走到的只有「不传项目名」那一条。契约在、入口不在。
        //
        // 改成按名单循环：与 status / update / deep / journal / git 一致，
        // 顺带把那条早就写好的平铺契约接上。
        for (e in namedTargets(refs)) {
            targets.add(e)
        }
    } else {
        for (p in reg.projects) {
            if (!p.disabled) {
                targets.add(p)
            }
        }
    }
    printOut(Json.pretty(docsPayload(targets, config)))
    return 0
}

/// 组装 docs JSON payload。抽离打印是为了让契约可被单测直接断言。
/// 每条文档都带 project：不带项目名调用时会把多个项目的文档平铺进同一数组，
/// 消费方无法分辨哪份 README 属于哪个项目（实测 14 个项目 → 22 条同名文件）。
/// envelope 的 project 与 /api/docs 对齐，仅在单项目时给出。
func docsPayload(targets: ArrayList<ProjectEntry>, config: Config): JsonValue {
    let arr = ArrayList<JsonValue>()
    // 读失败的文档按项目分组披露。不能只丢进数组 —— 数组少一条，
    // 消费方看到的就是「这个项目的 README 不存在」。
    let badByProject = ArrayList<JsonValue>()
    for (p in targets) {
        let r = readProjectDocs(p.path, config)
        for (d in r.docs) {
            let e = d.toJson()
            Json.set(e, "project", Json.of(p.name))
            arr.add(e)
        }
        if (!r.unreadable.isEmpty()) {
            let e = Json.obj()
            Json.set(e, "project", Json.of(p.name))
            Json.set(e, "unreadable", Json.of(joinStrings(r.unreadable, ",")))
            badByProject.add(e)
        }
    }
    let o = Json.obj()
    // ⚠️ 这里的条件性是**有意契约**，不是缺陷，不要"顺手修掉"：
    // 有 project 键 = 单项目 envelope，键不在 = 多项目平铺。
    // testDocsPayloadAttributesEveryEntry 明确钉住了它。
    //
    // 我一度按「标志位必须恒发」把它改成恒发（多项目给逗号连接的名单），
    // 结果撞红了上面那条既有测试，理由有二，两条都成立：
    //   1. project 是**身份标识**不是披露标志位。storeHealth/degraded 那条铁律
    //      针对的是「坏的时候才带」的降级标志，不适用于「这个 envelope 关于谁」。
    //   2. 替代方案本身更差：项目名理论上可以含逗号，拼进字符串就不可逆解析了。
    // 恒发反而制造新的歧义 —— 这正是「修一处坏一处」的典型。
    if (targets.size == 1) {
        Json.set(o, "project", Json.of(targets[0].name))
    }
    Json.set(o, "docs", JArr(arr))
    // 键一直存在（空数组），消费方不必区分「没有」和「这个版本还没这个字段」
    Json.set(o, "unreadable", JArr(badByProject))
    return o
}

func cmdContext(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    // 契约：项目不存在必须以非 0 退出，而不是把错误文本塞进 context 字段后返回 exit 0
    // （自动化消费者只能靠字符串匹配才能发现失败）。多余项目名也不再被静默忽略。
    if (refs.size > 1) {
        throw DgError.usage(T("context accepts at most one project name (got ${refs.size})", "context 最多接受一个项目名（收到 ${refs.size} 个）"))
    }
    if (refs.size == 1) {
        requireProject(refs[0])
    }
    var budget: Int64 = AGENT_DEFAULT_BUDGET
    match (flagValue(rest, "--budget")) {
        case Some(v) =>
            try {
                budget = Int64.parse(v)
            } catch (e: Exception) {
                throw DgError.usage(T("--budget expects an integer: ${v}", "--budget 需要整数：${v}"))
            }
            budget = clampAgentBudget(budget)
        case None => ()
    }
    let config = loadConfig()
    let reg = loadRegistry()
    let scope = if (refs.size > 0) { "project" } else { "group" }
    let target = if (refs.size > 0) { refs[0] } else { "" }
    let ctxOut = buildAgentContext(reg.projects, config, scope, target, budget)
    let text = ctxOut.text
    if (ctx.json) {
        let o = Json.obj()
        Json.set(o, "scope", Json.of(scope))
        Json.set(o, "budget", Json.of(budget))
        Json.set(o, "context", Json.of(text))
        printOut(Json.pretty(o))
    } else {
        printOut(text)
    }
    // 全部采集失败时不能 exit 0：agent 拿到的是一段不含任何项目事实的上下文，
    // 却收到「成功」信号，会据此得出「这个项目群是空的」。
    //
    // M18：okCount/listed 由 buildAgentContext 内部那次采集带回。
    // 原来这里**又跑了一遍** allProjectStatuses —— 所有项目的 git 采集开销翻倍，
    // 而且两份结果可能不一致（并发 git 状态变化 ⇒ 退出码与正文对不上）。
    return groupExitCode(ctxOut.okCount, ctxOut.listed)
}

// ------------------------------ 代码图谱（CodeGraph） ------------------------------

/// `moongit graph` —— 代码图谱：符号索引 + 关系树 + 影响面 + 技术架构图。
///
/// 【为什么引擎做这个】codegraph 类产品的核心能力（符号索引、关系树、影响面）
/// 本质是「确定性事实」，正是引擎的职责边界：agent 要理解一个陌生仓库时，
/// 与其让它自己 cat 几十个文件，不如给它一张结构化的图。
/// 词法级粒度如实写进输出（不是语义调用图），不包装。
///
/// 子命令：overview（默认）/ tree / symbol <名> / impact <名> / arch。
/// arch 支持 --format html（Canvas 交互架构图，默认）/ mermaid / dot / json。
func cmdGraph(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let subs = ["overview", "tree", "symbol", "impact", "arch", "confidence", "patchconf"]
    var sub = "overview"
    let args = ArrayList<String>()
    if (rest.size > 0 && subs.contains(rest[0])) {
        sub = rest[0]
        var i: Int64 = 1
        while (i < rest.size) {
            args.add(rest[i])
            i += 1
        }
    } else {
        for (a in rest) { args.add(a) }
    }

    // patchconf --merge：Layer 3 纯 JSON 合并，不需要项目上下文
    if (sub == "patchconf" && hasFlag(args, "--merge")) {
        let mrefs = positionalsOnly(args, VALUE_FLAGS)
        if (mrefs.size != 2) {
            throw DgError.usage(T(
                "Usage: moongit graph patchconf --merge <algorithm.json> <agent.json>",
                "用法：moongit graph patchconf --merge <algorithm.json> <agent.json>"))
        }
        let algText = match (readFileText(mrefs[0])) {
            case Some(t) => t
            case None => throw DgError.usage(T("Cannot read ${mrefs[0]}", "读不了 ${mrefs[0]}"))
        }
        let agText = match (readFileText(mrefs[1])) {
            case Some(t) => t
            case None => throw DgError.usage(T("Cannot read ${mrefs[1]}", "读不了 ${mrefs[1]}"))
        }
        match (Json.parse(algText)) {
            case Some(alg) =>
                match (Json.parse(agText)) {
                    case Some(ag) =>
                        match (mergePatchConfidence(alg, ag)) {
                            case Some(m) =>
                                match (flagValue(args, "--out")) {
                                    case Some(outPath) =>
                                        writeFileAtomic(outPath, Json.pretty(mergedConfidenceJson(m, alg)))
                                        Log.ok(T("Written: ${outPath}", "已写出：${outPath}"))
                                    case None =>
                                        if (ctx.json) {
                                            printOut(Json.pretty(mergedConfidenceJson(m, alg)))
                                        } else {
                                            printOut(mergedConfidenceText(m))
                                        }
                                }
                            case None => throw DgError.usage(T(
                                "Merge failed (malformed inputs)", "合并失败（输入结构不合法）"))
                        }
                    case None => throw DgError.usage("agent.json " + T("is not valid JSON", "不是合法 JSON"))
                }
            case None => throw DgError.usage("algorithm.json " + T("is not valid JSON", "不是合法 JSON"))
        }
        return 0
    }

    let refs = positionalsOnly(args, VALUE_FLAGS)
    let config = loadConfig()
    let en = isEnglish(config.language)

    // 项目解析：symbol / impact 的第二个位置参数是**符号名**，
    // 不能把它塞给 resolveTargets（未注册的符号名会被当成「找不到项目」砸掉）。
    // 项目解析：symbol / impact 的第二个位置参数是**符号名**，
    // 不能把它塞给 resolveTargets（未注册的符号名会被当成「找不到项目」砸掉）。
    // 返回 (项目, 符号名)；符号名只在 symbol/impact 下非 None。
    func resolveGraphProject(): (ProjectEntry, Option<String>) {
        if ((sub == "symbol" || sub == "impact") && refs.size >= 1) {
            if (refs.size >= 2) {
                return (requireProject(refs[0]), Some(refs[1]))
            }
            // 只给符号名：项目从 cwd 推断（与 status 同一条路）
            let cwd = normalizePath(expandHome(getCwd()))
            match (findProject(cwd)) {
                case Some(entry) => return (entry, Some(refs[0]))
                case None => throw DgError.notFound(T(
                    "Current directory is not a registered project; pass <project> <symbol>",
                    "当前目录不属于任何已注册项目；请传 <项目> <符号名>"))
            }
        }
        let targets = resolveTargets(args, false)
        if (targets.size != 1) {
            throw DgError.usage(T(
                "Usage: moongit graph <overview|tree|symbol|impact|arch> [project] [...]; exactly one project required (got ${targets.size})",
                "用法：moongit graph <overview|tree|symbol|impact|arch> [项目] [...]；恰好一个项目（收到 ${targets.size} 个）"))
        }
        return (targets[0], None)
    }
    let (p, symbolArg) = resolveGraphProject()
    let graph = buildGraph(p.path)

    match (sub) {
        case "overview" =>
            if (ctx.json) {
                printOut(Json.pretty(overviewJson(graph)))
            } else {
                printOut(overviewText(graph))
            }
        case "tree" =>
            var depth: Int64 = 6
            match (flagValue(args, "--depth")) {
                case Some(v) =>
                    // L1：原来裸 Int64.parse —— 传 `abc` 抛的异常被顶层兜成
                    // 「内部错误（graph tree）」而不是用法报错。用户打错一个
                    // 参数，读到的却是「引擎内部错误」。同文件 cmdScan 对同一
                    // 参数是正确示范（try/catch → usage）。
                    try {
                        depth = Int64.parse(v.trimAscii())
                    } catch (e: Exception) {
                        throw DgError.usage(T(
                            "--depth expects an integer (got \"${v}\")",
                            "--depth 需要整数（收到 \"${v}\"）"))
                    }
                case None => ()
            }
            // --format：html（默认，Web Canvas 交互代码图谱——与 arch 同纪律：
            // 引擎零实现也能直接导出看）/ text（索引树文本）/ json（与 --json 等价）
            var fmt = "html"
            match (flagValue(args, "--format")) {
                case Some(v) => fmt = v
                case None => ()
            }
            if (fmt == "json" || ctx.json) {
                // M16：`--depth` 原先对 --json 路径完全无效（fullGraphJson 没有
                // 这个参数），于是「同一条命令、同一个参数，两条路径两种行为」。
                // 现在两条路都按 depth 截断，且 JSON 侧恒发 depth / depthOmitted。
                printOut(Json.pretty(fullGraphJson(graph, depth)))
            } else if (fmt == "text") {
                printOut(treeText(graph, depth))
            } else if (fmt == "html") {
                printOut(treeCanvasHtml(graph, depth, false))
            } else {
                throw DgError.usage(T(
                    "tree format accepts html | text | json (got \"${fmt}\")",
                    "tree format 支持 html | text | json（收到 \"${fmt}\"）"))
            }
        case "symbol" =>
            let name = match (symbolArg) {
                case Some(n) => n
                case None => throw DgError.usage(T(
                    "Usage: moongit graph symbol <project> <symbol> (or run inside the project and pass <symbol>)",
                    "用法：moongit graph symbol <项目> <符号名>（或在项目目录内只传 <符号名>）"))
            }
            if (ctx.json) {
                printOut(Json.pretty(symbolJson(graph, name)))
            } else {
                printOut(symbolText(graph, name))
            }
        case "impact" =>
            let name = match (symbolArg) {
                case Some(n) => n
                case None => throw DgError.usage(T(
                    "Usage: moongit graph impact <project> <symbol>",
                    "用法：moongit graph impact <项目> <符号名>"))
            }
            match (impactOf(graph, name)) {
                case Some(res) =>
                    if (ctx.json) {
                        printOut(Json.pretty(impactJson(res)))
                    } else {
                        printOut(impactText(res))
                    }
                case None =>
                    if (ctx.json) {
                        printOut(Json.pretty(Json.obj()))
                    } else {
                        printOut(T(
                            "Symbol not found: ${name} (lexical index covers supported source languages only)",
                            "未找到符号：${name}（词法索引只覆盖支持的源码语言）"))
                    }
                    return 1
            }
        case "patchconf" =>
            // Layer 1：算法层（被动能力：仅显式执行）
            let patchPath = match (flagValue(args, "--patch")) {
                case Some(p) => p
                case None => throw DgError.usage(T(
                    "Usage: moongit graph patchconf <project> --patch <diff> [--skill] [--out F]",
                    "用法：moongit graph patchconf <项目> --patch <diff> [--skill] [--out 文件]"))
            }
            if (hasFlag(args, "--skill")) {
                printOut(patchConfidenceSkill(p.name))
                return 0
            }
            let patchText = match (readFileText(patchPath)) {
                case Some(t) => t
                case None => throw DgError.usage(T(
                    "Cannot read patch: ${patchPath}", "读不了补丁文件：${patchPath}"))
            }
            let pc = analyzePatchConfidence(graph, patchText)
            match (flagValue(args, "--out")) {
                case Some(outPath) =>
                    writeFileAtomic(outPath, Json.pretty(patchConfidenceJson(pc)))
                    Log.ok(T(
                        "Written: ${outPath} (Layer 1 done; next: --skill, then --merge)",
                        "已写出：${outPath}（Layer 1 完成；下一步 --skill，再 --merge）"))
                case None => printOut(Json.pretty(patchConfidenceJson(pc)))
            }
        case "confidence" =>
            // 被动能力：只有用户显式执行才算（不是任何更新流程的一部分）
            var useAst = true
            var wantLlm = false
            if (hasFlag(args, "--no-ast")) { useAst = false }
            if (hasFlag(args, "--llm")) { wantLlm = true }
            let report = analyzeConfidence(graph, useAst)
            if (wantLlm) {
                printOut(confidenceLlmPrompt(report, p.name))
            } else if (ctx.json) {
                printOut(Json.pretty(confidenceJson(report)))
            } else {
                printOut(confidenceText(report))
            }
        case "arch" =>
            let arch = buildArch(graph)
            layoutArch(arch)
            var format = "html"
            match (flagValue(args, "--format")) {
                case Some(v) => format = v.trimAscii()
                case None => ()
            }
            var payload = ""
            if (format == "mermaid") {
                payload = archMermaid(arch, en)
            } else if (format == "dot") {
                payload = archDot(arch, en)
            } else if (format == "json") {
                payload = Json.pretty(archJson(arch, en))
            } else if (format == "html") {
                payload = archCanvasHtml(arch, en)
            } else if (format == "scene") {
                // 场景 JSON（moongit-graph-scene v1）：几何/命中/动画时序的
                // 数据层，供任何标准 Canvas2D API 移植实现驱动渲染
                payload = Json.pretty(buildArchScene(arch, en))
            } else {
                throw DgError.usage(T(
                    "--format accepts html | mermaid | dot | json | scene (got: ${format})",
                    "--format 只支持 html | mermaid | dot | json | scene（收到：${format}）"))
            }
            match (flagValue(args, "--out")) {
                case Some(outPath) =>
                    writeFileAtomic(outPath, payload)
                    Log.ok(T(
                        "Written: ${outPath} (${payload.toArray().size} bytes)",
                        "已写出：${outPath}（${payload.toArray().size} 字节）"))
                case None => printOut(payload)
            }
        case _ =>
            throw DgError.usage(T(
                "Unknown graph subcommand (use overview|tree|symbol|impact|arch)",
                "未知 graph 子命令（可用 overview|tree|symbol|impact|arch）"))
    }
    return 0
}

func cmdTools(rest: ArrayList<String>, ctx: CliContext): Int64 {
    printOut(Json.pretty(agentToolsManifest()))
    return 0
}

let SKILL_FRONTMATTER = "---\nname: moongit\ndescription: 用 moonGit 引擎管理本地 git 项目群的进度与代码：查现状、记进度、浅/深更新文档、git 操作、里程碑，以及代码图谱、架构图（Canvas 契约）、代码置信度与补丁置信度三层体检。适用于任何关于本地项目状态、分支进度、项目文档维护、代码结构与可信度分析的问题。\n---\n\n"

func skillMarkdown(): String {
    let engine = currentExecutable()
    // 接入方式先攒成列表，标题里的「N 种」由列表长度派生。
    // 原来这里硬写「## 三种接入方式」却只列了 MCP + CLI 两条 ——
    // HTTP 删掉后第三种没了，标题没跟着改，agent 读到的就是一个空承诺。
    // 数字跟着列表走，就不会再漂。
    let ways = ArrayList<String>()
    ways.add("**MCP 服务器**（推荐，工具化接入）。宿主配置：\n   ```json\n   "
        + "{\"mcpServers\": {\"moongit\": {\"command\": \"" + engine + "\", \"args\": [\"mcp\"]}}}\n   ```\n   "
        + "工具（23 个，分三组）：\n"
        + "   - 进度管理：list_projects / get_project_context / get_project_status / get_dashboard / get_project_docs / "
        + "get_journal / run_shallow_update / run_deep_update / run_track / git_op / list_milestones / "
        + "milestone_add / milestone_action / add_project\n"
        + "   - 代码图谱：codegraph_overview / codegraph_tree（depth 控制目录深度）/ codegraph_symbol / codegraph_impact / "
        + "codegraph_arch（format=html|mermaid|dot|json|**scene**） / codegraph_confidence（format=json|text|**llm**——可直接喂给模型的逐条复核提示词）\n"
        + "   - 补丁置信度三层：codegraph_patch_confidence（Layer 1 算法分析）→ **你做 Layer 2**（按 `moongit skill print` 的任务书逐条裁决 uncertain）→ "
        + "codegraph_patch_merge（Layer 3 合并出 final 分数）")
    ways.add("**CLI**（一次性问答/脚本）：`" + engine + " status --json`、`context [项目] --budget N`、`tools`、"
        + "`journal <项目>`、`dashboard --json`、"
        + "`graph overview|tree --format html|symbol <名>|impact <名>|arch --format scene|confidence [--llm]|patchconf --patch <diff>`（tree/arch 默认即 Web Canvas 交互图）")
    let sb = StringBuilder()
    sb.append(SKILL_FRONTMATTER)
    sb.append("# moonGit — 本地项目群进度与代码引擎（agent 使用指南）\n\n")
    sb.append("moonGit 是 **AI 无关** 的确定性内核：它提供事实与动作，你（agent）负责理解与表达。\n\n")
    sb.append("## ${ways.size} 种接入方式（按场景选）\n\n")
    for (i in 0..ways.size) {
        sb.append("${i + 1}. ${ways[i]}\n\n")
    }
    sb.append("## 典型任务配方\n\n")
    sb.append("- **项目现状**：get_project_context(name) → 直接总结；要历史再 get_journal\n")
    sb.append("- **项目群周报**：get_group_context → get_dashboard → 按「活跃/风险/建议」输出\n")
    sb.append("- **收尾打扫**：git_op(op=commit, message=…) 提交未提交改动 → run_shallow_update 记进度\n")
    sb.append("- **项目说明文档**：get_project_context + get_project_docs → 生成 markdown 说明\n")
    sb.append("- **改这个函数影响谁**：codegraph_symbol(name, symbol) 看定义与引用 → codegraph_impact(name, symbol) "
        + "拿引用文件清单 → 按影响面给改动顺序（结论是词法级候选，不是编译器闭包，措辞要带上）\n")
    sb.append("- **这段代码可信吗**：codegraph_confidence(name, format=llm) 拿逐条复核提示词自己过一遍，"
        + "或 format=json 看六维度分数与 findings（file:line 证据自足）\n")
    sb.append("- **提交前补丁体检（三层）**：`git diff > /tmp/p.diff` → codegraph_patch_confidence(name, patch_path) "
        + "拿 S1..S10 信号与 uncertain 清单 → 你逐条裁决（confirm/dismiss/unsure，必须引用代码原文）→ "
        + "codegraph_patch_merge(algorithm_json, agent_json) → final 分数与披露\n")
    sb.append("- **架构图给客户端/用户**：codegraph_arch(name, format=scene) 出 moongit-graph-scene v1 JSON "
        + "（主题 token、形状、粒子、hits 点击区、panels 详情面板、逐视图 edgesDropped 截断披露）——"
        + "任何 Canvas2D 移植（浏览器/Swift/Skia）按 docs/graph-scene-schema.md 驱动；format=html 出零依赖单文件交互图\n\n")
    sb.append("## 红线\n\n")
    sb.append("- git_op 只允许白名单操作（pull/push/commit/stash/unstash/fetch），没有 reset/clean/force-push\n")
    sb.append("- 文档更新只发生 moonGit 托管区域内（引擎保证），用户内容逐字节保留\n")
    sb.append("- 引擎是 AI 无关的：所有判断与表达由你完成，引擎只提供事实\n")
    sb.append("- codegraph_* 是词法级近似，不是编译器闭包：对用户表述时必须带「词法级候选」限定，不许说成精确引用\n")
    return sb.toString()
}

func cmdSkill(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    let action = if (refs.size > 0) { refs[0] } else { "print" }
    let md = skillMarkdown()
    match (action) {
        case "print" =>
            printOut(md)
            return 0
        case "install" =>
            var dir = ""
            match (flagValue(rest, "--dir")) {
                case Some(v) => dir = expandHome(v)
                case None => dir = expandHome("~/.zcode/skills/moongit")
            }
            ensureDir(dir)
            let file = dir + "/SKILL.md"
            writeFileAtomic(file, md)
            if (ctx.json) {
                let o = Json.obj()
                Json.set(o, "file", Json.of(file))
                Json.set(o, "bytes", Json.of(md.size))
                printOut(Json.pretty(o))
            } else {
                Log.ok(T("Skill installed: ${file}", "Skill 已安装：${file}"))
            }
            return 0
        case _ =>
            throw DgError.usage(T("Usage: moongit skill <print|install> [--dir D]", "用法：moongit skill <print|install> [--dir D]"))
    }
}

/// dashboard 顶部的项目群行。抽成纯函数是为了能单独测。
///
/// ⚠️ 「共 N 个」必须用 `listed`（注册表里一共多少条），不是 `total`（采集成功数）。
///
/// total / listed / failed 三个字段 JSON 里一直是齐的，**只有这行文本用过 total**：
/// 实测注册 3 个项目、其中 1 个路径失效，文本写「共 2 个」而注册表里有 3 个，
/// 那个坏掉的项目就这么从视野里消失，零披露。
/// 「子集当全量」这一族在 status 修过一次（#115）、summary 修过一次（#125），
/// 这里是第三处 —— 同一个毛病第三次从同一个数据源的另一个出口钻出来。
///
/// 曾经这段是内联在 cmdDashboard 里的，于是数据源侧测得再严也测不到它：
/// 负控把 listed 换回 total，测试照样全绿。判定必须落在能测的纯函数上。
/// 与 T(en, zh) 同义的**参数化**版本：由调用方明确给语言。
///
/// ⚠️ 渲染纯函数一律走它，不走 T()：T() 读的是进程级 uiLang（启动时设一次），
/// 而纯函数的语言来自它的入参 —— 用 T() 会让「传了 lang 却不生效」，
/// 于是测试里传 "en" 拿到中文，而那种失败看起来像判据写错了。
func tl(lang: String, en: String, zh: String): String {
    return if (isEnglish(lang)) { en } else { zh }
}

func dashboardProjectLine(projs: JsonValue, lang: String): String {
    let failed = Json.intAt(projs, "failed", 0)
    let note = if (failed > 0) { tl(lang, " (${failed} unreadable)", "（${failed} 个读取失败）") } else { "" }
    return tl(lang, "Projects: ${Json.intAt(projs, "listed", 0)} total${note} · " +
        "active 7d ${Json.intAt(projs, "active7d", 0)} · " +
        "active 30d ${Json.intAt(projs, "active30d", 0)} · " +
        "with uncommitted changes ${Json.intAt(projs, "dirty", 0)}",
        "项目群：共 ${Json.intAt(projs, "listed", 0)} 个${note} · " +
        "近 7 天活跃 ${Json.intAt(projs, "active7d", 0)} · " +
        "近 30 天活跃 ${Json.intAt(projs, "active30d", 0)} · " +
        "有未提交改动 ${Json.intAt(projs, "dirty", 0)}")
}

/// dashboard 的里程碑行。
///
/// 四个必须说清的区别，缺任何一个都会把「读不出来」/「筛掉了」渲染成「没有」：
///   unknown            —— 仓库读不出来，**不知道**达没达成（不是「没达成」）
///   degraded           —— milestones.json 读不出来，**一条也没读到**（不是「没有里程碑」）
///   excludedDisabled   —— 条目属于已停用项目，**故意不计入**（不是「没这回事」）
///   orphaned           —— 条目指向已删除的项目，**列不出来**（不是「已清理」）
///
/// ⚠️ excludedDisabled 这条是实测出来的口径分裂：同屏里
/// 「项目群：共 1 个」（停用项目被排除）与「里程碑：进行中 2」（停用项目照计）
/// 互相打架，列表里还明写「on2｜已停用项目的里程碑」—— 项目群外的东西。
/// 修完 buildMilestoneOverview 之后，如果不把筛掉的条数说出来，
/// 全停用场景下这行会变成「进行中 0 · 已达成 0 · 已放弃 0」，
/// 用户仍然读成「一个里程碑都没有」。
func dashboardMilestoneLine(counts: JsonValue, lang: String): String {
    var line = tl(lang, "Milestones: open ${Json.intAt(counts, "open", 0)} · done ${Json.intAt(counts, "done", 0)} · dropped ${Json.intAt(counts, "dropped", 0)}",
        "里程碑：进行中 ${Json.intAt(counts, "open", 0)} · 已达成 ${Json.intAt(counts, "done", 0)} · 已放弃 ${Json.intAt(counts, "dropped", 0)}")
    let unknown = Json.intAt(counts, "unknown", 0)
    if (unknown > 0) {
        line = line + tl(lang, " · ⚠ ${unknown} unverifiable (repo unreadable)", " · ⚠ 无法核验 ${unknown}（仓库读不出来）")
    }
    // 认不出来的 status（缺陷 #182）。不披露的话，这行会和下面的列表自相矛盾：
    // 「进行中 1 · 已达成 0 · 已放弃 0」而列表里有 2 条。
    let other = Json.intAt(counts, "other", 0)
    if (other > 0) {
        line = line + tl(lang, " · ⚠ ${other} unrecognized status (counted in no column above)",
            " · ⚠ 状态认不出来 ${other}（没算进上面任何一栏）")
    }
    if (Json.boolAt(counts, "degraded", false)) {
        line = line + tl(lang, " · ⚠ milestones.json ${Json.strAt(counts, "storeHealth", "corrupt")}: milestones unreadable" +
            " (${Json.intAt(counts, "readCount", 0)} read) - the 0 above does not mean none",
            " · ⚠ milestones.json ${Json.strAt(counts, "storeHealth", "corrupt")}，里程碑读不出来" +
            "（读到 ${Json.intAt(counts, "readCount", 0)} 条），上面的 0 不是「没有」")
    }
    let excluded = Json.intAt(counts, "excludedDisabled", 0)
    if (excluded > 0) {
        line = line + tl(lang, " · ${excluded} from disabled projects not counted", " · 已停用项目的 ${excluded} 条未计入")
    }
    let orphaned = Json.intAt(counts, "orphaned", 0)
    if (orphaned > 0) {
        line = line + tl(lang, " · ⚠ ${orphaned} belong to projects that no longer exist", " · ⚠ ${orphaned} 条所属项目已不存在")
    }
    return line
}

/// `milestone list` 选哪几条、以及哪些被排除在外。**纯函数**。
///
/// 抽出来的直接原因：这个判定内联在 cmdMilestone 里时，它的结果只走 stdout
/// printOut，单测**根本捕获不到** —— 于是第一版负控把生产代码里的
/// `if (p.disabled) { continue }` 撤掉，测试照样全绿。
/// 「判定必须抽成可测的纯函数」这条铁律的第 4 次实例
/// （前三次：dashboard 文本口径、journal commitCount、里程碑孤儿判定）。
///
/// 三种「里程碑存在于 milestones.json 但这里列不出来」必须分开，
/// 否则下游只能笼统地理解成「用户一条都没设」：
///   matched           —— 正常列出
///   excludedDisabled  —— 所属项目被停用（还在注册表里，只是 disabled）
///   orphans           —— projectId 在注册表里对不上任何项目（项目被 remove 过）
class MilestoneSelection {
    /// (项目, 里程碑) 对
    let matched: ArrayList<(ProjectEntry, Milestone)>
    let excludedDisabled: Int64
    let orphans: ArrayList<Milestone>

    init(matched: ArrayList<(ProjectEntry, Milestone)>, excludedDisabled: Int64, orphans: ArrayList<Milestone>) {
        this.matched = matched
        this.excludedDisabled = excludedDisabled
        this.orphans = orphans
    }
}

func milestoneListSelection(projects: ArrayList<ProjectEntry>, allMs: ArrayList<Milestone>): MilestoneSelection {
    let matched = ArrayList<(ProjectEntry, Milestone)>()
    var excludedDisabled: Int64 = 0
    // knownIds 收**全部**项目（含已停用），因为它的用途是
    // 「这个 projectId 在注册表里还对不对得上」。
    // 漏掉停用项目的话，它的里程碑会被下面的孤儿判定误收成「所属项目已删除」
    // —— 而项目明明还在。第一版修复正是这么写的，写完立刻发现，已改。
    var knownIds = HashSet<String>()
    for (p in projects) {
        knownIds.add(p.id)
    }
    for (p in projects) {
        if (p.disabled) {
            // 该项目名下有多少条，就排除多少条 —— 不是「一个项目算 1」
            excludedDisabled += Int64(milestonesOf(allMs, p.id).size)
            continue
        }
        for (m in milestonesOf(allMs, p.id)) {
            matched.add((p, m))
        }
    }
    // 孤儿：projectId 在注册表里已经对不上任何项目。
    //
    // 实测 `moongit remove orph` 之后，用户手写的「v1.0 重要里程碑」
    // 数据还在 milestones.json 里，但 milestone list 报「（无里程碑）」exit 0。
    // 用户看到的是「remove 掉的项目，它的里程碑也没了」，
    // 实际是「还在，但每条命令都看不见」。
    let orphans = ArrayList<Milestone>()
    for (m in allMs) {
        if (!knownIds.contains(m.projectId)) {
            orphans.add(m)
        }
    }
    return MilestoneSelection(matched, excludedDisabled, orphans)
}

/// `milestone list` 的空态判定：返回 (要打印的文案, 退出码)。
/// 文案为空串表示「不是空态，什么都不用打印」。
///
/// 抽成纯函数是因为这个判定一旦内联在渲染里，改错了没有任何测试会红 ——
/// 第一版负控把 `orphans.isEmpty()` 去掉，测试照样全绿。
///
/// 四种「看起来都是 0」必须分开：
///   存储坏 + 什么都没读到      → 必须说「一条也没读到」且 exit 1
///   有一条但列不出来（孤儿）    → **不能**说「无里程碑」
///   全部属于已停用项目          → **不能**说「无里程碑」
///   文件里确实一条都没有        → 才可以说「（无里程碑）」
///
/// ⚠️ 停用项目那一条是实测出来的：第一版把说明写成 printOut 之外的一行
/// `Log.info`，结果它走 stderr、空态文案走 stdout，**两个流顺序不可控**，
/// 实测输出是「（2 条属于已停用项目）」在前、「（无里程碑）」在后 ——
/// 用户第一眼读到的仍然那句谎报。必须让这个判定自己产出一行确定的文案。
func milestoneEmptyState(itemCount: Int64, orphanCount: Int64, msLabel: String, excludedDisabled: Int64, lang: String): (String, Int64) {
    if (msLabel != "ok") {
        return (tl(lang, "(milestones.json ${msLabel}: nothing read - that is not \"no milestones\")",
            "（milestones.json ${msLabel}：一条也没读到，不是「没有里程碑」）"), 1)
    }
    if (itemCount > 0 || orphanCount > 0) {
        return ("", 0)
    }
    if (excludedDisabled > 0) {
        // 存储健康 + 读得到 0 条 + 孤儿 0 条 ⇒ 全部里程碑都挂在已停用项目上。
        // 说「无里程碑」等于断言「用户一条都没设」—— 数据明明在 milestones.json 里。
        return (tl(lang, "(${excludedDisabled} milestones belong to disabled projects and are not listed; clear `disabled` in registry.json to show them)",
            "（${excludedDisabled} 条里程碑属于已停用项目，未列出；清掉 registry.json 里的 disabled 即可显示）"), 0)
    }
    return (tl(lang, "(no milestones)", "（无里程碑）"), 0)
}

func cmdDashboard(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let config = loadConfig()
    let reg = loadRegistry()
    let dash = buildDashboard(reg.projects, config)
    // 全部项目采集失败时不能 exit 0：与「没有项目」在退出码上必须可区分
    let dashRc = groupExitCode(Json.intAt(Json.getOr(dash, "projects"), "total", 0),
                               Json.intAt(Json.getOr(dash, "projects"), "listed", 0))
    if (ctx.json) {
        printOut(Json.pretty(dash))
        return dashRc
    }
    let projs = Json.getOr(dash, "projects")
    printOut(dashboardProjectLine(projs, config.language))
    if (Json.intAt(projs, "failed", 0) > 0 && Json.intAt(projs, "total", 0) == 0) {
        Log.error(T("Every project failed to read; all statistics below are empty. Debug one by one: moongit status <project>", "全部项目都读取失败，下面所有统计都是空的。逐个排查：moongit status <项目名>"))
    }
    let work = Json.getOr(dash, "work")
    printOut(T("Working surface: branches ${Json.intAt(work, "branches", 0)} · merge candidates ${Json.intAt(work, "mergeCandidates", 0)} · untracked files ${Json.intAt(work, "untrackedFiles", 0)} · stashes ${Json.intAt(work, "stashes", 0)}", "工作面：分支 ${Json.intAt(work, "branches", 0)} · 待合入分支 ${Json.intAt(work, "mergeCandidates", 0)} · 未跟踪文件 ${Json.intAt(work, "untrackedFiles", 0)} · stash ${Json.intAt(work, "stashes", 0)}"))
    let ms = Json.getOr(dash, "milestones")
    let counts = Json.getOr(ms, "counts")
    printOut(dashboardMilestoneLine(counts, config.language))
    if (Json.boolAt(counts, "degraded", false)) {
        Log.error(T("milestones.json is unreadable (a .corrupt copy has been kept). Writes are rejected; restore the file, or delete it after confirming.", "milestones.json 读不出来（已留 .corrupt 副本）。写操作会被拒绝，先恢复或确认后删除该文件。"))
    }
    let items = Json.arrAt(ms, "items")
    if (items.size > 0) {
        printOut("")
        var shown: Int64 = 0
        for (it in items) {
            if (shown >= 8) {
                printOut(T("  ... ${items.size} in total; full list: moongit milestone list", "  … 共 ${items.size} 条，完整列表：moongit milestone list"))
                break
            }
            printOut("  ${milestoneLine(it, loadConfig().language)}")
            shown += 1
        }
    }
    let langs = Json.arrAt(dash, "languages")
    // ⚠️ 不能只靠 `langs.size > 0` 才打印（#187）：
    // 全部项目语言采集失败时 languages 是空的，于是**整节连同失败披露一起消失** ——
    // 读者只看到一个没有语言分布的仪表盘，完全不知道「没采到」和「没有」是两回事。
    // 这正是不变量 33「不要有内容才发」说的那件事。
    let langFailed = Json.intAt(dash, "languagesFailed", 0)
    if (langs.size > 0 || langFailed > 0) {
        printOut("")
        if (langs.size > 0) {
            let parts = ArrayList<String>()
            var n: Int64 = 0
            for (l in langs) {
                if (n >= 6) {
                    break
                }
                parts.add("${Json.strAt(l, "language", "")} ${Json.intAt(l, "count", 0)}")
                n += 1
            }
            printOut(T("Languages: ${joinStrings(parts, " · ")}", "语言分布：${joinStrings(parts, " · ")}"))
            // 两层截断，两个分母。判定抽成纯函数是因为内联在 printOut 里
            // 改错了不会有任何测试变红 —— 上一版就是内联的。
            for (note in dashboardLanguageNotes(dash, n)) {
                printOut(note)
            }
        } else {
            printOut(T("Languages: (nothing collected from any project)", "语言分布：（未采集到任何项目）"))
            for (note in dashboardLanguageNotes(dash, 0)) {
                printOut(note)
            }
        }
    }
    // ⚠️ 必须返回 dashRc，不能写死 0。
    //
    // 守卫（全部项目采集失败时不能 exit 0）在上面算好了，却只在 `if (ctx.json)`
    // 分支里 return；纯文本路径一路走到这里 return 0，把守卫丢掉了。
    // 而纯文本形式恰恰是**人工使用的默认入口**。
    //
    // 实测（2 个已注册项目目录全部移走）：
    //   dashboard --json  → exit 1   ✓
    //   dashboard          → exit 0   ✗ 谎报成功
    //   status / report / context 两条路径都正确报 1
    return dashRc
}

func printHelp(): Unit {
    if (uiLanguage() == "en") {
        printOut("moonGit Engine - git-based local project progress engine")
        printOut("")
        printOut("Usage: moongit <command> [args] [--json] [-q] [-v]")
        printOut("")
        printOut("Commands:")
        printOut("  list                     List registered projects with a one-line status")
        printOut("  add <path> [--name N]    Register a project")
        printOut("  remove <project> [--purge]  Deregister (--purge also deletes progress data)")
        printOut("  scan [root...] [--depth N] [--git-only]  Discover and register projects (--git-only skips non-git dirs)")
        printOut("  status [project]         Show progress status (writes nothing)")
        printOut("  track [project]          Progress snapshot: record only, never touch docs (for hooks)")
        printOut("  update [project] [--docs S] [--dry-run] [--no-ai]  Shallow update: record branch progress + refresh managed doc sections (S = all|readme|agent, default all)")
        printOut("  deep [project] [--scope S]   Deep update: rewrite overview/architecture/commands/history")
        printOut("  journal [project] [--branch B]  View the progress log")
        printOut("  git <pull|push|commit|stash|unstash|fetch> [project] [--message M]")
        printOut("  hook <install|uninstall|status> [project]  Manage the post-commit hook")
        printOut("  milestone <add|list|done|drop|remove|reopen> ...  Milestone management")
        printOut("  dashboard                Cross-project aggregate dashboard (activity/milestones/languages)")
        printOut("  context [project] [--budget N]  Emit the agent context pack (markdown; budget = char budget)")
        printOut("  docs [project]           Print project README/AGENTS/CLAUDE verbatim (--json)")
        printOut("  tools                    Print the agent tool manifest (JSON)")
        printOut("  mcp                      Run as an MCP server (stdio JSON-RPC; for Claude and other agent hosts)")
        printOut("  skill <print|install>    Print/install the agent Skill pack (--dir for the target directory)")
        printOut("  report [project] [--out F]  Export a Markdown progress report")
        printOut("  graph [overview|tree|symbol|impact|arch|confidence|patchconf] [project]")
        printOut("                           patchconf: patch-level confidence (3-layer: --patch analyze / --skill agent / --merge final)")
        printOut("                           confidence: structural confidence report (--llm for the LLM review prompt; --no-ast skips the syntax-tree layer)")
        printOut("                           Code graph: symbol index / relationship tree / impact /")
        printOut("                           interactive architecture canvas (--format html|mermaid|dot|json|scene)")
        printOut("  config <list|get|set> [k] [v]  Configuration (AI preset, etc.)")
        printOut("  verify [project]         Verify doc integrity (user content untouched)")
        printOut("  doctor                   Environment self-check")
        printOut("")
        printOut("Options:")
        printOut("  --json                   Machine-readable output")
        printOut("  -q, --quiet              Quiet progress output (warnings and errors still go to stderr)")
        printOut("  -v, --verbose            Verbose logging")
        printOut("")
        printOut("Examples:")
        printOut("  moongit scan ~/dev --depth 3        # scan and register a project group")
        printOut("  moongit status                      # status of all projects")
        printOut("  moongit update moonGit              # shallow-update one project")
        printOut("  moongit deep --scope readme         # manually trigger a README deep update")
        printOut("  moongit hook install                # install the post-commit hook")
        printOut("  moongit milestone add myapp v1.0 --tag v1.0.0 --date 2026-12-01")
        printOut("  moongit dashboard                   # group-wide overview")
        printOut("  moongit report --out ~/Desktop/progress.md  # export a report")
        return
    }
    printOut("moonGit Engine — git-based local project progress engine")
    printOut("")
    printOut("用法：moongit <命令> [参数] [--json] [-q] [-v]")
    printOut("")
    printOut("命令：")
    printOut("  list                     列出已注册项目及一句话现状")
    printOut("  add <路径> [--name N]    注册项目")
    printOut("  remove <项目> [--purge]  取消注册（--purge 一并删除进度数据）")
    printOut("  scan [根目录...] [--depth N] [--git-only]  扫描发现项目并注册（--git-only 跳过非 git 目录）")
    printOut("  status [项目]            查看项目进度现状（不写任何文件）")
    printOut("  track [项目]             进度快照：只记录，不改文档（钩子用）")
    printOut("  update [项目] [--docs S] [--dry-run] [--no-ai]  浅更新：记录各分支进度 + 刷新文档进度区域（S = all|readme|agent，默认 all）")
    printOut("  deep [项目] [--scope S]   深度更新：重写 overview/architecture/commands/history")
    printOut("  journal [项目] [--branch B]  查看进度日志")
    printOut("  git <pull|push|commit|stash|unstash|fetch> [项目] [--message M]")
    printOut("  hook <install|uninstall|status> [项目]  管理 post-commit 钩子")
    printOut("  milestone <add|list|done|drop|remove|reopen> …  里程碑管理")
    printOut("  dashboard                跨项目聚合仪表盘（活跃度/里程碑/语言分布）")
    printOut("  context [项目] [--budget N]  输出 agent 上下文包（markdown，budget=字符预算）")
    printOut("  docs [项目]                输出项目 README/AGENTS/CLAUDE 原文（--json）")
    printOut("  tools                    输出 agent 工具清单（JSON）")
    printOut("  mcp                      以 MCP 服务器运行（stdio JSON-RPC；供 Claude 等 agent 宿主接入）")
    printOut("  skill <print|install>    输出/安装 agent Skill 教学包（--dir 指定目录）")
    printOut("  report [项目] [--out F]  导出 Markdown 进度报告")
    printOut("  graph [overview|tree|symbol|impact|arch|confidence|patchconf] [项目]")
    printOut("                           patchconf：补丁级置信度三层架构（--patch 分析 / --skill 取 Agent 任务 / --merge 合并终稿）")
    printOut("                           confidence：代码置信度报告（--llm 出 LLM 复核提示词；--no-ast 跳过语法树层）")
    printOut("                           代码图谱：符号索引/关系树/影响面/技术架构图")
    printOut("                           （arch 用 --format html|mermaid|dot|json|scene；html 为 Canvas 交互图）")
    printOut("  config <list|get|set> [k] [v]  配置（AI 预设等）")
    printOut("  verify [项目]            校验文档完整性（用户内容是否被改动）")
    printOut("  doctor                   环境自检")
    printOut("")
    printOut("选项：")
    printOut("  --json                   机器可读输出")
    printOut("  -q, --quiet              静默进度输出（告警与错误仍会输出到 stderr）")
    printOut("  -v, --verbose            详细日志")
    printOut("")
    printOut("示例：")
    printOut("  moongit scan ~/dev --depth 3        # 扫描并注册项目群")
    printOut("  moongit status                      # 看全部项目现状")
    printOut("  moongit update moonGit              # 浅更新指定项目")
    printOut("  moongit deep --scope readme         # 手动触发 README 深度更新")
    printOut("  moongit hook install                # 装 post-commit 钩子")
    printOut("  moongit milestone add myapp v1.0 --tag v1.0.0 --date 2026-12-01")
    printOut("  moongit dashboard                   # 项目群全景")
    printOut("  moongit report --out ~/Desktop/progress.md  # 导出报告")
}

/// 解析目标项目：给了就用，没给则用 cwd 推断
func resolveTargets(rest: ArrayList<String>, allowAll: Bool): ArrayList<ProjectEntry> {
    let out = ArrayList<ProjectEntry>()
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    if (refs.size > 0) {
        for (r in refs) {
            out.add(requireProject(r))
        }
        return out
    }
    if (allowAll) {
        let reg = loadRegistry()
        for (p in reg.projects) {
            if (!p.disabled) {
                out.add(p)
            }
        }
        return out
    }
    // cwd 推断
    let cwd = normalizePath(expandHome(getCwd()))
    match (findProject(cwd)) {
        case Some(p) => out.add(p)
        case None => throw DgError.notFound(T("Current directory is not part of any registered project (register it with `moongit add .`)", "当前目录不属于任何已注册项目（可用 `moongit add .` 注册）"))
    }
    return out
}

/// 「一个目标都没有」时的处置。
///
/// ⚠️ **只给会做活的命令用**（update / deep）。读路径（status / journal / list /
/// dashboard / report）里「没有项目」是合法答案，必须继续输出合法 JSON 或空表，
/// 把它们改成报错会直接打断客户端的解码契约。
///
/// 旧实现在空注册表下静默 exit 0、stdout 全空：
///   moongit update         → 无任何输出，exit 0
///   moongit update --json  → `[]`，exit 0
///   moongit deep           → 无任何输出，exit 0
/// agent / CI 读到 exit 0 就认定「全部项目已是最新」，于是永远不去跑
/// `scan` / `add`，注册表就一直空着 —— 静默降级成事实性谎言。
/// 同一份「没有目标」的判定散在多个命令里各写一遍也是隐患，
/// 所以收敛成函数（这是「抄多处就漏一处」的第 8 例）。
func requireWorkableTargets(targets: ArrayList<ProjectEntry>): Unit {
    if (!targets.isEmpty()) {
        return
    }
    // 显式点名项目时 resolveTargets 内部已 requireProject 过，
    // 走到这里必然是 allowAll 分支，所以「为空」只有两种成因，且必须分开说
    let reg = loadRegistry()
    if (reg.projects.isEmpty()) {
        throw DgError.notFound(T("No projects registered yet; nothing to process. Run `moongit scan <root>` or `moongit add <path>` first", "尚未注册任何项目，没有可处理的内容；先运行 `moongit scan <根目录>` 或 `moongit add <路径>`"))
    }
    // 全部被停用：同样是「没有活可干」，但成因不同。
    // 笼统说「尚未注册」会让用户去跑一遍 scan，发现还是不行。
    //
    // ⚠️ 这里**不能**建议 `moongit enable` —— 引擎根本没有这个子命令。
    // `disabled` 字段全代码只读不写（registry.cj 只有 `toJson` / 反序列化两处触碰），
    // 唯一能置 true 的途径是手改 registry.json。给一个不存在的命令，
    // 是「静默降级成事实性谎言」的另一种形态：不是没说，是说错了。
    throw DgError.notFound(
        T("${reg.projects.size} projects are all disabled; nothing to process. ", "${reg.projects.size} 个项目全部处于 disabled 状态，没有可处理的项目；") +
        T("Clear the disabled field by hand-editing ${deepgitPath(["registry.json"])}", "该字段只能手工编辑 ${deepgitPath(["registry.json"])} 里的 disabled 来清除") +
        T("(the engine has no enable/disable subcommand)", "（引擎没有 enable/disable 子命令）"))
}

/// dashboard 文本路径的语言分布截断提示。**纯函数**。
///
/// ⚠️ 两层截断，两个分母，都必须写出来。
///
/// 第 1 层：语言种类 Top N。上一段里程碑列表就有「… 共 N 条，完整列表：…」
/// 的现成写法，唯独语言这里只打 6 个就收工，用户会当成「这个项目群只有 6 种语言」。
/// 「上限当全量」这一族的第 14 处。
///
/// 第 2 层：`languagesTruncated` —— 有项目撞了跟踪文件上限，
/// 被丢掉的文件里可能还含整类语言。JSON 路径有该字段，文本路径原先**完全不读**，
/// 于是这个事实只在 --json 下可见。
///
/// report.cj 早就把这两层都写对了（还专门注释预防过）。
/// 同一件事两份拷贝、一份对一份错 —— 「抄多处就漏一处」的第 9 例。
/// 文件上限取自 kernel 的同一个常量，不在此处硬编码。
func dashboardLanguageNotes(dash: JsonValue, shown: Int64): ArrayList<String> {
    let out = ArrayList<String>()
    let total = Json.arrAt(dash, "languages").size
    if (total > shown) {
        out.add("  … 共 ${total} 种语言，此处仅列前 ${shown} 种")
    }
    if (Json.boolAt(dash, "languagesTruncated", false)) {
        out.add("  ⚠ 有项目撞到 ${MAX_TRACKED_FILES} 个跟踪文件的上限，被丢掉的文件里可能还有整类语言")
    }
    // 第 3 层（缺陷 #187）：**采集失败**的项目根本没进这份画像。
    // 这与上面两层完全不同 —— 截断是「看了留一部分」，失败是「压根没看成」。
    // 少了它，失败的项目静默消失，而 languagesTruncated 仍是 false，
    // 等于反过来告诉读者「这份分布是完整的」。
    let failed = Json.intAt(dash, "languagesFailed", 0)
    if (failed > 0) {
        let reasons = Json.arrAt(dash, "languagesFailedReasons")
        var line = "  ⚠ ${failed} 个项目语言采集失败，未计入上面这份分布（不是「这个项目群没有这些语言」）"
        // reasons 是字符串**值**数组，不是对象数组 —— 用 asStr 取，
        // 用 strAt 会去对象里找同名键，结果恒为空串（写错过一次）。
        match (Json.asStr(reasons[0])) {
            case Some(reason) => line += "；原因示例：${reason}"
            case None => ()
        }
        out.add(line)
    }
    return out
}

/// `moongit list` 单行的「现状」列。**纯函数**。
///
/// 抽出来的原因不是洁癖：cmdList 直接 printOut，测试截不到 stdout，
/// 「停用项目有没有被采集」这个判定就只能靠人眼看输出 —— 而这正是
/// 下面这条闸门被漏掉、三个月都没人发现的原因。
///
/// ⚠️ 停用项目**不许**跑 collectFacts。
///
/// 引擎全代码的 disabled 约定是「不参与默认处理」，其余出口都遵守：
/// allProjectStatuses (flow/status.cj:328)、buildDashboard 的语言采样
/// (dashboard.cj:50，注释写明「否则每个 ls-files 都要等满 git 超时」）、
/// report / docs / resolveTargets 各自的 `if (!p.disabled)` 闸门。
/// 只有这里的文本分支漏了，对停用项目照样拉起一串 git 子进程 ——
/// 用户把项目停用掉正是为了让它别被碰（比如路径在网络卷上、故意排除），
/// 而 `list` 每次都去碰一遍。
///
/// 停用项目仍然**要列出来**：`list` 的职责是「注册表里有什么」，
/// JSON 出口也恒发 disabled 字段。区别是必须标出来，
/// 不能让它顶着「暂无新变化」冒充健康项目。
func listRowHeadline(p: ProjectEntry, config: Config): String {
    if (p.disabled) {
        return tl(config.language, "disabled (not collected)", "已停用（不采集）")
    }
    try {
        let facts = collectFacts(p.path, p.kind, config, 3, false)
        let progress = readProgress(p.id)
        return computeHeadline(facts, progress, config.language)
    } catch (e: Exception) {
        return tl(config.language, "(unreadable: ${e.message})", "（读取失败：${e.message}）")
    }
}

/// `moongit list` 的分母行。
///
/// list 列的是**注册表**（含已停用），dashboard / status 报的是
/// **可处理项目**（排除已停用）。两个数不同是设计使然，但两边都沉默时
/// 用户只会看到 `list` 说「共 2 个」而 dashboard 说「共 1 个」，无从判断谁错了。
/// 所以停用数必须写出来，把「口径不同」变成「口径已知」。
func listSummaryLine(total: Int64, disabledCount: Int64, lang: String): String {
    let note = if (disabledCount > 0) { tl(lang, " (${disabledCount} disabled, excluded from stats)", "（${disabledCount} 个已停用，不参与统计）") } else { "" }
    return tl(lang, "${total} projects${note}. Use `moongit status <project>` for details.",
        "共 ${total} 个项目${note}。用 `moongit status <项目>` 看详情。")
}

func cmdList(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let reg = loadRegistry()
    let config = loadConfig()
    if (ctx.json) {
        let arr = ArrayList<JsonValue>()
        for (p in reg.projects) {
            // 必须用 p.toJson()，不能在这里手工拼。
            // 原来手工拼了 6 个键，漏掉 addedAt 与 tags：
            //     CLI  list --json       → 6 键，无 addedAt / tags
            //     HTTP /api/projects    → 8 键（走 p.toJson()）
            // 同一份注册表两种元素 schema，客户端无法共用解码器；
            // 而且「注册时间」和「分组标签」在 CLI 侧完全不可得。
            // toJson 本来就是权威形状，这里没有任何理由不用它。
            arr.add(p.toJson())
        }
        printOut(Json.pretty(JArr(arr)))
        return 0
    }
    if (reg.projects.size == 0) {
        Log.info(T("No projects registered yet. Run `moongit scan <root>` or `moongit add <path>`.", "尚未注册任何项目。运行 `moongit scan <根目录>` 或 `moongit add <路径>`。"))
        return 0
    }
    let rows = ArrayList<Array<String>>()
    var disabledCount: Int64 = 0
    for (p in reg.projects) {
        if (p.disabled) {
            disabledCount += 1
        }
        rows.add([p.name, p.kind, prettyPath(p.path, 42, ), listRowHeadline(p, config)])
    }
    printOut(renderTable([T("Project", "项目"), T("Type", "类型"), T("Path", "路径"), T("Headline", "现状")], rows.toArray()))
    Log.info("")
    Log.info(listSummaryLine(reg.projects.size, disabledCount, config.language))
    return 0
}

func cmdAdd(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    if (refs.size == 0) {
        throw DgError.usage(T("Usage: moongit add <path> [--name NAME]", "用法：moongit add <路径> [--name 名称]"))
    }
    // ⚠️ #196：原来多出来的位置参数被静默丢弃（`moongit add /p n1 n2` → rc=0）。
    // 项目名走的是 `--name`，第二个位置参数**没有**别的含义 ——
    // 静默吞掉它等于把用户的拼写错误（以为可以直接写名字）变成成功。
    rejectExtraPositionals("add", refs, 1)   // 项目名走 --name，不是第二个位置参数
    var name = ""
    match (flagValue(rest, "--name")) {
        case Some(n) => name = n
        case None => ()
    }
    let cwd = normalizePath(expandHome(getCwd()))
    let (entry, added) = addProject(refs[0], name, ArrayList<String>(), cwd)
    if (ctx.json) {
        printOut(Json.pretty(entry.toJson()))
    } else if (added) {
        Log.ok(T("Registered: ${entry.name} (${entry.kind}) -> ${entry.path}", "已注册：${entry.name}（${entry.kind}）→ ${entry.path}"))
        if (!entry.remote.isEmpty()) {
            Log.info(T("  Remote: ${entry.remote}", "  远端：${entry.remote}"))
        }
    } else {
        Log.info(T("Project already exists: ${entry.name} (${entry.path})", "项目已存在：${entry.name}（${entry.path}）"))
    }
    return 0
}

func cmdRemove(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let refs = positionalsOnly(rest, VALUE_FLAGS)
    if (refs.size == 0) {
        throw DgError.usage(T("Usage: moongit remove <project...> [--purge]", "用法：moongit remove <项目...> [--purge]"))
    }
    let purge = hasFlag(rest, "--purge")
    // ⚠️⚠️ #196：原来只处理 `refs[0]`，其余项目名静默丢弃、退出码 0。
    // 实测 `moongit remove alpha beta` → 「✓ 已取消注册：alpha」rc=0，
    // 而 beta **原封不动留在注册表里**（`list` 仍能看到）。
    // 这是本族里最有害的一个：取消注册是**破坏性操作**，
    // 「要注销两个、只注销一个、还告诉我成功了」比不响应更糟 ——
    // 用户据此认为 beta 也已经注销，于是把它从自己的清单里划掉。
    // 现在按名单逐个处理，与 status / update / deep / journal 一致。
    let results = ArrayList<JsonValue>()
    for (entry in namedTargets(refs)) {
        // ⚠️ 取消注册前先数一下这个项目背着几条里程碑。
        //
        // 里程碑是**用户手写**的数据，存在 milestones.json 里、按 projectId 关联。
        // 取消注册之后 projectId 就不再对应任何项目，于是这些条目变成孤儿：
        // 数据还在盘上，但 `milestone list` 是按注册表遍历再按 id 过滤的，
        // 于是每一条命令都看不见它们 —— 实测 remove 之后
        //     milestone list → 「（无里程碑）」  exit 0
        // 而 milestones.json 里「v1.0 重要里程碑」原封不动。
        //
        // 用户看到的是「我 remove 了一个项目，我的里程碑就凭空没了」。
        // 实际是「还在，但谁都看不见」。这两件事必须分开说。
        // 必须在 removeProject **之前**查 —— 它返回的 entry 只在删除后才拿得到。
        let orphanCandidates = milestonesFor(entry.id).size
        let removed = removeProject(entry.name, purge)
        if (ctx.json) {
            results.add(removed.toJson())
        } else {
            Log.ok(T("Deregistered: ${removed.name}${if (purge) { "(progress data deleted)" } else { "" }}", "已取消注册：${removed.name}${if (purge) { "（进度数据已删除）" } else { "" }}"))
            if (orphanCandidates > 0) {
                // 方向：宁可多提醒一次。里程碑还在盘上，命令却再也列不出它们，
                // 不说的话用户会以为数据被删了而放弃找回。
                Log.warn(T("${orphanCandidates} milestones now point to a deregistered project and no longer appear in milestone list.", "${orphanCandidates} 条里程碑现在指向一个已取消注册的项目，不再出现在 milestone list 里。"))
                Log.info(T("  The data is not lost; it is still in ${deepgitPath(["milestones.json"])}. Re-register the same path to show them again.", "  数据仍在 ${deepgitPath(["milestones.json"])} 里没丢；重新注册同一路径即可恢复显示。"))
                Log.info(T("  To delete them for good: moongit milestone remove <project> <milestone> (re-register the project first)", "  想彻底删掉它们：moongit milestone remove <项目> <里程碑>（需要先重新注册该项目）"))
            }
        }
    }
    if (ctx.json) {
        // 多项目时必须是一份合法 JSON：`--json` 下逐个 printOut 会吐出
        // N 份首尾相接的文档（cmdGit / cmdTrack / cmdHook 都栽过这个）。
        // 复用 printMultiProjectJson：它对单个目标原样输出，与旧行为一致。
        printMultiProjectJson(results)
    }
    return 0
}

/// scan 的默认递归深度。**两个出口共用这一个常量**。
///
/// 原来 CLI 是 4、HTTP 是 2（http.cj 手写 `var depth: Int64 = 2`），
/// 于是同一份数据两个出口给出两个「没找到」：
///     仓库在 root/a/b/c/d（4 层）
///     CLI  scan /root              → candidates=1
///     HTTP POST /api/scan?root=…   → {"found":0}   ← 谎报「这里没有项目」
/// 客户端拿到 200 + found:0 就会向用户断言「这个目录下没有项目」，
/// 而事实是「有，只是没扫到」。这与 cli.cj 里 truncated 那条注释是同一族：
/// 把「没扫完」说成「没有」。
///
/// HTTP 那个 2 从来没被任何调用方依赖过（实测显式传 depth=4 结果正确），
/// 所以统一到 4 是纯粹的一致性修复。
let SCAN_DEFAULT_DEPTH: Int64 = 4

/// scan 结果的 JSON 组装。**纯函数**，CLI 与 HTTP 共用。
///
/// 原来 HTTP 侧手写了第二份，少两个字段：
///     CLI : {candidates:[…], added, existing, dirsVisited, truncated}
///     HTTP: {found, added, dirsVisited, truncated}        ← 无 candidates / existing
/// 双重损失：
///   (a) 客户端拿不到候选项目的路径，无法展示「发现这些，等你确认」
///   (b) found − added 就是 existing，HTTP 不给这个数，客户端无法区分
///       「找到 1 个但已存在」与「找到 1 个但一个都没加进去」
/// http.cj 自己的注释就承认「CLI 的 scan 一直有报 truncated，HTTP 侧漏了」——
/// 同一段代码补了一个字段、漏了两个。「抄多处就漏一处」的第 13 例。
///
/// `found` 恒发，与 CLI 的 candidates.size 同义；两个都留着，
/// 让已经适配了 CLI 形状的客户端不必立刻改。
func scanResultJson(result: ScanResult, added: Int64, existing: Int64): JsonValue {
    let o = Json.obj()
    let arr = ArrayList<JsonValue>()
    for (c in result.candidates) {
        let e = Json.obj()
        Json.set(e, "name", Json.of(c.name))
        Json.set(e, "path", Json.of(c.path))
        Json.set(e, "kind", Json.of(c.kind))
        Json.set(e, "remote", Json.of(c.remote))
        arr.add(e)
    }
    Json.set(o, "candidates", JArr(arr))
    Json.set(o, "found", Json.of(result.candidates.size))
    Json.set(o, "added", Json.of(added))
    Json.set(o, "existing", Json.of(existing))
    Json.set(o, "dirsVisited", Json.of(result.dirsVisited))
    // truncated 必须带上：撞到 20000 目录上限时 found=0 与「确实一个项目都没有」
    // 在响应里长得一模一样，调用方无从分辨，只能如实报「扫到了 0 个项目」。
    Json.set(o, "truncated", Json.of(result.truncated))
    // depthCapped 恒发（缺陷 #197）：`--depth` 太浅也是「没扫全」，
    // 与 truncated 同族。少了它，调用方看到 `found=0` 只能报「这里没有项目」，
    // 而事实是「你没看那么深」。恒发 false 也是恒发 ——
    // 「看全了」是一个有意义的事实，缺键会让人以为是旧版本。
    Json.set(o, "depthCapped", Json.of(result.depthCapped))
    // unreadable 恒发（空数组也是恒发）：读不出来的目录与「没有项目」
    // 在响应里必须能被区分开。少了这个键，调用方看到 found=1 只知道「找到 1 个」，
    // 而不知道还有整棵子树根本没被读到（缺陷 #179）。
    // ⚠️ 恒发空数组 vs 缺键：这里选恒发，因为「读得进来但没有读不了的目录」
    // 是一个**有意义的事实**，缺键会让调用方误以为字段是旧版本没支持。
    let unread = ArrayList<JsonValue>()
    for (u in result.unreadable) {
        unread.add(Json.of(u))
    }
    Json.set(o, "unreadable", JArr(unread))
    return o
}

/// 扫描的覆盖程度。**纯函数**：把「扫全了没有」这句话变成一个可断言的判定。
///
/// 覆盖不全有**三种**成因，缺一不可：
///   · `truncated`   —— 撞到 20000 目录上限
///   · `unreadable`  —— 有目录读不出来（#179）
///   · `depthCapped` —— 撞到 `--depth` 上限且下面还有没看过的子目录（#197）
/// 原来只表达前两种，于是「深度不够所以没看完」被渲染成
/// 「看完了，这里没有项目」。
/// 枚举而不是 if 链：三种成因可以同时发生，逐个 if 迟早漏掉一种组合。
public func scanCoverage(truncated: Bool, unreadableCount: Int64, depthCapped: Bool, lang: String): String {
    let en = isEnglish(lang)
    var why = ArrayList<String>()
    if (truncated) {
        why.add(tl(lang, "hit the directory cap", "撞到目录上限"))
    }
    if (depthCapped) {
        why.add(tl(lang, "hit the --depth cap; deeper directories were not visited", "撞到 --depth 上限，下面还有目录没看"))
    }
    if (unreadableCount > 0) {
        why.add(tl(lang, "${unreadableCount} directories unreadable", "${unreadableCount} 个目录读不出来"))
    }
    if (why.isEmpty()) {
        return tl(lang, "complete", "完整")
    }
    return tl(lang, "partial coverage: ", "部分覆盖：") + joinStrings(why, tl(lang, "; ", "，且"))
}

/// 「本次扫描**没看完**吗」——文本路径两个出口（空结果早退 / 有结果收尾）
/// 必须用**同一个**判定。
///
/// ⚠️ #197 的原始形状就是这个：空结果那条早退看的是 `truncated`，
/// 收尾那条也看 `truncated`，而「深度上限」两种成因都没接 ——
/// 于是「深度不够」在两条路上都安静地变成了完整结论。
/// 同一个问题问两遍，两遍都答错。
public func scanIncomplete(truncated: Bool, depthCapped: Bool): Bool {
    return truncated || depthCapped
}

func cmdScan(rest: ArrayList<String>, ctx: CliContext): Int64 {
    var depth: Int64 = 4
    let scanLang = loadConfig().language
    match (flagValue(rest, "--depth")) {
        case Some(v) =>
            try {
                depth = Int64.parse(v)
            } catch (e: Exception) {
                throw DgError.usage(T("--depth expects an integer", "--depth 需要整数"))
            }
        case None => ()
    }
    // ⚠️ #197：`--depth 0` 与 `--depth -1` 原来都被接受，扫一个目录就收工，
    // 打印「未发现项目（已访问 1 个目录）」exit 0 —— 而「一个子目录都不看」
    // 永远不是想找仓库的人会提的要求。
    // 与 `journal --limit 0/-1`、`update.backupKeep < 0` 同一处置：直接报错。
    if (depth < 1) {
        throw DgError.usage(T("--depth must be at least 1 (got ${depth}): below 1 visits no subdirectory at all and only yields a misleading no-projects-found line", "--depth 至少为 1（收到 ${depth}）：小于 1 等于一个子目录都不看，只会得到一句误导性的「未发现项目」"))
    }
    let includeNonGit = !hasFlag(rest, "--git-only")
    let roots = positionalsOnly(rest, VALUE_FLAGS)
    if (roots.size == 0) {
        let config = loadConfig()
        if (config.roots.size == 0) {
            throw DgError.usage(T("Usage: moongit scan <root...> [--depth N]\n(Set roots in the config as default scan roots: moongit config set roots a,b)", "用法：moongit scan <根目录...> [--depth N]\n（可在配置里设 roots 作为默认扫描根：moongit config set roots a,b）"))
        }
        for (r in config.roots) {
            roots.add(r)
        }
    }
    let cwd = normalizePath(expandHome(getCwd()))
    let resolvedRoots = ArrayList<String>()
    for (r in roots) {
        let p = resolvePath(r, cwd)
        if (!isDirectoryPath(p)) {
            Log.warn(T("Skipping non-existent directory: ${p}", "跳过不存在的目录：${p}"))
            continue
        }
        resolvedRoots.add(p)
    }
    if (resolvedRoots.size == 0) {
        throw DgError.usage(T("No valid directories to scan", "没有可扫描的有效目录"))
    }

    Log.step(T("Scanning ${resolvedRoots.size} root directories (depth ${depth})...", "扫描 ${resolvedRoots.size} 个根目录（深度 ${depth}）…"))
    let result = scanRoots(resolvedRoots, depth, includeNonGit)
    let (added, existing) = registerCandidates(result.candidates)

    if (ctx.json) {
        let o = scanResultJson(result, added, existing)
        // 生效参数回显：
        // 少了这一项，「没找到」无法与「没扫到那么深」区分开。
        Json.set(o, "depth", Json.of(depth))
        printOut(Json.pretty(o))
        return 0
    }

    // ⚠️ 覆盖程度必须**在所有早退之前**说（缺陷 #179）。
    // 原来只有 truncated 在「一个候选都没扫到」那条早退分支里被提及；
    // 于是「有目录读不出来」从头到尾没有任何提示 ——
    // 实测把某个子树 chmod 000，终端只打印「✓ 发现 1 个项目」，
    // 而实际上有一整棵子树没被读到，文本读起来像句完整结论。
    if (result.unreadable.size > 0) {
        Log.warn(T("${result.unreadable.size} directories are unreadable (permission or I/O error) and were not covered this run:", "有 ${result.unreadable.size} 个目录**读不出来**（无权限或 I/O 错误），本次未覆盖它们："))
        for (u in result.unreadable) {
            Log.warn("  · ${u}")
        }
        Log.warn(T("Scan coverage: ${scanCoverage(result.truncated, result.unreadable.size, result.depthCapped, scanLang)} - the projects listed above are not the full set.", "扫描覆盖程度：${scanCoverage(result.truncated, result.unreadable.size, result.depthCapped, scanLang)} —— 上面列出的项目不是全部。"))
    }

    if (result.candidates.size == 0) {
        // ⚠️ 「没找到」和「没找完」必须分开说。
        // 原来这个早退早于下面的 truncated 告警，于是
        //   scan <超大目录树>   （撞上 20000 目录上限，一个候选都没扫到）
        // 打印「未发现项目（已访问 20000 个目录）」并 exit 0，
        // 读起来就是断言式的「这里没有项目」—— 而事实是「没看完」。
        // 「上限当全量」这一族的又一处；JSON 路径本来就有 truncated 字段，
        // 只有文本路径在早退处把它丢了。
        // ⚠️⚠️ #197：这里原来**只**看 truncated，于是同样早退的还有
        //   scan <树> --depth 2   （仓库在第 4 层）
        // → 「未发现项目（已访问 3 个目录）」exit 0。
        // 目录上限有披露、深度上限没有 —— 同一个「没看完」的两种成因，
        // 只接上了其中一种。两种都必须说。
        if (scanIncomplete(result.truncated, result.depthCapped)) {
            let why = if (result.depthCapped) {
                "本次撞到 --depth ${depth} 上限，下面还有目录没看"
            } else {
                "扫描被截断（目录过多）"
            }
            Log.warn(T("${why}: no-projects-found above only means none among the ${result.dirsVisited} directories visited; increase --depth or scan roots separately", "${why}：上面「未发现项目」只代表已访问的 ${result.dirsVisited} 个目录里没有，请增加 --depth 或分根扫描"))
            return 0
        }
        Log.info(T("No projects found (visited ${result.dirsVisited} directories)", "未发现项目（已访问 ${result.dirsVisited} 个目录）"))
        return 0
    }
    let rows = ArrayList<Array<String>>()
    for (c in result.candidates) {
        rows.add([c.name, c.kind, prettyPath(c.path, 46), if (c.remote.isEmpty()) { "-" } else { c.remote }])
    }
    printOut(renderTable([T("Project", "项目"), T("Type", "类型"), T("Path", "路径"), T("Remote", "远端")], rows.toArray()))
    Log.info("")
    Log.ok(T("Found ${result.candidates.size} projects: ${added} added, ${existing} already registered", "发现 ${result.candidates.size} 个项目：新增 ${added}，已存在 ${existing}"))
    if (scanIncomplete(result.truncated, result.depthCapped)) {
        // 找到了项目不代表看全了：更深的目录里可能还有别的仓库。
        // 原来这里也只接了 truncated，深度上限同样静默。
        Log.warn(T("Scan coverage: ${scanCoverage(result.truncated, result.unreadable.size, result.depthCapped, scanLang)} - the projects listed above are not the full set; increase --depth or scan roots separately", "扫描覆盖程度：${scanCoverage(result.truncated, result.unreadable.size, result.depthCapped, scanLang)} —— 上面列出的项目不是全部，可增加 --depth 或分根扫描"))
    }
    return 0
}

func cmdStatus(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let targets = resolveTargets(rest, true)
    let config = loadConfig()
    if (ctx.json) {
        // 恒定 envelope 形状：单项目/零项目/全部停用也与多项目一致（客户端契约）
        // summary 必须始终写入：早退会让 stdout 为空导致客户端 JSONDecoder 失败，
        // 条件写入则会在全部停用时缺键。groupSummary 对空列表产出全零但完整的 summary。
        let statuses = allProjectStatuses(targets, config, false)
        let o = Json.obj()
        Json.set(o, "projects", JArr(statuses))
        let sum = groupSummary(statuses, config)
        Json.set(o, "summary", sum)
        // 恒发，与 HTTP /api/status 同构。
        // 原来只有 HTTP 侧有（http.cj 的 status 路由），CLI 侧没有，
        // 于是同一份契约的顶层键随出口变化：严格 schema 校验的客户端
        // 在 CLI 下会因缺键失败，宽松的则两边行为不一致。
        // 值就在 config.language（cmdStatus 开头已加载）。
        Json.set(o, "language", Json.of(config.language))
        printOut(Json.pretty(o))
        // 全部采集失败时不能 exit 0
        return groupExitCode(Json.intAt(sum, "projectCount", 0), Json.intAt(sum, "listedProjects", 0))
    }
    if (targets.size == 0) {
        Log.info(T("No projects registered yet.", "尚未注册任何项目。"))
        return 0
    }
    if (targets.size == 1) {
        return printSingleStatus(targets[0], config)
    }
    // 多项目概览
    let light = positionalsOnly(rest, VALUE_FLAGS).size == 0
    let statuses = allProjectStatuses(targets, config, light)
    let rows = ArrayList<Array<String>>()
    for (s in statuses) {
        // 采集失败的项目原先 headline 是空的，表格里就是一个光秃秃的空格，
        // 看不出是「没变化」还是「读不到」。把原因直接放进现状列，
        // 用户不必再跑一次 list 才知道哪个项目坏了、为什么坏。
        let err = Json.strAt(s, "error", "")
        let headline = if (!err.isEmpty()) { "读取失败：${oneLineClamped(err, 60)}" } else { Json.strAt(s, "headline", "") }
        rows.add([
            Json.strAt(s, "name", "?"),
            Json.strAt(s, "kind", ""),
            Json.strAt(s, "currentBranch", "-"),
            headline,
        ])
    }
    printOut(renderTable([T("Project", "项目"), T("Type", "类型"), T("Current branch", "当前分支"), T("Headline", "现状")], rows.toArray()))
    let summary = groupSummary(statuses, config)
    // 采集失败的项目也要在表头说清楚。原来说「共 N 个项目」而 N 只数成功项，
    // 表格却列了全部条目 —— 数字对不上，坏掉的项目就这么从视野里消失了。
    // 实测：4 个注册项目、2 个路径失效，表头写「共 2 个项目」而下面列 4 行。
    let failed = Json.intAt(summary, "failedProjects", 0)
    let failedNote = if (failed > 0) { "（${failed} 个读取失败）" } else { "" }
    Log.info("")
    // 「N 个分支」= 引擎追踪到基线的数量，必须把仓库真实总数摆出来。
    // 实测：16 个分支的仓库这行原本只写「7 个分支」，读者只能理解成
    // 仓库只有 7 个分支。branchUnknownProjects 也要说 —— 那些项目的
    // 真实分支数读不出来，repoBranchTotal 不含它们，沉默会让人以为「都在里面了」。
    let branchTruncated = Json.intAt(summary, "branchTruncatedProjects", 0)
    let branchUnknown = Json.intAt(summary, "branchUnknownProjects", 0)
    var branchNote = ""
    if (branchTruncated > 0) {
        branchNote = "（仓库共 ${Json.intAt(summary, "repoBranchTotal", 0)} 个，${branchTruncated} 个项目未全部追踪）"
    }
    if (branchUnknown > 0) {
        branchNote = branchNote + (if (branchNote.isEmpty()) { "" } else { "；" }) +
            "${branchUnknown} 个项目分支数读不出来，未计入"
    }
    Log.info(T("${Json.intAt(summary, "listedProjects", 0)} projects in total${failedNote} · ${Json.intAt(summary, "branchCount", 0)} branches${branchNote} · active ${Json.intAt(summary, "activeProjects", 0)} · stale ${Json.intAt(summary, "staleProjects", 0)}", "共 ${Json.intAt(summary, "listedProjects", 0)} 个项目${failedNote} · ${Json.intAt(summary, "branchCount", 0)} 个分支${branchNote} · 活跃 ${Json.intAt(summary, "activeProjects", 0)} · 停滞 ${Json.intAt(summary, "staleProjects", 0)}"))
    if (failed > 0 && Json.intAt(summary, "projectCount", 0) == 0) {
        Log.error(T("Every project failed to read; no facts were produced. Debug one by one: moongit status <project>", "全部项目都读取失败，没有生成任何事实。逐个排查：moongit status <项目名>"))
    }
    return groupExitCode(Json.intAt(summary, "projectCount", 0), Json.intAt(summary, "listedProjects", 0))
}

func printSingleStatus(project: ProjectEntry, config: Config): Int64 {
    let status = projectStatus(project, config, 8)
    let zh = !isEnglish(config.language)
    printOut(T("${Json.strAt(status, "name", "")}  ${if (Json.strAt(status, "kind", "") == "git") { "(git)" } else { "(non-git)" }}", "${Json.strAt(status, "name", "")}  ${if (Json.strAt(status, "kind", "") == "git") { "（git）" } else { "（非 git）" }}"))
    printOut(T("Path: ${Json.strAt(status, "path", "")}", "路径：${Json.strAt(status, "path", "")}"))
    if (Json.strAt(status, "remote", "").size > 0) {
        printOut(T("Remote: ${Json.strAt(status, "remote", "")}", "远端：${Json.strAt(status, "remote", "")}"))
    }
    printOut(T("Headline: ${Json.strAt(status, "headline", "")}", "现状：${Json.strAt(status, "headline", "")}"))
    printOut("")
    let branches = Json.arrAt(status, "branches")
    if (branches.size > 0) {
        // 表头必须带分母。这张表列的是「引擎追踪到基线的分支」，
        // 不是仓库的全部分支：候选集被 maxShallowBranches（默认 6）限着。
        // 16 个分支的仓库这张表只列 7 行，却顶着一句中性的「分支进度」——
        // 读者只能理解成「仓库就这几个分支」。
        let repoN = Json.intAt(status, "repoBranchCount", -1)
        let tableTitle = if (repoN >= 0 && repoN != branches.size) {
            if (zh) { "分支进度（仓库共 ${repoN} 个，已追踪 ${branches.size} 个）" }
            else { "Branches (${branches.size} of ${repoN} tracked)" }
        } else {
            if (zh) { "分支进度" } else { "Branches" }
        }
        printOut(tableTitle)
        let rows = ArrayList<Array<String>>()
        for (b in branches) {
            let flags = ArrayList<String>()
            if (Json.boolAt(b, "isCurrent", false)) {
                flags.add(if (zh) { "当前" } else { "cur" })
            }
            if (Json.boolAt(b, "isDefault", false)) {
                flags.add(if (zh) { "默认" } else { "def" })
            }
            let extra = ArrayList<String>()
            let ahead = Json.intAt(b, "aheadOfDefault", 0)
            if (ahead > 0 && !Json.boolAt(b, "isDefault", false)) {
                extra.add("+${ahead}")
            }
            let pending = Json.intAt(b, "pendingCommits", 0)
            if (pending > 0) {
                extra.add(if (zh) { "${pending} 待记录" } else { "${pending} pending" })
            }
            rows.add([
                Json.strAt(b, "name", ""),
                Json.strAt(b, "statusLabel", ""),
                Json.strAt(b, "headShort", "-"),
                Json.strAt(b, "headAgo", "-"),
                "${joinStrings(flags, "/")}${if (extra.size > 0) { " " + joinStrings(extra, " ") } else { "" }}",
                truncate(oneLine(Json.strAt(b, "summary", "")), 44, "…"),
            ])
        }
        printOut(renderTable([T("Branch", "分支"), T("Status", "状态"), "HEAD", T("Last commit", "最近提交"), T("Tag", "标记"), T("Summary", "摘要")], rows.toArray()))
    } else {
        printOut(if (zh) { T("(no progress records yet; run `moongit update` to generate)", "（暂无进度记录，运行 `moongit update` 生成）") } else { "(no progress yet)" })
    }

    let progressMeta = Json.getOr(status, "progress")
    printOut("")
    let lastUpdate = Json.strAt(progressMeta, "lastUpdateAt", "")
    let lastDeep = Json.strAt(progressMeta, "lastDeepAt", "")
    printOut(T("Shallow update: ${if (lastUpdate.size > 0) { formatDateTime(lastUpdate) } else { "never" }} · Deep update: ${if (lastDeep.size > 0) { formatDateTime(lastDeep) } else { "never" }}", "进度更新：${if (lastUpdate.size > 0) { formatDateTime(lastUpdate) } else { "从未" }} · 深度更新：${if (lastDeep.size > 0) { formatDateTime(lastDeep) } else { "从未" }}"))
    if (Json.intAt(status, "userDirtyCount", 0) > 0) {
        printOut(T("Working tree: ${Json.intAt(status, "userDirtyCount", 0)} uncommitted changes (moonGit-managed docs excluded)", "工作区：${Json.intAt(status, "userDirtyCount", 0)} 处未提交改动（不含 moonGit 托管文档）"))
    }

    let journal = Json.arrAt(status, "journal")
    if (journal.size > 0) {
        printOut("")
        printOut(if (zh) { T("Recent progress", "最近进度") } else { "Recent" })
        var i: Int64 = 0
        for (e in journal) {
            if (i >= 5) {
                break
            }
            printOut("- ${formatDateTime(Json.strAt(e, "at", ""))} · ${modeLabel(Json.strAt(e, "mode", ""), config.language)} · `${Json.strAt(e, "branch", "-")}` · ${truncate(oneLine(Json.strAt(e, "summary", "")), 70, "…")}")
            i += 1
        }
        // 截断必须写出来。只打 5 条就收工，用户会以为「这个项目最近就这些」。
        // JSON 路径已有 journalTruncated 字段，这里是文本路径的对应披露。
        if (Json.boolAt(status, "journalTruncated", false)) {
            printOut(T("- ... showing the latest ${Json.intAt(status, "journalLimit", 5)} entries; full history: moongit journal ${Json.strAt(status, "name", "<project>")} --limit N", "- … 仅显示最近 ${Json.intAt(status, "journalLimit", 5)} 条，完整历史：moongit journal ${Json.strAt(status, "name", "<项目>")} --limit N"))
        }
        // 坏行也必须说：entries 少了内容却不说原因，调用方会以为「最近没更新过」
        if (Json.intAt(status, "journalUnparsableLines", 0) > 0) {
            printOut(T("- ⚠ ${Json.intAt(status, "journalUnparsableLines", 0)} progress log lines could not be parsed and were skipped", "- ⚠ 有 ${Json.intAt(status, "journalUnparsableLines", 0)} 行进度日志无法解析，已跳过"))
        }
    }
    match (Json.get(status, "overall")) {
        case Some(overall) =>
            let notes = Json.strArrAt(overall, "notes")
            if (notes.size > 0) {
                printOut("")
                printOut(if (zh) { T("Needs attention", "需要注意") } else { "Attention" })
                for (n in notes) {
                    printOut("- ${n}")
                }
            }
        case None => ()
    }
    return 0
}

func cmdTrack(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let targets = resolveTargets(rest, false)
    let config = loadConfig()
    var source = "cli"
    match (flagValue(rest, "--source")) {
        case Some(s) => source = s
        case None => ()
    }
    var failed = false
    // 同 cmdGit：多项目 --json 必须只输出一份文档
    let trackResults = ArrayList<JsonValue>()
    for (p in targets) {
        try {
            let result = runTrack(p, config, source)
            if (ctx.json) {
                trackResults.add(updateResultToJson(result))
            } else {
                // 命中 30 条基线上限时必须说清是「已记录」而非「共」——
                // 否则 100 提交的仓库首次 update 报「30 个提交」，
                // 紧接着 deep 报 100，用户以为数据丢了。
                let commitNote = if (Json.boolAt(result.journalEntry, "commitCountTruncated", false)) {
                    "已记录 ${result.commitCount} 个提交（超过 ${MAX_BASELINE_COMMITS} 条基线上限，非全量）"
                } else {
                    "${result.commitCount} 个提交"
                }
                Log.ok(T("Recorded ${p.name}: ${result.branchCount} branches${branchScopeNote(result.branchCount, result.repoBranchCount, !isEnglish(config.language))}, ${commitNote}", "已记录 ${p.name}：${result.branchCount} 个分支${branchScopeNote(result.branchCount, result.repoBranchCount, !isEnglish(config.language))}，${commitNote}"))
            }
        } catch (e: Exception) {
            failed = true
            if (ctx.json) {
                trackResults.add(chainError("track 失败", e).toJson())
            } else {
                Log.error("${p.name}: ${e.message}")
            }
        }
    }
    if (ctx.json) {
        printMultiProjectJson(trackResults)
    }
    return if (failed) { 1 } else { 0 }
}

func cmdUpdate(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let targets = resolveTargets(rest, true)
    requireWorkableTargets(targets)
    let config = loadConfig()
    var docs = ""
    match (flagValue(rest, "--docs")) {
        case Some(d) => docs = d
        case None => ()
    }
    let dryRun = hasFlag(rest, "--dry-run")
    var notes = ArrayList<String>()
    match (flagValue(rest, "--note")) {
        case Some(n) => notes.add(n)
        case None => ()
    }
    var failed = false
    let results = ArrayList<JsonValue>()
    for (p in targets) {
        try {
            let opts = UpdateOptions()
            opts.mode = "shallow"
            opts.docs = docs
            opts.dryRun = dryRun
            opts.source = "cli"
            opts.notes = notes
            let result = runUpdate(p, config, opts)
            if (ctx.json) {
                results.add(updateResultToJson(result))
            } else {
                Log.info("")
                let commitNote2 = if (Json.boolAt(result.journalEntry, "commitCountTruncated", false)) {
                    "已记录 ${result.commitCount} 个提交（超过 ${MAX_BASELINE_COMMITS} 条基线上限，非全量）"
                } else {
                    "${result.commitCount} 个提交"
                }
                Log.ok(T("${result.projectName}: ${result.branchCount} branches${branchScopeNote(result.branchCount, result.repoBranchCount, !isEnglish(config.language))}, ${commitNote2} (summary by: ${providerLabel(result.provider)})", "${result.projectName}：${result.branchCount} 个分支${branchScopeNote(result.branchCount, result.repoBranchCount, !isEnglish(config.language))}，${commitNote2}（摘要来源：${providerLabel(result.provider)}）"))
                for ((file, changed, created, _, backup) in result.docChanges) {
                    if (changed) {
                        Log.info(T("  · ${file}${if (created) { " (new)" } else { "" }}", "  · ${file}${if (created) { "（新建）" } else { "" }}"))
                        // 改了用户的文件就**必须说备份在哪**（缺陷 #210）。
                        // 原来 res.backup 在 flow 里就被丢掉了，引擎每轮都留一份、
                        // 按 backupKeep 裁剪，用户却从不知道它存在。
                        // 没有备份时一个字都不许说：新建文件本来就没有旧版本。
                        if (!backup.isEmpty()) {
                            Log.info(T("    Backups: ${backup}", "    备份：${backup}"))
                        }
                    }
                }
            }
        } catch (e: Exception) {
            failed = true
            if (ctx.json) {
                results.add(chainError("${p.name} 更新失败", e).toJson())
            } else {
                Log.error("${p.name}: ${e.message}")
            }
        }
    }
    if (ctx.json) {
        printMultiProjectJson(results)
    }
    return if (failed) { 1 } else { 0 }
}

func cmdDeep(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let targets = resolveTargets(rest, true)
    requireWorkableTargets(targets)
    let config = loadConfig()
    var scope = "all"
    match (flagValue(rest, "--scope")) {
        case Some(s) => scope = s
        case None => ()
    }
    if (scope != "all" && scope != "readme" && scope != "agent") {
        throw DgError.usage(T("--scope must be all | readme | agent", "--scope 只能是 all | readme | agent"))
    }
    let dryRun = hasFlag(rest, "--dry-run")
    var failed = false
    let results = ArrayList<JsonValue>()
    for (p in targets) {
        try {
            let opts = DeepOptions()
            opts.scope = scope
            opts.dryRun = dryRun
            opts.source = "cli"
            let result = runDeep(p, config, opts)
            if (ctx.json) {
                results.add(deepResultToJson(result))
            } else {
                Log.info("")
                Log.ok(T("${result.projectName} deep update done (summary by: ${providerLabel(result.provider)})", "${result.projectName} 深度更新完成（摘要来源：${providerLabel(result.provider)}）"))
                for ((file, changed, created, _, backup) in result.docChanges) {
                    Log.info(T("  · ${file}${if (created) { " (new)" } else if (changed) { "" } else { " (no change)" }}", "  · ${file}${if (created) { "（新建）" } else if (changed) { "" } else { "（无变化）" }}"))
                    if (!backup.isEmpty()) {
                        Log.info(T("    Backups: ${backup}", "    备份：${backup}"))
                    }
                }
                if (result.highlights.size > 0) {
                    Log.info("")
                    Log.info(T("Key takeaways:", "关键结论："))
                    for (h in result.highlights) {
                        Log.info("  - ${h}")
                    }
                }
            }
        } catch (e: Exception) {
            failed = true
            if (ctx.json) {
                results.add(chainError("${p.name} 深度更新失败", e).toJson())
            } else {
                Log.error("${p.name}: ${e.message}")
            }
        }
    }
    if (ctx.json) {
        // 必须复用 printMultiProjectJson。原来这里是第三份手写拷贝
        // （`if (results.size == 1) { printOut(...) } else { printOut(JArr(...)) }`），
        // 另两份在 util/log.cj。抄三份就有两份形状已经漂移的风险 ——
        // 「同一份形状约定抄多处，漏一处就破」已在本引擎栽到第 7 例。
        printMultiProjectJson(results)
    }
    return if (failed) { 1 } else { 0 }
}

func updateResultToJson(r: UpdateResult): JsonValue {
    let o = Json.obj()
    Json.set(o, "ok", Json.of(r.ok))
    Json.set(o, "mode", Json.of(r.mode))
    Json.set(o, "projectId", Json.of(r.projectId))
    Json.set(o, "project", Json.of(r.projectName))
    Json.set(o, "provider", Json.of(r.provider))
    Json.set(o, "providerLabel", Json.of(providerLabel(r.provider)))
    Json.set(o, "branchCount", Json.of(r.branchCount))
    // ⚠️ branchCount 是「这轮建立了基线的分支数」，不是仓库的分支数。
    // 候选集受 maxShallowBranches 限制（默认 6），实测 16 个分支的仓库
    // 只报 7 个。程序化调用方（客户端 / MCP）拿到 branchCount 会直接
    // 当成「这个项目有几个分支」，所以分母必须进 envelope。
    // -1 = 读不出来（非 git 项目或 for-each-ref 失败），不是 0。
    match (r.repoBranchCount) {
        case Some(n) => Json.set(o, "repoBranchCount", Json.of(n))
        case None => Json.set(o, "repoBranchCount", Json.of(-1))
    }
    Json.set(o, "branchCountTruncated", Json.of(Json.boolAt(r.journalEntry, "branchCountTruncated", false)))
    Json.set(o, "commitCount", Json.of(r.commitCount))
    let docs = ArrayList<JsonValue>()
    for ((file, changed, created, preview, backup) in r.docChanges) {
        let d = Json.obj()
        Json.set(d, "file", Json.of(file))
        Json.set(d, "changed", Json.of(changed))
        Json.set(d, "created", Json.of(created))
        if (preview.size > 0) {
            Json.set(d, "preview", Json.of(preview))
        }
        // ⚠️ **恒发**，即使是空串：键出现与否取决于数据的话，消费方就得写两套
        // 解码分支，而最容易漏的那套会把「键不存在」显示成「没备份」——
        // 而真实原因是「这份文档是新建的，本来就没有旧版本可备份」。
        // 空串 = 确实没有备份（新建 / 无变化 / dry-run），不是「不知道」。
        Json.set(d, "backup", Json.of(backup))
        docs.add(d)
    }
    Json.set(o, "docs", JArr(docs))
    Json.set(o, "journalEntry", r.journalEntry)
    Json.set(o, "at", Json.of(r.at))
    return o
}

func deepResultToJson(r: DeepResult): JsonValue {
    let o = Json.obj()
    Json.set(o, "ok", Json.of(r.ok))
    Json.set(o, "mode", Json.of("deep"))
    Json.set(o, "projectId", Json.of(r.projectId))
    Json.set(o, "project", Json.of(r.projectName))
    Json.set(o, "provider", Json.of(r.provider))
    Json.set(o, "providerLabel", Json.of(providerLabel(r.provider)))
    let hl = ArrayList<JsonValue>()
    for (h in r.highlights) {
        hl.add(Json.of(h))
    }
    Json.set(o, "highlights", JArr(hl))
    let docs = ArrayList<JsonValue>()
    for ((file, changed, created, preview, backup) in r.docChanges) {
        let d = Json.obj()
        Json.set(d, "file", Json.of(file))
        Json.set(d, "changed", Json.of(changed))
        Json.set(d, "created", Json.of(created))
        if (preview.size > 0) {
            Json.set(d, "preview", Json.of(preview))
        }
        // ⚠️ **恒发**，即使是空串：键出现与否取决于数据的话，消费方就得写两套
        // 解码分支，而最容易漏的那套会把「键不存在」显示成「没备份」——
        // 而真实原因是「这份文档是新建的，本来就没有旧版本可备份」。
        // 空串 = 确实没有备份（新建 / 无变化 / dry-run），不是「不知道」。
        Json.set(d, "backup", Json.of(backup))
        docs.add(d)
    }
    Json.set(o, "docs", JArr(docs))
    Json.set(o, "journalEntry", r.journalEntry)
    Json.set(o, "at", Json.of(r.at))
    return o
}

/// journal 的默认条数窗口。**两个出口共用这一个常量**。
///
/// 原来 CLI 是 20、HTTP 是 30（两处各自手写字面量），于是「这个项目的完整历史」
/// 在两个出口是不同的数。实测一个累积 49 条日志的项目：
///     CLI  journal --json            → 20 条
///     HTTP /api/journal?name=…       → 30 条
/// 客户端若把默认响应当「全部历史」，CLI 侧会**静默少 1/3**，
/// 而且响应里没有任何字段能说「被截断了」（见下方 journalWindowNoteText）。
/// 把上限当全量的又一例，且散成两个字面量 —— 抄多处就漏一处的最小复现。
let JOURNAL_DEFAULT_LIMIT: Int64 = 20

func cmdJournal(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let targets = resolveTargets(rest, true)
    let jl = loadConfig().language
    var branch = ""
    match (flagValue(rest, "--branch")) {
        case Some(b) => branch = b
        case None => ()
    }
    var limit: Int64 = JOURNAL_DEFAULT_LIMIT
    match (flagValue(rest, "--limit")) {
        case Some(v) =>
            // 旧实现解析失败与传负数都静默回落：--limit abc 当成 20，
            // --limit -5 传下去让 readJournal 返回空列表，用户看到「暂无记录」，
            // 与「这个项目真的没有记录」无法区分。
            limit = parseIntStrict(v, "--limit")
            if (limit <= 0) {
                throw DgError.usage(T("--limit expects a positive integer: ${v}", "--limit 需要正整数：${v}"))
            }
        case None => ()
    }
    let jsonEntries = ArrayList<JsonValue>()
    // 窗口耗尽的项目要单独收集，**收集**是为了 JSON 出口最后能按项目分别说清。
    // 必须区分「一条没捞到」和「捞到 limit 条但更早处还有」——
    // 两种情况处置不同，合成一句话就会出现「明明返回了 3 条却说没有条目」这种反向谎报。
    //
    // ⚠️ 2026-10-01 订正：这段原来写的是「这个 JSON 路径输出的是**裸数组**
    // （消费方按数组解析），没法往里塞 envelope 字段，所以走 stderr 告警披露」。
    // 那是**过期的**，而且与同一个函数下面 150 行处的注释直接矛盾
    // （那里写着「⚠️ 必须是 envelope，不能是裸数组」并真的建了 envelope）。
    // 实际输出（实测 `journal --json` 顶层键）：
    //     branchWindowExhausted / branches / entries / limit / projects
    //     / unparsableLines / windowExhausted
    // 留着那条过期注释的危害不是「描述不准」：它紧挨着下面这三个变量的声明，
    // 而这三个变量**正是为了 envelope 才存在的** —— 下一个读到这里的人
    // 会得出「envelope 里放不下，只能走 stderr」这个**与事实相反**的结论，
    // 然后照着它把已修好的披露又删回去。
    // 教训与 `docs/deepgit-redesign-plan.md` 里那段过期声明同一类：
    // **解释性注释是最容易腐烂的一类代码**，改了行为必须回头改它。
    let windowExhaustedEmpty = ArrayList<String>()
    let windowExhaustedPartial = ArrayList<String>()
    // 窗口级耗尽要跨项目累加（#189）：上面两个 list 只装**按分支过滤**时耗尽的项目，
    // 无分支过滤时它们恒为空，于是 `--limit 3` 配 12 条记录一个都不进。
    var windowExhaustedAny = false
    var badLines = 0
    for (p in targets) {
        // ⚠️ 必须让 store 层按分支过滤，不能「先取 limit*4 条再自己筛」。
        // 原来那样筛：窗口先截断、过滤后为空就报「（暂无记录）」，
        // 而「记录存在但落在窗口之外」与「这个分支没有记录」完全同构。
        // 实测 gamma 有 1 条 feat/x + 90 条 main、feat/x 在最旧：
        //   journal gamma --branch feat/x --limit 20  → 「（暂无记录）」
        //   journal gamma --branch feat/x --limit 200 → 记录就在那里
        // windowExhausted 用来区分「文件里就那么多」与「窗口不够，往更早处找」。
        let (entries, bad, windowExhausted) = readJournalForBranch(p.id, branch, limit)
        if (windowExhausted) {
            windowExhaustedAny = true
        }
        badLines += bad
        let filtered = entries
        if (ctx.json) {
            // 收集而不是就地打印：旧实现在项目循环里逐个 printOut 数组，
            // 于是 `moongit journal --json`（不指定项目 → 默认全部项目）
            // 会输出 N 个首尾相接的 JSON 数组，整份 stdout 非法，任何 JSONDecoder 都解不出来。
            // 归属不用我们补：readJournal 的条目本来就带 project / projectId 字段，
            // 所以单项目输出与旧版字节一致，多项目则靠该字段区分来源。
            // 顺带把 limit 施加到 JSON 路径 —— 以前只有文本分支做截断，
            // 导致 `journal --json` 每个项目返回的条数是文本模式的 4 倍。
            if (windowExhausted && branch.size > 0) {
                if (filtered.size == 0) {
                    windowExhaustedEmpty.add(p.name)
                } else {
                    windowExhaustedPartial.add(p.name)
                }
            }
            var taken: Int64 = 0
            for (e in filtered) {
                if (taken >= limit) {
                    break
                }
                // 走 journalEntryJson（与 status --json 内嵌的 journal 同一份构造）。
                // 原来这里是 `jsonEntries.add(e)` 存储原样，而 status 那边是
                // 手挑的 9 键投影 —— 同一份形状约定抄两处、其中一处有损，
                // 这个引擎已经栽到第 8 例。
                jsonEntries.add(journalEntryJson(e))
                taken += 1
            }
            continue
        }
        printOut(T("# ${p.name} progress log${if (branch.size > 0) { " (branch ${branch})" } else { "" }}", "# ${p.name} 进度日志${if (branch.size > 0) { "（分支 ${branch}）" } else { "" }}"))
        printOut("")
        if (filtered.size == 0) {
            // 窗口用完仍无匹配：绝不能说「暂无记录」——
            // 事实是「最近 limit 条里没有，更早处可能有」。
            // 反过来，窗口没耗尽（= 扫到了文件头）时说「暂无记录」才是实话。
            let emptyNote = journalWindowNoteText(branch, limit, 0, windowExhausted, "--limit")
            if (emptyNote.size > 0) {
                printOut(T("(${emptyNote}; drop --branch for the full log)", "（${emptyNote}，或去掉 --branch 查看全量）"))
            } else {
                printOut(T("(no records)", "（暂无记录）"))
            }
            continue
        }
        var i: Int64 = 0
        for (e in filtered) {
            if (i >= limit) {
                break
            }
            let mode = modeLabel(Json.strAt(e, "mode", ""), jl)
            printOut("## ${formatDateTime(Json.strAt(e, "at", ""))} · `${Json.strAt(e, "branch", "-")}` · ${mode}")
            let commits = Json.intAt(e, "commitCount", 0)
            if (commits > 0) {
                printOut(T("- ${commits} commits involved · summary by: ${providerLabel(Json.strAt(e, "provider", ""))}", "- 涉及 ${commits} 个提交 · 摘要来源：${providerLabel(Json.strAt(e, "provider", ""))}"))
            }
            let summary = Json.strAt(e, "summary", "")
            if (summary.size > 0) {
                printOut("")
                printOut(T("**Summary**: ${oneLine(summary)}", "**摘要**：${oneLine(summary)}"))
            }
            let hl = Json.strArrAt(e, "highlights")
            if (hl.size > 0) {
                printOut("")
                for (h in hl) {
                    printOut("- ${oneLine(h)}")
                }
            }
            printOut("")
            i += 1
        }
        // 「有结果」这一路同样必须披露窗口被截断 —— 文案与 HTTP 出口共用同一份纯函数。
        // 上一版只把标志位接到了「筛完为空」那一路，于是
        //   moongit journal gamma --branch main --limit 3   （实际有 30 条）
        // 打出 3 条就干净收工，看上去和「这个分支一共就 3 条」一模一样。
        // 「上限当全量」这一族已经栽到第 12 次：只接一半等于把谎报从
        // 「说没有」换成「说只有这些」。
        let partNote = journalWindowNoteText(branch, limit, filtered.size, windowExhausted, "--limit")
        if (partNote.size > 0) {
            printOut("（${partNote}）")
        }
    }
    // 坏行提示走 stderr，不污染 stdout 的 JSON
    if (badLines > 0) {
        Log.warn(journalBadLineNoteText(badLines))
    }
    if (!windowExhaustedEmpty.isEmpty()) {
        Log.warn("${journalWindowNoteText(branch, limit, 0, true, "--limit")}（${joinStrings(windowExhaustedEmpty, "、")}）")
    }
    if (!windowExhaustedPartial.isEmpty()) {
        Log.warn("${journalWindowNoteText(branch, limit, limit, true, "--limit")}（${joinStrings(windowExhaustedPartial, "、")}）")
    }
    if (ctx.json) {
        // ⚠️ 必须是 envelope，不能是裸数组。
        //
        // 原来输出裸数组，于是三件**读出口必须知道**的事实全放不下，
        // 只能走 stderr 告警 —— 而 JSON 消费方不读 stderr：
        //   1. 生效的 limit：实测 26 个提交的项目，`journal --json` 给 20 条，
        //      消费方无法知道「20」是全部还是被砍过的窗口
        //   2. windowExhausted：「最近 limit 条里没有，更早处可能有」与
        //      「这个分支没有记录」在裸数组里完全同构
        //   3. badLines：日志里有解析不了的行
        // HTTP 出口早就是 {project, entries, limit, branchWindowExhausted,
        // unparsableLines, note}，两边披露能力不对等。
        //
        // 这是「把上限当全量」的第 N 次，也是本引擎最顽固的一族。
        let o = Json.obj()
        Json.set(o, "entries", JArr(jsonEntries))
        // 恒发：消费方必须能自证「这个数字是窗口，不是全量」
        Json.set(o, "limit", Json.of(limit))
        Json.set(o, "branches", Json.of(if (branch.isEmpty()) { "*" } else { branch }))
        Json.set(o, "projects", Json.of(targets.size))
        // 坏行数与窗口耗尽：按恒发处理，不能「有才带」——
        // 键出现与否取决于数据，消费方就得写两套解码分支。
        Json.set(o, "unparsableLines", Json.of(badLines))
        // ⚠️ 窗口级耗尽必须**独立**于分支级那个 map（缺陷 #189）。
        // `branchWindowExhausted` 只装按分支过滤时耗尽的分支，
        // 无过滤读取时它恒为 `{}` —— 于是 `journal --limit 3` 配 12 条记录，
        // 消费方看到「limit=3、耗尽集合为空」，两种读法都成立：
        // 「一共 3 条」和「只给了 3 条」。只有 limit 这一个数字无法自证。
        Json.set(o, "windowExhausted", Json.of(windowExhaustedAny))
        // 分支级窗口耗尽要按项目说清是「一条没捞到」还是「捞满了但更早处还有」——
        // 两种情况处置不同，合成一个布尔会反向谎报。
        let exhaustedObj = Json.obj()
        for (name in windowExhaustedEmpty) {
            Json.set(exhaustedObj, name, Json.of("none-in-window"))
        }
        for (name in windowExhaustedPartial) {
            Json.set(exhaustedObj, name, Json.of("window-full"))
        }
        Json.set(o, "branchWindowExhausted", exhaustedObj)
        printOut(Json.pretty(o))
    }
    return 0
}

func cmdHook(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let sub = positionalsOnly(rest, VALUE_FLAGS)
    if (sub.size == 0) {
        throw DgError.usage(T("Usage: moongit hook <install|uninstall|status> [project]", "用法：moongit hook <install|uninstall|status> [项目]"))
    }
    let action = sub[0]
    // 去掉动作词本身，resolveTargets 只应看到项目引用
    let restNoAction = ArrayList<String>()
    var skipped = false
    for (a in rest) {
        if (!skipped && a == action) {
            skipped = true
            continue
        }
        restNoAction.add(a)
    }
    let targets = resolveTargets(restNoAction, false)
    var failed = false
    // ⚠️ 同 cmdGit / cmdTrack：多项目 --json 只能输出一份文档。
    // 旧实现在项目循环里逐个 printOut，`moongit hook install --json`（不指定项目）
    // 会吐出 N 个首尾相接的 JSON 数组，整份 stdout 非法。
    let hookResults = ArrayList<JsonValue>()
    for (p in targets) {
        if (p.kind != "git") {
            Log.warn(T("${p.name} is not a git repository; skipped", "${p.name} 不是 git 仓库，跳过"))
            // 文本模式走 stderr 就够了；--json 下 stdout 什么都不写的话，
            // 调用方连「这个项目被跳过了」都不知道，会以为压根没注册过。
            if (ctx.json) {
                let o = Json.obj()
                Json.set(o, "project", Json.of(p.name))
                Json.set(o, "skipped", Json.of(true))
                Json.set(o, "reason", Json.of("不是 git 仓库"))
                hookResults.add(o)
            }
            continue
        }
        try {
            match (action) {
                case "install" =>
                    let engine = currentExecutable()
                    if (ctx.json) {
                        for (hn in HOOK_KINDS) {
                            let res = installHookFor(p.path, engine, hn)
                            let o = Json.obj()
                            Json.set(o, "project", Json.of(p.name))
                            Json.set(o, "hook", Json.of(hn))
                            Json.set(o, "file", Json.of(res.file))
                            Json.set(o, "installed", Json.of(res.installed))
                            Json.set(o, "created", Json.of(res.created))
                            hookResults.add(o)
                        }
                    } else {
                        for (hn in HOOK_KINDS) {
                            let res = installHookFor(p.path, engine, hn)
                            Log.ok(T("${p.name}: installed ${hn} hook -> ${res.file}", "${p.name}：已安装 ${hn} 钩子 → ${res.file}"))
                        }
                    }
                case "uninstall" =>
                    if (ctx.json) {
                        for (hn in HOOK_KINDS) {
                            let res = uninstallHookFor(p.path, hn)
                            let o = Json.obj()
                            Json.set(o, "project", Json.of(p.name))
                            Json.set(o, "hook", Json.of(hn))
                            Json.set(o, "file", Json.of(res.file))
                            Json.set(o, "removed", Json.of(res.replaced))
                            hookResults.add(o)
                        }
                    } else {
                        for (hn in HOOK_KINDS) {
                            let res = uninstallHookFor(p.path, hn)
                            if (res.replaced) {
                                Log.ok(T("${p.name}: removed ${hn} hook block(s)", "${p.name}：已卸载 ${hn} 钩子块"))
                            }
                        }
                    }
                case "status" =>
                    if (ctx.json) {
                        let o = Json.obj()
                        Json.set(o, "project", Json.of(p.name))
                        let arr = ArrayList<JsonValue>()
                        for (hn in HOOK_KINDS) {
                            arr.add(Json.of(hookInstalledFor(p.path, hn)))
                        }
                        Json.set(o, "installed", JArr(arr))
                        // 钩子在后台跑、stderr 重定向到日志文件，
                        // 告警不会出现在终端 —— 必须把日志路径告诉用户，
                        // 否则「有告警」和「根本没告警」在界面上无法区分。
                        Json.set(o, "log", Json.of(hookLogPathFor(p.path)))
                        hookResults.add(o)
                    } else {
                        let states = ArrayList<String>()
                        for (hn in HOOK_KINDS) {
                            let on = hookInstalledFor(p.path, hn)
                            states.add("${hn} ${if (on) { "✓" } else { "—" }}")
                        }
                        printOut("${p.name}：${joinStrings(states, " · ")}")
                        let logPath = hookLogPathFor(p.path)
                        if (fileExists(logPath) && fileNonEmpty(logPath)) {
                            printOut(T("  Background warning log: ${logPath}", "  后台告警日志：${logPath}"))
                            printOut(T("    Hooks run in the background with stderr redirected here; warnings never appear in the terminal", "    钩子在后台运行、stderr 重定向到这里，告警不会出现在终端"))
                        }
                    }
                case _ =>
                    throw DgError.usage(T("Unknown hook subcommand: ${action}", "未知 hook 子命令：${action}"))
            }
        } catch (e: Exception) {
            failed = true
            if (ctx.json) {
                // 异常路径也要留在 JSON 里，否则失败的项目从输出中凭空消失
                let o = Json.obj()
                Json.set(o, "project", Json.of(p.name))
                Json.set(o, "ok", Json.of(false))
                Json.set(o, "output", Json.of(e.message))
                hookResults.add(o)
            } else {
                Log.error("${p.name}: ${e.message}")
            }
        }
    }
    if (ctx.json) {
        // install/uninstall 的旧版单项目输出本来就是「按钩子展开的扁平数组」
        // （每条都带 project 字段），跨项目直接接在后面仍是一个合法数组，
        // 单项目时与旧版逐字节一致。status 是「每项目一个对象」，走统一出口。
        if (action == "install" || action == "uninstall") {
            printOut(Json.pretty(JArr(hookResults)))
        } else {
            printMultiProjectJson(hookResults)
        }
    }
    return if (failed) { 1 } else { 0 }
}

func cmdConfig(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let sub = positionalsOnly(rest, VALUE_FLAGS)
    let cfg = loadConfig()
    if (sub.size == 0 || sub[0] == "list") {
        if (ctx.json) {
            printOut(Json.pretty(configToJson(cfg)))
            return 0
        }
        printOut(T("Language: ${cfg.language}", "语言：${cfg.language}"))
        printOut(T("Scan roots: ${if (cfg.roots.size == 0) { "(not set)" } else { joinStrings(cfg.roots, ", ") } }", "扫描根：${if (cfg.roots.size == 0) { "（未设置）" } else { joinStrings(cfg.roots, ", ") } }"))
        printOut(T("Docs: ${joinStrings(cfg.docs, ", ")}", "文档：${joinStrings(cfg.docs, ", ")}"))
        printOut(T("Branch limit: ${cfg.maxShallowBranches}", "分支上限：${cfg.maxShallowBranches}"))
        printOut(T("AI: handled by the client layer (deepDolphin.app settings); the engine stays AI-agnostic", "AI：由客户端层负责（deepDolphin.app 设置），引擎保持 AI 无关"))
        return 0
    }
    if (sub[0] == "get") {
        if (sub.size < 2) {
            throw DgError.usage(T("Usage: moongit config get <key>", "用法：moongit config get <键>"))
        }
        let key = sub[1]
        // ⚠️ #194：未知键**必须报错**，不能返回 null + rc=0。
        //
        // 原来 `configGetValue` 的兜底是 `Json.null()`，于是
        //   moongit config get 瞎写的键   → 打印 `null`，退出码 0
        // 而同一批键在 `config set` 那边是「✗ 未知配置键：瞎写的键」+ 非 0。
        // 读侧说「这个键的值是 null」、写侧说「这个键不存在」——
        // 两套判据、两种结论，脚本没法分辨自己是拼错了键还是键真的没值。
        // 「不存在」和「值为空」是两个状态，任何层都不许合并。
        let value = configGetValue(cfg, key)
        if (ctx.json) {
            printOut(Json.pretty(value))
        } else {
            printOut(Json.compact(value))
        }
        return 0
    }
    if (sub[0] == "set") {
        if (sub.size < 3) {
            throw DgError.usage(T("Usage: moongit config set <key> <value>", "用法：moongit config set <键> <值>"))
        }
        let key = sub[1]
        let value = sub[2]
        let updated = configSetValue(cfg, key, value)
        saveConfig(updated)
        Log.ok(T("Set ${key} = ${value}", "已设置 ${key} = ${value}"))
        return 0
    }
    throw DgError.usage(T("Unknown config subcommand: ${sub[0]}", "未知 config 子命令：${sub[0]}"))
}

/// 引擎认得的配置键。**读与写的唯一来源**。
///
/// #194 之前读（`configGetValue`）和写（`configSetValue`）是两份独立的
/// `match`，而它们**已经漂移过一次**：`hooks.mode` 是引擎自己写进
/// config.json、自己 `loadConfig` 会读的键，读侧没它、写侧也没有它，
/// 于是用户既查不到也改不了。两份清单各写各的，早晚再漂移一次。
/// 改键表时两边一起改，并由 `testConfigReadAndWriteCoverTheSameKeys` 钉住。
func configKnownKeys(): Array<String> {
    return ["language", "update.backupKeep", "update.maxShallowBranches", "roots"]
}

/// 每个可写键的**合法样例值**，与 `configKnownKeys()` 成对维护。
///
/// 存在理由（#203）：`language` 的合法值是 `zh` / `en`，不是任意字符串。
/// 「每个键都设得上」这句话**只对合法值成立** ——
/// 而 `testConfigReadAndWriteCoverTheSameKeys` 原来给所有非 roots 键塞同一个占位串
/// `"1"`，`language` 一旦有了校验就立刻撞上。
///
/// 与其把测试改成对 `language` 特殊-case（那等于把校验放宽回「任意值」，
/// 正好抵消 #203 的修复），不如把「这个键的合法值长什么样」也收成单一来源：
/// 将来加新键的人照着填就行，不用自己猜，也不会把占位串当规格。
///
/// 返回 `None` 表示**没有登记样例值** —— 测试会因此变红，
/// 这是有意的：新键漏登记样例值，测试就该拦。
func configKeySample(key: String): Option<String> {
    match (key) {
        case "language" => return Some("en")
        case "update.backupKeep" => return Some("5")
        case "update.maxShallowBranches" => return Some("4")
        case "roots" => return Some("/tmp")
        case _ => return None
    }
}

func configGetValue(cfg: Config, key: String): JsonValue {
    match (key) {
        case "language" => return Json.of(cfg.language)
        case "update.backupKeep" => return Json.of(cfg.backupKeep)
        case "update.maxShallowBranches" => return Json.of(cfg.maxShallowBranches)
        case "roots" => return jsonStrArray(cfg.roots)
        // ⚠️ 未知键抛错，与 configSetValue 同一判据、同一退出码。
        // 原来这里是 `Json.null()` —— 见 cmdConfig 的注释。
        case _ => throw DgError.usage(T("Unknown config key: ${key} (available: ${joinStrings(configKnownKeys(), ", ")})", "未知配置键：${key}（可用：${joinStrings(configKnownKeys(), ", ")}）"))
    }
}

func configSetValue(cfg: Config, key: String, value: String): Config {
    match (key) {
        case "language" =>
            // ⚠️ #203：原来这里一行校验都没有，`config set language fr` 报
            // 「✓ 已设置」，而引擎只有 en / 中文两条路 —— 任何非 "en" 的值
            // 都渲染成中文。写入口接受了一个引擎不会兑现的值（#202 同族）。
            let le = languageError(value)
            if (!le.isEmpty()) {
                throw DgError.usage(le)
            }
            cfg.language = value
        case "update.backupKeep" =>
            let n = parseIntStrict(value, key)
            // 判据来自 kernel 的单一来源（#201）：原来这里只拦负数，
            // 而 0 的后果与负数**完全一样**——excess = names.size - 0 = names.size，
            // 把全部备份删光，包括本次刚为用户文件建的那份。
            // 修一份就够，写两处阈值必然漂移。
            let ke = backupKeepError(n)
            if (!ke.isEmpty()) {
                throw DgError.usage(ke)
            }
            cfg.backupKeep = n
        case "update.maxShallowBranches" =>
            let n = parseIntStrict(value, key)
            // ⚠️ #202：这里原来**一行校验都没有**。写进去之后 `config set` 报
            // 「✓ 已设置 … = 0」，而 `config get` 回读是 6 ——
            // 读路径会静默把它改回 6，只在 stderr 留一行。
            // 报成功在 stdout、解释为什么没用在 stderr，脚本与 CI 根本看不见。
            // 判据取自 kernel 单一来源，与读路径同一份（#201 的同一条纪律）。
            let me = maxShallowBranchesError(n)
            if (!me.isEmpty()) {
                throw DgError.usage(me)
            }
            cfg.maxShallowBranches = n
        case "roots" =>
            let parts = value.split(",")
            let arr = ArrayList<String>()
            for (p in parts) {
                let t = p.trimAscii()
                if (t.size > 0) {
                    arr.add(t)
                }
            }
            cfg.roots = arr
        case _ => throw DgError.usage(T("Unknown config key: ${key} (available: ${joinStrings(configKnownKeys(), ", ")})", "未知配置键：${key}（可用：${joinStrings(configKnownKeys(), ", ")}）"))
    }
    return cfg
}

/// 软解析：失败时回退到 fallback。适合「取不到就用默认」的 flag（如 --limit）。
/// ⚠️ 不要用于 config set —— 那会让「打印已设置 X」但值其实没变（谎报成功）。
func parseInt(s: String, fallback: Int64): Int64 {
    try {
        return Int64.parse(s.trimAscii())
    } catch (e: Exception) {
        return fallback
    }
}

/// 严格解析：失败即报 usage 错误。用于必须真实生效的配置写入。
func parseIntStrict(s: String, key: String): Int64 {
    try {
        return Int64.parse(s.trimAscii())
    } catch (e: Exception) {
        throw DgError.usage(T("${key} expects an integer: ${s}", "${key} 需要整数：${s}"))
    }
}

/// 校验「只改托管区域」承诺：对比备份与当前文档的用户内容
/// verify 的通过数与对外说明。
///
/// ⚠️ 原来这里是 `checked - undeterminedCount - missing`，减了两次 missing：
/// 文档缺失那一支在 `checked += 1` **之前**就 continue 了，
/// 所以 missing 根本不在 checked 里。实测 checked=1/undetermined=0/missing=1
/// → passed=0，于是 `verified:false` 配 note「暂无可校验的文档
/// （需要先执行 moongit update）」—— 而**同一命令的文本路径**
/// （checked - undeterminedCount）算出 1，打印「✓ 校验通过：1 份」。
/// JSON 与文本自相矛盾。
///
/// 后果比「数字不好看」严重：那句 note 会**直接诱导 agent 重跑 update
/// 覆盖用户文档**，而 README 其实刚刚逐字节校验通过。
///
/// ⚠️⚠️ #195：`failures` 原来**根本没传进来**。于是
///   checked=1 / failures=1 / undetermined=0 / missing=0
/// → passed=1 → `verified: true`
/// 而同一份信封里 `failures: 1`、`documents[0].ok: false`、退出码 1。
/// 三个信号里两个说不通过、一个说通过，**自相矛盾**。
/// `verified` 的含义是「这次校验通过了」，不是「这次校验到了东西」——
/// 校验到东西是 `checked > 0`，那是另一个字段。
/// 退出码当时是对的（failures>0 返回 1），所以只有读 JSON 的消费方
/// 会被骗：脚本 / 客户端 / MCP 一律只看那个布尔。
///
/// 抽成纯函数是因为这是整个 verify 的对外契约，值得能单独断言；
/// 之前它内联在 cmdVerify 里，改错了没有任何测试会红。
public func verifyOutcome(checked: Int64, undetermined: Int64, missing: Int64, failures: Int64): (Int64, Bool, String) {
    // ⚠️ 不减 missing —— 见上文。
    let passed = checked - undetermined - failures
    // 有失败 ⇒ 一律不算通过，**无论 checked 有多大**。
    if (failures > 0) {
        return (passed, false, "${failures} 份文档的非托管区域与上次写入前不一致")
    }
    if (passed > 0) {
        return (passed, true, "")
    }
    // ⚠️⚠️ #195：判据顺序必须与状态对应。原来 `checked == 0 && missing == 0`
    // 排在 undetermined 前面，于是「一份文档无法判定（引擎新建、没有快照）」
    // 会拿到 note「暂无可校验的文档（**需要先执行 moongit update**）」——
    // 而用户**刚刚跑过 update**，再跑一次不会有任何变化。
    // 那句 note 的用途是诱导 agent 重跑 update，所以指错方向比不说更糟：
    // 它会把一份好文档再覆盖一遍，却什么都没修好。
    if (undetermined > 0) {
        return (0, false, "${undetermined} 份文档无法判定（没有写入前快照，或读不到证据）—— 不算通过，也不等于被改动")
    }
    // 「没有任何可校验的东西」和「可校验的都缺失/无法判定」必须分开说 ——
    // 前者的正确处置是先 update，后者是去恢复文档 / 查权限。
    if (checked == 0 && missing == 0) {
        return (0, false, "暂无可校验的文档（需要先执行 moongit update）")
    }
    if (checked == 0) {
        return (0, false, "没有可校验的文档：${missing} 份文档缺失（备份仍在，可从备份恢复）")
    }
    return (0, false, "已校验 ${checked} 份，全部无法判定（读不到证据）—— 不算通过")
}

func cmdVerify(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let targets = resolveTargets(rest, true)
    var failures = 0
    var checked = 0
    // 无法判定（备份/文档读不到、标记结构异常）与文档缺失都不算「通过」，
    // 也不能算「破坏」—— 混进 checked/failures 会让 verify 为没做过的校验背书
    var undeterminedCount = 0
    var missing = 0
    let rows = ArrayList<Array<String>>()
    for (p in targets) {
        let store = StorePaths(p.id)
        let backupRoot = "${store.backups}"
        if (!isDirectoryPath(backupRoot)) {
            continue
        }
        for (entry in listDir(backupRoot)) {
            // 走 classifyEntry：不抛（#199）。备份根目录虽然是自己建的，
            // 但「子项 stat 不到」在备份迁移/半删状态下是真实可能的。
            let isDir = match (classifyEntry(entry)) {
                case EntryKind.Dir => true
                case _ => false
            }
            if (!isDir) {
                continue
            }
            // 文档路径优先取备份目录里的清单；老备份没有清单才退回目录名反推。
            // 目录名把 "/" 换成了 "_"，映射不可逆 —— update.agentDocCandidates
            // 配成 docs/AGENTS.md 时，反推出来的 docs_AGENTS.md 并不存在，
            // 于是这份文档会被静默跳过（或被误报成「文档已被删除」）。
            let docName = entry.name
            let backupDirPath = entry.path.toString()
            var relPath = readBackupManifest(backupDirPath)
            if (relPath.isEmpty()) {
                relPath = docName
            }
            let docPath = "${p.path}/${relPath}"
            if (!fileExists(docPath)) {
                // 备份目录存在 = 引擎以前管过这份文档，现在文档不见了。
                // 以前静默 continue，于是「文档被整个删掉」和「本来就没有文档」
                // 在输出里完全一样，verify 照样报「校验通过」。
                // 备份还在，可以恢复 —— 这属于必须让用户知道的事。
                missing += 1
                rows.add([p.name, docName, "文档缺失", "文档已被删除，但备份仍在 ${entry.path.toString()}（可从备份恢复）"])
                continue
            }
            // ⚠️⚠️ #195：备份目录里除了真备份，还有两个**元数据文件**：
            //   `.docpath`（这份文档的真实相对路径）、`.owned`（托管区域名清单）。
            // 原来 `listDir` 的结果被整个当成备份列表，于是
            //   「取最新备份」= 按文件名取字典序最大的那个
            // 真备份叫 `<时间戳>-<文件名>`（`2` = 0x32），
            // 而 `.owned` 的 `.` = 0x2E —— 有真备份时真备份赢（看起来一切正常），
            // **没有真备份时 `.owned` 赢**。
            //
            // 什么时候没有真备份？`applyRegions` 只在 `exists` 为真时留备份
            // （docs.cj:520）—— 也就是**引擎自己新建的文档**一份都没有。
            // 于是对一份刚由引擎生成的 README.md，verify 会：
            //   拿 README 的非托管区域  ⟂  字符串 "progress"（.owned 的内容）
            // 比，得出「不一致」，报出
            //   「非托管区域与上次写入前不一致（你之后编辑过，或引擎改动了托管
            //     区域外内容；备份可恢复）」
            // 用户一个字都没改，文档是引擎自己建的，却被**指控**改过。
            // 那句 note 还专门是用来诱导 agent 从备份恢复 / 重跑 update 的 ——
            // 按它做只会把一份好文档再覆盖一遍。
            //
            // 正确处置是三态里的第三态：**无法判定**（没有写入前快照），
            // 既不是「通过」也不是「不一致」。
            let all = listDir(entry.path.toString())
            if (all.size == 0) {
                // listDir() 吞掉读取异常（无权限、被占用）返回空列表 ——
                // 连元数据都列不出来 = 目录读不动，与「只有元数据」是两回事。
                Log.warn(T("Backup directory exists but is unreadable; verification skipped: ${p.name}/${docName}", "备份目录存在但读取不到内容，已跳过校验：${p.name}/${docName}"))
                continue
            }
            let latestOpt = latestRealBackup(entry.path.toString())
            if (latestOpt.isNone()) {
                // 目录能列、但除了元数据没有快照 = 引擎新建的文档（或备份被清掉了）。
                // 必须进 undetermined，且必须在 documents 里留下一行 ——
                // 静默 continue 会让这份文档从输出里消失，而 checked=0 配 note
                //「需要先执行 moongit update」是在教用户做一件已经做过、
                // 且再做一次也不会有用的事。
                undeterminedCount += 1
                rows.add([
                    p.name,
                    docName,
                    "无法判定",
                    "没有写入前快照（文档由引擎新建，或备份已被清理）—— 无可比对的证据，不算通过也不算被改动",
                ])
                continue
            }
            checked += 1
            let (ok, undetermined, reason) = verifyPreservation(docPath, latestOpt.getOrThrow())
            if (undetermined) {
                // 读不到证据 ≠ 证据通过。不计入 failures，但必须单独报出来，
                // 且 verified 不能因为它而变成 true
                undeterminedCount += 1
            } else if (!ok) {
                failures += 1
            }
            rows.add([
                p.name,
                docName,
                if (undetermined) { "无法判定" } else if (ok) { "OK" } else { "不一致" },
                reason,
            ])
        }
    }
    if (ctx.json) {
        let o = Json.obj()
        Json.set(o, "checked", Json.of(checked))
        Json.set(o, "failures", Json.of(failures))
        // 「无法判定」与「文档缺失」单列：它们既不是通过也不是破坏，
        // 混进 checked/failures 会让 verify 为自己没做过的校验背书
        Json.set(o, "undetermined", Json.of(undeterminedCount))
        Json.set(o, "missing", Json.of(missing))
        let (passed, verified, note) = verifyOutcome(checked, undeterminedCount, missing, failures)
        // 显式告诉调用方「到底校验了没有」：checked=0 时退出码仍是 0，
        // 只看退出码的自动化会把「根本没校验」当成「校验通过」。
        Json.set(o, "verified", Json.of(verified))
        if (!note.isEmpty()) {
            Json.set(o, "note", Json.of(note))
        }
        let arr = ArrayList<JsonValue>()
        for (row in rows) {
            let e = Json.obj()
            Json.set(e, "project", Json.of(row[0]))
            Json.set(e, "doc", Json.of(row[1]))
            Json.set(e, "ok", Json.of(row[2] == "OK"))
            Json.set(e, "note", Json.of(row[3]))
            arr.add(e)
        }
        Json.set(o, "documents", JArr(arr))
        printOut(Json.pretty(o))
        return if (failures > 0 || missing > 0) { 1 } else { 0 }
    }
    // ⚠️ 文本路径原来自己算了一遍 `passed = checked - undeterminedCount` ——
    // 与 JSON 路径的 verifyOutcome 是**两份实现**，且同样不减 failures。
    // 同一个数字有两处算法，漂移只是时间问题（#195 就是在 JSON 那侧漏的）。
    // 现在两侧共用 verifyOutcome。
    let (passed, _, note) = verifyOutcome(checked, undeterminedCount, missing, failures)
    if (rows.size == 0) {
        // 只有**一行都没有**才能走「没东西可校验」这条路。
        // 原来判的是 checked==0，于是「引擎新建的文档」那种一行
        // 「无法判定」会被整张表一起吞掉（#195 的那行就是新增的）。
        Log.warn(note)
        return 0
    }
    printOut(renderTable([T("Project", "项目"), T("Doc", "文档"), T("Result", "结果"), T("Note", "说明")], rows.toArray()))
    Log.info("")
    if (undeterminedCount > 0) {
        Log.warn(T("${undeterminedCount} docs could not be determined (backup unreadable, no pre-write snapshot, or malformed markers) - not counted as passed", "${undeterminedCount} 份文档无法判定（读不到备份、没有写入前快照或标记结构异常）—— 这些不计入通过"))
    }
    if (missing > 0) {
        Log.error(T("${missing} docs were deleted (backups remain and can be restored)", "${missing} 份文档已被删除（备份仍在，可恢复）"))
    }
    if (failures > 0) {
        Log.error(T("${failures} docs have non-managed content changes (restorable from backups)", "${failures} 份文档存在非托管内容改动（可用备份恢复）"))
        return 1
    }
    if (passed > 0) {
        Log.ok(T("Verification passed: user content in ${passed} docs is untouched", "校验通过：${passed} 份文档的用户内容均未被改动"))
    }
    return if (missing > 0) { 1 } else { 0 }
}

/// doctor「临时残留」这一行的三态。
///
/// ⚠️ 缺陷 #200：这里原来只有一个判断 —— `leftovers.size == 0` 就写「无」。
/// 而那个统计用的 `listDir` 吞掉读取异常返回空数组，条件还是**恒真**的
/// `listDir(p.path).size >= 0`（`size` 是 `Int64`，永远 >= 0，等于什么都没判）。
/// 三件事叠在一起，于是目录读不出来时：
///   `fileExists(<doc>)` 假 → 内层循环一次都不跑 → `leftovers` 空 → 报「无」。
/// 实测：磁盘上确实有 `README.md.tmp-999-0`，doctor 却报「临时残留 无」。
/// **自检工具报出了一个它从没做过的检查的结果** —— 这是它最不该出的错，
/// 和 #197「扫描没看完却说看全了」是同一条，但发生在自检工具自己身上。
///
/// 所以这一行必须是三态：`Clean`（查了，没有）/ `Found`（查了，有）/
/// `PartlyUnreadable`（**没查完**）。第三态不许塌进第一态。
public enum LeftoverVerdict {
    | Clean
    | Found(Int64)
    /// (已找到的残留数, 未检查的项目数)
    | PartlyUnreadable(Int64, Int64)
}

/// 纯判定：残留扫描的三态收口。**不碰文件系统。**
public func leftoverVerdict(leftovers: Int64, unreadableProjects: Int64): LeftoverVerdict {
    // 顺序是承重的：只要有项目没查到，就不能报「无」——
    // 哪怕在已查到的部分里一个残留都没发现。
    if (unreadableProjects > 0) {
        return LeftoverVerdict.PartlyUnreadable(leftovers, unreadableProjects)
    }
    if (leftovers > 0) {
        return LeftoverVerdict.Found(leftovers)
    }
    return LeftoverVerdict.Clean
}

public func leftoverResultText(v: LeftoverVerdict, lang: String): String {
    // M15 残留：doctor 表格单元格原先硬编码中文——en 模式下表头英文、
    // 单元格中文同屏。
    match (v) {
        case LeftoverVerdict.Clean => return tl(lang, "none", "无")
        case LeftoverVerdict.Found(n) => return tl(lang, "${n} found", "${n} 个")
        case LeftoverVerdict.PartlyUnreadable(n, k) =>
            return if (n == 0) { tl(lang, "${k} projects not checked", "${k} 个项目未检查") }
                else { tl(lang, "${n} found (${k} projects not checked)", "${n} 个（另有 ${k} 个项目未检查）") }
    }
}

public func leftoverDetailText(v: LeftoverVerdict, leftovers: ArrayList<String>, unreadableNames: ArrayList<String>, lang: String): String {
    match (v) {
        case LeftoverVerdict.Clean => return tl(lang, "none", "无")
        case LeftoverVerdict.Found(_) =>
            return tl(lang, ".tmp files left by killed engine processes, safe to delete: ",
                "引擎被强杀留下的 .tmp，可安全删除：") + joinStrings(leftovers, " ")
        case LeftoverVerdict.PartlyUnreadable(_, _) =>
            var msg = tl(lang, "these project directories are unreadable and **were not checked** (not \"no leftovers\"): ",
                "读不到这些项目目录，**没有检查过**（不是「没有残留」）：") + joinStrings(unreadableNames, ", ")
            if (leftovers.size > 0) {
                msg = msg + tl(lang, "; found in checked part: ", "；已检查部分发现：") + joinStrings(leftovers, " ")
            }
            return msg
    }
}

/// 扫引擎自己留下的 `.tmp` 残留。**返回 (残留清单, 读不到的项目名)**。
///
/// 第二项是这一行的诚实性前提：读不到的项目目录是「没检查」，
/// 不是「没有残留」。第二项不返回，调用方就只能把两者合并。
///
/// 命名规则来自 `writeFileAtomic`：`<name>.tmp-<pid>-<seq>`。
/// 原来用 `fileExists(<doc>)` 当闸门，而 `exists` 在父目录不可读时返回 false
/// —— 于是「目录读不出来」被翻译成「文档不存在」，进而跳过整个检查。
/// 那个闸门本来也是多余的：`<name>.tmp-` 前缀本身就已经把范围限死在同名文档上了。
func scanLeftovers(projects: ArrayList<ProjectEntry>): (ArrayList<String>, ArrayList<String>) {
    let leftovers = ArrayList<String>()
    let unreadable = ArrayList<String>()
    for (p in projects) {
        // 每个项目只列一次。原来在 4 个文档名里各 listDir 一遍 ——
        // 同一份目录读了 8 次，其中 4 次的返回值被拿去跟 0 比。
        let (entries, readable) = listDirChecked(p.path)
        if (!readable) {
            unreadable.add(p.name)
            continue
        }
        for (name in DEEPGIT_MANAGED_DOCS) {
            for (e in entries) {
                if (e.name.startsWith("${name}.tmp-")) {
                    leftovers.add("${p.name}/${e.name}")
                }
            }
        }
    }
    return (leftovers, unreadable)
}

func cmdDoctor(rest: ArrayList<String>, ctx: CliContext): Int64 {
    let lang = loadConfig().language
    let checks = ArrayList<Array<String>>()
    let gitOk = commandExists("git")
    checks.add(["git", if (gitOk) { "OK" } else { tl(lang, "missing", "缺失") }, if (gitOk) { gitRun(".", ["--version"], true) } else { tl(lang, "git is required", "需要安装 git") }])
    checks.add([tl(lang, "data dir", "数据目录"), if (isDirectoryPath(deepgitHome())) { "OK" } else { tl(lang, "not created", "未创建") }, deepgitHome()])
    let reg = loadRegistry()
    checks.add([tl(lang, "registered projects", "注册项目"), "${reg.projects.size}", tl(lang, "run `moongit scan` to add", "用 `moongit scan` 添加")])
    let missing = ArrayList<String>()
    for (p in reg.projects) {
        if (!isDirectoryPath(p.path)) {
            missing.add(p.name)
        }
    }
    checks.add([tl(lang, "paths valid", "路径有效"), if (missing.size == 0) { "OK" } else { tl(lang, "${missing.size} invalid", "${missing.size} 个失效") }, joinStrings(missing, ", ")])
    // 结果列不能硬编码：原来无论当前目录是否真在已注册项目里都写「项目内」，
    // 自检工具自己说谎，正是它最不该出的错。
    let cwdNorm = normalizePath(expandHome(getCwd()))
    let cwdInside = match (findProjectIn(reg, cwdNorm)) {
        case Some(_) => true
        case None => false
    }
    checks.add([tl(lang, "current dir", "当前目录"), if (cwdInside) { tl(lang, "inside a project", "项目内") } else { tl(lang, "outside projects", "项目外") }, cwdNorm])

    // 引擎自己留下的临时文件。writeFileAtomic 用「写 .tmp 再 rename」保证原子性，
    // 但进程若在 rename 之前被 kill -9，.tmp 就留在用户仓库里，
    // 变成 git status 里的脏文件，而且用户无从判断它是什么、能不能删。
    //
    // ⚠️ 三态：查不到残留 ≠ 查过且没有。目录读不出来的项目是「未检查」，
    // 报成「无」就是自检工具给自己发了一张没做过的检查的合格证（#200）。
    let (leftovers, unreadableProjects) = scanLeftovers(reg.projects)
    let lv = leftoverVerdict(Int64(leftovers.size), Int64(unreadableProjects.size))
    checks.add([tl(lang, "temp leftovers", "临时残留"), leftoverResultText(lv, lang), leftoverDetailText(lv, leftovers, unreadableProjects, lang)])

    // 自检命令必须能失败。原来两条路径都恒返回 0，于是 git 缺失、项目路径全部失效
    // 也照样退出成功，脚本/CI 无法据此判断环境是否可用。
    var problems = 0
    if (!gitOk) {
        problems += 1
    }
    if (missing.size > 0) {
        problems += 1
    }
    // 残留不算环境故障（不影响可用性），所以不计入 problems：
    // doctor 的退出码语义是「环境能不能用」，脏文件属于需要清理但不影响使用。
    // 它出现在检查表和 detail 里，用户能看到并自行删除。

    if (ctx.json) {
        let o = Json.obj()
        let arr = ArrayList<JsonValue>()
        for (row in checks) {
            let e = Json.obj()
            Json.set(e, "check", Json.of(row[0]))
            Json.set(e, "result", Json.of(row[1]))
            Json.set(e, "detail", Json.of(row[2]))
            arr.add(e)
        }
        Json.set(o, "checks", JArr(arr))
        Json.set(o, "problems", Json.of(problems))
        printOut(Json.pretty(o))
        return if (problems > 0) { 1 } else { 0 }
    }
    printOut(renderTable([T("Check", "检查项"), T("Result", "结果"), T("Detail", "详情")], checks.toArray()))
    return if (problems > 0) { 1 } else { 0 }
}

/// 当前可执行文件路径（用于钩子内嵌回退）
func currentExecutable(): String {
    match (getVariable("DEEPGIT_BIN")) {
        case Some(v) =>
            if (v.trimAscii().size > 0) {
                return v.trimAscii()
            }
        case None => ()
    }
    // 从进程参数第 0 项推断
    let args = getCommandLine()
    if (args.size > 0 && args[0].startsWith("/")) {
        return args[0]
    }
    // ⚠️ L2：兜底原来返回旧名 `deepgit`。改名后这个分支只在「PATH 查找启动
    //（argv[0] 是 moongit，不以 / 开头）且未设 DEEPGIT_BIN」时走到，
    // 于是 hook install 写进去的是指向不存在命令的钩子 —— 老用户的钩子
    // 会报「unknown command」，而这类失败只发生在用户机器上，CI 全绿。
    return "moongit"
}

func getCwd(): String {
    return getWorkingDirectory().toString()
}

