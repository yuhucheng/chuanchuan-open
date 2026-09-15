# plan-desktop-platform-completion 设计摘要

## Context

当前主线在 Windows 完成静态检查、Flutter 测试和 Debug 构建。Windows 真实首帧仍失败；macOS 新 SDK 插件尚未原生构建；Windows FileAccess 未实现。动机见 proposal.md。

本文件是既有设计迁移，lifecycle/delivery 均为 planned，能力尚未实现；此次只整理规格，不表示已授权实施，也不恢复已停止的产品开发。规格版本 0.1.0、产品基线 0.1.0、release-target 0.1.0。具体实现需另行进入 apply，并先解决下文的设计门槛。

### 已确认的公开产品约束

客户端及所有平台宿主属于本仓，媒体实现属于 SDK；真实平台能力必须以实际产物验证，测试模拟画面不能当作投屏证据。

## Goals / Non-Goals

按当前实际 SDK 布局补齐两端预览验收和 Windows 本地文件访问。非目标：不进行网络文件发送、远控、稳定发行或重新引入第二客户端工程。

## Decisions

以下划分保留用户已确定的边界；标为候选的内容仍是未实现的技术建议，不提升为已确认产品需求。

1. Windows 首帧修复先定位来源选择、采集、渲染和首帧报告的实际证据，不在无证据时指定根因。使用受控真实窗口检查来源内容，现有 fake 保留作生命周期回归。

2. macOS 从当前公开宿主构建并加载 SDK 插件，分别检查注册、权限、真实来源与资源释放。旧无 SDK 产物只保留历史参考，不覆盖新布局。

3. Windows 文件适配复用 FileAccess 令牌接口与 TransferQueue，不修改准备状态的语义。原生选择器授权普通文件并有界读取；任意路径输入无法表达用户选择授权，因此不采用。

4. 候选验证矩阵包含取消、文件变化、来源失效与退出释放；Windows/macOS 原生结果分别记版本，不用另一平台测试补齐缺失证据。

## Risks / Trade-offs

- 构建成功掩盖黑屏 → 来源可辨识内容与首帧单列验收。
- 文件句柄或采集资源泄漏 → 重复启动/停止、选择/移除和退出后检查。
- 一次功能补齐扩大到网络收发 → 保持本地 ready 状态，网络传送独立未排期。

## Migration Plan

实现授权后分别复现 Windows 首帧问题和编译 macOS 当前布局，记录版本与失败点，再修复 SDK/宿主集成。Windows 文件访问单独接入公开方法契约。每个平台通过后更新本仓验证记录；未通过的平台继续显示待验收。

## Decisions Required Before Implementation

最低操作系统版本、正式签名与发行矩阵仍须确定。首帧失败根因依赖现场证据，不能从旧测试推断；这一步作为具体诊断任务保留。

当前计划文件已整理齐全，但这些门槛解决前不应声称具备可直接执行的最终接口设计。任何新增产品范围先更新版本计划，具体任务见 tasks.md，全部保持未完成。

## Sources

- [现有能力与构建边界](../../../README.md)
- [版本计划](../../../docs/version-plan.md)
- `docs/validation/main-integration.md`（仓库根目录相对路径）
- `docs/validation/required-sdk-client.md`（仓库根目录相对路径）
- `test/preview_controller_test.dart`（仓库根目录相对路径）
- `lib/features/transfers/file_access.dart`（仓库根目录相对路径）
- `macos/Platform/Sources/ShareHubPlatform/SelectedFileStore.swift`（仓库根目录相对路径）
- 用户已确认的公开产品约束，已在本文件摘录；候选实现建议单独标明。本摘要不依赖任何非公开源码、部署环境或凭据。
