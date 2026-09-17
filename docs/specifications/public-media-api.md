<!-- Generated from the approved public baseline. Do not edit this snapshot directly. -->

# 公共媒体 API

## Purpose

记录 v0.1.0 开发基线中的公共媒体 API，初始规格版本 0.1.0 独立于产品版本和公共 API 版本。已实现控制逻辑与真实平台验收分别记录；本规格不表示稳定版已发布。

## Requirements

### Requirement: 可扩展的授权类型与期限

grant MUST 显式包含可扩展的类型及有效时长字段，二者绑定双方身份并参与认证。当前短码配置 SHALL 为 short-code / 8 小时；不得将 8 小时硬编码为授权契约唯一形态。新增类型的产品准入与策略须独立交付，不能由对端任意字段启用。恢复仍使用原类型、原期限和原截止时刻，不能续期。

#### Scenario: 类型或时长不匹配

- **WHEN** 双方提交的 grant 类型或时长不同
- **THEN** 持有证明失败，不接受该恢复或发放操作授权。


### Requirement: 独立契约包

公共包 `share_hub_media_api` MUST 独立提供 Flutter 媒体契约，不依赖 SDK 实现或客户端 UI。当前包 API 版本为 0.2.0，规格版本独立维护。

#### Scenario: 实现引擎

- **WHEN** SDK 实现当前预览契约
- **THEN** 只需依赖公共契约，不导入客户端包或平台宿主源码。

### Requirement: 来源描述

公共 API MUST 用 `CaptureSource` 描述来源 id、名称和 `CaptureSourceType`，现有类型为 screen 和 window。

#### Scenario: 选择窗口

- **WHEN** 客户端收到窗口类型来源
- **THEN** 保留该来源 id 和 window 类型交给引擎，不把它隐式改为默认屏幕。

### Requirement: 预览生命周期

`PreviewEngine` MUST 暴露 `sources()`、`start(source, onEnded, onFirstFrame)`、`stop()`、`dispose()` 和 `view`；采集结束与首次画面到达 SHALL 通过不同回调表达。

#### Scenario: 启动尚无首帧

- **WHEN** start 完成但 onFirstFrame 尚未触发
- **THEN** 客户端不能据此宣称收到真实画面。

#### Scenario: 结束回调

- **WHEN** 系统结束当前来源采集
- **THEN** 客户端接收 onEnded 并进入停止和释放流程。

### Requirement: 实现可用性含义

`unavailableReason` 为 null MUST 只表示构建存在对应实现，不授予权限，不证明远端连接、首帧或控制可用。新增远端能力 SHALL 经版本和运行时能力显式协商；当前 0.1.0 预览 API 不得被描述为已交付远端协议或二进制 ABI。

#### Scenario: 存在实现但没有授权

- **WHEN** 实现可用但录屏权限未获允许
- **THEN** 仍检查权限，不直接采集或显示授权成功。

#### Scenario: 旧 SDK 不支持远端

- **WHEN** 协商结果只有本地预览
- **THEN** 保留兼容的本地预览，远端能力明确不可用，不伪造成功。

### Requirement: 方向化会话契约与并发能力

公开契约 MUST 分别表达连接授权标识、双方身份、方向、原截止时间、传输代次、画面会话标识、来源/几何及真实事件；SDK 只消费可验证材料，不能从 UI 已连接布尔值推导全权。首版 SHALL 声明单画面并发上限，接口允许未来多会话和一对多投屏扩展。

#### Scenario: 第二路画面

- **WHEN** 客户端已有观看、投屏或带画面的远控，另一请求占用同一预算
- **THEN** 明确返回忙碌，不静默抢占；复用同一会话缩略图不重复占用。

#### Scenario: 反向操作

- **WHEN** A 验证 B 短码后 B 尝试观看或控制 A
- **THEN** 没有反向授权时执行侧拒绝；A 主动投屏给 B 不产生 B 控制 A 的权限。

## Delivery

2026-09-17：公共媒体 API 0.2.0 已增加方向授权、认证恢复、版本/能力协商、会话/来源/几何/真实事件及并发预算契约，保持 PreviewEngine 源码兼容；会话公共包为 0.1.0，协议版本为 2。当前 SDK 仍只实现本地预览，远端执行与客户端后台恢复尚待接入，以公开源码为唯一接口定义。

## 文档版本

规格版本：0.3.0。这是当前行为与约束说明，具体实现和平台验收状态见[验证摘要](../validation.md)。公开接口源码见[媒体 API](../../packages/share_hub_media_api/README.md)。
