import assert from "node:assert/strict";
import test from "node:test";
import { recoverRootSessions } from "../lib/recovery.js";

test("root recovery uses the Host session create/resume path and continues after one failure", async () => {
  const calls = [];
  const errors = [];
  await recoverRootSessions([
    { sessionId: "root-1", cwd: "/work/one" },
    { sessionId: "root-2", cwd: "/work/two" },
  ], async (request) => {
    calls.push(request);
    if (request.payload.sessionId === "root-1") {
      return { result: { ok: false, error: { message: "unavailable" } } };
    }
    return { result: { ok: true, value: { sessionId: request.payload.sessionId } } };
  }, (root, error) => errors.push([root.sessionId, String(error)]));

  assert.deepEqual(calls.map((request) => request.payload), [
    { sessionId: "root-1", cwd: "/work/one" },
    { sessionId: "root-2", cwd: "/work/two" },
  ]);
  assert.equal(errors.length, 1);
  assert.equal(errors[0][0], "root-1");
  assert.match(errors[0][1], /unavailable/);
});
