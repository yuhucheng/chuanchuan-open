# 品牌资源

单色标志及浅/深底应用图标 SVG 来自用户确认的几何稿。Flutter `BrandMark` 保留原标志路径；标题字标使用独立轮廓，UI 正文继续使用常规字重及系统回退，不依赖本机安装品牌字体。组合字标、字体版本、来源、许可与重新生成见 [WORDMARK.md](WORDMARK.md)。

## 原生图标

在产品仓运行 `python3 tool/generate_brand_icons.py`；加 `--check` 检查源及产物漂移。生成器只依赖 Python 标准库和 PATH 内的 librsvg `rsvg-convert`，正常应用构建使用已检入资源，不运行生成器、不读取其他仓库、不下载字体。渲染器版本和源/产物 SHA-256 记录于 [native-icons.json](native-icons.json)。当前渲染器为 librsvg 2.60.0；升级后应重新检查生成差异和小尺寸显示。

- Windows/macOS 应用图标使用 `appicon-light.svg`，保持稳定的应用标识；`appicon-dark.svg` 保留为已确认设计源，未声称会随 Flutter 偏好切换系统应用图标。
- macOS 菜单栏使用 `logo-mono-ink.svg` 的 16/32 px 模板资源，由 AppKit 适配菜单栏外观。
- Windows 托盘使用独立透明单色 ink/white ICO，含 16/20/24/32/40/48/64 px 表示；应用 ICO 另含 128/256 px。由原生宿主按任务栏外观和 DPI 选择，复用同一几何，不把应用圆角底板缩成托盘图标。

生成和编译不等于所有平台验收。真实 16px 可读性、系统高对比及各 DPI/任务栏行为须在实际平台核验。
