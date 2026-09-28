# 品牌资源

`appicon-light.svg` 和 `appicon-dark.svg` 是已确认的纯几何应用图标源。`logo-mono-ink.svg` / `logo-mono-white.svg` 是纯几何标志源。图标生成器只读取本仓的这些文件，不依赖管理仓或本机字体。

运行 `cd tool/brand_icons && npm ci && npm run build`，即可重新生成 macOS AppIcon、macOS 菜单栏模板图标，以及 Windows 应用和托盘 `.ico`。Windows 托盘使用有浅色底的应用图标，以便在深浅任务栏上保留对比；macOS 菜单栏使用单色模板，由系统着色。生成器保留 16px 尺寸，Windows 另包含适合高 DPI 的尺寸。

设计稿的 `lockup-horizontal.svg` 和 `lockup-vertical.svg` 仍含实时文本，并依赖思源黑体和 Inter Tight。两款字体的官方仓库分别以 [SIL Open Font License 1.1](https://github.com/adobe-fonts/source-han-sans/blob/release/LICENSE.txt) 和 [SIL Open Font License 1.1](https://github.com/googlefonts/inter-gf-tight/blob/main/OFL.txt) 授权。当前产品没有打包这两份字标、字体文件或其字形轮廓；若后续用于印刷或安装包，应按字体许可证核对来源并转轮廓或随包提供符合许可的字体。
