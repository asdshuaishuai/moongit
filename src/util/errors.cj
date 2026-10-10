// 统一错误类型与结果封装。
package moongit.util

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/// 内部错误消息的组装。**只补确定的信息，不猜成因。**
///
/// 原来顶层直接 `内部错误：${e.message}`。而仓颉运行时对原生调用失败给的消息
/// 是固定一句 `Native function error.` —— 不点名路径、不说哪一步失败、
/// 不区分是权限不足还是路径已消失。实测 `scan /` 与 `scan /private/var/db`
/// 都只吐这一句，用户既不知道该重试、该改路径，还是该报 bug。
///
/// 这里补两样**确定**的东西：
///   1. 正在跑哪条命令（`argv[0]` 是事实，不是推断）
///   2. 完整信息在 `--verbose` 里（这是真的，且是唯一的定位入口）
///
/// ⚠️ 刻意**不**加「可能是权限问题」这类猜测：没有证据的话术比没有话术更糟，
/// 它会把用户引向错误的排查方向。**「不知道成因」就说不知道。**
public func internalErrorMessage(cmd: String, raw: String): String {
    let head = pickText(if (cmd.isEmpty()) { "Internal error" } else { "Internal error (${cmd})" },
        if (cmd.isEmpty()) { "内部错误" } else { "内部错误（${cmd}）" })
    if (raw.isEmpty()) {
        return pickText("${head}: no message captured (run with --verbose for details)",
            "${head}：未捕获到错误信息（加 --verbose 看完整信息）")
    }
    return pickText("${head}: ${raw} (run with --verbose for details)",
        "${head}：${raw}（加 --verbose 看完整信息）")
}

/// 命令名（`argv` 的第一个非选项参数）。取不到就返回空串。
public func failingCommandName(argv: ArrayList<String>): String {
    for (a in argv) {
        if (a.startsWith("-")) {
            continue
        }
        if (a == "--help" || a == "-h" || a == "--version" || a == "-V") {
            continue
        }
        return a
    }
    return ""
}

public class DgError <: Exception {
    public let code: String
    public let msgText: String
    public let exitCode: Int64
    public let details: Option<String>

    public init(code: String, message: String) {
        super(message)
        this.code = code
        this.msgText = message
        this.exitCode = 1
        this.details = None
    }

    public init(code: String, message: String, exitCode: Int64, details: Option<String>) {
        super(message)
        this.code = code
        this.msgText = message
        this.exitCode = exitCode
        this.details = details
    }

    public static func usage(message: String): DgError {
        return DgError("USAGE", message, 2, None)
    }

    public static func notFound(message: String): DgError {
        return DgError("NOT_FOUND", message, 1, None)
    }

    public static func git(message: String): DgError {
        return DgError("GIT_FAILED", message, 1, None)
    }

    public func withDetails(d: String): DgError {
        return DgError(this.code, this.msgText, this.exitCode, Some(d))
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "code", Json.of(this.code))
        Json.set(o, "message", Json.of(this.msgText))
        match (this.details) {
            case Some(d) => Json.set(o, "details", Json.of(d))
            case None => ()
        }
        return o
    }

    public override func toString(): String {
        return "[${this.code}] ${this.msgText}"
    }
}

/// 在上下文失败信息中包装底层错误，保留原始 code。
public func chainError(context: String, e: Exception): DgError {
    match (e as DgError) {
        case Some(de) =>
            return DgError(de.code, "${context}：${de.msgText}", de.exitCode, de.details)
        case None =>
            return DgError("UNEXPECTED", "${context}：${e.message}", 1, None)
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testErrorJson(): Unit {
    let e = DgError("X", "boom").withDetails("d")
    let j = e.toJson()
    @Assert(Json.strAt(j, "code", "") == "X")
    @Assert(Json.strAt(j, "details", "") == "d")
    @Assert(Json.strAt(j, "message", "") == "boom")
}

@Test
func testErrorExitCodes(): Unit {
    @Assert(DgError.usage("u").exitCode == 2)
    @Assert(DgError.notFound("n").exitCode == 1)
}

@Test
func testChainError(): Unit {
    let inner = DgError("INNER", "cause")
    let wrapped = chainError("while doing x", inner)
    @Assert(wrapped.code == "INNER")
    @Assert(wrapped.msgText.contains("while doing x"))
    @Assert(wrapped.msgText.contains("cause"))
}

@Test
func testChainErrorNonDg(): Unit {
    let plain = Exception("plain failure")
    let wrapped = chainError("ctx", plain)
    @Assert(wrapped.code == "UNEXPECTED")
    @Assert(wrapped.msgText.contains("plain failure"))
}

/// 机器可读的失败 JSON：{error:true, code, message}。
///
/// 从 cli/http.cj 迁到这里 —— HTTP 服务端已按「传输层只在本机进程之间通信、
/// 不要 HTTP」的要求整体删除，但 CLI 的 `milestone done/drop` 在目标不存在时
/// 仍然用它输出失败（cli.cj 的 milestone 动作分支）。
///
/// 形状不变：error 键是布尔 true（不是字符串），消费方据此识别失败。
/// 与 hasErrorOrCode 配套 —— 那个函数认的就是 {error} 与 {code} 两种形状。
public func errJson(code: String, message: String): JsonValue {
    let o = Json.obj()
    Json.set(o, "error", Json.of(true))
    Json.set(o, "code", Json.of(code))
    Json.set(o, "message", Json.of(message))
    return o
}

// ------------------------------ #199：崩溃消息必须能定位 ------------------------------

/// 顶层错误消息不允许只有一句运行时原文。
///
/// 原来 `内部错误：${e.message}`，而仓颉对原生调用失败给的是固定的
/// `Native function error.` —— 不点名路径、不说哪一步失败。
/// 现在必须带上**正在跑哪条命令**（argv[0] 是事实）与定位入口。
@Test
func testInternalErrorMessageNamesTheCommand(): Unit {
    let raw = "Native function error."
    let m = internalErrorMessage("scan", raw)
    @Assert(m.contains("scan"))
    @Assert(m.contains(raw))
    // 必须指向唯一能定位的地方
    @Assert(m.contains("--verbose"))
    // 命令名取不到时不能编一个出来
    let none = internalErrorMessage("", raw)
    @Assert(none.contains(raw))
    @Assert(!none.contains("（）"))
    // 错误信息本身为空时也不能输出一个空的「内部错误：」
    @Assert(!internalErrorMessage("scan", "").endsWith("："))
}

/// 从 argv 里取「正在跑哪条命令」：跳过选项，跳过 help/version。
@Test
func testFailingCommandNameSkipsFlagsAndMetaCommands(): Unit {
    @Assert(failingCommandName(ArrayList<String>(["scan", "/x"])) == "scan")
    @Assert(failingCommandName(ArrayList<String>(["--json", "status"])) == "status")
    @Assert(failingCommandName(ArrayList<String>(["-v", "--verbose", "deep", "repo"])) == "deep")
    // 没有子命令时返回空串，不许把 --help 当成命令名
    @Assert(failingCommandName(ArrayList<String>(["--help"])) == "")
    @Assert(failingCommandName(ArrayList<String>(["-V"])) == "")
    @Assert(failingCommandName(ArrayList<String>()).isEmpty())
}
