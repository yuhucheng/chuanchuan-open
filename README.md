# Share Hub · 开源客户端

这是串串客户端的唯一源码工程，包含 Flutter 界面、设备发现、文件准备、Windows/macOS 宿主和 SDK 接口。**客户端使用可选媒体 SDK；闭源工程负责 SDK 实现，不再作为客户端宿主。**

自有代码使用 [Apache License 2.0](LICENSE)，Flutter 等上游保留原许可，见 [第三方声明](THIRD_PARTY_NOTICES.md)。不安装 SDK 也可以独立构建和运行基础功能，不需要官方邀请码。官方 SDK 的运行授权与开源代码复用分开处理，当前尚未实现生产激活体系。

## 目录与能力

| 模块 | 位置与状态 |
| --- | --- |
| 客户端与界面 | `lib/main.dart`、`lib/ui`，全部在本工程 |
| 设备发现 | `lib/features/devices`，Windows DNS-SD / macOS Bonjour；默认关闭 |
| 文件准备 | `lib/features/transfers`，macOS 可选文件、计算摘要、管理队列；Windows 待实现 |
| 平台宿主与适配 | `windows`、`macos`，全部在本工程 |
| 媒体契约 | 独立包 `packages/share_hub_media_api`，客户端和 SDK 实现共享 |
| 媒体实现 | 可选外部 SDK，未安装时显示不可用；当前接口只覆盖本机视频预览 |
| 配对、网络传输、远控、Android | 尚未完成，不把本地准备或预览当作跨设备功能 |

SDK 实现不依赖客户端包，只实现公共媒体契约。原 `lib/features/preview/preview_engine.dart` 继续导出契约以兼容现有引用；生命周期控制器和不可用实现属于客户端。

## 无 SDK 的独立构建

使用 Flutter 3.47.2 / Dart 3.13.2，将 Flutter `bin` 加入 PATH。Windows 需要 VS 2022 C++ 桌面工具链和 Windows SDK，脚本使用 PowerShell 7；Mac 需要完整 Xcode。

从本工程根目录运行：

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
flutter build windows --debug --no-pub
./build/windows/x64/runner/Debug/share_hub.exe
```

Mac 使用 `flutter build macos --debug --no-pub`，输出 `build/macos/Build/Products/Debug/Share Hub.app`。新布局尚未在 Mac 上编译验收。

## 接入开发 SDK

当前 SDK 仍是授权开发者本地使用的 Dart/WebRTC 实现包，尚不是对外分发的闭源二进制。安装该包不代表已获得生产连接授权，也不解决现有首帧问题。

```powershell
./tool/configure_media_sdk.ps1 -SdkPath /absolute/path/to/share_hub_media_sdk
flutter build windows --debug --no-pub -t .local/media-sdk/main.dart
# 或使用 flutter run -d windows -t .local/media-sdk/main.dart
```

脚本会暂时把 SDK 加入直接依赖，并生成被 Git 忽略的依赖覆盖配置和启动入口。它保存原始 manifest，拒绝覆盖开发者已有或手动修改的配置。SDK 源码不会复制进本仓库。Flutter 不在 PATH 时可传 `-FlutterCommand` 指定工具路径；遇到插件链接权限问题可使用 `tool/prepare_windows_plugins.ps1` 后重试。

禁用并恢复默认构建：

```powershell
./tool/configure_media_sdk.ps1 -Disable
flutter clean
flutter pub get
flutter build windows --debug --no-pub
```

切换 SDK 配置后应清理旧构建产物，避免打包残留插件。启用期间 manifest、锁文件与生成的插件列表可能有本地变化；提交公共源码前先禁用并恢复默认依赖，不提交开发 SDK 配置。

客户端身份为 Windows `share_hub.exe` / `HKCU\Software\ShareHub\Client`、Mac `dev.sharehub.client`，沿用原官方宿主的设备资料位置。上一轮临时 OpenClient 身份的数据不自动迁移。

## 验证与交付限制

`flutter test` 检查公共逻辑；`tool/windows_test_native.ps1` 检查 Windows 原生基础，Mac 可运行 `swift test --package-path macos/Platform`。`integration_test/windows_platform_test.dart` 保留真实 Windows 设备资料检查，需 Windows 宿主运行；它不采集屏幕。`tool/test_configure_media_sdk.ps1` 验证可选配置及用户文件保护。

最新结果见 [依赖方向验证](docs/validation/client-sdk-direction.md)。当前没有可信发行签名，Windows 安全策略仍可能拦截；局域网广播未经认证，不能据此信任对端。尚未创建公共远程仓库。
