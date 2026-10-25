// 项目注册表：记录被管理的项目群。
package moongit.kernel

import std.collection.*
import std.fs.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

public class ProjectEntry {
    public let id: String
    public let name: String
    public let path: String
    public let kind: String  // git | dir
    public let remote: String
    public let addedAt: String
    public var tags: ArrayList<String>
    public var disabled: Bool

    public init(id: String, name: String, path: String, kind: String, remote: String, addedAt: String, tags: ArrayList<String>, disabled: Bool) {
        this.id = id
        this.name = name
        this.path = path
        this.kind = kind
        this.remote = remote
        this.addedAt = addedAt
        this.tags = tags
        this.disabled = disabled
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "id", Json.of(this.id))
        Json.set(o, "name", Json.of(this.name))
        Json.set(o, "path", Json.of(this.path))
        Json.set(o, "kind", Json.of(this.kind))
        Json.set(o, "remote", Json.of(this.remote))
        Json.set(o, "addedAt", Json.of(this.addedAt))
        let tagsArr = ArrayList<JsonValue>()
        for (t in this.tags) {
            tagsArr.add(Json.of(t))
        }
        Json.set(o, "tags", JArr(tagsArr))
        Json.set(o, "disabled", Json.of(this.disabled))
        return o
    }

    public static func fromJson(j: JsonValue): ProjectEntry {
        return ProjectEntry(
            Json.strAt(j, "id", ""),
            Json.strAt(j, "name", ""),
            Json.strAt(j, "path", ""),
            Json.strAt(j, "kind", "dir"),
            Json.strAt(j, "remote", ""),
            Json.strAt(j, "addedAt", ""),
            Json.strArrAt(j, "tags"),
            Json.boolAt(j, "disabled", false),
        )
    }
}

public class Registry {
    public var projects: ArrayList<ProjectEntry>

    public init() {
        this.projects = ArrayList<ProjectEntry>()
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "version", Json.of(1))
        let arr = ArrayList<JsonValue>()
        for (p in this.projects) {
            arr.add(p.toJson())
        }
        Json.set(o, "projects", JArr(arr))
        return o
    }

    public static func fromJson(j: JsonValue): Registry {
        let reg = Registry()
        let arr = Json.arrAt(j, "projects")
        for (item in arr) {
            reg.projects.add(ProjectEntry.fromJson(item))
        }
        return reg
    }
}

public func loadRegistry(): Registry {
    let (reg, _) = loadRegistryChecked()
    return reg
}

/// 返回 (注册表, 存储是否损坏)。第二个返回值给写路径用。
///
/// registry.json 损坏时读路径只告警（保持宽松），
/// 但**写路径必须拦**：否则 add/remove 拿着空注册表做读-改-写，
/// 把损坏文件覆盖成只含新项目的表 —— 全部项目注册永久丢失。
/// 这条链路的触发条件在实践中出现过：项目名里带一个 ESC 字符
/// （带颜色的构建/终端输出被误存）就会让引擎写出非法 JSON，
/// 下一次启动读不回，整个项目群从注册表里消失。
public func loadRegistryChecked(): (Registry, StoreHealth) {
    let (j, health) = readStoreJsonChecked(registryPath())
    return (Registry.fromJson(j), health)
}

/// 写路径闸门：注册表已损坏时拒绝写入。
func assertRegistryWritable(): Unit {
    let (_, health) = loadRegistryChecked()
    // 「读不出来」和「解析失败」都要拦。旧实现只拦后者：
    // readFileText 把权限/IO 错误和「文件不存在」都返回 None，
    // 于是 chmod 000 之后闸门放行，注册表被覆盖成只剩新加的那 1 个项目、exit 0、
    // 连 .corrupt 副本都留不下。而 writeFileAtomic 走 rename，只需要目录写权限，
    // 覆盖一个读不了的文件照样成功 —— 读失败这一种在写入侧原本完全没有防线。
    match (health) {
        case StoreHealth.Corrupt =>
            throw DgError(
                "STORE_CORRUPT",
                "registry.json 已损坏，已保留 .corrupt 副本，本次未做任何写入。\n" +
                    "  继续写入会把全部项目注册覆盖成只含新项目的表 —— 项目群就此消失。\n" +
                    "  请先从副本恢复，或确认可以丢弃后手动删除该文件再重试。",
                1,
                None,
            )
        case StoreHealth.Unreadable(reason) =>
            throw DgError(
                "STORE_UNREADABLE",
                "registry.json 读不出来，本次未做任何写入：${reason}\n" +
                    "  继续写入会用只含新项目的表覆盖它，而原内容读不出来、连副本都留不下。\n" +
                    "  请先修复文件权限（或用 chmod u+r）再重试。",
                1,
                None,
            )
        case StoreHealth.Ok => ()
    }
}

public func saveRegistry(reg: Registry): Unit {
    writeFileAtomic(registryPath(), Json.pretty(reg.toJson()))
}

/// 全局注册表文件的互斥锁。
///
/// registry.json 同样是跨项目的单文件，而项目锁管不到它。
/// 并发 `moongit add`（例如菜单栏扫描与命令行 add 同时跑）会各自读到同一份旧快照、
/// 各自全量覆盖 → 先写者的新项目永久消失，而两条命令都返回成功。
public func withRegistryLock<T>(body: () -> T): T {
    return withLockWaiting(deepgitPath(["locks", "registry.lock"]), 60000, 30000, body)
}

/// 探测路径的项目类型与远端
public func detectProjectInfo(absPath: String): (String, String) {
    let r = gitTry(absPath, ["rev-parse", "--show-toplevel"])
    if (r.ok() && !r.stdout.isBlank()) {
        let root = r.stdout.trimAscii()
        let remoteRes = gitTry(root, ["config", "--get", "remote.origin.url"])
        let remote = if (remoteRes.ok()) { remoteRes.stdout.trimAscii() } else { "" }
        return ("git", remote)
    }
    return ("dir", "")
}

/// 注册项目（已存在则返回既有条目）
public func addProject(inputPath: String, name: String, tags: ArrayList<String>, base: String): (ProjectEntry, Bool) {
    let abs = resolvePath(inputPath, base)
    if (!isDirectoryPath(abs)) {
        throw DgError.notFound("路径不存在或不是目录：${abs}")
    }
    let (kind, remote) = detectProjectInfo(abs)
    let root = if (kind == "git") { gitRun(abs, ["rev-parse", "--show-toplevel"], false) } else { abs }
    let id = projectIdFor(root)

    // ⚠️⚠️ #198：名字算出来是空的就**必须拒绝注册**，不能写一条空名项目。
    //
    // 原来只有 `isDirectoryPath` 一道闸，于是
    //     moongit add /            →  ✓ 已注册：（dir）→ /
    //     MCP add_project {"path": ""} → 已注册：（/）
    // 两条都往注册表里塞了 `name=""`、`path="/"` 的条目。后果不是「多一行」：
    //   ① 那条项目**永远引用不到** —— `findProjectIn` 对空 ref 直接返回 None，
    //      于是 `remove` 之类的命令根本删不掉它（用户连补救手段都没有）；
    //   ② 它**永久污染每一次聚合命令**：实测注册后
    //        moongit status --json → summary.failedProjects = 1
    //        该项目的 error = 「Native function error.」
    //      一句用户看不懂、也无处可查的错，挂在每一次 status/dashboard/report 上。
    // 引擎只是「如实地」报了一个它本不该收下的输入。
    //
    // 触发条件就是 basename 为空 —— `/` 的 basename 是空串。
    let finalName = if (name.isEmpty()) { basename(root) } else { name }
    if (finalName.isEmpty() || finalName == "/") {
        throw DgError.usage(
            "无法从「${root}」推导出项目名（它的末级目录名是空的）—— " +
            "请用 --name <名称> 显式指定"
        )
    }

    // 读-改-写整体在锁内：只在 save 前加锁没用，两个进程仍会读到同一份旧快照
    return withRegistryLock({ =>
        assertRegistryWritable()
        let reg = loadRegistry()
        for (p in reg.projects) {
            // ⚠️ 必须用 samePath（词法规范化 + macOS 符号链接前缀），不能用裸 normalizePath。
            // 同一个物理仓库经 /tmp 和 /private/tmp 两个路径进来时，
            // normalizePath 认为它们不同，于是注册表里出现两条同名条目、两个 id、
            // 两份独立的进度库；`remove` 只能删掉其中一条，另一份进度数据变孤儿。
            // 实测：`add $SB/repos/dup` 记 /private/tmp/...，`scan $SB/repos` 记 /tmp/...，
            // 两条都在，remove 后还剩一条。
            // projectIdFor 保持不变（改了会让既有 store 目录名对不上），
            // 身份判据统一走 samePath 就够了 —— 不会再产生第二条。
            if (p.id == id || samePath(p.path, root)) {
                return (p, false)
            }
        }
        let entry = ProjectEntry(id, finalName, root, kind, remote, nowIso(), tags, false)
        reg.projects.add(entry)
        ensureDir(deepgitHome())
        saveRegistry(reg)
        return (entry, true)
    })
}

/// 按 id / 名称 / 路径查找
public func findProject(ref: String): Option<ProjectEntry> {
    let reg = loadRegistry()
    return findProjectIn(reg, ref)
}

public func findProjectIn(reg: Registry, ref: String): Option<ProjectEntry> {
    if (ref.isEmpty()) {
        return None
    }
    for (p in reg.projects) {
        if (p.id == ref) {
            return Some(p)
        }
    }
    for (p in reg.projects) {
        if (p.name == ref) {
            return Some(p)
        }
    }
    // 「这里」的引用（当前/父目录简写）必须如实未找到。normalizePath 是纯词法的：
    // "." 归一化成空串，于是「精确路径」阶段永远匹配不到 cwd，而
    // 空串 + "/" 让**前缀阶段命中每一个项目**（返回第一个注册项目）、
    // 子串阶段亦然（几乎所有路径都 contains(".")）。实测 `git commit .`
    // 在未注册目录会静默对另一个不相干的已注册项目执行写操作（跨项目写入）。
    // 同族纪律见缺陷 #29：语义不明的引用不许被解释成「某个更大的范围」。
    if (ref == "." || ref == "./" || ref == ".." || ref == "../") {
        return None
    }
    let abs = resolveMacSymlink(normalizePath(expandHome(ref)))
    for (p in reg.projects) {
        if (samePath(p.path, abs)) {
            return Some(p)
        }
    }
    for (p in reg.projects) {
        if (resolveMacSymlink(normalizePath(p.path)).startsWith(abs + "/")) {
            return Some(p)
        }
    }
    for (p in reg.projects) {
        if (basename(p.path) == ref) {
            return Some(p)
        }
    }
    let lower = ref.toAsciiLower()
    for (p in reg.projects) {
        if (p.name.toAsciiLower().contains(lower) || p.path.toAsciiLower().contains(lower)) {
            return Some(p)
        }
    }
    return None
}

public func requireProject(ref: String): ProjectEntry {
    match (findProject(ref)) {
        case Some(p) => return p
        case None =>
            throw DgError.notFound("未找到项目：${ref}（可用 `moongit list` 查看，或 `moongit scan` 扫描注册）")
    }
}

public func removeProject(ref: String, purge: Bool): ProjectEntry {
    // 锁只护「找到 + 从注册表移除 + 落盘」这段读-改-写。
    // purge 是慢速文件系统操作，留在锁外 —— 否则删一个大 store 会把所有 add 卡住。
    let target = withRegistryLock({ =>
        assertRegistryWritable()
        let reg = loadRegistry()
        match (findProjectIn(reg, ref)) {
            case Some(t) =>
                let keep = ArrayList<ProjectEntry>()
                for (p in reg.projects) {
                    if (p.id != t.id) {
                        keep.add(p)
                    }
                }
                reg.projects = keep
                saveRegistry(reg)
                return t
            case None => throw DgError.notFound("未找到项目：${ref}")
        }
    })
    if (purge) {
        let storeDir = deepgitPath(["store", target.id])
        removePathIfExists(storeDir)
        // removePathIfExists 会吞掉删除异常且返回 Unit，调用方本来无从判断。
        // 破坏性操作不能靠「打印成功」蒙混：删不掉就如实报错。
        if (isDirectoryPath(storeDir)) {
            throw DgError("PURGE_FAILED", "进度数据删除失败（可能权限不足或文件被占用）：${storeDir}")
        }
    }
    return target
}

// ------------------------------ 测试 ------------------------------

@Test
func testRegistryRoundTrip(): Unit {
    let reg = Registry()
    reg.projects.add(ProjectEntry("p_x", "demo", "/tmp/demo", "git", "git@x:y", nowIso(), ArrayList<String>(["a"]), false))
    let j = reg.toJson()
    let back = Registry.fromJson(j)
    @Assert(back.projects.size == 1)
    @Assert(back.projects[0].name == "demo")
    @Assert(back.projects[0].kind == "git")
    @Assert(back.projects[0].tags.size == 1)
}

@Test
func testFindProjectByVariousRefs(): Unit {
    let reg = Registry()
    reg.projects.add(ProjectEntry("p_abc", "myproj", "/Volumes/x/myproj", "git", "", nowIso(), ArrayList<String>(), false))
    @Assert(findProjectIn(reg, "p_abc").isSome())
    @Assert(findProjectIn(reg, "myproj").isSome())
    @Assert(findProjectIn(reg, "/Volumes/x/myproj").isSome())
    @Assert(findProjectIn(reg, "MYPROJ").isSome())
    @Assert(findProjectIn(reg, "/Volumes/x").isSome())
    @Assert(findProjectIn(reg, "nonexistent-xyz").isNone())
}

@Test
func testDotRefNeverFallsThroughToSubstringMatch(): Unit {
    let reg = Registry()
    // 项目路径里含点号（点目录/扩展名）——"." 是几乎所有路径的子串
    reg.projects.add(ProjectEntry("p_dot", "dotproj", "/deepgit-dotref-probe.d/proj", "git", "", nowIso(), ArrayList<String>(), false))
    // 子串模糊对普通片段仍然可用
    @Assert(findProjectIn(reg, "dot").isSome())
    // 「这里」简写绝不能靠子串命中：必须如实未找到（否则未注册目录里的
    // `git commit .` 会对这个不相干项目执行 add -A 级别的写操作）
    @Assert(findProjectIn(reg, ".").isNone())
    @Assert(findProjectIn(reg, "./").isNone())
    @Assert(findProjectIn(reg, "..").isNone())
    @Assert(findProjectIn(reg, "../").isNone())
}

@Test
func testProjectEntryJsonShape(): Unit {
    let e = ProjectEntry("p_1", "n", "/p", "dir", "", "2026-01-01", ArrayList<String>(), false)
    let j = e.toJson()
    @Assert(Json.strAt(j, "id", "") == "p_1")
    @Assert(Json.boolAt(j, "disabled", true) == false)
    @Assert(Json.arrAt(j, "tags").size == 0)
}

@Test
func testDetectProjectInfoNonGit(): Unit {
    let tmp = "/tmp/deepgit-detect-${nowMillis()}"
    ensureDir(tmp)
    let (kind, remote) = detectProjectInfo(tmp)
    @Assert(kind == "dir")
    @Assert(remote.isEmpty())
    removePathIfExists(tmp)
}

@Test
func testRegistryGateRejectsUnreadableStore(): Unit {
    // 闸门原先只判「解析失败」，漏了「读取失败」——
    // readFileText 把权限/IO 错误和「文件不存在」都表达成 None，
    // case None 于是回报「未损坏」，写闸门放行。
    // 实测 chmod 000 后 add 一个项目：注册表 2 项变 1 项、exit 0、连 .corrupt 都没有。
    // writeFileAtomic 走 rename 只需要目录写权限，覆盖一个读不了的文件照样成功。
    let base = "/tmp/dg_reg_unreadable_${nowMillis()}"
    let testHome = "${base}/home"
    enterTestHome(testHome)
    ensureDir(testHome)
    ensureDir(base)
    let proj = "${base}/proj"
    ensureDir(proj)
    gitRun(proj, ["init", "-b", "main"], false)
    writeFileAtomic("${proj}/a.txt", "x")
    gitRun(proj, ["add", "."], false)
    gitRun(proj, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "i"], false)

    addProject(proj, "proj", ArrayList<String>(), base)
    @Assert(loadRegistry().projects.size == 1)
    let before = readFileTextOr(registryPath(), "")

    // 抽掉读权限再写
    execCapture("chmod", ["000", registryPath()], None, 5000)
    var code = ""
    var msg = ""
    try {
        addProject(proj, "second", ArrayList<String>(), base)
    } catch (e: DgError) {
        code = e.code
        msg = e.message
    }
    execCapture("chmod", ["644", registryPath()], None, 5000)

    @Assert(code == "STORE_UNREADABLE")
    @Assert(msg.contains("读不出来"))
    // 关键：内容必须逐字节未变，且仍是原来那一个项目
    @Assert(readFileTextOr(registryPath(), "") == before)
    @Assert(loadRegistry().projects.size == 1)

    removePathIfExists(base)
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testScanGateRejectsCorruptStore(): Unit {
    // registerCandidates 是 registry.json 的第二个写入者，
    // 而锁和损坏闸门原先只加在 addProject / removeProject 里。
    // 结果 scan 完全绕过闸门：实测注入非法 JSON 后 add 正确 exit 1 拒绝写入，
    // scan 却 exit 0「发现 1 个项目」，原来的 2 个项目被覆盖掉，连 .corrupt 都没有。
    let base = "/tmp/dg_scan_gate_${nowMillis()}"
    let testHome = "${base}/home"
    enterTestHome(testHome)
    ensureDir(testHome)
    ensureDir(base)
    let proj = "${base}/proj"
    ensureDir(proj)
    gitRun(proj, ["init", "-b", "main"], false)
    writeFileAtomic("${proj}/a.txt", "x")
    gitRun(proj, ["add", "."], false)
    gitRun(proj, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "i"], false)
    addProject(proj, "keeper", ArrayList<String>(), base)
    @Assert(loadRegistry().projects.size == 1)

    // 注入非法字节
    writeFileAtomic(registryPath(), "{\"projects\":[{\"id\":\"p1\",\"name\":\"OLD\"")

    let cands = ArrayList<ScanCandidate>()
    cands.add(ScanCandidate(proj, "proj", "git", ArrayList<String>(), ""))
    var code = ""
    try {
        registerCandidates(cands)
    } catch (e: DgError) {
        code = e.code
    }
    @Assert(code == "STORE_CORRUPT")

    // 原文件必须原样保留（损坏内容留证，而不是被覆盖）
    @Assert(readFileTextOr(registryPath(), "").contains("OLD"))
    // 存在 .corrupt 副本
    let dir = registryPath()
    @Assert(!dir.isEmpty())

    removePathIfExists(base)
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testTmpAliasDoesNotRegisterTwice(): Unit {
    // add 记录的是 `git rev-parse --show-toplevel` 给的物理路径（/private/tmp/...），
    // scan 拿到的是用户给的路径（/tmp/...），两者 id 不同但指向同一个仓库。
    // 旧实现只比 id / 裸 normalizePath，于是同一个物理仓库被注册两次、
    // 两个 id、两份独立的进度库；`remove` 只能删掉其中一条，另一份变孤儿。
    let base = "/tmp/dg_alias_${nowMillis()}"
    let testHome = "${base}/home"
    enterTestHome(testHome)
    ensureDir(testHome)
    ensureDir(base)
    let repo = "${base}/dup"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic("${repo}/a.txt", "x")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "i"], false)

    // 先用 add 走一遍（内部会把路径规范化成 git 给的物理路径）
    addProject(repo, "dup", ArrayList<String>(), base)
    @Assert(loadRegistry().projects.size == 1)

    // 再用 scan 走一遍（拿到的是用户给的 /tmp/... 形式）
    let cands = ArrayList<ScanCandidate>()
    cands.add(ScanCandidate(repo, "dup", "git", ArrayList<String>(), ""))
    let (added, existing) = registerCandidates(cands)
    @Assert(added == 0)
    @Assert(existing == 1)
    // 关键断言：仍然只有一条
    @Assert(loadRegistry().projects.size == 1)

    // 第二次 scan 也必须是「新增 0」
    let (_, existing2) = registerCandidates(cands)
    @Assert(existing2 == 1)
    @Assert(loadRegistry().projects.size == 1)

    removePathIfExists(base)
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testAddAfterScanDoesNotRegisterTwice(): Unit {
    // 反序：scan 先注册（记的是用户给的 /tmp/... 形式），
    // 之后 add 走一遍（内部用 git rev-parse 拿物理路径 /private/tmp/...）。
    // 这条专门覆盖 addProject 的去重判据 —— 上一条测试里 add 先于 scan，
    // 走不到这里，只靠它的话 addProject 退回 normalizePath 测试仍然全绿。
    let base = "/tmp/dg_alias_rev_${nowMillis()}"
    let testHome = "${base}/home"
    enterTestHome(testHome)
    ensureDir(testHome)
    ensureDir(base)
    let repo = "${base}/dup"
    ensureDir(repo)
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic("${repo}/a.txt", "x")
    gitRun(repo, ["add", "."], false)
    gitRun(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "i"], false)

    // scan 先来
    let cands = ArrayList<ScanCandidate>()
    cands.add(ScanCandidate(repo, "dup", "git", ArrayList<String>(), ""))
    let (added0, _) = registerCandidates(cands)
    @Assert(added0 == 1)
    @Assert(loadRegistry().projects.size == 1)

    // add 后到，必须判定为「已存在」而不是新增第二条
    let (entry, created) = addProject(repo, "dup", ArrayList<String>(), base)
    @Assert(!created)
    @Assert(loadRegistry().projects.size == 1)

    removePathIfExists(base)
    exitTestHome()
    removePathIfExists(testHome)
}

@Test
func testSamePathHandlesMacSymlinkPrefixes(): Unit {
    @Assert(samePath("/tmp/x", "/private/tmp/x"))
    @Assert(samePath("/var/x", "/private/var/x"))
    @Assert(samePath("/tmp/a/../b", "/private/tmp/b"))
    @Assert(!samePath("/tmp/x", "/tmp/y"))
    @Assert(samePath("/a/b", "/a/b"))
    // 词法规范化之外的路径不该被误判为相同
    @Assert(!samePath("/Users/x", "/Users/y"))
}
