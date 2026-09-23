# 短接码本地连接 v1（开发中）

本文上半部保留 v1 实施时的协议及能力快照；当前客户端使用文末的 v2 集成，不能把历史「断线终止/仅保活」描述套用于已协商恢复的 v2 连接。适用客户端 0.1.0-dev.1。公开实现为 `packages/share_hub_connection`，不依赖 UI 或媒体 SDK。当前支持 macOS 客户端接入及通用 Dart 协议；Windows 安全存储/入口、远端媒体、官方/内网辅助服务、双机验收未完成。该实现未经独立密码协议审计，不作为正式发行安全认证。

## 使用

两台 Mac 使用此开发版：目标端在设备页点击“开启接入”，获得 6 位纯数字短接码；双方开启局域网发现后，发起端选择目标并输入短码。也可在“输入地址和短接码”中填写目标端显示的地址和端口。无需互联网或目标端第二次点击确认。发现记录只是未经认证的连接线索。

短码 5 分钟内有效，成功一次即消费；每码最多 5 次握手尝试，失败、取消和未提交证明也计次。耗尽或过期需用户主动重新生成。重新生成/关闭接入停止该码的未完成握手；已建立连接独立存在，使用“断开并撤销”终止。退出应用清除所有连接授权。短码不写入发现记录、日志或持久存储。

目标端在安全握手完成、收到加密 ready 后，原子消费短码并建立连接授权；从此刻起有效 28800 秒。目标端的连续时钟是授权期限依据。发起端用发送 ready 时刻设定保守的本地截止保护，可能比目标端稍早断开，不会因最后一次网络往返推迟到期。此保护不是从显示短码或开始握手计时。断线会结束本次连接；重试不复活旧授权，重新连接须取得新短码。没有永久信任或自动续期接口。

会话当前仅允许加密保活，能力集合为空；连接成功不开放观看、录屏、输入或文件功能。未识别的操作会终止连接，媒体 SDK 仍使用原公共媒体 API，不消费本包的对象作为媒体授权。未来媒体绑定契约需要独立兼容验证。

## 身份和密码协议

- 32 字节随机种子生成 Ed25519 身份；设备标识为公钥的 SHA-256。macOS 使用本应用 Keychain generic-password 条目，`WhenUnlockedThisDeviceOnly`；读取失败即拒绝接入，不使用发现 UUID 或应用签名证书代替。会话不跨进程恢复。
- PointyCastle 4.0.0 SRP6a、固定 RFC 5054 3072-bit group / SHA-256；不接受网络指定的群。每次握手使用新 salt、双方 nonce 和 SRP 私有随机数。短码从 `Random.secure()` 等概率生成，保留前导零。
- SRP identity 编码为 UTF-8 JSON 数组 `[1, offerId, hostPublicKey, clientPublicKey, clientNonce, hostNonce]`。offerId 16 字节，其余 nonce/salt 32 字节，公钥 32 字节；所有二进制为规范 padded base64url。
- 握手 transcript 是上述数组后追加 `[salt, B, A]` 的 UTF-8 JSON。SRP A/B 固定 384 字节且 `0 < value < N`；M1/M2 和派生 session key 固定 32 字节。客户端 M1+Ed25519 签名和目标端 M2+Ed25519 签名共同验证密码及双端公钥持有。签名 64 字节。代码中未重写 SRP/Ed25519 数学运算。
- `SHA256(transcript)` 是 session ID 和 HKDF salt；HKDF-SHA256 从 SRP key 分别派生 `chuanchuan.connection.v1/client-to-host` 和 `.../host-to-client` 两个 256-bit key。AES-GCM-256、16 字节 tag，nonce 为 4 个零字节加 8 字节大端方向序号；AAD 为 `[1, sessionId, sequence]` 的 UTF-8 JSON。方向序号从 0 起严格递增，拒绝重放、跳号及 >= 2^32 消息。不同会话不复用密钥。

## 消息和生命周期

TCP 消息为 4 字节大端长度前缀及 UTF-8 JSON 对象，最大 8192 字节；输入累计上限 65536 字节，待处理消息上限 8。并发未完成握手最多 4，单次最多 30 秒，连接地址阶段最多 5 秒；客户端最多保留 8 个连接。每秒加密 heartbeat，连续 10 秒未收到有效消息结束连接。工程限值不是网络时延承诺。

顺序：`hello(v,key,nonce)` → `challenge(v,context,salt,b)` → `proof(v,a,m1,signature)` → `verified(v,m2,signature)` → 加密 `ready` → 加密 `connected(lifetimeSeconds=28800)` → 加密 `heartbeat`。只有上述步骤成功，UI 才展示已验证连接。所有明文消息 v 必须为 1；未知版本失败关闭，不匿名降级。

取消关闭所拥有的 socket，检查尝试代次及 offer 对象；晚到 socket/身份读取/证明不能发布连接。成功消费与代次检查间没有异步让出点，两个并发正确证明最多一个成功。刷新短码不延长任何已有连接授权。

macOS 使用 `mach_continuous_time`（包含休眠），不使用可调整的墙上时间。到期定时器、保活以及每条入站消息均检查授权，时钟回退/读取失败即终止；撤销关闭 socket、停止定时器并完成 `whenClosed`。UI 保持授权与能力的区别。以后新增依赖资源必须绑定同一关闭通知及期限，不能自行另起八小时。

## 验证

```sh
cd packages/share_hub_connection
dart pub get --enforce-lockfile
dart analyze
dart test
```

协议测试使用两个独立身份和真实 loopback TCP，覆盖错误/过期/消费/限次、并发、取消、身份签名伪造、消息篡改/重放、报文边界及撤销。八小时测试推进注入时钟，没有宣称连续实跑八小时或真实休眠验收。应用层另有取消后身份晚到测试。两台物理设备、断公网、Bonjour 互通、系统休眠和 Windows 实机须分别验收。

## v2 客户端接入（2026-09-17）

客户端显式使用协议版本 2，不向旧 v1 对端静默降级。配对协议包保留 v1 测试入口；上文 v1 帧格式仅描述该兼容模式。v2 在同一 PAKE/身份绑定基础上生成方向授权，字段及信任边界见 [Session API](../../packages/share_hub_session_api/README.md)。v2 已接入有界的认证操作请求与双向信令路由，并由公共媒体 API 连接远端媒体编排。当前客户端双方显式协商恢复后，短暂断线可在原授权截止内沿原路线有界恢复；类型/时长继续使用可扩展 grant 策略，当前仍为八小时。短码刷新保留监听端口，主动断开/关开关/退出/身份变化/到期拒绝恢复。协议、重试和取消清理边界见[连接包契约](../../packages/share_hub_connection/README.md)。连接恢复不代表媒体自动恢复、首帧或双设备验收已完成。

`ConnectionController` 在成功握手后将真实 grant 注册到进程内 `GrantRegistry`，SDK 使用该注册表核验收到的 permit；不根据 UI 布尔值或发现名称签发授权。关闭开关和退出先同步 `revokeAll()`，再等待套接字清理；单连接结束删除对应注册。重新开启生成新码及新上下文。客户端契约样例见 `test/connection_controller_test.dart`，覆盖两端身份、对端注册表隔离、关闭前同步撤销及关闭后主动出站；SDK 消费样例在 SDK 包的 `test/session_contract_test.dart`。这些测试不替代双机、Windows 或后台验收。
