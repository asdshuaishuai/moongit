# Cambium Engine

**基于 git 历史的本地项目群进度引擎（跨平台核心，AI 无关）。**

AI 开发时代，最容易丢失的不是代码，而是**进度和文档**——人和 AI 都会忘记「这个分支做到哪了」「README 是否还准」。
Cambium Engine 用 git 自己的历史回答这两个问题：

- **记录进度现状（按分支）**：每个分支做到哪、停滞多久、是否已合并，存进全局进度库。
- **浅更新文档**：把各分支进度写进 `README.md` / `AGENTS.md` / `CLAUDE.md` 的**托管区域**。
- **深度更新文档**（手动触发）：基于全量历史重写 `overview` / `architecture` / `commands` / `history` 章节。

> 文档更新只改写 Cambium 自己标记的区域，**其余内容逐字节保留**；写入前自动备份。

配套客户端（菜单栏常驻 + 管理面板 + **AI 层**）见 [Canopy](https://github.com/asdshuaishuai/deepDolphin) 仓库。

## 命名：Sylva · Cambium · Canopy · Dendro

整个项目叫 **Sylva**（拉丁语「森林」）：一个 git 仓库像一片森林——分支是树，提交是年轮。
四个名字各管一层：

| 名字 | 是什么 | 在哪 |
|---|---|---|
| **Cambium**（引擎） | 基于 git 历史的本地项目群进度引擎 + 代码事实引擎，命令 `cambium` | 本仓库 |
| **Dendro**（置信度） | 置信度模块：结构性疑点检测、补丁级置信度三层、热力图产物。引擎内的独立包 | 本仓库 `src/dendro/` |
| **Canopy**（客户端） | 跨平台桌面客户端（Compose Multiplatform，全平台唯一客户端） | [Canopy 仓库](https://github.com/asdshuaishuai/deepDolphin) |
| **Sylva**（整体） | 上面三者的合称 | 文档里互相引用时用 |

名字改过两次：deepGit → moonGit（2026-10-03），moonGit → **Cambium** / deepDolphin → **Canopy** /
置信度 → **Dendro** / 整体 → **Sylva**（2026-11-26，品牌升级）。
> GitHub 上两个仓库的库名暂时仍是 `moongit` 与 `deepDolphin`（未改名，链接有效）；要改由维护者在 GitHub 上操作。

### 改名字，不改身份

> 凡是构成既有数据或既有外部契约的字面量一律保持原样——跟着改名会让引擎认不出已托管的区域、另开新区，
> 让所有现存调用脚本一次性失效，或者让已有的库被判过期重建。

| 这轮改了 | 没改（且**不要**顺手改） | 为什么留着 |
|---|---|---|
| CLI 命令 `moongit` → `cambium`（安装留 `moongit`、`deepgit` 两个兼容软链；argv[0] 三个名字都认） | 数据目录 **`~/.deepgit/`** | 用户已积累的进度库与注册表。改名 = 引擎在空目录重来，旧数据变孤儿 |
| 仓颉包 `moongit.*` → `cambium.*` | 文档托管标记 **`<!-- deepgit:begin -->`** | 已写进用户手写 README/AGENTS 的字面量。改了引擎会**另起新区** |
| 显示名 moonGit → Cambium | 环境变量 **`DEEPGIT_HOME` / `DEEPGIT_BIN` / …** | 外部调用方的既有接口（客户端、CI、shell profile） |
| 置信度命令 `confidence …`、`graph confidence|patchconf` → **`dendro …`**（旧写法保留为别名） | MCP 资源 URI **`deepgit://project/{id}`** | 已发布的协议标识符 |
| MCP 工具 `confidence_*`、`codegraph_patch_*` → **`dendro_*`**（旧名带 `deprecated` / `replacedBy`） | JSON schema 串 **`moongit-patch-confidence/1`** | 已落盘产物与客户端按它识别 |
| 嵌入声明 `window.MOONGIT_EMBED` → **`window.CAMBIUM_EMBED`**（产物两个名字都读） | 库的 generator 值 **`moongit graph db v2`** 等 | 写进已有库的 meta，引擎按它判库新旧 |
| 产物驱动入口 `window.CambiumCodeGraph` / `CambiumArch`（旧名 `Moongit*` 保留为别名） | 场景契约名 **`moongit-graph-scene v1`** | 外部 Canvas2D 移植端按它驱动 |
| | JSON 键名里的 `confidence`（节点字段、回执键 `staleConfidence` 等）、旗标 `--confidence` | 数据键与功能词，不是品牌 |

### 命令对照

| 旧 | 新（正名） | 说明 |
|---|---|---|
| `moongit <任意命令>` | `cambium <任意命令>` | 启动器与 `moongit` 软链都可用 |
| `moongit confidence gen <项目>` | `cambium dendro gen <项目>` | 现算并落盘快照；旧写法仍是别名 |
| `moongit confidence query <项目>` | `cambium dendro query <项目>` | 只读快照 |
| `moongit confidence db <项目>` | `cambium dendro db <项目>` | 单文件 SQLite |
| `moongit graph confidence <项目> [--no-ast] [--llm]` | `cambium dendro check <项目> …` | **现算报告、不落盘**（与 `query` 不是一回事） |
| `moongit graph patchconf <项目> --patch <diff>` | `cambium dendro patch <项目> --patch <diff>` | 补丁置信度 Layer 1 |
| `moongit graph patchconf --merge a.json b.json` | `cambium dendro merge a.json b.json` | Layer 3 合并 |
| `render index <项目> --confidence` | 不变 | 旗标是功能词 |
| MCP `confidence_gen` / `confidence_query` | `dendro_gen` / `dendro_query` | 旧名带 `deprecated` + `replacedBy` |
| MCP `codegraph_patch_confidence` / `codegraph_patch_merge` | `dendro_patch_confidence` / `dendro_patch_merge` | 同上 |

### Dendro：引擎内的独立置信度包

置信度从图谱包里剥离成了独立包 `src/dendro/`（仓颉包 `cambium.dendro`），与引擎同仓、同一个 cjpm 模块——
不是独立仓库。分层是单向的：`util ← graph ← dendro ← kernel / flow / cli`。

- **在 Dendro 里**：疑点检测（`confidence*.cj`）、补丁级置信度（`patchconf*.cj`）、置信度库（`db.cj`）、
  热力图产物（`treehtml.cj`）、文本出口（`rendertext.cj`）。
- **Dendro 只引入** `std`、`cambium.util`、`cambium.graph`；图谱层与工具层**不认识** Dendro
  （引入就是循环依赖，cjpm 直接拒绝）。这两条由 `src/dendro/layering_test.cj` 钉住。
- 为什么不做成 cjpm 的子模块：置信度直接读图谱模型与词法工具，而子模块不能引用引擎模块里的任何东西——
  要做成子模块，得先把工具包和词法层整个下沉成第三个共享模块（还得再起一个名字）。品牌升级不该顺手做大手术。

> ⚠️ **拉到这版改动后要做一次干净构建**：`cjpm clean`（或删掉 `target/` 与 `.build/`）。
> cjpm 1.0.5 把解析过的包依赖缓存在构建状态里，**新增子包目录后不会失效**——实测增量构建时链接行里
> 缺 `-lcambium.dendro`，cli 对 Dendro 的引用全部 undefined；干净构建后依赖树与链接行才是对的。

## AI 架构（deepDesign 模式）

引擎是 **AI 无关** 的确定性内核：不含任何 LLM 调用，也不持有 AI 配置。
它为上层 agent **提供所需的一切**：

| 提供 | 接口 | 说明 |
|---|---|---|
| **上下文包** | `cambium context [项目] [--budget N] --json`（MCP：context 类工具） | 预算内（字符数）的 markdown 事实摘要：总览/脉搏/分支表/日志/里程碑 |
| **工具清单** | `cambium tools --json`（MCP：`tools/list`） | agent 可执行操作的结构化清单（CLI 侧 18 项 / MCP 侧 23 项：读上下文/文档/日志，跑更新，git 操作，里程碑，代码图谱） |
| **工具执行** | 对应的 CLI 子命令 | agent 决定调用，引擎照常执行并返回结果 |
| **代码图谱** | `cambium graph <overview\|tree\|symbol\|impact\|arch\|confidence>`（MCP：`codegraph_*` 六工具） | 符号索引 / 关系树 / 影响面 / 技术架构图 / 代码置信度（详见下节） |

## CodeGraph — 代码图谱与架构图（AI 原生能力）

agent 理解一个陌生仓库，靠的不是把几十个文件全 cat 一遍，而是一张**结构化的图**。
`graph` 命令族把仓库变成可查询的事实：符号索引、依赖关系树、改动影响面、技术架构图。

```sh
cambium graph <项目>                        # 概览：文件/符号/引用边统计（--json 同构）
cambium graph tree <项目> --depth 3         # 关系树：目录 → 文件 → 符号（--json 出全量图）
cambium graph symbol <项目> <符号>          # 符号定位：定义处 + 词法引用文件
cambium graph impact <项目> <符号>          # 影响面：改这个符号会波及谁
cambium graph arch <项目> --format html --out arch.html
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

### 代码置信度 `dendro check`（被动能力；Dendro）

AI 生成的代码最常见的不是「编译不过」，而是一批**看起来对**的结构性疑点：定义了没人引用的
符号、空实现、吞掉错误的 catch、魔法数字、深嵌套、复制粘贴的重复函数体、TODO 残留。
`cambium dendro check` 把它们做成**确定性事实**——逐条给出 `file:line` 证据，不替人下结论。

```sh
cambium dendro check <项目>            # 文本报告（现算、不落盘）：分数 + 分类计数 + 明细
cambium dendro check <项目> --json     # 机读：findings / byKind / score
cambium dendro check <项目> --llm      # 预填 LLM 复核提示词（要求逐条裁决并引用代码原文）
cambium dendro check <项目> --no-ast   # 跳过语法树，纯词法
```

- **语法树来自外部开源 `ast-grep`（tree-sitter 内核）**，引擎不自研 parser；未安装时**优雅降级**
  为词法级，并在 `astNote` 里**如实披露**（区分「未安装」与「本次文件的语言都没有语法覆盖」）。
- **仓颉暂无 tree-sitter 语法包**，因此词法路径被做厚到能产出**长度 / 嵌套 / 魔法数 / 空体**
  四种函数级信号——引擎对自己的代码也能给出有意义的置信度（吞错与重复体依赖 AST 节点边界，词法路径不产出）。
- **孤儿符号是符号级判定**，使用证据是两路的并集：名字在某处（含同文件）以**非声明位置**出现过，
  或有解析后的调用点连到它（与代码索引的 `sites` 表同一批行）。只有声明没有体、而另有同名定义的
  （头文件原型 / 接口签名）不单独报。测试入口（`@Test` / `__lint*`）与入口文件已豁免。
  ⚠ 「被引用」仍是名字级证据（同名不同物会漏报）；框架约定的回调（Qt override / D-Bus slot / 协议方法）
  恒报——探针工程剩余孤儿抽 10 条：6 条真死、4 条是框架回调。
- **每条疑点带符号键**（`id` / `qual`，键集恒定 10 键）：`id` 与代码索引的稳定 id 同一个键，拿去
  `index query` / `index refs` 能直接回到定义与调用点；`symbol` 是「谁有问题」（幻觉调用的名字）、
  `qual` 是「问题发生在哪」（挂靠符号的限定名）。定位不到符号的（文件级 TODO、构造函数体内）为空串。
- **幻觉调用（`unresolved-call`）的精度有硬上限**：它只是「全仓没有该名字的裸调用」。词法级没有类型与
  依赖信息——探针工程剩余的这一类抽 20 条，**0 条是真的编造 API**（15 条框架 / 标准库调用、
  3 条 C++ 局部变量构造、2 条局部函数或 lambda）。agent 转述前先核对依赖里有没有这个名字，
  不要直接说成「AI 编造了 API」。带接收者的未解析调用（`obj->m(`）不入这一类，只留在调用点表里。
- **`render index --confidence` 会校验快照是否过期**：置信度快照依据的索引版本与当前不一致时
  不叠加旧快照（回执如实写「置信度快照过期……先 cambium dendro gen」，`--json` 恒发
  `staleConfidence`）；页面上每个符号给出**定位串** `相对路径:行:列`（一键复制）与「复制符号 ID」。
  产物里不内嵌本机绝对路径。
- **分数按「每文件疑点密度」归一（与仓库规模无关）**：`100·S/(S+密度)`，S=20；
  它是结构性疑点汇总，**不是正确性证明**，这个语义写进每一次输出。
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
  引擎保持「git 之外零依赖」的发布形态，agent 宿主不必拖一棵依赖树。
- **确定性输出**：目录遍历排序、插入排序、固定布局算法，同一仓库两次构建逐字节一致——
  agent 可以对账，这是给 LLM 消费的事实该有的性质。

## AI Agent 接入：CLI / MCP / Skill（三件套）

引擎对 agent 的一等公民接口，三者同源（同一套事实与动作，AI 无关）：

### 1. CLI（一次性问答与脚本）

```sh
cambium status --json            # 全部项目状态
cambium context [项目] [--budget N]   # agent 上下文包（markdown，字符预算内）
cambium tools                    # agent 工具清单（JSON）
cambium dashboard --json         # 项目群聚合
cambium index gen myapp          # 建代码索引（成员级；每个项目一次，之后 index update 增量）
cambium index search parse myapp # 按名字搜符号 → index query / outline / refs / impact / grep
```

### 2. MCP 服务器（工具化接入，推荐）

```sh
cambium mcp                      # stdio JSON-RPC（2024-11-05）
```

宿主配置示例（Claude Code / 任何 MCP 宿主）：

```json
{"mcpServers": {"cambium": {"command": "/path/to/cambium", "args": ["mcp"]}}}
```

提供 **38 个工具**（32 个现行 + 6 个旧名别名；别名在 `tools/list` 里带 `deprecated: true` 与 `replacedBy`）：
- 项目管理：`list_projects`、`add_project`
- 上下文与状态：`get_group_context`、`get_project_context`、`get_project_status`、`get_dashboard`、`get_project_docs`、`get_journal`
- 更新与追踪：`run_shallow_update`、`run_deep_update`、`run_track`
- git 与里程碑：`git_op`、`list_milestones`、`milestone_add`、`milestone_action`
- 代码索引（agent 定位代码）：`index_gen`、`index_update`、`index_overview`、`index_search`、`index_query`、`index_outline`、`index_refs`、`index_impact`、`index_grep`
- 架构与置信度：`arch_gen`、`arch_update`、`arch_query`、`dendro_gen`、`dendro_query`、`render`
- 补丁级置信度三层（Layer 1 算法信号 / Layer 2 agent 复核走 skill / Layer 3 合并）：
  `dendro_patch_confidence`（Layer 1）、`dendro_patch_merge`（Layer 3）
- 旧名别名（将移除，勿在新方案里使用）：`codegraph_overview`、`codegraph_tree`、`codegraph_symbol`、`codegraph_impact`、`codegraph_arch`、
  `codegraph_confidence`、`confidence_gen`、`confidence_query`、`codegraph_patch_confidence`、`codegraph_patch_merge`

`index_*` 工具同时返回 `content[0].text`（人读摘要）与 `structuredContent`（与 CLI `--json` 同形的对象）；
只读工具带 `annotations.readOnlyHint`。另有 resources（deepgit://project/{id}）与 prompts（project_brief）。
> MCP 工具表与 CLI 的 `cambium tools --json`（33 项）**是两份注册表**，服务不同运行时、
> 能力集本就可以不同——要紧的是差异是**有意识**的（见 `AGENTS.md` 不变量 43）。
> 数字要跟着清单走：这两处都漂过（审查 M25 实测两处各差 3 项）。

### 3. Skill（教学包，让编码类 agent 学会用引擎）

```sh
cambium skill print              # 输出 SKILL.md 内容
cambium skill install            # 安装到 ~/.zcode/skills/cambium/SKILL.md（--dir 可指定）
```

内容含：两种接入方式（标题里的数字由列表长度派生）、工具清单（**从 `mcpToolList()` 生成**，名字与计数
不手抄——对账测试 `testSkillMarkdownToolListMatchesMcpToolList` 双向钉住）、用索引前要先读的五条、
典型任务配方（项目现状 / 项目群周报 / 收尾打扫 / 项目说明 / **代码在哪** / **改这个函数影响谁** /
**这段代码可信吗** / 提交前补丁体检三层 / 架构图）、红线、旧名别名对照。frontmatter 带引擎 `version`。
配方行不教旧名别名（`testSkillRecipesDoNotTeachDeprecatedAliases`）。

### 代码索引（agent 快速定位代码）

```sh
cambium index gen <项目>                      # 建索引：codegraph.db（SQLite v2）+ index.json
cambium index update <项目> [--force]         # 探针增量：源没变就跳过，变了重建（版本 +1）
cambium index search <模式> [项目] [--kind K] [--lang L] [--limit N] [--file F]
                                              # 按名字/限定名搜符号（大小写不敏感；名字精确 > 限定名相等
                                              #   > 名字前缀 > 子串 > 子序列），每条带稳定 id 与 score
cambium index query <符号> [项目]              # 符号 = 裸名 | Outer.method | id
cambium index query --file <路径> [项目]        # 同 index file
cambium index file <路径> [项目]               # 文件大纲：符号 + 行范围 + 签名 + 调入/调出文件
cambium index refs <符号> [项目]               # 每一个调用点（file:line:col、接收者、tier、所在函数）
cambium index impact <符号> [项目] [--depth N] # 沿 direct/resolved 边反向传递闭包（谁会跟着坏）
cambium index grep <文本> [项目] [--ignore-case] [--limit N] [--context K] [--glob G]
                                              # 字面文本搜索，不依赖索引
cambium index overview <项目>                  # 计数：符号 / 边 / 调用点 / 未解析 / 各 tier
```

- **符号是成员级的**：`kind / name / qual（Outer.method）/ file / line / endLine / col / sig / visibility /
  declOnly`，9 种语言（`lang` 值：swift、kotlin、java、ts、python、go、rust、cangjie、c——C 与 C++ 共用 `c`）。
  入表的成员是函数与类型（`func` / `class` / `struct` / `interface` / `enum` / `extension` / `typealias`）；
  属性 / 字段目前不作为独立符号入表。
  只有声明没有体的（头文件原型、接口方法签名）以 `declOnly: true` 入表——agent 要能在头文件里找到声明处；
  同一工程另有同名定义时它作为该定义的 `decls` 呈现，不单独算定义。
- **稳定 id** `f:<相对路径>:<行>:<名字>`：同一份源码两次索引得到同一个 id，可当句柄回传给
  `index query / refs / impact`（同文件同行同名的重复者带 `#n` 后缀）。行号是 id 的一部分——代码挪了行 id 就变（词法级索引给不出跨编辑恒定的身份，
  不编一个看起来恒定实际会漂的哈希）。
- **从声明处一跳到定义**：`index file <头文件>` 的大纲里有原型的 id；拿它去 `index query / refs / impact`，
  回的是**定义**（含调用方与调用点），声明处列在定义的 `decls` 里。只有声明、没有定义的照常回声明本身。
- **裸名有歧义时不替你挑**：`index query` 返回 `ambiguous: true` 与 `perDef`（逐定义的调用方/被调），
  用限定名或 id 收窄。同名不同语言不算同一个符号。
- **调用边带调用点与确信度** `tier`：`direct` = 限定命中（`Type.name(` / `self.name(`）；
  `resolved` = 裸名在候选里唯一（同文件 → 全工程 → 同模块）；`guessed` = 有歧义、全部连边。
  **全部是词法级候选，不是编译器闭包**——向用户转述必须带这个限定。
- **未解析的调用点**（`dst = 0`）绝大多数是框架/标准库调用（探针工程上约 60%：`Text`、`addWidget`、`isEmpty`…），
  不要说成「项目里没有定义」。各语言关键字与标准库内建在解析阶段丢弃（仅当工程内无同名符号时）。
- **SQL 直查**（给要自己写查询的 agent）：`codegraph.db`
  `nodes(id, kind, name, file, line, lang, findings, max_weight, sid, qual, end_line, col, sig, visibility, decl_only)`、
  `sites(src, dst, file, line, col, receiver, tier, name)`、`edges(src, dst, tier, weight)`、`files(path, lang, lines, symbols)`。
  例：`SELECT s.file, s.line, s.col FROM sites s JOIN nodes n ON n.id = s.dst WHERE n.qual = 'AppModel.goRoute'`。
  旧版（v1）库在下次 `index update` / `cambium dendro gen` 时视为过期自动重建。
- 查不到就是查不到：`index query / refs / file` 对不存在的符号/文件报错、非 0 退出、不编结果；
  `search / grep` 无命中返回空数组。

### 红线（三件套共有）

- git 操作白名单（pull/push/commit/stash/unstash/fetch），无 reset/clean/force-push
- 文档写入仅限 Cambium 托管区域；用户内容逐字节保留
- 引擎只提供事实与动作；判断与表达由 agent 完成

上层 AI 实现（Canopy.app 内置「AI 助手」，或未来的独立 agent 层）负责：
**models.dev 目录选型、provider 通道（ai-sdk 风格，原生 tool_calls）**、
prompt 组装、工具调用循环、答案渲染——与 deepDesign 之于 moonviz 的分层完全同构。

---

## 多平台路线

引擎是**唯一的业务核心**，所有 UI 交互层（各平台客户端）只消费它的两种接口：CLI `--json`（客户端主通道，以子进程方式调用）与 MCP（`cambium mcp`，stdio JSON-RPC，AI agent 用）。传输层只在本机进程之间通信（子进程 + 管道/stdio），**不跨网络，没有 HTTP 服务**。

> 「进程内」这个词在本仓库里只指**进程内 FFI**（把引擎编成 dylib 链接进客户端）——
> 那条路在仓颉 1.0.5 上**已决定不做**（见 `AGENTS.md` 不变量 58），
> 不要把它读成「客户端在同一进程里调引擎」。

| 平台 | 状态 | 说明 |
|---|---|---|
| **macOS** (arm64) | ✅ 已验证 | 当前开发平台；macOS 26/27 需极简兼容 SDK（install.sh 自动处理） |
| **Linux** (x86_64 / aarch64) | 🧭 路线内 | 仓颉官方支持 Linux 目标；引擎只用 `std.*` 与系统 `git`，无 macOS 专有依赖 |
| **Windows** (x86_64) | 🧭 路线内 | 仓颉官方支持 Windows 目标；`cjpm.toml` 的 link-option 为 darwin 专属，移植时需按平台调整 |
| **鸿蒙 PC** | 🧭 路线内 | 仓颉是鸿蒙生态一等语言；走仓颉鸿蒙工具链编译，客户端层见 clients 仓库 |

> 引擎零第三方依赖（JSON / SHA-256 / Markdown 渲染全部自研），外部依赖只有系统 `git`——这是多平台移植成本低的关键。

## 快速开始

```sh
# 1. 安装仓颉 SDK LTS 1.0.5：https://cangjie-lang.cn/download/1.0.5
# 2. 构建并安装
sh scripts/install.sh        # macOS 自动处理 SDK 兼容问题，装到 ~/.local/bin/cambium

# 3. 注册项目群
cambium scan ~/dev --depth 4

# 4. 看现状 / 浅更新 / 深度更新
cambium status
cambium update
cambium deep --scope readme
```

## 命令一览

```
cambium list                      列出已注册项目及一句话现状
cambium add <路径> [--name N]      注册项目
cambium remove <项目> [--purge]    取消注册
cambium scan [根目录...] [--depth N]
cambium status [项目]              查看进度现状（只读，不写任何文件）
cambium track [项目]               进度快照：只写进度库，不改文档（钩子用）
cambium update [项目] [--docs S]   浅更新：记录分支进度 + 刷新文档
cambium deep [项目] [--scope S]    深度更新：重写文档章节
cambium journal [项目] [--branch B]
cambium git <pull|push|commit|stash|unstash|fetch> [项目]
                                  面板级 git 操作（无破坏性命令）--message M 传提交信息
cambium milestone <add|list|done|drop|remove|reopen> [项目] [名称]
                                  里程碑：--tag T（tag 存在即自动达成）--date --desc
cambium dashboard                 跨项目聚合：活跃度 / 里程碑 / 语言分布 / 待合入
cambium report [项目] [--out F]   导出自包含 Markdown 进度报告
cambium hook <install|uninstall|status> [项目]   post-commit + post-merge 钩子
cambium verify [项目]             校验文档完整性（用户内容是否被改动）
cambium graph <overview|tree|symbol|impact|arch|confidence> [项目] [--json]
                                  代码图谱：符号索引 / 关系树 / 影响面 / 架构图 / 代码置信度
cambium index <gen|update|overview|search|query|file|refs|impact|grep> …
                                  代码索引（成员级，稳定 id）：见上文「代码索引」
cambium confidence <gen|query> <项目> [--file F] [--symbol S] [--kind K] [--weight W] [--top N]
                                  置信度快照：gen 生成（索引过期先自愈）；query 只读快照
cambium arch <gen|update|query> <项目> [模块] [--violations]
                                  架构索引：模块聚合 + 分层判定 + 泳道布局
cambium render <arch|index> <项目> [--confidence] [--force]
                                  用持久化 payload 渲染单文件交互 HTML（未变即复用）
cambium tools / cambium mcp / cambium skill <print|install>
                                  agent 三件套：工具清单 / MCP 服务器 / Skill 教学包
cambium context [项目] [--budget N]
                                  agent 上下文包
cambium config <list|get|set> [k] [v]
                                  配置键：language / update.backupKeep / update.maxShallowBranches / roots
cambium doctor                    环境自检
cambium version                   引擎版本号
```

全局选项：`--json`（机器可读）、`-q`（静默）、`-v`（详细日志）。

## 客户端契约

**没有本地 HTTP 服务，也没有 `cambium serve`。** 客户端（各平台 UI 层）以**子进程**方式调用 CLI，
读 `status` / `dashboard` / `milestone list` / `journal` / `docs` / `config` 的 `--json` 输出；
写操作调用 `update` / `deep` / `track` / `git <op>` / `add` / `scan` / `milestone <子命令>`。

`--json` CLI 与 MCP 工具输出共用同一套结构，**键名即契约**。
其中 `status --json` 恒为 `{projects, summary, language}` envelope——单项目与多项目同形状。

图谱两页走 `render index --confidence` / `render arch`：文本回执给人看（末行 + 产物路径），
`--json` 回执给调用方判状态（`reused` / `updateCount` / `confidence` 四态 / 恒发的 `staleConfidence`）。
**客户端的义务**：`render index` 的回执说「置信度快照过期」时要先 `cambium dendro gen <项目>` 再重绘——
引擎不叠加旧快照，这一页就没有热力图。CMP 客户端在 `renderGraph` 里做了这一步自愈。
`cambium dendro check <项目> --json` 的每条 finding 有 10 个键（`id` / `qual` 可为空串）：镜像要么接住，要么显式豁免。

图谱产物可以**内嵌**进宿主页面（CMP 客户端的两张图谱页就是这么做的）。原样塞进去时，产物自带的
页头、工具条、面包屑、技术状态条会和宿主的外壳叠在一起，配色也不是一套；所以由产物自己适配宿主——
宿主在产物**任何脚本之前**（`<head>` 最前面）声明：

```js
window.CAMBIUM_EMBED = {
  chrome: "page",            // 收拢外壳：一条命令条 + 画布 + 一条通栏底条；不声明 = 独立完整版
  vars:   { "--bg": "#1f1f1f", "--text": "#ffffff", "--cyan": "#60cdff",               // 主题变量
            "--e-ctl-h": "32px", "--e-foot-h": "32px", "--e-r-ctl": "4px", "--e-r-card": "8px" },  // 尺寸契约（可选）
  canvas: { bg: "#1f1f1f", atmosphere: false, radius: 8, red: "#ff99a4", /* … */ }
};
```

- `vars` 是 CSS 自定义属性，产物把它们写进 `<html>` 与 `<body>` 的内联样式。变量名见两份产物各自的
  `:root`（热力图：`--bg / --panel / --line / --line2 / --text / --muted / --muted2 / --green / --yellow /
  --red / --cyan / --radius / --sans / --mono`；架构图：`--bg / --grid / --text / --muted / --panel /
  --border / --accent / --arrow / --chip`），多余的无害。
- `canvas` 是画在 canvas 上的颜色与圆角（CSS 管不到像素）：键名见驱动里 `cv(key, 原值)` 的调用处；
  架构图是它的暗色调色板的键名（`bg0 / bg1 / grid / text / muted / border / arrow / accent / cols / fills / card / mini`）。
- **尺寸契约（可选）**：`--e-ctl-h` 控件高、`--e-foot-h` 底条高、`--e-r-ctl` 控件圆角、`--e-r-card` 卡片圆角——
  让嵌入页的输入框、按钮、卡片与宿主的控件同高同圆角（CMP 传 `ControlHeight` 与 `Radius` 令牌，换皮肤即跟着变）。
  不传就回退到产物自己的定稿值，旧宿主不受影响。
- **布局看视口**：嵌入模式下产物按它拿到的视口排布，而不是把定稿布局整体缩小——
  架构图的泳道按可用区域的宽高比折行（4 个模块在 1040×634 的页面里，从一行 0.77 倍折成 2×2 的 1.35 倍，
  卡片上的字从 6px 到 12px）；热力图按可用区域选列数、色带包住自己的卡片、图例与操作按钮并进通栏底条。
  窗口拖大拖小时，还在「适应画布」状态就重新取景；用户手动缩放/平移过的不抢。独立打开时沿用定稿布局，一个像素不变。
- 宿主**不要**覆写产物内部的类名与结构（`AGENTS.md` 不变量 155、156）：适配由产物负责，老引擎的产物
  不认识这份声明，按独立版渲染，不会坏。
- `arch.json` 带 `geo`（槽位几何，折行只认这一份）才是当前数据形状：更早的构建写出的没有它，
  `render arch` / `arch query` / MCP 遇到会按过期**自愈重建一次**（与索引的 `payload_shape` 同一纪律——
  探针一致 ≠ 数据形状一致），版本号 +1。
- 产物的复用判定比对**模板版本**（注释行 `<!-- cambium render · template=N -->`）：引擎升级后模板变了，
  输入没变的旧产物也会重画一次，不会一直复用旧外壳。

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
6. **零第三方依赖**：外部依赖只有系统 `git`。
   （⚠️ 这里原来写着「git 与 curl（AI 调用走 curl）」——AI 层移到客户端后
   `grep -rn curl src/` 零调用点，`doctor` 只检查 git。
   **残留的依赖声明比没有声明更糟**：它让用户去装一个根本没人用的二进制。）

## 叙述生成

浅/深更新的摘要与章节由内置**规则引擎**（确定性启发式：提交前缀分类、分支名归类）生成，
不依赖任何 LLM。要 AI 增强？在上层客户端里问 AI 助手，或让它驱动引擎工具——引擎只提供事实与动作。

## 项目结构

```
src/util/     JSON / SHA256 / 文本 / 时间 / 路径 / 进程 / 日志 / 错误（叶子，仅依赖 std）
src/kernel/   配置 / 注册表 / 存储 / git 封装 / 事实采集 / 里程碑 / 进度 / 叙事 / 文档区域 / 渲染 / 钩子
src/graph/    CodeGraph：符号索引 / 关系边 / 影响面 / 架构图（只依赖 util）
src/dendro/   Dendro：代码置信度 / 补丁置信度 / 热力图产物（只依赖 util 与 graph）
src/flow/     浅更新 / 深更新 / 状态聚合 / 仪表盘 / 报告 / agent 上下文（编排层）
src/cli/      命令分发 + MCP 服务器（stdio JSON-RPC）
scripts/      install.sh / cambium.sh / build-minimal-sdk.sh / package-release.sh /
             nc-graph-confidence.sh / nc-audit-2026-10-09.sh（负控：注入真缺陷→判据必须变红）
```

依赖方向严格单向：`util → kernel → flow → cli`；`graph` 只依赖 `util`，与 `kernel` 并列供 `flow`/`cli` 消费。

## 构建细节与已知边界

见 [AGENTS.md](AGENTS.md)（仓颉编码约定、macOS SDK 兼容；测试基线以 `cjpm test` 实跑为准，
v0.3.0 为 725 项——Linux 上有 3 条环境性红用例，见下）。

- SHA-256 自研（通过官方测试向量），不用于密码学安全场景。
- AI 摘要质量取决于提交信息质量。
- **代码置信度的边界**：孤儿是**词法级保守**判定（名字从未在非声明处出现），测试入口
  （`@Test` / `__lint*`）与入口文件已豁免；**不追**传递性死代码；语法树信号只对
  ast-grep 覆盖的语言启用（仓颉走词法近似）。**分数已按规模归一**，但低权重疑点
  （魔法数等）数量仍会压分，请以 `byKind` 分类明细为准，不要只看 headline 分数。
  孤儿报告的处置口径：未使用的**私有**符号可安全删除（文件外不可能有人引用）；
  **公开**符号可能是预留给后续能力的 API，引擎只报告、不自动删除。
- **代码索引的边界**（v0.3.0 的取舍，数字取自探针工程 /tmp/itest：9 种语言、2.3k 符号）：
  · **稳定 id 是名字基的** `f:<相对路径>:<行>:<名字>`——同一份源码两次索引得到同一个 id，
    但代码挪了行 id 就变。词法级索引给不出跨编辑恒定的身份，这里**不编一个看起来恒定、
    实际会漂的哈希**；要跨编辑追踪请用 `qual` + 名字自己兜。
  · **v1 库视为过期**：旧版 `codegraph.db` 在下次 `index update` / `cambium dendro gen` 时自动重建，
    不做迁移（schema v2 的列是新增的，旧库没有可迁的数据）。
  · **调用边是词法级候选，不是编译器闭包**。tier 的含义见上文「代码索引」；探针上调用点
    18131 个、未解析 10911 个（约 60%），未解析的绝大多数是框架/标准库调用
    （`Text` ×667、`addWidget` ×354、`isEmpty` ×309…）——**不要说成「项目里没有定义」**。
    接收者调用（`a.b(`）在接收者类型未知时按裸名解析：探针上 1508 条 `resolved` 边里有 815 条
    的证据来自带接收者的调用（接收者的类型未知）——**可能误连**，向用户转述必须带这个限定。
    显式接收者（不是 self / this）的同名调用**不连回所在函数自身**（`m_autoTimer->stop()` 写在
    `AppModel::stop` 里记为未解析，不再产生假自环）；同名**重载之间**的委托调用
    （`summary(a, b, c)` 写在另一个 `summary` 重载里）在词法上与递归分不开，仍会表现为自环。
  · **没有真正的增量解析**：`index update` 是探针增量（源没变就跳过；变了整库重建，版本 +1）。
  · C++ 栈上构造的对象不计调用点（`Foo f; f.m()` 的 `f.m(` 按裸名 `m` 解析）。
  · 扫描器**一行只记一个符号起点**：同一行上闭合括号之后的声明不记（`}; class B {}`、
    `int f() {…} int g() {…}` 这类写法会丢后一个）；正常排版不受影响。
  · **声明行上的调用不计调用点**：签名、默认实参、装饰器所在行上的调用
    （`fun f(a: Int = helper(1))`、`@cache`）不记，只有函数体里的调用入库。
  · **`->` 只在 C / C++ 里当成员访问**；Kotlin / Java 的 lambda 箭头（`x -> f(x)`）与 Rust / Python /
    Swift 的返回类型箭头不是接收者——箭头后的调用是自由调用。
  · **行中开的块注释不跨行跟踪**（`int x; /**< 说明` 换行续写）：续行在「提及证据」里仍算代码。
  · 嵌套函数与 lambda 不入符号表（里面的调用挂在最外层函数上）；构造函数不入表——构造函数体内的
    疑点没有符号键（探针上 400 条里 9 条）；Qt 的 `emit sig(` 被当成声明；全大写加下划线的名字
    按形状当作宏丢弃（探针上碰巧都对，但依据是长相不是事实）。
  · **「新鲜」也看数据形状**：更早的构建留下的索引（函数节点没有成员级三键）即使源码没变也会被
    自动重建一次——见证是 `codegraph.db` 里 `store_meta` 的 `payload_shape` 行，不去读 index.json
    （5MB 的 payload 光解码 UTF-8 就要约 0.35 秒，而 `index query` 每次都要过新鲜度判定）。
  · **卷可达性预检靠起 `stat` 进程、预算 1.2 秒**：机器高负载时会把可达的卷判成超时并缓存 60 秒
    （两套全量测试并行时实测复现过一次，单独重跑即绿）。
  · MCP 工具尚未声明 `outputSchema`（形状靠 `structuredContent` 与描述文字约定）；
    两遍词法扫描（成员级扫描器与 `build.cj` 的引用遍）各有一套口径，偶有不一致；
    其余未做项见 [docs/ROADMAP.md](docs/ROADMAP.md)。
  · **macOS 客户端的 AgentCore 尚未接入 5 个新索引查询工具**（`index_query / refs / impact /
    search / grep`）——引擎侧 CLI 与 MCP 都已就绪，客户端侧是后续工作。
  · **MCP 与 `tools --json` 的现行工具名并不对齐**（v0.2 之前的旧账，本轮没并）：两边同名的 23 个，
    MCP 独有 9 个（`add_project` / `list_projects` / `get_project_status` / `get_dashboard` / `run_track` /
    `git_op` / `list_milestones` / `milestone_add` / `milestone_action`），`tools --json` 独有 4 个
    （`get_milestones` / `git_commit` / `git_pull_push` / `milestone_done`——客户端 AgentCore 按这些名字分发）。
    6 个旧名别名两边一致。本轮新增的 `index_*` 九个两边同名同数；并表要动客户端的分发表，另起一轮。
- **Linux 上有 3 条环境性红用例**（改动前就红，与功能无关，不要为了变绿去改断言）：
  `testExecCaptureTerminatesTimedOutProcess`、`testExecCaptureTimeoutIsATotalBoundNotPerPhase`
  ——`/bin/sh` 是 dash，不认 `exec -a`；`testDocWriteFailureStillPersistsProgressToStore`
  ——没有 `chflags uchg`，「把文件锁成只读再写」这个前提造不出来（文档照常写成，
  拿不到 `DOC_WRITE_FAILED`）。本轮在 Linux 上实跑 722/725；macOS 上未实跑。
- **`graph arch` 系列的内存**：`--format json | html | scene` 会把整个图谱**加上每个模块的
  文件级下钻**都序列化出来，内存需求随仓库规模上涨。**仓颉运行时的默认堆上限偏小**，
  大仓库会 `OutOfMemoryError` —— 这不是算法问题：用 `cjHeapSize` 提高堆即可
  （**必须带单位**，如 `1gb`；范围 `[4MB, 系统内存]`，不带单位会被静默忽略）。
  `scripts/cambium.sh` 与 `install.sh` 安装出的启动器已默认注入 `cjHeapSize=1gb`
  （**不覆盖**你显式设置的值）；直接跑 `target/release/bin/main`、或客户端内嵌引擎副本时需自行设置。
  发布包（`scripts/package-release.sh` 生成的 `cambium-v*.tar.gz`）根部同样带这个启动器，
  且**自带仓颉 runtime dylib**（`runtime/lib/`）、二进制只保留 `@executable_path` 相对 rpath ——
  解包后 `env -i ./cambium --help` 能跑即为包自包含的判据；产物在本地生成，不入库（见 `.gitignore`）。
  实测：deepGit / deepOrca / ddolphin 的 `--format json | html | scene` 在默认堆下会崩或**时崩时通**，
  `cjHeapSize=1gb` 下三者恒定通过（deepOrca 的最小可用值是 `512mb`）。
  `--format dot | mermaid` 只出模块级依赖，始终轻量。
  `scene` 另有**单视图边数上限**（`SCENE_MAX_EDGES_PER_VIEW`）作为兜底：超限按权重降序保留
  （留最重的依赖），并在每个视图里**恒发** `edgesDropped`（0 = 完整）—— 截断会披露，不会静默；
  常规仓库（≤560 边/视图）`edgesDropped` 全为 0，不受影响。

## 发版（GitHub Releases）

**打 tag 即发版**：`.github/workflows/release.yml` 监听 `v*` tag，**并行**构建
macOS arm64 与 Linux x64 两个平台的 `cambium-<tag>-<平台>.tar.gz`，再由 release job
把两个资产挂到同一条 release 上。资产名带版本号（`cambium-v0.2.0-linux-x64.tar.gz`）。

- **客户端怎么取**：deepin 客户端的引擎下载链（`logic/EngineDownload`）走
  GitHub Releases「最新版本」API，按**平台后缀**挑资产（`linux-x64` / `darwin-arm64`），
  **不认死版本号** ⇒ 发了新 tag，客户端下一次检查就能拿到新引擎。
  mac 侧曾用固定 URL `releases/latest/download/cambium-darwin-arm64.tar.gz`
  （**无版本号**）⇒ 与实际资产名 `cambium-v0.1.0-darwin-arm64.tar.gz` 对不上 ⇒ 404。
  ⇒ **mac 侧要改成和 deepin 同一套「查 API + 按平台挑资产」**（已知待修）。
- **从哪条分支发**：⚠ **从 `dev` 发**（不是 `main`）。`main` 落后 `dev` 49 个提交
  （代码图谱 × 置信度热力图重做 + SQLite 图库/置信度库那批）⇒ 从 `main` 发的包
  **比客户端本机装的还旧**，客户端下载完反而降级。
  ⇒ 判据：**发布出去的引擎必须 ≥ 客户端当前使用的引擎**。
  （本条是 2026-10-20 自行拍板的：发版属「可逆的公开发布」，按协作规约第 2 条
  直接定，不停下来提问；理由与影响面记在这里。）
- **版本号是单一真相源**：`src/util/version.cj` 的 `ENGINE_VERSION` 是代码侧唯一出处；
  `cjpm.toml` 的 `version` 字段没法引用代码常量，由**测试**钉死两处同值
  （改一处忘另一处，测试立刻红）。CLI `version` 输出与 MCP `server.version`
  都取同一个常量。
- **重发同一个 tag**（改了 workflow 想重跑，或某个平台构建挂了）：用
  `workflow_dispatch` **显式填 tag**（如 `v0.2.0`）—— 手动触发时 `github.ref` 是**分支**，
  不显式指定就会 checkout 到分支的代码、还把 release 建在分支上（tag 指向空，
  客户端按 `releases/latest` 取不到）。
- **发版流水线的三个易踩点**（都实测踩过）：
  ① 仓库默认 `GITHUB_TOKEN` 权限可能是 read-only ⇒ 建 release 会被 API 拒 **403**
  ⇒ workflow 显式声明 `permissions: contents: write`；
  ② 产物必须是**自包含**布局（`cambium` 启动器 + `bin/cambium-cli` + `runtime/lib/`），
  验收口径 = `tar xzf <产物> -C /tmp/x && env -i /tmp/x/cambium --help`（`env -i` 是关键）；
  ③ **Linux 打包的依赖探测不能依赖构建环境** —— `ldd` 靠运行时的库搜索路径解析依赖，
  在 CI 的另一个 step（没 `source envsetup.sh`）里全部 `not found` ⇒ 会**静默**产出
  没有仓颉 runtime 的坏包，而流水线照样全绿 ⇒ 现在依赖清单改用 `readelf -d` 的
  `DT_NEEDED`、库来源改用 SDK 目录、找不到就 `exit 1`，且打包后**真的**解包跑一次。
- ⚠ **v0.2.0 的 Linux 资产是坏包**（`runtime/lib/` 是空的，装下来跑不起来；
  mac 资产是好的）—— 已在 **v0.2.1** 修好，用 v0.2.1。

<!-- deepgit:begin progress -->
## 项目进度

> 本区域由 **Cambium** 自动维护（浅更新）· 更新于 2026-10-10 17:13
> 追踪 4 个分支 · 2 处未提交改动

### 工程脉搏

- 提交构成：`feat` ×10 · `fix` ×13 · `perf` ×2 · `docs` ×2 · `chore` ×1 · `other` ×2
- 注意：`dev` 可直接 fast-forward 到 `main`

### `dev`（当前）

- **状态**：活跃 · 最近提交 2026-10-10 16:40（`82c21ff2` feat: patchconf entities 补 file/line 字段——客…）
- **摘要**：最近 30 个提交：修复×14、新增×10、文档×2、其他3类×4，（已达 30 条基线上限，此处为样本而非全部提交）
- **近期进展**
  - 新增：“patchconf entities 补 file/line 字段——客户端低置信度…
  - 新增：“AI 出口补齐——MCP codegraph_arch 出 scene 画布契约 + …
  - 修复：“dogfood 实测三连修——引擎对自己的文档不再无能为力”
  - 合并：“审计 47 条发现全链路修复（三轮：修复/复审残留清零/终…
  - 修复：“终审补漏——.c 路径双重扩展名 + 前置声明误入 stub 通道”
  - （另有 25 个提交未展开，见 journal）
- 本次记录 30 个提交 · 领先默认分支 29 个提交

### `main`（默认分支）

- **状态**：活跃 · 最近提交 2026-10-07 22:41（`3152b96f` feat: CLI 外壳层双语（zh/en）—— 数据层早已双语…）
- **摘要**：最近 30 个提交：文档×14、新增×4、修复×4、其他4类×8，（已达 30 条基线上限，此处为样本而非全部提交）
- **近期进展**
  - 新增：“CLI 外壳层双语（zh/en）—— 数据层早已双语，补齐话术层”
  - 文档：“长周期路线图（Phase 1 数据深度 → Phase 2 动作扩展 → …
  - 修复：“skill 内容命名修正 deepgit→cambium（frontmatter/MCP …
  - 文档：“官网 landing page”
  - 文档：“官网 landing page（GitHub Pages）”
  - （另有 25 个提交未展开，见 journal）
- 本次记录 30 个提交

### `fix/audit-2026-10-09`

- **状态**：活跃 · 最近提交 2026-10-10 14:13（`6ad03637` fix: 终审补漏——.c 路径双重扩展名 + 前置声明误入…）
- **摘要**：最近 30 个提交：修复×14、新增×8、文档×5、其他2类×3，（已达 30 条基线上限，此处为样本而非全部提交）
- **近期进展**
  - 修复：“终审补漏——.c 路径双重扩展名 + 前置声明误入 stub 通道”
  - 修复：“清零审计复审残留（M3 重修/L10 收紧/L15 预分配 + 9 条…
  - 文档：“审计复审（针对 74abba5）：35 全修 / 9 部分 / 3 未修…
  - 修复：“修复 audit-2026-10-09 全部 47 条发现（5 high / 26 me…
  - 文档：“引擎全面审查报告归档（47 条发现：5 high / 26 medium …
  - （另有 25 个提交未展开，见 journal）
- **下一步**
  - 推进该分支的收尾与验证，考虑合并回默认分支
- 本次记录 30 个提交 · 领先默认分支 25 个提交

### `graph/confidence-hardening`

- **状态**：活跃 · 最近提交 2026-10-09 03:04（`a45d24bb` fix(graph): 修大仓库 OutOfMemoryError —— 真因是…）
- **摘要**：最近 30 个提交：修复×13、新增×5、文档×5、其他5类×7，（已达 30 条基线上限，此处为样本而非全部提交）
- **近期进展**
  - 修复：“修大仓库 OutOfMemoryError —— 真因是运行期堆上限（cjH…
  - 修复：“scene 出口加单视图边数上限 + 披露（修大仓库 OutOfMem…
  - 性能：“stripCode 零拷贝快路径（与 stripComment 同款）”
  - 构建/依赖：“清理自审判定的死符号（13 个孤儿中移除 4 个无引…
  - 修复：“架构图补上 _ord —— JS 读的字段不在 archJson 的节点形…
  - （另有 25 个提交未展开，见 journal）
- 本次记录 30 个提交 · 领先默认分支 17 个提交
<!-- deepgit:end progress -->
