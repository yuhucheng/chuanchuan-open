# plan-remote-screen-sharing

## Why

当前公共契约仅覆盖本地预览，无法代表另一台设备已经收到画面。迁移既有远端投屏目标，将来源同意、观看授权、真实首帧与媒体清理写成独立规划。

本提案为既有设计迁移，lifecycle 为 planned、delivery 为 planned；尚未实现，任务清单不表示已授权开发，也不恢复此前停止的产品功能实施。规格版本为 0.1.0，产品基线为 0.1.0，release-target 为 0.1.0（开发归属，不是稳定版发布日期或完成承诺）。

## What Changes

- 增加发送与观看的远端会话目标，不改变当前本地预览基线。
- 要求用户明确选择来源，对端与能力验证通过后建立会话，观看授权不包含控制权。
- 按真实对端画面和实际选中路径验收，保留权限变化、取消和来源失效的失败路径。
- 本次仅形成规划文档；未决技术建议和实现授权需在开始 apply 前按版本计划处理。

## Capabilities

### New Capabilities

- `remote-screen-sharing`: 可信设备之间的屏幕发送、观看、媒体状态及停止。

### Modified Capabilities

无。当前基线保持原状；待接口方案明确后再以独立变更描述确有影响的 API 要求。

## Impact

未来涉及公开 UI 与版本化远端媒体契约，并依赖可信连接、SDK 的采集/编码/传输/解码能力。不得将 SDK 实现放入公开仓库，也不得直接把 PreviewEngine 重命名为完整投屏会话。

未决范围：投屏音频、多显示器、一对多、最低操作系统版本、编解码组合和性能阈值尚未确定；应单独确认或实验后补充。

## Sources

- [产品范围与当前状态](../../../README.md)
- [版本计划](../../../docs/version-plan.md)
- [公共媒体契约](../../../packages/share_hub_media_api/README.md)
- 用户已确认的公开产品约束与既有设计整理，详见本变更 design.md；未决选择没有提升为确认需求。

## Cross-repository Development Plan

[两仓开发计划 v0.1.0](../../../docs/superpowers/plans/2026-09-15-cross-repository-development.md)统一本 change 的执行次序：**M / S3**。协作对象：closed:plan-media-sessions。本仓交付：远端发送/观看的公开状态、授权、来源选择和对端首帧展示。需求条款与 spec-version 保持不变；本次同步仅更新规划，不勾选实施任务。
