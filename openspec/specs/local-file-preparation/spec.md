---
spec-id: local-file-preparation
spec-version: 0.1.0
product-baseline: 0.1.0
release-target: 0.1.0
lifecycle: baseline
delivery: partial
---

# 本地文件准备

## Purpose

记录 v0.1.0 开发基线中的本地文件准备，初始规格版本 0.1.0 独立于产品版本和公共 API 版本。已实现控制逻辑与真实平台验收分别记录；本规格不表示稳定版已发布。

## Requirements

### Requirement: 受限文件选择

文件准备 MUST 只接收原生系统文件选择器返回的令牌，不接收 Flutter 或网络对端提供的任意文件路径；队列最多容纳 64 个文件。

#### Scenario: 超出队列限制

- **WHEN** 新选择超过剩余容量
- **THEN** 拒绝整批新选择并释放新令牌，不开始读取这些文件。

#### Scenario: 取消选择器

- **WHEN** 用户取消原生文件选择
- **THEN** 返回空选择，不新增队列项目。

### Requirement: 增量内容检查

队列 MUST 顺序读取最多 256 KiB 的分块并计算 SHA-256；仅在读取完整内容且原生最终检查通过后标为 ready，空文件也执行最终检查。

#### Scenario: 文件中途变化

- **WHEN** 读取短于预期或最终检查发现文件变化
- **THEN** 标记准备失败，不发布可用摘要并释放访问。

#### Scenario: 空文件

- **WHEN** 所选文件长度为零且最终检查通过
- **THEN** 显示标准空文件 SHA-256，并标记本地检查完成。

### Requirement: 取消与释放

队列 MUST 支持取消、移除、清空和关闭，忽略取消后的晚到读取或选择结果；释放失败保留项目和错误，允许再次释放。

#### Scenario: 取消进行中的读取

- **WHEN** 用户取消项目后旧分块才返回
- **THEN** 丢弃该分块，不生成摘要并释放令牌。

#### Scenario: 移除释放失败

- **WHEN** 原生释放令牌失败
- **THEN** 项目仍可见且标为失败，用户可再次移除以重试。

### Requirement: 准备状态的含义

界面 MUST 把 ready 表述为本地检查完成、等待连接，明确文件尚未发送；退出应用后队列清空。

#### Scenario: 准备完成

- **WHEN** 文件摘要已计算完成
- **THEN** 显示已检查或等待连接，不显示已发送或对端已接收。

## Verification

- macOS 已有系统选择器、令牌管理和普通文件校验实现；Windows 文件适配尚未实现。
- 公开队列测试覆盖增量摘要、空文件、晚到回调、短读、文件变化、超限和释放重试；测试 fake 不证明 Windows 原生文件能力。
- 当前没有网络发送、接收、接收确认或断点恢复实现。本次迁移未进行新的原生验收。

## Sources

- [文件访问契约](../../../lib/features/transfers/file_access.dart)
- [队列实现](../../../lib/features/transfers/transfer_queue.dart)
- [队列测试](../../../test/transfer_queue_test.dart)
- `macos/Runner/FileAccessBridge.swift`、`macos/Platform/Sources/ShareHubPlatform/SelectedFileStore.swift`
- [当前实现状态](../../../README.md)
