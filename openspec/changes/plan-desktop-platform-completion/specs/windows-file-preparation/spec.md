---
spec-id: windows-file-preparation
spec-version: 0.1.0
product-baseline: 0.1.0
release-target: 0.1.0
lifecycle: planned
delivery: planned
---

# Windows 原生文件准备

## Purpose

将既有设计中的Windows 原生文件准备整理为可审阅的未来行为契约。当前能力尚未实现，本次仅迁移规格；规格版本独立维护，目标版本只说明规划归属，不代表已经授权开发、完成验收或承诺发布日期。

## ADDED Requirements

### Requirement: 系统选择器与令牌

Windows 文件适配 MUST 通过原生系统选择器取得普通文件的受限访问令牌，匹配现有公开文件访问契约；不接受界面或网络提供的任意路径。

#### Scenario: 未选择文件的读取请求

- **WHEN** 调用方提交未经选择器授权的令牌或任意路径
- **THEN** 拒绝读取，不泄露文件内容或建立新授权。

#### Scenario: 取消系统选择

- **WHEN** 用户关闭选择器而未确认文件
- **THEN** 返回空选择，保留现有队列。

### Requirement: 有界读取和变化检测

Windows 适配 MUST 支持现有 64 文件及 256 KiB 分块边界，验证读取范围、顺序和文件变化，并在最终确认时防止把不完整或已改变的文件标为 ready。

#### Scenario: 准备时文件变化

- **WHEN** 所选文件在读取或最终确认前发生变化
- **THEN** 返回明确失败，队列不发布可用摘要。

### Requirement: 取消与访问释放

Windows 适配 MUST 在取消、移除、清空和退出时释放原生访问；晚到的选择和读取不得使已关闭队列重新持有资源。

#### Scenario: 退出时选择器仍未完成

- **WHEN** 应用关闭队列后系统选择器才返回文件
- **THEN** 释放新取得的访问，不将文件加入或继续读取。

## Verification

- 现有 Windows 文件方法尚未实现；Flutter 队列 fake 测试不证明原生能力。
- 后续使用真实系统选择器和生成的测试文件验证普通文件、空文件、中文与空格名称、超限、变化、取消和句柄释放。
- 本能力不发送网络数据，ready 仍只表示本地准备完成。

所有场景均为待验收项；现有单元测试、局部平台构建与媒体实验不构成本能力已经交付的证据。

## Sources

- [公开设计摘要](../../design.md)
- [当前客户端边界](../../../../../README.md)
- [版本计划](../../../../../docs/version-plan.md)
- [公开文件访问](../../../../../lib/features/transfers/file_access.dart)
- [队列行为测试](../../../../../test/transfer_queue_test.dart)
- [macOS 现有文件适配](../../../../../macos/Platform/Sources/ShareHubPlatform/SelectedFileStore.swift)
