# AGENTS.md — moonGit 工作区指南

moonGit Engine：基于 git 历史的本地项目群进度引擎（跨平台核心，**AI 无关**）。**100% 仓颉实现，零第三方依赖**（JSON/SHA-256/Markdown 渲染全部自研）。
外部依赖只有系统 `git` 与 `curl`。本仓库是引擎；各平台 UI 层在 deepDolphin 仓库（macOS 客户端 deepDolphin.app 已实现：菜单栏常驻 + 主面板）。

> 🔴 **改名时的硬边界：改名字，不改身份。** 引擎已从 deepGit 更名为 **moonGit**，
> 但下列字面量**必须保持原样**，它们是既有数据与既有外部契约，不是显示名：
>
> | 保持不变 | 它是什么 |
> |---|---|
> | `~/.deepgit/`（`paths.cj` 的 `homeDir() + "/.deepgit"`） | 用户已积累的进度库与注册表。改名 = 引擎在空目录重来，旧数据变孤儿 |
> | `<!-- deepgit:begin ... -->`（`docs.cj`） | 已写进用户手写 README/AGENTS 的字面量。改了引擎认不出托管区，会**另开新区**而不是就地更新 |
> | `DEEPGIT_HOME` / `DEEPGIT_BIN` / `DEEPGIT_MANAGED_DOCS` / `DEEPGIT_SDKROOT` | 外部调用方（客户端、CI、别人的 shell profile）的既有接口 |
> | `deepgit://project/{id}`（`mcp.cj`） | 已发布的 MCP 资源 URI，是协议标识符不是名字。改了打断所有已配置好的 MCP 客户端，零功能收益 |
> | `deepgitHome()`（函数名） | 同上，纯内部标识；改名要动 5 个文件 12 处，而它是「解析 `~/.deepgit` 的那个函数」，名字与职责一致 |
>
> 反向的坑同样真实：`install.sh` 装 `moongit` 时**必须**留 `deepgit → moongit` 软链，
> `main.cj` 的 argv[0] 判定**必须**同时认新旧两个名字 ——
> 否则老脚本会拿到「未知命令」，且这类失败发生在用户机器上而不是 CI 上。
> 完整对照表见 [README.md](README.md) 的「命名」一节。

> **传输层哲学：只在本机进程之间通信，不跨网络。** 引擎对客户端只暴露两条通道——
> CLI（`moongit <命令> --json`，**以子进程方式调用**）与 MCP（`moongit mcp`，stdio JSON-RPC）。
> **没有 HTTP 服务，没有 `moongit serve`，没有 `/api/*`。**
>
> ⚠️ 早先这里写的是「只用**进程内**通信」，而同一句话下一行就写着「以子进程方式调用」——
> 两句自相矛盾，而且「进程内」这个词把**没实现**的 FFI（同一进程、同一地址空间）
> 和**已经在用**的子进程 + stdio 管道混为一谈。读者按字面理解会以为
> 客户端是链接进引擎的 dylib 调用的，而真相是它 spawn 了一个进程。
> 「进程内」现在只用于指 FFI 那条**已决定不做**的路（见不变量 58）。


## 构建与测试

```sh
# 环境（每次新 shell）
source ~/.local/share/cangjie/current/envsetup.sh
export SDKROOT="$HOME/.local/share/sdks/MacOSX.minimal/latest"  # macOS 26/27+ 必需，见下方说明

cd engine
cjpm build          # 构建 → target/release/bin/main
cjpm test           # 492 项测试 —— ⚠️ 必须带 DEEPGIT_HOME，见下方红线
cjpm build -i       # 增量构建（改单文件时更快）
```

### 🔴 红线：`cjpm test` 必须带 `DEEPGIT_HOME`

```sh
export DEEPGIT_HOME=/tmp/dg-test-$(date +%s)   # 没有这条，测试会写进用户真实数据
cjpm test --parallel 1
```

**为什么是红线**（缺陷 #181，已决定性复现）：不带 `DEEPGIT_HOME` 跑一次全量
`cjpm test --parallel 1`，用户 `~/.deepgit/store` 的 mtime 就会变
（`stat -f %m` 前后不同）。用假 `HOME=/tmp/dg-fakehome` 复跑，
`$FAKEHOME/.deepgit/store` 被建了出来 —— 坐实是测试写的。

机制：`deepgitHome()` 在 `DEEPGIT_HOME` 为空时回落到 `homeDir() + "/.deepgit"`，
而测试原本用 `setVariable("DEEPGIT_HOME", "")` 收尾「还原环境」——
**空串会被读成「用真实 home」**，比没设更糟。
任何自己没设隔离的测试，只要走到 `ensureStore`（它会 `ensureDir` 建目录），
就在真实数据目录里落东西。

已做的一半：76 处收尾改成 `exitTestHome()`，它回到**沙箱**而不是空串；
进入侧统一为 `enterTestHome(base)`。另一半是上面这条环境变量 ——
代码只能保护「记得用这对函数」的测试，环境变量才是兜底。
本次实测**没有改到用户任何文件内容**（store 下 26 个项目文件时间戳未变），
留下的是空目录，但「跑测试会碰真实数据」本身就是缺陷。

**运行二进制必须带运行时路径**（或直接用 `scripts/moongit.sh` 包装）：

```sh
sh scripts/moongit.sh status --json     # 推荐：自动处理工具链与 rpath
# 或
moonGit/target/release/bin/main status
```

- **macOS 26/27+ 关键坑**：系统 SDK 的 `libSystem.tbd` 只声明 `arm64e-macos`，
  仓颉自带的 `ld64.lld` 15.0.4 无法解析，链接会报
  `malformed file` / `unknown architecture` / 大量 undefined symbol。
  **解法**：极简兼容 SDK（~2MB，只含 libSystem/libc/libm/libdl/libpthread 的 arm64-macos TBD），
  `scripts/install.sh` 会自动下载 macOS 15.5 SDK 并裁剪到 `~/.local/share/sdks/MacOSX.minimal/latest`；
  也可 `sh scripts/build-minimal-sdk.sh <源SDK目录>` 手动生成，或 `export DEEPGIT_SDKROOT=` 指定现成 SDK。
  STS 1.2.0 / 1.3.0-alpha 的链接器同样是 15.0.4，升版本解决不了此问题。
- **deepDolphin（mac 客户端）注意**：双形态——MenuBarExtra `.window` 弹窗（bar，辅助）+
  NSWindow 主面板（PanelWindowController 承载 PanelView，可 `--open-panel --project X --section milestones`
  深链启动）。**它是纯客户端**：数据全部走 **CLI 子进程**（`EngineCLI.swift` 拉起 `moongit <命令> --json`，
  `AIClient.swift` 是其类型安全封装）——读 `status` / `dashboard` / `milestone list` / `journal` / `docs`，
  写 `update` / `deep` / `track` / `git <op>`。**不走 HTTP 网络**。
  契约模型集中在 `Models.swift`，键名与引擎 `flow/status.cj`、`flow/dashboard.cj`、
  `kernel/milestones.cj` 严格同名——引擎改键 = 破坏契约。CLI `status [项目] --json` 恒定 envelope
  `{projects, summary, language}`，单项目与多项目同形状，客户端只按这一种形状解码。
  MenuBarExtra 内容是**懒加载**的：启动期逻辑放 AppDelegate，别放 BarView 的 `.task`。
- ⚠️ **改任何 JSON 键名/增删字段后必须跑 `deepDolphin/macos/scripts/contract-check.sh`。**
  那类破坏**编译期发现不了、代码评审也看不出来**（引擎侧和客户端侧各自看着都合理），
  只在真解码时才炸。已实证的代价：P0-1 `status(name:)` 按裸 `ProjectStatus` 解码而引擎
  恒返回 envelope —— 100% 必现的 `Key 'id' not found`，详情面板每次打开都崩。
  该脚本拿**引擎真实输出**喂**客户端真实模型**（直接编译 `Models.swift` 本体，不复制副本），
  46 项断言覆盖：envelope 形状、披露字段是否齐全、-1 三态是否被渲染成 0、
  `unknown` 是否被断言成「进行中」、`journal` 顶层是否退回裸数组、
  全部项目失败时 stdout 是否仍带可解析 JSON（**且该场景必须真的是非 0 退出**，
  否则这条断言整个空转——加过一个常驻沙箱项目后 exit 悄悄变 0，已踩过）、
  MCP 三个出口的形状、以及**降级态键集 == 健康态键集**。
  已挂进 `deepDolphin/macos/build.sh` 末尾（`CONTRACT_STRICT=1` 可令其阻断）。
  它当场抓出过 4 个真不一致，其中 3 个在引擎侧：`dashboard` 的里程碑条目曾缺
  `tagName` / `createdAt` / `completedAt` / `id`，且 `tag` 键在两个出口里**同名不同义**
  （`milestone list` 里是用户绑定的 tag，`dashboard` 里是解析后的 tagName）。
  注意：脚本按 `../../moonGit/...` 定位仓内 release；用已安装的旧版会报出一堆假失败。
- ⚠️ **披露字段一律恒发，键集不得随数据变化。**
  写成 `if (!gitReadable) 才加 unverifiedReason` 时，键集就随数据漂了：
  实测健康态 17 键、降级态 CLI 18 键而 dashboard 17 键。后果是消费方只能靠
  「有没有这个键」反推出了故障（无文档的耦合），而把它建成可选时缺失拿到空串 ——
  空串恰好是「一切正常」的值，于是**故障被渲染成正常**。
  现在三个出口恒发 17 键，由 `contract-check.sh` 第 11 组与
  `testMilestoneJsonKeySetIsStableAcrossGitReadability` 钉死。
- ⚠️ **里程碑条目的形状只有一份：`kernel.milestoneJson`。**
  `milestone list --json` / `dashboard --json` / MCP `list_milestones` 三个出口都调它。
  曾经在 `flow/dashboard.cj` 手抄过第三份，于是连续栽了三次（缺 3 个键、
  `tag` 同名不同义、`unverifiedReason` 只在一边）。**别再在任何出口重写字段列表** ——
  靠注释写「这几个键必须一致」没用，注释不会跟着新键更新。
- ⚠️ **别把里程碑存储主键 `id` 加回只读出口。** 它是「只出不进」的：
  `milestone_action` 用的是 `project` + `name`，全引擎没有任何 API 收 `id` 作入参。
  发出来有两个害处：客户端的 `id` 是算出来的（`projectId/name`），与它永远不相等；
  LLM 在列表里看到 `id` 会自然拿它当句柄传回去，注定失败。
  存储侧的 `Milestone.toJson()` 仍保留 `id`（持久化主键，删了数据就丢关联）。
- ⚠️ **`milestoneProgress` 的 `repoPath=""` 判 `gitReadable=true` 是刻意的**
  （「没查」≠「查失败」，见该函数注释）。要造降级样本得用**存在但不是 git 仓库**的目录，
  而且**不能**是另一个 git 仓库的子目录 —— `rev-parse` 会向上找到父仓库。
  两条都踩过，症状都是「unverifiedReason 莫名其妙是空串」。
- ⚠️ **写源码级 lint（正则扫源文件）第一步就剥注释，否则一定出假红。**
  本项目已被这个咬过一次：修「刷新请求被静默丢弃」时，我在 `refreshAll` 上方写了
  「原来第一行是 `if isLoading { return }`」这句解释，lint 直接把**注释**
  当成了「缺陷代码还在」⇒ 4 条假红。修另外三处时同样：解释性注释里引用了被删掉的代码。
  假红比没检查更糟 —— 它会让人习惯性忽略这条检查。
  连带两条：lint 的**区间结束标记也必须用代码里的东西**，
  拿 `///` 文档注释当边界会在剥注释后永远找不到。
  现在 `Tests/ClientCheck/main.swift` 的 `code()` 负责剥 `//` 与 `/* */`，
  `codeOf(_:)` 是唯一该用的取源码入口。
- ⚠️ **检查程序遇到契约破坏必须「干净失败」，不能 crash。**
  `contract-check` 的每一组原来用顶层 `do { … }`，而组内第一句常是
  `let env = try expectDecode(...)`。引擎改一个键名时它就抛，错误一路逃到顶层
  ⇒ `Fatal error: Error raised at top level` ⇒ 进程 trap。
  crash 当然也让构建失败，但**其余全部诊断一起丢了** ——
  而「引擎动了 JSON 键」恰恰是最需要一次看到所有受影响检查的场景。
  实测：把 journal 披露退回条件性发，检查程序直接 trap，只看得到一句 `keyNotFound`，
  另外 30 多项一条都没报。现在每组用 `require("第 N 组的准备阶段", { … })` 包住，
  抛出的错变成一条失败记录，退出码仍是 1。
  **判别力也随之更好**：那次负控里只有真正依赖该键的第 1、7b 组变红，其余全绿。
- ⚠️ **负控必须能抓住真缺陷，抓不住就说明检查有洞 —— 别硬说它通过。**
  实例：把 `MarkdownView.parsed` 退回 computed property（每帧重解析）后，
  我新写的「记忆化生效」检查**照样全绿** —— 记忆化仍命中、耗时仍低、块数仍一样。
  因为「同一个视图被构造几次」是 SwiftUI 运行时行为，观察不到。
  于是补了一条**源码 lint**（`private let parsed` + 「body 里不调 blocks(」）才抓住。
  记这条不是为了 lint，是因为**当时我差一点就把「11/11 通过」当成验证过了**。
- ⚠️ **重构不许顺手改行为；但重构中撞见的缺陷要显式改 + 显式测 + 显式说。**
  抽 `MarkdownParser` 时发现标题文本带前导空格（`dropFirst(level)` 只去 `#`）。
  两条路：为了「保持行为一致」留着，或改掉并写测试说明。
  选后者 —— 但必须在报告里讲明「这一条超出了纯重构的范围」，不能混在搬文件里悄悄带过。
  同理，`testStatusJournalTruncationIsDisclosedNotSilent` 断言
  「不截断时**不该有** journalTruncated 键」，那正是我改掉的旧契约：
  改的是**契约**（披露键一律恒发），测试随之显式更新，不是「改绿了事」。
- ⚠️ **断言要查不变量，不要查某一种拼法。**
  实例：`client-check` 里「build.sh 不得吞掉 codesign 失败」第一版写成
  「找那一句固定的 `codesign … 2>/dev/null || true`」。负控植入同一缺陷的
  **另一种写法**（`if ! … 2>/dev/null`）时，26 项照样全绿 —— 一个检查只挡住一种错法，
  等于没挡。现在改成扫出所有 `--sign -` 的调用行，逐行断言没有 `2>/dev/null`、没有 `|| true`。
- ⚠️ **剥注释要按语言来。** `client-check` 里的 `code()` 剥 Swift 的 `//` 与 `/* */`；
  扫 `build.sh` 必须用另一个 `shellCode()` 剥 `#`。
  踩过一次：build.sh 的解释性注释里写着「原来是 `codesign … 2>/dev/null || true`」，
  被 Swift 版剥注释器原样留下，lint 把它当成缺陷代码 ⇒ 假红。
  与前面那条「lint 必须剥注释」是同一个坑的两次发作：**剥法与语言不匹配 = 没剥。**
- **运行期 rpath**：`cjpm.toml` 的 `link-option` 内嵌了运行时库路径与
  `-headerpad_max_install_names`（后者用于让 `build.sh` 能追加 `@executable_path/../Frameworks`）。
  修改 link-option 后要 `rm -rf target` 全量重建，否则链接器参数不会生效。
- **`--static-std` 不可用**：静态链接 std 后二进制在 macOS 上 dyld 加载失败。保持动态链接 + rpath。
- 新增子包（如 `src/xxx/`）后若链接报 undefined symbol，执行 `rm -rf target` 重建——
  cjpm 的包发现缓存需要全量刷新。
- ⚠️ **`cjpm test` 默认并行跑用例，测试之间会互相污染**：
  用例用 `setVariable("DEEPGIT_HOME", ...)` 隔离，而这个变量是**进程级全局**的，
  并行时后跑的用例会把它改掉，于是先跑的用例读到了别人的 store。
  已实测的偶发失败：`testSecondUpdateWithNoNewCommitsRewritesNothing`
  （红在 `AGENTS.md` 内容比对，表现为「第二次 update 本该 no-op 却重写了」）。
  证据链（不是猜的）：
  - 并行（默认）跑 3 次：绿、绿、**红 1 条**；
  - `--filter` 单跑 2 次：全绿；
  - `--parallel 1` 串行跑 2 次：全绿 403/403；
  - 用**构建出的二进制**在 15 个全新沙箱上复刻「恰好两次 update」：AGENTS.md 0/15 变化。
  最后一条是关键：生产代码在隔离进程里行为稳定，所以问题在测试隔离，不在 update 逻辑。
  **要可靠信号就跑 `cjpm test --parallel 1`**（代价是慢几倍）。
  真正的修法是给每个用例独立的 store 路径而不是全局环境变量 —— 涉及 403 个用例，
  属于架构改动，没有用户拍板前不要自己动。
- 部分用例建了 `/tmp/deepgit-*` 沙箱却没在 `finally` 里删干净
  （实测 `/tmp` 下已积 996 个，`deepgit-mcpallfail` 一个前缀就 132 个）。
  新写用例务必 `try/finally` + `removePathIfExists`。

## 架构边界（依赖方向严格单向，改前必看）

```
util → (kernel | graph) → ai → flow → cli
       (graph 只依赖 util：词法级代码图谱，不碰 git/进度库)
       (↑ ai 只依赖 kernel/util，绝不反向依赖 flow)
```

- **`ai` 不得引入 `flow`**：上层编排（浅/深更新）在 `flow/`，它依赖 `ai`。
  曾因把更新管线放进 `kernel/` 造成 `ai ↔ kernel` 循环依赖，被迫提升为独立 `flow` 包。
  **新增「调 AI 做编排」的代码一律进 `flow/`。**
- `util/` 是叶子，只依赖仓颉标准库。`kernel/` 依赖 `util`。`cli/` 在最上层。

## 编码约定（仓颉特有，踩过的坑）

- **多行字符串必须以换行开头**：`"""` 后紧跟内容会报 `must start with newline character`。
  拼接长文本用 `StringBuilder`，不要硬凑多行字面量。
- **没有 `?:` 三元运算符**，写 `if (cond) { a } else { b }`（是表达式，可直接用于 `const`/实参）。
- **`Option` 没有 `orDefault`**；用 `match` 或本项目在 `Json` 上提供的 `getOr(obj, key)`。
- **整数运算会溢出抛异常**：SHA-256 这类位运算必须用 `.wrappingAdd()`（`+%` 不是合法语法）。
- **字符串按字节索引**：`s[..n]` 可能切断 UTF-8 多字节序列并抛
  `Invalid utf8 byte sequence`。**任何外部来源的字符串截断都用 `safeSlice(s, n)` / `truncateChars`**
  （`util/text.cj`）。这个 bug 只在真实中文项目上暴露，测试数据不易发现。
- **读外部数据用 `fromUtf8Lossy(bytes)`**（`util/text.cj`），不要用 `String.fromUtf8` ——
  提交信息/文件可能是 GBK 等非 UTF-8 编码（deepOffice 的 git 历史就是）。
- **`for-each-ref` 的字段分隔用 `%1f`**（会被展开为 0x1f）；
  `git log` 的 `--format` 里则必须写 `%x1f`。两者行为不同，已验证。
- **`std.unittest` 不是自动导入**：新增含 `@Test` 的文件必须在 import 区加
  `import std.unittest.*` 与 `import std.unittest.testmacro.*`。
- **仓颉标准库里没有 SHA-256 类型**（`std.crypto.digest` 只给 `Digest` 接口和 `digest()` 函数），
  所以 `util/sha256.cj` 是自研实现。
- **进程与时间 API 在 `std.env`**：`getCommandLine()`、`getProcessId()`、`getWorkingDirectory()`、
  `getVariable(key)`（返回 `?String`）；进程 id 在 `std.posix.getpid()`。
- **`String` 方法名**：没有 `trim()`，用 `trimAscii()`；也没有 `trimLeft` / `trimRight`，需要时自己实现。
- **`extend` 对 std 类型不跨包可见**（1.0.5 实测）：`isBlank()` 等扩展在各包的 `strx.cj` 里
  各声明一份（util/text.cj、kernel/flow/cli/ai 的 strx.cj）。别指望在 util 里 extend、其他包直接用。
- **面板级 git 操作走 `runGitOp` 白名单**（kernel/git.cj）：pull（--ff-only）/ push（无 upstream 自动
  补 -u origin）/ commit（必须带 message，身份用 `gitUserName/gitUserEmail` 兜底）/ stash / unstash / fetch。
  **不要往里加 reset/clean/force-push**——这是给 GUI 客户端的按钮用的，误触即事故。
  CLI 入口 `moongit git <op> [项目] --json`；文档内容 `moongit docs [项目] --json`（单文件 200KB 截断）。
  注意：release 二进制改了命令行为后必须 `cjpm build` 重出 release，`cjpm test` 只构建测试目标——
  客户端内嵌的是 release 引擎，曾因此出现「测试全绿但内嵌引擎还是旧行为」。
- **`git worktree list` 不支持 `--format=`**，只有 `--porcelain`（records 以 `worktree ` 行开头）；
  `git stash list` 要用 `--pretty=format:`（`--format=` 会把 `%x1f` 原样输出，`%1f` 也一样）。
  porcelain/相对路径里的 `/tmp` 会被 git 输出成 `/private/tmp`——路径比较一律走 `util/paths.cj` 的
  `samePath()`（词法规范化 + macOS 符号链接容忍）。
- **MCP 服务器（cli/mcp.cj）**：`moongit mcp` 以 stdio 单行 JSON-RPC 运行（2024-11-05）。
  工具执行直连 flow/kernel 层（mcpCallTool），与 CLI 同源；**stdout 是协议通道，
  严禁 printOut 任何非协议内容**（日志恒走 stderr，MCP 模式还会 Log.setQuiet(true)）。
  新增 agent 能力 = mcpToolList 加清单 + mcpCallTool 加分支，并同步 `moongit tools --json`（agentToolsManifest）。
  Cangjie 注意：lambda 语法在此版本不可靠（`{ (a: T) => }` 报错），局部函数用 `func` 嵌套定义。
- **Skill（cli.cj skillMarkdown）**：`moongit skill print|install` 输出教学包；
  内容改动要同步 README 的 MCP 章节。
- **引擎保持 AI 无关（deepDesign 模式，改前必读）**：`src/ai` 包已删除——provider/prompts 不在引擎里，
  规则启发式在 `kernel/narrative.cj`。AI 的配置、调用、工具循环全部在客户端（AIProvider.swift / AgentView.swift）。
  引擎对 agent 只暴露两个喂养接口：`moongit context --json`（flow/agent.cj，预算内 markdown 事实包）与
  `moongit tools --json`（工具清单）。**往引擎里加 LLM 调用 = 违反架构**；要让 agent 能做新动作，加引擎工具 + 更新清单即可。
  注意 `cjpm test` 不重建 release——改了命令行为必须 `cjpm build` 后再装，否则客户端内嵌引擎还是旧行为。
- **CLI 位置参数解析统一走 `VALUE_FLAGS`**（`cli/cli.cj`）：新增「带值 flag」必须加进这个名单，
  否则它的值会被当成项目名（曾导致 `hook --source hook` 静默解析失败）。
- **`const` 不能用于数组字面量初始化**，用 `let`（如 `util/sha256.cj` 的 `SHA256_K`）。

## 关键不变量（做错很难回头）

1. **进度状态永不写进项目工作区。**
   状态在 `~/.deepgit/store/<projectId>/`（`state.json` / `progress.json` / `journal.jsonl`）。
   项目内只允许写：托管文档区域、可选的 post-commit 钩子。
   这条保证进度记录跨分支安全，且不污染 `git status`。

2. **文档只改托管区域。**
   `kernel/docs.cj` 的 `listRegions` / `upsertRegion` / `applyRegions` 是唯一写文档的入口。
   `upsertRegion` 里有「去时间戳后内容等价则不刷新」的逻辑，**不要删**——否则每次运行都会抖动文件。

3. **`git log` 解析依赖 `%x1f`/`%x1e` 分隔符**，字段顺序在 `kernel/git.cj` 的 `logCommits` 里，
   改格式必须同步改解析（`logRange`/`oldestCommits`/`authorStats` 都建立在此之上）。

4. **AI 失败必须降级而非中断**：`flow/update.cj` 与 `flow/deep.cj` 都用 `match` 而非 `try?`
   语义处理 `aiChatJson` 的失败，并在结果里回报 `aiError`。降级后仍要写进度库与日志。

5. **钩子必须后台异步且永不非零退出**：`post-commit` 与 `post-merge` 共用同一套托管块
   （`(moongit track --quiet --source hook >/dev/null 2>&1 &)`），可重复安装/卸载而不破坏用户已有钩子内容。

6. **状态聚合并发化的边界**：`flow/status.cj` 的 `allProjectStatuses` 用 `std.sync.spawn` 并发采集，
   前提是「只读 + 每项目独立 store」。往 `projectStatus` 里加**写操作**前必须三思；
   若出现并发问题，最小回退是改回串行 for 循环。

7. **分发件的 rpath 必须只有 bundle 相对路径。**
   cjpm 编出来的二进制带 `/Users/<你>/.local/share/cangjie/...` 绝对 rpath。
   只用 `install_name_tool -add_rpath` 追加的话，绝对路径会**排在前面**命中 ——
   于是「本机能跑」证明的是开发机装了 SDK，不是 app 自包含。
   改法是**重写**：先 `codesign --remove-signature`（install_name_tool 拒改已签名二进制），
   逐条 `-delete_rpath "<路径字符串>"` 删光（**收字符串不收序号**，传序号报错但退出码仍是 0），
   再按 `@executable_path/../Frameworks` 等相对顺序加回。见 `deepDolphin/macos/build.sh`。

8. **放进 `Contents/Resources/` 的可执行文件必须单独签名。**
   `codesign --force --deep --sign - <bundle>` 只把 `Contents/MacOS`、`Frameworks/`、
   `PlugIns/`、`XPCServices/` 当嵌套代码；Resources 下的东西在它眼里是**资源**。
   与第 7 条连起来就是一个静默故障：剥签名 → 改 rpath → bundle 签名跳过它 → 交付一份裸的。
   未签名的 arm64 二进制被 AMFI 直接 `SIGKILL`（exit 137、零输出），
   app 于是静默退回 `~/.local/bin` 或 `PATH` 上的引擎 —— 本机一切正常，
   而打出去的 app 里那份引擎**一次都没被执行过**。

9. **只读元数据的验证跨不过 AMFI / dyld / rpath。**
   引擎完全未签名时 `codesign --verify --deep --strict <bundle>` 依然返回 0 并报成功。
   「检查通过」与「那个二进制跑得起来」可以同时为假。
   唯一算数的是 `env -i` 空环境下真 fork 一次 —— 它同时证明 bundle 自包含
   （带走 CANGJIE_HOME/PATH，否则验的是「这台机器装了 SDK」）。

10. **AI 通道的「对话」必须真的带历史。**
    引擎是 AI 无关内核；客户端的 agent 循环在 `AgentCore.run`。
    原来它每次都 `var convo = [ChatMessage.user(question)]` 从零起步、用完即弃 ——
    所谓"对话"其实是一串互不相干的一次性提问，模型看不见上一轮。
    「那刚才那个项目后来怎么样了」会拿第一轮的上下文硬答，**而且答得还挺像回事**。
    多轮版把「拼对话」抽到 `Conversation.seed`（`deepDolphin/macos/Sources/deepDolphin/AgentConversation.swift`），
    这样"历史会不会被丢"才是**可断言的行为**而不是某一种拼法 ——
    内联在 run 里时，lint 只能查到一种写法，换个写法缺陷就溜过去（NC18 的教训）。
    历史发送前要过 `trimHistory`，否则聊几轮撞上下文上限，
    报出来的错和"你这条太长"长得一样。

11. **判定层文件必须零依赖。**
    `AgentOutcome` / `ClientDecisions` / `PathInput` / `Conversation` 都能被检查程序
    单独编译，正是因为它们不 import SwiftUI、不碰 Keychain、不碰网络。
    `ChatMessage` 原本埋在 `AISDK.swift`（带 Security 与网络通道），
    拆成独立文件后 `agent-check` 才编得动。
    反过来说：**判定一旦被内联回视图里，就又变成"编译过、评审看不出、只在运行时发作"**。

12. **取消 Swift Task 杀不掉引擎进程。**
    `EngineCLI.run` 是**同步阻塞**的（`Thread.sleep` 轮询），被 `runData` 包在
    `Task.detached` 里 —— 而**取消只对结构化并发传播**，detached task 不受
    调用方取消影响。所以：
    ```
    Task { await model.updateAll(...) }.cancel()   // 外层提前返回
                                                   // 引擎照样跑到超时（900s）
    ```
    「停止」的唯一有效动作是**真的 terminate 那个 Process**，
    这就是 `EngineCLI.ProcessRegistry` 存在的理由。
    两步缺一不可：先 `terminateRunning` 杀进程，再 `Task.cancel` 拦后续代码。
    只做后者是**假停止**（界面上有个能点的按钮，什么也没停掉）；
    只做前者则 `await` 之后还会继续 refreshAll 并弹「更新完成」。
    另外：「谁停的」由注册表记录（`userStopped`），**不从退出状态反推** ——
    超时分支的 `interrupt()` 同样让进程死于信号，两者猜错的代价是
    用户主动停了却弹一个「超时」。

13. **`EngineError.cancelled` 必须独立于 `timeout`。**
    被停掉是用户自己干的（不必惊慌、更不该报「更新失败」——
    那会让人以为跑了一半的更新坏了，白折腾一场）；
    超时是引擎卡住了，值得担心。混成一句就是误导。

14. **同一份形状约定只能有一个构造点。**
    `journalEntryJson`（`kernel/store.cj`）是 journal 条目在**所有出口**的唯一构造：
    `status --json` 内嵌的 journal 与 `journal --json` 的 entries 都走它。
    原来 `flow/status.cj` 里有一份手挑的 9 键投影，实测三套真相并存：
        存储 journal.jsonl        17 键
        journal --json 的 entries 17 键（存储原样）
        status 内嵌 journal        9 键（有损投影，还多造一个恒为 [] 的 docs）
    投影丢掉 `commitCountScope` / `highlights` / `nextSteps` / `notes` / `source` /
    `repoBranchCount` / `projectId` / `project` 与两个截断标志。
    后果不是"字段少几个"：消费方得写两套解码分支，
    而最容易漏的那一套会把「没数据」显示成「一切正常」。
    逐键拷贝（而不是手挑）是为了让**新增字段自动出现在所有出口**。
    契约检查第 7b 组会断言两个出口的键集与值**完全相等**，别让它红。

15. **恒空的假值比缺键更坏。**
    上面那个 `docs: []` 就是：引擎只让 `flow/deep.cj` 往 journal entry 写 `docs`，
    浅更新路径里 `docChanges` 是在 entry 定稿之后才建的。
    投影为了"形状统一"给不存在的键硬塞 `[]`，
    于是「压根没记录」被压成「这次没碰任何文档」——
    而缺键至少还能被 `Json.has` 检测到。
    对应的客户端模型必须是 `[String]?` 而不是 `[String]`。

16. **构建命令：`cjpm build`，不是 `cjpm build -o release`。**
    `-o` 是**产物名**不是模式 —— `cjpm build -o release` 会额外产出一个
    叫 `release` 的二进制，`target/release/bin/main` **原封不动**。
    于是负控会"测"一个旧构建并报绿：负控抓不住 = 没做过。
    验证构建是否真的更新了 `main`，看时间戳，别看命令的退出码。

17. **披露说了不算数，得有人显示它。**
    引擎对非 git 项目一直诚实地给出
    `warnings = ["非 git 仓库：进度基于文件活动时间，不含提交历史"]`，
    而 `commitCount` 是 `0`。实测结果是**用户看到「0 个提交」** ——
    因为客户端 `ProjectStatus` **压根没有 warnings 字段**，
    引擎说了等于没说，谎话由**模型层**说出口。
    这不是引擎的锅：披露已经在数据里，缺的是消费侧把它显示出来。
    现在 warnings 恒发 + 客户端模型有字段 + 详情页与看板卡片都渲染，
    `client-check` 第 7 组用源码守卫钉住渲染不许消失。
    教训：**「数据里有」不等于「用户看得到」**，
    断言也要分两层——模型能解出来是一层，真的被渲染是另一层
    （先植缺陷试过：只断言模型层的话，三套检查会全绿）。

18. **断言要分清「前提不成立」和「断言失败」。**
    写「遍历所有项目，遇到非 git 就断言 warnings 非空」时，
    沙箱里若恰好全是 git 项目，这条会一路空转着变绿。
    所以要么点名查那个样本（`plain`），要么先写一条「前提」检查。
    契约检查第 7b 组的「前提：沙箱里真的有 journal 条目」就是这么加的。

19. **错误信息必须能指导下一步，且绝不能泄出凭据。**
    客户端六个调用点全都用 `error.localizedDescription`，
    而 `AISDK.post` 原来把 `URLError` **裸传** ——
    于是在中文界面里用户看到的是：
        Could not connect to the server.
    英文、且不告诉他**哪一部分**错了。而这恰恰发生在「测试连接」按钮上：
    用户刚填完 baseURL 想知道对不对，这句话没用。
    修法是 `post()` 把错误包成 `AIChannelError`（自带「试过的地址」），
    `localizedDescription` 在**任何**出口自动变成可执行的中文。
    —— 包一层而不是让每个调用点多传参数：漏传一处，那个出口就退回英文。

20. **错误里出现的地址必须脱敏到只剩 host:port。**
    有些服务把 key 放在 URL 的 user 或 query 里，
    而错误文本会进错误横幅、日志与通知中心 —— 泄出去无法收回。
    `AIErrorMessage.hostOf` 解析不出 host 时返回 `nil`，
    **宁可少说也不能回显原文**。这条有断言守着（3 种含 key 的写法）。

21. **同一份「清单」不许抄两份。**
    引擎 `tools --json` 声明 10 个工具，客户端 `AgentCore.executeTool`
    是一份**手写 switch** 覆盖同样 10 个 —— 同一份清单的两处副本。
    漂移的表现很隐蔽：模型调了一个客户端不会执行的工具，
    界面上只显示一句「未知工具：X」，
    很容易被当成模型乱调，而真因是两份清单已经不一致。
    契约检查第 12 组断言「客户端能执行的工具集 == 引擎声明的工具集」。
    加引擎工具时必须同步客户端，否则那条会红。

22. **抓源码的断言必须配一条「前提」守卫。**
    上一条是**抓 Swift 源码**（`case "x":`）而不是跑代码，
    所以它只对某一种写法有效：改成 `if name == "x"` 就抓不到了。
    而抓不到 = 集合为空 = **断言静默空转着变绿** ——
    这是最坏的失败形态：检查看起来在跑，实际什么都没验。
    所以同组第一条断言是「两边都抓到了东西」，
    抓到 0 个就报错并说明"要么改写法了、要么抓取坏了"。
    实测把 switch 改成 if 之后，这条会立刻报警（负控 NC28b）。
    比集合不比顺序、不比条数 —— 调顺序、加空行都不该假红。

23. **macOS 的 `/bin/sh` 是 bash 3.2：`$VAR` 后面紧跟全角标点会把变量整个吃掉。**
    ```sh
    sh -c 'RC=137; echo "（exit=$RC）："'   # → （exit=<?>：   137 整个消失
    sh -c 'RC=137; echo "(exit=$RC):"'     # → (exit=137):   正常
    ```
    bash 3.2 把全角括号的高位字节当成了变量名的一部分，去找一个不存在的变量并**静默展开成空**。
    本项目 shell 输出全是中文，「变量紧跟全角括号/冒号」是常态。
    后果是**真实故障的诊断被吞**：退出码和路径从错误信息里消失，只剩两个乱码字节。
    一律写 `${VAR}`。`client-check` 第 4 组会扫全部 `.sh` 守住这条。

24. **给 agent / 模型看的输出里，不许携带已删传输层的任何地址。**
    `agentToolsManifest()`（`moongit tools --json`）原来给每个工具带
    `method` + `path`（`GET /api/context?scope=group`…），末尾 note 还写着
    「由上层 AI 通过 HTTP 调用执行」——**10 条 `/api/*` 全部指向已整体删除的服务端**，
    与本文件第 7 行的头号不变量直接冲突。清单是**要喂给模型**的，
    那两列字面上就是「去调这些地址」的指令。
    之所以一直没暴露：客户端 `engineToolDefinitions` 只读 name/description/params，
    把它们丢掉了 —— 那是调用方的将就，不是这里没坏。
    **教训：给模型的清单只声明「有什么能力、收什么参数」，不声明「怎么调用」。**
    也不许补一列手抄的 CLI 命令行（`git <sub> [项目]`、`milestone <sub> …`）：
    那是第二份「怎么到达能力 X」的人工副本，必然和真实语法漂移 —— 正是这个函数栽的跟头。
    路由是调用方的事，已有两处活的实现（客户端 switch、MCP 分支）。
    守门：`testAgentToolsManifestCarriesNoDeadEndpoint`（全文扫 `/api/`/`HTTP`/
    `http://`/`localhost`/`serve`）+ `testAgentToolsManifestDeclaresCapabilityNotTransport`
    （无 method/path 两列）+ 契约检查第 12 组后三条。

25. **禁令词断言会连自己写的免责声明一起抓。**
    修第 24 条时，我在 note 里写「……没有 HTTP 服务」来安抚读者，
    当场被自己那条「全文不含 HTTP」的红线抓住 —— 这正是它该干的活。
    正确做法是**根本不提那个词**，直接说清现在有什么（"传输层只有 CLI 子进程与 MCP(stdio)"）。
    推论：写下 `!text.contains("X")` 这类断言后，**必须把自己新写的文案也过一遍**，
    否则会在"文案比断言更完整"时假红，然后有人会去放宽断言 —— 那就等于把守门拆了。

26. **写在标题里的数量必须由列表派生。**
    `skill print`（agent 教学包）原来硬写「## 三种接入方式」，
    而 HTTP 删掉后正文只剩 MCP + CLI 两条 —— agent 读到的是一个永远差一条的承诺。
    现在标题是 `## ${ways.size} 种接入方式`，数字跟着列表走。
    守门：`testSkillMarkdownAccessMethodCountMatchesListedItems`
    抓标题数字与实际编号条目数是否相等，并要求 `listed > 0`
    （一条都没列出来时 `claimed == "0"` 也会通过，那是恒真）。
    ⚠️ 踩坑：`String.lastIndexOf(sub, from)` 是**全串找最后一次**，
    不是从 `from` 往回找 —— 按「从下标往回找标题起点」写会拿到后面的下标，
    区间切片直接 `IndexOutOfBounds`。按行切（`split("\n")`）取标题行更稳。

27. **已经产生副作用的动作，绝不许被报成「失败」。**
    agent 循环撞上工具调用轮次上限时，原来只看「这一轮有没有文本」，
    文本空就 `throw` —— 可工具**在判之前就跑完了**：
    `run_shallow_update` 改完了文档、`git_commit` 的提交已经进了仓库。
    抛错出去后界面显示「已达上限，未产出任何文本」，
    工具输出、过程事件、整段历史一并丢掉；
    用户看到的证据是「没成功」，据此重试就是**同一个 commit 提交两次、更新跑两遍**。
    这不是边角：模型只在返回 `tool_calls` 时 `text` 本来就是空的
    （OpenAI 兼容 `content=null`、Anthropic 无 text block），
    所以「最后一轮仍在调工具」是**正常路径**。
    更狠的是 `updateWithAISummary`：它先跑完更新、再调摘要，
    摘要那一环撞上限就把**整次更新**报成失败。
    收尾判定是 `AgentOutcome.finish(text:executedTools:maxRounds:)`：
    有文本 → 交文本（不变）；文本真空但**工具跑过** → 交「已执行完并且生效了：X，请不要重复执行」；
    两者皆空 → 才 `.failed`。
    守门：agent-check 第 1b 组 4 条行为断言 +
    1 条 lint「AgentCore 的收尾必须走 `AgentOutcome.finish`」
    （判定被内联回循环，上面四条就变成在测没人调用的代码）。

28. **抽成纯函数只是第一步，还得钉住调用点。**
    第 27 条的判定放进 `AgentOutcome` 之后，仍可能哪天被改回
    `guard let partial = AgentOutcome.atRoundLimit(...) else { throw }` ——
    纯函数测试照样全绿，因为**测的是那段没人调用的代码**。
    所以每抽一个判定，都要配一条 lint 断言调用方真的走它
    （同 client-check 的「UI 必须走 StopDecision」）。
    负控 NC30-b 验证过：把调用点内联回去，那条 lint 立刻红。

    ⚠️ **最强的形态是「同包端到端调真函数」，不是 lint**（负控 NC35-c 实测）：
    #184 的回归测试原本放在 `flow/dashboard.cj` 里，自己调
    `buildDashboard(reg.projects, …)` 再 `renderReportMarkdown(…)`。
    它只证明了「渲染函数给什么数就写什么数」，
    **根本没经过 `cmdReport` 里那个决定「传什么进去」的接缝**。
    于是把 `let dashProjects = …` 退回错误版本（整群报告传已滤掉 disabled 的
    `targets`），测试**全绿**，而真实 `moongit report` 的「已注册」当场从 2 掉回 1。
    补法：在调用方所在的包里直接调 `cmdReport` 端到端跑一遍，断言落盘文件的内容。
    —— 关键是**跨包的测试结构上就抓不到**：调用方在 `moongit.cli`，
    而测试在 `moongit.flow`，那个接缝压根不在测试的执行路径上。
    同理，「测试自己准备数据再喂给纯函数」永远只证明纯函数，
    证明不了**谁在喂它、喂的是什么**。

29. **「解析失败」绝不能退化成「参数为空」——空项目名等于整个项目群。**
    `AgentCore` 原来写的是
    `(try? JSONSerialization.jsonObject(…)) as? [String: Any] ?? [:]`。
    模型只要吐一次**畸形的 arguments JSON**，`params` 就成了 `[:]`，
    `name` 取到空串，客户端拼出**空位置参数** `["update", "", …]`；
    而引擎把空位置参数等同于「不传项目名」= **整个项目群**。
    实测（/tmp 沙箱，两个已注册项目）：`moongit update "" --json --quiet`
    把两个项目的 README **都改写了**，exit 0，界面上那次调用显示「✓ 执行成功」。
    读侧同样扩大作用域且不报错：`journal ""` 返回所有项目的日志，
    `context ""` 静默退化成整个项目群的上下文。
    现在拦在**执行之前**（`ToolArgs.decode` / `ToolArgs.missing`），
    拦下后**不执行**，只把原因回报给模型让它重试 ——
    报「执行失败」会诱使模型放弃或编造项目名，那比报错更糟。
    必填清单只有一个来源：**已经发给模型的那份 `required`**，
    执行端照模型看到过的契约执行，不另抄一份。
    ⚠️ 而且这个校验必须落在**执行点内部**（`executeTool`）而不是调用方 ——
    放调用方的话今天只有一个调用点所以看不出问题，
    将来多一个调用点就绕过去了，而绕过去的后果是批量写操作。
    畸形 JSON 的拦截则留在循环里，因为它发生在 `params` 存在之前。
    守门：agent-check 第 1c 组 6 条行为断言 + 1 条 lint
    （不得再用 `?? [:]`、且 `executeTool` 必须接 `parametersJSONByName`）。

30. **源码 lint 必须先剥注释，否则它会匹配到你自己写的说明。**
    修第 29 条时我在 `AgentCore.swift:211` 的注释里引用了旧的
    `as? [String: Any] ?? [:]`，结果「不得再用 `?? [:]`」那条 lint 立刻假红 ——
    它抓到的是注释，而那行代码早改掉了。
    `agent-check` 因此有了 `code()`（状态机剥 `//` 与 `/* */`，保留字符串字面量；
    不用正则，因为源码里有 `"https://…"`，正则分不清 `//` 是注释还是 URL）。
    并且 **`code()` 自己要有自测**（第 1a 组）：它一旦退化成恒等函数，
    所有源码 lint 一起失效，而且失效得**毫无声响**。
    ⚠️ 反过来也别夸大：我一度断言「1b 那条 lint 也会被注释骗绿」，
    负控 NC31-c 实测否证 —— `AgentCore` 的注释写的是「判定在 AgentOutcome」，
    并没有 `AgentOutcome.finish` 这个字面量。剥注释只挡**真的会被骗的那些**；
    给每条 lint 都套一层并宣称都防住了，是把猜测写成保证。

31. **状态不许拿文案字面量当标记 —— 谁执行、失败了没有，只有发起方知道。**
    `Conversation.transcript` 原来判断「这条 tool 消息要不要显示」用的是
    `m.text.contains("执行失败")`。修第 29 条时新增了一条「拒绝畸形参数」的路径，
    文案写的是「已拒绝执行」—— 四个字对不上，于是
    **工具根本没执行、界面上一个字都没有**，用户只看到模型说了句不痛不痒的话。
    这是**修 A 引入的 B**：A 本身是对的，但 A 让「失败」的表达方式多了一种，
    而 B 把它当成了唯一一种。
    现在 `ChatMessage` 带 `isError`（只给界面，不发给模型），
    失败状态由**发起方**打，`transcript` 只读标记；
    tool 消息统一走 `ChatMessage.tool(…)` 工厂，裸构造只此一处。
    守门：agent-check 第 1d 组 5 项（其中一条拿 5 种不同措辞验证「换说法也不漏显示」）
    + 1 条 lint（不得再出现 `contains("执行失败")`）。
    ⚠️ 连带效果：第 1 组那条**旧断言**当场变红 —— 因为它的测试夹具也是靠文案
    判定失败的，测试和实现在同一个字面量上耦合。改实现时它替你抓了一次。

32. **「核验不了」不许渲染成任何一种确定状态。**
    `report.cj` 的里程碑状态格原来是个内联 `match`，只有 `done`/`dropped` 两支，
    `_` 把 `open` 和 **`unknown`** 一起兜成「进行中」。
    实测把 `.git/objects` 移走：dashboard 说「? 无法核验（仓库读不出来）」，
    报告那一格却是「进行中」、备注空白 —— 报告恰恰是人最可能照着做事的文件。
    附带一条同类：备注栏在 `unknown` 时是空的，核验失败**原因**整个消失；
    只写「无法核验」等于告诉读者「有问题」却不告诉他「为什么」。
    修法：`milestoneCellStatus` / `milestoneCellNote` 抽成纯函数，
    `unknown` 恒渲染成「? 无法核验」+ 带 `unverifiedReason`。
    **「不知道」和「没有」是两个状态，渲染层不能把它们合并。**

33. **披露必须出现在每一个出口；恒发小节，不要「有内容才发」。**
    同一个 `report.cj`，`storeHealth` 早就接进了 status/summary/agent 三处，
    而 `milestones.counts` **一个出口都没接**。实测把 `milestones.json` 写坏：
    dashboard 大声披露「读到 0 条，上面的 0 不是『没有』」，
    而 `report` exit 0、报告里**一个「里程碑」字都没有**。
    根因是 `if (msItems.size > 0)` —— items 空有两种含义
    （真的没有 / 读不出来），而结构上无法区分。
    修法：小节**恒发**，用 `milestoneSectionHeader` 把
    「读不出来」「降级」「孤儿」「真的没有」四种情况说成四种不同的话。
    推论：新增字段时，别只想着「有值时写出来」，
    要问「**空的时候**调用方怎么知道这是空还是读不到」。

34. **持锁者还活着 = 绝不动它，锁龄一概不看。**
    `lock.cj` 的 `tryAcquire` 原来是：持锁者已死 → 立即接管；
    持锁者**还活着** → 却仍然去看锁龄，超了 `staleMs` 就 `removePathIfExists` 抢走。
    而 `holderAlive` 的文档写着「宁可等，也不要在活进程头上抢锁」——
    代码与它自己写下的约定相反。
    后果可复现：锁目录 mtime **只在加锁那一刻写、body 期间不刷新**，
    而 `update` 的 `staleMs=600000`（10 分钟）、`deep=900000`（15 分钟），
    于是**任何跑过 10 分钟的 update 都会在运行途中丢锁**，
    第二个进程得以同时进入临界区，并发改写同一份 `progress.json` /
    README 托管区，而两个进程都 exit 0。
    实测：持锁 pid 活着 + mtime 回拨 20 分钟 → 直接进临界区、exit 0、
    原 `holder.json` 被覆盖；mtime 新鲜 → 正确报 LOCKED、exit 1、锁完好。
    修法：判定抽成纯函数 `acquireDecision(holderAlive, ageMs, staleMs)`。
    ⚠️ 既有测试 `testLockIsNotStolenFromLiveHolder` 用 `staleMs=86400000`（一天），
    于是锁永远「新鲜」，**恰好绕开了「活 + 旧」这个组合** ——
    加新判定时必须补上被旧参数挡掉的那一格。
    推论：任何「超时/陈旧就抢占」的机制，都要问一句
    「这个超时量是**判据**还是**兜底**」——
    在这里它是兜底，而判据是「持锁者还活着吗」。

35. **「读不出来」必须与「没有」分开，而且不能算进「已访问」。**
    `listDir` 吞掉异常返回空数组，于是「无权限 / 被占用 / I/O 错误」
    与「这个目录本来就是空的」完全同构。
    实测把某个子树 `chmod 000`：`scan --json` 给出
    `found=1, dirsVisited=3, truncated=false`，**stderr 零告警**，
    文本只打印「✓ 发现 1 个项目」—— 这组数与「这棵树里确实只有 1 个项目」
    在响应里结构完全相同。更糟的是 `dirsVisited` 把那个根本没读到的目录
    也算作「已访问」，等于**主动声称覆盖了一个没读的地方**。
    修法：新增 `listDirChecked` 返回 `(子项, 是否读成功)`；
    `ScanResult.unreadable` 收集路径；`scan --json` **恒发** `unreadable`
    （空数组也是恒发，见第 33 条）；CLI 文本在**所有早退之前**打覆盖程度。
    覆盖程度是三态不是 Bool：`scanCoverage(truncated, unreadableCount)`。
    ⚠️ 仓颉 1.0.5 的 std **没有**权限 API（`core/file` 无 `setPermission`/`chmod`），
    测试里造「读不出来」的目录只能借 `execCapture` 调 `/bin/chmod`。

36. **「还原环境」绝不能等于「置空」—— 空串会被读成真实 home。**
    `deepgitHome()`：`DEEPGIT_HOME` 为空 → 回落到 `homeDir() + "/.deepgit"`。
    测试原本用 `setVariable("DEEPGIT_HOME", "")` 收尾「还原环境」，
    于是**主动把后续代码导向用户真实数据目录** —— 比「压根没设」更糟。
    实测：任何自己没设隔离的测试，只要走到 `ensureStore`（它 `ensureDir` 建目录），
    就在真实 `~/.deepgit/store` 里落东西（`stat -f %m` 前后不同，实验坐实）。
    现在统一用 `enterTestHome(base)` / `exitTestHome()`（共 76 处收尾已改）：
    退出时回到**沙箱**；进入前若本来没有环境变量，就落到 `/tmp/deepgit-testrun-*`，
    **永远不回到真实 home**。
    ⚠️ 但代码只保护「记得用这对函数」的测试，兜底仍然是
    **跑 `cjpm test` 必须带 `DEEPGIT_HOME=/tmp/…`**（见「构建与测试」的红线）。
    推论：凡是「结束时恢复状态」的代码，都要问一句
    「我恢复到的那个值，在下游会被怎么解释」——
    这里「空」不是「无」，而是「用默认」，而默认指向用户数据。

37. **沙箱的兄弟目录不会被 `removePathIfExists(base)` 带走。**
    `let testHome = base + "-home"` 与 `base` **平级**，不是它的子目录。
    只删 `base` 时 `testHome` 原封不动，于是每跑一轮测试就在 `/tmp` 多一个空壳，
    跑得越多攒得越多 —— 实测一轮全量 `cjpm test` 就能倒 286 个空目录，
    而且**测试全绿**，没有任何一条断言会发现它（残留不是被断言的对象）。
    正确写法：`ensureDir(x)` 的那个 `x`，必须在**同一个测试里**
    出现一次 `removePathIfExists(x)`。
    ⚠️ 隐式产生的中间父目录（`okA = base + "-ok/a"` 会顺手建出 `base + "-ok"`）
    静态看不见，只能靠约定：兄弟目录一律显式命名 + 显式清理。
    已由 `testEveryTestSandboxIsRemovedInTheSameTest` 把可静态判定的部分钉住
    （只认「`ensureDir` 建出来的、且自己就是 `/tmp` 一级目录」的路径；
    `base + "/alpha"`、`"${dir}/x.lock"` 这类在父目录里的不算）。
    同源问题：`removePathIfExists` 原本 `catch { () }` 把删除失败整个吞掉，
    删不掉也一声不响；现在至少 `Log.warn` 报出路径。

38. **「采集失败」与「上限截断」是两种不同的不完整，绝不许合并，更不许并成「没有」。**
    `listFiles` 失败时原本返回 `FileListing([], 0, false)`：
    没有错误标志，而 `truncated: false` 反而**声称没截断** ——
    失败的项目在语言分布里与「零个文件的项目」完全同形。
    实测：两个项目，坏的那个 `.git/index` 损坏，仪表盘写
    `语言分布：Python 1 · Rust 1`，读者会把这两个数字当成整个项目群的画像，
    而实际上其中一个项目**压根没被看过**。
    现在恒发 `languagesFailed` / `languagesFailedReasons`，并在三个出口都披露：
    JSON、文本（`dashboardLanguageNotes`）、报告（`renderReportMarkdown`）。
    ⚠️ **客户端也必须接**：`Dashboard` 原先根本没解 `languagesTruncated` ——
    引擎那层截断披露只对 `--json` 的消费方有效，界面上永远看不到。
    「引擎披露了」不等于「用户看得到」，中间还隔着一个模型。
    ⚠️ 小节不能写成 `if (langs.size > 0)`：全部采集失败时 `languages` 是空的，
    于是**整节连同失败披露一起消失**（不变量 33 的「不要有内容才发」）。
    空态文案也必须分两套：真的没有 → 「暂无数据」；没采到 → 「未采集到语言数据」。
    判定抽到客户端零依赖纯函数 `languageCoverage`，由 client-check 钉住。
    教训（负控实测两次）：源码 lint 断言**不能只 `contains` 字段名** ——
    文档注释里出现同一个词就假绿；`let languagesFailedReasons` 本身又是
    `let languagesFailed` 的前缀。必须匹配到**类型**。

39. **同名不同义的数字，必须让数字自己说口径；「缺键」不是「没截断」。**
    journal 的 `commitCount`：浅更新装「本轮真正新记录的提交数」
    （`commitCountScope:"new"`），深更新装「仓库提交总数」
    （`commitCountScope:"repoTotal"`，无上限、会一直涨）。
    引擎早就为此恒发了口径字段，注释写明「靠 mode 字段去猜口径不行：
    那是约定不是契约」；而客户端既不解也不显示，日志里一个「本轮新增 6」
    和一个「仓库一共 6 个」渲染成**两个一模一样的绿色 `+6`** ——
    读者会得出「深更新也新增了 6 个提交」。
    推论：**绿色只许留给真增量**。累计量用绿色等于说「这次变好了 N 个」。
    ⚠️ 深更新路径原先**只写** `commitCount` + `commitCountScope`，
    `commitCountTruncated` / `branchCountTruncated` / `repoBranchCount`
    三个一个都没有 —— 消费方只能把缺键当成「没截断」。
    而 `store.cj` 里那条**手搓的 deep 夹具**偏偏把三个字段都写全了，
    **夹具比现实更完整**，于是用夹具测形状永远测不出真实路径漏写。
    凡是「某条路径必须恒发某组字段」，测试必须走**那条路径本身**，
    绝不能拿手搓夹具代替 —— 夹具是你自己写的，你当然会写成你觉得的样子。
    可测的形式是查**键集**（`Json.has`），不是逐个查值。
    客户端侧判定抽到零依赖纯函数 `commitCountBadge`（四态：
    新增 / 累计 / 未知 / 读不出来），由 client-check 钉住。

40. **「读了 N 条」永远不等于「一共 N 条」—— 读取器必须能回答「窗口外还有没有」。**
    `readJournalWindow` 原来填满 `limit` 就停，返回值里**根本没有这个信息**，
    于是每一层想披露都披露不出来：
      · MCP `get_journal`：12 条记录 + 默认 limit=8 → 返回 8 行、**零披露**。
        模型据此认定「这个项目只更新过 8 次」，并可能据此判断项目不活跃。
      · `journal --json` 的 `branchWindowExhausted` 只装**分支级**耗尽，
        无过滤读取时恒为 `{}` —— `--limit 3` 配 12 条记录同样不披露。
        只给 `limit` 这一个数字无法自证：3-of-3 与 3-of-12 完全同形。
    ⚠️ 最严重的一处是 `readJournalForBranch` 在无分支过滤时把耗尽标志
    **硬编码成 `false`**。那是主动谎报，比缺字段更糟。
    教训：**「不知道」不许编码成「没有」**，哪怕只是返回值里的一个 Bool。
    探测只做 O(1) 字节检查（合法 JSONL 行以 `{` 开头）、找到第一个候选就停，
    不会把那条「倒序只解析最后 limit 条」的热路径优化退回去。
    披露给模型时必须是**人话且放在最后一行**（模型读结尾结论），
    并且**不得过度披露** —— 装得下时也要天天提醒，用户会学会无视它。
    `badLines` 的披露本来就在，说明作者知道该披露，只是漏了「窗口」这一个事实：
    同一段代码里两个同类事实，一个披露一个不披露，比两个都不披露更难查。

41. **截断后的残骸如果「结构完整、内容说谎」，比半句残文危险得多。**
    `context` 的预算截断有两处裸切片，各自都在撒谎（缺陷 #190）：
    项目小节按**字节**切，整篇按行切但**零披露**。
    实测（`context <名> --scope project --budget 500`，真实二进制）AI 收到：
        | 分支 | 状态 | 待记录 | 最近提交 |
        |---|---|---|---|
        |                                     ← 零行，而该项目实际有 7 个分支
        ### big · 进度日志（最近 1 条）         ← 声称 1 条，下面一条都没有
    全文没有任何提示说内容被砍过。group scope 有 `omittedNotice` 那套机制，
    **project scope 压根没有** —— 披露机制长在一条路径上，没长在另一条。
    现在统一走 `truncateContextForBudget`，它保证三件事：
      · 先给**披露行**预留字节，再按行边界回退正文
        （顺序反了就退化成「披露被自己挤掉」，那正是原来什么都不说的原因）
      · 丢失末尾**悬空的结构行**（`###` 标题、表格行）——
        行边界切**不够**，切点落在小节标题之后就会留下「声称 1 条、下面 0 条」
      · 预算比披露本身还小时**选超预算，不选闭嘴**。
        与 `assembleOmittedNotice` 同一个取舍：披露被静默丢弃 = 事实性谎言，
        超出软预算几十字节只是不整齐。
    附带一条测试纪律：**断言「必须披露」之前，先确认场景真的触发了截断**。
    我第一版测试只建 1 个分支，整篇 200 多字节压根不截断，
    「必须披露」就成了永远为真的空话（负控照样红，但红的原因不对）。
    ⚠️ 修的过程中我**自己引入过一个回归**，值得单列：
    剥离悬空结构行时，把 group 路径里唯一幸存的 `### p0` 也删了，
    于是每段只剩披露行 → **一个项目都不展示**。
    那正是 `testAgentContextDiscardsWholeSectionsAndDiscloses` 早就写着
    「不能一个都不给（诚实但没用）」要防的东西 ——
    全量跑才抓到，单跑新测试不会。
    规则：**剥离类改动，剥完若为空就保留原样**。
    治「结构完整、内容说谎」的残骸，不能制造「诚实但没用」的空白 ——
    后者在 LLM 场景里同样有害，甚至更糟，因为它连「这里本该有东西」都不说。
    推论：修 A 时改坏 B 是常态，**全量跑不是收尾，是发现问题的主要手段**。

42. **同一份数据交给模型只能有一种形状；「解析不出」不许兜成空串。**
    客户端的 `AgentCore` 有两条路取同一份 context：
      · 系统提示词那条路抽 `ctxObj["context"]` → markdown
      · 工具结果那条路（`get_group_context` / `get_project_context`）
        把整个 `{"scope":…,"budget":…,"context":"# moonGit…\n…"}` 塞进对话
    而引擎自己的 MCP 工具回的是**裸 markdown**。
    于是同名工具三种形状，模型读到的第一行是 `{"scope":`。
    现在两条路共用 `ContextEnvelope.decode`（零依赖纯函数，client-check 钉住）。
    ⚠️ 附带一条更硬的：系统提示词那条路原来是 `… as? String ?? ""`，
    解不出就得到**空串**，而空上下文会被模型读成「这个项目群什么都没有」。
    「没解出来」与「没有」必须分开 —— 畸形 JSON 仍然该 `try` 抛错
    （引擎二进制坏了就该硬失败），但「JSON 合法、context 键缺失」必须说明。
    ⚠️ **二次截断会把披露切掉**：引擎的截断披露写在**结尾**，
    客户端从头部按 16000 字符再切一刀，那行披露就没了 ——
    模型看到一段「看起来完整、其实缺尾巴」的上下文。
    客户端自己切的这刀必须**自报家门**（是谁切的、原文多长、怎么拿全量）。
    遗留（未修，已知）：`get_journal` / `get_project_docs` 客户端回 JSON、
    引擎 MCP 回排版后的文本 —— 跨运行时的形状差异，
    根子是 `tools --json` 清单只声明了**能力与参数**、没声明**结果形状**。
    ⚠️ 写 lint 断言时注意粒度：全局搜 `as? String ?? ""` 会误伤
    `params[key] as? String ?? ""`（合法的参数取值器）——正控就是这么红的。

43. **同一份能力清单有几份副本，就必须钉几对；单边改动要能立刻红。**
    工具清单实测有**两份**注册表，而且几乎完全不相交（缺陷 #192）：
      · CLI `tools --json` —— 10 个，客户端据此给模型建工具
      · MCP `tools/list`   —— 15 个，Claude Desktop 等 AI 看到的
    重叠只有 6 个。只在 CLI：`get_milestones` / `git_commit` /
    `git_pull_push` / `milestone_done`；只在 MCP：`list_projects` /
    `get_project_status` / `get_dashboard` / `git_op` / `run_track` /
    `list_milestones` / `milestone_add` / `milestone_action` / `add_project`。
    契约检查早就钉住了「CLI 清单 ⇄ 客户端 executeTool」这一对，
    **唯独漏了 MCP 那一侧** —— 所以漂移一直是静默的。
    现在把差集写成**已声明的基线**并钉住。注意基线的含义：
    两份注册表服务于不同运行时，能力集**本就可以**不同，
    要紧的是「不同」必须是**有意识的**。
    断言基线而不是「应该相同」—— 后者会逼着人造假等价。
    还钉了同一能力的两种改名对应（`get_milestones`/`list_milestones`、
    `milestone_done`/`milestone_action`）：
    「同一件事两个名字」是本引擎反复栽跟头的族，
    消费方无从知道它们是不是同一个，模型也会当成两个工具。
    推论：**清单有几份副本，就把副本之间的关系全部写成断言**。
    只钉住最显眼的那一对，剩下的漂移照样静悄悄。

44. **引擎已经说清的原因，不许在消费方降级成退出码；也不许有第二份失败判据。**
    缺陷 #193 的形状：`EngineCLI.run` 早就会在「非 0 退出 + stdout 是 JSON」时
    抛 `failedWithPayload` 把 stdout 原样带上，注释里原话就是
    「丢掉 payload 就只剩一句无信息量的『引擎退出码 1』」——
    而 `EngineError.jsonPayload` **全仓库零个消费方**。
    于是 7 个文件 25 行 `catch` 里的 `error.localizedDescription`
    拿到的全是那句空话。
    引擎侧实测会吐 **6 种**非 0 退出的形状，全部实测过：
      ① `{code,message,details?}` —— update/deep 单项目 `DOC_WRITE_FAILED`
      ② `{error:true,code,message}` —— milestone done/drop 的 `errJson`
      ③ `{results:[…],count,succeeded,failed}` —— update/deep 全项目，
         **成功项与失败项混在同一个数组里**
      ④ `{projects:[…],summary:{failedProjects:N}}` —— status，
         失败项目自带 `error`；**stderr 0 字节**
      ⑤ `{projects:{…,failed:N},…}` —— dashboard，**只有个数没有原因**
      ⑥ stdout 是**纯文本**（`git commit` 缺 `--message` 的
         「需要提交信息」），stderr 另有一句无信息量的汇总 ⇒ 整份丢弃
    三条硬规则：
      · **退出码不是原因**。载荷里能挖到原因就必须用挖到的；
        挖不到才退回退出码文案，且那一支要**承认自己没拿到原因**，
        不许把「0 个项目」当「一切正常」。
      · **消费方不许另发明失败判据**。判据必须与引擎的 `hasErrorOrCode`
        （`src/util/log.cj`：**有 `ok` 键 ⇒ 不是失败**）同规则，
        个数直接读引擎写的 `failed` 字段。
        写成 `ok == true 才算成功` 会数出比引擎更多的失败项 ——
        屏幕上「2 个项目失败」（客户端数）和 `failed: 1`（引擎数）并存，
        没人知道该信哪个。判据有两份就必然漂移（同 43）。
      · **判据要能在一行里用完**。缺陷的根因不是没人想到，
        是「正确写法要跨三个文件记住二十五次」，于是二十五次一个都没写。
        收口成一个 `EngineError.userMessage(for:)`，
        非引擎错误（AI/网络）照旧退回 `localizedDescription`。
    ⚠️ **写这类断言前先确认夹具能分开两种判据**（坑了两次）：
    `{ok:true,…}` 抓不住（它没有 `message`，按 message 过滤结果一样）；
    `{ok:false,message:…}` 也抓不住（它没有 `code`/`error` 键，
    两种规则都判它不是失败）。只有 **`{ok:…, code|error:…}` 两个键都带**
    的形状才能把两条规则分开。断言抓不住等于没做。
    ⚠️ 「某条命令必须恒发某组字段」的测试**必须走那条命令本身**：
    这里的 6 份载荷都是 `moongit <cmd> --json` 的真实 stdout 逐字抄的，
    手搓夹具比现实更完整就永远测不出漏读（同 #188 的教训）。

45. **配置键要么改变行为，要么不存在；「键不存在」必须报错，不许返回 null。**
    缺陷 #194 的形状分两半，都属于「说了不算」：
      · **死配置**：`config set server.port 8080` 打印「✓ 已设置」、写进
        config.json、能读回来 —— 而全仓库**没有任何一行读它**。
        命令确认了一件事，而那件事不会发生。四个字段这样死：
        `serverHost` / `serverPort`（HTTP 层残留，HTTP 已按「传输层只在本机
        进程之间通信、不要 HTTP」整体删除，零 socket 代码，可引擎仍然往
        **每个新建的 config.json** 里主动写一个 `server` 块）、
        `hookMode`（`cmdHook` 无条件装 hook，从不查它）、
        `aiJsonMode`（全 `src/` 零出现，连自己的 load/emit 都没接）。
      · **读侧判据不一致**：`config get <未知键>` 返回 `null` + **rc=0**，
        而同一批键在 `config set` 那边报「未知配置键」+ **rc=2**。
        同一批键、两套判据、两种结论 —— 脚本无法分辨「我拼错了键」和
        「这个键的值恰好是空」。`hooks.mode` 就是漂移的证据：引擎自己写进
        config.json、自己 `loadConfig` 会读，而读写两侧都不认它。
    三条硬规则：
      · **写 = 宣称**。引擎往 config.json 里写一个键，就是在宣称「设置它
        会改变什么」。宣称了却没人读，比不写更坏。
      · **有默认值 ≠ 有消费方**。`Config` 每个字段都带默认值、缺了回落，
        于是死字段既不报错也没人发现 —— 「它能正常工作」正是死字段的伪装。
      · **读与写必须是同一份键表**（`configKnownKeys()`），
        未知键两侧同判据同退出码。
    已删键的老 config.json 里的值**保留不删**（`OWNED_SUB_KEYS` 移出后
    `mergeEngineOwned` 不再碰它们）—— 不主动删用户文件，也不再宣称。
    ⚠️ 死键 lint（`testEveryConfigFieldHasAConsumerOutsideConfig`）踩了三个坑，
    都值得记下来，因为它们让 lint **假红或假绿**：
      · 剥注释必须**复用** `stripCjComment`（已提为 public）。自己写第二份：
        第一版漏了字符串字面量里的 `//`（路径字符串最常见），
        第二版忘了 `StringBuilder.append(UInt8)` 走 `Any` 重载会把字节
        拼成十进制数字串 —— 后者让 `contains("public class Config")` 恒为
        false，lint 报「6 个字段全是死的」，红得莫名其妙。
      · 逐字节取字段名要过 `fromUtf8Lossy`：`c.toString()` 在 UInt8 上给的是
        十进制数字，拼出 "108111101031…"，后面所有匹配恒为 false。
      · 剥注释的实现只有一份才谈得上可靠（同 43 的道理）。

46. **「没有证据」不等于「有反证」；判据的输入必须包含它要回答的那个问题。**
    缺陷 #195 全在 `moongit verify` 一个命令里，四个独立缺陷同源：
      · **假指控**：`applyRegions` 只在文件**已存在**时才留备份，所以
        **引擎自己新建的文档一份快照都没有**。而备份目录里除真备份外还住着
        两个元数据文件 `.docpath` / `.owned`，cmdVerify 把 `listDir` 的结果
        整个当成备份列表，「取最新」= 取字典序最大的文件名：
        真备份 `<时间戳>-README.md`（`2` = 0x32）vs `.owned`（`.` = 0x2E）
        ⇒ **有真备份时真备份赢（看着一切正常），没有时 `.owned` 赢**。
        于是拿 README 去和字符串 `"progress"`（`.owned` 的内容）比，必然不一致，
        报出「非托管区域与上次写入前不一致（你之后编辑过…）」+ 退出码 1。
        **用户一个字没改，文档是引擎建的，却被指控改过。**
        ⚠️ 别处早就知道这两个是元数据并在过滤（docs.cj 的 pruneBackups、
        归属检查都写了「点开头的元文件不算备份」）—— cmdVerify 是**唯一
        漏掉的第三份拷贝**。判据有两份就必然漂移（同 43）。
      · **布尔不看自己回答的那个问题**：`verifyOutcome(checked, undetermined,
        missing)` —— `failures` **根本没传进来**。于是
        `checked=1/failures=1/undetermined=0/missing=0` → `verified: true`，
        而同一份信封里 `failures: 1`、`documents[0].ok: false`、退出码 1。
        **三个信号两个说不通过、一个说通过。** 退出码当时是对的，所以
        **只有读 JSON 的消费方会被骗**（脚本 / 客户端 / MCP 一律只看那个布尔）。
      · **处置建议指错方向**：if 链里 `checked == 0 && missing == 0`
        排在 `undetermined > 0` 前面，于是「无法判定（引擎新建、没有快照）」
        拿到 note「暂无可校验的文档（**需要先执行 moongit update**）」——
        而用户**刚跑过 update**，再跑一次不会有任何变化。
        那句 note 存在的目的就是诱导 agent 重跑 update，所以指错方向
        **比不说更糟**：它会把一份好文档再覆盖一遍，却什么都没修好。
      · **同一个数字两处算法**：文本路径自己写了一遍
        `passed = checked - undeterminedCount`，与 JSON 路径的 verifyOutcome
        是两份实现，且同样不减 failures。已收口为共用 verifyOutcome。
    三条硬规则：
      · **「没有证据」是第三态**，不是「通过」也不是「被改动」。
        引擎新建的文档没有写入前快照，正确结论是「无法判定」。
      · **判据的输入必须包含它要回答的那个问题**：
        「这次校验通过了吗」的答案不能由一个没看过 failures 的函数给出。
        「大量通过 + 少量失败」也**不算通过** —— 否则「大部分通过」就成了
        漏看那一份的借口。
      · **if 链的顺序必须与状态对应**。写完逐个念一遍：每个状态走到哪个分支？
        念不通就是顺序错了。
    ⚠️ 复现必须走**真实写路径**（`applyRegions`），不能手搓备份目录：
    「新建 ⇒ 无快照」这个前提正是缺陷的来源，手搓目录复现不了它（同 #188）。
    ⚠️ 第二段写入必须让**区域内容真的变化** —— 内容不变时 `applyRegions`
    走 `if (!changed) return` 提前返回，压根不写备份，测到的会是另一条路径。
    ⚠️ 负控脚本只 grep「Assert Failed」会把**编译失败**误判成绿
    （仓颉报 `error:` 而不是断言失败）。负控必须同时判编译失败，
    否则「红」与「根本没跑」分不开 —— 这次就靠它发现了两个假绿。

47. **位置参数一个都不许静默丢弃：要么逐个处理，要么报错，绝不吞。**
    缺陷 #196：`cmdDocs` / `cmdRemove` 各写了一份
    `targets.add(requireProject(refs[0]))` —— **只取第一个**，
    其余项目名蒸发，退出码还是 **0**：
      · `moongit docs alpha beta --json` → rc=0，输出只有 alpha 的 envelope，
        beta 一个字都没出现，也没有任何「已忽略」提示
      · `moongit remove alpha beta` → rc=0，「✓ 已取消注册：alpha」，
        **beta 原封不动留在注册表里**（`list` 仍能看到）
    `remove` 那个尤其恶劣：取消注册是**破坏性操作**，
    「要注销两个、只注销一个、还告诉我成功了」比不响应更糟 ——
    用户据此认为 beta 也注销了，于是把它从自己的清单里划掉。
    ⚠️ 更刺眼的是**契约在、入口不在**：`docsPayload` 早就为多项目设计
    （有 `project` 键 = 单项目 envelope，键不在 = 多项目平铺），
    既有测试也直接拿两个 entry 喂它、还特意注明「不要顺手修掉」——
    但从 CLI 上用项目名**永远走不到**那条分支，只有「不传项目名」能走到。
    测试测的是纯函数，测不到「用户敲两个名字会发生什么」。
    两条硬规则：
      · **会接受多个项目的命令**（docs / remove / status / update / deep /
        journal / git）一律走 `namedTargets(refs)` 逐个解析，共用同一个接缝。
        各写一份 `refs[0]` 就是「多份实现必然漂移」（同 43）。
      · **元数固定的命令**（add / milestone）走 `rejectExtraPositionals`，
        多出来的位置参数**报错**而不是吞掉 ——
        吞掉它等于把用户的拼写错误变成一次「成功」。
        真实例子：`moongit add <路径> <名称>` 这种写法**一直**不生效
        （名字只认 `--name`），却打印「✓ 已注册」。
        本次审计里我自己就踩了两次 —— 写测试脚本时注册全被守卫挡掉才发现。
    ⚠️ 收口时顺带修掉的：`cmdRemove` 多项目 `--json` 若逐个 `printOut`，
    会吐出 N 份首尾相接的 JSON（`cmdGit`/`cmdTrack`/`cmdHook` 都栽过），
    现在走 `printMultiProjectJson`；单项目形状保持不变。
    ⚠️ 源码 lint 匹配前**必须剥注释** —— 这条守卫第一次跑就假红：
    `cmdDocs` 里我写的解释性注释「原来这里是
    `targets.add(requireProject(refs[0]))`」正好包含被禁的字符串。
    **解释缺陷的注释长得和缺陷一模一样**（同 45 的教训）。

48. **「没扫完」有几种成因就列几种；一个出口的披露不是另一个出口的披露。**
    缺陷 #197：`scan` 的「没看完」有**三种**成因，原来只表达两种：
      · `truncated`   —— 撞到 20000 目录上限
      · `unreadable`  —— 有目录读不出来（#179）
      · `depthCapped` —— 撞到 `--depth` 上限且下面还有没看过的子目录
    缺第三种的实测后果（仓库在第 4 层）：
        moongit scan <树> --depth 2
        → 「未发现项目（已访问 3 个目录）」exit 0
    仓库明明就在那儿。而同一个函数对「目录过多」早就有正确措辞
    （那句「扫描被截断…本次**未**覆盖全部范围」），只是**深度这条路没接上**。
    「上限当全量」这一族已经在 status(#115) / summary(#125) / dashboard 标题 /
    scan 目录上限 各修过一次，这里是第 5 次从 scan 自己的另一个出口钻出来。
    三条硬规则：
      · **列成因用枚举不用 if 链**。三种成因可以同时发生，逐个 if 迟早漏一种组合。
        现在 `scanCoverage` 往一个 list 里追加，组合天然覆盖。
      · **同一个问题只能问一次**。文本路径有「空结果早退」和「有结果收尾」
        两个出口，原来两条都只看 `truncated` —— 同一个问题问两遍，
        两遍都答错。现在共用 `scanIncomplete`。
        ⚠️ 只测 `scanRoots` / `scanCoverage` / JSON **抓不到**这条：
        负控把早退回退成只看 `truncated` 时那几个测试全绿，
        只有「两个出口都必须调 scanIncomplete」的结构守卫抓得住。
      · **判定本身要区分「到边界」和「被截断」**。撞到 `--depth` 上限时
        下面可能**根本没有子目录**（叶子），那就是真的看全了 ——
        一见边界就置位 = 谎报「没看完」。用 `hasUnexploredSubdir` 确认。
        ⚠️ 它必须用 `listDirChecked` 而不是 `listDir`：`listDir` 把读取异常
        吞成空数组 =「没有子目录」= 谎报成「看全了」（#179 在这条路上的复发）。
        读不出来时返回 **true** —— 宁可说「可能没看完」。
      · **无意义的参数直接报错**。`--depth 0` / `-1` 原来都被接受，
        扫一个目录就收工并报「未发现项目」exit 0 ——
        「一个子目录都不看」永远不是想找仓库的人会提的要求。
        与 `journal --limit 0/-1`、`update.backupKeep < 0` 同一处置。
    JSON 侧 `depthCapped` **恒发**（含 false）：「看全了」是一个有意义的事实，
    缺键会让人以为是旧版本没这个字段（同 #187 的口径）。

49. **空值/缺参数不许被静默解释成一个危险含义；要批量必须显式说出来。**
    缺陷 #198 是同一族的两处，都属于「空 ≠ 无害」：
      · **`addProject` 收下了空名项目**。`name` 为空时用 `basename(root)` 兜底，
        而 `basename("/")` 是空串，于是
            moongit add /                 →  ✓ 已注册：（dir）→ /
            MCP add_project {"path": ""}  →  已注册：（/）
        写进注册表一条 `name=""`、`path="/"` 的条目。后果不是「多一行」：
          ① 那条项目**永远引用不到** —— `findProjectIn` 对空 ref 返回 None，
             连 `remove` 都删不掉它（用户连补救手段都没有）；
          ② 它**永久污染每一次聚合命令**：实测之后
             `moongit status --json` → `summary.failedProjects = 1`，
             而那条项目的 error 是「Native function error.」——
             用户看不懂、也查不出是哪来的。
      · **MCP `run_shallow_update` 把缺 name 当成「更新全部项目」**。它是 15 个
        MCP 工具里**唯一**一个「参数缺失 = 批量写」的；同族全部工具
        （`run_deep_update` / `run_track` / `get_*`）缺 name 都老老实实报
        「未找到项目：」，因为它们走 `mcpRequireProject`。
        这是**写**操作：漏一个参数 = 改写注册表里每一个项目的文档托管区域。
        读操作漏参数只是少给点信息，**写操作漏参数是改数据**。
    三条硬规则：
      · **空值不许当哨兵**。要批量必须**显式**写出来。
        现在用 `name = "*"`：能力没删（删了会把多项目批处理那条路径变成死代码，
        连带一个已修 bug 的测试失去意义），但「漏参数」与「我要全部」被分开了。
      · **读侧守则与写侧守则不同，要按操作性质分别判**。
        同一个「参数缺失」，读操作里是「少给点信息」，写操作里是「改全部数据」。
      · **必填清单只有一个来源**（同 43 / 45 的口径）。缺陷 #31 早认定
        「空项目名 = 改写所有项目的 README」是危险，并给**客户端**加了必填守卫；
        但引擎自己的 MCP 工具表**没跟上** ——
        客户端从 CLI `tools --json` 的 `params: "name"` 推出 required，
        引擎 MCP 那份 `required` 是手写的、且是空的。
        **两份注册表要一起改**。
      · **schema 与处理器都要有**：schema 是给模型看的提示，处理器才是闸门。
        只改 schema 的话，模型仍然可能传 `""`，而 `""` 绕得过 `isEmpty()` 的一半 ——
        所以处理器里要 `trimAscii()` 之后再判。
      · **报错必须教回怎么改**：「需要 name」不够，要说清
        「要更新整个项目群请显式传 name=*」。一条只说「缺参数」的错误
        会让模型反复重试同一个调用。
    ⚠️ 上文那句「已知遗留」已由不变量 50 处置：当时记的是
    「不可采集目录的 error 是运行时原文，措辞质量，非谎报」——
    **那个判断是错的**。同一句 `Native function error.` 在
    `moongit add / --name home` 这条路径上的成因不是措辞，是整条命令崩了。

50. **会失败的系统调用不许当不会失败；「读不到」是第四态，且必须走到用户眼前。**
    缺陷 #199 的成因查清了：`FileInfo` 的属性各自走不同的系统调用，
    **stat 失败时是抛异常而不是返回错误码**：
      · `isDirectory()` / `isRegular()` —— stat 不到就抛。
        触发者全是**本机真实存在**的路径，实测
        `/private/var/db/DifferentialPrivacy`、`/dev/fd/20`、
        `/Library/Caches/com.apple.aned`（SIP / 权限边界，不是构造出来的）。
      · `lastModificationTime` —— 跟随符号链接，断链就抛（`git.cj` 早修过一处）。
      · `FileInfo(path)` **构造器本身**也抛。
    而 `collectActivity` 与扫描器的循环体**一个 try/catch 都没有**。
    后果实测：
      · `moongit scan /`                  → exit 1「内部错误：Native function error.」
      · `moongit scan /private/var/db`    → exit 1 同上
      · `moongit add / && moongit status` → 该项目 `error='Native function error.'`、
        `commitCount=-1`、`userDirtyCount=-1`
    即：**一个只读属性取不到，整个项目的状态面板全黑**。
    而这些路径是**用户自己给的** —— 指向 `/` 或任何系统目录都合法。
    同一次审计里我把它误记成「措辞质量问题、非谎报」，
    教训是：**看到一句没信息量的报错，先查它到底是不是崩了，别先假设它是文案。**
    第二个独立缺陷在同一个循环里：`listDir` 吞异常返回空数组，
    于是「子目录读不出来」与「这个子目录真的是空的」完全同构，
    `fileCount` 悄悄变小而 headline 照报「N 个文件」。
    四条硬规则：
      · **四态，不是三态**：`Dir` / `Regular` / `Other` / `Unreadable`。
        `if (!info.isDirectory()) continue` 把 `Unreadable` 归进 `Other`，
        就是把「没看到的子目录」说成「这里没有子目录」——
        与 `listDirChecked` 把「读不出来」与「真的是空的」分开是同一条理由。
        口径收在 `classifyEntry` / `entryKindFrom`（paths.cj）。
      · **判据与 IO 必须分开**。原生 stat 失败在测试里**复现不了**
        （要构造 EACCES/EPERM 得有非 root 属主的目录，或依赖 SIP 路径），
        所以四态判定抽成纯函数 `entryKindFrom(Option<Bool>, Option<Bool>)`，
        `None` 就是「读不出来」。**测不了的判定等于不存在。**
      · **不猜成因**。权限不足 / SIP / 已消失在消息里分不出来，
        就只报「读不到」并把路径列出来，不写「可能是权限问题」——
        没有证据的话术会把用户引向错误的排查方向。
      · **披露要出现在每一个出口，且共用一个口径函数**。
        `fileCountLabel` 是「N 个文件」这句话的唯一来源，三个出口共用：
        `computeHeadline`（状态列表 / 菜单栏 / MCP / AI 上下文）、
        `overallLine`（报告总体行）、`renderFacts`（**README 托管区**）。
        有读不到的地方时 `fileCount` 是**下界**，文案必须写「至少 N 个文件」。
        README 那一处是写进用户仓库的**持久文件**，谎报会跟着仓库活很久。
      · **行为测不到的那一半要由源码 lint 守**：遍历目录的代码不许直接调
        `isDirectory()` / `isRegular()` / `lastModificationTime`，
        也不许用 `listDir` 代替 `listDirChecked`。
        lint 前**必须剥注释**（解释这个缺陷的注释长得和缺陷一模一样）。
      · **崩溃消息必须能定位**：顶层 `catch` 至少要带**正在跑哪条命令**
        （`argv[0]` 是事实）与 `--verbose` 入口，
        不许只吐一句 `Native function error.`

51. **自检工具报出的每一条结论，都必须对应一次真的做过的检查；恒真条件是伪装成守卫的空判断。**
    缺陷 #200 出在 `doctor` 自己身上 —— 一个专门用来「发现环境问题」的命令，
    给出了一条**它从没做过的检查的合格证**。
    原来的「临时残留」这一行是三件坏事叠在一起：
      · 统计用的 `listDir` 吞掉读取异常返回空数组（#199 同源）；
      · 闸门条件 `listDir(p.path).size >= 0` —— `size` 是 `Int64`，
        **永远 >= 0，等于什么都没判**。它是「看起来像守卫」的空判断；
      · `fileExists(<doc>)` 在父目录不可读时返回 false，
        于是内层循环一次都不跑，`leftovers` 为空 → 输出「无」。
    实测：磁盘上确实有 `README.md.tmp-999-0`，把项目目录 `chmod 000` 之后
    `moongit doctor` 报的是**「临时残留  无」**。磁盘上那个文件就在那儿，它只是没读到。
    危害等级高于一般措辞问题：`doctor` 的退出码语义是「环境能不能用」，
    而这一行是用户判断「我的仓库干不干净」的唯一依据。
    四条硬规则：
      · **自检结论必须三态**：`Clean`（查了，没有）/ `Found`（查了，有）/
        `PartlyUnreadable`（**没查完**）。第三态不许塌进第一态。
        收口在 `leftoverVerdict`（纯函数）+ `scanLeftovers`（返回
        `(残留清单, 读不到的项目名)`）。**第二项不返回，调用方就只能把两者合并**。
      · **没找到就不许开处方**。`PartlyUnreadable` 的 detail 里不许出现
        「可安全删除」——那是在没检查过的目录上给删除建议。
      · **恒真条件零容忍**。`x.size >= 0` / `x != null` 这类对类型恒成立的判断
        写着「像守卫」，读代码的人会以为那里有检查。lint 里明令禁止。
        lint 前**必须剥注释**。
      · **闸门要用真正的判据**。用 `fileExists(<doc>)` 当「目录可读」的代理是错的：
        `exists` 依赖父目录可搜索，父目录不可读时它返回 false，
        于是「读不到」被翻译成「文档不存在」。真正的判据是 `listDirChecked`
        的 `readable` 标志。
    顺带收掉一处漂移：`cli.cj` 里手抄了一份
    `["README.md","AGENTS.md","AGENT.md","CLAUDE.md"]`，
    而 `render.cj` 的 `DEEPGIT_MANAGED_DOCS` 是同一份名单的**既有单一来源**。
    托管文档名单只允许有一份，改名单时手抄副本不会跟着变
    （lint 已盯：`cli.cj` 里不许再出现这个字面量）。

52. **同后果的取值必须同侧拦截；写入口的校验不是唯一一道闸门。**
    缺陷 #201：`config set update.backupKeep 0` 放行（只拦负数），
    `pruneBackups` 也只拦负数。于是 0 走到
    `excess = names.size - keep = names.size` → **把全部备份删光**。
    端到端实测（`backupKeep=0` 跑一次 `moongit update proj`）：
      引擎输出「✓ 已更新 README.md」、exit 0，托管区**写进了用户的 README**，
      而 `备份文件数 = 0` —— 用户的原文永久丢失，引擎全程报告成功。
    关键在于 **0 与负数的数学后果完全一样**，区别只有语义标签。
    所以「只拦负数」从一开始就没关上那道门：它挡的是同一个后果的另一个入口。
    这个仓库里这条规则已经写过三遍，且 `cli.cj` 自己在注释里列了清单：
      `--depth 0`（#197 拒）、`journal --limit 0`（拒）、`backupKeep < 0`（拒）。
    唯独 `backupKeep 0` 漏了。四条硬规则：
      · **闸门判据只有一个来源**。阈值收在 `MIN_BACKUP_KEEP` /
        `backupKeepError`（`docs.cj`），`config set` 与 `pruneBackups` 共用。
        写两处阈值必然漂移，症状是「配置被接受了但行为不是那样」。
      · **写入口不是唯一一道闸门**。`pruneBackups` 的注释早就写明：
        「config set 会被拦住，但直接改 config.json 就绕过去了
        （负载校验只在一处，绕过去就没人管）」。
        所以**写入口与运行时必须各有一道**，
        且运行时那道的报错要教回怎么改 config.json。
      · **判错方向必须是「多留一份」，不是「多删一份」**。
        备份是引擎重写用户 README/AGENTS 托管区时**唯一的回滚手段**；
        没有它，引擎的一个 bug 就从「可回滚」变成「用户数据不可恢复」。
      · **既有测试里可能有把缺陷写成断言的**，遇到要**显式推翻并留下理由**，
        不许偷偷改。本条就推翻了 `testPruneBackupsRefusesToDeleteOnNegativeKeep`
        里的一段：它原本断言「keep=0 是合法语义，必须删光」。
        反向结论也一样成立：**「真的不保留备份」是需要新增的显式开关**，
        不是把 `keep` 这个「保留几份」的数字挪作他用 ——
        在那之前把 0 归到非法一侧。
    ⚠️ 顺带记一笔（**未修，属特性缺口不是谎报**）：
    `ApplyResult.backup` 在生产侧没有消费方（唯一读者是一条测试断言），
    于是 `update` 改了用户文件却从不告诉用户备份放在哪。
    字段本身留着是对的（verify/诊断迟早要用），缺的是那条提示。

53. **「写入口报成功」和「读路径会拒绝」必须是同一份判据；报成功与解释不许分两个流。**
    缺陷 #202 是 #201 的同一条纪律在另一个键上的复发，而且形态更阴：
    `config set update.maxShallowBranches` 原来**一行校验都没有**。
    实测两条命令就能证：
    ```
    $ moongit config set update.maxShallowBranches 0
    ✓ 已设置 update.maxShallowBranches = 0        ← 报成功（stdout）
    $ moongit config get update.maxShallowBranches
    6                                              ← 存的是 0，读出来是 6
    ```
    原因是读路径（`configFromJson`）会把 `< 1` 静默修回 6，只在 **stderr** 留一行。
    于是：**用户设的值被丢弃了，而报成功在 stdout、解释为什么没用在 stderr ——
    脚本与 CI 根本看不见后者。**「引擎会拒绝的取值，写入口却报成功」。
    后果侧也真实存在：`collectCandidateBranches` 里 `taken >= maxBranches`
    立刻成立 → 候选集为空 → 浅更新一个分支都不采，而报告仍像「只有这些分支」，
    进度库里从此不再有分支基线。
    本条同时修掉 #201 留下的**档位漂移**：`backupKeep` 写入口按 `< 1` 拦，
    而读路径还写着 `< 0` —— 两处差一档。三层闸门各写一遍阈值，
    漂了以后症状是「配置被接受了但行为不是那样」，属于最难查的那类。
    三条硬规则：
      · **一个键的判据只有一个来源**：`MIN_*` 常量 + `xxxError()` 纯函数
        （`backupKeepError` / `maxShallowBranchesError`），
        **写入口 / 读路径 / 运行时**三层全部调它。
        阈值字面量只允许出现在 `public let MIN_*` 那一行（lint 已盯）。
      · **写入口不许比读路径宽松**。写入口是唯一「用户以为它生效了」的地方，
        它放行而读路径拒绝，就是把用户的设置偷偷丢掉。
      · **「已设置」的回执必须与实际生效的值一致**。
        报成功走 stdout、解释走 stderr 的组合，等于对脚本说谎；
        要么两边都在同一个流，要么写入口直接拒绝（现在是这样）。
      · **报错文案不能假设用户传了什么**。收到 `-3` 时说「设成 0 等于…」会把
        人引向错误的排查方向；措辞必须与取值无关。

54. **能力清单与判定各留一份就会漂；副本数要用 lint 钉死，不是靠自觉。**
    缺陷 #203 是 #202 的第三处复发，形态又换了一种：这次连**清单**都没有。
    全仓判断「是不是英文输出」的方式是一句裸的 `lang != "en"`，
    **20 份副本，跨 7 个文件**：
      render.cj 10 / cli.cj 3 / progress.cj 2 / narrative.cj 2
      report.cj 1 / store.cj 1 / time.cj 1
    危害两层：
      · `config set language fr` 报「✓ 已设置」，而引擎只有 `en` / 中文两条路，
        于是**任何非 `"en"` 的值都渲染成中文** —— 写入口接受了一个引擎不会兑现的值
        （与 #202「设了但被丢弃」同族，方向相反：这次是**接受了但永不兑现**）。
      · 将来要加第三种语言，得改 20 处。**漏一处就出半中半英的输出** ——
        那比单一语言更糟，因为用户读到的是一份自相矛盾的文件，
        而没人知道是哪一处漏了。
    修法与 #201 / #202 同源：
      · **能力清单只有一个来源**：`SUPPORTED_LANGUAGES`（`util/text.cj`）。
        清单和判定必须成对出现 —— 有判定没清单（`language`）会永不兑现，
        有清单没判定（没有这样的键）则清单本身是死数据。
      · **判定走正形**：`isEnglish(lang)` 用 `== "en"`；
        全仓**一处 `!= "en"` 都不许剩**（lint 断言 `total == 0`，
        并同时断言接缝本身还在、且用的是正形 —— 否则把接缝删了也算绿）。
      · **副本数要写进 lint**。「有 20 份副本」这种知识只写在注释里是不够的：
        写成断言后，「加一种语言」从一个静默的漂移风险变成一次**必须处理的
        编译期事件**。
      · **同一键的写入口 / 读路径仍要共用 `languageError`**
        （延续 53 的三层纪律），手改 config.json 那条绕过路径才有人接。
    ⚠️ 通用教训：**「多份实现必然漂移」不只是在函数层面成立，**
    一句两字符的裸判定同样算。判定与清单都属于「会被复制的东西」。

55. **schema 与处理器是同一条契约的两半；改一半必须同时改另一半，并由 lint 兜住。**
    延续不变量 49 那句「schema 是给模型看的提示，处理器才是闸门，两道都要有」。
    缺陷 #204 证明「两道都要有」还不够 —— **改了处理器忘了改 schema**，
    提示就会和实际相反：
      `run_deep_update` 的处理器是 `mcpRequireProject(getStr("name"))`，
      与 `run_shallow_update` / `run_track` **完全同构**，三者都必须传 name。
      但 #198 只把后两个的 `required` 补成 `["name"]`，
      `run_deep_update` 留在 `[]` ——
      schema 告诉模型「name 可选」，模型就放心地调 `run_deep_update {}`，
      处理器回一句「未找到项目：」。**模型拿到的是失败，不是它要的东西。**
    危害分级：把必填标成可选，比反过来更坏 ——
    反过来模型会补上参数，这里模型会**自信地漏掉**。
    三条硬规则：
      · **改处理器必改 schema**。给某个工具加/去掉参数校验时，
        `mcpToolList()` 里那一行的 `required` 与 `description` 一起改。
      · **schema 与处理器的一致性必须由 lint 保证**，不能靠记得。
        `__lintMcpSchemaRequiredMatchesHandler` 扫全表：
        处理器里出现 `mcpRequireProject(` 的工具，schema 的 `required`
        必须含 `name`。写成断言后，第 N 个同族工具忘了补就红，
        而不是等模型踩到。
      · **同构工具的 schema 要同构**。另配一条更直白的
        `testSiblingWriteToolsAllRequireName`，让新增第四个 `run_*` 的人
        一眼看到「这里要填 name」。
    ⚠️ 写这类 lint 的血泪（同一个陷阱本会话踩了**三次**，都在判据上）：
      ① **needle 字面量在源码里** → 匹配到自己。用拼接构造。
      ② **lint 扫自己所在的文件** → 自己的代码命中。按函数名前缀排除。
      ③ **片段提取越界** → 终止条件只认带引号的 `case "…"`，没认无引号的
        `case _ =>`，于是最后一个工具的「处理器」一路吞到文件末尾，
        匹配到文件末尾正好存在的本 lint needle。
      三次的症状都一样：**红的原因与它声称的判据不是一回事**。
      负控必须核对「红的原因」，否则你测的是另一个 bug。
      本条另外踩了偏移量写错（`"mcpTool(\""` 长度 9 却写了 10，
      把工具名首字符截掉，于是按名找处理器全部落空）——
      同一条教训：**判据本身错了，结论就是反的。**

56. **每一层截断都要有自己那一句披露；过滤必须发生在截断之前。**
    缺陷 #205 是 #199 / #200 那一族（「看了但只留了一部分」被报成「完整」）的
    第二次复发，叠了**三层**截断，而披露只覆盖了其中一层。
    端到端实测：14 种真实语言 + 10 个 `.md` 的仓库，
      · **引擎**：`langStats(names, 12)` 先截断，`Markdown` **之后**才被 `continue` 掉
        → Markdown 白占一个名额又被丢弃，上限 12 实际只出 **11** 条；
        第 12 种**真实**语言被静默吞掉（实测 Shell / Swift / TypeScript）；
        而 `languagesTruncated` 是 `false` —— 它只反映 20000 文件上限，
        与这条无关，于是引擎**反过来声称「这份画像是完整的」**。
      · **客户端**：`d.languages.prefix(8)` 又砍一层（引擎 12 → 界面 8），
        而 `languageCoverage` 拿到的是 `d.languages.count`（**含**被藏的 4 条）
        → 披露按 12 算、界面画 8 条，`note` 为 `nil`，
        卡片标题「语言分布（跟踪文件数）」零限定词。
    三条硬规则：
      · **过滤必须在截断之前**。「先取前 N 条、再把不要的去掉」会让
        被去掉的东西**占着名额**，而名额本可以给一条真实数据 ——
        这是数据级的损失，不只是显示问题。
      · **每一层截断各有各的披露，披露要能区分是谁砍的**：
        `languagesTruncated`（文件被砍）/ `languagesTopCut`（语言条数被引擎砍）/
        `shownCount < languageCount`（**界面自己**又砍的）。
        少一个轴，那一层就静默消失。
      · **界面自己砍的也算截断**。`prefix(8)` 不是「显示细节」，
        它是一个**用户看不见的过滤器**；把 count 传成引擎的条数而不是画出来的条数，
        等于让披露函数算一个界面上不存在的事实。
    ⚠️ 顺带一条通用形态：**「先截断再过滤」是所有 top-N 场景的通病**。
      任何 `take top N` 之后还有过滤的代码，都要问一句：
      「被过滤掉的那几条，白占名额了吗？」

57. **引擎给的截断标志只能描述引擎自己砍的那一层；消费方自己砍的必须自报。**
    缺陷 #206 是 #205 的**反向复发**：同一族缺陷，位置相反 ——
    这次引擎的数据是**完整**的，谎报出在客户端。
    端到端实测：14 个提交、14 种不同类型（含 4 种旧分类法遗留名）的仓库：
      · **引擎**：`status --json` 给 12 条（= `COMMIT_TYPE_ORDER` 长度 12：
        11 个已知 + `other` 桶；表外名称全聚进 `other`，所以**未知类型再多也不加条数**），
        且 `commitTypesTruncated = false` —— 后者的意思是
        **「采样窗口没被砍，这就是全量」**，是引擎能给出的最强的一句真话。
      · **客户端**：`commitTypeLine` 写死 `types.prefix(5)`，
        于是这一行变成「feat ×1 · fix ×1 · perf ×1 · refactor ×1 · docs ×1」，
        **藏掉 7 种，一个字都不提**；而它唯一的披露
        `commitTypesTruncated` 描述的是**引擎的采样窗口**，
        在这个样本上恰好是 `false`。
    于是出现了一个必须记住的反直觉形态：
      **引擎数据越完整，消费方藏得越狠、披露越少。**
    `commitTypesTruncated = false` 的含义是「这就是全量」，
    消费方若拿它当「可以放心只画前 5 条」的信号，等于把**引擎的诚实**读成了**自己的许可**。
    三条硬规则：
      · **每个截断标志只对自己的那一层负责**。窗口轴（`commitTypesTruncated`）
        与条数轴（消费方自己的 top-N）是两回事，拿一个轴的标志替另一个轴背书 = 谎报。
      · **披露的分母必须是「界面上实际画出来的条数」**。
        把引擎的条数当分母，披露就在陈述一个界面上不存在的事实
        （#205 的 `shownCount` 与 #206 的 `shown` 是同一条规则的两处落地）。
      · **采样截断要写分母**：「已截断」而不说「近 15/23 条」，
        读者只能把样本当全量。`report.cj` / `agent.cj` 早就这么写了，客户端这次跟上。
    ⚠️ 跨进程边界的另一条：**上界要两端都钉**。
      客户端提交构成卡片用 12 色色板给每类上色，而 12 这个数是**引擎词表的长度**，
      不是客户端自己定的。色板短于引擎能发的条数时，
      `palette[i % palette.count]` 会让第 13 类拿到第 1 类的颜色 ——
      分段条上两段糊成一段、图例两行同色圆点，**把两类画成了一类**。
      现在：引擎侧 `testCommitTypeCountIsBoundedByVocabulary` 钉住
      「条数 ≤ 词表长度」，契约检查（跑**真实引擎**）钉住
      「实测条数 == 12 且 ≤ 客户端色板容量」。
      客户端侧那条判据刻意写成「这个函数体里不许出现取模」而不是
      「不许出现 `palette[i % palette.count]`」——只认死变量名的话，
      换个变量名就能把同一个缺陷溜过去（NC58-b 第一版就是这么假绿的）。
      容量不足的正确表现是**说出来**（`commitTypeCardSlice` 的 note），
      不是让取模把两段涂成同色。

58. **传输层只有 CLI 子进程与 MCP(stdio) 两面；进程内 FFI 是「已决定不做」，不是待办。**
    这条把一个长期挂着的问题**结案**：原计划要让引擎编成 dylib、被客户端直接链接、
    在同一进程里调用（`docs/deepgit-redesign-plan.md` 的 D1）。
    在仓颉 **1.0.5** 上它做不成 —— 五条路径全部失败于 `Check failed: runtime != nullptr`：
    宿主（Swift）进程里没有仓颉运行时，而 dylib 里的代码要拿那个运行时（GC、调度器）。
    决定：**不做 FFI，传输层停在子进程 + stdio。** 理由三条：
      · **失败形态是硬崩溃，不是可回退的失败**。`runtime != nullptr` 是断言失败。
        「先试 FFI、失败再退 CLI」意味着两条代码路径必须**永远行为一致** ——
        而本仓库最贵的一课恰恰是两份实现必然漂移（`!= "en"` 20 份副本、
        `required` 三处手写、`DEEPGIT_MANAGED_DOCS` 手抄清单，都是这么漂出来的）。
        为一个拿不到收益的能力养一条影子路径，是净亏。
      · **收益侧本来就薄**。status 载荷是 ~58KB JSON，微秒级拷贝；
        子进程开销在这个量级不是瓶颈，而「省掉它」换不来任何用户可见的东西。
      · **子进程这条通道已经被守住了**：契约检查拿**真实引擎输出**喂**真实模型**
        （53 项），MCP 另有自己的形状检查。加 FFI 等于新增第三份契约，
        而它换来的只是同一份 JSON 的另一种取法。
    **重开条件**（两条都满足才值得重开）：官方 `language.cffi.overview.5` 指向的
    `build/README.md` 到手（它描述宿主进程如何初始化运行时），
    且工具链版本明确支持这种嵌入。注意这**不是**「等材料」——
    在条件满足之前，这条路的答案是「不做」。
    ⚠️ 决定必须**被机器守住**，否则半年后有人加一个 `@C` 垫片谁也看不出来：
      `__lintTransportLayerHasOnlyTwoSurfaces`（`util/paths.cj`）扫全部 `src/**/*.cj`，
      禁止 `foreign` / `@C` / `dylib` / `staticlib` / `TcpListener` / `Socket` /
      `bind(` / `listen(` / `0.0.0.0`，并用结构判据钉住 CLI 表里没有 `serve` 条目。
      它的封杀清单是**逐词量过**的：`localhost` / `127.0.0.1` / `http` **故意不在列**
      （它们只出现在断言自己不存在的测试与遗留配置样本里，按词封杀会红在守卫身上），
      `serve` 也不在列（它在代码里 23 次命中全是 `server` 的子串）。
      任何往清单里加词的动作，先用实测零命中的词。
    ⚠️ 术语纪律：**「进程内」只指 FFI 那条没做的路**。
      早先文档把子进程 + stdio 也叫「进程内通信」，而同一句话里又写着
      「以子进程方式调用」—— 自相矛盾，且会把读者引向「客户端链接了 dylib」这个
      与事实相反的结论。传输层的正确说法是「**本机进程之间**通信，不跨网络」。

59. **「界面自己砍了一层」是同一族缺陷的第三次复发；两端的完整性都要钉。**
    #205（语言）、#206（提交类型）、#207（里程碑）是**同一个家族的三次**复发，
    形态完全一致：**引擎给了完整数据 + 一个「这就是全量」的真话，
    消费方自己 `prefix(N)` 砍了一层，零披露。**
    #207 实测：1 个项目 8 条进行中里程碑，`dashboard --json` 给
    `counts.open = 8` / `readCount = 8` / `items` 8 条（items **无上限**，
    且引擎侧有对账等式 `readCount = open+done+dropped+unknown+excludedDisabled+orphaned`），
    而卡片标题按 counts 说话（「进行中 8」）、列表只画 5 条 ——
    v6.0 / v7.0 / v8.0 静默消失，退出码 0，没有任何字段提示。
    三次复发说明**这不是个案，是这个架构的默认失败模式**，所以规则按家族写：
      · **引擎给了什么，和界面画了什么，是两件事，必须分别记账。**
        引擎侧要么不截断（`items` 无上限、commitTypes 上界 = 词表长度、
        langStats 有 `DASH_LANG_TOP` 并恒发 `languagesTopCut`），
        消费方各自的 `prefix(N)` 也各自有披露。三处披露现在是
        `languageCoverage`（三轴）/ `commitTypeComposition`（两轴）/ `milestoneCardSlice`（一轴）。
      · **披露的分母必须是「界面上实际画出来的条数」**。#207 的负控 c 专门钉这一条：
        把披露里的 `total` 换成 `shown`（「只显示前 8 条（共 8 条）」而实际画 5 条）——
        界面上**确实有一行提示**，只是那行提示在撒谎。这类错最难被肉眼抓到，
        因为「有披露」这件事本身成立了。
      · **画几条必须用判定算出来的 `shown`**，不许在视图里再写第二个字面量。
        `prefix(5)` 与 `prefix(slice.shown)` 差一个字面量，却差一整条判据。
    ⚠️ **两端都要钉，缺一端等于没钉**：
      · 引擎侧钉「我给的是全量」：`testDashboardMilestoneItemsAreCompleteAndUncapped`
        断言 `items.size == 计入数`（`testCommitTypeCountIsBoundedByVocabulary`
        是另一端的对应物：条数上界 = 词表长度）。
      · 客户端侧钉「我砍的我说了」：纯函数 + 源码 lint。
      只钉客户端的话，引擎哪天给 `items` 加个上限省流量，两边都不会红 ——
      counts 仍然是全量（引擎测试看不出来），而 items 已经少了几条
      （客户端看不出来，因为它只知道「引擎给了 3 条」）。
    ⚠️ 复用的判据形状：三个纯函数文件（`LanguageCoverage.swift` /
    `CommitTypeComposition.swift` / `MilestoneCard.swift`）都是
    「零依赖 + 返回 (shown, total, cut, note) + 渲染用 shown」。
    **再出现第四处 top-N 截断时，照抄这个形状，不要就地写 `prefix`。**

60. **合并了两份形状 ≠ 钉住了它；文档里的「已知问题」会过期，要以实测为准。**
    journal 的条目形状历史上是**两套**：`status --json` 内嵌的是手挑的 9 键投影
    （丢了 `docs` 等键，还对不存在的 `docs` 硬塞 `[]` —— 「压根没记录」被压成
    「这次没碰任何文档」），`journal --json` 给的是原始条目。同一份形状约定抄两处、
    漏一处就破，这个引擎在它上面**栽到第 8 例**（`cli.cj` 那句注释是证词）。
    现已合并：两个出口都走 `kernel/store.cj` 的 `journalEntryJson`（逐键拷贝 + 派生
    `providerLabel`），实测各 19 键、差集为空。
    ⚠️ 但**那次合并什么钉都没留下**：
      · 数据层有（契约检查第 7b 组拿两个 fixture 逐键比键集**并比值**）——
        这层能抓住「形状真的分叉了」，抓不住「有人把出口改成绕开共享构造器、
        恰好还拼出了同样的键集」。
      · 源码层当时**没有**。构造函数改对了，但「两个出口都调用它」只是一句注释。
        谁在某天把某个出口改成自己拼对象，两个形状立刻又分叉，而**两边都不会红**：
        各自的测试都只验自己那一份。
    现在补上源码层：`__lintJournalEntryHasExactlyTwoOutletsThroughTheSharedBuilder`
    断言 `.add(journalEntryJson(` 在全仓**恰好 2 处**、且分别在 `cli.cj` 与
    `flow/status.cj`。少一处 = 有出口绕开了；多一处 = 有了第三个出口却没登记，
    消费方会多一套解码分支。
      · 选 `.add(journalEntryJson(` 这个形式而不是「数调用次数」：
        测试里有 5 处直接调用它验行为，只有「塞进数组」才是出口。
    两条通用规则：
      · **修好一个「两份实现」的问题，必须同时留下一道防止它重新分叉的钉。**
        否则修复只是把状态改对，没把状态**锁住**。
      · **源码 lint 的自排除机制要抽成共用函数，不要每个 lint 抄一份。**
        `util/paths.cj` 的 `strippedCodeSkippingFunction(path, skip: Option<String>)`
        是这一轮从传输层 lint 里抽出来的：它踩过两次坑（变量名自带 token /
        单趟扫描算不出区间），抄第二份就会「改一处忘一处」。
        `skip = None` 表示只剥注释不排除；**区间算不出来时返回 `None` 而不是
        「排除整个文件」** —— 后者会让调用方的 lint 变成永远绿的安全带，比没有还糟
        （这个设计当场就抓到了我自己的一个拼写错误：selfName 写成 `ExactlyOne`）。
        配套地 `cjSourceFiles` 从 `private` 改成 `public`：
        lint 天然要住在**被检查的东西旁边**，遍历器私有就等于逼着每条 lint
        塞回 `paths.cj` 或复制一份遍历器。
    ⚠️ 文档侧的同一课：`docs/deepgit-redesign-plan.md` 长期挂着
    「两套 journal 形状仍不一致（9 键 vs 17 键），留待与 FFI 方案一起定」。
    实测早已一致（19 vs 19），而 FFI 也已结案 —— 这条**同时**过期了两处，
    还把「破坏性变更待定」当成悬在头上的风险。
    **「已知问题」清单是最容易腐烂的文档**：它记录的是写下那一刻的世界。
    动过那块代码之后，要么更新它，要么实测一遍再决定留不留。
    ⚠️ 负控的第三版教训（NC61-c，写了两遍才对）：
      第一版「复制构造器 ⇒ 必须红」—— 判据数的是 `.add(journalEntryJson(`，
      复制品叫 `journalEntryJsonCopy`，**名字后缀不同就匹配不上**；
      顺带暴露「定义只有 1 处」是恒真断言（同名函数同包内根本编译不过），
      已从 lint 里删掉。**恒真断言要删，不要留着显得严谨。**
      第二版「整体改名 ⇒ 必须红」—— 那是在**断言一个假命题**：
      全局改名（IDE 重命名会连字面量一起改）之后两个出口仍共用同一个构造器，
      形状没分叉，**绿才是正确答案**。判据声称的是「两个出口共用一个构造器」，
      不是「这个函数必须叫 journalEntryJson」—— 名称是实现细节，分叉才是缺陷。
      **一条负控写「必须红」之前，先问：它注入的到底是缺陷，还是仅仅是变化？**

61. **两个真实数字讲不同的集合时，标题只准说它真正代表的那一个。**
    #209 实测（客户端设置页，真实快照 `Resources/models-dev.json`）：
    section 标题写「models.dev 目录 · 225 家」，而 Provider 选择器只列
    `popularProviders()` 的**前 40 家**。两个数字都真实，讲的是**不同的集合**：
      · 目录 225 家（`providers.count`）；
      · 其中**有可用 api 端点的 199 家** —— 这才是能被列出来的全集；
      · 列表实际给 40 家 ⇒ **159 家有端点的 provider 用户根本选不到**
        （含 `minimax-cn-coding-plan` 28 个模型、`alibaba-token-plan-cn` 28 个、
        `ai21`、`inference`、`databricks`、`wandb` …），
        而 provider 那一栏**没有过滤框**（只有模型栏有 `TextField`）。
    与 #205/#206/#207 是同一家族的第四次复发：**一个声称完整的数字，
    配一个被砍过的列表，而没人说。**
    ⚠️ 但这一处**不能照抄前三次的结论**（这是它值得单独记的原因）：
      前三次修的都是「砍掉的没有披露」；这一处的**上限本身是合理的** ——
      目录在 `parse()` 里已按「有端点优先 + 模型数降序」排过序，
      实测第 40 家 33 个模型、第 41 家 32 个，正好卡在自然断点上，
      被砍掉的 159 家里模型数最多的也就 32 个。
      所以正确处置是**修标签**（把两个口径都说出来），
      不是取消上限，更不是把 185 家塞进 Picker。
      「发现截断」和「截断是缺陷」是两件事 —— 判据要能区分它们，
      否则就会一路滑到「凡是截断都是 bug」这种蠢修法上。
    修法沿用家族形状：`ProviderPickerSlice.swift`（零依赖）出
    `(shown, withEndpoint, total, cut, note)`，文案**必须同时给两个口径**
    并指出可执行的下一步：
      · 只报 199 不报 225 ⇒ 仍会被读成「225 家里 199 家可用、剩下 26 家没端点」，
        而真相是 159 家**有端点却被列表砍掉了**。这是本条最容易被写错的地方，
        NC62-b 专门钉它。
      · 只报数字不报路径 ⇒ 等于把一个**可用**功能说成缺失。
        设置页本来就有「Base URL 覆盖」输入框与「手动输入模型 id」，
        所以披露要指到那里，而不是写一句「其余略」。
    ⚠️ 本次修里最险的一处，写下来免得再犯：
      检查程序里「列表条数 == 披露条数」这条相等断言，第一版的数据源用了
      `ModelCatalog.shared` —— 那是验死锁用的单例，那一刻**还没加载完**，
      于是 `shown=0 withEndpoint=0`，而 `0 == 0` 让它**白转着变绿**。
      **空数据上的相等断言是最容易自我欺骗的一种。**
      现在数据走纯函数 `parseCatalog(data:)`，并且**先断言前提**
      （这份快照真的被砍过），前提不成立就直接 `exit(2)` 而不是继续跑。
      NC62-d 专门把数据源换成空数组，守的就是这条。
    ⚠️ 顺带一条通用纪律（与不变量 60 的「文档会过期」同一根）：
      **解释性注释是最容易腐烂的一类代码**。`cli.cj` 的 `cmdJournal` 里
      有一段注释说「JSON 路径输出的是裸数组，没法往里塞 envelope 字段，
      所以走 stderr 披露」，而同一个函数下面 150 行处写着
      「⚠️ 必须是 envelope，不能是裸数组」并真的建了 envelope
      （实测顶层 7 个键）。两条注释互相矛盾，而**过期的那条紧挨着
      三个正是为了 envelope 才存在的变量声明** ——
      下一个读到那里的人会得出「envelope 放不下」这个与事实相反的结论，
      然后照着它把已修好的披露删回去。
      改了行为必须回头看它周围的注释：**注释不是历史记录，是当前契约的一部分。**

62. **动了用户的文件就必须说备份在哪；「没做」也不许说成「做了」。**
    这是不变量 52 记下的那个「`ApplyResult.backup` 零消费方」的收口，
    也是**同一族缺陷的另一个方向**——前面是「做了但没说」，这条是「没做却说了」。
      · **引擎（#210）**：`applyRegions` 每次改文档前都会把旧版复制到
        `store/<id>/backups/<file>/<时间戳>-<文件名>`，再按 `update.backupKeep` 裁剪
        （≥1，#201 已把 0/负数堵死）。而 `docChanges` 的元组里**没有这一位**：
        `res.backup` 在 `flow/{update,deep}.cj` 的调用点被直接丢掉。
        于是引擎每轮都在改用户的 README/AGENTS.md、留了备份、还会**静默删掉旧的**，
        而用户从头到尾不知道备份存在 —— 想回滚时无从下手，
        旧版本消失时也没有任何提示。
      · **客户端（#211）**：把更新结果整个丢掉（`_ = try await …`），
        然后**无条件**弹「X 的文档托管区域已刷新」。
        而引擎在文档没变化时输出的是「README.md 无变化」——
        **没做被说成做了**。它与「失败被当成没有」是同一条轴的两个方向：
        都是把「引擎给了三态」压成「界面上只有一种说法」。
    三种形状必须分开，合成一句话就会撒谎：
      · **新建**（本来就没有旧版本）⇒ 没有备份，**不许编一个**
      · **改动既有文档** ⇒ 必须是真实路径，且落在 `backups/` 目录下
      · **dry-run** ⇒ 压根没写文件 ⇒ 没有备份
    修法沿用家族形状，但这次要动**元组**：`docChanges` 从
    `(file, changed, created, preview)` 变成 `(…, backup)`。
      · 为什么不另开一个平行数组：两个必须一一对应的列表就是一处会漂的副本，
        而漂了之后没人知道（这仓库在「同一份约定抄多处」上已经栽到第 8 例）。
      · 改动牵连 4 个文件 14 处调用点 —— 这就是**元组不该用来承载三态**的代价。
        下一处要加字段时，先考虑换成具名结构。
      · JSON 侧 `backup` **恒发**（空串也是键）：键出现与否取决于数据的话，
        消费方就得写两套解码分支，而最容易漏的那套会把「键不存在」显示成「没备份」——
        真实原因可能是「这份文档是新建的」，两者处置完全不同。
    ⚠️ 客户端侧的接线守卫钉三件事（`__U` 组）：不许再出现 `_ = try await`、
      不许再出现那句「已刷新」、必须调 `updateOutcomeSummary`。
      **写死的成功文案是这类缺陷的温床** —— 它不依赖任何数据，
      所以无论引擎报什么，它都会说同一句话。
    ⚠️ 本次修里踩到的两个坑，都写进测试注释了：
      · **fixture 采集本身会执行一次命令**。`collect update_one` 要跑
        `update ok`，而我在它之前又多跑了一次 ⇒ 采集到的是第三次 update，
        引擎判「无变化」，样本里根本没有「改动 + 备份」那一档。
        症状是「样本里没有改动过的既有文档」—— 看着像判据错，其实是**样本造错了**。
      · **照抄邻近测试的搭法会毁掉前提**。上面那个 dry-run 测试预先建了
        `README.md`，我顺手抄过来，于是第 1 次变成「改动」而不是「新建」，
        `createdSeen` 永远不成立 —— 前提错了，整组断言在空转。

63. **设计 token 的取值必须逐值承接设计稿，不许自己编一套。**
    审查结论写过「设计系统：完全不存在」（redesign-plan §1.5），
    散值一度是 154 处颜色字面量、8 种圆角、7 种字号。
    现在有 token 层，但它**只能从设计稿取值**——设计稿在
    `docs/gitpulse_ai_workspace.html` 的 `tailwind.config → theme.extend.colors.dev`：
      · 表面：`bg/card/sidebar/border` 各有深浅两套（`darkMode: 'class'`）
      · 双轨：`shallow = #10B981`（绿，代码/提交轨）、`deep = #8B5CF6`（紫，AI 记忆/文档轨）
      · 另加 `accent = #3B82F6`、`ai = #06B6D4`
    判据（`__V` 组「色板取值必须逐值等于设计稿」）：12 个色值逐个核对。
    ⚠️ 纯函数层与视图层**刻意分成两个文件**：
      · `DesignTokens.swift` —— 零 SwiftUI/AppKit 依赖，所以 `Tests/ClientCheck` 能编它并断言
      · `DesignSystem.swift` —— 视图层，消费语义名。改色不会让检查失真。
    这条与不变量 9 同一根：**一个"看起来对"的常量，读者无从判断它从哪来**。

64. **能表达量级的东西不许塌成一档。**
    原 `statTint` 是「任何 n>0 都橙」——1 个未提交文件和 300 个未提交文件同色，
    等于**没分级**却摆出一副分级的样子。现在 `DSStat` 分四档
    （0 / 1–2 / 3–9 / ≥10），每档还有一句完整的中文描述（`describe`），
    供 VoiceOver 用——「未提交 5 个，需要注意」比一个孤零零的数字有用。
      · **负数按最严重处理**。第一版写成 `case ..<1: return .none`，
        负数落进「干净」档，而负数意味着**数据本身有问题**（引擎给错 / 解析错）。
        这时候报「干净」是最坏的一种说谎 —— 宁可报「需要处理」，让人看见异常。
      · 状态同理：未知字符串一律 `.unknown`，**不许默认绿**。
        8pt 的状态点没有文字替代，配色错了用户看不出来。
    判据（`__V` 组）：四档边界可证伪（0/1/2/3/9/10/999/负数），
    且断言「四档真的分出四种」—— 防止塌回两档时判据自己先绿。

65. **恒真断言比没有断言更糟：它让人以为这一层有人守着。**
    本轮删掉两条自己写的断言，都是这个形状：
      · 「编译清单里声明的源文件必须真被 swiftc 编译」
      · 「编译清单里声明的源文件必须真实存在」
    它们都**永远绿**。原因是同一件事：这两种错都会让 `swiftc` **先**失败
    （`error opening input file` / `cannot find 'DSStatus' in scope`），
    检查器根本没编出来，断言代码**永远执行不到**。
    修法：这类判据必须放在 **swiftc 之前**的 shell 前置检查里
    （`client-check.sh` 编译前的两道 check），那里才真跑得到。
      · 教训的推广形式：**判据的可达性本身就是判据的一部分**。
        写完一条 lint，要问「它在上游出错时还跑得到吗？」
      · 写完负控，还要核对「红的原因」与「它声称的判据」是否一致 ——
        红在编译阶段 ≠ 验证到了那条 lint。
    配套的负控纪律见下一条。

66. **负控脚本自己的备份/还原也必须有判据。**
    NC64 第一版把备份写进 `$SB`、还原时用 `$SH.bak` ⇒ **还原静默失败**，
    把工作区源码改坏了都没报警：`client-check.sh` 丢了 `$DSTOK`、
    `DesignTokens.swift` 的 `shallow` 变成 `0x123456`。
    症状是「负控跑着跑着后面几条全绿」——**看起来像判据抓不住，其实是环境被它自己污染了**。
    修法：
      · `trap ... EXIT` 兜底还原
      · **注入后自证文件真的变了**（md5 前后比对）——
        注入没生效会被误读成「判据抓不住」
      · 跑完逐条核对内容复原，**不数个数**（数行数的阈值定错会让「已复原」也报警，
        报了等于没报）
    ⚠️ ⚠️ 这条纪律**我自己在写 NC65 时又犯了一次**，而且症状极具误导性：
    沙箱目录（备份所在）被 `restore_all` 顺手删掉了 —— 我让它在还原后
    `mavis-trash "$SB"`，而某条 `inject` 失败会提前调用它。
    于是从那条开始，所有 `cp` 还原都报 `No such file`，
    看起来像「后面几条判据突然全绿」，**真因是环境被脚本自己毁了**。
      · **沙箱只由 `trap` 删**，任何中途路径都不许碰它。
      · 症状识别：中途出现连续的 `cp: ... No such file` ⇒ 立刻停，
        先修环境再谈判据 —— 否则会把「环境坏了」记成「判据无效」，
        白白改一堆好代码。
        **前提断言必须放在这组断言之前**，别让它埋在末尾。
    ⚠️ 顺带暴露的一条（#186 的静态守卫抓不到的那一半）：
      `testRunUpdateDryRunDoesNotWrite` 的清理原本写在**断言之后**且没有 `finally`，
      于是**测试一失败，`/tmp/deepgit-dry-*` 就永久留下** ——
      而负控（注入一条假备份路径让它红）每跑一次就漏一份，本会话实测漏了 2 份。
      `testEveryTestSandboxIsRemovedInTheSameTest` 抓不到这个：它是**静态**检查，
      只验「`removePathIfExists` 的调用存在」，**验不了它在失败路径上会不会跑到**。
      静态守卫能守住「写了没有」，守不住「跑到没跑到」—— 后者只有 `try/finally` 能保证。
      已在该测试里补 `try/finally`（`pid` 必须声明在 `try` **外面**，
      否则失败路径上 `finally` 引用不到它，直接编译不过），
      并把「失败也不许泄漏」变成负控 NC63-c 的一部分。
      **任何测试只要建了沙箱，就必须用 `try/finally` 清理** ——
      健康时不泄漏不算数，**红的时候才见真章**。

67. **不可逆的操作必须先确认，而且确认框必须说清代价。**
    规范 §3.2 要求「删除里程碑、放弃里程碑、提交全部改动、批量更新——全部加
    `confirmationDialog`」，核实后确认是**真缺口**（全库 0 个），且引擎侧坐实了后果：
      · `removeMilestone`（`kernel/milestones.cj:249`）直接从列表剔除 + `saveMilestones`
        ——**不留备份、没有回收站**。
      · 面板的「提交」走 `runGitOp(…, "commit")`，引擎那边是
        `git add -A` + `git commit`（`kernel/git.cj:1792`）——
        提交的是**整个工作区**，不是用户挑的那几个文件。
    后者尤其隐蔽：「全部」两个字只写在输入框的 **placeholder** 里，一填就被盖掉，
    于是用户以为提交的是眼前这几个文件。
    判定抽在 `DestructiveGuard`（纯函数，零 SwiftUI 依赖），视图只问
    `needsConfirmation(for:)`。三条边界要一起记：
      · **可逆的动作不许弹确认**。达成/重开是可逆的，弹了只会教会用户「确认疲劳」，
        而真正危险的操作也会被一起忽略。`setMilestoneStatus` 故意不在确认集合里。
      · **确认框要报真实数量**。只说「将提交所有改动」等于没说；`CommitScope`
        从 `userDirtyCount`/`untrackedCount` 算出规模，而**未跟踪文件必须单独警告**
        （最容易出事的一种：误提交 `.env`/密钥，它们会**首次**进历史）。
      · **代价与颜色要匹配**。不可逆的按钮染红且标题说动作（「删除」不是「确定」）；
        批量更新虽然动多个仓库，但每个文件都留备份（不变量 62），所以它是
        **告知式**确认、不染红 —— 满屏红会稀释「红=危险」这个信号。
    ⚠️ 同一动作的**每个入口都要有确认**：批量更新在 `BarView`（弹窗）与
    `DeepDolphinApp` 的菜单两处都存在。而菜单那条路是 `.commands` 里的 `CommandMenu`
    ——**不是 View**，挂不上 `.confirmationDialog`，所以待确认状态必须放在
    `AppModel.pendingBulkUpdate` 上，由主面板代为呈现。
    漏掉任一入口，这层保护就等于不存在（判据里专门钉了这条）。

68. **判据要卡在「实质」上，不能卡在「现象」上，否则删一半就假绿。**
    这是写 NC65 时被自己的负控抓出来的两处，形状一样：
      · 提交确认里写「未跟踪文件会**首次进入版本历史**，其中可能包含**不该提交**的内容」。
        我原先的判据是 `contains("首次") || contains("不该提交")` ——
        注入只删掉后半句「不该提交」，前半句「首次」还在，判据照样绿。
        现在只查 `不该提交`（**警告的实质**），现象描述不再算数。
      · 浅/深更新的文案里都嵌着 `track.label`（「浅更新」/「深更新」），
        所以哪怕正文一字不差，两句**字符串也不相等**，判据 `shallow != deep` 永远绿。
        现在先把标签与项目数替换掉再比正文，并额外要求深轨提到 `AI`
        （那是两轨最大的实际差别）。
    推广形式：**一条判据要问「它声称守的东西，被破坏时这句还成立吗」**。
    凡是用「或」连接多个同义信号的判据，等于给了一条绕过路径 ——
    同一句话里的两个近义词，必须挑最实的那个当锚。
    这与不变量 4、33 是同一根：**宁可只查一条硬判据，也不要写一条看起来周全、
    实际谁都能糊弄过去的**。
    配套的注入技巧也记一笔：注入要命中**判据真正在查的那一行**。
    我曾把 `if s.untracked > 0 {` 换成 `if false {`，
    结果命中的是 `parts.append` 那处，而真正的警告在下面的 `return` 里 —— 注入"成功"了，
    缺陷却没被注入。**注入"生效"不等于"注入到了要点"**，
    所以负控必须同时看「文件变了」和「判据红了」两件事。

69. **规范里的判断也会过期 —— 动手删之前先核实它现在成不成立。**
    `docs/deepgit-redesign-plan.md` §3.1 写：
    > **删除**：看板页（设计稿没有；`BoardSection` 本就是死代码）。
    这次照着做之前核实，发现**前提已经不成立**：
      · 侧栏有「看板」入口（`PanelView` 的 `Section("总览")` 里 `Label("看板")` + `.tag(.board)`）
      · `detail` 的 `switch model.selection` 有 `case .board: BoardPage()`
      · `BoardView.swift` 有 251 行完整实现
    也就是说它现在是一条**用户点得到的真功能**，不是死代码。
    规范说的「设计稿没有」也成立（`gitpulse_ai_workspace.html` 的 8 个模块里确实没有看板页），
    但「死代码」不成立。
    处理：**不删**。理由不是「舍不得」，而是——
      · 删掉会让现有用户丢一个能用的功能，而换来的只是「和设计稿一致」
      · 规范这条的前提已被后续改动推翻（看板被人接上了线），
        文档没跟上——这与不变量 60 是同一根
    正确做法是**改文档**，把「删除」标注为「前提已不成立，暂不执行」，
    免得下一次又有人照着删。
    推广形式：**规范是意图的记录，不是事实的记录**。
    照着规范动手之前，先花十分钟核实它描述的那个东西**现在**是什么——
    这一步省掉的时间，远少于删错一个功能再恢复的时间。

70. **图标按钮的 `.help()` 是 VoiceOver 标签的唯一来源，不要写两遍。**
    规范 §3.2 写「全部交互控件补 `accessibilityLabel`/`accessibilityValue`
    （当前 0 个，图标按钮只有 `.help()`，VoiceOver 读不到）」。
    核实：`.help()` 20 处，`accessibilityLabel` 只有 2 处。
    两句文案是**同一句话**，各写一份就是这仓库第 N 次「同一份约定抄多处」——
    而两处漂了没人知道（不变量 68 那条通用根因）。
    所以判定抽在 `A11y`（纯函数），视图用 `A11y.label("清空对话")` 与
    `.help("清空对话")` **共用同一字面量**。三态不能糊：
      · **空标签比没标签更糟**。`.accessibilityLabel("")` 会让 VoiceOver 念出一个
        空按钮 —— 控件「存在但无名」，用户完全不知道它是什么。
        所以拿不到文案时给**有意义的兜底**（`fallback:` 链），而不是 `?? ""`。
        ⚠️ 我第一版批量生成时留了 20 处 `?? ""`，与这条判断自相矛盾，已全部清掉。
      · **「读不出来」不许显示成 0**。引擎用 -1 表示读不出来（不变量 33 那一族），
        `A11y.count` 把它说成「读不出来」而不是「0」。
      · 列表项要报「第几项、共几项」，否则用户不知道列表有多长；
        空列表不谎报位置。
    ⚠️ 与搜索同源的一条：搜索框**必须接到过滤后的数组**上。
    只挂 `.searchable` 而 `ForEach` 仍渲染全量 ⇒ 搜索框是摆设，
    而它看起来完全能用 —— 这类「装饰性功能」比没有更坏。
    搜索的两种「空」必须分开说：**「没匹配上」与「本来就没有」**，
    前者要回显查询词（用户才知道自己搜了什么）。
    过滤生效时报「匹配 x / y」，否则 12 条里只列 3 条会被读成「就这 3 个」
    —— 这与 #206/#207 那族「静默截断」是同一条轴。

71. **判据要卡「随输入变化」，不是卡「碰巧包含某个词」。**
    这是 NC66 唯一一条没被负控抓住的判据，抓它的过程比抓到它更有价值。
    原来的判据是：
    ```swift
    let text = SearchFilter.emptyText(reason!, noun: "项目")
    guard text.contains("zzz") else { throw fail("没回显查询词") }
    ```
    注入把文案改成 `匹配「X」`（**去掉了 query 插值**），判据却仍绿 ——
    因为 `text` 是拿 `noMatch(query: "zzz")` 生成的，`zzz` 仍在**传入的参数**里，
    而 `contains("zzz")` 命中的是**别处**残留的同名词。
    换句话说：那条判据验证的是「文串里碰巧有这个字」，
    不是「文案真的把用户的查询回显出来了」。
    改成：
    ```swift
    let a = emptyText(.noMatch(query: "zzz"), noun: "项目")
    let b = emptyText(.noMatch(query: "qqq"), noun: "项目")
    guard a != b, a.contains("zzz"), b.contains("qqq") else { … }
    ```
    —— **换个输入，输出必须跟着换**。这才是「回显」的实质。
    推广形式：验证「某信息被带出去了」的判据，要问
    「**换一个值，这条输出会变吗**」。不变 ⇒ 它根本没带这个信息，
    只是碰巧同名。这是与不变量 68（判据要卡实质而非现象）配套的一条：
      · 68 讲的是「别用两个同义信号之一」——
        `contains(A) || contains(B)` 里删掉 B、A 还在，判据就假绿。
      · 71 讲的是「别用与输入无关的固定串」——
        文案里有个同名词就恒真。

    ⚠️ 配套的一条实操教训：给含 Swift 插值（`\(x)`）的源码做 perl 注入，
    **反斜杠层数极易错** —— bash 单引号里 `\\(` 传给 perl 是两个反斜杠
    （匹配「转义反斜杠 + 裸括号」），而源码要的是一个。
    这次在同一条上耗了好几轮，症状是 `Unmatched ( in regex` 与「文件没变」。
    两个绕法：
      · **锚点选不含插值的字面量**（`匹配 `、`读不出来"`）——
        点号在正则里本来就能匹配任意字符，**不需要转义**（我一开始转义了，纯属多余）
      · 实在要匹配插值就用 **python 做字符串替换**（`inject_py`），
        `str.replace` 没有正则层数问题
    记这条是因为：反反复复失败的那几轮，看起来像「判据有问题」，
    实际是注入没打中 —— 而这两种误判会导致完全相反的修法。

72. **快捷键必须集中声明，因为撞键是编译期看不见的缺陷。**
    规范 §3.2 列了一串快捷键（⌘R / ⇧⌘U / ⌥⇧⌘D / ⌘1–⌘5 / ⌘F / ⌘, / ⌘W）。
    散着写 `.keyboardShortcut` 的三个问题，第三个最隐蔽：
      · **撞键不会编译失败**，也不会警告 —— 后声明的那个永远不触发，
        而用户看到的是「我按了没反应」
      · 修饰符漏写一个（`[.command]` 写成 `[.command, .shift]` 的反面）
        同样不报错，只是静默少一个键
      · 规范说的视图数会过期，见下面那条
    所以 `ShortcutMap.swift` 是唯一声明处，**刻意零 SwiftUI 依赖**，
    `duplicatePairs()` 能在测试里算出撞键对。
    `ShortcutKey.swift` 单独做 `KeyEquivalent` / `EventModifiers` 的换算 ——
    混进 `ShortcutMap` 会把「可断言的纯函数层」和「视图层」搅在一起
    （与 `DesignTokens` / `DesignSystem` 同一分层原则）。
    两条容易踩的：
      · `KeyEquivalent` 收的是 **Character 不是 String**，
        而 `EventModifiers` 是 OptionSet —— 手写 `[.command, .shift]` 漏一个就静默失效
      · 空键位兜底要给 `"\u{0}"`（匹配不到任何真实键），
        给 `""` 编译器不会拦你

    ⚠️ **规范写的「⌘1–⌘5」是按它设想的五个固定视图写的，实际不是。**
    侧栏只有**三个**固定入口（总览 / 看板 / 里程碑），
    项目详情是**动态**的（N 个项目 ⇒ N 个入口，没有「第 4 个」）。
    照抄就会有两个按了没反应的键（⌘4 ⌘5）。
    现在的分法：⌘1–⌘3 对三个固定视图，⌘4 给「打开当前选中的项目」，
    **没有 ⌘5**。`ShortcutMap.view(at:)` 越界返回 nil，
    判据钉死了「不许硬凑」—— 与不变量 69 是同一根：
    **规范的数字要对着现状核实**。

    ⚠️ **⌘F 要能用，搜索框就不能用系统的 `.searchable`。**
    那个搜索栏**不接受外部 focus 绑定**，`@FocusState` 送不进去 ——
    ⌘F 存在但按了没反应，比没有更坏。
    所以侧栏改成自建 `TextField` + `.focused($searchFocused)`
    （`AgentView` 的输入框一直是自建的，同一条路）。
    判据里同时钉住「有 focus 绑定」与「不许出现 `.searchable(`」——
    后者防的是有人哪天"顺手改回系统的"。

    ⚠️ 负控 NC67-d 抓出的一处**真的漏报**：`ShortcutMap.all` 原本是
    `[7 个动作] + viewOrder.compactMap(…)`，而 `currentProject`
    **刻意不在 `viewOrder` 里**（那是「固定视图」的列表，详情是动态的）——
    于是 ⌘4 从来没进过全表，任何与它撞车的声明都**查不出来**。
    症状极其误导：注入「看板改成 ⌘4」本该与「打开项目详情」撞车，
    判据却绿 —— 看起来像判据坏了，实际是它**够不着那个声明**。
      · 「刻意排除在某个集合之外」的东西，**如果它仍占用外部资源（键位/端口/路径），
        就必须单独进守卫用的集合**。分组的理由不能连带削弱覆盖。
      · 推广：任何「按 A 归类不进 B，但按 C 算」的东西，
        守卫就得按 C 全量枚举，不能沿用 B 的遍历。

73. **判据匹配字面量时，要覆盖它的所有书写形式。**
    NC67-f 抓到的：判据写的是
    ```swift
    for pat in ["keyboardShortcut(\"1\")", …] where pv.contains(pat) { … }
    ```
    只匹配**单参数**写法。而真实代码全是
    `keyboardShortcut("1", modifiers: [.command])` —— **双参数**。
    于是注入了一处写死键位，判据仍绿。
    改成匹配前缀 `keyboardShortcut("1` 就两种写法都盖住。
    推广形式：
      · 匹配字面量时问「**它还有哪些等价写法**」——
        单/双参数、带不带 modifiers、`.keyboardShortcut` vs `keyboardShortcut`
      · 更稳的做法是匹配**结构**（前缀 + 首字符）而不是完整调用：
        `keyboardShortcut("` + 数字，既覆盖参数个数，又不会误伤
        `ShortcutMap.refresh.keyEquivalentSwiftUI` 这种变量形式
    这与不变量 71 是配套的：71 说「别用与输入无关的固定串」，
    73 说「别只覆盖一种写法」——**两条都是「判据够不着它声称的东西」**。

74. **加功能的默认动作不是「新建一个入口」，是「挂在已有入口上」。**
    给视图加快捷键时，我顺手在侧栏另开了一个「视图切换」分组，
    把「总览」里已有的仪表盘 / 看板 / 里程碑**又列了一遍**。
    后果不止是冗余：
      · 两组**不一致** —— 只有「总览」那组带 badge，于是里程碑在两个地方
        显示不同的数字，用户会以为是两个不同的东西
      · 破坏了 §3.1 定的侧栏信息架构（引擎 / 协作 / 智能三分组）
      · 而且测试**抓不到**：原来是数 `RootSection.dashboard` 出现几次，
        改成 `viewShortcut(.dashboard, …)` 之后那个字符串**一次都不出现**，
        判据从「重复 2 次」变成「出现 0 次」—— 红是红了，但**理由完全错了**
    判据改成数**侧栏里声明了几次导航项**（`viewShortcut(.dashboard` 出现几次），
    并且要求恰好 1 次。顺带也修了「看板入口还在不在」那条 ——
    它原来查 `case .board:`，而那个字符串现在出现在一个 `switch` 分支里，
    **一个 switch 分支 ≠ 一个可达入口**。
    推广形式：
      · 改视图结构时，**判据里那些「数某字符串出现几次」的地方要重新核实** ——
        它守的是旧结构的形状，而结构一变它就在数别的东西。
      · 这与不变量 73 是同一族的另一面：73 说判据**覆盖不全**，
        这条说判据**指向错了对象** —— 都会在结构变更后静默失效。

75. **模型里的非可选字段，必须在引擎的每一种输出形状里都存在 —— 包括错误桩。**
    这条是本轮真实踩到的，而且症状与病因隔着三层。
    我给 `ProjectStatus` 补 `overall` / `dirty` 时，把两个子结构的字段
    声明成了非可选（`let summary: String`）。而引擎在**采集失败**时
    是这么发的（`moonGit/src/flow/status.cj:361`）：
    ```json
    "overall": {}, "dirty": {}
    ```
    空对象 ⇒ `Decodable` 抛 `keyNotFound` ⇒
    **整条 `StatusEnvelope` 解不出来**，于是**所有项目**（包括好的那些）
    一起从界面上消失 —— 症状是「应用坏了」，病因是「一个坏项目的两个字段」。
    推广形式：
      · 「一个字段声明错了」的影响范围**不等于**那个字段的字段 ——
        父容器的解码会一起失败。凡是嵌在对象里的，字段一律可缺席，
        展示层再决定「没有」怎么画。
      · 加键时先把**引擎的错误桩**那一路想清楚：
        能在这个项目里出现的一切形状，都必须能解出来。
      · 判据要钉住错误桩本身，别指望别的判据「顺便」抓到它 ——
        本次是【2】组那条「错误桩解码」报出来的，它当时已经存在，
        只是没人往模型里加过非可选字段。

76. **引擎给了、模型收了、界面不说 ⇒ 等于没算。**
    ⚠️ **判定「死代码」前，grep 引用时不要加过滤模式。**
    这次差点删掉 `RepoFacts.toJson()`（126 行，输出 tags / authors /
    commitActivity / fileStats 等 20 个键）：我用
    `grep "\.toJson()" | grep -v 关键词` 找引用，输出被 `head` 截断，
    剩下的两行全落在已排除的关键词里，看起来就是「零调用」。
    换成不带过滤的 `grep -rn "facts.toJson"` 才看见：
    `repo.cj:951` 与 `984` 两个测试在用它守 JSON 形状契约。

    而且它**确实该保留**：`moongit docs` 的深更新会把 commitActivity /
    authors / tags 写进 markdown（客户端文档页能读到），
    改版规范 D5 又把它列为「复活热力图 / 贡献者 / tag 视图的现成资产」。
    生产路径零调用 ≠ 可以删 —— 要问的是「有没有人在等它」。

    Phase 3 地基层补了 13 个引擎键进客户端模型，逐个查视图层引用时发现
    **6 个一个都没渲染**：`tags`、`manifests`、`dirty`、`headSubject`、
    `headDate`、`provider`。引擎为了 `overall.notes` 专门算出了
    「工作区有 2 处未提交改动」，而界面上没有任何地方提「2 处」。
    推广形式：
      · 补数据通路时，**「模型里有这个字段」不算完成**，
        要一路走到「界面上有一行字或一个颜色」。
      · 剩下 7 个键我做了取舍而不是全留：`merged` / `headDate` / `updatedAt`
        与已有字段完全冗余（`headAgo` 已是人话形式、日志卡已覆盖更新时间），
        于是**从模型里删掉** —— 留着就是「收了不说」，
        而模型存在的唯一理由就是最终会说出来。
      · 反过来说，一个键要么有话说，要么不进模型。中间态最坏：
        它看起来像是被支持过了。

77. **同一个判定只能有一个出处；客户端不得复刻引擎的阈值。**
    我在分支卡上写了一句
    `b.staleDays >= 30 ? .orange : .tertiary`，而引擎的档位线是
    **3 天 / 14 天**（`moonGit/src/kernel/progress.cj:30-36`）：
    ```swift
    if (d < 3.0)  { return "active" }
    if (d < 14.0) { return "idle" }
    return "stale"
    ```
    后果不是「颜色略有偏差」，而是**同一张卡片上两个元素说两种话**：
    左边的状态点按引擎的判定显示「停滞」（15 天），
    右边我写的天数按 30 天的线显示成安静的灰色（15 < 30）。
    而 `status` 本来就在 `BranchStatus` 里，引擎已经判完了。
    推广形式：
      · 引擎给了**判定结果**的字段（status / merged / ok），
        客户端**不许**再拿原始数据重算一遍。
      · 只想显示事实（多少天）就用事实（`staleText`），
        想上色就从判定结果取（`DSColor.color(DSStatus.from(b.status))`）——
        事实与判断分开，正好也让这两件事可以被单独测试。
      · 这与不变量 33（-1 三态）是同一族：**同一条事实只允许有一个口径**。

78. **空数组验证不了元素类型；造不出样本时要查源码并把局限写明。**
    `tags` 在没有任何 tag 的沙箱里恒为 `[]`，于是「它是字符串数组还是对象数组」
    根本没法用 CLI 样本验证 —— 而 `overall` 恰恰就是**照想象**写错的
    （我写了 `{summary, notes}`，实测引擎发的是字符串；错误桩发的又是 `{}`）。
    更糟的是 `add` 子命令**只有 `--name`**，压根没有 tags 参数
    ⇒ 非空样本**永远造不出来**。
    推广形式：
      · 用「空数组能通过」的判据去验元素类型，等于没验。
      · 确实造不出样本时，判据要改成**查引擎怎么构造**这个键
        （`tagsArr.add(Json.of(t))`），并在判据文案里写明
        「这是源码级保证，不是解码级保证」—— 让读的人知道这条的边界在哪。

79. **判据在前提不满足时必须红，而不是空跑通过。**
    我给 `manifests` 写的第一版是：
    ```swift
    if all.contains(where: { ($0.manifests?.isEmpty == false) }) {
        return "有 manifests 样本，解得出来"
    }
    // 没有就……什么也不做，直接算过
    ```
    于是它**永远绿**，而它声称要验的东西一次都没验过。
    改成：没有非空样本就**报错**，并且要求沙箱去造一个真的带 `package.json`
    的仓库。改完它第一次跑就是红的 —— 红的正是它该红的原因。
    推广形式：
      · 「样本不满足前提」默认应当是**失败**，不是跳过。
        真要允许跳过，判据文案里必须写明跳过条件。
      · 改判据时顺手问一句：**这条判据在什么样的坏世界上会绿？**
        答不上来的，它大概率就是个摆设。

80. **SwiftUI 的报错位置可能离真凶很远 —— 往上找 ViewBuilder 的边界。**
    这次的编译错误报在
    `DetailViews.swift:358: ForEach(p.branches) { b in` 上：
    ```
    error: cannot convert value of type '[BranchStatus]' to expected argument type 'Range<Int>'
    error: value of type 'Int' has no member 'status'
    ```
    看起来像 `ForEach` 用错了重载、`BranchStatus` 不再 `Identifiable`，
    或者该行被注入弄坏了（于是去查括号配平、`var id` 在不在）。
    真凶在 **413 行**，一个隔了 55 行的三元：
    ```swift
    .foregroundStyle(b.staleDays < 0 ? .tertiary            // HierarchicalShapeStyle
        : (b.staleDays >= 30 ? .orange : .tertiary))        // Color
    ```
    `.tertiary` 与 `.orange` 归不到同一个类型 ⇒ 该 `HStack` 的
    `@ViewBuilder` 变换失败 ⇒ **整个 `ForEach` 表达式的 `Content` 推不出来** ⇒
    重载解析退到 `ForEach(Range<Int>, …)`，`b` 被推成 `Int`。
    推广形式：
      · 看到「重载解析失败」且报错点是个**容器构造表达式**，
        先怀疑它闭包体里的某个子表达式，而不是容器本身。
      · 定位手法是**把闭包体逐块换成最小内容重编译**，
        而不是盯着报错行猜。这次二分到第 3 块就定位了。
      · 同一族：三元表达式里不要混 `Color` 与 `HierarchicalShapeStyle`
        （`.secondary`/`.tertiary` 属于前者，`.orange`/`.blue` 属于后者）——
        需要二选一时先让两边类型一致，比如全部写成 `DSColor.color(...)`。

81. **空数组往往同时表示「还没有」与「确实没有」两件事。**
    把路由/判定的入参写成 `loadedProjects: [String]` 时，
    「启动瞬间还没加载」与「加载完了，项目群真的是空的」都表现为 `[]`。
    用数组空不空去回答「这个项目存不存在」，会同时错两次：
      · 启动瞬间判「不存在」 ⇒ 深链功能**永远失效**（列表总在加载前被问一次）
      · 真·空项目群的用户被判成「列表没加载」 ⇒ 永远不敢说「找不到项目」
    修法是让「加载过没有」成为一个**独立的参数**（`hasLoadedOnce`），
    并让判定返回**三态**而不是两态：
    ```swift
    enum Resolution: Equatable {
        case go(RootSection?)
        case projectNotFound(String)
        case listNotLoaded        // 不知道 ≠ 没有
    }
    ```
    推广：
      · 任何「先问后答」的判定，第一件事是问「**我手上的数据是全的还是空的**」。
      · 把 `nil`（未知）与空集合（已知为空）当成同一个东西，
        是这类缺陷最常见的入口。
      · 这与不变量 33（-1 三态）、75（字段可缺席）是同一族：
        **「不知道」必须能在数据里表达出来。**

82. **命令行开关之间不该有隐藏的依赖关系。**
    旧的深链解析第一行是
    ```swift
    guard args.contains("--open-panel") || args.contains("--open-settings") else { return }
    ```
    于是 `--project foo` **单独使用会被静默忽略** —— 而主面板本来就是
    「启动自动打开」的，也就是说从命令行传深链必须额外记住加一个
    无关的 `--open-panel`，少加了没有任何提示。
    复现：`deepDolphin.app --project target` ⇒ selection 停在默认的 `.dashboard`。
    推广：
      · 解析函数里**不要用一个开关当另一个开关的前置条件**，
        除非它们在语义上真的有依赖。
      · 这类缺陷没法靠读代码看出来，因为那行 `guard` 看着很合理 ——
        只有**真的敲一次命令**才会发现。所以启动参数必须**可单测**：
        抽成纯函数（`Route.parse(_ args: [String])`），
        判据直接喂 `["deepDolphin", "--project", "target"]`。
      · 顺带：参数值本身可能是另一个 flag（`--project --open-panel`）。
        把 `--` 开头的值当名字，就会去加载一个叫「--open-panel」的项目 ——
        而那正好会撞上下一个缺陷（永远转圈）。

83. **「还在做」与「做不成」在界面上必须有两种样子。**
    `ProjectDetailView` 原来只有两个分支：
    ```swift
    if let p = project { content(p) } else { ProgressView("加载 \(projectName) …") }
    ```
    而项目**根本不存在**时 `project` 永远是 nil ⇒ 主区**永远转圈**，
    既不报错也不停 —— 用户会一直等一个不会来的结果。
    这与不变量 33 同源：把「做不到」渲染成「还在做」。
    修法有两条，缺一不可：
      · 失败原因要**落到能显示它的地方**：只有全局 `lastError` 不够，
        详情页得能按项目名查到（`projectLoadErrors[name]`），
        且**成功一次要清掉**旧的失败，否则项目修好了红色标记还在。
      · 空态分支必须先问「有没有失败原因」，再决定画转圈还是画错误态。

84. **两个不同的失败不要挤进同一个字段。**
    我把「深链指向的项目不存在」报成 `lastError`，看起来对，其实是接上了
    旁边那条短路：
    ```swift
    // runRefreshAll
    if lastError != nil { isLoading = false; return }   // 刷新失败了，别再等 dashboard/milestones
    ```
    ⇒ **一次打错的深链会掐断整个启动刷新**，症状是仪表盘一片空白，
    比原问题更难查。已拆成独立的 `routeNotice`（说明）与 `lastError`（失败）。
    推广：
      · 加一个状态字段前先问「**还有谁会读它**」——
        `lastError` 的读者里有一个带 `return` 的短路，加字段前必须看清。
      · 「说明」与「错误」不是一回事：说明该被忽略或继续显示，
        错误该触发降级路径。
      · 与不变量 33 配套：那三个 -1 之所以能被渲染成 0，
        正是因为「读不出来」和「就是 0」共用了一个数字。

85. **判据里的源码切片必须有界。**
    判「某个分支不许写 lastError」时，我一开始写成
    `m.components(separatedBy: "case .projectNotFound").last ?? ""` ——
    `.last` 取的是**从该串到文件末尾**的整段，于是把几百行之后
    `loadProject` 里那个**合法**的 `lastError = msg` 也算进来 ⇒ 假红。
    判据红了，而代码是对的 —— 这种假红比没有判据更费时间。
    推广：
      · 判据要卡的必须是**局部**事实，就用 `slice(s, from:to:)` 划出那一段，
        并在找不到边界时**报错**（说明判据已经对不上代码的位置）。
      · 凡是「在某处不许出现 X」的判据，先确认切片**不会越界**。
        与不变量 74（判据指向错对象）是同一族：73 说覆盖不全，
        74 说指向错对象，这条说**范围搞大了**。

86. **照抄设计稿之前，先核对它引用的文件名是不是真的。**
    设计稿的深更新按钮上印着「AGENT.md + README」。照抄进客户端就会告诉用户
    moonGit 会改一个叫 `AGENT.md` 的文件 —— 而引擎托管的是
    **README / AGENTS / CLAUDE**（无 `.md`）。
    这不是细节：这是**动手前告诉用户会改哪几个文件**的那句话，
    写错一个文件名，用户按下去之后在文件系统里找不到它，
    于是要么以为被改了不该改的，要么以为没生效。
    推广：
      · 从设计稿抄文案/文件名时，逐个去引擎或磁盘上核实存在性。
      · 设计稿是**视觉稿**，它不知道你的实现细节；凡涉及真实文件名、
        真实命令、真实键名的，一律以引擎为准。
      · 与不变量 75 是同一族：一个字段/文件名说错了，
        错的代价落在用户的真实数据上。

87. **规范里的结构描述可能是二手转述 —— 结构问题以设计稿原文为准。**
    §3.1 写了一张侧栏分组表（引擎 / 协作 / 智能三组，各挂哪些视图）。
    去翻设计稿原文 `docs/gitpulse_ai_workspace.html`，它的侧栏是：
    ```
    双轨协同管道 | 双轨指挥中心 | 变动管道 & Diff 萃取 | AGENT.md 记忆治理
    | Rule Matrix | 动态 README & Release | Git 结构与进度分析
    | 全量 Git 历史进度大盘 | 跨仓库依赖拓扑 | 双轨提交与 AI 审计日志
    ```
    —— **根本没有那三个分组**，也没有「文档」「助手」这两个独立视图
    （文档在项目详情里平铺，助手是 sheet）。
    照那张表实现会造出两个点进去什么都没有的壳子入口。
    推广：
      · 规范是**意图的记录**；当它描述的是**结构**时，去设计稿原文核对。
        本项目已经因此躲过三次：看板是不是死代码（不是）、
        `MarkdownView` 是不是每帧重解析（不是）、固定视图是 3 个还是 5 个（3 个）。
      · 规范里凡是「照着做会新建入口」的表格，先问一句
        「这些视图在客户端里真的存在吗」——不存在的那些是规范作者的想象。
      · 与不变量 69 同源：规范的**前提**也会过期。

88. **快捷键「声明了」不等于「绑上了」。**
    `ShortcutMap.deep`（⌥⇧⌘D 深更新）在表里、冲突检查把它算进去、
    `ShortcutMap.all` 也把它列出来 —— 但整个客户端**没有任何一处**
    `.keyboardShortcut` 用它。于是 §3.2 写的「⌥⇧⌘D 深更新」
    是一个**不存在的功能**，而所有针对快捷键表的检查全绿。
    推广：
      · 快捷键的判据必须有一条「**声明的每个键位都真的被绑定**」，
        光查冲突等于查一张没人读的表。
      · 同一个动作在 toolbar 按钮和 CommandMenu 各有一份是**正常的**
        （macOS 惯例），但两份**必须调同一个入口** ——
        否则迟早一个改了范围语义、另一个没改。
      · 快捷键优先挂在 CommandMenu 上：toolbar 按钮上的
        `.keyboardShortcut` 虽然合法，但那是另一套分发路径，不拿它赌。
      · 与不变量 74 同族：判据查的是「表里有没有这一行」，
        而用户要的是「按下去有没有反应」。

89. **画一个拿不到的数字，比不画更糟。**
    设计稿的浅更新按钮带一个「待记录 N」徽章，我照抄了，然后才去问
    「这个 N 从哪来」。答案是：**这个架构里它恒为 0**。
      · 引擎只在 `update` 运行期间算这个数（`flow/update.cj:652`），
        而且算完立刻归零：本次有提交的分支走 `:591` 被写成 0；
        没新提交的分支实时数一遍 `${head}..${name}`，自然是 0。
      · 引擎自己的注释早就写着这件事
        （`flow/dashboard.cj:205`：「该字段在刚跑过 update 的分支上恒为 0」），
        而且**正因为这句话**，dashboard 才把 `mergeCandidates`
        从 `pendingCommits` 换成了 `aheadOfDefault`。
    实测印证：建好基线后再提交 3 个提交，`status` 仍报 `pendingCommits=0`。
    推广：
      · **照抄设计稿的每个数字之前，先追到它的数据源**，
        并问「这个数字在什么情况下会变」。恒定的数字不是数据，是装饰。
      · 一个只会「亮不起来」的徽章，比没有徽章更糟：
        它让用户等一个不会来的数字，久了整个按钮区都变得不可信。
      · 不要拿**另一个**口径的数字来填它（这里最容易顺手写成
        `aheadOfDefault`）—— 那是「待记录」与「可合并」两件事混成一件
        （见不变量 77：同一条事实只允许有一个口径）。
      · 与不变量 76 是同一枚硬币的两面：76 说「引擎给了、界面不说 ⇒ 等于没算」，
        这条说「**引擎没给真数、界面不许画**」。
      · 顺带：同一条数据源让分支卡上的「N 待记录」也成了死 UI。
        它是既有元素、且在少数边界情况下可能非 0，所以没删 ——
        但**新代码不许再吃这个字段**。判据已把这件事钉住，
        下次谁照着设计稿加回来会红。

90. **「换掉用法」不等于「数据活了」。**
    `pendingCommits` 恒为 0 这件事，引擎在 `flow/dashboard.cj` 里早就知道了，
    当时的修法是**把 `mergeCandidates` 改用 `aheadOfDefault`**。
    那个修法是对的（它修好了 dashboard），但它只换了**用法**，
    数据本身仍然是死的 —— 于是下一个要用这个字段的人（我）照抄设计稿，
    又一次画了一个永远不亮的徽章。
    推广：
      · 发现「某个字段不可信」时，先问「**谁已经绕开它了，为什么**」。
        绕开的地方通常就写着原因（本例：`dashboard.cj:205` 的注释）。
      · 绕过 ≠ 修复。要么把数据修活，要么明确写下「这个字段不许再用」。
      · 判据要钉在**数据源**上，不是钉在「用法」上：
        本例的判据是「status 必须报实时值」（引擎回归测试 + 契约测试），
        而不是「徽章不许画」—— 后者只会逼着人换个写法接着画。
      · 与不变量 89 是同一件事的两半：89 说别画拿不到的数字，
        这条说拿不到的时候要**去把它变成拿得到的**。

91. **负控改了引擎源码并重建之后，还原时必须重建回去。**
    注入 `pendingCommits` 的旧实现时重建了一次引擎，于是
    `moonGit/target/release/bin/main` 变成了**注入版**。
    还原源码（sha 核对通过）之后我没重建二进制 ——
    下一轮契约检查就挂了 1 条，原因是「引擎报的值对不上」，
    与它声称的判据（徽章的数据源）**完全无关**。
    这种「因为对不上而红」和「因为缺陷而红」混在一起时，
    人会去改代码，而真正该改的是构建产物。
    推广：
      · 负控的还原纪律要覆盖**所有派生产物**：源码改了会带出二进制、
        会带出生成文件、可能带出缓存。只还原源码不算还原。
      · 契约检查开头会打印「用的是哪个引擎构建产物」——
        那条提示本来就在，只是这次没人把它和「源码已还原」联系起来。
      · 与不变量 79（判据在前提不满足时必须红）是同一族的反面：
        那条讲「空跑通过」，这条讲「跑了，但跑的不是你以为的那个东西」。

92. **「还在读」与「读不出来」必须画成两种样子。**
    `DashboardView` 原来是
    ```swift
    if let d = model.dashboard { … } else { ProgressView("汇总项目群…") }
    ```
    采集失败时 `dashboard` 永远是 nil ⇒ **主区永远转圈**，既不报错也不停。
    更糟的是错误横幅同时挂在 PanelView 顶部 ——
    用户同时看到「一条报错」和「一个永不停歇的加载中」，两句话互相矛盾。
    里程碑是同一族：读取失败与「真的还没有里程碑」渲染成同一句话，
    于是用户以为是自己还没建，于是一直不去建。
    推广：
      · 「`nil` ⇒ 转圈」这个写法只在**真的不会失败**时成立。
        会失败的数据源必须单独记一份加载结果（`LoadState`），
        至少能区分 idle / loading / loaded / failed。
      · 「失败了但还有上一次的旧数据」是最难处理的一种：
        显示旧数据 = 拿陈旧数据冒充这次的结果；只显示错误 = 用户失去参照。
        本项目的取法是**显示失败**，把旧数据留给下一次成功覆盖。
      · 判据要卡**接线**而不只是卡判定函数存在：
        `fetchDashboard` 失败时必须写 `dashboardState = .failed(...)`，
        视图必须读它 —— 少任何一半，缺陷都还在。

93. **一个全局错误字段回答不了「某个数据源读失败了吗」。**
    `lastError` 是全局的：git 操作失败、深链打错字、扫描失败、批量更新出错
    都会写它。拿它判断「仪表盘读不出来了吗」，
    会把别的操作的错误算到仪表盘头上；反过来仪表盘失败也会让别处以为是自己错了。
    推广：
      · 每个数据源要有自己的一份加载结果，别共用一个错误字符串。
      · 这与不变量 81（空数组的两种含义）是同一族：
        「一个字段同时表示多件事」在数据层和在状态层的后果一样 ——
        接收方无法判断该信多少。
      · 也与不变量 84 配套：那里说「两个失败别挤一个字段」，
        这条说「不同数据源的失败也不该挤」。

94. **Swift 陷阱：计算属性不带参数。**
    写 `var phase(hasContent: Bool) -> LoadPhase { … }` 会报
    ```
    error: consecutive declarations on a line must be separated by ';'
    error: type annotation missing in pattern
    ```
    报错完全指不到真正的位置（列号落在参数名中间），
    看起来像「上一行缺了个分号」或「模式写错了」。
    带参数的只能是方法：`func phase(hasContent: Bool) -> LoadPhase`。
    推广：
      · 看到 `consecutive declarations … ';'` 而上一行没问题时，
        **二分**一下签名：把 `var` 换成 `func` 试一次（本次二分第二轮就中）。
      · 仓颉那边也有同族陷阱（枚举不支持 `==`、`init` 不支持默认值），
        两边的报错都不指位置，所以「二分」比「盯着报错猜」靠谱。

95. **「空集合分支什么都不画」= 把「读不出来」和「确实没有」并成了一个出口。**
    `if let xs = model.map[k], !xs.isEmpty { 画卡片 }` 这种写法**没有 else**：
    分支不成立时什么都不画。于是三种情况共用同一个空画面 ——
    正在读、读不出来（引擎失败/超时/权限）、真的没有。
    用户看到空白会合理地推断「没有」，而真相可能是前两者。

    本项目在这个模式上栽了**三次**，三处表现完全一样：
      · 仪表盘 `if let d = model.dashboard { … } else { ProgressView }`
        → 采集失败时主区永远转圈（不变量 92）
      · 里程碑 `SearchFilter.emptyReason(…)`
        → 「读取失败」被渲染成「还没有里程碑」（不变量 81）
      · 文档区 `if let docs = …, !docs.isEmpty { … }`
        → 「读不出来」被说成「这个项目没有 README」

    推广：
      · 凡是从字典/数组取数据再判 `isEmpty`，一律要求**四个出口各有一句自己的话**，
        不许留空出口。宁可多画一个「读不出来」的卡片，也不要给用户留白让他猜。
      · 判定放进纯函数层（`LoadState.phase(hasContent:)`），视图只 switch ——
        这样判据能 lint「四态齐不齐」，而不是靠人眼看。
      · ⚠️ 光有四个 case **不够**。`case .empty` 与 `case .failed` 都不画主体时，
        措辞一混就等于没改。所以判据查的是**措辞不同**（"读不出来" vs "还没有受管的文档"），
        不是「case 齐」——「case 齐」是上一轮的判据，它绿过而缺陷还在。
      · 与不变量 92 配套：92 说「读与失败要两种样子」，
        这条补上「失败与没有也要两种样子」——三者两两之间都得能分辨。

96. **token 化分两步：等值替换是修缺陷，值收敛是改布局。**
    把 `spacing: 8` 改成 `spacing: DSSpacing.sm`（数值相同、来源不同）
    是**修缺陷**：`8` 与 `sm` 是两个真相源，改 `DSSpacing` 时前者不跟着动。
    这是不变量 77（同一个判定只能有一个出处）在视觉层的版本。

    但把 `spacing: 14` 收成 `lg(16)` 是**改布局**，不是重构。
    14→16 挤不挤、10 该变 8 还是 12，只有看着屏幕才知道。
    **在没做过视觉验证的项目里擅自做值收敛，等于把猜测写进布局。**

    推广：
      · token 化按两步走：① 等值替换（零视觉变化，随时可做）
        ② 值收敛（改变视觉，必须先有人看过窗口）。
        两步不要混在一个 commit 里 —— 混了就分不清哪处变化是「意图」哪处是「意外」。
      · 判据也要分开卡：等值替换后卡「刻度值字面量 = 0」，
        值收敛卡「散值基线不许增长」并把基线数字写进判据。
        这样「还有 51 处没收敛」是**被如实记账的状态**，不是假装做完。
      · 同族：颜色、圆角、字重都适用。
        （圆角已全部归一，因为 DSRadius 的 3 档刚好覆盖了原有取值；
        颜色的两套调色板是**语义**冲突，见不变量 97。）

97. **同一个视觉线索（颜色序号）必须在全局指向同一个含义。**
    改版规范 §3.3 点名的「两套调色板」——提交构成 12 色 vs 语言分布 9 色，
    蓝色在一张卡里是 feat、在另一张卡里是 Swift —— **至今还活着**，
    而且根因不是「作者抄了两份字面量」这么表面：

      `commitTypeColor(_:)` 当时是 `ProjectDetailView` 的**私有方法**。
      语言分布卡住在 `DashboardView` 里，够不着它，于是只能自己内联 8 色。
      ⇒ **映射藏在某个 View 的 private 里，就是「必然出现第二套色板」的成因。**

    推广：
      · token 的**映射**（序号 → 颜色）必须放在所有用它的 View 都看得见的地方
        （视图层共享，如 `DSColor.sequence`），不能是某个 View 的 private。
        色板**序列**可以留在纯函数层（`CommitTypeColor.palette`，可单测），
        映射必须在视图层（`Color` 属于 SwiftUI，纯函数层不许 import）。
      · ⚠️ 判据「这个卡片用没用色板」是**现象**，不是实质。
        只要函数体里**出现过一次** `CommitTypeColor.palette` 就绿，
        把另一处硬编码成 `Color.blue` 完全查不出来 ——
        NC76 变体 2 实测假绿过一次。**必须逐处查**（分段条 / 图例各算一处）。
      · 同一处替换要配多个负控变体：变体注入若不精确到目标位置，
        判据就会因为「注入根本没碰到它检查的东西」而假绿 ——
        `replace(x, 1)` 替换的是**文件里第一处**，不是你想改的那处。
      · 与不变量 77 同族：又一个「唯一出处」问题，这回在视觉层。

98. **值收敛了 ≠ 收敛了 —— 每个视觉属性都有第二个维度。**
    圆角的**值**早就收敛到 `DSRadius` 三档了（§3.3 明确要求的），判据也一直在盯
    「不许散值复活」。但 9 处 `RoundedRectangle` 里只有 `surface` 内部写了
    `style: .continuous`，其余 8 处是默认 **circular** ——
    于是同一张 Card（continuous）里嵌着的 Chip / 描边 / 彩色底（circular）
    圆角**接缝对不上**。值对了，风格分叉，判据一条都不红。

    推广：
      · 收敛一个视觉属性时把它的维度列全：**值 / 风格 / 语义 / 状态**。
        只查值是最容易的一种查法，也最容易给人「已经收干净了」的错觉。
      · 判据卡在**唯一构造点**上（「全库只许有一处 `RoundedRectangle`」），
        不要逐个用法检查 —— 逐个检查既会漏，新增时也没人记得回来加。
        唯一构造点顺带治好了「新增时无感」：冒出第二处就红。
      · ⚠️ 唯一构造点要返回**具体类型**（`RoundedRectangle`）而不是 `some View`：
        不透明类型进 `.overlay { }` 这类 ViewBuilder 后，编译器会崩在
        `failed to produce diagnostic for expression`，
        那不是语法错误，它自己都推导不出来 ⇒ 报错完全指不到真正的原因。
      · 语义着色的表面**不要并进中性 token**：`tinted(.red.opacity(0.08))`
        里的红是「出错」这条信息，抹成中性 surface 就把「读不出来」和
        「确实没有」画成同一张卡了（不变量 81）。
        它的参数必须是泛型 `ShapeStyle` 而不是 `Color` ——
        `.quaternary` / `.secondary` 是 `HierarchicalShapeStyle`，
        写死 `Color` 会逼调用方把层级色硬转，白丢一层语义。

99. **「声明存在」有三层：名字在 ≠ 被调用 ≠ 真的生效。**
    给 Dock 菜单写判据时连栽**三次假绿**，三次都是「我以为查了，其实没查」：

      1. `code.contains("applicationDockMenu")`
         → 注入把函数体换成 `{ nil }`，函数名还在，照样绿。
      2. `code.contains("buildDockMenu()")`
         → **函数定义本身** `private func buildDockMenu() -> NSMenu?` 就含
         `buildDockMenu()` 这个子串。查「有没有调用」却分不清「定义」和「调用」。
      3. `slice(from: "func applicationDockMenu(", to: "\n    }\n")`
         → 目标函数被压成单行时找不到结束标记，切片一路跨到下一个函数，
         把别处的**定义**又吃了进来 —— 第 2 条的坑换个形式复发。

    最后靠**按行取「声明的下一行」**才真正抓住：那是函数体第一行，
    不可能是别处的定义。

    推广：
      · 查「真的被调用了吗」：**不要靠子串，也不要靠花括号配平**。
        子串分不清定义与调用；配平遇到单行函数体就跨界。
        取「声明行的下一行」最简单也最稳。
      · 一条判据里有多条 guard 时，**按严重程度排序**。
        第一版把「不许绕过确认」放在最后，于是注入「直接开跑」时先撞上
        「没走 requestBulkUpdate」抛了 —— 缺陷抓到了，但报的理由不是最严重的。
      · ⚠️ 负控的价值一半在「红」，另一半在「红的原因与它声称的判据一致」。
        本条里的三次假绿 + 一次理由错位，全靠后一半抓出来。
        看到判据红，先问「它红的原因是我以为的那个吗」，别急着收工。
      · 与不变量 88（声明 ≠ 绑定）同族，这次在「文档 ↔ 实现 ↔ 判据」三层各栽一次：
        README 声明了一个不存在的 Dock 菜单（文档层）、
        判据只查函数名（判据层）、
        `NSMenuItem.target` 留空则灰着点不动（实现层）。

100. **自动化视觉验证有边界：能用它排除，不能用它确诊。**
    连续三轮挂着「视觉未验证，只能靠人眼」这个待办，直到写了个离屏渲染
    harness（`deepDolphin/macos/scripts/render-harness/`）把真实视图渲成 PNG。
    它确实把一批问题从盲区里拿了出来（三态文案、EmptyState、卡片圆角接缝、
    分段条配色、spacing 等值替换后的观感），但**它自己也会撒谎**。

    实测出来的离屏限制（每条都做过对照实验）：
      · `ImageRenderer` 渲染 `NavigationSplitView` 只得到一张黄底红斜杠的
        **「禁止」占位图** —— 极易被当成「界面画成这样」。
      · `NavigationSplitView` 的侧栏与路由不参与离屏布局。
      · 视图带 `.task` 取数副作用时（仪表盘），快照会截到中间态。
      · **按钮文字**：header 位置的按钮只画得出空白底。
      · **文字行距**：个别文字行会重叠。

    推广：
      · 离屏下看到异常，**先做一次能证伪的对照实验再下结论**。
        只改一个变量、其它不动，改完现象不变 ⇒ 排除这个原因。
        本轮两次都靠它避免了大错：
        「文字重叠」改 `spacing: 6`→`8` 重叠依旧 ⇒ 不是间距问题；
        「按钮白框」改成 `Label` 之后依旧 ⇒ 不是 label 结构问题。
        若省掉这两次，就会「把 artifact 当产品缺陷去修」，或反过来
        「把真缺陷当 artifact 放过」—— 两个方向都是错的。
      · 对照实验的改动**要能回退**（先备份再改），别为了验证留下半个改动。
      · 等待点要在**视图创建之后**，等的条件要与**视图的判定同源**
        （视图读 `dashboardState` 就等它，别等 `dashboard != nil`）。
      · harness 静默退出/超时要**显式报出来**。我第一版多写了一个
        「无论如何都 signal」的兜底，于是渲染没做完就 `exit(1)` ——
        退出码 1 看不出是超时还是崩，排查时容易误判成「这视图不支持离屏」。
      · 仍然需要人眼的：窗口 chrome 的拖拽/缩放、动画、真实交互、真实光标。
        这些**照实说**，不要因为「大部分能自动验了」就含糊过去。
        （toolbar 不在此列：造一个**不上屏**的 NSWindow 拍它的 theme frame 就能拍到，
          见下一条。）

101. **「这条路走不通」的结论，必须与产生它的那个改动解绑。**
    离屏 harness 曾留下一条结论：「造窗口 `orderFront` 会 SIGSEGV ⇒ 整窗渲染不可行
    ⇒ toolbar 只能人眼看」。于是「顶栏双轨按钮在 1100 宽下挤不挤」被挂成永久待办。

    **那条结论是假的。** 那次崩溃根本不是 `orderFront` 造成的 ——
    是本文件自己一个无限递归的 `log()`（函数体写成了调用自己）打出来的栈溢出，
    而它恰好和整窗渲染的实验落在**同一批未提交改动**里，
    于是我把自己打崩的证据记成了环境的锅，还顺手把一条能走的路标成死路。

    修掉递归之后的实测：窗口**能建**（只要不上屏）、theme frame **能拍**、
    侧栏 + 顶栏 + 主区**一次拍全**。据此拿掉了一个挂了很久的待办。

    推广：
      · 写下「放弃某条路」之前，先问一句：**这次失败的原因，真的属于这条路吗？**
        同一批改动里若有别的可疑点（尤其是没验证过的重构），先排除它再下结论。
      · **别让一条结论和一个自己都还没跑绿过的改动同生共死** ——
        一次崩溃只说明「这次没成」，不说明「这条路没有」。
      · 与不变量 100 同族但方向相反：100 说「自动化看到的东西要先证伪再下结论」，
        101 说「自动化失败的原因也要先证伪再下结论」。
        两边都指向同一件事 —— **结论要有独立的支撑，不能蹭别人的证据**。
      · 发现自己写的注释/文档里有假结论时，**改掉并把推翻过程留在原处**。
        只删掉不改写，等于让下一个人重新踩一遍同样的坑。

102. **判据的「覆盖面」本身也是产物，要单独核一次。**
    §3.3 把 45 处 spacing 刻度值换成 `DSSpacing` token 之后，
    判据写的是「spacing 刻度值必须走 token」，而它的正则是
    `spacing: (\d+)` —— **只匹配 Stack 的 `spacing:` 参数**。
    `.padding(.edge, N)` 与 `.padding(N)` 两种拼法根本不在视野里。

    于是那句「刻度值零字面量」**只覆盖了一半的代码**。实测漏网 **28 处**
    （18 处 `.padding(.edge,N)` + 10 处 `.padding(N)`），其中 **11 处在
    BarView.swift** —— 恰好是计划书 D8 点名的「重复渲染」那个文件。
    另有 5 档散值（1 发丝线 / 11 / 18 / 30 / 40）从来没被计入基线，
    所以基线 51 那个数也是漏算的。

    推广：
      · 判据通过了 ≠ 判据在查你以为的东西。**每加一条判据，都要问一句
        「这个属性在代码里还有几种拼法，我全查了吗」**。本例是三种。
      · **基线数字也要复核来源**。51 是「当前被看见的散值数」，
        不是「实际散值数」；覆盖面一变，基线必须跟着重算并说明理由。
        本轮 51→87 是**判据修好之后才第一次看见的**，不是新增违规。
      · 补覆盖面时**不要顺手豁免新发现的值**。1/11/18/30/40 如实进 pending
        并计数 —— 豁免掉等于「让判据迁就代码」，下一个人再也看不见它们。
      · 两种拼法各自的负控要分开做（NC81 做了 5 个变体），因为
        「查得到其中一种」和「两种都查得到」是两回事。
        还要有一条**该绿的场景**（pending 散值总数不变时必须绿），
        否则「什么都在红」的判据也满足「能红」，但没有区分力。
      · 与不变量 99（声明存在 ≠ 真的生效）、
        不变量 101（放弃理由不能蹭别人证据）同族：
        **99 查的是「声明有没有被调用」，102 查的是「判据有没有把话说全」**。

103. **领域规则散在多个视图里 = 必然会分叉，与重复渲染多少无关。**
    计划书 D8 问「BarView 菜单栏弹窗与主面板重复约 60% 内容，要不要收敛」。
    真去量之后发现的**不是**「重复太多」，而是：
    **`branches.first { $0.isCurrent } ?? branches.first` 这条规则被抄了三遍** ——
    BarView 一个私有 computed property、BoardView 一个、PanelView 内联在
    `else if` 里且**拼法还不一样**。`ProjectStatus` 模型层压根没有这个属性，
    所以每个需要它的视图都自己推导一遍。

    推广：
      · **判「重复」要判到规则那一层，不是判到视图那一层。**
        「两个界面都画项目行」是表面重复；「两个界面各自决定哪个分支是主分支」
        才是会分叉的那种 —— 而它俩常常同屏，用户会以为是两个不同的真相。
      · 抄三遍还能编译过、判据也全绿，因为**没有任何东西在卡「规则只许有一处」**。
        这与不变量 97（映射不能藏在某个 View 的 private 里）同源，
        补法也一样：**规则下沉到模型/纯函数层，视图只消费**。
      · 命名要避开同名不同义。`ProjectStatus.currentBranch` 已经是引擎给的
        **分支名字符串**，所以派生出来的那个叫 `primaryBranch`。
        两个同名不同义的东西并排放在一个类型上，读代码的人得停下来想一秒。
      · **行为断言要用真数据，不要造数据。** 这里用真实 `status --json` fixture，
        并且做了一次**交叉验证**：客户端选出的 `primaryBranch.name` 必须等于
        引擎自己声明的 `currentBranch` 字符串。等于「引擎说的」与「客户端选的」
        是同一个分支 —— 客户端从没读那个字段就自己挑一条，两边迟早对不上。
      · 放行规则要**窄**且**有证据**：`if b.isCurrent`（要不要标「当前」徽标）
        与「挑哪一条当主分支」是两个问题，前者放行后者拦。
        负控里必须有一条证明放行规则不是「谁来都放行」，也要有一条证明它不是
        模糊匹配（NC82 5/5）。

104. **判据在自己覆盖不到的数据上放行 = 给缺陷发通行证。**
    「近 7 天 / 近 30 天」那条时间窗判据写着：
    ```swift
    if inD30.count == readables.count && inD7.count == readables.count {
        return "\(readables.count) 个项目全新鲜：窗口正确但分不出差异（沙箱数据如此）"
    }
    ```
    看着像体贴，实则是**主动放行**：沙箱里项目全新鲜时，判据什么都验不到却全绿。
    而真缺陷恰好就让判据失效 —— 判定挂在 `primaryBranch?.staleDays` 上，
    `branches` 是**追踪数组**，无远端基线的仓库恒为空，于是每个项目都走
    「没有分支记录 → 保留」⇒ **近 7 天筛不掉任何项目**，控件在任何数据下都是死的。
    判据绿了整个三月，因为沙箱数据恰好落进逃生口。

    推广：
      · **「数据不支持断言」要判红，不是判绿。** 正确写法是让它要求先把数据造出来：
        「分不出差异就是 fixture 不合格，先造一个陈旧项目（`lastCommitAt` 拉到
        30 天前）再验 —— 不许用『数据如此』把自己放过去」。
        这样 fixture 升级和缺陷修复都会被逼到台面上。
      · **造 fixture 时要问「这是真形状吗」。** 加完陈旧仓库才发现
        「无远端 + `branches` 为空 + 只有 `lastCommitAt`」才是真形状，
        而旧判据的样本里**分支记录是非空的** —— 判据验的是它自己造的形状。
      · 与不变量 101 同源：那条是「放弃理由不能蹭别人证据」，
        这条是「通过理由不能蹭数据不足」。

105. **`let x: T? = nil` 的存储属性永远不会被解码 —— 编译器只给一句 warning。**
    Swift 合成的 `init(from:)` 对**带初始值的不可变存储属性直接跳过**：
    ```
    immutable property will not be decoded because it is declared with
    an initial value which cannot be overwritten
    ```
    写 `var` 才是「默认值只作为缺键兜底、解码照常发生」。

    本项目因此白丢 **5 个引擎恒发的键**（`JournalEntry` 四个 +
    `ProjectStatus.lastCommitAt`），而其中 `lastCommitAt` 直接让仪表盘的时间窗筛选
    **在任何数据下都是死控件**（见不变量 104 —— 同一个缺陷的两面）。

    推广：
      · **「声明了字段」≠「解出了字段」。** 要钉的是解码行为，不是源码里有没有这个名字。
      · 原来那条判据是 `m.contains("let commitCountScope:")` —— **按字段点名**，
        而它测的三个字段恰好不是这么写的，于是**另外 4 个死键从头到尾没人看见**。
        判据要从「点名制」改成「**按写法覆盖整族**」：凡 `let x: T? = nil` 一律判红。
      · 同名不同义要防：`ProjectStatus.repoBranchCount` 是**必填**的合法 `let`，
        文件级匹配会把它一起判红（假红）。所以匹配要**限定在结构体切片内**。
      · 与不变量 97（映射不能藏在某个 View 的 private 里）同源：
        隐蔽不是代码写得差，是**没有东西在看它**。

106. **控件在源码里存在、在判据里能测出逻辑、实际永远不触发 —— 三者可以同时成立。**
    两个实例，同一天：
      · `MilestonesView` 把「当前仓库范围」写成
        `if case .project(let n)? = model.selection`。而这个视图**只在**
        `model.selection == .milestones` 时才被渲染（`PanelView` 的 `switch`），
        那个分支**永不成立**。实测选中 atlas 再进里程碑页，3 个仓库照旧全列。
      · 侧栏「里程碑」行上的 `.badge(...)` 让**整行点不动**：`.badge()` 在
        `List(selection:)` 的行上会接管命中测试，点击与选中高亮一起失效，
        而**外观完全正常**、⌘3 也能进。连点 5 次 `selection` 的 didSet 一次未变。

    推广：
      · **「摆而不动」有三种伪装**：① 控件压根没接数据 ② 控件接了但数据源恒为空
        ③ 控件在但命中测试被别的东西吃掉。前两种靠读代码能看出来，**第三种看不出来** ——
        必须真的点一次。
      · **离屏 harness 抓不到这一类**：它不跑命中测试、不执行点击、不加载真实
        `NSToolbar`。所以「离屏能渲染」不是「能用」。
      · 真 app 可以自证（本机 `launchctl managername` = `Aqua`，
        `osascript` + `screencapture -x` + CGEvent 真点击都可用）。
        顺带推翻了一条旧结论：「无 UI session / 需要人眼」**从来没被验证过，是错的**。
      · 关键手法是**看有没有留痕**：`selection` 的 `didSet` 打 NSLog，
        点 5 次数日志行数，比肉眼看高亮可靠得多。

107. **判据要钉语义，不钉写法 —— 但也不能钉到「换个变量名就溜过去」。**
    这轮改判据时在两端各栽了一次：
      · 钉**机制**会误伤正确实现。原来断言
        `w.contains("b.staleDays < 0")`，可实现换了数据源
        （`staleDays` → `lastCommitAt`，因为追踪数组恒空）之后那条断言就红了 ——
        而**那次的实现其实是对的**。改法：钉「读不出来 ⇒ 放行」这个语义，
        以及判定依据是模型层那个**有名字**的派生属性（视图里现算天数就是第二真相源）。
      · 钉**字面量**会漏掉同义替换。只认死变量名（`palette[i % palette.count]`）时，
        改成 `colors[i % colors.count]` 就能溜过去（NC58-b 第一版就因此假绿）。
        改法：钉「这个函数体里不许出现取模」—— 因为那三十行**没有任何一处需要取模**。
    推广：
      · 判据分三层，从上到下越来越稳：**语义**（要什么）＞ **数据流**（怎么接）
        ＞ **字面量**（怎么写）。能用上两层就别只靠第三层。
      · **判据自己也要被判据卡。** 这轮三次被自己的注释触发假红
        （注释里写了 `.badge(`、`status == "stale"`、以及文件里另一处合法同名的
        `model.selection`）。凡是在注释里**解释**某个缺陷的判据，
        必须用 `strippedCode`（剥注释）且**限定结构体切片**，否则下次有人想补充
        说明时就会莫名其妙地红，然后被人「修」掉。
      · **切片边界要跟文件实际的书写顺序走**，用下一个分区标记而不是「下一个函数」：
        中途插进一个新函数，它的函数体会被算进上一个函数的切片里 ——
        本轮就因为插了 `milestoneCard`（含一个 `50%` 字面量）导致取模判据误报。
        报错的是判据的边界、不是代码有缺陷，**两者别混**。
      · 改判据的边界/范围之后，**必须再跑一次负控**证明它还咬得住
        （NC86：注入真取模，确认仍报红）。
      · ⚠️ **切片不含 `to` 标记本身。** 这个细节本轮又栽了一次（NC88 写判据时）：
        把 `to` 设成 catch 体里那句 `return ("", "未生成 AI 简报…")`，
        而要检查的恰恰是**那一句** —— 于是被检查的区间刚好少了它，
        判据对着自己的边界报红。`from`/`to` 是**区间外**的墙，
        想检查墙上的东西就不能拿它当墙。

108. **「全量 / 全部 / 一键」这类词本身就是一个承诺，覆盖必须由代码保证。**
    用户点「一键全量」，买的是「一个不漏」这**一条**。所以：
      · **不许把「跑哪些」委托给概率性组件**（模型、采样、重试策略）。
        模型决定的覆盖 ⇒ 可能少跑一个，而界面照样显示「全量完成」，
        用户没有任何线索发现少了一个 —— 这是最坏的一类失败：**看起来对**。
      · **不许用截断换「快」**：`prefix(n)` / `filter { 可更新 }` 一旦出现，
        「全量」这个词就变成了谎报。实测代价：路径已失效的仓库会被过滤掉，
        而那正是最该被告知「这个仓库更新不了」的那些。
      · 名单**在发起时冻结**。跑到一半刷新了列表，迭代中途换名单会让
        「已注册 N 个」和实际执行的对不上。
      · **一个失败不许中断整批**：第 2 个失败就退出 ⇒「全量」变成「跑到一半」，
        而通知只说「更新完成」。要逐个记账（成功几个 / 失败几个 / 失败的为什么）。

109. **同一份契约只许有一个出处 —— 抄两份必然漂移，而漂移的方向通常是危险的那一侧。**
    本轮的实例：agent 工具循环与「一键全量」各自需要「工具名 → 必填参数」这份清单。
    抄一份的后果不是「多几行代码」，而是**必填校验悄悄失效** ——
    `run_shallow_update` 传空项目名在引擎侧等于「整个项目群」，
    校验一旦失效，一次「更新一个仓库」会静默变成「改写全群」。
    同族：工具名字面量也不许在视图/模型层各写一份，引擎改名后
    失败会表现为「点了没反应」而不是一条能被看见的报错。
    推广：**凡是「两份不一致时，失效方向是不安全的那一侧」的契约，就必须收成一处。**

110. **可选的一层没跑成时必须说出口。**
    凡是「基础动作 + 可选增强」（更新 + AI 简报、采集 + 摘要）的结构：
      · 增强层失败**不许静默**，也不许把整件事报成失败 ——
        基础动作已经做完了，报「失败」会让人以为仓库没被动过。
      · 措辞必须区分三态：**跑成了** / **没跑成（附原因与下一步）** / **跑了但没产出**。
        「没生成」和「生成了空的」在界面上长得一样，不说就等于没发生。
      · 判据只卡「有没有把原因说给用户」，**不卡具体措辞** ——
        改文案不该红，写成空 catch 就该红。
    同族：不可重生成的**事实陈述**不许挂在「重新生成」按钮上 ——
    重新生成一份事实表等于允许「再编一份」。

111. **接口/工具的原始返回值不是界面文案。**
    本轮实例：agent 工具返回的是引擎的完整 JSON
    （`{ok, mode, project, docs:[…], journalEntry:{…}}`），第一版整段塞进结果表格。
    真 app 一跑暴露两件事：
      · **排版**：备份路径很长而表格单元不换行 ⇒ 右侧整段被截断。
        ⇒ 明细一律用**列表**，表格只放真正短且对齐的字段。
      · **信息**：用户唯一需要的是「哪个文档被改了、有没有备份、在哪」，
        而它被埋在 `projectId` / `journalEntry` 这些内部字段里 ——
        原始载荷对用户零意义，却占满整屏。
    修法不是自己写一份措辞，而是**转调项目里已有的那个唯一口径**
    （`updateOutcomeSummary`，为缺陷 #211 写的）。推广：
      · 凡是项目里已经有一处「把 X 说成人话」的地方，**新界面必须调它**，
        不许再写一份 —— 抄两份必然漂移，而漂移的方向通常是漏掉披露
        （备份位置、截断条数、失败原因）。
      · **判据钉「用了那一个口径」+ 反向钉「没有直接取原始返回」**，
        两条都要：只钉前者的话，把 `detail` 改回 `text` 就能溜过去。
        而反向那条**本身**也栽了一次：断言写的是 `detail: text)`（带右括号），
        那正是第一版的**单行**写法；后来为了可读性把构造拆成多行，
        右括号跑到下一行，断言再也匹配不上 ⇒ 改回原始 JSON 判据照样绿。
        **反向断言不要锚在标点上**，锚在「那一段里必须调用 `describe(`」这种语义上。

112. **负控「没红」有两种完全不同的原因，分不清就会把好判据改坏。**
    本轮同时踩到两种，而且它们长得一模一样（都是「变体没报错」）：
      · **判据失效**：断言匹配不到它该匹配的东西。
        例：反向断言锚在 `detail: text)` 的右括号上，而实现已拆成多行。
      · **负控根本没生效**：改写脚本的正则锚点失配，**一个字符都没改**，
        于是检查自然全绿。例：锚点写的是整段多行构造，排版一改就失配。
    区分办法（已写进 `scripts/nc88-agent-bulk-check.sh` 的 `mutate()`）：
    **对「变体声称要改的那个文件」做局部哈希比对**，改动前后不一致才算生效。
      · 没改动 ⇒ 负控失配，去修锚点，**不许碰判据**；
      · 改动过却仍绿 ⇒ 判据失效，去修判据。
    推广：任何「用正则/脚本改源码再跑检查」的负控，
    都必须自带这个「变体确实生效了」的前置断言 ——
    否则它给出的每一个「绿」都不可信，而最自然的反应（怀疑判据）
    恰好是错的方向。
      · ⚠️ **守卫必须局部，不能拿全局快照比。** 第二版改成
        「四个文件全都没变 ⇒ 变体没生效」，结果我在负控运行期间
        **自己**改了另一个源文件 ⇒ 快照失配 ⇒ 守卫以为「有改动」，
        于是一个**根本没生效**的变体被报成「这条判据现在是个摆设」。
        我差点就去改那条判据 —— 而它是对的。
        ⇒ 负控运行期间**不要改任何源文件**；守卫也只信「变体自己声明的那个文件」。
      · ⚠️ **还原必须挂在 `trap` 上，不能只写在每个变体末尾。**
        `mutate` 检测到「正则失配、什么都没改」时会 `exit 2`，
        而那时前一个变体可能已经把源码改坏（实测：变体 6 删掉了
        `busyAll = true`，脚本非零退出没走到 `restore`）。
        留在工作区的那份源码**看起来完全正常** —— 它是能编译的，
        判据也会红（红在一条其实没问题的实现上），
        下一个人只会以为「代码有缺陷」。⇒ `trap restore EXIT INT TERM`。
      · 顺带一条：写负控时**别留「替换成自身」的空操作**。
        `s/(…refreshAll…\n            onDone\(report\))/$1/s` 看着像在改代码，
        其实一个字节都不动。局部守卫会当场拦下它 ——
        而如果没有守卫，它就会伪装成一次成功的改动混过去。

113. **「全量 / 所有」的执行名单必须是**发起那一刻**的真实状态，不是上次加载的快照。**
    本轮实例：按钮承诺「对所有仓库执行更新」，实现冻结了 `model.projects`。
    那个数组是 app **上次加载**时的注册表 —— 别的进程（CLI、另一个终端、
    另一个客户端实例）改了注册表，它并不知道。
    真 app 实测：用 CLI 加了一个仓库后**不刷新 app** 直接点「全量」，
    面板写「已注册项目 3 个，本次实际执行 3 个，成功 3 个，失败 0 个」，
    而侧栏已经是「仓库（4/4）」—— 第 4 个**整行消失**，面板还说「全量完成」。
      · 「冻结名单」防的是**跑到一半换名单**（中途换 ⇒ 报出来的 N 和执行的对不上），
        但**冻结得太早**就是本条：冻结的是陈旧数据。
      · 正确顺序是 **先刷新、再冻结**：占锁仍在任何 `await` 之前
        （否则并发会同时改写多个仓库），但名单要在 Task 里、刷新之后取。
      · 推广：**凡是承诺「覆盖某个全集」的动作，名单都必须在动作发起时重新取**，
        不能复用「界面当前显示的那份」—— 界面那份是为了显示，不是为了执行。
    同族：**承诺里出现的数字必须取自真值。** 同一个面板上，
    标题写「· 4 个仓库」（点击时的 `model.projects.count`）而正文写
    「已注册项目 5 个」（结果里的真值）—— 面板自己跟自己打架，
    用户没有任何线索该信哪个。凡是同一个概念在两处出现，两处必须同源。

114. **引擎已经修过的口径，客户端必须逐字对齐，不许自己发明。**
    本轮实例：引擎 `flow/dashboard.cj:200-208` 早就把 `work.mergeCandidates`
    的判据从 `pendingCommits` 换成 `aheadOfDefault`，还专门写了回归测试
    `testDashboardMergeCandidatesUsesAheadOfDefaultNotPending`（注释写明
    「`pendingCommits` 在刚跑过 update 的分支上恒为 0」）。
    客户端的 `ProjectStatus.needsAction` 里写着
    `branches.contains { $0.pendingCommits > 0 && !$0.isDefault }` ——
    **把引擎刚修掉的错误又犯了一遍。**
    真 app 实测：5 个分支 `ahead=1 / pending=0` ⇒ 引擎 `work.mergeCandidates` = 5，
    客户端判 0 个项目要动手 ⇒ 侧栏「看板 0」而仪表盘「待处理 6」。
      · **「引擎有回归测试」不等于「客户端跟上了」**。回归测试守的是引擎那一侧；
        消费方照抄旧判据时两边都会绿，而界面在说谎。
      · ⇒ 凡引擎某处注释里写着「原来用 X 是错的 / 用 X 与 Y 毫无关系」，
        客户端就不许再出现 X。要么对齐，要么不实现。
      · 推广：**跨仓库的「同一口径」必须有一条拿真实数据做的交叉验证**，
        而不是两边各写一份看起来一样的表达式。

115. **同一个量在同一屏里只许有一个算法；修法是消掉分叉的源头，不是把数字调成一致。**
    本轮实例：一次真 app 巡检看到三处自相矛盾的数字 ——
    侧栏「看板 0」/ 仪表盘「待处理 6」/ KPI「项目总数 3」而侧栏「仓库（6/6）」。
    三处的成因完全同型：**同一个量被算了两遍，两遍规则不同**。
      · `needsAction` 判「可合入」用一套（见不变量 114），引擎用另一套。
      · KPI「项目总数」用 `d.projects.total`（**只数采集成功**的），
        侧栏与范围选择器用注册表条数。引擎测试注释
        （`dashboard.cj:721-722`）早就点名：「必须钉住『listed 才是注册表条数』，
        否则下一个人又会去用 total」—— 上一个「下一个人」就是这张卡。
      · KPI「待处理」是 `dirty + mergeCandidates + (untracked > 0 ? 1 : 0)`：
        **项目数 + 分支数 + 布尔**，三种单位加成一个数，结果没有意义。
      · 第四处最隐蔽：仪表盘**页头那一行摘要**又独立算了一遍（前两处修完仍在）。
    ⇒ 教训不是「以后算仔细点」，是**分叉的源头要消掉**：
      · 提成有名字的派生属性（`BranchStatus.isMergeCandidate`），多处共用。
      · 页头**不许有自己的算法** —— `DashKPIBuilder.summaryLine` 只从 `kpis` 数组读，
        数组只算一次。判据钉「`kpis` 在视图里只出现一次」。
      · 单位不许混：主数字只放一种单位，其余降级到副说明**并写清单位**
        （「待合入分支 5 条」，不是「待处理 5」）。
      · 失败不许跟着消失：主数字改用 `listed` 是对的，
        但采集失败数必须同时出现在副说明里，否则只改一半等于把坏掉的项目藏起来。

    ⚠️ **这一类缺陷会「修完三处还有第四处」，而且判据可以全绿。**
      本轮就发生过：前两处修完、判据全绿之后，真 app 上仍然是
      侧栏「看板 **1**」而仪表盘「待处理 **3**」。
      根因不是两处用了不同算法 —— 它们**都**走 `liveness`，链条是通的；
      是 `liveness` **内部**把 `engineStale` 排在 `needsAction` 前面，
      「又停滞又有活要干」的项目一命中 `return` 就再也没机会问 `needsAction`。
      ⇒ **「同一个谓词」不保证「同一个结果」**：中间任何一层都可能短路。
        判据钉「这几行都在」是**不够**的，要钉**判定顺序**
        （谁先 return），并且对每个「不互斥的判定条件」都问一遍：
        哪条应该先判？现在的顺序是**设计出来的**还是**碰巧写出来的**？
      · 这里的答案是「等我动手」先于「多久没动」，两条理由：
        (a) 两者不互斥，先命中哪个不该由书写顺序决定；
        (b) `.attention` 列的表头本来就写着「待合入的分支」——
        按列自己的定义，有待合入分支的项目无论多停滞都该进这一列。
      · 代价照实记：「停滞」列会因此变小。但信息没丢 ——
        每张项目卡仍单独写着「main: 停滞」，那一行与 `liveness` 无关。
      · 推广：**每修一处「同一件事两个答案」，都要回头找还有没有第五处** ——
        分叉往往是同一个习惯散在四个地方，不是一次手滑。
      · ⚠️ **措辞也是答案的一部分。** 真 app 最后一处：逐仓库面板上一行写
        「已注册项目 6 个…成功 **3** 个，失败 **3** 个」，
        下一行紧接着写「逐仓库结果（**3/6 完成**）」——
        数字一个都没错，判据也全绿，可它是同一件事用了两个词
        （「成功」和「完成」）。中文里这两个词不总是同义，
        读者会以为分母不同 ⇒ **数字对而措辞分叉，一样是分叉**。
        判据要钉「同一段里必须同时报出成功与失败两个数」，
        不钉具体用词（换个中文词组不该红），但要**禁止退回分叉前那套措辞**。

116. **撤掉界面入口 ≠ 撤掉能力。入口数是排版问题，能力是通路问题。**
    本轮实例：顶栏原有「全量浅 / 全量深」两个按钮，与双轨在全局范围下的
    「浅更新 · 全部 / 深更新 · 全部」是**同一个动作的两个入口**，
    措辞还不一样（用户原话：「仪表盘那边有浅更新和深更新 全部，
    所以没必要再多两个」）⇒ 按钮撤掉。
    但同一轮里「全量必须基于 AI agent 执行」这条要求是**仍然成立**的 ——
    撤按钮时若连执行路径一起撤掉，就是用一个 UI 问题换掉一个功能问题。
      · 正确做法：把执行体搬到**已有入口**后面（`AppModel.updateAll` 走
        `AgentBulkUpdate.run`），顶栏恢复为「范围选择器 + 双轨」。
      · 判据不能钉「按钮必须在」（那是钉写法），要钉**背后那条**：
        同一个动作在同一屏里只能有一个入口 **且** 这一处真能走通到执行体。
        按钮可以换位置换措辞，但两处并排就是复发。
      · 同族：**一个动作不许在同一屏里列两遍**。撤掉重复入口之后，
        判据要改成钉「唯一入口」而不是钉某个具体控件。
      · 顺带收益：合并入口之后反而拿到了更好的结果披露
        （逐仓库面板取代了原来那条聚合通知）。

117. **交叉验证必须拿**非空**样本，否则 `0 == 0` 空转着变绿。**
    本轮实例：判据「客户端判出的可合入分支数 == 引擎 `work.mergeCandidates`」
    第一版是**绿的**——而客户端的判据当时是错的。
    根因：契约沙箱里所有仓库都**没有远端**，于是 `branches` 追踪数组**恒空**，
    两边都数出 0，断言恒成立。
      · `0 == 0` 是这类判据最常见的死法：断言写对了，数据让它失去意义。
        凡是「A == B」的判据，都要问一句「**A 和 B 有没有可能不相等**」。
      · 修法是**造出让旧判据判错、新判据判对的样本**：远端 + 一个领先 main 的
        非默认分支 + 已经跑过 update ⇒ `ahead=1 / pending=0`，
        引擎判 1、旧判据判 0。判据里同时加一条**自检**：
        样本退化时（旧判据与新判据同结果）直接判红，而不是放过。
      · 同族：`let x: T = false` 那种「解码永远走不到」的字段，
        样本里必须有**真的出现过 true** 的值，否则「解出来了」与「恒为默认值」
        在数据上长得一样。
      · ⚠️ 与之配套的一条纪律：**别把「造不出样本」写成更强的保证**。
        本轮 `!merged` 这一条在真实数据里**无法独立承重**（引擎的 `merged` 走
        git 祖先关系、`aheadOfDefault` 比本地默认分支算，两者互斥，
        造不出「已合入且领先」的分支）—— 于是那条判据只能保证
        「条件写全了」，保证不了「少写一条会红」。这条局限必须写在判据注释里。

118. **负控必须按判据的**实际位置**选判据套件。**
    本轮实例：负控变体「把 `isMergeCandidate` 退回 `pendingCommits`」报
    「期望红，实际绿 —— 这条判据现在是个摆设」。
    实际情况是：`isMergeCandidate` 的函数体断言与「客户端 == 引擎」那条
    交叉验证都住在 **contract-check**（那里才有引擎真实输出当证据），
    而负控只跑了 **client-check** ⇒ 绿是必然的，**判据无辜**。
      · 这与不变量 112 是同一族，但方向不同：112 说的是「判据失效」vs
        「负控没生效」两种原因要分清；本条多一层 ——
        **「跑错了套件」既不是判据失效，也不是负控没生效，而是问错了地方**。
      ⇒ 拿到「实际绿」时，按这个顺序查，不要直接改判据：
        1. 负控真的改到文件了吗？（局部哈希守卫，见不变量 112）
        2. 那条判据在**哪个套件**里？（grep 判据名，别凭印象）
        3. 那条判据的**证据**来自哪里？（源码文本 / 真实 fixture / 行为）
      · 反向也要写：负控变体**必须真的构造出缺陷**。
        变体「让 `summaryLine` 绕过 kpis 数组去重算待处理」算出来的数是一样的，
        那不是缺陷变体，是无效变体 —— 判据绿是对的。
        变体要还原**真实发生过的那个错**，不是找一个能让判据红的改法。

119. **走不上的分支不会报错，只会显得像「保险起见的多余代码」。**
    本轮实例：`AppDelegate.openPanel()` 里那条
    「窗口已经开着就直接 focus」的快路径判 `w.title == "deepDolphin"`，
    而 `PanelView` 的 `.navigationTitle("deepDolphin 面板")` 覆盖了窗口标题
    （`NSApp.windows[i].title` 取的正是**导航标题**，不是 `Window` 场景的初始标题）
    ⇒ **那个比较永不成立**，每次都落到下面的通知转发。
      · 症状为什么藏得住：功能**没坏**。通知转发那条兜底照样把窗口带出来，
        于是「快路径」看起来像一段防御性冗余，而不是一个坏掉的分支。
        只有拿真实取值去对，才会发现它一次都没跑过。
      · 推广：**凡是「按某个属性找对象」的代码，那个属性的真实取值要钉住** ——
        框架会用别处的声明覆盖它（这里是导航标题覆盖场景标题），
        而症状是「找不到」，不是「报错」。
      · 同一段实现还被**逐字抄了两份**（`AppDelegate` 与 `DockMenuTarget`
        各一份「activate → 找同名窗口 → 前置 → 否则发通知」）。
        标题只是这两份会一起漂移的那一部分 —— 换个别的字符串它们照样分叉。
        ⇒ 修法是**两条一起收**：值收进一个常量（场景 / 导航 / 识别三处都走它），
          行为收进一个函数（两个调用点）。只修值不收函数，下一个字段照样分叉。
      · 判据钉「**唯一出处**」而不是钉「这个标题字符串」：
        后者换个值就绿了 —— 变体「把导航标题换成另一个没人对过的字面量」
        正是靠这条区分开的。
      · 隔离处理照抄本文件既有做法（`MainActor.assumeIsolated`）：
        `NSApplicationDelegate` 回调与 `NSMenuItem` 的 action 都不是
        `@MainActor` 隔离的，而实现是；这些回调必在主线程，
        `assumeIsolated` 在非主线程直接断言，正好是「别这么用」的提示。
      · 同族（更早修过的）：`.badge()` 在 `List(selection:)` 行上接管命中测试、
        无 `.tag` 的行点它会清掉 selection、声明了 `dismiss` 却一次没用 ——
        它们共同的形状都是**「看起来在工作，而那条路一次都没被走过」**。
        这类缺陷不会被崩溃暴露，也不会被功能测试暴露（兜底让它照样能用）。

120. **用合成事件驱动界面时，读回来的状态可能比现实晚一拍。**
     本轮实例：设置页改成三个分类页签后，用 `osascript` 合成按键往
     「或手动输入模型 id」里打字，再立刻用 AX 读「保存」按钮的 `enabled`
     与 Picker 的值 —— 读到的永远是**打字之前**的状态：按钮灰、Picker 停在
     「（手动输入）」。据此得出的结论是「`TextField` 绑在结构体成员绑定
     （乃至跨视图 `@Binding`）上不会提交」，还照着它改了设计。
     点进**另一个**输入框之后再读一次，值**立刻**出现了 ⇒ 绑定一直是对的，
     只是编辑会话的提交与界面刷新都发生在下一次事件里。
      · 代价照实说：多烧了四轮构建，并且把一个**不存在的缺陷**写进了
        源码注释与判据。注释与判据是最贵的一种错 —— 它们会把误判
        固化成「以后谁都别改」的规矩。
      · 推广一：**读状态前先泵一次事件循环**（挪一下鼠标或点一下无关处），
        合成事件驱动出来的界面尤其如此。「读回来的是旧值」和
        「程序没生效」在观测上长得一模一样，必须先排除前者。
      · 推广二：**探针一次只动一个变量。** 本轮先后给出「跨视图 `@Binding`」
        与「结构体成员绑定」两个解释，看起来是层层逼近，实际是同一个
        测量错误造出来的两个说法 —— 两次都只在一个 build 里改了一处、
        却拿它去解释全部现象。
      · 推广三：**「既有行为」要拿既有代码验，不能靠相似性推断。**
        这里一度怀疑「TextField 提交时机」是分页签引入的；
        正确的问法是「旧版有没有」—— 把文件换回 HEAD 重新构建，
        同样输入同样不动（`/tmp/old2.png`）。一问就定了性：
        既有行为就不该顺手改，尤其在成因没弄清之前。
      · 判据钉「**可静态验证且真的会分叉**」的那一条（草稿只有一处真身），
        不把误判写成不变量。负控变体也跟着改指同一条。
      · 同族（更早修过的）：负控替换串里漏写转义的 `$`，perl 把它当自己的
        变量吃成空串，源文件编译不过但**按文本查的判据照样绿** ——
        于是「负控没生效」被报成「判据是摆设」。
        ⇒ `mutate()` 只能证明「文件被改过」，证明不了「改成了想要的样子」；
          现在的做法是额外要求**改完必须出现某段锚点文本**。
      · 同族第二例：**删东西的变体没有「出现」可指认**，硬塞一个改前改后
        都存在的锚点进去，这个「必需的锚点」就静默退化成永远通过；
        而且锚点里**带换行也不行** —— grep 逐行匹配，`grep -F` 拿到含换行的
        模式永远不中，脚本照样往下跑。现在的做法是给删除型变体单独的
        `expect_gone`（指认它该**不**出现），相邻两行这种断言改成数出现次数。
      · 同族第三例：负控的锚点**跟着源码排版走**。把 `case .x: Foo()` 这种
        一行式分支改写成多行块之后，旧正则当场失配，`mutate()` 会以 rc=2
        报「锚点失配」—— 那时**判据是清白的**，红不起来不是判据的锅。
        rc=2 与「判据没红」必须分开报，不能混成一句「负控失败」。

121. **嵌套滚动容器：外层拿到的不是视口高度，「能滚」和「装得下」会一起说谎。**
    - `Form` 在 macOS 是 List-backed。把它塞进外层 `ScrollView`，它报给外层
      的是**整份内容高度**而不是视口高度，于是两件事同时坏，而且**都不报错**：
      ① 外层永远判定「装得下」，滚轮纹丝不动，内容下半段够不着；
      ② 外层反过来把这个高度当作内容尺寸，把 sheet 撑到比窗口还高 ——
         页脚被顶出窗口框，画在窗口外、压在桌面上。实测（窗口 940×672）：
         sheet 776×689，页脚按钮落在 y=809，窗口底边在 772。
    - 「够不着」这件事**看截图看不出来**：把窗口拉高，内容就全出现了，
      于是很容易误判成「窗口太小」。分辨办法只有一条 ——
      **在最小窗口尺寸下量**：能靠拉高窗口解决的，就不是滚动坏了。
      判据也要跟着改：钉「哪一页归谁滚」，别钉「有没有 `ScrollView`」。
    - **两侧都要钉，缺一不可**：外侧（本例 AI 分支 0 层外层 ScrollView）
      与内侧（页面自己得有滚动容器，本例是 `Form`）。只钉外侧的话，
      把 `Form` 换成普通 `VStack` 会「从一侧看很干净」地通过判据，
      而那一页已经彻底不能滚了。
    - 推广：**任何「容器报告的内容尺寸」喂给外层布局的地方都要问一句
      「这是视口还是全文」**。同样的错在 `List`/`ScrollView`/`Text` 上
      都会复现，只是症状不同。
    - 修法（本例）：让会自己滚的那个当滚动容器，不给它套第二个。
      尺寸下限（`minWidth/minHeight`）只有在**内容不再反过来撑大它**之后
      才是它的实际大小 —— 否则改数字是没用的，改了也会被内容顶回去。
    - 负控必须包含「**把本轮修掉的缺陷原样改回去**」这个变体。
      这类缺陷版与修复版长得极像（都有一层 `ScrollView`、都有 `minHeight`），
      只靠「记下当前写法」的判据分不出谁是谁。

122. **「打字时下游不动」先怀疑输入法，再怀疑绑定；A/B 对照不许共用被测状态。**
    - 这个症状本项目连量三轮才对，而三轮各自**看起来都有证据**：
      ① 合成按键读得太早（不变量 120）；② `Form` 里 `TextField` 的提交时机；
      ③ `Picker` 与 `TextField` 共用一份绑定。**三个都不对。**
    - **输入法把「没提交」伪装成「绑定坏了」**：中文输入法开着时，字母进的是
      **组字缓冲区**，输入框里看到的是组字预览，文本**还没交给 app** ——
      症状与「`TextField` 忘了提交绑定」逐字相同。组字在空格/回车/选中候选
      **或失焦**时才提交，所以「点了别处才一起变」是必然的，不是缺陷。
      SwiftUI 拿不到组字缓冲区（它归输入法所有），也没有绕过它的正经 API。
      实测判据：同一个框，切 ABC 打字立刻提交、切拼音打字不动、
      按空格后**不用失焦**就提交了 ⇒ 病根在输入法侧。
      ⇒ **复现疑似绑定缺陷之前，先把输入源切成 ABC 再测一遍**。
    - **A/B 两组必须各有各的状态**。想验证「是不是 `Form` 的锅」，
      就放一个框在 `Form` 内、一个在 `Form` 外 —— 但**两个框都绑 `$draft.model`**。
      两个控件抢同一份存储、互相回写，于是**两个一起坏**，
      看起来「`Form` 内外表现一致 ⇒ 不是 `Form` 的问题」。
      **被测的变量压根没被动过，对照组还自带一个额外缺陷**，
      这个实验无论出不出结论都不能采信。
    - 推广：「两组表现一致 ⇒ 不是这里的问题」是**只有对照有效才成立**的推理。
      先自问「这两组除了被测变量，还差什么」，再采信结论。

123. **全局改名时，先分清哪些字面量是「名字」，哪些是「身份」。**
    - 本项目从 deepGit 改到 moonGit 时，最省事的做法是全局替换 —— 而它会**静默毁数据**。
    - 判据很简单：**这个字面量被谁持有？**
      | 谁持有 | 例子 | 能不能改 |
      |---|---|---|
      | 本仓源码 | `deepGit Engine` 标题、报告页眉 | 随便改 |
      | **用户的磁盘** | `~/.deepgit/`、已写进手写 README 的 `<!-- deepgit:begin -->` | **不能** |
      | **仓外的调用方** | `DEEPGIT_*` 环境变量、`deepgit://` 协议 URI、别人的 shell profile | **不能** |
    - 托管区标记这一条后果最重：改了它，引擎在用户的 README 里**找不到自己标记的区域**，
      于是**另开一个新区**而不是就地更新。用户看到的是「引擎把它之前写的段落留在原地、
      底下又长出一段新的」—— 数据没丢，但文档从此双份，且每次更新都再长一份。
    - 反向的漏也是真漏：`install.sh` 改了安装名却没留软链、`main.cj` 改了 argv[0] 判定却只认新名，
      都会让**老用户的既有脚本当场报「未知命令」**。这类缺陷不在 CI 里 ——
      CI 跑的是新名字，测试全绿，用户机器上才炸。
    - ⇒ 改名提交前逐条过这张表；改完跑一遍
      `grep -rn 'deepgit\|deepGit' --include='*.md' --include='*.sh' .`，
      **逐条判读每处残留是「该留」还是「漏了」**，不要默认「剩下的应该都是对的」。
      （本轮就靠这条抓到 `client-check.sh` 里两条带转义斜杠的 `Sources\/deepGit\/` sed 模式 ——
       普通批量替换匹配不上，症状是「编译清单解析出 0 个源文件」。）

124. **字符串判定的「取哪一段 / 锚在哪」错一处，就是静默的全量失效。**
    两处同族实证（都在 `src/graph/`）：
    - `scanImportLine` 取 `import a.b.c` 的**首段** `a`，而仓颉的跨包语义在**末段**
      （能命中项目内目录/文件名的才是它）；`tokenize` 早已把 `.` 当分隔符，
      所以那行代码**永远取不到末段**。后果不是「少几条边」——
      **整个仓颉仓库的 import 边恒为 0**（`overview.imports = 0`、架构图丢掉唯一的依赖信号）。
    - `containsTodo` 判「出现过 TODO 这个词」，于是命中了自己解释「TODO 残留」的注释
      （自审 2/2 全是假阳性）；第一版修法（后跟 `:`/`(`）仍会命中**文档里示范标记写法**的行。
      正解是把判据锚在**结构位置**（注释体跳过空白后的第一个词）。
    - **既有测试可能把缺陷写成断言**：`testScanCangjieAndGo` 当时断言 `imports[0] == "moongit"`
      （正是那个 bug）。它红了先问「守的是行为还是当时那个 bug」——是后者就**显式推翻并留理由**。
    - **提取类代码要拿真实仓库验证「数量是否合理」**：单测夹具是自己写的，测不出这种错。
    - **检测器自己的测试数据也要防自噬**：标记字面量必须拼接构造（`"TO" + "DO"`）。
    推广：凡「从一段文本里取子串 / 判某个词」的代码，写完先问「取到的是我想要的那一段吗」
    与「它会不会命中我自己的说明文字」。

125. **同一个量必须与它的「使用证据」一起流传，否则下游只能用更粗的近似，而近似会漏。**
    引用边原来只存 `(from, to, count)`，**丢弃了「哪个符号名被引用过」**，
    于是孤儿检测只能以**文件**为判定单位 —— 文件里混有活符号与死符号时漏报。
    现在 `CodeGraph` 增内部字段 `referencedNames`（**不进任何 JSON 出口，契约不变**），判定细化到**符号**。
    三个必须同时做对的细节：
    - **声明位置不算「使用」**：否则「定义即使用」，孤儿永远检不出来；
    - **`"${expr}"` 插值里嵌的是代码**，而 `stripCode` 会把整串剥掉 ⇒「只在插值里用到」的
      符号被误判孤儿（实测 `sanitizeId` / `sumLines` / `numText`）。取「使用证据」要用
      **剥注释、保留字符串**的文本，与「引用计数」用剥串文本是**两个口径**；
    - 测试框架**反射调用**的符号（`@Test` / `__lint*`）源码里没有引用，必须豁免。
    推广：**判定粒度受数据粒度限制**；要更细就把那个维度的信息一路带下去 ——
    但只带进内部结构，**不许顺手进出 JSON**（那是契约变更）。

126. **「并列」是排序的默认失败模式：比较器不给全序，输出就不确定。**
    findings 原比较器只按 `(权重, file, line)`；权重并列且 file:line 相同时判等，
    于是顺序**取决于输入顺序**，而输入来自按语言分组的 `HashMap` 迭代 ——
    实测同一仓库两次 `graph confidence` 逐字节不同（违反「同一仓库两次构建逐字节一致」的既有契约）。
    - 全序要**补到最后一位**（本例：`权重↓ → file↑ → line↑ → flawId↑ → symbol↑`）；
      `byKind` 这类聚合列表同理（`MagicNumber=3` 与 `SuspiciousName=3` 并列）。
    - **限流也会被输入顺序决定**：`CONF_MAX_PER_KIND_PER_FILE`「留下哪 6 条」同样随输入顺序变，
      所以还要把**输入侧的迭代顺序**确定化（语言名排序），而不只是改比较器。
    推广：任何「HashMap 迭代 + 排序」的组合都要问一句「并列时按什么定序」。

127. **负控脚本自己也会因为环境而假失败 —— 先分清「判据没红」与「脚本跑不起来」。**
    `scripts/nc-graph-confidence.sh` 第一版把 SDKROOT 写成 `${SDKROOT:-<极简SDK>}`，
    而 `envsetup.sh` 会在 SDKROOT **未设时**把它设成 Xcode 全量 SDK ——
    于是 `${SDKROOT:-…}` 保留的是**全量** SDK，链接报 `undefined symbol: _strtod`，
    5 个变体**全部**「未判定」。看起来像「判据都抓不住缺陷」，实则是**脚本自己没跑起来**。
    - 必须在 source `envsetup.sh` **之后**无条件改用极简兼容 SDK（macOS 26/27 的系统
      `libSystem.tbd` 缺 arm64-macos 声明，见「构建与测试」）。
    - 负控的「未判定」分支必须**打印关键错误行**（不是整段链接命令），否则无法判断原因。
    - 本仓库的负控入口：`sh scripts/nc-graph-confidence.sh`（注入真缺陷 → 跑对应用例 →
      必须变红 → 还原；注入后自证文件 md5 变化，还原挂 `trap`）。


## 常用命令

```sh
# 引擎
sh scripts/moongit.sh scan ~/dev --depth 4
sh scripts/moongit.sh status --json | jq '.projects | length'
sh scripts/moongit.sh update <项目> --no-ai      # 跳过 AI，用规则引擎
sh scripts/moongit.sh deep <项目> --scope readme --dry-run
sh scripts/moongit.sh context --budget 20000     # agent 上下文包
sh scripts/moongit.sh tools                     # agent 工具清单

# 测试隔离（不污染真实 ~/.deepgit）
export DEEPGIT_HOME=/tmp/deepgit-test
cjpm test

# 负控：判据必须能被真缺陷打红（注入 → 跑对应用例 → 期望红 → 还原）
sh scripts/nc-graph-confidence.sh

# macOS 客户端（独立 SwiftPM 项目；主面板 + 菜单栏 bar，纯展示层）
cd deepDolphin/macos
sh build.sh                    # swift build -c release + 组装 .app + ad-hoc 签名
open deepDolphin.app --args --open-panel    # 启动即开主面板（--project X 直达详情）
# 深链调试：--section milestones | --project deepDolphin
# 构建期会尝试把引擎（~/.local/bin/moongit 或 moonGit/target/release/bin/main）
# 与仓颉运行时 dylib 内嵌进 .app（~59MB），使 app 可独立分发；不内嵌则按
# DEEPGIT_BIN → 内嵌副本 → ~/.local/bin → 登录 shell PATH 的顺序发现引擎。
```

## 数据与日志位置

```
~/.deepgit/
  config.json              全局配置（AI 预设、扫描根）
  registry.json            已注册项目
  store/<projectId>/
    progress.json          各分支进度（结构化）
    state.json             运行元信息（上次更新/深度更新时间）
    journal.jsonl          追加式日志（机器读）
    journal.md             同上的人类可读版
    backups/               文档写入前的备份（保留 config.update.backupKeep 份）
    locks/                 并发锁
```

项目 ID = `p_` + SHA-256(规范化绝对路径) 前 12 位，路径不变则 ID 稳定。

## 协作规约（用户 2026-10-02 定，勿再逐次询问）

1. **阶段完成即提交。** 提交与推送不再逐次征求同意。判据全绿 + 负控真红 + 复验完成
   就算一个阶段，直接建分支提交并推送。默认分支上不直接提交 —— 先建分支。
2. **拿不准时按最佳预案定，不停下来提问。** 可以问的边界只剩两类：
   ① 会写进用户真实数据或造成不可逆损失的动作；② 物理授权（OAuth / MFA / 硬件钥匙）。
   其余一律自己定，定完把「决定了什么 + 为什么 + 影响面」写进 `README.md` 与本文件。
3. **抽象声明（本条的约束形式）：**
   任何一次「本来可以问、但我按预案定了」的决定，都必须在**同一轮**落到文档里，
   否则这个决定等于不存在 —— 下一个人（或下一轮的我）会重新纠结同一个问题。
   写的时候要记**可复用的判据**，不要只记这一次的结论：
   - 通用结论 → 进「关键不变量」（带「推广：」小节，说明它管到哪）
   - 这一次的具体取舍与已知代价 → 进 `README.md` 的「已知边界 / 待人工确认」
   - 两者都要能回答「后来者凭什么这么定」

## 安全与并发基线（2026-09-30 全域对抗审查后立约）

- **execCapture 超时路径的已知限制**：Cangjie SubProcess 不暴露 pid、无 kill API，
  超时后子进程无法回收（泄漏 1 进程+2 线程+管道 FD）。volumeAccessible 已加 60s
  结果缓存使泄漏有界。若未来 Cangjie 暴露终止 API，立即在 TimeoutException 分支补 kill。
- **锁纪律**：同一项目的 track/update/deep 共用 `project.lock`（历史上有三把锁名导致
  钩子+手动并发丢进度条目，已统一）。新增写路径必须 withLock(project.lock)。
- **status --json 恒定 envelope** `{projects:[], summary?}`（单项目/零项目同形状）；
  errorStatusJson 必须补齐客户端 ProjectStatus 的全部非可选键（缺一个键整个面板解码失败）。

## 已知边界

- SHA-256 自研（通过官方测试向量），**不用于密码学安全场景**。
- 深度更新的 `history` 章节不做语义去重，同义提交多时章节会长。
- 非 git 模式只能感知 mtime，无法得知改动内容。
- macOS 菜单栏应用为 ad-hoc 签名（`codesign -s -`），分发给他人时对方首次打开需在
  「系统设置 → 隐私与安全性」中放行。
- **测试沙箱不回收**：`cjpm test` 里用 `mktemp -d` 造 `DEEPGIT_HOME` 的用例跑完不删目录，
  一次全量测试能留下几十个 `/tmp/dg_*_<时间戳>/`（实测累积 200+ 个）。
  不影响正确性（macOS 会按年龄清理 `/tmp`），但排查问题时 `/tmp` 里一堆同名目录
  会干扰判断。要根治：给测试基类加 `defer` 清理，或统一走一个 `withSandbox` 辅助函数。
  临时清法：`mavis-trash -- /tmp/dg_<前缀>_<某次时间戳前缀>`（逐个传，批量会报假失败）。

<!-- deepgit:begin progress -->
## 当前进度（deepGit 维护）

> 深度更新 · 2026-09-30 12:00 · 追踪 1 个分支

- **`main`**（默认 · 当前）：活跃 · head `e48df23d`（2 分钟前） —— 新增 1 个提交（修复×1），涉及 (根目录)（2 文件）、engine（1 文件）、scripts（1 文件）

**最近提交**
- `4294b0f4` feat: deepgit verify 命令 —— 自查文档完整性承诺（2026-09-30）
- `e48df23d` fix: 文档非托管部分逐字节保留（2026-09-30）
- `735a653a` fix: 托管区域容忍缩进标记 + 排除构建产物（2026-09-30）
<!-- deepgit:end progress -->

<!-- deepgit:begin overview -->
## 项目概览

- **技术构成**：`其他` 60 文件、`Cangjie` 29 文件、`Shell` 3 文件、`Markdown` 2 文件
- **工程规模**：100 个跟踪文件 · 4 个提交 · 始于 2026-09-30
- **分支**：`main`

_（本节由 deepGit 依据仓库事实生成，可运行 `deepgit update --mode deep` 用 AI 深化）_
<!-- deepgit:end overview -->

<!-- deepgit:begin architecture -->
## 架构与目录

**目录结构（跟踪文件聚合）**：

```
(根目录 4 个文件)
deepDolphin/ (63)
  macos/ (60)
    deepGit/ (60)
  web/ (3)
    assets/ (2)
moonGit/ (31)
  src/ (29)
    ai/ (3)
    cli/ (2)
    flow/ (3)
    kernel/ (11)
    util/ (9)
scripts/ (2)
```
<!-- deepgit:end architecture -->

<!-- deepgit:begin commands -->
## 常用命令

_未检测到标准构建清单，请参考 README。_
<!-- deepgit:end commands -->
