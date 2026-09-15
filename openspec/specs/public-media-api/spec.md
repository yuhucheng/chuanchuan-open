---
spec-id: public-media-api
spec-version: 0.1.0
product-baseline: 0.1.0
release-target: 0.1.0
lifecycle: baseline
delivery: implemented
---

# 公共媒体 API

## Purpose

记录 v0.1.0 开发基线中的公共媒体 API，初始规格版本 0.1.0 独立于产品版本和公共 API 版本。已实现控制逻辑与真实平台验收分别记录；本规格不表示稳定版已发布。

## Requirements

### Requirement: 独立契约包

公共包 `share_hub_media_api` MUST 独立提供 Flutter 媒体契约，不依赖 SDK 实现或客户端 UI。当前包 API 版本为 0.1.0，规格版本独立维护。

#### Scenario: 实现引擎

- **WHEN** SDK 实现当前预览契约
- **THEN** 只需依赖公共契约，不导入客户端包或平台宿主源码。

### Requirement: 来源描述

公共 API MUST 用 `CaptureSource` 描述来源 id、名称和 `CaptureSourceType`，现有类型为 screen 和 window。

#### Scenario: 选择窗口

- **WHEN** 客户端收到窗口类型来源
- **THEN** 保留该来源 id 和 window 类型交给引擎，不把它隐式改为默认屏幕。

### Requirement: 预览生命周期

`PreviewEngine` MUST 暴露 `sources()`、`start(source, onEnded, onFirstFrame)`、`stop()`、`dispose()` 和 `view`；采集结束与首次画面到达 SHALL 通过不同回调表达。

#### Scenario: 启动尚无首帧

- **WHEN** start 完成但 onFirstFrame 尚未触发
- **THEN** 客户端不能据此宣称收到真实画面。

#### Scenario: 结束回调

- **WHEN** 系统结束当前来源采集
- **THEN** 客户端接收 onEnded 并进入停止和释放流程。

### Requirement: 实现可用性含义

`unavailableReason` 为 null MUST 只表示当前构建存在媒体实现；它不授予权限，不证明远端连接、首帧或控制能力。当前契约 MUST 不被描述为已定义跨设备会话、远控协议或二进制 ABI。

#### Scenario: 存在实现但没有授权

- **WHEN** unavailableReason 为 null 而录屏权限未获允许
- **THEN** 客户端仍检查权限，不能直接采集或显示授权成功。

## Verification

- `packages/share_hub_media_api/lib/share_hub_media_api.dart` 为当前接口来源；包版本 0.1.0。
- 最新主线记录包含客户端 33 项测试和关联 SDK 22 项测试，不等同于 ABI 兼容认证或真实媒体验收。
- 远端会话和能力协商属于待规划扩展，不能在本基线中假定已存在。

## Sources

- [公共契约说明](../../../packages/share_hub_media_api/README.md)
- [接口定义](../../../packages/share_hub_media_api/lib/share_hub_media_api.dart)
- [包版本](../../../packages/share_hub_media_api/pubspec.yaml)
- [主线整合验证](../../../docs/validation/main-integration.md)
