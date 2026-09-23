# 字标轮廓与来源

`lockup-horizontal.svg`、`lockup-vertical.svg` 是既有组合字标的轮廓版本。
保留原画布、标志几何、颜色、字号、字距、位置和文字内容；没有替换或重画标志。
`wordmark-cn.svg`、`wordmark-latin.svg` 从横版提取，画布为真实字形边界外加 2 单位留白。
四份交付 SVG 只有路径和几何，没有 `<text>`、外部资源或字体依赖。

客户端可用 `lib/ui/field/brand_wordmark_paths.dart` 的中文轮廓。
`createBrandWordmarkPath()` 返回新 Path；左上角归零，真实边界为
`brandWordmarkBounds`，尺寸为 `brandWordmarkSize`（171.28 × 87.4）。
调用者等比缩放、使用主题对应的单色并在外层提供“串串”语义；无需运行时字体或 SVG 解析库。
应用构建不需要 Python、网络、字体安装或管理仓。

## 已固定的字体

| 使用处 | 官方字体 | 固定来源 |
| --- | --- | --- |
| 中文“串串” | Source Han Sans CN Heavy，900，2.005 | [Adobe 2.005R](https://github.com/adobe-fonts/source-han-sans/tree/2.005R/SubsetOTF/CN)，commit `6c709ca72d3d7c46ab42ebecc1a26e7d69595a37` |
| 竖版标语 | Source Han Sans CN Regular，400，2.005 | 同一 Adobe 发布的 CN Subset OTF |
| `chuanchuan` | Inter Tight 3.004，可变字体 `wght=500` | [Google Fonts](https://github.com/google/fonts/tree/0b58fb370093f9a9f4ff785d94405710b79de67c/ofl/intertight)，commit `0b58fb370093f9a9f4ff785d94405710b79de67c` |

Google Fonts 的 [METADATA.pb](https://github.com/google/fonts/blob/0b58fb370093f9a9f4ff785d94405710b79de67c/ofl/intertight/METADATA.pb)
记录 Inter Tight 的源版本 commit `c194f94c60b569b47876811321f5ef1f0c2614a2`。
字体文件的 name 表实际读取为 `Version 2.005;addfeatures 5.0.0b21` 和 `Version 3.004`。
字体二进制的完整 SHA-256、不可变下载链接、许可哈希、原 SVG 哈希和生成文件哈希见
[wordmark-manifest.json](wordmark-manifest.json)。没有使用系统回退字体，也没有将完整字体打包进客户端。

## 许可

两套字体均采用 SIL Open Font License 1.1。完整原始版权和许可文本保留在
[SourceHanSans-OFL-1.1.txt](../../LICENSES/SourceHanSans-OFL-1.1.txt) 和
[InterTight-OFL-1.1.txt](../../LICENSES/InterTight-OFL-1.1.txt)，与固定官方提交逐字节一致。
Source Han 的保留字体名称为 `Source`；这里不分发改名字体或可安装字体。
字体许可来源不表示字体作者为本产品背书。

[OFL 官方 FAQ 1.1–1.1.2](https://openfontlicense.org/ofl-faq/)
允许使用字体制作标志和轮廓图形；图形本身不因此成为 OFL 字体软件。
此处仍保留完整许可和来源，便于审计。品牌图形继续沿用本仓现有资产许可与品牌使用边界。

## 重现与校验

维护者使用 Python 3.10+，创建独立环境并安装锁定依赖；以下命令从产品仓根执行：

```sh
python3 -m venv /tmp/chuanchuan-wordmark-env
/tmp/chuanchuan-wordmark-env/bin/python -m pip install -r tool/generate_wordmark_requirements.txt
/tmp/chuanchuan-wordmark-env/bin/python tool/generate_wordmark.py --font-dir /tmp/chuanchuan-wordmark-fonts --download
/tmp/chuanchuan-wordmark-env/bin/python tool/generate_wordmark.py --font-dir /tmp/chuanchuan-wordmark-fonts --check
```

`--download` 是显式的维护操作，仅下载三份固定字体到指定缓存目录；已存在文件先校验 SHA-256，错误文件不会被默默接受或替换。
准备好字体缓存后，生成和 `--check` 完全离线。普通构建直接使用已提交轮廓。
HarfBuzz 负责字形定位，fontTools 读取准确字重的轮廓；保留 kerning，关闭可选连字，按原 SVG 的字距与文本锚点布局。
工具检查字形缺失、原画布裁切、字体和许可哈希、生成工具版本，以及生成物逐字节漂移。
原始可编辑 SVG 存在 `tool/generate_wordmark_sources/`，只用于维护，不作为产品运行资源。

2026-09-22 验证：原横版文字绘制边界最右为 360.486328，画布宽 384；
原竖版文字绘制边界为 x 40.970703–211.525391、y 108.512–242.14，画布 260 × 264。
没有越界，未修改 viewBox。生成的横竖组合已经过无字体环境的 CairoSVG 2.9.1 渲染检查。
这证明字标资源可独立绘制；不替代 Windows/macOS 图标、托盘或整机验收。
