import assert from "node:assert/strict";
import test from "node:test";
import { LaneScheduler } from "../lib/scheduler.js";

test("global concurrency is capped while each lane remains FIFO", async () => {
  const scheduler = new LaneScheduler(3);
  let running = 0;
  let maxRunning = 0;
  const order = [];
  const task = (lane, label, delay) => scheduler.enqueue(lane, async () => {
    running += 1;
    maxRunning = Math.max(maxRunning, running);
    order.push(`start:${label}`);
    await new Promise((resolve) => setTimeout(resolve, delay));
    order.push(`end:${label}`);
    running -= 1;
  });

  await Promise.all([
    task("same", "a1", 25),
    task("same", "a2", 1),
    task("b", "b1", 15),
    task("c", "c1", 15),
    task("d", "d1", 1),
  ]);

  assert.equal(maxRunning, 3);
  assert.ok(order.indexOf("end:a1") < order.indexOf("start:a2"));
});
