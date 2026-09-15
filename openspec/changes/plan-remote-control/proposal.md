# plan-remote-control

## Why

屏幕观看不授予操作他人设备的权利，当前客户端没有输入接收或注入能力。迁移既有远控目标，规划独立控制同意、能力检查与断开后输入释放。

本提案为既有设计迁移，lifecycle 为 planned、delivery 为 planned；尚未实现，任务清单不表示已授权开发，也不恢复此前停止的产品功能实施。规格版本为 0.1.0，产品基线为 0.1.0，release-target 为 unassigned（尚未排期）。

## What Changes

- 规划 Windows/macOS 的控制与被控，以及 Android 控制电脑的客户端职责。
- 将控制请求、允许、拒绝、撤回和连接断开映射为明确状态。
- 要求 SDK 在执行输入时验证授权，不把隐藏按钮或已配对视为执行授权。
- 本次仅形成规划文档；未决技术建议和实现授权需在开始 apply 前按版本计划处理。

## Capabilities

### New Capabilities

- `remote-control-client`: 控制端交互、被控同意、授权撤回与 SDK 输入会话。

### Modified Capabilities

无。当前基线保持原状；待接口方案明确后再以独立变更描述确有影响的 API 要求。

## Impact

未来涉及公开远控 UI、能力与会话协议，并依赖 SDK 输入映射及执行适配。现有 PreviewEngine 没有输入事件或控制授权接口；官方 Android 被控不属于本计划。

未决范围：首版是否支持无人值守、并发控制者、快捷键策略、输入坐标/屏幕几何协议、剪贴板和最低系统版本尚未确定。

## Sources

- [产品范围与当前状态](../../../README.md)
- [版本计划](../../../docs/version-plan.md)
- [公共媒体契约](../../../packages/share_hub_media_api/README.md)
- 用户已确认的公开产品约束与既有设计整理，详见本变更 design.md；未决选择没有提升为确认需求。
