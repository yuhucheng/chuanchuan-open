# 普通客户端官方辅助入口默认值（2026-09-29）

普通 `lib/main.dart` 产品入口现以 `https://chuanchuan.xyz:8443` 作为官方辅助服务 origin；`CHUANCHUAN_AUX_ORIGIN` 仍可在构建时覆盖，显式空值关闭官方路径。自定义内网选择保留独立偏好，若已选定有效自定义地址仍可使用，不在失败时回退官方。客户端仅在需要连接辅助链路时请求服务；本地连接不等待官方地址。

`flutter analyze --no-pub lib/main.dart` 无问题；未传 `--dart-define` 的 `flutter build macos --debug --no-pub` 成功，普通产品应用的 `App.framework` Dart kernel 包含上述默认地址。此次只验证默认值进入普通构建，未启动真实采集，也未证明 8443 线上可达、服务部署、正式发行配置或陌生设备异网六码连接。上线前仍须核对该 origin 的 TLS、服务和两台设备实际路径。
