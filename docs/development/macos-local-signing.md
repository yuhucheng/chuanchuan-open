# macOS 本机开发签名

Debug 默认可使用 ad-hoc 签名构建，但它的代码身份可能随重建改变，使 macOS 不再沿用旧的录屏授权。反复调试建议复用同一个开发签名证书，并保持 bundle ID 和应用路径稳定。

可使用自己的 Apple Development 证书，或仅供本机开发的固定自签代码签名证书。自签证书不是 Apple Developer ID，不提供发行、公证或其他用户电脑上的信任。正式发行签名仍是独立待办。

## 配置 Debug

先将自己的代码签名证书及匹配私钥安装到本机钥匙串。使用自签证书时，仅对代码签名用途配置信任，不将其设为 TLS 等用途的通用信任根。不要下载或共用公开的签名私钥。

```sh
security find-identity -v -p codesigning
```

在源码仓创建已被忽略的 `.local/macos-signing.xcconfig`，填入上述命令显示的证书 SHA-1 指纹：

```text
CHUAN_DEBUG_SIGNING_IDENTITY = YOUR_40_HEX_CERTIFICATE_FINGERPRINT
```

运行锁定版本 Flutter：

```sh
flutter build macos --debug --no-pub
codesign --verify --deep --strict 'build/macos/Build/Products/Debug/Share Hub.app'
codesign -d -r- 'build/macos/Build/Products/Debug/Share Hub.app'
```

证书签名的 designated requirement 应基于证书和应用标识，而不只是该次构建的 `cdhash`。重建前后可对照 requirement；实际授权能否保留还需使用同一构建路径完成系统录屏授权和重建复验。

配置只影响 Runner 的 Debug 构建。没有本机配置时仍可按原方式构建；Release/Profile 不使用此本机证书配置。证书选择失效时应修复钥匙串或本机配置，不通过关闭权限检查或系统安全保护继续。

从 ad-hoc 切换为固定证书属于一次身份变更，旧授权可能需要重新登记。证书过期、替换或丢失私钥也可能要求重新授权；不要在每次构建时重新生成证书。

私钥仅保存在钥匙串；不提交到仓库、共享目录、日志或安装包。本机配置也不应要求其他贡献者使用同一张私人证书。

参考：[Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/)、[Apple 对 ad-hoc 录屏授权问题的说明](https://developer.apple.com/forums/thread/819406)。
