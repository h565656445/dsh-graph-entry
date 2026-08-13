---
name: dsh-graph-entry
description: GraphEntry 只读项目发现与核验技能 / Read-only GraphEntry project discovery and verification skill
---

# Hermes 项目发现入口（GraphEntry） / Hermes Graph Entry / Project Discovery

本技能用于通过 GraphEntry 做只读项目发现：运行 graph_entry.ps1，按 Subject 输出投影并核对 entry_paths；发现不等于派发，不得借此写完成状态。

This skill covers read-only project discovery via GraphEntry: run graph_entry.ps1, emit the projection by Subject, and verify entry_paths. Discovery is not dispatch — never write completion state through it.

## When to use / 何时使用

需要定位项目入口、读取注册表投影或按任务 ID 追踪合同/账本时。

Use when locating project entries, reading registry projections, or tracking contracts/ledgers by task ID.

## Workflow / 工作流

1. 运行 graph_entry.ps1 -Subject projects -AsJson。
2. 定位目标项目及其 entry_paths。
3. 有任务 ID 时用 -Subject task:<id> 核对合同与账本。
4. 将投影结果交回调度方，不代写状态。

## References / 参考

- 项目 README: 见仓库根目录
- 作者: h565656445 (GitHub)