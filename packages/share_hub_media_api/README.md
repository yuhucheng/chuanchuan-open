# Share Hub Media API

Apache-2.0 公共契约。客户端和媒体实现共享此包，SDK 不需要依赖客户端 UI 或平台宿主。

当前接口仅包含 `CaptureSource`、`CaptureSourceType` 和本机视频预览生命周期 `PreviewEngine`。`unavailableReason == null` 仅表示存在实现，不代表已授权、已连接或收到首帧。跨设备媒体会话、远控协议和正式二进制 ABI 尚未定义。

此包只有 Flutter 契约，不依赖媒体 SDK。正常客户端必须接入 SDK；模拟实现仅用于测试。
