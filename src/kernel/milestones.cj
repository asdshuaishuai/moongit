// 里程碑：项目群级别的目标管理。
//
// 存储在全局 ~/.deepgit/milestones.json（单文件、跨项目聚合友好）。
// 完成判定支持两种来源：手工标记 done，或绑定 git tag 自动检测（tag 存在即达成）。
package moongit.kernel

import std.collection.*
import std.convert.*
import std.env.*
import moongit.util.*
import std.unittest.*
import std.unittest.testmacro.*

public class Milestone {
    public let id: String
    public let projectId: String
    public var name: String
    public var description: String
    public var targetDate: String    // YYYY-MM-DD，可为空
    public var tag: String           // 绑定的 git tag，可为空
    public var status: String        // open | done | dropped
    public var createdAt: String
    public var completedAt: String

    public init(id: String, projectId: String, name: String, description: String,
                targetDate: String, tag: String, status: String, createdAt: String, completedAt: String) {
        this.id = id
        this.projectId = projectId
        this.name = name
        this.description = description
        this.targetDate = targetDate
        this.tag = tag
        this.status = status
        this.createdAt = createdAt
        this.completedAt = completedAt
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "id", Json.of(this.id))
        Json.set(o, "projectId", Json.of(this.projectId))
        Json.set(o, "name", Json.of(this.name))
        Json.set(o, "description", Json.of(this.description))
        Json.set(o, "targetDate", Json.of(this.targetDate))
        Json.set(o, "tag", Json.of(this.tag))
        Json.set(o, "status", Json.of(this.status))
        Json.set(o, "createdAt", Json.of(this.createdAt))
        Json.set(o, "completedAt", Json.of(this.completedAt))
        return o
    }

    public static func fromJson(j: JsonValue): Milestone {
        return Milestone(
            Json.strAt(j, "id", ""),
            Json.strAt(j, "projectId", ""),
            Json.strAt(j, "name", ""),
            Json.strAt(j, "description", ""),
            Json.strAt(j, "targetDate", ""),
            Json.strAt(j, "tag", ""),
            Json.strAt(j, "status", "open"),
            Json.strAt(j, "createdAt", ""),
            Json.strAt(j, "completedAt", ""),
        )
    }
}

/// 里程碑的 git 感知进度（运行时计算，不落盘）
public class MilestoneProgress {
    public let milestone: Milestone
    public let tagName: String        // 实际生效的 tag 名（绑定或同名推导）
    public let tagReached: Bool       // tag 是否已存在于仓库
    public let commitsSince: Int64    // 自创建以来的提交数（**整个仓库**，非当前分支）；-1 = 读不出来
    public let daysToTarget: Int64    // 距目标日期天数（正=剩余天数，负=已逾期 N 天；未设置=-1）
    public let overdue: Bool
    public let effectiveStatus: String  // 综合手工状态与 tag 检测后的状态
    /// 是否**尝试过**读取 git 且失败。
    ///
    /// false ⇒ tagReached / commitsSince 都是「未知」，不是「没有」——
    /// 见 milestoneProgress 里的说明。
    /// 注意语义：没有配置仓库（repoPath 为空）时我们根本没去查，
    /// 不算「不可用」，此时为 true。区分这两者很重要：
    /// 「这个里程碑没绑仓库」是正常配置，「绑的仓库读不出来」是故障。
    public let gitReadable: Bool

    public init(milestone: Milestone, tagName: String, tagReached: Bool, commitsSince: Int64,
                daysToTarget: Int64, overdue: Bool, effectiveStatus: String, gitReadable!: Bool = true) {
        this.milestone = milestone
        this.tagName = tagName
        this.tagReached = tagReached
        this.commitsSince = commitsSince
        this.daysToTarget = daysToTarget
        this.overdue = overdue
        this.effectiveStatus = effectiveStatus
        this.gitReadable = gitReadable
    }
}

func milestonesFilePath(): String {
    return deepgitPath(["milestones.json"])
}

public func loadMilestones(): ArrayList<Milestone> {
    let (list, _) = loadMilestonesChecked()
    return list
}

/// 返回 (列表, 存储是否损坏)。
///
/// 第二个返回值是给**写路径**的。旧实现（以及旧 readStoreJson）解析失败时
/// 返回空列表，写操作分不清「本来就没有里程碑」和「文件坏了、什么都没读到」，
/// 于是拿空列表做读-改-写，把损坏文件覆盖成近乎空的文件：
/// 实测 50 条里程碑被截成 1 条，命令却 exit 0 谎报成功。
/// 副本留在盘上，但没人会去翻一个 .corrupt 文件 —— 那 49 条等于没了。
public func loadMilestonesChecked(): (ArrayList<Milestone>, StoreHealth) {
    let out = ArrayList<Milestone>()
    let (j, health) = readStoreJsonChecked(milestonesFilePath())
    for (m in Json.arrAt(j, "milestones")) {
        out.add(Milestone.fromJson(m))
    }
    return (out, health)
}

/// 写路径闸门：存储已损坏时拒绝写入。
///
/// 「读到 0」和「真的是 0」在下游完全无法区分，所以必须在上游断掉。
/// 读路径保持宽松（继续用 loadMilestones），只有会覆盖文件的操作才拦。
func assertMilestonesWritable(): Unit {
    let (_, health) = loadMilestonesChecked()
    // 「读不出来」和「解析失败」都要拦。旧实现只拦后者：
    // readFileText 把权限/IO 错误和「文件不存在」都返回 None，
    // 于是 chmod 000 之后闸门放行，5 条里程碑被覆盖成只剩新加的那 1 条、exit 0、
    // 连 .corrupt 副本都留不下（原文件读不出来，副本也复制不出来）。
    match (health) {
        case StoreHealth.Corrupt =>
            throw DgError(
                "STORE_CORRUPT",
                "milestones.json 已损坏，已保留 .corrupt 副本，本次未做任何写入。\n" +
                    "  继续写入会把全部里程碑覆盖成近乎空的文件（实测 50 条 → 1 条）。\n" +
                    "  请先从副本恢复，或确认可以丢弃后手动删除该文件再重试。",
                1,
                None,
            )
        case StoreHealth.Unreadable(reason) =>
            throw DgError(
                "STORE_UNREADABLE",
                "milestones.json 读不出来，本次未做任何写入：${reason}\n" +
                    "  继续写入会用只含新里程碑的内容覆盖它，而原内容读不出来、连副本都留不下。\n" +
                    "  请先修复文件权限（或用 chmod u+r）再重试。",
                1,
                None,
            )
        case StoreHealth.Ok => ()
    }
}

/// 全局里程碑文件的互斥锁。
///
/// milestones.json 是**跨项目的单文件**，而项目锁的作用域是 store/<projectId>/locks/
/// —— 锁域 ⊅ 数据域，项目锁根本管不到它。实测：并发跑 6 条 `milestone add`
/// （分属不同项目，所以彼此的项目锁互不排斥），30 条里程碑丢了 9 条，
/// 而每一条命令都 exit 0 谎报成功 —— 各自读到同一份旧快照，各自全量覆盖，后写者赢。
public func withMilestonesLock<T>(body: () -> T): T {
    return withLockWaiting(deepgitPath(["locks", "milestones.lock"]), 60000, 30000, body)
}

public func saveMilestones(list: ArrayList<Milestone>): Unit {
    let root = Json.obj()
    let arr = ArrayList<JsonValue>()
    for (m in list) {
        arr.add(m.toJson())
    }
    Json.set(root, "milestones", JArr(arr))
    Json.set(root, "updatedAt", Json.of(nowIso()))
    ensureDir(dirname(milestonesFilePath()))
    writeFileAtomic(milestonesFilePath(), Json.pretty(root))
}

/// 新增里程碑（同项目同名幂等：已存在则原样返回）
/// 校验 YYYY-MM-DD（月 1..12 日 1..31）；空串放行（未设置）
func isAsciiDigitByte(c0: UInt8): Bool {
    return c0 >= 0x30 && c0 <= 0x39
}

func validTargetDate(s0: String): Bool {
    if (s0.isEmpty()) {
        return true
    }
    if (s0.size != 10) {
        return false
    }
    if (s0[4] != 0x2Du8 || s0[7] != 0x2Du8) {  // '-'
        return false
    }
    for (i in [0, 1, 2, 3, 5, 6, 8, 9]) {
        if (!isAsciiDigitByte(s0[i])) {
            return false
        }
    }
    // 「这是一个真实存在的日子吗」只有一个判据：isIsoDate。
    // 原来这里是独立手写的一份，而**读取侧**的 isIsoDate 只验格式不验月长 ——
    // 同一个子系统两半对同一个日期给出相反答案（缺陷 #180）。
    return isIsoDate(s0)
}

/// 某年某月的天数（含闰年）。
private func daysInMonth(year: Int64, month: Int64): Int64 {
    // 闰年：4 年一百年一例外
    let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
    if (month == 2) {
        return if (leap) { 29 } else { 28 }
    }
    if (month == 4 || month == 6 || month == 9 || month == 11) {
        return 30
    }
    return 31
}

public func addMilestone(projectId: String, name: String, description: String,
                         targetDate: String, tag: String): (Milestone, Bool) {
    // 名字是里程碑的主键（去重、milestone_action、进度计算都靠它）。
    // 原来只校验日期，空名一路写进存储 —— MCP 的 milestone_add 不校验参数，
    // 实测传 name="" 会建出一条 name 为空的里程碑，回报还是「已创建：」，
    // 后面什么名字都没有。HTTP 侧有校验、CLI 靠位置参数天然非空，只有 MCP 这条路是漏的，
    // 但校验放在这一层才真正封死所有入口。
    if (name.trimAscii().isEmpty()) {
        throw DgError.usage("里程碑名不能为空")
    }
    if (!validTargetDate(targetDate)) {
        throw DgError.usage("目标日期格式须为 YYYY-MM-DD：${targetDate}")
    }
    // 整个读-改-写必须在锁内：只在 save 前加锁没用，两个进程仍会读到同一份旧快照
    return withMilestonesLock({ =>
        assertMilestonesWritable()
        let list = loadMilestones()
        for (m in list) {
            if (m.projectId == projectId && m.name == name) {
                return (m, false)
            }
        }
        let id = "m_" + sha256HexOf(projectId + "/" + name + "/" + "${nowMillis()}")[..10]
        let m = Milestone(id, projectId, name, description, targetDate, tag, "open", nowIso(), "")
        list.add(m)
        saveMilestones(list)
        return (m, true)
    })
}

/// 删除里程碑（按项目+名字）
public func removeMilestone(projectId: String, name: String): Bool {
    return withMilestonesLock({ =>
        assertMilestonesWritable()
        let list = loadMilestones()
        let kept = ArrayList<Milestone>()
        var removed = false
        for (m in list) {
            if (m.projectId == projectId && m.name == name) {
                removed = true
            } else {
                kept.add(m)
            }
        }
        if (removed) {
            saveMilestones(kept)
        }
        return removed
    })
}

/// 手工标记状态：done / open / dropped
public func setMilestoneStatus(projectId: String, name: String, status: String): Bool {
    return withMilestonesLock({ =>
        assertMilestonesWritable()
        let list = loadMilestones()
        var found = false
        for (m in list) {
            if (m.projectId == projectId && m.name == name) {
                m.status = status
                m.completedAt = if (status == "done") { nowIso() } else { "" }
                found = true
            }
        }
        if (found) {
            saveMilestones(list)
        }
        return found
    })
}

public func milestonesFor(projectId: String): ArrayList<Milestone> {
    return milestonesOf(loadMilestones(), projectId)
}

/// 从**已读出**的列表里筛出某项目的里程碑。
///
/// 与 milestonesFor 分开是因为调用方有时已经拿到了列表和它的 StoreHealth
/// （见 buildMilestoneOverview）—— 那时再 milestonesFor 一次就会把
/// 健康度又扔一遍，于是损坏被重新读成「0 个里程碑」。
public func milestonesOf(list: ArrayList<Milestone>, projectId: String): ArrayList<Milestone> {
    let out = ArrayList<Milestone>()
    for (m in list) {
        if (m.projectId == projectId) {
            out.add(m)
        }
    }
    return out
}

public func openMilestoneCount(): Int64 {
    var n: Int64 = 0
    for (m in loadMilestones()) {
        if (m.status == "open") {
            n += 1
        }
    }
    return n
}

/// 距离某 YYYY-MM-DD 的天数（目标日 - 今天；正数=还剩 N 天，负数=已过 N 天）
/// 是否是合法的 YYYY-MM-DD：前 10 位中第 4、7 位为连字符，其余 8 位为数字。
///
/// 里程碑的 targetDate 可以被手改，而 epochDays 里的 Int64.parse 遇非数字会抛异常。
/// 原实现只检查了长度，脏日期（如 "not-a-date"）会一路冒泡到 buildDashboard，
/// 让**所有项目**的仪表盘整体崩溃（stdout 0 字节，HTTP 侧是空回复）。
public func isIsoDate(dateStr: String): Bool {
    if (dateStr.size < 10) {
        return false
    }
    // 闭区间：0..9 共 10 个字符。写成 0..10 会越界取到第 11 位。
    for (i in 0..9) {
        let c = dateStr[i]
        if (i == 4 || i == 7) {
            if (c != 0x2Du8) {
                return false
            }
        } else if (c < 0x30u8 || c > 0x39u8) {
            return false
        }
    }
    let m = Int64.parse(dateStr[5..7])
    let d = Int64.parse(dateStr[8..10])
    if (m < 1 || m > 12 || d < 1) {
        return false
    }
    // ⚠️ 必须按**真实月长**校验，不能只查 d <= 31（缺陷 #180）。
    //
    // 原来这里只验「是 10 位、数字加横杠」，于是 2026-02-31、2026-13-01、
    // 2026-01-32 全被放行，再被 `epochDays` 的 clamp 换算成一个
    // **看起来完全可信**的纪元日：
    //   `milestone list` 打出
    //     「vX · ⚠ 已逾期 · 目标 2026-02-31（逾期 212 天）」
    //     「vX · 进行中 · 目标 2026-13-01（还剩 61 天）」
    // 而写入闸门 `milestone add --date 2026-02-31` **自己就拒收**这个日期
    // （`validTargetDate` 早就按真实月长判过了）。
    // 同一个子系统的两半对「2026-02-31 算不算一个日期」给出相反答案。
    //
    // 里程碑的「还剩多少天」是给人排期用的，凭空多出来的天数会直接变成排期错误。
    return d <= daysInMonth(Int64.parse(dateStr[0..4]), m)
}

/// 距今天数。日期非法时返回 -1（与「未设置目标日期」同义）。
public func daysFromToday(dateStr: String): Int64 {
    if (!isIsoDate(dateStr)) {
        return -1
    }
    // 仅取本地今天日期（ISO 前 10 位）
    let today = nowIso()[..10]
    return epochDays(dateStr) - epochDays(today)
}

/// 简化历法换算：YYYY-MM-DD → 自 1970-01-01 的天数
func epochDays(dateStr: String): Int64 {
    let y = Int64.parse(dateStr[0..4])
    var m = Int64.parse(dateStr[5..7])
    var d = Int64.parse(dateStr[8..10])
    // 防御性 clamp：脏数据不砖死整个 list/dashboard。
    // ⚠️ 现在它只是**兜底**了 —— 真正的闸门是 isIsoDate 的真实月长校验（#180）。
    // 留着是因为 :330 记着的那次事故：脏日期曾经让**所有项目**的仪表盘整体崩掉。
    if (m < 1) { m = 1 }
    if (m > 12) { m = 12 }
    if (d < 1) { d = 1 }
    if (d > 31) { d = 31 }
    // 累计各月天数（非闰年），闰年由 isLeap 修正
    let cum = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    var days = (y - 1970) * 365 + (y - 1969) / 4 - (y - 1901) / 100 + (y - 1601) / 400
    days += cum[m - 1]
    if (m > 2 && isLeapYear(y)) {
        days += 1
    }
    return days + d - 1
}

func isLeapYear(y: Int64): Bool {
    return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

/// 计算里程碑的 git 感知进度。repoPath 为空或非 git 仓库时只做日期计算。
public func milestoneProgress(m: Milestone, repoPath: String, defaultBranch: String): MilestoneProgress {
    // tag 检测：显式绑定，或默认用里程碑名本身作为 tag 名
    var tagName = m.tag
    if (tagName.isEmpty()) {
        tagName = m.name
    }
    var tagReached = false
    // -1 = 「没查出来 / 查不了」，与 daysToTarget 的 -1（未设置）同一套约定。
    // 绝不能让它停在 0：0 是一个**结论**（「一个提交都没有」），
    // 而没查出来是**无知**，两者相反。详见下面 rev-list 那段。
    var commitsSince: Int64 = -1

    // ⚠️ git 是否可用必须**问 git 自己**，不能用 volumeAccessible。
    //
    // volumeAccessible 只 `stat <path>`，而「.git/objects 丢失」「索引损坏」
    // 「卷挂载后目录还在但内容读不出」这些情况下目录照样存在、stat 照样成功，
    // 于是守卫放行，后面所有 git 调用静默失败。
    //
    // 真实判据：git 能不能报出自己的 git-dir。
    // 没有仓库可查 ≠ 仓库读不出来。只有「查了且失败」才是故障。
    var gitReadable = true
    if (!repoPath.isEmpty()) {
        gitReadable = gitTry(repoPath, ["rev-parse", "--git-dir"]).ok()
    }

    // ⚠️⚠️⚠️ 这个目录**本身就是仓库**吗？不能问 `rev-parse`（缺陷 #183）。
    //
    // `git rev-parse --git-dir` 会一路往上找，直到找到一个仓库为止 ——
    // 所以一个**嵌在别人仓库里**的普通目录照样「通过」。
    // 后果不是「拿不到数」，是**拿一个毫不相干的仓库的数**安到本项目头上：
    // 实测 registry 里一个 `kind:"dir"` 的 innerdir，路径 `/…/outer/inner`，
    // 里程碑打出「创建以来 2 提交」—— 那是 outer 的提交，与 innerdir 无关。
    // 用户看到自己一个非 git 目录的里程碑「有 2 个提交」，会去查根本查不到。
    //
    // 判据用 `<path>/.git` 是否存在：它只在该目录**自身**是仓库根时为真。
    // 不用 `--show-toplevel` 比较字符串，是为了躲开 macOS 的 /tmp ↔ /private/tmp
    // 这类同一目录两种拼写（registry 存一种、git 报另一种）造成的假阴性。
    let isRepoRoot = !repoPath.isEmpty() && fileExists("${repoPath}/.git")

    // ⚠️⚠️ 没有仓库路径时，**一次 git 调用都不能发**。
    //
    // 原实现在 repoPath 为空时 gitReadable 保持初值 true，于是照样进了下面那个
    // if 块，把空路径交给 gitTry —— 而空路径意味着「在进程当前工作目录里跑」。
    // 后果不是「拿不到数」，是**拿一个毫不相干的仓库的数**再安到用户里程碑上：
    // 实测（测试进程的 CWD 在引擎仓库里）没绑仓库的里程碑报出
    //     创建以来 6 提交        ← 那是 moonGit 自己的仓库的提交数
    // 而 dashboard 对没配 git 的项目正是传空路径。
    //
    // 「没绑仓库」是正常配置（gitReadable 仍为 true，「没查」≠「查失败」），
    // 但答案必须是 commitsSince = -1（不知道），不是别人的仓库的数字。
    if (gitReadable && isRepoRoot) {
        match (revParse(repoPath, "refs/tags/" + tagName)) {
            case Some(_) => tagReached = true
            case None => ()
        }
        // 自创建以来的提交数：**整个仓库**，不只当前分支。
        //
        // ⚠️ 原来传的是 `HEAD`，于是 rev-list 只走当前分支，而这里的注释
        // 写的是「不限分支，看整个仓库的活跃量」、字段注释又写「（当前分支）」——
        // 两处注释互相矛盾，实现是唯一那个不符合用户预期的。
        //
        // 危害不是数字不好看，是**方向错了**：里程碑建完之后大家照常在特性分支上
        // 干活，main 一动不动，HEAD 口径就几乎不涨。实测里程碑创建后特性分支
        // 6 个提交：
        //     HEAD   = 1   ← 引擎报「创建以来 1 提交」
        //     --all  = 7
        // 一个已经忙了半年的里程碑看上去毫无动静，方向上属于
        // 「本引擎最高发的那族缺陷」：把部分口径当全量，且往**低**的一边偏。
        //
        // --all 才是这个指标该有的语义（用户问的是「这个里程碑立项以来做了多少事」），
        // 也正是注释一直承诺的那个。
        // ⚠️ 切片前必须先过 isIsoDate（对齐 targetDate 的 #180 判例）。
        //
        // 原来只查「非空且长度 ≥ 10」就裸切 `m.createdAt[..10]`：
        // 仓颉字符串按**字节**索引，手改 milestones.json 写
        // 「2026年1月1日」「２０２６－０１－０１」（全角）这类值时，
        // 第 10 个字节正好落在多字节 UTF-8 序列中间，
        // `Invalid utf8 byte sequence` 一路冒泡 ——
        // milestone list / dashboard / milestone done 三条出口全灭。
        // isIsoDate 逐字节校验前 10 位是 ASCII 数字/连字符（外加真实月长），
        // 过了它再切，切片永远落在 ASCII 边界内。
        if (isIsoDate(m.createdAt)) {
            let since = m.createdAt[..10]
            let r = gitTry(repoPath, ["rev-list", "--count", "--since=" + since + "T00:00:00", "--all"])
            if (r.ok() && !r.stdout.isBlank()) {
                try {
                    commitsSince = Int64.parse(r.stdout.trimAscii())
                } catch (e: Exception) {
                    commitsSince = -1
                }
            } else {
                // ⚠️ 读不出来**不等于**没有提交。
                //
                // gitReadable 只由 `rev-parse --git-dir` 决定，而对象库损坏、
                // 索引损坏、shallow/partial clone 缺对象这些情况下它照样成功，
                // rev-list 却会失败 —— 于是原实现让 commitsSince 停在 0，
                // 同时对外声明 gitReadable=true，调用方无从分辨
                // 「这个里程碑创建以来一个提交都没有」和「我们查不出来」。
                commitsSince = -1
            }
        } else {
            // 没有 createdAt，或日期部分不是合法 YYYY-MM-DD
            // （长度不足、手改成中文/全角、或日历上不存在 —— 见 #180），
            // 连日期都取不出来：这是「没查」，不是「查了是 0」
            commitsSince = -1
        }
    }

    var days = -1  // -1 表示未设置或日期非法
    var overdue = false
    // 只对**合法日期**算逾期。原先只要 targetDate 非空就算，脏日期返回 -1 会被
    // 判成「-1 < 0」→ 逾期，把「日期损坏」显示成「已逾期」，是误导。
    if (isIsoDate(m.targetDate)) {
        let d = daysFromToday(m.targetDate)
        days = d
        overdue = d < 0 && m.status == "open"
    }

    // 生效状态：手工 done/dropped 优先；open 时 tag 达成自动视为 done
    var effective = m.status
    if (m.status == "open" && tagReached) {
        effective = "done"
    }
    // ⚠️ 仓库读不出来时，**不能**报「进行中」。
    //
    // 实测：里程碑 `demo v1.0` 绑定 tag v1.0.0，仓库正常时
    //   status=done  tagReached=true   dashboard counts = {done: 1}
    // 把 .git/objects 移走（模拟卷未挂载 / 索引损坏）之后，同一个里程碑变成
    //   status=open  tagReached=false  dashboard counts = {open: 1}
    // 且**零告警**。也就是说：磁盘满、卷掉线、.git 损坏这些最该报警的时刻，
    // 引擎报出来的**成就数反而减少了** —— 已达成的里程碑悄悄退回进行中。
    //
    // 「我们不知道」和「没有达成」是两件相反的事，必须分开表达。
    if (!gitReadable && m.status == "open") {
        effective = "unknown"
    }
    return MilestoneProgress(m, tagName, tagReached, commitsSince, days, overdue, effective, gitReadable: gitReadable)
}

/// 里程碑在**只读 JSON 出口**（`milestone list --json` / `dashboard --json` /
/// MCP `list_milestones`）里的唯一形状。
///
/// 【为什么住在 kernel 而不是 cli】
/// 三个出口必须逐键一致，而它们分属三个文件。原先 dashboard 在 flow/dashboard.cj
/// 里**手抄了第三份**，于是本会话已经栽了两次：
///   1. dashboard 少 id / createdAt / completedAt 三个键 → 同一个结构体在
///      milestone list 下能解、在 dashboard 下必然崩；
///   2. dashboard 把 tag 写成 tagName、且没有 tagName 键 → `tag` 同名不同义。
/// 两次都是「两份拷贝忘了同步」，第三次（unverifiedReason 只在一边发）同理。
/// 靠注释提醒「这几个键必须一致」是没用的 —— 注释不会跟着新键更新。
/// 所以形状下沉到 kernel，让 cli 与 flow 都调这一份：
/// **键集只可能一致，不一致就编译不过或一眼看出。**
public func milestoneJson(p: ProjectEntry, prog: MilestoneProgress): JsonValue {
    let o = prog.milestone.toJson()

    // 剥掉存储主键 `id`（milestones.json 里的 m_xxx）。
    //
    // 它是**只出不进**的键：全引擎没有任何 API 收它作入参 ——
    // milestone_action 用的是 project + name，不是 id。留着它有两个害处：
    //   1. 客户端 MilestoneItem 的 id 是算出来的（projectId/name），
    //      与这个主键**永远不相等** —— 同一里程碑两个身份，正是本引擎
    //      反复栽的「同一份事实两种理解」；
    //   2. LLM 在 list 结果里看到 id，天然会拿它当句柄传回
    //      milestone_action，而那儿只认 name ⇒ 一次注定失败的调用。
    //
    // ⚠️ 存储侧的 toJson() 仍保留 id（那是持久化主键，删了数据就丢关联），
    //    只有只读出口剥。别「顺手」把它加回来。
    Json.remove(o, "id")

    Json.set(o, "projectName", Json.of(p.name))
    Json.set(o, "status", Json.of(prog.effectiveStatus))
    Json.set(o, "tagName", Json.of(prog.tagName))
    Json.set(o, "tagReached", Json.of(prog.tagReached))
    Json.set(o, "commitsSince", Json.of(prog.commitsSince))
    // commitsSince = -1 是「读不出来」，不是「零个提交」。
    // 与 gitReadable 分开：gitReadable 只反映 rev-parse --git-dir 能不能成，
    // 对象库损坏 / partial clone 时它照样 true，而 rev-list 是失败的 ——
    // 少这一个字段，调用方只能把 -1 当 0 读。
    //
    // ⚠️ 必须**恒发**、不能「只在失败时发」：键出现与否取决于数据，
    // 调用方就得写两套解码分支，那正是 envelope 分歧的来源。
    Json.set(o, "commitsSinceReadable", Json.of(prog.commitsSince >= 0))
    Json.set(o, "daysToTarget", Json.of(prog.daysToTarget))
    Json.set(o, "overdue", Json.of(prog.overdue))
    // git 读不出来时，tagReached / commitsSince 都是「未知」而不是「没有」。
    // 客户端必须能区分这两种，否则会把故障读成「里程碑没达成」。
    Json.set(o, "gitReadable", Json.of(prog.gitReadable))
    // ⚠️ 同样**恒发**：原实现是 `if (!gitReadable) 才加这个键`，
    // 于是降级态的条目比健康态多一个键 ——
    // 实测（客户端契约检查抓出来的）：
    //   健康态：milestone list 17 键 / dashboard 17 键
    //   降级态：milestone list 18 键 / dashboard 17 键（dashboard 侧根本没有）
    // 键集随数据漂移，消费方只能靠「有没有这个键」反推出了故障，
    // 而那层耦合没有任何契约文档。现在恒发：可读时是空串。
    Json.set(o, "unverifiedReason",
             if (prog.gitReadable) {
                 Json.of("")
             } else {
                 Json.of("仓库读不出来（git rev-parse 失败），无法核验该里程碑的 tag 与提交数")
             })
    return o
}

// ------------------------------ 测试 ------------------------------

@Test
func testMilestoneCrud(): Unit {
    // 用临时 HOME 隔离
    let base = "/tmp/deepgit-ms-${nowMillis()}"
    ensureDir(base)
    enterTestHome(base)
    let (m, created) = addMilestone("p_test", "v1.0", "首个版本", "2026-12-01", "v1.0.0")
    @Assert(created)
    @Assert(m.name == "v1.0")
    // 幂等
    let (_, again) = addMilestone("p_test", "v1.0", "重复", "", "")
    @Assert(!again)
    // 列出
    @Assert(milestonesFor("p_test").size == 1)
    // 标记完成
    @Assert(setMilestoneStatus("p_test", "v1.0", "done"))
    let list = milestonesFor("p_test")
    @Assert(list[0].status == "done")
    @Assert(!list[0].completedAt.isEmpty())
    // 删除
    @Assert(removeMilestone("p_test", "v1.0"))
    @Assert(milestonesFor("p_test").size == 0)
    exitTestHome()
    removePathIfExists(base)
}

@Test
func testEpochDays(): Unit {
    // 已知锚点：2026-09-30 与 2026-10-01 相差 1 天
    let a = epochDays("2026-09-30")
    let b = epochDays("2026-10-01")
    @Assert(b - a == 1)
    // 闰年：2024-02-28 → 2024-03-01 相差 2 天
    @Assert(epochDays("2024-03-01") - epochDays("2024-02-28") == 2)
    // 平年：2025-02-28 → 2025-03-01 相差 1 天
    @Assert(epochDays("2025-03-01") - epochDays("2025-02-28") == 1)
    // 与 Unix 锚点对照：1970-01-01 = 0
    @Assert(epochDays("1970-01-01") == 0)
}

@Test
func testDaysFromTodayToleratesDirtyDate(): Unit {
    // 里程碑 targetDate 可以被手改。脏日期原来会让 epochDays 里的 Int64.parse 抛异常，
    // 一路冒泡到 buildDashboard —— 让**所有项目**的仪表盘整体崩溃（stdout 0 字节）。
    // 这里按「未设置目标日期」的既有语义返回 -1。
    @Assert(!isIsoDate("not-a-date"))
    @Assert(!isIsoDate("2026/12/31"))
    @Assert(!isIsoDate("26-12-31xxxx"))
    @Assert(!isIsoDate(""))
    @Assert(!isIsoDate("2026-1"))
    @Assert(isIsoDate("2026-12-31"))
    @Assert(daysFromToday("not-a-date") == -1)
    @Assert(daysFromToday("2026/12/31") == -1)
    @Assert(daysFromToday("") == -1)
    // 合法日期仍要正常计算
    @Assert(daysFromToday("2999-12-31") > 0)
    @Assert(daysFromToday("2000-01-01") < 0)
}

@Test
func testDirtyTargetDateIsNotReportedAsOverdue(): Unit {
    // 日期损坏必须显示成「未知」，不能显示成「已逾期」：
    // 原实现在 targetDate 非空时就算 overdue，脏日期返回 -1 恰好满足 d < 0。
    let m = Milestone("m1", "p1", "脏日期里程碑", "", "not-a-date", "", "open", "2026-01-01T00:00:00+08:00", "")
    let prog = milestoneProgress(m, "", "")
    @Assert(prog.daysToTarget == -1)
    @Assert(!prog.overdue)

    // 合法且已过期的日期仍要正确标记逾期
    let past = Milestone("m2", "p1", "已过期", "", "2000-01-01", "", "open", "2026-01-01T00:00:00+08:00", "")
    @Assert(milestoneProgress(past, "", "").overdue)
}

@Test
func testMilestoneJsonKeySetIsStableAcrossGitReadability(): Unit {
    // 键集**不得随数据变化**。
    //
    // 原实现在 kernel.milestoneJson 里写的是 `if (!gitReadable) 才加 unverifiedReason`，
    // 于是降级态的条目比健康态多一个键。实测三个出口：
    //     健康态：milestone list 17 键 / dashboard 17 键
    //     降级态：milestone list 18 键 / dashboard 17 键（dashboard 压根没这个键）
    // 两层后果：
    //   1. 消费方看见「多了个键」反推出了故障，这层耦合没有任何契约文档；
    //   2. 客户端把该键建成可选时，缺失拿到空串 —— 而空串恰好是
    //      「一切正常」的值，于是**故障被渲染成正常**。
    //
    // 降级态要用「**存在但不是 git 仓库**」的目录，且**不能是** base 的子目录：
    //   1. 空路径不行 —— milestoneProgress 刻意把空路径判成 gitReadable=true
    //      （「没查」≠「查失败」，见该函数第 404 行注释）；
    //   2. 放在 base 里面也不行 —— git 的 rev-parse 会**向上**找 .git，
    //      base/not-a-repo 会命中 base 这个仓库，gitReadable 照样 true。
    // 两条都已各栽过一次，症状都是「unverifiedReason 是空串」。
    // 所以：notRepo 建成 base 的**兄弟**目录，并先断言前提真的成立。
    let base = "/tmp/deepgit-mjkeys-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-q", "-b", "main"], false)
    gitRun(base, ["commit", "--allow-empty", "-q", "-m", "init"], false)
    let notRepo = "${base}-nr"
    ensureDir(notRepo)

    let m = Milestone("m_abc", "p_1", "同名里程碑", "描述", "2027-06-01", "v1.0", "open",
                      "2026-01-01T00:00:00+08:00", "")
    let p = ProjectEntry("p_1", "demo", notRepo, "git", "", "2026-01-01T00:00:00+08:00",
                         ArrayList<String>(), false)

    // 前提自证：两个样本必须真的是「一个查得出、一个查不出」。
    @Assert(milestoneProgress(m, base, "main").gitReadable)
    @Assert(!milestoneProgress(m, notRepo, "").gitReadable)

    let bad = milestoneJson(p, milestoneProgress(m, notRepo, ""))
    let good = milestoneJson(p, milestoneProgress(m, base, "main"))

    let badKeys = match (Json.asObj(bad)) { case Some(m2) => m2; case None => ArrayList<(String, JsonValue)>() }
    let goodKeys = match (Json.asObj(good)) { case Some(m2) => m2; case None => ArrayList<(String, JsonValue)>() }
    @Assert(badKeys.size == goodKeys.size)

    var i = 0
    while (i < badKeys.size) {
        // 元组不能写 badKeys[i].0（@Assert 宏解析不了，实测 parsing expr error），
        // 必须先解构出来。
        let (bk, _) = badKeys[i]
        let (gk, _) = goodKeys[i]
        @Assert(bk == gk)
        i += 1
    }

    // 恒发语义：可读时是空串，不可读时给出原因。两个都不能是「键不存在」。
    @Assert(Json.has(good, "unverifiedReason"))
    @Assert(Json.strAt(good, "unverifiedReason", "\u{0}") == "")
    @Assert(Json.has(bad, "unverifiedReason"))
    @Assert(Json.strAt(bad, "unverifiedReason", "") != "")

    // 降级态的 -1 三态
    @Assert(Json.strAt(bad, "status", "") == "unknown")
    @Assert(Json.intAt(bad, "commitsSince", 0) == -1)
    @Assert(!Json.boolAt(bad, "gitReadable", true))
    @Assert(!Json.boolAt(bad, "commitsSinceReadable", true))

    // 存储主键 id **不得**进只读出口：它是只出不进的（milestone_action 只认
    // project+name），留着只会让客户端的 id 与它永远不相等，并诱使 LLM 拿它当句柄。
    // 存储侧的 toJson() 仍须保留 id，删了数据就丢关联。
    @Assert(!Json.has(bad, "id"))
    @Assert(!Json.has(good, "id"))
    @Assert(Json.strAt(m.toJson(), "id", "") == "m_abc")

    removePathIfExists(base)
    // ⚠️ notRepo 是 base 的**兄弟**（`${base}-nr`），不是它的子目录。
    // 只删 base 管不到它 —— 每轮测试都在 /tmp 留一个。
    removePathIfExists(notRepo)
}

@Test
func testMilestoneProgressWithGit(): Unit {
    let base = "/tmp/deepgit-msg-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    gitRun(base, ["commit", "--allow-empty", "-q", "-m", "init"], false)
    enterTestHome(base + "/home")
    ensureDir(base + "/home")
    let (m, _) = addMilestone("p_git", "v0.1", "", "", "v0.1")
    // 未打 tag：open、tagReached=false
    let p1 = milestoneProgress(m, base, "main")
    @Assert(p1.effectiveStatus == "open")
    @Assert(!p1.tagReached)
    // 打 tag 后自动 done
    gitRun(base, ["tag", "v0.1"], false)
    let p2 = milestoneProgress(m, base, "main")
    @Assert(p2.tagReached)
    @Assert(p2.effectiveStatus == "done")
    exitTestHome()
    removePathIfExists(base)
}

@Test
func testMilestoneOverdue(): Unit {
    let base = "/tmp/deepgit-mso-${nowMillis()}"
    ensureDir(base)
    enterTestHome(base)
    // 过去日期 → 逾期
    let (past, _) = addMilestone("p_od", "old", "", "2026-01-01", "")
    let pp = milestoneProgress(past, "", "main")
    @Assert(pp.overdue)
    @Assert(pp.daysToTarget < 0)
    // 未来日期 → 未逾期
    let (future, _) = addMilestone("p_od", "new", "", "2027-01-01", "")
    let fp = milestoneProgress(future, "", "main")
    @Assert(!fp.overdue)
    @Assert(fp.daysToTarget > 0)
    exitTestHome()
    removePathIfExists(base)
}

@Test
func testMilestoneProgressWithoutRepo(): Unit {
    let base = "/tmp/deepgit-msnr-${nowMillis()}"
    ensureDir(base)
    enterTestHome(base)
    let (m, _) = addMilestone("p_nr", "v3.0", "仅日期", "2027-01-01", "")
    // repoPath 为空：不做 tag 检测与提交统计，但日期计算仍有效
    let prog = milestoneProgress(m, "", "")
    @Assert(!prog.tagReached)
    // ⚠️ 这里是 -1，不是 0。
    //
    // 这条断言原先写的是 `== 0`，而它上面那行注释明明写着「repoPath 为空：
    // 不做 tag 检测与提交统计」—— 既然不做统计，0 就是一个**凭空造出来的结论**
    // （「这个里程碑创建以来一个提交都没有」），而且是测试亲手把它钉死的。
    //
    // 危害还不止于显示：repoPath 为空时旧代码照样把空路径交给 git，
    // 等于「在进程当前工作目录里跑」，于是数字来自一个毫不相干的仓库。
    // 0 会把这个错误掩盖掉 —— 调用方看到 0 根本不会怀疑。
    // -1 = 「没查」，与 daysToTarget 的 -1 同一套约定。
    @Assert(prog.commitsSince == -1)
    // 前置条件：没绑仓库 ≠ 仓库坏了，gitReadable 仍必须是 true
    @Assert(prog.gitReadable)
    @Assert(prog.daysToTarget > 0)
    @Assert(prog.effectiveStatus == "open")
    exitTestHome()
    removePathIfExists(base)
}

@Test
func testMilestoneStatusTransitions(): Unit {
    let base = "/tmp/deepgit-mst-${nowMillis()}"
    ensureDir(base)
    enterTestHome(base)
    addMilestone("p_tr", "m1", "", "", "")
    @Assert(setMilestoneStatus("p_tr", "m1", "dropped"))
    @Assert(milestonesFor("p_tr")[0].status == "dropped")
    @Assert(milestonesFor("p_tr")[0].completedAt.isEmpty())
    @Assert(setMilestoneStatus("p_tr", "m1", "open"))
    @Assert(milestonesFor("p_tr")[0].status == "open")
    // 不存在的里程碑
    @Assert(!setMilestoneStatus("p_tr", "nope", "done"))
    // drop 后再 remove
    @Assert(removeMilestone("p_tr", "m1"))
    @Assert(openMilestoneCount() == 0)
    exitTestHome()
    removePathIfExists(base)
}

@Test
func testEpochDaysMonthBoundaries(): Unit {
    // 月末边界：1月31 → 2月1
    @Assert(epochDays("2026-02-01") - epochDays("2026-01-31") == 1)
    // 年末边界
    @Assert(epochDays("2027-01-01") - epochDays("2026-12-31") == 1)
    // 世纪闰年：2000 年是闰年
    @Assert(epochDays("2000-03-01") - epochDays("2000-02-28") == 2)
    // 已知锚点：2024-01-01 与 Unix 元年相差 19723 天（(19723/365.25)≈54 年 ✓）
    @Assert(epochDays("2024-01-01") == 19723)
}

@Test
func testUnreadableRepoReportsUnknownInsteadOfOpen(): Unit {
    // 回归（P0）：仓库读不出来时，已达成的里程碑静默退回「进行中」，
    // 项目成就数**反向减少** —— 而且恰好发生在最该报警的时刻。
    //
    // 实测（修复前）：里程碑绑定 tag v1.0.0，仓库正常时
    //     status=done  tagReached=true   dashboard counts = {done: 1}
    // 把 .git/objects 移走（模拟卷未挂载 / 索引损坏 / 磁盘满）后，同一个里程碑
    //     status=open  tagReached=false  counts = {open: 1}
    // 且**零告警**。用户看到的是「进度倒退」，真相是「系统坏了」。
    //
    // 根因：守卫用的是 volumeAccessible，它只 `stat <path>`，
    // 而 .git/objects 丢失时目录照样存在、stat 照样成功。
    // 「我们不知道」和「没有达成」是相反的两件事，必须分开。
    let base = "/tmp/deepgit-msunread-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let repo = base + "-repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic(repo + "/a.txt", "a")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: a"], false)
    gitRun(repo, ["tag", "v1.0.0"], false)

    let (m, _) = addMilestone("p_unread", "v1.0", "首个版本", "", "v1.0.0")
    @Assert(!m.status.isEmpty())

    // 仓库正常：tag 达成 → done
    let good = milestoneProgress(m, repo, "main")
    @Assert(good.gitReadable)
    @Assert(good.tagReached)
    @Assert(good.effectiveStatus == "done")

    // 破坏 .git：git 自己报不出 git-dir，但**目录还在**（stat 仍会成功）
    let objects = repo + "/.git/objects"
    let hidden = repo + "/.git/objects.bak"
    gitRun(repo, ["config", "core.bare", "false"], false)
    moveDirForTest(objects, hidden)
    let broken = milestoneProgress(m, repo, "main")
    // ⚠️ 前置条件：volumeAccessible 骗过了我们（这正是原来的 bug）
    @Assert(volumeAccessible(repo))
    @Assert(!broken.gitReadable)
    @Assert(!broken.tagReached)          // 未知 → false（Bool 表达不了未知）
    // 关键断言：不能报「进行中」
    @Assert(broken.effectiveStatus == "unknown")
    @Assert(broken.effectiveStatus != "open")
    @Assert(broken.effectiveStatus != "done")

    // 手工标记为 done 的里程碑不受影响：手工状态本来就比 tag 检测权威。
    // ⚠️ 必须**重新从存储读**：addMilestone 返回的是写入前的快照，
    // setMilestoneStatus 改的是存储里的那一份（这个坑踩过一次）。
    _ = addMilestone("p_unread", "v2.0", "第二个", "", "")
    @Assert(setMilestoneStatus("p_unread", "v2.0", "done"))
    var m2 = m
    for (x in loadMilestones()) {
        if (x.name == "v2.0") {
            m2 = x
        }
    }
    @Assert(m2.status == "done")
    let manual = milestoneProgress(m2, repo, "main")
    @Assert(!manual.gitReadable)
    @Assert(manual.effectiveStatus == "done")

    moveDirForTest(hidden, objects)
    removePathIfExists(repo)
    removePathIfExists(deepgitPath(["milestones.json"]))
    // 复位必须排在所有 deepgitPath(...) 之后
    exitTestHome()
    removePathIfExists(testHome)
    removePathIfExists(base)
}

/// 测试辅助：把目录改名（仓颉 std 的 move 跨 API 差异大，直接走系统 mv）
func moveDirForTest(from: String, to: String): Unit {
    let r = execCapture("mv", [from, to], None, 8000)
    if (!r.ok()) {
        throw DgError("TEST_SETUP", "mv 失败：${from} → ${to}（${r.stderr}）", 1, None)
    }
}

@Test
func testTargetDateValidatesRealCalendar(): Unit {
    // 原来只查 d <= 31，于是 2026-02-31（不存在的日子）、2026-04-31（4 月没 31 号）
    // 全部被当成合法日期存进去，之后再被 clamp 掉。
    // 实测 `milestone add --date 2026-02-31` 存进去、读出来变成 3-3。
    //
    // 里程碑的「还剩多少天」是给人排期用的：凭空多出来的 2 天会直接变成
    // 排期错误，而且**没人知道它是哪来的** —— 存储里躺着一个看似合法的日期。
    @Assert(validTargetDate(""))                    // 空 = 不设目标日期，合法
    @Assert(validTargetDate("2026-01-01"))
    @Assert(validTargetDate("2026-12-31"))

    // 各月最后一天
    @Assert(validTargetDate("2026-01-31"))
    @Assert(!validTargetDate("2026-01-32"))
    @Assert(validTargetDate("2026-04-30"))
    @Assert(!validTargetDate("2026-04-31"))         // 4 月 30 天
    @Assert(!validTargetDate("2026-06-31"))
    @Assert(!validTargetDate("2026-09-31"))
    @Assert(!validTargetDate("2026-11-31"))

    // 2 月随闰年变
    @Assert(validTargetDate("2026-02-28"))          // 2026 不是闰年
    @Assert(!validTargetDate("2026-02-29"))
    @Assert(validTargetDate("2024-02-29"))          // 2024 是闰年
    @Assert(!validTargetDate("2024-02-30"))
    @Assert(validTargetDate("2000-02-29"))          // 400 年一闰
    @Assert(!validTargetDate("1900-02-29"))         // 100 年一闰，1900 不是

    // 原本就该拒的
    @Assert(!validTargetDate("2026-00-10"))
    @Assert(!validTargetDate("2026-13-10"))
    @Assert(!validTargetDate("2026-1-1"))
    @Assert(!validTargetDate("20260101"))
    @Assert(!validTargetDate("2026-01-00"))

    // 收敛点：非法日期必须让 addMilestone 抛错，而不是存进去再 clamp
    var threw = false
    try {
        _ = addMilestone("p_x", "m1", "d", "2026-02-31", "")
    } catch (e: DgError) {
        threw = true
    }
    @Assert(threw)
}

@Test
func testCommitsSinceCountsWholeRepoNotJustCurrentBranch(): Unit {
    // 里程碑「创建以来 N 提交」问的是立项之后这个项目做了多少事，
    // 不是「当前分支长了几根」。
    //
    // 原实现传 `rev-list ... HEAD`，只走当前分支，而同行注释写的是
    // 「不限分支，看整个仓库的活跃量」、字段注释又写「（当前分支）」——
    // 两处注释互相矛盾，实现是唯一不符合用户预期的那个。
    //
    // 危害在**方向**：立项之后大家照常在特性分支上干活，main 一动不动，
    // HEAD 口径就几乎不涨。实测本仓库：HEAD=1、--all=7，
    // 引擎报「创建以来 1 提交」—— 一个已经忙了半年的里程碑看上去毫无动静。
    let home = "/tmp/deepgit-mscope-${nowMillis()}"
    let base = home + "-repo"
    ensureDir(home)
    enterTestHome(home)
    var m = Milestone("m1", "p", "v1.0", "", "2027-01-01", "v1.0.0", "open", "", "")
    try {
        ensureDir(base)
        gitRun(base, ["init", "-b", "main"], false)
        writeFileAtomic(base + "/a.txt", "0\n")
        gitRun(base, ["add", "."], false)
        gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: base"], false)
        // 6 个提交全在特性分支上，main 保持不动
        gitRun(base, ["checkout", "-q", "-b", "feature"], false)
        var i: Int64 = 1
        while (i <= 6) {
            writeFileAtomic(base + "/a.txt", "${i}\n")
            gitRun(base, ["add", "."], false)
            gitRun(base, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: w${i}"], false)
            i += 1
        }
        gitRun(base, ["checkout", "-q", "main"], false)

        // 前提必须自己钉住：HEAD 口径与 --all 口径此刻确实不等
        let headCount = parseIntOr(
            gitTry(base, ["rev-list", "--count", "HEAD"]).stdout.trimAscii(), -1
        )
        let allCount = parseIntOr(
            gitTry(base, ["rev-list", "--count", "--all"]).stdout.trimAscii(), -1
        )
        @Assert(headCount == 1)
        @Assert(allCount == 7)

        // createdAt 用今天的日期（addMilestone 也是这么取的），当天提交都算数
        m = Milestone("m1", "p", "v1.0", "", "2027-01-01", "v1.0.0", "open", "${formatDateOnly(nowIso())}T00:00:00Z", "")
        let prog = milestoneProgress(m, base, "main")
        @Assert(prog.commitsSince == 7)
        @Assert(prog.commitsSince != headCount)
    } finally {
        exitTestHome()
        removePathIfExists(base)
        removePathIfExists(home)
    }
}

@Test
func testCommitsSinceIsUnknownNotZeroWhenNotQueryable(): Unit {
    // 「没查」和「查出来是 0」是两件相反的事，必须分开表达。
    //
    // 原实现在这些情况下都让 commitsSince 停在 0，而 0 是个**结论**：
    //     没有绑仓库（repoPath 为空）      ← 极其常见，非 git 项目 / dashboard 传空
    //     createdAt 为空或长度不足 10      ← 手写 milestones.json 时很常见
    //     rev-list 失败                    ← 对象库损坏 / partial clone（本地未能复现，防御性）
    //
    // 用户看到的是「创建以来 0 提交」—— 一个凭空造出来的数字，
    // 而真实含义是「我们不知道」。
    let home = "/tmp/deepgit-msunk-${nowMillis()}"
    ensureDir(home)
    enterTestHome(home)
    try {
        // 场景一：没绑仓库 —— gitReadable 仍是 true（没查 ≠ 查失败）
        let noRepo = Milestone("m1", "p", "v1.0", "", "2027-01-01", "", "open", "${formatDateOnly(nowIso())}T00:00:00Z", "")
        let a = milestoneProgress(noRepo, "", "")
        @Assert(a.commitsSince == -1)
        // 前置条件核对：没绑仓库时 gitReadable 必须是 true（没查 ≠ 查失败）
        @Assert(a.gitReadable)

        // 场景二：createdAt 太短，取不出日期 —— 「没查」而不是「0 个提交」
        let shortDate = Milestone("m2", "p", "v2.0", "", "2027-01-01", "", "open", "2026", "")
        let b = milestoneProgress(shortDate, "", "")
        @Assert(b.commitsSince == -1)

        // 场景三：createdAt 为空
        let noDate = Milestone("m3", "p", "v3.0", "", "2027-01-01", "", "open", "", "")
        let c = milestoneProgress(noDate, "", "")
        @Assert(c.commitsSince == -1)

        // 关键：真的 0 个提交仍然必须报 0，不能被 -1 吞掉
        // 用一个**零提交**的仓库：rev-list --count --all 在这种仓库上
        // 正常返回 "0"（rc=0），所以 0 确实是查出来的结论，不是无知。
        let emptyRepo = home + "-empty"
        ensureDir(emptyRepo)
        gitRun(emptyRepo, ["init", "-b", "main"], false)
        let real = Milestone("m4", "p", "v4.0", "", "2027-01-01", "", "open", "${formatDateOnly(nowIso())}T00:00:00Z", "")
        let d = milestoneProgress(real, emptyRepo, "main")
        @Assert(d.commitsSince == 0)      // 真的是 0，不是「不知道」
        removePathIfExists(emptyRepo)
    } finally {
        exitTestHome()
        removePathIfExists(home)
    }
}

/// K2 回归：手改 milestones.json 的 createdAt 不许让出口全灭。
///
/// 原实现只查「非空且长度 ≥ 10」就裸切 `m.createdAt[..10]` ——
/// 仓颉字符串按**字节**索引，「2026年1月1日」的第 10 个字节正好落在
/// 「月」这个 UTF-8 序列中间，`Invalid utf8 byte sequence` 一路冒泡，
/// milestone list / dashboard / milestone done 三条出口全部崩掉。
/// 同文件的 targetDate 早就由 isIsoDate 把住（#180 判例），createdAt 漏了同一道闸门。
///
/// 测试走**真实路径**：真 git 仓库（切片那一行只在 gitReadable && isRepoRoot
/// 时执行）+ 手写 milestones.json + loadMilestones + milestoneProgress。
@Test
func testMilestoneProgressSurvivesNonIsoCreatedAtFromStore(): Unit {
    let base = "/tmp/deepgit-msutf8-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let repo = base + "-repo"
    try {
        ensureDir(repo)
        gitRun(repo, ["init", "-b", "main"], false)
        writeFileAtomic(repo + "/a.txt", "a\n")
        gitRun(repo, ["add", "."], false)
        gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "feat: a"], false)

        // 前提必须自己钉住（不变量 18/22 的纪律）：
        // 合法 createdAt 在这个仓库上确实查得出来 —— 否则「没炸」
        // 可能只是压根没走到切片那一行（repo 不是根 / git 不可读）。
        _ = addMilestone("p_utf8", "clean", "对照", "", "")
        var clean = Milestone("x", "p_utf8", "clean", "", "2027-01-01", "", "open", "", "")
        for (x in loadMilestones()) {
            if (x.name == "clean") {
                clean = x
            }
        }
        @Assert(!clean.createdAt.isEmpty())          // 写路径确实给了 createdAt
        let sanity = milestoneProgress(clean, repo, "main")
        @Assert(sanity.gitReadable)
        @Assert(sanity.commitsSince >= 0)            // 合法日期：这条分支真的会切 [..10]

        // 手改 milestones.json：中文日期与全角数字 ——
        // 两者的第 10 个字节都落在多字节 UTF-8 序列中间
        writeFileAtomic(deepgitPath(["milestones.json"]),
            "{\"milestones\":[" +
            "{\"id\":\"m1\",\"projectId\":\"p_utf8\",\"name\":\"cn\",\"description\":\"\"," +
            "\"targetDate\":\"2027-01-01\",\"tag\":\"\",\"status\":\"open\"," +
            "\"createdAt\":\"2026年1月1日\",\"completedAt\":\"\"}," +
            "{\"id\":\"m2\",\"projectId\":\"p_utf8\",\"name\":\"fullwidth\",\"description\":\"\"," +
            "\"targetDate\":\"2027-01-01\",\"tag\":\"\",\"status\":\"open\"," +
            "\"createdAt\":\"２０２６－０１－０１\",\"completedAt\":\"\"}" +
            "],\"updatedAt\":\"2026-01-01T00:00:00Z\"}")

        // 真实读路径：loadMilestones → milestoneProgress。
        // 修复前 String 构造在 [..10] 处直接抛 Invalid utf8，测试走不到任何断言。
        var seen = 0
        for (m in loadMilestones()) {
            let p = milestoneProgress(m, repo, "main")
            @Assert(p.commitsSince == -1)   // 「没查」，不是「查了是 0」
            @Assert(p.gitReadable)          // 日期脏 ≠ 仓库坏，两个事实分开
            seen += 1
        }
        @Assert(seen == 2)
    } finally {
        exitTestHome()
        removePathIfExists(repo)
        removePathIfExists(testHome)
    }
}

/// #180 回归：不存在的日期不许被换算成可信的天数。
///
/// 负控（曾真实发红）：`isIsoDate` 只验「10 位 + 数字 + 横杠」，
/// 于是 2026-02-31 / 2026-13-01 / 2026-01-32 全被放行，
/// 再被 `epochDays` 的 clamp 换算成一个合法纪元日：
///   「vX · ⚠ 已逾期 · 目标 2026-02-31（逾期 212 天）」
///   「vX · 进行中 · 目标 2026-13-01（还剩 61 天）」
/// 而写入闸门 `milestone add --date 2026-02-31` 当时就拒收这个日期。
@Test
func testIsoDateRejectsDatesThatDoNotExist(): Unit {
    // 格式合法但日历上不存在
    let impossible = [
        "2026-02-31", "2026-04-31", "2026-06-31", "2026-09-31", "2026-11-31",
        "2026-01-32", "2026-01-00", "2026-13-01", "2026-00-10", "2027-02-30",
    ]
    for (d in impossible) {
        @Assert(!isIsoDate(d))
    }
    // 闰年边界：2024 是闰年，2026 不是
    @Assert(isIsoDate("2024-02-29"))
    @Assert(!isIsoDate("2026-02-29"))
    @Assert(!isIsoDate("2100-02-29"))   // 2100 不是闰年（能被 100 整除但不能被 400 整除）
    @Assert(isIsoDate("2000-02-29"))    // 2000 是闰年
    // 真实存在的日子仍然通过（别把闸门收得过紧）
    for (d in ["2026-01-01", "2026-12-31", "2026-02-28", "2026-04-30"]) {
        @Assert(isIsoDate(d))
    }
    // 既有格式判据不能被放松
    @Assert(!isIsoDate("not-a-date"))
    @Assert(!isIsoDate("2026/12/31"))
    @Assert(!isIsoDate("2026-1"))
    @Assert(!isIsoDate(""))
}

/// 写入闸门与读取判据必须给出**同一个答案**（单一判据构造点）。
///
/// 负控（曾真实发红）：`validTargetDate` 按真实月长判、`isIsoDate` 只判格式，
/// 于是同一个日期「能不能存」和「算不算日期」在两半里答案相反。
@Test
func testWriteGateAndReadGuardAgreeOnExistence(): Unit {
    let cases = ["2026-02-31", "2026-13-01", "2026-04-31", "2026-01-32"]
    for (d in cases) {
        @Assert(!validTargetDate(d))
        @Assert(!isIsoDate(d))
    }
    for (d in ["2026-02-28", "2024-02-29", "2026-12-31"]) {
        @Assert(validTargetDate(d))
        @Assert(isIsoDate(d))
    }
}

/// 非法日期不得产生任何天数（-1 = 未设置 / 不可信）。
@Test
func testDaysFromTodayIsMinusOneForImpossibleDates(): Unit {
    @Assert(daysFromToday("2026-02-31") == -1)
    @Assert(daysFromToday("2026-13-01") == -1)
    @Assert(daysFromToday("2026-01-32") == -1)
    @Assert(daysFromToday("not-a-date") == -1)
    // 真实日期仍要给出天数
    @Assert(daysFromToday(nowIso()[..10]) == 0)
}

/// #183 回归：嵌在别人仓库里的目录不得借用外层仓库的提交数。
///
/// 负控（曾真实发红）：闸门只判「路径非空」，而 `git rev-parse` 会一路往上找，
/// 于是 registry 里一个 `kind:"dir"` 的 innerdir（路径 `/…/outer/inner`）
/// 里程碑打出「创建以来 2 提交」—— 那是 outer 的提交，与 innerdir 无关。
/// 用户在自己一个非 git 目录的里程碑上看到「有 2 个提交」，会去查根本查不到。
///
/// 判据必须是 `<path>/.git` 存在（该目录自身是仓库根），不是 `rev-parse`。
@Test
func testNestedDirectoryDoesNotBorrowOuterRepoCommits(): Unit {
    let outer = "/tmp/dg_nest-${nowMillis()}"
    let inner = "${outer}/inner"
    ensureDir(inner)
    gitRun(outer, ["init", "-b", "main"], false)
    writeFileAtomic("${outer}/a.txt", "a")
    gitRun(outer, ["-c", "user.name=t", "-c", "user.email=t@t", "add", "."], false)
    gitRun(outer, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "i"], false)
    writeFileAtomic("${outer}/b.txt", "b")
    gitRun(outer, ["-c", "user.name=t", "-c", "user.email=t@t", "add", "."], false)
    gitRun(outer, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "i2"], false)

    // 外层是真仓库 → 它的里程碑必须照常拿到提交数
    let mOuter = Milestone("m1", "p", "v9", "", "", "v9", "open", "2026-01-01T00:00:00+08:00", "")
    let progOuter = milestoneProgress(mOuter, outer, "main")
    @Assert(progOuter.commitsSince >= 0)

    // 内层只是嵌在外层里的普通目录 → 必须「查不到」，不能借外层的数
    let mInner = Milestone("m2", "p", "v1", "", "", "v1", "open", "2026-01-01T00:00:00+08:00", "")
    let progInner = milestoneProgress(mInner, inner, "main")
    @Assert(progInner.commitsSince == -1)
    // 且不能被谎报成「0 个提交」——0 是一个结论
    @Assert(progInner.commitsSince != 0)

    // 完全不在任何仓库里的普通目录，同样是 -1
    let lonely = "${outer}/../dg_nest_lonely_${nowMillis()}"
    ensureDir(lonely)
    let progLonely = milestoneProgress(mInner, lonely, "main")
    @Assert(progLonely.commitsSince == -1)
    removePathIfExists(lonely)

    removePathIfExists(outer)
}
