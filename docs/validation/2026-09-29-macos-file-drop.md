# macOS 原生文件拖入接线

Mac 主窗口接收系统 `.fileURL` 拖放，整批 URL 交给与系统选择器相同的 `SelectedFileStore`。只接纳普通文件，拒绝目录、符号链接、远程 URL、纯文本路径和超过 64 项的批次；无有效 token 的读取仍被拒绝。路径不跨入 Dart，队列使用同一摘要、取消、移除及退出释放流程。

原生到 Dart 的交接需要明确确认；拒绝、缺少处理器、10 秒无确认或退出后的迟到结果会释放该批访问。重复或迟到确认不会复活能力。安全作用域由 store 持有到对应文件释放或进程清理，主窗口退出后不再接收拖放。没有接入网络文件发送。

应用层启用 Mac 拖入处理器。同时修复两平台共有的空闲界面问题：仅排入 post-frame 回调不足以请求界面帧，原先文件可能已进入队列却不展示面板；现在明确请求帧。组件回归在额外 pump 之前检查帧已请求，再检查文件已准备且未发送、没有调用选择器以及卸载时释放。

验证入口：

```sh
flutter test --no-pub test/transfers_widget_test.dart test/transfer_queue_test.dart test/file_access_test.dart
bash tool/test_macos_file_drop.sh /absolute/path/to/flutter-sdk
```

Windows 客户端完整 315 项测试和 Flutter 静态分析通过。Mac Swift Package 共 9 项通过，包含实际私有 NSPasteboard、生成文件、整批回滚及原 token 保留。桥接探针直接链接真实 FlutterMacOS 与生产 FileAccessBridge/store，验证成功、拒绝、10 秒超时、重复/迟到确认、路径伪装令牌和退出竞争。主窗口与桥接的真实框架类型检查通过；该类型检查仅用空函数替代插件注册，不能替代完整应用构建。

探针不读取系统剪贴板、不操作 Finder、不采集画面。它使用独立 pasteboard 和临时测试文件，不证明 Finder 鼠标手势、沙箱授予范围或用户会话中的完整端到端拖入。普通 Mac 签名构建当前仍待交互签名问题解决；上述检查不绕过或修改该签名配置。场式客户端 2.5 和双平台验收继续保持待办。
