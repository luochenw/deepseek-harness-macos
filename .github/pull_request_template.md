## 改了什么

<!-- 一两句话：这个 PR 改了什么？用用户可见的语言描述。 -->

## 为什么

<!-- 要解决的问题。有对应 issue 就链接上。 -->

## 检查清单

- [ ] `./scripts/test-macos-native.sh` 本地通过
- [ ] 行为改动已通过 `./scripts/test-macos-native.sh --unit`
- [ ] Runtime 改动已通过 `./scripts/test-agent-platform-runtime-script.sh` 和 `./scripts/test-agent-platform-runtime.sh`
- [ ] 打包改动已通过 `./scripts/build-macos-app.sh` 和 `./scripts/test-macos-native.sh --smoke`
- [ ] 非平凡决策？已在 `.agents/notes/` 下补 Agent Note（见 [CLAUDE.md](../CLAUDE.md)）
- [ ] 涉及 web 对齐功能？已更新 [macos/WEB_PARITY.md](../macos/WEB_PARITY.md)
