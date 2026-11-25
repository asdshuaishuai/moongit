// graph/lambdaarrow_test.cj — `->` 只在 C / Rust 里是成员访问；Kotlin / Java 的 lambda 箭头不是接收者。
//
// 扫描器此前不分语言，把 `x -> real()` 里的箭头当成 C 的 `obj->m(`，给箭头后的调用安了一个
// 接收者（lambda 参数 x）。后果两处：箭头后的幻觉调用被当成「接收者调用」而不报 unresolved-call
// （阶段二 B 逐条核对 13 个「旧报新不报」的名字时暴露：withLink / withStyle 就是这么漏掉的）；
// 调用点的接收者归属也是错的。
package moongit.graph

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import moongit.util.*

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
