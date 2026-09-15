# plan-desktop-platform-completion

## Why

Windows 真实预览首帧与 macOS 新 SDK 插件布局仍有验收缺口，Windows 文件适配也尚未完成。迁移既有桌面补齐计划，按各平台真实产物和实际用户操作设置验收。

本提案为既有设计迁移，lifecycle 为 planned、delivery 为 planned；尚未实现，任务清单不表示已授权开发，也不恢复此前停止的产品功能实施。规格版本为 0.1.0，产品基线为 0.1.0，release-target 为 0.1.0（开发归属，不是稳定版发布日期或完成承诺）。

## What Changes

- 记录 Windows 真窗口和显示器预览，以及 macOS 新插件编译、来源、权限和释放验收。
- 计划实现与现有 FileAccess/TransferQueue 契约匹配的 Windows 原生适配。
- 使平台证据可追溯到具体构建，保留未通过项，不把旧布局构建当作新布局验证。
- 本次仅形成规划文档；未决技术建议和实现授权需在开始 apply 前按版本计划处理。

## Capabilities

### New Capabilities

- `desktop-preview-acceptance`: Windows/macOS 当前 SDK 预览布局的真实平台验收。
- `windows-file-preparation`: Windows 系统文件选择、受限读取与本地准备。

### Modified Capabilities

无。当前基线保持原状；待接口方案明确后再以独立变更描述确有影响的 API 要求。

## Impact

未来涉及 windows/platform、公开宿主注册、FileAccess 适配、平台测试及 SDK 配套修复。现有本地预览和文件准备基线仍保留；网络传输不在这组平台补齐工作中。

未决范围：最低系统版本、发布签名渠道和正式二进制包验收矩阵尚未确定。没有依据时不预设 Windows 首帧问题的根因或修复实现。

## Sources

- [产品范围与当前状态](../../../README.md)
- [版本计划](../../../docs/version-plan.md)
- [公共媒体契约](../../../packages/share_hub_media_api/README.md)
- 用户已确认的公开产品约束与既有设计整理，详见本变更 design.md；未决选择没有提升为确认需求。

## Cross-repository Development Plan

[两仓开发计划 v0.1.0](../../../docs/superpowers/plans/2026-09-15-cross-repository-development.md)统一本 change 的执行次序：**D / S0→S1**。协作对象：closed:plan-desktop-preview-acceptance。本仓交付：客户端宿主、预览编排与 Windows 文件准备。需求条款与 spec-version 保持不变；本次同步仅更新规划，不勾选实施任务。
