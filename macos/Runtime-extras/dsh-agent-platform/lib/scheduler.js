export class LaneScheduler {
  #limit;
  #running = 0;
  #ready = [];
  #lanes = new Map();

  constructor(limit = 3) {
    if (!Number.isSafeInteger(limit) || limit < 1) throw new TypeError("scheduler limit must be a positive integer");
    this.#limit = limit;
  }

  enqueue(laneId, task) {
    if (typeof laneId !== "string" || laneId.length === 0) throw new TypeError("lane id must be non-empty");
    if (typeof task !== "function") throw new TypeError("scheduler task must be a function");
    return new Promise((resolve, reject) => {
      const lane = this.#lanes.get(laneId) ?? { running: false, queue: [] };
      this.#lanes.set(laneId, lane);
      lane.queue.push({ task, resolve, reject });
      if (!lane.running && lane.queue.length === 1) this.#ready.push(laneId);
      this.#pump();
    });
  }

  #pump() {
    while (this.#running < this.#limit && this.#ready.length > 0) {
      const laneId = this.#ready.shift();
      const lane = this.#lanes.get(laneId);
      if (lane === undefined || lane.running || lane.queue.length === 0) continue;
      const entry = lane.queue[0];
      lane.running = true;
      this.#running += 1;
      Promise.resolve()
        .then(entry.task)
        .then(entry.resolve, entry.reject)
        .finally(() => {
          lane.queue.shift();
          lane.running = false;
          this.#running -= 1;
          if (lane.queue.length === 0) this.#lanes.delete(laneId);
          else this.#ready.push(laneId);
          this.#pump();
        });
    }
  }
}
