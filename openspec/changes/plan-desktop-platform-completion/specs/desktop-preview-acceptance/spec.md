---
spec-id: desktop-preview-acceptance
spec-version: 0.1.0
product-baseline: 0.1.0
release-target: 0.1.0
lifecycle: planned
delivery: planned
---

# 桌面真实预览验收

## Purpose

将既有设计中的桌面真实预览验收整理为可审阅的未来行为契约。初始迁移时能力尚未完成，当前实施进展见 Verification；规格版本独立维护，目标版本只说明规划归属，不代表已经授权开发、完成验收或承诺发布日期。

## ADDED Requirements

### Requirement: Windows 来源与真实首帧

Windows 预览验收 MUST 使用当前 SDK 集成产物，证明用户选中的真实窗口或显示器被正确采集并呈现；权限标志、插件注册或本地模拟回调不能代替画面证据。

#### Scenario: 显示具备采集能力但无画面

- **WHEN** 权限接口允许尝试采集，却未出现所选来源首帧
- **THEN** 该项验收失败，保持问题记录，不据权限值宣称预览通过。

### Requirement: macOS 当前插件布局

macOS 预览验收 MUST 对当前 SDK 插件布局重新构建并验证宿主注册、系统权限、明确来源、真实首帧和停止/恢复，不沿用旧无 SDK 产物的构建结果。

#### Scenario: 只有旧布局成功记录

- **WHEN** 历史 macOS 应用编译成功，但当前 SDK 插件没有构建记录
- **THEN** 当前布局继续标记待验收。

### Requirement: 隐私停止与证据归属

各平台验收 MUST 覆盖取消启动、权限失效、来源关闭、重复停止和资源释放，记录实际构建版本与平台；停止后不能继续更新采集画面。

#### Scenario: 权限撤回或用户停止

- **WHEN** 真实采集中用户停止或撤回权限
- **THEN** 终止采集并释放资源，失败必须记录，不能以关闭预览控件代替停止采集。

## Verification

2026-09-16 Windows 原始 PerMonitorV2 宿主已通过所选自建窗口的两次首帧、四象限像素、变化后重采、重复停止和来源关闭拒绝。原生回归 3 项、SDK 22 项和客户端 33 项测试通过；模拟生命周期证据单独记录。详情及历史失败见 [Windows DPI 验证](../../../../../docs/validation/windows-preview-dpi.md)。

显示器、多屏、完整生命周期与 Mac 当前插件实采仍未验收；整个 change 保持 planned，不能据窗口子集宣称全平台交付。仅更新验证证据，需求和规格版本保持 0.1.0。

本验收仅针对本地预览，不代替远端投屏和可信发行签名验收。

## Sources

- [公开设计摘要](../../design.md)
- [当前客户端边界](../../../../../README.md)
- [版本计划](../../../../../docs/version-plan.md)
- [主线验证缺口](../../../../../docs/validation/main-integration.md)
- [预览控制器测试](../../../../../test/preview_controller_test.dart)
