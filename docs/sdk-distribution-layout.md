# SDK 分发格式（设计契约，尚无正式制品）

本文件供客户端接入和 SDK 维护者共同使用。当前 `share_hub_media_sdk` 仍是内部源码适配包；[样例清单](sdk-release-manifest.example.json)的版本、文件名和摘要都是格式示例，不对应可下载或可运行的发行物。公开媒体接口仍以 `packages/share_hub_media_api` 的代码为唯一来源。

## 包和取得方式

同一 SDK 发行在平台 Releases 的一个不可变发行记录中，先以草稿备齐以下附件，校验和签名验收后才公布。具体发行仓和下载地址在真实发行任务中确定。

| 附件 | 内容 | 用途 |
| --- | --- | --- |
| `share-hub-media-plugin-<sdk-version>.zip` | 可分发的薄 Flutter 插件源码、注册声明和桥接；不含私有会话/资源实现 | 与原生包组装后成为标准 `package/` |
| `share-hub-media-native-windows-x64-<sdk-version>.zip` | x64 DLL、导入库、C ABI 头、必要传递依赖及通知 | Windows x64 Flutter 或非 Flutter 宿主 |
| `share-hub-media-native-windows-arm64-<sdk-version>.zip` | ARM64 对应内容，不能用 x64 包代替 | Windows ARM64 宿主 |
| `share-hub-media-native-macos-universal-<sdk-version>.zip` | 同时含 arm64/x86_64 slice 的 XCFramework、C ABI 头、依赖及通知 | macOS Flutter 或非 Flutter 宿主 |
| `sdk-release-manifest.json` | 此发行的版本、能力、逐文件摘要和构建身份 | 取得及安装前验证 |

三个原生包独立构建和签名，可不依赖 Flutter 交给同平台原生宿主。薄插件保留 Windows `ffiPlugin` 和 macOS `pluginClass` 自动注册；其 Dart 层仅映射公开 API，不能包含私有实现。目标平台的组装目录以插件 zip 的内容为根，另放入 `sdk-release-manifest.json`，并把该平台原生 zip 的内容放在 `native/<target-id>/`，例如 `native/windows-x64/include/share_hub_media_sdk.h`。该目录由配置脚本链接到客户端既有 `.local/media-sdk/package`，根目录仍有 `pubspec.yaml` 和 `lib/share_hub_media_sdk.dart`；`windows/` 与 `macos/` 的构建钩子引用该包内原生附件。客户端保持 `path:` 直接依赖和唯一正常入口。正式组装/安装工具须在临时目录完成校验，成功后才指向新包，失败不替换原有有效包。

## 清单和兼容判定

清单 `formatVersion: 1` 使用 UTF-8 JSON。`sampleOnly: true` 只允许在文档样例中；正式清单必须是 `false`。正式清单的 `sdkVersion`、`publicMediaApi`、`nativeAbi` 分别标识 SDK、公开 Dart API 和原生 ABI，不能拿产品版本或 CPU 架构替代其中任一项。`publicMediaApi` 以明确验证过的版本列表表示源码兼容；未知版本默认不兼容。ABI 主版本必须匹配，消费者所需次版本不得大于实际次版本。能力按每个目标架构独立声明，未验收能力为 `false`，不以协议或 UI 支持推定。

每个目标必须记录系统、架构、最低 OS、运行库、构建身份、插件和原生附件名，以及独立验证过的来源、方向会话、后台、单画面、输入、纯文本和并发上限。最低 OS 和运行库以目标架构实测结果填写，未知值不得进入正式清单。Windows x64/ARM64 分开列出；macOS universal 还必须列明两个 slice。`files` 覆盖所有可执行文件、导入库、头文件、桥接文件、传递依赖及许可通知，路径相对附件根目录，摘要为最终签名、公证和包装完成后字节的 64 位小写 SHA-256；附件自身的 `sha256` 也取最终字节。清单不存放密钥或私有源码路径。解压时只接受规范化的相对路径，拒绝绝对路径、`..`、重复路径及逃出包根目录的链接。

安装器先从可信发行记录取得清单和附件，再验证来源/适用平台签名及所有摘要，之后检查布局、公开 API 和 ABI 兼容、运行库与平台能力；清单校验通过不代替签名信任或实际加载。缺包、布局错误、校验失败、平台不支持、API 不兼容和 ABI 不兼容分别报错。清单本身需随发行记录提供可信来源或独立签名；不能仅用清单中自报的摘要验证它自己。旧版保留用于失败恢复；不可变记录修复须使用新版本/候选标识。

当前 `tool/configure_media_sdk.ps1` 接收已组装目录及**独立取得**的 `-ExpectedManifestSha256`，先核对清单自身，再核对当前平台的清单字段与每个解压文件；它不下载、不验平台签名、不替代最终加载测试。内部适配包须显式传 `-DevelopmentAdapter`，正式包不得使用该参数。`-ExpectedManifestSha256` 若仅从待验包内抄出，不能证明发布来源可信。

正式制品、签名信任、无私有源码构建和非 Flutter 调用尚未完成；本格式只确定消费边界，不宣称当前可安装。
