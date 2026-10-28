# Agent Note: Group consecutive tool calls and mark the ones that modify files

Status: implemented — consecutive tool calls in a turn fold into one row; file-modifying calls are marked

## Problem

In a live DeepSeek session, the user saw three things in the transcript:
- several terminal rows with no text at all;
- a long ladder of individual command rows;
- no way to tell which commands changed code.

The blank rows came from real Host data. Almost every bash command starts with `cd <dir> && python3 - <<'PY'` or `cat > X <<'EOF'`. The row title was the command's first line, and once the `cd` prefix was dropped nothing readable was left. Rows only merged when same-name tool calls sat directly next to each other. Real turns interleave reasoning and text between steps and alternate bash, read, write and edit, so in practice nothing ever merged.

## Decision

- **Titles** (`DSHCommandTitle.summarize` in `DSHToolCallClassification.swift`, called from `DSHToolPresentationSupport`):
  - A leading `cd <dir> &&` is stripped and the directory becomes the secondary line.
  - Python heredocs become "Python 脚本 · 修改 <file>" when the script writes a file, otherwise their first meaningful code line.
  - `cat > X <<'EOF'` becomes "写入 X".
  - Other multi-line commands use their first meaningful statement.
  - `job_output` becomes "等待后台任务输出" and `job_kill` becomes "停止后台任务".
  - A title is never empty.
- **Grouping** (transcript fold in `ConversationView.swift`, `ToolGroupRow`):
  - All consecutive tool calls in a turn become one row reading "执行了 N 条命令 · 其中 M 条修改了文件": bash, read, write, edit, glob, grep, `read_image` and `job_*`.
  - Reasoning and text in between no longer split the group.
  - The row is collapsed by default and expands on click.
  - While running, it shows the current command's title with an "执行中" mark.
  - A single call stays a plain row. `run_code` and subagent calls are not grouped.
- **Modification marks** (pure classifier in `DSHToolCallClassification.swift`):
  - edit, write and `apply_patch` always count as modifying.
  - bash counts as modifying when it matches write patterns: redirection, `tee`, `sed -i`, `mv`/`rm`/`cp`/`mkdir`/`touch`/`chmod`/`ln`, git apply/checkout/reset/commit, package installs, `curl -o`, archive extraction, and Python or Node scripts that write files.
  - Modifying rows get a pencil icon, a 2pt accent bar and a "改" chip. Titles stay in the body ink color, with contrast ≥ 4.5:1 checked in light and dark mode by a unit test.

## Alternatives considered

- **Keep same-name adjacency grouping**: it never triggers on real DeepSeek turns, as shown above.
- **Color the whole title with the accent color**: tried first. In the light theme it was hard to read, so the marks moved to the icon, bar and chip.
- **Classify bash by asking the model, or with a heavier shell parser**: unnecessary. A pattern table covers the commands seen in real sessions and is unit-tested. Indirect writes, such as `subprocess.run(["sed","-i",…])` inside `python -c`, are a known miss.

## Consequences

- Tests: `DSHToolCallPresentationTests` use real arguments from a recorded DeepSeek drawing session (41 calls). They check that no title is empty, assert five exact titles, cover 20 classifier cases, check group N/M on the real event sequence, and render off-screen snapshots in light and dark mode.
- Not yet verified in the running app: the feel of expand and collapse, and the switch from "执行中" to the settled title.
