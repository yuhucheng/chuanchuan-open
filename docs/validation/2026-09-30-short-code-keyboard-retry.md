# 短接码键盘重试与取消

本轮修复正常输码弹窗验证失败后的焦点丢失。六位短接码入口、授权时长及自动发现/会合路径保持现有契约。

## 缺陷与修复

通过键盘提交六位码时，Flutter 的输入完成动作会释放输入焦点；验证期间输入框禁用，失败后重新启用并不会自动恢复焦点。新增组件用例先在原实现复现 `Expected: true, Actual: false`，位置为失败结算后的输入焦点断言。

弹窗现在持有并释放自己的输入焦点节点，在下一帧重新启用输入框后恢复焦点；不完整码和失效发现端点的本地校验失败同样恢复。关闭、取消或再次提交时，迟到恢复回调不能夺取焦点。验证中状态增加语义 live region。

## 验证

Mac 本机 Flutter 3.47.2 / Dart 3.13.2：

- 新增键盘组件 3 项：失败后直接改码重试、不完整码保留焦点且不发起连接、640×550 / 200% 字号时 Escape 立即取消且恢复入口焦点，迟到失败不影响再次打开。
- `flutter test test/connection_dialog_keyboard_test.dart test/connection_direction_ui_test.dart --reporter expanded`：14/14 通过，包含已有正反向、自动发现回退和迟到结果隔离回归。
- `flutter analyze`：无问题。
- 客户端完整 `flutter test --reporter expanded`：325 通过、1 跳过。该结果取自包含另一会话未提交设备命名/发现修复的工作区；本次提交仅包含弹窗、键盘用例和本记录，完整结果不是干净发行组合证明。

没有启动采集 fixture 或实机媒体/后台验收，没有新增 Windows 构建或平台读屏证据。语义 live region 的代码接线不等于 VoiceOver/Narrator 实机通过。场式 2.2 / 3.1 / 3.2 按完整条件保留待办。
