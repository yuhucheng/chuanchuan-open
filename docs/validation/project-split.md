# 独立工程拆分验证

后续 macOS 构建与实机基础验收见 [macOS 验证](macos-foundation.md)，下文保留首次在 Windows 拆分时的状态。

日期：2026-09-15。环境：Windows、Flutter 3.47.2 / Dart 3.13.2、VS 2022 与 Windows SDK 10.0.26100。

已通过：

- 开源工程 `flutter pub get`、`flutter analyze --no-pub`。
- 开源工程 Flutter 测试 33 项：包含原有公共测试与 3 项无媒体引擎行为检查；Windows/macOS 布局均不展示采集入口，也不会请求录屏权限。
- `flutter build windows --debug --no-pub`：生成 `build/windows/x64/runner/Debug/share_hub_open.exe`。
- `tool/windows_test_native.ps1`：2 项 CTest 通过（发现记录和设备资料存储）。
- macOS 工程的 Swift 文件引用与 scheme XML 静态检查。

本工程的包依赖不包含 `flutter_webrtc`，原生插件注册为空；业务源文件不引用官方闭源目录。Flutter SDK 作为外部工具使用，其安装位置不属于源码依赖。

未验证：拆分后的 macOS 编译/真机运行、双机发现、跨设备配对与传输、Android、发行签名。以上构建结果不代表投屏或远控已经实现。默认客户端未包含媒体引擎。
