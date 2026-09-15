# 客户端与 SDK 依赖方向验证

历史记录：可选 SDK 和无 SDK 入口已移除，当前见 [统一 SDK 构建](required-sdk-client.md)。

日期：2026-09-15。此工程现在拥有唯一客户端和 Windows/macOS 宿主，可选择消费外部媒体 SDK。SDK 实现只需公开 `share_hub_media_api` 包，不依赖客户端 UI。

已通过：公共 Flutter 测试 33 项、静态分析、Windows 原生 CTest 2 项、Windows 平台宿主集成测试 1 项、无 SDK 的 Windows Debug 构建。集成测试检查本机身份与非法名称处理，不采集屏幕。

SDK 配置工具通过包含空格和中文路径的测试，检查启停幂等、原始 manifest 精确恢复、已有配置/修改文件/孤立备份保护、错误 SDK 和 pub get 失败恢复。启用时直接 SDK 依赖保证 Flutter 原生插件注册，单独 dependency_overrides 不作为集成成功证据。

应用身份恢复为 `share_hub.exe` / `Software\ShareHub\Client`，Mac 为 `Share Hub.app` / `dev.sharehub.client`。Mac 工程仅核对 XML 和源码引用，本轮尚未在 Mac 编译验收。

当前可选 SDK 是内部 Dart 开发适配器；二进制 SDK、发行签名、真实首帧和跨设备功能仍未交付。默认配置不含媒体实现。

有 SDK 的 Windows Debug 构建通过，原生插件注册及媒体 DLL 均存在。禁用后恢复原始 manifest、重新获取默认依赖并清理构建产物，无 SDK Windows Debug 再次通过，锁文件与插件注册均无媒体实现。配置工具共 8 项场景检查通过，审查发现的问题已修复并复核。
