---
spec-id: remote-control-client
spec-version: 0.1.0
product-baseline: 0.1.0
release-target: unassigned
lifecycle: planned
delivery: planned
---

# 客户端远程控制

## Purpose

将既有设计中的客户端远程控制整理为可审阅的未来行为契约。当前能力尚未实现，本次仅迁移规格；规格版本独立维护，目标版本只说明规划归属，不代表已经授权开发、完成验收或承诺发布日期。

## ADDED Requirements

### Requirement: 单独控制授权

客户端和执行引擎 MUST 将观看与控制权限分开；远程输入仅在已验证对端、当前有效控制授权及平台权限均满足时执行。

#### Scenario: 只有观看权的输入

- **WHEN** 对端只获屏幕观看授权却发送键鼠事件
- **THEN** 执行侧拒绝输入，不能依赖 UI 是否显示控制按钮来授权。

### Requirement: 请求和拒绝状态

客户端 MUST 清晰展示控制请求、已允许、已拒绝、已撤回及不可用状态，并让被控端能够结束当前控制；具体有人值守/无人值守首版策略需另行确定。

#### Scenario: 被控端拒绝请求

- **WHEN** 被控端拒绝本次控制请求
- **THEN** 控制端显示拒绝，执行侧保持禁止远程输入。

### Requirement: 撤回和断开清理

控制授权撤回、权限失效、会话断开或切换身份时 MUST 立即终止相关输入处理并释放已按下的键或按钮；重新连接不得自动复活失效的控制权。

#### Scenario: 按键期间断线

- **WHEN** 远程按键尚未释放时连接实际断开
- **THEN** 被控侧释放输入状态并清除本次控制授权。

### Requirement: 平台能力边界

客户端 MUST 根据对端实际可执行能力显示远控操作；Windows/macOS 是官方被控目标，官方 Android 客户端仅作为电脑控制端，不宣称其提供 Android 被控能力。

#### Scenario: 不支持被控的官方 Android

- **WHEN** 其他设备尝试控制官方 Android 客户端
- **THEN** 报告能力不支持，不通过安装 SDK 或界面设置承诺系统级输入权限。

## Verification

- 后续真实 Windows/macOS 被控验证同意、拒绝、撤回、系统权限失效和断开后的输入释放。
- Android 控制端与第三方被控互通需分别验收；模拟输入消息不代表系统实际收到输入。
- 当前没有远控契约或执行能力；无人值守、剪贴板、多控制者等不在本次已确认实现范围。

所有场景均为待验收项；现有单元测试、局部平台构建与媒体实验不构成本能力已经交付的证据。

## Sources

- [公开设计摘要](../../design.md)
- [当前客户端边界](../../../../../README.md)
- [版本计划](../../../../../docs/version-plan.md)
- [当前公共 API](../../../../../packages/share_hub_media_api/README.md)
- 用户已确认桌面远控、Android 控制电脑与官方 Android 不承担被控的产品边界。
