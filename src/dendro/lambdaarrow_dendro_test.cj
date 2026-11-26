// lambdaarrow_dendro_test.cj —— 从图谱包的 lambdaarrow_test.cj 搬来的用例：它们断言的是 Dendro（置信度）的契约，
// 而图谱包的测试不能再引入 Dendro（cjpm：循环依赖）。用例原文未改，只换了所在的包。
// 建图、扫描这类被测能力仍是图谱包的公开接口（import cambium.graph）。

package cambium.dendro

import cambium.util.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import cambium.graph.*


@Test
func testLambdaArrowIsNotAReceiver(): Unit {
    let root = testRoot()
    try {
        writeFileAtomic("${root}/a.kt", """
fun real(): Int { return 1 }

fun user(list: List<Int>): List<Int> {
    return list.map { x -> ghostArrow(x) + real() }
}
""")
        writeFileAtomic("${root}/B.java", """
public class B {
    public static int real() { return 1 }
    public static int user(java.util.List<Integer> list) {
        java.util.function.Function<Integer, Integer> f = x -> ghostJava(x) + real();
        return f.apply(1);
    }
}
""")
        // 正控：C++ 的 `t->real()` 仍然带接收者
        writeFileAtomic("${root}/c.cpp", """
struct T { int helm(); };

int f(T* t) { return t->helm(); }
""")
        let g = buildGraph(root)
        var kotlinSeen = 0
        for (s in g.callSites) {
            if (s.file == "a.kt" && (s.name == "real" || s.name == "ghostArrow")) {
                kotlinSeen += 1
                // 负控：修之前 receiver == 1、receiverText == "x"
                @Assert(s.receiver == 0)
                @Assert(s.receiverText.isEmpty())
            }
            if (s.file == "B.java" && (s.name == "real" || s.name == "ghostJava")) {
                @Assert(s.receiver == 0)
                @Assert(s.receiverText.isEmpty())
            }
        }
        @Assert(kotlinSeen == 2)
        // 正控：C++ 的 `t->helm()` 仍然带接收者 t（只数带接收者的那一处——声明行上的 `helm(` 是另一回事）
        var cppArrow = 0
        for (s in g.callSites) {
            if (s.file == "c.cpp" && s.name == "helm" && s.receiverText == "t") {
                cppArrow += 1
                @Assert(s.receiver == 1)
            }
        }
        @Assert(cppArrow == 1)
        // 箭头后的幻觉调用要能报出来（与 unresolved-call 的口径一致：自由调用、全仓无定义、非内建）
        let report = analyzeConfidence(g, false)
        var reported = HashSet<String>()
        for (f in report.findings) {
            match (f.kind) {
                case UnresolvedCall => reported.add(f.symbol)
                case _ => ()
            }
        }
        @Assert(reported.contains("ghostArrow"))
        @Assert(reported.contains("ghostJava"))
    } finally {
        removeTree(root)
    }
}
