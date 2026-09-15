# Share Hub Open 协作

本工程是完整客户端的唯一源码工程，自有代码使用 Apache 2.0，上游许可见 THIRD_PARTY_NOTICES.md。产品能力及验收范围以 README.md 为准。

依赖方向为客户端消费可选媒体 SDK。公开的 `packages/share_hub_media_api` 提供双方共享的契约，SDK 不得依赖本客户端包或 UI。默认应用必须能在没有 SDK 的情况下独立构建和运行，显示真实能力状态；有 SDK 的本地配置通过 `tool/configure_media_sdk.ps1` 生成并忽略，不提交闭源源码、路径配置、部署材料或凭据。

Windows/macOS 平台宿主、原生设备和文件逻辑均在本仓库维护，不在闭源仓库另建客户端。修改媒体契约时验证 SDK 兼容性；基础构建和公共测试不能强制要求安装官方 SDK。

使用锁定版本 Flutter 3.47.2 / Dart 3.13.2。运行 flutter analyze、flutter test 和相关平台检查；不能在本平台完成的验收明确记录。不要将测试模拟画面当作真实投屏证据。
