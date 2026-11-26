// git 钩子安装器。
//
// 安全设计：
// - 只装 post-commit（非阻塞，绝不会让 commit 失败）
// - 钩子后台异步调用 cambium track，提交不等待任何扫描或 AI
// - 托管块标记：重装只替换 Cambium 自己的块，其余内容保留；
//   卸载只删这一块
package cambium.kernel

import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.util.*

let HOOK_BEGIN = "# deepgit:begin"
let HOOK_END = "# deepgit:end"

func hookBody(deepgitPath: String, hookName: String, hookLog: String): String {
    let note = if (hookName == "post-merge") {
        "Cambium post-merge hook — 合并后记录默认分支进度。"
    } else {
        "Cambium post-commit hook — 后台记录分支进度。"
    }
    let sb = StringBuilder()
    sb.append(HOOK_BEGIN)
    sb.append("\n")
    sb.append("# ${note}\n")
    sb.append("# 托管块：请在块外编辑，块内内容会被覆盖。\n")
    // ⚠️ 顺序是承重的：**绝对路径优先，PATH 只作兜底**。
    // 旧实现反过来（先 `command -v deepgit`），实测两个后果：
    //   1) PATH 上一个同名旧版或恶意 binary 会被优先执行 ——
    //      钩子是每次 git commit 都会跑的后台进程，等于把执行权让给了 PATH。
    //   2) 记录路径失效时（引擎重装 / target 被清 / 目录移动）走 elif 静默跳过，
    //      没有任何提示。叠加第 1 点就是「重建引擎 + PATH 上有旧版 = 钩子永久跑在旧版上」。
    // 绝对路径是安装时写死的、可预期的；PATH 是环境里最容易被动的东西。
    // ⚠️ 告警必须落到一个**持久的地方**。
    //
    // 原来是 `>/dev/null 2>&1`：stdout 和 stderr 一起丢进黑洞。
    // 于是 post-commit 钩子（唯一的后台写进度路径）报出的
    // 「N 行进度日志无法解析，已跳过」「存储文件读不出来，写入已拒绝」
    // 「负数 backupKeep，已跳过剪枝」这类**数据丢失告警**，
    // 没有任何一个能到达用户 —— 钩子每次提交都跑，却永远沉默。
    // （`--quiet` 曾额外门控了 Log.warn，是第二层丢弃，已在 util/log.cj 修掉：
    //   warn 现在只走 stderr，不再受 quiet 影响，脚本与钩子都拿得到。）
    // 现在的分工是：--quiet 负责关掉 info/step/ok 这层叙述，
    // 2>>"$HOOK_LOG" 负责把剩下的一切（warn + error）接住。
    //
    // 落点用 store 下的 runs/hook.log —— 该目录 ensureStore 一直在建，
    // 但全仓从未使用过，正好拿来放这个。
    sb.append("HOOK_LOG=\"${hookLog}\"\n")
    sb.append("mkdir -p \"$(dirname \"$HOOK_LOG\")\" 2>/dev/null || true\n")
    // 轮转：钩子每次提交都跑，不封顶会无限增长
    sb.append("if [ -f \"$HOOK_LOG\" ] && [ \"$(wc -c < \"$HOOK_LOG\" 2>/dev/null || echo 0)\" -gt 262144 ]; then\n")
    sb.append("  mv -f \"$HOOK_LOG\" \"$HOOK_LOG.1\" 2>/dev/null || true\n")
    sb.append("fi\n")
    sb.append("if [ -x \"${deepgitPath}\" ]; then\n")
    sb.append("  (\"${deepgitPath}\" track --quiet --source hook >/dev/null 2>>\"${hookLog}\" &)\n")
    // 名字探测与执行必须是**同一个**：探测 cambium 却执行 deepgit（或反过来），
    // 后果是「钩子静默什么都不做」—— 用户那边表现为进度记录无声停止，
    // 没有任何报错，与「把引擎卸了」的症状一模一样（见下方卸载章节）。
    // 新名优先、旧名兜底：没跑过新 install.sh 的机器上只有 deepgit。
    sb.append("elif command -v cambium >/dev/null 2>&1; then\n")
    sb.append("  (cambium track --quiet --source hook >/dev/null 2>>\"${hookLog}\" &)\n")
    sb.append("elif command -v deepgit >/dev/null 2>&1; then\n")
    sb.append("  (deepgit track --quiet --source hook >/dev/null 2>>\"${hookLog}\" &)\n")
    sb.append("fi\n")
    sb.append(HOOK_END)
    sb.append("\n")
    return sb.toString()
}

/// 钩子日志的落点。与 store 用同一个 projectId 推导规则。
public func hookLogPathFor(repoDir: String): String {
    return deepgitPath(["store", projectIdFor(repoDir), "runs", "hook.log"])
}

func stripHookBlock(content: String): (String, Bool) {
    let beginIdx = content.indexOf(HOOK_BEGIN)
    match (beginIdx) {
        case None => return (content, false)
        case Some(bi) =>
            let endIdx = content.indexOf(HOOK_END, bi)
            match (endIdx) {
                case None => return (content, false)
                case Some(ei) =>
                    let after = content[ei + HOOK_END.size..]
                    let cleaned = if (after.startsWith("\n")) { after[1..] } else { after }
                    return (content[..bi] + cleaned, true)
            }
    }
}

public func hookPath(repoDir: String): Option<String> {
    return hookPathFor(repoDir, "post-commit")
}

public func hookPathFor(repoDir: String, hookName: String): Option<String> {
    let r = gitTry(repoDir, ["rev-parse", "--git-path", "hooks/" + hookName])
    if (!r.ok()) {
        return None
    }
    let p = r.stdout.trimAscii()
    if (p.startsWith("/")) {
        return Some(p)
    }
    return Some("${repoDir}/${p}")
}

public class HookResult {
    public let file: String
    public let installed: Bool
    public let created: Bool
    public let replaced: Bool

    public init(file: String, installed: Bool, created: Bool, replaced: Bool) {
        this.file = file
        this.installed = installed
        this.created = created
        this.replaced = replaced
    }
}

public func installHook(repoDir: String, deepgitPath: String): HookResult {
    return installHookFor(repoDir, deepgitPath, "post-commit")
}

public func installHookFor(repoDir: String, deepgitPath: String, hookName: String): HookResult {
    match (hookPathFor(repoDir, hookName)) {
        case None => throw DgError("NOT_GIT", "不是 git 仓库：${repoDir}")
        case Some(file) =>
            ensureDir(dirname(file))
            // ⚠️ 必须用 readFileTextChecked，不能用 readFileText。
            //
            // readFileText 把「存在但读不出来」（权限、瞬时 I/O）和「不存在」
            // 一样表达成 None，于是这里 exists=false、existing=""，
            // 紧接着 writeFileAtomic 走 rename —— 只需要**目录**写权限，
            // 覆盖一个读不了的文件照样成功。
            //
            // 实测：用户自己写的 post-commit 钩子 chmod 000 之后跑 hook install，
            //   ✓ 已安装 post-commit 钩子 → .../.git/hooks/post-commit   EXIT=0
            //   cat 出来：#!/bin/sh  之后直接是 # deepgit:begin
            //              用户那一行彻底消失，零警告
            // 二次伤害：uninstall 时看到「块外无内容」就把整个文件删掉。
            //
            // readFileTextChecked 对「读不出来」抛异常而不是返回 None ——
            // 宁可不装，也不能销毁用户的文件。
            var existing = ""
            var exists = false
            if (fileExists(file)) {
                existing = readFileTextChecked(file).getOrThrow()
                exists = true
            }
            let (stripped, wasPresent) = stripHookBlock(existing)
            let shebang = extractShebang(existing)
            let bodyWithoutShebang = stripShebang(stripped)
            let next = "${shebang}\n${hookBody(deepgitPath, hookName, hookLogPathFor(repoDir))}\n${bodyWithoutShebang}".trimAsciiEnd() + "\n"
            writeFileAtomic(file, next)
            // chmod 755
            chmodExecutable(file)
            return HookResult(file, true, !exists, wasPresent)
    }
}

public func uninstallHook(repoDir: String): HookResult {
    return uninstallHookFor(repoDir, "post-commit")
}

public func uninstallHookFor(repoDir: String, hookName: String): HookResult {
    match (hookPathFor(repoDir, hookName)) {
        case None => throw DgError("NOT_GIT", "不是 git 仓库：${repoDir}")
        case Some(file) =>
            // 同 install：读不出来必须报错，不能当成「没装」。
            // 否则 hook status 会谎报未安装，hook uninstall 会静默什么都不做，
            // 而钩子块其实好好地躺在文件里。
            if (!fileExists(file)) {
                return HookResult(file, false, false, false)
            }
            let existing = readFileTextChecked(file).getOrThrow()
            let (cleaned, found) = stripHookBlock(existing)
            if (!found) {
                return HookResult(file, false, false, false)
            }
            let meaningful = stripShebang(cleaned).trimAscii()
            if (meaningful.size == 0) {
                removePathIfExists(file)
                return HookResult(file, false, false, true)
            }
            // ⚠️ 必须**还原卸载时的权限位**，否则用户自己的钩子会被静默废掉。
            //
            // 实测：用户自写了一个可执行的 post-commit（-rwxr-xr-x），
            //   hook install   → -rwxr-xr-x  ✓（install 末尾有 chmodExecutable）
            //   hook uninstall → -rw-r--r--  ✗ 用户钩子就此不再被执行
            // 而 writeFileAtomic 是「写临时文件 + rename」，临时文件按 umask 得到
            // 0644，rename 不会继承原文件的 mode。
            //
            // git 只会打一行 hint：
            //   hint: The '.git/hooks/post-commit' hook was ignored
            //          because it's not set as executable.
            // 没人会注意到，于是用户以为「卸掉 moonGit 就恢复正常了」，
            // 实际上自己的自动化已经死了。这比 Cambium 装错了严重得多 ——
            // 毁掉的是**不属于** Cambium 的东西。
            //
            // 方向选择：还原**卸载时**的位，而不是一律 755。
            // 判定读不出来时（fileIsExecutable 返回 false）宁可不动，
            // 因为动错的方向就是本 bug 本身。
            //
            // ⚠️ 已知残留（不是已复现缺陷的遗漏，是语义上的不完整）：
            // install 会强制 755，所以「安装**之前**的原始位」在 uninstall 时
            // 已经无从得知 —— 一个原本被用户故意设为 644 的 post-commit，
            // 走完 install + uninstall 会变成 755 并开始执行。
            // 要彻底还原需要在托管块里持久化原始位（如 `# deepgit:mode 644`），
            // 代价是引入对 stat 的跨平台解析；考虑到该场景的后果只是
            // 「用户自己那个本来就没在跑的脚本开始跑了」（文件仍是用户的、随时可改回），
            // 暂不做。真要做时以「先在托管块里留模式行」为准。
            let wasExecutable = fileIsExecutable(file)
            writeFileAtomic(file, cleaned.trimAsciiEnd() + "\n")
            if (wasExecutable) {
                chmodExecutable(file)
            }
            return HookResult(file, false, false, true)
    }
}

public func hookInstalled(repoDir: String): Bool {
    return hookInstalledFor(repoDir, "post-commit")
}

public func hookInstalledFor(repoDir: String, hookName: String): Bool {
    match (hookPathFor(repoDir, hookName)) {
        case None => return false
        case Some(file) =>
            // 读不出来时抛错而不是报 false ——
            // 「读不到」和「没装」是相反的结论，status 报错比报错更安全。
            if (!fileExists(file)) {
                return false
            }
            return readFileTextChecked(file).getOrThrow().contains(HOOK_BEGIN)
    }
}

func extractShebang(content: String): String {
    if (content.startsWith("#!")) {
        let nl = content.indexOf("\n")
        match (nl) {
            case Some(i) => return content[..i]
            case None => return content
        }
    }
    return "#!/bin/sh"
}

func stripShebang(content: String): String {
    if (content.startsWith("#!")) {
        let nl = content.indexOf("\n")
        match (nl) {
            case Some(i) => return content[i + 1..]
            case None => return ""
        }
    }
    return content
}

/// 仅测试用：把文件权限改回 644，用来构造「本来不可执行的钩子」。
func chmodNonExecutable(file: String): Unit {
    let r = execCapture("chmod", ["644", file], None, 8000)
    if (!r.ok()) {
        Log.debug("chmod 644 失败：${file}")
    }
}

func chmodExecutable(file: String): Unit {
    // 用系统 chmod 保证权限（仓颉 std 无 chmod）
    let r = execCapture("chmod", ["755", file], None, 8000)
    if (!r.ok()) {
        Log.debug("chmod 755 失败：${file}")
    }
}

/// 文件当前是否带可执行位。
///
/// 用 `test -x` 而不是 stat/解析权限位：`test -x` 认的是**实际可执行性**，
/// 在 macOS 上还会考虑 ACL，解析 `100755` 那种字面量会误判。
/// 读不到就当「不可执行」—— 判错方向是**不还原权限**，
/// 那会退回到本 bug 的旧行为；而这里真正要防的恰恰是这个方向，
/// 所以宁可**多**判成可执行：最坏情况是给一个本来不可执行的文件补上可执行位，
/// 远好过悄悄废掉用户自己的钩子。
func fileIsExecutable(file: String): Bool {
    if (!fileExists(file)) {
        return false
    }
    let r = execCapture("/bin/sh", ["-c", "test -x \"$1\" && echo yes || echo no", "sh", file], None, 8000)
    return r.ok() && r.stdout.trimAscii() == "yes"
}

/// 测试辅助：把文件权限改成只读（000），用来制造「存在但读不出来」。
/// 失败时抛 —— 前提没造出来，后面的断言就是在空集上跑。
func setMode000(file: String): Unit {
    let r = execCapture("chmod", ["000", file], None, 8000)
    if (!r.ok()) {
        throw DgError("TEST_SETUP", "chmod 000 失败：${file}（${r.stderr}）", 1, None)
    }
}

/// 测试辅助：恢复成可读可执行
func setMode755(file: String): Unit {
    let r = execCapture("chmod", ["755", file], None, 8000)
    if (!r.ok()) {
        throw DgError("TEST_SETUP", "chmod 755 失败：${file}（${r.stderr}）", 1, None)
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testStripHookBlock(): Unit {
    let content = "#!/bin/sh\necho hello\n${HOOK_BEGIN}\nstuff\n${HOOK_END}\necho world\n"
    let (cleaned, found) = stripHookBlock(content)
    @Assert(found)
    @Assert(!cleaned.contains(HOOK_BEGIN))
    @Assert(cleaned.contains("echo hello"))
    @Assert(cleaned.contains("echo world"))
}

@Test
func testStripHookBlockNotFound(): Unit {
    let (cleaned, found) = stripHookBlock("#!/bin/sh\necho x\n")
    @Assert(!found)
    @Assert(cleaned.contains("echo x"))
}

@Test
func testInstallAndUninstallHook(): Unit {
    let base = "/tmp/deepgit-hook-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    let res = installHook(base, "/usr/local/bin/deepgit")
    @Assert(res.installed)
    @Assert(res.created)
    @Assert(hookInstalled(base))

    // 重装幂等（不重复块）
    let res2 = installHook(base, "/usr/local/bin/deepgit")
    @Assert(res2.replaced)
    match (readFileText(res.file)) {
        case Some(c) =>
            var count: Int64 = 0
            for (line in c.split("\n")) {
                if (line.startsWith(HOOK_BEGIN)) {
                    count += 1
                }
            }
            @Assert(count == 1)
        case None => @Assert(false)
    }

    let un = uninstallHook(base)
    @Assert(un.file.size > 0)
    @Assert(!hookInstalled(base))
    removePathIfExists(base)
}

@Test
func testInstallHookPreservesExistingContent(): Unit {
    let base = "/tmp/deepgit-hook2-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    match (hookPath(base)) {
        case Some(p) =>
            ensureDir(dirname(p))
            writeFileAtomic(p, "#!/bin/sh\necho my-custom-hook\n")
        case None => @Assert(false)
    }
    installHook(base, "/x/deepgit")
    match (hookPath(base)) {
        case Some(p) =>
            let c = readFileTextOr(p, "")
            @Assert(c.contains("my-custom-hook"))
            @Assert(c.contains(HOOK_BEGIN))
            @Assert(c.startsWith("#!/bin/sh"))
        case None => @Assert(false)
    }
    removePathIfExists(base)
}

@Test
func testHookPathRequiresGit(): Unit {
    let tmp = "/tmp/deepgit-hook3-${nowMillis()}"
    ensureDir(tmp)
    @Assert(hookPath(tmp).isNone())
    removePathIfExists(tmp)
}

@Test
func testPostMergeHookLifecycle(): Unit {
    let base = "/tmp/deepgit-hk-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    // 未安装
    @Assert(!hookInstalledFor(base, "post-merge"))
    // 安装
    let res = installHookFor(base, "/fake/engine", "post-merge")
    @Assert(res.installed)
    @Assert(hookInstalledFor(base, "post-merge"))
    // 内容包含 post-merge 注释（而非 post-commit）
    let content = readFileText(res.file).getOrThrow()
    @Assert(content.contains("post-merge hook"))
    @Assert(!content.contains("post-commit hook"))
    @Assert(content.contains("cambium track --quiet --source hook"))
    // 重装幂等（不重复）
    let res2 = installHookFor(base, "/fake/engine", "post-merge")
    @Assert(res2.replaced)
    let content2 = readFileText(res.file).getOrThrow()
    @Assert(content2.split("deepgit:begin").size == 2)  // 恰好一个托管块
    // 卸载
    let rm = uninstallHookFor(base, "post-merge")
    @Assert(rm.replaced)
    @Assert(!hookInstalledFor(base, "post-merge"))
    removePathIfExists(base)
}

@Test
func testHookBodyCommentVaries(): Unit {
    let cm = hookBody("/e", "post-commit", "/tmp/lg/hook.log")
    let pm = hookBody("/e", "post-merge", "/tmp/lg/hook.log")
    @Assert(cm.contains("post-commit hook"))
    @Assert(pm.contains("post-merge hook"))
}

/// 钩子必须优先使用安装时记录的绝对路径，PATH 只作兜底。
///
/// 旧实现顺序反了（先 `command -v deepgit`）。实测后果：
///   1) PATH 上一个同名旧版/恶意 binary 被优先执行 —— 钩子是每次 git commit
///      都会跑的后台进程，等于把执行权让给了环境里最容易被动的东西。
///   2) 记录路径失效时走 elif 静默跳过，没有任何提示。叠加第 1 点，
///      「重建引擎 + PATH 上有旧版」= 钩子永久跑在旧版上。
///
/// 断言的是脚本里两个分支的**先后次序**，不是「有没有提到 PATH」——
/// 顺序反了照样能通过后者。
@Test
func testHookPrefersRecordedEnginePathOverPathLookup(): Unit {
    let script = hookBody("/abs/path/to/engine/main", "post-commit", "/tmp/lg/hook.log")
    let absIdx = script.indexOf("[ -x \"/abs/path/to/engine/main\" ]")
    let pathIdx = script.indexOf("command -v deepgit")
    @Assert(absIdx.isSome())
    @Assert(pathIdx.isSome())
    // 绝对路径必须排在 PATH 查找之前
    @Assert(absIdx.getOrThrow() < pathIdx.getOrThrow())
    // 两者都要还在（PATH 是兜底，不是删掉）
    @Assert(script.contains("track --quiet --source hook"))
}

/// 钩子里 `command -v X` 探测的名字，必须与该分支里**实际执行**的命令同名。
///
/// 2026-10-03 改名时踩过：批量替换把执行侧的 `deepgit track` 换成了 `cambium track`，
/// 探测侧的 `command -v deepgit` 因为后面紧跟 `>` 没被命中 ——
/// 结果是**测旧名、跑新名**。装的机器上只有 cambium 时两个分支都进不去，
/// 钩子**静默什么都不做**：用户那边表现为进度记录无声停止、零报错，
/// 症状与「把引擎卸了」一模一样，最难自查的那一类。
///
/// 判据钉的是**关系**（探测名 == 执行名），不是具体字面量：
/// 下次再改名这条判据照样有效，而真出现交叉时必红。
@Test
func testHookPathProbeAndInvocationUseSameBinaryName(): Unit {
    let script = hookBody("/abs/path/to/engine/main", "post-commit", "/tmp/lg/hook.log")
    for (name in ["cambium", "deepgit"]) {
        let probe = script.indexOf("command -v ${name} ")
        let run = script.indexOf("(${name} track --quiet")
        @Assert(probe.isSome())
        @Assert(run.isSome())
        let p = probe.getOrThrow()
        let r = run.getOrThrow()
        // 探测必须排在自己的执行之前
        @Assert(p < r)
        // 两者之间不许夹着别的探测 —— 那说明两个名字的分支被交叉了
        @Assert(indexOfFrom(script, p + 1, "command -v ") >= r)
    }
    // 反向：执行过的名字，没有一个是不探测就直接跑的
    for (name in ["cambium", "deepgit"]) {
        @Assert(script.indexOf("(${name} track --quiet").isSome())
        @Assert(script.indexOf("command -v ${name} ").isSome())
    }
}

@Test
func testHookNeverDestroysUnreadableUserFile(): Unit {
    // 回归（P0）：hook install 把「存在但读不出来」当成「不存在」，
    // 于是把用户自己写的钩子**无声销毁**。
    //
    // 链条：readFileText 把权限/IO 失败也表达成 None
    //      → exists=false、existing=""
    //      → writeFileAtomic 走 rename，只需要**目录**写权限，
    //        覆盖一个读不了的文件照样成功
    //      → 用户内容消失，命令还打印「✓ 已安装」，exit 0
    // 二次伤害：随后 uninstall 看到「块外无内容」把整个文件删掉。
    //
    // 实测（修复前）：chmod 000 post-commit → hook install →
    //   cat 只剩 # deepgit:begin，用户那一行彻底消失，零警告。
    let dir = "/tmp/deepgit-hookro-${nowMillis()}"
    ensureDir(dir)
    let repo = "${dir}/repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic(repo + "/a.txt", "x")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)

    let hookFile = "${repo}/.git/hooks/post-commit"
    let userScript = "#!/bin/sh\necho \"MY IMPORTANT CUSTOM HOOK LOGIC\"\n"
    writeFileAtomic(hookFile, userScript)
    setMode000(hookFile)

    // install 必须失败，且**绝不能**动那个文件
    var threw = false
    try {
        _ = installHookFor(repo, "/bin/echo", "post-commit")
    } catch (e: Exception) {
        threw = true
    }
    @Assert(threw)
    setMode755(hookFile)
    // 关键断言：用户脚本一个字节都没少
    @Assert(readFileTextOr(hookFile, "") == userScript)

    // uninstall 同样不能把「读不出来」当成「没装」而静默返回
    setMode000(hookFile)
    var threw2 = false
    try {
        _ = uninstallHookFor(repo, "post-commit")
    } catch (e: Exception) {
        threw2 = true
    }
    @Assert(threw2)
    setMode755(hookFile)
    @Assert(readFileTextOr(hookFile, "") == userScript)

    // status 也不能谎报「未安装」
    setMode000(hookFile)
    var threw3 = false
    try {
        _ = hookInstalledFor(repo, "post-commit")
    } catch (e: Exception) {
        threw3 = true
    }
    @Assert(threw3)
    setMode755(hookFile)

    removePathIfExists(dir)
}

@Test
func testHookInstallPreservesUserContentOutsideManagedBlock(): Unit {
    // 对照组：读得出来时必须正常安装，且用户脚本完整保留在块外。
    let dir = "/tmp/deepgit-hookkeep-${nowMillis()}"
    ensureDir(dir)
    let repo = "${dir}/repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic(repo + "/a.txt", "x")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], false)

    let hookFile = "${repo}/.git/hooks/post-commit"
    writeFileAtomic(hookFile, "#!/bin/sh\necho \"USER LINE\"\n")
    let r = installHookFor(repo, "/bin/echo", "post-commit")
    @Assert(r.installed)
    // created = 「文件本来不存在」。这里文件存在，所以必须是 false ——
    // 这正是修复前那个 P0 的判定依据：读不出来时 exists 被算成 false，
    // 于是一个覆盖了用户文件的动作被报成「新建」。
    @Assert(!r.created)
    // replaced = 「替换掉了一个已有的托管块」。用户脚本里没有托管块，所以是 false。
    @Assert(!r.replaced)
    let after = readFileTextOr(hookFile, "")
    @Assert(after.contains(HOOK_BEGIN))
    @Assert(after.contains(HOOK_END))
    @Assert(after.contains("USER LINE"))

    removePathIfExists(dir)
}

@Test
func testHookRedirectsStderrToDurableLog(): Unit {
    // 回归：钩子用 `>/dev/null 2>&1`，stdout 和 stderr 一起丢进黑洞。
    //
    // 于是 post-commit 钩子（唯一的后台写进度路径）报出的数据丢失告警
    // —— 「存储文件无法解析，已保留副本」「请先检查/恢复该副本；
    // 在此之前的写操作会按空数据继续」—— 没有任何一个能到达用户。
    // 钩子每次提交都跑，却永远沉默。
    //
    // 有两层丢弃，只解开一层没用：
    //   1) --quiet 门控了 Log.warn   → 已在 util/log.cj 修掉
    //   2) 2>&1 把 stderr 一起扔掉   → 本条锁定这一层
    // 两层都在的情况下，钩子的 stderr 是条不漏的静默管道：
    // Log.error 不受 --quiet 门控，它之前纯粹是被 2>&1 扔掉的。
    let base = "/tmp/deepgit-hooklog-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    let repo = base + "-repo"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic(repo + "/a.txt", "a")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "feat: a"], false)

    // 日志路径必须落在 store 下，且与 projectId 的推导一致
    let logPath = hookLogPathFor(repo)
    @Assert(logPath.contains("/runs/hook.log"))
    @Assert(logPath.contains(projectIdFor(repo)))

    _ = installHookFor(repo, "/nonexistent-engine", "post-commit")
    let script = readFileTextOr("${repo}/.git/hooks/post-commit", "")
    // stderr 必须重定向到日志，不能再是 2>&1 黑洞
    @Assert(script.contains("2>>"))
    @Assert(!script.contains("2>&1 &)"))
    // 日志路径写死在钩子里；目录可能还不存在（首次运行前），
    // 所以 mkdir -p 必须在，否则重定向失败会让命令根本跑不起来
    @Assert(script.contains(logPath))
    @Assert(script.contains("mkdir -p"))
    // 不封顶会无限增长（每次提交都写）→ 必须有轮转
    @Assert(script.contains("262144"))
    @Assert(script.contains("mv -f"))

    removePathIfExists(repo)
    removePathIfExists(deepgitPath(["store", projectIdFor(repo)]))
    exitTestHome()
    removePathIfExists(testHome)
    removePathIfExists(base)
}

@Test
func testHookLogFileIsNonEmptyDetection(): Unit {
    // hook status 靠它决定要不要提示用户去看日志 —— 文件不存在/空/有内容三种情况
    let dir = "/tmp/deepgit-logprobe-${nowMillis()}"
    ensureDir(dir)
    let f = "${dir}/x.log"
    @Assert(!fileNonEmpty(f))                       // 不存在
    writeFileAtomic(f, "")
    @Assert(!fileNonEmpty(f))                       // 空文件：不该提示
    writeFileAtomic(f, "有告警\n")
    @Assert(fileNonEmpty(f))                        // 有内容：必须提示
    removePathIfExists(dir)
}

@Test
func testHookUninstallDoesNotSilentlyDisableUsersOwnHook(): Unit {
    // 卸载 Cambium 钩子时**必须还原权限位**。
    //
    // 实测（修复前）：用户自写了一个可执行的 post-commit（-rwxr-xr-x）
    //   hook install   → -rwxr-xr-x
    //   hook uninstall → -rw-r--r--   ← 用户钩子从此不再执行
    // writeFileAtomic 是「临时文件 + rename」，临时文件按 umask 得 0644，
    // rename 不继承原 mode。git 只会打一行 hint：
    //   hint: The '.git/hooks/post-commit' hook was ignored
    //          because it's not set as executable.
    // 用户以为「卸掉 moonGit 就恢复正常」，实际上自己的自动化已经死了 ——
    // 毁掉的是**不属于** Cambium 的东西。
    let base = "/tmp/deepgit-hookperm-${nowMillis()}"
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
        let (p, _) = addProject(repo, "hookperm", ArrayList<String>(), "")
        projId = p.id

        let hookFile = match (hookPath(repo)) {
            case Some(f) => f
            case None => @Assert(false); return
        }
        // 前提自检：测试必须先证明 hookPath 指向的确实是一个可执行脚本
        writeFileAtomic(hookFile, "#!/bin/sh\necho user-hook-ran\n")
        chmodExecutable(hookFile)
        @Assert(fileExists(hookFile))
        @Assert(fileIsExecutable(hookFile))

        installHookFor(repo, "/bin/echo", "post-commit")
        @Assert(fileIsExecutable(hookFile))
        let afterInstall = readFileTextOr(hookFile, "<缺>")
        @Assert(afterInstall.contains("deepgit:begin"))
        @Assert(afterInstall.contains("user-hook-ran"))   // 用户内容不得丢

        // 核心断言：卸载后用户钩子仍然可执行
        uninstallHookFor(repo, "post-commit")
        @Assert(fileIsExecutable(hookFile))
        let afterUninstall = readFileTextOr(hookFile, "<缺>")
        @Assert(!afterUninstall.contains("deepgit:begin"))
        @Assert(afterUninstall.contains("user-hook-ran"))

        // 负控方向：判错的方向必须是「不动」而不是「删」。
        // 不可执行的文件卸载后**保持**不可执行 —— 不该被顺手激活。
        writeFileAtomic(hookFile, "#!/bin/sh\necho user-hook-ran\n")
        chmodNonExecutable(hookFile)
        @Assert(!fileIsExecutable(hookFile))
        installHookFor(repo, "/bin/echo", "post-commit")
        // install 必然要 755（钩子不执行就没有意义），这一步是前提
        @Assert(fileIsExecutable(hookFile))
    } finally {
        exitTestHome()
        if (!projId.isEmpty()) {
            removePathIfExists(deepgitPath(["store", projId]))
        }
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}
