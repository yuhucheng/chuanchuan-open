# Share Hub Open

串串的开源客户端基础工程：Flutter 界面、局域网设备发现、文件准备与平台适配。它是独立工程，可单独构建和复用；不需要官方邀请码或闭源仓库来运行本工程已实现的基础功能。

自有代码采用 [Apache License 2.0](LICENSE)。Flutter 宿主模板等上游文件保留原许可，详见 [第三方声明](THIRD_PARTY_NOTICES.md)。本仓库不包含官方投屏/远控引擎、激活后台、部署配置或生产凭据；官方 SDK 的独立授权条款不限制这里的 Apache 2.0 代码。

## 当前实现

| 能力 | 状态 |
| --- | --- |
| 设备页、设置、设备名称保存 | Windows / macOS 已有实现 |
| 局域网设备发现 | Windows DNS-SD、macOS Bonjour；默认关闭，用户手动开启 |
| 配对与连接 | 界面保留未配对状态；可信配对、信令和连接尚未实现 |
| 文件准备 | macOS 系统选文件、队列、增量 SHA-256、取消及句柄释放；Windows 待实现 |
| 文件网络传输 | 尚未实现，已检查的文件不代表已发送 |
| 本机视频预览 | 公共接口可注入实现；默认不提供媒体引擎，不请求录屏权限 |
| 跨设备投屏与远控 | 尚未实现会话或远程输入接口，不注入远程输入 |
| Android | 尚未创建客户端或 Host SDK |

这是开发基础工程，还不是可交付的三端协作产品。设备广播使用 `_sharehub-dev._tcp`，UUID 只用于去重，不能据此信任对端；跨子网发现与 TURN 接入尚未实现。

## 独立开发

安装 Flutter 3.47.2（Dart 3.13.2），将其 `bin` 加入 PATH。Windows 还需 Visual Studio 2022 C++ 桌面工具链及 Windows SDK，脚本使用 PowerShell 7；macOS 需完整 Xcode。Flutter SDK 可以放在任何目录，本工程不读取闭源工程的源码或配置。

在本仓库根目录运行：

```sh
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

Windows：

```powershell
flutter build windows --debug --no-pub
./build/windows/x64/runner/Debug/share_hub_open.exe
./tool/windows_test_native.ps1
```

macOS：

```sh
flutter build macos --debug --no-pub
open 'build/macos/Build/Products/Debug/Share Hub Open.app'
swift test --package-path macos/Platform
```

macOS 工程引用已随拆分调整，但拆分后尚未在 Mac 上编译或进行原生验收。Windows 构建及测试结果见 [拆分验证](docs/validation/project-split.md)。调试产物没有可信发行签名，Windows 安全策略可能阻止启动；复制程序时须包含同目录 DLL 和 `data`。

## 扩展与目录

- `lib/ui`、`lib/features/devices`：共享界面与设备状态。
- `lib/features/transfers`：文件访问接口、准备队列与界面。
- `lib/features/preview`：`PreviewEngine` 接口、预览生命周期及不可用实现。
- `lib/platform`：Flutter/原生通道契约。
- `windows/platform`、`macos/Platform`：单一来源的原生基础实现。
- `macos/Runner/FileAccessBridge.swift`、`MainFlutterWindow.swift`：原生通道绑定。
- `test`、`windows/tests`、`macos/Platform/Tests`：公共测试。

接入自有媒体实现时，实现 `PreviewEngine`，再通过 `ShareHubApp(previewEngine: yourEngine, appTitle: yourAppName)` 注入。`unavailableReason` 非空表示本构建不具备媒体实现；为空只表示提供了实现，不代表连接已授权或首帧已到达。不要用它替代正式的设备/会话授权。

接口目前只覆盖本机视频预览生命周期，尚不是稳定的跨设备 SDK ABI。第三方可独立复用开源基础，官方客户端也通过相同接口消费它。

界面渲染工具 `tool/render_preview.dart` 使用测试状态，可设置 `SHARE_HUB_PREVIEW_FONT` 指向本机 CJK 字体并运行 `flutter test tool/render_preview.dart`；Windows 布局再设置 `SHARE_HUB_PREVIEW_TARGET=windows`。图片写入 `build/ui-preview`，不代表原生功能验收。

代码由原客户端按明确边界提取，以新的 Git 历史维护；来源说明见 [迁移记录](docs/source-origin.md)。本地工程已建立，尚未创建公共远程仓库。
