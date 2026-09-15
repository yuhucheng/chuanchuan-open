# OpenSpec 规格与版本管理

本仓使用 [Fission-AI OpenSpec](https://github.com/Fission-AI/OpenSpec)，固定 CLI **1.13.0**。它是研发文档工具，不是客户端运行时依赖。结构遵循官方 `spec-driven`；版本前言与 `catalog.json` 是本项目增加的约定。

## 入口与目录

- [规格索引](../../openspec/README.md)：能力、待办变化、来源和当前边界。
- [机器可读清单](../../openspec/catalog.json)：每份规格的 ID、路径、版本、生命周期和目标版本。
- `openspec/specs/<capability>/spec.md`：当前能力和已生效架构约束的基线；每份单独列出未通过的验证。
- `openspec/changes/<change>/`：尚未完成的变化，含提案、设计、增量规格和未勾选任务。
- `openspec/changes/archive/`：完成后的历史变更。不要把未实现设计移进去。
- `.agents/skills/openspec-*`：官方 CLI 生成的 Codex 工作流；仓库约束集中放在 config、AGENTS 和本文，不手工修改生成内容。

## 三类版本分别维护

| 版本 | 来源 | 含义 |
| --- | --- | --- |
| 产品基线 | 根目录 `VERSION`，当前 `0.1.0` | 当前研发目标；不是已经发布的稳定版 |
| 规格版本 | 每份 `spec-version`，首次导入 `0.1.0` | 该能力需求文本的修订版本；各能力独立演进 |
| 公共 API 版本 | `share_hub_media_api` 的包版本，当前 `0.1.0` | 客户端与 SDK 的契约兼容性；不随规格或产品版本机械升级 |

规格修订按语义版本维护：不改变要求的澄清/修正递增 patch；向后兼容的新增要求递增 minor；不兼容的契约改变递增 major。尚在 `0.x` 阶段也必须在提案中说明兼容性，不能靠版本号掩盖破坏性变化。版本号不放进能力目录名；历史通过 Git 和归档 change 保留。

`release-target` 只允许版本计划已经列出的版本，或 `unassigned`。后者表示已有需求但尚未排期，不能为了填字段新造产品版本。初始导入统一规格版本不代表这些能力都将在 v0.1.0 交付。

每份基线/增量规格使用如下前言（字段使用简单、不加引号的标量）：

```yaml
---
spec-id: local-device-discovery
spec-version: 0.1.0
product-baseline: 0.1.0
release-target: 0.1.0
lifecycle: baseline
delivery: partial
---
```

- `lifecycle: baseline`：当前行为或已生效的架构约束；可以仍有平台验收缺口。
- `lifecycle: planned`：未实现设计，只能搭配 `delivery: planned`。
- 基线的 `delivery` 可为 `implemented`、`partial`、`experimental`；这些都不能替代 `Verification` 中的实测证据。
- `product-baseline` 和 catalog 的 `productVersion` 对齐当前 `VERSION`；升级产品时统一审阅更新。
- 新增/移动/归档规格或修改版本时，同时更新前言、catalog 和索引，校验器会检查遗漏和漂移。

标准基线有 `## Purpose` 和 `## Requirements`；增量使用 `## ADDED/MODIFIED/REMOVED/RENAMED Requirements`。保留英文结构关键字，正文用中文。每项 `### Requirement:` 包含 MUST/SHALL 和至少一个 `#### Scenario:`，场景写清 WHEN/THEN。

## 日常使用

先遵循 [分支规则](branch-management.md) 和 [版本计划](../version-plan.md)，使用既有 main。新克隆先安装 Git 钩子，不跳过检查。Node.js 最低 20.19.0：

```powershell
pwsh -File tool/install_git_hooks.ps1
npm ci
$env:OPENSPEC_TELEMETRY = '0'
npm run spec:list
npm run spec:changes
npm run spec:test
npm run spec:validate
```

npm 锁文件使 CLI 可重复安装；不要求修改机器的全局 OpenSpec 版本。其他 CLI 操作使用 `npm exec -- openspec ...`，运行前先安装依赖。Codex 重新加载项目后可使用生成的 `$openspec-propose` 工作流。

### 新需求或行为变化

1. 读相关 baseline 和已有 change，确定要求归属、公开契约和具体版本计划。
2. 用 `npm exec -- openspec new change <change-id>` 或 Codex 的 OpenSpec 提案工作流创建变更。
3. 编写 proposal、design、增量 specs、tasks；记录来源、未决问题、目标版本和验证方案。仅创建这些文件不表示功能已实现。
4. 更新 catalog，并运行 `npm run spec:validate`。同一个能力的 baseline 和 planned delta 可以同时存在；本项目不同时维护两个 planned change 修改同一能力，需先整合或明确依赖后调整清单约束。
5. 在用户授权的范围内实现，逐项执行测试；模拟测试、实机验证、双机互通和上线结果分别记录。
6. 完成后核对 tasks 和验收证据，再执行 `npm exec -- openspec archive <change-id>`。OpenSpec 同步要求文本不等于自动维护本项目版本信息：归档后要同步前言、catalog、索引和 Verification，再运行全部规格校验。保留已知验收限制。

文档齐全、`openspec status` 显示工件 complete、CLI 校验通过，均只证明规格工件有效；不能据此勾选实现任务或声称能力交付。本次迁入的所有 planned changes 保持未执行。

## 来源、公开边界与历史

- 用户最新决定、AGENTS 和版本计划控制任务范围；规格正文必须与当前代码/验证边界一致。
- 旧设计继续保留为详细背景，过时方案在迁移索引明确标识。不篡改原始测试失败或原来的验证范围。
- 公开媒体契约由开源仓唯一维护。闭源 SDK/服务规格引用它，不能复制一份独立演进的公开契约。
- 公开文档可独立阅读，不要求访问私有仓；不写入生产密钥、凭据、私有实例或内部服务器信息。
- 不因使用 MIT 授权的 OpenSpec 工具改变产品源码许可证；生成工作流保留上游许可元数据。

## 校验范围

`npm run spec:validate` 先执行官方 `openspec validate --all --strict --no-interactive`，再检查版本与完整清单。版本工具覆盖版本漂移、未登记版本、路径越界、重复条目、漏列和计划冒充基线等问题；它不验证功能实现、平台运行结果或网络是否可达。

`npm run spec:test` 用临时目录验证校验器的失败路径，不修改实际规格。CI 对规格、工具、版本计划和锁文件变化运行同样的检查。

官方参考：[项目初始化](https://openspec.dev/docs/setup)、[CLI](https://openspec.dev/docs/cli)、[项目配置](https://openspec.dev/docs/configuration/config-yaml)。
