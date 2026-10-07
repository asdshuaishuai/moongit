# moonGit Engine — 长周期路线图

> **定位**：AI 无关的确定性项目群进度内核。引擎只回答「事实是什么」和「能做什么」；
> 判断与表达由上层（deepDolphin / MCP 宿主 / 任意 agent）完成。
>
> **版本节奏**：每 6-8 周一个 minor 版本（0.x），1.0 为 API 冻结的稳定版。
>
> **跨平台**：macOS ARM64（首发）→ Linux x64 → Windows x64 → 鸿蒙 PC。

---

## Phase 1 — 数据深度与可靠性（v0.2.x）

**目标**：让引擎的"事实"从「快照」升级为「趋势」，让子进程生命周期可控。

| # | 特性 | 说明 | 客户端影响 |
|---|------|------|-----------|
| 1.1 | **进度差分** `diff` | 两次快照之间：新增/消失了哪些分支、提交增减、里程碑状态变化。输出结构化 delta | 客户端可展示"自上次以来发生了什么"而不是每次全量刷新 |
| 1.2 | **速度追踪** `velocity` | 按周/月的提交速率（per project / per branch / per author），趋势方向（加速/减速/停滞） | 仪表盘增加速度曲线图 |
| 1.3 | **子进程生命周期管理** | execCapture 超时路径 kill 子进程（用信号量 + waitpid WNOHANG 轮询）；泄漏有界化 | 无感（引擎内部） |
| 1.4 | **并发 serve** | HTTP serve 从串行 accept 改为 thread-per-connection + 连接池；慢请求不再阻塞全局 | 面板多请求并发不排队 |
| 1.5 | **Linux x64 二进制** | GitHub Actions 自动构建 Linux 版，Cangjie SDK Linux 安装 | Linux 客户端可用 |
| 1.6 | **数据导出** `export --format json\|csv\|md` | 任意查询结果导出为文件；为 agent 和 CI 提供结构化数据 | 客户端"导出"按钮 |
| 1.7 | **registry v2** | 注册表支持项目分组（group）、标签（tags）、排序权重 | 侧栏项目分组展示 |
| 1.8 | **进度历史 API** `GET /api/history?project=&range=` | 从 journal.jsonl 构建时间序列数据点 | 图表库绘制进度变化曲线 |

---

## Phase 2 — 动作扩展与自动化（v0.3.x–v0.4.x）

**目标**：引擎从"只读+浅写"扩展为"可编排的自动化平台"。

| # | 特性 | 说明 | 客户端影响 |
|---|------|------|-----------|
| 2.1 | **watch 模式** `moongit watch` | fsevents / inotify 监听文件变更 → 自动 track；`--interval` 定时自动 update | 客户端"实时模式"开关 |
| 2.2 | **分支生命周期** `branch create/merge/delete` | 安全白名单扩展：merge 需 ff-only 或确认；delete 需已合入；不支持 force | 客户端看板卡片上的分支操作按钮 |
| 2.3 | **多根扫描** `scan --root A --root B` | 一次扫描多个目录；跨根去重 | 客户端批量添加支持多目录 |
| 2.4 | **webhook 通知** `hook webhook <url>` | 事件驱动：update 完成 / 里程碑达成 / 分支停滞 → POST JSON 到指定 URL | 设置页 webhook 管理 UI |
| 2.5 | **查询语言** `query "dirty>10 AND stale AND lang=swift"` | 结构化过滤表达式，替代 if-else 组合；MCP tool `query_projects` | 客户端搜索栏升级为表达式输入 |
| 2.6 | **模板系统** `template list/apply` | 托管区域内容模板：自定义 README 格式、里程碑格式、报告格式 | 客户端模板选择器 |
| 2.7 | **Windows x64 二进制** | Cangjie Windows 工具链；路径分隔符/编码适配 | Windows 客户端可用 |
| 2.8 | **进度快照回滚** `snapshot rollback <id>` | 进度库（非 git）误写回滚；快照 list/create/restore | 客户端"撤销"按钮 |

---

## Phase 3 — 协作与远程（v0.5.x）

**目标**：从单机工具扩展为"可同步的团队基础设施"。

| # | 特性 | 说明 | 客户端影响 |
|---|------|------|-----------|
| 3.1 | **远程同步协议** | moonGit sync pull/push：进度库推送到远端 JSON 文件（Git 仓库 / S3 / 自建服务器）；多机冲突解决 | 客户端同步设置 + 冲突展示 |
| 3.2 | **团队聚合** | 多台机器的 registry 合并到一个视图；按 author 维度统计 | 客户端"团队"页 |
| 3.3 | **review 工作流** | 进度更新需要 review（像 PR 一样 approve/reject）；reviewer 留痕 | 客户端 review 队列 |
| 3.4 | **Web Dashboard** | 自托管只读 Web 面板（引擎 serve 内置 HTML），手机浏览器可看 | 客户端可选（有 Web 就够了） |
| 3.5 | **OpenAPI 规范** | 输出 OpenAPI 3.0 JSON；第三方可用代码生成器自动生成客户端 | 第三方集成成本→0 |

---

## Phase 4 — 生态与智能（v1.0+）

**目标**：从工具升级为可扩展的平台。

| # | 特性 | 说明 |
|---|------|------|
| 4.1 | **插件系统** | 自定义命令注册（`moongit plugin install <url>`）；自定义数据源（不只 git，还可接 Jira/GitHub Issues） |
| 4.2 | **IDE 扩展** | VS Code 扩展（读引擎 MCP）；JetBrains 插件 |
| 4.3 | **AI agent 框架** | 引擎内置轻量 agent 循环（可选启用）：注册工具 → LLM 推理 → 执行 → 反馈；但引擎仍不绑定 LLM |
| 4.4 | **指标插件** | 测试覆盖率趋势 / 代码复杂度趋势 / 构建成功率——作为新的数据维度 |
| 4.5 | **自定义仪表盘** | 用户定义 dashboard 布局（选择展示哪些卡片、排序、过滤条件） |
| 4.6 | **API 冻结** | 1.0 冻结 CLI 参数名 / HTTP 路径 / JSON 键名 / MCP 工具签名；后续只增不改 |

---

## 里程碑时间线（估算）

```
v0.1.0 ← 当前（已完成）
v0.2.0 ← Phase 1 核心（diff + velocity + Linux + 并发 serve）    ~6 周
v0.2.x ← Phase 1 补全（export + registry v2 + history API）      ~4 周
v0.3.0 ← Phase 2 核心（watch + branch ops + query language）     ~8 周
v0.4.0 ← Phase 2 补全（webhook + template + Windows）            ~6 周
v0.5.0 ← Phase 3 核心（sync + review + web dashboard）           ~10 周
v1.0.0 ← Phase 4（生态 + API 冻结）                               长期
```

---

## 客户端跟进（deepDolphin 对应表）

引擎每新增一个端点，客户端需要新增对应的 UI：

| 引擎能力 | deepDolphin 需要的 UI |
|---|---|
| 1.1 进度差分 | 详情页"变化"tab |
| 1.2 速度追踪 | 仪表盘速度曲线图 |
| 1.6 数据导出 | 工具栏导出按钮 |
| 1.7 registry v2 | 侧栏项目分组 |
| 1.8 进度历史 API | 图表库 |
| 2.1 watch 模式 | 设置页实时开关 |
| 2.2 分支生命周期 | 看板卡片分支操作 |
| 2.5 查询语言 | 搜索栏表达式模式 |
| 2.8 快照回滚 | 撤销按钮 |
| 3.1 远程同步 | 同步设置 + 冲突展示 |
| 3.2 团队聚合 | 团队页 |
| 3.4 Web Dashboard | 无（引擎内置） |
| 4.1 插件 | 插件管理页 |

---

## 不做的事（Negative Space）

| 不做 | 理由 |
|---|---|
| 内置 LLM 调用 | AI 无关是核心架构决策；AI 在客户端/插件层 |
| 内置数据库（SQLite 等） | JSON 文件够用且 git 可追踪；零依赖是红线 |
| 云服务 | 本地优先是核心价值；远程同步是协议不是服务 |
| 实时协作编辑 | 不是 Google Docs；进度是"事实记录"不是"文档编辑" |
| Windows ARM64 | 需求不明确；先覆盖 x64 |
