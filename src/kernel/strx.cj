// String 扩展（kernel 包内）。仓颉的 extend 对第三方/std 类型的扩展
// 是否跨包可见存在限制，实测本包内声明即本包内生效。
package cambium.kernel

import std.unittest.*
import std.unittest.testmacro.*

extend String {
    /// 空白行判断：空串或仅含空白字符
    public func isBlank(): Bool {
        return this.trimAscii().isEmpty()
    }
}

// ------------------------------ 测试 ------------------------------


@Test
func testKernelStringExtension(): Unit {
    @Assert("".isBlank())
    @Assert(!"1".isBlank())
}
