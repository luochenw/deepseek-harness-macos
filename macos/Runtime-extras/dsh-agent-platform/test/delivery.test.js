import assert from "node:assert/strict";
import test from "node:test";
import { deliverDurableAgentMessage, KeyedSingleFlight } from "../lib/delivery.js";

test("same-key delivery is executed once while the first call is in flight", async () => {
  const gate = new KeyedSingleFlight();
  let releases;
  const blocked = new Promise((resolve) => { releases = resolve; });
  let calls = 0;
  const deliver = () => gate.run("batch-1", async () => {
    calls += 1;
    await blocked;
    return "delivered";
  });

  const first = deliver();
  const second = deliver();
  await Promise.resolve();
  assert.equal(calls, 1);
  releases();
  assert.equal(await first, "delivered");
  assert.equal(await second, "delivered");
  assert.equal(calls, 1);
});

test("a settled delivery key can be used again", async () => {
  const gate = new KeyedSingleFlight();
  let calls = 0;
  await gate.run("batch-1", async () => { calls += 1; });
  await gate.run("batch-1", async () => { calls += 1; });
  assert.equal(calls, 2);
});

test("a durable outbox message pending on an idle resumed Agent is re-woken", () => {
  const message = { id: "message-1" };
  const pending = [message];
  const calls = [];
  const agent = {
    status: "idle",
    session: { events: [] },
    inbox: {
      nextTurn: pending,
      nextStep: [],
      remove(id) {
        calls.push(["remove", id]);
        pending.splice(0, pending.length);
        return true;
      },
    },
    followup(value) { calls.push(["followup", value.id]); },
    steer(value) { calls.push(["steer", value.id]); },
  };
  assert.equal(deliverDurableAgentMessage(agent, message), "rewoken");
  assert.deepEqual(calls, [["remove", "message-1"], ["followup", "message-1"]]);
});
