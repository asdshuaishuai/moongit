// 托管区域文档引擎：moonGit 只改写自己标记的区块，其余内容逐字节保留。
//
//   <!-- deepgit:begin progress -->
//   …生成内容…
//   <!-- deepgit:end progress -->
package moongit.kernel

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

public class Region {
    public let name: String
    public let start: Int64
    public let end: Int64
    public let content: String

    public init(name: String, start: Int64, end: Int64, content: String) {
        this.name = name
        this.start = start
        this.end = end
        this.content = content
    }
}

let beginMarkerPlaceholder = "<!-- deepgit:begin "
let endMarkerPlaceholder = "<!-- deepgit:end "

func beginMarker(name: String): String {
    return "<!-- deepgit:begin ${name} -->"
}

func endMarker(name: String): String {
    return "<!-- deepgit:end ${name} -->"
}

/// 严格解析文档中的托管区域，返回 (区域列表, 结构问题列表)。
///
/// **问题非空时调用方必须拒绝写入，绝不猜测。**
///
/// 为什么必须严格：旧实现对每个 begin 直接找「其后第一个同名 end」，既不校验嵌套也不校验配对。
/// 用户手敲一行未闭合的 `<!-- deepgit:begin progress -->`（很常见：从别处复制示例只抄了开头）时，
/// 第一次 update 会在文末追加引擎自己的块，正好给那行补上了配对的 end；
/// 第二次 update 区域跨度就从用户那行一直延伸到引擎的 end，中间全部用户内容被整体替换。
/// 实测：README 里「第二章：踩坑记录」整段消失，而 verify 用同一套错误配对逻辑做剥离，
/// 报「逐字节一致」——破坏与自查共用同一套错误逻辑，所以自查必然看不见。
///
/// 栈式配对同时解决嵌套问题：用户自己写的 `mine` 块里嵌一个 `progress` 块，
/// 旧实现的 searchFrom 会跳过外层 end 导致内层永久隐形，栈式解析则把两者都正确识别。
/// 字节偏移 → 行号。报错给用户看行号才有意义，「第 403 字节」没人能定位。
private func lineNumberAt(text: String, offset: Int64): Int64 {
    var line: Int64 = 1
    var i: Int64 = 0
    let stop = if (offset < text.size) { offset } else { text.size }
    while (i < stop) {
        if (text[i] == 0x0au8) {
            line += 1
        }
        i += 1
    }
    return line
}

/// 区域名判据：引擎自选的标识符，只允许 ASCII 字母/数字/下划线/连字符。
/// 解析侧用它挡掉文档正文里的占位写法（如 `...`）——它们是叙述不是标记。
/// 渲染侧（renderBlock）的名字来源全是引擎常量，与此判据天然一致。
func isRegionName(name: String): Bool {
    if (name.isEmpty()) {
        return false
    }
    for (b in name.toArray()) {
        let ok = (b >= 0x41u8 && b <= 0x5au8) || (b >= 0x61u8 && b <= 0x7au8) ||
                 (b >= 0x30u8 && b <= 0x39u8) || b == 0x5fu8 || b == 0x2du8
        if (!ok) {
            return false
        }
    }
    return true
}

public func parseRegions(text: String): (ArrayList<Region>, ArrayList<String>) {    let out = ArrayList<Region>()
    let problems = ArrayList<String>()
    // 栈：名称 / 区域起点 / 内容起点三个平行数组，避免元组下标。
    // 内容起点 = 该 begin 标记的 " -->" 之后的位置，闭合时用它切内容
    let names = ArrayList<String>()
    let starts = ArrayList<Int64>()
    let contentStarts = ArrayList<Int64>()

    var cursor: Int64 = 0
    while (cursor < text.size) {
        let bIdx = text.indexOf(beginMarkerPlaceholder, cursor)
        let eIdx = text.indexOf(endMarkerPlaceholder, cursor)
        var isBegin = false
        var idx: Int64 = 0
        if (bIdx.isSome() && eIdx.isSome()) {
            if (bIdx.getOrThrow() <= eIdx.getOrThrow()) {
                isBegin = true
                idx = bIdx.getOrThrow()
            } else {
                isBegin = false
                idx = eIdx.getOrThrow()
            }
        } else if (bIdx.isSome()) {
            isBegin = true
            idx = bIdx.getOrThrow()
        } else if (eIdx.isSome()) {
            isBegin = false
            idx = eIdx.getOrThrow()
        } else {
            break
        }

        match (text.indexOf(" -->", idx)) {
            case None =>
                problems.add("第 ${lineNumberAt(text, idx)} 行的 <!-- deepgit: 标记缺少闭合的 \" -->\"")
                break
            case Some(me) =>
                let headSize = if (isBegin) { beginMarkerPlaceholder.size } else { endMarkerPlaceholder.size }
                // ⚠️ 无名标记不是区域边界：`<!-- deepgit:begin -->`（begin 后
                // 直接闭合、无名字）常出现在**讲引擎格式的文档正文**里——本仓
                // README.md 第 26 行就有一处。此时闭合 " -->" 与占位符（含尾随
                // 空格）的匹配区重叠，me < idx + headSize，名字切片反向——
                // 实测抛 Invalid range [1713..1712]，update/deep 对本仓必崩
                // （任何能改文档的人都能远程触发，dogfood 实测抓到）。
                // 空名标记一律按叙述文本整段跳过，不进栈、不配对。
                let inverted = me < idx + headSize
                let name = if (inverted) { "" } else { text[idx + headSize..me].trimAscii() }
                // ⚠️ 区域名是引擎自选的标识符（progress / journal …，ASCII 字母
                // 数字下划线连字符）。名字不合法的"标记"——空名，或 AGENTS.md
                // 改名红线表里 `<!-- deepgit:begin ... -->` 这种把 `...` 当占位名
                // 的文档叙述——一律按普通文本跳过：不进栈、不配对、不因此拒绝
                // 改写（dogfood 实测：本仓 AGENTS.md 第 12 行曾让 update 对
                // 引擎自己的仓库永久拒绝写文档）。
                if (inverted || name.isEmpty() || !isRegionName(name)) {
                    cursor = me + 4
                } else if (isBegin) {
                    // 容忍标记行的前导空白：把区域起点回退到行首，
                    // 这样重写时不会残留旧的缩进（手写文档常见）。
                    var regionStart = idx
                    while (regionStart > 0) {
                        let ch = text[regionStart - 1]
                        if (ch == 0x20u8 || ch == 0x09u8) {
                            regionStart -= 1
                        } else {
                            break
                        }
                    }
                    names.add(name)
                    starts.add(regionStart)
                    contentStarts.add(me + 4)
                } else {
                    if (names.isEmpty()) {
                        problems.add("多余的 end 标记：${name}（第 ${lineNumberAt(text, idx)} 行），前面没有对应的 begin")
                    } else {
                        let openName = names[names.size - 1]
                        let openStart = starts[starts.size - 1]
                        let openContent = contentStarts[contentStarts.size - 1]
                        names.remove(at: names.size - 1)
                        starts.remove(at: starts.size - 1)
                        contentStarts.remove(at: contentStarts.size - 1)
                        if (openName != name) {
                            problems.add("标记不配对：begin ${openName} 被 end ${name} 关闭（第 ${lineNumberAt(text, idx)} 行）")
                        } else {
                            let rawContent = text[openContent..idx]
                            // ⚠️ 右边界必须是**实测**的标记末尾（me + 4），
                            // 不能用 endMarker(name).size 推算。
                            //
                            // 推算等于假设文档里的标记与规范形式逐字节相同，而
                            // 名字是 trimAscii() 出来的、对空白不敏感 ——
                            // 于是「标记被手改过空格」这条路径能通过解析、
                            // 却在算边界时算错。实测 end 标记写成
                            //   <!-- deepgit:end progress          -->
                            // （`-->` 前多打了 16 个空格），
                            // update 之后那一行变成
                            //   <!-- deepgit:end progress -->            -->
                            // 每跑一次就多留一截垃圾在用户的 agent 指令文件里。
                            //
                            // 反方向（标记比规范**短**）走不到这里：
                            // `<!-- deepgit:end progress-->` 里没有 " -->"
                            // 这段串，indexOf 会报「缺少闭合的 " -->"」并拒绝改写。
                            // 所以只有「长」这一侧会漏。
                            out.add(Region(name, openStart, me + 4, trimSingleNewline(rawContent)))
                        }
                    }
                }
                cursor = me + 4
        }
    }

    for (i in 0..names.size) {
        problems.add("未闭合的 begin 标记：${names[i]}（第 ${lineNumberAt(text, starts[i])} 行）。引擎拒绝改写此文档 —— 请补上对应的 end 标记，或删除/改名这一行")
    }
    // 闭合时是「内层先出栈」，所以 out 的顺序是内→外。按起点排成文档顺序，
    // 调用方（regionNames / 测试 / 未来可能的批量重写）拿到的顺序才符合直觉。
    for (i in 1..out.size) {
        let cur = out[i]
        var j = i - 1
        while (j >= 0 && out[j].start > cur.start) {
            out[j + 1] = out[j]
            j -= 1
        }
        out[j + 1] = cur
    }
    return (out, problems)
}

/// 列出文档中所有托管区域。
/// ⚠️ 仅供只读场景使用：结构异常时它会静默丢弃配对失败的那些区域。
/// 任何要写文件的路径必须用 parseRegions 并在 problems 非空时中止。
public func listRegions(text: String): ArrayList<Region> {
    let (regions, _) = parseRegions(text)
    return regions
}

func trimSingleNewline(s: String): String {
    var t = s
    if (t.startsWith("\n")) {
        t = t[1..]
    }
    if (t.endsWith("\n")) {
        t = t[..t.size - 1]
    }
    return t
}

public func regionNames(text: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (r in listRegions(text)) {
        out.add(r.name)
    }
    return out
}

func renderBlock(name: String, content: String): String {
    // 硬闸门：所有托管块写入的唯一收敛点，在这里做最后一次标记中和。
    //
    // oneLine() 已经在渲染侧中和过一次（覆盖绝大多数路径），但 renderBlock
    // 是唯一能保证「无论调用方是谁、无论内容从哪来，写出去的块都不可能
    // 携带伪造标记」的位置 —— 逐点加防护必然漏点，在这里加则不可能漏。
    //
    // 漏点的后果不是数据丢失（解析侧的栈式配对 + 重名 + 归属三重闸门挡得住），
    // 而是**写入通道被永久焊死**：README 里多一个假 begin 标记，此后每次
    // update/deep 都报「标记结构异常」退出，且因为内容每次都从 commit
    // subject 重新生成而无法自愈 —— 用户必须手工编辑 README 才能恢复。
    // 实测可远程触发：任何能给你推 commit 的人都可以。
    return "${beginMarker(name)}\n${tidyMarkdown(neutralizeMarkers(content))}${endMarker(name)}"
}

/// 替换已有区域内容
public func replaceRegion(text: String, name: String, content: String): Option<String> {
    for (r in listRegions(text)) {
        if (r.name == name) {
            let block = renderBlock(name, content)
            return Some(text[..r.start] + block + text[r.end..])
        }
    }
    return None
}

/// 在文末追加新区域。保留原文末尾的换行风格，只在必要时补分隔空行。
public func insertRegion(text: String, name: String, content: String): String {
    let block = renderBlock(name, content)
    if (text.size == 0) {
        return block + "\n"
    }
    // 已有文档：在保留原文的前提下追加（末尾无换行则先补一个）
    let needsNewline = !text.endsWith("\n")
    let needsBlank = !text.endsWith("\n\n")
    let sb = StringBuilder(text)
    if (needsNewline) {
        sb.append("\n")
    }
    if (needsBlank) {
        sb.append("\n")
    }
    sb.append(block)
    sb.append("\n")
    return sb.toString()
}

/// 把候选内容归一化成「落盘后再读回来」会得到的形态，用于与已存区域比对。
///
/// upsertRegion 的「内容未变」守卫原本是死代码：两侧根本不对称。
///   - 磁盘上的 r.content  来自 parseRegions → trimSingleNewline(tidyMarkdown(neutralizeMarkers(...)))
///     —— 尾部换行已被吃掉
///   - 传进来的 content    是调用方的原始渲染结果（如 renderProgressReadme
///     在分支循环里 sb.append("\n\n")）—— 尾部还带着两个换行
/// 于是 `stripUpdateStamp(r.content) == stripUpdateStamp(content)` 恒为 false，
/// stripUpdateStamp（它设计要压制的正是时间戳抖动）在真实写路径里从不生效。
/// 后果实测：跨分钟重跑 update 必定重写 README，每次都留一份备份、
/// 让用户仓库变脏产生提交噪音，而 CLI 报的是「已更新」不是「无变化」。
///
/// 只归一化「候选」一侧、不动已存的一侧：已存的那份本来就是归一化过的。
func normalizeForCompare(content: String): String {
    return trimSingleNewline(tidyMarkdown(neutralizeMarkers(content)))
}

/// 更新区域内容；若仅时间戳不同则保持原样（避免无意义的文件抖动/提交噪音）。
public func upsertRegion(text: String, name: String, content: String): String {
    for (r in listRegions(text)) {
        if (r.name == name) {
            if (stripUpdateStamp(r.content) == stripUpdateStamp(normalizeForCompare(content))) {
                return text  // 实质内容未变，保留原时间戳
            }
            let block = renderBlock(name, content)
            return text[..r.start] + block + text[r.end..]
        }
    }
    return insertRegion(text, name, content)
}

/// 去掉"更新于 <时间>"片段，用于语义等价比对。
/// 契约（审计 L10 收紧）：引擎只把 stamp 写在**引用行**里——render.cj 的
/// 块首行 `> … · 更新于 <时间>`。因此只剥「`>` 开头的行」里的 stamp 且只剥
/// 第一处；正文行（commit subject / AI 摘要等用户可控文本）出现「更新于 」
/// 时**不许动**——否则两边同剥错行，等价比对失真：该更新时不更新，
/// 或无谓重写留备份弄脏用户仓库。行扫描的切点全在 ASCII 字节上（行首 /
/// 换行处），无 UTF-8 劈切风险。
public func stripUpdateStamp(content: String): String {
    let marker = "更新于 "
    var lineStart: Int64 = 0
    while (lineStart < content.size) {
        let rest = content[lineStart..]
        let nl = rest.indexOf("\n")
        let lineLen = match (nl) {
            case Some(n) => n
            case None => rest.size
        }
        let line = rest[0..lineLen]
        if (line.startsWith(">")) {
            match (line.indexOf(marker)) {
                case Some(i) =>
                    // 只剥第一处：marker 到行尾
                    return content[..lineStart + i] + content[lineStart + lineLen..]
                case None => ()
            }
        }
        lineStart += lineLen + 1   // +1 跳过换行；无换行的末行使下一轮条件不满足
    }
    return content
}

public class ApplyResult {
    public let file: String
    public let changed: Bool
    public let created: Bool
    public let backup: String
    public let regions: ArrayList<String>

    public init(file: String, changed: Bool, created: Bool, backup: String, regions: ArrayList<String>) {
        this.file = file
        this.changed = changed
        this.created = created
        this.backup = backup
        this.regions = regions
    }
}

/// 写入前的准入校验：结构异常、同名多块、以及「同名块不是引擎写的」一律拒绝。
///
/// 第三条是实测出来的：用户自己手写一个 `<!-- deepgit:begin progress -->` 块
/// （比如放团队迭代表格），第一次 update 就把它整体替换成引擎的进度块，
/// 而 verify 用的是同一套剥离逻辑，报「逐字节一致」。
///
/// 判据用「引擎是否写过这份文档」而不是给标记加签名 —— 后者要改标记格式，
/// 现有安装的所有托管块都没有签名，会一次性全部失效。
/// 备份目录只在真正写入时创建，所以它存在 == 引擎以前管过这份文档。
/// 对已安装的用户零影响（有备份目录 → 认定块是引擎的），只拦新文档的首次冲突。
/// 备份目录里记录「引擎已接管哪些托管区域」的凭据文件名，每行一个区域名。
///
/// ⚠️ 归属判据必须**按区域**记录，不能只按文件。
/// 旧判据是「备份目录存在 = 引擎拥有这份文档」，而要保护的对象是**区域**：
///   引擎写过 progress 区域 → 整份 README 被判为「引擎拥有」
///   → 同名的 overview 区域即使引擎从未碰过，也照写不误
/// 而「用户在自己项目的 README 里手写一个 `<!-- deepgit:begin overview -->`
/// 迭代表格」是完全正常的行为。实测：
///   update（只写 progress）→ 用户自己加 overview 块 → deep
///   → PRECIOUS-USER-OVERVIEW-TABLE 被整体替换，verify 报「逐字节一致」
/// verify 看不见是因为它比对时两边都把该块剥掉了 —— 用户的整块内容消失后，
/// 两边自然一致。这与「破坏者与审计者共用同一个假设」是同一族。
let OWNED_MANIFEST = ".owned"

/// 读「引擎已接管的区域」清单。老备份没有这个文件时返回空列表，
/// 调用方据此退回文件级判据（见 assertRegionsWritable 的说明）。
public func readOwnedRegions(backupDir: String): ArrayList<String> {
    let out = ArrayList<String>()
    if (backupDir.isEmpty() || !isDirectoryPath(backupDir)) {
        return out
    }
    for (line in readFileTextOr("${backupDir}/${OWNED_MANIFEST}", "").split("\n")) {
        let t = line.trimAscii()
        if (!t.isEmpty()) {
            out.add(t)
        }
    }
    return out
}

/// 把本次已接管的区域并进清单（只增不减：引擎一旦写过某区域，
/// 将来就不该因为一次失败写入而「忘掉」这段所有权）。
public func writeOwnedRegions(backupDir: String, names: ArrayList<String>): Unit {
    if (backupDir.isEmpty()) {
        return
    }
    try {
        ensureDir(backupDir)
        let merged = readOwnedRegions(backupDir)
        for (n in names) {
            if (!merged.contains(n)) {
                merged.add(n)
            }
        }
        writeFileAtomic("${backupDir}/${OWNED_MANIFEST}", joinStrings(merged, "\n") + "\n")
    } catch (e: Exception) {
        // 写不进去不阻断文档写入：文档本身已经安全落盘，
        // 只是下次会多一次「归属不明」的确认成本。方向是「宁可多问一次」。
        ()
    }
}

private func assertRegionsWritable(
    filePath: String,
    original: String,
    regions: ArrayList<(String, String)>,
    backupDir: String,
): Unit {
    if (original.isEmpty()) {
        return
    }
    let (existing, problems) = parseRegions(original)
    if (!problems.isEmpty()) {
        throw DgError(
            "DOC_REGION_MALFORMED",
            "${basename(filePath)} 的 <!-- deepgit: 托管标记结构异常，已拒绝改写（否则可能覆盖你的内容）：\n  - " +
                joinStrings(problems, "\n  - "),
            1,
            Some(basename(filePath)),
        )
    }
    // 归属判据按**区域**取，而不是按文件。
    //
    // 旧判据 `engineOwnsDoc = 备份目录存在`，粒度与被保护对象不匹配：
    // 引擎只要写过这份文档的**任意**区域，同名的其它区域就完全失去保护。
    let owned = readOwnedRegions(backupDir)
    // 迁移兼容：老备份目录里没有 .owned。此时退回旧的**文件级**判据，
    // 而不是一律拒绝 —— 否则所有存量用户会在一次例行 update 后
    // 突然被「区域归属不明」挡住，那是拿可用性换正确性，方向错了。
    // 代价是**过渡期内**（该文档下一次成功写入之前）这个洞还在；
    // 写完那次就会生成 .owned，洞自动关闭。
    let legacyDocLevel = owned.isEmpty() && !backupDir.isEmpty() && isDirectoryPath(backupDir)
    for ((name, _) in regions) {
        var n: Int64 = 0
        for (r in existing) {
            if (r.name == name) {
                n += 1
            }
        }
        // 同名区域多于一个 → 归属不明，拒绝猜测（否则只会更新第一个，另一个永久过时）
        if (n > 1) {
            throw DgError(
                "DOC_REGION_DUPLICATE",
                "${basename(filePath)} 里有 ${n} 个名为「${name}」的托管区域，无法判断该更新哪一个，已拒绝改写",
                1,
                Some(basename(filePath)),
            )
        }
        // 引擎从未接管过这个区域，却已存在同名块 → 那多半是用户自己的内容。
        //
        // 判据必须逐区域问「我写过这个块吗」，而不是逐文件问
        // 「我写过这份文档吗」—— 后者会让「我写过 progress」
        // 顺带授权我覆盖用户自己的 overview。
        if (n == 1 && !owned.contains(name) && !legacyDocLevel) {
            throw DgError(
                "DOC_REGION_NOT_OWNED",
                "${basename(filePath)} 里已有一个名为「${name}」的 <!-- deepgit: 托管区块，" +
                    "但引擎从未接管过**这个区块** —— 那很可能是你自己写的内容，引擎不会覆盖它。\n" +
                    "  确认可以交给引擎的话：删掉该区块（含 begin/end 两行）后重试。",
                1,
                Some(basename(filePath)),
            )
        }
    }
}

/// 读入一份**即将被整体重写**的文档。
///
/// ⚠️ 内容**不是合法 UTF-8 时必须拒绝写入**，不能有损解码后照写。
///
/// 这是本引擎「静默降级成事实性谎言」最恶劣的一种形态，因为
/// **破坏者与审计者共用同一个有损假设，自查通道因此同时失效**：
///
///   1. 读入走 fromUtf8Lossy，把非法字节替换成 U+FFFD；
///   2. 托管区**之外**的用户正文（也就是「其余内容逐字节保留」这条核心承诺
///      保护的对象）被整体替换；
///   3. 文档被整篇写回，U+FFFD 固化下来；
///   4. `verify` 读回时同样走 fromUtf8Lossy，两边把同样的 U+FFFD 当成原文，
///      于是报「校验通过：用户内容均未被改动」。
///
/// 实测（沙箱）：
///   GBK README  → 23 字节原文件里 11 处字节被换成 U+FFFD，verify 报 OK
///   UTF-16 README → 40 字节膨胀成 550 字节，BOM 与中文全成 U+FFFD，verify 报 OK
///   内嵌 \xff\xfe → 变成 2 个 U+FFFD，verify 无感
///
/// 缓解：备份里保留着原始字节，可回滚。但备份不是许可 ——
/// 用户不会知道自己的一份 README 被改成了另一种编码。
///
/// 方向选择：**宁可拒绝写**。判错的后果是不对称的：
/// 误拒（用户文件本来合法）= 少更新一次文档；
/// 误写（文件其实不合法）= 不可逆地改坏用户的正文。
public func readDocForRewrite(filePath: String): String {
    let p = Path(filePath)
    if (!exists(p)) {
        return ""
    }
    // 故意不 catch：读不出来必须让调用方知道，绝不能降级成空内容
    // （降级成空串 = 把用户的整份文档清空，只剩一个引擎块）
    let bytes = File.readFrom(p)
    try {
        return String.fromUtf8(bytes)
    } catch (e: Exception) {
        throw DgError("DOC_NOT_UTF8",
            "${basename(filePath)} 不是合法的 UTF-8 文本（可能是 GBK/UTF-16 编码或含二进制内容），已拒绝改写：" +
            "moonGit 会把读到的内容整篇写回，有损解码会把托管区之外的用户正文替换成 U+FFFD 并永久固化。" +
            "请先把它转存为 UTF-8（macOS 可用 `iconv -f gbk -t utf-8 <原文件> > <文件>`）再重试")
    }
}

/// 应用一组区域内容到文件（带备份与变更检测）
public func applyRegions(filePath: String, regions: ArrayList<(String, String)>, backupDir: String, createTemplate: String): ApplyResult {
    let exists = fileExists(filePath)
    var original = ""
    var created = false
    if (exists) {
        // 读失败必须抛，不能降级成空串：原文会被整体重写，
        // 把「读不出来」当成「空文档」等于清空用户的整份文档。
        // 非 UTF-8 也必须抛：见 readDocForRewrite 的注释（有损解码会毁掉
        // 托管区之外的用户正文，而 verify 因为同样有损而看不见）
        original = readDocForRewrite(filePath)
    } else if (!createTemplate.isEmpty()) {
        original = createTemplate
        created = true
    }

    assertRegionsWritable(filePath, original, regions, backupDir)

    var next = original
    var changed = false
    let applied = ArrayList<String>()
    for ((name, content) in regions) {
        let after = upsertRegion(next, name, content)
        if (after != next) {
            changed = true
        }
        next = after
        applied.add(name)
    }

    if (!changed) {
        // 即使内容没变也要记归属：闸门已经确认过这些区块归引擎所有，
        // 记下来下次就能按区域精确判断，而不必再退回文件级判据。
        writeOwnedRegions(backupDir, applied)
        return ApplyResult(filePath, false, false, "", applied)
    }

    var backupPath = ""
    if (exists && !backupDir.isEmpty()) {
        ensureDir(backupDir)
        backupPath = uniqueBackupPath(backupDir, basename(filePath))
        copy(Path(filePath), to: Path(backupPath), overwrite: true)
    }

    // 只规整 moonGit 生成的区域内容（renderBlock 内已做），
    // 文档其余部分必须逐字节保留 —— 不能对整篇文档做 tidyMarkdown。
    writeFileAtomic(filePath, next)
    // 归属凭据必须在文档写成功**之后**记：先记后写一旦写失败，
    // 就会凭空多出一块「引擎拥有」的区域。
    writeOwnedRegions(backupDir, applied)
    return ApplyResult(filePath, true, created, backupPath, applied)
}

/// 只算不写：算出「应用 regions 后是否真的会变」以及「文件是否会被新建」。
/// 供 --dry-run 使用。dry-run 必须如实回答会不会变 —— 早先 update/deep 硬编码
/// changed=true，导致已是最新的文档也报「需要更新」，用 dry-run 判断要不要跑更新的
/// 调用方恒得到「要」。changed 的判定与 applyRegions 完全一致（upsertRegion 纯比较）。
public func previewRegions(filePath: String, regions: ArrayList<(String, String)>, createTemplate: String, backupDir: String): ApplyResult {
    let exists = fileExists(filePath)
    var original = ""
    var created = false
    if (exists) {
        // 读失败必须抛，不能降级成空串：原文会被整体重写，
        // 把「读不出来」当成「空文档」等于清空用户的整份文档。
        // 非 UTF-8 也必须抛：见 readDocForRewrite 的注释（有损解码会毁掉
        // 托管区之外的用户正文，而 verify 因为同样有损而看不见）
        original = readDocForRewrite(filePath)
    } else if (!createTemplate.isEmpty()) {
        original = createTemplate
        created = true
    }

    // 与 applyRegions 用同一套校验：dry-run 必须预告真实运行会拒绝，
    // 否则「dry-run 说没事、真跑报错」比直接报错更难排查
    assertRegionsWritable(filePath, original, regions, backupDir)

    var next = original
    var changed = false
    let applied = ArrayList<String>()
    for ((name, content) in regions) {
        let after = upsertRegion(next, name, content)
        if (after != next) {
            changed = true
        }
        next = after
        applied.add(name)
    }
    return ApplyResult(filePath, changed, created, "", applied)
}

/// 生成互不冲突的备份路径。
///
/// fileTimestamp() 只精确到秒，而同一秒内对同一份文档写两次会用 overwrite 覆盖掉
/// 前一份快照。cmdVerify 的核心假设正是「最新备份 = 本次写入前」—— 基线一旦被覆盖，
/// 校验就会拿写后状态当对照，用户内容被改动也检测不出来（假阴性）。
/// 这里在重名时追加定宽序号，保证每次写入都留下独立快照；
/// 定宽（pad2）是为了让按文件名排序取最大值仍然得到正确顺序。
/// 从一份文档的备份目录里挑出**最新的真备份**。没有就返回 None。
///
/// ⚠️ 为什么必须过滤 `.` 开头的文件（缺陷 #195）：
/// 备份目录里除了真备份，还住着两个元数据文件：
///   `.docpath` —— 这份文档的真实相对路径（目录名把 `/` 换成了 `_`，不可逆）
///   `.owned`  —— 这份文档的托管区域名清单
/// 原来 `cmdVerify` 把 `listDir` 的结果**整个**当成备份列表，
/// 于是「取最新备份」= 按文件名取字典序最大的那个：
///   真备份叫 `<时间戳>-<文件名>`（`2` = 0x32）
///   `.owned` 的首字符是 `.`（0x2E）
/// ⇒ 有真备份时真备份赢（一切看起来正常），**没有真备份时 `.owned` 赢**。
///
/// 什么时候没有真备份？`applyRegions` 只在 `exists` 为真时才留备份
/// （见上面 `if (exists && !backupDir.isEmpty())`）—— 也就是
/// **引擎自己新建的文档一份快照都没有**。实测：注册一个只有 a.txt 的空仓库，
/// 跑一次 `moongit update` 生成 README.md，再 `moongit verify`：
///   备份目录里只有 `.docpath` 与 `.owned`，没有真备份
///   → verify 拿 README 的非托管区域去和字符串 "progress"（.owned 的内容）比
///   → 报「非托管区域与上次写入前不一致（你之后编辑过，或引擎改动了托管区域
///      外内容；备份可恢复）」，退出码 1
/// 用户一个字都没改，文档是引擎自己建的，却被**指控**被改过。
/// 而那句 note 正是设计来诱导 agent「从备份恢复 / 重跑 update」的。
///
/// 正确结论是第三态：**无法判定**（没有写入前快照，无可比对的证据）。
/// 这个函数是那个判定的接缝。
public func latestRealBackup(backupDir: String): Option<String> {
    var best = ""
    for (b in listDir(backupDir)) {
        // 走 classifyEntry：b.isDirectory() 遇到 stat 不到的条目会抛，
        // 而备份目录的路径来自用户配置文档里写的字符串。
        let isDir = match (classifyEntry(b)) {
            case EntryKind.Dir => true
            case _ => false
        }
        if (isDir || b.name.startsWith(".")) {
            continue   // 元数据与子目录都不是文档快照
        }
        if (b.name > best) {
            best = b.name
        }
    }
    if (best.isEmpty()) {
        return None
    }
    return Some("${backupDir}/${best}")
}

private func uniqueBackupPath(backupDir: String, name: String): String {
    let base = "${backupDir}/${fileTimestamp()}-${name}"
    var candidate = base
    var n: Int64 = 2
    while (fileExists(candidate) && n < 1000) {
        candidate = "${base}-${pad2(n)}"
        n += 1
    }
    if (fileExists(candidate)) {
        // 候选耗尽时旧实现直接返回 base —— 而 base 一定已存在，
        // copy(overwrite: true) 会把**最早那份**快照覆盖掉。
        // 那份快照可能正是 cmdVerify 唯一的校验基线，静默覆盖等于毁掉证据。
        // 这里宁可让本次写入失败并说清楚，也不假装成功。
        throw DgError(
            "BACKUP_NAME_EXHAUSTED",
            "备份文件名候选已用尽（${base}-01..-999 都存在），为避免覆盖已有快照已中止写入：${backupDir}",
            1,
            Some(backupDir),
        )
    }
    return candidate
}

/// 校验文档完整性：剥离托管区域后，用户内容应与备份（写入前）一致。
/// 用于自查「只改托管区域」这一核心承诺是否被违反。
///
/// 返回 (通过, 无法判定, 说明)。三态而不是两态：
/// 「读不到证据」不等于「证据通过」。旧实现把备份读不到直接返回 (true, "无备份可比对")，
/// 计入 checked、报 OK、退出码 0 —— 权限被改、备份被误删时，verify 会为一次
/// 它根本没做的校验背书。
public func verifyPreservation(filePath: String, backupFile: String): (Bool, Bool, String) {
    match (readFileText(backupFile)) {
        case None => return (false, true, "无法判定：读不到备份 ${basename(backupFile)}")
        case Some(before) =>
            match (readFileText(filePath)) {
                case None => return (false, true, "无法判定：读不到当前文档 ${basename(filePath)}")
                case Some(after) =>
                    // 结构异常时不能判定。破坏与校验如果共用同一套错误的配对逻辑，
                    // 两边会剥掉同一段内容然后报「一致」—— 那是假通过。
                    let (_, pBefore) = parseRegions(before)
                    let (_, pAfter) = parseRegions(after)
                    if (!pBefore.isEmpty() || !pAfter.isEmpty()) {
                        return (false, true, "无法判定：托管标记结构异常（${basename(filePath)}），无法确定哪些内容属于引擎")
                    }
                    let b = stripRegionsForVerify(before)
                    let a = stripRegionsForVerify(after)
                    if (b == a) {
                        return (true, false, "逐字节一致")
                    }
                    if (b.trimAscii() == a.trimAscii()) {
                        return (true, false, "仅文末分隔空行差异（插入区域所必需）")
                    }
                    // 措辞要准确：这里比对的是「当前文件」与「上次写入前的备份」，
                    // 差异只说明非托管区域在上次写入之后被改过 —— 可能是使用者自己编辑的，
                    // 也可能是 moonGit 破坏了托管区域以外的内容。两者后果不同，
                    // 不能一律写成「用户内容被改动」而让使用者误以为引擎毁了自己的内容。
                    return (false, false, "非托管区域与上次写入前不一致（你之后编辑过，或引擎改动了托管区域外内容；备份可恢复）")
            }
    }
}

/// 剥离全部托管区域（用于完整性校验）
public func stripRegionsForVerify(text: String): String {
    let sb = StringBuilder()
    var cursor: Int64 = 0
    while (cursor < text.size) {
        let beginIdx = text.indexOf(beginMarkerPlaceholder, cursor)
        match (beginIdx) {
            case None =>
                sb.append(text[cursor..])
                break
            case Some(bi) =>
                // 回退到标记行行首（含前导空白）
                var lineStart = bi
                while (lineStart > 0) {
                    let ch = text[lineStart - 1]
                    if (ch == 0x20u8 || ch == 0x09u8) {
                        lineStart -= 1
                    } else {
                        break
                    }
                }
                sb.append(text[cursor..lineStart])
                let afterBegin = bi + beginMarkerPlaceholder.size
                let closeIdx = text.indexOf(" -->", afterBegin)
                match (closeIdx) {
                    case None =>
                        sb.append(text[bi..])
                        break
                    case Some(ci) =>
                        let name = text[afterBegin..ci].trimAscii()
                        let endIdx = text.indexOf(endMarker(name), ci)
                        match (endIdx) {
                            case None =>
                                sb.append(text[bi..])
                                break
                            case Some(ei) =>
                                // 跳过整个区域与其后的空行
                                var next = ei + endMarker(name).size
                                while (next < text.size && text[next] == 0x0au8) {
                                    next += 1
                                }
                                cursor = next
                        }
                }
        }
    }
    return sb.toString()
}

/// 备份目录里记录「原始相对路径」的清单文件名。
/// 目录名是 file.replace("/", "_")，这个映射不可逆：docs/AGENTS.md → docs_AGENTS.md，
/// 而合法文件名里本来也可以带下划线，verify 无法从目录名反推原文路径。
/// 猜错的后果是 verify 去找一个根本不存在的文件，然后报「文档已被删除」——
/// 而我刚加的这条告警本来是给真实删除用的，不能被这种误报淹没。
let BACKUP_MANIFEST = ".docpath"

/// 写入清单。失败不阻断写入：verify 会退回旧的目录名反推。
public func writeBackupManifest(backupDir: String, relPath: String): Unit {
    try {
        ensureDir(backupDir)
        writeFileAtomic("${backupDir}/${BACKUP_MANIFEST}", relPath)
    } catch (e: Exception) {
        ()
    }
}

/// 读清单；老备份没有清单时返回空串，由调用方退回目录名反推。
public func readBackupManifest(backupDir: String): String {
    return readFileTextOr("${backupDir}/${BACKUP_MANIFEST}", "").trimAscii()
}

/// 备份保留数的**合法下界**，也是判据的**唯一来源**。
///
/// 缺陷 #201：`config set update.backupKeep 0` 原来放行（只拦负数），
/// 而 `pruneBackups` 也只拦负数，于是 0 走到「excess = names.size - 0」=
/// **把全部备份删光**，包括 `applyRegions` 在同一次运行里刚为用户文件建的那份。
/// 实测：`backupKeep=0` 跑一次 `moongit update proj` →
///   引擎报「✓ 已更新 README.md」、exit 0、托管区写进了用户的 README，
///   而备份文件数 = 0。用户的原文永久丢失，引擎全程报告成功。
///
/// 0 与负数的**后果完全一样**（都让 `excess >= names.size`），
/// 所以只拦负数的那道闸门从一开始就没关上。
/// 同一个仓库里这条规则已经写过三遍：
///   `--depth 0`（#197 拒）、`journal --limit 0`（拒）、`backupKeep < 0`（拒）。
/// 现在 `backupKeep 0` 也要拒 —— 阈值从这两个地方各写一遍必然漂移，
/// 所以只有一个来源。
public let MIN_BACKUP_KEEP: Int64 = 1

/// 纯判定：备份保留数是否合法。返回空串表示合法，否则返回该报给用户的原因。
public func backupKeepError(n: Int64): String {
    if (n >= MIN_BACKUP_KEEP) {
        return ""
    }
    return "update.backupKeep 至少为 ${MIN_BACKUP_KEEP}（收到 ${n}）：" +
        "备份是引擎改写你的 README/AGENTS 托管区时唯一的回滚手段，" +
        "上限小于 1 时每次改写后都不留退路"
}

/// 修剪备份目录至最新 keep 个
public func pruneBackups(backupDir: String, keep: Int64): Unit {
    if (!isDirectoryPath(backupDir)) {
        return
    }
    // ⚠️ 非法 keep 必须**跳过剪枝**，绝不能当成 0。
    //
    // keep 为负时原实现会算出 excess = names.size - keep > names.size，
    // 于是把**全部**备份删光；而且 keep 还是负的，之后每次都算成 excess > 0，
    // 于是**永远存不下新备份**。
    //
    // ⚠️ #201：**0 有同样的后果**。原来只拦 `keep < 0`，0 照样算出
    // excess = names.size - 0 = names.size，把全部删光 ——
    // 包括本次运行 applyRegions 刚建的那份，于是用户原文当场丢失、
    // 而引擎报「已更新」并 exit 0。判据改为 `backupKeepError`（单一来源）。
    //
    // 实测：config set update.backupKeep -1 会被写入口拦住，
    // 但直接改 config.json 就绕过去了（负载校验只在一处，绕过去就没人管）：
    //   backupKeep=20 跑 3 次 → 备份 3 份
    //   改成 -1 再跑 1 次    → 备份 0 份（三份被清空，零告警）
    //   再跑 1 次            → 备份 0 份（之后永久存不下）
    //
    // 文档备份是引擎重写用户 README/AGENTS 托管区时**唯一的回滚手段**，
    // 一个坏配置让这道防线自动失效、还顺手删掉已有的快照，方向完全错了。
    // 判错方向必须是「多留一份」，不是「多删一份」。
    if (keep < MIN_BACKUP_KEEP) {
        Log.error("备份保留数非法（${keep}），已跳过本次剪枝：${backupDir}（不删除任何备份；${backupKeepError(keep)}；请修 config.json 的 update.backupKeep）")
        return
    }
    let entries = listDir(backupDir)
    let names = ArrayList<String>()
    for (e in entries) {
        // 跳过元文件（如 .docpath 清单）：它按名字排序会排在最前面，
        // 混进修剪列表就会被当成「最旧的备份」删掉。
        if (e.name.startsWith(".")) {
            continue
        }
        names.add(e.name)
    }
    if (names.size <= keep) {
        return
    }
    names.sort()
    let excess = names.size - keep
    var i: Int64 = 0
    for (n in names) {
        if (i >= excess) {
            break
        }
        removePathIfExists("${backupDir}/${n}")
        i += 1
    }
}

// ------------------------------ 测试 ------------------------------

@Test
func testListRegions(): Unit {
    let doc = "# Title\n\n<!-- deepgit:begin progress -->\nhello\n<!-- deepgit:end progress -->\n\nmore text\n"
    let regions = listRegions(doc)
    @Assert(regions.size == 1)
    @Assert(regions[0].name == "progress")
    @Assert(regions[0].content == "hello")
}

@Test
func testListMultipleRegions(): Unit {
    let doc = "<!-- deepgit:begin overview -->\nA\n<!-- deepgit:end overview -->\n\n<!-- deepgit:begin progress -->\nB\n<!-- deepgit:end progress -->"
    let names = regionNames(doc)
    @Assert(names.size == 2)
    @Assert(names[0] == "overview")
    @Assert(names[1] == "progress")
}

@Test
func testReplaceRegionPreservesSurrounding(): Unit {
    let doc = "# Title\n\n<!-- deepgit:begin progress -->\nold\n<!-- deepgit:end progress -->\n\nfooter\n"
    let next = replaceRegion(doc, "progress", "new content").getOrThrow()
    @Assert(next.contains("new content"))
    @Assert(!next.contains("old"))
    @Assert(next.startsWith("# Title"))
    @Assert(next.contains("footer"))
}

@Test
func testUpsertAppendsWhenMissing(): Unit {
    let doc = "# Title\n"
    let next = upsertRegion(doc, "progress", "generated")
    @Assert(next.contains("# Title"))
    @Assert(next.contains("deepgit:begin progress"))
    @Assert(next.contains("generated"))
}

@Test
func testUserContentIsPreservedByteForByte(): Unit {
    let doc = "用户手写内容 🙌\n\n<!-- deepgit:begin progress -->\nold\n<!-- deepgit:end progress -->\n\n尾部内容\n"
    let next = replaceRegion(doc, "progress", "new").getOrThrow()
    @Assert(next.contains("用户手写内容 🙌"))
    @Assert(next.contains("尾部内容"))
    @Assert(next.contains("new"))
}

@Test
func testUpsertRegionKeepsOldTimestampWhenContentUnchanged(): Unit {
    let content1 = "> moonGit · 更新于 2026-09-30 10:00\n\n正文内容"
    let doc = upsertRegion("# t\n", "progress", content1)
    let content2 = "> moonGit · 更新于 2026-09-30 11:00\n\n正文内容"
    let doc2 = upsertRegion(doc, "progress", content2)
    @Assert(doc2 == doc)  // 时间戳未刷新
    let content3 = "> moonGit · 更新于 2026-09-30 11:00\n\n正文已改变"
    let doc3 = upsertRegion(doc, "progress", content3)
    @Assert(doc3 != doc)
    @Assert(doc3.contains("正文已改变"))
    @Assert(doc3.contains("11:00"))
}

@Test
func testNoOpGuardSurvivesCrossMinuteStampAndTrailingNewlines(): Unit {
    // 上面那条单测两侧都不带尾随换行，于是**绕开了**真实渲染器的形态。
    // 真实路径是：renderProgressReadme / renderProgressAgent 在分支循环里
    // `sb.append("\n\n")`，交到 upsertRegion 的候选内容尾部带着换行；
    // 而存盘那一侧来自 parseRegions，已经被 trimSingleNewline 吃掉了。
    // 两侧因此不对称 —— 这正是 normalizeForCompare 存在的理由。
    //
    // 触发条件也必须是**跨分钟**：renderBlock 的时间戳是分钟粒度
    // （formatDateTime 取到 HH:MM），同一分钟内两次跑的 stamp 相同，
    // 于是 stripUpdateStamp 两侧都命中，测试会**假绿**。
    // 第一版就栽在这里：两条 update 跑在同一秒内，把 normalizeForCompare
    // 整个删掉测试照样绿。负控跑出全绿 = 测试没有判别力。
    let dir = "/tmp/deepgit-stamp-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/AGENTS.md"
    let backupDir = "${dir}/bk"
    try {
        // 真实渲染器的形态：尾部两个换行 + 引用行 + 若干空行
        let rendered1 = "> moonGit · 更新于 2026-09-30 10:00\n\n## 进度\n\n- main：3 个提交\n\n\n"
        let r1 = applyRegions(file, regionsOf(rendered1), backupDir, "")
        @Assert(r1.changed)
        let after1 = readFileTextOr(file, "")
        @Assert(after1.contains("10:00"))

        // 跨一分钟：只有时间戳和尾部换行数不同，正文一字未改
        let rendered2 = "> moonGit · 更新于 2026-09-30 11:00\n\n## 进度\n\n- main：3 个提交\n\n\n"
        let r2 = applyRegions(file, regionsOf(rendered2), backupDir, "")
        // 核心：必须判定为「无变化」
        @Assert(!r2.changed)
        // 文件必须逐字节不变 —— 重写就会让用户仓库变脏、每次留一份备份
        @Assert(readFileTextOr(file, "") == after1)
        // 旧时间戳必须保留（不被刷新成 11:00）
        @Assert(readFileTextOr(file, "").contains("10:00"))
        // 备份不得增加。首轮是 0 而不是 1：applyRegions 只在 `exists` 时留备份，
        // 而首轮文件还不存在 —— 那里本来就是 0，不是被这轮涨上去的。
        @Assert(countBackupFiles(backupDir) == 0)

        // 正文真变了就必须改 —— 守卫不能变成「什么都不写」
        let rendered3 = "> moonGit · 更新于 2026-09-30 11:00\n\n## 进度\n\n- main：9 个提交\n\n\n"
        let r3 = applyRegions(file, regionsOf(rendered3), backupDir, "")
        @Assert(r3.changed)
        @Assert(readFileTextOr(file, "").contains("9 个提交"))
        // 真实变更才留备份：上一轮断言 0、这一轮断言 1，两者合起来才说明
        // 「备份只在真写时产生」，而不是「备份功能坏了」
        @Assert(countBackupFiles(backupDir) == 1)
    } finally {
        removePathIfExists(dir)
    }
}

/// 单区域参数表。applyRegions 的 regions 形参要的是 ArrayList<(String, String)>
/// 而不是数组字面量，所以单独包一层。
func regionsOf(content: String): ArrayList<(String, String)> {
    return ArrayList<(String, String)>([("progress", content)])
}

/// 备份目录下的备份文件数（`.owned` / `.docpath` 是归属凭据，不算备份）。
///
/// ⚠️ 备份文件**直接躺在** backupDir 下（uniqueBackupPath 就在这一层拼时间戳文件名），
/// 不要再往下找子目录 —— 那是调用方传进来那层的形态：
/// 真实路径是 `${store.backups}/${file}`，即 store.backups 下按文档分子目录、
/// 每个子目录里才是备份文件。这里传的是叶子目录，两种形态不要混。
func countBackupFiles(backupDir: String): Int64 {
    var n: Int64 = 0
    for (f in listDir(backupDir)) {
        // 走 classifyEntry：不抛（#199）
        let isDir = match (classifyEntry(f)) {
            case EntryKind.Dir => true
            case _ => false
        }
        if (!isDir && !f.name.startsWith(".")) {
            n += 1
        }
    }
    return n
}

@Test
func testStripUpdateStamp(): Unit {
    // 契约（审计 L10 收紧）：只剥「`>` 引用行」里的 stamp——引擎只在渲染块
    // 首行写 `> … · 更新于 <时间>`（render.cj）。正文行里的「更新于 」是
    // 用户可控文本（commit subject 等），误剥会让等价比对两边同剥错行。
    @Assert(stripUpdateStamp("> moonGit · 更新于 2026-01-01 00:00\n\n正文") == "> moonGit · \n\n正文")
    @Assert(stripUpdateStamp("## 进度\n\n> 更新于 2026-01-01 00:00\n\n### main") == "## 进度\n\n> \n\n### main")
    // 非 quote 行不许动（原实现会从首个「更新于 」剥到行尾——正是 L10 的缺陷形态）
    @Assert(stripUpdateStamp("a 更新于 2026-01-01 00:00\nb") == "a 更新于 2026-01-01 00:00\nb")
    @Assert(stripUpdateStamp("no stamp here") == "no stamp here")
    // AGENTS 渲染行的形态（时间在行尾；renderProgressAgent 生成）：
    // 时间被中和，「追踪 N 个分支」这类真实状态保留——它变了就该重写
    @Assert(stripUpdateStamp("> 浅更新 · 追踪 4 个分支 · 更新于 2026-10-10 17:07")
        == "> 浅更新 · 追踪 4 个分支 · ")
    // 旧行形态（时间在中间、无「更新于」）——历史上剥不到、每分钟必重写的元凶；
    // 现在渲染端已统一为时间在行尾，但行内含「更新于」的任意形态仍要能剥
    @Assert(stripUpdateStamp("> 浅更新 · 2026-10-10 17:07 · 追踪 4 个分支")
        == "> 浅更新 · 2026-10-10 17:07 · 追踪 4 个分支")
}

@Test
func testProseMarkerWithoutNameIsNotARegion(): Unit {
    // 回归（dogfood 实测抓到）：正文里的字面量 `<!-- deepgit:begin -->`（无名字）
    // 曾让名字切片反向（Invalid range [1713..1712]），update/deep 对写了这行字
    // 的仓库必崩——本仓 README.md 第 26 行自己就有一处。
    let doc = "# t\n\n讲格式的正文：**`<!-- deepgit:begin -->`** 是托管标记的字面形态。\n\n<!-- deepgit:begin progress -->\n旧内容\n<!-- deepgit:end progress -->\n"
    let (regions, problems) = parseRegions(doc)
    @Assert(regions.size == 1)
    @Assert(regions[0].name == "progress")
    @Assert(problems.isEmpty())
    // 写路径不被这块叙述文本卡死
    let next = upsertRegion(doc, "progress", "新内容")
    @Assert(next.contains("新内容"))
    @Assert(next.contains("托管标记的字面形态"))
}

@Test
func testProseMarkerWithPlaceholderNameIsNotARegion(): Unit {
    // 回归（dogfood 实测抓到，同族第二形态）：改名红线表里的
    // `<!-- deepgit:begin ... -->` 把 `...` 当占位名——语法上像命名标记，
    // 但 `...` 不是合法区域名（区域名只允许 [A-Za-z0-9_-]）。曾让本仓
    // AGENTS.md 被「未闭合的 begin 标记：…」永久拒绝改写。
    let doc = "# t\n\n| `<!-- deepgit:begin ... -->` | 字面量契约，改了引擎认不出托管区 |\n\n<!-- deepgit:begin progress -->\n旧内容\n<!-- deepgit:end progress -->\n"
    let (regions, problems) = parseRegions(doc)
    @Assert(regions.size == 1)
    @Assert(regions[0].name == "progress")
    @Assert(problems.isEmpty())
    let next = upsertRegion(doc, "progress", "新内容")
    @Assert(next.contains("新内容"))
    // 非法名的 end 同样只是叙述：不成对、不报问题
    let doc2 = "<!-- deepgit:begin progress -->\n内容\n<!-- deepgit:end progress -->\n\n表格：`<!-- deepgit:end ... -->`\n"
    let (r2, p2) = parseRegions(doc2)
    @Assert(r2.size == 1)
    @Assert(p2.isEmpty())
}

@Test
func testIndentedMarkerIsRecognizedAndReNormalized(): Unit {
    // 手写文档里标记常被缩进；重写后应回归顶格，且不产生重复区域
    let doc = "# t\n\n   <!-- deepgit:begin progress -->\n旧内容\n   <!-- deepgit:end progress -->\n"
    @Assert(listRegions(doc).size == 1)
    @Assert(listRegions(doc)[0].name == "progress")
    let next = upsertRegion(doc, "progress", "新内容")
    @Assert(next.contains("新内容"))
    @Assert(!next.contains("旧内容"))
    @Assert(listRegions(next).size == 1)
    // 重写后标记应顶格（不要残留缩进）
    @Assert(next.contains("\n<!-- deepgit:begin progress -->") || next.startsWith("<!-- deepgit:begin progress -->"))
}

@Test
func testNoDuplicateRegionWhenMarkerIndented(): Unit {
    let doc = "   <!-- deepgit:begin progress -->\nA\n   <!-- deepgit:end progress -->\n"
    let next = upsertRegion(doc, "progress", "B")
    var count: Int64 = 0
    for (r in listRegions(next)) {
        if (r.name == "progress") {
            count += 1
        }
    }
    @Assert(count == 1)
}

@Test
func testUnclosedRegionIgnored(): Unit {
    let doc = "<!-- deepgit:begin progress -->\nnever closed\n"
    @Assert(listRegions(doc).size == 0)
}

@Test
func testUserWhitespaceIsPreservedExactly(): Unit {
    let doc = "# 标题\n\n\n\n（连续空行应保留）\n带行尾空格   \n\n<!-- deepgit:begin progress -->\n旧\n<!-- deepgit:end progress -->\n"
    let next = upsertRegion(doc, "progress", "新")
    @Assert(next.contains("标题\n\n\n\n"))     // 连续空行未被压缩
    @Assert(next.contains("带行尾空格   \n"))     // 行尾空格未被去掉
    @Assert(next.contains("新"))
}

@Test
func testApplyRegionsPreservesUserWhitespaceOnDisk(): Unit {
    let dir = "/tmp/deepgit-ws-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    let original = "# T\n\n\n内容行   \n"
    writeFileAtomic(file, original + "\n<!-- deepgit:begin progress -->\nold\n<!-- deepgit:end progress -->\n")
    let regions = ArrayList<(String, String)>([("progress", "new")])
    // 备份目录已存在 = 引擎以前写过这份文档。assertRegionsWritable 靠它区分
    // 「引擎自己的块（可更新）」与「用户自己写的同名块（拒绝覆盖）」。
    let backupDir = "${dir}/backups"
    ensureDir(backupDir)
    applyRegions(file, regions, backupDir, "")
    let after = readFileTextOr(file, "")
    @Assert(after.contains("# T\n\n\n内容行   \n"))  // 原文空白原样保留
    removePathIfExists(dir)
}

@Test
func testApplyRegionsCreatesFile(): Unit {
    let dir = "/tmp/deepgit-docs-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    let regions = ArrayList<(String, String)>([("progress", "## 进度\n\n内容")])
    let res = applyRegions(file, regions, "${dir}/backups", "# 新文档\n\n")
    @Assert(res.changed)
    @Assert(res.created)
    let text = readFileTextOr(file, "")
    @Assert(text.contains("## 进度"))
    @Assert(text.contains("# 新文档"))
    removePathIfExists(dir)
}

@Test
func testApplyRegionsBacksUpAndIsIdempotent(): Unit {
    let dir = "/tmp/deepgit-docs2-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    writeFileAtomic(file, "# Original\n\n<!-- deepgit:begin progress -->\nold\n<!-- deepgit:end progress -->\n")
    let regions = ArrayList<(String, String)>([("progress", "v2")])
    // 备份目录已存在 = 引擎以前写过这份文档。assertRegionsWritable 靠它区分
    // 「引擎自己的块（可更新）」与「用户自己写的同名块（拒绝覆盖）」。
    let backupDir = "${dir}/backups"
    ensureDir(backupDir)
    let r1 = applyRegions(file, regions, backupDir, "")
    @Assert(r1.changed)
    @Assert(!r1.backup.isEmpty())
    let r2 = applyRegions(file, regions, backupDir, "")
    @Assert(!r2.changed)  // 幂等
    // 同上：只数真实备份，点开头的元文件（.docpath / .owned）不算
    var backups: Int64 = 0
    for (e in listDir("${dir}/backups")) {
        if (!e.name.startsWith(".")) {
            backups += 1
        }
    }
    @Assert(backups == 1)
    removePathIfExists(dir)
}

@Test
func testVerifyPreservationDetectsNoChange(): Unit {
    let dir = "/tmp/deepgit-verify-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    let before = "# T\n\n用户内容\n"
    writeFileAtomic("${dir}/backup.md", before + "\n<!-- deepgit:begin progress -->\nold\n<!-- deepgit:end progress -->\n")
    writeFileAtomic(file, before + "\n<!-- deepgit:begin progress -->\nnew content here\n<!-- deepgit:end progress -->\n")
    let (ok, undetermined, _) = verifyPreservation(file, "${dir}/backup.md")
    @Assert(ok)
    @Assert(!undetermined)
    removePathIfExists(dir)
}

@Test
func testVerifyPreservationDetectsTampering(): Unit {
    let dir = "/tmp/deepgit-verify2-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    writeFileAtomic("${dir}/backup.md", "# T\n\n用户内容A\n")
    writeFileAtomic(file, "# T\n\n用户内容B（被改了）\n<!-- deepgit:begin progress -->\nx\n<!-- deepgit:end progress -->\n")
    let (ok, undetermined, reason) = verifyPreservation(file, "${dir}/backup.md")
    @Assert(!ok)
    @Assert(!undetermined)
    // 措辞必须中立：差异只说明「上次写入后非托管区域被改过」，
    // 使用者自己编辑与引擎破坏托管区外内容是两种不同后果，不能默认归咎引擎。
    @Assert(reason.contains("非托管区域"))
    @Assert(reason.contains("你之后编辑过"))
    @Assert(!reason.contains("用户内容被改动"))
    removePathIfExists(dir)
}

/// #195：**引擎自己新建的文档没有任何写入前快照**，而 verify 曾把它
/// 报成「非托管区域与上次写入前不一致」。
///
/// 根因：备份目录里除真备份外还住着 `.docpath` / `.owned` 两个元数据文件，
/// 原来它们被整个当成备份列表，「取最新」= 取字典序最大的文件名：
///   真备份 `<时间戳>-README.md`（首字符 `2` = 0x32）
///   `.owned`（首字符 `.` = 0x2E）
/// 有真备份时真备份赢（看着一切正常），**没有时 `.owned` 赢** ——
/// 于是拿 README 去和字符串 "progress"（.owned 的内容）比，必然不一致。
///
/// 后果是**假指控**：用户一个字没改，文档是引擎建的，却被说成被改过；
/// 而那句 note 正是设计来诱导 agent「从备份恢复 / 重跑 update」的。
///
/// 走真实写路径（applyRegions）而不是手搓目录：手搓的目录不会复现
/// 「新建 ⇒ 无快照」这个前提（#188 的教训）。
@Test
func testVerifyOnEngineCreatedDocumentHasNoSnapshotAndIsNotTampered(): Unit {
    let dir = "/tmp/deepgit-verifynew-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    let backupDir = "${dir}/backups/README.md"
    let regions = ArrayList<(String, String)>([("progress", "## 进度\n\n内容")])

    // ① 引擎新建文档：applyRegions 走的是 `if (exists)` 那一支的**否**路径，
    //    不留快照，只写两个元数据文件。
    let res = applyRegions(file, regions, backupDir, "# 新文档\n\n")
    @Assert(res.created)
    // 真实流程里备份目录会同时住着这两个元数据文件（.docpath 由
    // writeBackupManifest 写，.owned 由 applyRegions 写），
    // 所以这里也补上 —— 现场就是「两个元数据 + 零快照」
    writeBackupManifest(backupDir, "README.md")
    @Assert(fileExists("${backupDir}/${OWNED_MANIFEST}"))
    @Assert(fileExists("${backupDir}/${BACKUP_MANIFEST}"))

    // 这就是缺陷的现场：目录里只有元数据，一份真快照都没有
    @Assert(latestRealBackup(backupDir).isNone())

    // 「没有快照」不能被读成「被改过」—— 拿元数据当备份去比必然不一致，
    // 而元数据的内容与文档正文毫无关系
    // ⚠️ 仓颉里 `!` 的优先级高于 `==`，必须加括号
    let metaOnly = readFileTextOr("${backupDir}/${OWNED_MANIFEST}", "")
    let doc = readFileTextOr(file, "")
    let strippedBody = stripRegionsForVerify(doc).trimAscii()
    @Assert(!(strippedBody == metaOnly.trimAscii()))

    // ② 第二次写入：文件已存在 **且区域内容真的变了** ⇒ 这才有快照。
    //    ⚠️ 区域内容不变时 applyRegions 走 `if (!changed) return` 提前返回，
    //    压根不写备份 —— 所以这里必须换一份区域内容，否则测的是另一条路径。
    let body = readFileTextOr(file, "") + "\n用户加的一行\n"
    writeFileAtomic(file, body)
    let regions2 = ArrayList<(String, String)>([("progress", "## 进度\n\n第二版内容")])
    let res2 = applyRegions(file, regions2, backupDir, "")
    @Assert(!res2.created)
    @Assert(res2.changed)
    @Assert(latestRealBackup(backupDir).isSome())
    // 快照必须是**文档**（含刚加的那行用户内容），不是元数据
    let snap = latestRealBackup(backupDir).getOrThrow()
    @Assert(readFileTextOr(snap, "").contains("用户加的一行"))
    // 刚刚逐字节校验过 ⇒ 通过
    let (ok, undetermined, _) = verifyPreservation(file, snap)
    @Assert(ok)
    @Assert(!undetermined)

    removePathIfExists(dir)
}

/// latestRealBackup 必须挑最新的**真备份**，且无视元数据。
/// 直接按 `listDir` 取字典序最大的话，`.owned` 会在没有快照时顶上来。
@Test
func testLatestRealBackupIgnoresMetadataAndPicksNewestSnapshot(): Unit {
    let dir = "/tmp/deepgit-latestbk-${nowMillis()}"
    ensureDir(dir)
    // 只有元数据 ⇒ 没有真备份
    writeFileAtomic("${dir}/.docpath", "README.md")
    writeFileAtomic("${dir}/.owned", "progress\n")
    @Assert(latestRealBackup(dir).isNone())

    // 有了快照：`.owned`（0x2E）在字典序上小于 `2...`（0x32），
    // 但这条测试不能只靠「. 排在 2 后面」—— 必须**只**看真备份。
    writeFileAtomic("${dir}/2026-01-01T00-00-00-README.md", "第一份\n")
    @Assert(latestRealBackup(dir).getOrThrow() == "${dir}/2026-01-01T00-00-00-README.md")
    writeFileAtomic("${dir}/2026-12-31T23-59-59-README.md", "最后一份\n")
    @Assert(latestRealBackup(dir).getOrThrow() == "${dir}/2026-12-31T23-59-59-README.md")
    // 加一份排在元数据之后的假快照也不能被跳过
    writeFileAtomic("${dir}/9999-README.md", "最新\n")
    @Assert(latestRealBackup(dir).getOrThrow() == "${dir}/9999-README.md")
    // 子目录不是快照
    ensureDir("${dir}/sub")
    @Assert(latestRealBackup(dir).getOrThrow() == "${dir}/9999-README.md")
    // 目录不存在 ⇒ None（不是崩、不是「通过」）
    @Assert(latestRealBackup("${dir}/nope").isNone())

    removePathIfExists(dir)
}

@Test
func testStripRegionsForVerify(): Unit {
    let doc = "A\n<!-- deepgit:begin progress -->\nX\n<!-- deepgit:end progress -->\nB\n"
    let stripped = stripRegionsForVerify(doc)
    @Assert(stripped.contains("A"))
    @Assert(stripped.contains("B"))
    @Assert(!stripped.contains("X"))
}

@Test
func testPruneBackups(): Unit {
    let dir = "/tmp/deepgit-prune-${nowMillis()}"
    ensureDir(dir)
    for (i in 0..5) {
        writeFileAtomic("${dir}/b${i}", "x")
    }
    pruneBackups(dir, 2)
    @Assert(listDir(dir).size == 2)
    removePathIfExists(dir)
}

@Test
func testApplyRegionsKeepsDistinctBackups(): Unit {
    // fileTimestamp() 只精确到秒 + copy(overwrite: true) 曾导致同一秒内对同一文档
    // 两次写入互相覆盖，前一份快照消失。而 verify 的核心假设是「最新备份 = 本次写入前」，
    // 基线被覆盖后校验拿写后状态当对照，用户内容被改动也检测不出来（假阴性）。
    let dir = "/tmp/deepgit-bk-${nowMillis()}"
    ensureDir(dir)
    let f = dir + "/DOC.md"
    let backupDir = dir + "/backups"
    writeFileAtomic(f, "# user content\n")
    let first = ArrayList<(String, String)>([("progress", "FIRST-BODY")])
    let second = ArrayList<(String, String)>([("progress", "SECOND-BODY")])
    applyRegions(f, first, backupDir, "")
    applyRegions(f, second, backupDir, "")
    // 两次写入必须留下两份独立快照（跨秒或同秒都要成立）。
    // ⚠️ 只数**真实备份**，点开头的元文件（.docpath 路径清单、
    // .owned 区域归属凭据）不算 —— 它们和备份同处一个目录，
    // 直接数目录项会让「加一个元文件」变成一次假红灯。
    // pruneBackups 那边同样按 startsWith(".") 跳过，两侧口径必须一致。
    var backups: Int64 = 0
    for (e in listDir(backupDir)) {
        if (!e.name.startsWith(".")) {
            backups += 1
        }
    }
    @Assert(backups == 2)
    removePathIfExists(dir)
}

@Test
func testPreviewRegionsReportsTruthfully(): Unit {
    // --dry-run 以前硬编码 changed=true，导致「已是最新」的文档也报需要更新。
    // previewRegions 必须给出和 applyRegions 一致的判断，且不落盘。
    let dir = "/tmp/deepgit-preview-${nowMillis()}"
    ensureDir(dir)
    let f = dir + "/DOC.md"
    let regions = ArrayList<(String, String)>([("progress", "MANAGED-BODY")])
    // 备份目录已存在 = 引擎以前写过这份文档。assertRegionsWritable 靠它区分
    // 「引擎自己的块（可更新）」与「用户自己写的同名块（拒绝覆盖）」。
    let backupDir = "${dir}/backups"
    ensureDir(backupDir)

    // 文件不存在 + 给了模板 → 会新建且必然有变化
    let fresh = previewRegions(f, regions, "# T\n\n", backupDir)
    @Assert(fresh.created)
    @Assert(fresh.changed)
    @Assert(!fileExists(f))          // 只算不写

    // 先真实写入一次，让托管区域与目标一致
    let applied = applyRegions(f, regions, backupDir, "# T\n\n")
    @Assert(applied.changed)
    @Assert(applied.created)

    // 目标内容与现状一致 → 不应报变化
    let same = previewRegions(f, regions, "# T\n\n", backupDir)
    @Assert(!same.changed)
    @Assert(!same.created)

    // 托管区域内容不同 → 应报变化
    let diff = ArrayList<(String, String)>([("progress", "OTHER-BODY")])
    @Assert(previewRegions(f, diff, "# T\n\n", backupDir).changed)

    // 托管区域不存在（普通文档）→ 会新增该区域 → 报变化
    let plain = dir + "/PLAIN.md"
    writeFileAtomic(plain, "# plain\n")
    @Assert(previewRegions(plain, regions, "", backupDir).changed)

    removePathIfExists(dir)
}

// ---------- 托管标记结构校验（防内容销毁） ----------

@Test
func testUnclosedBeginIsReportedInsteadOfAbsorbingUserContent(): Unit {
    // 这是本引擎最严重的一类缺陷，必须锁死。
    // 旧实现对每个 begin 找「其后第一个同名 end」，不校验配对。于是：
    //   README:  …用户正文…\n<!-- deepgit:begin progress -->\n（我以后想自己放东西）
    // 第 1 次 update 在文末追加引擎块 → 正好给用户那行补上了配对的 end
    // 第 2 次 update 区域跨度 = 用户那行 → 引擎块 → 引擎 end
    //   → 用户正文被 renderBlock 整体替换，实测「第二章：踩坑记录」整段消失
    //   → 而 verify 用同一套错误配对做剥离，报「逐字节一致」
    // 现在：未闭合的 begin 必须被报成结构问题，交给调用方拒绝写入。
    let doc = "# T\n\n## 第二章：踩坑记录\n\n- 坑一\n\n<!-- deepgit:begin progress -->\n我以后想自己放东西在这\n"
    let (regions, problems) = parseRegions(doc)
    @Assert(regions.size == 0)          // 不得凭空造出区域
    @Assert(problems.size == 1)
    @Assert(problems[0].contains("未闭合"))
    @Assert(problems[0].contains("progress"))
    @Assert(problems[0].contains("第 7 行"))  // 报错给行号，不是字节偏移
}

@Test
func testApplyRegionsRefusesMalformedDocument(): Unit {
    let dir = "/tmp/deepgit-malformed-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    // 用户正文在悬空 begin 之后 —— 旧实现在这里会被整体覆盖
    writeFileAtomic(file, "# T\n\n precious\n\n<!-- deepgit:begin progress -->\n用户手写\n\n## 第二章：踩坑记录\n")
    let regions = ArrayList<(String, String)>([("progress", "引擎内容")])

    var threw = false
    try {
        _ = applyRegions(file, regions, "${dir}/backups", "")
    } catch (e: DgError) {
        threw = true
        @Assert(e.code == "DOC_REGION_MALFORMED")
    }
    @Assert(threw)
    // 关键：文件必须一个字节都没动
    let after = readFileTextOr(file, "")
    @Assert(after.contains("第二章：踩坑记录"))
    @Assert(after.contains("precious"))
    @Assert(!after.contains("引擎内容"))
    // dry-run 必须预告同一错误，否则「dry-run 说没事、真跑报错」更难排查
    var threw2 = false
    try {
        _ = previewRegions(file, regions, "", "")
    } catch (e: DgError) {
        threw2 = e.code == "DOC_REGION_MALFORMED"
    }
    @Assert(threw2)
    removePathIfExists(dir)
}

@Test
func testDuplicateRegionNamesAreRefused(): Unit {
    // 两个同名块都合法闭合，但引擎无法判断该更新哪一个。
    // 旧实现只更新第一个、第二个永久冻结过时 —— 两份互相矛盾的进度同时存在。
    let dir = "/tmp/deepgit-dup-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    writeFileAtomic(file, "<!-- deepgit:begin progress -->\nA\n<!-- deepgit:end progress -->\n\n正文\n\n<!-- deepgit:begin progress -->\nB\n<!-- deepgit:end progress -->\n")
    let regions = ArrayList<(String, String)>([("progress", "新内容")])
    var threw = false
    try {
        _ = applyRegions(file, regions, "${dir}/backups", "")
    } catch (e: DgError) {
        threw = e.code == "DOC_REGION_DUPLICATE"
    }
    @Assert(threw)
    let after = readFileTextOr(file, "")
    @Assert(after.contains("A") && after.contains("B"))  // 原样保留
    removePathIfExists(dir)
}

@Test
func testNestedRegionsAreBothParsed(): Unit {
    // 用户自己写的 mine 块里嵌一个 progress 块。旧实现的 searchFrom 跳过外层 end，
    // 内层永久隐形 → 引擎在文末追加出第二个 progress 块，用户看到两份矛盾进度。
    let doc = "<!-- deepgit:begin mine -->\n我的说明\n<!-- deepgit:begin progress -->\nOLD\n<!-- deepgit:end progress -->\n<!-- deepgit:end mine -->\n"
    let (regions, problems) = parseRegions(doc)
    @Assert(problems.isEmpty())
    @Assert(regions.size == 2)
    // 按文档顺序：外层 mine 在前、内层 progress 在后
    @Assert(regions[0].name == "mine")
    @Assert(regions[0].content.contains("OLD"))  // 外层内容确实包含内层
    @Assert(regions[1].name == "progress")

    // 正常改写：只动内层，外层用户的说明文字保留，且不产生重复块
    let next = upsertRegion(doc, "progress", "NEW")
    @Assert(next.contains("NEW"))
    @Assert(!next.contains("OLD"))
    @Assert(next.contains("我的说明"))
    let (after, afterProblems) = parseRegions(next)
    @Assert(afterProblems.isEmpty())
    @Assert(after.size == 2)
}

@Test
func testMismatchedMarkersAreReported(): Unit {
    // begin A 被 end B 关闭：旧实现会按 A 的名字去找 A 的 end，跨度算错
    let doc = "<!-- deepgit:begin a -->\nX\n<!-- deepgit:end b -->\n"
    let (_, problems) = parseRegions(doc)
    @Assert(problems.size >= 1)
    @Assert(problems[0].contains("不配对"))
}

@Test
func testStrayEndMarkerIsReported(): Unit {
    let doc = "正文\n<!-- deepgit:end progress -->\n"
    let (regions, problems) = parseRegions(doc)
    @Assert(regions.isEmpty())
    @Assert(problems.size == 1)
    @Assert(problems[0].contains("多余的 end"))
}

@Test
func testVerifyPreservationIsUndeterminedWithoutEvidence(): Unit {
    // 「读不到证据」不等于「证据通过」。旧实现返回 (true, "无备份可比对")，
    // 计入 checked、报 OK、退出码 0 —— 备份被误删或权限被改时，verify 会为
    // 一次它根本没做的校验背书。
    let dir = "/tmp/deepgit-verify3-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    writeFileAtomic(file, "# T\n\n用户内容\n<!-- deepgit:begin progress -->\nX\n<!-- deepgit:end progress -->\n")
    let (ok, undetermined, reason) = verifyPreservation(file, "${dir}/不存在的备份.md")
    @Assert(!ok)
    @Assert(undetermined)
    @Assert(reason.contains("无法判定"))
    // 当前文档读不到同样是「无法判定」，不是「一致」
    let (ok2, und2, _) = verifyPreservation("${dir}/也没有这个文档.md", file)
    @Assert(!ok2)
    @Assert(und2)
    removePathIfExists(dir)
}

@Test
func testVerifyPreservationIsUndeterminedWhenStructureMalformed(): Unit {
    // 破坏与校验共用同一套错误配对逻辑时，两边会剥掉同一段内容然后报「一致」。
    // 结构异常必须判为无法判定。
    let dir = "/tmp/deepgit-verify4-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    let backup = "${dir}/backup.md"
    writeFileAtomic(backup, "用户内容\n<!-- deepgit:begin progress -->\n旧\n")
    writeFileAtomic(file, "用户内容\n<!-- deepgit:begin progress -->\n新\n")
    let (ok, undetermined, reason) = verifyPreservation(file, backup)
    @Assert(!ok)
    @Assert(undetermined)
    @Assert(reason.contains("结构异常"))
    removePathIfExists(dir)
}

@Test
func testUsersOwnRegionBlockIsNotOverwritten(): Unit {
    // 用户自己手写一个同名托管块（很常见：抄了引擎的示例，或自己放迭代表格）。
    // 旧实现第一次 update 就把它整体替换成引擎的块，而 verify 报「逐字节一致」。
    let dir = "/tmp/deepgit-owned-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    let backupDir = "${dir}/backups/README.md"
    writeFileAtomic(
        file,
        "# t\n\n## 团队自己的进度表\n\n<!-- deepgit:begin progress -->\n| 迭代 |\n| S1 |\n<!-- deepgit:end progress -->\n\n## 联系我\n",
    )
    let regions = ArrayList<(String, String)>([("progress", "引擎内容")])

    // 引擎从未写过这份文档（备份目录不存在）→ 拒绝
    var threw = false
    try {
        _ = applyRegions(file, regions, backupDir, "")
    } catch (e: DgError) {
        threw = e.code == "DOC_REGION_NOT_OWNED"
    }
    @Assert(threw)
    let after = readFileTextOr(file, "")
    @Assert(after.contains("| S1 |"))     // 用户表格必须原样保留
    @Assert(!after.contains("引擎内容"))

    // 用户删掉该块后，引擎可以正常接管
    let clean = "# t\n\n## 联系我\n"
    writeFileAtomic(file, clean)
    let r = applyRegions(file, regions, backupDir, "")
    @Assert(r.changed)
    @Assert(readFileTextOr(file, "").contains("引擎内容"))
    @Assert(readFileTextOr(file, "").contains("联系我"))

    // 接管之后（备份目录已存在）再更新不得被误拦 —— 这是老用户升级后的日常路径
    let r2 = applyRegions(file, regions, backupDir, "")
    @Assert(!r2.changed || readFileTextOr(file, "").contains("引擎内容"))
    removePathIfExists(dir)
}

@Test
func testExistingEngineOwnedRegionStillUpdates(): Unit {
    // 已有安装的回归保护：引擎写过、有备份目录 → 块被认定为自己写的，正常更新。
    let dir = "/tmp/deepgit-owned2-${nowMillis()}"
    ensureDir(dir)
    let file = "${dir}/README.md"
    let backupDir = "${dir}/backups/README.md"
    writeFileAtomic(file, "# t\n\n<!-- deepgit:begin progress -->\n旧引擎内容\n<!-- deepgit:end progress -->\n")
    ensureDir(backupDir)   // 引擎以前写过
    let r = applyRegions(file, ArrayList<(String, String)>([("progress", "新引擎内容")]), backupDir, "")
    @Assert(r.changed)
    let after = readFileTextOr(file, "")
    @Assert(after.contains("新引擎内容"))
    @Assert(!after.contains("旧引擎内容"))
    removePathIfExists(dir)
}

/// 托管块内容不得携带伪造标记。
///
/// 引擎会把 commit subject、AI 摘要等完全不可信的文本写进用户 README。
/// 实测：一次 `git commit -m 'fix: <!-- deepgit:begin progress --> x'`
/// 就能让 README 里出现假的 begin 标记，此后每次 update/deep 都因
/// 「标记结构异常」被拒 —— 写入通道永久焊死，且因为内容每次都从
/// commit subject 重新生成而无法自愈。用户必须手工编辑 README 才能恢复。
/// 可远程触发：任何能给你推 commit 的人都可以。
///
/// 不是数据丢失（解析侧三重闸门挡得住破坏），是可用性永久损失。
@Test
func testRenderBlockNeutralizesInjectedMarkers(): Unit {
    let forged = "fix: x <!-- deepgit:begin progress --> y"
    let block = renderBlock("overview", forged)
    // 伪造的那个 progress 标记必须已被中和。
    // 注意不能断言 `!block.contains(beginMarkerPlaceholder)` —— 块首行就是引擎
    // 自己写的合法标记，prefix 必然命中。要断的是「伪造的那一个」。
    @Assert(!block.contains(beginMarkerPlaceholder + "progress -->"))
    @Assert(!block.contains(endMarkerPlaceholder + "progress -->"))
    // 中和的具体形态：`<!--` 与 `deepgit:` 之间插了 U+200B，
    // 所以 `deepgit:begin progress` 这个子串仍在（无害），但带前缀的标记形式已不成立。
    @Assert(block.contains("\u{200b}deepgit:begin progress"))
    // 引擎自己的标记必须完好
    @Assert(block.contains("<!-- deepgit:begin overview -->"))
    @Assert(block.contains("<!-- deepgit:end overview -->"))
    // 可读性不应被破坏：原文主体仍在
    @Assert(block.contains("fix: x"))
    @Assert(block.contains("y"))
}

/// 中和后的文本必须仍然能往返，且不可见字符不影响 Markdown 解析。
@Test
func testNeutralizeMarkersPreservesReadableText(): Unit {
    let s = neutralizeMarkers("a <!-- deepgit:end progress --> b")
    @Assert(!s.contains("<!-- deepgit:end progress -->"))
    @Assert(s.contains("a "))
    @Assert(s.contains(" b"))
    // 不含标记的文本原样返回（零开销、无副作用）
    @Assert(neutralizeMarkers("普通提交信息") == "普通提交信息")
    @Assert(neutralizeMarkers("") == "")
}

/// 端到端不变量：注入标记的 subject 不得让文档结构被破坏。
///
/// 这是真正的验收点：写入 → 再解析 → 结构仍然合法 → 再写仍然成功。
/// 旧的渲染路径在这里会产出第二个 begin 标记，第二次 applyRegions 必失败。
@Test
func testInjectedMarkerInSubjectDoesNotCorruptDocumentStructure(): Unit {
    let doc = "/tmp/deepgit-inject-${nowMillis()}.md"
    writeFileAtomic(doc, "# t\n\n用户正文\n")
    let backup = doc + ".bak"

    // 第 1 次：把带伪造标记的内容写进去
    _ = applyRegions(doc, ArrayList<(String, String)>([("progress", "fix: <!-- deepgit:begin progress --> payload")]), backup, "")
    let after = readFileTextOr(doc, "")
    @Assert(after.contains("用户正文"))
    @Assert(!after.contains(beginMarkerPlaceholder + "progress --> payload"))

    // 结构必须仍然合法 —— 这是旧实现失败的地方
    let (regions, problems) = parseRegions(after)
    @Assert(problems.isEmpty())
    @Assert(regions.size == 1)
    @Assert(regions[0].name == "progress")

    // 第 2 次：内容相同也必须成功，且不产生变化（旧实现在这里会抛 MALFORMED）
    let r2 = applyRegions(doc, ArrayList<(String, String)>([("progress", "fix: <!-- deepgit:begin progress --> payload")]), backup, "")
    @Assert(!r2.changed)
    @Assert(readFileTextOr(doc, "") == after)

    removePathIfExists(doc)
    removePathIfExists(backup)
}

@Test
func testUpsertRegionIgnoresTimestampOnlyChange(): Unit {
    // 守卫两侧原本不对称：磁盘上的 r.content 过了 trimSingleNewline，
    // 传进来的 content 是调用方原始渲染结果（renderProgressReadme 尾部带 \n\n），
    // 于是比较恒为 false —— stripUpdateStamp 在真实写路径里是死代码。
    // 后果：跨分钟重跑 update 必定重写 README，每次留备份、弄脏用户仓库。
    // 实测（4 分支仓库，跨分钟后重跑）：md5 变化，报「已更新 README.md」。
    let original = "# 我的项目\n\n手写内容\n"
    // 带时间戳、带尾部空行 —— 与 renderProgressReadme 的产出形态一致
    let c1 = "## 进度\n\n> 更新于 2026-10-01 04:01\n\n### main\n- 本次记录 1 个提交\n\n"
    let c2 = "## 进度\n\n> 更新于 2026-10-01 04:02\n\n### main\n- 本次记录 1 个提交\n\n"

    let afterFirst = upsertRegion(original, "progress", c1)
    let afterSecond = upsertRegion(afterFirst, "progress", c2)
    // 只差时间戳 => 必须原样返回，连时间戳都保留旧的
    @Assert(afterSecond == afterFirst)
    @Assert(afterSecond.contains("04:01"))
    @Assert(!afterSecond.contains("04:02"))

    // 反向：实质内容变了必须照写（否则就是误杀）
    let c3 = "## 进度\n\n> 更新于 2026-10-01 04:03\n\n### main\n- 本次记录 9 个提交\n\n"
    let afterReal = upsertRegion(afterFirst, "progress", c3)
    @Assert(afterReal != afterFirst)
    @Assert(afterReal.contains("9 个提交"))
    @Assert(afterReal.contains("手写内容"))   // 用户手写内容必须完好
}

@Test
func testPruneBackupsRefusesToDeleteOnNegativeKeep(): Unit {
    // 回归：keep 为负会让 pruneBackups 删光全部备份，且之后永远存不下。
    //
    // 实测（修复前）：config set update.backupKeep -1 被写入口拦住，
    // 但直接改 config.json 绕过去（负载校验只在一处）：
    //   backupKeep=20 跑 3 次 → 备份 3 份
    //   改成 -1 再跑 1 次    → 备份 0 份（三份被清空，零告警）
    //   再跑 1 次            → 备份 0 份（之后永久存不下）
    //
    // 文档备份是引擎重写用户 README/AGENTS 托管区时**唯一的回滚手段**。
    // 一个坏配置让这道防线自动失效、还顺手删掉已有快照，方向完全错了 ——
    // 判错方向必须是「多留一份」。
    let dir = "/tmp/deepgit-negkeep-${nowMillis()}"
    ensureDir(dir)
    for (n in ["b1", "b2", "b3"]) {
        writeFileAtomic("${dir}/${n}", "x")
    }
    @Assert(listDir(dir).size == 3)

    // keep = -1：一份都不能删
    pruneBackups(dir, -1)
    @Assert(listDir(dir).size == 3)
    // 更负也一样
    pruneBackups(dir, -100)
    @Assert(listDir(dir).size == 3)

    // ⚠️ #201：**这一段原来的断言与缺陷一模一样**，本会话显式推翻它。
    //
    // 原断言（修复前）：
    //     // 正常的 0 是合法语义（明确要求不保留任何备份），必须照做
    //     pruneBackups(dir, 0)
    //     @Assert(listDir(dir).size == 0)
    //
    // 它把 0 当成「用户明确要求不留备份」。但 keep=0 的实际行为不是「不留备份」，
    // 而是 **applyRegions 先建一份、pruneBackups 同一轮把它删掉** ——
    // 引擎做完了建备份的全套工作，然后亲手销毁它。
    // 端到端实测（backupKeep=0 跑一次 `moongit update proj`）：
    //     引擎输出「✓ 已更新 README.md」、exit 0，托管区写进了用户的 README，
    //     备份文件数 = 0。用户的原文永久丢失，而引擎全程报告成功。
    //
    // 而 keep=0 与 keep=-1 的**数学后果完全一样**：
    //     excess = names.size - keep，keep=0 → excess = names.size（全删）
    // 所以只拦负数的那道闸门从一开始就没关上 —— 它挡的是同一个后果的另一个入口。
    // 0 与负数的区别只有语义标签，没有行为区别。
    //
    // ⚠️ 为什么不改成「支持真的不留备份」：那要先决定「不建备份」的语义，
    //   属于新增特性（要在线程里给 applyRegions 加跳过分支），不该由一条
    //   断言顺手定下来。真要做，应该是一个**独立的显式开关**，
    //   而不是把 keep 这个「保留几份」的数字挪作他用。
    //   在那之前，把 0 归到非法一侧，方向是「多留一份」而不是「多删一份」。
    pruneBackups(dir, 0)
    @Assert(listDir(dir).size == 3)
    // 1 是下界，且必须真的开始剪
    pruneBackups(dir, 1)
    @Assert(listDir(dir).size == 1)

    // 正常的正数按原语义工作
    for (n in ["c1", "c2", "c3"]) {
        writeFileAtomic("${dir}/${n}", "x")
    }
    pruneBackups(dir, 2)
    @Assert(listDir(dir).size == 2)

    removePathIfExists(dir)
}

/// 判据的单一来源（#201）。阈值写两处必然漂移：
/// 写入口放行 0、运行时闸门却按别的阈值裁剪，症状就是「配置被接受了但行为不是那样」。
@Test
func testBackupKeepErrorIsTheSingleThreshold(): Unit {
    // 合法
    @Assert(backupKeepError(1).isEmpty())
    @Assert(backupKeepError(5).isEmpty())
    @Assert(backupKeepError(1000).isEmpty())
    // 非法：0 与负数同侧
    @Assert(!backupKeepError(0).isEmpty())
    @Assert(!backupKeepError(-1).isEmpty())
    @Assert(!backupKeepError(-100).isEmpty())
    // 报错必须教回怎么改（只说「非法」会让用户猜）
    let msg = backupKeepError(0)
    @Assert(msg.contains("至少为 1"))
    @Assert(msg.contains("0"))
    @Assert(msg.contains("回滚"))
    @Assert(MIN_BACKUP_KEEP == 1)
}

/// 运行时闸门与写入口必须用同一个阈值。写两处 `0` / `1` 就会漂。
@Test
func __lintBackupKeepThresholdHasOneSource(): Unit {
    // ⚠️ needle 拼接：源码里不能出现完整 needle，否则这个 lint 匹配到自己。
    let litA = "keep < " + "0"
    let litB = "n < 0" + ")"
    for (f in ["src/kernel/docs.cj", "src/cli/cli.cj"]) {
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
        // 本文件里不许出现写死的阈值
        if (code.contains(litA) && f.endsWith("docs.cj")) {
            @Assert(false)
        }
        if (code.contains(litB)) {
            @Assert(false)
        }
    }
}

@Test
func testRefusesToRewriteNonUtf8DocumentInsteadOfCorruptingIt(): Unit {
    // 非 UTF-8 文档被整篇重写 = 托管区**之外**的用户正文被改坏，
    // 而这正是「其余内容逐字节保留」这条核心承诺要保护的东西。
    //
    // 之所以格外恶劣：**破坏者与审计者共用同一个有损假设**。
    // 读入走 fromUtf8Lossy（非法字节 → U+FFFD），verify 读回也走 fromUtf8Lossy，
    // 两边把同样的 U+FFFD 当成原文，于是报「校验通过」。
    //
    // 实测（修复前）：GBK README 24 字节里 11 处字节被换成 U+FFFD，verify 报 OK；
    // UTF-16 README 40 字节膨胀到 550 字节，BOM 与中文全成 U+FFFD，verify 报 OK。
    let dir = "/tmp/deepgit-utf8-${nowMillis()}"
    ensureDir(dir)
    try {
        let gbk = dir + "/gbk.md"
        let raw: Array<UInt8> = [0x23u8, 0x20u8, 0xBAu8, 0xDAu8, 0x0Au8]   // GBK 的「# 啊」
        File.writeTo(Path(gbk), raw)
        let before = File.readFrom(Path(gbk))

        // 方向 1：必须**拒绝**，且错误要说清「为什么不改」和「怎么改」
        var msg = ""
        try {
            readDocForRewrite(gbk)
        } catch (e: DgError) {
            msg = e.message
        }
        @Assert(msg.contains("UTF-8"))
        @Assert(msg.contains("拒绝改写"))
        // 错误信息里不能出现一个跑不通的指令
        @Assert(msg.contains("iconv") || msg.contains("转存"))

        // 方向 2：文件必须逐字节未变
        @Assert(File.readFrom(Path(gbk)) == before)

        // 方向 3：合法 UTF-8 必须照常读入，不能被这条闸门误伤
        let ok = dir + "/ok.md"
        File.writeTo(Path(ok), "# 中文项目\n\n正文\n".toArray())
        @Assert(readDocForRewrite(ok) == "# 中文项目\n\n正文\n")

        // 方向 4：文件不存在时返回空串（按「新建文档」处理，不是错误）
        @Assert(readDocForRewrite(dir + "/nope.md").isEmpty())

        // 方向 5：applyRegions 必须把这条拒绝传出去，而不是自己吞掉后写空文档。
        // 吞掉的后果正是最初那个 bug —— 把用户的整份 README 换成只剩一个引擎块。
        let backup = dir + "/bk"
        var applyMsg = ""
        try {
            let regions = ArrayList<(String, String)>()
            regions.add(("progress", "引擎内容\n"))
            applyRegions(gbk, regions, backup, "# 模板\n")
        } catch (e: DgError) {
            applyMsg = e.message
        }
        @Assert(applyMsg.contains("UTF-8"))
        @Assert(File.readFrom(Path(gbk)) == before)
    } finally {
        removePathIfExists(dir)
    }
}

@Test
func testRegionOwnershipIsCheckedPerRegionNotPerFile(): Unit {
    // 归属判据必须**按区域**。旧判据是「备份目录存在 = 引擎拥有这份文档」，
    // 粒度与被保护对象（区域）不匹配，于是：
    //   引擎写过 progress → 整份 README 判为「引擎拥有」
    //   → 同名的 overview 区域即使引擎从未碰过也照写不误
    // 而「用户在自己项目的 README 里手写一个 <!-- deepgit:begin overview -->
    // 迭代表格」是完全正常的行为。实测该内容被整体替换，
    // verify 还报「逐字节一致」—— 因为用户的整块消失后两边自然一致。
    let dir = "/tmp/deepgit-own-${nowMillis()}"
    ensureDir(dir)
    try {
        let doc = dir + "/README.md"
        let bk = dir + "/bk"
        writeFileAtomic(doc, "# 项目\n\n用户正文\n")

        // 前提：文档里还没有任何托管块
        @Assert(parseRegions(readFileTextOr(doc, ""))[0].isEmpty())

        // 第 1 步：引擎接管 progress。文档此前没有同名块 → 允许
        let r1 = ArrayList<(String, String)>()
        r1.add(("progress", "引擎的进度块\n"))
        let a1 = applyRegions(doc, r1, bk, "# 模板\n")
        @Assert(a1.changed)
        @Assert(readOwnedRegions(bk).contains("progress"))

        // 第 2 步：用户自己加一个 overview 块（引擎从未写过）
        let userBlock = "\n<!-- deepgit:begin overview -->\n## 我自己维护的概览\n\nPRECIOUS-TABLE\n<!-- deepgit:end overview -->\n"
        writeFileAtomic(doc, readFileTextOr(doc, "") + userBlock)
        @Assert(readFileTextOr(doc, "").contains("PRECIOUS-TABLE"))

        // 第 3 步：deep 要写 overview —— **必须被拒**，且用户内容一字不动
        let r2 = ArrayList<(String, String)>()
        r2.add(("overview", "引擎的概览\n"))
        var msg = ""
        try {
            applyRegions(doc, r2, bk, "")
        } catch (e: DgError) {
            msg = e.message
        }
        @Assert(msg.contains("从未接管过"))
        @Assert(msg.contains("overview"))
        @Assert(readFileTextOr(doc, "").contains("PRECIOUS-TABLE"))

        // 第 4 步：负控 —— progress 归引擎所有，更新它**必须**照常成功。
        // 只钉第 3 步的话，实现里写死「一律拒绝」也能全绿。
        let r3 = ArrayList<(String, String)>()
        r3.add(("progress", "新的进度块\n"))
        let a3 = applyRegions(doc, r3, bk, "")
        @Assert(a3.changed)
        @Assert(readFileTextOr(doc, "").contains("新的进度块"))
        @Assert(readFileTextOr(doc, "").contains("PRECIOUS-TABLE"))

        // 第 5 步：归属凭据只增不减 —— 一次失败写入不该「忘掉」已有所有权
        @Assert(readOwnedRegions(bk).contains("progress"))
        @Assert(!readOwnedRegions(bk).contains("overview"))
    } finally {
        removePathIfExists(dir)
    }
}

@Test
func testRegionEndOffsetUsesMeasuredMarkerNotCanonicalLength(): Unit {
    // 区域右边界必须落在**实测**的 end 标记末尾。
    //
    // 原实现写的是 `idx + endMarker(name).size`，等于假设文档里的标记
    // 与规范形式逐字节相同。而名字是 trimAscii() 出来的、对空白不敏感，
    // 于是「用户把 end 标记的空格打多了」能顺利通过严格解析，
    // 却在算边界时算短 —— 实测每跑一次 update 就在用户的 agent 指令文件里
    // 多留一截垃圾：
    //   改写前 <!-- deepgit:end progress                -->
    //   改写后 <!-- deepgit:end progress -->            -->
    //
    // 反方向（标记比规范短）走不到这条路径：`<!-- deepgit:end progress-->`
    // 里根本没有 " -->" 这段串，indexOf 会报「缺少闭合的 " -->"」并拒绝改写。
    // 所以**只有长这一侧会漏**——测试也只针对长这一侧，两侧都测反而是虚的。
    let longEnd = "<!-- deepgit:end progress                -->"
    let doc = "# 标题\n\n<!-- deepgit:begin progress -->\n内容\n" + longEnd + "\n\n## 用户正文\n"
    let (regions, problems) = parseRegions(doc)
    @Assert(problems.isEmpty())
    @Assert(regions.size == 1)

    let r = regions[0]
    // 核心断言：切片必须与原文中那**一段**逐字节相同
    // （用推算长度时这里会多带出 15 个空格加 "-->"）
    @Assert(doc[r.start..r.end] == "<!-- deepgit:begin progress -->\n内容\n" + longEnd)
    // 标记之外紧跟的必须是换行，而不是残留
    @Assert(doc[r.end] == 0x0au8)
    // 用户正文必须原样落在区域之外
    @Assert(doc[r.end..].contains("## 用户正文"))
    // 内容不含标记本身
    @Assert(!r.content.contains("deepgit:begin"))
    @Assert(!r.content.contains("deepgit:end"))

    // 端到端：applyRegions 之后不得留残渣。
    // 顺序必须是「先建立归属 → 再手改标记 → 再重写」：
    // 归属闸门对没有 .owned 凭据的既有区块会直接拒绝（DOC_REGION_NOT_OWNED），
    // 那是对的，所以手改必须发生在归属建立**之后**。
    let dir = "/tmp/deepgit-endmark-${nowMillis()}"
    ensureDir(dir)
    try {
        let file = "${dir}/AGENTS.md"
        writeFileAtomic(file, "# 标题\n")
        let bk = "${dir}/bk"
        _ = applyRegions(file, ArrayList<(String, String)>([("progress", "> 更新于 2026-10-01 10:00\n\n旧内容\n")]), bk, "")
        // 现在归属已建立（.owned 写在 bk 下），可以放心手改标记
        let owned = readFileTextOr(file, "")
        @Assert(owned.contains("<!-- deepgit:end progress -->"))
        writeFileAtomic(file, owned.replace("<!-- deepgit:end progress -->", longEnd))

        _ = applyRegions(file, ArrayList<(String, String)>([("progress", "> 更新于 2026-10-01 11:00\n\n新内容\n")]), bk, "")
        let after = readFileTextOr(file, "")
        @Assert(after.contains("<!-- deepgit:end progress -->"))
        @Assert(!after.contains("--> -->"))
        @Assert(!after.contains("     -->"))
        @Assert(after.contains("新内容"))
        @Assert(after.contains("# 标题"))
    } finally {
        removePathIfExists(dir)
    }
}
