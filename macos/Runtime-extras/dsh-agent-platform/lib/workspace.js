import { randomUUID } from "node:crypto";
import { mkdir, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";

function sanitize(value) {
  return value.replace(/[^A-Za-z0-9_.-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 80) || randomUUID();
}

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (status) => {
      if (status === 0) resolve(stdout.trim());
      else reject(new Error(`${command} ${args.join(" ")} failed (${status}): ${stderr.trim()}`));
    });
  });
}

async function isGitRepository(sourcePath) {
  try {
    return (await run("/usr/bin/git", ["-C", sourcePath, "rev-parse", "--is-inside-work-tree"])) === "true";
  } catch {
    return false;
  }
}

async function exists(target) {
  try {
    await stat(target);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

export class WorkspaceManager {
  #root;

  constructor(root) {
    this.#root = root;
  }

  async allocate({ sourcePath, identity, existingPath }) {
    if (existingPath !== undefined) return { path: existingPath, reused: true };
    await mkdir(this.#root, { recursive: true });
    const target = path.join(this.#root, sanitize(identity));
    if (!await isGitRepository(sourcePath)) {
      throw new Error(`Agent execution requires a Git worktree; "${sourcePath}" is not inside a Git repository`);
    }
    return this.#allocateGit(sourcePath, target, identity);
  }

  async cleanup(workspace) {
    if (workspace.gitRoot !== undefined) {
      const target = workspace.worktreeRoot ?? workspace.path;
      if (await exists(target)) {
        await run("/usr/bin/git", ["-C", workspace.gitRoot, "worktree", "remove", "--force", target]);
      }
      if (workspace.branch !== undefined) {
        await run("/usr/bin/git", ["-C", workspace.gitRoot, "branch", "-D", workspace.branch]).catch(() => {});
      }
      return;
    }
    await rm(workspace.path, { recursive: true, force: true });
  }

  async reconcileOrphans(retainedPaths) {
    await mkdir(this.#root, { recursive: true });
    const retained = new Set(retainedPaths
      .filter((candidate) => typeof candidate === "string" && candidate.length > 0)
      .map((candidate) => path.resolve(candidate)));
    const removed = [];
    for (const entry of await readdir(this.#root, { withFileTypes: true })) {
      if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
      const target = path.join(this.#root, entry.name);
      if (retained.has(path.resolve(target))) continue;
      await this.#cleanupOrphan(target);
      removed.push(target);
    }
    return removed;
  }

  async inspect(workspacePath, baselineCommit) {
    if (await isGitRepository(workspacePath)) {
      const branch = await run("/usr/bin/git", ["-C", workspacePath, "branch", "--show-current"]);
      const baseline = baselineCommit ?? "HEAD";
      const diffSummary = await run("/usr/bin/git", ["-C", workspacePath, "diff", "--stat", baseline, "--", "."]);
      const changed = (await run("/usr/bin/git", ["-C", workspacePath, "diff", "--name-only", "--relative", baseline, "--", "."]))
        .split("\n").filter(Boolean);
      const pending = (await run("/usr/bin/git", ["-C", workspacePath, "status", "--short"]))
        .split("\n").filter(Boolean).map((line) => line.slice(3));
      const files = [...new Set([...changed, ...pending])];
      return { worktreePath: workspacePath, branch: branch || undefined, diffSummary, files };
    }
    return { worktreePath: workspacePath, files: [] };
  }

  async #allocateGit(sourcePath, target, identity) {
    const gitRoot = await run("/usr/bin/git", ["-C", sourcePath, "rev-parse", "--show-toplevel"]);
    const prefix = await run("/usr/bin/git", ["-C", sourcePath, "rev-parse", "--show-prefix"]);
    const head = await run("/usr/bin/git", ["-C", sourcePath, "rev-parse", "HEAD"]);
    const indexPath = path.join(this.#root, `.index-${sanitize(identity)}-${randomUUID()}`);
    const env = {
      GIT_INDEX_FILE: indexPath,
      GIT_AUTHOR_NAME: "DSH Agent Platform",
      GIT_AUTHOR_EMAIL: "agent-platform@localhost",
      GIT_COMMITTER_NAME: "DSH Agent Platform",
      GIT_COMMITTER_EMAIL: "agent-platform@localhost",
    };
    try {
      await run("/usr/bin/git", ["-C", sourcePath, "read-tree", "HEAD"], { env });
      await run("/usr/bin/git", ["-C", sourcePath, "add", "-A", "--", "."], { env });
      const tree = await run("/usr/bin/git", ["-C", sourcePath, "write-tree"], { env });
      const commit = await run("/usr/bin/git", ["-C", sourcePath, "commit-tree", tree, "-p", head, "-m", `DSH agent snapshot ${identity}`], { env });
      const branch = `dsh-agent/${sanitize(identity)}-${randomUUID().slice(0, 8)}`;
      await run("/usr/bin/git", ["-C", gitRoot, "worktree", "add", "-b", branch, target, commit]);
      return {
        path: prefix === "" ? target : path.join(target, prefix),
        worktreeRoot: target,
        branch,
        baselineCommit: commit,
        gitRoot,
        reused: false,
      };
    } finally {
      await rm(indexPath, { force: true });
    }
  }

  async #cleanupOrphan(target) {
    if (!await isGitRepository(target)) {
      await rm(target, { recursive: true, force: true });
      return;
    }
    const branch = await run("/usr/bin/git", ["-C", target, "branch", "--show-current"]);
    const gitDir = await run("/usr/bin/git", [
      "-C", target, "rev-parse", "--path-format=absolute", "--git-common-dir",
    ]);
    await run("/usr/bin/git", [
      `--git-dir=${gitDir}`, "worktree", "remove", "--force", target,
    ]);
    if (branch) {
      await run("/usr/bin/git", [
        `--git-dir=${gitDir}`, "branch", "-D", branch,
      ]).catch(() => {});
    }
  }
}

export { run as runProcess };
