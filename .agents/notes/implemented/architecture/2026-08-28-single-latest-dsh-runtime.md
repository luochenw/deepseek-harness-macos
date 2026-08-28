# Agent Note: 构建只打包单一最新版 DSH runtime

Status: implemented — 构建、补丁与内置插件只接受 npm 当前 latest

## Problem

构建脚本默认读取开发机全局安装的 `@deepseek-ai/dsh`。即使 CI 已安装
`0.1.1-rc.2`，本地和发布构建仍可能因为全局残留而打包 `0.1.0-rc.6` 或
`0.1.0-rc.7`。运行时补丁、Host 启动和内置插件也继续保留三套版本分支，
导致产物版本取决于机器状态，并可能把已经不兼容当前凭据格式的旧 runtime
带进 App。

## Decision

- 仓库维护一个 DSH runtime 版本源，当前值与 npm `latest`
  `0.1.1-rc.2` 一致。
- 构建脚本调用独立准备脚本，在 `dist` 缓存中隔离安装该精确版本并打包，
  不再自动读取全局 DSH；`DSH_SOURCE` 只允许指向同一精确版本。
- 构建和 CI 调用准备脚本时核对 npm `latest`。若上游发布新版本而仓库尚未
  适配，构建明确失败，要求先升级补丁和测试；显式离线模式只能复用同版本缓存。
- 删除 rc.6/rc.7 的运行时补丁、Host 参数、smoke 和插件 peer dependency
  分支；CI 与本地构建共用同一准备流程。
- 真实包补丁测试必须使用当前版本，且显式拒绝旧 runtime。

## Alternatives considered

- **继续读取全局 DSH，但文档要求开发者手工升级。** 不选：机器状态仍会
  决定发布内容，无法保证 Release 与 CI 一致。
- **每次直接安装 `@latest`，不固定版本。** 不选：运行时补丁依赖上游编译
  产物结构；新版本未经验证时自动进入发布包会破坏可复现性和 fail-closed
  边界。
- **保留旧版本分支，仅让 Release 使用新版。** 不选：维护和测试成本仍然
  存在，本地构建仍可能掩盖新版本回归。

## Consequences

- `./scripts/build-macos-app.sh` 自动准备当前版本，无需全局 DSH。
- 开发机全局安装 `0.1.0-rc.7` 时，默认构建产物仍为 `0.1.1-rc.2`；
  旧版 `DSH_SOURCE` 覆盖会被拒绝。
- 构建和 CI 核对版本文件等于 npm `latest`；当前 `latest` 为
  `0.1.1-rc.2`。上游 Git tag 中尚未发布到 npm 的 alpha 不会绕过
  runtime patch 适配与测试直接进入正式 App。
- runtime patch、内置插件和 Host smoke 不再包含 rc.6/rc.7 支持分支。
- 验证通过：134 项 Swift 单测、99 项 Agent Platform 测试、真实 rc.2
  补丁测试、默认构建、签名检查和 packaged Host smoke。

## Risks

- 首次源码构建需要 npm 网络访问；后续构建复用 `dist` 下的隔离缓存。
- npm latest 更新后构建会主动失败，直到维护者完成兼容性升级并更新版本源。
