# plan-android-client 设计摘要

## Context

本仓当前只有 Windows/macOS 宿主；发现协议能识别 android 标签，但这不是 Android 产品实现。所有相关远端会话和权限契约尚未完善。动机见 proposal.md。

本文件是既有设计迁移，lifecycle/delivery 均为 planned，能力尚未实现；此次只整理规格，不表示已授权实施，也不恢复已停止的产品开发。规格版本 0.1.0、产品基线 0.1.0、release-target unassigned。具体实现需另行进入 apply，并先解决下文的设计门槛。

### 已确认的公开产品约束

官方 Android 保留画面发送/观看与文件发送/接收目标，并可控制 Windows/macOS 电脑；官方 Android 不承担被控，第三方可按实际平台条件适配被控 SDK。

## Goals / Non-Goals

形成 Android 官方客户端能力边界及公开宿主集成要求，保持必需 SDK 和能力协商方向。非目标：本次不创建 Android 宿主，不承诺第三方设备自动获得特权或固定上线版本。

## Decisions

以下划分保留用户已确定的边界；标为候选的内容仍是未实现的技术建议，不提升为已确认产品需求。

1. 未来 Android 宿主放在唯一公开客户端仓库，媒体/输入执行适配仍通过 SDK；另外建立客户端或无 SDK 构建会破坏现有工程边界。

2. UI 根据平台实际支持能力展示操作；支持目标未实现时保留明确状态。平台名称不能替代运行时能力和授权验证。

3. 候选平台方案需遵守录屏和存储授权以及后台运行规则，并在权限撤回或系统结束时通知会话。具体平台 API、后台服务类型和支持版本在 Android 实施时按官方文档核验，不在本次规格迁移中假定。

4. 第三方 Android 被控负责设备采集、输入适配与系统权限，公共协议只声明实际能力与会话语义；官方客户端与第三方被控的互通阶段独立验收。

## Risks / Trade-offs

- 桌面测试被误用为移动端证据 → Android 设备矩阵逐项实机记录。
- 后台或旋转变化破坏会话 → 平台生命周期和权限变化纳入协议与验收。
- 集成方夸大系统权限 → 按实际能力协商，无法执行时明确失败。

## Migration Plan

release-target 为 unassigned；先确定系统版本/设备矩阵和依赖能力的交付顺序，再设计公共契约及宿主。依次验证本机权限、连接、投屏、文件和控制端，跨能力失败保持独立状态；不兼容 SDK 不生成替代产品模式。

## Decisions Required Before Implementation

最低系统版本、设备矩阵、后台模型、存储交互、第三方互通范围与交付阶段均待设计；各依赖能力的版本不能由 Android 目标反向推定。

当前计划文件已整理齐全，但这些门槛解决前不应声称具备可直接执行的最终接口设计。任何新增产品范围先更新版本计划，具体任务见 tasks.md，全部保持未完成。

## Sources

- [现有能力与构建边界](../../../README.md)
- [版本计划](../../../docs/version-plan.md)
- `README.md`（仓库根目录相对路径）
- `pubspec.yaml`（仓库根目录相对路径）
- `packages/share_hub_media_api/README.md`（仓库根目录相对路径）
- `lib/platform/client_platform.dart`（仓库根目录相对路径）
- 用户已确认的公开产品约束，已在本文件摘录；候选实现建议单独标明。本摘要不依赖任何非公开源码、部署环境或凭据。

## Cross-repository Development Plan

- 计划与阶段：[两仓开发计划 v0.1.0](../../../docs/superpowers/plans/2026-09-15-cross-repository-development.md)，**N / 桌面能力稳定后，未排期**。
- 本仓职责：官方 Android 客户端、权限/生命周期与主控角色；协作对象为 closed:plan-android-host-sdk（第三方互通组合，不是官方宿主实现）。
- 前置条件：先指定 release-target；消费 C/M/A/K 的可用契约与包，F/U 按能力接入；第三方组合才依赖 H。
- 联合验收：真实 Android 上验证已有发送/观看/文件/控制能力；官方 Android 不变为被控，缺失能力和第三方未测项不宣称完成。
- 本节补开发顺序和分阶段依赖，保留上文的未决设计与发布目标；不能把工程联调结果当作正式上线资格。
