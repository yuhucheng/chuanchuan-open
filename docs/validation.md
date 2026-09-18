# 验证摘要

此文档记录截至 2026-09-16 的产品事实，历史实验和内部执行日志单独保存。

- macOS 当前宿主与 SDK 原生插件编译、运行时加载已通过；生成的 A/B 测试窗口获得真实首帧和持续帧，启停循环已有验证。
- macOS 来源退出触发的释放竞态已修复，修复后的单次退出/失效来源拒绝回归通过；该平台完整生命周期、最小化、权限撤销和稳定竞态复现仍未完成。
- 既有客户端 33 项、SDK 22 项测试及 macOS 平台层 4 项测试通过；模拟测试不等于实机或双机验收。
- Windows 当前 SDK 与宿主组合已通过选定测试窗口 20 次真实首帧/四象限/启停、16 秒生成内容变化、来源最小化后显式重启、活跃来源关闭结束通知与失效来源拒绝。显示器采集和完整生命周期仍未验收。
- 跨设备会话、远端投屏和完整直连/中继流程仍未验收。
- 当前 SDK 为内部源码开发适配器，正式二进制、签名和稳定发行未交付。

2026-09-16 开发工作区迁移后的 Mac 回归中，客户端与 SDK 的 flutter analyze 均无问题，客户端 33 项及 SDK 22 项测试重新通过，macOS Debug 在新路径重新构建成功；该迁移回归没有重新执行录屏、Windows 实机或双机测试。

同日 Windows 定向修复后，两个包 analyze 均无问题，客户端 33 项与 SDK 22 项测试通过，Windows Debug 普通入口恢复构建成功。原生采集探针在 unaware 与 PerMonitorV2 两模式均成功取得真实帧，测试窗口不在前台；SDK 窗口图案集成测试通过。使用经输入与哈希核对的现有本机开发 DLL，本轮未重新构建整个 WebRTC，也不代表正式二进制 SDK 发布。

后续生命周期测试复现活跃来源关闭后缺少结束通知，已通过 Windows 原生来源 ID 检查修复。当前 SDK 26 项、客户端 33 项测试及两包 analyze 通过；真实集成测试通过并恢复普通 Windows Debug 构建。停止后的回调稳定有证据，原生停止后帧/资源计数、活动采集中的宿主隐藏/关闭与权限撤回仍未完成。

Windows 文件准备已接入系统选择器与令牌读取，保留 64 项与 256 KiB 边界；原生文件和平台测试 3/3 通过。真实选择器读取普通、空、中文空格名称文件，摘要核对、取消、移除、清空及普通主窗口退出释放均通过；保留时独占打开被拒绝，移除/清空/退出后可独占打开且内容未改变。选择器打开期间关闭宿主的真实消息循环与销毁路径未实测，迟到结果处理由自动测试及代码审查覆盖。

本次回归针对保留了既有未提交产品改动的本地工作区，不代表迁移提交本身已完成上述功能或获得发布验收。

后续普通 Windows 客户端实测通过采集中最小化/恢复、手动停止后保持空白及重启。活动采集中退出曾触发 abort；客户端现在等待采集清理后允许关闭，失败则取消退出并保留重试界面。两项定向回归先失败后通过，客户端 35/35 测试、analyze 和普通 Windows Debug 构建通过，修复后一次真实采集中退出重放确认进程消失且没有运行时错误。

原生探针补充两种 DPI 各 20 次启停、停止后回调与资源快照。直接 capturer Stop 后保留 renderer 时仍出现一次迟到回调，严格断言失败；重复停止及移除 renderer 后的有限观察期无增加。资源计数短期稳定，完整清理后仍高于初始化前，不能宣称零泄漏。此诊断与 SDK 完整停止的边界不同，权限撤回、录屏指示及完整跨平台矩阵继续待验。

提交前拉取同名 release/v0.1.0 的连接功能与预览编排更新，并保留本轮 Windows 改动。合并后客户端 42 项、SDK 26 项、连接包 17 项测试通过，两包 analyze 无问题，普通 Windows Debug 构建通过；管理工具 60 项测试及工作区检查通过。连接包首次拉取需单独恢复其锁定测试依赖。此轮合并回归未重新进行实采、macOS 构建或跨设备通信，前述实机证据仍限定于各自执行时的代码组合。

## 2026-09-17 公共会话契约兼容验证

媒体 API 0.2.0 保持 PreviewEngine 源码兼容，新增会话公共包 0.1.0（协议版本 2）。连接包 19 项、会话协议 11 项、媒体契约 8 项、客户端 42 项、SDK 28 项测试通过，相关静态分析及 macOS Debug 构建通过。SDK 仍只提供本地预览，不因新增类型自动开放远端能力。协议测试和本机回环 PAKE 不代表双机通信、真实休眠、后台恢复或远端媒体已验收；Windows 构建与实机验收本轮未执行。

## 2026-09-17 后台生命周期开发验证

客户端资源所有者提升至应用根，Windows 托盘与 macOS 菜单栏接入关闭到后台、打开及明确退出。退出统一撤销连接、等待采集、取消选择器并释放文件令牌；清理失败保留重试。SDK macOS 隐藏/最小化不再主动结束采集。当前无远控执行器，菜单显示“当前无远控会话”；Windows 可信连接适配仍不可用。

客户端 46 项、SDK 28 项测试及客户端 analyze 通过；macOS Debug 构建通过，平台 Swift 6 项测试以独立 scratch-path 通过（默认缓存存在迁移前路径冲突）。这些是自动测试/构建证据。本轮 Mac 锁屏，后台真实帧与菜单恢复/退出未实测；Windows 新宿主代码未编译、未实机验证。默认主屏及完整权限/资源矩阵仍待完成，旧 hidden-stop 验收不适用于新语义。工作区有未提交修改，不是发布验收。

## 2026-09-17 自动发现与来源策略

客户端启动自动发现，与允许连接独立，失败可重试；退出等待未完成启动，忽略释放后的回调。CaptureSource 增加兼容的可选 isPrimary；macOS SDK 提供原生主屏标记、稳定来源令牌、启动复核与主屏变化结束。客户端刷新保留有效来源，失效不回退；Windows 缺少可靠主屏元数据时要求明确选择，默认主屏仍待适配。

Mac 当前工程产物已有限复验自动发现、未手选时启动主屏、隐藏/关闭恢复和离页后仍预览、采集中明确退出后进程消失。观察窗口会激活应用，不代表隐藏期间连续帧、完整菜单栏点击、权限撤回或主屏切换已验收。Windows 本轮未构建/实测；工作区仍未提交。

## 2026-09-17 场式首页开发验证

首页改为稳定设备节点、搜索与场内聚合，无侧栏；普通点击/Enter 和 600ms 长按进入动作，六位输码可取消，未交付远端能力明确不可用。主题使用仓内 token，跟随系统/浅/深选择持久化；产品构建无需管理仓。单色几何已接入，正式品牌字标和平台图标仍待验收。

Mac 实机验证空场、深浅切换与跨重启偏好；修复新 UI 退出触发 AppKit 嵌套终止等待，修复后界面退出与 Cmd+Q 均确认进程消失。失败版本的进程用 SIGTERM 结束，不计为通过。Windows 主屏、拖放和完整后台矩阵由用户另在 Windows 开发机完成，本轮未验收；当前为未提交工作区，不是发布组合。

本轮最终客户端 59/59、管理工具 60/60 测试通过，客户端 analyze 与 Mac Debug 构建通过，workspace:check 通过。平台实机范围仅限上述明确步骤；字体字标、平台图标与完整读屏/高对比仍未验收。

## 2026-09-18 macOS 真实预览验收（plan-desktop-platform-completion 2.2）

在真实 macOS 主机（arm64，Flutter 3.47.2）重新构建当前插件布局并运行真实客户端验收。验收入口为专用开发 target `lib/dev/macos_acceptance_main.dart`，不进入产品入口；它按产品方式挂载引擎视图，读取真实权限与真实来源，并对主屏执行两次真实采集。验收构建的隔离方式见文末「验收入口的构建隔离」一节（本条记录当时仍写入产品路径，该问题已修复）。构建 `flutter build macos --debug --no-pub` 通过；`swift test --package-path macos/Platform` 6/6 通过；客户端 analyze 无问题，`flutter test` 72 项通过（含本轮新增 2 项回归）。

真实客户端记录（2026-09-18，同一构建）：

- 设备身份稳定：`loadDevice()` 两次返回同一 discovery id，名称默认「我的 Mac」。
- 权限读数为真实 TCC 状态：`screenRecording=true`、`accessibility=false`，未以权限值推断画面。
- 真实来源 17–19 项（2 个屏幕 + 15–17 个窗口），其中主屏唯一标记为「显示器 1 · 1728 × 1117」；未手选来源时控制器选择该主屏，没有回退到整屏或首个来源。
- 两次真实采集均取得首帧：冷启动首帧 205/218/233 ms，停止后恢复再次取得首帧 152/166 ms；停止后 `cleanupFailed=false`，可立即再次启动并再次停止。
- 控制器路径（`PreviewController`）逐项通过：`loadSources` 17 项、`selected` 为空、`start` 后 `active` 与 `firstFrame` 均为真、`stop` 后 `active` 为假且无释放失败、恢复与再次停止一致。

未授权路径（独立 bundle id `dev.sharehub.client.permprobe`，ad hoc 重签，不影响已授权客户端）：preflight 为假、来源枚举为空、原生 `sources()` 抛 `PlatformException(code: permission)`。据此本轮修复：客户端不再把原生权限失败描述成来源问题，改为指向系统设置；新增 2 项回归覆盖权限失败与未知失败的分流。

环境限制（本轮实测，非产品缺陷）：从沙箱化 shell 直接启动 app 会因 App Sandbox 容器初始化被拒而 SIGTRAP（`_libsecinit_appsandbox`），必须经 LaunchServices（`open`）启动；Xcode 解析 Swift Package Manager 依赖需要 `IDEPackageSupportDisableManifestSandbox`，否则 `sandbox_apply: Operation not permitted`；`flutter test` 在注入 `HTTP_PROXY` 时无法连接 flutter_tester 的回环 WebSocket。

本轮仍未完成：隐藏/关闭主窗、最小化、菜单栏入口与 20 次启停的完整后台矩阵；上述验收未覆盖 Windows 侧，也未替代任何双机或发行验收。默认主屏与「停止后恢复」仅在本条记录限定的 macOS 构建上成立。

入口 `integration_test/macos_platform_test.dart` 已按真实进程/真实通道编写，但在当前环境无法由 `flutter test -d macos` 启动 app（同一沙箱限制），因此本轮以开发 target 的记录为准，该集成入口保留待可用环境执行。

## 2026-09-18 采集中真实权限撤回

同一构建的专用 target 增加 `revocation` 模式：经产品控制器启动一次真实采集，在容器内写入就绪标记，等待外部撤回后记录观测结果；外部执行器 `tool/test_macos_acceptance.sh revocation` 负责执行 `tccutil reset ScreenCapture dev.sharehub.client` 并回收结果。

实测（2026-09-18 16:31，同一构建；系统崩溃报告计数 4 → 4，未新增）：

| 观测项 | 结果 |
|---|---|
| 撤回前 preflight / 采集状态 | `screenRecording=true`；`active=true`、`firstFrame=true`（269 ms），来源 17 项，选中「显示器 1 · 1728 × 1117」 |
| `tccutil reset ScreenCapture dev.sharehub.client` | 成功（exit=0） |
| 撤回后运行中进程的 preflight | 连续 60 次采样（0–59.6 s）**始终为 true** |
| 撤回后运行中的采集 | **未中断**：无 `ended` 事件、无权限轮询停止、`active` 保持为真 |
| 撤回后同进程新的 `SCShareableContent` 查询 | 失败，原生返回 `capture_failed` |
| 撤回后重复停止 | 幂等：`active=false`、`cleanupFailed=false`、无错误信息 |
| 撤回后**新进程**的 preflight | false |
| 撤回后新进程 `sources()` | `PlatformException(code: permission)`，客户端不发起采集（`controller` 路径整体跳过） |

结论与边界：macOS 按进程缓存录屏 TCC 决定，`tccutil reset` 只清除 TCC 记录、不通知运行中的进程，而系统设置开关会要求正在运行的应用退出并重新打开。因此「撤回后终止采集并释放资源」在 macOS 上由操作系统（进程退出）保证，客户端进程内 2 秒权限轮询观测不到该变化。这不是客户端缺陷，但也不得据此宣称进程内已能感知撤回；客户端在重开后拒绝采集的行为本轮已实测。反向的「采集中被原生结束」路径由下方的来源关闭验收独立覆盖。

撤回操作会清除本机对该 bundle id 的录屏授权，后续任何需要真实采集的验收都必须在系统设置中重新授权一次并重开应用（本次已重新授权，见下节）。

## 2026-09-18 停止释放、20 次启停与采集中来源关闭

`tool/test_macos_acceptance.sh lifecycle|source-loss` 两个模式在重新授权后执行（2026-09-18 17:21–17:22，同一构建；崩溃报告计数 4 → 4，未新增）。

lifecycle（真实主屏「显示器 1 · 1728 × 1117」，来源 16 项，权限 `true`）：

| 观测项 | 结果 |
|---|---|
| 启动前渲染树中的预览 Texture | 不存在 |
| 采集中的预览 Texture | 存在（52 ms 内出现） |
| `stop()` | 无错误 |
| 停止后的预览 Texture | **不存在**（0 ms 内确认） |
| 20 次真实启停 | 20/20 取得首帧，0 报错，总耗时 8280 ms；首帧 min 139 / p50 157 / max 164 ms |
| 20 次后的预览 Texture | 不存在 |
| 20 次后控制器恢复 | 重新启动取得首帧，`cleanupFailed=false` |

说明：本轮可得的最强「停止后不再更新画面」证据是三层叠加 —— 操作系统层 `stopCapture` 成功返回（错误码只容忍 `.attemptToStopStreamState`）、原生会话清除像素缓冲并注销纹理、Dart 侧预览 Texture 从渲染树移除。本轮**没有**取得像素级帧计数证据（原生只在首帧回调一次，Dart 侧无法读到逐帧信号），因此不得声称已逐帧验证画面冻结。

source-loss（采集真实 TextEdit 窗口，随后用 `pkill` 关闭该窗口；两次独立执行结果一致）：

| 观测项 | 结果 |
|---|---|
| 选中来源 | 「文本编辑 · 打开」（TextEdit 窗口） |
| 采集建立 | `active=true`、`firstFrame=true`，228 / 240 ms |
| 窗口关闭后 | **原生结束事件到达**：`ended=true`，306 / 409 ms 后客户端进入停止 |
| 客户端提示 | `屏幕预览已被系统结束。`（`endedPath=native-ended-event`），`cleanupFailed=false` |
| 失效来源回落 | **不回退**：`loadSources` 报「所选来源已失效，请重新选择；不会自动切换到整屏。」，`start` 报「请重新选择画面来源；不会自动切换到整屏。」 |
| 显式改选主屏后恢复 | 取得首帧（613→619 ms），停止后 `cleanupFailed=false` |

这是原生结束路径（`SCStreamDelegate.didStopWithError` 或帧状态 `.stopped/.suspended` → `onEnded` → 控制器 `stop`）首次取得真实客户端证据；此前该路径只有单元测试覆盖。

仍未完成（本轮未执行，不得由上述记录代替）：隐藏/最小化/关闭主窗后的持续采集与菜单栏停止入口、明确退出后的资源回收矩阵、Windows 侧对应验收。

## 2026-09-18 验收入口的构建隔离

问题：`flutter build macos --target=lib/dev/macos_acceptance_main.dart` 与产品构建写入**同一路径** `build/macos/Build/Products/Debug/Share Hub.app`，一次验收运行就会把产品 app 替换成开发入口，所以"当前这个 app 是哪个入口"取决于最后一次构建用的 target，工作区因此难以判断。

`tool/test_macos_acceptance.sh` 已改为四步，产品路径不再被触碰：

1. `flutter build macos --debug --no-pub --config-only --target=lib/dev/macos_acceptance_main.dart` —— 只把 `FLUTTER_TARGET` 写进生成的 xcconfig，不执行构建。
2. `xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -derivedDataPath build/acceptance-dd -clonedSourcePackagesDirPath build/macos/SourcePackages build` —— Dart 编译仍由 Runner 的 Run Script 阶段完成，产物落在独立 DerivedData，SwiftPM 依赖复用已有解析结果。
3. `ditto` 到 `build/acceptance/Share Hub Acceptance.app`，经 `open` 从该路径启动。
4. 退出时用 `--config-only`（默认 target）还原生成的配置。

两道守卫：产品 app 的 mtime 发生变化、或复制出来的 app 不含 `acceptance-mode` 标记时，脚本直接失败退出。

**bundle identifier 有意保持不变**（`dev.sharehub.client`）：App Sandbox 容器与录屏授权都按它索引，因此验收仍写同一个容器（`~/Library/Containers/dev.sharehub.client/Data`）、沿用同一份授权，无需重新授权即可运行。

实测（2026-09-18 17:39，`full` 模式）：产品 app mtime 保持 `17:20:59` 未被覆盖；验收 app 从 `build/acceptance/` 启动；`permissions.screenRecording=true`（授权随 bundle id 保留）；来源 16 项、主屏唯一「显示器 1 · 1728 × 1117」、冷启动首帧 207 ms、停止后恢复 182 ms、控制器路径全绿；崩溃报告 4 → 4。`pkill` 模式已改为按绝对路径匹配并单独复验通过。

代价与开关：验收构建不再复用产品构建的增量产物，首次需完整编译一次，之后 `build/acceptance-dd` 增量复用；设置 `ACCEPTANCE_CLEAN=1` 可强制从零重建。`build/` 整体仍被 `.gitignore` 覆盖，三个产物目录（`build/acceptance-dd`、`build/acceptance`、`build/macos`）都可整目录删除后重建。

## 2026-09-18 macOS 后台矩阵（6.1 / 7.1 / 7.2 的 macOS 部分）

`tool/test_macos_acceptance.sh background`，2026-09-18 17:52–17:53 两次执行（第二次为加入停止对照后的最终结果）。验收宿主用**产品同一个 `DesktopLifecycle`** 接线后台入口，采集与退出走产品控制器，崩溃报告计数 4 → 4，退出后进程已终止。

### 为取得正面证据新增的原生接口

「隐藏时仍在采集」此前只能间接推断（会话未结束、无 `ended` 事件、Texture 仍挂载），无法区分「采集停了」与「只是渲染暂停」。为此补了两处**只读**可观测性，不改变任何既有行为：

| 位置 | 新增 | 说明 |
|---|---|---|
| SDK 原生（chuanchuan）`ScreenPreviewBridge` | `capturedFrames`（`didOutputSampleBuffer` 接受的有效帧）、`renderedFrames`（`copyPixelBuffer` 拉取次数）、`lastFrameAt` | 两个计数器分开，隐藏/最小化时即使渲染停摆也能量到采集是否在推进 |
| SDK 原生 | 通道方法 `stats`（只读） | 在 `busy`/`session` 守卫**之前**处理，因此采集中也能读 |
| 客户端原生（chuanchuan-open）`MainFlutterWindow` | 通道方法 `window.state`、`system.indicators` | 后台状态与菜单栏项的可观测快照 |
| 客户端原生 | 通道方法 `window.action`（`minimize`/`deminiaturize`/`hide`/`unhide`/`close`/`reopen`） | 见下方「未支持条件」：本机无辅助功能权限，无法用真实点击驱动窗口动作，故每个动作复用与相应用户手势**同一条代码路径** |

`stats` 与 `window.*` 都只在宿主–插件通道上，**不进入 SDK 的 Dart 公共 API**，产品客户端不调用。

### 阶段帧计数（采样窗口：foreground 2 s，其余 3 s）

| 阶段 | visible | miniaturized | onscreen | capturedFrames 增量 | renderedFrames 增量 | 最后帧龄 |
|---|---|---|---|---|---|---|
| foreground | true | false | true | +58 | +59 | 30 ms |
| window-minimized | **false** | **true** | false | **+88** | +88 | 4 ms |
| window-restored | true | false | true | +59 | +59 | 7 ms |
| app-hidden | **false** | false | false | **+88** | +88 | 30 ms |
| app-unhidden | true | false | false | +59 | +58 | 5 ms |
| closed-to-background | **false** | false | false | **+89** | +89 | 9 ms |
| after-reopen | true | false | true | +59 | +59 | 16 ms |

换算：3 s 窗口 +88/+89 ≈ **29.6 fps**，2 s 窗口 +58/+59 ≈ **29.3 fps**，与原生 `minimumFrameInterval = 1/30` 的上限一致。**窗口不可见与可见时的采集帧率没有差别**，且每阶段 `running=true`、`acceptingFrames=true`、`hasPixelBuffer=true`、`sessionId` 未变（单一会话贯穿全程）。这是 7.2「隐藏仍持续采集」的正面证据，而非推断。

`window-restored` / `app-unhidden` 阶段的 `onscreen=false` 是采样时机所致（刚解除隐藏后合成器尚未上报遮挡状态），不影响该阶段的 `visible` 结论。

### 菜单栏入口与后台驻留（7.1）

`trayAfterInitialize`（`desktop.initialize` 之后，`connectionSupported=false`）：

| 菜单项 | enabled |
|---|---|
| 打开主窗口 | true |
| 允许连接（当前平台不可用） | false（与 `connectionSupported=false` 一致） |
| 停止控制（当前无远控会话） | true |
| 退出串串 | true |

`trayInstalled=true`、`trayButtonAvailable=true`、`desktopReady=true`，且以上状态在**全部七个阶段**（含关闭到后台后）都保持为真 —— 菜单栏入口在窗口不可见时未被拆除，这是「关闭到后台」可恢复的前提。

关闭到后台走真实 `close()` 路径：`visible=false` 但 `processAliveAfterClose=true`、`controllerAfterClose.active=true`、`cleanupFailed=false` —— 引擎、采集会话与菜单栏进程内保留。

### 系统级唤醒

关闭窗口后，验收宿主写出标记文件，由执行器用 `open "$APP"`（**不带 `-n`**）唤醒已运行实例，即 `applicationShouldHandleReopen` 的 LaunchServices 真实路径，不涉及任何辅助功能权限。结果 `externalReopen.observed=true`，唤醒后 `visible=true`、`key=true`、`trayInstalled=true`。**未使用** `window.action: reopen` 兜底（报告中的 `externalReopenFallback` 字段不存在，即未触发）。

### 退出与资源回收（6.1）

`desktop.requestExit()` → `allowed=true`、`exited=true`、`error=null`；退出时序上 `active=false`、`cleanupFailed=false`、`transfersRemaining=0`。执行器确认**退出后进程已终止**，崩溃报告 4 → 4，菜单栏项随进程消失。

### 录屏指示：本轮**未取得**可用证据

按 6.1「记录录屏指示」的要求做了对照枚举（`system.indicators`，`CGWindowListCopyWindowInfo` 过滤 `Window Server` / `Control Center` 等）：

| 采样点 | 命中窗口数 |
|---|---|
| 采集中 | 5 |
| 采集停止后 | 5 |

两次命中都是常驻的 `Window Server · StatusIndicator`（菜单栏区域 1697,3 及屏幕外坐标）与 `Cursor`，**逐项一致**。结论：这些窗口与采集无关，**无法用公开窗口枚举区分 macOS 的录屏指示**。因此本轮不得声称「观测到录屏指示」，此项作为未支持条件记录；系统自身的录屏指示属 WindowServer 私有实现，无公开 API 可读。

### 未支持条件（不得由上述记录替代）

1. **菜单栏项与窗口按钮未经真实点击驱动**：本机无辅助功能权限（`osascript` 对 System Events 报权限违例），无法点击菜单栏或窗口按钮。`window.action` 复用与用户手势相同的 selector/代码路径，但这是**程序化等价路径**，不是真实点击证据；菜单栏项的「点击」本身只有状态读数与等价调用两层覆盖。
2. **录屏指示**：见上，公开接口无法区分，未取得证据。
3. **「停止后画面冻结」仍无像素级证据**：`capturedFrames` 现在能证明「停止前持续出帧」，但停止后的冻结仍需帧计数或像素比对，本轮未做。原生 `stats` 已提供 `capturedFrames`，具备补测条件。
4. **Windows 侧未参与**：6.1 / 7.1 / 7.2 均要求两平台，上表全部是 macOS 单平台证据，**不足以勾选任何一项**。
5. **`window.action` 是验收专用接口**：产品 UI 不调用；若后续认为不应留在产品 Runner 中，应在 7.1 完成后评估移出。

### 本轮回归

`flutter analyze --no-pub` 无问题；`flutter test --no-pub` 72/72；SDK `flutter test --no-pub` 91/91；`swift test --package-path macos/Platform` 6/6。验收构建未覆盖产品 app（mtime 守卫通过）。
