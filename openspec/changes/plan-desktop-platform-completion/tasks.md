# plan-desktop-platform-completion 任务清单

以下均为尚未执行的未来任务。本次既有设计迁移只整理文档，不表示已授权产品开发；规格版本 0.1.0，产品基线 0.1.0，release-target 0.1.0。先完成设计门槛，再依据新的实施授权进入 apply；不得自行建分支/worktree或推定未排期能力的发布版本。

## 1. 现场与边界

- [ ] 1.1 用当前 Windows SDK 集成产物复现真实首帧问题，记录来源、采集、渲染与回调证据；以可重复的失败步骤及确认根因为完成证据。
- [ ] 1.2 在 macOS 使用当前 SDK 插件布局运行 `flutter build macos --debug --no-pub`，记录编译和注册结果；不得用旧无 SDK 产物替代。

## 2. 预览和文件补齐

- [ ] 2.1 按实测根因修复 Windows 预览的 SDK/宿主集成并补回归；以真实所选窗口/显示器首帧和 `flutter test --no-pub` 通过为完成证据。
- [ ] 2.2 完成 macOS 当前插件必要的集成修复，验证真实来源、权限拒绝/撤回、停止和恢复；以真实客户端记录及 `swift test --package-path macos/Platform` 为完成证据。
- [ ] 2.3 为 Windows 接入系统文件选择器和 FileAccess 令牌方法，保留 64 项及 256 KiB 边界；以真实普通文件/空文件读取和现有队列测试通过为完成证据。
- [ ] 2.4 补齐 Windows 文件变化、非法令牌、取消、清空和退出释放检查；运行 `pwsh -File tool/windows_test_native.ps1` 并记录真实选择器与句柄释放结果。

## 3. 平台回归

- [ ] 3.1 运行 `flutter analyze --no-pub`、`flutter test --no-pub`、`flutter build windows --debug --no-pub` 及 Mac 对应构建；将每个平台的通过/失败与客户端、SDK 版本写入验证记录。
- [ ] 3.2 分别复验真实预览停止后不再更新、来源关闭、权限撤回和重复停止；未完成的网络投屏和发行签名继续标为独立缺口。

## Cross-repository Development Plan

- 按 [两仓开发计划 v0.1.0](../../../docs/superpowers/plans/2026-09-15-cross-repository-development.md) 的 **D / S0→S1** 推进；先执行 1.1/1.2，确认根因后执行 2.1/2.2；2.3/2.4 文件准备可独立推进。
- 前置条件：当前 SDK/公开接口；预览问题先按证据定位所属层，文件准备独立验收。
- 协作对象：closed:plan-desktop-preview-acceptance；联合验收要求：真实所选来源首帧、停止和权限撤回与闭源 D 联测；文件令牌/摘要/释放单独留证。
- 原任务编号保持不变，每项按本仓证据单独勾选；只完成子集时其余任务保持未完成，不能归档整个 change。
