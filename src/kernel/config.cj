// 配置：默认值 + 文件读写 + 环境变量覆盖 + AI provider 解析。
package moongit.kernel

import std.collection.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

/// AI provider 预设

/// 生效的 AI 配置（解析后的）

/// 应用配置（带默认值）
///
/// ⚠️ **每个字段都必须有 config.cj 之外的消费方**，否则它就是一个
/// 「`config set` 打印『✓ 已设置』、写进 config.json、而没有任何代码读它」
/// 的键 —— 谎报成功。已删掉的三个（缺陷 #194）：
///   · `serverHost` / `serverPort` —— HTTP 层的残留。HTTP 服务已按
///     「传输层只在本机进程之间通信、不要 HTTP」整体删除，全仓库零 socket 代码，
///     可引擎仍然往**每个新建的 config.json** 里主动写一个
///     `server: {host, port}` 块。留着它等于邀请别人起一个不存在的服务。
///   · `hookMode` —— `cmdHook` 无条件装 post-commit/post-merge，
///     从不查这个字段。它是唯一一个「引擎自己写、自己读回、但零行为影响」的键。
///   · `aiJsonMode` —— 更极端：全 `src/` 零出现，连 `configFromJson` /
///     `configToJson` 都没接它。声明了、谁也不读、谁也不写、默认值也不生效。
/// 不变量有测试兜着（`testEveryConfigFieldHasAConsumerOutsideConfig`），
/// 再加回来会立刻红。
public class Config {
    public var language: String = "zh"
    public var roots: ArrayList<String> = ArrayList<String>()
    public var docs: ArrayList<String> = ArrayList<String>(["README.md", "AGENTS.md", "CLAUDE.md"])
    public var agentDocCandidates: ArrayList<String> = ArrayList<String>(["AGENTS.md", "AGENT.md", "CLAUDE.md"])
    public var backupKeep: Int64 = 20
    public var maxShallowBranches: Int64 = 6

    public static func defaults(): Config {
        return Config()
    }
}

public func configPath(): String {
    return deepgitPath(["config.json"])
}

/// 浅更新分支上限的**合法下界**，判据的**唯一来源**（#202）。
///
/// 缺陷 #202：`config set update.maxShallowBranches 0` 原来**完全没有校验**，
/// 写进去之后 `✓ 已设置 update.maxShallowBranches = 0`，
/// 而 `config get` 回读是 6 —— 读路径（`configFromJson`）会静默把它改回 6，
/// 只在 **stderr** 留一行。于是：
///   · 用户以为自己设了一个值，实际上那个值被丢弃了；
///   · 报成功的是 stdout，解释为什么没用的是 stderr —— 脚本与 CI 看不见。
/// 也就是「**引擎会拒绝的取值，写入口却报成功**」，与 #193 / #201 同族。
///
/// 后果（0 与负数同侧）：`collectCandidateBranches` 里 `taken >= maxBranches`
/// 立刻成立，候选集为空 → 浅更新一个分支都不采，
/// 报告却像「只有这些分支」，而进度库里从此不再有任何分支基线。
public let MIN_SHALLOW_BRANCHES: Int64 = 1

/// 纯判定：分支上限是否合法。返回空串表示合法，否则返回该报给用户的原因。
public func maxShallowBranchesError(n: Int64): String {
    if (n >= MIN_SHALLOW_BRANCHES) {
        return ""
    }
    return "update.maxShallowBranches 至少为 ${MIN_SHALLOW_BRANCHES}（收到 ${n}）：" +
        "浅更新按这个上限挑候选分支，上限小于 1 时一个分支都不采，" +
        "而报告仍会像「只有这些分支」"
}

public func registryPath(): String {
    return deepgitPath(["registry.json"])
}

/// 从 JSON 加载配置（缺失字段用默认值）
public func configFromJson(j: JsonValue, base: Config): Config {
    let cfg = Config()
    cfg.language = Json.strAt(j, "language", base.language)
    // ⚠️ #203：读路径必须和写入口用**同一份**判据（#202 的三层纪律）。
    // 原来这里没有闸门，于是手改 config.json 写 `"language": "fr"` 会被原样接受，
    // 而引擎只有 en / 中文两条路 —— 用户以为设了法语，全仓渲染成中文，
    // 且**零提示**（报错的流都不存在）。
    let langErr = languageError(cfg.language)
    if (!langErr.isEmpty()) {
        Log.error("config.json 的 ${langErr}；已回落到 ${base.language}")
        cfg.language = base.language
    }
    let roots = Json.strArrAt(j, "roots")
    cfg.roots = if (roots.isEmpty()) { base.roots } else { roots }
    let update = Json.getOr(j, "update")
    let docs = Json.strArrAt(update, "docs")
    cfg.docs = if (docs.isEmpty()) { base.docs } else { docs }
    let agentDocs = Json.strArrAt(update, "agentDocCandidates")
    cfg.agentDocCandidates = if (agentDocs.isEmpty()) { base.agentDocCandidates } else { agentDocs }
    // 备份保留数：0 或负数都会让 pruneBackups 删光全部备份（详见 docs.cj 的说明），
    // 所以**加载期**就要拦。`config set` 的写入口虽然也拦，但 config.json
    // 可以手改绕过 —— 读路径是真正绕不过去的那一道。
    //
    // ⚠️ #202：判据用 `backupKeepError`（docs.cj 的单一来源），
    // 原来这里写的是 `< 0`，与写入口的 `< 1` 差一档。
    // 三层闸门（写入口 / 读路径 / pruneBackups 运行时）各写一遍阈值必然漂移 ——
    // 漂了以后症状是「配置被接受了但行为不是那样」，最难查。
    cfg.backupKeep = Json.intAt(update, "backupKeep", base.backupKeep)
    let bkErr = backupKeepError(cfg.backupKeep)
    if (!bkErr.isEmpty()) {
        Log.error("config.json 的 ${bkErr}；已回落到 ${base.backupKeep}")
        cfg.backupKeep = base.backupKeep
    }
    // 分支上限同理：0 或负数会让浅更新一个分支都不采，报告却像「只有这些分支」
    cfg.maxShallowBranches = Json.intAt(update, "maxShallowBranches", base.maxShallowBranches)
    let msErr = maxShallowBranchesError(cfg.maxShallowBranches)
    if (!msErr.isEmpty()) {
        Log.error("config.json 的 ${msErr}；已回落到 ${base.maxShallowBranches}")
        cfg.maxShallowBranches = base.maxShallowBranches
    }
    // ⚠️ 老的 config.json 里可能有 `server` / `hooks` 块（写它们的代码已删），
    // 这里**故意不再读**：读了就会把它们重新变成「有语义的配置」，
    // 而实际上没有任何行为消费它们。留在文件里当历史即可 ——
    // saveConfig 的定点合并会把它们原样保留，不主动删用户的文件。
    return cfg
}

public func configToJson(cfg: Config): JsonValue {
    let o = Json.obj()
    Json.set(o, "version", Json.of(1))
    Json.set(o, "language", Json.of(cfg.language))
    let rootsArr = ArrayList<JsonValue>()
    for (r in cfg.roots) {
        rootsArr.add(Json.of(r))
    }
    Json.set(o, "roots", JArr(rootsArr))
    let ai = Json.obj()
    Json.set(o, "ai", ai)
    let update = Json.obj()
    let docsArr = ArrayList<JsonValue>()
    for (d in cfg.docs) {
        docsArr.add(Json.of(d))
    }
    Json.set(update, "docs", JArr(docsArr))
    let agentArr = ArrayList<JsonValue>()
    for (d in cfg.agentDocCandidates) {
        agentArr.add(Json.of(d))
    }
    Json.set(update, "agentDocCandidates", JArr(agentArr))
    Json.set(update, "backupKeep", Json.of(cfg.backupKeep))
    Json.set(update, "maxShallowBranches", Json.of(cfg.maxShallowBranches))
    Json.set(o, "update", update)
    // ⚠️ 曾经在这里恒发 `hooks: {mode}` 与 `server: {host, port}`。
    // 两个块都没有任何行为消费方（见类注释），而引擎会往**每个新建的
    // config.json** 里写它们 —— 于是每个用户手上都躺着一份
    // 「这台机器有个 server 在 5177」的假声明。写 = 宣称，所以不写。
    return o
}

public func loadConfig(): Config {
    let base = Config.defaults()
    match (readFileText(configPath())) {
        case Some(text) =>
            match (Json.parse(text)) {
                case Some(j) =>
                    var cfg = configFromJson(j, base)
                    return applyEnvOverrides(cfg)
                case None =>
                    Log.warn("config.json 解析失败，使用默认配置")
                    return applyEnvOverrides(base)
            }
        case None => return applyEnvOverrides(base)
    }
}

/// 写 config.json：**定点覆盖**，不整份重写。
///
/// ⚠️ 原来是 `writeFileAtomic(path, pretty(configToJson(cfg)))` ——
/// 由结构体重新生成**整份文档**，于是 config.json 里任何 Config 结构体
/// 不认识的键全部消失。实测（`moongit config set update.backupKeep 5` 前后）：
///     前：顶层 [version, language, clientAppSettings, update, server]
///         update [docs, experimental] / server [host, port, tls]
///     后：顶层 [version, language, roots, ai, update, hooks, server]
///         update [docs, agentDocCandidates, backupKeep, maxShallowBranches]
///         server [host, port]
/// `clientAppSettings` / `update.experimental` / `server.tls` 三个键被静默抹掉，
/// 而命令还打印「已设置 update.backupKeep = 5」。
///
/// config.json 是**共享文件**：客户端层（deepDolphin.app）也在里面放自己的设置。
/// 引擎整份重写 = 客户端的配置被引擎的一次 `config set` 悄悄清空。
/// 方向也反了：保护性写操作的失败方向应当是「多留一份」，不是「顺手删掉不认识的」。
///
/// 读不出来时（文件不存在 / 已损坏）才退回整份重写 —— 读不出来的东西没法保留，
/// 此时也已有 loadConfig 侧的「解析失败，使用默认配置」告警。
public func saveConfig(cfg: Config): Unit {
    let own = configToJson(cfg)
    match (readFileTextChecked(configPath())) {
        case Some(text) =>
            match (Json.parse(text)) {
                case Some(existing) =>
                    writeFileAtomic(configPath(), Json.pretty(mergeEngineOwned(existing, own)))
                    return
                case None => ()
            }
        case None => ()
    }
    writeFileAtomic(configPath(), Json.pretty(own))
}

/// 引擎**自己管的**子键白名单。写路径只碰这些，其余一律保留。
///
/// ⚠️ `hooks` / `server` 曾在这里（#194 已删）：引擎不再写它们，
/// 所以老 config.json 里的同名块会被 `mergeEngineOwned` **原样保留**——
/// 不主动删用户文件，但也不再宣称那些键有意义。
private let OWNED_TOP_SCALARS: Array<String> = ["version", "language", "roots"]
private let OWNED_SUB_KEYS: Array<(String, Array<String>)> = [
    ("ai", []),
    ("update", ["docs", "agentDocCandidates", "backupKeep", "maxShallowBranches"]),
]

private func mergeEngineOwned(existing: JsonValue, own: JsonValue): JsonValue {
    // existing 不是对象时无从「保留」，直接用引擎的完整投影
    match (Json.asObj(existing)) {
        case None => return own
        case Some(_) => ()
    }
    for (k in OWNED_TOP_SCALARS) {
        if (Json.has(own, k)) {
            Json.set(existing, k, Json.getOr(own, k))
        }
    }
    for ((key, subKeys) in OWNED_SUB_KEYS) {
        // own 里没有这个对象 → 引擎自己都不知道它写什么，不碰
        if (!Json.has(own, key)) {
            continue
        }
        // existing 里的同名对象若不是对象（比如用户写了 "update": 3），
        // 不能往非对象上塞键 —— 覆盖成一个新对象，丢掉的是那个畸形值。
        var target = Json.obj()
        match (Json.get(existing, key)) {
            case Some(cur) =>
                match (Json.asObj(cur)) {
                    case Some(_) => target = cur
                    case None => ()
                }
            case None => ()
        }
        for (sk in subKeys) {
            if (Json.has(Json.getOr(own, key), sk)) {
                Json.set(target, sk, Json.getOr(Json.getOr(own, key), sk))
            }
        }
        Json.set(existing, key, target)
    }
    return existing
}

public func applyEnvOverrides(cfg: Config): Config {
    match (getVariable("DEEPGIT_LANG")) {
        case Some(v) =>
            if (!v.isBlank()) {
                // ⚠️ L9：原来只做 isBlank 检查 ⇒ `DEEPGIT_LANG=fr` 被静默接受，
                // 而全仓判定是 `isEnglish(lang)`（lang != "en" ⇒ 中文）——
                // 于是设了一个不存在的语言，得到**全中文且零提示**。
                // #203 的三层纪律（写入口 / 读路径 / 运行时同一判据）在 env 分支
                // 漏掉了：这里补上 languageError，与 configFromJson 同一判据。
                let want = v.trimAscii()
                if (!SUPPORTED_LANGUAGES.contains(want)) {
                    Log.warn(languageError(want) + "（DEEPGIT_LANG 已忽略，继续用 ${cfg.language}）")
                } else {
                    cfg.language = want
                }
            }
        case None => ()
    }
    return cfg
}

// ------------------------------ 测试 ------------------------------

@Test
func testConfigDefaults(): Unit {
    let cfg = Config.defaults()
    @Assert(cfg.language == "zh")
    @Assert(cfg.docs.size == 3)
    @Assert(cfg.maxShallowBranches == 6)
    // 「不存在」与「值是默认值」是两个状态。#194 之前这两个键都存在，
    // 而它们零消费方 —— 引擎会往每个新 config.json 里写一个假的 server 块。
    let j = configToJson(cfg)
    @Assert(!Json.has(j, "server"))
    @Assert(!Json.has(j, "hooks"))
}

@Test
func testConfigRoundTrip(): Unit {
    let cfg = Config.defaults()
    cfg.language = "en"
    cfg.roots = ArrayList<String>(["/a", "/b"])
    let j = configToJson(cfg)
    let back = configFromJson(j, Config.defaults())
    @Assert(back.language == "en")
    @Assert(back.roots.size == 2)
}

@Test
func testConfigJsonShape(): Unit {
    let j = configToJson(Config.defaults())
    @Assert(Json.get(j, "ai").isSome())
    @Assert(Json.get(j, "update").isSome())
}

@Test
func testConfigRejectsNegativeBackupKeepOnLoad(): Unit {
    // 读路径是真正绕不过去的那一道：`config set` 的守卫可以被手改 config.json 绕过。
    // 实测绕过之后每次 update 都清空全部文档备份（详见 docs.cj 的 pruneBackups 说明）。
    let base = "/tmp/deepgit-negcfg-${nowMillis()}"
    ensureDir(base)
    let defaults = Config.defaults()
    @Assert(defaults.backupKeep > 0)

    let bad = Json.obj()
    let update = Json.obj()
    Json.set(update, "backupKeep", Json.of(-1))
    Json.set(update, "maxShallowBranches", Json.of(0))
    Json.set(bad, "update", update)
    let cfg = configFromJson(bad, defaults)
    // 负数 → 回落到默认，绝不带负值出门
    @Assert(cfg.backupKeep == defaults.backupKeep)
    // 0 个分支上限会让浅更新一个分支都不采，报告却像「只有这些分支」
    @Assert(cfg.maxShallowBranches == defaults.maxShallowBranches)

    // 合法值必须原样通过
    let ok = Json.obj()
    let okUpdate = Json.obj()
    Json.set(okUpdate, "backupKeep", Json.of(7))
    Json.set(okUpdate, "maxShallowBranches", Json.of(3))
    Json.set(ok, "update", okUpdate)
    let cfg2 = configFromJson(ok, defaults)
    @Assert(cfg2.backupKeep == 7)
    @Assert(cfg2.maxShallowBranches == 3)

    // 键缺失时用默认值
    @Assert(configFromJson(Json.obj(), defaults).backupKeep == defaults.backupKeep)

    removePathIfExists(base)
}

@Test
func testSaveConfigPreservesKeysEngineDoesNotOwn(): Unit {
    // config.json 是**共享文件**：客户端层（deepDolphin.app）也在里面放自己的设置。
    // 原来 saveConfig 由结构体重新生成整份文档，于是引擎不认识的键全部消失。
    //
    // 实测 `moongit config set update.backupKeep 5` 前后：
    //   前 顶层 [version, language, clientAppSettings, update, server]
    //      update [docs, experimental] / server [host, port, tls]
    //   后 顶层 [version, language, roots, ai, update, hooks, server]
    //      update [docs, agentDocCandidates, backupKeep, maxShallowBranches]
    //      server [host, port]
    // clientAppSettings / update.experimental / server.tls 被静默抹掉，
    // 而命令还打印「已设置 update.backupKeep = 5」。
    //
    // 方向也反了：保护性写操作失败时应当「多留一份」，不是「顺手删掉不认识的」。
    let base = "/tmp/deepgit-cfgmerge-${nowMillis()}"
    let testHome = base + "-home"
    ensureDir(testHome)
    enterTestHome(testHome)
    ensureDir(deepgitHome())
    writeFileAtomic(configPath(), "{\n" +
        "  \"version\": 1,\n" +
        "  \"language\": \"zh\",\n" +
        "  \"clientAppSettings\": {\"theme\": \"dark\"},\n" +
        "  \"update\": {\"docs\": [\"README.md\"], \"experimental\": true},\n" +
        "  \"server\": {\"host\": \"127.0.0.1\", \"port\": 7777, \"tls\": \"self-signed\"}\n" +
        "}\n")

    var cfg = loadConfig()
    cfg.backupKeep = 5
    saveConfig(cfg)

    let after = Json.parse(readFileTextOr(configPath(), "{}")).getOrThrow()
    // 别人的顶层键必须原样留下
    @Assert(Json.has(after, "clientAppSettings"))
    @Assert(Json.strAt(Json.getOr(after, "clientAppSettings"), "theme", "") == "dark")
    // 别人的子键（引擎同样不管 update.experimental / server.tls）也要留下
    @Assert(Json.boolAt(Json.getOr(after, "update"), "experimental", false) == true)
    @Assert(Json.strAt(Json.getOr(after, "server"), "tls", "") == "self-signed")
    // 引擎自己要写的仍然写了 —— 不能因为「要保留」就不写
    @Assert(Json.intAt(Json.getOr(after, "update"), "backupKeep", -1) == 5)
    // ⚠️ #194：`server` / `hooks` 已从引擎的 OWNED_SUB_KEYS 移出。
    // **保留**它们（不删用户的文件），但引擎**不再写**也不再宣称。
    @Assert(Json.intAt(Json.getOr(after, "server"), "port", -1) == 7777)
    // 反复保存不累积垃圾，也不丢别人的键
    saveConfig(loadConfig())
    saveConfig(loadConfig())
    let after2 = Json.parse(readFileTextOr(configPath(), "{}")).getOrThrow()
    @Assert(Json.has(after2, "clientAppSettings"))
    @Assert(Json.strAt(Json.getOr(after2, "server"), "tls", "") == "self-signed")
    @Assert(Json.intAt(Json.getOr(after2, "update"), "backupKeep", -1) == 5)

    // 配置文件不存在 → 退回整份写入（没有可保留的东西）
    removePathIfExists(configPath())
    var fresh = Config.defaults()
    fresh.backupKeep = 7
    saveConfig(fresh)
    @Assert(Json.intAt(Json.getOr(Json.parse(readFileTextOr(configPath(), "{}")).getOrThrow(), "update"), "backupKeep", -1) == 7)

    // 配置文件已损坏 → 读不出来就没有可保留的，整份重写而不是崩溃
    writeFileAtomic(configPath(), "{ not json at all")
    saveConfig(Config.defaults())
    @Assert(Json.parse(readFileTextOr(configPath(), "{}")).isSome())

    exitTestHome()
    removePathIfExists(testHome)
    removePathIfExists(base)
}

// ------------------------------ #194：配置键不许「说了不算」 ------------------------------

/// 收集 src/ 下所有 .cj 文件路径。
private func allCjFiles(dir: String, acc: ArrayList<String>): Unit {
    let (items, ok) = listDirChecked(dir)
    if (!ok) {
        return
    }
    for (it in items) {
        // 走 classifyEntry：不抛（#199）。源码目录里的条目一样可能 stat 不到
        // （构建产物里的断链软链、临时挂载），lint 扫全树时不能因此中断。
        match (classifyEntry(it)) {
            case EntryKind.Dir => allCjFiles(dir + "/" + it.name, acc)
            case EntryKind.Regular =>
                if (it.name.endsWith(".cj")) {
                    acc.add(dir + "/" + it.name)
                }
            case _ => ()
        }
    }
}

/// 剥掉全部注释的源码。逐字节处理后必须过 `fromUtf8Lossy` ——
/// 直接 `StringBuilder.append(UInt8)` 会走 `Any` 重载，把字节拼成
/// 十进制数字串，于是后面所有 `contains` 恒为 false。
private func codeOnly(src: String): String {
    let bytes = ArrayList<UInt8>()
    var blk = false
    for (raw in src.split("\n")) {
        let (l, nb) = stripCjComment(raw, blk)
        blk = nb
        for (c in l) {
            bytes.add(c)
        }
        bytes.add(0x0au8)
    }
    return fromUtf8Lossy(bytes.toArray())
}

/// 取出 `public class Config { … }` 里 `public var NAME` 的字段名。
private func configFieldNames(src: String): ArrayList<String> {
    let names = ArrayList<String>()
    var inClass = false
    for (raw in codeOnly(src).split("\n")) {
        let l = raw.trimAscii()
        if (l.startsWith("public class Config")) {
            inClass = true
            continue
        }
        if (!inClass) {
            continue
        }
        if (l.startsWith("}")) {
            break
        }
        if (!l.startsWith("public var ")) {
            continue
        }
        let rest = l[11..]   // 剥掉 "public var "
        // ⚠️ 逐字节取名必须走 fromUtf8Lossy：`c.toString()` 在 UInt8 上给的是
        // 十进制数字（108 而不是 'l'），拼出来是 "108111101031…" 这种东西，
        // 后面 `contains("cfg." + name)` 恒为 false ⇒ lint 报全部字段都死。
        let nameBytes = ArrayList<UInt8>()
        for (c in rest) {
            if (c == 0x3au8 || c == 0x20u8) {   // ':' 或空格
                break
            }
            nameBytes.add(c)
        }
        let name = fromUtf8Lossy(nameBytes.toArray())
        if (name.size > 0) {
            names.add(name)
        }
    }
    return names
}

/// #194 的不变量：**每个 Config 字段都必须有 config.cj 之外的消费方。**
///
/// 缺陷形状：`config set server.port 8080` 打印「✓ 已设置」、写进
/// config.json、能读回来 —— 而全仓库没有任何一行读它。
/// 命令确认了一件事，而那件事不会发生。三个字段（serverHost /
/// serverPort / hookMode）是这样死的，aiJsonMode 更极端（连
/// config.cj 自己的 load/emit 都没接）。
///
/// 写「有默认值」不等于「有消费方」：`Config` 的每个字段都带默认值，
/// 缺了就回落 —— 于是死字段既不会报错也不会有人发现。
///
/// ⚠️ 接收者名只认 `cfg.` 与 `config.`（实测这两个覆盖全部 Config 用法）。
/// 将来引入了第三个接收者名，这条会**假红** —— 那比假绿好：
/// 假绿会让死配置悄悄回来，假红只会让你更新一条 lint。
@Test
func testEveryConfigFieldHasAConsumerOutsideConfig(): Unit {
    let files = ArrayList<String>()
    allCjFiles("src", files)
    @Assert(files.size > 20)   // 确认真的读到了源码，不是空跑

    let self = "src/kernel/config.cj"
    let own = readFileTextChecked(self).getOrThrow()
    let names = configFieldNames(own)
    @Assert(names.size >= 5)

    // 除 config.cj 之外的所有源码，剥完注释拼起来
    let others = StringBuilder()
    var scanned = 0
    for (f in files) {
        if (f == self) {
            continue
        }
        let m = readFileTextChecked(f)
        if (m.isNone()) {
            continue
        }
        others.append(codeOnly(m.getOrThrow()))
        scanned += 1
    }
    @Assert(scanned > 20)
    let hay = others.toString()

    var dead = ArrayList<String>()
    for (n in names) {
        let has = hay.contains("cfg.${n}") || hay.contains("config.${n}")
        if (!has) {
            dead.add(n)
        }
    }
    @Assert(dead.size == 0)
}

// ------------------------------ #202：配置值的判据必须三层共用 ------------------------------

/// `maxShallowBranchesError` 的纯判定。
///
/// 缺陷 #202 的形状：`config set` 对一个**引擎会拒绝**的取值报「✓ 已设置」，
/// 而 `config get` 回读是别的值 —— 用户设的值被丢弃，报成功与解释在
/// **stdout / stderr 两个流**，脚本与 CI 看不见后者。
@Test
func testMaxShallowBranchesErrorIsTheSingleJudge(): Unit {
    // 合法
    @Assert(maxShallowBranchesError(1).isEmpty())
    @Assert(maxShallowBranchesError(6).isEmpty())
    @Assert(maxShallowBranchesError(1000).isEmpty())
    // 非法：0 与负数同侧（后果一样：候选集为空）
    @Assert(!maxShallowBranchesError(0).isEmpty())
    @Assert(!maxShallowBranchesError(-1).isEmpty())
    @Assert(!maxShallowBranchesError(-100).isEmpty())
    // 报错必须教回怎么改，且不能把负数说成 0
    let msg = maxShallowBranchesError(-3)
    @Assert(msg.contains("至少为 1"))
    @Assert(msg.contains("-3"))
    @Assert(msg.contains("分支"))
    @Assert(MIN_SHALLOW_BRANCHES == 1)
}

/// 三层闸门（写入口 / 读路径 / backupKeep 的运行时）必须共用**同一份**判据。
/// 各写一遍阈值必然漂移；漂了以后症状是「配置被接受了但行为不是那样」，最难查。
///
/// 这条 lint 盯的是「阈值字面量不许出现在闸门处」：
/// 合法值只允许出现在 `MIN_*` 常量定义与纯判定函数里。
@Test
func __lintConfigGatesShareOneJudge(): Unit {
    // ⚠️ needle 拼接：源码里不能出现完整 needle，否则这个 lint 匹配到自己。
    let gateA = "backupKeep < " + "0"
    let gateB = "maxShallowBranches < " + "0"
    let gateC = "maxShallowBranches < " + "1"
    for (f in ["src/kernel/config.cj", "src/kernel/docs.cj", "src/cli/cli.cj"]) {
        let raw = readFileTextChecked(f).getOrThrow()
        let sb = StringBuilder()
        var blk = false
        for (r in raw.split("\n")) {
            let (l, nb) = stripCjComment(r, blk)
            blk = nb
            sb.append(l)
            sb.append("\n")
        }
        let code = sb.toString()
        // 闸门处不许写死阈值：要么用 MIN_*，要么用 xxxError()
        for (needle in [gateA, gateB, gateC]) {
            var at = 0
            while (true) {
                let k = code.indexOf(needle, at)
                match (k) {
                    case None => break
                    case Some(i) =>
                        // 唯一允许出现的地方：定义 MIN_* 的那一行
                        let lineStart = lastIndexBefore(code, i)
                        let lineEnd = indexOfFrom(code, i, "\n")
                        let line = code[lineStart..lineEnd]
                        if (!line.contains("public let MIN_")) {
                            @Assert(false)
                        }
                        at = i + 1
                }
            }
        }
    }
    // 两处闸门都必须真的调判据函数
    let cli = readFileTextChecked("src/cli/cli.cj").getOrThrow()
    @Assert(cli.contains("backupKeepError(n)"))
    @Assert(cli.contains("maxShallowBranchesError(n)"))
    let conf = readFileTextChecked("src/kernel/config.cj").getOrThrow()
    @Assert(conf.contains("backupKeepError(cfg.backupKeep)"))
    @Assert(conf.contains("maxShallowBranchesError(cfg.maxShallowBranches)"))
    let docs = readFileTextChecked("src/kernel/docs.cj").getOrThrow()
    @Assert(docs.contains("keep < MIN_BACKUP_KEEP"))
}

/// 读路径必须真的把非法值**修回**默认值，而不是只打个警告就带着非法值往下走。
/// 修复前 backupKeep 读路径只拦 `< 0`，而写入口拦 `< 1` —— 两处差一档。
@Test
func testReadPathRepairsBothJudgesNotJustNegative(): Unit {
    let j = Json.obj()
    let up = Json.obj()
    Json.set(up, "backupKeep", Json.of(0))
    Json.set(up, "maxShallowBranches", Json.of(0))
    Json.set(j, "update", up)
    let base = Config.defaults()
    let cfg = configFromJson(j, base)
    @Assert(cfg.backupKeep == base.backupKeep)
    @Assert(cfg.maxShallowBranches == base.maxShallowBranches)
    // 负数同样修回
    let j2 = Json.obj()
    let up2 = Json.obj()
    Json.set(up2, "backupKeep", Json.of(-1))
    Json.set(up2, "maxShallowBranches", Json.of(-1))
    Json.set(j2, "update", up2)
    let cfg2 = configFromJson(j2, base)
    @Assert(cfg2.backupKeep == base.backupKeep)
    @Assert(cfg2.maxShallowBranches == base.maxShallowBranches)
    // 合法值不许被「顺手修掉」
    let j3 = Json.obj()
    let up3 = Json.obj()
    Json.set(up3, "backupKeep", Json.of(7))
    Json.set(up3, "maxShallowBranches", Json.of(3))
    Json.set(j3, "update", up3)
    let cfg3 = configFromJson(j3, base)
    @Assert(cfg3.backupKeep == 7)
    @Assert(cfg3.maxShallowBranches == 3)
}

// ------------------------------ #203：语言取值与 20 份副本 ------------------------------

/// 支持的语言只有一个来源，判据只有一个口径。
@Test
func testLanguageJudgeIsTheSingleSource(): Unit {
    @Assert(SUPPORTED_LANGUAGES.size == 2)
    @Assert(languageError("en").isEmpty())
    @Assert(languageError("zh").isEmpty())
    // 任何其它值都非法 —— 原来 `config set language fr` 报「✓ 已设置」，
    // 而引擎只有 en / 中文两条路，于是全仓渲染成中文且零提示。
    for (v in ["fr", "de", "ja", "zh-CN", "", "EN", "En"]) {
        @Assert(!languageError(v).isEmpty())
    }
    // 报错要列出合法值，并回显收到的值
    let msg = languageError("fr")
    @Assert(msg.contains("zh"))
    @Assert(msg.contains("en"))
    @Assert(msg.contains("fr"))
    // isEnglish 与 languageError 必须一致：说是 en 的就得真被支持
    @Assert(isEnglish("en"))
    @Assert(!isEnglish("zh"))
    @Assert(!isEnglish("fr"))
    // 大小写敏感要说清楚：EN 非法（否则用户会以为"设了就行"）
    @Assert(!languageError("EN").isEmpty())
}

/// 读路径必须和写入口用同一份判据（#202 的三层纪律）。手改 config.json 是
/// 绕过写入口的已知路径，读路径是最后一道。
@Test
func testReadPathRepairsUnsupportedLanguage(): Unit {
    let base = Config.defaults()
    // ⚠️ 仓颉的 lambda 是 `{ |x| => expr }`，不是 `|x| { … }`。
    // 这里直接内联构造，顺带避免闭包在测试里添乱。
    let bad1 = Json.obj()
    Json.set(bad1, "language", Json.of("fr"))
    @Assert(configFromJson(bad1, base).language == base.language)
    let bad2 = Json.obj()
    Json.set(bad2, "language", Json.of(""))
    @Assert(configFromJson(bad2, base).language == base.language)
    // 合法值不许被「顺手修掉」
    let ok1 = Json.obj()
    Json.set(ok1, "language", Json.of("en"))
    @Assert(configFromJson(ok1, base).language == "en")
    let ok2 = Json.obj()
    Json.set(ok2, "language", Json.of("zh"))
    @Assert(configFromJson(ok2, base).language == "zh")
}

/// 全仓**不许有任何** `!= "en"` 形式的判定；语言判定只走 `isEnglish`。
///
/// 为什么必须是 lint 而不是口头约定：缺陷 #203 的 `lang != "en"` 有 **20 份**副本
/// 跨 7 个文件。将来加第三种语言要改 20 处，**漏一处就出半中半英的输出** ——
/// 那比单一语言更糟，因为用户看到的是一份自相矛盾的文件。
/// 数量对不上就红，于是「加语言」从一个静默的漂移风险变成一次必须处理的编译期事件。
@Test
func __lintEnglishCheckHasExactlyOneCopy(): Unit {
    var total = 0
    for (f in ["src/util/text.cj", "src/util/time.cj", "src/kernel/render.cj",
               "src/kernel/progress.cj", "src/kernel/narrative.cj", "src/kernel/store.cj",
               "src/kernel/config.cj", "src/flow/report.cj", "src/flow/status.cj",
               "src/flow/update.cj", "src/flow/deep.cj", "src/cli/cli.cj", "src/cli/mcp.cj"]) {
        let raw = readFileTextChecked(f).getOrThrow()
        let sb = StringBuilder()
        var blk = false
        for (r in raw.split("\n")) {
            let (l, nb) = stripCjComment(r, blk)
            blk = nb
            sb.append(l)
            sb.append("\n")
        }
        for (line in sb.toString().split("\n")) {
            if (line.contains("!= \"en\"")) {
                total += 1
            }
        }
    }
    // 否定形一处都不许剩（接缝本身用正形 `== "en"`）
    @Assert(total == 0)
    // 接缝必须还在，且用正形 —— 否则有人把 isEnglish 删了/改回否定形也算绿
    let text = readFileTextChecked("src/util/text.cj").getOrThrow()
    @Assert(text.contains("public func isEnglish(lang: String): Bool"))
    @Assert(text.contains("return lang == \"en\""))
    // 写入口与读路径都调判据
    let cli = readFileTextChecked("src/cli/cli.cj").getOrThrow()
    @Assert(cli.contains("languageError(value)"))
    let conf = readFileTextChecked("src/kernel/config.cj").getOrThrow()
    @Assert(conf.contains("languageError(cfg.language)"))
}
