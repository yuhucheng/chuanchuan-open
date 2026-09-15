# plan-android-client 任务清单

以下均为尚未执行的未来任务。本次既有设计迁移只整理文档，不表示已授权产品开发；规格版本 0.1.0，产品基线 0.1.0，release-target unassigned。先完成设计门槛，再依据新的实施授权进入 apply；不得自行建分支/worktree或推定未排期能力的发布版本。

## 1. 移动平台门槛

- [ ] 1.1 确定 Android 目标版本、最低系统/设备矩阵、后台与存储交互及第三方互通范围；更新版本计划和 design.md，以明确决策及 `npm run spec:validate` 为完成证据。
- [ ] 1.2 核对连接、投屏、文件、激活和控制端依赖能力的可用版本，与 SDK 维护方形成 Android 包和公共契约兼容清单；未交付能力保留不可用状态。

## 2. 宿主和能力接入

- [ ] 2.1 在本仓添加 Android 宿主并接入必需 SDK 标准入口；运行 `flutter pub get` 和 `flutter build apk --debug --no-pub`，验证缺失/不兼容 SDK 不产生无 SDK 产品模式。
- [ ] 2.2 实现平台许可和生命周期适配，核对所支持 Android 版本的官方平台要求；用真实设备验证拒绝/撤回、前后台及系统结束的状态和资源释放。
- [ ] 2.3 按已实现依赖接入官方发送/观看、文件及控制电脑操作；增加实际能力与 UI 一致性测试并运行 `flutter test --no-pub`，确认不提供官方 Android 被控。

## 3. Android 实机验收

- [ ] 3.1 运行 `flutter analyze --no-pub`、`flutter test --no-pub` 与 Android Debug 构建，按设备矩阵逐项记录授权、真实远端帧、文件完整性和控制端表现。
- [ ] 3.2 对已批准互通范围的第三方被控设备验证身份、实际能力及输入权限失效；没有对应设备或 SDK 的项目保留待验收，不以桌面结果补齐。

## Cross-repository Development Plan

- 按 [两仓开发计划 v0.1.0](../../../docs/superpowers/plans/2026-09-15-cross-repository-development.md) 的 **N / 桌面能力稳定后，未排期** 推进；先执行 1.1/1.2 的矩阵与兼容清单；2.x 接入实际能力，3.1 先验官方端，3.2 待 H 条件具备。
- 前置条件：先指定 release-target；消费 C/M/A/K 的可用契约与包，F/U 按能力接入；第三方组合才依赖 H。
- 协作对象：closed:plan-android-host-sdk（第三方互通组合，不是官方宿主实现）；联合验收要求：真实 Android 上验证已有发送/观看/文件/控制能力；官方 Android 不变为被控，缺失能力和第三方未测项不宣称完成。
- 原任务编号保持不变，每项按本仓证据单独勾选；只完成子集时其余任务保持未完成，不能归档整个 change。
