# Cambium Engine（Sylva 家族）— 路线图与现状

> **定位**：AI 无关的确定性项目群进度内核 + 代码事实引擎。引擎只回答「事实是什么」和
> 「能做什么」；判断与表达由上层（Canopy / MCP 宿主 / 任意 agent）完成。
>
> **版本节奏**：按能力批次发 minor（0.x），1.0 为 API 冻结的稳定版。
>
> **跨平台**：macOS arm64、Linux x64 已随 release 发版 → Windows x64 → 鸿蒙 PC。

**已发版**：`v0.1.0`（2026-10-07）· `v0.2.0`、`v0.2.1`（2026-10-20）。
**v0.3.0** 的代码在 `feat/conf-join`（置信度 × 索引 × 热力图协同）与 `feat/skill-docs`（叠在前者之上：
skill / 帮助 / 文档 / 版本 + 索引查询补丁）两条分支上，**尚未打 tag 发版**——打 tag 即触发公开发版，
这一步留给维护者。内容：代码索引 schema v2 与 `index` 命令、MCP 九个 `index_*` 工具、skill 面向索引重写、
疑点挂符号键、渲染过期校验、热力图定位串、扫描器三处缺陷与假自环的修复。

---

## 已交付（原路线图之外、实际先做了的）

| 能力 | 入口 | 状态 |
|---|---|---|
| 项目群进度内核：注册 / 扫描 / 浅更新 / 深更新 / 追踪 / 里程碑 / 进度日志 / 仪表盘 / 报告 | `list` `add` `scan` `status` `track` `update` `deep` `journal` `milestone` `dashboard` `report` | 已发版 |
| 文档生成与完整性校验（README / AGENTS / CLAUDE 的托管区域） | `update --docs` `deep` `docs` `verify` | 已发版 |
| git 安全操作与 post-commit 钩子 | `git <pull\|push\|commit\|stash\|unstash\|fetch>`、`hook <install\|uninstall\|status>` | 已发版 |
| agent 三件套 | CLI（`--json`）/ `cambium mcp`（38 个工具）/ `cambium skill` | 已发版，持续补 |
| 代码图谱（符号索引 / 关系树 / 影响面）+ SQLite 图库 | `graph overview\|tree\|symbol\|impact`、`graph db` | 已发版 |
| 架构图（模块聚合 / 分层判定 / 泳道布局 / Canvas 交互图） | `arch gen\|update\|query`、`graph arch --format …` | 已发版 |
| 代码置信度（确定性疑点）+ 置信度库 + 热力图 | `cambium dendro gen\|query\|db`、`render index --confidence` | 已发版 |
| 补丁级置信度三层（算法信号 / agent 复核 / 合并） | `cambium dendro patch\|merge`、MCP `dendro_patch_confidence` / `_merge` | 已发版 |
| **代码索引 v2**：成员级符号、调用点、稳定 id、9 个 `index_*` 工具 | `index gen\|update\|overview\|search\|query\|file\|refs\|impact\|grep` | v0.3.0（未发版） |
| **置信度 × 索引 × 热力图协同**：疑点带符号键（与索引同键）、孤儿与幻觉调用吃解析后的调用点、渲染过期校验、热力图定位串与复制 | `confidence gen\|query`、`render index --confidence` | v0.3.0（未发版） |
| **品牌升级 Sylva**：引擎 Cambium（命令 `cambium`，旧名 `moongit` / `deepgit` 留软链）、置信度剥离成引擎内独立包 **Dendro**（`src/dendro`，命令 `cambium dendro …`、MCP `dendro_*`，旧名全是别名）；数据面身份不变 | `cambium dendro …`、`cambium version` | v0.3.0（未发版） |
| **图谱产物嵌入模式 + 嵌入尺寸融合**：宿主声明配置后产物收拢外壳、改走宿主主题与控件尺寸；嵌入时按视口排布（架构图泳道折行、热力图按区域选列 / 色带包卡 / 通栏底条），视口变化重取景；`arch.json` 带 `geo`，旧形状自愈重建 | `render index\|arch`（产物自带，模板 3） | v0.3.0（未发版） |

---

## 代码索引线 · 本轮没做、下一步做的

按「对 agent 定位代码的影响」排序：

| # | 项 | 现状 | 要做到 |
|---|---|---|---|
| I.1 | **属性 / 字段索引** | 只索引函数与类型（7 种 `kind`），字段不出现在 `nodes` | 字段 / 属性作为符号入表，带所属类型 |
| I.2 | **真增量** | `index update` 是探针增量：源没变跳过，变了**整库重建** | 按文件增量解析，只重算变过的文件与其调用点 |
| I.3 | **接收者类型解析** | 接收者调用按裸名解析，`resolved` 边可能误连（探针上 1508 条里 815 条的证据来自带接收者的调用） | 至少对「本文件 / 本类型内可见的成员」做类型感知解析 |
| I.4 | **孤儿检测的证据升级** | 「被引用」仍是名字级（裸名在任意非声明处出现），同名不同物会漏报 | 在不把「当类型用 / 按名引用的槽函数 / 字符串插值里的调用」误判成孤儿的前提下收紧 |
| I.5 | **两遍词法扫描合一** | 成员级扫描器与 `build.cj` 的引用遍各有一套口径，偶有不一致 | 一遍扫描产出带分类的 token 流，图谱 / 引用 / 未解析 / 架构引用都从它取 |
| I.6 | **MCP `outputSchema`** | 只有 `inputSchema`；返回形状靠 `structuredContent` 与描述文字约定 | 给每个工具声明 `outputSchema` |
| I.6b | **一行多声明** | 扫描器一行只记一个符号起点，同一行闭合括号之后的声明不记 | 逐段扫描一行内的多个声明起点 |
| I.7 | **跨编辑恒定的符号身份** | 稳定 id 含行号，代码挪了行就变 | 增加按 `qual` 的别名查找（已在 `index query` 支持限定名），文档明示 id 的有效期 |
| I.8 | **带接收者的未解析调用入疑点** | `unresolved-call` 只报自由调用 | 接收者是工程内类型时，未解析的成员调用才报——需要 I.3 |
| I.9 | **macOS 客户端接入 `index_*`** | 引擎侧 CLI 与 MCP 就绪；macOS 客户端 AgentCore 未接入 5 个查询工具 | 客户端工具循环接入 |
| I.10 | **Linux 环境红夹具跨平台化** | 3 条用例的夹具依赖 macOS / bash 行为 | 改夹具而不是改断言（`AGENTS.md` 不变量 148） |
| I.11 | **两份工具清单并表** | MCP 与 `tools --json` 现行工具名只有 23 个同名 | 并表要动客户端分发表，另起一轮 |
| I.12 | **幻觉调用的精度** | `unresolved-call` 只是「全仓没有该名字的裸调用」：框架密集的工程上抽 20 条 0 条是真的编造 API | 需要框架 / 依赖名单或类型信息；在那之前按 README 写明的口径转述 |
| I.13 | **嵌套函数与 lambda 入表** | 不入符号表：里面的调用挂在最外层函数上；它们的定义行曾因此被当成幻觉调用 | 作为成员级符号入表，带所属函数 |
| I.14 | **行中开的块注释跨行跟踪** | `int x; /**< 说明` 换行续写：续行在提及证据里仍算代码 | 剥注释统一走带状态的那一份（与 I.5 一起做） |
| I.15 | **卷可达性预检** | 靠起 `stat` 进程、预算 1.2 秒：高负载下把可达的卷判成超时并缓存 60 秒 | 用文件系统调用代替子进程；超时不缓存或缩短缓存 |
| I.17 | **payload 读取性能** | `fromUtf8Lossy` 约 70ms/MB：5MB 的 index.json 每次渲染都要读一遍（约 0.35 秒，仅解码） | 合法 UTF-8 走快速路径直接构造；或 payload 分块 / 二进制化 |
| I.16 | **`emit sig(` 被当成声明** | Qt 信号发射行被扫描器当成声明（探针上造成一处假符号） | 识别 `emit` 关键字 |

---

## 原路线图条目的现状

### Phase 1 — 数据深度与可靠性

| # | 特性 | 现状 | 说明 |
|---|---|---|---|
| 1.1 | 进度差分 `diff` | 未做 | 两次快照之间的结构化 delta |
| 1.2 | 速度追踪 `velocity` | 未做 | 按周 / 月的提交速率与趋势 |
| 1.3 | 子进程生命周期管理 | **已交付** | `execCapture` 超时路径杀子进程（util/exec.cj 的用例组） |
| 1.4 | 并发 serve | **已废弃** | HTTP 服务端已整体删除；传输层只有 CLI 子进程与 MCP(stdio)，零 socket |
| 1.5 | Linux x64 二进制 | **已交付** | release 流水线产出 `cambium-<tag>-linux-x64.tar.gz`（`AGENTS.md` 不变量 140） |
| 1.6 | 数据导出 `export` | 形态变了 | 没有独立的 `export` 命令；每个命令都有 `--json`，`report --out` 导出 Markdown |
| 1.7 | registry v2 | 部分交付 | 项目群（group）与标签（tags）已有；排序权重未做 |
| 1.8 | 进度历史 HTTP API | **已废弃**（HTTP 形态） | 数据在 `journal` / MCP `get_journal` 里；没有 HTTP 端点 |

### Phase 2 — 动作扩展与自动化

| # | 特性 | 现状 | 说明 |
|---|---|---|---|
| 2.1 | watch 模式 | 部分交付 | post-commit 钩子 → `track` 已有；inotify / fsevents 监听与定时 update 未做 |
| 2.2 | 分支生命周期 | 未做 | 现有 git 操作是 pull / push / commit / stash / unstash / fetch |
| 2.3 | 多根扫描 | **已交付** | `scan [根目录…] [--depth N] [--git-only]` |
| 2.4 | webhook 通知 | 搁置 | 向外发 HTTP 与「零 socket」红线冲突；由上层（MCP 宿主 / 客户端）在 update 后自行通知 |
| 2.5 | 查询语言 | 未做 | — |
| 2.6 | 模板系统 | 未做 | — |
| 2.7 | Windows x64 二进制 | 未做 | — |
| 2.8 | 进度快照回滚 | 未做 | 只有备份保留（`update.backupKeep`），没有回滚命令 |

### Phase 3 — 协作与远程

| # | 特性 | 现状 | 说明 |
|---|---|---|---|
| 3.1 | 远程同步协议 | 未做 | — |
| 3.2 | 团队聚合 | 未做 | — |
| 3.3 | review 工作流 | 未做 | — |
| 3.4 | Web Dashboard | **已废弃** | 依赖已删除的 HTTP 服务端 |
| 3.5 | OpenAPI 规范 | **已废弃** | 没有 HTTP API 可描述；对外契约是 CLI `--json` 与 MCP |

### Phase 4 — 生态与智能（未开始）

| # | 特性 | 说明 |
|---|---|---|
| 4.1 | 插件系统 | 自定义命令注册；自定义数据源（Jira / GitHub Issues） |
| 4.2 | IDE 扩展 | VS Code 扩展（读引擎 MCP）；JetBrains 插件 |
| 4.3 | AI agent 框架 | 引擎内置轻量 agent 循环（可选启用）；引擎仍不绑定 LLM |
| 4.4 | 指标插件 | 测试覆盖率趋势 / 复杂度趋势 / 构建成功率 |
| 4.5 | 自定义仪表盘 | 用户定义布局 |
| 4.6 | API 冻结 | 1.0 冻结 CLI 参数名 / JSON 键名 / MCP 工具签名；后续只增不改 |

---

## 客户端跟进（Canopy 对应表）

| 引擎能力 | Canopy 需要的 |
|---|---|
| 疑点符号键 / 渲染过期校验 / 热力图定位串（v0.3.0） | CMP 客户端已接：镜像补符号键、置信度页显示限定名、快照过期自愈（渲染后读到过期回执就补生成快照再重绘）；macOS 客户端尚未同步 |
| 代码索引 v2（`index_*`） | AgentCore 接入查询工具；热力图按定位串跳转 |
| 1.1 进度差分 | 详情页「变化」tab |
| 1.2 速度追踪 | 仪表盘速度曲线图 |
| 1.6 数据导出 | 工具栏导出按钮 |
| 1.7 registry v2 | 侧栏项目分组（排序权重落地后补自定义排序） |
| 2.1 watch 模式 | 设置页实时开关（inotify / 定时部分） |
| 2.2 分支生命周期 | 看板卡片分支操作 |
| 2.5 查询语言 | 搜索栏表达式模式 |
| 2.8 快照回滚 | 撤销按钮 |
| 3.1 远程同步 | 同步设置 + 冲突展示 |
| 3.2 团队聚合 | 团队页 |
| 4.1 插件 | 插件管理页 |

---

## 不做的事（Negative Space）

| 不做 | 理由 |
|---|---|
| 内置 LLM 调用 | AI 无关是核心架构决策；AI 在客户端 / 插件层 |
| 云服务 | 本地优先是核心价值；远程同步是协议不是服务 |
| 实时协作编辑 | 不是 Google Docs；进度是「事实记录」不是「文档编辑」 |
| Windows ARM64 | 需求不明确；先覆盖 x64 |
| HTTP 服务端 | 已整体删除：进程之间用 CLI 子进程与 MCP(stdio) 通信，零 socket |

> **更正一条旧记录**：本表原来写着「内置数据库（SQLite 等）——不做」。
> 自 2026-10-13（v0.2.0 之前）起，图库与置信度库就是单文件 SQLite
> （`graph db` / `confidence db` / `codegraph.db`，经系统 `libsqlite3`）。
> 红线守住的其实是三件事：**不引入数据库服务、不引入第三方仓颉包**（走系统 `libsqlite3`）、
> **JSON 仍是默认的出口形状**（SQLite 只作为可选的单文件落盘，给要自己写 SQL 的 agent）。
> 那一行与事实相反，删去；留这条说明，免得后来者按旧表去「纠正」现有实现。
