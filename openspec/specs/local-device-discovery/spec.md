---
spec-id: local-device-discovery
spec-version: 0.1.0
product-baseline: 0.1.0
release-target: 0.1.0
lifecycle: baseline
delivery: partial
---

# 本机资料与局域网发现

## Purpose

记录 v0.1.0 开发基线中的本机资料与局域网发现，初始规格版本 0.1.0 独立于产品版本和公共 API 版本。已实现控制逻辑与真实平台验收分别记录；本规格不表示稳定版已发布。

## Requirements

### Requirement: 本机发现资料

客户端 MUST 持久保存用于发现的 UUID 和设备名称；名称经去除首尾空白后不能为空、不得包含控制字符，且最多 128 个 UTF-8 字节。发现 UUID MUST 不被当作设备密钥、激活凭证或身份认证证据。

#### Scenario: 非法名称

- **WHEN** 用户提交空白、控制字符或超长名称
- **THEN** 原生适配拒绝保存并保留原名称，界面允许修正后重试。

### Requirement: 主动开启发现

客户端 MUST 仅在用户开启后启动局域网发现，使用 `_sharehub-dev._tcp` 与版本 1 的发现记录；开启状态重命名后刷新广播。

#### Scenario: 初次启动

- **WHEN** 客户端初始化本机资料
- **THEN** 不自动广播或搜索设备。

#### Scenario: 关闭发现

- **WHEN** 用户关闭发现或客户端释放发现对象
- **THEN** 停止广播和浏览，清空发现列表。

### Requirement: 记录过滤

发现实现 MUST 过滤本机、无效 UUID、未知记录版本、非法名称和不支持的平台，按 UUID 去重并响应设备移除；发现结果仅展示存在，不建立可信连接。

#### Scenario: 伪造或畸形记录

- **WHEN** 局域网返回异常发现记录或声称与本机相同 UUID
- **THEN** 记录被忽略，不变成可信设备或可执行远控授权。

### Requirement: 生命周期与失败

客户端 MUST 展示 starting、searching、waiting、stopped 或 failed 的实际发现状态；停止或重启后的旧回调不得恢复已清空设备。

#### Scenario: 过时回调

- **WHEN** 一次发现已停止，旧请求随后返回设备
- **THEN** 忽略回调并保持当前发现状态。

#### Scenario: 网络不可用

- **WHEN** 系统发现服务报告等待或失败
- **THEN** 显示可重试的网络/权限提示，不把空列表解释为已经完成双机连接。

## Verification

- 设备控制器与记录过滤有公开单元测试；最新主线通过 33 项 Flutter 测试。
- 历史 Windows 原生记录含 2 项 CTest 和本机身份宿主检查；历史 macOS 记录含 4 项 XCTest。这些记录对应各自所记基线。
- 当前双机发现与跨平台可信连接未取得完整验收，故 delivery 为 partial。

## Sources

- [平台接口](../../../lib/platform/client_platform.dart)
- `lib/features/devices/device_controller.dart`
- `windows/platform/discovery_model.cpp`、`windows/tests/platform_tests.cpp`
- `macos/Platform/Sources/ShareHubPlatform/PlatformServices.swift`、`macos/Platform/Tests/ShareHubPlatformTests/PlatformServicesTests.swift`
- [主线整合验证](../../../docs/validation/main-integration.md)
- [历史 macOS 验证](../../../docs/validation/macos-foundation.md)
