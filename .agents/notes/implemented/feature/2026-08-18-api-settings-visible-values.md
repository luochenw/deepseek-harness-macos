# Agent Note: API 设置回显 —— 配置全可见、密钥密码样式预填

Status: implemented — 配置行内可见，Key 密码样式预填可查看

## Problem

设置 → 模型 里看不到"当前到底配了什么"：自定义配置行只有名字和
"已配置/待填写 Key"徽标，API 地址、协议、模型 ID 都要点进编辑抽屉才
可见；API Key 输入框永远是空的，只有一个布尔徽标，用户无法确认存的
是哪个值、也无法核对改没改对。

## Decision

- **配置行内直接展示当前值**：API 地址 / 协议 / 模型 ID / Key 引用，
  数据与编辑抽屉同源（settingsDescription 的 profile 对象），无新协议。
- **API Key 预填**：从 Host 配置根（dshHome）的 `.credentials.yaml`
  本地读回当前值，预填进密码样式（SecureField）输入框，旁边加
  眼睛按钮可临时明文查看；改动后才能保存。

## Alternatives considered

- **走 Host 协议读凭据值**：credentials 服务有意只回 configured 布尔
  （写单向），改协议属于上游行为变更，超出客户端范畴。App 与 Host
  同机同用户，凭据文件本来就是用户自己的本地文件，直接读文件即可。
- **保持只写不读（现状）**：正是用户抱怨的问题——"看不到当前设置"；
  一个布尔徽标不足以核对配置。
- **明文展示密钥**：不必要的暴露（截屏/旁观）；密码样式 + 主动点击
  眼睛查看是标准折中，也是用户点名的形态。

## Consequences

- 模型页每个自定义配置行能直接读到 API 地址、协议、模型、Key 引用。
- API Key 行打开设置时已带值（圆点样式），点眼睛可见明文，改动后
  保存生效。

## Risks

- `.credentials.yaml` 若引入嵌套/多文档 YAML，行级解析会读不到——
  当前 Host 写入格式为平面 `KEY: value`，解析器按此约定。
