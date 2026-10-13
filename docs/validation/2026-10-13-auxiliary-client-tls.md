# 辅助入口正常客户端 TLS 复核 — 2026-10-13

新增只读 `packages/share_hub_connection/tool/auxiliary_health_probe.dart`，使用正常辅助 transport 相同的默认 HttpClient 证书验证；读取有界 `/health`，不登记身份、输码、申请TURN或发送媒体，首配与中继结果始终false。用于真实双机前的部署检查，不改变产品、协议、grant或辅助来源选择规则。

## 当前外网观察

- Python系统信任TLS连接8443和5349成功，8443 `/health` 返回200/ok。
- 同一Mac的Dart3.13.2默认HttpClient及SecureSocket两种ALPN设置，在握手阶段被重置（SocketException/errno54）；系统curl也被重置。正式预检正确返回非零，tlsValidated/healthVerified均false。
- 同域名同地址的Python强制TLS1.2被重置，强制TLS1.3返回健康成功。这是版本限定下的观察，不足以断言服务配置或网络设备是根因。
- Dart对官方dart.dev的HTTPS连接证书验证成功，`/health` 404正确不被当成健康成功；不能据此把问题归为Dart完全不能访问HTTPS。
- 本地独立TLS1.2/1.3服务，测试driver只信任指定localhost端口上自己的精确临时leaf，两版本健康路径通过；4097字节、非JSON与503负例被拒绝且不回显正文。这证明该Dart运行时可协商两协议，不是生产PKI验证。本地仅加载CA的探索夹具曾证书验证失败，不用该失败推断协议支持。生产CLI不提供证书跳过或测试leaf覆写选项。
- 5组不安全origin（HTTP、userinfo、额外path、query、fragment）均exit64且未回显值；Dart静态分析通过。未改运行中的服务、客户端产品入口或SDK，未启动应用/采集。

## 下一步证据

Windows在同步脚本后复验同一endpoint；ECS部署负责人按同期服务/握手日志核对实际TLS链路、版本/套件策略及中间层。当前客户端仍未通过，所以健康200不能填为正常首配可用；真实未配对异网双机、取消/错误码/身份与原截止、实际信令和媒体路径继续待验收。
