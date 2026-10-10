// CLI 层测试：位置参数解析与展示行格式。
package moongit.cli

import std.collection.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.flow.*
import moongit.kernel.*
import moongit.util.*

// ------------------------------ 测试 ------------------------------

@Test
func testPositionalsOnlySkipsValueFlagPairs(): Unit {
    let args = ArrayList<String>(["status", "--source", "hook", "-q", "proj"])
    let refs = positionalsOnly(args, VALUE_FLAGS)
    // --source 与它的值 hook 都不算位置参数；-q 是短 flag
    @Assert(refs.size == 2)
    @Assert(refs[0] == "status")
    @Assert(refs[1] == "proj")
}

@Test
func testValueFlagsValueIsNeverTreatedAsProject(): Unit {
    // 行为级回归：带值 flag 的「值」绝不能被当成位置参数（项目名）。
    // 曾经的缺陷：--note / --limit / --dir 不在 VALUE_FLAGS 里，于是
    //   moongit update p --note "shipped v2"  → 未找到项目：shipped v2
    //   moongit journal p --limit 5            → 未找到项目：5
    // 且 findProjectIn 走子串兜底，值若是某项目名的子串还会静默命中错误项目。
    //
    // 这个测试按行为断言，而不是抄 VALUE_FLAGS 自身 —— 抄写式断言发现不了清单缺项。
    // 新增任何 `flagValue(x, "--foo")` 时，必须把 --foo 同时加进 cases 和 VALUE_FLAGS。
    let cases: Array<String> = [
        "--name", "--depth", "--docs", "--scope", "--branch", "--port",
        "--source", "--tag", "--date", "--desc", "--out", "--message",
        "--budget", "--dir", "--limit", "--note", "--host",
    ]
    for (f in cases) {
        let args = ArrayList<String>(["someproject", f, "VALUE_THAT_IS_A_PROJECT_NAME"])
        let refs = positionalsOnly(args, VALUE_FLAGS)
        // 只应剩下真正的项目名
        @Assert(refs.size == 1)
        @Assert(refs[0] == "someproject")

        // 同一份清单还驱动 validateValueFlags：漏登记的 flag 既不会被剔除，
        // 缺值时也不会被拦下（`add <path> --name --note` 曾把项目注册成 "--note"）。
        // 两个契约绑在同一个循环里，漏一处就红。
        var threw = false
        try {
            validateValueFlags(ArrayList<String>(["someproject", f]))
        } catch (e: DgError) {
            threw = true
            @Assert(e.exitCode == 2)
        }
        @Assert(threw)
    }
}

@Test
func testConfigSetRejectsNonNumericInsteadOfSilentlyKeepingOld(): Unit {
    // 原实现用 parseInt(value, 旧值)，解析失败回退旧值，调用方却打印「已设置 <新值>」
    // 并退出 0 —— 值其实没变，用户以为改好了。
    var threw = false
    try {
        let _ = configSetValue(Config.defaults(), "update.maxShallowBranches", "abc")
    } catch (e: DgError) {
        threw = true
        @Assert(e.exitCode == 2)
    }
    @Assert(threw)

    // 负数 backupKeep 会让 pruneBackups 清空备份目录，必须拒绝
    var threwNeg = false
    try {
        let _ = configSetValue(Config.defaults(), "update.backupKeep", "-1")
    } catch (e: DgError) {
        threwNeg = true
    }
    @Assert(threwNeg)

    // 合法值仍要能写入
    let ok = configSetValue(Config.defaults(), "update.maxShallowBranches", "5")
    @Assert(ok.maxShallowBranches == 5)
}

/// #194：未知配置键在**读侧**也必须失败，且与写侧同一退出码。
///
/// 原来 `configGetValue` 的兜底是 `Json.null()` + rc=0，而 `configSetValue`
/// 报「未知配置键」+ exit 2。同一批键，两套判据、两种结论 ——
/// 脚本没法分辨「我拼错了键」和「这个键的值恰好是空」。
@Test
func testConfigGetUnknownKeyFailsLikeSetDoes(): Unit {
    let cfg = Config.defaults()
    var getThrew = false
    var getCode: Int64 = -1
    try {
        let _ = configGetValue(cfg, "瞎写的键")
    } catch (e: DgError) {
        getThrew = true
        getCode = e.exitCode
    }
    var setThrew = false
    var setCode: Int64 = -1
    try {
        let _ = configSetValue(cfg, "瞎写的键", "x")
    } catch (e: DgError) {
        setThrew = true
        setCode = e.exitCode
    }
    @Assert(getThrew)
    @Assert(setThrew)
    @Assert(getCode == setCode)
    @Assert(getCode == 2)
}

/// #194：读与写必须是**同一份**键清单。
///
/// 两份独立 `match` 漂移过一次：`hooks.mode` 是引擎自己写进 config.json、
/// 自己 `loadConfig` 会读的键，读侧没它、写侧也没有它 ——
/// 用户既查不到也改不了一个引擎自己维护的配置。
/// 只钉「最显眼的那一对」没用，这里把键表整个钉住。
@Test
func testConfigReadAndWriteCoverTheSameKeys(): Unit {
    let cfg = Config.defaults()
    // 键表就是唯一来源：改它时两边必须一起改。
    let keys = configKnownKeys()
    @Assert(keys.size >= 4)

    for (k in keys) {
        // 读：每个键都读得出（不许有「只写不读」）
        var readOk = true
        try {
            let _ = configGetValue(cfg, k)
        } catch (e: DgError) {
            readOk = false
        }
        @Assert(readOk)
        // 写：每个键都用**它自己的合法样例值**设得上。
        //
        // ⚠️ 原来这里塞的是一个占位串 `"1"`（roots 除外）。`language` 有了校验之后
        //（#203）`"1"` 立刻非法 —— 这条测试因此变红。
        // 修法**不是**给 language 特殊-case：那等于把校验放宽回「任意值」，
        // 正好抵消 #203。要么放宽判据、要么承认「每个键的合法值不同」，
        // 后者才是事实：样例值收在 configKeySample（与 configKnownKeys 成对维护）。
        let sample = configKeySample(k)
        // 新键漏登记样例值就红，不给它偷偷滑过去的余地
        @Assert(sample.isSome())
        var writeOk = true
        try {
            let _ = configSetValue(cfg, k, sample.getOrThrow())
        } catch (e: DgError) {
            writeOk = false
        }
        @Assert(writeOk)
        // 样例值必须**真被读回来** —— 写进去了但读出来是别的/null，就是 #202 那种谎报成功
        let back = Json.pretty(configGetValue(cfg, k))
        @Assert(back != "null")
        @Assert(back.size > 0)
    }

    // 反向：已删除的键必须**两端都**拒绝。
    // `server.port` 曾是 `config set` 打印「✓ 已设置」而零消费方的死键（#194），
    // `hooks.mode` 曾是引擎自己维护却查不到也改不了的键。
    for (dead in ["server.port", "server.host", "hooks.mode"]) {
        var r = false
        try {
            let _ = configGetValue(cfg, dead)
        } catch (e: DgError) {
            r = true
        }
        @Assert(r)
        var w = false
        try {
            let _ = configSetValue(cfg, dead, "x")
        } catch (e: DgError) {
            w = true
        }
        @Assert(w)
    }
}

@Test
func testMilestoneLineFormatting(): Unit {
    let it = Json.obj()
    Json.set(it, "projectName", Json.of("demo"))
    Json.set(it, "name", Json.of("v1.0"))
    Json.set(it, "status", Json.of("open"))
    Json.set(it, "targetDate", Json.of("2026-12-01"))
    Json.set(it, "daysToTarget", Json.of(62))
    Json.set(it, "commitsSince", Json.of(12))
    Json.set(it, "tagReached", Json.of(false))
    Json.set(it, "overdue", Json.of(false))
    let line = milestoneLine(it, "zh")
    @Assert(line.contains("demo｜v1.0"))
    @Assert(line.contains("进行中"))
    @Assert(line.contains("还剩 62 天"))
    @Assert(line.contains("12 提交"))
    // en 分支（M15 残留：本行原先整行硬编码中文）
    @Assert(milestoneLine(it, "en").contains("in progress"))
    @Assert(milestoneLine(it, "en").contains("62 days left"))
    @Assert(milestoneLine(it, "en").contains("12 commits since creation"))

    // 逾期展示
    let od = Json.obj()
    Json.set(od, "projectName", Json.of("demo"))
    Json.set(od, "name", Json.of("old"))
    Json.set(od, "status", Json.of("open"))
    Json.set(od, "targetDate", Json.of("2026-01-01"))
    Json.set(od, "daysToTarget", Json.of(-9))
    Json.set(od, "commitsSince", Json.of(0))
    Json.set(od, "tagReached", Json.of(false))
    Json.set(od, "overdue", Json.of(true))
    @Assert(milestoneLine(od, "zh").contains("已逾期"))
    @Assert(milestoneLine(od, "zh").contains("逾期 9 天"))
    @Assert(milestoneLine(od, "en").contains("overdue"))
    @Assert(milestoneLine(od, "en").contains("9 days overdue"))
}

@Test
func testMilestoneJsonRoundTrip(): Unit {
    let base = "/tmp/deepgit-mj-${nowMillis()}"
    ensureDir(base)
    enterTestHome(base)
    let (m, _) = addMilestone("p_rt", "v2.0", "desc", "2027-06-01", "v2.0.0")
    let p = ProjectEntry("p_rt", "demo", "/tmp/nowhere", "git", "", nowIso(), ArrayList<String>(), false)
    let prog = milestoneProgress(m, "", "")
    let j = milestoneJson(p, prog)
    @Assert(Json.strAt(j, "projectName", "") == "demo")
    @Assert(Json.strAt(j, "tagName", "") == "v2.0.0")
    @Assert(Json.strAt(j, "targetDate", "") == "2027-06-01")
    exitTestHome()
    removePathIfExists(base)
}

@Test
func testCmdContextRejectsMultipleProjects(): Unit {
    // 原实现只取 refs[0]，多余项目名被静默忽略，调用方以为全部生效了
    // 注意：cmd* 收到的是已剥离命令名的 rest，命令名不在其中
    let rest = ArrayList<String>(["aaa", "bbb"])
    let ctx = CliContext(ArrayList<String>(["context"]))
    var threw = false
    try {
        cmdContext(rest, ctx)
    } catch (e: DgError) {
        threw = true
        @Assert(e.exitCode == 2)
    }
    @Assert(threw)
}

@Test
func testCmdContextUnknownProjectFailsLoudly(): Unit {
    // 原实现把 buildAgentContext 生成的错误文本当作正常 context 字段输出并 exit 0，
    // 自动化消费者只能靠字符串匹配才能发现失败。现在必须以 NOT_FOUND(1) 退出。
    let base = "/tmp/deepgit-ctx-${nowMillis()}"
    ensureDir(base)
    enterTestHome(base)
    let rest = ArrayList<String>(["__no_such_project__"])
    let ctx = CliContext(ArrayList<String>(["context"]))
    var threw = false
    try {
        cmdContext(rest, ctx)
    } catch (e: DgError) {
        threw = true
        @Assert(e.exitCode == 1)
    }
    @Assert(threw)
    exitTestHome()
    removePathIfExists(base)
}

@Test
func testDocsPayloadAttributesEveryEntry(): Unit {
    // 不带项目名调用 docs 会平铺多个项目的文档；每条必须带 project 才可归属。
    let base = "/tmp/deepgit-docs-${nowMillis()}"
    let a = base + "/alpha"
    let b = base + "/beta"
    ensureDir(a)
    ensureDir(b)
    writeFileAtomic(a + "/README.md", "# Alpha\n")
    writeFileAtomic(b + "/README.md", "# Beta\n")

    let pa = ProjectEntry("p_a", "alpha", a, "git", "", nowIso(), ArrayList<String>(), false)
    let pb = ProjectEntry("p_b", "beta", b, "git", "", nowIso(), ArrayList<String>(), false)
    let both = ArrayList<ProjectEntry>([pa, pb])
    let payload = docsPayload(both, Config.defaults())

    let docs = Json.arrAt(payload, "docs")
    @Assert(docs.size > 0)
    // 每一条都必须能说清自己属于哪个项目
    for (d in docs) {
        let owner = Json.strAt(d, "project", "")
        @Assert(owner == "alpha" || owner == "beta")
        // 内容也要能对上所属项目
        let content = Json.strAt(d, "content", "")
        if (owner == "alpha") {
            @Assert(content.contains("Alpha"))
        } else {
            @Assert(content.contains("Beta"))
        }
    }
    // 多项目时 envelope 不给单一 project
    @Assert(!Json.has(payload, "project"))

    // 单项目时 envelope 带 project（与 /api/docs 对齐）
    let one = ArrayList<ProjectEntry>([pa])
    let single = docsPayload(one, Config.defaults())
    @Assert(Json.strAt(single, "project", "") == "alpha")

    removePathIfExists(base)
}

@Test
func testDocsPayloadDisclosesUnreadableInsteadOfShorteningArray(): Unit {
    // docs 数组少一条，消费方无从判断是「这个项目没有 README」还是「读不出来」。
    // 契约：unreadable 键**一直存在**（空时是空数组），
    // 读失败的文档按项目点名，而不是从数组里悄悄消失。
    let base = "/tmp/deepgit-docsp-${nowMillis()}"
    let a = base + "/alpha"
    let b = base + "/beta"
    ensureDir(a)
    ensureDir(b)
    writeFileAtomic(a + "/README.md", "# Alpha\n")
    // beta 的 README 存在但是目录 → 存在性为真、读取必失败
    ensureDir(b + "/README.md")

    let pa = ProjectEntry("p_a", "alpha", a, "git", "", nowIso(), ArrayList<String>(), false)
    let pb = ProjectEntry("p_b", "beta", b, "git", "", nowIso(), ArrayList<String>(), false)
    let payload = docsPayload(ArrayList<ProjectEntry>([pa, pb]), Config.defaults())

    // 键必须存在，哪怕没人失败
    @Assert(Json.has(payload, "unreadable"))
    // 好的那份照常在数组里
    let docs = Json.arrAt(payload, "docs")
    @Assert(docs.size == 1)
    @Assert(Json.strAt(docs[0], "project", "") == "alpha")
    // 坏的那份被点名，且带上项目归属
    let unread = Json.arrAt(payload, "unreadable")
    @Assert(unread.size == 1)
    @Assert(Json.strAt(unread[0], "project", "") == "beta")
    @Assert(Json.strAt(unread[0], "unreadable", "") == "README.md")

    // 全部可读时 unreadable 是空数组而不是缺键
    let okPayload = docsPayload(ArrayList<ProjectEntry>([pa]), Config.defaults())
    @Assert(Json.has(okPayload, "unreadable"))
    @Assert(Json.arrAt(okPayload, "unreadable").size == 0)

    removePathIfExists(base)
}

@Test
func testDoubleDashEndsFlagParsing(): Unit {
    // `--` 以前只是个「无值 flag」被跳过，后面仍然在 flag 空间里：
    //   moongit report -- --out /tmp/x.md   → --out 被正常解析，报告写进了 /tmp/x.md
    // 调用方以为自己传的是字面量，实际被引擎改了行为。现在 `--` 之后一律字面量。
    let args = ArrayList<String>(["update", "--", "--note", "v2 release"])

    // 位置参数：-- 之后全部保留
    let refs = positionalsOnly(args, VALUE_FLAGS)
    @Assert(refs.size == 3)
    @Assert(refs[0] == "update")
    @Assert(refs[1] == "--note")
    @Assert(refs[2] == "v2 release")

    // flag 查找不得越过 --
    @Assert(flagValue(args, "--note").isNone())

    // -- 之后是字面量，不该触发「带值 flag 缺值」报错
    validateValueFlags(args)

    // -- 之前仍然是 flag 空间
    let before = ArrayList<String>(["update", "--out", "/tmp/x.md", "--", "--weird-proj"])
    @Assert(flagValue(before, "--out").getOrThrow() == "/tmp/x.md")
    @Assert(positionalsOnly(before, VALUE_FLAGS).size == 2)

    // hasFlag 同样不得越过 --
    @Assert(!hasFlag(ArrayList<String>(["remove", "p", "--", "--purge"]), "--purge"))
    @Assert(hasFlag(ArrayList<String>(["remove", "p", "--purge"]), "--purge"))
}

@Test
func testValueFlagMissingValueFailsLoudly(): Unit {
    // 原实现 flagValue() 只看下一个 token，于是
    //   moongit add <path> --name --note  → 项目被真的注册成 "--note"（数据污染）
    //   moongit report --out              → 静默回落到默认路径，exit 0
    // 两种都必须在分发前就被拦下，且以 usage 错误（exit 2）退出。

    // 1) 带值 flag 后面紧跟另一个 flag
    var threw = false
    try {
        validateValueFlags(ArrayList<String>(["add", "/tmp/x", "--name", "--note"]))
    } catch (e: DgError) {
        threw = true
        @Assert(e.exitCode == 2)
        @Assert(e.message.contains("--name"))
    }
    @Assert(threw)

    // 2) 带值 flag 位于末尾，完全没有值
    threw = false
    try {
        validateValueFlags(ArrayList<String>(["report", "--out"]))
    } catch (e: DgError) {
        threw = true
        @Assert(e.exitCode == 2)
    }
    @Assert(threw)

    // 3) 正常调用不得被误伤：普通 flag 后面没有值是合法的
    validateValueFlags(ArrayList<String>(["report", "--json"]))
    validateValueFlags(ArrayList<String>(["remove", "projA", "--purge"]))
    validateValueFlags(ArrayList<String>(["journal", "projA", "--limit", "5"]))

    // 4) 逃生舱：值确实以 - 开头时用 --flag=值 单 token 形式，必须仍然可用
    //    （commit message 传 "--amend" 这类场景靠它）
    validateValueFlags(ArrayList<String>(["report", "--out=--weird"]))
    // 单横线开头的值也放行（commit message 传 "-Werror" 这类场景）
    validateValueFlags(ArrayList<String>(["journal", "projA", "--limit", "-5"]))
}

@Test
func testDefaultReportPathNeverCollides(): Unit {
    // 原实现用 nowMillis() % 100000 做后缀，而该值每 100 秒回绕一次：
    // 相隔 100 秒、毫秒偏移相同的两次生成得到同一文件名，后一次静默覆盖前一份
    // （定时任务按整点跑最容易踩到，历史报告全丢）。
    let base = "/tmp/deepgit-rep-${nowMillis()}"
    ensureDir(base)
    enterTestHome(base)

    let first = defaultReportPath()
    @Assert(first.endsWith(".md"))
    @Assert(first.contains("/reports/report-"))

    // 占位后立刻再取一次：即使落在同一毫秒，也必须换名而不是覆盖
    ensureDir(dirname(first))
    writeFileAtomic(first, "FIRST")
    let second = defaultReportPath()
    @Assert(second != first)
    @Assert(fileExists(first))
    @Assert(readFileTextOr(first, "") == "FIRST")

    // 再占位一次，序号必须继续递增（-02 / -03），不能又回到 first
    ensureDir(dirname(second))
    writeFileAtomic(second, "SECOND")
    let third = defaultReportPath()
    @Assert(third != first)
    @Assert(third != second)

    exitTestHome()
    removePathIfExists(base)
}

@Test
func testCmdReportRejectsMultipleProjects(): Unit {
    // 原实现只取 refs[0]，第二个项目名被静默忽略：用户以为导出的是两个项目的
    // 全景报告，实际只有第一个，报告正文里也不会有任何提示。
    let base = "/tmp/deepgit-rpt-${nowMillis()}"
    ensureDir(base)
    enterTestHome(base)
    let rest = ArrayList<String>(["aaa", "bbb"])
    let ctx = CliContext(ArrayList<String>(["report"]))
    var threw = false
    try {
        cmdReport(rest, ctx)
    } catch (e: DgError) {
        threw = true
        @Assert(e.exitCode == 2)
    }
    @Assert(threw)
    exitTestHome()
    removePathIfExists(base)
}

/// #184 接缝回归：**端到端跑 cmdReport**，钉住整群报告的接线。
///
/// 为什么必须在 cli 包里跑，而不是只测 `buildDashboard`：
/// 上一版的回归测试在 flow/dashboard.cj 里自己调
/// `buildDashboard(reg.projects, ...)` —— 它只证明了「渲染函数给什么数就写什么数」，
/// 根本没经过 `cmdReport` 那个决定「传什么进去」的地方。
/// 于是把 `let dashProjects = targets` 改回错误版本，测试**照样全绿**（负控验证时实测），
/// 而真实 `moongit report` 输出的「已注册」当场从 2 掉回 1。
/// 教训：抽成纯函数只是第一步，还得有一条真的走调用方的断言。
///
/// 负控（曾真实发红）：整群报告退回报 `targets`（已滤掉 disabled），
/// 报告写「项目总数（已注册） | 1」而注册表里明明有 2 个。
@Test
func testCmdReportGroupReportCountsDisabledAsRegistered(): Unit {
    let base = "/tmp/deepgit-regw-${nowMillis()}"
    let r1 = "${base}-a"
    let r2 = "${base}-b"
    let outPath = "${base}-out.md"
    let onePath = "${base}-one.md"
    ensureDir(r1)
    ensureDir(r2)
    for (r in [r1, r2]) {
        gitRun(r, ["init", "-b", "main"], false)
        writeFileAtomic("${r}/a.txt", "a")
        gitRun(r, ["-c", "user.name=t", "-c", "user.email=t@t", "add", "."], false)
        gitRun(r, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "i"], false)
    }
    enterTestHome(base)
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

        // ---- 分支一：整群报告，必须报「已注册 2 / 已停用 1」 ----
        let code = cmdReport(ArrayList<String>(["--out", outPath]), CliContext(ArrayList<String>(["report"])))
        @Assert(code == 0)
        let md = readFileTextOr(outPath, "")
        @Assert(md.contains("| 项目总数（已注册） | 2 |"))
        @Assert(md.contains("其中已停用（不参与统计） | 1"))

        // ---- 分支二：单项目报告，「总数」本来就该是 1 ----
        // 这条同样重要：修整群的时候很容易顺手把 reg.projects 到处传，
        // 于是单项目报告也变成「共 2 个」。两个分支必须都钉住。
        let code1 = cmdReport(ArrayList<String>(["bb", "--out", onePath]), CliContext(ArrayList<String>(["report"])))
        @Assert(code1 == 0)
        let md1 = readFileTextOr(onePath, "")
        @Assert(md1.contains("| 项目总数（已注册） | 1 |"))
    } finally {
        exitTestHome()
        removePathIfExists(outPath)
        removePathIfExists(onePath)
        removePathIfExists(base)
        removePathIfExists(r1)
        removePathIfExists(r2)
    }
}

@Test
func testUnknownFlagsAreRejected(): Unit {
    // 旧实现里未知 flag 落进 positionals 后被无声丢弃：
    // `moongit status --bogus` 照常 exit 0，`--limti 5` 照常用默认 20 条。
    // 打错一个字母 = 「命令成功执行，但用的是默认值」，自动化里最难查的一类。
    for (bad in ["--bogus", "--limti", "--dryrun", "--jsonn", "-z"]) {
        var threw = false
        try {
            validateKnownFlags(ArrayList<String>(["status", bad]))
        } catch (e: DgError) {
            threw = e.exitCode == 2
            @Assert(e.message.contains("未知 flag"))
        }
        @Assert(threw)
    }
    // --flag=value 形式只校验 flag 名
    validateKnownFlags(ArrayList<String>(["status", "--out=/tmp/x.md", "--name=NN"]))
    // 全部已知 flag 不得被误伤
    for (ok in KNOWN_FLAGS) {
        validateKnownFlags(ArrayList<String>(["status", ok]))
    }
    // 负数不是 flag
    validateKnownFlags(ArrayList<String>(["journal", "p", "--limit", "-5"]))
    // 普通位置参数不是 flag
    validateKnownFlags(ArrayList<String>(["status", "myproj", "/some/path"]))
    // -- 之后是字面量，不校验
    validateKnownFlags(ArrayList<String>(["status", "--", "--bogus"]))
}

@Test
func testBackupManifestRoundTripsAndSurvivesPruning(): Unit {
    // 备份目录名是 file.replace("/", "_")，映射不可逆：docs/AGENTS.md → docs_AGENTS.md，
    // 而合法文件名里本来也可以带下划线。verify 若靠目录名反推就会找错文件 ——
    // 找不到时会被静默跳过，或被误报成「文档已被删除」。
    let dir = "/tmp/deepgit-manifest-${nowMillis()}"
    ensureDir(dir)
    writeBackupManifest(dir, "docs/AGENTS.md")
    @Assert(readBackupManifest(dir) == "docs/AGENTS.md")

    // 清单不能被当成「最旧的备份」修剪掉：点号开头的名字排序最靠前
    for (i in 0..5) {
        writeFileAtomic("${dir}/20260101-00000${i}-AGENTS.md", "x")
    }
    pruneBackups(dir, 2)
    @Assert(listDir(dir).size == 3)          // 2 份备份 + 1 份清单
    @Assert(readBackupManifest(dir) == "docs/AGENTS.md")
    @Assert(fileExists("${dir}/20260101-000004-AGENTS.md"))

    // 老备份没有清单时返回空串，调用方据此退回目录名反推
    let legacy = "${dir}-legacy"
    ensureDir(legacy)
    writeFileAtomic("${legacy}/20260101-000000-README.md", "x")
    @Assert(readBackupManifest(legacy).isEmpty())
    removePathIfExists(dir)
    removePathIfExists(legacy)
}

@Test
func testDashboardReturnsExitCodeOnBothJsonAndTextPaths(): Unit {
    // 回归：cmdDashboard 算好了守卫 dashRc，却只在 `if (ctx.json)` 分支里 return，
    // 纯文本路径一路走到 `return 0` 把守卫丢了 ——
    // 而纯文本恰恰是**人工使用的默认入口**。
    //
    // 实测（2 个已注册项目目录全部移走）：
    //   dashboard --json → exit 1 ✓
    //   dashboard         → exit 0 ✗ 谎报成功
    //   status / report / context 两条路径都正确报 1
    let base = "/tmp/deepgit-dashrc-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let config = loadConfig()
    let reg = Registry()

    // 造两个「采集必然失败」的项目：路径指向从未存在过的目录
    reg.projects.add(goneEntryForDashboard("g1"))
    reg.projects.add(goneEntryForDashboard("g2"))

    // ⚠️ 必须落盘：cmdDashboard 内部走 loadRegistry() 读真实文件，
    // 局部变量 reg 它看不见 —— 只在内存里造 registry 会让断言跑在空表上。
    saveRegistry(reg)

    let dash = buildDashboard(reg.projects, config)
    let expected = groupExitCode(Json.intAt(Json.getOr(dash, "projects"), "total", -1),
                                 Json.intAt(Json.getOr(dash, "projects"), "listed", -1))
    // 前提：确实处于「全部采集失败」状态
    @Assert(expected == 1)

    // 两条路径必须给同一个码。
    // CliContext 只吃 args，json/quiet 由调用方设置 ——
    // 所以这里用可变字段而不是构造参数。
    let jsonCtx = CliContext(ArrayList<String>())
    jsonCtx.json = true
    jsonCtx.quiet = true      // 静默，避免测试输出污染
    @Assert(cmdDashboard(ArrayList<String>(), jsonCtx) == expected)

    let textCtx = CliContext(ArrayList<String>())
    textCtx.json = false
    textCtx.quiet = true
    @Assert(cmdDashboard(ArrayList<String>(), textCtx) == expected)

    exitTestHome()
    removePathIfExists(testHome)
    removePathIfExists(base)
}

/// 构造一个指向不存在路径的项目条目
private func goneEntryForDashboard(name: String): ProjectEntry {
    let gone = "/tmp/deepgit-nonexistent-${name}-${nowMillis()}"
    return ProjectEntry(projectIdFor(gone), name, gone, "git", "", nowIso(), ArrayList<String>(), false)
}

// 行为级回归：`moongit milestone reopen <项目> <名称> -q` 在「写入没生效」时
// 必须仍然告警。
//
// 原来的代码是：
//     if (!ctx.quiet) {
//         if (effective == status) { Log.ok("…→ open") } else { Log.warn("…生效状态仍是 done") }
//     }
// 两种结果被同一个 quiet 判断一起关掉了。于是：
//   1) reopen 写回 open，但同名 tag 还在 → milestoneProgress 按
//      「tag 达成即自动完成」算回 done
//   2) -q 下用户**什么都看不到**，退出码 0
// 3) 于是他以为里程碑重新打开了，实际还关着
// 这不是日志安静，是谎报结果 —— 比 #112 的「告警无处可去」更重一档：
// 那条至少还有 hook.log 可查，这条是当场骗人。
//
// 对照组：非 quiet 时打印 ok 而非 warn，--quiet 只该关掉 ok。
@Test
func testMilestoneReopenQuietStillWarnsWhenWriteDidNotTakeEffect(): Unit {
    let base = "/tmp/deepgit-mjq-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let repo = base + "-repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic(repo + "/a.txt", "a")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: a"], false)
    // 提前打 tag —— 这正是「reopen 写回 open 却被算回 done」的前提
    gitRun(repo, ["tag", "v1.0"], false)

    let (p, _) = addProject(repo, "mjq-demo", ArrayList<String>(), "")
    let (m, created) = addMilestone(p.id, "v1.0", "首个版本", "", "v1.0")
    @Assert(created)
    // 前提确认：先真的标一次 done，这样 reopen 才有对比可写
    @Assert(setMilestoneStatus(p.id, m.name, "done"))
    @Assert(milestoneProgress(m, p.path, "").effectiveStatus == "done")

    let seen = ArrayList<String>()
    Log.setErrOut({ s => seen.add(s) })
    Log.setColor(false)

    // cmdMilestone 内部不会自己同步 Log —— Log.setQuiet 是在 main2 里做的。
    // 测试直接调命令，所以必须手动对齐 ctx.quiet，否则测的是
    // 「quiet=false 下有没有告警」而不是「quiet 下有没有告警」。
    // 这是本条最容易空转绿的地方。
    func runReopen(quiet: Bool): String {
        seen.clear()
        let ctx = CliContext(ArrayList<String>())
        ctx.json = false
        ctx.quiet = quiet
        Log.setQuiet(quiet)
        let rc = cmdMilestone(ArrayList<String>(["reopen", "mjq-demo", "v1.0"]), ctx)
        @Assert(rc == 0)                        // 两次都 exit 0 —— 问题不在退出码
        let sb = StringBuilder()
        for (s in seen) {
            sb.append(s)
            sb.append("\n")
        }
        return sb.toString()
    }

    let loudText = runReopen(false)
    // 前提：非 quiet 路径确实报了「未生效」告警。
    // 少了它，下面 quiet 路径的断言可能只是「本来就没话说」的空转绿。
    @Assert(loudText.contains("生效状态仍是"))
    @Assert(loudText.contains("! "))
    @Assert(!loudText.contains("→ open"))

    // 关键断言：quiet 下同样必须出声，且不得报成功口吻
    let quietText = runReopen(true)
    @Assert(quietText.contains("生效状态仍是"))
    @Assert(quietText.contains("! "))
    @Assert(!quietText.contains("→ open"))

    // 对照组：quiet 本身仍然生效（否则上面两条可能只是 Log 整体静音的假象）。
    // 叙述层必须被关掉 —— 证明 quiet 没被顺带关掉。
    seen.clear()
    Log.setQuiet(true)
    Log.ok("NARRATION-PROBE")
    var narration = StringBuilder()
    for (s in seen) {
        narration.append(s)
        narration.append("\n")
    }
    @Assert(!narration.toString().contains("NARRATION-PROBE"))

    Log.setQuiet(false)
    Log.setColor(true)
    Log.resetErrOut()
    exitTestHome()
    removePathIfExists(repo)
    removePathIfExists(deepgitPath(["store", p.id]))
    removePathIfExists(testHome)
    removePathIfExists(base)
}

@Test
func testVerifyJsonMustNotSubtractMissingTwice(): Unit {
    // 文档缺失那一支在 `checked += 1` **之前**就 continue 了，
    // 所以 missing 根本不在 checked 里。原来 JSON 路径算
    // `checked - undeterminedCount - missing`，减了第二次：
    //   checked=1、undetermined=0、missing=1 → passed=0
    // 而**同一命令的文本路径**算出 1，打印「✓ 校验通过：1 份」。
    // JSON 与文本自相矛盾。
    //
    // 后果比「数字不好看」严重：verified:false 配 note
    // 「暂无可校验的文档（需要先执行 moongit update）」会**直接诱导 agent
    // 重跑 update 覆盖用户文档** —— 而 README 其实刚刚逐字节校验通过。
    //
    // 审计给的原始场景：README.md 与 AGENTS.md 都跑过 update 生成备份，
    // 随后删掉 AGENTS.md → checked=1 / missing=1。
    let (passed, verified, note) = verifyOutcome(1, 0, 1, 0)
    // 核心：那一份 README 确实校验通过了，就该算通过
    @Assert(passed == 1)
    @Assert(verified)
    @Assert(note.isEmpty())
    // 且绝不能出现「先跑 update」那句 —— 它是诱导覆盖用户文档的元凶
    @Assert(!note.contains("moongit update"))

    // 真的什么都不可校验时，措辞必须把「先跑 update」说出来
    let (p0, v0, n0) = verifyOutcome(0, 0, 0, 0)
    @Assert(p0 == 0)
    @Assert(!v0)
    @Assert(n0.contains("moongit update"))

    // 「可校验的都缺失」与「什么都没有」必须分开 ——
    // 前者该去恢复文档，后者该先 update，处置完全不同
    let (p1, v1, n1) = verifyOutcome(0, 0, 3, 0)
    @Assert(p1 == 0)
    @Assert(!v1)
    @Assert(n1.contains("文档缺失"))
    @Assert(n1.contains("可从备份恢复"))
    @Assert(!n1.contains("需要先执行 moongit update"))

    // 无法判定不算通过
    let (p2, v2, n2) = verifyOutcome(2, 2, 0, 0)
    @Assert(p2 == 0)
    @Assert(!v2)
    @Assert(n2.contains("无法判定"))

    // 全部通过
    let (p3, v3, n3) = verifyOutcome(3, 0, 5, 0)
    @Assert(p3 == 3)
    @Assert(v3)
    @Assert(n3.isEmpty())
}

/// #195：`failures` 原来**根本没传进** verifyOutcome，于是
///   checked=1 / failures=1 / undetermined=0 / missing=0
/// → passed=1 → `verified: true`
/// 而同一份信封里 `failures: 1`、`documents[0].ok: false`、退出码 1。
/// 三个信号里两个说不通过、一个说通过。
///
/// 后果是实的：退出码当时是对的，所以**只有读 JSON 的消费方会被骗** ——
/// 脚本 / 客户端 / MCP 一律只看那个布尔。
/// 真实来源：引擎自己新建的 README.md 没有任何写入前快照（缺陷见
/// `testVerifyOnEngineCreatedDocumentReportsUndeterminedNotTampered`），
/// 而 verify 把元数据文件 `.owned` 当成备份去比对，得出「不一致」。
///
/// ⚠️ `checked` 大不能把失败洗成通过：checked=9 / failures=1 也必须
/// verified=false —— 否则「大部分通过」就成了漏看那一份的借口。
@Test
func testVerifiedMustBeFalseWheneverThereIsAnyFailure(): Unit {
    let (p1, v1, n1) = verifyOutcome(1, 0, 0, 1)
    @Assert(!v1)
    // 通过数要减掉失败的，否则「校验通过：1 份」会和 failures=1 并排出现
    @Assert(p1 == 0)
    @Assert(n1.contains("1 份文档"))

    // 大量通过 + 少量失败：一律不算通过
    let (p9, v9, n9) = verifyOutcome(9, 0, 0, 1)
    @Assert(!v9)
    @Assert(p9 == 8)
    @Assert(n9.contains("1 份文档"))

    // 失败 + 无法判定 + 缺失 三者同时存在：verified 仍是 false
    let (p2, v2, n2) = verifyOutcome(2, 1, 3, 1)
    @Assert(!v2)
    @Assert(p2 == 0)

    // 零失败时的行为不得被这次改动带偏
    let (p3, v3, n3) = verifyOutcome(3, 0, 0, 0)
    @Assert(v3)
    @Assert(p3 == 3)
    @Assert(n3.isEmpty())
    let (p4, v4, n4) = verifyOutcome(2, 2, 0, 0)
    @Assert(!v4)
    @Assert(n4.contains("无法判定"))
}

/// #195（第三处）：verify 的**文本出口与 JSON 出口不许各算一遍**。
///
/// 原来文本路径自己写了一遍 `passed = checked - undeterminedCount`，
/// 与 JSON 路径的 verifyOutcome 是两份实现，且同样不减 failures。
/// 同一个数字两处算法，漂移只是时间问题 —— #195 就是在 JSON 那侧漏的。
/// 收口后两侧共用 verifyOutcome，这条钉住那个收口。
@Test
func testVerifyTextPathMustShareTheSameOutcomeComputation(): Unit {
    let src = readFileTextChecked("src/cli/cli.cj").getOrThrow()
    // 剥注释后再数：注释里为了说明历史必然提到这两处，别把它算进去
    let sb = StringBuilder()
    var blk = false
    for (raw in src.split("\n")) {
        let (l, nb) = stripCjComment(raw, blk)
        blk = nb
        sb.append(l)
        sb.append("\n")
    }
    let code = sb.toString()
    // cmdVerify 整段
    let a = code.indexOf("func cmdVerify(")
    @Assert(a.isSome())
    let rest = code[a.getOrThrow()..]
    let b = rest.indexOf("\nfunc ")
    let body = if (b.isSome()) { rest[0..b.getOrThrow()] } else { rest }

    // 1) 算 passed/verified 的地方只有一处：verifyOutcome 的调用点
    @Assert(body.contains("verifyOutcome("))
    // 2) 不许再出现手写的减法（两份算法必然漂移）
    @Assert(!body.contains("checked - undeterminedCount"))
    @Assert(!body.contains("checked - undetermined"))
    // 3) 文本路径与 JSON 路径都必须把 failures 传进去
    @Assert(body.contains("missing, failures)"))
}

/// #195（第四处）：备份目录里的元数据不是备份。收口在 latestRealBackup，
/// 这里钉住 cmdVerify 必须走那个接缝，而不是自己 listDir 一遍。
@Test
func testCmdVerifyMustUseLatestRealBackupSeam(): Unit {
    let src = readFileTextChecked("src/cli/cli.cj").getOrThrow()
    let a = src.indexOf("func cmdVerify(")
    @Assert(a.isSome())
    let rest = src[a.getOrThrow()..]
    let b = rest.indexOf("\nfunc ")
    let body = if (b.isSome()) { rest[0..b.getOrThrow()] } else { rest }
    @Assert(body.contains("latestRealBackup("))
    // 直接对 listDir 取「字典序最大的那个」就是原缺陷的形状
    @Assert(!body.contains("b.name > latest.name"))
}

/// #195（第二处）：`verifyOutcome` 的 if 链**顺序与状态不对应**。
///
/// 原来 `checked == 0 && missing == 0` 排在 undetermined 之前，于是
/// 「一份文档无法判定（引擎新建、没有写入前快照）」会拿到
/// note「暂无可校验的文档（**需要先执行 moongit update**）」——
/// 而用户刚刚跑过 update，再跑一次不会有任何变化。
///
/// 那句 note 存在的目的就是诱导 agent 重跑 update，所以指错方向
/// 比不说更糟：它会把一份好文档再覆盖一遍，却什么都没修好。
/// 真实复现：注册一个只有 a.txt 的空仓库，跑一次 update 生成 README.md，
/// 再 verify ⇒ checked=0 / undetermined=1 / missing=0。
@Test
func testUndeterminedMustNotBeAdvisedToRerunUpdate(): Unit {
    let (p, v, n) = verifyOutcome(0, 1, 0, 0)
    @Assert(!v)
    @Assert(p == 0)
    // 处置方向必须说对：去弄快照，不是重跑 update
    @Assert(n.contains("无法判定"))
    @Assert(n.contains("写入前快照"))
    @Assert(!n.contains("需要先执行 moongit update"))

    // 真的什么都没有时，「先跑 update」才是对的处置 —— 不得被上一条带跑
    let (_, v0, n0) = verifyOutcome(0, 0, 0, 0)
    @Assert(!v0)
    @Assert(n0.contains("需要先执行 moongit update"))

    // 缺失的处置方向是「从备份恢复」，与上面两个都不同
    let (_, v2, n2) = verifyOutcome(0, 0, 2, 0)
    @Assert(!v2)
    @Assert(n2.contains("可从备份恢复"))
    @Assert(!n2.contains("需要先执行 moongit update"))
    @Assert(!n2.contains("写入前快照"))
}

@Test
func testWorkableTargetsNeverReportsSilenceAsSuccess(): Unit {
    // 「没有活可干」必须与「活干完了」在退出码上可区分。
    //
    // 旧实现在空注册表下静默 exit 0、stdout 全空：
    //   moongit update        → 无输出，exit 0
    //   moongit update --json → `[]`，exit 0
    //   moongit deep          → 无输出，exit 0
    // agent / CI 读到 exit 0 就认定「全部项目已是最新」，于是永远不去跑
    // scan / add，注册表就一直空着 —— 静默降级成事实性谎言。
    //
    // 关键约束：**读路径不受影响**。status / journal / list 在没有项目时
    // 必须继续给合法答案，把它们改成报错会直接打断客户端的解码契约。
    let base = "/tmp/deepgit-notargets-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    try {
        // 成因 1：注册表为空
        writeFileAtomic(deepgitPath(["registry.json"]), "{\"version\":1,\"projects\":[]}")
        var emptyMsg = ""
        try {
            requireWorkableTargets(ArrayList<ProjectEntry>())
        } catch (e: DgError) {
            emptyMsg = e.message
        }
        @Assert(emptyMsg.contains("尚未注册任何项目"))
        @Assert(emptyMsg.contains("scan") || emptyMsg.contains("add"))

        // 成因 2：项目都在但全部 disabled —— 原因不同，
        // 笼统说「尚未注册」会让用户白跑一遍 scan
        writeFileAtomic(deepgitPath(["registry.json"]),
            "{\"version\":1,\"projects\":[" +
            "{\"id\":\"p1\",\"name\":\"a\",\"path\":\"/tmp/a\",\"kind\":\"git\",\"disabled\":true}," +
            "{\"id\":\"p2\",\"name\":\"b\",\"path\":\"/tmp/b\",\"kind\":\"git\",\"disabled\":true}]}")
        var disabledMsg = ""
        try {
            requireWorkableTargets(ArrayList<ProjectEntry>())
        } catch (e: DgError) {
            disabledMsg = e.message
        }
        @Assert(disabledMsg.contains("2 个项目"))
        @Assert(disabledMsg.contains("disabled"))
        // ⚠️ 负控：不能建议一个不存在的子命令。
        // `disabled` 全代码只读不写，没有 enable/disable 子命令，
        // 说「运行 moongit enable」是「说错了」而非「没说」。
        @Assert(!disabledMsg.contains("moongit enable"))
        @Assert(!disabledMsg.contains("moongit disable"))

        // 有目标时必须完全放行 —— 显式点名被 disabled 的项目也要能跑
        let okList = ArrayList<ProjectEntry>()
        okList.add(ProjectEntry("p1", "a", "/tmp/a", "git", "", nowIso(), ArrayList<String>(), true))
        requireWorkableTargets(okList)
    } finally {
        exitTestHome()
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

@Test
func testDashboardLanguageTruncationSaysItsDenominator(): Unit {
    // dashboard 文本路径原先只打 6 种语言就收工，无分母、也不读 languagesTruncated。
    // 「上限当全量」这一族的第 14 处。同样的两层截断在 report.cj 里早就写对了，
    // 两份拷贝一份对一份错。
    let dash = Json.obj()
    let langs = ArrayList<JsonValue>()
    for (i in 0..10) {
        let l = Json.obj()
        Json.set(l, "language", Json.of("L${i}"))
        Json.set(l, "count", Json.of(i + 1))
        langs.add(l)
    }
    Json.set(dash, "languages", JArr(langs))

    // 方向 1：显示 6 / 共 10 → 必须写出分母
    let notes = dashboardLanguageNotes(dash, 6)
    @Assert(notes.size == 1)
    @Assert(notes[0].contains("共 10 种语言"))
    @Assert(notes[0].contains("仅列前 6 种"))

    // 方向 2：全部显示得下 → **不得**出现分母提示（否则是给用户的假建议）
    @Assert(dashboardLanguageNotes(dash, 10).isEmpty())
    @Assert(dashboardLanguageNotes(dash, 20).isEmpty())

    // 方向 3：languagesTruncated 是**独立**的第二层截断，
    // 之前文本路径完全没读，于是这个事实只在 --json 下可见
    Json.set(dash, "languagesTruncated", Json.of(true))
    let both = dashboardLanguageNotes(dash, 6)
    @Assert(both.size == 2)
    @Assert(both[1].contains("跟踪文件"))
    // 上限数字必须来自 kernel 的同一个常量，不能在这里再硬编码一遍
    @Assert(both[1].contains("${MAX_TRACKED_FILES}"))

    // 方向 4：一个语言都没有时彻底沉默
    let empty = Json.obj()
    Json.set(empty, "languages", JArr(ArrayList<JsonValue>()))
    @Assert(dashboardLanguageNotes(empty, 6).isEmpty())

    // 方向 5（缺陷 #187）：**采集失败**是第 3 层，与两层截断都不同。
    // 截断 = 看了留一部分；失败 = 压根没看成。
    // 少了它，失败的项目静默消失，而 languagesTruncated 仍是 false，
    // 等于反过来告诉读者「这份分布是完整的」。
    let fail = Json.obj()
    Json.set(fail, "languages", JArr(langs))
    Json.set(fail, "languagesTruncated", Json.of(false))   // ← 关键：截断标志是「正常」的
    Json.set(fail, "languagesFailed", Json.of(2))
    let reasons = ArrayList<JsonValue>()
    reasons.add(Json.of("git ls-files 失败：index 损坏"))
    Json.set(fail, "languagesFailedReasons", JArr(reasons))
    let fnotes = dashboardLanguageNotes(fail, 6)
    // 两条：分母（10 选 6）+ 采集失败。失败这条必须**独立**存在，
    // 少一条就意味着读者把剩下的 2 种语言当成了全量画像。
    @Assert(fnotes.size == 2)
    @Assert(fnotes[1].contains("2 个项目语言采集失败"))
    // 必须说清「不是这个项目群没有这些语言」，否则读者仍会照着旧数字下结论
    @Assert(fnotes[1].contains("不是"))
    // 原因示例要能读出来：reasons 是字符串**值**数组，用 strAt 会恒为空串
    @Assert(fnotes[1].contains("index 损坏"))

    // 方向 6：languagesFailed 缺键时按 0 处理，不得凭空造一条提示
    let noKey = Json.obj()
    Json.set(noKey, "languages", JArr(langs))
    @Assert(dashboardLanguageNotes(noKey, 6).size == 1)   // 只有分母那条
}

@Test
func testDashboardTextDisclosesListedCountAndStoreDegradation(): Unit {
    // 这两行文本曾经内联在 cmdDashboard 里，数据源侧测得再严也测不到它们：
    // 负控把 listed 换回 total、把 degraded 压成 false，测试照样全绿。
    // 判定必须落在能测的纯函数上 —— 这条就是那个纯函数的护栏。

    // 一、3 个注册项目、1 个路径失效：文本必须说「共 3 个（1 个读取失败）」
    let projs = Json.obj()
    Json.set(projs, "total", Json.of(2))       // 采集成功数
    Json.set(projs, "listed", Json.of(3))      // 注册表条数 —— 文本必须用这个
    Json.set(projs, "failed", Json.of(1))
    Json.set(projs, "active7d", Json.of(2))
    Json.set(projs, "active30d", Json.of(2))
    Json.set(projs, "dirty", Json.of(0))
    let line = dashboardProjectLine(projs, "zh")
    @Assert(line.contains("共 3 个"))
    @Assert(line.contains("1 个读取失败"))
    // 关键：不能出现「共 2 个」
    @Assert(!line.contains("共 2 个"))

    // 全部失败时也要说，不能沉默地报个 0
    let allBad = Json.obj()
    Json.set(allBad, "total", Json.of(0))
    Json.set(allBad, "listed", Json.of(4))
    Json.set(allBad, "failed", Json.of(4))
    let badLine = dashboardProjectLine(allBad, "zh")
    @Assert(badLine.contains("共 4 个"))
    @Assert(badLine.contains("4 个读取失败"))

    // 健康时不要制造噪音
    let clean = Json.obj()
    Json.set(clean, "total", Json.of(2))
    Json.set(clean, "listed", Json.of(2))
    Json.set(clean, "failed", Json.of(0))
    @Assert(!dashboardProjectLine(clean, "zh").contains("读取失败"))

    // 二、milestones.json 损坏：四个计数全是 0，但那不是「没有里程碑」
    let broken = Json.obj()
    Json.set(broken, "open", Json.of(0))
    Json.set(broken, "done", Json.of(0))
    Json.set(broken, "dropped", Json.of(0))
    Json.set(broken, "unknown", Json.of(0))
    Json.set(broken, "degraded", Json.of(true))
    Json.set(broken, "storeHealth", Json.of("corrupt"))
    Json.set(broken, "readCount", Json.of(0))
    let msLine = dashboardMilestoneLine(broken, "zh")
    @Assert(msLine.contains("读不出来"))
    @Assert(msLine.contains("不是「没有」"))
    @Assert(msLine.contains("corrupt"))

    // 健康时不得出现任何损坏告警
    let ok = Json.obj()
    Json.set(ok, "open", Json.of(1))
    Json.set(ok, "done", Json.of(0))
    Json.set(ok, "dropped", Json.of(0))
    Json.set(ok, "unknown", Json.of(0))
    @Assert(!dashboardMilestoneLine(ok, "zh").contains("读不出来"))

    // unknown（仓库读不出来）必须与 degraded（存储读不出来）分开说
    let both = Json.obj()
    Json.set(both, "open", Json.of(0))
    Json.set(both, "done", Json.of(0))
    Json.set(both, "dropped", Json.of(0))
    Json.set(both, "unknown", Json.of(2))
    Json.set(both, "degraded", Json.of(false))
    let bothLine = dashboardMilestoneLine(both, "zh")
    @Assert(bothLine.contains("无法核验 2"))
    @Assert(!bothLine.contains("milestones.json"))
}

@Test
func testOrphanedMilestonesAreNeverReportedAsNoMilestones(): Unit {
    // 里程碑是**用户手写**的数据。`remove` 一个项目之后，它的里程碑数据
    // 还在 milestones.json 里，但 projectId 已经对不上任何注册项目 ——
    // 而 milestone list 是按注册表遍历再按 id 过滤的，于是：
    //     milestone list → 「（无里程碑）」  exit 0
    //
    // 用户看到的是「我 remove 掉的项目，它的里程碑也没了」。
    // 实际是「还在，但每一条命令都看不见」。
    // 「列不出来」被说成「不存在」，正是本引擎最高发的那族缺陷。
    let base = "/tmp/deepgit-orphan-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let repo = base + "-repo"
    try {
        ensureDir(repo)
        gitRun(repo, ["init", "-b", "main"], false)
        writeFileAtomic(repo + "/a.txt", "1")
        gitRun(repo, ["add", "."], false)
        gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: x"], false)
        let (p, _) = addProject(repo, "orph", ArrayList<String>(), "")
        let (_, _) = addMilestone(p.id, "v1.0 重要里程碑", "", "2027-01-01", "")

        // 前提：注册时列得出来
        var listedBefore: Int64 = 0
        for (pr in loadRegistry().projects) {
            listedBefore += milestonesOf(loadMilestones(), pr.id).size
        }
        @Assert(listedBefore == 1)

        // 取消注册 —— 数据必须仍在文件里（只是没人能列出它了）
        _ = removeProject("orph", false)
        let stillOnDisk = loadMilestones()
        @Assert(stillOnDisk.size == 1)
        @Assert(stillOnDisk[0].name == "v1.0 重要里程碑")

        // 核心：注册表里已经没有这个 id 了 ⇒ 任何按项目过滤的列法都给不出它
        var listedAfter: Int64 = 0
        for (pr in loadRegistry().projects) {
            listedAfter += milestonesOf(loadMilestones(), pr.id).size
        }
        @Assert(listedAfter == 0)
        // 读得到 1 条、列得出 0 条 —— 这个差值本身就是「列不出来」这个状态
        // 存在的证明，而「（无里程碑）」正是把它说成「不存在」的那句话。

        // 重新注册同一路径 → 立刻恢复显示（证明数据没丢，只是不可见）
        let (p2, _) = addProject(repo, "orph", ArrayList<String>(), "")
        @Assert(p2.id == p.id)     // id 由路径推导，必须一致
        @Assert(milestonesOf(loadMilestones(), p2.id).size == 1)
    } finally {
        exitTestHome()
        removePathIfExists(repo)
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

@Test
func testMilestoneEmptyStateDistinguishesOrphansFromNothing(): Unit {
    // 这是「（无里程碑）」那句话的唯一出口。判定必须可测 ——
    // 第一版把 orphans.isEmpty() 内联在渲染里，负控去掉它测试照样全绿。
    //
    // 三种「看起来都是 0」：
    //   存储坏 + 一条也没读到   → 必须说「一条也没读到」且 exit 1
    //   有条目但列不出来（孤儿） → **绝不能**说「无里程碑」
    //   文件里确实一条都没有     → 才可以说「（无里程碑）」
    let (line1, rc1) = milestoneEmptyState(0, 0, "ok", 0, "zh")
    @Assert(line1 == "（无里程碑）")
    @Assert(rc1 == 0)

    // 核心：孤儿存在时不能说「无里程碑」
    let (line2, rc2) = milestoneEmptyState(0, 1, "ok", 0, "zh")
    @Assert(!line2.contains("无里程碑"))
    @Assert(line2 == "")          // 什么都不打印，交给孤儿告警那一段
    @Assert(rc2 == 0)

    // 列得出条目时同样不是空态
    let (line3, _) = milestoneEmptyState(2, 0, "ok", 0, "zh")
    @Assert(line3 == "")

    // 存储坏：优先级最高，且退出码必须非零
    let (line4, rc4) = milestoneEmptyState(0, 0, "corrupt", 0, "zh")
    @Assert(line4.contains("一条也没读到"))
    @Assert(!line4.contains("（无里程碑）"))
    @Assert(rc4 == 1)
    // 存储坏 + 同时有孤儿：仍然是「读不出来」，不能说无里程碑
    let (line5, rc5) = milestoneEmptyState(0, 3, "corrupt", 0, "zh")
    @Assert(!line5.contains("（无里程碑）"))
    @Assert(rc5 == 1)
}

// #158 回归（一）：`moongit list` 不得采集停用项目。
//
// 真实故障：2 个项目，on2 手工置 disabled:true。
// 修之前 `list` 的输出是：
//     on2   git   /private/tmp/dg-scope/r2  暂无新变化
// —— 文本表格没有 disabled 这一列，停用项目顶着「暂无新变化」冒充健康项目，
// 用户完全看不出它已被停用；而那行 headline 是真的对 on2 跑了一串 git 子进程算出来的。
//
// 判别力来自这个对照：把停用项目的 path 指向一个**不存在**的目录。
//   修复后 → 「已停用（不采集）」（没去碰，所以碰不到）
//   修复前 → 「（读取失败：路径不存在…）」（去碰了，碰失败）
// 只断言「文案里有停用」是不够的，必须让它在「去碰了」的方向上会红。
@Test
func testListSkipsCollectionForDisabledProjects(): Unit {
    let cfg = Config.defaults()
    let missing = "/tmp/dg-definitely-missing-${nowMillis()}"

    // 停用 + 路径不存在：仍然必须是「已停用」，不能是「读取失败」
    let off = ProjectEntry("p_off", "off", missing, "git", "", nowIso(), ArrayList<String>(), true)
    let offLine = listRowHeadline(off, cfg)
    @Assert(offLine.contains("已停用"))
    @Assert(!offLine.contains("读取失败"))

    // 对照组：同样是路径不存在，但**启用** → 必须是「读取失败」。
    // 少了这条，上面的断言可能只是因为「这个路径在测试环境读不了」而恒真。
    let on = ProjectEntry("p_on", "on", missing, "git", "", nowIso(), ArrayList<String>(), false)
    @Assert(listRowHeadline(on, cfg).contains("读取失败"))
}

// #158 回归（二）：list 与 dashboard 的项目口径不同，必须两边都写明。
// list 报的是注册表（含停用），dashboard 报的是可处理项目（排除停用）——
// 数字不同是设计使然，但两边都沉默时用户无从判断谁错了。
@Test
func testListSummaryLineDisclosesDisabledCount(): Unit {
    // 无停用时不能凭空多出括号
    @Assert(listSummaryLine(2, 0, "zh") == "共 2 个项目。用 `moongit status <项目>` 看详情。")
    // 有停用时必须写明，并且写清是「不参与统计」——否则用户以为坏掉了
    let line = listSummaryLine(2, 1, "zh")
    @Assert(line.contains("共 2 个项目"))
    @Assert(line.contains("1 个已停用"))
    @Assert(line.contains("不参与统计"))
    // 全部停用也要照实说，不能变成「共 0 个」
    let all = listSummaryLine(1, 1, "zh")
    @Assert(all.contains("共 1 个项目"))
    @Assert(all.contains("1 个已停用"))
}

// #158 回归（三）：dashboard 里程碑行必须披露被筛掉和成孤儿的条目。
// 只过滤不披露的话，全停用场景下这行会变成「进行中 0 · 已达成 0 · 已放弃 0」，
// 用户读到的仍然是「一个里程碑都没有」—— 把「筛掉了」说成「没有」。
@Test
func testDashboardMilestoneLineDisclosesExcludedAndOrphaned(): Unit {
    let c = Json.obj()
    Json.set(c, "open", Json.of(1))
    Json.set(c, "done", Json.of(0))
    Json.set(c, "dropped", Json.of(0))
    Json.set(c, "unknown", Json.of(0))
    Json.set(c, "excludedDisabled", Json.of(2))
    Json.set(c, "orphaned", Json.of(1))
    let line = dashboardMilestoneLine(c, "zh")
    @Assert(line.contains("已停用项目的 2 条未计入"))
    @Assert(line.contains("1 条所属项目已不存在"))

    // 干净场景不能刷噪音
    let clean = Json.obj()
    Json.set(clean, "open", Json.of(3))
    Json.set(clean, "done", Json.of(0))
    Json.set(clean, "dropped", Json.of(0))
    Json.set(clean, "unknown", Json.of(0))
    Json.set(clean, "excludedDisabled", Json.of(0))
    Json.set(clean, "orphaned", Json.of(0))
    let cl = dashboardMilestoneLine(clean, "zh")
    @Assert(!cl.contains("已停用"))
    @Assert(!cl.contains("已不存在"))
    // 四种口径必须能同时出现，互不吞掉
    let all = Json.obj()
    Json.set(all, "open", Json.of(1))
    Json.set(all, "done", Json.of(0))
    Json.set(all, "dropped", Json.of(0))
    Json.set(all, "unknown", Json.of(4))
    Json.set(all, "degraded", Json.of(true))
    Json.set(all, "storeHealth", Json.of("corrupt"))
    Json.set(all, "readCount", Json.of(0))
    Json.set(all, "excludedDisabled", Json.of(1))
    Json.set(all, "orphaned", Json.of(1))
    let al = dashboardMilestoneLine(all, "zh")
    @Assert(al.contains("无法核验 4"))
    @Assert(al.contains("milestones.json"))
    @Assert(al.contains("已停用项目的 1 条未计入"))
    @Assert(al.contains("1 条所属项目已不存在"))
}

// #160 回归：全部里程碑挂在已停用项目上时，空态文案不能是「（无里程碑）」。
//
// 第一版把说明写成 `printOut(emptyLine)` 之外的一行 `Log.info`，
// 结果空态文案走 stdout、说明走 stderr，两个流顺序不可控。
// 实测输出：
//     （2 条里程碑属于已停用项目，未列出；…）   ← stderr，先 flush
//     （无里程碑）                              ← stdout
// 用户第一眼读到的仍然是那句谎报。修法是让判定自己产出一行确定文案。
//
// 判别力：这条必须精确命中「不能说无里程碑」。
// 负控 = 从 milestoneEmptyState 里删掉 excludedDisabled 那个分支。
@Test
func testMilestoneEmptyStateDistinguishesAllDisabledFromNone(): Unit {
    // 存储健康、读得到 0 条、孤儿 0 条、但有 1 条挂在停用项目上
    let (line, rc) = milestoneEmptyState(0, 0, "ok", 1, "zh")
    @Assert(!line.contains("无里程碑"))
    @Assert(line.contains("已停用"))
    @Assert(line.contains("1 条"))
    @Assert(rc == 0)          // 不是故障，只是被筛掉了

    // 真的什么都没有，才可以说「（无里程碑）」
    let (noneLine, noneRc) = milestoneEmptyState(0, 0, "ok", 0, "zh")
    @Assert(noneLine == "（无里程碑）")
    @Assert(noneRc == 0)

    // 存储坏优先级最高：即使同时有停用项目的条数，也必须说「一条也没读到」
    let (badLine, badRc) = milestoneEmptyState(0, 0, "corrupt", 2, "zh")
    @Assert(badLine.contains("一条也没读到"))
    @Assert(!badLine.contains("无里程碑"))
    @Assert(badRc == 1)

    // 孤儿优先于停用：孤儿段有自己的告警文案，空态不该抢话
    let (orphLine, _) = milestoneEmptyState(0, 1, "ok", 1, "zh")
    @Assert(orphLine == "")
}

// #160 负控补测：disabled 过滤必须在**可测的纯函数**上。
//
// 第一版只测 milestoneEmptyState（纯函数，但被喂的是手写的 excludedDisabled=1），
// NEGCTRL 把生产代码里的 `if (p.disabled) { continue }` 撤掉，测试照样全绿 ——
// 纯函数与生产路径之间没有任何联系。
//
// 第二版试图直接调 cmdMilestone 走生产路径，更糟：它的结果只走 stdout printOut，
// 单测捕获不到。
//
// 现在的形态：过滤/孤儿判定收敛成 milestoneListSelection 纯函数，
// cmdMilestone 真的调它，测试也真的测它。撤掉过滤 → 本条必须红。
@Test
func testMilestoneListSelectionExcludesDisabledAndSeparatesOrphans(): Unit {
    let on = ProjectEntry("p_on", "on", "/tmp/nope-on", "git", "", nowIso(), ArrayList<String>(), false)
    let off = ProjectEntry("p_off", "off", "/tmp/nope-off", "git", "", nowIso(), ArrayList<String>(), true)
    let mOn1 = Milestone("m1", "p_on", "启用1", "", "2027-01-01", "", "open", nowIso(), "")
    let mOn2 = Milestone("m2", "p_on", "启用2", "", "2027-02-01", "", "open", nowIso(), "")
    let mOff = Milestone("m3", "p_off", "停用项目", "", "2027-03-01", "", "open", nowIso(), "")
    let mGone = Milestone("m4", "p_gone", "孤儿", "", "2027-04-01", "", "open", nowIso(), "")
    let all = ArrayList<Milestone>([mOn1, mOn2, mOff, mGone])

    let sel = milestoneListSelection(ArrayList<ProjectEntry>([on, off]), all)

    // 只列启用项目的 2 条
    @Assert(sel.matched.size == 2)
    @Assert(sel.matched[0][1].name == "启用1")
    @Assert(sel.matched[1][1].name == "启用2")

    // 停用项目那条必须**按条数**排除，不是「一个项目算 1」
    @Assert(sel.excludedDisabled == 1)

    // ⚠️ 停用项目的 id 绝不能进孤儿：项目还在注册表里，只是 disabled。
    //    第一版修复漏了这一半，实测输出是「1 条里程碑指向已取消注册的项目」。
    @Assert(sel.orphans.size == 1)
    @Assert(sel.orphans[0].name == "孤儿")

    // 全部停用：matched 空、excludedDisabled 等于总条数、orphans 仍只算真孤儿
    let sel2 = milestoneListSelection(ArrayList<ProjectEntry>([ProjectEntry("p_on", "on", "/tmp/nope-on", "git", "", nowIso(), ArrayList<String>(), true), ProjectEntry("p_off", "off", "/tmp/nope-off", "git", "", nowIso(), ArrayList<String>(), true)]), all)
    @Assert(sel2.matched.isEmpty())
    @Assert(sel2.excludedDisabled == 3)      // 启用1 + 启用2 + 停用项目
    @Assert(sel2.orphans.size == 1)

    // 停用项目名下有多条时必须逐条计
    let mOff2 = Milestone("m5", "p_off", "停用项目2", "", "2027-05-01", "", "open", nowIso(), "")
    let sel3 = milestoneListSelection(
        ArrayList<ProjectEntry>([on, off]),
        ArrayList<Milestone>([mOn1, mOff, mOff2, mGone]),
    )
    @Assert(sel3.excludedDisabled == 2)
    @Assert(sel3.matched.size == 1)
}

// #162 回归：/api/docs 的 unreadable 类型必须与 CLI 一致，且 docsPayload 恒发 project。
//
// 审计实测（把 README.md 换成同名目录，使其存在但读不出）：
//     CLI : "unreadable": [ {"project":"x","unreadable":"README.md"} ]
//     HTTP: "unreadable": "README.md"        ← 裸字符串，类型都不同
// 按 CLI 契约写 for (x in payload.unreadable) 的客户端拿到 string，
// 会把每个字符当对象遍历 —— 直接抛异常。
//
// 根因是 HTTP 侧手写了第二份组装逻辑，没复用已经是纯函数的 docsPayload。
// 这里锁住纯函数本身；HTTP 路由是否真的调它，见端到端实测。
@Test
func testDocsPayloadUnreadableIsStructuredArrayNotString(): Unit {
    let base = "/tmp/dg_docspayload_${nowMillis()}"
    let testHome = "${base}/home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic("${base}/README.md", "# ok\n")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)
    let (p, _) = addProject(base, "docsp", ArrayList<String>(), testHome)

    let payload = docsPayload(ArrayList<ProjectEntry>([p]), Config.defaults())
    // unreadable 必须是**数组**，不是字符串。这是 HTTP 侧崩客户端的直接原因。
    @Assert(Json.arrAt(payload, "unreadable").size == 0)
    @Assert(Json.has(payload, "unreadable"))
    @Assert(Json.has(payload, "project"))
    @Assert(Json.strAt(payload, "project", "") == "docsp")
    @Assert(Json.arrAt(payload, "docs").size >= 1)

    removePathIfExists(testHome)
    exitTestHome()
}


// #165 回归：scan 的默认深度与字段集必须两个出口一致。
//
// 实测（仓库在 root/a/b/c/d，4 层）：
//     修复前 CLI  → candidates=1
//     修复前 HTTP → {"found":0}      ← 谎报「这里没有项目」，事实是「没扫到那么深」
// 「把没扫完说成没有」与 truncated 那条注释同一族。
// 另外 HTTP 原来少 candidates / existing 两个字段，客户端无法展示候选路径、
// 也无法区分「找到 1 个但已存在」与「找到 1 个但一个都没加进去」。
@Test
func testScanDefaultDepthIsSharedByBothSurfaces(): Unit {
    // 一个常量，两个出口；HTTP 侧若再手写字面量，这条测不到 ——
    // 所以下面还断言 HTTP 路由确实用的是这个常量（见 http 包的对照测试）。
    @Assert(SCAN_DEFAULT_DEPTH == 4)
    // 必须是 4 而不是 2：仓库埋在 4 层时，2 扫不到
    @Assert(SCAN_DEFAULT_DEPTH >= 4)
}

@Test
func testScanResultJsonCarriesEveryFieldConsumersNeed(): Unit {
    let base = "/tmp/dg_scanjson_${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic("${base}/a.txt", "a")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "i"], false)
    let result = scanRoots(ArrayList<String>([base]), SCAN_DEFAULT_DEPTH, false)
    let o = scanResultJson(result, 1, 0)

    // 候选路径必须能拿到，客户端才能展示「发现这些，等你确认」
    @Assert(Json.has(o, "candidates"))
    @Assert(Json.arrAt(o, "candidates").size == result.candidates.size)
    @Assert(Json.has(o, "existing"))
    @Assert(Json.intAt(o, "existing", -1) == 0)
    @Assert(Json.has(o, "found"))
    @Assert(Json.intAt(o, "found", -1) == Json.arrAt(o, "candidates").size)
    @Assert(Json.has(o, "truncated"))
    @Assert(Json.has(o, "dirsVisited"))
    // found − added == existing，三者必须能对账
    @Assert(Json.intAt(o, "found", 0) - Json.intAt(o, "added", 0) == Json.intAt(o, "existing", -1))

    removePathIfExists(base)
}

// #175 回归：skill 教学包承诺的接入方式数量必须等于实际列出的条数。
//
// 负控（曾真实发红）：HTTP 服务端删除后，「三种接入方式」只剩 MCP + CLI 两条，
// 而标题里的「三种」是手写死的 —— agent 读到的是一个永远差一条的承诺。
// 现在标题由列表长度派生，所以这条测的是「派生真的生效」，不是「数字对不对」。
@Test
func testSkillMarkdownAccessMethodCountMatchesListedItems(): Unit {
    let md = skillMarkdown()
    var claimed = ""
    var listed: Int64 = 0
    var sawHeader = false
    for (line in md.split("\n")) {
        let t = line.trimAscii()
        if (t.contains("种接入方式")) {
            sawHeader = true
            // 标题行形如「## 2 种接入方式（按场景选）」，按空格切开取第 2 段
            let parts = t.split(" ")
            @Assert(parts.size >= 2)
            claimed = parts[1]
        } else if (sawHeader && t.size >= 3
                   && t[0] == 0x23u8 && t[1] == 0x23u8 && t[2] == 0x20u8) {
            // 撞到下一节标题就停，别把后面章节的编号也算进来
            break
        } else if (sawHeader && t.size >= 2
                   && t[0] >= 0x31u8 && t[0] <= 0x39u8 && t[1] == 0x2eu8) {
            listed += 1
        }
    }
    // 前提：一个编号都没列出来时 claimed == "0" 也会「通过」，不能就这么放过
    @Assert(sawHeader)
    @Assert(!claimed.isEmpty())
    // 必须是纯数字：写死成「三种」这类中文数字会让下面的 == 永远不成立
    for (b in claimed) {
        @Assert(b >= 0x30u8 && b <= 0x39u8)
    }
    @Assert(listed > 0)
    @Assert(claimed == listed.toString())
}

/// #179 回归：读不出来的目录必须与「没有项目」分开报告。
///
/// 负控（曾真实发红）：`listDir` 吞掉异常返回空数组，于是把某个子树
/// `chmod 000` 之后，`scan --json` 给出 `found=1, dirsVisited=3, truncated=false`，
/// stderr 零告警 —— 这组数与「这棵树里确实只有 1 个项目」结构完全同构。
/// 而 `dirsVisited=3` 还把那个根本没读到的目录算作「已访问」。
@Test
func testScanJsonAlwaysCarriesUnreadableAndCoverage(): Unit {
    let base = "/tmp/dg_scanunreadable_${nowMillis()}"
    ensureDir("${base}/ok-proj")
    gitRun("${base}/ok-proj", ["init", "-b", "main"], false)
    writeFileAtomic("${base}/ok-proj/a.txt", "a")
    gitRun("${base}/ok-proj", ["-c", "user.name=t", "-c", "user.email=t@t", "add", "."], false)
    gitRun("${base}/ok-proj", ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "i"], false)
    // 造一个读不出来的目录（chmod 000）。测完必须还原，否则删不掉。
    ensureDir("${base}/locked")
    // 仓颉 std 没有设置权限的 API（查过 core/file，无 setPermission/chmod），
    // 所以借引擎自带的 execCapture 调 /bin/chmod。
    _ = execCapture("/bin/chmod", ["000", "${base}/locked"], None, 5000)

    let result = scanRoots(ArrayList<String>([base]), SCAN_DEFAULT_DEPTH, false)
    let o = scanResultJson(result, 0, 0)
    // 还原权限，否则 removePathIfExists 也清不掉
    _ = execCapture("/bin/chmod", ["755", "${base}/locked"], None, 5000)

    // unreadable 必须**恒发**，哪怕是空数组
    @Assert(Json.has(o, "unreadable"))
    let unread = Json.arrAt(o, "unreadable")
    @Assert(unread.size == 1)
    // unreadable 里是**裸字符串**（不是对象），要用 asStr 取，不能用 strAt(o, key)
    match (Json.asStr(unread[0])) {
        case Some(path) => @Assert(path.contains("locked"))
        case None => @Assert(false)
    }

    // 覆盖程度：三种「没扫全」的成因一个都不能少（#197 加了 depthCapped）
    @Assert(scanCoverage(false, 0, false, "zh") == "完整")
    @Assert(scanCoverage(true, 0, false, "zh").contains("目录上限"))
    @Assert(scanCoverage(false, 1, false, "zh").contains("读不出来"))
    @Assert(scanCoverage(true, 1, false, "zh").contains("读不出来"))
    @Assert(scanCoverage(false, 0, true, "zh").contains("--depth"))

    // 全部可读时 unreadable 必须是空数组，而不是缺键
    let okResult = scanRoots(ArrayList<String>([base]), SCAN_DEFAULT_DEPTH, false)
    let okO = scanResultJson(okResult, 0, 0)
    @Assert(Json.has(okO, "unreadable"))
    @Assert(Json.arrAt(okO, "unreadable").size == 0)
    @Assert(scanCoverage(okResult.truncated, okResult.unreadable.size, okResult.depthCapped, "zh") == "完整")

    removePathIfExists(base)
}

/// #180 回归续：days == -1 不得被渲染成「逾期 1 天」。
///
/// 负控（曾真实发红，两种形态）：
///   修 isIsoDate 之前：不存在的日期被 clamp，`目标 2026-02-31（逾期 212 天）`
///   修 isIsoDate 之后：days 变成 -1，原来的 `else` 分支把它渲染成「逾期 1 天」
/// 假数字没了，假断言还在 —— 换了个形式继续骗人。
@Test
func testMilestoneLineNeverRendersMinusOneAsOneDayOverdue(): Unit {
    func line(status: String, date: String, days: Int64, overdue: Bool): String {
        let it = Json.obj()
        Json.set(it, "name", Json.of("vX"))
        Json.set(it, "projectName", Json.of("repo"))
        Json.set(it, "status", Json.of(status))
        Json.set(it, "targetDate", Json.of(date))
        Json.set(it, "daysToTarget", Json.of(days))
        Json.set(it, "commitsSince", Json.of(1))
        Json.set(it, "commitsSinceReadable", Json.of(true))
        Json.set(it, "tagReached", Json.of(false))
        Json.set(it, "overdue", Json.of(overdue))
        return milestoneLine(it, "zh")
    }
    // -1 必须说「算不出」，不许出现任何天数
    for (d in ["2026-02-31", "2026-13-01", "2026-01-32", "not-a-date"]) {
        let l = line("open", d, -1, false)
        @Assert(!l.contains("逾期 1 天"))
        @Assert(!l.contains("还剩 -1 天"))
        @Assert(l.contains("算不出"))
    }
    // 正常两档不能被这次改动带坏
    @Assert(line("open", "2027-06-01", 243, false).contains("还剩 243 天"))
    @Assert(line("open", "2020-01-01", -100, true).contains("逾期 100 天"))
    // 没设目标日期时不该冒出任何日期文案
    @Assert(!line("open", "", -1, false).contains("目标"))
}

/// #182 回归（文本侧）：counts.other > 0 时那行摘要必须说出来。
///
/// 负控（曾真实发红）：不披露的话这行与下面的列表自相矛盾 ——
/// 「里程碑：进行中 1 · 已达成 0 · 已放弃 0」而列表里有 2 条。
@Test
func testDashboardMilestoneLineDisclosesOtherStatus(): Unit {
    let c = Json.obj()
    Json.set(c, "open", Json.of(1))
    Json.set(c, "done", Json.of(0))
    Json.set(c, "dropped", Json.of(0))
    Json.set(c, "unknown", Json.of(0))
    Json.set(c, "other", Json.of(0))
    let clean = dashboardMilestoneLine(c, "zh")
    @Assert(!clean.contains("认不出来"))
    @Assert(!clean.contains("无法核验"))

    Json.set(c, "other", Json.of(1))
    let dirty = dashboardMilestoneLine(c, "zh")
    @Assert(dirty.contains("认不出来"))
    @Assert(dirty.contains("1"))
}

// ------------------------------ #196：位置参数不许被静默丢弃 ------------------------------

/// #196：「哪些位置参数变成了目标」正是缺陷本身，抽成 `namedTargets` 才测得到。
///
/// 原来 `cmdDocs` / `cmdRemove` 各写了一份 `targets.add(requireProject(refs[0]))`
/// —— 只取第一个，其余项目名静默丢弃，退出码还是 0。
@Test
func testNamedTargetsResolvesEveryGivenName(): Unit {
    let base = "/tmp/deepgit-namedt-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(deepgitHome())
    let a = base + "/alpha"
    let b = base + "/beta"
    ensureDir(a)
    ensureDir(b)
    let (_, okA) = addProject(a, "alpha", ArrayList<String>(), a)
    let (_, okB) = addProject(b, "beta", ArrayList<String>(), b)
    @Assert(okA && okB)

    // 两个名字 ⇒ 两个目标。原缺陷在这里只回一个。
    let both = namedTargets(ArrayList<String>(["alpha", "beta"]))
    @Assert(both.size == 2)
    @Assert(both[0].name == "alpha")
    @Assert(both[1].name == "beta")

    // 顺序必须与命令行一致：消费方靠顺序对应请求与结果
    let rev = namedTargets(ArrayList<String>(["beta", "alpha"]))
    @Assert(rev[0].name == "beta")
    @Assert(rev[1].name == "alpha")

    // 三个也一样
    let c = base + "/gamma"
    ensureDir(c)
    let (_, okC) = addProject(c, "gamma", ArrayList<String>(), c)
    @Assert(okC)
    @Assert(namedTargets(ArrayList<String>(["alpha", "beta", "gamma"])).size == 3)

    // 空名单 ⇒ 空目标（不是整个项目群 ——「全部」是另一条显式路径）
    @Assert(namedTargets(ArrayList<String>()).size == 0)

    // 名字不存在必须 NOT_FOUND，不能被静默跳过
    var threw = false
    try {
        let _ = namedTargets(ArrayList<String>(["alpha", "不存在的项目"]))
    } catch (e: DgError) {
        threw = true
        @Assert(e.exitCode == 1)
    }
    @Assert(threw)

    exitTestHome()
    removePathIfExists(testHome)
    removePathIfExists(base)
}

/// #196 的有害那一半：`remove` 是**破坏性操作**，
/// 「要注销两个、只注销一个、还告诉我成功了」比不响应更糟 ——
/// 用户据此认为第二个也注销了，于是把它从自己的清单里划掉。
///
/// 断言**注册表的真实状态**而不是 stdout，所以走的是完整路径。
@Test
func testRemoveMustActuallyRemoveEveryNamedProject(): Unit {
    let base = "/tmp/deepgit-rmall-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(deepgitHome())
    for (n in ["p1", "p2", "p3"]) {
        let d = "${base}/${n}"
        ensureDir(d)
        let (_, ok) = addProject(d, n, ArrayList<String>(), d)
        @Assert(ok)
    }
    @Assert(loadRegistry().projects.size == 3)

    // 注销两个 ⇒ 注册表里必须真的少了两个
    let rc = cmdRemove(ArrayList<String>(["p1", "p2"]), CliContext(ArrayList<String>(["remove"])))
    @Assert(rc == 0)
    let left = loadRegistry().projects
    @Assert(left.size == 1)
    @Assert(left[0].name == "p3")

    exitTestHome()
    removePathIfExists(testHome)
    removePathIfExists(base)
}

/// #196：`docs` 的多项目契约早就写在 docsPayload 里（有 project 键 = 单项目
/// envelope，键不在 = 多项目平铺），但从 CLI 上用项目名**永远走不到**那条分支。
/// 契约在、入口不在 —— 既有测试也就只测了纯函数，
/// 测不到「用户敲两个名字会发生什么」。
@Test
func testDocsWithTwoNamesMustReturnBothProjects(): Unit {
    let base = "/tmp/deepgit-docstwo-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(deepgitHome())
    for (n in ["alpha", "beta"]) {
        let d = "${base}/${n}"
        ensureDir(d)
        writeFileAtomic("${d}/README.md", "# ${n}\n")
        let (_, ok) = addProject(d, n, ArrayList<String>(), d)
        @Assert(ok)
    }

    // 两个名字 ⇒ 平铺形状（顶层**没有** project 键），每条自带 project
    let both = docsPayload(namedTargets(ArrayList<String>(["alpha", "beta"])), Config.defaults())
    @Assert(!Json.has(both, "project"))
    let owners = ArrayList<String>()
    for (d in Json.arrAt(both, "docs")) {
        owners.add(Json.strAt(d, "project", ""))
    }
    @Assert(owners.contains("alpha"))
    @Assert(owners.contains("beta"))

    // 一个名字 ⇒ 单项目 envelope，**形状不能变**（消费方按 project 键分流）
    let one = docsPayload(namedTargets(ArrayList<String>(["alpha"])), Config.defaults())
    @Assert(Json.strAt(one, "project", "") == "alpha")

    exitTestHome()
    removePathIfExists(testHome)
    removePathIfExists(base)
}

/// #196：元数固定的命令（add / milestone）多出来的位置参数必须报错。
/// 吞掉它等于把拼写错误变成一次「成功」——
/// `moongit add <路径> <名称>` 这种写法**一直**不生效（名字只认 `--name`），
/// 却打印「✓ 已注册」。本次审计里我自己就踩了两次。
@Test
func testFixedArityCommandsRejectExtraPositionals(): Unit {
    var threw = false
    try {
        rejectExtraPositionals("add", ArrayList<String>(["/p", "n1", "n2"]), 1)
    } catch (e: DgError) {
        threw = true
        @Assert(e.exitCode == 2)
    }
    @Assert(threw)

    // 在上限之内不得报错
    var threw2 = false
    try {
        rejectExtraPositionals("milestone add", ArrayList<String>(["add", "alpha", "v1"]), 3)
    } catch (e: DgError) {
        threw2 = true
    }
    @Assert(!threw2)
}

/// #196 的结构守卫：这两条命令必须走共享接缝，不能再各写一份 refs[0]。
/// 「多份实现必然漂移」是本引擎栽得最多的一条（同不变量 43）。
///
/// ⚠️ 匹配前**必须剥注释** —— 这条 lint 第一次跑就假红了，
/// 因为 `cmdDocs` 里我写的解释性注释「原来这里是
/// `targets.add(requireProject(refs[0]))`」正好包含被禁的字符串。
/// 正控就是这么红的：解释缺陷的注释长得和缺陷一模一样。
@Test
func testMultiProjectCommandsMustNotHandRollRefs0(): Unit {
    let src = readFileTextChecked("src/cli/cli.cj").getOrThrow()
    // 剥注释（复用唯一那份实现，见不变量 45）
    let sb = StringBuilder()
    var blk = false
    for (raw in src.split("\n")) {
        let (l, nb) = stripCjComment(raw, blk)
        blk = nb
        sb.append(l)
        sb.append("\n")
    }
    let code = sb.toString()
    for (fn in ["cmdDocs", "cmdRemove"]) {
        let a = code.indexOf("func ${fn}(")
        @Assert(a.isSome())
        let rest = code[a.getOrThrow()..]
        let b = rest.indexOf("\nfunc ")
        let body = if (b.isSome()) { rest[0..b.getOrThrow()] } else { rest }
        @Assert(body.contains("namedTargets("))
        // 原缺陷的形状：只把第一个 refs 变成目标
        @Assert(!body.contains("requireProject(refs[0])"))
    }
}

// ------------------------------ #197：scan 的「没看完」不许说成「没有」 ------------------------------

/// #197：`--depth` 太浅是「没扫全」，与「撞到目录上限」同族，
/// 而 `truncated` 只表达后者。原来的文本出口于是打印
/// 「未发现项目（已访问 3 个目录）」exit 0 —— 而仓库就在第 4 层。
///
/// 走真实的 scanRoots + 真实的目录树，不手搓 ScanResult：
/// 「深度不够所以没看完」这个前提正是缺陷的来源（同 #188）。
@Test
func testScanMustDiscloseThatItStoppedAtTheDepthLimit(): Unit {
    let base = "/tmp/deepgit-depthcap-${nowMillis()}"
    let repo = base + "/a/b/c/repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], true)

    // 深度 2：仓库在第 4 层，看不见 —— 但必须说「没看完」
    let shallow = scanRoots(ArrayList<String>([base]), 2, false)
    @Assert(shallow.candidates.size == 0)
    @Assert(!shallow.truncated)          // 没撞目录上限
    @Assert(shallow.depthCapped)          // 撞的是深度上限
    @Assert(scanCoverage(shallow.truncated, shallow.unreadable.size, shallow.depthCapped, "zh").contains("--depth"))

    // 深度 5：看得见 ⇒ 找到，且**不得**说被截断
    let deep = scanRoots(ArrayList<String>([base]), 5, false)
    @Assert(deep.candidates.size == 1)
    @Assert(!deep.depthCapped)
    @Assert(scanCoverage(deep.truncated, deep.unreadable.size, deep.depthCapped, "zh") == "完整")

    // 叶子目录不算「被截断」：撞到深度上限时下面**确实没有子目录**
    // 就是真的看全了，置位 depthCapped 反而是谎报。
    let shallowRepo = scanRoots(ArrayList<String>([repo]), 1, false)
    @Assert(shallowRepo.candidates.size == 1)
    @Assert(!shallowRepo.depthCapped)

    removePathIfExists(base)
}

/// `depthCapped` 必须恒发（含 false），否则调用方分不清
/// 「没扫全」与「旧版本没这个字段」。
@Test
func testScanJsonAlwaysCarriesDepthCapped(): Unit {
    let base = "/tmp/deepgit-depthjson-${nowMillis()}"
    ensureDir(base)
    let r = scanRoots(ArrayList<String>([base]), 3, false)
    let o = scanResultJson(r, 0, 0)
    @Assert(Json.has(o, "depthCapped"))
    @Assert(!Json.boolAt(o, "depthCapped", true))
    // 有真备份式的对照：撞上限时必须为 true
    let repo = base + "/x/y/z"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], true)
    let capped = scanRoots(ArrayList<String>([base]), 2, false)
    @Assert(Json.boolAt(scanResultJson(capped, 0, 0), "depthCapped", false))
    removePathIfExists(base)
}

/// `hasUnexploredSubdir` 的判定：叶子 / 有子目录 / 读不出来。
///
/// ⚠️ 读不出来必须返回 true（宁可说「可能没看完」）：
/// 用 `listDir` 会把读取异常吞成空数组 =「没有子目录」= 谎报成「看全了」——
/// 那是 #179 在 scan 深度这条路上的复发。
@Test
func testHasUnexploredSubdirDistinguishesLeafFromBranchFromUnreadable(): Unit {
    let base = "/tmp/deepgit-subdir-${nowMillis()}"
    ensureDir(base)
    let leaf = base + "/leaf"
    let branch = base + "/branch"
    ensureDir(leaf)
    ensureDir(branch)
    ensureDir(branch + "/child")
    @Assert(!hasUnexploredSubdir(leaf))
    @Assert(hasUnexploredSubdir(branch))
    // 不存在的目录：listDirChecked 返回 ok=true 空列表 ⇒ 没有子目录
    @Assert(!hasUnexploredSubdir(base + "/nope"))
    // 点开头的目录不算（与遍历本身保持一致）
    ensureDir(branch + "/.hidden")
    @Assert(!hasUnexploredSubdir(leaf))
    removePathIfExists(base)
}

/// #197：文本路径的**两个出口**（空结果早退 / 有结果收尾）必须共用同一个判定。
///
/// 原缺陷正是这个：两条路都只看 `truncated`，「深度上限」在两处都没接 ——
/// 于是「没看完」在两条路上都安静地变成了完整结论。
/// 同一个问题问两遍，两遍都答错。
@Test
func testScanTextExitsShareTheSameIncompletePredicate(): Unit {
    // 判定本身
    @Assert(!scanIncomplete(false, false))
    @Assert(scanIncomplete(true, false))
    @Assert(scanIncomplete(false, true))
    @Assert(scanIncomplete(true, true))

    // 两个出口都得问它。剥注释后再数 —— 注释里必然提到这两个成因。
    let src = readFileTextChecked("src/cli/cli.cj").getOrThrow()
    let sb = StringBuilder()
    var blk = false
    for (raw in src.split("\n")) {
        let (l, nb) = stripCjComment(raw, blk)
        blk = nb
        sb.append(l)
        sb.append("\n")
    }
    let code = sb.toString()
    let a = code.indexOf("func cmdScan(")
    @Assert(a.isSome())
    let rest = code[a.getOrThrow()..]
    let b = rest.indexOf("\nfunc ")
    let body = if (b.isSome()) { rest[0..b.getOrThrow()] } else { rest }
    let hits = body.split("scanIncomplete(result.truncated, result.depthCapped)").size - 1
    @Assert(hits == 2)
    // 不许再出现就地手写的版本
    @Assert(!body.contains("result.truncated || result.depthCapped"))
}

/// #197：`--depth` 小于 1 必须报错。
///
/// `--depth 0` 与 `--depth -1` 原来都被接受，扫一个目录就收工，
/// 打印「未发现项目（已访问 1 个目录）」exit 0 ——
/// 而「一个子目录都不看」永远不是想找仓库的人会提的要求。
/// 与 `journal --limit 0/-1`、`update.backupKeep < 0` 同一处置。
@Test
func testScanRejectsNonsensicalDepth(): Unit {
    for (bad in ["0", "-1", "-99"]) {
        var msg = ""
        var threw = false
        try {
            let _ = cmdScan(ArrayList<String>(["/tmp", "--depth", bad]), CliContext(ArrayList<String>(["scan"])))
        } catch (e: DgError) {
            threw = true
            msg = e.message
        }
        @Assert(threw)
        @Assert(msg.contains("--depth"))
    }
    // 合法值不得被这条守卫误伤
    var threw2 = false
    try {
        let _ = cmdScan(ArrayList<String>(["/definitely/not/here", "--depth", "1"]), CliContext(ArrayList<String>(["scan"])))
    } catch (e: DgError) {
        // 目录不存在是另一条错误（没扫描根），不是深度守卫
        threw2 = e.message.contains("--depth 至少为 1")
    }
    @Assert(!threw2)
}

// ------------------------------ #200：doctor 的自检结论不许是无依据的 ------------------------------

/// 「查了没有」与「没查」必须分开。原实现只有一个 Bool，
/// 于是目录读不出来时 doctor 报「临时残留：无」——
/// 而磁盘上那个 `.tmp` 就在那儿，它只是没读到。
@Test
func testLeftoverVerdictIsThreeStateNotTwo(): Unit {
    // 全查了，确实没有
    match (leftoverVerdict(0, 0)) {
        case LeftoverVerdict.Clean => ()
        case _ => @Assert(false)
    }
    // 全查了，确实有
    match (leftoverVerdict(3, 0)) {
        case LeftoverVerdict.Found(n) => @Assert(n == 3)
        case _ => @Assert(false)
    }
    // ⚠️ 关键：没查完就绝不能塌成 Clean，哪怕已查部分一个残留都没有。
    // 这一条正是缺陷 #200 的形状。
    match (leftoverVerdict(0, 2)) {
        case LeftoverVerdict.PartlyUnreadable(n, k) =>
            @Assert(n == 0)
            @Assert(k == 2)
        case _ => @Assert(false)
    }
    // 部分未检查 + 部分有残留：两个数都要带出去，不能只报一个
    match (leftoverVerdict(1, 3)) {
        case LeftoverVerdict.PartlyUnreadable(n, k) =>
            @Assert(n == 1)
            @Assert(k == 3)
        case _ => @Assert(false)
    }
}

/// 呈现层也不许把「未检查」写成「无」。这是缺陷原文照抄的那句谎话。
@Test
func testLeftoverTextNeverSaysNoneWhenUnchecked(): Unit {
    let none = ArrayList<String>()
    let unchecked = ArrayList<String>(["proj-a", "proj-b"])
    let some = ArrayList<String>(["proj-a/README.md.tmp-1-0"])

    let cleanText = leftoverResultText(leftoverVerdict(0, 0), "zh")
    @Assert(cleanText == "无")
    // en 分支不许再漏（M15 残留）：doctor 单元格原先硬编码中文
    @Assert(leftoverResultText(leftoverVerdict(0, 0), "en") == "none")

    let uncheckedText = leftoverResultText(leftoverVerdict(0, 2), "zh")
    @Assert(!uncheckedText.contains("无"))
    @Assert(uncheckedText.contains("未检查"))

    let detail = leftoverDetailText(leftoverVerdict(0, 2), none, unchecked, "zh")
    @Assert(!detail.contains("可安全删除"))    // 没找到就不许开删除处方
    @Assert(detail.contains("proj-a"))
    @Assert(detail.contains("没有检查过"))
    let detailEn = leftoverDetailText(leftoverVerdict(0, 2), none, unchecked, "en")
    @Assert(detailEn.contains("were not checked"))
    @Assert(detailEn.contains("proj-a"))

    let mixed = leftoverDetailText(leftoverVerdict(1, 2), some, unchecked, "zh")
    @Assert(mixed.contains("README.md.tmp-1-0"))   // 已查到的部分照常给
    @Assert(mixed.contains("没有检查过"))
    @Assert(leftoverResultText(leftoverVerdict(1, 2), "zh") == "1 个（另有 2 个项目未检查）")
    @Assert(leftoverResultText(leftoverVerdict(1, 2), "en") == "1 found (2 projects not checked)")
}

/// 真实文件系统：目录读不出来时必须进 unreadable 清单，而不是安静地报「没有」。
/// 走 `scanLeftovers` 这条生产路径，不直接调判据。
@Test
func testScanLeftoversSeparatesUnreadableFromEmpty(): Unit {
    let base = "/tmp/deepgit-leftover-${nowMillis()}"
    let clean = base + "/clean"
    let closed = base + "/closed"
    ensureDir(clean)
    ensureDir(closed)
    writeFileAtomic(clean + "/README.md", "# c")
    writeFileAtomic(closed + "/README.md", "# c")
    // 两个项目都真的留了 .tmp；closed 那个我们会看不见
    writeFileAtomic(clean + "/README.md.tmp-11-0", "junk")
    writeFileAtomic(closed + "/README.md.tmp-22-0", "junk")
    let ch = execCapture("chmod", ["000", closed], None, 8000)
    @Assert(ch.ok())

    let projects = ArrayList<ProjectEntry>()
    projects.add(ProjectEntry("p_clean", "clean", clean, "dir", "", nowIso(), ArrayList<String>(), false))
    projects.add(ProjectEntry("p_closed", "closed", closed, "dir", "", nowIso(), ArrayList<String>(), false))
    let (leftovers, unreadable) = scanLeftovers(projects)
    execCapture("chmod", ["755", closed], None, 8000)

    // 看得见的那个必须找到
    var sawClean = false
    for (l in leftovers) {
        if (l == "clean/README.md.tmp-11-0") {
            sawClean = true
        }
    }
    @Assert(sawClean)
    // 看不见的必须进 unreadable，且绝不能被算成「没有残留」
    @Assert(unreadable.size == 1)
    @Assert(unreadable[0] == "closed")
    // 仓颉枚举不支持 ==/!=，用 match 断言「不是 Clean」
    match (leftoverVerdict(Int64(leftovers.size), Int64(unreadable.size))) {
        case LeftoverVerdict.Clean => @Assert(false)
        case _ => ()
    }

    // 全部可读且干净时必须是 Clean（别把「正常」也染成「未检查」）
    let okDir = base + "/ok"
    ensureDir(okDir)
    writeFileAtomic(okDir + "/README.md", "# ok")
    let one = ArrayList<ProjectEntry>()
    one.add(ProjectEntry("p_ok", "ok", okDir, "dir", "", nowIso(), ArrayList<String>(), false))
    let (l2, u2) = scanLeftovers(one)
    @Assert(l2.isEmpty())
    @Assert(u2.isEmpty())
    match (leftoverVerdict(Int64(l2.size), Int64(u2.size))) {
        case LeftoverVerdict.Clean => ()
        case _ => @Assert(false)
    }
    removePathIfExists(base)
}

/// 源码 lint：doctor 那一行必须走三态接缝，不许再写回单 Bool 版本。
/// 剥注释后再匹配。
@Test
func __lintDoctorLeftoverRowMustUseTheThreeStateSeam(): Unit {
    let raw = readFileTextChecked("src/cli/cli.cj").getOrThrow()
    let sb = StringBuilder()
    var blk = false
    for (r in raw.split("\n")) {
        let (l, nb) = stripCjComment(r, blk)
        blk = nb
        sb.append(l)
        sb.append("\n")
    }
    let code = sb.toString()
    // 用了接缝
    @Assert(code.contains("leftoverResultText(lv, lang)"))
    @Assert(code.contains("leftoverDetailText(lv, leftovers, unreadableProjects, lang)"))
    @Assert(code.contains("scanLeftovers(reg.projects)"))
    // 恒真条件不许回来：`size >= 0` 对 Int64 恒成立，等于什么都没判
    @Assert(!code.contains(".size >= 0"))
    // 托管文档名单只有一个来源（render.cj 的 DEEPGIT_MANAGED_DOCS），
    // 手抄副本会随名单演进而漂移。
    // ⚠️ needle 拼接：源码里不能出现完整 needle，否则这个 lint 匹配到自己。
    let handCopy = "\"README.md\", \"AGENTS.md\"" + ", \"AGENT.md\""
    @Assert(!code.contains(handCopy))
}

/// 键表与样例值表必须**成对**（#203 的后续）。
///
/// `configKnownKeys()` 里有键、而 `configKeySample()` 没登记样例值时，
/// 测试会红 —— 这是有意的：新键漏登记，测试就该拦，
/// 而不是让下一个加键的人自己猜这个键的合法值长什么样。
///
/// 同一个键在两张表里不一致（一张有、一张无）也红。
@Test
func testEveryKnownConfigKeyHasAValidSample(): Unit {
    for (k in configKnownKeys()) {
        let sample = configKeySample(k)
        @Assert(sample.isSome())
        // 样例值必须真的写得进去（这就是「合法」的定义，不是我们说了算）
        let cfg = Config.defaults()
        let _ = configSetValue(cfg, k, sample.getOrThrow())
        // 并且读得回来，且不是 null
        @Assert(Json.pretty(configGetValue(cfg, k)) != "null")
    }
    // 键表里的每个键都在样例值表里（反向）
    for (k in configKnownKeys()) {
        @Assert(configKeySample(k).isSome())
    }
    // ⚠️ 样例值表**不许**登记键表里没有的键。
    // 原来这条只检查了 4 个已知键「在键表里」，等于什么都没验 ——
    // 往样例值表里塞一个 `case "update.newKey"` 照样全绿（NC55-g 假绿现场）。
    // 真实危害是**漂移**：同一个键名写在两张表里，改名时忘了另一张。
    for (k in ["update.newKey", "server.port", "hooks.mode", "", "LANGUAGE"]) {
        @Assert(!configKnownKeys().contains(k))
        @Assert(configKeySample(k).isNone())
    }
    // 非法样例必须被拒（证明这张表真的在表达合法性，不只是「有个值」）
    var rejected = false
    try {
        let _ = configSetValue(Config.defaults(), "language", "fr")
    } catch (e: DgError) {
        rejected = true
    }
    @Assert(rejected)
}

/// `configSetValue` / `configGetValue` 的 case 分支必须**恰好**等于 `configKnownKeys()`。
///
/// ⚠️ 这是 #194 那个测试的加强版。原测试只保证「已知键读写都通」，
/// 但保证不了**反向**：某人在 `configSetValue` 里加了一个 case 却忘了加进
/// `configKnownKeys()`，于是
///     moongit config set update.newKey 5   →  ✓ 已设置
///     moongit config get update.newKey     →  ✗ 未知配置键
/// 写入口报成功、读入口说这个键不存在 —— 正是 #193 / #202 / #203 那一族。
/// 函数末尾的 `case _ => throw 未知配置键` 让这件事编译期无感，只能靠源码比对。
@Test
func __lintConfigKeyTableMatchesBothAccessors(): Unit {
    let raw = readFileTextChecked("src/cli/cli.cj").getOrThrow()
    let sb = StringBuilder()
    var blk = false
    for (r in raw.split("\n")) {
        let (l, nb) = stripCjComment(r, blk)
        blk = nb
        sb.append(l)
        sb.append("\n")
    }
    let code = sb.toString()

    // 1) 键表字面量
    let ks = code.indexOf("return [\"language\"")
    @Assert(ks.isSome())
    let rest = code[ks.getOrThrow()..]
    let ke = rest.indexOf("]")
    @Assert(ke.isSome())
    let table = rest[0..ke.getOrThrow()]

    // 2) 两个访问器各自的 case 分支
    var setKeys = ArrayList<String>()
    var getKeys = ArrayList<String>()
    collectCaseKeys(code, "func configSetValue(", setKeys)
    collectCaseKeys(code, "func configGetValue(", getKeys)

    // 3) 三个集合必须两两相等
    @Assert(setKeys.size == getKeys.size)
    for (k in setKeys) {
        @Assert(getKeys.contains(k))
        @Assert(table.contains("\"" + k + "\""))
    }
    for (k in getKeys) {
        @Assert(setKeys.contains(k))
    }
    @Assert(setKeys.size == 4)
}

/// 抽出一个函数体里所有 `case "..."` 的键。⚠️ 靠 `\nfunc ` 切函数体，
/// 所以只处理仓颉这种「函数顶层顶格」的排版（本文件一直是这个风格）。
public func collectCaseKeys(code: String, header: String, acc: ArrayList<String>): Unit {
    let h = code.indexOf(header)
    if (h.isNone()) {
        return
    }
    let body = code[h.getOrThrow()..]
    let end = body.indexOf("\nfunc ")
    let seg = if (end.isSome()) { body[0..end.getOrThrow()] } else { body }
    for (line in seg.split("\n")) {
        let t = line.trimAscii()
        if (!t.startsWith("case \"")) {
            continue
        }
        let a = t.indexOf("\"")
        match (a) {
            case None => ()
            case Some(i) =>
                let tail = t[(i + 1)..]
                match (tail.indexOf("\"")) {
                    case None => ()
                    case Some(j) => acc.add(tail[0..j])
                }
        }
    }
}

// MARK: - 审查回归（audit-2026-10-09）：外壳层双语与语言链路

/// M15：English 模式下这些渲染函数必须真的给英文，不能仍然中文。
/// 原实现整段中文硬编码，`DEEPGIT_LANG=en` 时数据是英文、话术是中文。
@Test
func testChromeRenderersHonourEnglish(): Unit {
    let projs = Json.parse("{\"listed\":3,\"failed\":1,\"active7d\":2,\"active30d\":3,\"dirty\":1}").getOrThrow()
    let pl = dashboardProjectLine(projs, "en")
    @Assert(pl.contains("Projects:"))
    @Assert(pl.contains("unreadable"))
    @Assert(!pl.contains("项目群"))

    let counts = Json.parse("{\"open\":2,\"done\":1,\"dropped\":0,\"unknown\":1,\"other\":1,\"degraded\":true,\"storeHealth\":\"corrupt\",\"readCount\":0,\"excludedDisabled\":2,\"orphaned\":1}").getOrThrow()
    let ml = dashboardMilestoneLine(counts, "en")
    @Assert(ml.contains("Milestones:"))
    @Assert(ml.contains("unverifiable"))
    @Assert(ml.contains("does not mean none"))
    @Assert(!ml.contains("里程碑"))

    let (emptyEn, _) = milestoneEmptyState(0, 0, "ok", 0, "en")
    @Assert(emptyEn.contains("no milestones"))
    let (emptyZh, _) = milestoneEmptyState(0, 0, "ok", 0, "zh")
    @Assert(emptyZh.contains("无里程碑"))

    let ls = listSummaryLine(2, 1, "en")
    @Assert(ls.contains("2 projects"))
    @Assert(ls.contains("disabled"))
    @Assert(!ls.contains("个项目"))

    let cov = scanCoverage(true, 1, true, "en")
    @Assert(cov.contains("partial coverage"))
    @Assert(!cov.contains("部分覆盖"))
    // 中文键集一个都不许丢
    @Assert(!scanCoverage(true, 1, true, "zh").contains("partial coverage"))
}

/// L9：env 覆盖必须走同一份 language 判据。`DEEPGIT_LANG=fr` 原来被静默接受，
/// 而 isEnglish("fr") == false ⇒ 全输出中文且零提示。
@Test
func testEnvLanguageOverrideRejectsUnsupported(): Unit {
    setVariable("DEEPGIT_LANG", "fr")
    let cfg = applyEnvOverrides(Config.defaults())
    @Assert(cfg.language == "zh")     // 不接受引擎不会兑现的值
    setVariable("DEEPGIT_LANG", "en")
    @Assert(applyEnvOverrides(Config.defaults()).language == "en")
    setVariable("DEEPGIT_LANG", "")
}
