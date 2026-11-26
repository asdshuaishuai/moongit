// builtins.cj —— 各语言内建名表：解析阶段（未解析调用的豁免集）与置信度（幻觉调用检测）共用的唯一一份。
//
// 放在图谱层而不是 Dendro：解析器（resolve.cj）与 Dendro 都要用它，而图谱层不认识 Dendro
// （分层：util ← graph ← dendro ← kernel / flow / cli，见 AGENTS.md）。
// 判据保守：宁可漏报（它本来就只是启发式信号），不可把合法调用报成幻觉。

package cambium.graph

import std.collection.*
import cambium.util.*



// MARK: - 内建名表（未解析调用的豁免集）

/// 各语言常见内建函数/类型/命名空间名的**并集**。
/// 判据保守：宁可漏报（它本来就只是启发式信号），不可把合法调用报成幻觉。
public func buildBuiltinNames(): HashSet<String> {
    let s = HashSet<String>()
    let words = [
        "print", "println", "printf", "puts", "echo", "log", "error", "warn",
        "info", "debug", "trace", "assert", "throw", "panic",
        "len", "cap", "make", "new", "append", "copy", "delete", "close",
        "recover", "Println", "Printf", "Sprintf",
        "range", "str", "int", "float", "list", "dict", "set", "tuple", "open",
        "type", "super", "isinstance", "enumerate", "zip", "map", "filter",
        "sorted", "sum", "min", "max", "abs", "round", "any", "all", "repr",
        "format", "ord", "chr", "hex", "bin", "bool", "bytes", "setattr",
        "getattr", "hasattr",
        "fatalError", "precondition", "String", "Int", "Double",
        "Bool", "Array", "Dictionary", "Set",
        "console", "fetch", "parseInt", "parseFloat", "Number", "Boolean",
        "Object", "JSON", "Math", "isFinite", "isNaN", "require", "Promise",
        "Symbol", "Error", "TypeError", "Date", "Map",
        "vec", "Some", "None", "Ok", "Err",
        "System", "out", "valueOf",
        // sizeof 是 C/C++ 的编译期运算符不是函数，但形态与调用一致
        //（`malloc(sizeof(int))` 曾被指控为幻觉 API —— G2）
        "sizeof",
        "malloc", "free", "memcpy", "strlen", "memset", "exit",
        "ArrayList", "HashMap", "HashSet", "StringBuilder", "Path", "FileInfo",
        "Directory", "Char", "UInt8", "Int64", "Float64", "Float32", "Rune",
        "Unit", "Comparable", "Runnable", "Iterator", "Optional",
        "describe", "it", "expect", "beforeEach", "afterEach", "main",
        // node/Browser API（AI 高频使用、非项目内定义）
        "hypot", "alloc", "writeUInt32BE", "readUInt32BE", "writeInt32BE",
        "concat", "Buffer", "from", "toString", "slice", "splice", "indexOf",
        "includes", "replace", "match", "test", "split", "trim", "padStart",
        "padEnd", "entries", "keys", "values", "forEach", "reduce", "push",
        "pop", "shift", "unshift", "find", "findIndex", "some", "every",
        "flat", "fill", "join", "reverse", "sort", "at", "includes",
        "keys", "assign", "freeze", "create", "defineProperty", "getPrototypeOf",
        "preventExtensions", "isFrozen", "seal",
        "writeFileSync", "readFileSync", "existsSync", "mkdirSync", "readdirSync",
        "statSync", "unlinkSync", "appendFileSync", "copyFileSync", "rmSync",
        "writeFile", "readFile", "mkdir", "readdir", "stat", "unlink",
        "resolve", "join", "dirname", "basename", "extname", "relative",
        "createServer", "listen", "request", "get", "post", "put", "delete",
        "setTimeout", "setInterval", "clearTimeout", "clearInterval",
        "queueMicrotask", "structuredClone", "fetch",
        // Swift 协议必需方法（框架回调，永不显式调用）
        "makeNSView", "updateNSView", "makeCoordinator", "effectValue",
        "body", "onAppear", "onDisappear", "task", "onChange", "deref",
        "hash", "isEqual", "compareTo", "description"
    ]
    for (w in words) {
        let t = w.trimAscii()
        if (!t.isEmpty()) { s.add(t) }
    }
    return s
}

public let BUILTIN_NAMES: HashSet<String> = buildBuiltinNames()

public func isBuiltinName(name: String): Bool {
    if (BUILTIN_NAMES.contains(name)) { return true }
    let lower = lowerAscii(name)
    return BUILTIN_NAMES.contains(lower)
}
