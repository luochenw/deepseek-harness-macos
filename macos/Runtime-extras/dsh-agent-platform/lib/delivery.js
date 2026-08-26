export class KeyedSingleFlight {
  #active = new Map();

  run(key, task) {
    const existing = this.#active.get(key);
    if (existing !== undefined) return existing;
    const current = Promise.resolve().then(task);
    this.#active.set(key, current);
    return current.finally(() => {
      if (this.#active.get(key) === current) this.#active.delete(key);
    });
  }
}

export function deliverDurableAgentMessage(agent, message) {
  if (agent.session.events.some((event) => event.type === "user/message" && event.data?.id === message.id)) {
    return "logged";
  }
  const pending = agent.inbox.nextTurn.some((item) => item.id === message.id)
    || agent.inbox.nextStep.some((item) => item.id === message.id);
  if (pending) {
    if (agent.status === "idle") {
      agent.inbox.remove(message.id);
      agent.followup(message);
      return "rewoken";
    }
    return "pending";
  }
  if (agent.status === "idle") agent.followup(message);
  else agent.steer(message);
  return "sent";
}
