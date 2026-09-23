# 设计参数

`design-tokens.json` 是产品仓内可独立使用的参数快照。运行 `python3 tool/generate_field_tokens.py` 生成 Flutter 色彩、排版、字体回退、圆角及动作参数；加 `--check` 验证漂移。构建和生成均不读取外部管理仓。

默认主题为 system；仅保存 system/light/dark 偏好，不保存任何连接授权。正文使用 JSON 中指定的系统回退，不额外打包字体文件。品牌 Heavy 字标使用 [独立轮廓资源](../brand/WORDMARK.md)，不改变正文 400/500 字重。
