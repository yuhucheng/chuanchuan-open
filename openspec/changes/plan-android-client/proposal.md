# plan-android-client

## Why

Android 是既有产品目标，但当前仓库只有 Windows/macOS 宿主。迁移官方 Android 客户端范围，区分投屏、文件和作为电脑控制端的能力，与第三方 Android 被控适配分开。

本提案为既有设计迁移，lifecycle 为 planned、delivery 为 planned；尚未实现，任务清单不表示已授权开发，也不恢复此前停止的产品功能实施。规格版本为 0.1.0，产品基线为 0.1.0，release-target 为 unassigned（尚未排期）。

## What Changes

- 记录官方 Android 客户端发送/观看画面、文件收发及控制 Windows/macOS 的目标。
- 保持官方客户端不承担 Android 被控，第三方适配遵守实际系统权限与能力声明。
- 规划相同公共契约和必需 SDK 构建路线，以及前后台和权限失效处理。
- 本次仅形成规划文档；未决技术建议和实现授权需在开始 apply 前按版本计划处理。

## Capabilities

### New Capabilities

- `android-client`: 官方 Android 客户端平台职责、能力展示、权限和生命周期。

### Modified Capabilities

无。当前基线保持原状；待接口方案明确后再以独立变更描述确有影响的 API 要求。

## Impact

未来涉及本仓 Android 宿主与 UI 适配、SDK Android 平台包及能力契约。依赖连接、远端投屏、文件传送、激活和远控的相应可用子集；这些能力当前均不能由桌面测试证明。

未决范围：最低 Android 版本、支持设备矩阵、后台服务方案、移动端接收存储交互和官方客户端连接第三方被控端的互通阶段均待设计；不得承诺 SDK 自动提升系统权限。

## Sources

- [产品范围与当前状态](../../../README.md)
- [版本计划](../../../docs/version-plan.md)
- [公共媒体契约](../../../packages/share_hub_media_api/README.md)
- 用户已确认的公开产品约束与既有设计整理，详见本变更 design.md；未决选择没有提升为确认需求。
