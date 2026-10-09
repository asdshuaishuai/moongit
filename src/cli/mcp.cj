// MCP 服务器：把引擎暴露为 Model Context Protocol 工具服务器（stdio，JSON-RPC 2.0）。
//
// 设计：
// - 单行 JSON 进、单行 JSON 出（stdout 专用；日志恒走 stderr 不污染协议）
// - 工具直接调 flow/kernel 层函数（进程内），与 CLI 同源同权
//   （HTTP 服务端已整体删除：AGENTS.md 第一条不变量「没有 /api/*」）
// - 无状态：除显式写操作外全部只读；写操作走与 CLI 相同的锁与白名单
// - AI 无关：MCP 只暴露事实与动作，供任何 MCP 宿主（Claude/其它 agent）消费
package moongit.cli

import std.collection.*
import std.console.*
import std.convert.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.flow.*
import moongit.graph.*
import moongit.kernel.*
import moongit.util.*

// ------------------------------ 工具清单 ------------------------------

func mcpSchemaObject(properties: Array<(String, String, String)>, required: Array<String>): JsonValue {
    // (name, type, description)
    let props = Json.obj()
    for ((n, t, d) in properties) {
        let p = Json.obj()
        Json.set(p, "type", Json.of(t))
        Json.set(p, "description", Json.of(d))
        Json.set(props, n, p)
    }
    let o = Json.obj()
    Json.set(o, "type", Json.of("object"))
    Json.set(o, "properties", props)
    let req = ArrayList<JsonValue>()
    for (r in required) {
        req.add(Json.of(r))
    }
    Json.set(o, "required", JArr(req))
    return o
}

func mcpTool(name: String, desc: String, schema: JsonValue): JsonValue {
    let t = Json.obj()
    Json.set(t, "name", Json.of(name))
    Json.set(t, "description", Json.of(desc))
    Json.set(t, "inputSchema", schema)
    return t
}

/// MCP 工具全集（与 `moongit tools --json` 同源能力，进程内直连）
public func mcpToolList(): JsonValue {
    let arr = ArrayList<JsonValue>()
    arr.add(mcpTool("list_projects", "列出全部已注册项目及一句话现状", mcpSchemaObject([], [])))
    arr.add(mcpTool("get_group_context", "整个项目群的 markdown 事实上下文（总览/脉搏/分支/待合入）。budget=字符预算", mcpSchemaObject([("budget", "integer", "上下文字符预算，默认 12000")], [])))
    arr.add(mcpTool("get_project_context", "单项目深度上下文（分支进度/脉搏/日志/里程碑）", mcpSchemaObject([("name", "string", "项目名或 ID"), ("budget", "integer", "字符预算")], ["name"])))
    arr.add(mcpTool("get_project_status", "单项目完整状态 JSON（分支/提交构成/合入建议）", mcpSchemaObject([("name", "string", "项目名或 ID")], ["name"])))
    arr.add(mcpTool("get_dashboard", "跨项目聚合仪表盘（活跃度/里程碑/语言分布）", mcpSchemaObject([], [])))
    arr.add(mcpTool("get_project_docs", "读取项目 README/AGENTS/CLAUDE 原文", mcpSchemaObject([("name", "string", "项目名或 ID")], ["name"])))
    arr.add(mcpTool("get_journal", "读取项目进度日志", mcpSchemaObject([("name", "string", "项目名或 ID"), ("limit", "integer", "条数，默认 8")], ["name"])))
    // ⚠️⚠️ #198：name 从「缺省=全部项目」改成**必填**。
    //
    // 原来这一支是全部项目里**唯一**一个「参数缺失 = 批量写」的工具：
    //     run_shallow_update {}  →  alpha：ok | beta：ok   isError=false
    // 而同族全部工具（run_deep_update / run_track / get_project_status /
    // get_journal / get_project_docs / get_project_context）在缺 name 时都
    // 老老实实报「未找到项目：」—— 因为它们走 `mcpRequireProject`。
    //
    // 为什么这是缺陷而不是特性：
    //   ① 它是**写**操作。一个漏掉的参数 = 改写注册表里**每一个**项目的
    //      文档托管区域。读操作漏参数只是少给点信息，写操作漏参数是改数据。
    //   ② 客户端早就把这条堵死了。客户端的必填清单由 CLI `tools --json` 的
    //      `params: "name"` 推出（AgentCore.engineToolDefinitions），
    //      于是 `run_shallow_update` 在客户端**必须**带 name ——
    //      缺陷 #31 修的就是这个（「空项目名在引擎侧等于整个项目群，
    //      实测会改写所有项目的 README」）。那次只加在客户端，
    //      引擎自己的 MCP 工具表里这一层**没跟上**。
    //   ③ 工具描述写的是「浅更新」——单数，默认动作与描述不符。
    // 引擎 CLI 的 `moongit update`（不带名字 = 全部）仍然保留；
    // 那是**人**敲的命令，而这里是**模型**填的参数表。
    arr.add(mcpTool("run_shallow_update", "浅更新：记录各分支进度并刷新文档托管区域。name 必填；传 * 表示整个项目群", mcpSchemaObject([("name", "string", "项目名或 ID；传 * 表示全部项目")], ["name"])))
    arr.add(mcpTool("run_deep_update", "深度更新：重写 overview/architecture/commands/history。name 必填（与 run_shallow_update / run_track 同构）", mcpSchemaObject([("name", "string", "项目名或 ID"), ("scope", "string", "all|readme|agent")], ["name"])))
    arr.add(mcpTool("run_track", "进度快照：只写进度库不动文档", mcpSchemaObject([("name", "string", "项目名或 ID")], ["name"])))
    arr.add(mcpTool("git_op", "面板级 git 操作（白名单：pull/push/commit/stash/unstash/fetch）", mcpSchemaObject([("name", "string", "项目名或 ID"), ("op", "string", "pull|push|commit|stash|unstash|fetch"), ("message", "string", "commit 时的提交信息")], ["name", "op"])))
    arr.add(mcpTool("list_milestones", "列出全部里程碑及 git 感知进度", mcpSchemaObject([], [])))
    arr.add(mcpTool("milestone_add", "新增里程碑（tag 存在即自动达成）", mcpSchemaObject([("project", "string", "项目名或 ID"), ("name", "string", "里程碑名"), ("tag", "string", "绑定 tag"), ("target_date", "string", "YYYY-MM-DD"), ("description", "string", "描述")], ["project", "name"])))
    arr.add(mcpTool("milestone_action", "里程碑状态操作", mcpSchemaObject([("project", "string", "项目名或 ID"), ("name", "string", "里程碑名"), ("action", "string", "done|open|drop|remove")], ["project", "name", "action"])))
    arr.add(mcpTool("add_project", "注册一个项目目录", mcpSchemaObject([("path", "string", "项目绝对路径"), ("name", "string", "项目名（缺省取目录名）")], ["path"])))
    // ── CodeGraph：代码图谱（仓颉引擎的确定性词法分析，零依赖）──
    arr.add(mcpTool("codegraph_overview", "代码图谱概览：文件/符号/引用边统计，按语言与符号种类分桶", mcpSchemaObject([("name", "string", "项目名或 ID")], ["name"])))
    arr.add(mcpTool("codegraph_tree", "索引关系树：目录→文件→符号（JSON 形态为全量图：文件事实 + import 边 + 引用边）", mcpSchemaObject([("name", "string", "项目名或 ID"), ("depth", "integer", "目录深度，默认 6")], ["name"])))
    arr.add(mcpTool("codegraph_symbol", "符号定位：定义处 + 词法引用文件", mcpSchemaObject([("name", "string", "项目名或 ID"), ("symbol", "string", "符号名")], ["name", "symbol"])))
    arr.add(mcpTool("codegraph_impact", "影响面分析：符号定义 + 引用文件 + 受影响符号（词法文件级粒度，非语义调用图）", mcpSchemaObject([("name", "string", "项目名或 ID"), ("symbol", "string", "符号名")], ["name", "symbol"])))
    arr.add(mcpTool("codegraph_arch", "技术架构图：模块聚合 + 分层判定。format=html（Canvas 交互图，单文件零依赖）/ mermaid / dot / json", mcpSchemaObject([("name", "string", "项目名或 ID"), ("format", "string", "html|mermaid|dot|json，默认 html")], ["name"])))
    arr.add(mcpTool("codegraph_patch_confidence", "补丁级置信度 Layer 1（算法层）：S1..S10 信号 + certain/uncertain 分层。uncertain 是给 Agent 的待办清单（配合 --skill 的任务说明）。name=项目名，patch_path=diff 文件路径", mcpSchemaObject([("name", "string", "项目名或 ID"), ("patch_path", "string", "unified diff 文件路径")], ["name", "patch_path"])))
    arr.add(mcpTool("codegraph_patch_merge", "补丁级置信度 Layer 3（合并器）：algorithm.json + agent.json → final.json。规则：agent resolved ×0.9 / unresolved 计负分 / ambiguous 0.5 / 未处理 deferred 0.5", mcpSchemaObject([("algorithm_json", "string", "Layer 1 输出的 JSON 文本"), ("agent_json", "string", "Layer 2 输出的 JSON 文本")], ["algorithm_json", "agent_json"])))
    arr.add(mcpTool("codegraph_confidence", "代码置信度：结构性疑点（孤儿/占位/吞错/魔法数/重复体…）的确定性度量。被动能力——只在本工具被显式调用时分析。format=json|text|llm（llm 产出可直接喂模型的逐条复核提示词）", mcpSchemaObject([("name", "string", "项目名或 ID"), ("format", "string", "json|text|llm，默认 json")], ["name"])))
    let o = Json.obj()
    Json.set(o, "tools", JArr(arr))
    return o
}

// ------------------------------ 工具执行 ------------------------------

/// MCP 文本结果。
///
/// ⚠️ 第二个参数是 **isError**（true = 失败），不是「成功」。
/// 这里以前叫 `mcpText(text, r.ok)` —— 把成功标志直接当 isError 传，
/// 于是语义**完全反转**：git push 失败 → 宿主看到「成功」；
/// run_track 成功 → 宿主看到「失败」，并可能因此重试。
/// MCP 宿主（Claude 等）按 isError 决定是否向用户报错、是否重试，
/// 双向失真都发生在「静默」上：失败不报错、成功被当成失败重试。
///
/// 现在参数名自带语义，且下面三处调用点显式取反 —— 宁可啰嗦也不留陷阱。
func mcpText(text: String, isError: Bool): JsonValue {
    let content = Json.obj()
    Json.set(content, "type", Json.of("text"))
    Json.set(content, "text", Json.of(text))
    let o = Json.obj()
    Json.set(o, "content", JArr(ArrayList<JsonValue>([content])))
    Json.set(o, "isError", Json.of(isError))
    return o
}

/// 成功结果。
func mcpOk(text: String): JsonValue {
    return mcpText(text, false)
}

/// 失败结果。
func mcpErr(message: String): JsonValue {
    return mcpText(message, true)
}

/// 解析「项目引用」→ ProjectEntry（空串 = 全部项目场景由调用方处理）
/// 「更新全部项目」的**显式**写法（#198）。
///
/// ⚠️ 原来这个语义挂在「参数缺失」上，于是模型漏一个 name 就批量改写
/// 每一个项目的文档托管区域。漏参数与「我要全部」是两件完全不同的事，
/// 必须在参数里分得开。
let ALL_PROJECTS_SENTINEL: String = "*"

func mcpRequireProject(ref: String): ProjectEntry {
    return requireProject(ref)
}

/// 工具执行：与 CLI 同源，进程内直连。
public func mcpCallTool(name: String, args: JsonValue): JsonValue {
    func getStr(key: String): String {
        match (Json.get(args, key)) {
            case Some(v) =>
                match (v) {
                    case JStr(t) => return t
                    case _ => return ""
                }
            case None => return ""
        }
    }
    // 严格的整数取参。**本文件所有数值参数都必须走这里**。
    //
    // 为什么不能用 Json.intAt：它对 JNum 一律 Int64(n) 静默截断，
    // 于是实测 get_journal 传 limit=1.5 被当成 1、limit="abc" 被当成缺省 8、
    // limit=1e30 也不报错，三个都 isError:false 照常返回。
    // 而**同一个文件**里的 get_group_context 对 budget=1.5 / "abc" 是报错的
    // —— 同一份工具清单里两套数值契约，调用方无从判断该信哪个。
    //
    // 契约：非整数 = 调用方写错了参数，必须报错而不是悄悄改。
    // 越界不是错误（按语义 clamp）：预算有上下界，limit 越大只是「全要」。
    // 远小于 Int64 上限、又远大于任何有意义的 limit / budget。
    // 越界不是错误：真正超出语义范围的由各自的 clamp 处理，
    // 这里的值只是「先夹住、别在 Int64(n) 上抛异常」。
    let SAFE_INT: Int64 = 900000000000000

    func strictIntArg(key: String): Option<Int64> {
        match (Json.get(args, key)) {
            case None => return None
            case Some(v) =>
                match (v) {
                    // JsonValue 的数字一律是 JNum(Float64)
                    case JNum(n) =>
                        // 先夹到远小于 Int64 上限的区间再转换：1e30 直接 Int64(n) 会抛异常
                        if (n > 1.0e15) {
                            return Some(SAFE_INT)
                        }
                        if (n < -1.0e15) {
                            return Some(-SAFE_INT)
                        }
                        let asInt = Int64(n)
                        // 转回浮点对不上 = 本来就不是整数
                        if (Float64(asInt) != n) {
                            return None
                        }
                        return Some(asInt)
                    // JSON 数字写成字符串的情况一并接受，但必须是合法整数
                    case JStr(s) =>
                        return try {
                            Some(Int64.parse(s.trimAscii()))
                        } catch (e: Exception) {
                            None
                        }
                    case _ => return None
                }
        }
    }

    // budget 专用：与 CLI 同一套契约（clampAgentBudget）。
    // 原来直接用 Json.intAt，实测传 budget=0 得到空上下文却回报 isError=false，
    // 传 1.5 会被截成 1（当时的 HTTP 侧同样输入会 clamp 到 500），两个入口结果不一致。
    func getBudget(): Option<Int64> {
        match (strictIntArg("budget")) {
            case None =>
                // 缺省与「显式传了但不是整数」必须分开：
                // 前者用默认值，后者报错。
                return if (Json.has(args, "budget")) { None } else { Some(AGENT_DEFAULT_BUDGET) }
            case Some(n) => return Some(clampAgentBudget(n))
        }
    }
    let config = loadConfig()
    let reg = loadRegistry()

    try {
        match (name) {
            case "list_projects" =>
                let statuses = allProjectStatuses(reg.projects, config, true)
                let lines = ArrayList<String>()
                for (st in statuses) {
                    if (Json.has(st, "error")) {
                        lines.add("${Json.strAt(st, "name", "")}：错误（${Json.strAt(st, "error", "")}）")
                    } else {
                        lines.add("${Json.strAt(st, "name", "")}：${Json.strAt(st, "headline", "")}")
                    }
                }
                // 全部采集失败时，列表里全是「名称：错误（…）」，
                // 而 isError:false 会让模型把它当成「这些项目都正常，只是没进展」。
                // 实测两个项目路径全失效时，返回 4 行错误 + isError:false。
                let allFail = groupExitCode(okCountOf(statuses), Int64(statuses.size))
                if (allFail != 0 && statuses.size > 0) {
                    lines.add("⚠ 以上 ${statuses.size} 个项目**全部采集失败**，没有任何一个项目的事实可用。请先修复路径/权限，或用 get_project_docs 逐个确认。")
                }
                return mcpText(joinStrings(lines, "\n"), allFail != 0)
            case "get_group_context" =>
                let b = getBudget()
                match (b) {
                    case Some(n) =>
                        let ctx = buildAgentContext(reg.projects, config, "group", "", n)
                        // 同上：全部采集失败时正文会写「项目 0 个」并列出全是
                        // 「状态获取失败」的小节。isError 必须为 true，
                        // 否则模型读到一个自称空的项目群。
                        return mcpText(ctx, groupExitCode(okCountOf(allProjectStatuses(reg.projects, config, true)),
                                                          Int64(reg.projects.size)) != 0)
                    case None =>
                        return mcpErr("budget 需要整数")
                }
            case "get_project_context" =>
                // 必须前置校验，否则「项目不存在」会变成 isError:false。
                // buildAgentContext 在找不到项目时 return 的是一段**字符串**
                // 「未找到项目：X」，原本直接 mcpOk 包装 —— isError:false，
                // AI 收到的是一段看起来像正文开头的文字 + 成功信号。
                // 它只能靠字符串匹配才发现失败，和 CLI 修之前一模一样
                // （CLI 现在靠 cmdContext 里的 requireProject 抛错）。
                // 姊妹工具 get_project_status / get_project_docs 都调了
                // mcpRequireProject，只有这个漏了。
                _ = mcpRequireProject(getStr("name"))
                let b = getBudget()
                match (b) {
                    case Some(n) =>
                        return mcpOk(buildAgentContext(reg.projects, config, "project", getStr("name"), n))
                    case None =>
                        return mcpErr("budget 需要整数")
                }
            case "codegraph_overview" =>
                let p = mcpRequireProject(getStr("name"))
                let g = buildGraph(p.path)
                mcpOk(Json.pretty(overviewJson(g)))
            case "codegraph_tree" =>
                let p = mcpRequireProject(getStr("name"))
                let g = buildGraph(p.path)
                var depth: Int64 = 6
                match (strictIntArg("depth")) {
                    case Some(d) =>
                        depth = if (d < 1) { 1 } else { if (d > 24) { 24 } else { d } }
                    case None => ()
                }
                mcpOk(Json.pretty(fullGraphJson(g)))
            case "codegraph_symbol" =>
                let p = mcpRequireProject(getStr("name"))
                let sym = getStr("symbol")
                if (sym.isEmpty()) { return mcpErr("symbol is required") }
                let g = buildGraph(p.path)
                let o = symbolJson(g, sym)
                if (Json.arrAt(o, "defs").size == 0) {
                    return mcpErr("symbol not found: ${sym} (lexical index covers supported source languages only)")
                }
                mcpOk(Json.pretty(o))
            case "codegraph_impact" =>
                let p = mcpRequireProject(getStr("name"))
                let sym = getStr("symbol")
                if (sym.isEmpty()) { return mcpErr("symbol is required") }
                let g = buildGraph(p.path)
                match (impactOf(g, sym)) {
                    case Some(res) => mcpOk(Json.pretty(impactJson(res)))
                    case None => mcpErr("symbol not found: ${sym}")
                }
            case "codegraph_patch_confidence" =>
                let p = mcpRequireProject(getStr("name"))
                let patchPath = getStr("patch_path")
                if (patchPath.isEmpty()) { return mcpErr("patch_path is required") }
                let patchText = match (readFileText(patchPath)) {
                    case Some(t) => t
                    case None => return mcpErr("cannot read patch file: " + patchPath)
                }
                let g = buildGraph(p.path)
                mcpOk(Json.pretty(patchConfidenceJson(analyzePatchConfidence(g, patchText))))
            case "codegraph_patch_merge" =>
                let algText = getStr("algorithm_json")
                let agText = getStr("agent_json")
                if (algText.isEmpty() || agText.isEmpty()) {
                    return mcpErr("algorithm_json and agent_json are required")
                }
                match (Json.parse(algText)) {
                    case Some(alg) =>
                        match (Json.parse(agText)) {
                            case Some(ag) =>
                                match (mergePatchConfidence(alg, ag)) {
                                    case Some(m) => mcpOk(Json.pretty(mergedConfidenceJson(m, alg)))
                                    case None => mcpErr("merge failed (malformed inputs)")
                                }
                            case None => mcpErr("agent_json is not valid JSON")
                        }
                    case None => mcpErr("algorithm_json is not valid JSON")
                }
            case "codegraph_confidence" =>
                let p = mcpRequireProject(getStr("name"))
                var format = "json"
                let f = getStr("format")
                if (!f.isEmpty()) { format = f }
                let g = buildGraph(p.path)
                let report = analyzeConfidence(g, true)
                if (format == "text") {
                    mcpOk(confidenceText(report))
                } else if (format == "llm") {
                    mcpOk(confidenceLlmPrompt(report, p.name))
                } else if (format == "json") {
                    mcpOk(Json.pretty(confidenceJson(report)))
                } else {
                    mcpErr("format accepts json | text | llm (got: ${format})")
                }
            case "codegraph_arch" =>
                let p = mcpRequireProject(getStr("name"))
                var format = "html"
                let f = getStr("format")
                if (!f.isEmpty()) { format = f }
                let g = buildGraph(p.path)
                let arch = buildArch(g)
                layoutArch(arch)
                if (format == "mermaid") {
                    mcpOk(archMermaid(arch, false))
                } else if (format == "dot") {
                    mcpOk(archDot(arch, false))
                } else if (format == "json") {
                    mcpOk(Json.pretty(archJson(arch, false)))
                } else if (format == "html") {
                    mcpOk(archCanvasHtml(arch, false))
                } else {
                    mcpErr("format accepts html | mermaid | dot | json (got: ${format})")
                }
            case "get_project_status" =>
                let p = mcpRequireProject(getStr("name"))
                let st = projectStatus(p, config, 8)
                // ⚠️ 这里返回**裸 ProjectStatus**，不是 CLI 的 `{projects, summary, language}` envelope。
                //
                // 这是**有意**的，别"顺手统一"：
                //   MCP get_project_status —— 单项目语义（mcpRequireProject 保证恰好一个），
                //     不存在 0/1/N 三种情况，套 envelope 只是让 LLM 多剥一层、白花 token。
                //   CLI status [项目]      —— 参数可选，0/1/N 都可能出现，
                //     恒定 envelope 才是「客户端只需一套解码器」的契约
                //     （cli.cj 的注释原话：「恒定 envelope 形状…（客户端契约）」）。
                //
                // 消费方要共用解码器就得写两个分支 —— 这是**已知且刻意**的取舍，
                // 由 deepDolphin/macos/scripts/contract-check.sh 的第 10 组断言钉住，
                // 改形状会立刻红。
                return mcpText(Json.pretty(st), false)
            case "get_dashboard" =>
                let dash = buildDashboard(reg.projects, config)
                // projects.total 是采集成功数，listed/failed 才是总量与失败量。
                // 全部失败时 total=0，原实现照样 isError:false 返回，
                // 模型据此认为「这个项目群没有任何项目」。
                return mcpText(Json.pretty(dash),
                               groupExitCode(Json.intAt(Json.getOr(dash, "projects"), "total", 0),
                                             Json.intAt(Json.getOr(dash, "projects"), "listed", 0)) != 0)
            case "get_project_docs" =>
                let p = mcpRequireProject(getStr("name"))
                let r = readProjectDocs(p.path, config)
                let parts = ArrayList<String>()
                for (d in r.docs) {
                    parts.add("## ${d.file}\n\n${d.content}")
                }
                // 「存在但读不出来」必须说清楚。把两种都压成空列表时，
                // 一份权限被改（或路径不是普通文件）的 README 会被报成
                // 「该项目没有可读文档」—— 模型会据此认定项目没文档，
                // 甚至转头去新建一份。
                let body = if (r.docs.isEmpty()) {
                    "（该项目没有可读文档）"
                } else {
                    joinStrings(parts, "\n\n")
                }
                let n = r.notice()
                return mcpText(if (n.isEmpty()) { body } else { "${body}\n\n${n}" }, false)
            case "get_journal" =>
                let p = mcpRequireProject(getStr("name"))
                // 负数/零 limit 以前会一路传到 readJournal，返回空列表，
                // 模型看到「（暂无日志）」会以为项目没有更新记录，而不是参数写错了。
                // 必须走 strictIntArg，与同文件的 budget 同一套契约。
                // 原来用 getInt（Json.intAt）：limit=1.5 静默截成 1、limit="abc"
                // 静默取缺省 8、limit=1e30 也不报错，三个都 isError:false 照常返回 ——
                // 模型于是以为「这个项目只有 1 条日志」，而它传的根本不是 1。
                var limit: Int64 = 8
                if (Json.has(args, "limit")) {
                    match (strictIntArg("limit")) {
                        case Some(n) => limit = n
                        case None => return mcpErr("limit 需要正整数")
                    }
                }
                if (limit <= 0) {
                    return mcpErr("limit 需要正整数，收到：${limit}")
                }
                let (journal, badLines, windowExhausted) = readJournalWindow(p.id, limit)
                let lines = ArrayList<String>()
                for (e in journal) {
                    lines.add("[${Json.strAt(e, "at", "")}] ${Json.strAt(e, "mode", "")} · ${Json.strAt(e, "branch", "")}：${Json.strAt(e, "summary", "")}")
                }
                // 模型看到「（暂无日志）」会以为项目没有更新记录，而不是数据有损坏
                if (badLines > 0) {
                    lines.add("⚠️ 有 ${badLines} 行日志无法解析（通常是进程被强杀留下的半截行），已跳过")
                }
                // ⚠️ 窗口披露必须给，而且必须**放在最后一行**（缺陷 #189）。
                // 实测：12 条记录 + 默认 limit=8，工具返回 8 行且零提示 ——
                // 模型据此认定「这个项目只更新过 8 次」，并可能据此判断项目不活跃。
                // 放最后是因为模型读的是结尾结论；放前面会被当成一条普通记录。
                if (windowExhausted) {
                    lines.add("⚠️ 以上是最近 ${limit} 条，**更早处还有记录**（不是全部）。要看全量请把 limit 调大后重试。")
                }
                return mcpText(if (lines.isEmpty()) { "（暂无日志）" } else { joinStrings(lines, "\n") }, false)
            case "run_shallow_update" =>
                let refs = getStr("name")
                // ⚠️ #198：空 name 不再是「全部项目」，而是**要求重填**。
                // schema 里 name 已改成必填，但模型仍可能传 "" ——
                // 两道都要有：schema 是给模型看的提示，处理器才是闸门。
                if (refs.trimAscii().isEmpty()) {
                    return mcpErr("run_shallow_update 需要 name（单个项目名或 ID）。留空会改写**每一个**已注册项目的文档托管区域，所以这里不接受空值——要更新整个项目群请显式传 name=\"*\"。")
                }
                let targets = ArrayList<ProjectEntry>()
                if (refs.trimAscii() == ALL_PROJECTS_SENTINEL) {
                    // 显式的「全部」。原来这个语义挂在「参数缺失」上，
                    // 于是模型漏一个参数就变成批量写 —— 见上面的注释。
                    for (p in reg.projects) {
                        if (!p.disabled) {
                            targets.add(p)
                        }
                    }
                } else {
                    targets.add(mcpRequireProject(refs))
                }
                let out = ArrayList<String>()
                var failed: Int64 = 0
                // ⚠️ 必须逐项目 try —— runUpdate 对失效路径是**抛异常**而不是
                // 返回 r.ok=false。原来没有这层保护：
                //   第 1 个项目更新成功（进度库/journal/文档都已落盘，是真实副作用）
                //   第 2 个项目路径失效 → 抛异常 → 整个 mcpCallTool 被外层 catch
                //   → 已完成项目的那行报告被整个丢弃，剩下的也不再处理
                // 宿主收到的是一句「路径不存在」，据此会以为什么都没发生而重跑全部。
                // 「已经写进去的东西」和「报出来的东西」对不上 = 事实性谎言。
                // HTTP 的 /api/update 早有这层保护，只有 MCP 漏了。
                for (p in targets) {
                    let opts = UpdateOptions()
                    opts.mode = "shallow"
                    opts.source = "mcp"
                    try {
                        let r = runUpdate(p, config, opts)
                        if (r.ok) {
                            out.add("${p.name}：ok，${r.commitCount} 提交")
                        } else {
                            failed += 1
                            out.add("${p.name}：失败（更新未成功）")
                        }
                    } catch (e: Exception) {
                        failed += 1
                        out.add("${p.name}：失败（${chainError("${p.name} 执行失败", e).message}）")
                    }
                }
                if (targets.size == 0) {
                    return mcpErr("没有可更新的项目")
                }
                // 全部失败时不能 isError:false（与 #115 的聚合出口同一判据）：
                // 逐行写着「失败」却回报成功，宿主不会提示用户。
                let allFail = groupExitCode(Int64(targets.size) - failed, Int64(targets.size))
                return mcpText(joinStrings(out, "\n"), allFail != 0)
            case "run_deep_update" =>
                let p = mcpRequireProject(getStr("name"))
                let opts = DeepOptions()
                opts.scope = getStr("scope")
                if (opts.scope.isEmpty()) {
                    opts.scope = "all"
                } else {
                    // 拼错必须报错，不能默默变成全量重写。
                    // runDeep 内部是 `scope != "agent"` / `!= "readme"` 的排除法，
                    // 任何认不出来的值都等同于 "all" —— README 和 AGENTS/CLAUDE
                    // 一起被重写，是三种 scope 里破坏性最大的那个。
                    // AI 传 "Readme" / "agents" / "readme " 的概率不低。
                    // （CLI 和 HTTP 早就有这个校验，只有 MCP 漏了；
                    //   现在 runDeep 里也有一道，任何调用面都躲不掉。）
                    try {
                        validateDeepScope(opts.scope)
                    } catch (e: DgError) {
                        return mcpErr(e.message)
                    }
                }
                opts.source = "mcp"
                let r = runDeep(p, config, opts)
                if (r.ok) {
                    return mcpOk("${p.name} 深度更新完成（${r.provider}）")
                }
                return mcpErr("${p.name} 深度更新失败")
            case "run_track" =>
                let p = mcpRequireProject(getStr("name"))
                let r = runTrack(p, config, "mcp")
                if (r.ok) {
                    return mcpOk("${p.name} 快照完成（${r.commitCount} 提交）")
                }
                return mcpErr("${p.name} 快照失败")
            case "git_op" =>
                let p = mcpRequireProject(getStr("name"))
                let r = runGitOp(p.path, getStr("op"), getStr("message"))
                // 失败必须带 isError:true —— 宿主据此决定是否报错/重试。
                // 曾经这里传的是 r.ok（成功为 true），语义完全反转：
                // git push 失败被报成成功，宿主不会提示用户。
                if (r.ok) {
                    return mcpOk("[${r.op}] ${r.output}")
                }
                return mcpErr("[${r.op}] ${r.output}")
            case "list_milestones" =>
                let ms = buildMilestoneOverview(reg.projects, config)
                return mcpText(Json.pretty(ms), false)
            case "milestone_add" =>
                let p = mcpRequireProject(getStr("project"))
                let (m, created) = addMilestone(p.id, getStr("name"), getStr("description"), getStr("target_date"), getStr("tag"))
                return mcpText(if (created) { "已创建：${m.name}" } else { "已存在：${m.name}" }, false)
            case "milestone_action" =>
                let p = mcpRequireProject(getStr("project"))
                let mn = getStr("name")
                let action = getStr("action")
                if (action == "remove") {
                    return mcpText(if (removeMilestone(p.id, mn)) { "已删除 ${mn}" } else { "未找到 ${mn}" }, false)
                }
                var status = ""
                if (action == "done") {
                    status = "done"
                } else if (action == "drop") {
                    status = "dropped"
                } else if (action == "open" || action == "reopen") {
                    status = "open"
                } else {
                    // 旧实现把 status 默认成 "open"，于是 AI 拼错成 "opne"/"delete"/空串
                    // 也会静默执行一次 reopen 并返回 isError:false —— typo 直接变成
                    // 一次非预期的状态变更。未知 action 必须报错。
                    return mcpErr("未知 action：${action}（支持 done|open|reopen|drop|remove）")
                }
                let ok = setMilestoneStatus(p.id, mn, status)
                if (!ok) {
                    return mcpText("未找到 ${mn}", true)
                }
                // ⚠️ 必须回读实际生效状态，不能只报「请求写入的状态」。
                //
                // setMilestoneStatus 返回 true 只代表**写进去了**，
                // 不代表最终状态就是它：同名/绑定 tag 仍存在时，
                // milestoneProgress 会按「tag 达成即自动完成」把状态算回 done。
                // 实测（里程碑绑 tag v9.9 且已达成，手动 reopen）：
                //     CLI : {"requested":"open","status":"done","applied":false}
                //     HTTP: 409 + {"applied":false}
                //     MCP : {"text":"自动完成 → open","isError":false}   ← 修复前
                // MCP 侧原文案是 "${mn} → ${status}"，正是 cli.cj 注释里点名的
                // 「报告了一个根本没有生效的结果」。而且 isError:false 会让模型
                // 停止追查，直接向用户复述「里程碑已重开」。
                let effective = effectiveMilestoneStatus(p, mn, status)
                if (effective == status) {
                    return mcpText("${mn} → ${status}", false)
                }
                return mcpText(
                    "${mn}：请求 ${status}，但实际生效状态是 ${effective}" +
                    "（同名或绑定 tag 仍达成，引擎按「tag 达成即自动完成」把它算回 ${effective}）；" +
                    "若确需 ${status}，请先解除绑定或换一个 tag",
                    true,
                )
            case "add_project" =>
                let path = getStr("path")
                let name = getStr("name")
                let (p, created) = addProject(path, if (name.isEmpty()) { basename(normalizePath(expandHome(path))) } else { name }, ArrayList<String>(), "")
                return mcpText(if (created) { "已注册：${p.name}（${p.path}）" } else { "已存在：${p.name}" }, false)
            case _ =>
                return mcpErr("未知工具：${name}")
        }
    } catch (e: Exception) {
        return mcpErr(e.message)
    }
}

// ------------------------------ JSON-RPC 处理 ------------------------------

/// 处理一条 JSON-RPC 请求。通知（无 id）返回 None。
///
/// ⚠️ **批量请求不是单条请求**。JSON-RPC 2.0 允许顶层是一个数组，
/// 语义是「一批请求」，服务端必须回一个响应数组。
/// 原来 mcpRun 把解析结果原样传进来，而 `Json.has(req, "id")` 对数组恒为 false
/// —— 于是整批被当成 notification **静默丢弃，一行输出都没有**。
/// 后果不是「少回几条」，而是客户端把这一行读走后仍在等那个数组响应，
/// 表现为挂起直到超时。（与 #115 同族：把「我没处理」说成了「没这回事」。）
public func mcpHandle(req: JsonValue): Option<JsonValue> {
    // 批量：逐条处理，只回有 id 的（通知不回），最后回一个数组。
    match (req) {
        case JArr(items) => return mcpHandleBatch(items)
        case _ => ()
    }
    let method = Json.strAt(req, "method", "")
    let hasId = Json.has(req, "id")
    if (!hasId) {
        return Option<JsonValue>.None  // notification
    }
    let id = Json.getOr(req, "id")

    func respond(result: JsonValue): JsonValue {
        let o = Json.obj()
        Json.set(o, "jsonrpc", Json.of("2.0"))
        Json.set(o, "id", id)
        Json.set(o, "result", result)
        return o
    }
    func respondErr(code: Int64, message: String): JsonValue {
        let errObj = Json.obj()
        Json.set(errObj, "code", Json.of(code))
        Json.set(errObj, "message", Json.of(message))
        let o = Json.obj()
        Json.set(o, "jsonrpc", Json.of("2.0"))
        Json.set(o, "id", id)
        Json.set(o, "error", errObj)
        return o
    }

    match (method) {
        case "initialize" =>
            let server = Json.obj()
            Json.set(server, "name", Json.of("moongit"))
            Json.set(server, "version", Json.of("0.1.0"))
            let caps = Json.obj()
            let toolsCap = Json.obj()
            Json.set(toolsCap, "listChanged", Json.of(false))
            Json.set(caps, "tools", toolsCap)
            let resCap = Json.obj()
            Json.set(resCap, "subscribe", Json.of(false))
            Json.set(caps, "resources", resCap)
            let result = Json.obj()
            Json.set(result, "protocolVersion", Json.of("2024-11-05"))
            Json.set(result, "capabilities", caps)
            Json.set(result, "serverInfo", server)
            return Some(respond(result))
        case "ping" =>
            return Some(respond(Json.obj()))
        case "tools/list" =>
            return Some(respond(mcpToolList()))
        case "tools/call" =>
            let params = Json.getOr(req, "params")
            let name = Json.strAt(params, "name", "")
            let args = Json.getOr(params, "arguments")
            let result = mcpCallTool(name, args)
            return Some(respond(result))
        case "resources/list" =>
            let reg = loadRegistry()
            let arr = ArrayList<JsonValue>()
            for (p in reg.projects) {
                let r = Json.obj()
                Json.set(r, "uri", Json.of("deepgit://project/${p.id}"))
                Json.set(r, "name", Json.of(p.name))
                Json.set(r, "mimeType", Json.of("application/json"))
                arr.add(r)
            }
            let result = Json.obj()
            Json.set(result, "resources", JArr(arr))
            return Some(respond(result))
        case "resources/read" =>
            let params = Json.getOr(req, "params")
            let uri = Json.strAt(params, "uri", "")
            let prefix = "deepgit://project/"
            if (!uri.startsWith(prefix)) {
                return Some(respondErr(-32602, "未知资源：${uri}"))
            }
            let pid = uri[prefix.size..]
            match (findProjectIn(loadRegistry(), pid)) {
                case Some(p) =>
                    let config = loadConfig()
                    let st = projectStatus(p, config, 8)
                    let result = Json.obj()
                    let contents = Json.obj()
                    Json.set(contents, "uri", Json.of(uri))
                    Json.set(contents, "mimeType", Json.of("application/json"))
                    Json.set(contents, "text", Json.of(Json.pretty(st)))
                    Json.set(result, "contents", JArr(ArrayList<JsonValue>([contents])))
                    return Some(respond(result))
                case None =>
                    return Some(respondErr(-32602, "未找到项目：${pid}"))
            }
        case "prompts/list" =>
            let prompt = Json.obj()
            Json.set(prompt, "name", Json.of("project_brief"))
            Json.set(prompt, "description", Json.of("生成某个项目的现状说明（调用工具收集事实后输出 markdown）"))
            let args = Json.obj()
            let arg = Json.obj()
            Json.set(arg, "description", Json.of("项目名或 ID"))
            Json.set(args, "project", arg)
            Json.set(prompt, "arguments", args)
            let result = Json.obj()
            Json.set(result, "prompts", JArr(ArrayList<JsonValue>([prompt])))
            return Some(respond(result))
        case "prompts/get" =>
            let params = Json.getOr(req, "params")
            let pname = Json.strAt(params, "name", "")
            if (pname != "project_brief") {
                return Some(respondErr(-32602, "未知 prompt：${pname}"))
            }
            let pparams = Json.getOr(params, "arguments")
            let proj = Json.strAt(pparams, "project", "")
            let msg = Json.obj()
            Json.set(msg, "role", Json.of("user"))
            Json.set(msg, "content", Json.of("请生成项目 ${proj} 的现状说明：先用 get_project_context 收集事实，再输出一份 markdown 说明（现状/分支/风险/下一步）。"))
            let result = Json.obj()
            Json.set(result, "messages", JArr(ArrayList<JsonValue>([msg])))
            return Some(respond(result))
        case _ =>
            return Some(respondErr(-32601, "未知方法：${method}"))
    }
}

/// 批量请求：逐条处理，只回有 id 的（通知按规范不回），**整体回一个顶层裸数组**。
///
/// 全是通知时返回 None（不输出任何东西）—— 这符合规范，
/// 但**不能**和「整批被丢弃」混为一谈，所以下面那条测试专门区分这两种情况。
private func mcpHandleBatch(items: ArrayList<JsonValue>): Option<JsonValue> {
    // 空数组是无效请求（-32600），不是「空批次」
    if (items.isEmpty()) {
        let errObj = Json.obj()
        Json.set(errObj, "code", Json.of(-32600))
        Json.set(errObj, "message", Json.of("批量请求不能是空数组"))
        let o = Json.obj()
        Json.set(o, "jsonrpc", Json.of("2.0"))
        Json.set(o, "id", Json.null())
        Json.set(o, "error", errObj)
        return Some(o)
    }
    let out = ArrayList<JsonValue>()
    for (item in items) {
        match (mcpHandle(item)) {
            case Some(resp) => out.add(resp)
            case None => ()
        }
    }
    if (out.isEmpty()) {
        return Option<JsonValue>.None
    }
    // ⚠️ 顶层必须是**裸数组**。
    // JSON-RPC 2.0 对批量的规定是「请求是数组 → 响应也是数组」，
    // 客户端按数组解析。包成 {"jsonrpc":..,"id":null,"result":[..]} 它就当非法响应丢掉。
    // 端到端用真二进制发批量才发现的：单测当时只查了数组里每条的 id 对不对，
    // 没查顶层形状，于是信封版本一路绿灯通过。
    return Some(JArr(out))
}

/// MCP 主循环（stdio：单行 JSON 进 / 单行 JSON 出）
/// MCP 响应出口：**必须逐行 flush** ——
/// printOut 底层的 println 在管道（非 tty）下是块缓冲，
/// 宿主会一直等不到响应直到进程退出，协议等于死锁。
/// MCP 是请求-响应式的长会话，flush 是协议的一部分，不是优化。
func mcpEmit(line: String): Unit {
    printOut(line)
    Console.stdOut.flush()
}

public func mcpRun(): Int64 {
    Log.setQuiet(true)
    while (true) {
        let lineOpt = Console.stdIn.readln()
        match (lineOpt) {
            case Some(raw) =>
                let line = raw.trimAscii()
                if (line.isEmpty()) {
                    continue
                }
                let reqOpt = Json.parse(line)
                match (reqOpt) {
                    case Some(req) =>
                        match (mcpHandle(req)) {
                            case Some(resp) => mcpEmit(Json.compact(resp))
                            case None => ()
                        }
                    case None =>
                        let errObj = Json.obj()
                        Json.set(errObj, "code", Json.of(-32700))
                        Json.set(errObj, "message", Json.of("解析错误"))
                        let o = Json.obj()
                        Json.set(o, "jsonrpc", Json.of("2.0"))
                        Json.set(o, "id", Json.null())
                        Json.set(o, "error", errObj)
                        mcpEmit(Json.compact(o))
                }
            case None => break  // EOF
        }
    }
    return 0
}

// ------------------------------ 测试 ------------------------------

@Test
func testMcpInitializeAndTools(): Unit {
    let req = Json.obj()
    Json.set(req, "jsonrpc", Json.of("2.0"))
    Json.set(req, "id", Json.of(1))
    Json.set(req, "method", Json.of("initialize"))
    let resp = mcpHandle(req)
    @Assert(resp.isSome())
    let r = resp.getOrThrow()
    @Assert(Json.strAt(r, "jsonrpc", "") == "2.0")
    let result = Json.getOr(r, "result")
    @Assert(Json.strAt(result, "protocolVersion", "") == "2024-11-05")

    let req2 = Json.obj()
    Json.set(req2, "id", Json.of(2))
    Json.set(req2, "method", Json.of("tools/list"))
    let resp2 = mcpHandle(req2).getOrThrow()
    let tools = Json.arrAt(Json.getOr(resp2, "result"), "tools")
    @Assert(tools.size >= 14)
}

@Test
func testMcpNotificationReturnsNone(): Unit {
    let req = Json.obj()
    Json.set(req, "method", Json.of("notifications/initialized"))
    @Assert(mcpHandle(req).isNone())
}

@Test
func testMcpUnknownMethod(): Unit {
    let req = Json.obj()
    Json.set(req, "id", Json.of(9))
    Json.set(req, "method", Json.of("nope"))
    let resp = mcpHandle(req).getOrThrow()
    let err = Json.getOr(resp, "error")
    @Assert(Json.intAt(err, "code", 0) == -32601)
}

@Test
func testMcpToolsCallOnTempRepo(): Unit {
    let base = "/tmp/deepgit-mcp-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.cj", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: mcp 测试"], false)

    let home = "${base}/home"
    ensureDir(home)
    enterTestHome(home)
    let (p, created) = addProject(base, "mcp-demo", ArrayList<String>(), "")
    @Assert(created)

    // get_project_status
    let req = Json.obj()
    Json.set(req, "id", Json.of(3))
    Json.set(req, "method", Json.of("tools/call"))
    let params = Json.obj()
    Json.set(params, "name", Json.of("get_project_status"))
    let args = Json.obj()
    Json.set(args, "name", Json.of("mcp-demo"))
    Json.set(params, "arguments", args)
    Json.set(req, "params", params)
    let resp = mcpHandle(req).getOrThrow()
    let result = Json.getOr(resp, "result")
    let contentArr = Json.arrAt(result, "content")
    @Assert(contentArr.size == 1)
    let text = Json.strAt(contentArr[0], "text", "")
    @Assert(text.contains("mcp-demo"))
    @Assert(Json.boolAt(result, "isError", true) == false)

    // milestone roundtrip
    let req2 = Json.obj()
    Json.set(req2, "id", Json.of(4))
    Json.set(req2, "method", Json.of("tools/call"))
    let params2 = Json.obj()
    Json.set(params2, "name", Json.of("milestone_add"))
    let args2 = Json.obj()
    Json.set(args2, "project", Json.of("mcp-demo"))
    Json.set(args2, "name", Json.of("v9.9"))
    Json.set(params2, "arguments", args2)
    Json.set(req2, "params", params2)
    let resp2 = mcpHandle(req2).getOrThrow()
    let text2 = Json.strAt(Json.arrAt(Json.getOr(resp2, "result"), "content")[0], "text", "")
    @Assert(text2.contains("已创建"))

    exitTestHome()
    removePathIfExists(base)
}

/// isError 的语义不得反转 —— 走真实的工具分发验证。
///
/// 旧实现三处写成 `mcpText(text, r.ok)` —— 把「成功=true」直接当 isError 传。
/// 后果双向静默失真：git push 失败被报成成功（宿主不报错、不重试），
/// run_track 成功被报成失败（宿主可能反复重试）。
/// MCP 宿主按 isError 决定是否向用户报错 —— 那是它唯一的成败信号。
///
/// ⚠️ 这个测试必须走 mcpCallTool 真分发。只断言 mcpOk/mcpErr 两个辅助函数
/// 是没用的：辅助函数一直是对的，错的是调用点把 r.ok 塞进了 isError 位。
/// （第一版就是这么写的，负控一跑就露馅。）
@Test
func testMcpToolResultsCarryCorrectIsError(): Unit {
    let base = "/tmp/deepgit-mcperr-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/a.txt", "1")
    gitRun(base, ["add", "."], false)
    gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)
    // 必须真正写进注册表：mcpCallTool 内部走 loadRegistry()，
    // 局部 Registry 对象它看不见（第一版就栽在这里 —— 项目找不到 → 抛错 →
    // 走 mcpErr → isError:true，看起来像修复没生效）。
    let (_, _) = addProject(base, "mcp-err", ArrayList<String>(), "")
    let pid = projectIdFor(base)

    // 成功路径：run_track 应当 isError:false
    let okArgs = Json.obj()
    Json.set(okArgs, "name", Json.of("mcp-err"))
    let okRes = mcpCallTool("run_track", okArgs)
    @Assert(Json.boolAt(okRes, "isError", true) == false)

    // 失败路径：git_op 对一个没有 remote 的仓库做 push 必然失败
    let badArgs = Json.obj()
    Json.set(badArgs, "name", Json.of("mcp-err"))
    Json.set(badArgs, "op", Json.of("push"))
    let badRes = mcpCallTool("git_op", badArgs)
    // 核心断言：失败必须报 isError:true
    @Assert(Json.boolAt(badRes, "isError", false) == true)

    // 未知工具仍走 mcpErr
    @Assert(Json.boolAt(mcpCallTool("no_such_tool", Json.obj()), "isError", false) == true)

    removePathIfExists(base)
    removePathIfExists(deepgitPath(["store", pid]))
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testMcpBudgetIsClampedAndValidated(): Unit {
    // 必须走真实的 mcpCallTool，而不是只测 clampAgentBudget：
    // 参数解析（JNum 是 Float64、intAt 会截断小数）都在这一层，改回去测试不会红。
    let args = Json.obj()
    // 缺省
    @Assert(mcpTextOf(mcpCallTool("get_group_context", args)).size > 0)
    // 越界：0 / 负数 原来都得到空上下文且 isError=false
    @Assert(mcpTextOf(mcpCallTool("get_group_context", withBudget(Json.obj(), 0.0))).size > 0)
    @Assert(mcpTextOf(mcpCallTool("get_group_context", withBudget(Json.obj(), -5000.0))).size > 0)
    @Assert(mcpTextOf(mcpCallTool("get_group_context", withBudget(Json.obj(), 1000000000000000.0))).size > 0)
    // 非整数：原来 intAt 静默截成 1
    @Assert(mcpIsError(mcpCallTool("get_group_context", withBudget(Json.obj(), 1.5))))
    // 非数字类型
    @Assert(mcpIsError(mcpCallTool("get_group_context", withBudget(Json.obj(), "abc"))))
    // 合法区间内不该报错
    @Assert(!mcpIsError(mcpCallTool("get_group_context", withBudget(Json.obj(), 500.0))))
    // 数字写成字符串要能接受
    @Assert(!mcpIsError(mcpCallTool("get_group_context", withBudget(Json.obj(), "5000"))))
}

func withBudget(args: JsonValue, v: Float64): JsonValue {
    Json.set(args, "budget", Json.of(v))
    return args
}

func withBudget(args: JsonValue, v: String): JsonValue {
    Json.set(args, "budget", Json.of(v))
    return args
}

func mcpTextOf(r: JsonValue): String {
    let content = Json.arrAt(r, "content")
    if (content.size == 0) {
        return ""
    }
    return Json.strAt(content[0], "text", "")
}

func mcpIsError(r: JsonValue): Bool {
    return Json.boolAt(r, "isError", false)
}

@Test
func testAddMilestoneRejectsEmptyName(): Unit {
    // MCP 的 milestone_add 不校验参数，原来传 name="" 会写进存储一条空名里程碑，
    // 回报还是「已创建：」后面什么都没有。校验放在 kernel 层，HTTP/CLI/MCP 同时受保护。
    var threw = false
    try {
        addMilestone("p_x", "", "描述", "", "")
    } catch (e: DgError) {
        threw = true
    }
    @Assert(threw)

    var threwBlank = false
    try {
        addMilestone("p_x", "   ", "描述", "", "")
    } catch (e: DgError) {
        threwBlank = true
    }
    @Assert(threwBlank)
}

@Test
func testMcpAggregateToolsFailLoudlyWhenEveryProjectFails(): Unit {
    // 三个聚合出口原来恒 isError:false，而正文自称「项目 0 个」。
    //
    // 实测（两个已注册项目路径全失效）：
    //   get_group_context → isError:false，正文「- 项目 0 个」，
    //                       紧接着「项目速览」却列着 ### a / ### b 两个失败小节
    //   get_dashboard     → isError:false，projects.total=0 而 listed=2 failed=2
    //   list_projects     → isError:false，4 行「名称：错误（…）」被当成正常现状
    //
    // 模型读的是第一行。isError:false + 「项目 0 个」= 它会认定项目群是空的，
    // 甚至据此去新建项目。这跟 CLI 的 dashboard 直接 exit 1 也对不上 ——
    // 同一个事实，两个调用面给出相反的判断。
    let base = "/tmp/deepgit-mcpallfail-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    // 造两个真实存在的仓库再移走：路径失效是稳定的采集失败来源
    let repoA = base + "/a"
    let repoB = base + "/b"
    for (r in [repoA, repoB]) {
        ensureDir(r)
        gitRun(r, ["init", "-b", "main"], false)
        writeFileAtomic(r + "/a.txt", "1")
        gitRun(r, ["add", "."], false)
        gitRun(r, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)
    }
    let (_, _) = addProject(repoA, "afail", ArrayList<String>(), "")
    let (_, _) = addProject(repoB, "bfail", ArrayList<String>(), "")
    let pidA = projectIdFor(repoA)
    let pidB = projectIdFor(repoB)
    removePathIfExists(repoA)
    removePathIfExists(repoB)

    // get_group_context
    let ctx = mcpCallTool("get_group_context", withBudget(Json.obj(), 12000.0))
    @Assert(mcpIsError(ctx))
    // 前提：正文确实在说谎（否则下面只是「文案变了」）
    @Assert(mcpTextOf(ctx).contains("项目 0 个"))
    // 修复后必须自报口径
    @Assert(mcpTextOf(ctx).contains("采集失败，未计入"))

    // get_dashboard
    let dash = mcpCallTool("get_dashboard", Json.obj())
    @Assert(mcpIsError(dash))

    // list_projects：不仅 isError，还要有一句人话披露
    let list = mcpCallTool("list_projects", Json.obj())
    @Assert(mcpIsError(list))
    @Assert(mcpTextOf(list).contains("全部采集失败"))

    // 对照组：项目能用时必须仍是 isError:false ——
    // 否则这条测试就只是把工具改成永远报错。
    // 用**独立沙箱**而不是「删了重建」：真实二进制复刻删除-重建时序完全正常，
    // 但在同一测试内切换状态时对照组断言恒红，测的是状态切换而不是契约。
    let okA = base + "-ok/a"
    let okB = base + "-ok/b"
    for (r in [okA, okB]) {
        ensureDir(r)
        gitRun(r, ["init", "-b", "main"], false)
        writeFileAtomic(r + "/a.txt", "1")
        gitRun(r, ["add", "."], false)
        gitRun(r, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)
    }
    let (_, _) = addProject(okA, "okA", ArrayList<String>(), "")
    let (_, _) = addProject(okB, "okB", ArrayList<String>(), "")
    let pidOkA = projectIdFor(okA)
    let pidOkB = projectIdFor(okB)
    @Assert(!mcpIsError(mcpCallTool("get_dashboard", Json.obj())))
    @Assert(!mcpIsError(mcpCallTool("list_projects", Json.obj())))
    // 此时注册表里有 4 个项目：okA / okB 可用，afail / bfail 的目录已被删掉。
    // 于是这是**部分失败**（2 好 2 坏），不是「全部采集失败」：
    //   · isError 必须为 false —— 还有事实可用，报错是过度反应
    //   · 但披露必须照给 —— 口径是「成功 2 个」，漏掉的 2 个要写明
    // （我曾把这里断言成「不得出现披露」，前提是错的：坏项目只是删了目录，
    //   注册表条目还在，披露本就应该出现。测的是前提，不是行为。）
    let partialCtx = mcpTextOf(mcpCallTool("get_group_context", withBudget(Json.obj(), 12000.0)))
    @Assert(partialCtx.contains("项目 2 个（另 2 个采集失败，未计入下列统计）"))
    @Assert(!mcpIsError(mcpCallTool("get_group_context", withBudget(Json.obj(), 12000.0))))

    removePathIfExists(repoA)
    removePathIfExists(repoB)
    removePathIfExists(okA)
    removePathIfExists(okB)
    // ⚠️ `${base}-ok` 本身也要删：okA/okB 在它里面，只删子目录会留一个空壳。
    removePathIfExists(base + "-ok")
    removePathIfExists(deepgitPath(["store", pidA]))
    removePathIfExists(deepgitPath(["store", pidB]))
    removePathIfExists(deepgitPath(["store", pidOkA]))
    removePathIfExists(deepgitPath(["store", pidOkB]))
    exitTestHome()
    removePathIfExists(testHome)
    removePathIfExists(base)
}

@Test
func testJsonRpcBatchIsNotSilentlyDroppedAsNotification(): Unit {
    // JSON-RPC 2.0 允许顶层是一个数组（批量），服务端必须回**响应数组**。
    // 原来 mcpRun 把解析结果直接传进 mcpHandle，而 `Json.has(req, "id")`
    // 对数组恒为 false —— 整批被当成 notification 静默丢弃，一行输出都没有。
    //
    // 后果不是「少回几条」，而是客户端把这一行读走后仍在等那个数组响应，
    // 表现为挂起直到超时。把「我没处理」说成了「没这回事」。
    let initReq = Json.obj()
    Json.set(initReq, "jsonrpc", Json.of("2.0"))
    Json.set(initReq, "id", Json.of(1))
    Json.set(initReq, "method", Json.of("initialize"))
    Json.set(initReq, "params", Json.obj())
    let pingReq = Json.obj()
    Json.set(pingReq, "jsonrpc", Json.of("2.0"))
    Json.set(pingReq, "id", Json.of(2))
    Json.set(pingReq, "method", Json.of("ping"))
    // 混一条通知：规范要求通知不产生响应条目
    let noteReq = Json.obj()
    Json.set(noteReq, "jsonrpc", Json.of("2.0"))
    Json.set(noteReq, "method", Json.of("notifications/initialized"))

    let batch = JArr(ArrayList<JsonValue>([initReq, pingReq, noteReq]))
    // 前提：批量的顶层不是对象 —— 旧实现就是在这里被当成通知的
    @Assert(!Json.has(batch, "id"))

    // 显式判空而不是 getOrThrow：负控下（批量分支被删）这里会返回 None，
    // getOrThrow 抛异常，测试报 ERROR 而不是断言失败 —— 红灯是红了，
    // 但看不出「到底哪里不对」。断言失败比异常更能定位。
    let maybeResp = mcpHandle(batch)
    @Assert(maybeResp.isSome())          // 批量必须被处理，不能被当通知丢掉
    let resp = maybeResp.getOrThrow()
    // ⚠️ 顶层必须是**裸数组**，不是 {jsonrpc,id,result:[...]} 信封。
    // 规范规定批量请求回批量响应数组；包一层信封客户端就当非法响应丢掉。
    // （端到端发真批量才发现，单测只查了数组内 id 就放过了信封版本。）
    let arrOpt = Json.asArr(resp)
    @Assert(arrOpt.isSome())
    let arr = arrOpt.getOrThrow()
    // 三条里只有两条有 id，通知不进数组
    @Assert(arr.size == 2)
    // 顺序与 id 都要对得上，客户端靠 id 配对
    @Assert(Json.intAt(arr[0], "id", -1) == 1)
    @Assert(Json.intAt(arr[1], "id", -1) == 2)
    @Assert(Json.strAt(arr[0], "jsonrpc", "") == "2.0")
    @Assert(Json.strAt(arr[1], "jsonrpc", "") == "2.0")
    // ping 的 result 必须原样带出来，不能是空桩
    @Assert(Json.has(arr[1], "result"))
    @Assert(!Json.has(arr[1], "error"))

    // 全是通知 → 不输出任何东西（这与「整批被丢弃」是两回事，下面单独锁）
    @Assert(mcpHandle(JArr(ArrayList<JsonValue>([noteReq, noteReq]))).isNone())

    // 空数组是无效请求，不能也静默
    let maybeEmpty = mcpHandle(JArr(ArrayList<JsonValue>()))
    @Assert(maybeEmpty.isSome())         // 空数组也必须回错误，不能静默
    let emptyResp = maybeEmpty.getOrThrow()
    @Assert(Json.intAt(Json.getOr(emptyResp, "error"), "code", 0) == -32600)

    // 单条请求不受影响（batch 分支只是提前分流）
    @Assert(mcpHandle(initReq).isSome())
    @Assert(mcpHandle(noteReq).isNone())
}

@Test
func testMcpGetProjectContextUnknownProjectIsError(): Unit {
    // 项目不存在必须 isError:true。
    //
    // buildAgentContext 在找不到项目时 return 的是一段**字符串**
    // 「未找到项目：X」，而 get_project_context 原来直接 mcpOk 包装它 ——
    // isError:false，AI 收到一段像正文开头的文字 + 成功信号，
    // 只能靠字符串匹配才发现失败。
    //
    // CLI 早就修过同一个 bug（cmdContext 里用 requireProject 抛错，非 0 退出），
    // 姊妹工具 get_project_status / get_project_docs 也都调了 mcpRequireProject，
    // 只有这个漏了。
    let base = "/tmp/deepgit-mcpctxmissing-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let repo = base + "/repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic(repo + "/a.txt", "1")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], false)
    let (p, _) = addProject(repo, "mcp-ctx-ok", ArrayList<String>(), "")

    // 不存在的项目 → 必须报错
    let missing = Json.obj()
    Json.set(missing, "name", Json.of("__no_such_project__"))
    let badRes = mcpCallTool("get_project_context", missing)
    @Assert(mcpIsError(badRes))
    @Assert(mcpTextOf(badRes).contains("未找到项目"))

    // 对照：存在的项目必须照常返回上下文
    let okArgs = Json.obj()
    Json.set(okArgs, "name", Json.of("mcp-ctx-ok"))
    let okRes = mcpCallTool("get_project_context", okArgs)
    @Assert(!mcpIsError(okRes))
    @Assert(mcpTextOf(okRes).contains("mcp-ctx-ok"))
    // 不得出现「未找到项目」
    @Assert(!mcpTextOf(okRes).contains("未找到项目"))

    removePathIfExists(repo)
    removePathIfExists(deepgitPath(["store", p.id]))
    exitTestHome()
    removePathIfExists(testHome)
    removePathIfExists(base)
}

@Test
func testShallowUpdateKeepsResultsOfProjectsThatAlreadySucceeded(): Unit {
    // runUpdate 对失效路径是**抛异常**而不是返回 r.ok=false。
    // 原来 MCP 侧没有逐项目 try：
    //   项目 1 更新成功（进度库 / journal / 文档都已落盘，是真实副作用）
    //   项目 2 路径失效 → 抛异常 → 整个 mcpCallTool 被外层 catch
    //   → 已完成项目的那行报告被整个丢弃，剩下的也不再处理
    // 宿主收到的是一句「路径不存在」，据此会以为什么都没发生而重跑全部。
    //
    // 「已经写进去的东西」和「报出来的东西」对不上 = 事实性谎言。
    // HTTP 的 /api/update 早有这层保护，只有 MCP 漏了。
    let base = "/tmp/deepgit-mcpupd-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let good = base + "/good"
    let bad = base + "/bad"
    // 三个 ProjectEntry 必须在 try **外**声明，否则 finally 看不到。
    // 同理，清理必须绑在 finally 上：这条测试改的是进程级全局量
    // （DEEPGIT_HOME + 注册表）。断言一挂，后面的 setVariable/remove 就不执行了，
    // 全局量留在一个已被删掉的临时目录上，污染同进程后续所有测试。
    // 实测负控时它连带打红了 flow 包的 testRunDeepOnRealRepo ——
    // 那跟本改动毫无关系，红灯是被污染的假象，会让人去查一个根本不存在的 bug。
    var pg = ProjectEntry("", "", "", "git", "", "", ArrayList<String>(), false)
    var pb = ProjectEntry("", "", "", "git", "", "", ArrayList<String>(), false)
    var po = ProjectEntry("", "", "", "git", "", "", ArrayList<String>(), false)
    try {
        ensureDir(good)
        gitRun(good, ["init", "-b", "main"], false)
        writeFileAtomic(good + "/a.txt", "1")
        gitRun(good, ["add", "."], false)
        gitRun(good, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: one"], false)
        ensureDir(bad)
        gitRun(bad, ["init", "-b", "main"], false)
        writeFileAtomic(bad + "/a.txt", "1")
        gitRun(bad, ["add", "."], false)
        gitRun(bad, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: two"], false)
        let (g1, _) = addProject(good, "upd-good", ArrayList<String>(), "")
        let (b1, _) = addProject(bad, "upd-bad", ArrayList<String>(), "")
        pg = g1
        pb = b1
        // 前提：好项目确实可更新（否则「它报 ok」没有意义）
        @Assert(runUpdate(g1, Config.defaults(), shallowOpts()).ok)

        // 场景 A：1 好 1 坏。挪走坏项目目录 → 采集必然失败。
        removePathIfExists(bad)
        let res = mcpCallTool("run_shallow_update", allProjectsArgs())
        let text = mcpTextOf(res)
        // 核心断言：**两个项目都要出现在报告里**。
        // 旧实现在这里就丢掉了 upd-good 那行，只剩一句异常文本。
        @Assert(text.contains("upd-good"))
        @Assert(text.contains("upd-bad"))
        // 好的如实报成功，坏的如实报失败
        @Assert(text.contains("upd-good：ok"))
        @Assert(text.contains("upd-bad：失败"))
        // 部分失败 = 还有事实可用，不该报整体失败（同 groupExitCode 契约）
        @Assert(!mcpIsError(res))

        // 场景 B：两个都坏 → 必须 isError:true。
        // 逐行写着「失败」却回报成功，宿主不会提示用户。
        removePathIfExists(good)
        let allBad = mcpCallTool("run_shallow_update", allProjectsArgs())
        @Assert(mcpIsError(allBad))
        @Assert(mcpTextOf(allBad).contains("upd-good：失败"))
        @Assert(mcpTextOf(allBad).contains("upd-bad：失败"))

        // 场景 C（对照组）：项目健康时必须 isError:false 且报 ok。
        // 用**独立沙箱**而不是「把上面删掉的重建回来」——
        // 进程内删了再重建并不保证采集恢复（#115 那条测试已吃过一次亏，
        // 真实二进制复刻同样的时序却是正常的，说明红的是测试的状态切换）。
        let okDir = base + "-ok/repo"
        ensureDir(okDir)
        gitRun(okDir, ["init", "-b", "main"], false)
        writeFileAtomic(okDir + "/a.txt", "1")
        gitRun(okDir, ["add", "."], false)
        gitRun(okDir, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: three"], false)
        let (o1, _) = addProject(okDir, "upd-ok", ArrayList<String>(), "")
        po = o1
        let okArgs = Json.obj()
        Json.set(okArgs, "name", Json.of("upd-ok"))
        let okRes = mcpCallTool("run_shallow_update", okArgs)
        @Assert(!mcpIsError(okRes))
        @Assert(mcpTextOf(okRes).contains("upd-ok：ok"))
    } finally {
        removePathIfExists(good)
        removePathIfExists(bad)
        removePathIfExists(base + "-ok")
        removePathIfExists(deepgitPath(["store", pg.id]))
        removePathIfExists(deepgitPath(["store", pb.id]))
        removePathIfExists(deepgitPath(["store", po.id]))
        exitTestHome()
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

/// 「更新全部项目」的显式参数（#198：原来靠「不传 name」，是漏参数陷阱）
private func allProjectsArgs(): JsonValue {
    let o = Json.obj()
    Json.set(o, "name", Json.of(ALL_PROJECTS_SENTINEL))
    return o
}

private func shallowOpts(): UpdateOptions {
    let o = UpdateOptions()
    o.mode = "shallow"
    return o
}

@Test
func testMcpNumericArgsShareOneStrictContract(): Unit {
    // 同一个文件里两套数值契约，调用方无从判断该信哪个：
    //   get_group_context {budget: 1.5}  → isError:true   （严格）
    //   get_journal        {limit: 1.5}  → isError:false  （Json.intAt 静默截成 1）
    //   get_journal        {limit:"abc"} → isError:false  （静默取缺省 8）
    //   get_journal        {limit: 1e30} → isError:false  （且 Int64(n) 本该抛异常）
    //
    // 后果不是「数值不精确」，而是模型会以为自己只查了 1 条日志 ——
    // 而它传的根本不是 1。非整数是调用方写错了参数，必须报错而不是悄悄改。
    let base = "/tmp/deepgit-mcpnum-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let repo = base + "/repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic(repo + "/a.txt", "1")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: one"], false)
    let (p, _) = addProject(repo, "num-demo", ArrayList<String>(), "")

    func journalArgs(limit: JsonValue): JsonValue {
        let a = Json.obj()
        Json.set(a, "name", Json.of("num-demo"))
        Json.set(a, "limit", limit)
        return a
    }

    // 非整数 / 非数字 → 必须报错（两条工具同一套契约）
    @Assert(mcpIsError(mcpCallTool("get_journal", journalArgs(Json.of(1.5)))))
    @Assert(mcpIsError(mcpCallTool("get_journal", journalArgs(Json.of("abc")))))
    @Assert(mcpIsError(mcpCallTool("get_journal", journalArgs(Json.of(0)))))
    @Assert(mcpIsError(mcpCallTool("get_journal", journalArgs(Json.of(-3)))))
    // budget 侧保持原契约不变（防「修 journal 时把 budget 弄坏」）
    @Assert(mcpIsError(mcpCallTool("get_group_context", withBudget(Json.obj(), 1.5))))
    @Assert(mcpIsError(mcpCallTool("get_group_context", withBudget(Json.obj(), "abc"))))

    // 合法值必须照常工作（含「数字写成字符串」）
    @Assert(!mcpIsError(mcpCallTool("get_journal", journalArgs(Json.of(5)))))
    @Assert(!mcpIsError(mcpCallTool("get_journal", journalArgs(Json.of("5")))))
    // 越界不是错误：limit 越大只是「全要」，budget 按 clampAgentBudget 处理
    @Assert(!mcpIsError(mcpCallTool("get_journal", journalArgs(Json.of(1000000)))))
    @Assert(!mcpIsError(mcpCallTool("get_journal", journalArgs(Json.of(1e30)))))
    // 缺省仍然合法
    let noLimit = Json.obj()
    Json.set(noLimit, "name", Json.of("num-demo"))
    @Assert(!mcpIsError(mcpCallTool("get_journal", noLimit)))

    removePathIfExists(repo)
    removePathIfExists(deepgitPath(["store", p.id]))
    exitTestHome()
    removePathIfExists(testHome)
    removePathIfExists(base)
}

/// #189 回归：MCP `get_journal` 必须披露「窗口之外还有记录」。
///
/// 负控（曾真实发红，真实二进制复现）：12 条记录的条目 + 默认 limit=8，
/// 工具返回 8 行、**零披露** —— 模型据此认定「这个项目只更新过 8 次」，
/// 并可能据此判断项目不活跃。`badLines` 的披露本来就在，
/// 说明作者知道披露该在这儿，只是漏了「窗口」这一个事实。
///
/// 模型读的是**结尾结论**，所以披露必须是最后一行，不能混在记录里。
@Test
func testMcpGetJournalDisclosesWindowExhaustion(): Unit {
    let base = "/tmp/deepgit-mcpjwin-${nowMillis()}"
    let testHome = "${base}-home"
    let repo = "${base}/repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-q", "-b", "main"], false)
    writeFileAtomic("${repo}/a.py", "1\n")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "i"], false)
    enterTestHome(testHome)
    try {
        let (p, _) = addProject(repo, "jwin", ArrayList<String>(), "")
        // 写 12 条记录（12 > 默认 limit 8）
        let sb = StringBuilder()
        for (i in 0..12) {
            sb.append("{\"id\":\"j_${i}\",\"at\":\"2026-01-01T00:00:00+08:00\",")
            sb.append("\"mode\":\"shallow\",\"branch\":\"main\",\"summary\":\"第 ${i} 次\",")
            sb.append("\"commitCount\":1,\"commitCountScope\":\"new\",\"provider\":\"rules\"}\n")
        }
        writeFileAtomic(deepgitPath(["store", p.id, "journal.jsonl"]), sb.toString())

        // 默认 limit=8 → 窗口装不下 → 必须披露
        let r = mcpCallTool("get_journal", withName(Json.obj(), "jwin"))
        @Assert(!mcpIsError(r))
        let text = mcpTextOf(r)
        @Assert(text.contains("更早处还有记录"))
        @Assert(text.contains("不是全部"))
        // 披露必须是**最后一行**：模型读结尾结论
        let lastLine = text.split("\n")[text.split("\n").size - 1]
        @Assert(lastLine.contains("更早处还有记录"))

        // limit=20 → 装得下 → 不得过度披露（否则天天提醒，用户会学会无视它）
        var args20 = Json.obj()
        Json.set(args20, "name", Json.of("jwin"))
        Json.set(args20, "limit", Json.of(20))
        let t20 = mcpTextOf(mcpCallTool("get_journal", args20))
        @Assert(!t20.contains("更早处还有记录"))
        @Assert(t20.split("\n").size == 12)
    } finally {
        exitTestHome()
        removePathIfExists(base)
        removePathIfExists(testHome)
    }
}

/// 往 args 里塞一个 name。
private func withName(args: JsonValue, name: String): JsonValue {
    Json.set(args, "name", Json.of(name))
    return args
}

/// #198：`run_shallow_update` 缺 name / 空串**必须报错**，且一个项目都不许动。
///
/// 原缺陷：空 name 被解释成「更新全部项目」，而这是 15 个 MCP 工具里
/// **唯一**一个「参数缺失 = 批量写」的：
///     run_shallow_update {}  →  alpha：ok | beta：ok | gamma：ok   isError=false
/// 同族全部工具（run_deep_update / run_track / get_*）缺 name 都报「未找到项目：」，
/// 因为它们走 `mcpRequireProject`。
///
/// 为什么是缺陷不是特性：
///   · 它是**写**操作。漏一个参数 = 改写注册表里每一个项目的文档托管区域。
///     读操作漏参数只是少给点信息，写操作漏参数是改数据。
///   · 缺陷 #31 早就认定这件事危险（「空项目名在引擎侧等于整个项目群，
///     实测会改写所有项目的 README」），并把必填清单加在了**客户端** ——
///     客户端从 CLI `tools --json` 的 `params: "name"` 推出 required，
///     所以客户端侧一直安全。**引擎自己的 MCP 工具表没跟上**。
///   · 工具描述写的是「浅更新」，单数，与默认动作不符。
///
/// 批量能力没有删，改成**显式** `name = "*"`：漏参数与「我要全部」
/// 是两件完全不同的事，必须在参数里分得开。
@Test
func testMcpShallowUpdateRefusesMissingNameInsteadOfUpdatingEverything(): Unit {
    let base = "/tmp/deepgit-mcpnoname-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    var p1 = ProjectEntry("", "", "", "git", "", "", ArrayList<String>(), false)
    var p2 = ProjectEntry("", "", "", "git", "", "", ArrayList<String>(), false)
    try {
        for (n in ["noname-a", "noname-b"]) {
            let d = "${base}/${n}"
            ensureDir(d)
            gitRun(d, ["init", "-b", "main"], false)
            writeFileAtomic("${d}/a.txt", "1")
            gitRun(d, ["add", "."], false)
            gitRun(d, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: one"], false)
            let (e, _) = addProject(d, n, ArrayList<String>(), "")
            if (n == "noname-a") { p1 = e } else { p2 = e }
        }

        // ① 完全不传 name
        let noneRes = mcpCallTool("run_shallow_update", Json.obj())
        @Assert(mcpIsError(noneRes))
        @Assert(mcpTextOf(noneRes).contains("name"))
        // 报错文案必须教回怎么改，不能只说「需要 name」
        @Assert(mcpTextOf(noneRes).contains("*"))

        // ② 传空串 —— 与不传是同一个陷阱，必须同样挡住
        let emptyRes = mcpCallTool("run_shallow_update", withName(Json.obj(), ""))
        @Assert(mcpIsError(emptyRes))

        // ③ 全空白也要挡（`"   "` 绕得过 `isEmpty()`）
        let wsRes = mcpCallTool("run_shallow_update", withName(Json.obj(), "   "))
        @Assert(mcpIsError(wsRes))

        // 核心：**一个项目都不许被更新**。报错了还把数据改了 = 更糟。
        @Assert(readJournalWindow(p1.id, 50)[0].size == 0)
        @Assert(readJournalWindow(p2.id, 50)[0].size == 0)

        // ④ 显式传 "*" 仍然能做批量 —— 能力没丢，只是不再挂在「漏参数」上
        let allRes = mcpCallTool("run_shallow_update", allProjectsArgs())
        @Assert(!mcpIsError(allRes))
        let text = mcpTextOf(allRes)
        @Assert(text.contains("noname-a"))
        @Assert(text.contains("noname-b"))
        @Assert(readJournalWindow(p1.id, 50)[0].size > 0)
        @Assert(readJournalWindow(p2.id, 50)[0].size > 0)

        // ⑤ 单项目仍然正常
        let oneRes = mcpCallTool("run_shallow_update", withName(Json.obj(), "noname-a"))
        @Assert(!mcpIsError(oneRes))
        @Assert(mcpTextOf(oneRes).contains("noname-a"))
        @Assert(!mcpTextOf(oneRes).contains("noname-b"))
    } finally {
        removePathIfExists(deepgitPath(["store", p1.id]))
        removePathIfExists(deepgitPath(["store", p2.id]))
        exitTestHome()
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

/// #198 的 schema 侧：name 必须在 `required` 里，且描述要说明 `*` 的含义。
///
/// schema 是给模型看的**提示**，处理器是**闸门**，两道都要有 ——
/// 模型仍然可能传 `""`，但至少它知道 name 是必填的。
@Test
func testMcpShallowUpdateSchemaMarksNameRequired(): Unit {
    let listing = mcpToolList()
    var found = false
    for (t in Json.arrAt(listing, "tools")) {
        if (Json.strAt(t, "name", "") != "run_shallow_update") {
            continue
        }
        found = true
        let schema = Json.getOr(t, "inputSchema")
        let required = Json.strArrAt(schema, "required")
        @Assert(required.contains("name"))
        // 描述里必须出现 `*`，否则模型无从知道怎么表达「全部」
        @Assert(Json.strAt(t, "description", "").contains("*"))
        let props = Json.getOr(schema, "properties")
        @Assert(Json.strAt(Json.getOr(props, "name"), "description", "").contains("*"))
    }
    @Assert(found)
}

/// #198：`addProject` 不得收下**空名**项目。
///
/// 实测 `moongit add /` 与 MCP `add_project {"path": ""}` 都能注册出
/// `name=""`、`path="/"` 的条目，后果不是「多一行」：
///   ① 那条项目**永远引用不到** —— `findProjectIn` 对空 ref 直接返回 None，
///      连 `remove` 都删不掉它；
///   ② 它**永久污染每一次聚合命令**：实测之后
///        moongit status --json → summary.failedProjects = 1
///      而那条项目的 error 是「Native function error.」—— 用户看不懂、
///      也查不出是哪来的。
@Test
func testAddProjectRefusesToRegisterAnUnnameableProject(): Unit {
    let base = "/tmp/deepgit-noname-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    try {
        // 文件系统根：basename 为空 ⇒ 算不出名字
        var threw = false
        var msg = ""
        try {
            let _ = addProject("/", "", ArrayList<String>(), "")
        } catch (e: DgError) {
            threw = true
            msg = e.message
        }
        @Assert(threw)
        // 报错必须教回怎么改
        @Assert(msg.contains("--name"))
        // 且注册表里必须**一条都没多**
        @Assert(loadRegistry().projects.size == 0)

        // 显式给了名字就允许（用户明确要的，不拦）
        ensureDir(base)
        let (e, added) = addProject(base, "显式命名", ArrayList<String>(), "")
        @Assert(added)
        @Assert(e.name == "显式命名")

        // 正常路径不受影响
        let normal = base + "/normal"
        ensureDir(normal)
        let (n, okN) = addProject(normal, "", ArrayList<String>(), "")
        @Assert(okN)
        @Assert(n.name == "normal")
    } finally {
        exitTestHome()
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

// ------------------------------ #204：MCP schema 必须与处理器一致 ------------------------------

/// 抽出一个函数体里所有 `mcpTool("NAME", …, mcpSchemaObject([...], [required]))` 的
/// (name, required)。剥注释后再做 —— 解释这个缺陷的注释里必然出现工具名与
/// `required=` 字样，不剥就会把自己算进去。
private func mcpSchemaRows(): ArrayList<(String, ArrayList<String>)> {
    let raw = readFileTextChecked("src/cli/mcp.cj").getOrThrow()
    let sb = StringBuilder()
    var blk = false
    for (r in raw.split("\n")) {
        let (l, nb) = stripCjComment(r, blk)
        blk = nb
        sb.append(l)
        sb.append("\n")
    }
    let code = sb.toString()
    let out = ArrayList<(String, ArrayList<String>)>()
    for (line in code.split("\n")) {
        let t = line.trimAscii()
        if (!t.contains("arr.add(mcpTool(\"")) {
            continue
        }
        // 工具名：mcpTool(" 之后的第一个引号段
        let a = t.indexOf("mcpTool(\"")
        if (a.isNone()) {
            continue
        }
        // ⚠️ 偏移量必须是字面量长度 9（`mcpTool("`）。
        // 第一版写成 10，把工具名的首字符截掉了（run_deep_update → un_deep_update），
        // 于是按名字找处理器全部落空，`checked` 停在 0 ——
        // lint 红了，但红的是 `checked >= 3` 而不是它声称的 `required` 判据。
        // **判据本身错了，结论就是反的**（同 NC52-d 的教训）。
        let tail = t[(a.getOrThrow() + 9)..]
        match (tail.indexOf("\"")) {
            case None => ()
            case Some(i) =>
                let name = tail[0..i]
                // required：`mcpSchemaObject([...], [ ... ])` 的**第二个**方括号
                let mo = t.indexOf("mcpSchemaObject(")
                if (mo.isNone()) {
                    continue
                }
                let after = t[(mo.getOrThrow() + 16)..]
                let firstClose = after.indexOf("]")
                if (firstClose.isNone()) {
                    continue
                }
                let second = after[(firstClose.getOrThrow() + 1)..]
                let secondOpen = second.indexOf("[")
                let secondClose = second.indexOf("]")
                if (secondOpen.isNone() || secondClose.isNone()) {
                    continue
                }
                let reqSeg = second[secondOpen.getOrThrow() + 1..secondClose.getOrThrow()]
                let req = ArrayList<String>()
                var at = 0
                while (true) {
                    let q = reqSeg.indexOf("\"", at)
                    match (q) {
                        case None => break
                        case Some(i) =>
                            match (reqSeg.indexOf("\"", i + 1)) {
                                case None => break
                                case Some(j) =>
                                    req.add(reqSeg[(i + 1)..j])
                                    at = j + 1
                            }
                    }
                }
                out.add((name, req))
        }
    }
    return out
}

/// 一个工具的处理器片段（含缩进的那几行）。取到下一个 `case "` 为止。
private func mcpHandlerBody(code: String, tool: String): String {
    let needle = "case \"" + tool + "\" =>"
    let k = code.indexOf(needle)
    if (k.isNone()) {
        return ""
    }
    let seg = code[k.getOrThrow()..]
    // ⚠️ 终止条件必须是**下一个同缩进的 case**，带不带引号都要拦。
    // 第一版只认 `case "`，于是最后一个工具（add_project）后面那条无引号的
    // `case _ =>` 没拦住，片段一路吞到文件末尾 ——
    // 而文件末尾正好有本 lint 自己的 needle 字面量，于是 `add_project` 被误判成
    // 「处理器要 name」。这是本会话第三次自匹配（needle 字面量 / lint 扫自己 /
    // 片段越界），三次都是「判据把自己算进结果集」。
    let nxt = seg.indexOf("\n            case ")
    if (nxt.isSome()) {
        return seg[0..nxt.getOrThrow()]
    }
    return seg
}

/// **处理器要求 `name` 的工具，schema 的 `required` 里必须有 `name`。**
///
/// 缺陷 #204：`run_deep_update` 的处理器是 `mcpRequireProject(getStr("name"))`
/// —— 与 `run_shallow_update` / `run_track` **完全同构**，三者都必须要 name。
/// 但 #198 只把后两个的 `required` 补成了 `["name"]`，`run_deep_update` 留在 `[]`。
/// 于是 schema 告诉模型「name 可选」，模型就照着调 `run_deep_update {}`，
/// 处理器回一句「未找到项目：」—— 模型拿到的是失败，不是它要的东西。
///
/// schema 是给模型看的提示（不变量 49），提示写错和处理器写错一样是缺陷：
/// 一个把参数标成可选的写工具，模型会放心地不传。
///
/// 这条 lint 的价值不在这一处，而在**它把「schema 与处理器一致」变成结构保证**：
/// 三个同族工具、三处手写 `required`，已经漂了一处；
/// 写成断言之后，第 N 个同族工具忘了补就红，而不是等模型踩到。
@Test
func __lintMcpSchemaRequiredMatchesHandler(): Unit {
    let raw = readFileTextChecked("src/cli/mcp.cj").getOrThrow()
    let sb = StringBuilder()
    var blk = false
    for (r in raw.split("\n")) {
        let (l, nb) = stripCjComment(r, blk)
        blk = nb
        sb.append(l)
        sb.append("\n")
    }
    let code = sb.toString()
    let rows = mcpSchemaRows()
    // 工具表不能是空的（解析器失效时要立刻红，而不是静默通过）
    @Assert(rows.size >= 10)

    let needName = ArrayList<String>()
    for ((name, req) in rows) {
        let body = mcpHandlerBody(code, name)
        // ⚠️ needle 拼接：源码里不能出现完整 needle，否则匹配到自己。
        let needs = "mcpRequire" + "Project("
        if (!body.contains(needs)) {
            continue
        }
        needName.add(name)
        // 处理器强制要 name → schema 必须声明它必填
        if (!req.contains("name")) {
            @Assert(false)
        }
    }
    // 三个同族的 run_* 必须都在被检查集合里 —— 少一个说明解析器或表退化了，
    // 而那会让上面那个循环**一条都不跑**、整条 lint 空转成绿。
    for (r in ["run_shallow_update", "run_deep_update", "run_track"]) {
        @Assert(needName.contains(r))
    }
    // 解析器失效时要立刻红，而不是静默通过
    @Assert(needName.size >= 8)
    // 片段提取的**终止条件**必须真的在无引号的 `case _ =>` 处停住。
    // 一个 handler 分支体内**永远不可能**出现 `@Test`；
    // 一旦越界吞到文件末尾（本文件后面全是测试），这个断言立刻红。
    // ⚠️ 越界曾经是**现实**错误而不是潜在错误：needle 还是字面量时，
    // 越界会让 add_project 的片段匹配到 lint 自己的 needle 而误报。
    // needle 改成拼接之后它变成潜在隐患 —— 但潜在隐患迟早会被下一次文件增长唤醒，
    // 所以这条断言必须留着。
    let lastBody = mcpHandlerBody(code, "add_project")
    @Assert(!lastBody.isEmpty())
    @Assert(!lastBody.contains("@Test"))
}

/// 三个同族写工具的 `required` 必须一致，且都必须是 `["name"]`。
///
/// 单独写一条是因为「同构工具的 schema 要同构」这个断言比通用 lint 更直白：
/// 新增第四个 `run_*` 工具的人，一眼能看到这一行在要求他填 `name`。
@Test
func testSiblingWriteToolsAllRequireName(): Unit {
    // ⚠️ 必须写 `let want = ArrayList<String>()` 而不是 `var want: ArrayList<String>()`：
    // 仓颉会把后者解析成「类型声明 + 多出来的 ()」，
    // 报 expected ';' or '<NL>', found '('。本文件既有写法一律用 let。
    let want = ArrayList<String>()
    for ((name, req) in mcpSchemaRows()) {
        if (name == "run_shallow_update" || name == "run_deep_update" || name == "run_track") {
            want.add(name)
            @Assert(req.size == 1)
            @Assert(req[0] == "name")
        }
    }
    @Assert(want.size == 3)
}
