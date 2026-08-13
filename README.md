# dsh-graph-entry

<!-- DeepSeek Harness 衍生声明 -->
> **DeepSeek Harness 个人适配声明（Personal Adaptation Notice）**
>
> 本项目是 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的**个人适配产物（personal adaptation）**，**并非 DeepSeek Harness 官方文件（not an official DeepSeek Harness file）**，随附功能、使用说明与个人产物（bundled with features, documentation, and personal artifacts），可与 DeepSeek Harness 搭配使用，也可独立使用。
>
> This project is a **personal adaptation** for DeepSeek Harness, and is **NOT an official DeepSeek Harness file**, bundled with features, documentation, and personal artifacts. It can be used alongside DeepSeek Harness or standalone.

**作者 / Author**: [h565656445](https://github.com/h565656445)

**合作 / Collaboration**: 如有项目可以一起合作，欢迎联系。微信：`wohaishihenshuaide`。If you have projects, let's collaborate. WeChat: `wohaishihenshuaide`.


---

## 用途 / What this is for

GraphEntry 项目发现入口：从项目注册表生成机器注册表，按 Subject 定位项目/任务/图谱并核验漂移。

GraphEntry discovery entrypoint: generates the machine registry and locates projects/tasks/graphs with drift verification.

---
## Hermes Graph Entry / Project Discovery / Hermes 项目发现入口（GraphEntry）

GraphEntry 是 Hermes Harness 控制平面的只读发现入口：`graph_entry.ps1` 一次查询即可按 Subject 定位项目入口与 `entry_paths`；它只负责发现和核验——不派发任务、不批准副作用、不写完成状态。`generated/project_registry.json` 是注册表生成快照；`GraphEntry.Tests.ps1` 覆盖发现与核验行为。

GraphEntry is the read-only discovery entry of the Hermes Harness control plane: `graph_entry.ps1` locates project entries and `entry_paths` by Subject in one query. It only discovers and verifies — it never dispatches tasks, approves side effects, or writes completion state. `generated/project_registry.json` is a generated registry snapshot; `GraphEntry.Tests.ps1` covers discovery and verification.

## Features / 功能

- 只读发现：`-Subject projects` 一次查询返回全部项目入口 / Read-only discovery: one `-Subject projects` query returns all project entries
- 任务定位：`-Subject task:<id>` 直达 TaskContract 与账本 / `-Subject task:<id>` locates the TaskContract and ledger directly
- 投影输出：`-AsJson` 输出结构化投影 / Structured projection output via `-AsJson`
- 核验语义：发现与核验分离，不触碰权威镜像 / Verification-only semantics: never dispatches, approves, or writes completion
- Pester 套件：`GraphEntry.Tests.ps1` / Pester suite `GraphEntry.Tests.ps1`

## What's inside / 目录结构

```
dsh-graph-entry/
├── README.md
├── LICENSE
├── runner/graph_entry.ps1          # 只读发现入口
├── generated/project_registry.json # 注册表生成快照（示例）
├── tests/GraphEntry.Tests.ps1      # Pester 测试
└── .dsh/
```

## Quick start / 快速开始

```powershell
# 项目发现（推荐 PowerShell 7）
pwsh -NoProfile -ExecutionPolicy Bypass -File .\runner\graph_entry.ps1 -Subject projects -AsJson

# 按任务 ID 定位
pwsh -NoProfile -File .\runner\graph_entry.ps1 -Subject task:<task_id> -AsJson
```

## DeepSeek Harness 衍生 / DSH Derivative

本项目附带 DeepSeek Harness 衍生包，位于 `.dsh/` 目录：

- `preset.yml` — Agent 预设元数据
- `agent.cordis.yml` — Cordis 组装（基于 standard 预设，persona 已定制）
- `skills/dsh-graph-entry/SKILL.md` — 项目专属技能（skill）

安装与接入方式见 [`.dsh/README.md`](.dsh/README.md)（双语）。

## License / 许可证

[MIT](LICENSE)