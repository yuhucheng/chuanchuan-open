# chuanchuan-open 桌面预览事实记录（D1 macOS 侧）

日期：2026-09-15。环境：macOS 26.6.2（25G83）/ Apple Silicon arm64，Xcode 26.6（17F113），Apple Swift 6.3.3，Node.js 22.22.2。

**工作分支：** `release/v0.1.0`，起点为 `main` 提交 `c13e20a`。

本记录对应[两仓开发计划](../superpowers/plans/2026-09-15-cross-repository-development.md)的 D1 工作包，以及 `plan-desktop-platform-completion` 任务 1.2、2.2。只包含 macOS 侧事实；Windows 侧由另一台工作机执行，两边结果不相互替代。

## 先决环境修复

本轮先修掉两处由工作区父目录迁移（`github/` → `github/chuan/`）留下的绝对路径缺陷：

1. **SDK 符号链接已断。** `.local/media-sdk/package` 原指向 `…/github/chuanchuan/packages/share_hub_media_sdk`，缺少 `chuan/` 一层，任何 Flutter 构建都会失败。已重建指向 `chuanchuan/packages/share_hub_media_sdk`。注意 `tool/configure_media_sdk.ps1` 在本机不可用（需 PowerShell 7），且其既有链接保护逻辑会主动拒绝替换"指向别处"的链接。
2. **Swift 构建缓存含迁移前路径。** `macos/Platform/.build` 原为 236 MiB，模块缓存记录的仍是旧绝对路径，导致 `missing required module 'SwiftShims'`。执行 `swift package --package-path macos/Platform clean` 后重建，缓存未追踪且已被 `.gitignore` 覆盖。

## 已通过

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 规格结构与版本 | `npm run spec:validate` | 13 passed / 0 failed；16 份规格元数据有效 |
| 平台单元测试 | `swift test --package-path macos/Platform` | 4 项 XCTest 全部通过（0 失败） |
| 平台行为 smoke | `swiftc` 编译 `tool/PlatformSmoke.swift` + `PlatformServices.swift` | passed：偏好持久化、歧义名归一、发现记录校验、重复 stop 幂等；不启动网络与采集 |
| 真实 Bonjour 发现 | `swiftc` 编译 `tool/DiscoverySmoke.swift` + `PlatformServices.swift` | passed：同机两个生成对端完成发现、重命名、移除、重复 stop |
| 真实本地文件准备 | `swiftc` 编译 `tool/SelectedFileSmoke.swift` + `SelectedFileStore.swift` | passed：14 项检查，分块上限 262144 字节，SHA-256 `68080891…d4daec` |

后两项是真实系统资源操作（本机两个生成对端、真实生成的本地文件），不涉及用户数据、远程会话或网络传输。

## 未通过或未执行

- **`flutter build macos --debug --no-pub`（任务 1.2）未执行。** 本机没有 Flutter SDK，仅有 Xcode。Flutter 工程需要 `App.framework` 与 `flutter_assets` 才能产出可运行 bundle，纯 Xcode 无法替代。因此**插件注册与当前 bundle 读数本轮未取得**。
- **真实首帧与持续帧、权限拒绝/撤回、停止与恢复（任务 2.2、3.2）未取证。** 依赖上一项与录屏授权。
- **`flutter analyze --no-pub`、`flutter test --no-pub`（任务 3.1）未执行。** 同上。
- **系统录屏/辅助功能授权读数未取得。** TCC 数据库需"完全磁盘访问"权限，当前被系统拒绝。
- **Windows 全部任务（1.1、2.1、2.3、2.4）及 `tool/windows_test_native.ps1` 不在本机范围。**
- **`tool/test_git_policy.ps1` 未运行。** 需要 PowerShell 7；本轮 `.githooks/pre-commit` 的分支白名单改动以人工直接执行钩子验证（`release/v0.1.0` 放行、其他分支拒绝）。

## 边界说明

以上通过项只覆盖 **macOS 原生平台层与规格工件**，不构成桌面预览验收。本机布局构建、真实采集首帧、双机投屏必须分别在具备 Flutter 与录屏授权的环境另行取证。默认工程是否包含媒体引擎、以及预览能力包的交付状态，以 SDK 侧记录为准。
