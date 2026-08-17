# Agent Note: GitHub Release 附带 ad-hoc 签名的 zip 安装包

Status: implemented — 从 v0.1.0 起 Release 附带可下载构建

## Problem

仓库此前没有任何 Release，也没有可下载的安装包。想试用的访客必须先装 Node、全局装 `@deepseek-ai/dsh`，再跑构建脚本——这个门槛会劝退绝大多数人，直接压制 star/fork 转化。而 notarized DMG 需要 Apple Developer 账号（$99/年），短期内没有。

## Decision

每个 GitHub Release 附带一个 `ditto -c -k --keepParent` 打包的 zip（约几百 MB，低于 GitHub 单文件 2GB 上限），内容是 `./scripts/build-macos-app.sh` 的产物：ad-hoc 签名、未 notarize。Release notes 和 README 明确写出 Gatekeeper 后果和首次打开步骤（系统设置 → 隐私与安全性 → 仍要打开，或 `xattr -rd com.apple.quarantine`），并注明「从源码构建」始终是无警告的替代路径。

CLAUDE.md 的发布流程同步更新：发布 = tag + Release + zip 资产。

## Alternatives considered

- **不附包，只发 tag（原状）**：对 star 转化几乎没有帮助；「开源但没法直接用」是最常见的流失原因。被用户明确否决。
- **Developer ID + notarized DMG**：正确的长期方案（也是上 Homebrew cask 的前提），但需要付费账号，现在没有。做了 ad-hoc zip 不妨碍以后升级，Release 流程不变，只是换签名和容器格式。
- **GitHub Actions 上构建产物**：CI runner 上装全量 dsh + Node 再打包可行，但产物和本机构建不一致（native addon 架构、dsh 版本漂移），且 ad-hoc 签名在哪台机器打都一样不可验证，没有额外收益。先用本机构建，等升级 Developer ID 签名时再考虑迁到 CI。
- **只用 zip 不用 DMG**：主动选择。未签名 DMG 相比 zip 没有任何 Gatekeeper 优势，还多一步挂载；zip 双击即解压。

## Consequences

- 访客可以直接下载试用，首次打开需要手动过一次 Gatekeeper（文档已写清楚）。
- Release 资产是本机构建，暂时无法由 CI 复现字节级一致——可接受，MIT 源码可审计、可自构建。
- 以后拿到 Developer ID 后：同一流程换成签名+notarize+DMG，并补一条 Homebrew cask。
