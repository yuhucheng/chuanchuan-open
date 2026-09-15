# plan-sdk-distribution

## Why

正常客户端已统一要求 SDK，但当前开发适配包不是正式闭源二进制交付。迁移既有分发目标，记录贡献者获取 SDK、版本兼容、依赖通知与真实平台发行验收要求。

本提案为既有设计迁移，lifecycle 为 planned、delivery 为 planned；尚未实现，任务清单不表示已授权开发，也不恢复此前停止的产品功能实施。规格版本为 0.1.0，产品基线为 0.1.0，release-target 为 0.1.0（开发归属，不是稳定版发布日期或完成承诺）。

## What Changes

- 保持标准 SDK 包布局和唯一客户端入口，计划提供贡献者可取得的正式 SDK。
- 定义 SDK/公共 API/平台与制品身份的兼容说明，以及缺失、损坏或不兼容的错误区分。
- 明确开发适配器与正式制品、可信签名与普通构建检查的差异。
- 本次仅形成规划文档；未决技术建议和实现授权需在开始 apply 前按版本计划处理。

## Capabilities

### New Capabilities

- `sdk-consumption`: 正式 SDK 的客户端消费、兼容诊断及制品说明。

### Modified Capabilities

无。当前基线保持原状；待接口方案明确后再以独立变更描述确有影响的 API 要求。

## Impact

未来涉及 SDK 配置工具、公开包契约、客户端构建与发布文档；二进制 ABI、平台封装和 SDK 制品由 SDK 维护方提供。公开侧不需要 SDK 实现源码或签名私钥。

未决范围：正式 ABI、平台制品格式、可信签名渠道、下载入口与稳定发行平台清单尚未确定；当前不能提供虚构链接或发布日期。

## Sources

- [产品范围与当前状态](../../../README.md)
- [版本计划](../../../docs/version-plan.md)
- [公共媒体契约](../../../packages/share_hub_media_api/README.md)
- 用户已确认的公开产品约束与既有设计整理，详见本变更 design.md；未决选择没有提升为确认需求。
