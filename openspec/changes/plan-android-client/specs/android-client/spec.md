---
spec-id: android-client
spec-version: 0.1.0
product-baseline: 0.1.0
release-target: unassigned
lifecycle: planned
delivery: planned
---

# 官方 Android 客户端

## Purpose

将既有设计中的官方 Android 客户端整理为可审阅的未来行为契约。当前能力尚未实现，本次仅迁移规格；规格版本独立维护，目标版本只说明规划归属，不代表已经授权开发、完成验收或承诺发布日期。

## ADDED Requirements

### Requirement: 官方平台范围

官方 Android 客户端 MUST 以屏幕发送/观看、文件发送/接收及控制 Windows/macOS 电脑为目标能力，并明确不提供官方 Android 被控入口；未实现的能力显示真实状态。

#### Scenario: 某目标能力尚未实现

- **WHEN** Android 版本尚不能接收文件
- **THEN** 界面明确能力不可用，不因产品路线图列出该能力就显示可执行成功入口。

### Requirement: 实际权限与生命周期

Android 客户端 MUST 按实际平台能力申请所需系统权限；拒绝、撤回、前后台或系统终止造成能力失效时更新状态并终止受影响会话，不宣称 SDK 能提升权限。

#### Scenario: 用户撤回投屏许可

- **WHEN** 正在发送画面时系统收回相关许可
- **THEN** 停止发送并通知对端，重新采集需重新满足平台授权。

### Requirement: 统一 SDK 和能力契约

Android 产品构建 MUST 通过本仓宿主消费匹配的 SDK 与公开契约，保持唯一客户端工程；只协商实际支持的观看、控制和文件能力。

#### Scenario: SDK 缺少 Android 能力

- **WHEN** 已安装的 SDK 包不支持目标架构或所需能力
- **THEN** 构建或运行阶段按兼容检查明确失败，不退回无 SDK 产品模式。

### Requirement: 第三方适配边界

客户端对第三方 Android 被控实现 MUST 依据版本和实际能力协商决定是否互通，仍检查身份和会话授权；集成方自行实现采集、输入及所需系统权限，不能从普通应用接入 SDK 推导出特权能力。

#### Scenario: 第三方缺少输入权限

- **WHEN** 第三方设备声明当前无法执行系统输入
- **THEN** 客户端不显示可用控制状态，仅展示已协商并获授权的其他能力。

## Verification

- 当前没有 Android 宿主和客户端验收，桌面构建与发现记录中的 android 字段不构成实现证据。
- 后续按明确的系统/设备矩阵验证录屏授权、存储访问、前后台、权限撤回、实际远端画面、文件及控制端能力。
- 第三方 Android 被控 SDK、官方互通阶段和最低系统版本分别设计，release-target 为 unassigned。

所有场景均为待验收项；现有单元测试、局部平台构建与媒体实验不构成本能力已经交付的证据。

## Sources

- [公开设计摘要](../../design.md)
- [当前客户端边界](../../../../../README.md)
- [版本计划](../../../../../docs/version-plan.md)
- 用户已确认 Android 官方客户端保留投屏与文件目标、可以控制电脑；被控端由第三方基于 SDK 和实际平台条件实现。
