# Windows 高 DPI 预览验证

## Windows D2 修复与实采验收（2026-09-16）

当前结论：Windows 高 DPI 所选窗口预览已通过真实像素验收，宿主仍为 `PerMonitorV2`。原生库按帧的实际像素尺寸和行跨度转换，修正窗口坐标与帧尺寸混用；窗口焦点请求改为尽力处理，来源枚举不再隐式生成所有新窗口的缩略图。

环境：Windows 11 10.0.26200 / 200% 缩放，Windows SDK 10.0.26100.0，VS 2022；Flutter 3.47.2 / Dart 3.13.2；客户端及 SDK 0.1.0-dev.1，API 0.1.0，flutter_webrtc 1.6.2+hotfix.1。构建基于本轮未提交工作区；本地开发适配器和补丁 DLL 不等于正式二进制 SDK 发布。

| 检查 | 结果与范围 |
| --- | --- |
| 原生合成帧回归 | 修复前 3/3 失败，修复后 3/3 通过：行填充、窗口与帧尺寸不同、同面积宽高变化 |
| 原生 DPI 探针 | 两个独立进程各采集 2 秒：unaware 40 帧、PerMonitorV2 39 帧；均无访问异常，测试窗口当时未在前台 |
| 实际尺寸 | 同为 480×320 帧，unaware 窗口矩形 480×320，PerMonitorV2 窗口矩形 960×640，证实不能用窗口矩形读取帧 |
| 探针错误出口复验 | 加入访问异常即失败后，两模式分别 38/38 帧，访问异常均为 0 |
| Flutter 原生像素验收 | 两次首帧、两组四象限颜色、变化后重采、重复停止、来源关闭后拒绝全部通过 |
| SDK / 客户端回归 | 静态检查均无问题；SDK 22 项、客户端 33 项测试通过，含启动中取消、迟到回调及清理失败重试的单元/契约检查 |
| 构建保护 | 额外核心源码修改、缺失 DLL、错误 DLL 校验值和过期输入均被拒绝；有效依赖替换检查通过 |
| 规格与计划 | 两仓 spec:validate、规格链接及 diff 检查通过；17 个未归档 change 共 124 项任务，5 完成 / 119 待办，两仓计划正文一致 |
| 普通应用 | 测试入口退出后恢复普通 Windows Debug 构建，通过 |

实际应用与 SDK DLL 的 SHA-256 一致：`6a0d77f1071426915f40fb142879b47c1e87ccbd78120f08c1f76d61e222f645`。SDK Windows FFI 构建钩子替换依赖 DLL，并检查 DLL、补丁和版本锁；没有修改 Pub 缓存或宿主 DPI 配置。

复验命令：SDK 包内运行 `tool/test_windows_capture_dpi.ps1 -LibWebRtcDirectory ./build/windows/libwebrtc`；配置 SDK 的公开宿主内运行 `tool/test_media_sdk_windows.ps1 -FlutterCommand <flutter.bat路径>`。测试只操作自建随机标题/PID/HWND 窗口，像素仅用于内存断言。

未完成：显示器、多显示器/不同缩放、完整 20 次启停与权限撤回矩阵、Mac 当前插件实采、Windows 文件准备和远端投屏。本轮只勾选闭源 D 的 2.1/2.3 和开源 D 的 2.1；2.3 的单元证据不代替完整实机生命周期验收。

## 历史：2026-09-15 D1 诊断（以下未完成结论为当时状态）

### 结论与范围

完成 `plan-desktop-platform-completion` 的 1.1 根因定位；2.1 正式修复仍未完成。当前 SDK 采集链在本机每显示器 DPI 模式下无法交付首帧，不能将其归因于 Dart 未绑定轨道或单纯未取得前台焦点。尚未定位到原生库内部的具体错误语句。

环境：Windows 11 10.0.26200、Windows SDK 10.0.26100.0、VS 2022/MSVC 19.44、Flutter 3.47.2/Dart 3.13.2；客户端和开发 SDK 0.1.0-dev.1，公共 API 0.1.0。本记录仅验证自建彩色窗口，没有采集用户桌面，也不证明远端投屏、显示器采集或其他机器均通过。

### 对照证据

| 对照 | 结果 |
| --- | --- |
| 从宿主直接运行仓外 SDK 测试路径 | Flutter 作为普通单元测试运行，原生插件未加载，报 `MissingPluginException`；不能用于原生验收 |
| 宿主 `integration_test` 下的入口，原始 `PerMonitorV2` | 找到唯一标题、HWND 和窗口类型；12 秒无首帧 |
| 先显示 Flutter 首个界面，再启动测试窗口 | 即使测试窗口在前台，仍无首帧 |
| 临时原生诊断副本，原始宿主 DPI | `Start=CS_RUNNING`、`IsRunning=true`，流/渲染器存在，实际轨道匹配，渲染器没有收到帧 |
| 同一原生 DLL 的独立程序，仅切换进程 DPI | 不感知 DPI：2 秒收到 32 帧；`PerMonitorV2`：启动成功但 0 帧 |
| Flutter 宿主临时改为 `Unaware`，其他测试条件保持一致 | 测试全部通过：两次真实首帧、四象限像素、图案变化后重采、重复停止、来源关闭后拒绝启动 |
| `Unaware` 进程 + UI 线程 `PerMonitorV2` 的混合模式尝试 | 仍无首帧，未作为修复保留 |
| 恢复原始 DPI 和未插桩依赖，用正式测试脚本复验 | 首帧测试仍失败；脚本随后成功恢复普通客户端 Debug 构建 |

焦点仍可能独立导致 `CS_FAILED`。自动运行时如测试窗口未取得焦点，应记录为启动前置条件未满足，不能把该次失败计为 DPI 对照结果。原生库启动成功也不等于有真实画面。

### 可重复入口

客户端已经配置带验证材料的 SDK 后，在本仓根目录执行：

```powershell
./tool/test_media_sdk_windows.ps1 -FlutterCommand <flutter.bat完整路径>
```

脚本在被忽略的 `integration_test/.sdk-validation` 内生成仅导入 SDK 测试的临时入口，不复制 SDK 实现。测试只匹配自己生成的窗口，在内存比较像素；无论测试通过或失败，均删除自建入口并重新构建普通客户端。运行前关闭正在使用 Debug 可执行文件的开发版应用，避免链接器无法替换文件。

### 下一步与未验收

- 在 SDK 采集层修复 DPI 兼容性或评估替换原生采集后端，公开媒体 API 暂不改变。
- 保留正式宿主的 `PerMonitorV2`。降低整个客户端的 DPI 感知能力只是诊断对照，不是可交付修复。
- 修复后在原始 DPI 下重新通过窗口像素、变化后重采与来源关闭测试，再补显示器、不同缩放、多显示器、最小化和 20 次启停。
- Windows 文件准备、macOS 当前插件验收、网络投屏均未在本轮完成。

[Windows 线程 DPI 上下文](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setthreaddpiawarenesscontext)解释进程默认值与线程覆盖的区别；上述结论来自本机对照，不从 API 文档推定采集结果。

### 本轮静态与构建检查

- SDK：flutter analyze 无问题，22 项单元测试通过。
- 客户端：flutter analyze 无问题，33 项单元/组件测试通过。
- 两仓 npm run spec:validate 通过；普通 Windows Debug 入口恢复构建通过。
- 原始 DPI 的真实首帧测试仍失败；Mac 和完整桌面生命周期未验收。
