# Mac 合并与主线收敛

日期：2026-09-15。执行环境：Windows，Flutter 3.47.2 / Dart 3.13.2。

将 Mac 分支 `11516f9` 合入以 `dd153d2` 为起点的 `main`，保留必需 SDK 的架构。接收品牌标题、预览生命周期、刷新后重新选择来源和来源失效提示；客户端宿主继续只在本仓库维护。对应闭源合并接收 Mac `34b5664`，将原生采集改为 SDK 内的 macOS Flutter 插件。

验证结果：

- `flutter pub get` 通过；首次因 Windows symlink 支持失败，使用已有插件 junction 脚本准备后重试通过，未调整系统安全设置。
- `flutter analyze --no-pub` 无问题，`flutter test --no-pub` 33 项通过。
- `flutter build windows --debug --no-pub` 成功。
- 关联 SDK 静态检查无问题，22 项测试通过。
- 本仓库 `tool/test_git_policy.ps1` 9 项通过，本机已安装 `.githooks`；规则与闭源仓库一致。

macOS 生成注册器已包含 `ShareHubMediaSdkPlugin`。新的插件布局尚未在 Mac 编译、运行或取得真实采集帧；此前 [Mac 验证](macos-foundation.md) 对应历史版本，不能替代本次原生编译验证。Windows 真实预览首帧仍待修复，本轮结果也不代表远端投屏完成。

两端日常开发统一为 `main`，当前目标 `v0.1.0`，未创建新分支或删除历史远端分支。每个新克隆（含 Mac）需执行 `pwsh -File tool/install_git_hooks.ps1`；本地配置不会随 Git 自动传播。
