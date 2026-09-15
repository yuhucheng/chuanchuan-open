# chuanchuan-open macOS 基础验证

日期：2026-09-15。环境：macOS 26.6.2 / Apple Silicon，Xcode 26.6，Flutter 3.47.2 / Dart 3.13.2。验证范围为基线提交 `3a7f718` 加本次提交的公共生命周期修复。

本轮调整：

- `ShareHubApp` 在同一组件生命周期内使用同一组平台、文件与预览引擎对象，避免父组件重建后控制器与显示画面使用不同实例。
- 每次刷新来源后必须重新选择，避免默认启动整块显示器；来源失效会要求重新读取。
- 默认无媒体引擎的行为保留：不请求录屏权限，不展示可执行的来源读取与采集按钮。

已通过：

- `flutter pub get`、`flutter analyze --no-pub`。
- **35 项 Flutter 测试**，包含明确选择、实例稳定性、Windows/macOS 布局、默认无媒体能力和文件队列检查。
- `swift test --package-path macos/Platform`，**4 项 XCTest**。
- `flutter build macos --debug --no-pub`，生成 `build/macos/Build/Products/Debug/Share Hub Open.app`。
- `.app` 的 `codesign --verify --deep --strict` 检查；Frameworks 目录只有 App 和 FlutterMacOS，未包含 WebRTC 框架。
- 实机启动、进入预览页，显示“当前版本未包含投屏引擎。设备发现与已实现的文件准备功能仍可使用。”，无来源读取与采集按钮。

Flutter SDK 作为外部工具使用，源码和构建包均不依赖官方宿主或私有媒体实现。窗口与应用标识暂保留历史兼容名称，品牌与仓库为 `chuanchuan` / `chuanchuan-open`。

本轮没有验证双机发现、系统文件选择全部场景、Windows 原生回归、发行签名或跨设备功能。已有队列测试只验证本地准备，不代表网络文件已经发送。默认工程没有媒体采集能力；模拟引擎测试不构成真实画面或远控验收。
