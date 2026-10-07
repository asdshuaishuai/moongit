// lang.cj — CLI 外壳层文案的语言选择器。
//
// 【分层】数据层的语言（headline / narrative / 渲染文档）早就全程带
// config.language 参数（narrative.cj / render.cj / status.cj）；本文件补的是
// **外壳层**：帮助文本、用法报错、进度 Log。缺了它，`DEEPGIT_LANG=en` 时
// 数据是英文的、话术还是中文 —— 同一屏两种语言。
//
// 【取语言】复用 loadConfig()：config.json 的 language + DEEPGIT_LANG 覆盖 +
// 非法值回落，全在那一处。进程内只算一次：外壳文案一次运行要查几十次，
// 不值得每次都读文件。副作用只有一个 —— config.json 损坏时启动会往 stderr
// 打一行告警（本就如此，只是提前了）。
//
// 【为什么是 T(en, zh) 而不是 key 表】外壳文案是**一次性话术**（报错、提示、
// 进度），不是反复复用的 UI 词汇；169 个 key 的表需要全仓跳转对齐，
// 成本高于把两句话写在一起。同一句话出现在两处就该收敛成函数
// （本项目一贯纪律），而不是靠 key 表去重。
package moongit.cli

import moongit.kernel.*
import moongit.util.*

// top-level let：进程内缓存的语言判定。首次访问求值。
let CHROME_ENGLISH: Bool = isEnglish(loadConfig().language)

/// 外壳层文案选择器：`T("Unknown command: ${c}", "未知命令：${c}")`。
/// 英文在前 —— 外壳默认是中文（与 Config.language 默认值一致），
/// 调用点读起来「英文是翻译」的顺序更贴近事实。
public func T(en: String, zh: String): String {
    return if (CHROME_ENGLISH) { en } else { zh }
}
