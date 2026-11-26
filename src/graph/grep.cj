// graph/grep.cj — `index grep`：工作区的定字符串内容搜索。
//
// 【不依赖索引】读的是**工作区当前文件**，与 codegraph.db 无关——没建过索引也能搜，
// 索引过期也不会搜到旧代码。扫描范围与索引器同源：同一个 walkSources（同一套
// 跳过目录规则、同一个文件数上限）、同一套语言识别（只搜索引会扫的那些源码
// 文件）、同一个单文件大小上限。所以 `filesScanned` 与 `index overview` 的
// files 对得上——两套遍历各说各话，agent 就没法在两个数字之间对账。
//
// 【定字符串，不是正则】仓颉标准库没有正则，仓库里也没有自己的正则工具——
// 不为一条命令引入一台正则机。模式按字面量逐字节匹配；`--ignore-case` 做
// ASCII 大小写折叠（标识符只有 ASCII 字母有大小写）。
package cambium.graph

import std.collection.*
import std.fs.*
import cambium.util.*

/// 一行命中（含上下文）。col 是匹配起点的 1 起字符列；text / before / after
/// 是原始行（长行截断，不切 UTF-8）。
public struct GrepHit {
    public let file: String
    public let line: Int64
    public let col: Int64
    public let text: String
    public let before: ArrayList<String>
    public let after: ArrayList<String>

    public init(file: String, line: Int64, col: Int64, text: String,
                before: ArrayList<String>, after: ArrayList<String>) {
        this.file = file
        this.line = line
        this.col = col
        this.text = text
        this.before = before
        this.after = after
    }
}

public struct GrepResult {
    public let hits: ArrayList<GrepHit>
    /// 命中数达到 --limit 之后**确实还有**没列出的命中（不是「正好等于上限」）
    public let truncated: Bool
    /// 实际读过并搜索过的文件数（提前停在 limit 时小于全部文件数——这个数如实说）
    public let filesScanned: Int64

    public init(hits: ArrayList<GrepHit>, truncated: Bool, filesScanned: Int64) {
        this.hits = hits
        this.truncated = truncated
        this.filesScanned = filesScanned
    }
}

/// grep 输出的默认上限与上下文行数上限。
public let GREP_DEFAULT_LIMIT: Int64 = 200
public let GREP_MAX_CONTEXT: Int64 = 20
let GREP_LINE_BYTES: Int64 = 500

/// 简单通配：`*` 匹配任意长度（含 `/`），`?` 匹配单个字符；其余按字面。
/// 迭代回溯（经典双指针），不递归、不分配。
public func globMatch(text: String, pattern: String): Bool {
    let tb = text.toArray()
    let pb = pattern.toArray()
    let tn = Int64(tb.size)
    let pn = Int64(pb.size)
    var t: Int64 = 0
    var p: Int64 = 0
    var star: Int64 = -1
    var mark: Int64 = 0
    while (t < tn) {
        if (p < pn && (pb[p] == 63 || pb[p] == tb[t])) {
            p += 1
            t += 1
        } else if (p < pn && pb[p] == 42) {
            star = p
            p += 1
            mark = t
        } else if (star >= 0) {
            p = star + 1
            mark += 1
            t = mark
        } else {
            return false
        }
    }
    while (p < pn && pb[p] == 42) { p += 1 }
    return p == pn
}

/// `--glob` 对相对路径的匹配：整条路径匹配，或者（glob 里没有 `/` 时）只看文件名。
func globMatchesPath(relPath: String, glob: String): Bool {
    if (globMatch(relPath, glob)) { return true }
    if (!glob.contains("/")) {
        let segs = relPath.split("/")
        return globMatch(segs[segs.size - 1], glob)
    }
    return false
}

/// 一行里模式的第一个出现位置（字节偏移）；没有 = -1。
func grepFind(line: String, needle: String, lowered: Bool, needleLower: String): Int64 {
    if (lowered) {
        return indexOfSub(line, needleLower)
    }
    return indexOfSub(line, needle)
}

/// 搜工作区。root 必须是已存在的目录。limit ≤ 0 用默认值；context 夹到 [0, GREP_MAX_CONTEXT]。
public func grepSources(root: String, pattern: String, ignoreCase: Bool, limit0: Int64,
                        context0: Int64, glob: String): GrepResult {
    let limit = if (limit0 <= 0) { GREP_DEFAULT_LIMIT } else { limit0 }
    let context = if (context0 < 0) { 0 } else { if (context0 > GREP_MAX_CONTEXT) { GREP_MAX_CONTEXT } else { context0 } }
    let files = ArrayList<(String, String)>()   // (绝对目录, 相对路径)
    let skipped = ReferVar(0)
    let unreadable = ArrayList<String>()
    let probeAcc = ProbeAcc()
    walkSources(root, "", files, skipped, unreadable, probeAcc)
    let hits = ArrayList<GrepHit>()
    var truncated = false
    var scanned: Int64 = 0
    var needleLower = ""
    if (ignoreCase) { needleLower = lowerAscii(pattern) }
    for ((absDir, rel) in files) {
        if (truncated) { break }   // 取满之后又撞见一处：已确认「还有更多」，停
        if (detectLang(rel).isEmpty()) { continue }
        if (!glob.isEmpty() && !globMatchesPath(rel, glob)) { continue }
        let content = readFileText("${absDir}/${lastSeg(rel)}")
        match (content) {
            case Some(text) =>
                if (Int64(text.size) > GRAPH_MAX_FILE_BYTES) { continue }
                scanned += 1
                let lines = text.split("\n")
                let n = Int64(lines.size)
                var i: Int64 = 0
                while (i < n) {
                    var rawLine = lines[i]
                    if (rawLine.endsWith("\r")) { rawLine = rawLine[0..rawLine.size - 1] }
                    let hay = if (ignoreCase) { lowerAscii(rawLine) } else { rawLine }
                    let at = grepFind(hay, pattern, ignoreCase, needleLower)
                    if (at >= 0) {
                        if (Int64(hits.size) >= limit) {
                            // 取满之后再撞见一处 = 确实还有没列出的（不是「正好等于上限」）
                            truncated = true
                            break
                        }
                        // 大小写折叠是 ASCII 一对一替换，不改变字节布局，偏移可直接用于原始行
                        let col = runeCountOf(rawLine[0..at]) + 1
                        let before = ArrayList<String>()
                        var b = i - context
                        while (b < i) {
                            if (b >= 0) { before.add(safeSlice(stripCr(lines[b]), GREP_LINE_BYTES)) }
                            b += 1
                        }
                        let after = ArrayList<String>()
                        var a = i + 1
                        while (a <= i + context && a < n) {
                            after.add(safeSlice(stripCr(lines[a]), GREP_LINE_BYTES))
                            a += 1
                        }
                        hits.add(GrepHit(rel, i + 1, col, safeSlice(rawLine, GREP_LINE_BYTES), before, after))
                    }
                    i += 1
                }
            case None => ()   // 读不出 ≠ 有害；跳过且不计数（与索引器同口径）
        }
    }
    return GrepResult(hits, truncated, scanned)
}

func stripCr(s: String): String {
    if (s.endsWith("\r")) { return s[0..s.size - 1] }
    return s
}
