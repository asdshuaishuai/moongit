// 进程执行：封装 git 等外部命令调用，返回结构化结果。
//
// 设计取舍：moonGit **只依赖「系统 git」一个必备二进制**，
// 其余能力（JSON/SHA256/Markdown）全部自研，保持零第三方依赖。
//
// ⚠️ 这里原来还封装了 `curlPostJson`（经 curl 发 HTTP POST），
// 头部也写着「只依赖 git 与 curl 两个必备二进制」——
// 那都是 **AI 层还在引擎里时**的遗留：AI 迁到客户端后，
// `curlPostJson` 零生产调用点，而 `doctor` 仍在把 curl 当前置条件报出来。
// 后果是没装 curl 的用户会在自检里看到「curl 缺失」，
// 去装一个根本没人用的二进制 —— **残留的依赖检查比没有检查更糟**。
// （它自己的测试也是恒真的：`@Assert(status == 0 || status > 0)`
//   对任何 Int64 都成立、`@Assert(body.size >= 0)` 同理，
//   那种测试永远不会红，属于"看起来在跑、实际什么都没验"。）
package moongit.util

import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.process.*
import std.io.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

public class ExecResult {
    public let exitCode: Int64
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(exitCode: Int64, stdout: String, stderr: String, timedOut: Bool) {
        this.exitCode = exitCode
        this.stdout = stdout
        this.stderr = stderr
        this.timedOut = timedOut
    }

    public func ok(): Bool {
        return this.exitCode == 0
    }
}

/// 杀掉子进程之后，留给读取线程收尾的时间。
///
/// 这一段**在** timeoutMs 之外：等到我们决定要杀的时候，timeoutMs 已经用完了，
/// 读取线程还在等 EOF。不给这段时间就只能丢掉已经读到的数据。
/// 所以真实上界是 `timeoutMs + KILL_GRACE_MS`（单段，不是两段 2000）。
private const KILL_GRACE_MS: Int64 = 2000

/// GIT_SSH_COMMAND 的兜底值：只在用户**没有**自己设置时使用（M21）。
/// BatchMode 禁掉口令交互（ssh 会直接失败而不是挂住等输入），
/// ConnectTimeout=5 让连不上的Host在 5 秒内放弃而不是卡满整个超时预算。
/// ⚠️ 这是兜底不是覆盖：用户 export 的 ProxyJump / Host 别名 / 非标准端口
/// 必须原样传下去（见 execCapture 里那段注释）。
public const DEFAULT_SSH_COMMAND: String = "ssh -oBatchMode=yes -oConnectTimeout=5"

/// 执行命令（同步，带真实超时）。
///
/// 设计：
/// - 管道读取放在 spawned 线程（读到 EOF），否则大输出写满管道缓冲会卡死子进程
/// - **先等管道读到 EOF，再 wait() 拿退出码** —— 顺序是承重的，见下方实测记录
/// - 环境守卫掐掉最常见的挂起源：git 凭证交互提示与 ssh 交互提示
///   （SubProcess 不暴露 pid，超时的子进程只能放弃；有守卫后实际挂死概率极低）
/// - **timeoutMs 是整次调用的等待预算**，不是每个阶段各给一份 —— 见下方实测记录
///
/// ⚠️ 为什么必须 drain-first（实测：/bin/cat 读 400000 字节文件，重复 3 次）
///     旧顺序（wait → get）：  got = 360448 / 376832 / 376832
///     新顺序（get  → wait）：  got = 400000 / 400000 / 400000
/// wait() 返回时 SubProcess 句柄被回收，它持有的 stdout 读端随之失效，
/// 读取线程只拿得到内核管道缓冲里已经到达的那部分，剩下的直接丢失 ——
/// 而且退出码仍是 0，调用方完全看不出数据被截断。
/// 真实后果（实测 20001 个文件的仓库）：
///     git ls-files -z  真实 20001 条 / 328870 字节
///     引擎拿到        16899 条 / 278528 字节（每次丢的量都不同）
/// 于是 README 托管区里写下「16834 个跟踪文件」—— 既不是真实总数，也不是
/// 20000 的采集上限，是一个纯属虚构的数字。同一条路径影响 git log / status /
/// diff --numstat / shortlog：所有超过 ~64KB 的 git 输出都在被静默砍掉。
///
/// ⚠️ 为什么 timeoutMs 必须是**共享 deadline**（实测记录）：
/// 原来两个 `get()` 各自传了完整的 timeoutMs，等于把同一份预算花两遍：
///     outFuture.get(timeoutMs) + errFuture.get(timeoutMs)   ← 2 × 120s
/// 再加上超时后为了取回残缺输出而额外等的两段 2000ms。
/// `gitRun` 传 120000，于是最坏耗时 **244 秒**，而调用方以为上限是 120 秒。
/// execCapture 是全仓唯一的进程执行入口，一个被误报的 2 倍上界会一路放大：
/// `allProjectStatuses` 用 120s 上界等 `f.get()`，而里面每个项目都在跑 gitRun。
/// 现在整次调用共用一个绝对 deadline，真实上界是 `timeoutMs + KILL_GRACE_MS`。
public func execCapture(
    cmd: String,
    args: Array<String>,
    cwd: Option<String>,
    timeoutMs: Int64,
): ExecResult {
    var workDir: Option<Path> = None
    match (cwd) {
        case Some(c) => workDir = Some(Path(c))
        case None => ()
    }
    // 继承当前环境（否则丢失 PATH/HOME 等），再叠加防挂守卫。
    // std.env 没有枚举全部变量的 API，逐个拷贝已知关键项；
    // git 需要的就是 PATH/HOME/USER 这类基础变量。
    //
    // ⚠️ M21：代理变量（http_proxy / https_proxy / no_proxy，含大写形态）必须
    // 一起传下去。原先漏了它们 ⇒ 公司内网/代理环境下的 pull/fetch/push 连不上
    // 远端，而报出来的只有 git 自己的 "Permission denied"（真实原因是代理没生效），
    // 排查方向被完全引错。
    let guardEnv = HashMap<String, String>()
    for (key in ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "LC_ALL", "TERM",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "SSH_AUTH_SOCK",
        "http_proxy", "https_proxy", "no_proxy", "all_proxy", "ftp_proxy",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY", "FTP_PROXY"]) {
        match (getVariable(key)) {
            case Some(v) => guardEnv[key] = v
            case None => ()
        }
    }
    guardEnv["GIT_TERMINAL_PROMPT"] = "0"
    guardEnv["GIT_ASKPASS"] = "/bin/true"
    // ⚠️ M21：GIT_SSH_COMMAND **不再无条件覆盖**。用户 export 的自定义配置
    // （跳板机 ProxyJump、非 22 端口的 Host 别名、指定 IdentityFile）是既有事实，
    // 覆盖它 ⇒ 内网/自定义密钥环境下的 pull/fetch/push 必败，而错误只有一句
    // git 的 Permission denied。原本的用意（BatchMode 防挂）仍然保留 ——
    // 只是改成「用户没设时才兜底」。
    //
    // 与 GIT_TERMINAL_PROMPT / GIT_ASKPASS 的区别：那两个是**防挂守卫**
    // （不让 git 弹凭据框把 GUI 客户端的交互卡死），没有用户既有配置要保护。
    match (getVariable("GIT_SSH_COMMAND")) {
        case Some(userCmd) =>
            if (!userCmd.trimAscii().isEmpty()) {
                guardEnv["GIT_SSH_COMMAND"] = userCmd
            } else {
                guardEnv["GIT_SSH_COMMAND"] = DEFAULT_SSH_COMMAND
            }
        case None => guardEnv["GIT_SSH_COMMAND"] = DEFAULT_SSH_COMMAND
    }

    let sub: SubProcess
    try {
        sub = launch(
            cmd, args,
            workingDirectory: workDir,
            environment: Some(guardEnv),
            // L12：原来是 Inherit —— 子进程与父进程共享同一个 stdin。
            // MCP 模式下 stdin 是 JSON-RPC 流，任何读 stdin 的子进程
            // （自定义 credential helper 之类）会**抢食 RPC 输入**，
            // 表现为协议消息莫名丢失。改 Null 的成本是零。
            stdIn: ProcessRedirect.Discard,
            stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Pipe,
        )
    } catch (e: Exception) {
        return ExecResult(-1, "", e.message, false)
    }

    // 取引到局部变量再交给读取线程：闭包里直接写 sub.stdOutPipe 会让读取线程
    // 去访问一个正被主线程 wait() 操作的句柄。
    let outStream = sub.stdOutPipe
    let errStream = sub.stdErrPipe
    let outFuture = spawn {
        return readAllFromPipe(outStream)
    }
    let errFuture = spawn {
        return readAllFromPipe(errStream)
    }

    // 第一步：等两个管道都读到 EOF。子进程退出 → 写端关闭 → EOF。
    //
    // ⚠️ 两个 get() 必须共用**同一个绝对 deadline**，各自再拿一份 timeoutMs
    // 等于把预算花两遍（详见本函数文档的实测记录）。这里算一次 endAt，
    // 之后每一步都只取「剩下的」。
    let endAt = nowMillis() + timeoutMs
    // 至少给 1ms：get(0) 会在任何情况下立刻抛，读线程连启动的机会都没有。
    func left(): Duration {
        let remain = endAt - nowMillis()
        return Duration.millisecond * (if (remain > 0) { remain } else { 1 })
    }
    var outRead = ("", true)
    var errRead = ("", true)
    var timedOut = false
    try {
        outRead = outFuture.get(left())
    } catch (e: TimeoutException) {
        timedOut = true
    }
    if (!timedOut) {
        try {
            errRead = errFuture.get(left())
        } catch (e: TimeoutException) {
            timedOut = true
        }
    }
    // 管道读取也必须有上界：子进程若派生了存活更久的孙进程（git lfs、gpg pinentry、
    // 自定义 credential.helper，或仓库里 core.sshCommand 覆盖了本函数设的
    // GIT_SSH_COMMAND），孙进程会继承 stdout/stderr 的写端 → 永远不 EOF。
    // execCapture 是全仓唯一的进程执行入口，一旦挂死就是整条命令挂死，
    // 而且每次泄漏两个读取线程（长驻 serve/mcp 下会累积）。
    if (timedOut) {
        Log.warn(pickText("Subprocess timed out or pipe never closed; terminating: ${cmd} ${joinStrings(args, " ")} (${timeoutMs}ms)",
            "子进程超时或管道未关闭，终止：${cmd} ${joinStrings(args, " ")}（${timeoutMs}ms）"))
        // 必须杀掉再返回。放任不管会留下孤儿进程，而 runGitOp 的 commit 路径会先跑
        // `git add -A` —— 超时的 git add 会留下 .git/index.lock，之后用户仓库里
        // 所有 git 操作都报 "Unable to create index.lock: File exists"。
        // 杀掉后管道才会 EOF，上面两个 spawn 读取线程才能退出，避免线程泄漏累积。
        //
        // ⚠️ 已知残留：terminate(force) 只作用于**直接子进程**。若被杀的 git
        // 已经派生了 ssh / gpg-agent 之类持有管道写端的孙进程，它们会继续活着
        // （= 孤儿）。仓颉 1.0.5 的 std.process 不暴露进程组 / setsid，
        // 没有可靠的修法，所以这里只如实记录现状，不假装解决。
        killSubprocess(sub)
        // 尽力把已经读到的数据取回来（此时读端会正常 EOF），别把等待白白丢掉。
        // 注意：这里拿到的是**残缺**数据，所以下面一律按失败返回，不当成有效输出。
        //
        // 这段是整次调用里唯一在 timeoutMs **之外**的等待。
        // 两个 get 也共用一个 grace deadline（不是各给一份 KILL_GRACE_MS）——
        // 否则又是一处「同一份预算花两遍」，只是换了个地方。
        let graceEnd = nowMillis() + KILL_GRACE_MS
        func graceLeft(): Duration {
            let remain = graceEnd - nowMillis()
            return Duration.millisecond * (if (remain > 0) { remain } else { 1 })
        }
        try {
            outRead = outFuture.get(graceLeft())
        } catch (e: Exception) {
            ()
        }
        try {
            errRead = errFuture.get(graceLeft())
        } catch (e: Exception) {
            ()
        }
        return ExecResult(-1, "", if (errRead[0].isEmpty()) { "命令超时或管道未关闭（${timeoutMs}ms）：${cmd}" } else { errRead[0] }, true)
    }

    // 第二步：管道都 EOF 了，子进程几乎必然已退出，wait 是瞬时的。
    // 上界也必须从同一份预算里出，不能再额外给 5000ms。
    var code: Int64 = 0
    try {
        code = sub.wait(timeout: Some(left()))
    } catch (e: TimeoutException) {
        killSubprocess(sub)
        return ExecResult(-1, outRead[0], errRead[0], true)
    } catch (e: Exception) {
        code = -1
        killSubprocess(sub)
    }

    // 读取过程中真的抛过错（管道被关闭、fd 失效等）→ 拿到的数据是残缺的。
    // 这种情况必须报错而不是返回半截输出 + exit 0：调用方无法区分
    // 「命令成功但输出短」和「命令成功但输出被砍了一半」。
    if (!outRead[1] || !errRead[1]) {
        let note = "读取子进程输出时管道出错，返回的数据不完整"
        return ExecResult(-1, outRead[0], joinNote(errRead[0], note), false)
    }
    return ExecResult(code, outRead[0], errRead[0], false)
}

/// 拼一条带后缀的 stderr；空则只返回后缀。
private func joinNote(text: String, note: String): String {
    if (text.isEmpty()) {
        return note
    }
    return text + "\n" + note
}

/// 终止子进程。进程可能已自行退出，此时 terminate 会抛错 —— 吞掉即可，
/// 无论是否杀成功调用方都不该因此崩。
private func killSubprocess(sub: SubProcess): Unit {
    try {
        if (sub.isAlive()) {
            sub.terminate(force: true)
        }
    } catch (e: Exception) {
        ()
    }
}

/// 读管道到 EOF，UTF-8 容错解码。返回 (文本, 是否完整读完)。
///
/// ⚠️ 第二个返回值是承重的。以前这里 `catch (e: Exception) { () }` 把读错误吞掉，
/// 直接返回已读到的半截数据 —— 配合 wait-first 的顺序缺陷，管道被关闭时
/// 读错误发生、数据被静默截断，而退出码仍是 0，调用方无从察觉。
/// 现在读出错就如实上报，由 execCapture 变成一次失败而不是一份残缺的成功结果。
func readAllFromPipe(pipe: ?InputStream): (String, Bool) {
    match (pipe) {
        case Some(input) =>
            let total = ArrayList<UInt8>()
            let buf = Array<UInt8>(65536, repeat: 0u8)
            var clean = true
            while (true) {
                var n = 0
                try {
                    n = input.read(buf)
                } catch (e: Exception) {
                    clean = false
                    break
                }
                if (n <= 0) {
                    break
                }
                for (i in 0..n) {
                    total.add(buf[i])
                }
            }
            return (fromUtf8Lossy(total.toArray()), clean)
        case None => return ("", true)
    }
}

/// 执行命令并返回 (exitCode, stdout, stderr)
public func execOut(
    cmd: String,
    args: Array<String>,
    cwd: Option<String>,
): (Int64, String, String) {
    let r = execCapture(cmd, args, cwd, 60000)
    return (r.exitCode, r.stdout, r.stderr)
}

/// 执行 git；失败时抛 DgError（可用 tolerate 容忍失败）
///
/// ⚠️ tolerate 的语义是「**失败就返回空串，不报错**」——它不是 mustSucceed。
/// 全仓曾有 288 处测试用 `gitRun(dir, args, true)`，看上去像「这条必须成功」，
/// 实际是「这条失败也别吭声」。代价是测试可以在前提不成立时**空转绿**。
///
/// 本轮真实踩中的例子：两个新测试要建裸库当 remote，写的是
///     gitRun(remote, ["init", "-q", "--bare"], true)
/// 而 remote 目录根本不存在 —— `git -C <不存在的目录>` 直接失败，
/// 裸库没建起来，后面的 `git push -u origin feature-x` 也一起失败。
/// 于是「分支比自己的 upstream 新 1 个提交」这个前提从未成立，
/// 而被测代码恰好在这个前提下**也是对的**，测试绿了，却什么也没测到。
///
/// 判据：**测试里凡是后续断言依赖其结果的 git 步骤，一律传 false。**
/// 只有「失败也在预期内」的探测性命令（如 `git stash list` 探有无 stash）
/// 才传 true。全仓测试区的 gitRun 已统一改为 false。
public func gitRun(
    repoDir: String,
    args: Array<String>,
    tolerate: Bool,
): String {
    let fullArgs = ArrayList<String>()
    fullArgs.add("-c")
    fullArgs.add("core.quotepath=false")
    fullArgs.add("-c")
    fullArgs.add("color.ui=false")
    fullArgs.add("-C")
    fullArgs.add(repoDir)
    for (a in args) {
        fullArgs.add(a)
    }
    let r = execCapture("git", fullArgs.toArray(), None, 120000)
    if (r.exitCode != 0) {
        if (tolerate) {
            return ""
        }
        throw DgError(
            "GIT_FAILED",
            "git ${joinStrings(args, " ")} 失败（cwd=${repoDir}）",
            1,
            Some(r.stderr.trimAscii()),
        )
    }
    return r.stdout.trimAscii()
}

/// 执行 git，不抛异常，返回结构体
public func gitTry(repoDir: String, args: Array<String>): ExecResult {
    let fullArgs = ArrayList<String>()
    fullArgs.add("-c")
    fullArgs.add("core.quotepath=false")
    fullArgs.add("-c")
    fullArgs.add("color.ui=false")
    fullArgs.add("-C")
    fullArgs.add(repoDir)
    for (a in args) {
        fullArgs.add(a)
    }
    return execCapture("git", fullArgs.toArray(), None, 120000)
}

/// 执行 git，保留原始输出（不 trim，用于 -z 输出）
public func gitRaw(repoDir: String, args: Array<String>): String {
    let fullArgs = ArrayList<String>()
    fullArgs.add("-c")
    fullArgs.add("core.quotepath=false")
    fullArgs.add("-c")
    fullArgs.add("color.ui=false")
    fullArgs.add("-C")
    fullArgs.add(repoDir)
    for (a in args) {
        fullArgs.add(a)
    }
    let r = execCapture("git", fullArgs.toArray(), None, 120000)
    if (r.exitCode != 0) {
        throw DgError("GIT_FAILED", "git 调用失败", 1, Some(r.stderr.trimAscii()))
    }
    return r.stdout
}

/// 命令是否存在
public func commandExists(cmd: String): Bool {
    let r = execCapture("which", [cmd], None, 8000)
    return r.exitCode == 0 && !r.stdout.isBlank()
}

// ------------------------------ 测试 ------------------------------

@Test
func testExecCaptureEcho(): Unit {
    let r = execCapture("echo", ["hello"], None, 8000)
    @Assert(r.exitCode == 0)
    @Assert(r.stdout.trimAscii() == "hello")
}

@Test
func testExecCaptureFailure(): Unit {
    let r = execCapture("/nonexistent-binary-xyz", [], None, 5000)
    @Assert(!r.ok())
}

@Test
func testExecCaptureTerminatesTimedOutProcess(): Unit {
    // 超时必须真的把子进程杀掉，不能只是「放弃等待」。
    // 放任不管会留下孤儿进程；而 runGitOp 的 commit 路径会先跑 `git add -A`，
    // 超时的 git add 会留下 .git/index.lock，之后用户仓库里所有 git 操作
    // 都会报 "Unable to create index.lock: File exists"。
    // 另外读取 stdout/stderr 的两个 spawn 线程也要靠进程被杀后拿到 EOF 才能退出。
    let marker = "deepgit-timeout-probe"
    let r = execCapture("/bin/sh", ["-c", "exec -a ${marker} sleep 30"], None, 700)
    @Assert(r.timedOut)
    @Assert(r.exitCode == -1)
    @Assert(r.stderr.contains("超时"))

    // 给操作系统一点回收时间（复用自身提供的 execCapture，不引入额外依赖）
    _ = execCapture("/bin/sleep", ["0.4"], None, 5000)
    let ps = execCapture("/bin/ps", ["-Ao", "comm"], None, 5000)
    // 探针进程必须已经不在了
    @Assert(!ps.stdout.contains(marker))
}

@Test
func testExecCaptureTimeoutIsATotalBoundNotPerPhase(): Unit {
    // timeoutMs 必须是**整次调用**的等待预算，而不是每个阶段各给一份。
    //
    // 原实现有两处「同一份预算花两遍」：
    //   ① 超时后取回残缺输出时，两个 get 各等 2000ms（合计 4000ms）
    //   ② 管道阶段两个 get 各拿一份完整的 timeoutMs
    //
    // ⚠️⚠️ 这条测试**拿不出能红的负控** —— 两处在本机都不可观测，如实记录：
    //
    //   ① kill 掉子进程之后管道立刻 EOF，两个 grace get 瞬间返回，
    //     4000ms 根本花不出去。（试过把 grace 退回「各一份」，测试照样全绿。）
    //   ② 需要「stdout 已 EOF 但 stderr 被某个孙进程持有」才会真的花两倍。
    //     仓颉 launch 出来的管道 fd 带 CLOEXEC，后台进程 exec 后就丢掉写端，
    //     构造不出来（实测记录见
    //     testExecCaptureIsBoundedWhenCommandIgnoresTermination）。
    //     试过 `sh -c 'sleep 5 & exit'` 之类，stdout 同样被后台进程持有，
    //     第一个 get 直接超时，第二个压根不会执行。
    //
    // 所以这两处是**按代码读出来的**修复，不是测出来的。
    // 留这条测试的价值是：它锁住「总耗时 ≤ timeoutMs + KILL_GRACE_MS + 余量」
    // 这个不变量。哪天换平台 / 换 launch 实现让上述场景变得可达（最可能是
    // CLOEXEC 被去掉），它会立刻变红。不变量的正确性由构造保证，不由本次验证保证。
    let timeoutMs: Int64 = 1500
    let t0 = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let r = execCapture("/bin/sh", ["-c", "exec -a dg-totalbound-probe sleep 30"], None, timeoutMs)
    let elapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - t0
    @Assert(r.timedOut)
    @Assert(!r.ok())
    let bound = timeoutMs + KILL_GRACE_MS + 1000
    @Assert(elapsed < bound)
    // 这条是**有**判别力的：进程必须真被杀掉，否则只是一次「放弃等待」，
    // 而放弃等待会留下 .git/index.lock 把用户仓库里的 git 全锁死。
    _ = execCapture("/bin/sleep", ["0.3"], None, 5000)
    let ps = execCapture("/bin/ps", ["-Ao", "comm"], None, 5000)
    @Assert(!ps.stdout.contains("dg-totalbound-probe"))
}

@Test
func testGitRunVersion(): Unit {
    let out = gitRun("/tmp", ["--version"], false)
    @Assert(out.contains("git version"))
}

@Test
func testGitTryToleratesFailure(): Unit {
    let r = gitTry("/tmp", ["rev-parse", "--verify", "nonexistent-ref-xyz"])
    @Assert(!r.ok())
}

@Test
func testCommandExists(): Unit {
    @Assert(commandExists("git"))
    @Assert(!commandExists("definitely-not-a-real-binary-xyz"))
}

// ------------------------------ 测试 ------------------------------

@Test
func testExecCaptureBasic(): Unit {
    let r = execCapture("echo", ["hello"], None, 5000)
    @Assert(r.ok())
    @Assert(r.stdout.contains("hello"))
    @Assert(!r.timedOut)
}

@Test
func testExecCaptureTimeoutActuallyTimesOut(): Unit {
    // 挂死命令：必须在超时附近返回 timedOut，而不是永远阻塞
    let t0 = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let r = execCapture("sleep", ["30"], None, 500)
    let elapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - t0
    @Assert(r.timedOut)
    @Assert(!r.ok())
    @Assert(elapsed < 5000)  // 远小于 sleep 30s
}

@Test
func testExecCaptureLargeOutput(): Unit {
    // 大输出（>64KB 管道缓冲）：并发读取线程必须让它正常走完而不是死锁
    let r = execCapture("sh", ["-c", "i=0; while [ $i -lt 8000 ]; do echo line_$i; i=$((i+1)); done"], None, 30000)
    @Assert(r.ok())
    @Assert(!r.timedOut)
    @Assert(r.stdout.size > 60000)
}

@Test
func testExecCaptureIsBoundedWhenCommandIgnoresTermination(): Unit {
    // execCapture 是全仓唯一的进程执行入口，一旦挂死就是整条命令挂死，
    // 所以「无论子进程多顽固，都必须在 timeoutMs + 余量内返回」是不变量。
    // 这里用忽略 SIGTERM 的命令验证：killSubprocess 的 force 终止必须真的生效，
    // 否则一个不配合的进程就能把 update / status / doctor 全部拖死。
    let t0 = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let r = execCapture("/bin/sh", ["-c", "trap '' TERM; /bin/sleep 30"], None, 700)
    let elapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - t0
    @Assert(r.timedOut)
    @Assert(elapsed < 10000)  // 远小于 sleep 30s，也小于 force kill 可能失败时的 30s
    @Assert(r.stderr.contains("超时"))

    // 顺带锁定「管道读取也有上界」这条修复。
    // ⚠️ 实测记录：审计提出的「孙进程继承管道写端 → EOF 永不到」场景在本机**不可复现** ——
    // 仓颉 launch 出来的管道 fd 带 CLOEXEC，后台进程 exec 后就丢掉了写端
    // （诊断：sh -c '/bin/sleep 3 & echo done' 在 execCapture 里 4ms 就 EOF，
    //   同样的命令用 Python 的 Popen 则 3s 后仍未 EOF）。
    // 所以下面的 get() 上界是防御性的：它保证「主进程已退出但管道没关」时仍有返回点，
    // 代价为零，且在换平台 / 换 launch 实现时能兜住。
}



/// 大输出必须完整取回，一条字节都不能少。
///
/// 旧实现是 `sub.wait()` → `outFuture.get()`：wait 返回时 SubProcess 句柄被回收，
/// 读端随之失效，读取线程只拿得到内核管道缓冲里已到达的部分，退出码却是 0。
/// 实测 /bin/cat 读 400000 字节，重复三次分别只拿到 360448 / 376832 / 376832。
/// 这不是上限，是竞态 —— 换台机器、换个负载就可能全丢。
@Test
func testExecCaptureDoesNotTruncateLargeOutput(): Unit {
    // 远超管道缓冲（64KB），且远大于任何一次 read() 的返回量
    let want = 400000
    let r = execCapture("/bin/sh", ["-c", "head -c ${want} /dev/zero | tr '\\0' 'a'"], None, 30000)
    @Assert(r.ok())
    @Assert(!r.timedOut)
    @Assert(r.stdout.size == want)
}

/// 直接从文件读也要完整 —— 走的是同一条管道路径，不能因为来源不同就丢数据。
@Test
func testExecCaptureDoesNotTruncateWhenReadingFile(): Unit {
    let path = "/tmp/deepgit-bigout-${nowMillis()}.bin"
    let want = 400000
    let unit = Array<UInt8>(4000, repeat: UInt8(97))
    let all = ArrayList<UInt8>()
    for (i in 0..100) {
        for (b in unit) {
            all.add(b)
        }
    }
    File.writeTo(Path(path), all.toArray())
    let r = execCapture("/bin/cat", [path], None, 30000)
    @Assert(r.ok())
    @Assert(r.stdout.size == want)
    removePathIfExists(path)
}

/// 同一路径重复执行必须稳定拿到同样的长度 —— 竞态的特征就是「有时对有时不对」。
@Test
func testExecCaptureLargeOutputIsStableAcrossRuns(): Unit {
    for (i in 0..5) {
        let r = execCapture("/bin/sh", ["-c", "head -c 400000 /dev/zero | tr '\\0' 'b'"], None, 30000)
        @Assert(r.ok())
        @Assert(r.stdout.size == 400000)
    }
}

@Test
func testGitRunTolerateSilentlySwallowsFailure(): Unit {
    // 锁定 gitRun 最容易被误用的那个语义。
    //
    // tolerate 的意思是「失败返回空串」，**不是**「必须成功」。
    // 测试里写 `gitRun(dir, args, true)` 看起来像断言，实际什么都没断言：
    // 目录不存在、参数写错、ref 不存在 —— 全部静默通过，
    // 后续断言在一个从未成立的前提上运行，于是空转绿。
    //
    // 本轮两个新测试就是这么假绿的（裸库没建成 → push 失败 → upstream 差恒为 0
    // → 被测代码「恰好也对」→ 测试绿）。所以这条测试必须存在：
    // 它让 tolerate 的危险语义在任何改动下都留在纸面上。
    let missing = "/tmp/deepgit-no-such-dir-${nowMillis()}"

    // tolerate=true：不抛，返回空串 —— 静默吞掉
    let out = gitRun(missing, ["init"], true)
    @Assert(out.isEmpty())

    // tolerate=false：必须抛，且错误要指名道姓
    var threw = false
    try {
        _ = gitRun(missing, ["init"], false)
    } catch (e: DgError) {
        threw = true
        @Assert(e.code == "GIT_FAILED")
        @Assert(e.msgText.contains("init"))
        // stderr 必须带出来，否则「为什么失败」就丢了
        match (e.details) {
            case Some(d) => @Assert(!d.isEmpty())
            case None => @Assert(false)
        }
    }
    @Assert(threw)

    // 正常路径不受影响
    let base = "/tmp/deepgit-execok-${nowMillis()}"
    ensureDir(base)
    @Assert(gitRun(base, ["init", "-q"], false).isEmpty())   // init 无输出但不失败
    @Assert(gitRun(base, ["rev-parse", "--is-inside-work-tree"], false) == "true")
    removePathIfExists(base)
}

/// M21 回归：代理变量必须传给子进程。原先白名单漏了 http_proxy 一族 ⇒
/// 内网/代理环境下的 git pull/push 连不上远端，而报出来的只有一句 git 的
/// "Permission denied"，排查方向被整个引错。
@Test
func testExecCapturePassesProxyVariablesThrough(): Unit {
    setVariable("all_proxy", "socks5://127.0.0.1:8899")
    setVariable("NO_PROXY", "internal.example")
    let r = execCapture("/usr/bin/env", [], None, 10000)
    @Assert(r.exitCode == 0)
    @Assert(r.stdout.contains("socks5://127.0.0.1:8899"))
    @Assert(r.stdout.contains("internal.example"))
    // 还原：测试不该把环境留给后续用例
    setVariable("all_proxy", "")
    setVariable("NO_PROXY", "")
}

/// M21 回归：用户自己 export 的 GIT_SSH_COMMAND 必须原样传下去。
/// 原来无条件覆盖成 BatchMode 默认值 ⇒ 跳板机/非标准端口/指定密钥环境下
/// pull/fetch/push 必败。
@Test
func testExecCaptureDoesNotOverrideUserSshCommand(): Unit {
    setVariable("GIT_SSH_COMMAND", "ssh -oProxyJump=bastion -p 2222")
    let r = execCapture("/usr/bin/env", [], None, 10000)
    @Assert(r.exitCode == 0)
    @Assert(r.stdout.contains("ProxyJump=bastion"))
    setVariable("GIT_SSH_COMMAND", "")

    // 用户没设 ⇒ 兜底的 BatchMode 守卫仍然生效（防挂的那一半不许丢）
    let r2 = execCapture("/usr/bin/env", [], None, 10000)
    @Assert(r2.stdout.contains("BatchMode=yes"))
}

/// L12 回归：子进程的 stdin 必须是 Null 而不是 Inherit。
/// MCP 模式下 stdin 是 JSON-RPC 流，读 stdin 的子进程会抢食协议输入。
@Test
func testExecCaptureChildGetsNullStdin(): Unit {
    // /bin/cat 会把 stdin 原样吐到 stdout。Inherit 模式下它会读到父进程的
    // stdin（测试里通常是终端或 /dev/null，行为不确定）；Null 模式下立刻 EOF。
    let r = execCapture("/bin/cat", [], None, 5000)
    @Assert(r.exitCode == 0)
    @Assert(r.stdout.isEmpty())
}
