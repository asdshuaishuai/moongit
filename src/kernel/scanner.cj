// 项目扫描器：在给定根目录下发现项目（git 仓库 或 带清单+README 的目录）。
package moongit.kernel

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

let SCAN_SKIP_DIRS = ["node_modules", ".git", ".svn", ".hg", ".build", ".swiftpm", "DerivedData", "dist", "build", "target", "__pycache__", ".venv", "venv", ".next", ".cache", ".gradle", ".idea", "_build", "coverage", "Library", ".Trash", "renders", "snapshots", ".playwright-mcp", ".zcode", "tmp"]

let STRONG_MARKERS = ["package.json", "moon.mod.json", "Cargo.toml", "Package.swift", "pyproject.toml", "go.mod", "pubspec.yaml", "pom.xml", "cjpm.toml", "build.gradle", "build.gradle.kts", "CMakeLists.txt"]

let README_MARKERS = ["README.md", "README.zh-CN.md", "AGENTS.md", "CLAUDE.md"]

func scanSkip(name: String): Bool {
    for (s in SCAN_SKIP_DIRS) {
        if (s == name) {
            return true
        }
    }
    return false
}

public class ScanCandidate {
    public let path: String
    public let name: String
    public let kind: String
    public let markers: ArrayList<String>
    public let remote: String

    public init(path: String, name: String, kind: String, markers: ArrayList<String>, remote: String) {
        this.path = path
        this.name = name
        this.kind = kind
        this.markers = markers
        this.remote = remote
    }
}

public class ScanResult {
    public let candidates: ArrayList<ScanCandidate>
    public let dirsVisited: Int64
    public let truncated: Bool
    /// **读不出来**的目录。与「没有项目」是两件事，必须一起报出去。
    ///
    /// ⚠️ 这条是缺陷 #179 的收口：原来 `listDir` 吞掉异常返回空数组，
    /// 扫描于是把「无权限的子树」当成「这里没有项目」——
    /// 实测 `chmod 000` 后 `scan --json` 给出 `found=1, dirsVisited=3,
    /// truncated=false`，stderr 零告警，与「真的只有 1 个项目」结构同构。
    public let unreadable: ArrayList<String>
    /// 遍历是**因为撞到 --depth 上限**而停下的，且停下时下面还有子目录没看。
    ///
    /// ⚠️ 这是缺陷 #197：`truncated` 只表达「撞到 20000 目录上限」，
    /// 覆盖不全还有**第二种**成因 —— 用户给的 `--depth` 太浅。
    /// 实测在一棵只有 4 层深的仓库树上：
    ///     moongit scan <树> --depth 2
    ///     → 「未发现项目（已访问 3 个目录）」exit 0
    /// 仓库明明就在第 4 层。而同一个函数对「目录过多」早就有正确措辞
    /// （cli.cj 里那句「扫描被截断…本次**未**覆盖全部范围」），
    /// 只是**深度上限这条路没接上**。
    /// 「上限当全量」这一族在 status(#115) / summary(#125) / dashboard 标题
    /// / scan 目录上限 都修过一次，这里是第五次从 scan 自己的另一个出口钻出来。
    public let depthCapped: Bool

    public init(candidates: ArrayList<ScanCandidate>, dirsVisited: Int64, truncated: Bool) {
        this(candidates, dirsVisited, truncated, ArrayList<String>())
    }

    public init(
        candidates: ArrayList<ScanCandidate>,
        dirsVisited: Int64,
        truncated: Bool,
        unreadable: ArrayList<String>
    ) {
        this(candidates, dirsVisited, truncated, unreadable, false)
    }

    public init(
        candidates: ArrayList<ScanCandidate>,
        dirsVisited: Int64,
        truncated: Bool,
        unreadable: ArrayList<String>,
        depthCapped: Bool
    ) {
        this.candidates = candidates
        this.dirsVisited = dirsVisited
        this.truncated = truncated
        this.unreadable = unreadable
        this.depthCapped = depthCapped
    }
}

func detectMarkers(dir: String): ArrayList<String> {
    let hits = ArrayList<String>()
    for (m in STRONG_MARKERS) {
        if (fileExists("${dir}/${m}")) {
            hits.add(m)
        }
    }
    // Xcode 工程
    // ⚠️ 走 classifyEntry：isDirectory() 遇到 stat 不到的条目会抛，
    // 而扫描根目录是用户随便给的一个路径（实测 `/` 与 `/private/var/db`
    // 都能让 `scan` 直接 exit 1「内部错误：Native function error.」）。
    for (info in listDir(dir)) {
        let isDir = match (classifyEntry(info)) {
            case EntryKind.Dir => true
            case _ => false
        }
        if (isDir && info.name.endsWith(".xcodeproj")) {
            hits.add(info.name)
        }
    }
    return hits
}

func hasReadme(dir: String): Bool {
    for (r in README_MARKERS) {
        if (fileExists("${dir}/${r}")) {
            return true
        }
    }
    return false
}

/// 这个目录下**是否还有没被看过的子目录**（排除点开头与 scanSkip 名单）。
///
/// #197 的接缝：撞到 `--depth` 上限时，只有「下面确实还有东西」才算被截断。
/// 边界处常常是叶子目录（没有子目录）—— 那种情况是**真的看全了**，
/// 置位 depthCapped 反而会谎报「没看完」。
///
/// ⚠️ 必须用 `listDirChecked` 而不是 `listDir`：`listDir` 把读取异常
/// 吞成空数组，于是「读不出来」会被当成「没有子目录」=
/// 谎报成「看全了」。读不出来时返回 true —— 宁可说「可能没看完」。
///
/// ⚠️ 同样必须走 `classifyEntry`：Unreadable 条目**可能就是一个没被走过的子目录**。
/// `!info.isDirectory()` 会把「读不出来」和「不是目录」合并，
/// 于是 `scan /` 这类路径上明明还有子目录，却报 `depthCapped=false`（「看全了」）。
public func hasUnexploredSubdir(dir: String): Bool {
    let (entries, readable) = listDirChecked(dir)
    if (!readable) {
        return true
    }
    for (info in entries) {
        match (classifyEntry(info)) {
            // 读不出来 = 可能有没看过的子目录
            case EntryKind.Unreadable => return true
            case EntryKind.Dir => ()
            case _ => continue
        }
        if (info.name.startsWith(".") || scanSkip(info.name)) {
            continue
        }
        return true
    }
    return false
}

/// 扫描根目录，发现项目
public func scanRoots(roots: ArrayList<String>, depth: Int64, includeNonGit: Bool): ScanResult {
    let candidates = ArrayList<ScanCandidate>()
    let seen = ArrayList<String>()
    var dirsVisited: Int64 = 0
    var truncated = false
    // 撞到 --depth 上限时下面还有没看过的子目录（#197）
    var depthCapped = false
    // 读不出来的目录。⚠️ 必须收集而不是吞掉：吞掉之后
    // 「无权限的子树」与「这里没有项目」在输出里完全同构（缺陷 #179）。
    let unreadable = ArrayList<String>()

    // 显式队列式遍历（避免深递归）
    let queue = ArrayList<(String, Int64)>()
    for (r in roots) {
        queue.add((normalizePath(expandHome(r)), 0))
    }
    var head = 0
    while (head < queue.size) {
        let (dir, curDepth) = queue[head]
        head += 1
        dirsVisited += 1
        if (dirsVisited > 20000) {
            truncated = true
            break
        }

        let isGit = fileExists("${dir}/.git")
        if (isGit) {
            var already = false
            for (s in seen) {
                if (s == dir) {
                    already = true
                    break
                }
            }
            if (!already) {
                seen.add(dir)
                let remote = remoteUrl(dir)
                candidates.add(ScanCandidate(dir, basename(dir), "git", ArrayList<String>([".git"]), remote))
            }
            continue  // 不再深入仓库内部
        }

        if (includeNonGit) {
            let markers = detectMarkers(dir)
            if (markers.size > 0 && hasReadme(dir)) {
                var already = false
                for (s in seen) {
                    if (s == dir) {
                        already = true
                        break
                    }
                }
                if (!already) {
                    seen.add(dir)
                    candidates.add(ScanCandidate(dir, basename(dir), "dir", markers, ""))
                }
                continue  // 最外层非 git 项目优先
            }
        }

        if (curDepth >= depth) {
            // ⚠️ #197：撞到深度上限时**原来什么都不记**，于是
            // 「没看完」与「看完了、确实没有」在输出里完全同构。
            // 注意不能一见 curDepth >= depth 就置位：那只是「到边界了」，
            // 边界处可能根本没有子目录（叶子），那样是**真的看全了**。
            // 必须确认下面确实还有没看过的子目录，才算「被截断」。
            if (hasUnexploredSubdir(dir)) {
                depthCapped = true
            }
            continue
        }
        let (entries, readable) = listDirChecked(dir)
        if (!readable) {
            unreadable.add(dir)
        }
        for (info in entries) {
            // ⚠️ Unreadable 必须单列进 unreadable 清单，不能被「不是目录」悄悄吃掉：
            // 一个 stat 不到的子目录是一棵**没被走过的树**，与「这里没有子目录」不同构。
            match (classifyEntry(info)) {
                case EntryKind.Unreadable =>
                    unreadable.add(dir + "/" + info.name)
                    continue
                case EntryKind.Dir => ()
                case _ => continue
            }
            let nm = info.name
            if (nm.startsWith(".") || scanSkip(nm)) {
                continue
            }
            queue.add((dir + "/" + nm, curDepth + 1))
        }
    }

    return ScanResult(candidates, dirsVisited, truncated, unreadable, depthCapped)
}

/// 批量注册扫描结果，返回 (新增数, 已有数)
///
/// ⚠️ 整个读-改-写必须在 withRegistryLock 内，且开头调 assertRegistryWritable。
///
/// 本函数是 registry.json 的**第二个**写入者，而锁和损坏闸门原先只加在
/// addProject / removeProject 里 —— 也就是「谁改了这个文件」与「谁遵守了规矩」
/// 不是同一批函数。后果实测：
///   - 并发 add 三个项目 + 并发 scan 一个根：scan 打印「新增 5」、exit 0，
///     5 个项目一个没留下。add 那边的 3 个 exit 0「已注册」也被一起抹掉。
///   - registry.json 被注入非法 JSON 后跑 add：正确地 exit 1 拒绝写入；
///     跑 scan：exit 0「发现 1 个项目」，原来的 2 个项目被覆盖掉，
///     连 .corrupt 副本都没有（写闸门被完全绕过）。
///
/// 锁放在最外层、闸门放在锁内第一行 —— 顺序反了就会出现
/// 「检查完是好的、等锁期间被别人写坏、然后用旧快照覆盖」。
public func registerCandidates(candidates: ArrayList<ScanCandidate>): (Int64, Int64) {
    return withRegistryLock({ =>
        assertRegistryWritable()
        let reg = loadRegistry()
        var added: Int64 = 0
        var existing: Int64 = 0
        for (c in candidates) {
            // ⚠️⚠️ #198 的空名闸门：registry.json 的**第二个写入者**同样要拦。
            //
            // addProject（registry.cj）在 #198 修掉了「basename("/") 为空串仍注册」，
            // 而这里没跟上 —— scan 的根目录本身成为 candidate 时
            // （`moongit scan /`），basename("/") 算出的就是空串，
            // 于是静默写进一条 `name=""` 的项目。后果与 add 侧一模一样：
            //   ① 那条项目**永远引用不到** —— findProjectIn 对空 ref 返回 None，
            //      连 `remove` 都删不掉它（用户连补救手段都没有）；
            //   ② 它**永久污染每一次聚合命令**（status/dashboard/report 各自带上
            //      一条读不出状态的项目）。
            // 处置与 add 侧不同：add 是单项目命令，拒绝并教回怎么改；
            // scan 是批量操作，一条坏候选不该掀翻整批 —— 跳过 + 告警，
            // 其余候选照常注册。
            if (c.name.trimAscii().isEmpty()) {
                Log.warn("扫描候选 ${c.path} 的名称为空，已跳过注册" +
                    "（空名项目引用不到、且会污染聚合命令；如确需注册请用 moongit add --name）")
                continue
            }
            let id = projectIdFor(c.path)
            var found = false
            for (p in reg.projects) {
                // samePath 而非只比 id：add 记录的是 git rev-parse 给的物理路径
                // （/private/tmp/...），scan 拿到的是用户给的路径（/tmp/...），
                // 两者 id 不同但指向同一个仓库。旧实现只比 id，于是同一个物理仓库
                // 被注册两次、进度库劈成两半，remove 后剩一份成为孤儿。
                if (p.id == id || samePath(p.path, c.path)) {
                    found = true
                    break
                }
            }
            if (found) {
                existing += 1
                continue
            }
            reg.projects.add(ProjectEntry(id, c.name, c.path, c.kind, c.remote, nowIso(), ArrayList<String>(), false))
            added += 1
        }
        saveRegistry(reg)
        return (added, existing)
    })
}

// ------------------------------ 测试 ------------------------------

@Test
func testScanFindsGitRepo(): Unit {
    let base = "/tmp/deepgit-scan-${nowMillis()}"
    let repo = "${base}/proj-a"
    ensureDir(repo)
    // 构造一个最小 git 仓库
    gitRun(repo, ["init", "-b", "main"], false)
    writeFileAtomic(repo + "/README.md", "# a")
    let roots = ArrayList<String>([base])
    let res = scanRoots(roots, 3, true)
    var found = false
    for (c in res.candidates) {
        if (c.name == "proj-a" && c.kind == "git") {
            found = true
        }
    }
    @Assert(found)
    removePathIfExists(base)
}

@Test
func testScanFindsNonGitProjectWithMarker(): Unit {
    let base = "/tmp/deepgit-scan-ng-${nowMillis()}"
    let proj = "${base}/dirproj"
    ensureDir(proj)
    writeFileAtomic(proj + "/package.json", "{\"name\":\"x\"}")
    writeFileAtomic(proj + "/README.md", "# x")
    let roots = ArrayList<String>([base])
    let res = scanRoots(roots, 3, true)
    var found = false
    for (c in res.candidates) {
        if (c.name == "dirproj" && c.kind == "dir") {
            found = true
        }
    }
    @Assert(found)
    removePathIfExists(base)
}

@Test
func testScanSkipsNodeModules(): Unit {
    let base = "/tmp/deepgit-scan-skip-${nowMillis()}"
    let nm = "${base}/node_modules/pkg"
    ensureDir(nm)
    writeFileAtomic(nm + "/package.json", "{}")
    writeFileAtomic(nm + "/README.md", "# x")
    let roots = ArrayList<String>([base])
    let res = scanRoots(roots, 4, true)
    @Assert(res.candidates.size == 0)
    removePathIfExists(base)
}

@Test
func testScanRespectsDepth(): Unit {
    let base = "/tmp/deepgit-scan-depth-${nowMillis()}"
    let deep = "${base}/a/b/c/deep"
    ensureDir(deep)
    gitRun(deep, ["init", "-b", "main"], false)
    let roots = ArrayList<String>([base])
    let shallow = scanRoots(roots, 1, true)
    @Assert(shallow.candidates.size == 0)
    let deeper = scanRoots(roots, 4, true)
    @Assert(deeper.candidates.size == 1)
    removePathIfExists(base)
}

@Test
func testScanNonGitDisabled(): Unit {
    let base = "/tmp/deepgit-scan-ng2-${nowMillis()}"
    let proj = "${base}/dirproj"
    ensureDir(proj)
    writeFileAtomic(proj + "/package.json", "{}")
    writeFileAtomic(proj + "/README.md", "# x")
    let roots = ArrayList<String>([base])
    let res = scanRoots(roots, 3, false)
    @Assert(res.candidates.size == 0)
    removePathIfExists(base)
}

/// #198 的空名闸门必须盖住 registry.json 的**第二个写入者**。
///
/// addProject（registry.cj）修掉了「basename("/") 为空仍注册」，
/// 而 registerCandidates 没跟上 —— scan 根目录本身成为 candidate 时
/// （`moongit scan /`，根目录里有 .git 时它就是 candidate），
/// basename("/") 是空串，会被静默写进一条 `name=""` 的项目：
/// findProjectIn 对空 ref 返回 None，那条项目永远引用不到、连 remove
/// 都删不掉，还永久污染每一次聚合命令（status/dashboard/report）。
///
/// 直接构造 candidate 列表调 registerCandidates（真实写入路径），
/// 不必真去 scan /——candidate 的 name 就是 scanRoots 里 basename(dir)
/// 的产物，空串等价。
@Test
func testRegisterCandidatesSkipsEmptyName(): Unit {
    let base = "/tmp/dg-scan-emptyname-${nowMillis()}"
    let testHome = "${base}-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    try {
        // 一条空名 + 一条纯空白名 + 一条正常名。
        // 纯空白（"   "）与空串同侧：trimAscii 之后都引用不到。
        let cands = ArrayList<ScanCandidate>()
        cands.add(ScanCandidate("/", "", "git", ArrayList<String>(), ""))
        cands.add(ScanCandidate("/w", "   ", "git", ArrayList<String>(), ""))
        cands.add(ScanCandidate("/tmp/ok-proj", "ok-proj", "git", ArrayList<String>(), ""))
        let (added, _) = registerCandidates(cands)

        // 空名候选不进注册表；正常候选照常注册（闸门不许误伤好数据）
        @Assert(added == 1)
        let reg = loadRegistry()
        @Assert(reg.projects.size == 1)
        @Assert(reg.projects[0].name == "ok-proj")
        for (p in reg.projects) {
            @Assert(!p.name.trimAscii().isEmpty())
        }
    } finally {
        exitTestHome()
        removePathIfExists(testHome)
        removePathIfExists(base)
    }
}

// ------------------------------ #199：扫描器不许被 stat 失败掀翻 ------------------------------

/// `scanRoots` 走真实调用链：树里必须有一个 stat 不到的东西，
/// 且扫描仍然成功、并且把它列进 `unreadable`。
///
/// 修复前这棵树里只要有一个 `isDirectory()` 抛异常的条目，
/// 整次 `scan` 就 exit 1「内部错误：Native function error.」。
/// 本机唯一能稳定构造的 stat 失败是「父目录 `chmod 000`」，
/// 那条走的是 `listDirChecked` 分支（目录读不出来）；
/// 条目级的 EACCES 需要非 root 属主或 SIP 路径，测试里造不出来，由源码 lint 守。
@Test
func testScanSurvivesUnreadableSubtree(): Unit {
    let base = "/tmp/deepgit-scan-unreadable-${nowMillis()}"
    ensureDir(base + "/ok")
    ensureDir(base + "/closed")
    writeFileAtomic(base + "/ok/.git/HEAD", "ref: refs/heads/main")
    let ch = execCapture("chmod", ["000", base + "/closed"], None, 8000)
    @Assert(ch.ok())

    let roots = ArrayList<String>([base])
    let res = scanRoots(roots, 3, true)
    execCapture("chmod", ["755", base + "/closed"], None, 8000)

    // 读不出来的地方必须被点名，且路径要具体
    var named = false
    for (u in res.unreadable) {
        if (u.contains("closed")) {
            named = true
        }
    }
    @Assert(named)
    // 同时 `ok` 那个 git 仓库仍然被找到了 —— 失败隔离到条目，不连坐整棵树
    @Assert(res.candidates.size >= 1)
    removePathIfExists(base)
}

/// 源码 lint：**全引擎**遍历目录的代码不许直接调会抛的原生属性。
///
/// 行为测试覆盖不到条目级 EACCES（要非 root 属主或 SIP 路径，造不出来），
/// 所以这一条是那半边的唯一防线。
///
/// ⚠️ 白名单式，不是黑名单式：把全仓库所有直接调用点列出来，要求它
/// **恰好等于**已知的 6 处。新的遍历点漏进黑名单等于没检查；
/// 白名单则是「多一处就红」，而总数不等也会红，所以**少扫一个文件同样会红**。
///
/// ⚠️ 两处必须处理的自匹配（第一版就是这么把自己写红的）：
///   ① needle 字面量本身就在源码里 → 用拼接构造，源码里永远不出现完整 needle；
///   ② `update.cj` 那个 lint 自己就在扫自己 → 排除本函数体。
/// 排除靠的是「函数名以 `__lint` 开头」，比按行号硬编码稳。
@Test
func __lintOnlyTheSeamMayCallThrowingStatPropsDirectly(): Unit {
    // 拼接构造 needle：源码里不出现完整 needle，lint 匹配不到自己
    let nDir = "." + "isDirectory()"
    let nReg = "." + "isRegular()"
    let nMtime = "." + "lastModif" + "icationTime"

    // 恰好允许的 6 处，全是「自身带 try/catch 或就是接缝本体」。
    // 顺序无所谓，用 contains 判。
    // ⚠️ 别把已经收口到接缝的地方也列进来：`backupSnapshot` 原来在这里，
    // 修好之后它走 classifyEntry，就该从名单里消失 ——
    // 名单里留一条已经没人用的白名单，等于给未来留了个静默通过的洞。
    let allowed = ArrayList<String>([
        "src/util/paths.cj|isDirectoryPath",      // try/catch 兜住（TOCTOU）
        "src/util/paths.cj|probeIsDirectory",     // 接缝本体
        "src/util/paths.cj|probeIsRegular",       // 接缝本体
        "src/util/paths.cj|entryMtime",           // 接缝本体
        "src/kernel/git.cj|listUntrackedFiles",   // 历史修法：就地 try/catch
        "src/kernel/lock.cj|lockAgeMs",           // 历史修法：就地 try/catch
    ])
    let found = ArrayList<String>()
    for (f in ["src/util/paths.cj", "src/kernel/repo.cj", "src/kernel/scanner.cj",
               "src/kernel/docs.cj", "src/kernel/config.cj", "src/kernel/git.cj",
               "src/kernel/lock.cj", "src/cli/cli.cj", "src/flow/update.cj",
               "src/flow/status.cj", "src/flow/deep.cj", "src/flow/report.cj",
               "src/flow/docs.cj", "src/flow/dashboard.cj", "src/util/log.cj",
               "src/util/json.cj", "src/main.cj", "src/cli/mcp.cj"]) {
        let raw = readFileTextChecked(f).getOrThrow()
        let sb = StringBuilder()
        var blk = CjStripState.Normal
        for (r in raw.split("\n")) {
            let (l, nb) = stripCjCommentEx(r, blk)
            blk = nb
            sb.append(l)
            sb.append("\n")
        }
        // 记下每行属于哪个函数，好把白名单写准
        var fn = ""
        for (line in sb.toString().split("\n")) {
            let t = line.trimAscii()
            if (t.contains("func ")) {
                for (p in ["private func ", "public func ", "func "]) {
                    if (t.startsWith(p)) {
                        fn = t[p.size..].split("(")[0]
                        break
                    }
                }
            }
            // 本 lint 自己不能算进结果集
            if (fn.startsWith("__lint")) {
                continue
            }
            if (line.contains(nDir) || line.contains(nReg) || line.contains(nMtime)) {
                found.add("${f}|${fn}")
            }
        }
    }
    // 每个调用点都必须有白名单条目，且总数一致（多一处 / 少一处都红）
    @Assert(found.size == allowed.size)
    for (x in found) {
        @Assert(allowed.contains(x))
    }
    // 白名单里也不能有多余的（否则以后新增调用点会静默通过）
    for (a in allowed) {
        @Assert(found.contains(a))
    }
}
