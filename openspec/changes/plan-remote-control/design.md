# plan-remote-control 设计摘要

## Context

当前 Windows 平台接口明确不提供输入注入，macOS 辅助功能只查询状态；公开媒体 API 无控制输入或授权契约。动机见 proposal.md。

本文件是既有设计迁移，lifecycle/delivery 均为 planned，能力尚未实现；此次只整理规格，不表示已授权实施，也不恢复已停止的产品开发。规格版本 0.1.0、产品基线 0.1.0、release-target unassigned。具体实现需另行进入 apply，并先解决下文的设计门槛。

### 已确认的公开产品约束

用户已确认 Windows/macOS 作为控制端和被控端，官方 Android 可控制电脑但不承担被控；屏幕观看与控制必须分别授权。

## Goals / Non-Goals

把请求/同意 UI、可信会话材料、平台能力和 SDK 输入执行分层，保证撤回与断开释放输入。非目标：本次不实现远控，不默认加入无人值守、剪贴板或多控制者。

## Decisions

以下划分保留用户已确定的边界；标为候选的内容仍是未实现的技术建议，不提升为已确认产品需求。

1. 公开客户端负责请求与状态，SDK 执行端再次检查当前控制权限。只隐藏按钮无法阻止未授权消息，因此不把 UI 当执行安全边界。

2. 控制授权绑定对端和当前会话，不从配对信任或观看授权推导。权限撤回、断开和身份变化都清理授权及按下状态；重连重新协商。

3. 候选输入契约包含能力、画面几何和事件生命周期，以便坐标映射正确；具体按键编码、组合键策略和事件序列待平台设计，不能把手机 SDK 接入等同于系统权限提升。

4. 有人确认与无人值守需要不同授权流程；当前只保留独立同意和可撤回约束，首版支持哪种模式尚待用户决定。

## Risks / Trade-offs

- 断线造成粘键 → 执行侧追踪按下状态，失效时释放，并做真实键鼠验收。
- 观看被升级为控制 → 独立授权材料及越权输入测试。
- 系统权限不足但界面显示可用 → 能力协商依据实际执行条件。

## Migration Plan

release-target 为 unassigned；先完成控制授权和输入协议评审，再实现 UI 状态与 SDK 适配。先分别验证 Windows/macOS 被控，再验证 Android 控制端。版本或能力不兼容时保持观看授权的既有边界，不启用控制。

## Decisions Required Before Implementation

无人值守首版范围、控制者数量、快捷键与输入映射、屏幕切换和平台权限撤回的细节需先确定；不能由本次迁移替用户决定。

当前计划文件已整理齐全，但这些门槛解决前不应声称具备可直接执行的最终接口设计。任何新增产品范围先更新版本计划，具体任务见 tasks.md，全部保持未完成。

## Sources

- [现有能力与构建边界](../../../README.md)
- [版本计划](../../../docs/version-plan.md)
- `windows/platform/platform_bridge.cpp`（仓库根目录相对路径）
- `macos/Platform/Sources/ShareHubPlatform/PlatformServices.swift`（仓库根目录相对路径）
- `packages/share_hub_media_api/README.md`（仓库根目录相对路径）
- 用户已确认的公开产品约束，已在本文件摘录；候选实现建议单独标明。本摘要不依赖任何非公开源码、部署环境或凭据。

## Cross-repository Development Plan

- 计划与阶段：[两仓开发计划 v0.1.0](../../../docs/superpowers/plans/2026-09-15-cross-repository-development.md)，**U / M 之后，未排期**。
- 本仓职责：控制授权交互、公开输入契约与控制端状态；协作对象为 closed:plan-remote-control-engine。
- 前置条件：先指定 release-target；依赖 C 身份、M 几何/画面和 A 资格；先验收桌面控制端，Android 组合在 N 后补齐。
- 联合验收：与闭源 U 联测真实系统输入、仅观看越权拒绝、失焦输入释放、断线/停止/权限失效撤权；未完成 Android 任务不归档。
- 本节补开发顺序和分阶段依赖，保留上文的未决设计与发布目标；不能把工程联调结果当作正式上线资格。
