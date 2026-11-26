// 日志与终端输出：人类可读信息进 stderr，数据进 stdout。
package cambium.util

import std.collection.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*

public class Log {
    static var quiet: Bool = false
    static var verbose: Bool = false
    static var useColor: Bool = true

    public static func setQuiet(q: Bool): Unit {
        Log.quiet = q
    }

    public static func setVerbose(v: Bool): Unit {
        Log.verbose = v
    }

    public static func setColor(c: Bool): Unit {
        Log.useColor = c
    }

    public static func isVerbose(): Bool {
        return Log.verbose
    }

    static func paint(code: String, s: String): String {
        if (!Log.useColor) {
            return s
        }
        return "\u{1b}[${code}m${s}\u{1b}[0m"
    }

    /// stderr 出口。生产路径就是 eprintln，拆出来只为让「告警到底有没有
    /// 被 --quiet 吞掉」这类问题可被断言 —— 这个类的全部价值就是
    /// 「什么时候出声」，而出声与否此前无法在测试里观察。
    static var errOut: (String) -> Unit = { s => eprintln(s) }

    /// 替换 stderr 出口（仅测试用）。用完请调 resetErrOut。
    public static func setErrOut(f: (String) -> Unit): Unit {
        Log.errOut = f
    }

    public static func resetErrOut(): Unit {
        Log.errOut = { s => eprintln(s) }
    }

    public static func info(msg: String): Unit {
        if (!Log.quiet) {
            Log.errOut(msg)
        }
    }

    public static func step(msg: String): Unit {
        if (!Log.quiet) {
            Log.errOut(paint("36", "›") + " " + msg)
        }
    }

    public static func ok(msg: String): Unit {
        if (!Log.quiet) {
            Log.errOut(paint("32", "✓") + " " + msg)
        }
    }

    // ⚠️ warn 刻意**不受** --quiet 门控。
    //
    // 全仓 17 处 Log.warn 逐条看过，没有一处是进度旁白：
    // 子进程超时 / 扫描被截断 / N 行进度日志无法解析 / 备份目录读不到、
    // 暂无可校验的文档 / N 份文档无法判定 / 不是 git 仓库 /
    // config.json 解析失败回退默认 / 非回环监听（无鉴权）……
    // 全是「你的数据或环境出问题了」。而 info/step/ok/dim/debug
    // 才是叙述层，`--quiet` 正是为它们准备的。
    //
    // 原来这里跟着 quiet 走，后果不是「日志安静」而是**告警消失**：
    //   1) 引擎自己的 post-commit 钩子跑的是 `track --quiet`
    //      （kernel/hooks.cj），用户从没要求过静默 —— 是引擎替他决定的。
    //      于是钩子每次提交报出的数据丢失告警，条条被吞。
    //   2) 用户在脚本里 `cambium update -q` 时，脚本能拿到非 0 退出码，
    //      却永远看不到「有 N 行进度日志无法解析，已跳过」。
    // 方向也反了：--quiet 的语义是「少给我念叨」，不是「别告诉我数据坏了」。
    public static func warn(msg: String): Unit {
        Log.errOut(paint("33", "!") + " " + msg)
    }

    public static func error(msg: String): Unit {
        Log.errOut(paint("31", "✗") + " " + msg)
    }

    public static func debug(msg: String): Unit {
        if (Log.verbose && !Log.quiet) {
            Log.errOut(paint("90", "·") + " " + msg)
        }
    }

    public static func dim(msg: String): Unit {
        if (!Log.quiet) {
            Log.errOut(paint("90", msg))
        }
    }
}

/// 打印数据（stdout）
public func printOut(line: String): Unit {
    println(line)
}

/// 多项目 `--json` 的统一出口形状：**只打印一份文档**。
///
/// 单项目时原样打印那一个值（与旧版字节一致，单项目调用方不用改），
/// 多项目时打印一个 envelope。**纯函数**。
///
/// ⚠️ 旧实现在项目循环里逐个 `printOut`，于是 N 个项目吐出 N 份首尾相接的
/// JSON 文档 —— 整份 stdout 非法，**任何** JSONDecoder 都解不出来。
/// 而这恰恰发生在「用户要跨项目批处理」的场景下：单项目能解析，
/// 一旦传两个项目就全线崩，症状是「偶发」。
///
/// cmdUpdate / cmdJournal 已经这样修过，cmdGit / cmdTrack / cmdHook 漏了。
/// 收敛成函数而不是各自照抄：这一族已经栽到第 7 例，
/// 「同一份形状约定抄多处，漏一处就破」是本引擎最顽固的结构性缺陷。
///
/// 字符串构造与打印**刻意分成两个函数**：判定抽成可测的纯函数，
/// 否则内联在循环里改错了不会有任何测试变红（本轮已踩过两次）。
///
/// ⚠️ 形状：单项目仍是**裸结果对象**，与 HTTP 的单项目分支一致；
/// 多项目 / 零个走 `{entries, count, failed}`。
/// 恒定 envelope 的话单项目调用方还得剥一层，没必要的负担。
public func multiProjectJson(results: ArrayList<JsonValue>): String {
    if (results.size == 1) {
        return Json.pretty(results[0])
    }
    let o = Json.obj()
    Json.set(o, "results", JArr(results))
    Json.set(o, "count", Json.of(results.size))
    // 失败数必须写出来，不能只靠调用方逐条 isErrorResult 扫 ——
    // 那是消费方必须重复实现的同一份判定，漏一处就静默把失败读成成功。
    var failed: Int64 = 0
    for (r in results) {
        if (hasErrorOrCode(r)) {
            failed += 1
        }
    }
    Json.set(o, "failed", Json.of(failed))
    Json.set(o, "succeeded", Json.of(results.size - failed))
    // 零个目标时 results 是空数组，**不是**空 stdout ——
    // 空串会让客户端 JSONDecoder 直接失败，而「没有项目」是合法答案。
    return Json.pretty(o)
}

/// 「这个结果对象是不是失败的」。
///
/// 判据用「有没有 code/error」而不是「ok 是不是 false」—— 后者要求每个
/// 产出函数永远同步维护 ok 字段，漏一个就静默变成成功。
/// 错误桩有三种形状（chainError 带 code+message / errorStatusJson 带 error /
/// 成功态两个都没有），只看其中一种就会漏判。
public func hasErrorOrCode(j: JsonValue): Bool {
    if (Json.has(j, "ok")) {
        return false
    }
    return Json.has(j, "code") || Json.has(j, "error")
}

public func printMultiProjectJson(results: ArrayList<JsonValue>): Unit {
    printOut(multiProjectJson(results))
}

/// 对齐表格渲染
public func renderTable(headers: Array<String>, rows: Array<Array<String>>): String {
    let colCount = headers.size
    let widths = Array<Int64>(colCount, repeat: 0)
    for (i in 0..colCount) {
        widths[i] = displayWidth(headers[i])
    }
    for (row in rows) {
        for (i in 0..colCount) {
            if (i < row.size) {
                let w = displayWidth(row[i])
                if (w > widths[i]) {
                    widths[i] = w
                }
            }
        }
    }
    let sb = StringBuilder()
    // header
    for (i in 0..colCount) {
        sb.append(padTo(headers[i], widths[i]))
        if (i < colCount - 1) {
            sb.append("  ")
        }
    }
    sb.append("\n")
    // separator
    for (i in 0..colCount) {
        for (_ in 0..widths[i]) {
            sb.append("─")
        }
        if (i < colCount - 1) {
            sb.append("  ")
        }
    }
    sb.append("\n")
    for (row in rows) {
        for (i in 0..colCount) {
            let cell = if (i < row.size) { row[i] } else { "" }
            sb.append(padTo(cell, widths[i]))
            if (i < colCount - 1) {
                sb.append("  ")
            }
        }
        sb.append("\n")
    }
    return sb.toString().trimAsciiEnd()
}

func padTo(s: String, width: Int64): String {
    let w = displayWidth(s)
    if (w >= width) {
        return s
    }
    let sb = StringBuilder(s)
    for (_ in 0..(width - w)) {
        sb.append(" ")
    }
    return sb.toString()
}

public func formatBytes(n: Int64): String {
    if (n < 0) {
        return "-"
    }
    var v = Float64(n)
    let units = ["B", "KB", "MB", "GB"]
    var i = 0
    while (v >= 1024.0 && i < 3) {
        v = v / 1024.0
        i += 1
    }
    if (i == 0) {
        return "${n}B"
    }
    return "${Int64(v * 10.0) / 10}.${Int64(v * 10.0) % 10}${units[i]}"
}

// ------------------------------ 测试 ------------------------------

// 行为级回归：--quiet 到底该关掉什么。
//
// 原来的 Log.warn 跟着 quiet 走，后果是**告警消失**而非日志安静。
// 全仓 17 处 Log.warn 逐条看过，没有一处是进度旁白，全是
// 「扫描被截断」「N 行进度日志无法解析」「config.json 解析失败回退默认」
// 「非回环监听且无鉴权」这类数据/环境问题。
//
// 最要命的一层：引擎自己的 post-commit 钩子跑的就是 `track --quiet`
// （kernel/hooks.cj），**用户从没要求过静默** —— 是引擎替他决定的。
// 于是钩子每次提交报出的数据丢失告警，条条被吞。
//
// 方向也反了：--quiet 的语义是「少给我念叨」，不是「别告诉我数据坏了」。
// 叙述层（info/step/ok/dim/debug）才是它该管的。
@Test
func testQuietSuppressesNarrationButNeverWarnings(): Unit {
    let seen = ArrayList<String>()
    Log.setErrOut({ s => seen.add(s) })
    Log.setColor(false)
    // 先在非 quiet 下各喊一次，确认每个方法都会用这个出口发声 ——
    // 前提不成立的话，下面「quiet 下也发声」是空转绿。
    Log.setQuiet(false)
    Log.info("PROBE-INFO")
    Log.step("PROBE-STEP")
    Log.ok("PROBE-OK")
    Log.dim("PROBE-DIM")
    Log.warn("PROBE-WARN")
    Log.error("PROBE-ERROR")
    @Assert(seen.size == 6)                       // 前提：6 条都真的出了声

    // 现在打开 quiet
    seen.clear()
    Log.setQuiet(true)
    Log.info("QUIET-INFO")
    Log.step("QUIET-STEP")
    Log.ok("QUIET-OK")
    Log.dim("QUIET-DIM")
    Log.debug("QUIET-DEBUG")
    // 关键断言：告警与错误必须仍然出声
    Log.warn("QUIET-WARN")
    Log.error("QUIET-ERROR")

    let got = StringBuilder()
    for (s in seen) {
        got.append(s)
        got.append("\n")
    }
    let out = got.toString()
    // 叙述层被关掉
    @Assert(!out.contains("QUIET-INFO"))
    @Assert(!out.contains("QUIET-STEP"))
    @Assert(!out.contains("QUIET-OK"))
    @Assert(!out.contains("QUIET-DIM"))
    @Assert(!out.contains("QUIET-DEBUG"))
    // 告警与错误**不受** --quiet 影响
    @Assert(out.contains("QUIET-WARN"))
    @Assert(out.contains("QUIET-ERROR"))
    // 且带上了 ! / ✗ 前缀，脚本按前缀分流时仍能识别
    @Assert(out.contains("! QUIET-WARN"))
    @Assert(out.contains("✗ QUIET-ERROR"))

    Log.setQuiet(false)
    Log.setColor(true)
    Log.resetErrOut()
}

// 负控锚点：把 Log.warn 改回 `if (!Log.quiet) { ... }` 时，
// 上面那条的 @Assert(out.contains("QUIET-WARN")) 必须红。
// 这里显式声明这条约定，避免后人「顺手给 warn 也加个 quiet 判断」。

@Test
func testRenderTableAlignsByWidth(): Unit {
    let t = renderTable(["a", "名字"], [["1", "中文"], ["22", "x"]])
    @Assert(t.contains("a"))
    @Assert(t.contains("名字"))
    @Assert(t.contains("中文"))
}

@Test
func testRenderTableEmptyRows(): Unit {
    let t = renderTable(["h"], [])
    @Assert(t.contains("h"))
}

@Test
func testMultiProjectJsonEmitsExactlyOneParsableDocument(): Unit {
    // 多项目 --json 的核心不变量：**整份 stdout 必须是且只能是一份 JSON 文档**。
    // 旧实现在项目循环里逐个 printOut，于是 N 个项目吐出 N 份首尾相接的文档，
    // 任何 JSONDecoder 都解不出来 —— 而单项目完全正常，症状是「偶发」，
    // 最难查的就是这种「加个参数就崩」。
    //
    // ⚠️ 方向 2/3 的形状在 2026-10-01 改过：多项目与零目标从**裸数组**改成了
    // `{results, count, succeeded, failed}` envelope。加失败数是因为
    // 「哪些失败了」原本要消费方自己逐条 hasErrorOrCode 扫一遍 ——
    // 那是同一份判定的第 N 份拷贝，漏一处就静默把失败读成成功。
    // 零目标那条尤其重要：裸 `[]` 与「stdout 是空串」在很多解析器里都难区分，
    // 而 envelope 的 `results: []` + `count: 0` 是自解释的。
    let one = Json.obj()
    Json.set(one, "project", Json.of("alpha"))
    let two = Json.obj()
    Json.set(two, "project", Json.of("beta"))
    let three = Json.obj()
    Json.set(three, "project", Json.of("gamma"))

    let oneList = ArrayList<JsonValue>()
    oneList.add(one)
    let threeList = ArrayList<JsonValue>()
    threeList.add(one)
    threeList.add(two)
    threeList.add(three)

    // 方向 1：单项目保持裸对象（单项目调用方不用剥一层）
    let parsed1 = Json.parse(multiProjectJson(oneList))
    @Assert(parsed1.isSome())                     // 前提：必须是一份合法文档
    @Assert(Json.strAt(parsed1.getOrThrow(), "project", "") == "alpha")

    // 方向 2：多项目必须是一份可解析的 envelope，且每条的归属项目不能丢
    let s3 = multiProjectJson(threeList)
    let parsed3 = Json.parse(s3)
    @Assert(parsed3.isSome())                     // ← 负控：旧形态下这里必然 None
    let env = parsed3.getOrThrow()
    let arr = match (Json.getOr(env, "results")) {
        case JArr(a) => a
        case _ => ArrayList<JsonValue>()
    }
    @Assert(arr.size == 3)
    @Assert(Json.strAt(arr[0], "project", "") == "alpha")
    @Assert(Json.strAt(arr[1], "project", "") == "beta")
    @Assert(Json.strAt(arr[2], "project", "") == "gamma")
    @Assert(Json.intAt(env, "count", -1) == 3)
    // 全成功时 failed 必须是 0（不是「没有这个键」也不是 -1）
    @Assert(Json.intAt(env, "succeeded", -1) == 3)
    @Assert(Json.intAt(env, "failed", -1) == 0)

    // 整份输出必须以 { 开头、} 结尾 —— 拼 3 份文档的旧形态会在这里露馅
    @Assert(s3.trimAscii().startsWith("{"))
    @Assert(s3.trimAscii().endsWith("}"))

    // 方向 3：零个目标必须输出 envelope 而不是空 stdout ——
    // 空串会让客户端 JSONDecoder 直接失败，而「没有项目」是合法答案。
    let empty = multiProjectJson(ArrayList<JsonValue>())
    @Assert(!empty.trimAscii().isEmpty())
    let emptyEnv = Json.parse(empty)
    @Assert(emptyEnv.isSome())
    @Assert(Json.intAt(emptyEnv.getOrThrow(), "count", -1) == 0)
    @Assert(Json.arrAt(emptyEnv.getOrThrow(), "results").size == 0)

    // 失败数必须真的被算出来 —— 否则上面那个 failed:0 只是「全都成功」这一种情况。
    // 两种失败形状都要认：chainError 的 {code} 与错误桩的 {error}。
    let okOne = Json.obj()
    Json.set(okOne, "project", Json.of("ok"))
    let failCode = DgError("VOLUME_BLOCKED", "路径不存在").toJson()
    let failError = Json.obj()
    Json.set(failError, "error", Json.of("路径不存在或卷未挂载：/gone"))
    let mixed = ArrayList<JsonValue>()
    mixed.add(okOne)
    mixed.add(failCode)
    mixed.add(failError)
    let mEnv = Json.parse(multiProjectJson(mixed)).getOrThrow()
    @Assert(Json.intAt(mEnv, "count", -1) == 3)
    @Assert(Json.intAt(mEnv, "failed", -1) == 2)
    @Assert(Json.intAt(mEnv, "succeeded", -1) == 1)
    // 恒等式：成功数 + 失败数 == 总数
    @Assert(Json.intAt(mEnv, "succeeded", 0) + Json.intAt(mEnv, "failed", 0) == Json.intAt(mEnv, "count", -1))
}

@Test
func testFormatBytes(): Unit {
    @Assert(formatBytes(512) == "512B")
    @Assert(formatBytes(2048).contains("KB"))
    @Assert(formatBytes(-1) == "-")
}

@Test
func testDisplayWidthPadToCJK(): Unit {
    @Assert(displayWidth(padTo("中", 4)) == 4)
    @Assert(displayWidth(padTo("abcd", 4)) == 4)
}
