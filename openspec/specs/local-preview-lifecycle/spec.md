---
spec-id: local-preview-lifecycle
spec-version: 0.1.0
product-baseline: 0.1.0
release-target: 0.1.0
lifecycle: baseline
delivery: partial
---

# 本地预览生命周期

## Purpose

记录 v0.1.0 开发基线中的本地预览生命周期，初始规格版本 0.1.0 独立于产品版本和公共 API 版本。已实现控制逻辑与真实平台验收分别记录；本规格不表示稳定版已发布。

## Requirements

### Requirement: 用户选择与权限

客户端 MUST 在枚举和启动前检查屏幕权限；每次刷新来源后清除已选项，要求用户明确选择显示器或窗口，不自动选择整屏。

#### Scenario: 拒绝录屏权限

- **WHEN** 用户未授予请求的录屏权限
- **THEN** 不枚举或启动采集，显示权限处理提示。

#### Scenario: 刷新来源

- **WHEN** 用户已选窗口后重新读取来源
- **THEN** 清除旧选择，开始按钮等待新的明确选择。

### Requirement: 首帧独立状态

客户端 MUST 区分采集启动、等待首帧和已收到画面；当前控制器在 12 秒内未收到首帧时停止并提示重新选择或检查权限。

#### Scenario: 首帧超时

- **WHEN** 引擎启动后始终未报告首帧
- **THEN** 超时停止并释放采集，不把运行状态当作可见画面。

### Requirement: 停止与授权撤回

客户端 MUST 在离开预览页、应用 hidden 或 detached、权限撤回或引擎结束当前采集时停止预览；恢复应用仅刷新权限，不自动重新采集。

#### Scenario: 隐藏应用

- **WHEN** 预览期间应用进入 hidden 状态
- **THEN** 请求停止并释放当前采集。

#### Scenario: 撤回权限

- **WHEN** 周期权限检查发现录屏权限被撤回
- **THEN** 停止采集并显示权限关闭提示。

### Requirement: 异步失效与清理失败

客户端 MUST 隔离旧启动和结束回调，串行完成停止；清理失败时禁止新启动并提供再次停止或退出的提示。

#### Scenario: 停止时启动仍在等待

- **WHEN** 启动异步工作尚未完成，用户请求停止
- **THEN** 晚到的结果不能恢复预览，已获得的资源仍被释放。

#### Scenario: 释放失败

- **WHEN** SDK stop 抛出错误
- **THEN** 显示释放失败且保留重试停止操作，不宣称采集已经结束。

## Verification

- `test/preview_controller_test.dart` 覆盖权限拒绝、明确选择、首帧超时、权限撤回、旧回调与清理失败；fake 测试只验证编排。
- Windows 真实本机首帧仍待修复；macOS 新 SDK 插件布局尚未编译、运行和取得真实帧。
- 旧 macOS 无 SDK 布局的构建记录不覆盖当前布局；本地预览不是远端投屏。

## Sources

- [控制器](../../../lib/features/preview/preview_controller.dart)
- [生命周期测试](../../../test/preview_controller_test.dart)
- `lib/ui/client_app.dart`、`test/client_widget_test.dart`
- [当前验收缺口](../../../docs/validation/main-integration.md)
- [版本计划](../../../docs/version-plan.md)
