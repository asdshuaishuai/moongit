// 随机/稳定 ID 生成。
package cambium.util

import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

let idCounter: AtomicInt64 = AtomicInt64(0)

/// 时间戳 + 进程内自增序号的短 ID（同毫秒内也保证唯一）
public func randomId(prefix: String): String {
    let seq = idCounter.fetchAdd(1)
    return "${prefix}_${nowMillis()}_${seq}"
}

/// 稳定短 ID：SHA256 前 len 位
public func stableId(prefix: String, input: String, len: Int64): String {
    let hex = sha256HexOf(input)
    return "${prefix}_${hex[..len]}"
}

@Test
func testRandomIdShape(): Unit {
    let a = randomId("j")
    let b = randomId("j")
    @Assert(a.startsWith("j_"))
    @Assert(a != b)
}

@Test
func testStableIdDeterministic(): Unit {
    @Assert(stableId("p", "/x", 12) == stableId("p", "/x", 12))
    @Assert(stableId("p", "/x", 12) != stableId("p", "/y", 12))
}
