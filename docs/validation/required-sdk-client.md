# 正常客户端统一依赖 SDK

日期：2026-09-15。按用户决定移除无 SDK 构建路线。

- `lib/main.dart` 直接调用 SDK 工厂，`ShareHubApp.previewEngine` 为必填参数；无 SDK 默认实现及对应的产品入口测试已删除。
- SDK 始终是直接依赖，标准安装目录为 `.local/media-sdk/package`；配置脚本只建立本地 SDK 包链接，不修改 manifest、不生成 main、不提供 Disable。
- 默认入口测试先失败（未注入 SDK），修改后通过；公共 Flutter 测试共 31 项通过，确认正常入口提供媒体引擎且不会自动启动采集。
- SDK 配置 6 项测试通过：重复配置、含中文/空格路径、manifest 保持、无额外入口、错误 SDK、已有目录/冲突链接/旧配置及重定向父目录保护。
- 默认 `flutter build windows --debug --no-pub` 已通过；不需要 `-t` 或 SDK 模式开关。
- 公共静态分析通过，Windows 默认产物包含 WebRTC 插件及媒体 DLL；代码复核无重要问题。

验证使用内部 Dart/WebRTC 开发包，不代表正式二进制 SDK 已发布。Mac 本轮未构建；可信签名、真实预览首帧和跨设备核心功能仍待完成。
