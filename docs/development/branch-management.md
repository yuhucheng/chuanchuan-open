# 分支与提交约定

开发目标见[版本说明](../version-plan.md)。统一工作区开发时，业务仓必须与管理仓当前分支同名；当前统一为 release/v0.1.0，用于已批准的 D1/S1。main 保持主线，独立检出按已批准的版本分支工作；产品构建和钩子不依赖管理仓；未经明确批准不新增分支/worktree，不 force-push，不丢弃他人改动。

提交标题为 type(v目标版本): 描述，版本读取根 VERSION。允许 feat、fix、refactor、docs、test、build、ci、chore、merge。提交前运行对应产品检查。

新克隆使用 `pwsh -File tool/install_git_hooks.ps1` 启用 .githooks；已有自定义钩子须合并而不是覆盖，不使用 --no-verify。没有 PowerShell 时可在确认现有 core.hooksPath 为空或 .githooks 后运行 `git config --local core.hooksPath .githooks`。

公开接口与客户端先交付，SDK/服务后交付，记录验证过的提交关联。SDK 与客户端源码边界保持独立；公开材料不含私有实现和生产凭据。
