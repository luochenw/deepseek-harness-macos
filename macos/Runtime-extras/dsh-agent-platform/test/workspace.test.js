import assert from "node:assert/strict";
import { mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { WorkspaceManager } from "../lib/workspace.js";

function git(cwd, args, env = {}) {
  const result = spawnSync("/usr/bin/git", ["-C", cwd, ...args], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

test("git workspace snapshot includes dirty tracked and unignored files without changing parent HEAD or index", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-repo-"));
  git(root, ["init"]);
  git(root, ["config", "user.email", "test@example.com"]);
  git(root, ["config", "user.name", "Test"]);
  await writeFile(path.join(root, ".gitignore"), "ignored.txt\n");
  await writeFile(path.join(root, "tracked.txt"), "base\n");
  git(root, ["add", "."]);
  git(root, ["commit", "-m", "base"]);
  const head = git(root, ["rev-parse", "HEAD"]);
  const indexBefore = git(root, ["ls-files", "-s"]);

  await writeFile(path.join(root, "tracked.txt"), "dirty\n");
  await writeFile(path.join(root, "new.txt"), "new\n");
  await writeFile(path.join(root, "ignored.txt"), "ignored\n");

  const manager = new WorkspaceManager(path.join(root, ".agent-workspaces"));
  const workspace = await manager.allocate({ sourcePath: root, identity: "run-1" });
  assert.equal(await readFile(path.join(workspace.path, "tracked.txt"), "utf8"), "dirty\n");
  assert.equal(await readFile(path.join(workspace.path, "new.txt"), "utf8"), "new\n");
  await assert.rejects(() => readFile(path.join(workspace.path, "ignored.txt"), "utf8"));
  assert.equal(git(root, ["rev-parse", "HEAD"]), head);
  assert.equal(git(root, ["ls-files", "-s"]), indexBefore);
});

test("workspace inspection compares against the allocation baseline after member commits", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-inspect-"));
  git(root, ["init"]);
  git(root, ["config", "user.email", "test@example.com"]);
  git(root, ["config", "user.name", "Test"]);
  await writeFile(path.join(root, "tracked.txt"), "base\n");
  git(root, ["add", "."]);
  git(root, ["commit", "-m", "base"]);

  const manager = new WorkspaceManager(path.join(root, ".agent-workspaces"));
  const workspace = await manager.allocate({ sourcePath: root, identity: "run-2" });
  git(workspace.path, ["config", "user.email", "agent@example.com"]);
  git(workspace.path, ["config", "user.name", "Agent"]);
  await writeFile(path.join(workspace.path, "tracked.txt"), "committed change\n");
  git(workspace.path, ["add", "tracked.txt"]);
  git(workspace.path, ["commit", "-m", "member change"]);
  await writeFile(path.join(workspace.path, "untracked.txt"), "pending\n");

  const inspection = await manager.inspect(workspace.path, workspace.baselineCommit);
  assert.match(inspection.diffSummary, /tracked\.txt/);
  assert.deepEqual(new Set(inspection.files), new Set(["tracked.txt", "untracked.txt"]));
});

test("workspace reconciliation removes allocation directories missing from durable state", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-orphan-"));
  git(root, ["init"]);
  git(root, ["config", "user.email", "test@example.com"]);
  git(root, ["config", "user.name", "Test"]);
  await writeFile(path.join(root, "tracked.txt"), "base\n");
  git(root, ["add", "."]);
  git(root, ["commit", "-m", "base"]);

  const manager = new WorkspaceManager(path.join(root, ".agent-workspaces"));
  const kept = await manager.allocate({ sourcePath: root, identity: "kept" });
  const orphan = await manager.allocate({ sourcePath: root, identity: "orphan" });

  const removed = await manager.reconcileOrphans([kept.worktreeRoot]);

  assert.deepEqual(removed, [orphan.worktreeRoot]);
  await stat(kept.worktreeRoot);
  await assert.rejects(() => stat(orphan.worktreeRoot), /ENOENT/);
  assert.equal(git(root, ["branch", "--list", orphan.branch]), "");
});

test("execution workspace allocation rejects non-Git project roots", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-non-git-"));
  const allocations = path.join(root, ".agent-workspaces");
  await writeFile(path.join(root, "task.txt"), "plain directory\n");

  const manager = new WorkspaceManager(allocations);
  await assert.rejects(
    () => manager.allocate({ sourcePath: root, identity: "run-non-git" }),
    /Git worktree/);
  await assert.rejects(() => stat(path.join(allocations, "run-non-git")), /ENOENT/);
});
