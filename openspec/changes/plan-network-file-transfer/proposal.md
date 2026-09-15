# plan-network-file-transfer

## Why

现有队列只生成本地摘要，没有网络发送或接收。迁移既有文件传送目标，明确双端授权、内容校验、取消与故障恢复，避免把 ready 状态当作送达。

本提案为既有设计迁移，lifecycle 为 planned、delivery 为 planned；尚未实现，任务清单不表示已授权开发，也不恢复此前停止的产品功能实施。规格版本为 0.1.0，产品基线为 0.1.0，release-target 为 unassigned（尚未排期）。

## What Changes

- 在已有本地文件令牌及摘要上规划版本化的文件传送协议。
- 要求接收侧独立同意与存储授权，发送前重新核验内容。
- 规划双端状态、完整性校验、取消、背压和受控恢复。
- 本次仅形成规划文档；未决技术建议和实现授权需在开始 apply 前按版本计划处理。

## Capabilities

### New Capabilities

- `network-file-transfer`: 可信连接上的文件发送、接收、进度、取消与失败处理。

### Modified Capabilities

无。当前基线保持原状；待接口方案明确后再以独立变更描述确有影响的 API 要求。

## Impact

未来涉及 lib/features/transfers、两端原生存储适配与公开通用连接协议。文件传送实现属于开源模块，正常产品构建仍要求 SDK；不能把本计划解释为恢复无 SDK 产品入口。

未决范围：冲突文件命名、目录传送、并发窗口、恢复粒度、覆盖确认及接收位置交互未定；未被用户确定的技术建议在设计阶段选择。

## Sources

- [产品范围与当前状态](../../../README.md)
- [版本计划](../../../docs/version-plan.md)
- [公共媒体契约](../../../packages/share_hub_media_api/README.md)
- 用户已确认的公开产品约束与既有设计整理，详见本变更 design.md；未决选择没有提升为确认需求。

## Cross-repository Development Plan

[两仓开发计划 v0.1.0](../../../docs/superpowers/plans/2026-09-15-cross-repository-development.md)统一本 change 的执行次序：**F / C 与本地准备之后，未排期**。协作对象：无需新增闭源文件实现；依赖 C 连接工作组。本仓交付：公开文件协议、发送/接收、摘要确认和恢复。需求条款与 spec-version 保持不变；本次同步仅更新规划，不勾选实施任务。
