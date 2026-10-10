// 锁：防止并发更新同一项目。
package moongit.kernel

import std.collection.*
import std.fs.*
import std.posix.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

/// 简单 pid+时间戳文件锁；超过 staleMs 的陈旧锁会被接管。
///
/// 锁用「独占创建目录」实现，不是 exists() + writeTo()。
/// 旧实现是 check-then-act：`if (!fileExists(lockFile)) { File.writeTo(...) }`
/// 在 exists 与 writeTo 之间有 TOCTOU 窗口，两个进程同时通过检查、双双 acquired=true，
/// 一起进入临界区 —— 互斥形同虚设，而且两个命令都返回成功。
/// mkdir 在内核里是原子的：已存在即失败，只有一个进程能拿到锁。
///
/// ⚠️ 锁名必须按「互斥哪个资源」命名，不能按「做哪种操作」命名。
/// 同一项目的 update / track / deep 写的是同一批文件（store 的 progress/state/journal
/// 与用户仓库里 README/AGENTS 的托管区），必须共用同一个锁名。
public func withLock<T>(lockFile: String, staleMs: Int64, body: () -> T): T {
    ensureDir(dirname(lockFile))
    // 旧版本留下的 .lock 是普通文件，它从来没有提供过真正的互斥，直接清掉
    if (fileExists(lockFile) && !isDirectoryPath(lockFile)) {
        Log.debug("清理旧格式锁文件：${lockFile}")
        removePathIfExists(lockFile)
    }
    let lockDir = "${lockFile}.d"
    if (!tryAcquire(lockDir, staleMs)) {
        throw DgError("LOCKED", "该项目正在更新中（另一个 moonGit 进程持锁），请稍后重试", 1, Some(lockFile))
    }
    // ⚠️ 释放必须绑在 finally 上，不能绑在 catch (e: Exception) 上。
    //
    // 仓颉的 Error 不是 Exception 的子类，Out of memory / StackOverflow 这类
    // Error 会直接穿透 catch (e: Exception) —— 锁目录就留在盘上了。
    // 实测：51MB 注册表（30 万项目）触发 OOM 后，registry.lock.d 留在原地，
    // 而此时**没有任何 moonGit 进程在运行**，后续命令却要白等一个 60 秒的
    // 陈旧锁窗口，并报出与事实不符的「另一个 moonGit 进程持锁」。
    // finally 块无论是否有异常都会执行（异常未被捕获时也会执行，然后重新抛出），
    // 所以 Error 路径同样能释放。
    try {
        return body()
    } finally {
        removePathIfExists(lockDir)
    }
}

/// 抢锁决策。**纯函数**，无 IO —— 目的是让「活 + 旧」这个组合能被单独钉住。
///
/// ⚠️ 缺陷 #178：原来没有这个函数，判定内联在 `tryAcquire` 里：
///   持锁者已死            → 立即接管（不必等满 staleMs，那次修复的收益，保留）
///   持锁者**还活着**     → 却仍然去看锁龄，超了 staleMs 就照抢不误
/// 而 `holderAlive` 的文档写着「宁可等，也不要在活进程头上抢锁」——
/// 代码与它自己写下的约定相反。
///
/// 后果是可复现的：锁目录的 mtime 只在**加锁那一刻**写，body 期间不刷新，
/// 而 update 的 staleMs = 600000（10 分钟）、deep = 900000（15 分钟）。
/// 于是**任何跑过 10 分钟的 update 都会在运行途中丢锁**，
/// 第二个进程得以同时进入临界区，并发改写同一份 progress.json /
/// README 托管区，而两个进程都 exit 0。
///
/// 实测（本轮）：持锁 pid 活着、锁目录 mtime 回拨 20 分钟 →
///   `moongit update repo` 直接进入临界区、exit 0、原 holder.json 被覆盖删除；
/// 同一实验把 mtime 保持新鲜 → 正确报「该项目正在更新中」、exit 1、锁完好。
///
/// 契约：**持锁者活着 = 绝不动它，年龄一概不看。**
public enum AcquireDecision {
    /// 立刻接管（持锁者已死）
    | TakeOver
    /// 等待（持锁者活着，或年龄读不出来）
    | Wait
}

/// 持锁者的可判定状态。三态而不是 Bool ——
/// 「查不到持锁者」与「持锁者已死」在**恢复通道**上是两件事（见 M23）。
public enum HolderState {
    /// holder.json 里有 pid 且进程活着
    | HolderAlive
    /// holder.json 里有 pid 且进程已退出
    | HolderDead
    /// 判不出来：holder.json 缺失/不是合法 JSON/pid 非法/kill -0 超时
    | HolderUnknown
}

/// 纯判定：给定「持锁者状态」与「锁龄」，决定抢还是不抢。**不碰文件系统。**
///
/// `ageMs < 0` 表示年龄读不出来 —— 那是「不知道」，按「还活着」处理。
///
/// ⚠️ M23（审查）：`HolderUnknown` **必须有一条恢复通道**，否则
/// 「SIGKILL 落在 mkdirExclusive 与 writeHolderInfo 之间」或「writeHolderInfo
/// 因磁盘满静默失败」留下的锁目录里没有 holder.json，HolderUnknown 被当成
/// 活着 ⇒ 锁永远无人接管，后续所有命令持续报「另一个 moonGit 进程持锁」，
/// 只能手动删目录。#178 移除 staleMs 兜底时把这一档一起带走了。
///
/// 这里把 staleMs 明确降级为**兜底**（不变量 34 的原话）：判据仍然是
/// 「持锁者还活着吗」，只有在那个判据**不可得**时才问锁龄 ——
/// 一个连自己 pid 都没写下来的锁，年龄超过 update 的 staleMs（10 分钟）
/// 之后不可能是谁正在跑的临界区（那窗口只有毫秒级）。
public func acquireDecision(holder: HolderState, ageMs: Int64, staleMs: Int64): AcquireDecision {
    // 活着的持锁者：无论锁多老都不动。这条是本函数存在的全部理由（#178）。
    match (holder) {
        case HolderAlive => return AcquireDecision.Wait
        case HolderDead => return AcquireDecision.TakeOver
        case HolderUnknown => ()
    }
    // 查不到持锁者：只要年龄读得出来且超过兜底窗口，就接管。
    // 这给「没人能声称持有的锁」留下唯一一条自动恢复通道。
    if (ageMs >= 0 && ageMs >= staleMs) {
        return AcquireDecision.TakeOver
    }
    return AcquireDecision.Wait
}

/// 尝试独占获取锁：创建目录这一步本身就是原子的判据。
/// 失败时若发现是陈旧锁，接管后重试一次 —— 接管仍是原子的（谁先 mkdir 成功谁拿到）。
private func tryAcquire(lockDir: String, staleMs: Int64): Bool {
    if (mkdirExclusive(lockDir)) {
        writeHolderInfo(lockDir)
        return true
    }
    // 锁已存在。判定走 acquireDecision（纯函数，可单测）。
    //
    // ⚠️ 原来这里是两段：先 `if (!holderAlive)` 立即接管，
    // 然后**不管死活**都去看锁龄，超了 staleMs 就抢。
    // 于是「持锁者还活着 + 锁很旧」会被抢 —— 而锁龄只反映加锁那一刻，
    // body 期间不刷新，所以任何跑过 staleMs 的 update 都会在运行途中丢锁。
    // 详见 acquireDecision 的文档。
    let holder = holderState(lockDir)
    let ageMs = lockAgeMs(lockDir)
    match (acquireDecision(holder, ageMs, staleMs)) {
        // 持锁者还活着：绝不动它，年龄一概不看
        case AcquireDecision.Wait => return false
        case AcquireDecision.TakeOver =>
            Log.debug("持锁进程已退出，立即接管：${lockDir}")
    }
    removePathIfExists(lockDir)
    if (mkdirExclusive(lockDir)) {
        writeHolderInfo(lockDir)
        return true
    }
    return false
}

/// 持锁进程是否还活着。
///
/// holder.json 里记了 pid，但它历来**只被写、从不被读** ——
/// 于是「持锁进程早就没了」这件事，除了干等 staleMs 之外无从得知。
/// 而 staleMs 在 update 上是 600000ms（10 分钟）。
///
/// 实测（本轮真踩到）：一个被 kill 掉的 update 留下 project.lock.d，
/// 之后 10 分钟内每一次 update 都报
///     ✗ 该项目正在更新中（另一个 moonGit 进程持锁），请稍后重试
/// 而系统里**一个 moonGit 进程都没有**。用户看到的是「有别的进程在忙」，
/// 真相是「上次崩了」，这两件事的处置方式完全不同。
///
/// 注意这与 `finally` 那次修复不冲突：finally 解决的是仓颉 Error 穿透，
/// 而 SIGKILL / 掉电 / 断电时进程根本没机会执行任何代码，finally 也不会跑。
/// 唯一能救的就是「持锁者还活着吗」这个外部事实。
///
/// 判不出来的三种情况一律当作「还活着」：宁可等，也不要在活进程头上抢锁。
///   - holder.json 读不到（写 holder 时崩了）
///   - pid 解析不出来
///   - kill -0 执行失败（容器里没有 /bin/kill 等）
private func holderState(lockDir: String): HolderState {
    let holderPath = "${lockDir}/holder.json"
    let raw = readFileTextOr(holderPath, "")
    if (raw.isEmpty()) {
        // ⚠️ 这是 M23 的关键分支：不是「活着」，是「查不到」。
        // 当成活着 ⇒ 没有任何恢复通道，锁永久卡死。
        return HolderState.HolderUnknown
    }
    match (Json.parse(raw)) {
        case None => return HolderState.HolderUnknown
        case Some(j) =>
            let pid = Json.intAt(j, "pid", 0)
            if (pid <= 0) {
                return HolderState.HolderUnknown
            }
            if (processExists(pid)) {
                return HolderState.HolderAlive
            }
            return HolderState.HolderDead
    }
}

/// 进程是否存在。signal 0 只做权限/存在性检查，不真的发信号。
private func processExists(pid: Int64): Bool {
    let r = execCapture("/bin/kill", ["-0", "${pid}"], None, 3000)
    // 超时按「还活着」处理：判错方向必须是「多等」，不是「误抢」
    if (r.timedOut) {
        return true
    }
    return r.exitCode == 0
}

/// 原子创建目录。已存在时返回 false（不抛异常）。
private func mkdirExclusive(dir: String): Bool {
    try {
        // recursive: false —— 目录已存在会抛异常，正是我们要的判据
        Directory.create(Path(dir), recursive: false)
        return true
    } catch (e: Exception) {
        return false
    }
}

/// 持锁信息仅供诊断；mtime 即为加锁时刻，body 期间不刷新（避免长任务被误判为陈旧）。
private func writeHolderInfo(lockDir: String): Unit {
    try {
        let content = "{\"pid\":${getpid()},\"at\":\"${nowIso()}\"}"
        File.writeTo(Path("${lockDir}/holder.json"), content.toArray())
    } catch (e: Exception) {
        ()  // 诊断信息写不进去不影响互斥本身
    }
}

private func lockAgeMs(lockDir: String): Int64 {
    try {
        let info = FileInfo(Path(lockDir))
        return nowMillis() - info.lastModificationTime.toUnixTimeStamp().toMilliseconds()
    } catch (e: Exception) {
        return -1  // 读不到就当作「刚加锁」，宁可等也不误抢
    }
}

/// 抢不到锁时轮询等待，而不是立刻抛 LOCKED。
///
/// 适合临界区很短的场景（毫秒级的读-改-写）：两个终端同时 `milestone add`
/// 是完全正常的用法，直接报错毫无帮助 —— 等几十毫秒就轮到了。
/// 项目更新那种临界区长达数分钟的场合仍用 withLock 快速失败，
/// 让用户立刻知道「另一个 moonGit 正在更新这个项目」而不是干等。
public func withLockWaiting<T>(lockFile: String, staleMs: Int64, waitMs: Int64, body: () -> T): T {
    let deadline = nowMillis() + waitMs
    var result: Option<T> = None
    while (result.isNone()) {
        try {
            result = Some(withLock(lockFile, staleMs, body))
        } catch (e: DgError) {
            if (e.code != "LOCKED" || nowMillis() >= deadline) {
                throw e
            }
            sleep(Duration.millisecond * 20)
        }
    }
    return result.getOrThrow()
}

// ------------------------------ 测试 ------------------------------

@Test
func testWithLockRunsBody(): Unit {
    let dir = "/tmp/deepgit-lock-${nowMillis()}"
    ensureDir(dir)
    let lock = "${dir}/x.lock"
    let result = withLock(lock, 60000, {=> 42})
    @Assert(result == 42)
    @Assert(!isDirectoryPath("${lock}.d"))  // 释放（锁是目录形态）
    removePathIfExists(dir)
}

@Test
func testWithLockRejectsWhenHeld(): Unit {
    let dir = "/tmp/deepgit-lock2-${nowMillis()}"
    ensureDir(dir)
    let lock = "${dir}/x.lock"
    // 锁现在是目录形态：已存在即视为被持有
    ensureDir("${lock}.d")
    var threw = false
    try {
        withLock(lock, 600000, {=> 1})
    } catch (e: DgError) {
        threw = e.code == "LOCKED"
    }
    @Assert(threw)
    removePathIfExists(dir)
}

@Test
func testWithLockReleasesOnError(): Unit {
    let dir = "/tmp/deepgit-lock3-${nowMillis()}"
    ensureDir(dir)
    let lock = "${dir}/x.lock"
    try {
        withLock(lock, 60000, {=> throw DgError("X", "boom")})
    } catch (e: Exception) {
        ()
    }
    @Assert(!isDirectoryPath("${lock}.d"))
    removePathIfExists(dir)
}

@Test
func testWithLockIsMutuallyExclusiveUnderConcurrency(): Unit {
    // 旧实现是 check-then-act：exists() 与 writeTo() 之间有窗口，
    // 并发进入的两个进程会双双 acquired=true，一起跑 body。
    // 这里把窗口放大到必然命中：临界区里做「读-改-写」，非原子。
    // 互斥失效 → 计数丢失；互斥生效 → 恰好等于总次数。
    let dir = "/tmp/deepgit-lock4-${nowMillis()}"
    ensureDir(dir)
    let lock = "${dir}/x.lock"
    // 自己用原子计数器，但故意在临界区里做非原子的读-改-写
    let counter = AtomicInt64(0)
    let workers = 6
    let perWorker = 50

    let futures = ArrayList<Future<Unit>>()
    for (i in 0..workers) {
        futures.add(spawn {
            for (_ in 0..perWorker) {
                // 拿到 LOCKED 说明别人正持有 —— 这正是互斥生效，必须重试而不是跳过，
                // 否则计数本来就到不了总数，测不出任何东西
                var attempts: Int64 = 0
                while (attempts < 100000) {
                    attempts += 1
                    var got = false
                    try {
                        _ = withLock(lock, 60000, { =>
                            // 临界区：读-改-写，非原子。互斥失效就会丢计数
                            let cur = counter.load()
                            counter.store(cur + 1)
                        })
                        got = true
                    } catch (e: DgError) {
                        got = false
                    }
                    if (got) {
                        break
                    }
                }
            }
        })
    }
    for (f in futures) {
        _ = f.get(Duration.second * 180)
    }
    @Assert(counter.load() == workers * perWorker)
    @Assert(!isDirectoryPath("${lock}.d"))
    removePathIfExists(dir)
}

@Test
func testWithLockTakesOverStaleLock(): Unit {
    // 陈旧锁必须能被接管，否则进程被 kill -9 后项目会永久锁死
    let dir = "/tmp/deepgit-lock5-${nowMillis()}"
    ensureDir(dir)
    let lock = "${dir}/x.lock"
    ensureDir("${lock}.d")
    // 持锁信息写一个很久以前的时间点，模拟上次运行遗留
    writeFileAtomic("${lock}.d/holder.json", "{\"pid\":1,\"at\":\"2000-01-01T00:00:00\"}")
    // 把目录 mtime 往前推：staleMs 很小即可判定陈旧
    let result = withLock(lock, 0, {=> 7})
    @Assert(result == 7)
    @Assert(!isDirectoryPath("${lock}.d"))
    removePathIfExists(dir)
}

@Test
func testWithLockWaitingRetriesInsteadOfFailing(): Unit {
    // 全局文件（milestones.json / registry.json）的临界区只有毫秒级，
    // 两个终端同时 milestone add 是完全正常的用法 —— 抢不到锁就报错毫无帮助，
    // 等 20ms 就轮到了。
    let dir = "/tmp/deepgit-lock6-${nowMillis()}"
    ensureDir(dir)
    let lock = "${dir}/x.lock"
    ensureDir("${lock}.d")  // 已被别人持有

    // 抢不到时应在等待窗口内重试，而不是立刻抛 LOCKED
    var threw = false
    try {
        _ = withLockWaiting(lock, 600000, 300, {=> 1})
    } catch (e: DgError) {
        threw = e.code == "LOCKED"
    }
    @Assert(threw)  // 300ms 窗口内对方一直不放，超时后如实报错

    // 窗口够长时应当等到成功：先起一个线程在 100ms 后释放锁
    let holder = spawn {
        sleep(Duration.millisecond * 100)
        removePathIfExists("${lock}.d")
    }
    let got = withLockWaiting(lock, 600000, 5000, {=> 99})
    @Assert(got == 99)
    _ = holder.get(Duration.second * 30)
    removePathIfExists(dir)
}

/// 触发一个仓颉 Error（不是 Exception）用来验证锁的释放路径。
/// 必须是非尾递归：写成 `f(n+1) + 1` 是尾调用，可能被优化掉而根本不增长调用栈。
func boomByStackOverflow(depth: Int64): Int64 {
    let n = depth + 1
    let v = [boomByStackOverflow(n), 1][0]
    return v
}

@Test
func testLockIsReleasedWhenErrorEscapes(): Unit {
    // ⚠️ 仓颉的 Error 不是 Exception 的子类，Out of memory / StackOverflow
    // 会直接穿透 catch (e: Exception) —— 旧实现在 catch 里清锁，
    // 于是锁目录留在盘上。
    // 后果实测：51MB 注册表触发 OOM 后，没有任何 moonGit 进程在运行，
    // 后续命令却要白等 60 秒的陈旧锁窗口，并报出与事实不符的
    // 「另一个 moonGit 进程持锁」。
    let lock = "/tmp/dg_locktest_${nowMillis()}.lock"
    let lockDir = "${lock}.d"
    var escaped = false
    try {
        withLock<Int64>(lock, 60000, {
            // 栈溢出 = Error 而非 Exception
            => boomByStackOverflow(0)
        })
    } catch (e: Exception) {
        escaped = true
    } catch (e: Error) {
        escaped = true
    }
    @Assert(escaped)
    // 关键断言：锁目录必须已经消失
    @Assert(!isDirectoryPath(lockDir))

    // 立刻重新取锁必须成功（陈旧锁窗口 60 秒，绝不能被卡住）
    let start = nowMillis()
    withLock<Int64>(lock, 60000, {
        => if (isDirectoryPath(lockDir)) { 1 } else { 0 }
    })
    @Assert(nowMillis() - start < 5000)
    @Assert(!isDirectoryPath(lockDir))
}

@Test
func testLockIsReleasedOnExceptionToo(): Unit {
    // 对照组：Exception 路径本来就能释放，不能被新写法改坏
    let lock = "/tmp/dg_locktest2_${nowMillis()}.lock"
    let lockDir = "${lock}.d"
    var threw = false
    try {
        withLock<Int64>(lock, 60000, {
            => throw DgError.usage("故意失败")
        })
    } catch (e: DgError) {
        threw = true
    }
    @Assert(threw)
    @Assert(!isDirectoryPath(lockDir))
}

@Test
func testLockIsReleasedOnSuccess(): Unit {
    // 对照组：正常路径
    let lock = "/tmp/dg_locktest3_${nowMillis()}.lock"
    let lockDir = "${lock}.d"
    @Assert(withLock<Int64>(lock, 60000, { => 42 }) == 42)
    @Assert(!isDirectoryPath(lockDir))
}

@Test
func testLockHolderPidLivenessTakesOverDeadLockImmediately(): Unit {
    // 回归：holder.json 里的 pid 从来只被写、从不被读，
    // 于是「持锁进程早就没了」只能靠干等 staleMs 才知道。
    // update 的 staleMs 是 600000ms —— 一个被 kill 掉的 update 会让项目
    // 锁死 10 分钟，每次都报「另一个 moonGit 进程持锁」，
    // 而系统里一个 moonGit 进程都没有。
    // 实测（本轮真踩到）：被 kill 的 update 留下 project.lock.d，
    // 之后所有命令都报「另一个进程持锁」直到陈旧窗口结束。
    //
    // 这与 finally 那次修复不冲突：finally 管的是仓颉 Error 穿透，
    // SIGKILL / 掉电时进程根本没机会执行代码，finally 同样不会跑。
    let dir = "/tmp/deepgit-deadlock-${nowMillis()}"
    ensureDir(dir)
    let lock = "${dir}/x.lock"
    let lockDir = "${lock}.d"
    ensureDir(lockDir)

    // 造一个「持锁进程已死」的锁。用一个保证不存在的 pid：
    // 自己 fork 出来再杀掉不可靠，直接取一个远超当前 pid 上限的值。
    let deadPid = 4194303
    writeFileAtomic("${lockDir}/holder.json", "{\"pid\":${deadPid},\"at\":\"2026-10-01T00:00:00+08:00\"}")
    @Assert(!processExists(deadPid))

    // staleMs 给一个极大的值：若没有 pid 检查，这里必然抛 LOCKED
    let start = nowMillis()
    let got = withLock(lock, 86400000, { => 7 })
    @Assert(got == 7)
    @Assert(nowMillis() - start < 5000)      // 没有白等陈旧窗口
    @Assert(!isDirectoryPath(lockDir))

    removePathIfExists(dir)
}

@Test
func testLockIsNotStolenFromLiveHolder(): Unit {
    // 反向：持锁进程**活着**时，即使锁很新也必须尊重，绝不能抢。
    // 判错的方向必须是「多等」而不是「误抢」—— 抢了就是两个进程同时写
    // progress.json / README 托管区，正是锁要防的事。
    let dir = "/tmp/deepgit-livelock-${nowMillis()}"
    ensureDir(dir)
    let lock = "${dir}/x.lock"
    let lockDir = "${lock}.d"
    ensureDir(lockDir)
    // 用自己的 pid：当前进程一定活着
    writeFileAtomic("${lockDir}/holder.json", "{\"pid\":${getpid()},\"at\":\"2026-10-01T00:00:00+08:00\"}")
    @Assert(processExists(Int64(getpid())))

    var threw = false
    try {
        _ = withLock(lock, 86400000, { => 1 })
    } catch (e: DgError) {
        threw = e.code == "LOCKED"
    }
    @Assert(threw)
    @Assert(isDirectoryPath(lockDir))        // 锁没被抢走

    removePathIfExists(dir)
}

@Test
func testLockWithUnreadableHolderIsTreatedAsAlive(): Unit {
    // 判不出来且**锁还新鲜** ⇒ 当「还活着」：宁可多等，也不误抢。
    // ⚠️ M23：这个「当活着」只在兜底窗口内成立 —— 超过 staleMs 的
    // 无人认领锁必须能接管（见 testUnclaimableLockIsRecoveredAfterStaleWindow），
    // 否则「写 holder 前崩了」留下的锁目录会永久锁死项目。
    // 三种判不出来的情况：holder.json 缺失 / 不是合法 JSON / pid 非法。
    let cases = ArrayList<String>([
        "",                                              // 文件不存在
        "这不是 JSON",                                    // 解析失败
        "{\"pid\":0,\"at\":\"x\"}",                         // pid 非法
        "{\"at\":\"x\"}",                                  // 没有 pid 字段
    ])
    for (content in cases) {
        let dir = "/tmp/deepgit-noholder-${nowMillis()}-${cases.size}"
        ensureDir(dir)
        let lock = "${dir}/x.lock"
        let lockDir = "${lock}.d"
        ensureDir(lockDir)
        if (!content.isEmpty()) {
            writeFileAtomic("${lockDir}/holder.json", content)
        }
        var threw = false
        try {
            _ = withLock(lock, 86400000, { => 1 })
        } catch (e: DgError) {
            threw = e.code == "LOCKED"
        }
        @Assert(threw)
        @Assert(isDirectoryPath(lockDir))
        removePathIfExists(dir)
    }
}

/// #178 回归：持锁者**还活着**时，无论锁多老都不许抢。
///
/// 负控（曾真实发红）：判定内联在 tryAcquire 里，持锁者活着时仍去看锁龄，
/// 于是「活 + 旧」被抢。锁目录 mtime 只在加锁那一刻写、body 期间不刷新，
/// 而 update 的 staleMs=600000、deep=900000 ——
/// 任何跑过 10 分钟的 update 都会在运行途中丢锁，第二个进程得以并发进入。
/// 实测：持锁 pid 活着 + mtime 回拨 20 分钟 → `update repo` 直接进临界区、
/// exit 0、原 holder.json 被覆盖；同一实验 mtime 新鲜 → 正确报 LOCKED、exit 1。
///
/// ⚠️ 这条与既有的 `testLockIsNotStolenFromLiveHolder` **不是同一件事**：
/// 那条用 `withLock(lock, 86400000, …)`，staleMs 是 1 天，
/// 于是锁永远是「新鲜的」，恰好绕开了「活 + 旧」这个组合。
@Test
func testAcquireDecisionNeverStealsFromLiveHolderNoMatterHowOld(): Unit {
    let live = HolderState.HolderAlive
    // 锁龄从 0 到极大值穷举：只要持锁者活着，答案就必须是 Wait
    let ages = [0, 1, 599_999, 600_000, 600_001, 900_000, 3_600_000, 86_400_000, 999_999_999]
    for (a in ages) {
        for (stale in [600_000, 900_000, 86_400_000]) {
            match (acquireDecision(live, a, stale)) {
                case AcquireDecision.TakeOver =>
                    @Assert(false)   // 活着的持锁者被抢了：两个进程会同时写
                case AcquireDecision.Wait => ()
            }
        }
    }
}

/// 持锁者已死：立刻接管，不等满 staleMs。
///
/// 这是 holderAlive 那次修复的收益，#178 收口时**必须保住**：
/// 如果改成「一律等 staleMs」，崩溃残留的锁又会白等 10 分钟。
@Test
func testAcquireDecisionTakesOverImmediatelyWhenHolderIsDead(): Unit {
    for (a in [0, 1, 600_000, 86_400_000, 999_999_999]) {
        match (acquireDecision(HolderState.HolderDead, a, 600_000)) {
            case AcquireDecision.TakeOver => ()
            case AcquireDecision.Wait =>
                @Assert(false)   // 持锁进程早就没了还在等 —— 崩溃残留锁会永久阻塞
        }
    }
}

/// 锁龄读不出来（ageMs < 0）时按「还活着」处理。
///
/// 「不知道」必须与「没有」分开：读不到年龄不是「没有持锁者」。
@Test
func testAcquireDecisionTreatsUnknownAgeAsAlive(): Unit {
    match (acquireDecision(HolderState.HolderAlive, -1, 600_000)) {
        case AcquireDecision.Wait => ()
        case AcquireDecision.TakeOver => @Assert(false)
    }
}

/// M23 回归：查不到持锁者（holder.json 缺失/损坏）且锁已超过 staleMs ⇒ 必须接管。
/// 原实现把这一档当成「活着」⇒ 没有任何恢复通道，#178 移除 staleMs 兜底时
/// 连带把「没人能声称持有的锁」一起锁死了。实测症状：SIGKILL 落在
/// mkdirExclusive 与 writeHolderInfo 之间留下的锁目录，让后续所有命令
/// 永远报「正在更新中（另一个 moonGit 进程持锁）」，只能手动删目录。
@Test
func testUnclaimableLockIsRecoveredAfterStaleWindow(): Unit {
    let dir = "/tmp/deepgit-unclaimable-${nowMillis()}"
    ensureDir(dir)
    let lock = "${dir}/x.lock"
    let lockDir = "${lock}.d"
    ensureDir(lockDir)   // 没有 holder.json：没人能声称持有它

    // staleMs = 0：兜底窗口为 0，任何年龄都算陈旧
    let got = withLock(lock, 0, { => 7 })
    @Assert(got == 7)
    @Assert(!isDirectoryPath(lockDir))
    removePathIfExists(dir)
}

/// 端到端：持锁者活着时，把 staleMs 压到边界也不许抢。必须报 LOCKED 且锁完好。
///
/// 纯函数那条穷举了所有年龄；这条验「判定真的接在 tryAcquire 上」——
/// 抽成函数后，若有人把调用点改回内联逻辑，纯函数测试照样全绿。
///
/// 复现手法说明：不去回拨 mtime（`FileInfo` 没有设修改时间的方法），
/// 而是**把 staleMs 压到 -1**。这等价于「无论锁多老都要抢」，
/// 正是修复前那条分支在活人锁上会走的路；而 `lockAgeMs` 只在读文件失败时
/// 才返回 -1，正常读到的是 ≥0，所以这个取值确定性地落在「年龄已知」那一档。
@Test
func testLiveLockIsNotStolenEvenWhenStaleThresholdIsZero(): Unit {
    for (stale in [-1, 0, 1]) {
        let dir = "/tmp/deepgit-oldlive-${nowMillis()}-${stale}"
        ensureDir(dir)
        let lock = "${dir}/x.lock"
        let lockDir = "${lock}.d"
        ensureDir(lockDir)
        // 用自己的 pid：当前进程一定活着
        writeFileAtomic("${lockDir}/holder.json", "{\"pid\":${getpid()},\"at\":\"2026-10-01T00:00:00+08:00\"}")
        @Assert(processExists(Int64(getpid())))

        var threw = false
        try {
            _ = withLock(lock, stale, { => 1 })
        } catch (e: DgError) {
            threw = e.code == "LOCKED"
        }
        @Assert(threw)                                  // 必须报「在更新中」
        @Assert(isDirectoryPath(lockDir))               // 锁没被抢走
        @Assert(fileExists("${lockDir}/holder.json"))   // 也没被覆盖
        removePathIfExists(dir)
    }
}
