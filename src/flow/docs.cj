// 文档读取：把项目内 README / AGENTS / CLAUDE 的内容供给客户端平铺展示。
package cambium.flow

import std.collection.*
import cambium.kernel.*
import cambium.util.*
import std.unittest.*
import std.unittest.testmacro.*

public class DocFile {
    public let file: String
    public let content: String

    public init(file: String, content: String) {
        this.file = file
        this.content = content
    }

    public func toJson(): JsonValue {
        let o = Json.obj()
        Json.set(o, "file", Json.of(this.file))
        Json.set(o, "content", Json.of(this.content))
        return o
    }
}

let DOC_MAX_BYTES: Int64 = 200000

/// 一次文档读取的完整结果。
///
/// ⚠️ 为什么要多一栏 `unreadable`：以前 readProjectDocs 对「存在但读不出来」
/// 和「压根不存在」一律返回 None，两种都从结果里消失，调用方只看到空列表。
/// 于是 MCP `get_project_docs` 报「（该项目没有可读文档）」——
/// 而 README 明明就躺在项目根目录，只是权限被改、或者那个路径其实是个目录。
/// 模型收到这句会认定「这个项目没有文档」，可能转头去新建一份，
/// 而 `deep` 也会报「没有找到可更新的文档」。**把读不出来说成不存在**。
///
/// 签名里必须能表达「读过但失败」，否则下一个调用方还会踩同一个坑。
public class DocReadResult {
    public let docs: ArrayList<DocFile>
    /// 存在但读取失败的文档名（权限 / 不是普通文件 / 瞬时 I/O 错误）
    public let unreadable: ArrayList<String>

    public init(docs: ArrayList<DocFile>, unreadable: ArrayList<String>) {
        this.docs = docs
        this.unreadable = unreadable
    }

    public func isEmpty(): Bool {
        return this.docs.isEmpty() && this.unreadable.isEmpty()
    }

    /// 披露文本。空字符串表示没有需要披露的失败 ——
    /// 出口只在真的失败时才多这一行，不制造噪音。
    public func notice(): String {
        if (this.unreadable.isEmpty()) {
            return ""
        }
        return "⚠ 以下文档存在但读取失败，未包含在上面的内容里：${joinStrings(this.unreadable, "、")}（可能是权限被改，或该路径不是普通文件）"
    }
}

/// 读取项目内存在的研究文档（config.docs + agentDocCandidates 的交集按配置顺序），
/// 单文件截断到 200KB，避免巨型 README 拖垮 API。
///
/// 读失败**不静默丢弃**：进 unreadable 栏，由出口如实披露。
public func readProjectDocs(root: String, config: Config): DocReadResult {
    let out = ArrayList<DocFile>()
    let bad = ArrayList<String>()
    for (name in detectDocsPresent(root, config)) {
        // readFileTextChecked：文件不存在 → None（正常，该文档本来就没有）；
        // 存在但读不出来 → 抛异常。必须 catch 住并记账：
        //   · 不 catch 的话，组模式下 `docs` 只要有一个项目的 README 读不出来
        //     就整组抛掉，其他项目的文档一条都拿不到 —— 用「全组失败」换「单条失败」，
        //     方向反了。
        //   · 也不能用 readFileText（它把这两种都压成 None，于是谎报「没有文档」）。
        var text: Option<String> = None
        try {
            text = readFileTextChecked("${root}/${name}")
        } catch (e: Exception) {
            bad.add(name)
        }
        match (text) {
            case Some(t) =>
                let trimmed = if (t.size > DOC_MAX_BYTES) { safeSlice(t, DOC_MAX_BYTES) + "\n\n_（内容过长，已截断）_" } else { t }
                out.add(DocFile(name, trimmed))
            case None => ()
        }
    }
    return DocReadResult(out, bad)
}

// ------------------------------ 测试 ------------------------------

@Test
func testReadProjectDocs(): Unit {
    let base = "/tmp/deepgit-docs-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    writeFileAtomic(base + "/README.md", "# 标题\n\n正文内容\n")
    writeFileAtomic(base + "/AGENTS.md", "# AGENTS 指南\n")
    writeFileAtomic(base + "/CLAUDE.md", "# CLAUDE 指南\n")

    let docs = readProjectDocs(base, Config.defaults())
    // README 在配置首位
    @Assert(docs.docs.size >= 2)
    @Assert(docs.docs[0].file == "README.md")
    @Assert(docs.docs[0].content.contains("正文内容"))
    @Assert(docs.unreadable.isEmpty())
    @Assert(docs.notice() == "")
    var hasAgents = false
    for (d in docs.docs) {
        if (d.file == "AGENTS.md") {
            hasAgents = true
        }
    }
    @Assert(hasAgents)
    // toJson 一致性
    @Assert(Json.strAt(docs.docs[0].toJson(), "file", "") == "README.md")

    // 没有任何文档的仓库 → 空列表（这一档和「读不出来」必须能区分）
    let empty = "/tmp/deepgit-docs2-${nowMillis()}"
    ensureDir(empty)
    gitRun(empty, ["init", "-b", "main"], false)
    let none = readProjectDocs(empty, Config.defaults())
    @Assert(none.docs.size == 0)
    @Assert(none.unreadable.isEmpty())
    @Assert(none.isEmpty())
    removePathIfExists(base)
    removePathIfExists(empty)
}

@Test
func testUnreadableDocIsDisclosedNotReportedAsAbsent(): Unit {
    // 「存在但读不出来」被报成「不存在」—— 把读不出来说成不存在。
    //
    // 复现路径：README.md 确实在项目根目录（detectDocsPresent 用 fileExists，
    // 算它「存在」），但它其实是个**目录**，File.readFrom 直接失败。
    // 用目录而不是 chmod 000：目录读不了对 root 也成立，测试不依赖运行用户。
    //
    // 旧实现 readFileText 把「不存在」和「读不出来」都压成 None，
    // 于是三处出口全部谎报：
    //   · MCP get_project_docs → 「（该项目没有可读文档）」
    //   · CLI docs payload      → docs 数组少一条，没有任何标记
    //   · HTTP /api/docs        → 200 + 少一条的数组
    // 模型据此会认定「这个项目没有文档」，甚至转头去新建一份。
    let base = "/tmp/deepgit-docbad-${nowMillis()}"
    ensureDir(base)
    gitRun(base, ["init", "-b", "main"], false)
    // README.md 存在但是目录 → 存在性为真、读取必失败
    ensureDir(base + "/README.md")
    // AGENTS.md 是正常文件，用来证明「组内部分失败不能拖垮整组」
    writeFileAtomic(base + "/AGENTS.md", "# 好文档\n")

    let r = readProjectDocs(base, Config.defaults())

    // 前提：确实被判定为「存在」—— 否则下面断言的是「本来就不在」
    @Assert(detectDocsPresent(base, Config.defaults()).contains("README.md"))

    // 读不到的那份必须被点名
    @Assert(r.unreadable.contains("README.md"))
    // 好的那份必须照常交付（不能因为一份坏掉就整组抛异常或全丢）
    @Assert(r.docs.size == 1)
    @Assert(r.docs[0].file == "AGENTS.md")
    @Assert(r.docs[0].content.contains("好文档"))

    // 披露文本要说清「读不出来」而不是「没有」
    let n = r.notice()
    @Assert(n.contains("README.md"))
    @Assert(n.contains("读取失败"))
    @Assert(!n.contains("没有可读文档"))
    // 这一档不是「空」—— 判据必须是「docs 与 unreadable 都空」
    @Assert(!r.isEmpty())

    // 全都读不出来时，docs 空但 unreadable 非空，仍然不算「没有文档」
    let allBad = "/tmp/deepgit-docbad2-${nowMillis()}"
    ensureDir(allBad)
    gitRun(allBad, ["init", "-b", "main"], false)
    ensureDir(allBad + "/README.md")
    let r2 = readProjectDocs(allBad, Config.defaults())
    @Assert(r2.docs.isEmpty())
    @Assert(r2.unreadable.contains("README.md"))
    @Assert(!r2.isEmpty())
    @Assert(r2.notice().contains("读取失败"))

    removePathIfExists(base)
    removePathIfExists(allBad)
}
