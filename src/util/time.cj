// 时间工具：格式化、解析、相对时间、天数差。
//
// 设计取舍：ISO 字符串的时间显示采用「字符串切片」而非时区换算——git 提交时间
// 由提交者时区决定，忠实显示原始值比转成本地时间更有意义。
package cambium.util

import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

public func nowIso(): String {
    return DateTime.now().toString()
}

/// 解析 ISO-8601（宽松）：返回毫秒时间戳
public func parseIsoMillis(s: String): Option<Int64> {
    try {
        let dt = DateTime.parse(s)
        return Some(dt.toUnixTimeStamp().toMilliseconds())
    } catch (e: Exception) {
        return None
    }
}

/// 判断 [0, idx) 是否落在合法的 UTF-8 字符边界上。
/// 仓颉的 String 是字节序列，切片点必须正好是某个字符的起始字节，
/// 否则 `s[..n]` 抛 "Invalid utf8 byte sequence"。
/// ISO 时间串的固定位置（0/4/7/10/11/16）只有在前面全是 ASCII 时才成立；
/// 只要有一个多字节字符插进来，后面所有固定偏移都可能劈开字符。
func isUtf8Boundary(s: String, idx: Int64): Bool {
    if (idx <= 0 || idx >= s.size) {
        return idx == 0 || idx == s.size
    }
    let b = s.toArray()[idx]
    // 起始字节：0xxxxxxx(ASCII) 或 110xxxxx(2 字节) 或 1110xxxx(3 字节) 或 11110xxx(4 字节)
    return (b & 0xC0u8) != 0x80u8
}

/// 本地 "YYYY-MM-DD HH:mm"（基于 ISO 字符串切片，不做时区换算）
public func formatDateTime(iso: String): String {
    let s = iso.trimAscii()
    if (s.size < 16) {
        return "-"
    }
    // ⚠️ 边界检查必须排在**所有**切片之前，包括下面 s[4..5] / s[7..8] 这两次单字节切片。
    // 它们的切点同样可能落在续字节上：串 "2026-1中-01T..." 的第 7 字节是「中」的
    // 第二个续字节，s[7..8] 切出来的单字节不是合法 UTF-8，仓颉当场抛
    // "Invalid utf8 byte sequence" —— 连「返回 -」都走不到。
    //
    // 旧实现只查长度和第 4/7 位是不是 "-"，然后无条件切 [..10] 和 [11..16]，
    // 串里只要有一个多字节字符插在切点之前就崩掉整个命令。
    // 实测 journal.jsonl 里 at="2026-10-01T03:4中"（第 15 字节起是汉字），
    // `cambium journal` 报「内部错误：Invalid utf8 byte sequence」exit 1。
    // journal.jsonl 是面向用户的可读文件，还被 post-commit 钩子持续追加。
    for (k in [4, 5, 7, 8, 10, 11, 16]) {
        if (!isUtf8Boundary(s, k)) {
            return "-"
        }
    }
    if (s[4..5] != "-" || s[7..8] != "-") {
        return "-"
    }
    return s[..10] + " " + s[11..16]
}

public func formatDateOnly(iso: String): String {
    let s = iso.trimAscii()
    if (s.size < 10) {
        return "-"
    }
    // 同上：[..10] 也可能劈开字符
    if (!isUtf8Boundary(s, 10)) {
        return "-"
    }
    return s[..10]
}

/// 距今毫秒数（正数表示过去）
public func millisSince(iso: String): Int64 {
    match (parseIsoMillis(iso)) {
        case Some(ms) => return DateTime.now().toUnixTimeStamp().toMilliseconds() - ms
        case None => return Int64.Max
    }
}

public func daysSince(iso: String): Float64 {
    let ms = millisSince(iso)
    if (ms == Int64.Max) {
        return Float64.Inf
    }
    return Float64(ms) / 86400000.0
}

/// "3 分钟前" / "2 天前"
public func timeAgo(iso: String, lang: String): String {
    let zh = !isEnglish(lang)
    let ms = millisSince(iso)
    if (ms == Int64.Max) {
        return "-"
    }
    if (ms < 0) {
        // 时间戳在未来。一天内当作时钟轻微偏差（毫秒级、时区换算都可能造成），
        // 说「刚刚」无害；超过一天就必须承认时间不可信 ——
        // 旧实现一律说「刚刚」，于是 2030 年的提交显示「刚刚」并会持续 3 年多。
        let lateDays = -ms / 86400000
        if (lateDays >= 1) {
            return if (zh) { "⚠ 时间异常（晚于当前 ${lateDays} 天）" } else { "⚠ clock skew: ${lateDays}d in the future" }
        }
        return if (zh) { "刚刚" } else { "just now" }
    }
    let sec = ms / 1000
    if (sec < 60) {
        return if (zh) { "刚刚" } else { "just now" }
    }
    let min = sec / 60
    if (min < 60) {
        return if (zh) { "${min} 分钟前" } else { "${min}m ago" }
    }
    let hours = min / 60
    if (hours < 24) {
        return if (zh) { "${hours} 小时前" } else { "${hours}h ago" }
    }
    let days = hours / 24
    if (days < 30) {
        return if (zh) { "${days} 天前" } else { "${days}d ago" }
    }
    let months = days / 30
    if (months < 12) {
        return if (zh) { "${months} 个月前" } else { "${months}mo ago" }
    }
    return if (zh) { "${months / 12} 年前" } else { "${months / 12}y ago" }
}

/// 当前本地时间戳（毫秒）
public func nowMillis(): Int64 {
    return DateTime.now().toUnixTimeStamp().toMilliseconds()
}

/// 生成文件名安全的本地时间戳：2026-09-30T11-22-33
public func fileTimestamp(): String {
    let dt = DateTime.now()
    return "${pad4(dt.year)}-${pad2(monthToInt(dt.month))}-${pad2(dt.dayOfMonth)}T${pad2(dt.hour)}-${pad2(dt.minute)}-${pad2(dt.second)}"
}

func monthToInt(m: Month): Int64 {
    match (m) {
        case Month.January => return 1
        case Month.February => return 2
        case Month.March => return 3
        case Month.April => return 4
        case Month.May => return 5
        case Month.June => return 6
        case Month.July => return 7
        case Month.August => return 8
        case Month.September => return 9
        case Month.October => return 10
        case Month.November => return 11
        case Month.December => return 12
    }
}

public func pad2(v: Int64): String {
    if (v < 10) {
        return "0${v}"
    }
    return "${v}"
}

public func pad4(v: Int64): String {
    if (v < 10) {
        return "000${v}"
    } else if (v < 100) {
        return "00${v}"
    } else if (v < 1000) {
        return "0${v}"
    }
    return "${v}"
}

// ------------------------------ 测试 ------------------------------

@Test
func testTimeAgoBasic(): Unit {
    let now = nowIso()
    @Assert(timeAgo(now, "zh") == "刚刚")
    @Assert(timeAgo(now, "en") == "just now")
}

@Test
func testFormatDateTime(): Unit {
    @Assert(formatDateTime("2026-09-30T10:00:00+08:00") == "2026-09-30 10:00")
    @Assert(formatDateTime("bogus") == "-")
    @Assert(formatDateOnly("2026-09-30T10:00:00+08:00") == "2026-09-30")
}

@Test
func testDaysSince(): Unit {
    let d = daysSince(nowIso())
    @Assert(d > -0.5 && d < 0.5)
    @Assert(daysSince("bad") == Float64.Inf)
}

@Test
func testFileTimestampShape(): Unit {
    let ts = fileTimestamp()
    @Assert(ts.size == 19)
    @Assert(ts.contains("T"))
}

@Test
func testPadHelpers(): Unit {
    @Assert(pad2(3) == "03")
    @Assert(pad2(13) == "13")
    @Assert(pad4(7) == "0007")
    @Assert(pad4(2026) == "2026")
}

@Test
func testParseIsoMillis(): Unit {
    @Assert(parseIsoMillis("2026-09-30T10:00:00+08:00").isSome())
    @Assert(parseIsoMillis("not-a-date").isNone())
}

@Test
func testFormatDateTimeReadable(): Unit {
    let f = formatDateTime("2026-09-30T13:05:00Z")
    @Assert(!f.isEmpty())
    @Assert(!f.contains("T"))
}

@Test
func testFormatDateTimeDoesNotSplitUtf8Char(): Unit {
    // 旧实现只查长度和第 4/7 位是不是 "-"，然后无条件切 [..10] 和 [11..16]。
    // 串里只要有一个多字节字符插在切点之前，切点就劈进字符中间，
    // 仓颉抛 "Invalid utf8 byte sequence" —— 整个命令崩掉。
    // 实测 journal.jsonl 里 at="2026-10-01T03:4中"（第 15 字节起是汉字），
    // `cambium journal` 报「内部错误：Invalid utf8 byte sequence」exit 1。
    // journal.jsonl 是面向用户的可读文件，还被 post-commit 钩子持续追加。
    @Assert(formatDateTime("2026-10-01T03:4中") == "-")
    // formatDateOnly 只切 [..10]，这个串的前 10 字节本来就是纯 ASCII，切片合法 ——
    // 它不受影响才是对的（否则就是防护过头误伤了正常输出）
    @Assert(formatDateOnly("2026-10-01T03:4中") == "2026-10-01")
    // 多字节前缀后索引 10 仍落在 ASCII 上，切片合法，不该被误伤成 "-"
    @Assert(formatDateOnly("中2026-10-01T03:45:00+08:00") == "中2026-10")
    // 第 5 位就不是 "-" 的
    @Assert(formatDateTime("2026-1中-01T00:00:00+08:00") == "-")
    // 多字节字符在切点之前（占住 [..10] 区间）
    @Assert(formatDateTime("中2026-10-01T03:45:00+08:00") == "-")

    // 正常串必须照常格式化，不能被这个防护误伤
    @Assert(formatDateTime("2026-10-01T03:45:00+08:00") == "2026-10-01 03:45")
    @Assert(formatDateOnly("2026-10-01T03:45:00+08:00") == "2026-10-01")
    @Assert(formatDateTime("短") == "-")
    @Assert(formatDateTime("") == "-")
}

@Test
func testIsUtf8Boundary(): Unit {
    // 判据是「该字节是不是某个字符的起始字节」，即不是 10xxxxxx 续字节。
    // 纯 ASCII 每个位置都是边界。
    @Assert(isUtf8Boundary("abc", 0))
    @Assert(isUtf8Boundary("abc", 1))
    @Assert(isUtf8Boundary("abc", 2))
    @Assert(isUtf8Boundary("abc", 3))
    // "中" = E4 B8 AD：0 是起始，1/2 是续字节
    @Assert(isUtf8Boundary("中", 0))
    @Assert(!isUtf8Boundary("中", 1))
    @Assert(!isUtf8Boundary("中", 2))
    // "a中b" = 61 E4 B8 AD 62：边界在 0/1/4
    @Assert(isUtf8Boundary("a中b", 0))
    @Assert(isUtf8Boundary("a中b", 1))
    @Assert(!isUtf8Boundary("a中b", 2))
    @Assert(!isUtf8Boundary("a中b", 3))
    @Assert(isUtf8Boundary("a中b", 4))
}
