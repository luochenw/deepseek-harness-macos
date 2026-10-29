import Foundation

/// Thin `Process`-based git access for the workspace chips. System git via
/// Process (not libgit2): this is a single swiftc target with no package
/// manager, and matching the user's terminal git exactly is a feature —
/// see the workspace-chips-git-worktree Agent Note.
enum DSHGitOps {
  struct Info: Equatable {
    let branch: String?
    let branches: [String]
    let isWorktree: Bool
  }

  /// Blocking — call from a background task. Returns nil when `path` is not
  /// inside a git repository (or git is unavailable).
  static func info(at path: String) -> Info? {
    guard run(["rev-parse", "--is-inside-work-tree"], at: path)?.output == "true" else { return nil }
    let branch = run(["branch", "--show-current"], at: path)?.output
    let branches = (run(["branch", "--format=%(refname:short)"], at: path)?.output ?? "")
      .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    // A linked worktree's .git is a file pointing at the main repository.
    let commonDir = run(["rev-parse", "--git-common-dir"], at: path)?.output ?? ""
    let gitDir = run(["rev-parse", "--git-dir"], at: path)?.output ?? ""
    let isWorktree = !commonDir.isEmpty && commonDir != gitDir
    return Info(branch: (branch?.isEmpty ?? true) ? nil : branch, branches: branches, isWorktree: isWorktree)
  }

  /// Blocking checkout; returns an error message on failure (dirty tree etc.).
  static func checkout(_ branch: String, at path: String) -> String? {
    guard let result = run(["checkout", branch], at: path) else { return "无法执行 git" }
    return result.status == 0 ? nil : result.errorOutput
  }

  /// Blocking `git worktree add` under `<repo>-worktrees/<branch>`; returns
  /// the created path, or an error message.
  static func addWorktree(branch: String, at path: String) -> Result<String, String> {
    let repo = URL(fileURLWithPath: path)
    let sanitized = branch.replacingOccurrences(of: "/", with: "-")
    let target = repo.deletingLastPathComponent()
      .appendingPathComponent("\(repo.lastPathComponent)-worktrees", isDirectory: true)
      .appendingPathComponent(sanitized, isDirectory: true)
    if FileManager.default.fileExists(atPath: target.path) { return .success(target.path) }
    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let result = run(["worktree", "add", target.path, branch], at: path) else { return .failure("无法执行 git") }
    return result.status == 0 ? .success(target.path) : .failure(result.errorOutput)
  }

  private static func run(_ arguments: [String], at path: String) -> (output: String, errorOutput: String, status: Int32)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", path] + arguments
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { return nil }
    process.waitUntilExit()
    let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let errorOutput = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (output, errorOutput, process.terminationStatus)
  }
}

// Allow `Result<String, String>` above.
extension String: @retroactive Error {}
