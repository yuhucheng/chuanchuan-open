# Share Hub Open 协作

本工程是完整客户端的唯一源码工程，自有代码使用 Apache 2.0，上游许可见 THIRD_PARTY_NOTICES.md。产品能力及验收范围以 README.md 为准。

客户端统一依赖媒体 SDK，不提供无 SDK 构建或另一套入口。`lib/main.dart` 始终注入 SDK 工厂返回的引擎，UI 要求显式引擎，fake 仅供测试。公开的 `packages/share_hub_media_api` 提供双方共享的契约，SDK 不依赖客户端 UI。标准 SDK 包位置 `.local/media-sdk/package` 被忽略；开发时用配置脚本链接本地包，不复制私有源码。

Windows/macOS 平台宿主、原生设备和文件逻辑均在本仓库维护，不在闭源仓库另建客户端。修改媒体契约时验证 SDK 兼容性。贡献者先取得 SDK 再构建；当前正式二进制 SDK 尚未交付，不虚构下载地址或把内部 Dart 适配包宣称为二进制发行物。

使用锁定版本 Flutter 3.47.2 / Dart 3.13.2。运行 flutter analyze、flutter test 和相关平台检查；不能在本平台完成的验收明确记录。不要将测试模拟画面当作真实投屏证据。
