# plan-trusted-device-connections

## Why

当前设备页只能展示局域网存在记录，尚无可信配对、设备目录或会话信令。迁移既有连接设计，明确从发现到可验证连接的边界，为后续实现提供可审阅的需求。

本提案为既有设计迁移，lifecycle 为 planned、delivery 为 planned；尚未实现，任务清单不表示已授权开发，也不恢复此前停止的产品功能实施。规格版本为 0.1.0，产品基线为 0.1.0，release-target 为 0.1.0（开发归属，不是稳定版发布日期或完成承诺）。

## What Changes

- 把发现 UUID 与可信设备身份分离，建立配对拒绝、超时、取消和撤销边界。
- 整理客户端设备目录、已信任设备和实时发现的不同含义。
- 记录直连优先、辅助服务不阻塞局域网、自定义内网配置及分层失败诊断。
- 本次仅形成规划文档；未决技术建议和实现授权需在开始 apply 前按版本计划处理。

## Capabilities

### New Capabilities

- `trusted-pairing`: 设备身份验证、配对同意和本地移除信任。
- `device-directory`: 发现记录与可信设备资料分离，保留可达性和能力的真实状态。
- `connection-signaling`: 可取消的身份绑定信令、直连优先及官方/自定义内网辅助配置。

### Modified Capabilities

无。当前基线保持原状；待接口方案明确后再以独立变更描述确有影响的 API 要求。

## Impact

未来涉及 lib/features/devices、lib/platform/client_platform.dart、新的公开连接协议和会话适配。SDK 需要消费经过验证的对端身份和会话材料；现有 PreviewEngine 不具备这类接口。官方服务实现不属于本仓，公开文档仅定义互通行为。

未决范围：配对校验方式、身份密钥算法与存储、信令消息结构、具体服务发现与手动地址交互均未定；不得把短配对码、特定时限或独立目录服务视为已确认需求。

## Sources

- [产品范围与当前状态](../../../README.md)
- [版本计划](../../../docs/version-plan.md)
- [公共媒体契约](../../../packages/share_hub_media_api/README.md)
- 用户已确认的公开产品约束与既有设计整理，详见本变更 design.md；未决选择没有提升为确认需求。

## Cross-repository Development Plan

[两仓开发计划 v0.1.0](../../../docs/superpowers/plans/2026-09-15-cross-repository-development.md)统一本 change 的执行次序：**C / S0 契约，S1 本地，S2 辅助**。协作对象：closed:plan-connection-services。本仓交付：配对、目录状态、本地/辅助信令和公开连接契约。需求条款与 spec-version 保持不变；本次同步仅更新规划，不勾选实施任务。
