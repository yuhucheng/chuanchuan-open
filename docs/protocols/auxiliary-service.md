# 官方辅助服务协议草案 v1

本协议只提供设备身份登记和短期 TURN 凭据。它不签发端到端连接、观看、投屏、远控或文件授权；桌面客户端在局域网可达时仍直接尝试本地信令。服务端实现与部署属于私有仓库，客户端不得持有 TURN 共享签发密钥。

所有请求使用 HTTPS、`Content-Type: application/json`，响应设置 `Cache-Control: no-store`。二进制字段使用公开连接包 `DeviceIdentity` 的**带标准填充的 Base64URL** 格式。`publicKey` 为 32 字节 Ed25519 公钥，`signature` 为 64 字节签名，`nonce` 为服务产生的 32 字节随机数。设备持有证明的签名原文为以下字节串拼接，不是 JSON 文本：

```text
UTF8("chuanchuan-aux-v1") || 0x00 || UTF8(purpose) || 0x00 || publicKey[32] || nonce[32]
```

`purpose` 只能是 `register` 或 `turn`。挑战绑定发起设备的公钥、用途和服务端看到的连接地址，短期有效且只可使用一次；失败的验证也消耗挑战。客户端应在用户取消或开始新请求代次时丢弃迟到响应。

| 请求 | JSON 请求体 | 成功响应 |
| --- | --- | --- |
| `POST /v1/aux/challenge` | `{"publicKey":"…","purpose":"register"}` | `{"nonce":"…","expiresAt":1800000030}`；`expiresAt` 是 Unix 秒 |
| `POST /v1/devices/register` | `{"publicKey":"…","nonce":"…","signature":"…"}` | `{"deviceId":"…"}`；ID 为公钥 SHA-256 小写十六进制 |
| `POST /v1/turn/credentials` | 同上，挑战用途为 `turn` | `{"expiresAt":"2027-01-15T08:05:00Z","iceServers":[{"urls":["turn:…"],"username":"…","credential":"…"}]}` |

登记是持有证明与服务访问资格，不建立设备间信任。服务按部署资源策略限制挑战、登记和活跃凭据；无激活码、邀请码或订阅前置。TURN 用户名/密码只用于 ICE relay，不能作为配对秘密或 grant。凭据续取不改变原 grant 类型、时长、截止时刻或方向，且不能让已停止的媒体或控制恢复。

错误体为 `{"error":"code"}`：`invalid_request` 为 400，`invalid_proof`、`not_eligible` 为 403，`capacity_limited` 为 429。TLS 失败或网络不可达由传输层报告，不伪装为普通挑战失败；本地直连不等待此请求。服务当前没有公开目录查询或跨网信令端点，客户端不能将登记响应推断为可见设备、对端在线或远端能力已交付。

公开连接包现提供 `AuxiliaryServiceClient`、`HttpsAuxiliaryTransport` 和 `AuxiliaryCancellation`：用现有 `DeviceIdentity` 签发上述持有证明，校验登记 ID 和凭据形状，取消后丢弃迟到响应；HTTPS 传输使用平台信任库，不支持 HTTP 服务地址。`AuxiliaryTurnCredential` 的字符串表示会隐藏密码，调用方仍须限制其他日志和持久化。该接口没有读取或续期端到端 grant。

产品入口现通过编译参数 `CHUANCHUAN_AUX_ORIGIN` 显式接收 HTTPS 服务 origin；未提供或无效时只走本地/直连路径，不内置公网地址。进程所有者只在主动短码握手、有效连接或认证恢复期间异步登记/获取，按凭据有效期重取，错误最多有限次短间隔重试；单纯打开“允许连接”不请求云凭据。连接需求消失即取消请求、停止续取并清除快照。SDK 新 Peer 仅同步读取已经取得且尚未过期的凭据，明确退出也会关闭传输。这个配置入口与接口接线尚未经过官方部署、资源配额和真实 relay 验收，内网自定义辅助替代方案仍待实现。
