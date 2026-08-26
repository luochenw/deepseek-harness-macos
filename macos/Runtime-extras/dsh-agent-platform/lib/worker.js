import { spawn } from "node:child_process";

const encoded = process.argv[2];
if (encoded === undefined) throw new Error("worker spec is required");
const spec = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));

const child = spawn(spec.command, spec.args, {
  cwd: spec.cwd,
  env: { ...process.env, ...spec.env },
  detached: true,
  stdio: ["ignore", "pipe", "pipe"],
});

child.stdout.pipe(process.stdout);
child.stderr.pipe(process.stderr);

let stopping = false;
function stop() {
  if (stopping) return;
  stopping = true;
  try {
    process.kill(-child.pid, "SIGTERM");
  } catch {}
  setTimeout(() => {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {}
  }, 3000).unref();
}

process.stdin.resume();
process.stdin.on("end", stop);
process.stdin.on("close", stop);
process.on("SIGTERM", stop);
process.on("SIGINT", stop);

child.on("error", (error) => {
  console.error(error instanceof Error ? error.stack ?? error.message : String(error));
  process.exitCode = 1;
});
child.on("close", (status, signal) => {
  process.exitCode = status ?? (signal ? 1 : 0);
  process.exit();
});
