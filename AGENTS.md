# chuanchuan-open 协作

规格入口为 [OpenSpec 索引](openspec/README.md)，工作流与版本约定见 [OpenSpec 管理](docs/development/openspec.md)。修改行为前阅读对应基线和待办 change；规格版本与产品/API 版本分别维护，更新前言及 `openspec/catalog.json` 后运行 `npm run spec:validate`。`planned` 仅表示设计待办，不能把未实现或未验证能力当成已交付，也不自动恢复此前暂停的产品开发。公开规格必须可独立阅读，不复制私有实现、生产实例信息或运营凭据。

开始开发、建分支或提交前必须阅读 [分支与提交规则](docs/development/branch-management.md) 和 [版本计划](docs/version-plan.md)。日常仅使用既有 `main`，不得按设备、任务或助手自行新建分支/worktree；例外须由用户明确批准并进入版本计划。新提交使用 `type(v0.1.0): 描述`（版本以 `VERSION` 为准）。新克隆先执行 `pwsh -File tool/install_git_hooks.ps1`；不能绕过检查。该规则优先于技能中的自动分支流程。

品牌名称是 `chuanchuan`（串串），仓库为 `yuhucheng/chuanchuan-open`。Dart 包名 `share_hub_open` 和既有应用标识暂作兼容使用；新仓库路径以 `chuanchuan-open` 为准。

本工程是完整客户端的唯一源码工程，自有代码使用 Apache 2.0，上游许可见 THIRD_PARTY_NOTICES.md。产品能力及验收范围以 README.md 为准。

客户端统一依赖媒体 SDK，不提供无 SDK 构建或另一套入口。`lib/main.dart` 始终注入 SDK 工厂返回的引擎，UI 要求显式引擎，fake 仅供测试。公开的 `packages/share_hub_media_api` 提供双方共享的契约，SDK 不依赖客户端 UI。标准 SDK 包位置 `.local/media-sdk/package` 被忽略；开发时用配置脚本链接本地包，不复制私有源码。

Windows/macOS 平台宿主、原生设备和文件逻辑均在本仓库维护，不在闭源仓库另建客户端。修改媒体契约时验证 SDK 兼容性。贡献者先取得 SDK 再构建；当前正式二进制 SDK 尚未交付，不虚构下载地址或把内部 Dart 适配包宣称为二进制发行物。

使用锁定版本 Flutter 3.47.2 / Dart 3.13.2。运行 flutter analyze、flutter test 和相关平台检查；不能在本平台完成的验收明确记录。不要将测试模拟画面当作真实投屏证据。
