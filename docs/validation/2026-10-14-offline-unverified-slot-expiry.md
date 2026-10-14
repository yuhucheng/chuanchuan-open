# 离线未认证卡片有界保留（2026-10-14）

## 背景与规则

真机测试期间，Windows 原生发现测试（`windows/tests/discovery_probe.cpp`）广播的 `diagnostic-probe` 停播后在设备场留下「已离线」卡片，重启只能清空一次，探针再次运行就再次残留。此前 `_known` 对离场未认证槽位无期限保留。

现在为**未认证且已不在当前快照**的展示槽位设置 `DeviceField.offlineRetention = 1 分钟` 的有界保留：

- 每个离场未认证槽位安排一次性清扫定时器；到期后移除槽位、释放焦点节点并清理悬停/焦点引用。
- 保留期内重新被发现则取消清扫；再次离场重新计满一个保留期。
- **已验证槽位（含「已保存资料」）永不清扫**；仍在快照中的槽位（在线/恢复/已连接）永不清扫。
- 纯展示层簿记：不触碰授权、连接、发现快照与信任语义；名称/UUID 仍不作为信任关联依据。

## 验证

公开仓 `release/v0.1.0`、Flutter 3.47.2 / Dart 3.13.2：

- 新增组件用例 2 项：① 未认证离线槽位到期清扫、已验证离线槽位保留；② 保留期内重现取消清扫、再次离场重新计期（同时覆盖「首个定时器未取消会误删」的回归路径）。
- `flutter test --no-pub test/device_directory_test.dart test/device_field_layout_test.dart`：14/14。
- `flutter test --no-pub` 全量：381 通过、1 跳过，无失败；`flutter analyze --no-pub` 无问题。
- 测试内定时器使用假时钟推进，不依赖真实等待；`dispose` 取消全部未决清扫，既有用例无 pending timer 影响。

## 边界

- 真机「探针停播 60 秒后卡片自动消失」的端到端观察未在本记录内完成；以上为组件级证据。
- 真机背景事实（dns-sd 实测）：`diagnostic-probe` 来自本仓 Windows 发现测试；当前 Windows 产品实例广播 `name=MAXHUB-LXXY`（系统电脑名），与本日 `55a6a94` 设备名修复一致。
