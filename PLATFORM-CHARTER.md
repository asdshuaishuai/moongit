# deepGit 客户端跨平台能力章程

> **原则：四大平台交互 UI 不一致是自由，能力必须一致。**
> 能力的唯一来源是 deepGit Engine（AI 无关内核）的两种契约：CLI `--json` 与 MCP 工具输出。
> 本文档是各平台客户端（macOS / Windows / Linux / 鸿蒙 PC）的**能力对齐基准**——
> 任何一个平台缺一项能力，就是违反本章程。

## 1. 必备能力矩阵（全平台一致）

| # | 能力 | 引擎依赖 | 说明 |
|---|---|---|---|
| C1 | 引擎发现与拉起 | — | DEEPGIT_BIN → 应用内嵌副本 → 常见安装路径 → 用户 shell PATH；按需拉起引擎子进程并在退出时回收 |
| C2 | 状态轮询 | `status --json`、`dashboard --json` | 启动 + 周期（默认 5 分钟）+ 手动刷新 |
| C3 | 面板四页 | 同上 | 仪表盘（统计卡/语言分布/里程碑/活跃）、里程碑管理（CRUD+tag 自动达成）、项目详情（脉搏/提交构成/分支/日志）、文档平铺（README/AGENTS/CLAUDE） |
| C4 | 更新动作 | `update --json`、`deep --json` | 单项目 + 全部；浅/深两档 |
| C5 | **AI 整合更新** | 同上 + 客户端 AI 层 | 浅/深更新 + AI 摘要；一键项目说明；一键项目群说明；定时更新 + AI 简报通知 |
| C6 | AI 助手 | `context --json`、`tools --json` + 客户端 AI 层 | 上下文包 + 原生工具调用循环（≤4 轮），Markdown 渲染 |
| C7 | AI 设置 | —（客户端持有） | models.dev 目录驱动的 provider/model 选择器；key 存平台安全存储（macOS 钥匙串 / DPAPI / libsecret / 鸿蒙关键资产）；测试连通 |
| C8 | git 操作 | `git <op> <项目> --json` | 白名单 pull/push/commit/stash/unstash/fetch；结果输出区 |
| C9 | 里程碑管理 | `milestone <子命令> --json` | 新建（tag/date/desc）、达成/重开/放弃/删除 |
| C10 | 系统集成 | — | 托盘/菜单栏常驻速览；系统通知（更新完成/停滞提醒/定时简报）；开机自启 |
| C11 | 文档完整性承诺 | 引擎保证 | 客户端永远只经引擎写文档；不直接改写项目文件 |

> **AI 层归属客户端**（deepDesign 模式）：模型目录（models.dev）、provider 通道、
> 工具循环、key 存储全在客户端；引擎只供事实（`context --json`）与动作（`tools --json`）。

## 2. 各平台 UI 自由区（建议而非约束）

| 平台 | 形态 | UI 技术 | 系统集成点 |
|---|---|---|---|
| macOS ✅ | 菜单栏常驻（MenuBarExtra .window 速览）+ 主面板窗口 | SwiftUI | SMAppService 自启、UNUserNotificationCenter |
| Windows | 托盘图标弹窗 + 主面板窗口 | WinUI 3 / WPF | 注册表 Run 自启、Toast 通知 |
| Linux | StatusNotifier 托盘 + 主窗口 | GTK4 或 Tauri | XDG autostart、libnotify |
| 鸿蒙 PC | 应用常驻 + 原生窗口面板 | ArkUI | 关键资产存储、系统通知 |

交互差异自由发挥（托盘 vs 菜单栏、通知渠道、窗口形态），但**信息架构必须同构**：
总览 → 里程碑 → 项目详情，AI 能力按 C5–C7 全量提供。

## 3. 新平台客户端的验收清单

- [ ] C1–C11 全部实现（逐项对照；Linux/CUI 端的逐条状态与已知差异记在
      [linux/README.md](linux/README.md#ai-通道c5--c6--c7与系统集成c10)，
      图标一致性由 `assets/icon/check-icon.sh` 判定）
- [ ] 契约模型与 engine 仓库 `flow/*.cj` 的 JSON 键名一致（提交前对照）
- [ ] 无键时的降级路径：AI 未配置 → 更新动作仍可用（仅无摘要）
- [ ] 引擎不可达 → 明确报错 + 引导安装，不静默失败
- [ ] key 只进平台安全存储，不进日志/配置文件明文

## 3.5 平台 Canvas 分派（2026-10-10 修订）

图谱/架构图的渲染遵循引擎契约 [graph-scene-schema.md]（moonGit 仓库 docs/）的**分派规则**：

> **运行时渲染一律走平台 Canvas 实现，没有例外。**
> 引擎的 `graph arch/tree --format html` 单文件导出**不是渲染路径**，而是引擎层交付物——
> 供只有引擎层的环境（终端/CI）与其他智能体驱动场景消费。

| 平台 | Canvas 实现 | 数据 |
|---|---|---|
| macOS | SwiftUI GraphicsContext（`ArchCanvasView`，已实现） | `graph arch --format scene` |
| Linux（本仓 `linux/`，仓颉客户端） | **仓颉 Canvas 移植**（CangjieGUI 宿主，实现同一 Canvas2D 子集） | 同上 |
| DDE / deepin（本仓 `deepin/`，C++ 客户端） | **Qt QPainter Canvas**（实现同一子集） | 同上 |
| Windows / 鸿蒙 PC | 平台 Canvas 实现（排期，不做 Web 运行时渲染） | `--format scene` |

三条不变量（与引擎契约文档一致）：数据单来源（scene 契约，渲染端换栈数据零改动）；
平台渲染零外包（客户端存在的地方不允许打开浏览器看图）；平台 Canvas 以契约方法清单为
移植验收清单。HTML 导出的定位是引擎层交付物：只有引擎层的环境与其他智能体驱动场景
消费它（`graph tree` 默认即单文件交互图，`MoongitCodeGraph.renderTo`）。

## 4. 引擎侧为 agent 提供的能力（平台无关）

- **MCP**：`moongit mcp`（stdio JSON-RPC，23 工具：进度管理 14 + 代码图谱 6 + 补丁置信度 3）——任何 MCP 宿主接入
- **Skill**：`moongit skill print|install` —— 教学包（接入方式/任务配方/红线），供编码类 agent 学习使用
- **CLI**：`moongit context|tools|status|dashboard --json` 与 `graph overview|tree|symbol|impact|arch|confidence|patchconf` —— 一次性问答与脚本（客户端主通道）
