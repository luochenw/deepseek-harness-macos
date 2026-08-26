import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

export class RunLogStore {
  #root;
  #queues = new Map();

  constructor(root) {
    this.#root = root;
  }

  async append(runId, stream, text) {
    if (text === "") return;
    const previous = this.#queues.get(runId) ?? Promise.resolve();
    const next = previous.then(async () => {
      await mkdir(this.#root, { recursive: true });
      const items = await this.#read(runId);
      items.push({
        seq: items.length === 0 ? 0 : items[items.length - 1].seq + 1,
        time: Date.now(),
        stream,
        text: String(text),
      });
      await writeFile(this.#file(runId), JSON.stringify(items) + "\n");
    });
    this.#queues.set(runId, next);
    try {
      await next;
    } finally {
      if (this.#queues.get(runId) === next) this.#queues.delete(runId);
    }
  }

  async page(runId, before, limit = 200) {
    const items = await this.#read(runId);
    const eligible = before === undefined ? items : items.filter((item) => item.seq < before);
    const slice = eligible.slice(Math.max(0, eligible.length - limit));
    return { items: slice, hasMore: eligible.length > slice.length };
  }

  #file(runId) {
    return path.join(this.#root, `${runId}.json`);
  }

  async #read(runId) {
    try {
      const value = JSON.parse(await readFile(this.#file(runId), "utf8"));
      return Array.isArray(value) ? value : [];
    } catch (error) {
      if (error?.code === "ENOENT") return [];
      throw error;
    }
  }
}
