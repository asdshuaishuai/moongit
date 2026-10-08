# moonGit Engine

**基于 git 历史的本地项目群进度引擎（跨平台核心，AI 无关）。**

AI 开发时代，最容易丢失的不是代码，而是**进度和文档**——人和 AI 都会忘记「这个分支做到哪了」「README 是否还准」。
moonGit Engine 用 git 自己的历史回答这两个问题：

- **记录进度现状（按分支）**：每个分支做到哪、停滞多久、是否已合并，存进全局进度库。
- **浅更新文档**：把各分支进度写进 `README.md` / `AGENTS.md` / `CLAUDE.md` 的**托管区域**。
- **深度更新文档**（手动触发）：基于全量历史重写 `overview` / `architecture` / `commands` / `history` 章节。

> 文档更新只改写 moonGit 自己标记的区域，**其余内容逐字节保留**；写入前自动备份。

配套客户端（菜单栏常驻 + 管理面板 + **AI 层**）见 [deepDolphin](https://github.com/asdshuaishuai/deepDolphin) 仓库。

## 命名：改了什么，为什么有些没改

引擎更名为 **moonGit**（原 deepGit），客户端应用统一为 **deepDolphin**。改名有一条硬边界：

> **改的是「名字」，没改「身份」。** 凡是构成既有数据或既有外部契约的东西一律保持原样 ——
> 跟着改名会让引擎认不出已托管的区域、另开新区，或者让所有现存调用脚本一次性失效。

| 改了 | 没改（且**不要**顺手改） | 为什么留着 |
|---|---|---|
| CLI 命令 `moongit` | 数据目录 **`~/.deepgit/`** | 里面是用户已积累的进度库与注册表。改名等于让引擎在一个空目录重新开始，旧数据变孤儿 |
| 仓包名 `moongit` | 文档托管标记 **`<!-- deepgit:begin -->`** | 已写进用户手写 README/AGENTS 的字面量。改了引擎就找不到托管区域，会**另起新区**而不是就地更新 |
| `scripts/moongit.sh` | 环境变量 **`DEEPGIT_BIN` / `DEEPGIT_HOME`** | 外部调用方的既有接口（客户端、CI、文档、别人的 shell profile 都在用） |
| 安装到 `~/.local/bin/moongit` | MCP 资源 URI **`deepgit://project/{id}`** | 已发布协议标识符，不是显示名。改了会打断所有已配置好的 MCP 客户端，零功能收益 |
| GitHub 仓 `asdshuaishuai/moongit` | | |

兼容性：安装时同时留 `deepgit → moongit` 软链，老脚本照常能跑；
`moongit` 与 `deepgit` 两个 argv[0] 都被识别，不会报「未知命令」。

## AI 架构（deepDesign 模式）

引擎是 **AI 无关** 的确定性内核：不含任何 LLM 调用，也不持有 AI 配置。
它为上层 agent **提供所需的一切**：

| 提供 | 接口 | 说明 |
|---|---|---|
| **上下文包** | `moongit context [项目] [--budget N] --json`（MCP：context 类工具） | 预算内（字符数）的 markdown 事实摘要：总览/脉搏/分支表/日志/里程碑 |
| **工具清单** | `moongit tools --json`（MCP：`tools/list`） | agent 可执行操作的结构化清单（10 项：读上下文/文档/日志，跑更新，git 操作，里程碑） |
| **工具执行** | 对应的 CLI 子命令 | agent 决定调用，引擎照常执行并返回结果 |
| **代码图谱** | `moongit graph <overview\|tree\|symbol\|impact\|arch\|confidence>`（MCP：`codegraph_*` 六工具） | 符号索引 / 关系树 / 影响面 / 技术架构图 / 代码置信度（详见下节） |

## CodeGraph — 代码图谱与架构图（AI 原生能力）

agent 理解一个陌生仓库，靠的不是把几十个文件全 cat 一遍，而是一张**结构化的图**。
`graph` 命令族把仓库变成可查询的事实：符号索引、依赖关系树、改动影响面、技术架构图。

```sh
moongit graph <项目>                        # 概览：文件/符号/引用边统计（--json 同构）
moongit graph tree <项目> --depth 3         # 关系树：目录 → 文件 → 符号（--json 出全量图）
moongit graph symbol <项目> <符号>          # 符号定位：定义处 + 词法引用文件
moongit graph impact <项目> <符号>          # 影响面：改这个符号会波及谁
moongit graph arch <项目> --format html --out arch.html
                                            # 技术架构图（Canvas 交互图，见下）
# arch 另有 mermaid / dot / json 三种 agent 友好出口
```

**技术架构图**：目录聚合为模块 + 依赖边 + 按语义分层（基础/核心/编排/接口），
`--format html` 产出**零依赖单文件 Canvas 交互图**——布局由引擎确定性计算
（同一仓库两次导出逐字节一致），拖拽平移、滚轮缩放、点选模块看出向/入向依赖、
分层过滤、搜索定位、明暗主题。参考了 pyreverse / dependency-cruiser 的模块依赖聚合
与 archify 的可交互形态，但布局算法与渲染器均为引擎自研。

**如实标注的边界**：符号与影响面是**词法级、文件级粒度**（标识符命中），不是语义调用图；
分层判定是模块名启发式。图里的**边**是事实，**层**是解读——两者在数据中分开存放。

### 代码置信度 `graph confidence`（被动能力）

AI 生成的代码最常见的不是「编译不过」，而是一批**看起来对**的结构性疑点：定义了没人引用的
符号、空实现、吞掉错误的 catch、魔法数字、深嵌套、复制粘贴的重复函数体、TODO 残留。
`graph confidence` 把它们做成**确定性事实**——逐条给出 `file:line` 证据，不替人下结论。

```sh
moongit graph confidence <项目>            # 文本报告：分数 + 分类计数 + 明细
moongit graph confidence <项目> --json     # 机读：findings / byKind / score
moongit graph confidence <项目> --llm      # 预填 LLM 复核提示词（要求逐条裁决并引用代码原文）
moongit graph confidence <项目> --no-ast   # 跳过语法树，纯词法
```

- **语法树来自外部开源 `ast-grep`（tree-sitter 内核）**，引擎不自研 parser；未安装时**优雅降级**
  为词法级，并在 `astNote` 里**如实披露**（区分「未安装」与「本次文件的语言都没有语法覆盖」）。
- **仓颉暂无 tree-sitter 语法包**，因此词法路径被做厚到能产出**长度 / 嵌套 / 魔法数 / 空体**
  四种函数级信号——引擎对自己的代码也能给出有意义的置信度（吞错与重复体依赖 AST 节点边界，词法路径不产出）。
- **孤儿符号是符号级判定**：只要名字在某处（含同文件）以**非声明位置**出现过就不算孤儿；
  测试入口（`@Test` / `__lint*`）与入口文件已豁免。
- **分数是结构性疑点的汇总（0..100），不是正确性证明**；这个语义写进每一次输出。
- **`--llm` 只产出提示词，不调用模型**：引擎 AI 无关是红线，语义复核由上层 agent 执行。
- 输出**确定性**：同一仓库两次运行逐字节一致（全序排序 + 排序化迭代），agent 可以对账。

### 为什么这是「仓颉 AI 原生」的示范位

这一模块是仓颉语言特性直接变成产品能力的地方：

- **enum ADT + 穷尽 match 建模语义轴**：`SymKind`（函数/类/结构体/接口/枚举/扩展/别名）
  是提取规则、树渲染、JSON 序列化、影响面分析四方共享的类型。新增一种符号忘了配渲染，
  是**编译期**错误而不是线上脏数据——静态类型把「确定性事实」做进了语言。
- **零正则的手写词法**：仓颉标准库不给正则，这里用字节级 tokenizer + 关键词规则表替代。
  对标识符提取与正则等价，且每条规则可独立单测；多字节 UTF-8（中文注释）在字节层
  天然不是标识符字符，词法边界天然正确。
- **无第三方依赖的图谱**：遍历、建图、布局、Canvas 渲染全部标准库完成——
  引擎保持「git + curl 之外零依赖」的发布形态，agent 宿主不必拖一棵依赖树。
- **确定性输出**：目录遍历排序、插入排序、固定布局算法，同一仓库两次构建逐字节一致——
  agent 可以对账，这是给 LLM 消费的事实该有的性质。

## AI Agent 接入：CLI / MCP / Skill（三件套）

引擎对 agent 的一等公民接口，三者同源（同一套事实与动作，AI 无关）：

### 1. CLI（一次性问答与脚本）

```sh
moongit status --json            # 全部项目状态
moongit context [项目] [--budget N]   # agent 上下文包（markdown，字符预算内）
moongit tools                    # agent 工具清单（JSON）
moongit dashboard --json         # 项目群聚合
```

### 2. MCP 服务器（工具化接入，推荐）

```sh
moongit mcp                      # stdio JSON-RPC（2024-11-05）
```

宿主配置示例（Claude Code / 任何 MCP 宿主）：

```json
{"mcpServers": {"moongit": {"command": "/path/to/moongit", "args": ["mcp"]}}}
```

提供 **21 个工具**：
- 项目管理：`list_projects`、`add_project`
- 上下文与状态：`get_group_context`、`get_project_context`、`get_project_status`、`get_dashboard`
- 文档与日志：`get_project_docs`、`get_journal`
- 更新与追踪：`run_shallow_update`、`run_deep_update`、`run_track`
- git 与里程碑：`git_op`、`list_milestones`、`milestone_add`、`milestone_action`
- 代码图谱：`codegraph_overview`、`codegraph_tree`、`codegraph_symbol`、`codegraph_impact`、`codegraph_arch`、`codegraph_confidence`

另有 resources（deepgit://project/{id}）与 prompts（project_brief）。
> MCP 工具表与 CLI 的 `moongit tools --json`（17 项）**是两份注册表**，服务不同运行时、
> 能力集本就可以不同——要紧的是差异是**有意识**的（见 `AGENTS.md` 不变量 43）。

### 3. Skill（教学包，让编码类 agent 学会用引擎）

```sh
moongit skill print              # 输出 SKILL.md 内容
moongit skill install            # 安装到 ~/.zcode/skills/moongit/SKILL.md（--dir 可指定）
```

内容含：三种接入方式、工具清单、典型任务配方（项目现状/项目群周报/收尾打扫/项目说明）、红线。

### 红线（三件套共有）

- git 操作白名单（pull/push/commit/stash/unstash/fetch），无 reset/clean/force-push
- 文档写入仅限 moonGit 托管区域；用户内容逐字节保留
- 引擎只提供事实与动作；判断与表达由 agent 完成

上层 AI 实现（deepDolphin.app 内置「AI 助手」，或未来的独立 agent 层）负责：
**models.dev 目录选型、provider 通道（ai-sdk 风格，原生 tool_calls）**、
prompt 组装、工具调用循环、答案渲染——与 deepDesign 之于 moonviz 的分层完全同构。

---

## 多平台路线

引擎是**唯一的业务核心**，所有 UI 交互层（各平台客户端）只消费它的两种接口：CLI `--json`（客户端主通道，以子进程方式调用）与 MCP（`moongit mcp`，stdio JSON-RPC，AI agent 用）。传输层只在本机进程之间通信（子进程 + 管道/stdio），**不跨网络，没有 HTTP 服务**。

> 「进程内」这个词在本仓库里只指**进程内 FFI**（把引擎编成 dylib 链接进客户端）——
> 那条路在仓颉 1.0.5 上**已决定不做**（见 `AGENTS.md` 不变量 58），
> 不要把它读成「客户端在同一进程里调引擎」。

| 平台 | 状态 | 说明 |
|---|---|---|
| **macOS** (arm64) | ✅ 已验证 | 当前开发平台；macOS 26/27 需极简兼容 SDK（install.sh 自动处理） |
| **Linux** (x86_64 / aarch64) | 🧭 路线内 | 仓颉官方支持 Linux 目标；引擎只用 `std.*` 与系统 `git`/`curl`，无 macOS 专有依赖 |
| **Windows** (x86_64) | 🧭 路线内 | 仓颉官方支持 Windows 目标；`cjpm.toml` 的 link-option 为 darwin 专属，移植时需按平台调整 |
| **鸿蒙 PC** | 🧭 路线内 | 仓颉是鸿蒙生态一等语言；走仓颉鸿蒙工具链编译，客户端层见 clients 仓库 |

> 引擎零第三方依赖（JSON / SHA-256 / Markdown 渲染全部自研），外部依赖只有系统 `git` 与 `curl`——这是多平台移植成本低的关键。

## 快速开始

```sh
# 1. 安装仓颉 SDK LTS 1.0.5：https://cangjie-lang.cn/download/1.0.5
# 2. 构建并安装
sh scripts/install.sh        # macOS 自动处理 SDK 兼容问题，装到 ~/.local/bin/moongit

# 3. 注册项目群
moongit scan ~/dev --depth 4

# 4. 看现状 / 浅更新 / 深度更新
moongit status
moongit update
moongit deep --scope readme
```

## 命令一览

```
moongit list                      列出已注册项目及一句话现状
moongit add <路径> [--name N]      注册项目
moongit remove <项目> [--purge]    取消注册
moongit scan [根目录...] [--depth N]
moongit status [项目]              查看进度现状（只读，不写任何文件）
moongit track [项目]               进度快照：只写进度库，不改文档（钩子用）
moongit update [项目] [--docs S]   浅更新：记录分支进度 + 刷新文档
moongit deep [项目] [--scope S]    深度更新：重写文档章节
moongit journal [项目] [--branch B]
moongit git <pull|push|commit|stash|unstash|fetch> [项目]
                                  面板级 git 操作（无破坏性命令）--message M 传提交信息
moongit milestone <add|list|done|drop|remove> [项目] [名称]
                                  里程碑：--tag T（tag 存在即自动达成）--date --desc
moongit dashboard                 跨项目聚合：活跃度 / 里程碑 / 语言分布 / 待合入
moongit report [项目] [--out F]   导出自包含 Markdown 进度报告
moongit hook <install|uninstall|status> [项目]   post-commit + post-merge 钩子
moongit verify [项目]             校验文档完整性（用户内容是否被改动）
moongit graph <overview|tree|symbol|impact|arch|confidence> [项目] [--json]
                                  代码图谱：符号索引 / 关系树 / 影响面 / 架构图 / 代码置信度
moongit config <list|get|set> [k] [v]
moongit doctor                    环境自检
```

全局选项：`--json`（机器可读）、`-q`（静默）、`-v`（详细日志）。

## 客户端契约

**没有本地 HTTP 服务，也没有 `moongit serve`。** 客户端（各平台 UI 层）以**子进程**方式调用 CLI，
读 `status` / `dashboard` / `milestone list` / `journal` / `docs` / `config` 的 `--json` 输出；
写操作调用 `update` / `deep` / `track` / `git <op>` / `add` / `scan` / `milestone <子命令>`。

`--json` CLI 与 MCP 工具输出共用同一套结构，**键名即契约**。
其中 `status --json` 恒为 `{projects, summary, language}` envelope——单项目与多项目同形状。

## 它怎么判断「进度」

| 状态 | 判定 |
|---|---|
| `active` | 3 天内有过提交 |
| `idle` | 14 天内 |
| `stale` | 超过 14 天未提交 |
| `merged` | 已是默认分支的祖先 |

每个项目还输出**工程脉搏**：提交类型构成（Conventional Commits 分类）、热点文件、
未跟踪文件 / stash / 多工作区提醒、当前分支的合入建议（fast-forward / 三方合并 / 已合入）。

## 设计取舍（重要）

1. **进度状态存全局库（`~/.deepgit/store/<项目>/`），不写进项目工作区。**
   天然跨分支安全，不污染 git status。项目内只写托管的文档区域与（可选）git 钩子。
2. **只改写自己标记的区域。** 用户手写内容逐字节保留；`overview` / `architecture` / `commands` / `history` 同理。
3. **内容未变则保留原时间戳**，避免文件抖动与提交噪音。
4. **客户端可驱动的 git 操作是白名单制**：pull（--ff-only）/ push / commit / stash / unstash / fetch，
   刻意不提供 reset/clean/force-push。
5. **非 git 目录降级但不放弃**：用文件 mtime 追踪并明确标注「非 git 模式」。
6. **零第三方依赖**：外部依赖只有系统 `git` 与 `curl`（AI 调用走 curl）。

## 叙述生成

浅/深更新的摘要与章节由内置**规则引擎**（确定性启发式：提交前缀分类、分支名归类）生成，
不依赖任何 LLM。要 AI 增强？在上层客户端里问 AI 助手，或让它驱动引擎工具——引擎只提供事实与动作。

## 项目结构

```
src/util/     JSON / SHA256 / 文本 / 时间 / 路径 / 进程 / 日志 / 错误（叶子，仅依赖 std）
src/kernel/   配置 / 注册表 / 存储 / git 封装 / 事实采集 / 里程碑 / 进度 / 叙事 / 文档区域 / 渲染 / 钩子
src/graph/    CodeGraph：符号索引 / 关系边 / 影响面 / 架构图 / 代码置信度（只依赖 util）
src/flow/     浅更新 / 深更新 / 状态聚合 / 仪表盘 / 报告 / agent 上下文（编排层）
src/cli/      命令分发 + MCP 服务器（stdio JSON-RPC）
scripts/      install.sh / moongit.sh / build-minimal-sdk.sh / package-release.sh / nc-graph-confidence.sh（负控）
```

依赖方向严格单向：`util → kernel → flow → cli`；`graph` 只依赖 `util`，与 `kernel` 并列供 `flow`/`cli` 消费。

## 构建细节与已知边界

见 [AGENTS.md](AGENTS.md)（仓颉编码约定、macOS SDK 兼容、测试基线 505 项）。

- SHA-256 自研（通过官方测试向量），不用于密码学安全场景。
- AI 摘要质量取决于提交信息质量。
- **代码置信度的边界**：孤儿是**词法级保守**判定（名字从未在非声明处出现），测试入口
  （`@Test` / `__lint*`）与入口文件已豁免；**不追**传递性死代码；语法树信号只对
  ast-grep 覆盖的语言启用（仓颉走词法近似）。分数受「低权重疑点数量」主导，
  请以 `byKind` 分类明细为准，不要只看 headline 分数。
