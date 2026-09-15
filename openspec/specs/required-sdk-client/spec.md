---
spec-id: required-sdk-client
spec-version: 0.1.0
product-baseline: 0.1.0
release-target: 0.1.0
lifecycle: baseline
delivery: implemented
---

# 必需 SDK 客户端

## Purpose

记录 v0.1.0 开发基线中的必需 SDK 客户端，初始规格版本 0.1.0 独立于产品版本和公共 API 版本。已实现控制逻辑与真实平台验收分别记录；本规格不表示稳定版已发布。

## Requirements

### Requirement: 唯一正常入口

正常客户端 MUST 从唯一 `lib/main.dart` 调用 SDK 的 `createPreviewEngine()`，向 UI 显式注入媒体引擎；Windows/macOS 宿主均在本仓库维护。

#### Scenario: 启动不采集

- **WHEN** 用户启动正常客户端
- **THEN** 应用获得 SDK 引擎，但不枚举或采集屏幕，等待用户选择并开始。

#### Scenario: SDK 未安装

- **WHEN** 构建环境缺少 SDK 包
- **THEN** 构建提示依赖缺失，不生成无 SDK 产品入口或退回缺少媒体依赖的产品模式。

### Requirement: 标准 SDK 安装位置

客户端 MUST 将 SDK 作为直接依赖，使用 `.local/media-sdk/package` 标准包位置；开发配置仅链接 SDK，不复制私有源码、不改写 manifest 或生成额外入口。

#### Scenario: 已有目录冲突

- **WHEN** 标准 SDK 位置存在不匹配的目录或链接
- **THEN** 配置工具报告冲突并保留已有内容，要求处理冲突后重试。

#### Scenario: 开发包链接

- **WHEN** 开发者配置有效 SDK 包
- **THEN** 配置建立被 Git 忽略的包目录链接并获取依赖，产品仍使用同一 main。

### Requirement: 依赖方向与实例稳定

SDK MUST 通过公开媒体 API 与客户端协作，不依赖客户端 UI；同一应用组件生命周期内的控制器和视图 MUST 使用同一组引擎、平台和文件访问实例。

#### Scenario: 父组件重建

- **WHEN** 应用父组件重建而当前客户端组件仍存活
- **THEN** 控制器和预览视图保持使用原实例，不创建第二个采集生命周期。

### Requirement: 交付状态说明

构建和接入文档 MUST 区分当前内部开发适配包与未来正式二进制 SDK；测试 fake 仅用于测试，不作为产品入口。

#### Scenario: 描述当前 SDK

- **WHEN** 文档说明开发环境如何构建
- **THEN** 明确当前正式二进制制品、下载地址和可信发行签名未交付，不将源码路径引用描述为闭源二进制交付。

## Verification

- 历史记录：统一 SDK 入口、配置工具 6 项场景、Windows Debug 默认构建已通过；后续主线整合记录为 33 项 Flutter 测试及静态分析通过。
- 本规格的 implemented 仅指必需依赖与入口结构已落地；不代表 SDK 二进制发行、macOS 新插件编译或真实首帧完成。
- 本次规格迁移未重跑产品构建或媒体采集。

## Sources

- [客户端构建与边界](../../../README.md)
- [统一 SDK 构建记录](../../../docs/validation/required-sdk-client.md)
- [主线整合验证](../../../docs/validation/main-integration.md)
- `lib/main.dart`、`lib/ui/client_app.dart`、`pubspec.yaml`
- `tool/configure_media_sdk.ps1`、`tool/test_configure_media_sdk.ps1`、`test/client_entry_test.dart`
