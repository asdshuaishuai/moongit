// SHA-256（手写实现，零依赖）。用于项目 ID 与文档内容哈希。
package moongit.util

import std.collection.*
import std.overflow.*
import std.unittest.*
import std.unittest.testmacro.*

let SHA256_K: Array<UInt32> = [
    0x428a2f98u32, 0x71374491u32, 0xb5c0fbcfu32, 0xe9b5dba5u32,
    0x3956c25bu32, 0x59f111f1u32, 0x923f82a4u32, 0xab1c5ed5u32,
    0xd807aa98u32, 0x12835b01u32, 0x243185beu32, 0x550c7dc3u32,
    0x72be5d74u32, 0x80deb1feu32, 0x9bdc06a7u32, 0xc19bf174u32,
    0xe49b69c1u32, 0xefbe4786u32, 0x0fc19dc6u32, 0x240ca1ccu32,
    0x2de92c6fu32, 0x4a7484aau32, 0x5cb0a9dcu32, 0x76f988dau32,
    0x983e5152u32, 0xa831c66du32, 0xb00327c8u32, 0xbf597fc7u32,
    0xc6e00bf3u32, 0xd5a79147u32, 0x06ca6351u32, 0x14292967u32,
    0x27b70a85u32, 0x2e1b2138u32, 0x4d2c6dfcu32, 0x53380d13u32,
    0x650a7354u32, 0x766a0abbu32, 0x81c2c92eu32, 0x92722c85u32,
    0xa2bfe8a1u32, 0xa81a664bu32, 0xc24b8b70u32, 0xc76c51a3u32,
    0xd192e819u32, 0xd6990624u32, 0xf40e3585u32, 0x106aa070u32,
    0x19a4c116u32, 0x1e376c08u32, 0x2748774cu32, 0x34b0bcb5u32,
    0x391c0cb3u32, 0x4ed8aa4au32, 0x5b9cca4fu32, 0x682e6ff3u32,
    0x748f82eeu32, 0x78a5636fu32, 0x84c87814u32, 0x8cc70208u32,
    0x90befffau32, 0xa4506cebu32, 0xbef9a3f7u32, 0xc67178f2u32,
]

func rotr(x: UInt32, n: UInt32): UInt32 {
    return (x >> n) | (x << (32u32 - n))
}

public func sha256(data: Array<UInt8>): Array<UInt8> {
    var h: Array<UInt32> = [
        0x6a09e667u32, 0xbb67ae85u32, 0x3c6ef372u32, 0xa54ff53au32,
        0x510e527fu32, 0x9b05688cu32, 0x1f83d9abu32, 0x5be0cd19u32,
    ]

    let len = data.size
    let bitLen: UInt64 = UInt64(len) * 8u64

    // padding: 0x80, zeros, 8-byte big-endian length。
    // 总长一次算出、数组一次预分配（审查 L15：原实现把输入逐字节 add 进
    // ArrayList——完整复制一遍且每字节带扩容检查）。
    let paddedLen: Int64 = ((len + 9 + 63) / 64) * 64
    var padded: Array<UInt8> = Array<UInt8>(paddedLen, repeat: 0u8)
    for (i in 0..len) {
        padded[i] = data[i]
    }
    padded[len] = 0x80u8
    for (i in 0..8) {
        let shift = (7 - i) * 8
        padded[paddedLen - 8 + i] = UInt8((bitLen >> UInt64(shift)) & 0xffu64)
    }

    let total = paddedLen
    var block: Array<UInt8> = Array<UInt8>(64, repeat: 0u8)
    // w 在块循环**外**分配复用（审查 L15：原来每 64 字节块重新分配一次，
    // MB 级输入 ≈ 1.6 万次分配）
    var w: Array<UInt32> = Array<UInt32>(64, repeat: 0u32)
    var offset = 0
    while (offset < total) {
        for (i in 0..64) {
            block[i] = padded[offset + i]
        }
        offset += 64

        for (i in 0..16) {
            let b0 = UInt32(block[i * 4])
            let b1 = UInt32(block[i * 4 + 1])
            let b2 = UInt32(block[i * 4 + 2])
            let b3 = UInt32(block[i * 4 + 3])
            w[i] = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        for (i in 16..64) {
            let s0 = rotr(w[i - 15], 7u32) ^ rotr(w[i - 15], 18u32) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17u32) ^ rotr(w[i - 2], 19u32) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16].wrappingAdd(s0).wrappingAdd(w[i - 7]).wrappingAdd(s1)
        }

        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]

        for (i in 0..64) {
            let s1 = rotr(e, 6u32) ^ rotr(e, 11u32) ^ rotr(e, 25u32)
            let ch = (e & f) ^ ((!e) & g)
            let t1 = hh.wrappingAdd(s1).wrappingAdd(ch).wrappingAdd(SHA256_K[i]).wrappingAdd(w[i])
            let s0 = rotr(a, 2u32) ^ rotr(a, 13u32) ^ rotr(a, 22u32)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0.wrappingAdd(maj)
            hh = g
            g = f
            f = e
            e = d.wrappingAdd(t1)
            d = c
            c = b
            b = a
            a = t1.wrappingAdd(t2)
        }

        h[0] = h[0].wrappingAdd(a)
        h[1] = h[1].wrappingAdd(b)
        h[2] = h[2].wrappingAdd(c)
        h[3] = h[3].wrappingAdd(d)
        h[4] = h[4].wrappingAdd(e)
        h[5] = h[5].wrappingAdd(f)
        h[6] = h[6].wrappingAdd(g)
        h[7] = h[7].wrappingAdd(hh)
    }

    var out = ArrayList<UInt8>()
    for (i in 0..8) {
        let v = h[i]
        out.add(UInt8((v >> 24) & 0xffu32))
        out.add(UInt8((v >> 16) & 0xffu32))
        out.add(UInt8((v >> 8) & 0xffu32))
        out.add(UInt8(v & 0xffu32))
    }
    return out.toArray()
}

public func toHex(bytes: Array<UInt8>): String {
    let hexChars = "0123456789abcdef"
    var sb = StringBuilder()
    for (b in bytes) {
        let hi = Int64(b >> 4)
        let lo = Int64(b & 0x0fu8)
        sb.append(hexChars[hi..hi + 1])
        sb.append(hexChars[lo..lo + 1])
    }
    return sb.toString()
}

public func sha256Hex(data: Array<UInt8>): String {
    return toHex(sha256(data))
}

public func sha256HexOf(s: String): String {
    return sha256Hex(s.toArray())
}

public func sha1HexShort(s: String, len: Int64): String {
    // 仅用于生成稳定短 ID：用 SHA256 前 len 字节代替 SHA1（避免再实现一套）
    let full = sha256HexOf(s)
    return full[..len]
}

@Test
func testSha256Vectors(): Unit {
    @Assert(sha256HexOf("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    @Assert(sha256HexOf("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    var longSb = StringBuilder()
    for (_ in 0..1000) {
        longSb.append("a")
    }
    @Assert(sha256HexOf(longSb.toString()).size == 64)
    @Assert(sha256HexOf("中文") == sha256HexOf("中文"))
    // padding 边界（预分配改造的回归锚点，期望值由 python hashlib 实算）：
    // 55 字节 = 数据+0x80+8 字节长度恰好填满一块；56 字节必须溢出到两块
    var sb55 = StringBuilder()
    for (_ in 0..55) { sb55.append("a") }
    @Assert(sha256HexOf(sb55.toString()) == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
    var sb56 = StringBuilder()
    for (_ in 0..56) { sb56.append("a") }
    @Assert(sha256HexOf(sb56.toString()) == "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
}
