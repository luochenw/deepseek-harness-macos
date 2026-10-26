# Agent Note: 打包运行时对齐 DeepSeek 官方模型目录

Status: implemented — pinned runtime 0.1.1-rc.2 的默认模型目录改成官方当前目录（DeepSeek-V4.1-Flash 含图片 + DeepSeek-V4-Pro）

## Problem

DeepSeek 官方 API 现在只公布两个模型（`GET https://api.deepseek.com/models`）：

| id | 名称 | 上下文 | 最大输出 | 输入 |
|---|---|---|---|---|
| `deepseek-flash` | DeepSeek-V4.1-Flash | 1,048,576 | 393,216 | text + image |
| `deepseek-v4-pro` | DeepSeek-V4-Pro | 1,048,576 | 393,216 | text |

旧的 `deepseek-v4-flash`、`deepseek-v4-flash-vision-exp` 已被官方退役，仅作为别名继续接受，实际由 DeepSeek-V4.1-Flash-1017 服务并按 Flash 价格计费。

而仓库钉住的 runtime `0.1.1-rc.2` 里 `dsh-llm-deepseek` 的 `DEFAULT_MODELS` 仍是退役目录：

```js
{ id: "deepseek-v4-flash", name: "DeepSeek-V4-Flash" }            // 无图片
{ id: "deepseek-v4-pro",   name: "DeepSeek-V4-Pro" }
{ id: "deepseek-v4-flash-vision-exp", name: "DeepSeek-V4-Flash-Vision-Exp" }  // 只有它能传图
```

后果是打包出去的 app：模型选择器显示已经退役的名字；最新模型（V4.1-Flash）没有正确的名字与输出上限；**图片只能发到一个退役的 `vision-exp` id 上**，而能以最新模型身份传图的路径根本不存在。用户自己的 `settings.yaml` 覆盖（`llm-deepseek.models`）能救本机，但救不了新装用户，属于"每个部署自己配一遍"的状态。

上游 DSH `0.2.1-rc.2` 已经把这个目录改成官方目录，但 0.2.x 同时换掉了整个 Host RPC 协议（见 [0.2 协议迁移](2026-08-28-dsh-0.2-protocol-migration.md)），不能为了一个目录去换协议。

## Decision

在 `scripts/patch-agent-platform-runtime.mjs` 里增加一步运行时补丁，把 `node_modules/@deepseek-ai/dsh-llm-deepseek/lib/index.js` 的 `DEFAULT_MODELS` 重写成官方目录：

```js
const DEFAULT_MODELS = [
	{ id: "deepseek-flash", name: "DeepSeek-V4.1-Flash", contextWindow: 1048576, maxTokens: 393216, inputModalities: ["text", "image"] },
	{ id: "deepseek-v4-pro", name: "DeepSeek-V4-Pro", contextWindow: 1048576, maxTokens: 393216 }
];
```

要点：

- **id 用官方 id**，与上游 0.2.x 的选择一致，而不是继续用退役别名。默认 route（`https://api.deepseek.com`）直接可用；本地 relay 之类只认旧别名的部署，用 `settings.yaml` 的 `llm-deepseek.models` 覆盖即可（本机就是这样）。
- **图片能力挂在最新模型上**（`inputModalities: ["text", "image"]`），这是 0.1.1 适配器本来就支持的字段，与 0.2.x 的能力面等价；退役的 `vision-exp` 条目随之删除。
- **fail closed**：锚点 `const DEFAULT_MODELS = [` 找不到、或结尾 `];` 缺失时补丁直接抛错，构建失败；同时把 `dsh-llm-deepseek` 加进补丁脚本的版本断言列表，版本漂移同样失败。
- **幂等**：源码里已出现 `id: "deepseek-flash"` 时不再改写（重复运行时安全）。

0.1.1 的目录 schema 没有 `systemPromptUpdate` / `toolUpdate` 字段（0.2.x 用它减少 KV cache 失效），所以这一项无法在 pinned runtime 上对齐，记录在下面的遗留里。

## Alternatives considered

- **升级到 0.2.1-rc.2 让上游自己给出目录**：0.2.x 顺带带 v41 图片 token 计费、`compaction-image-offload` 和按模型的 cache 友好标记，是"真正对齐"。但它同时把 Host RPC 表面整体换掉（41 个 legacy 方法全部 404，且新增 token→cookie 鉴权），需要重写原生客户端的传输层与全部功能域——那是一份独立的迁移计划（见另一份 Note），不能与"补一个模型目录"绑在一起发布。
- **只靠用户 `settings.yaml` 覆盖**：本机可解，但打包产物仍然对外提供退役模型，新装用户拿不到最新模型与图片能力，且每个部署都要手工配一遍。
- **保留 `deepseek-v4-flash` 别名 + 改名显示**：能兼容只认旧 id 的自建 relay，但选择器里出现的是一个官方已退役的 id，且与上游 0.2.x 的选择分叉。真正需要旧 id 的部署用 settings 覆盖更诚实。
- **在 Swift 侧硬编码模型列表**：原生客户端目前完全不认识模型 id（全部由 Host 的 `llm.models` 提供），把部署事实写进 UI 层会破坏这个分层。

## Consequences

- 打包后的 app 开箱即显示 DeepSeek-V4.1-Flash（1M/384K，可发图）与 DeepSeek-V4-Pro；退役的两个 id 不再出现。
- 已有 `settings.yaml` 的 `llm-deepseek.models` 仍然优先，用户自定义目录不受影响。
- 补丁脚本的职责从"只补 Agent Platform"扩到"顺带对齐 provider 目录"，文件名保留（build 脚本与测试都按这个名字调用），README 的补丁清单同步更新。
- 遗留：`systemPromptUpdate: "in-history"` / `toolUpdate: "addition-only"` 这类 0.2.x 才有的按模型标记无法在 0.1.1 上表达，等协议迁移时由上游提供。
- 验证：`scripts/test-agent-platform-runtime-patch.mjs` 覆盖重写结果、幂等与版本 fail-closed；`scripts/verify-native-host-api.sh` 新增真契约断言（必须出现 `deepseek-flash`/`deepseek-v4-pro`，不得出现 `deepseek-v4-flash*`），在「0.1.1-rc.2 runtime + 三个 extras + 补丁」组装出的等价 app 上跑通完整 smoke（Host 冷启动、读写 API、权限、Agent Platform 批次、workbench 插件全部通过）。
- 落地验证：`./scripts/test-macos-native.sh`（Swift 编译门 + native-contract + 全部快照用例）通过 → `./scripts/build-macos-app.sh` 完整构建通过（产出 `dist/DeepSeek Harness.app`，280M runtime，ad-hoc 签名）→ 产物内 `DEFAULT_MODELS` 即上表 → `codesign --verify --deep --strict` 通过 → `verify-native-host-api.sh` 对产物跑完整 smoke 通过（含新目录契约断言）。
- 环境备注：这些步骤在受文件沙箱限制的会话里会假性失败——Swift 编译器被拒（`clang: ModuleCache ... Operation not permitted`、`swift-plugin-server produced malformed response`），与本仓库代码无关；放开权限后同一台机器、同一命令一次通过。另有两条与本次改动无关的前置条件：`npm` 的 `~/.npm` 缓存归属异常，需要 `npm_config_cache` 指到可写目录；`prepare-dsh-runtime.sh` 的「pin 必须等于 npm latest」门在 npm latest 已到 `0.2.1-rc.2` 时会失败，需 `DSH_RUNTIME_VERIFY_LATEST=0`。
