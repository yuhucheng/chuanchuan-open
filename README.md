# Share Hub · 开源客户端

这是串串客户端的唯一源码工程，包含界面、设备发现、文件模块、Windows/macOS 宿主和公开 SDK 契约。**正常构建统一依赖媒体 SDK，不提供无 SDK 客户端。**

自有代码使用 [Apache License 2.0](LICENSE)，上游许可见 [第三方声明](THIRD_PARTY_NOTICES.md)。闭源 SDK 不公开实现源码，但计划免费向贡献者和集成者提供可分发包；闭源不意味着贡献者不能取得 SDK。

## OpenSpec 规格

客户端、公开媒体契约、设备发现、预览与文件准备的规格见 [规格索引](openspec/README.md)；跨网配对、目录、信令及其他未实现设计保留为待办 change。每份规格独立版本化，产品仍以 `VERSION` 和版本计划为准。使用方式见 [OpenSpec 管理](docs/development/openspec.md)：`npm ci` 后运行 `npm run spec:validate`，这些 Node 工具不参与客户端运行。

## 构建

两个仓库日常开发统一使用 `main`，当前目标 `v0.1.0`。开发和提交前阅读 [版本计划](docs/version-plan.md) 与 [分支管理规则](docs/development/branch-management.md)，运行 `pwsh -File tool/install_git_hooks.ps1` 启用本地检查。

安装 Flutter 3.47.2 / Dart 3.13.2；Windows 需要 VS 2022 C++ 桌面工具链和 Windows SDK，脚本使用 PowerShell 7；Mac 需要完整 Xcode。

SDK 是必需的构建依赖，标准位置为 `.local/media-sdk/package`。正式 SDK 可按此包布局解压；当前尚未交付正式二进制包或下载地址，本地开发使用已有内部适配包，通过脚本链接到标准位置：

```powershell
./tool/configure_media_sdk.ps1 -SdkPath /absolute/path/to/share_hub_media_sdk
flutter analyze --no-pub
flutter test --no-pub
flutter build windows --debug --no-pub
./build/windows/x64/runner/Debug/share_hub.exe
```

脚本只建立 SDK 包目录链接并执行 pub get，不复制私有源码，不修改 manifest，不生成另一套 main。已有 SDK 目录或冲突链接不会被覆盖。缺少 SDK 属于依赖未安装，需先准备 SDK；不会退回缺功能版本。已按标准目录解压包时可直接运行 `flutter pub get`。

若 Flutter 不在 PATH，可传 `-FlutterCommand` 指定完整路径。Windows 插件 symlink 权限不足时运行 `tool/prepare_windows_plugins.ps1`，再重试配置；不需改变系统安全策略。SDK 更新后建议清理旧构建产物，再获取依赖。

macOS 使用相同 `lib/main.dart`，运行 `flutter build macos --debug --no-pub`；输出为 `build/macos/Build/Products/Debug/Share Hub.app`，本轮未在 Mac 编译验收。

## 工程边界与实现状态

| 内容 | 位置 / 当前状态 |
| --- | --- |
| 唯一客户端入口 | `lib/main.dart`，固定注入 SDK 的 `createPreviewEngine()` |
| 公共媒体契约 | `packages/share_hub_media_api`，客户端与 SDK 共享 |
| 媒体实现 | SDK 包；当前内部开发适配器尚不是可分发二进制 SDK |
| 界面、设备发现 | `lib/ui`、`lib/features/devices`；手动 DNS-SD / Bonjour 发现 |
| 文件准备 | `lib/features/transfers`；macOS 已实现本地选文件和摘要，Windows 待实现 |
| 平台宿主 | 全部在本仓库的 `windows`、`macos` |
| 配对、网络传输、远控、Android | 尚未完成 |

UI 必须显式获得媒体引擎，测试可以注入 fake，但 fake 只存在于测试工具，不用于产品入口。启动应用不会自动采集屏幕，仍需用户选择并开始预览。

SDK 依赖项、锁文件和原生插件注册随正常客户端维护；`.local` 中的包和本机目录链接不提交。SDK 不依赖客户端 UI。SDK 的正式二进制交付、签名、激活与远端会话仍待实现，不能把当前预览适配器当作完整核心。

应用身份沿用 `share_hub.exe` / `Software\ShareHub\Client` 和 `dev.sharehub.client`。Windows 真实预览首帧仍需修复，当前没有可信发行签名。

验证见 [统一 SDK 构建记录](docs/validation/required-sdk-client.md) 和 [Mac 合并与主线收敛记录](docs/validation/main-integration.md)。开源远程地址为 `git@github.com:yuhucheng/chuanchuan-open.git`。
