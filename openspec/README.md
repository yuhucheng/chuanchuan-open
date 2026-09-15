# 串串开源规格索引

全部未归档 change 的开发顺序、跨仓依赖与联合验收见[两仓开发计划 v0.1.0](../docs/superpowers/plans/2026-09-15-cross-repository-development.md)。当前下一开发入口为桌面事实与根因收敛，连接契约和资格决定可并行准备。

本目录使用 **Fission-AI OpenSpec 1.13.0**。当前产品基线 **v0.1.0**，每份初始规格版本 **0.1.0**；公共媒体 API 版本独立维护。机器清单见 [catalog.json](catalog.json)，命令、版本与归档规则见 [OpenSpec 管理](../docs/development/openspec.md)。

`specs/` 是当前能力和约束的基线，`changes/` 是尚未完成的设计。每份规格列出实现状态、来源和验证边界；本次不实施这些待办功能。

## 当前能力基线

| Spec | 规格版本 | 当前边界 |
| --- | --- | --- |
| [required-sdk-client](specs/required-sdk-client/spec.md) | 0.1.0 | 唯一客户端和平台宿主、必需 SDK；没有无 SDK 产品模式 |
| [public-media-api](specs/public-media-api/spec.md) | 0.1.0 | 公共 PreviewEngine 契约；远端媒体/远控接口尚未定义 |
| [local-device-discovery](specs/local-device-discovery/spec.md) | 0.1.0 | 本机资料及手动 DNS-SD/Bonjour；发现不代表身份或可信连接 |
| [local-preview-lifecycle](specs/local-preview-lifecycle/spec.md) | 0.1.0 | 本地预览控制、权限、首帧和停止；实机首帧/新插件布局有验收缺口 |
| [local-file-preparation](specs/local-file-preparation/spec.md) | 0.1.0 | macOS 本地文件准备；Windows 原生选择和网络传输未完成 |

## 待办设计

各变更内的独立规格初始版本均为 **0.1.0**。任务全部保留为待办，目标版本不代表交付保证。

| Change | 独立规格 | 产品目标 |
| --- | --- | --- |
| [plan-trusted-device-connections](changes/plan-trusted-device-connections/proposal.md) | trusted-pairing、device-directory、connection-signaling | v0.1.0 |
| [plan-remote-screen-sharing](changes/plan-remote-screen-sharing/proposal.md) | remote-screen-sharing | v0.1.0 |
| [plan-sdk-distribution](changes/plan-sdk-distribution/proposal.md) | sdk-consumption | v0.1.0 |
| [plan-desktop-platform-completion](changes/plan-desktop-platform-completion/proposal.md) | desktop-preview-acceptance、windows-file-preparation | v0.1.0 |
| [plan-network-file-transfer](changes/plan-network-file-transfer/proposal.md) | network-file-transfer | 未排期 |
| [plan-client-activation](changes/plan-client-activation/proposal.md) | client-activation | 未排期 |
| [plan-remote-control](changes/plan-remote-control/proposal.md) | remote-control-client | 未排期 |
| [plan-android-client](changes/plan-android-client/proposal.md) | android-client | 未排期 |

## 契约归属与 SDK 协作

公开媒体 API 的规范来源为本仓 [public-media-api](specs/public-media-api/spec.md)，实现定义为 [share_hub_media_api](../packages/share_hub_media_api/lib/share_hub_media_api.dart)。SDK 消费这一小型公共契约，不依赖客户端 UI。将来的远端会话、控制和平台能力契约要通过对应 change 明确定义，不能把当前 PreviewEngine 当作已有完整媒体接口。

| 开源负责 | SDK / 服务配套职责 |
| --- | --- |
| 页面、权限交互、发现、配对与通用连接协议 | SDK 执行媒体采集/处理；官方服务提供登记、信令转发与辅助凭据 |
| 远端投屏的用户行为与公开会话契约 | 媒体会话、实际选中路径、首帧及资源生命周期实现 |
| SDK 安装布局、契约版本与兼容错误 | SDK 可分发制品、二进制封装、签名和正式许可 |
| 本地文件访问、网络文件协议、队列和校验 | 文件模块继续在开源仓维护 |
| 激活交互与验证契约 | 官方邀请与凭证签发；客户端不包含签发私钥 |
| 远控用户授权、Android 主控与公开适配契约 | 输入执行引擎和第三方 Android 被控 SDK |

本仓规格能独立阅读，不要求贡献者访问私有仓库。SDK 免费提供给贡献者的方向已经确定；当前仍需获得开发适配包，不能虚构正式二进制下载地址。

## 来源与历史记录

| 公开来源 | 对应规格 | 处理方式 |
| --- | --- | --- |
| [README](../README.md)、[AGENTS](../AGENTS.md)、[版本计划](../docs/version-plan.md) | 全部基线与版本归属 | 最新架构和排期优先；不自行新增产品版本 |
| [主线验证](../docs/validation/main-integration.md) | SDK 客户端、预览、公共 API | Windows 构建/自动测试与 Mac 新插件布局实机验收分开 |
| [必需 SDK 构建](../docs/validation/required-sdk-client.md) | required-sdk-client、sdk-consumption | 旧无 SDK 入口已被取代 |
| [历史 Mac 基础](../docs/validation/macos-foundation.md) | 发现、文件准备及预览历史背景 | 旧宿主证据不能充当新 SDK 布局通过 |
| [拆分记录](../docs/validation/project-split.md)、[客户端/SDK 调整](../docs/validation/client-sdk-direction.md) | 仓库和契约边界 | 保留历史，旧无 SDK/私有宿主方案不进入现有基线 |
| [公开来源说明](../docs/source-origin.md) | 已有模块的来源关系 | 保留源码来源和上游许可 |

待办 change 中公开转述已经确认的产品目标，并注明哪些机制仍是待定方案。邀请码额度、账号/设备关系、最低系统版本、多屏/音频、一对多与无人值守等不因本次迁移变成已批准实现。完整未来版本和验收排期仍由版本计划决定。
