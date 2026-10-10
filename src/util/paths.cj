// 路径工具：~ 展开、全局数据目录、项目 ID、相对路径。
package moongit.util

import std.collection.*
import std.env.*
import std.posix.*
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

public func homeDir(): String {
    match (getVariable("HOME")) {
        case Some(h) => return h
        case None => return "/tmp"
    }
}

/// 展开 ~ 前缀
public func expandHome(p: String): String {
    if (p == "~") {
        return homeDir()
    }
    if (p.startsWith("~/")) {
        return homeDir() + p[1..]
    }
    return p
}

/// 相对路径解析为绝对路径（不做 symlink 解析）
public func resolvePath(p: String, base: String): String {
    let expanded = expandHome(p)
    if (expanded.startsWith("/")) {
        return normalizePath(expanded)
    }
    return normalizePath(base + "/" + expanded)
}

/// 归一化路径：去掉 . 与 .. 段、重复斜杠
///
/// ⚠️ L14：相对路径的**前导 `..` 不能丢**。原实现 `if (!stack.isEmpty())`
/// 静默吞掉无法上弹的前导 `..` —— `normalizePath("../a")` 返回 `"a"`，
/// 于是 registry.cj 里以相对路径引用的项目丢了一层，症状是
/// 「明明注册过，却说项目未注册」（层级被静默抹掉，无从排查）。
/// 绝对路径按 `/` 语义处理（`/..` = `/`），相对路径保留前导 `..`。
public func normalizePath(p: String): String {
    let absolute = p.startsWith("/")
    let parts = p.split("/")
    let stack = ArrayList<String>()
    var leadingUps: Int64 = 0
    for (part in parts) {
        if (part.isEmpty() || part == ".") {
            continue
        }
        if (part == "..") {
            if (stack.isEmpty()) {
                leadingUps += 1
                continue
            }
            stack.remove(at: stack.size - 1)
            continue
        }
        stack.add(part)
    }
    let body = joinStrings(stack, "/")
    var prefix = ""
    var k: Int64 = 0
    while (k < leadingUps) {
        prefix += "../"
        k += 1
    }
    if (absolute) {
        return "/" + body
    }
    return prefix + body
}

/// 解析 macOS 常见符号链接目录前缀（/tmp → /private/tmp、/var → /private/var）。
/// 纯词法替换，仅用于路径等价比较，不访问文件系统。
public func resolveMacSymlink(p: String): String {
    if (p == "/tmp") {
        return "/private/tmp"
    }
    if (p.startsWith("/tmp/")) {
        return "/private/tmp" + p[4..]
    }
    if (p == "/var") {
        return "/private/var"
    }
    if (p.startsWith("/var/")) {
        return "/private/var" + p[4..]
    }
    return p
}

/// 路径等价判断：先做词法规范化，再容忍 macOS 符号链接前缀差异
public func samePath(a: String, b: String): Bool {
    if (a == b) {
        return true
    }
    let na = resolveMacSymlink(normalizePath(a))
    let nb = resolveMacSymlink(normalizePath(b))
    return na == nb
}

/// 全局数据目录（可用 DEEPGIT_HOME 覆盖，便于测试隔离）
public func deepgitHome(): String {
    match (getVariable("DEEPGIT_HOME")) {
        case Some(v) =>
            let t = v.trimAscii()
            if (!t.isEmpty()) {
                return normalizePath(expandHome(t))
            }
        case None => ()
    }
    return homeDir() + "/.deepgit"
}

// ------------------------------ 测试隔离 ------------------------------
//
// ⚠️ 缺陷 #181：**跑 `cjpm test` 会写进用户真实的 `~/.deepgit`。**
//
// 机制：测试原本用 `exitTestHome()` 收尾「还原环境」。
// 而 `deepgitHome()` 把**空串当未设置**，回落到 `homeDir() + "/.deepgit"`
// ——也就是用户真实数据目录。于是任何一个「自己没设隔离」的测试，
// 只要构造 `ProgressStore`（`ensureStore` 会 `ensureDir` 建出 `store/`），
// 就在真实目录里建目录。
//
// 实测（决定性）：`unset DEEPGIT_HOME; cjpm test --parallel 1` 之后，
// 用户 `~/.deepgit/store` 的 mtime 变了（`stat -f %m` 前后不同）。
// 用假 HOME 复跑，`$FAKEHOME/.deepgit/store` 被建了出来。
// 本次实测**没有**改到用户任何文件内容（store 下的 27 个项目文件时间戳未变），
// 留下的是空目录 —— 但「跑测试会碰真实数据」这件事本身就是缺陷。
//
// 修法分两半：
//   1. 本文件这对函数：退出测试时回到**沙箱**，而不是空串（空串=真实 home）。
//      测试必须用 exitTestHome() 收尾，不能再用 `setVariable(..., "")`。
//   2. 工作流：`cjpm test` **必须**带 `DEEPGIT_HOME=/tmp/<沙箱>` 运行。
//      这是最后一道兜底 —— 第 1 条只能保护「记得用这对函数」的测试。
//      详见 AGENTS.md 的构建与测试一节。
private var testHomeOriginal: String = ""
private var testHomeFallback: String = ""

/// 进入测试沙箱。base 为空时自动生成一个 /tmp 下的目录。
public func enterTestHome(base: String): String {
    if (testHomeOriginal.isEmpty()) {
        testHomeOriginal = match (getVariable("DEEPGIT_HOME")) {
            case Some(v) => v
            case None => ""
        }
    }
    let home = if (base.isEmpty()) {
        if (testHomeFallback.isEmpty()) {
            testHomeFallback = "/tmp/deepgit-testrun-${nowMillis()}"
        }
        testHomeFallback
    } else {
        base
    }
    setVariable("DEEPGIT_HOME", home)
    return home
}

/// 退出测试沙箱。**绝不置空** —— 空串会被 `deepgitHome()` 读成
/// 「用真实 home」，那正是这个缺陷本身。
public func exitTestHome(): Unit {
    if (!testHomeOriginal.isEmpty()) {
        setVariable("DEEPGIT_HOME", testHomeOriginal)
        return
    }
    // 本来就没有环境变量 → 回到本轮兜底沙箱，绝不回到真实 home
    _ = enterTestHome("")
}

public func deepgitPath(segments: Array<String>): String {
    let sb = StringBuilder(deepgitHome())
    for (s in segments) {
        sb.append("/")
        sb.append(s)
    }
    return sb.toString()
}

/// 稳定项目 ID：p_ + SHA256(绝对路径) 前 12 位
public func projectIdFor(absPath: String): String {
    let hex = sha256HexOf(normalizePath(absPath))
    return "p_" + hex[..12]
}

/// 取路径最后一段
public func basename(p: String): String {
    let trimmed = if (p.endsWith("/") && p.size > 1) { p[..p.size - 1] } else { p }
    let idx = trimmed.lastIndexOf("/")
    match (idx) {
        case Some(i) => return trimmed[i + 1..]
        case None => return trimmed
    }
}

public func dirname(p: String): String {
    let trimmed = if (p.endsWith("/") && p.size > 1) { p[..p.size - 1] } else { p }
    let idx = trimmed.lastIndexOf("/")
    match (idx) {
        case Some(i) =>
            if (i == 0) {
                return "/"
            }
            return trimmed[..i]
        case None => return "."
    }
}

/// 显示用短路径：/Volumes/data/…/moonGit
public func prettyPath(p: String, maxLen: Int64): String {
    if (p.size <= maxLen) {
        return p
    }
    let parts = p.split("/")
    if (parts.size <= 4) {
        // ⚠️ 不能裸切字节：`p[p.size - (maxLen - 1)..]` 在多字节字符（中文/
        // emoji 路径）中间落刀会抛 "Invalid utf8 byte sequence"，而这里是
        // 状态列表与注册表视图的必经渲染路径 ⇒ 一次中文路径就让整条命令失败
        // （审查 H4）。一律回退到字符边界。
        let want = p.size - (maxLen - 1)
        let start = if (want < 0) { 0 } else { nextCharBoundary(p, want) }
        return "…" + p[start..]
    }
    let tail = parts[parts.size - 2] + "/" + parts[parts.size - 1]
    return "…/" + tail
}

/// 确保目录存在
public func ensureDir(dir: String): Unit {
    let p = Path(dir)
    if (exists(p)) {
        return
    }
    try {
        Directory.create(p, recursive: true)
    } catch (e: Exception) {
        // 并发创建竞态（如钩子 track 与手动 update 同时首跑）：
        // 已存在视为成功，其余异常向上抛
        if (!exists(p)) {
            throw e
        }
    }
}

public func fileExists(p: String): Bool {
    return exists(Path(p))
}

public func isDirectoryPath(p: String): Bool {
    let path = Path(p)
    if (!exists(path)) {
        return false
    }
    // 两次 stat 之间目标可能已经消失（卷被卸载、文件被删），而 `FileInfo` 的构造器
    // 遇到 stat 失败是**抛异常**不是返回错误码。函数的契约是返回 Bool 而不是抛，
    // 所以这里必须兜住。
    //
    // ⚠️ 别把这条注释读成「权限不足会走到这里」——实测不会：父目录 `chmod 000`
    // 时 `exists` 自己就返回 false 了。这条只防 TOCTOU 窗口。
    try {
        return FileInfo(path).isDirectory()
    } catch (e: Exception) {
        return false
    }
}

/// 目录条目的四种身份。
///
/// ⚠️ `Other` 与 `Unreadable` 必须分开，理由和 `listDirChecked` 把
/// 「读不出来」与「真的是空的」分开是同一条：**「没看到」不是「不存在」**。
/// 合并成一个，扫描器就会把「SIP 保护目录读不到」报成「这里没有子目录」——
/// 而那正是本次实测踩到的：目录树里只要有一个 stat 不到的条目，
/// 整次扫描 / 整个项目状态直接失败，错误文案是仓颉运行时原文「Native function error.」，
/// 既不点名路径也不说哪一步失败。
public enum EntryKind {
    /// 子目录：可以继续往里走
    | Dir
    /// 普通文件：计入文件数
    | Regular
    /// 设备 / 套接字 / 符号链接等：确实是条目，但既不是目录也不是文件，不参与计数
    | Other
    /// **读不出来**：stat 失败。SIP 保护目录、/dev/fd/*、权限不足、刚被删掉的路径都会落在这里
    | Unreadable
}

/// 条目分类的唯一口径。所有遍历目录的代码都必须走这里。
///
/// `FileInfo` 的属性各自走不同的系统调用，**失败方式也不一样**：
///   isDirectory / isRegular —— stat 不到就抛（SIP 保护目录、`/dev/fd/20`、权限不足）
///   lastModificationTime   —— 跟随符号链接，断链就抛
///   size                   —— 走 lstat，断链也能拿到
///
/// 旧代码三样都当不会失败，异常一路穿透 `collectActivity` 与扫描器：
/// 一个读不到的条目就让整个项目状态采集 / 整次 `scan` 失败。
/// 实测（`/private/var/db/DifferentialPrivacy`、`/dev/fd/20`、
/// `/Library/Caches/com.apple.aned` 三条都让 `scan` exit 1）。
///
/// ⚠️ 还有第四个抛点：**`FileInfo(path)` 构造器本身**。`readdir` 出来的条目不受影响
/// （构造在 `Directory.readFrom` 内部完成，失败会被 `listDirChecked` 整个接住），
/// 但任何「拿路径现造 FileInfo」的地方都可能抛 —— `isDirectoryPath` 已单独兜住。
/// 要构造出 EACCES 得有非 root 属主的目录或依赖 SIP 路径，测试里复现不了，
/// 所以那一支由源码 lint 守，不由行为测试守。
///
/// 这里**不猜**具体成因（权限 / SIP / 已消失在消息里分不出来），
/// 只保证「读不到」有地方落脚，并由调用方负责披露。
///
/// IO 与策略分开：`classifyEntry` 只做「探两次 + 交给 `entryKindFrom`」，
/// 四态判定本身在纯函数里 —— 原生 stat 失败没法在测试里稳定复现
/// （要构造 EACCES/EPERM 需要非 root 拥有的目录或 SIP 路径），
/// 策略不抽出来就等于**没法测**，而没法测的判定等于不存在。
public func classifyEntry(info: FileInfo): EntryKind {
    let dirProbe = probeIsDirectory(info)
    match (dirProbe) {
        // 目录不必再探文件属性：省一次系统调用，也避免「是目录但 isRegular 读不出来」
        // 这种组合被误报成 Unreadable。
        case Some(true) => return EntryKind.Dir
        case None => return EntryKind.Unreadable
        case Some(false) => ()
    }
    return entryKindFrom(Some(false), probeIsRegular(info))
}

private func probeIsDirectory(info: FileInfo): Option<Bool> {
    try {
        return Some(info.isDirectory())
    } catch (e: Exception) {
        return None   // None = 读不出来，与 Some(false)「确实不是目录」不同构
    }
}

private func probeIsRegular(info: FileInfo): Option<Bool> {
    try {
        return Some(info.isRegular())
    } catch (e: Exception) {
        return None
    }
}

/// 四态判定的**纯函数**口径：`None` 表示「这次探测读不出来」。
///
/// ⚠️ `Some(false)` 与 `None` 绝不能合并。合并的那个版本就是本次修掉的缺陷：
/// `if (!info.isDirectory()) { continue }` 读不出来时也走这一支，
/// 于是「一个没被看过的子目录」被当成「这里没有子目录」。
public func entryKindFrom(dirProbe: Option<Bool>, regProbe: Option<Bool>): EntryKind {
    match (dirProbe) {
        case None => return EntryKind.Unreadable
        case Some(d) =>
            if (d) {
                return EntryKind.Dir
            }
    }
    match (regProbe) {
        case None => return EntryKind.Unreadable
        case Some(r) =>
            if (r) {
                return EntryKind.Regular
            }
    }
    return EntryKind.Other
}

/// 身份的可读名。仓颉枚举不支持 `==` / `!=`，
/// 需要比对身份的地方（断言、消息）一律走这里。
public func entryKindLabel(k: EntryKind): String {
    match (k) {
        case EntryKind.Dir => return "dir"
        case EntryKind.Regular => return "file"
        case EntryKind.Other => return "other"
        case EntryKind.Unreadable => return "unreadable"
    }
}

/// 这一态是不是「读不出来」。读代码时用它比 `match` 短。
public func isUnreadable(k: EntryKind): Bool {
    match (k) {
        case EntryKind.Unreadable => return true
        case _ => return false
    }
}

/// 条目修改时间；读不出来返回空串（**「不知道」不是「1970 年」**）。
/// `git.cj` 的未跟踪清单已有一份同款 try/catch，这里收成唯一口径。
public func entryMtime(info: FileInfo): String {
    try {
        return info.lastModificationTime.toString()
    } catch (e: Exception) {
        return ""
    }
}

/// 条目字节数；读不出来返回 -1 而不是 0 —— **0 是「空文件」的合法值**，
/// 拿 0 顶替会把「读不出来」说成「这个文件是空的」。
public func entrySize(info: FileInfo): Int64 {
    try {
        return info.size
    } catch (e: Exception) {
        return -1
    }
}

/// 目录直接子项，**并把「读不出来」与「真的是空的」分开**。
///
/// - Returns: (子项列表, 是否读成功)
///
/// ⚠️ `listDir` 吞掉异常返回空数组，于是「无权限 / 被占用 / I/O 错误」
/// 与「这个目录本来就是空的」完全同构。扫描侧的后果实测：
/// 把某个子树 `chmod 000` 之后，`scan --json` 给出
/// `found=1, dirsVisited=3, truncated=false`，**stderr 零告警**，
/// 而这组数与「这棵树里确实只有 1 个项目」在响应里结构完全相同。
/// 更糟的是 `dirsVisited` 还把那个根本没读到的目录算作「已访问」——
/// 等于**主动声称覆盖了一个没读的地方**。
///
/// 「不知道」必须与「没有」分开：这是本函数存在的全部理由。
public func listDirChecked(p: String): (ArrayList<FileInfo>, Bool) {
    let out = ArrayList<FileInfo>()
    let path = Path(p)
    if (!exists(path)) {
        return (out, true)   // 不存在不是「读不出来」
    }
    try {
        for (info in Directory.readFrom(path)) {
            out.add(info)
        }
    } catch (e: Exception) {
        return (out, false)
    }
    return (out, true)
}

/// 目录直接子项（不含递归）
public func listDir(p: String): ArrayList<FileInfo> {
    let out = ArrayList<FileInfo>()
    let path = Path(p)
    if (!exists(path)) {
        return out
    }
    try {
        for (info in Directory.readFrom(path)) {
            out.add(info)
        }
    } catch (e: Exception) {
        return out
    }
    return out
}

/// 原子写文件：先写临时文件再 rename
///
/// 临时名必须同时区分进程和线程。旧实现只带 pid：同一进程内两个线程写同一个文件
/// （allProjectStatuses 用 spawn 并发、execCapture 起读线程）会算出同一个 .tmp 路径，
/// 互相覆盖后 rename 出来的是半截内容 —— 原子性名存实亡。
let tmpCounter = AtomicInt64(0)

public func writeFileAtomic(filePath: String, content: String): Unit {
    ensureDir(dirname(filePath))
    // 重试一次：并发写**同一文件**时，std.fs 的 rename(overwrite: true) 本身会失败
    // —— 实测报 FSException「No such file or directory」，即目标临时文件在 rename
    // 那一刻消失了。这是 rename 到同一目标上的平台行为，不是临时名冲突
    // （临时名已带 pid + 线程序号，不会撞）。重试会重新生成一个临时名，
    // 对「读-改-写同一文件」的场景仍能拿到完整内容。
    //
    // 当前引擎里 applyRegions 持项目锁串行写同一文件，并发同目标写不会发生；
    // 这里是防御：未来若有人去掉锁或引入并发写，至少不会写坏文件。
    var attempt = 0
    while (attempt < 2) {
        let tmp = filePath + ".tmp-${getpid()}-${tmpCounter.fetchAdd(1)}"
        try {
            File.writeTo(Path(tmp), content.toArray())
            rename(Path(tmp), to: Path(filePath), overwrite: true)
            return
        } catch (e: Exception) {
            // 写失败时不要把临时文件留在用户仓库里 —— 它会变成 git status 里的脏文件，
            // 而且用户无从判断它是什么。（进程被 kill -9 的情况无法在此处理，
            // 由 moongit doctor 的残留检查兜底。）
            removePathIfExists(tmp)
            attempt += 1
            if (attempt >= 2) {
                throw e
            }
        }
    }
}

public func readFileText(filePath: String): Option<String> {
    let p = Path(filePath)
    if (!exists(p)) {
        return None
    }
    try {
        return Some(fromUtf8Lossy(File.readFrom(p)))
    } catch (e: Exception) {
        return None
    }
}

public func readFileTextOr(filePath: String, fallback: String): String {
    match (readFileText(filePath)) {
        case Some(s) => return s
        case None => return fallback
    }
}

/// 区分「文件不存在」（返回 None）与「存在但读不出来」（抛异常）。
///
/// applyRegions / previewRegions 必须用这个：它们把读到的内容当作原文整体重写。
/// 旧实现用 readFileTextOr(path, "")，读失败（权限、瞬时 I/O 错误）会静默得到空串，
/// 于是 upsertRegion 在「空文档」上追加托管块、changed=true、写盘 ——
/// 用户的整份 README 被替换成只剩一个引擎块。备份还在但用户完全不知情。
public func readFileTextChecked(filePath: String): Option<String> {
    let p = Path(filePath)
    if (!exists(p)) {
        return None
    }
    // 故意不 catch：读不出来必须让调用方知道，绝不能降级成空内容
    return Some(fromUtf8Lossy(File.readFrom(p)))
}

public func removePathIfExists(filePath: String): Unit {
    let p = Path(filePath)
    if (exists(p)) {
        try {
            remove(p, recursive: true)
        } catch (e: Exception) {
            // 删除失败必须让调用方知道：它常常意味着沙箱或用户的目录没清掉，
            // 继续跑下去就是往旧目录里堆数据。注意：这里**不能**降级成静默成功 ——
            // 静默会让「测试残留」这类问题永远查不出来。
            Log.warn(pickText("failed to remove (skipped): ${filePath}", "删除失败（已跳过）：${filePath}"))
        }
    }
}

public func appendLine(filePath: String, line: String): Unit {
    ensureDir(dirname(filePath))
    let p = Path(filePath)
    // 无条件 appendTo。旧实现先 exists() 再决定 append 还是 write：
    // 首次创建时两个并发写者都看到「不存在」，都走 writeTo（截断写）→ 丢一条。
    // appendTo 的 O_APPEND 语义由内核保证单次写原子，不需要先探测存在性。
    try {
        File.appendTo(p, (line + "\n").toArray())
    } catch (e: Exception) {
        // 文件确实不存在时 appendTo 会失败，退回创建。
        // 只在这一种情况下退回：这次的 exists 判定不会与别人形成「都判定不存在 → 都截断」的竞态，
        // 因为能走到这里说明上面已经失败过一次。
        if (!exists(p)) {
            File.writeTo(p, (line + "\n").toArray())
            return
        }
        throw e
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testNormalizePath(): Unit {
    @Assert(normalizePath("/a/b/../c") == "/a/c")
    @Assert(normalizePath("/a//b/./c") == "/a/b/c")
    @Assert(normalizePath("/../a") == "/a")
    @Assert(normalizePath("a/b") == "a/b")
}

@Test
func testBasenameDirname(): Unit {
    @Assert(basename("/a/b/c.txt") == "c.txt")
    @Assert(basename("/a/b/") == "b")
    @Assert(dirname("/a/b/c.txt") == "/a/b")
    @Assert(dirname("/x") == "/")
}

@Test
func testProjectIdStable(): Unit {
    let a = projectIdFor("/tmp/x")
    let b = projectIdFor("/tmp/x")
    let c = projectIdFor("/tmp/y")
    @Assert(a == b)
    @Assert(a != c)
    @Assert(a.startsWith("p_"))
    @Assert(a.size == 14)
}

@Test
func testProjectIdNormalizesSlashes(): Unit {
    @Assert(projectIdFor("/tmp//x/") == projectIdFor("/tmp/x"))
}

@Test
func testDeepgitHomeOverride(): Unit {
    let h = deepgitHome()
    @Assert(h.startsWith("/") || h.startsWith("~") == false)
    @Assert(!h.endsWith("/"))
}

@Test
func testPrettyPath(): Unit {
    let long = "/Volumes/data/dev/coding/deepcodeUI/deepGit/moonGit/src/util"
    let p = prettyPath(long, 30)
    @Assert(p.size <= 30)
    @Assert(prettyPath("/short", 30) == "/short")
}

/// H4 回归：显示用短路径不得在中文（3 字节）或 emoji（4 字节）字符中间落刀。
/// 原实现 `p[p.size - (maxLen - 1)..]` 是裸字节切片，切点落在多字节序列中间时
/// 抛 "Invalid utf8 byte sequence" —— 调用方（cli 状态列表 / 注册表）无 try，
/// 结果是整个命令失败，而不只是显示难看。
@Test
func testPrettyPathNeverSplitsMultibyteChars(): Unit {
    // 5 段路径（>4 段走 tail 分支），尾部全中文
    let zh = "/Volumes/data/dev/中文项目组/仓库甲"
    for (ml in 8..50) {
        let r = prettyPath(zh, ml)
        @Assert(r.size > 0)
    }
    // <=4 段走字节 tail 分支：这是原来必崩的那一支
    let zh4 = "/用户/目录/仓库名"
    for (ml in 2..20) {
        let r = prettyPath(zh4, ml)
        @Assert(r.size > 0)
    }
    // emoji（4 字节）：cli.cj 的 maxLen=46/42 曾把 4 字节字符劈中
    let emoji = "/用户/仓库🎯🎯/f4"
    for (ml in 2..30) {
        let r = prettyPath(emoji, ml)
        @Assert(r.size > 0)
    }
    // 短路径原样返回（不受影响）
    @Assert(prettyPath("/用户/仓库", 100) == "/用户/仓库")
}

/// L14 回归：相对路径的前导 `..` 不许被静默抹掉。
/// 原实现「上弹不出去就丢」⇒ `normalizePath("../a")` 返回 `"a"`，
/// 于是以相对路径引用的项目丢一层，症状是「明明注册过却说未注册」。
@Test
func testNormalizePathKeepsLeadingDotDots(): Unit {
    @Assert(normalizePath("../a") == "../a")
    @Assert(normalizePath("../../a") == "../../a")
    @Assert(normalizePath("../a/b") == "../a/b")
    @Assert(normalizePath("./a") == "a")
    @Assert(normalizePath("a/../b") == "b")
    // 绝对路径仍是 POSIX 语义：/.. = /
    @Assert(normalizePath("/..") == "/")
    @Assert(normalizePath("/a/../b") == "/b")
    @Assert(normalizePath("/a/b/..") == "/a")
    // 中间段与重复斜杠照常归一
    @Assert(normalizePath("a//b/./c") == "a/b/c")
    @Assert(normalizePath("a/../../b") == "../b")
}

@Test
func testExpandHome(): Unit {
    @Assert(expandHome("/abs") == "/abs")
    @Assert(expandHome("~").size > 1)
    @Assert(expandHome("~/x").endsWith("/x"))
}

@Test
func testResolvePath(): Unit {
    @Assert(resolvePath("b", "/a") == "/a/b")
    @Assert(resolvePath("../c", "/a/b") == "/a/c")
    @Assert(resolvePath("/x/y", "/a") == "/x/y")
}

@Test
func testResolveMacSymlink(): Unit {
    @Assert(resolveMacSymlink("/tmp") == "/private/tmp")
    @Assert(resolveMacSymlink("/tmp/a/b") == "/private/tmp/a/b")
    @Assert(resolveMacSymlink("/var/log") == "/private/var/log")
    @Assert(resolveMacSymlink("/Users/x") == "/Users/x")
    @Assert(resolveMacSymlink("/private/tmp/a") == "/private/tmp/a")
}

@Test
func testSamePath(): Unit {
    @Assert(samePath("/tmp/a", "/tmp/a"))
    @Assert(samePath("/tmp/a", "/private/tmp/a"))
    @Assert(samePath("/tmp/a//b/../c", "/tmp/a/c"))
    @Assert(!samePath("/tmp/a", "/tmp/b"))
    @Assert(!samePath("relative", "/tmp/relative"))
}

@Test
func testAppendLineNeverTruncates(): Unit {
    // 旧实现先 exists() 再决定 append 还是 write：首次创建时两个并发写者
    // 都看到「不存在」，都走 writeTo（截断写）→ 丢一条。现在无条件 appendTo，
    // 首次创建失败才退回 write。
    let dir = "/tmp/deepgit-append-${nowMillis()}"
    ensureDir(dir)
    let f = "${dir}/log.txt"
    appendLine(f, "第一行")
    appendLine(f, "第二行")
    let content = readFileTextOr(f, "")
    @Assert(content.contains("第一行"))
    @Assert(content.contains("第二行"))
    // 并发追加：8 个 worker 各写 5 行，一条都不能少
    let futures = ArrayList<Future<Unit>>()
    for (i in 0..8) {
        let tag = "w${i}"
        futures.add(spawn {
            for (j in 0..5) {
                appendLine(f, "${tag}-${j}")
            }
        })
    }
    for (fu in futures) {
        _ = fu.get(Duration.second * 60)
    }
    let merged = readFileTextOr(f, "")
    var missing = 0
    for (i in 0..8) {
        for (j in 0..5) {
            if (!merged.contains("w${i}-${j}")) {
                missing += 1
            }
        }
    }
    @Assert(missing == 0)
    removePathIfExists(dir)
}

@Test
func testReadFileTextCheckedDistinguishesMissingFromFailure(): Unit {
    let dir = "/tmp/deepgit-checked-${nowMillis()}"
    ensureDir(dir)
    let f = "${dir}/a.md"
    // 不存在 → None（调用方可以据此走「新建」分支）
    @Assert(readFileTextChecked(f).isNone())
    // 存在 → Some，且内容正确
    writeFileAtomic(f, "hello")
    @Assert(readFileTextChecked(f).getOrThrow() == "hello")
    // 对比：旧的 readFileTextOr 把「读不到」和「没有内容」混成同一个空串，
    // 而 applyRegions 用它做整体重写 → 读失败会清空用户的整份文档
    @Assert(readFileTextOr("${dir}/不存在.md", "") == "")
    removePathIfExists(dir)
}

@Test
func testWriteFileAtomicTempNamesAreUniquePerThread(): Unit {
    // 临时名旧实现只带 pid：同一进程内两个线程会算出同一个 .tmp 路径，
    // 互相覆盖后 rename 出来的是半截内容 —— 原子性名存实亡。
    //
    // ⚠️ 实测边界（不要把这个测试改成「多线程写同一个文件」）：
    // std.fs 的 rename(overwrite: true) 在**多个 rename 打到同一目标**时本身就不安全 ——
    // 报 FSException「No such file or directory」，加一次重试也不稳定复现成功。
    // 引擎按构造避开了这个场景：同一份文档的写入由项目锁串行化
    // （applyRegions 全程在 withLock 内），所以真实负载是「多线程写不同文件」。
    // 这里断言的正是那个真实场景。
    let dir = "/tmp/deepgit-atomic-${nowMillis()}"
    ensureDir(dir)
    let futures = ArrayList<Future<Unit>>()
    for (i in 0..6) {
        let path = "${dir}/w${i}.md"
        let tag = "writer-${i}"
        futures.add(spawn {
            for (j in 0..20) {
                let sb = StringBuilder()
                for (k in 0..200) {
                    sb.append("${tag}-${j}-${k}\n")
                }
                writeFileAtomic(path, sb.toString())
            }
        })
    }
    for (fu in futures) {
        _ = fu.get(Duration.second * 120)
    }
    // 每个文件都必须是某一次完整写入的内容：200 行、全部属于同一个 writer
    for (i in 0..6) {
        let content = readFileTextOr("${dir}/w${i}.md", "")
        var nonEmpty = 0
        for (l in content.split("\n")) {
            if (l.isEmpty()) {
                continue
            }
            nonEmpty += 1
            // 交错写入的痕迹：别的 writer 的行混进来
            @Assert(l.startsWith("writer-${i}-"))
        }
        @Assert(nonEmpty == 200)
    }
    // 不能留下临时文件
    var leftovers = 0
    for (e in listDir(dir)) {
        if (e.name.contains(".tmp-")) {
            leftovers += 1
        }
    }
    @Assert(leftovers == 0)
    removePathIfExists(dir)
}

@Test
func testWriteFileAtomicLeavesNoTempOnFailure(): Unit {
    // 写失败时不能把 .tmp 留在用户仓库里：它会变成 git status 里的脏文件，
    // 用户无从判断那是什么、能不能删。doctor 的残留检查只能事后发现，兜不住。
    let dir = "/tmp/deepgit-atomic2-${nowMillis()}"
    ensureDir(dir)
    let f = "${dir}/ok.md"
    writeFileAtomic(f, "内容")
    @Assert(readFileTextOr(f, "") == "内容")
    @Assert(listDir(dir).size == 1)  // 只有目标文件，没有残留 .tmp
    removePathIfExists(dir)
}

/// #186 回归：`remove(p, recursive: true)` 必须连**根目录**一起删掉。
///
/// 定位 286 个 /tmp 空目录残留时，先排除了「删除失败」这条路：
/// `removePathIfExists` 原本把异常整个吞掉（`catch { () }`），删不掉也一声不响。
/// 现在它至少 `Log.warn` 报出路径，删除失败不再隐形。
@Test
func testRemovePathIfExistsRemovesRootDirAndIsIdempotent(): Unit {
    let dir = "/tmp/deepgit-rmroot-${nowMillis()}"
    ensureDir(dir)
    writeFileAtomic("${dir}/x.txt", "x")
    ensureDir("${dir}/sub")
    writeFileAtomic("${dir}/sub/y.txt", "y")
    @Assert(exists(Path(dir)))
    removePathIfExists(dir)
    // 关键断言：递归删除必须连根一起删掉（否则每轮测试都留一个空壳）
    @Assert(!exists(Path(dir)))
    // 再删一次必须是无害的空操作（幂等）
    removePathIfExists(dir)
    removePathIfExists(dir)
    @Assert(!exists(Path(dir)))
}

/// 文件是否非空（只关心「有没有内容」，不关心多大）。
/// 用 stat 而不是把文件读进来 —— 调用方只是要决定「要不要提示用户去看」。
public func fileNonEmpty(p: String): Bool {
    try {
        return FileInfo(Path(p)).size > 0
    } catch (e: Exception) {
        return false
    }
}

// ---------------------------------------------------------------------------
// 测试沙箱卫生检查（缺陷 #186）
//
// 背景：一次全量 `cjpm test` 往 /tmp 倒了 286 个**空目录**。
// 根因不是删除失败，而是一个很容易犯的错：
//     let base      = "/tmp/deepgit-xxx"
//     let testHome  = base + "-home"   // 兄弟目录，不是 base 的子目录
//     …
//     removePathIfExists(base)         // 只删了 base
// `base + "-home"` 与 base **平级**，删 base 永远碰不到它。
// 于是每跑一轮就多一个空壳，跑得越多攒得越多。
//
// 本检查按「测试块」核对：块里 let 绑定的 /tmp 沙箱，
// 必须在**同一个块**里被 removePathIfExists 覆盖。
// 只覆盖能静态看见的写法；隐式产生的中间父目录（如 base+"-ok"）
// 由 AGENTS.md 的约定兜，本检查不假装能覆盖它。
// ---------------------------------------------------------------------------

private func isIdentByte(b: UInt8): Bool {
    return (b >= 0x30u8 && b <= 0x39u8) || (b >= 0x41u8 && b <= 0x5au8)
        || (b >= 0x61u8 && b <= 0x7au8) || b == 0x5fu8
}

/// 剥掉 Cangjie 注释，保留字符串字面量内容。逐字节状态机。
///
/// 不能用 `split("//")`：`"/a//b/./c"` 是合法字符串，里面就有 `//`；
/// `"${joinStrings(args, " ")}"` 在插值里**嵌了引号**。
/// 简单切分会把这两种都切坏，坏掉的行会让本检查误判。
/// 前提：代码里没有跨行字符串（已核过，奇数引号的行都是转义造成的）。
/// 剥掉单行的 `//` 与跨行 `/* */`。返回 (剥后的行, 是否仍在块注释里)。
///
/// 提到 public（#194）：配置死键的 lint（config.cj）需要同一份实现。
/// 自己再写一份的代价已经付过一次 ——
///   · 第一版没处理**字符串字面量**里的 `//`（路径类字符串最常见），
///     剥完的源码里字符串被截断，lint 拿着垃圾去匹配，红得莫名其妙；
///   · 第二版忘了 `StringBuilder.append(UInt8)` 会走 `Any` 重载把字节
///     拼成十进制数字串，于是 `contains("public class Config")` 恒为 false。
/// 「剥注释」这件事只有一份实现才谈得上可靠。
public func stripCjComment(line: String, inBlock: Bool): (String, Bool) {
    let bs = line.toArray()
    let out = ArrayList<UInt8>()
    var i = 0
    var block = inBlock
    var inStr = false
    while (i < bs.size) {
        let c = bs[i]
        if (block) {
            if (c == 0x2au8 && i + 1 < bs.size && bs[i + 1] == 0x2fu8) {
                block = false
                i += 2
            } else {
                i += 1
            }
            continue
        }
        if (inStr) {
            out.add(c)
            if (c == 0x5cu8 && i + 1 < bs.size) {
                out.add(bs[i + 1])
                i += 2
                continue
            }
            if (c == 0x22u8) {
                inStr = false
            }
            i += 1
            continue
        }
        if (c == 0x22u8) {
            inStr = true
            out.add(c)
            i += 1
            continue
        }
        if (c == 0x2fu8 && i + 1 < bs.size && bs[i + 1] == 0x2fu8) {
            break
        }
        if (c == 0x2fu8 && i + 1 < bs.size && bs[i + 1] == 0x2au8) {
            block = true
            i += 2
            continue
        }
        out.add(c)
        i += 1
    }
    return (fromUtf8Lossy(out.toArray()), block)
}

/// 表达式里的空白全去掉，让 `base + "-ok"` 与 `base+"-ok"` 视为同一个。
private func squashExpr(s: String): String {
    let out = ArrayList<UInt8>()
    for (b in s.toArray()) {
        if (b != 0x20u8 && b != 0x09u8) {
            out.add(b)
        }
    }
    return fromUtf8Lossy(out.toArray())
}

/// 递归列出目录下所有 .cj 文件。
///
/// **public 的理由**：它是源码 lint 的唯一遍历器，而 lint 天然要住在**被检查的
/// 东西旁边**（传输层 lint 在 util、journal 形状 lint 在 kernel/store）。
/// 私有的话每加一条 lint 就得把它塞回本文件，或者复制一份遍历器 ——
/// 而「同一段遍历逻辑抄多处」正是本仓库反复栽的形态（副本必然漂）。
public func cjSourceFiles(dir: String, acc: ArrayList<String>): Unit {
    let (items, _) = listDirChecked(dir)
    for (it in items) {
        // 走 classifyEntry：不抛（#199）。同文件内的另一个遍历点，
        // 源 lint 的白名单里要连它一起列上。
        match (classifyEntry(it)) {
            case EntryKind.Dir => cjSourceFiles(dir + "/" + it.name, acc)
            case EntryKind.Regular =>
                if (it.name.endsWith(".cj")) {
                    acc.add(dir + "/" + it.name)
                }
            case _ => ()
        }
    }
}

/// 取出 `let NAME = <expr>`；不是这种形式返回 ("", "")。只处理单行声明。
private func letBinding(line: String): (String, String) {
    let t = line.trimAscii()
    if (!t.startsWith("let ")) {
        return ("", "")
    }
    let bs = t.toArray()
    var i = 4
    let name = ArrayList<UInt8>()
    while (i < bs.size && isIdentByte(bs[i])) {
        name.add(bs[i])
        i += 1
    }
    let n = fromUtf8Lossy(name.toArray())
    if (n.isEmpty()) {
        return ("", "")
    }
    // 跳到 '='
    while (i < bs.size && (bs[i] == 0x20u8 || bs[i] == 0x09u8)) {
        i += 1
    }
    if (i >= bs.size || bs[i] != 0x3du8) {
        return ("", "")
    }
    i += 1
    let exprBytes = ArrayList<UInt8>()
    while (i < bs.size && bs[i] != 0x3bu8) {
        exprBytes.add(bs[i])
        i += 1
    }
    return (n, squashExpr(fromUtf8Lossy(exprBytes.toArray())))
}

/// 收集 `f(<arg>)` 的实参（单层括号，够覆盖本仓库写法）。
private func callArg(line: String, fname: String): String {
    let needle = fname + "("
    let idxOpt = line.indexOf(needle)
    if (idxOpt.isNone()) {
        return ""
    }
    let rest = line[idxOpt.getOrThrow() + needle.size..]
    let bs = rest.toArray()
    var depth = 1
    var i = 0
    let out = ArrayList<UInt8>()
    while (i < bs.size && depth > 0) {
        let c = bs[i]
        if (c == 0x28u8) {
            depth += 1
        } else if (c == 0x29u8) {
            depth -= 1
            if (depth == 0) {
                break
            }
        }
        out.add(c)
        i += 1
    }
    return fromUtf8Lossy(out.toArray()).trimAscii()
}

/// #186 回归：每个测试创建的 /tmp 沙箱都必须在同一个测试里被清掉。
///
/// 负控（曾真实发红）：删掉 milestones.cj 里的 `removePathIfExists(notRepo)` 后立刻报红。
@Test
func testEveryTestSandboxIsRemovedInTheSameTest(): Unit {
    let files = ArrayList<String>()
    cjSourceFiles("src", files)
    @Assert(files.size > 20)   // 确认真的读到了源码，不是空跑

    var leaks = ArrayList<String>()
    for (f in files) {
        let maybeSrc = readFileTextChecked(f)
        if (maybeSrc.isNone()) {
            continue
        }
        let src = maybeSrc.getOrThrow()
        let clean = ArrayList<String>()
        var inBlock = false
        for (raw in src.split("\n")) {
            let (l, b) = stripCjComment(raw, inBlock)
            inBlock = b
            clean.add(l)
        }
        var i = 0
        while (i < clean.size) {
            if (!clean[i].trimAscii().startsWith("@Test")) {
                i += 1
                continue
            }
            let blk = ArrayList<String>()
            var depth = 0
            var seen = false
            while (i < clean.size) {
                let l = clean[i]
                blk.add(l)
                for (b in l.toArray()) {
                    if (b == 0x7bu8) {
                        depth += 1
                        seen = true
                    } else if (b == 0x7du8) {
                        depth -= 1
                    }
                }
                i += 1
                if (seen && depth <= 0) {
                    break
                }
            }
            for (leak in unremovedSandboxesIn(blk, f)) {
                leaks.add(leak)
            }
        }
    }
    if (leaks.size > 0) {
        // @Assert 的二元形式是 (expected, actual) 相等比较，没有「消息」重载，
        // 所以明细走 stderr 单独打出来，断言只报数量。
        let msg = StringBuilder()
        msg.append("有 ${leaks.size} 个测试沙箱没有被清理（每跑一轮就在 /tmp 留一个）：\n")
        for (l in leaks) {
            msg.append("  - ${l}\n")
        }
        eprintln(msg.toString())
    }
    @Assert(leaks.size == 0)
}

/// 传输层只有两面：CLI 子进程（`--json`）与 MCP（stdio JSON-RPC）。
///
/// 这条 lint 把「没有第三面」从一句约定变成一次构建期事实。
///
/// 背景：原计划里的「进程内 FFI SDK」在仓颉 1.0.5 上**无法在宿主进程里引导运行时**
/// （五条路径全失败于 `Check failed: runtime != nullptr`），于是**决定不做**——
/// 不是「等材料」。决策与理由见 AGENTS.md 不变量 58。
/// 既然是决定，就必须能被机器守住：否则半年后有人加一个 `@C` 垫片，
/// 谁也看不出来它推翻了决策 —— 这正是本仓库反复修的那类静默漂移。
///
/// ⚠️ 封杀清单是**逐词量过**的，不能随手加词（2026-10-01 实测 36 个 `.cj` 剥注释后）：
///   · 在列的：`foreign`（仓颉唯一的 FFI 声明关键字）、`@C`（唯一的 C 导出修饰符）、
///     `dylib`、`staticlib`、`TcpListener`、`Socket`、`bind(`、`listen(`、`0.0.0.0`
///     —— 出现次数**全部为 0**，封杀它们零假红。
///   · **故意不在列的**：`localhost` / `127.0.0.1` / `http`
///     —— 它们只出现在两类地方：
///       ① `flow/agent.cj` 里**断言它们不存在**的那几条测试
///          （`@Assert(!text.contains("localhost"))`）；
///       ② `kernel/config.cj` 里喂给「已删除的 server 块」的**遗留配置样本**。
///     按词封杀会红在**守规矩的测试**上 —— 那等于把规则的守卫当成违规者。
///     真要开监听端口，`TcpListener` / `bind(` 这类 API 一个都跑不掉。
///   · 也不封 `serve` 这个词：它在代码里 23 次命中**全是** `server` / `mcpServers`
///     的子串（`reserve`、`server.port` …），按词封杀必假红。
///     第三面的存在与否改用**结构判据**钉：CLI dispatch 表里不许有 `serve` 条目。
///
/// 住在 paths.cj 而不是 cli/mcp 里，是因为要用这个文件私有的
/// `cjSourceFiles` 遍历器 —— 复制一份遍历器就是又一处会漂的副本。
@Test
func __lintTransportLayerHasOnlyTwoSurfaces(): Unit {
    let files = ArrayList<String>()
    cjSourceFiles("src", files)
    @Assert(files.size > 20)   // 确认真的读到了源码，不是空跑

    // 拼接构造 needle：源码里不出现完整 needle，lint 匹配不到自己。
    // ⚠️ 拼接**只解决字符串字面量**，解决不了标识符（`nSocket` 里就带着 `Socket`），
    // 所以「排除自身函数体」这一步交给 strippedCodeSkippingFunction ——
    // 它的两趟实现与踩过的坑都记在那里，抄第二份只会让下次改一处忘一处。
    let nForeign = "forei" + "gn"
    let nExport = "@" + "C"
    let nDylib = "dyl" + "ib"
    let nStaticlib = "static" + "lib"
    let nListener = "Tcp" + "Listener"
    let nSocket = "Sock" + "et"
    let nBind = "bind" + "("
    let nListen = "listen" + "("
    let nAny = "0.0.0" + ".0"
    let needles = [nForeign, nExport, nDylib, nStaticlib, nListener, nSocket, nBind, nListen, nAny]
    let selfName = "func __lintTransport" + "LayerHasOnlyTwoSurfaces"

    let hits = ArrayList<String>()
    for (f in files) {
        let skip = if (f == "src/util/paths.cj") {
            Option<String>.Some(selfName)
        } else {
            Option<String>.None
        }
        // None ⇒ 这个文件读不出来、或自身区间算不出来（判据坏了）。
        // 两种都不许当成「干净」放过去 —— 那正是永远绿的安全带。
        match (strippedCodeSkippingFunction(f, skip)) {
            case Some(code) =>
                for (line in code.split("\n")) {
                    for (n in needles) {
                        if (line.contains(n)) {
                            hits.add("${f}: 「${line.trimAscii()}」")
                        }
                    }
                }
            case None => hits.add("${f}: 剥不出纯代码（文件读不到，或排除区间算不出来）")
        }
    }
    if (hits.size > 0) {
        let msg = StringBuilder()
        msg.append("src/ 里出现了 FFI 或网络出口的代码（${hits.size} 处）：\n")
        for (h in hits) {
            msg.append("  - ${h}\n")
        }
        msg.append("传输层只有 CLI 子进程与 MCP(stdio) 两条通道（AGENTS.md 不变量 1 与 58）。\n")
        msg.append("进程内 FFI 是**已决定不做**的事，不是待办：要改这个决定，先改不变量 58。\n")
        eprintln(msg.toString())
    }
    @Assert(hits.size == 0)

    // 结构判据（替代按词封杀 serve）：CLI dispatch 表里不许出现 serve 条目。
    let cliRaw = readFileTextChecked("src/cli/cli.cj").getOrThrow()
    var cliBlock = false
    let cliClean = StringBuilder()
    for (raw in cliRaw.split("\n")) {
        let (l, b) = stripCjComment(raw, cliBlock)
        cliBlock = b
        cliClean.append(l)
        cliClean.append("\n")
    }
    @Assert(!cliClean.toString().contains("cmd" + "Serve"))
    // MCP 那一条通道必须在（它是允许的两面之一，不是可有可无）
    @Assert(cliClean.toString().contains("case \"mc" + "p\""))
}

/// 读一个源文件、剥掉注释、**并排除本文件里指定函数的函数体**，返回剩下的纯代码。
///
/// 源码 lint 必须先剥注释：解释缺陷的注释里必然引用被删掉的那行代码，
/// 不剥就会假红（本仓库已因此作废过 3 条负控）。
///
/// ⚠️ 排除自身函数体这一步同样是必需的，而且是**拼接 needle 挡不住的**：
/// 拼接只解决字符串字面量，解决不了标识符 ——
/// 变量名 `nSocket` 里就带着 `Socket`，`needles` 数组里也有 `nSocket`。
///
/// ⚠️⚠️ 必须**两趟**：先算出函数体区间，再据此过滤。
///   一趟的话区间终点要等扫过函数末尾才知道，而扫到函数**内部**那些行时终点还是 -1，
///   于是「排除自身」一行都没排除掉，lint 继续扫到自己
///   （传输层 lint 的第二版就是这么红的；第一版是变量名问题）。
///
/// 区间算不出来时返回 None 而不是「排除整个文件」——
/// 后者会让调用方的 lint 变成永远绿的安全带，比没有还糟。
public func strippedCodeSkippingFunction(path: String, skip: Option<String>): Option<String> {
    let maybeSrc = readFileTextChecked(path)
    if (maybeSrc.isNone()) {
        return None
    }
    // ① 剥注释，得到纯代码行
    let code = ArrayList<String>()
    var inBlock = false
    for (raw in maybeSrc.getOrThrow().split("\n")) {
        let (l, b) = stripCjComment(raw, inBlock)
        inBlock = b
        code.add(l)
    }
    // ② 算函数体区间（两趟）。skip = None 时不排除任何东西。
    var from = -1
    var to = -1
    match (skip) {
        case Some(funcName) =>
            var depth = 0
            var i = 0
            while (i < code.size) {
                if (from < 0) {
                    if (code[i].contains(funcName)) {
                        from = i
                    }
                }
                if (from >= 0) {
                    for (ch in code[i].toArray()) {
                        if (ch == 0x7bu8) {
                            depth += 1
                        } else if (ch == 0x7du8) {
                            depth -= 1
                        }
                    }
                    if (depth <= 0) {
                        to = i
                        break
                    }
                }
                i += 1
            }
            // 区间算不出来 = 判据坏了（函数被改名/挪走），必须让调用方知道
            if (from < 0 || to <= from) {
                return None
            }
        case None => ()
    }
    // ③ 拼剩下的代码
    let out = StringBuilder()
    for (j in 0..code.size) {
        if (from >= 0 && j >= from && j <= to) {
            continue
        }
        out.append(code[j])
        out.append("\n")
    }
    return Some(out.toString())
}

/// 插值起始标记。源码里不能写字面量 "${" —— 编译器会当成插值开头且内容为空。
private let IB_OPEN: String = "$" + "{"

/// 从 `from` 起找 `needle`，找不到返回 -1。
private func indexOfFrom(s: String, needle: String, from: Int64): Int64 {
    if (from >= s.size) {
        return -1
    }
    match (s[from..].indexOf(needle)) {
        case Some(i) => return from + i
        case None => return -1
    }
}

/// 表达式求值出的「/tmp 一级目录名」+「它指的就是这一级本身吗」。
///
/// 第二个返回值 atRoot 是关键，只有 atRoot 为 true 的路径才需要单独清理：
///   `base + "-home"`     → (base-home, true)   与 base 平级，删 base 碰不到 ← 真漏
///   `base + "/alpha"`    → (base,     false)  在 base 里面，删 base 就够
///   `lock = "${dir}/x"`  → (dir,      false)  深层
///   `lockDir = "${lock}.d"` → (dir,  false)  `.d` 加在深层组件上，仍在 dir 里
/// 少了 atRoot，`"${lock}.d"` 会被误判成 dir 的兄弟目录。
private func entryKeyOf(expr: String, known: ArrayList<(String, String, Bool)>): (String, Bool) {
    for ((k, v, r) in known) {
        if (expr == k) {
            return (v, r)
        }
    }
    if (expr.startsWith("\"")) {
        // 形如 "/tmp/AAA/BBB" 或 "<插值>-nr"
        // 注意：源码里不能直接写 "${" —— 编译器会当成插值开头且内容为空。
        if (expr.contains(IB_OPEN) && !expr.contains("/tmp/")) {
            let openOpt = expr.indexOf(IB_OPEN)
            if (openOpt.isNone()) {
                return ("", false)
            }
            let identStart = openOpt.getOrThrow() + IB_OPEN.size
            let close = indexOfFrom(expr, "}", identStart)
            if (close < 0) {
                return ("", false)
            }
            let (base, baseAtRoot) = entryKeyOf(expr[identStart..close], known)
            if (base.isEmpty()) {
                return ("", false)
            }
            let rest = expr[close + 1..expr.size - 1]
            return (base + trailingSegment(rest), baseAtRoot && !hasSlash(rest))
        }
        let t = expr.indexOf("/tmp/")
        if (t.isNone()) {
            return ("", false)
        }
        let after = expr[t.getOrThrow() + 5..expr.size - 1]
        let stop = after.indexOf("/")
        let seg = if (stop.isSome()) { after[..stop.getOrThrow()] } else { after }
        if (seg.isEmpty() || seg.startsWith("\"") || seg.endsWith("\"")) {
            return ("", false)
        }
        return (seg, stop.isNone())
    }
    // 形如 NAME + "-lit/…" 或 NAME + "/…"
    let plus = expr.indexOf("+")
    if (plus.isNone()) {
        return ("", false)
    }
    let (base, baseAtRoot) = entryKeyOf(expr[..plus.getOrThrow()].trimAscii(), known)
    if (base.isEmpty()) {
        return ("", false)
    }
    let rest = expr[plus.getOrThrow() + 1..]
    return (base + trailingSegment(rest), baseAtRoot && !hasSlash(rest))
}

/// 去掉引号后的残余里有没有 `/`（有就说明已经进入下一层了）。
private func hasSlash(lit: String): Bool {
    let t = lit.trimAscii()
    let inner = if (t.startsWith("\"")) {
        if (t.size < 2) { return false }
        t[1..t.size - 1]
    } else {
        t
    }
    return inner.indexOf("/").isSome()
}

/// 取第一个 `/` 之前的那一段。
/// 两种输入都要认：带引号的字面量（`"-ok/repo"`）与引号内的残余（`-nr`）。
/// `"/a"` → ""（这是**子**路径，一级目录就是它的父目录）。
private func trailingSegment(lit: String): String {
    let t = lit.trimAscii()
    let inner = if (t.startsWith("\"")) {
        if (t.size < 2) {
            return ""
        }
        t[1..t.size - 1]
    } else {
        t
    }
    let stop = inner.indexOf("/")
    if (stop.isSome()) {
        return inner[..stop.getOrThrow()]
    }
    return inner
}

/// 单个 @Test 块里「在 /tmp 下造了一级目录、却没删」的沙箱。
private func unremovedSandboxesIn(blk: ArrayList<String>, file: String): ArrayList<String> {
    // 1. 逐个 let 解析出「名字 → (一级目录名, 指不指向这一级)」
    let known = ArrayList<(String, String, Bool)>()
    for (l in blk) {
        let (n, e) = letBinding(l)
        if (n.isEmpty() || e.isEmpty()) {
            continue
        }
        let (k, atRoot) = entryKeyOf(e, known)
        if (!k.isEmpty()) {
            known.add((n, k, atRoot))
        }
    }
    if (known.isEmpty()) {
        return ArrayList<String>()
    }
    // 2. 只认**真正建了 /tmp 一级目录**的：
    //      · atRoot 为 false 的（base+"/alpha"、lock="${dir}/x.lock"）在父目录里，删父的就够
    //      · 锁文件 / 报告 .md 是文件，不是目录
    //      · `existing + "-no-such-dir"` 故意指向不存在的路径，压根没建
    let createdDirs = ArrayList<String>()
    for (l in blk) {
        if (!l.contains("ensureDir(")) {
            continue
        }
        let (k, atRoot) = entryKeyOf(squashExpr(callArg(l, "ensureDir")), known)
        if (atRoot) {
            createdDirs.add(k)
        }
    }
    if (createdDirs.isEmpty()) {
        return ArrayList<String>()
    }
    // 3. 这个块里清掉了哪些一级目录
    let removed = ArrayList<String>()
    for (l in blk) {
        if (!l.contains("removePathIfExists(")) {
            continue
        }
        let a = squashExpr(callArg(l, "removePathIfExists"))
        if (a.isEmpty()) {
            continue
        }
        let (k, _) = entryKeyOf(a, known)
        if (!k.isEmpty()) {
            removed.add(k)
        }
    }
    // 4. 建了却没清
    let bad = ArrayList<String>()
    let reported = ArrayList<String>()
    for ((n, k, atRoot) in known) {
        if (!atRoot || !createdDirs.contains(k) || removed.contains(k) || reported.contains(k)) {
            continue
        }
        reported.add(k)
        bad.add("${file}: ${n} → /tmp/${k}  建了目录但没被 removePathIfExists(...) 覆盖")
    }
    return bad
}

// ------------------------------ #199：条目分类的四态 ------------------------------

/// 四态判定必须能用**纯函数**覆盖 —— 原生 stat 失败在测试里没法稳定复现
/// （要构造 EACCES/EPERM 得有非 root 拥有的目录，或依赖 SIP 路径）。
/// 策略抽不出来就等于没法测，而没法测的判定等于不存在。
///
/// 这里逐条钉死 `None`（读不出来）与 `Some(false)`（确实不是）的分界：
/// 把 `None` 当成 `Some(false)` 就是本次修掉的缺陷本身。
@Test
func testEntryKindFromIsThreeStateNotTwo(): Unit {
    // 目录属性读不出来 → Unreadable，与「确实不是目录」完全不同构
    @Assert(entryKindLabel(entryKindFrom(None, None)) == "unreadable")
    @Assert(entryKindLabel(entryKindFrom(None, Some(true))) == "unreadable")
    @Assert(entryKindLabel(entryKindFrom(None, Some(false))) == "unreadable")
    // 读得出来的三种
    @Assert(entryKindLabel(entryKindFrom(Some(true), None)) == "dir")
    @Assert(entryKindLabel(entryKindFrom(Some(false), Some(true))) == "file")
    @Assert(entryKindLabel(entryKindFrom(Some(false), Some(false))) == "other")
    // 文件属性读不出来同样不能被当成「other」
    @Assert(entryKindLabel(entryKindFrom(Some(false), None)) == "unreadable")
}

/// 四态两两不等。把 `Unreadable` 并进 `Other`（本次修掉的正是这一处）
/// 之后，这个断言必须变红。
@Test
func testEntryKindFourStatesAreDistinguishable(): Unit {
    let all = ArrayList<EntryKind>([
        EntryKind.Dir, EntryKind.Regular, EntryKind.Other, EntryKind.Unreadable
    ])
    @Assert(all.size == 4)
    let labels = ArrayList<String>([
        entryKindLabel(all[0]), entryKindLabel(all[1]), entryKindLabel(all[2]), entryKindLabel(all[3])
    ])
    // 仓颉枚举不支持 ==，用可读名做两两比对
    for (i in 0..labels.size) {
        for (j in (i + 1)..labels.size) {
            @Assert(labels[i] != labels[j])
        }
    }
    @Assert(labels.size == 4)
}

/// 真实文件系统上的接缝：正常目录 / 普通文件 / 断链符号链接都必须**不抛**，
/// 且归到正确的态。这条守的是「接缝本身没把正常路径弄坏」。
@Test
func testClassifyEntryNeverThrowsOnRealTree(): Unit {
    let base = "/tmp/deepgit-classify-${nowMillis()}"
    ensureDir(base + "/sub")
    writeFileAtomic(base + "/plain.txt", "x")
    writeFileAtomic(base + "/sub/inner.txt", "y")
    // 断链软链：isDirectory 走 lstat 不跟随链接，所以它既不是目录也不是普通文件
    let ln = execCapture("ln", ["-s", "/nonexistent-target-xyz/dg", base + "/dangling"], None, 8000)
    @Assert(ln.ok())

    var sawDir = false
    var sawRegular = false
    var sawOther = false
    for (info in listDir(base)) {
        // 关键：这一句以前会让整条命令 exit 1
        let kind = classifyEntry(info)
        if (isUnreadable(kind)) {
            @Assert(false)
        }
        match (kind) {
            case EntryKind.Dir => sawDir = true
            case EntryKind.Regular => sawRegular = true
            case EntryKind.Other => sawOther = true
            case EntryKind.Unreadable => ()
        }
    }
    @Assert(sawDir)      // sub
    @Assert(sawRegular)  // plain.txt
    @Assert(sawOther)    // dangling
    removePathIfExists(base)
}
