# SDK 发布索引只读预检

`tool/sdk_release_index.py` 接收来自所选发行渠道、被调用方独立固定的索引 SHA-256，以及本地六个 ZIP 附件所在目录：

```sh
python3 tool/sdk_release_index.py /path/to/release-index.json \
  --expected-index-sha256 <渠道独立提供的索引摘要> \
  --archives-directory /path/to/attachments
```

索引必须声明同一稳定 SDK 版本下的 Windows x64、Windows ARM64、macOS arm64/x86_64，且每个目标都有原生包与薄 Flutter 包。工具核对六个文件名、大小、ZIP/清单摘要、包内身份和目标，以及薄插件包对对应原生清单的引用；每个 ZIP 仍由现有归档预检逐文件核对。缺失、重复、改写或跨目标混用均失败。仓内的六目标样例带 `exampleOnly=true`、摘要为空，会被拒绝。

成功结果始终为 `installable: false`。此工具不认证索引的发布者，不检查薄插件包内的原生文件是否与独立原生包逐字相同，也不验证真实 ABI、架构、运行库、签名、公证、许可或功能。后续仍须运行组合、兼容、签名与实际运行验收；不能将只读预检结果当作 0.1.0 SDK 发布资格。
