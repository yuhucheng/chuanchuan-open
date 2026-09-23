# Share Hub · 开源客户端

> 2026-09-16 产品决定：Windows、macOS 无需激活、激活码或邀请码，不要求首次联网激活。商业模式改为增值订阅，订阅权益、价格、计费和账户方案以后另行设计，本轮不实现订阅或设置订阅门槛。Android 与第三方 Android SDK 的准入规则本次不变，仍未排期。设备身份验证、配对确认、会话同意、系统权限和官方服务防滥用措施继续独立执行。

这是串串客户端的唯一源码工程，包含界面、设备发现、文件模块、Windows/macOS 宿主和公开 SDK 契约。**正常构建统一依赖媒体 SDK，不提供无 SDK 客户端。**

自有代码使用 [Apache License 2.0](LICENSE)，上游许可见 [第三方声明](THIRD_PARTY_NOTICES.md)。闭源 SDK 不公开实现源码，但计划免费向贡献者和集成者提供可分发包；闭源不意味着贡献者不能取得 SDK。

## 开发管理

Agent 配置、OpenSpec 和内部计划已迁至独立私有管理仓，本仓只维护产品交付内容。构建无需管理仓。说明见[开发与文档边界](docs/development.md)。

当前公开能力与契约见[规格说明](docs/specifications/README.md)。

## 构建

两个业务仓在统一工作区内跟随管理仓当前同名分支，当前在 `release/v0.2.0` 开发，产品 VERSION 暂保留 0.1.0；`main` 保持主线。开发和提交前阅读 [版本计划](docs/version-plan.md) 与 [分支管理规则](docs/development/branch-management.md)，运行 `pwsh -File tool/install_git_hooks.ps1` 启用本地检查。

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

Windows 开发 SDK 还需按 SDK 包内说明准备匹配的原生依赖。构建钩子检查 DLL、版本锁和补丁输入，缺失或不匹配时停止构建；当前没有正式二进制下载包。SDK 的真实窗口图案验收可从本客户端执行 `pwsh -File tool/test_media_sdk_windows.ps1`，脚本结束后恢复普通客户端 Debug 构建。

macOS 使用相同 `lib/main.dart`，运行 `flutter build macos --debug --no-pub`；输出为 `build/macos/Build/Products/Debug/Share Hub.app`，2026-09-16 已在 Mac 编译并启动，已取得 A/B 真实首帧、持续帧和启停证据，来源退出释放修复已通过单次回归；完整生命周期仍待验收，见[运行验证](docs/validation.md)。

## 工程边界与实现状态

| 内容 | 位置 / 当前状态 |
| --- | --- |
| 唯一客户端入口 | `lib/main.dart`，固定注入 SDK 的 `createPreviewEngine()` |
| 公共媒体契约 | `packages/share_hub_media_api`，客户端与 SDK 共享 |
| 媒体实现 | SDK 包；当前内部开发适配器尚不是可分发二进制 SDK |
| 界面、设备发现 | `lib/ui`、`lib/features/devices`；手动 DNS-SD / Bonjour 发现 |
| 文件准备 | `lib/features/transfers`；macOS 已实现本地选文件和摘要；Windows 系统选择器、令牌读取、摘要与普通退出释放已通过实机验收；准备完成仍不等于对端收妥 |
| 网络文件开发 | 双向自动接收、确认、暂停/进程内恢复和断线取消已接入客户端；接收目录设置由原生层保存，失效时要求重新选择。Windows 构建、本机 TCP/模拟文件与原生存储测试通过；macOS 新存储/持久化实现及真实双机验收待完成 |
| 文件拖放开发 | 系统文件拖到本机节点/文件面板后准备，拖到已连接设备后准备并向原连接发送。Windows 原生边界/令牌释放有自动测试，真实手势及多显示器 DPI 待验收；macOS 已补 AppKit 入口与安全作用域交接源码，尚未编译或执行原生测试 |
| 平台宿主 | 全部在本仓库的 `windows`、`macos` |
| 短接码连接 | `packages/share_hub_connection` 与 macOS 设备页已接入；协议测试通过，双机/休眠待验收 |
| 网络传输、远控、Android | 尚未完成 |
| Windows 远控屏幕几何探测 | 已提供只读本机 source ID 重新枚举与几何查询；执行侧仍需绑定画面、授权及原生输入，不代表远控可用 |

UI 必须显式获得媒体引擎，测试可以注入 fake，但 fake 只存在于测试工具，不用于产品入口。启动应用不会自动采集屏幕，仍需用户选择并开始预览。

SDK 依赖项、锁文件和原生插件注册随正常客户端维护；`.local` 中的包和本机目录链接不提交。SDK 不依赖客户端 UI。SDK 的正式二进制交付、签名与远端会话仍待实现，不能把当前预览适配器当作完整核心。

应用身份沿用 `share_hub.exe` / `Software\ShareHub\Client` 和 `dev.sharehub.client`。Windows 已通过选定测试窗口的真实首帧与像素检查，显示器和完整生命周期待验收，当前没有可信发行签名。

macOS 反复调试可按[本机开发签名](docs/development/macos-local-signing.md)配置固定的个人证书，减少 ad-hoc 重建导致的授权身份变化；该配置不代表正式发行签名。

验证见 [统一 SDK 构建记录](docs/validation.md) 和 [Mac 合并与主线收敛记录](docs/validation.md)。开源远程地址为 `git@github.com:yuhucheng/chuanchuan-open.git`。

短接码使用、密码协议及验证边界见[本地连接协议与 v2 接入](docs/protocols/short-code-connection.md)。连接授权不等于媒体、输入或文件权限。
