# desktop 3.1 Mac 侧三条精确命令（2026-10-15）

桌面 change 3.1 要求按**精确命令参数**执行并分平台记录通过/失败与版本。此前 Windows 已记录的运行参数不符、Mac 侧未以这三条命令留证（见 `chuanchuan/docs/validation/2026-10-14-normal-desktop-build-gate.md` 第 6-8 行），故 3.1 保持待办。本记录补齐 **Mac 侧**。

## 执行事实

公开仓 `chuanchuan-open` `release/v0.1.0` @ `853c94f`（含 Windows wire-driven discovery 修复；该提交仅触 Windows 原生与文档，不改变 Mac 构建输入以外的 Dart 代码），工作区干净。SDK 经 `.local/media-sdk/package` 源码符号链接取自 `chuanchuan`（`packages/share_hub_media_sdk` 0.1.0-dev.1）。

| 命令（逐字） | 结果 |
| --- | --- |
| `flutter analyze --no-pub` | 通过，`No issues found!`（2.9s） |
| `flutter test --no-pub` | 通过，**385 通过、1 跳过、无失败**（约 11s） |
| `flutter build macos --debug --no-pub` | 通过，`Built build/macos/Build/Products/Debug/Share Hub.app` |

版本：客户端 `0.1.0-dev.1+1`（pubspec），SDK `0.1.0-dev.1`，Flutter 3.47.2 / Dart 3.13.2。三条命令按上述顺序在同一会话依次执行，退出码均为 0。

## 边界

- 本记录只覆盖 **Mac 侧**；3.1 的勾选还要求 Windows 以同样三条精确命令（其构建为 `flutter build windows --debug --no-pub`）执行并留证。Windows 已有结果参数不符，需其重跑，不由 Mac 推定。
- 本记录是构建/测试证据，不替代真实预览停止、权限撤回、后台与双机验收（desktop 3.2/6.1/7.x 仍待）。
