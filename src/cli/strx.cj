// String 扩展（本包内生效）。
// 已实测：本版本仓颉的 extend 对 std 类型（如 String）不跨包导出，
// 因此各包各自声明所需扩展；方法是纯函数式小工具，重复成本低。
package cambium.cli

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
func testCliStringExtension(): Unit {
    @Assert("  ".isBlank())
    @Assert(!"x".isBlank())
}
