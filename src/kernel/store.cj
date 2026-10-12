// 存储层：全局 store（~/.deepgit/store/<id>/）与单项目状态/进度读写。
//
// 设计取舍：进度状态存全局 store 而非项目内 —— 使状态天然跨分支安全，
// 不会污染任何工作区，也不产生「记录进度」的提交噪音。项目内只写生成文档。
package moongit.kernel

import std.collection.*
import std.env.*
import std.fs.*
import moongit.util.*
import std.unittest.*
import std.unittest.testmacro.*

public class StorePaths {
    public let dir: String
    public let state: String
    public let progress: String
    public let journalJsonl: String
    public let journalMd: String
    public let runs: String
    public let backups: String
    public let locks: String
    public let hooks: String

    public init(projectId: String) {
        this.dir = deepgitPath(["store", projectId])
        this.state = this.dir + "/state.json"
        this.progress = this.dir + "/progress.json"
        this.journalJsonl = this.dir + "/journal.jsonl"
        this.journalMd = this.dir + "/journal.md"
        this.runs = this.dir + "/runs"
        this.backups = this.dir + "/backups"
        this.locks = this.dir + "/locks"
        this.hooks = this.dir + "/hooks"
    }
}

public func ensureStore(projectId: String): StorePaths {
    let p = StorePaths(projectId)
    ensureDir(p.dir)
    ensureDir(p.runs)
    ensureDir(p.backups)
    ensureDir(p.locks)
    ensureDir(p.hooks)
    return p
}

/// 读取 JSON 存储文件，并区分「文件不存在」与「文件已损坏」：
///
/// - 文件不存在 → 返回空对象（首次运行的正常路径）
/// - 文件存在但解析失败 → 先把原文件另存为 `<path>.corrupt-<时间戳>`，再报错并返回空对象
///
/// 旧实现在解析失败时直接返回空对象，于是任何一次 add / scan / update 都会用只含
/// 少量新数据的文件**覆盖掉损坏的 registry/state/progress/milestones**，
/// 原内容既没保留也没提示 —— 数据永久丢失。这里保留副本，保证损坏内容始终可找回。
public func readStoreJson(path: String): JsonValue {
    let (j, _) = readStoreJsonChecked(path)
    return j
}

/// 读取 JSON 存储文件，并如实报告「读到的是不是一份可信的数据」。
///
/// 第二个返回值 `corrupted` 是给**写路径**用的信号：
/// 旧实现在解析失败时返回空对象，而调用方分不清「文件本来是空的」和
/// 「文件坏了、我们什么也没读到」。于是 milestone add / registry add
/// 拿着这个空对象做读-改-写，把损坏文件覆盖成近乎空的文件 ——
/// 实测 50 条里程碑变 1 条、命令 exit 0 谎报成功。
/// 副本还在盘上，但用户不会去翻一个 .corrupt 文件。
///
/// 读路径继续用 readStoreJson（宽松，只告警）；写路径必须用本函数并在
/// `corrupted` 为真时拒绝写入。
/// 存储文件的健康状态。
///
/// 三态而不是 Bool：「读不出来」和「解析失败」必须分开 ——
/// 旧实现用 readFileText，它把「存在但读不出来」（权限、瞬时 I/O 错误）和
/// 「文件不存在」都表达成 None，case None 于是回报「未损坏」，
/// 写闸门直接放行，随后用只含新项目的内容整体覆盖原文件。
/// 实测 `chmod 000 registry.json` 后 add 一个项目：注册表 2 项变 1 项、exit 0、
/// 连 .corrupt 副本都没留；milestones 同样从 5 条变 1 条。
/// 而 writeFileAtomic 走 rename，只需要目录写权限 —— 覆盖一个读不了的文件照样成功，
/// 所以「读失败」这一种情况在写入侧完全没有防线。
public enum StoreHealth {
    | Ok
    /// 文件在，但内容不是合法 JSON。已留 .corrupt 副本。
    | Corrupt
    /// 文件在，但读不出来（权限 / I/O）。原文件未被动过，副本也读不出来所以留不了。
    | Unreadable(String)
}

/// 存储健康是否允许写入。只有 Ok 允许。
public func storeWritable(health: StoreHealth): Bool {
    match (health) {
        case Ok => return true
        case _ => return false
    }
}

public func readStoreJsonChecked(path: String): (JsonValue, StoreHealth) {
    // 真的不存在 = 正常的空存储，不是损坏。
    if (!exists(Path(path))) {
        return (Json.obj(), StoreHealth.Ok)
    }
    // 必须用 readFileTextChecked（读失败时抛异常），不能用 readFileText（读失败返回 None，
    // 与「文件不存在」同构）—— 那正是本缺陷的根因。
    let text = try {
        match (readFileTextChecked(path)) {
            case Some(t) => t
            case None => return (Json.obj(), StoreHealth.Unreadable("文件在读取前消失"))
        }
    } catch (e: Exception) {
        Log.error("存储文件读不出来，写入已拒绝：${path}\n  ${e.message}")
        return (Json.obj(), StoreHealth.Unreadable(e.message))
    }
    match (Json.parse(text)) {
        case Some(j) => return (j, StoreHealth.Ok)
        case None =>
            quarantineCorruptStore(path, text)
            return (Json.obj(), StoreHealth.Corrupt)
    }
}

/// 把损坏的存储文件复制一份保全副本。复制本身失败也不能抛错阻断读取 ——
/// 原文件此刻还在盘上，危险只发生在后续写操作覆盖它的时候。
private func quarantineCorruptStore(path: String, text: String): Unit {
    // 副本名用**内容哈希**而不是时间戳。
    //
    // 旧实现用时间戳 + 递增后缀保证唯一，而原文件是「复制」不是「移走」，
    // 于是文件一直坏着、每次读都重新判定损坏、每次都造一个新副本 ——
    // 副本数只增不减，永不收敛。实测一次 `milestone list` 生成 52 个 .corrupt
    // 文件、836K，而 post-commit 钩子每次提交都会触发一遍；
    // 那条「已保留副本」告警还会重复刷 50 次，把真实告警淹掉。
    //
    // 用内容哈希命名后：同一份损坏内容 → 同一个副本名 → 已存在就跳过，
    // 读写多少次都只有一份；内容真的变了（新的损坏）才会产生新副本。
    // 这是收敛的判据，不是一个更花哨的时间戳。
    let digest = sha256HexOf(text)
    let tag = digest[..12]
    let backup = "${path}.corrupt-${tag}"
    if (fileExists(backup)) {
        Log.debug("损坏副本已存在，跳过重复保全：${backup}")
        return
    }
    try {
        let dir = dirname(path)
        if (!dir.isEmpty()) {
            ensureDir(dir)
        }
        copy(Path(path), to: Path(backup), overwrite: true)
        Log.error("存储文件无法解析，已保留副本：${backup}")
        Log.error("请先检查/恢复该副本；在此之前的写操作会按空数据继续")
    } catch (e: Exception) {
        Log.error("存储文件无法解析，且保留副本失败：${path}（${e.message}）")
    }
}

public func readState(projectId: String): JsonValue {
    return readStoreJson(StorePaths(projectId).state)
}

public func writeState(projectId: String, state: JsonValue): Unit {
    let p = StorePaths(projectId)
    Json.set(state, "updatedAt", Json.of(nowIso()))
    writeFileAtomic(p.state, Json.pretty(state))
}

public func readProgress(projectId: String): JsonValue {
    return readStoreJson(StorePaths(projectId).progress)
}

/// 进度 JSON 中的分支记录表（不可变视图副本）
public func progressBranches(progress: JsonValue): ArrayList<(String, JsonValue)> {
    let out = ArrayList<(String, JsonValue)>()
    let branches = Json.getOr(progress, "branches")
    match (Json.asObj(branches)) {
        case Some(m) =>
            for ((k, v) in m) {
                out.add((k, v))
            }
        case None => ()
    }
    return out
}

public func progressBranch(progress: JsonValue, branch: String): Option<JsonValue> {
    let branches = Json.getOr(progress, "branches")
    match (Json.get(branches, branch)) {
        case Some(v) => return Some(v)
        case None => return None
    }
}

/// 更新/创建分支记录，返回更新后的记录
public func setProgressBranch(progress: JsonValue, branch: String, patch: JsonValue): JsonValue {
    var branches = Json.getOr(progress, "branches")
    if (Json.asObj(branches).isNone()) {
        branches = Json.obj()
    }
    let existing = Json.getOr(branches, branch)
    let merged = Json.obj()
    // 保留旧字段
    match (Json.asObj(existing)) {
        case Some(m) =>
            for ((k, v) in m) {
                Json.set(merged, k, v)
            }
        case None => ()
    }
    match (Json.asObj(patch)) {
        case Some(m) =>
            for ((k, v) in m) {
                Json.set(merged, k, v)
            }
        case None => ()
    }
    // 首次记录时间
    if (!Json.has(merged, "firstTrackedAt")) {
        Json.set(merged, "firstTrackedAt", Json.of(nowIso()))
    }
    Json.set(merged, "updatedAt", Json.of(nowIso()))
    Json.set(branches, branch, merged)
    Json.set(progress, "branches", branches)
    return merged
}

/// progress.json 里保留的条目上限。
///
/// 完整历史在 journal.jsonl（只追加，从不截断）。这里只限制 progress.json 的体积。
private const MAX_PROGRESS_ENTRIES: Int64 = 200

public func writeProgress(projectId: String, progress: JsonValue): Unit {
    let p = StorePaths(projectId)
    Json.set(progress, "version", Json.of(1))
    Json.set(progress, "updatedAt", Json.of(nowIso()))
    // entries 截断，完整历史留在 journal.jsonl
    let entries = Json.arrAt(progress, "entries")

    // ⚠️ 截断必须**同时记账**，否则「上限」会被当成「全量」上报。
    //
    // 旧实现只留最后 200 条、什么都不说，于是 status 的 entryCount 直接数这个数组：
    // 跑过 251 次的项目报「entryCount: 200」——
    //   progress.json 的 entries : 200（被截断）
    //   journal.jsonl 实际行数    : 251
    //   status 报的 entryCount    : 200     ← 没有任何截断提示
    // 而同一份 JSON 里还有个从不截断的 runCount，真跑到 200 次以上时
    // 两个数会直接打架（entryCount=200 / runCount=251）。
    //
    // 「上限当全量」这一族已经栽到第 8 次（commitActivity 400 / commitTypes 15 /
    // lsFiles 20000 / 语言 Top12 / scan 20000 目录 / dashboard languages /
    // update 基线 30 / entryCount 200）。修法始终一致：标志位与数据成对传出去。
    //
    // 真实总数靠「上次总数 + 本次新增」滚动得出，而不是靠数组长度 ——
    // 数组一旦被截断，长度就永远只是 200。
    let prevKept = Json.intAt(progress, "entriesKept", entries.size)
    let prevTotal = Json.intAt(progress, "entriesTotal", entries.size)
    var added = entries.size - prevKept
    if (added < 0) {
        // progress 被外部改过导致计数倒退：宁可少报也不报出负数
        added = 0
    }
    let total = prevTotal + added
    let kept = if (entries.size > MAX_PROGRESS_ENTRIES) { MAX_PROGRESS_ENTRIES } else { entries.size }
    Json.set(progress, "entriesTotal", Json.of(total))
    Json.set(progress, "entriesKept", Json.of(kept))
    if (entries.size > MAX_PROGRESS_ENTRIES) {
        let newKept = ArrayList<JsonValue>()
        for (i in (entries.size - MAX_PROGRESS_ENTRIES)..entries.size) {
            newKept.add(entries[i])
        }
        Json.set(progress, "entries", JArr(newKept))
    }
    writeFileAtomic(p.progress, Json.pretty(progress))
}

/// journal.md 镜像保留的条数。
public const JOURNAL_MD_KEEP: Int64 = 100

/// 追加一行 JSONL（并重写人类可读 journal.md）
public func appendJournal(projectId: String, entry: JsonValue, projectName: String): Unit {
    let p = StorePaths(projectId)
    ensureDir(p.dir)
    appendLine(p.journalJsonl, Json.compact(entry))
    // 重建 markdown（保留最近 JOURNAL_MD_KEEP 条）
    //
    // ⚠️ 截断必须**写进文件本身**。JSONL 还能用 `--limit` 往前翻，
    // 而 journal.md 是给人看的镜像：打开它的人只会看到 100 条，
    // 没有任何迹象说明后面还有，于是把「最近 100 条」当成「全部历史」——
    // 然后据此下结论说「这个项目只做过这些事」。
    // 「上限当全量」这一族的第 13 处。
    //
    // 多取 1 条只为判断是否被截断，**不必解析整个文件**。
    // 刻意不在这里报精确总数：为此得整文件扫一遍换行，
    // 而 appendJournal 跑在 post-commit 钩子里（每次提交同步执行），
    // 拿 50k 条项目的 0.5s 去换一个用不上的数字不划算。
    // 「仅显示最近 100 条」本身就是完整且诚实的口径。
    let probe = readJournal(projectId, JOURNAL_MD_KEEP + 1)
    let truncated = probe.size > JOURNAL_MD_KEEP
    let keep = if (truncated) { JOURNAL_MD_KEEP } else { probe.size }
    let sb = StringBuilder()
    sb.append("# moonGit 进度日志")
    if (!projectName.isEmpty()) {
        sb.append(" — ${projectName}")
    }
    sb.append("\n\n> 由 moonGit 自动维护，最新条目在最上方。")
    if (truncated) {
        sb.append("**本文件仅显示最近 ${JOURNAL_MD_KEEP} 条**，不是全部历史；")
        sb.append("更早的记录在同目录的 journal.jsonl 里，用 `moongit journal <项目> --limit N` 查看。")
    }
    sb.append("\n\n")
    for (i in 0..keep) {
        if (i > 0) {
            sb.append("\n---\n\n")
        }
        sb.append(renderJournalEntry(probe[i]))
    }
    writeFileAtomic(p.journalMd, tidyMarkdown(sb.toString()))
}

/// 读取 JSONL（最新在前的顺序返回）
///
/// limit <= 0 表示不要任何条目。旧实现直接把 limit 代入 `collected.size - limit`，
/// 负数会让 start 跑到数组末尾之外，while 循环一次都不执行 —— 结果确实是空列表，
/// 但走的是「算错了才碰巧对」的路径，且调用方分不清「limit 非法」与「真的没有记录」。
/// 调用方（cmdJournal / /api/journal / mcp get_journal）应在边界上拒绝非正数。
public func readJournal(projectId: String, limit: Int64): ArrayList<JsonValue> {
    return readJournalWithStats(projectId, limit)[0]
}

/// 读取 journal，同时报告被丢弃的坏行数。
///
/// 坏行以前是完全静默的：进程在 append 写到一半被杀会留下半截 JSONL，
/// readJournal 遇到解析失败只有空分支，那条进度记录就此消失，
/// 而用户看到的是「（暂无记录）」—— 与「这个项目真的没有记录」无法区分。
/// 崩溃残留和手工编辑损坏都属于这种情况，丢掉可以，但必须说出来。
public func readJournalWithStats(projectId: String, limit: Int64): (ArrayList<JsonValue>, Int64) {
    let (entries, bad, _) = readJournalWindow(projectId, limit)
    return (entries, bad)
}

/// 读取 journal，同时报告坏行数与「窗口之外还有没有记录」。
///
/// 第三个返回值是承重的（缺陷 #189）。原来的循环填满 `limit` 就停，
/// **根本不知道窗口外还有没有** —— 于是：
///   · MCP `get_journal` 完全没有披露，模型把 8 条窗口当成全量
///     （实测 12 条记录的条目，工具返回 8 行且零提示）
///   · `journal --json` 的 `branchWindowExhausted` 只装**分支级**耗尽，
///     无分支过滤时恒为 `{}`，于是 `--limit 3` + 12 条记录同样不披露
/// 只有 `limit` 这个数字是不足以自证的：3-of-3 与 3-of-12 完全同形。
public func readJournalWindow(projectId: String, limit: Int64): (ArrayList<JsonValue>, Int64, Bool) {
    let p = StorePaths(projectId)
    let out = ArrayList<JsonValue>()
    var bad = 0
    // 声明在 match 之外：`more` 要在函数末尾的 return 里用。
    var more = false
    if (limit <= 0) {
        return (out, 0, false)
    }
    match (readFileText(p.journalJsonl)) {
        case Some(text) =>
            let lines = text.split("\n")
            // ⚠️ 必须**倒序扫描、只解析最后 limit 条**，不能全量解析。
            //
            // 旧实现先把每一行都 Json.parse 一遍，再取最后 limit 条 ——
            // 复杂度与文件总行数成正比，于是每跑一次 update 都要重解析整个历史：
            //   journal 1 条        → update 0.21s
            //   journal 10000 条    → update 0.44s
            //   journal 50000 条    → update 1.75s   ← 16.7MB
            //   journal 50000 条    → 本实现 0.71s
            // 而 post-commit 钩子是**每次提交后同步跑**的，所以一个跟踪了一年
            // 的老项目每次 commit 都要多等一秒多，且没有任何提示。
            //
            // 剩下的 0.5s 花在 text.split("\n") 物化全部子串上。
            // 试过改用 String.lastIndexOf(byte, fromIndex) 在原始字符串上倒着找换行
            // 来跳过 split，**实测挂死**：该重载的文档只说「从 fromIndex 索引开始搜索，
            // 返回最后一次出现的索引」，没说搜索区间是 [0, len) 还是 [fromIndex, len)；
            // 实测行为下 end 不再递减，形成死循环。
            // 在 17MB 的热路径上赌一个有歧义的 API 语义不值得 —— 保留这个 2.5 倍的
            // 确定性收益，剩下的 split 成本记在这里，谁有确凿语义证据再优化。
            //
            // 坏行计数用「首个非空白字节不是 {」（合法 JSONL 行必然以 { 开头），
            // 这是 O(1) 字符检查，不必付出完整解析的代价。
            var i = lines.size - 1
            while (i >= 0 && out.size < limit) {
                let t = lines[i].trimAscii()
                if (!t.isEmpty()) {
                    if (t[0] == 0x7Bu8) {   // '{'
                        match (Json.parse(t)) {
                            case Some(j) => out.add(j)
                            case None => bad += 1
                        }
                    } else {
                        bad += 1
                    }
                }
                i -= 1
            }
            // 收集顺序天然是「最新在前」
            // 窗口之外还有没有记录？只回答「有/没有」就够了，
            // 但**必须有答案**。这里只做 O(1) 的字节检查（合法 JSONL 行以 { 开头），
            // 不做完整解析 —— 所以不会把上面那条热路径的性能优化退回去。
            // 找到第一个候选就停，常见情况下额外代价接近 0。
            var k = i
            while (k >= 0) {
                let t = lines[k].trimAscii()
                if (!t.isEmpty() && t[0] == 0x7bu8) {
                    more = true
                    break
                }
                k -= 1
            }
        case None => ()
    }
    return (out, bad, more)
}

/// 按分支读取 journal。**过滤发生在窗口之内**，不是取完再过滤。
///
/// ⚠️ 调用点原来都是「先 readJournalWithStats(limit) 再按 branch 过滤」：
///   CLI  更糟，还先把窗口放大成 limit*4
///   HTTP 连放大都没有，窗口就是 limit
/// 于是「记录存在但落在窗口之外」与「这个分支没有记录」完全同构：
///   gamma 有 1 条 feat/x + 90 条 main，feat/x 在最旧
///   moongit journal gamma --branch feat/x --limit 20  → 「（暂无记录）」
///   moongit journal gamma --branch feat/x --limit 200 → 记录就在那里
/// 后果不是「少显示几条」，而是**谎报该分支没有历史**。
///
/// 第三个返回值 `windowExhausted`：窗口用完仍未凑够 limit 条匹配记录时为真。
/// 调用方据此说明「窗口内没有，可能在更早处」，而不是说「没有」。
/// 不披露这一点，过滤版就换了个地方重犯「上限当全量」。
///
/// branch 为空时等价于 readJournalWithStats（不按分支筛）。
public func readJournalForBranch(projectId: String, branch: String, limit: Int64): (ArrayList<JsonValue>, Int64, Bool) {
    if (branch.isEmpty()) {
        // ⚠️ 这里原来硬编码 `false`（#189）：无过滤读取**一样会**把窗口填满。
        // 恒 false 等于对所有不过滤的 journal 调用谎报「没有更早的记录」。
        let (entries, bad, exhausted) = readJournalWindow(projectId, limit)
        return (entries, bad, exhausted)
    }
    let p = StorePaths(projectId)
    let out = ArrayList<JsonValue>()
    var bad: Int64 = 0
    if (limit <= 0) {
        return (out, 0, false)
    }
    // 倒序扫到底，直到凑够 limit 条**匹配**记录为止 —— 窗口因此只覆盖
    // 「最后若干条匹配记录」，而不是「最后 limit 条里的匹配记录」。
    match (readFileText(p.journalJsonl)) {
        case Some(text) =>
            let lines = text.split("\n")
            var i = lines.size - 1
            while (i >= 0 && out.size < limit) {
                let t = lines[i].trimAscii()
                if (!t.isEmpty()) {
                    if (t[0] == 0x7Bu8) {
                        match (Json.parse(t)) {
                            case Some(j) =>
                                if (Json.strAt(j, "branch", "") == branch) {
                                    out.add(j)
                                }
                            case None => bad += 1
                        }
                    } else {
                        bad += 1
                    }
                }
                i -= 1
            }
            // 扫到文件头还没凑够 → 文件里总共就没那么多条匹配记录，
            // 这时「没凑够」不是窗口问题，不该让调用方去提示调大 limit。
            return (out, bad, i >= 0)
        case None => ()
    }
    return (out, bad, false)
}

/// journal 窗口披露的文案。**三个出口（CLI 文本 / CLI stderr / HTTP note）共用这一份**。
///
/// 抽成纯函数是因为它一旦内联在路由和 CLI 的 if 里，改错了不会有任何测试变红 ——
/// 而这正是它第一次就写错的形态：
///   1. 只接到「筛完为空」那一路。于是 `journal gamma --branch main --limit 3`
///      （实际有 30 条）打出 3 条就收工，看上去和「这个分支一共就 3 条」一模一样。
///      「上限当全量」这一族已经栽到第 12 次，只接一半等于把谎报从
///      「说没有」换成「说只有这些」。
///   2. 两种情况共用同一句「没有分支 X 的条目」。于是**有结果时是反向谎报**：
///      明明返回了 3 条，却说一条都没有。
///
/// flag 让调用方决定怎么称呼这个参数：CLI 是 `--limit`，HTTP 是 `limit`。
/// 返回空串表示「不需要披露」——此时调用方**必须**什么都不写，
/// 因为对文件里总共就那么多的情况说「请调大 limit」是给用户的假建议。
public func journalWindowNoteText(branch: String, limit: Int64, matched: Int64,
                                  windowExhausted: Bool, flag: String): String {
    // branch 为空时 readJournalForBranch 直接退化为无过滤读取，恒不耗尽；
    // 这里仍然显式挡一道，因为「窗口耗尽」一旦被误传，提示会毫无意义。
    if (branch.isEmpty() || !windowExhausted) {
        return ""
    }
    if (matched == 0) {
        return "最近 ${limit} 条进度记录里没有分支 ${branch} 的条目；更早的记录可能存在，请调大 ${flag}"
    }
    return "已按分支 ${branch} 截断到最近 ${limit} 条；更早处还有该分支的记录，请调大 ${flag} 查看全量"
}

/// 被跳过的坏行的披露文案。同样收敛成一份：HTTP 与 CLI 各写一遍时
/// 措辞已经开始漂移（一个带「通常是进程被强杀留下的半截行」一个不带）。
public func journalBadLineNoteText(badLines: Int64): String {
    return "${badLines} 行进度日志无法解析（通常是进程被强杀留下的半截行），已跳过"
}

public func renderJournalEntry(e: JsonValue): String {
    let sb = StringBuilder()
    let at = Json.strAt(e, "at", "")
    let branch = Json.strAt(e, "branch", "-")
    let mode = modeLabel(Json.strAt(e, "mode", ""), "zh")
    sb.append("## ${formatDateTime(at)} · `${branch}` · ${mode}\n")
    let meta = ArrayList<String>()
    let from = Json.strAt(e, "from", "")
    let to = Json.strAt(e, "to", "")
    let commitCount = Json.intAt(e, "commitCount", 0)
    if (!from.isEmpty() && !to.isEmpty()) {
        meta.add("提交范围：`${shortSha(from)}` → `${shortSha(to)}`（${commitCount} 个提交）")
    } else if (commitCount > 0) {
        meta.add("最近 ${commitCount} 个提交")
    }
    let stats = Json.getOr(e, "stats")
    if (!Json.isNull(stats)) {
        meta.add("变更规模：${Json.intAt(stats, "files", 0)} 个文件，+${Json.intAt(stats, "insertions", 0)}/−${Json.intAt(stats, "deletions", 0)}")
    }
    let provider = Json.strAt(e, "provider", "")
    if (!provider.isEmpty()) {
        meta.add("摘要来源：${providerLabel(provider)}")
    }
    for (m in meta) {
        sb.append("- ${m}\n")
    }
    let summary = Json.strAt(e, "summary", "")
    if (!summary.isEmpty()) {
        // ⚠️ 用户文本必须过 oneLineClamped：oneLine 只折叠不截断，
        // 超长 summary 会把 journal.md 撑出任意长的单行。
        // README 侧（render.cj branchBlock）的同族早已按 160 收口，
        // 这里是同一契约的镜像侧 —— 两套标准并存必然漏点。
        sb.append("\n**摘要**：${oneLineClamped(summary, 160)}\n")
    }
    let highlights = Json.strArrAt(e, "highlights")
    if (!highlights.isEmpty()) {
        sb.append("\n**近期进展**\n")
        for (h in highlights) {
            sb.append("- ${oneLineClamped(h, 160)}\n")
        }
    }
    let nextSteps = Json.strArrAt(e, "nextSteps")
    if (!nextSteps.isEmpty()) {
        sb.append("\n**下一步**\n")
        for (h in nextSteps) {
            sb.append("- ${oneLineClamped(h, 160)}\n")
        }
    }
    let docs = Json.strArrAt(e, "docs")
    if (!docs.isEmpty()) {
        sb.append("\n**已更新文档**：${joinStrings(docs, "、")}\n")
    }
    return sb.toString().trimAsciiEnd()
}

public func modeLabel(mode: String, lang: String): String {
    let zh = !isEnglish(lang)
    match (mode) {
        case "track" => return if (zh) { "进度快照" } else { "snapshot" }
        case "shallow" => return if (zh) { "浅更新" } else { "shallow update" }
        case "deep" => return if (zh) { "深度更新" } else { "deep update" }
        case "manual" => return if (zh) { "手动记录" } else { "manual" }
        case _ => return mode
    }
}

public func providerLabel(provider: String): String {
    if (provider.isEmpty()) {
        return "未知"
    }
    if (provider == "rules") {
        return "规则引擎"
    }
    if (provider.startsWith("openai:")) {
        return "AI（${provider[7..]}）"
    }
    if (provider.startsWith("anthropic:")) {
        return "AI（${provider[10..]}）"
    }
    if (provider.startsWith("rules(after")) {
        return "规则引擎（AI 失败后降级）"
    }
    return provider
}

/// journal 条目 → 对外出口的条目。**两个出口必须共用这一个函数。**
///
/// 为什么原来是两套（2026-10-01 实测）：
///
///     存储 journal.jsonl        17 键
///     journal --json 的 entries 17 键（存储原样）
///     status --json 内嵌 journal  9 键（手挑投影）
///
/// 那 9 键是 `flow/status.cj` 里手写的一份拷贝，丢掉了存储里的 10 个键
/// （`commitCountScope` / `highlights` / `nextSteps` / `notes` / `source` /
/// `repoBranchCount` / `projectId` / `project` 与两个截断标志），
/// 还**凭空造了一个 `docs: []`** —— 浅更新根本不往 journal entry 写 `docs`
/// （只有 `flow/deep.cj` 写），于是对浅更新它恒为 `[]`：
/// 那不是"没有文档变更"，而是"这个键压根没写过"，两者被压成同一个值。
/// 恒空的假值比缺键更坏：缺键至少还能被检测。
///
/// 同一份形状约定抄多处、漏一处就破，这个引擎已经栽到第 8 例。
/// 现在只剩这一处构造，抄不动了。
///
/// `providerLabel` 是唯一加上去的键：它由 `provider` 推导，
/// 引擎在 update/deep 结果里早就恒发它。**不发的话每个消费方都要
/// 自己实现一遍 label 映射** —— 而那正是 label 会漂移的原因。
public func journalEntryJson(e: JsonValue): JsonValue {
    match (e) {
        case JObj(_) =>
            // 逐键拷贝而不是手挑：新增字段自动出现在所有出口，
            // 不会再出现"某个出口忘了加"的有损投影。
            let o = Json.obj()
            match (e) {
                case JObj(m) =>
                    for ((k, v) in m) {
                        Json.set(o, k, v)
                    }
                case _ => ()
            }
            Json.set(o, "providerLabel", Json.of(providerLabel(Json.strAt(e, "provider", ""))))
            return o
        case _ => return e
    }
}

/// journal 条目的**所有**出口都必须走 `journalEntryJson`，一个都不许自己搓。
///
/// 背景：这两个出口历史上是**两套形状**（`status --json` 内嵌的 journal 是
/// 手挑的 9 键投影，`journal --json` 给的是原始条目），同一个概念两个形状，
/// 消费方就得写两套解码分支。现已共用 `journalEntryJson`（逐键拷贝 + 派生
/// `providerLabel`），实测两个出口各 19 键、差集为空。
///
/// ⚠️ 那次合并**没有留下任何东西防止它重新分叉**：
/// 构造函数被改对了，但「两个出口都调用它」这件事只是注释里的一句话。
/// 谁在某天把某个出口改成自己拼对象，两个形状立刻又分叉，而且**两边都不会红** ——
/// 因为各自的测试都只验自己那一份。`cli.cj` 里那句注释写着这个引擎
/// 在「同一份形状约定抄多处」上已经栽到第 8 例，第 9 次不能靠自觉。
///
/// 判据：`.add(journalEntryJson(` 在全仓恰好出现 N 次，且分布在这些文件里。
/// 选这个形状而不是「数 `journalEntryJson(` 的调用」是因为测试里有 5 处
/// 直接调用它验行为 —— 只有「塞进数组」这一种形式才是出口。
/// 少一处 = 有出口绕开了共享构造器（形状会分叉）；
/// 多一处 = 有了第三个出口却没登记（消费方又多一套解码分支）。
///
/// ⚠️ 刻意**不**断言「`public func journalEntryJson` 在全仓只出现 1 次」：
/// 同名函数在同一包内根本编译不过，那是一条恒真断言 —— 等于没有断言。
/// 「构造器被改名/搬家」这种回归由上面的出口计数接住（改名后出口数直接变 0）。
@Test
func __lintJournalEntryHasExactlyTwoOutletsThroughTheSharedBuilder(): Unit {
    let files = ArrayList<String>()
    cjSourceFiles("src", files)
    @Assert(files.size > 20)   // 确认真的读到了源码，不是空跑

    let emit = ".add(" + "journalEntryJson("
    let selfName = "func __lintJournalEntryHasExactly" + "TwoOutletsThroughTheSharedBuilder"
    var emitters = ArrayList<String>()
    for (f in files) {
        let skip = if (f == "src/kernel/store.cj") {
            Option<String>.Some(selfName)
        } else {
            Option<String>.None
        }
        match (strippedCodeSkippingFunction(f, skip)) {
            case Some(code) =>
                for (line in code.split("\n")) {
                    if (line.trimAscii().contains(emit)) {
                        emitters.add(f)
                    }
                }
            case None =>
                // 剥不出纯代码 = 判据坏了（文件读不到，或排除区间算不出来）。
                // 不许当成「干净」放过去 —— 那正是永远绿的安全带。
                @Assert(false)
        }
    }
    if (emitters.size != 2) {
        eprintln("走共享构造器的 journal 出口变成了 ${emitters.size} 个（${emitters}），" +
            "必须恰好 2 个（cli.cj 的 journal --json、flow/status.cj 的 status --json）。\n" +
            "少一个 = 有出口绕开了 journalEntryJson，两个形状会重新分叉（本引擎栽过 8 次）；\n" +
            "多一个 = 有了第三个出口却没登记，消费方会多一套解码分支。")
    }
    @Assert(emitters.size == 2)
    @Assert(emitters.contains("src/cli/cli.cj"))
    @Assert(emitters.contains("src/flow/status.cj"))
}

public func shortSha(sha: String): String {
    if (sha.size <= 8) {
        return sha
    }
    return sha[..8]
}

// ------------------------------ 测试 ------------------------------

@Test
func testStoreRoundTrip(): Unit {
    let pid = "p_test_${nowMillis()}"
    let progress = Json.obj()
    Json.set(progress, "branches", Json.obj())
    let rec = setProgressBranch(progress, "main", jsonPatch([("head", Json.of("abc123")), ("status", Json.of("active"))]))
    @Assert(Json.strAt(rec, "head", "") == "abc123")
    @Assert(Json.has(rec, "firstTrackedAt"))
    writeProgress(pid, progress)
    let back = readProgress(pid)
    let backRec = progressBranch(back, "main")
    @Assert(backRec.isSome())
    @Assert(Json.strAt(backRec.getOrThrow(), "status", "") == "active")
    removePathIfExists(deepgitPath(["store", pid]))
}

@Test
func testJournalAppendAndRead(): Unit {
    let pid = "p_journal_${nowMillis()}"
    let e1 = Json.obj()
    Json.set(e1, "at", Json.of(nowIso()))
    Json.set(e1, "branch", Json.of("main"))
    Json.set(e1, "mode", Json.of("shallow"))
    Json.set(e1, "summary", Json.of("第一条"))
    appendJournal(pid, e1, "demo")
    let e2 = Json.obj()
    Json.set(e2, "at", Json.of(nowIso()))
    Json.set(e2, "branch", Json.of("feat/x"))
    Json.set(e2, "mode", Json.of("deep"))
    Json.set(e2, "summary", Json.of("第二条"))
    appendJournal(pid, e2, "demo")
    let list = readJournal(pid, 10)
    @Assert(list.size == 2)
    // 最新在前
    @Assert(Json.strAt(list[0], "summary", "") == "第二条")
    removePathIfExists(deepgitPath(["store", pid]))
}

@Test
func testReadJournalRejectsNonPositiveLimit(): Unit {
    // 负数 limit 以前直接代入 `collected.size - limit`，start 跑到数组末尾之外，
    // while 一次都不执行 —— 结果是空列表，但走的是「算错了才碰巧对」的路径。
    // 更糟的是调用方拿到的空列表和「这个项目真的没有记录」无法区分：
    //   CLI  `journal p --limit -5`  → 「（暂无记录）」exit 0
    //   HTTP /api/journal?limit=-5   → entries: [] 200
    //   MCP  get_journal{limit:-5}    → 「（暂无日志）」
    // 现在 readJournal 明确按「不要任何条目」处理，三个入口各自在边界上拒收非正数。
    let pid = "p_jlimit_${nowMillis()}"
    let e = Json.obj()
    Json.set(e, "at", Json.of(nowIso()))
    Json.set(e, "branch", Json.of("main"))
    Json.set(e, "mode", Json.of("shallow"))
    Json.set(e, "summary", Json.of("唯一一条"))
    appendJournal(pid, e, "demo")
    @Assert(readJournal(pid, 5).size == 1)
    @Assert(readJournal(pid, 0).size == 0)
    @Assert(readJournal(pid, -5).size == 0)
    @Assert(readJournal(pid, -1).size == 0)
    // 边界值：正好取 1 条仍要拿到最新的那条
    @Assert(readJournal(pid, 1).size == 1)
    @Assert(Json.strAt(readJournal(pid, 1)[0], "summary", "") == "唯一一条")
    removePathIfExists(deepgitPath(["store", pid]))
}

@Test
func testSetProgressBranchMergesFields(): Unit {
    let progress = Json.obj()
    setProgressBranch(progress, "main", jsonPatch([("a", Json.of(1))]))
    let rec = setProgressBranch(progress, "main", jsonPatch([("b", Json.of(2))]))
    @Assert(Json.intAt(rec, "a", 0) == 1)
    @Assert(Json.intAt(rec, "b", 0) == 2)
}

@Test
func testProviderLabels(): Unit {
    @Assert(providerLabel("rules") == "规则引擎")
    @Assert(providerLabel("openai:gpt-4o").contains("gpt-4o"))
    @Assert(providerLabel("").contains("未知"))
}

@Test
func testModeLabels(): Unit {
    @Assert(modeLabel("shallow", "zh") == "浅更新")
    @Assert(modeLabel("deep", "en") == "deep update")
}

@Test
func testRenderJournalEntry(): Unit {
    let e = Json.obj()
    Json.set(e, "at", Json.of("2026-09-30T10:00:00+08:00"))
    Json.set(e, "branch", Json.of("main"))
    Json.set(e, "mode", Json.of("deep"))
    Json.set(e, "summary", Json.of("完成核心层"))
    Json.set(e, "highlights", Json.strArray(["a", "b"]))
    let md = renderJournalEntry(e)
    @Assert(md.contains("main"))
    @Assert(md.contains("完成核心层"))
    @Assert(md.contains("- a"))
}

/// journal.md 镜像里的用户文本必须限长（oneLineClamped），不许只折叠不截断。
///
/// 旧实现 summary / highlights / nextSteps 走 oneLine（折叠不限长），
/// 一条超长 summary 就让 journal.md 出现任意长的单行 ——
/// 而 README 侧（render.cj）的同族字段早已按 oneLineClamped 收口，
/// 两侧两套标准必然漏点（render.cj 的契约测试先例：20000 字符 commit message
/// 撑坏 README 布局且每次 update 复现）。
///
/// ⚠️ 必须走 appendJournal 真实写路径读回 journal.md ——
/// 只断 renderJournalEntry 纯函数证明不了镜像文件真的被钳制。
@Test
func testJournalMdClampsRunawayUserText(): Unit {
    let base = "/tmp/deepgit-jclamp-${nowMillis()}"
    let testHome = "${base}-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    var pid = ""
    try {
        pid = "p_jclamp_${nowMillis()}"
        let huge = StringBuilder()
        for (i in 0..20000) {
            huge.append("A")
        }
        let long = huge.toString()
        @Assert(long.size == 20000)
        let e = Json.obj()
        Json.set(e, "at", Json.of("2026-10-01T10:00:00+08:00"))
        Json.set(e, "branch", Json.of("main"))
        Json.set(e, "mode", Json.of("deep"))
        Json.set(e, "summary", Json.of(long))
        Json.set(e, "highlights", Json.strArray([long, "正常条目"]))
        Json.set(e, "nextSteps", Json.strArray([long]))
        appendJournal(pid, e, "demo")
        let md = readFileTextOr(StorePaths(pid).journalMd, "<缺>")
        // 前提：镜像文件真的写出来了、且包含这三个小节（否则断言空转）
        @Assert(md.contains("**摘要**"))
        @Assert(md.contains("**近期进展**"))
        @Assert(md.contains("**下一步**"))
        // 镜像里不得出现超长单行（200 = 160 钳制 + 行内前缀余量）
        for (line in md.split("\n")) {
            @Assert(displayWidth(line) <= 200)
        }
        // 超长原文不得整段出现（5000 连 A 是它的任意子串）
        let probe = StringBuilder()
        for (i in 0..5000) {
            probe.append("A")
        }
        @Assert(!md.contains(probe.toString()))
        // 正常长度的条目原样保留（钳制不许误伤）
        @Assert(md.contains("正常条目"))
    } finally {
        // deepgitPath 解析依赖 DEEPGIT_HOME：先删 store 再复位环境
        //（反过来的话这里的 remove 静默 no-op，全靠 testHome 递归兜底才没泄漏）
        if (!pid.isEmpty()) {
            removePathIfExists(deepgitPath(["store", pid]))
        }
        exitTestHome()
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

/// 测试辅助：构造 JSON 对象
func jsonPatch(pairs: Array<(String, JsonValue)>): JsonValue {
    let o = Json.obj()
    for ((k, v) in pairs) {
        Json.set(o, k, v)
    }
    return o
}

@Test
func testReadStoreJsonPreservesCorruptFile(): Unit {
    // 回归：存储文件损坏时必须保住原内容。
    // 旧实现直接返回空对象，随后任意写操作都会用只含新数据的文件覆盖掉损坏文件，
    // 原内容既没保留也没提示 —— registry/state/progress/milestones 全部永久丢失。
    let dir = "/tmp/deepgit-corrupt-${nowMillis()}"
    ensureDir(dir)
    let f = dir + "/state.json"
    let broken = "{ this is not valid json "

    // 1) 文件不存在：空对象，且不产生副本
    let empty = readStoreJson(f)
    match (Json.asObj(empty)) {
        case Some(m) => @Assert(m.size == 0)
        case None => @Assert(false)
    }
    @Assert(listDir(dir).size == 0)

    // 2) 文件存在但损坏：返回空对象让读取路径继续，但必须另存副本
    writeFileAtomic(f, broken)
    let v = readStoreJson(f)
    match (Json.asObj(v)) {
        case Some(m) => @Assert(m.size == 0)
        case None => @Assert(false)
    }

    // 原文件一字未改 —— 这是「数据没丢」的核心断言
    @Assert(fileExists(f))
    @Assert(readFileTextOr(f, "") == broken)

    // 并且存在 .corrupt 保全副本，内容与原文件一致
    var kept = ""
    for (entry in listDir(dir)) {
        let full = entry.path.toString()
        if (full.contains("state.json.corrupt")) {
            kept = readFileTextOr(full, "")
        }
    }
    @Assert(kept == broken)

    removePathIfExists(dir)
}

@Test
func testReadJournalReportsUnparsableLines(): Unit {
    // 进程在 append 写到一半被杀会留下半截 JSONL。坏行以前完全静默，
    // 那条进度记录就此消失，而用户看到的是「（暂无记录）」——
    // 与「这个项目真的没有记录」无法区分。现在必须报出来。
    let pid = "p_badline_${nowMillis()}"
    let e = Json.obj()
    Json.set(e, "at", Json.of(nowIso()))
    Json.set(e, "branch", Json.of("main"))
    Json.set(e, "mode", Json.of("shallow"))
    Json.set(e, "summary", Json.of("完整的一条"))
    appendJournal(pid, e, "demo")

    // 追加两行垃圾：半截 JSON 和完全不是 JSON
    let p = StorePaths(pid)
    appendLine(p.journalJsonl, "{\"at\":\"2026-01-01\",\"summary\":\"被截断")
    appendLine(p.journalJsonl, "这不是 JSON")

    let (entries, bad) = readJournalWithStats(pid, 10)
    @Assert(entries.size == 1)   // 好行照常返回
    @Assert(bad == 2)            // 坏行被计数
    @Assert(Json.strAt(entries[0], "summary", "") == "完整的一条")
    // 旧签名保持兼容：只取条目，不报错
    @Assert(readJournal(pid, 10).size == 1)
    removePathIfExists(deepgitPath(["store", pid]))
}

/// 同一份损坏内容只保留一个 .corrupt 副本，且读多少次都不增殖。
///
/// 旧实现用时间戳 + 递增后缀命名，而原文件是「复制」不是「移走」，
/// 于是文件一直坏着 → 每次读都重新判定损坏 → 每次造一个新副本，
/// 副本数只增不减、永不收敛。实测一次 milestone list 生成 52 个副本 / 836K；
/// 而 post-commit 钩子每次提交都会触发一遍，那条告警还会重复刷几十次，
/// 把真实告警彻底淹掉。
@Test
func testCorruptStoreQuarantineIsIdempotent(): Unit {
    // 目录名刻意避开 "corrupt"：否则 state.json 自身也会被计数
    let home = "/tmp/deepgit-quar-${nowMillis()}"
    ensureDir(home)
    enterTestHome(home)
    let f = deepgitPath(["state.json"])
    writeFileAtomic(f, "{{{ 这不是合法 JSON")
    // 读 20 次
    for (_ in 0..20) {
        @Assert(Json.arrAt(readStoreJson(f), "nope").isEmpty())
    }
    var copies: Int64 = 0
    if (isDirectoryPath(home)) {
        for (fi in listDir(home)) {
            if (fi.path.toString().contains("corrupt")) {
                copies += 1
            }
        }
    }
    // 核心断言：20 次读只产生 1 份副本
    @Assert(copies == 1)
    exitTestHome()
    removePathIfExists(home)
}

/// 存储损坏后，写操作必须被拒绝而不是静默覆盖。
///
/// 「读到 0」和「真的是 0」在下游无法区分，所以必须在上游断掉。
/// 旧实现：解析失败返回空对象/空列表 → add 拿它做读-改-写 →
/// 50 条里程碑被覆盖成 1 条，命令 exit 0 谎报成功。
@Test
func testWriteIsRefusedWhenStoreIsCorrupt(): Unit {
    let home = "/tmp/deepgit-wg-${nowMillis()}"
    ensureDir(home)
    enterTestHome(home)
    // 造一批里程碑
    for (i in 0..5) {
        addMilestone("p1", "m${i}", "d", "", "")
    }
    @Assert(loadMilestones().size == 5)

    // 模拟崩溃导致的截断：内容不再是合法 JSON
    writeFileAtomic(milestonesFilePath(), "{\"milestones\":[{\"id\":\"m1\"")

    var threw = false
    try {
        addMilestone("p1", "should-not-land", "d", "", "")
    } catch (e: DgError) {
        threw = e.code == "STORE_CORRUPT"
    }
    @Assert(threw)
    // 原始损坏内容必须仍在（副本保全），且活跃存储没有被改写
    @Assert(readFileText(milestonesFilePath()).isSome())
    // 副本必须存在 —— 用户还有救
    @Assert(storeHasCorruptCopy(milestonesFilePath()))
    exitTestHome()
    removePathIfExists(home)
}

private func storeHasCorruptCopy(path: String): Bool {
    let dir = dirname(path)
    if (dir.isEmpty() || !isDirectoryPath(dir)) {
        return false
    }
    for (fi in listDir(dir)) {
        if (fi.path.toString().contains("corrupt")) {
            return true
        }
    }
    return false
}

@Test
func testWriteProgressAccountsEntriesInsteadOfSilentlyCapping(): Unit {
    // 回归：「上限当全量」这一族的第 8 次。
    //
    // writeProgress 把 entries 截到 200 条，但什么都不说，
    // status 的 entryCount 直接数这个数组 —— 于是跑过 251 次的项目报「200」，
    // 而 journal.jsonl 里明明有 251 行，且同一份 JSON 里还有个从不截断的
    // runCount 会报 251，两个数直接打架。
    //
    // 修法与这一族历次一致：真实总数滚动记账 + 标志位与数字成对给出。
    let testHome = "/tmp/deepgit-entrycnt-${nowMillis()}"
    ensureDir(testHome)
    enterTestHome(testHome)
    let pid = "p_entrycnt_${nowMillis()}"

    // 播种 250 条，模拟一个跑了两百多次的真实项目
    let progress = Json.obj()
    let entries = ArrayList<JsonValue>()
    for (i in 0..250) {
        let e = Json.obj()
        Json.set(e, "id", Json.of("seed${i}"))
        Json.set(e, "at", Json.of("2026-01-01T00:00:00+08:00"))
        entries.add(e)
    }
    Json.set(progress, "entries", JArr(entries))
    writeProgress(pid, progress)

    // 第一次写：总数必须等于 250，且此时还没截断
    let p1 = readProgress(pid)
    @Assert(Json.arrAt(p1, "entries").size == 200)          // 被截断了
    @Assert(Json.intAt(p1, "entriesTotal", -1) == 250)        // 但总数记下来了
    @Assert(Json.intAt(p1, "entriesKept", -1) == 200)

    // 连续再写 3 次：总数必须**继续累加**，不能被 200 冻住
    for (i in 0..3) {
        let p = readProgress(pid)
        let es = Json.arrAt(p, "entries")
        let e = Json.obj()
        Json.set(e, "id", Json.of("new${i}"))
        es.add(e)
        Json.set(p, "entries", JArr(es))
        writeProgress(pid, p)
    }
    let p2 = readProgress(pid)
    @Assert(Json.arrAt(p2, "entries").size == 200)
    @Assert(Json.intAt(p2, "entriesTotal", -1) == 253)
    @Assert(Json.intAt(p2, "entriesKept", -1) == 200)

    // 未达上限时不得凭空造出「截断」
    // ⚠️ projectId 必须先存进变量：nowMillis() 每调用一次值都不一样，
    // 写和读各调一次会得到两个不同的 id，于是读回的是全新空文件（这个坑踩过一次）。
    let smallId = "p_small_${nowMillis()}"
    let smallProgress = Json.obj()
    let se = ArrayList<JsonValue>()
    for (i in 0..5) {
        let e = Json.obj()
        Json.set(e, "id", Json.of("s${i}"))
        se.add(e)
    }
    Json.set(smallProgress, "entries", JArr(se))
    writeProgress(smallId, smallProgress)
    let reread = readProgress(smallId)
    @Assert(Json.intAt(reread, "entriesTotal", -1) == 5)
    @Assert(Json.arrAt(reread, "entries").size == 5)
    removePathIfExists(deepgitPath(["store", smallId]))

    removePathIfExists(deepgitPath(["store", pid]))
    exitTestHome()
    removePathIfExists(testHome)
}

/// 该项目的存储健康（三态）。
///
/// ⚠️ readState / readProgress 只返回解析后的 JSON，**把 StoreHealth 丢掉了**。
/// 于是「文件坏了、我们什么也没读到」和「这个项目本来就没有历史」
/// 在读出口上完全同构：branches=0、commitCount=0、一切正常。
///
/// 告警（Log.error）只走 stderr。CLI 在终端里能看见，但
///   · MCP 走 stdout —— 模型看不见
///   · HTTP 走响应体 —— 客户端看不见
///   · status --json —— 消费者也看不见
/// 而 summary.failedProjects=0，dashboard 还会报「一切正常」。
///
/// 实测把一个跑过 3 次 update 的项目的 progress.json 写成坏 JSON 后：
///   branches=0、failedProjects=0、isError=false、**没有任何字段**说存储已损坏。
/// 程序化调用方只会得出「这项目是新的 / 从没动过」。
///
/// 这是 #108（git 层的 gitReadable）在**存储层**的孪生问题：
/// 「读不出来」和「没有」是两件相反的事，必须分开表达。
public func storeHealthOf(projectId: String): StoreHealth {
    let p = StorePaths(projectId)
    var worst = StoreHealth.Ok
    // progress 与 state 分开判：只坏一个也要说出来，
    // 笼统报「存储正常」等于把另一半损坏也瞒了。
    let (_, hp) = readStoreJsonChecked(p.progress)
    let (_, hs) = readStoreJsonChecked(p.state)
    match (hp) {
        case StoreHealth.Ok => ()
        case StoreHealth.Corrupt => worst = StoreHealth.Corrupt
        case StoreHealth.Unreadable(_) => worst = hp
    }
    match (hs) {
        case StoreHealth.Ok => ()
        case StoreHealth.Corrupt => worst = StoreHealth.Corrupt
        case StoreHealth.Unreadable(_) =>
            // progress 已经报过更严重的问题时不覆盖（Corrupt > Unreadable：
            // 解析失败至少还留了 .corrupt 副本可恢复）
            match (worst) {
                case StoreHealth.Ok => worst = hs
                case _ => ()
            }
    }
    return worst
}

/// StoreHealth 的短标签，写进 JSON 字段。三态不能压成 Bool ——
/// 「读不出来」和「解析失败」的处置完全不同（后者有 .corrupt 副本可恢复）。
public func storeHealthLabel(h: StoreHealth): String {
    match (h) {
        case StoreHealth.Ok => return "ok"
        case StoreHealth.Corrupt => return "corrupt"
        case StoreHealth.Unreadable(_) => return "unreadable"
    }
}

@Test
func testJournalWindowDisclosureNeverLiesInEitherDirection(): Unit {
    // 窗口披露的文案是本引擎「上限当全量」第 12 次栽跟头的地方。
    // 它第一次就错在两处：
    //   1. 只接了「筛完为空」那一路 —— 有结果时被静默截断
    //   2. 两种情况共用同一句「没有条目」 —— 有结果时变成**反向**谎报
    // 而这段判定一度内联在 HTTP 路由的 if 里，没有任何测试能变红。
    // 所以它必须是纯函数，且四个方向都要钉死。
    let flag = "--limit"

    // 方向 1：窗口耗尽 + 一条没捞到 → 必须说「窗口内没有，更早处可能有」，
    // 绝不能是「（暂无记录）」这种断言式的否定。
    let e1 = journalWindowNoteText("feat/x", 5, 0, true, flag)
    @Assert(e1.size > 0)
    @Assert(e1.contains("没有分支 feat/x 的条目"))
    @Assert(e1.contains("更早的记录可能存在"))
    @Assert(e1.contains("--limit"))

    // 方向 2：窗口耗尽 + **有**结果 → 措辞必须换成「已截断」。
    // 这一条是负控：它与方向 1 的断言互斥。若实现仍在用同一句「没有条目」，
    // 方向 1 照样绿，方向 2 必红 —— 两者合起来才有判别力。
    let e2 = journalWindowNoteText("main", 3, 3, true, flag)
    @Assert(e2.size > 0)
    @Assert(e2.contains("截断"))
    @Assert(!e2.contains("没有分支"))   // 有 3 条却说「没有条目」= 反向谎报
    @Assert(e2.contains("main"))

    // 方向 3：窗口没耗尽（扫到了文件头，文件里总共就那么多）
    // → 必须**什么都不说**。对这种情况提示「请调大 limit」是给用户的假建议。
    @Assert(journalWindowNoteText("feat/x", 5, 5, false, flag).isEmpty())
    @Assert(journalWindowNoteText("no/such", 5, 0, false, flag).isEmpty())

    // 方向 4：branch 为空时不按分支筛，窗口耗尽没有意义 —— 同样必须沉默
    @Assert(journalWindowNoteText("", 5, 5, true, flag).isEmpty())

    // flag 称呼可切换：HTTP 侧叫 limit，CLI 侧叫 --limit
    @Assert(journalWindowNoteText("feat/x", 5, 0, true, "limit").contains("请调大 limit"))
    @Assert(!journalWindowNoteText("feat/x", 5, 0, true, "limit").contains("--limit"))

    // 坏行文案也收敛成一份，避免 HTTP 与 CLI 措辞漂移
    @Assert(journalBadLineNoteText(1).contains("1 行"))
    @Assert(journalBadLineNoteText(7).contains("7 行"))
}

@Test
func testBranchFilteredJournalDoesNotReportMissingAsAbsent(): Unit {
    // 「先取 limit 条再按分支过滤」让「记录存在但落在窗口之外」
    // 与「这个分支没有记录」完全同构。
    //
    // 调用点原来就是这么干的（CLI 还先把窗口放大成 limit*4，HTTP 连放大都没有）：
    //   最旧的 5 条是 feat/x，最新的 30 条是 main，读是倒序扫（最新在前）
    //   moongit journal gamma --branch feat/x --limit 5 → 旧实现「（暂无记录）」
    //   moongit journal gamma --branch feat/x --limit 50 → 记录就在那里
    //
    // 后果不是「少显示几条」，而是**谎报该分支没有历史**。
    let base = "/tmp/deepgit-jbranch-${nowMillis()}"
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
        let (p, _) = addProject(repo, "jbranch", ArrayList<String>(), "")
        projId = p.id

        // 手工铺一份有形状的 journal：最旧 5 条 feat/x，最新 30 条 main
        let pj = StorePaths(p.id)
        ensureDir(dirname(pj.journalJsonl))
        let sb = StringBuilder()
        for (i in 0..5) {
            sb.append("{\"branch\":\"feat/x\",\"at\":\"2026-01-0${i + 1}T09:00:00+08:00\",\"summary\":\"old feat ${i}\",\"commitCount\":1}\n")
        }
        for (i in 0..30) {
            sb.append("{\"branch\":\"main\",\"at\":\"2026-03-${pad2(i + 1)}T10:00:00+08:00\",\"summary\":\"main ${i}\",\"commitCount\":1}\n")
        }
        writeFileAtomic(pj.journalJsonl, sb.toString())

        // ⚠️ 前提自检：测试必须先证明自己的 fixture 成立，否则会把自己的错
        // 当成引擎的错。这一段是被一次真实翻车逼出来的 ——
        // 主 fixture 当时误写成了一行**残缺 JSON**（`{"branch":"main"` 少右花括号，
        // 那是本文件末尾「坏行」用例的内容，被抄到了前面），
        // 于是「坏行被计数」一路正确，而所有「行都能 parse」的前提问全部红灯，
        // 排查方向整个跑偏，一度怀疑 writeFileAtomic 往返在损坏字节。
        // 真实往返是逐字节一致的，问题在 fixture 自己身上。
        let rawTxt = readFileTextOr(pj.journalJsonl, "<缺文件>")
        @Assert(fileExists(pj.journalJsonl))
        @Assert(rawTxt.size > 10)
        @Assert(rawTxt[0] == 0x7Bu8)
        @Assert(rawTxt.contains("feat/x"))
        var rawLines = 0
        for (ln in rawTxt.split("\n")) {
            let t = ln.trimAscii()
            if (!t.isEmpty()) {
                @Assert(t[0] == 0x7Bu8)
                @Assert(Json.parse(t).isSome())
                rawLines += 1
            }
        }
        @Assert(rawLines == 35)

        // 前提 2：无过滤读取拿得到全部 35 条且零坏行
        let (allWin, allBad) = readJournalWithStats(p.id, 100)
        @Assert(allBad == 0)
        @Assert(allWin.size == 35)

        // 负控：**旧实现的做法**（先取最后 N 条、再按分支过滤）在这个 fixture 上
        // 确实一条 feat/x 都捞不到 —— 它读到的 5 条全是 main。
        // 后面 hits.size == 5 因此是有判别力的：oldFeat == 0 与它互斥，
        // 只断言其中一条都会让测试「怎么改都绿」。
        let (oldWin, _) = readJournalWithStats(p.id, 5)
        @Assert(oldWin.size == 5)
        var oldFeat = 0
        for (e in oldWin) {
            if (Json.strAt(e, "branch", "") == "feat/x") {
                oldFeat += 1
            }
        }
        @Assert(oldFeat == 0)

        // 核心：limit=5 时，最旧那 5 条 feat/x **必须**被捞出来。
        // 旧行为：命中 0 条 → CLI 打印「（暂无记录）」、HTTP 回 []，
        // 等于对着有历史的分支谎报「没有历史」。
        let (hits, bad, exhausted) = readJournalForBranch(p.id, "feat/x", 5)
        @Assert(bad == 0)
        @Assert(hits.size == 5)
        @Assert(Json.strAt(hits[0], "branch", "") == "feat/x")
        @Assert(Json.strAt(hits[0], "summary", "") == "old feat 4")
        // 倒序一路扫到文件头才凑够 → 文件里总共就这么多，
        // **不该**让调用方提示去调大 limit（那会变成对用户的假建议）
        @Assert(!exhausted)

        // 窗口确实不够：main 有 30 条，limit=3 只捞到 3 条，更早处还剩 32 条。
        // exhausted 必须为 true，调用方据此说「往更早处找」，而不是说「没有」。
        let (main3, main3Bad, main3Ex) = readJournalForBranch(p.id, "main", 3)
        @Assert(main3.size == 3)
        @Assert(main3Bad == 0)
        @Assert(main3Ex)
        @Assert(Json.strAt(main3[0], "summary", "") == "main 29")

        // limit 给足时窗口不算耗尽（文件里就那么多）
        let (mainAll, mainAllBad, mainAllEx) = readJournalForBranch(p.id, "main", 50)
        @Assert(mainAll.size == 30)
        @Assert(mainAllBad == 0)
        @Assert(!mainAllEx)
        @Assert(Json.strAt(mainAll[0], "summary", "") == "main 29")
        @Assert(Json.strAt(mainAll[29], "summary", "") == "main 0")

        // 分支结果的顺序仍是「最新在前」
        let (featAll, _, _) = readJournalForBranch(p.id, "feat/x", 50)
        @Assert(featAll.size == 5)
        @Assert(Json.strAt(featAll[0], "summary", "") == "old feat 4")
        @Assert(Json.strAt(featAll[4], "summary", "") == "old feat 0")

        // 从来没有记录的不存在分支：扫到文件头，exhausted 必须为 false ——
        // 否则会对着一个压根没有历史的分支喊「可能还有更早的记录」
        let (none, noneBad, noneEx) = readJournalForBranch(p.id, "no/such", 5)
        @Assert(none.size == 0)
        @Assert(noneBad == 0)
        @Assert(!noneEx)

        // branch 为空时等价于 readJournalWindow（不过滤）。
        //
        // ⚠️ 这条断言原来写的是 `@Assert(!plainEx)`，**它编码的是缺陷**（#189）：
        // 无分支过滤时 exhausted 被硬编码成 `false`，于是文件里 35 条、
        // limit=5，调用方（journal --json 与 MCP）一律被告知「没有更早的记录」。
        // 「恒 false」和「恒 true」一样是谎报，只是方向相反。
        // 现在如实上报：窗口确实装不下，更早处还有 30 条。
        let (plain, plainBad, plainEx) = readJournalForBranch(p.id, "", 5)
        @Assert(plain.size == 5)
        @Assert(plainBad == 0)
        @Assert(plainEx)
        // 给足窗口时又必须回到 false —— 不能只学会喊「还有更多」
        let (plainAll, _, plainAllEx) = readJournalForBranch(p.id, "", 50)
        @Assert(plainAll.size == 35)
        @Assert(!plainAllEx)

        // 坏行仍要计数 —— 崩溃残留不能被静默吞掉
        // （就是上面那次翻车的同款残缺行，但这里它是**被测输入**，不是 fixture 缺陷）
        writeFileAtomic(pj.journalJsonl, "{\"branch\":\"main\"\n" + "{\"branch\":\"feat/x\",\"at\":\"2026-01-01T00:00:00+08:00\"}\n")
        let (badHit, badLines, badEx) = readJournalForBranch(p.id, "feat/x", 5)
        @Assert(badLines == 1)
        @Assert(badHit.size == 1)
        @Assert(!badEx)     // 扫到了文件头：没凑够是因为真的就这么多
    } finally {
        // 全局状态必须在这里还原。断言一挂就跳过清理的话，
        // DEEPGIT_HOME 会漏给同进程后续测试，制造出让人去查一个
        // 根本不存在的 bug 的假红灯（实测连带打红 testRunDeepOnRealRepo）。
        exitTestHome()
        if (!projId.isEmpty()) {
            removePathIfExists(deepgitPath(["store", projId]))
        }
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

@Test
func testJournalMdMirrorSaysItIsTruncated(): Unit {
    // journal.md 是给人看的镜像，只留最近 100 条且**无任何说明** ——
    // 打开它的人会把「最近 100 条」当成「全部历史」，
    // 然后据此断言「这个项目只做过这些事」。JSONL 还能 --limit 往前翻，
    // 但打开 markdown 的人没有那个意识。
    let base = "/tmp/deepgit-jmd-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    var projId = ""
    try {
        let repo = base + "/repo"
        ensureDir(repo)
        let (p, _) = addProject(repo, "jmd", ArrayList<String>(), "")
        projId = p.id
        let pj = StorePaths(p.id)
        ensureDir(dirname(pj.journalJsonl))

        // 方向 1：条数不足上限 → 不得出现截断说明
        for (i in 0..3) {
            let e = Json.obj()
            Json.set(e, "branch", Json.of("main"))
            Json.set(e, "at", Json.of("2026-03-0${i + 1}T10:00:00+08:00"))
            Json.set(e, "summary", Json.of("e${i}"))
            appendJournal(p.id, e, "jmd")
        }
        let small = readFileTextOr(pj.journalMd, "<缺>")
        @Assert(small.contains("e0"))
        @Assert(!small.contains("仅显示最近"))

        // 方向 2：条数超过上限 → 必须写明「只是最近 N 条」以及去哪看全量
        for (i in 0..(JOURNAL_MD_KEEP + 5)) {
            let e = Json.obj()
            Json.set(e, "branch", Json.of("main"))
            Json.set(e, "at", Json.of("2026-04-01T10:00:00+08:00"))
            Json.set(e, "summary", Json.of("big${i}"))
            appendJournal(p.id, e, "jmd")
        }
        let big = readFileTextOr(pj.journalMd, "<缺>")
        @Assert(big.contains("仅显示最近 ${JOURNAL_MD_KEEP} 条"))
        @Assert(big.contains("不是全部历史"))
        @Assert(big.contains("journal.jsonl"))
        // 渲染出来的条目数仍必须严格等于上限，不能因为多读了一条探测项就多渲染一条。
        // （每个条目前都有一个 \n，所以 N 个条目会 split 成 N+1 段；
        //   String.indexOf 在本版本返回 Option<Int64>，不能直接参与算术。）
        @Assert(big.split("\n## ").size - 1 == JOURNAL_MD_KEEP)
    } finally {
        exitTestHome()
        if (!projId.isEmpty()) {
            removePathIfExists(deepgitPath(["store", projId]))
        }
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

@Test
func testJournalEntryJsonIsTheSameForBothOutlets(): Unit {
    // 这条钉的是 2026-10-01 修掉的那个缺陷本身：
    // `status --json` 内嵌的 journal 曾是一份**手挑的 9 键投影**，
    // 而 `journal --json` 的 entries 是存储原样的 17 键。
    // 同一个概念、同一个引擎、两个形状 —— 消费方得写两套解码分支，
    // 而最容易漏的那一套会把「没数据」显示成「一切正常」。
    //
    // 投影还多造了一个恒为 `[]` 的 `docs`（浅更新不写这个键），
    // 把「压根没记录」压成「没有变更」。

    // 造一条**深更新**形状的 entry（含条件性的 docs）
    let deepEntry = Json.obj()
    Json.set(deepEntry, "id", Json.of("j_1"))
    Json.set(deepEntry, "at", Json.of("2026-10-01T00:00:00+08:00"))
    Json.set(deepEntry, "mode", Json.of("deep"))
    Json.set(deepEntry, "branch", Json.of("main"))
    Json.set(deepEntry, "summary", Json.of("深度更新"))
    Json.set(deepEntry, "provider", Json.of("openai:gpt-4o"))
    Json.set(deepEntry, "commitCount", Json.of(12))
    Json.set(deepEntry, "commitCountScope", Json.of("repoTotal"))
    Json.set(deepEntry, "commitCountTruncated", Json.of(false))
    Json.set(deepEntry, "branchCountTruncated", Json.of(false))
    Json.set(deepEntry, "repoBranchCount", Json.of(7))
    Json.set(deepEntry, "highlights", Json.strArray(["a"]))
    Json.set(deepEntry, "nextSteps", Json.strArray(["b"]))
    Json.set(deepEntry, "notes", Json.strArray([]))
    Json.set(deepEntry, "source", Json.of("hook"))
    Json.set(deepEntry, "project", Json.of("demo"))
    Json.set(deepEntry, "projectId", Json.of("p_demo"))
    Json.set(deepEntry, "docs", Json.strArray(["AGENTS.md"]))

    let out = journalEntryJson(deepEntry)

    // 1. 一个键都不能丢：投影的整个问题就是有损
    match (deepEntry) {
        case JObj(m) =>
            for ((k, v) in m) {
                // JsonValue 没有结构相等（枚举带 payload 不自动实现 ==），
                // 所以比序列化结果 —— 键序在拷贝后保持不变，比字符串是安全的。
                @Assert(Json.compact(Json.getOr(out, k)) == Json.compact(v))
            }
        case _ => @Assert(false)
    }

    // 2. providerLabel 由 provider 推导，且不能覆盖存储里的原值
    @Assert(Json.strAt(out, "providerLabel", "") == "AI（gpt-4o）")
    @Assert(Json.strAt(out, "provider", "") == "openai:gpt-4o")

    // 3. 浅更新形状（**没有** docs 键）不得被凭空补出一个 docs: []
    //    —— 这就是原来那个恒空假值的来源。
    let shallowEntry = Json.obj()
    Json.set(shallowEntry, "id", Json.of("j_2"))
    Json.set(shallowEntry, "mode", Json.of("shallow"))
    Json.set(shallowEntry, "provider", Json.of("rules"))
    Json.set(shallowEntry, "commitCount", Json.of(1))
    let shallowOut = journalEntryJson(shallowEntry)
    match (shallowOut) {
        case JObj(m2) =>
            var hasDocs = false
            for ((k, _) in m2) {
                if (k == "docs") { hasDocs = true }
            }
            @Assert(!hasDocs)
        case _ => @Assert(false)
    }
    @Assert(Json.strAt(shallowOut, "providerLabel", "") == "规则引擎")

    // 4. 同一个函数作用两次结果相同（纯函数），且**不改入参**
    @Assert(Json.compact(journalEntryJson(deepEntry)) == Json.compact(out))
    @Assert(!Json.has(deepEntry, "providerLabel"))
}

@Test
func testJournalEntryJsonKeepsMinusOneAsUnknown(): Unit {
    // -1 是「读不出来」不是 0。手挑投影时代用 Json.intAt(e,"commitCount",0)，
    // 键缺失会被填成 0；逐键拷贝之后这个风险自然消失。
    // 这条把「-1 不能被当成 0」钉在共用函数上。
    let e = Json.obj()
    Json.set(e, "id", Json.of("j_3"))
    Json.set(e, "provider", Json.of("rules"))
    Json.set(e, "commitCount", Json.of(-1))
    let out = journalEntryJson(e)
    @Assert(Json.intAt(out, "commitCount", 0) == -1)

    // 键真的缺失时也不能被编造成 0
    let e2 = Json.obj()
    Json.set(e2, "id", Json.of("j_4"))
    Json.set(e2, "provider", Json.of("rules"))
    let out2 = journalEntryJson(e2)
    @Assert(!Json.has(out2, "commitCount"))
}

/// #189 回归：读取器必须能回答「窗口之外还有没有记录」。
///
/// 负控（曾真实发红）：循环填满 `limit` 就停，返回值里根本没有这个信息，
/// 于是 MCP `get_journal` 12 条记录返回 8 行且**零披露**，
/// `journal --json` 的 `branchWindowExhausted` 无过滤时恒为 `{}`。
/// 而 `readJournalForBranch` 在无分支时把它硬编码成 `false` ——
/// 那是**主动谎报**，比缺字段更糟。
@Test
func testJournalWindowKnowsWhetherMoreRecordsExistOutsideIt(): Unit {
    let pid = "p_jwin_${nowMillis()}"
    // 路径必须走 deepgitPath：StorePaths 是从 DEEPGIT_HOME 推出来的，
    // 自己拼 /tmp/... 会写到别处去（第一版就这么栽了，断言 all.size==12 直接红）。
    let storeDir = deepgitPath(["store", pid])
    let jpath = deepgitPath(["store", pid, "journal.jsonl"])
    ensureDir(storeDir)
    // 直接写 12 条记录，不走 update（那会牵出 git 与文档托管区，与本断言无关）
    let sb = StringBuilder()
    for (i in 0..12) {
        sb.append("{\"id\":\"j_${i}\",\"at\":\"2026-01-0${(i % 9) + 1}T00:00:00+08:00\",")
        sb.append("\"mode\":\"shallow\",\"branch\":\"main\",\"summary\":\"s${i}\",")
        sb.append("\"commitCount\":1,\"commitCountScope\":\"new\",\"provider\":\"rules\"}\n")
    }
    writeFileAtomic(jpath, sb.toString())

    // 窗口装得下：不得谎报耗尽
    let (all, badAll, exhaustedAll) = readJournalWindow(pid, 20)
    @Assert(all.size == 12)
    @Assert(badAll == 0)
    @Assert(!exhaustedAll)

    // 正好装满：全部 12 条都在窗口里，仍**不得**说耗尽
    let (exact, _, exhaustedExact) = readJournalWindow(pid, 12)
    @Assert(exact.size == 12)
    @Assert(!exhaustedExact)

    // 窗口不够：必须说耗尽（这是整个断言的承重处）
    let (win, badWin, exhaustedWin) = readJournalWindow(pid, 8)
    @Assert(win.size == 8)
    @Assert(badWin == 0)
    @Assert(exhaustedWin)

    // 无分支过滤时也必须如实上报 —— 原来硬编码 false
    let (nb, _, exhaustedNb) = readJournalForBranch(pid, "", 8)
    @Assert(nb.size == 8)
    @Assert(exhaustedNb)

    // 旧的两元接口必须保持行为不变（很多调用点在用）
    let (legacy, legacyBad) = readJournalWithStats(pid, 8)
    @Assert(legacy.size == 8)
    @Assert(legacyBad == 0)

    // 坏行不算「窗口外还有记录」：文件里全是坏行时不该谎报
    writeFileAtomic(jpath, "半截行\n另一行\n")
    let (none, badOnly, exhaustedNone) = readJournalWindow(pid, 5)
    @Assert(none.size == 0)
    @Assert(badOnly == 2)
    @Assert(!exhaustedNone)

    removePathIfExists(storeDir)
}
