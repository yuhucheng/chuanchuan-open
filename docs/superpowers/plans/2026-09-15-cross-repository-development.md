# 两仓未归档 Change 开发计划

> **For agentic workers:** 实施时使用 superpowers:executing-plans，按工作包逐项执行现有 tasks.md。初始阶段只同步规格和计划；2026-09-15 用户已授权继续 Windows 开发，执行状态见下文。遵守既有 main 规则，不自动建分支/worktree。

**Goal:** 将开源 8 个、闭源 9 个未归档 change 对齐为可追踪的开发顺序、跨仓交付物和验收关口。

**Architecture:** 开源仓拥有客户端、平台宿主和公共契约；闭源仓拥有 SDK 实现、官方服务和独立实验。跨仓工作先确定公开契约，再分别实现，最终以同一组版本和真实设备验收。

**Tech Stack:** 当前锁定 Flutter 3.47.2 / Dart 3.13.2、必需媒体 SDK、公共 share_hub_media_api；文档工具 OpenSpec 1.13.0 / Node.js >=20.19.0。信令服务技术栈、身份算法和二进制封装格式由对应设计任务决定。

**Spec:** [本仓规格索引](../../../openspec/README.md)、[完整清单](../../../openspec/catalog.json)，以及下表列出的各 change 的 proposal.md、design.md、specs 和 tasks.md。

**Plan version:** 0.1.0。产品基线仍为 0.1.0；此计划只补开发次序和依赖，不改需求条款，因此现有 spec-version 保持 0.1.0。计划版本、规格版本和公共 API 版本分别维护。

## Global Constraints

- 本文在两仓同路径保存相同正文。仓库限定名称是唯一键，例如 `open:plan-sdk-distribution` 与 `closed:plan-sdk-distribution` 是不同交付物。
- `open` 指 chuanchuan-open，`closed` 指 chuanchuan；责任分配到仓库和维护角色，不擅自指定人员或工期。
- 本仓 change 的实现明细仍以自己的 tasks.md 为准，不复制对仓实现，也不把本计划当作任务已完成的证据。共 124 项实施任务；两仓 Windows 1.1/2.1 及闭源 2.3 已完成，累计 5 项完成、119 项待完成。
- 基线 9 份、待办规格 22 份、未归档 change 17 个；本次不合并待办到 baseline，不归档 change。
- 公共契约以开源包及其规格为唯一来源。协议评审后才确定新增文件和类型签名；不得按本计划臆造已存在的接口。
- 正常客户端和贡献者构建均要求 SDK；测试替身和隔离测试材料只用于测试，不能形成可发行的无 SDK、免激活或匿名凭据路径。
- `release-target: unassigned` 保持未排期。本文允许先梳理其前置决定；进入产品实现前必须在两仓版本计划明确归属。阶段编号不是新产品版本或发布日期。
- 平台模拟、历史构建、当前真实帧、双机通信和线上服务分别验收。缺少设备或权限时记录缺测，不以另一平台结果代替。

## 开发顺序与关口

| 顺序 | 工作 | 进入条件 | 可交付结果 / 退出条件 |
| --- | --- | --- | --- |
| S0：第一轮 | D 桌面现状复现；C 连接契约与 A 资格依赖决定；R 运维维护准备 | 有对应实施任务授权，使用当前 SDK/宿主；云操作另遵守项目运维技能 | Windows 首帧失败证据、Mac 当前布局结果；身份/资格/信令职责和消息样例；续期现场事实。此阶段不把候选技术方案标为已经选定 |
| S1：桌面与本地可信连接 | D 修复/验收；C 本地配对、目录、信令；L 对应桌面实验 | D 根因已确认；C 的身份、配对和本地信令契约已评审 | 两台桌面设备互认身份；拒绝/取消/移除信任有效；断公网冷启动本地连接；真实本地预览及 Windows 文件准备有独立证据 |
| S2：辅助连接 | C 官方登记/转发/短期凭据及直连、中继联调 | C 本地流程稳定；A 的资格输入/验证契约明确；生产上线还需 A 资格功能与 R 运维验收 | 按实际候选对证明直连/relay；信令阻断、云凭据失败、内网配置、取消和旧代次均有可判别结果 |
| S3：桌面远端投屏 | M 的 SDK 媒体会话与客户端发送/观看 | D 真实预览、C 可信连接通过，远端媒体公开契约已评审 | Windows→Mac、Mac→Windows 的来源匹配、对端首帧、持续帧及停止资源释放；直连和受控 relay 分别留证 |
| S4：SDK 交付 | K 正式包装、获取、兼容和签名验收 | 制品契约明确，所声明平台/能力已经验收 | 无私有源码环境取得真实包并构建唯一客户端；缺包/不兼容/安装失败可诊断；签名、依赖和实际加载通过 |
| 后续产品队列 | A 资格完整交付优先解除上线阻塞；F 文件收发；U 远控；N 官方 Android；H 第三方 Android SDK | 各工作项先确定 release-target 和设计决定，再满足下表的分阶段依赖 | 分别按自己的规格完成验收；不能因进入队列表格而宣称已排期或实施 |

S0 的设备复现、契约设计和运维准备可分别进行。K 的包格式设计可与 C 并行，预览能力包的工程验证可在 D 后进行；S4 是所声明能力的正式交付验收，并不要求仅有预览的包等待所有未来功能。R 作为维护工作优先独立安排；L 按本轮平台提取实验，完整跨平台矩阵不阻断已经有证据的桌面子集。

## 全部 Change 的职责与依赖

| 工作组 | 责任仓 / Change | 发布目标 | 本仓交付 / 依赖 |
| --- | --- | --- | --- |
| D 桌面 | open:plan-desktop-platform-completion | 0.1.0 | SDK 宿主、客户端预览编排、Windows 文件访问；与闭源 D 共同验收预览，文件准备独立收敛 |
| D 桌面 | closed:plan-desktop-preview-acceptance | 0.1.0 | 媒体适配器根因、帧证据和资源释放；消费当前开源宿主，不接管客户端超时/取消 UI |
| C 连接 | open:plan-trusted-device-connections | 0.1.0 | 配对、目录状态、本地/辅助信令与公开契约；本地工程验证依赖身份契约，官方上线依赖 A 资格交付 |
| C 连接 | closed:plan-connection-services | 0.1.0 | 登记、转发和短期 TURN 凭据；依赖开源 C 契约；正式服务资格依赖 A，线上 TLS/relay 运维依赖 R |
| M 投屏 | open:plan-remote-screen-sharing | 0.1.0 | 选择可信对端、发送/观看、权限及对端首帧 UI；集成验收依赖 D、C 和闭源 M |
| M 投屏 | closed:plan-media-sessions | 0.1.0 | SDK 远端媒体、真实帧、候选路径及释放；先评审开源 M 契约，桌面集成依赖 D/C |
| K 分发 | open:plan-sdk-distribution | 0.1.0 | 安装、兼容诊断、公开获取文档和无私有源码构建；消费闭源 K 实际制品 |
| K 分发 | closed:plan-sdk-distribution | 0.1.0 | 二进制包装、许可、签名及能力清单；声明的每项能力须有 D/M 等对应证据，公开验证由开源 K 完成 |
| A 资格 | open:plan-client-activation | unassigned | 激活交互、本地材料及恢复；与闭源 A 先确定资格验证契约，完整离线核心功能验收再接 C/M |
| A 资格 | closed:plan-activation-service | unassigned | 邀请规则、签发/兑换、资格验证向量；先做资格基础，再支撑 C/M 集成；完整激活产品排期必须显式决定 |
| F 文件 | open:plan-network-file-transfer | unassigned | 文件公开协议、发送/接收、确认及恢复；依赖 D 的本地文件准备与 C 的可信通道，正式资格接 A；不依赖 M 视频解码 |
| U 远控 | open:plan-remote-control | unassigned | 控制请求、同意/撤回、输入协议和状态；先做桌面子集，依赖 M 的画面几何、C 身份、A 资格和闭源 U |
| U 远控 | closed:plan-remote-control-engine | unassigned | 输入执行及系统权限、授权/几何校验；与开源 U 协同；桌面验收先完成，Android 控制端组合留待 N |
| N 移动端 | open:plan-android-client | unassigned | 官方 Android 宿主和主控角色；消费已完成的 C/M/A/K，F/U 按实际能力接入；第三方被控互通组合等待 H |
| H 集成 SDK | closed:plan-android-host-sdk | unassigned | 第三方 Android 被控 SDK；依赖 C/A、输入/生命周期公开契约和原生实验；先用可用桌面控制端验收，再与 N 联测 |
| L 实验 | closed:complete-media-lab-validation | unassigned | 桌面路径子集支撑 C/M，原生 Android 子集支撑 H；全矩阵需相应设备与实验实现，不把独立实验声明为产品互通 |
| R 续期 | closed:repair-turn-certificate-renewal | unassigned | 独立维护优先项；依赖现场状态、所需权限和维护范围，支撑 C 的官方 TLS/relay 上线；不改产品版本归属 |

对方 change 的存在不代表本仓可以执行其实现任务；跨仓交付在同一工作组评审，任务勾选各自依据实际证据。

## 首轮工作包

### D1：先获得桌面事实，再修复

**Files:** 开源 `lib/features/preview/preview_controller.dart`、`lib/ui/client_app.dart`、`test/preview_controller_test.dart`、Windows/macOS 宿主；SDK 维护方处理预览适配器、平台桥接及对应单元/集成测试，具体内部路径列在闭源 D 的 design.md。公开维护者通过公共契约、SDK 安装说明和该工作组验收结果协作。根因确认后只修改实际负责层。

**Interfaces:** 当前 `PreviewEngine` 的 `sources/start/stop/dispose/view`、`onFirstFrame` 与 `onEnded` 保持兼容。SDK 提供真实帧与释放结果，客户端负责等待超时、串行取消和展示。

- [ ] 读取 open D 的 1.1/1.2 和 closed D 的 1.1/1.2；记录客户端/SDK/API 提交、系统版本、来源 ID、权限和采集→渲染→回调证据。
- [x] Windows 在专用生成窗口复现首帧失败；先依当前 SDK README 配置真实测试宿主及绝对 fixture 路径，核对测试依赖后运行 SDK 集成测试。不得套用历史私有客户端路径。
- [ ] Mac 在当前开源仓执行 `flutter build macos --debug --no-pub`，核对插件注册和录屏授权；构建失败与采集失败分别记录。
- [ ] 依据已确认根因补能复现问题的回归，再最小修复；在同一真实窗口复验首帧、来源关闭、权限撤回与停止。模拟测试通过不能代替该步骤。
- [ ] 开源维护方独立执行文件任务 2.3/2.4；其完成不作为网络传输或 SDK 媒体修复完成依据。

### C0 / A0：消除连接协议与资格排期的不确定性

**Files:** 两仓 C/A 的既有 design.md、specs 和 tasks.md；公开契约基线为开源 `packages/share_hub_media_api`，通用身份/信令应放入何种公开模块由此工作包决定。

**Interfaces:** 输入为既有可信配对、目录、信令和激活要求；输出为明确字段、错误、版本、正常/拒绝/取消/重放样例和 SDK/服务消费边界。这里尚无已批准的函数签名，不能直接进入服务编码。

- [ ] 先执行两仓 C 的 1.1/1.2：区分发现 UUID、持有密钥证明、配对信任、软件资格及会话访问；产出可检查的消息与失败样例。
- [ ] 处理两仓 A 的 1.1/1.2 所列决定，明确邀请规则、资格绑定和离线语义；产品负责人决定其版本归属。未决定时保留 unassigned 和官方上线阻塞，不默认匿名服务或生产测试根。
- [ ] 将本地、转发与 TURN 凭据的取消、代次、错误分层写回双方 C；算法、WSS/其他传输、超时值只在此评审后固定。
- [ ] 确定最小公开契约与兼容向量后，再开始 C 的 2.x。现阶段不凭目录名称创建新的私有接口替代公开契约。

### R0 / L0：准备辅助验证

- [ ] R 先执行 1.1/1.2 的现场与权限检查，再决定维护窗口；实际云操作使用闭源仓项目部署技能，不在开源计划保存实例或凭据。
- [ ] L 先执行 1.1/1.2 记录可用设备与测量工具；把桌面直连/relay 与 Android 原生实验分别分配给本轮需求，不声称全矩阵完成。

## 避免循环依赖和虚假完成

1. **A 与 C/M 分阶段集成。** A 的资格契约、签发和本地验证可以先完成；其“断公网后使用核心能力”的完整验收在 C/M 可用后完成。C/M 的工程开发可使用隔离测试向量验证认证拒绝路径，正式上线必须具有可用资格链路。不能要求 A 完整验收后才开始 C，同时又要求 C 完成后才开始 A。
2. **N、H、U 先验桌面组合。** U 先用桌面控制端验收，H 先用可用桌面控制端做原生宿主互通；N 的 Android 控制端与第三方组合随后补齐。Android 或全矩阵任务仍未完成时，整个 change 不归档。
3. **L 是实验支持。** 指定子集完成只给对应决策提供证据；M0 总状态与产品验收分别记录。不能用同机生成数据代替跨机媒体或系统级输入。
4. **R 是运维依赖。** 当前历史探针通过不能满足本轮上线关口；维护计划中的权限未就绪时保留阻塞，不以新建 timer 代替续期成功。
5. **K 按声明能力交付。** 当前源码开发适配包不是二进制 SDK；正式包的能力清单不得包含未验收的远控、Android 或媒体路径。

## 验收与提交协议

- 每个任务保留两端提交、API/SDK 版本、设备/网络拓扑、命令、预期/实际结果、失败和产物位置。不要记录完整凭据、私钥、输入内容或 SDP。
- 开源公共契约评审并提交后，闭源消费同一版本；跨仓协作先本地一起验证，先提交推送开源，再更新闭源 `open-source.lock.json` 并提交推送闭源。仅使用 main，不 force-push。
- 只在行为和对应证据满足时勾选原 tasks.md。部分平台通过保留剩余任务；所有实现/验收完成后才同步基线和归档，规划文件齐全不是实施完成。
- 每次改变需求条款同步 delta spec 的独立版本、catalog 和索引；只调整本计划顺序则递增 plan version，并同步两仓正文和每个 change 的引用。产品排期变化同时更新两仓版本计划。

| 所在目录 / 平台 | 命令或检查 | 证明范围 |
| --- | --- | --- |
| 两仓各自根目录 | `npm run spec:validate` | OpenSpec 结构、规格版本与清单 |
| 两仓各自根目录，修改校验工具时 | `npm run spec:test` | 版本校验器行为 |
| 开源根目录，已配置匹配 SDK | `flutter analyze --no-pub`、`flutter test --no-pub` | 客户端编排和契约回归 |
| 开源根目录 / Windows | `pwsh -File tool/windows_test_native.ps1`、`flutter build windows --debug --no-pub` | Windows 原生测试与构建；不等于首帧 |
| 开源根目录 / macOS | `swift test --package-path macos/Platform`、`flutter build macos --debug --no-pub` | Mac 平台测试与当前布局构建；不等于采集 |
| 闭源 SDK 包目录 | 使用仓库锁定 Flutter 执行 `flutter test --no-pub` | SDK 单元/通道模拟；实采另测 |
| 闭源根目录 | `pwsh -File tool/check_open_dependency.ps1` | 与开源提交/API 版本一致 |
| 实际两端与受控服务 | 各 change 的 3.x/4.x 真实场景 | 首帧、输入、文件完整性、直连/中继、取消与释放的实际结果 |

Windows D/2.1 高 DPI 所选窗口修复与闭源 2.3 单元回归已完成，下一入口为 **D/3.x Windows 完整生命周期和显示器矩阵**，Windows 文件准备仍按 open D/2.3→2.4 推进；Mac 仍执行 D1 现状核验，C0/A0 契约和版本决定可另行准备。后续按 S1→S4 推进，未排期项先完成排期决定。本文不指定日历工期，也不把计划同步当作开始执行这些工作包的授权。

## 历史：Windows D1 执行状态（2026-09-15）

两仓 D 的 1.1 已完成，证据见 [本仓 Windows DPI 诊断](../../validation/windows-preview-dpi.md)。已取得原生启动、轨道绑定和 DPI 对照结果；高 DPI 正式修复仍属 D/2.1。下一步在 SDK 采集层处理兼容性，再用原始宿主 DPI 通过像素与生命周期回归。Mac、文件准备及其他工作包未因此完成；本轮未变更需求条款，spec-version 和计划版本保持 0.1.0。

## Windows D2 执行状态（2026-09-16）

原始 PerMonitorV2 宿主的自建窗口真实像素验收通过，两仓 D/2.1 和闭源 D/2.3 已完成；原生 3 项、SDK 22 项和客户端 33 项测试通过，普通 Windows 入口恢复构建成功。证据与边界见 [Windows DPI 记录](../../validation/windows-preview-dpi.md)。显示器、多屏、20 次启停、权限撤回、Mac 实机和文件准备仍待推进。本轮更新实施证据，未修改需求或开发顺序，规格及计划版本仍为 0.1.0。
