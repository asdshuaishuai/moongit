// version.cj — 引擎版本号的**单一真相源**（代码侧）。
//
// 【为什么单独立一个文件】版本串原来散在**三处**：
//   · cjpm.toml 的 `version` 字段
//   · CLI `version` 命令的输出（src/cli/cli.cj）
//   · MCP `initialize` 回包的 server.version（src/cli/mcp.cj）
// 改一处忘一处 ⇒ 用户看到的版本与实际能力对不上（客户端的引擎下载链就是按
// 版本/资产名对账的，版本漂了会让「装到的是不是同一个引擎」变得没法核）。
//
// 【为什么 cjpm.toml 那一处不能省】Cangjie 没有「编译期把常量注入构建清单」的机制
// ⇒ cjpm.toml 的 version 字段**没法**引用本常量。
// ⇒ 两处的「必须同值」由**测试**钉死（cli_test.cj 的 testEngineVersionIsSingleSourced）：
// 谁改了其中一处而忘了另一处，测试立刻红。
package moongit.util

/// 引擎版本号（语义化版本）。
///
/// ⚠ 与 cjpm.toml 的 `version` 字段**必须同值**（测试钉死）。
public const ENGINE_VERSION: String = "0.2.0"

/// 构建时使用的仓颉 SDK 版本（CLI `version` 输出里那一段）。
///
/// ⚠ 与 cjpm.toml 的 `cjc-version` 字段**必须同值**（测试钉死）。
public const CANGJIE_SDK_VERSION: String = "1.0.5"
