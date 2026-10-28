// Host-mode client for `ds-agent`: talks to the DSH Host owned by the running
// DeepSeek Harness.app through its loopback JSON-RPC surface.
//
// The App publishes `<DSH_HOME>/host.json` once its packaged Host handshake
// succeeds (baseURL + launch token + owning pid). This module validates that
// record, exchanges the token for a `dsh-auth-*` cookie (no redirect
// following), and drives one Session turn: create → prompt → wait → page.
// Only Node builtins are used; tests import the helpers directly.

import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

export const HOST_FILE_NAME = 'host.json';
export const HOST_FILE_VERSION = 1;
export const DEFAULT_POLL_INTERVAL_MS = 500;
/// 0 = wait for as long as the turn takes. A model turn is unbounded work, so
/// the CLI only gives up when the user asks it to (`--timeout`).
export const DEFAULT_TIMEOUT_MS = 0;
/// Consecutive idle observations required before `--attach` without a
/// `requestId` concludes the Session has nothing in flight. A prompt accepted
/// microseconds ago is not yet `running` and has not written its user message,
/// so a single idle poll would mis-report the previous turn as this run's
/// answer; ~3 polls at the default interval covers that window.
export const ATTACH_SETTLE_POLLS = 3;
const HANDSHAKE_TIMEOUT_MS = 10_000;
const RPC_TIMEOUT_MS = 60_000;

/** `DSH_HOME` override, else the App's default DSH home. */
export function resolveDSHHome(env = process.env) {
  const override = env.DSH_HOME;
  if (typeof override === 'string' && override.trim() !== '') return resolve(override);
  return join(homedir(), 'Library/Application Support/DeepSeek Harness/dsh');
}

/**
 * `90s` / `30m` / `2h` / `1500ms` / `60000` → milliseconds. Bare numbers are
 * milliseconds (matching `DS_AGENT_TIMEOUT_MS`); `0` disables the timeout.
 */
export function parseDuration(raw) {
  if (typeof raw !== 'string') return null;
  const text = raw.trim().toLowerCase();
  const match = /^(\d+(?:\.\d+)?)(ms|s|m|h)?$/.exec(text);
  if (!match) return null;
  const value = Number(match[1]);
  if (!Number.isFinite(value) || value < 0) return null;
  const scale = { ms: 1, s: 1000, m: 60_000, h: 3_600_000 }[match[2] ?? 'ms'];
  return Math.round(value * scale);
}

/** Host names that are provably this machine's loopback interface. */
const LOOPBACK_HOSTS = new Set(['127.0.0.1', '[::1]', '::1', 'localhost']);

/**
 * Validate the published `baseURL` as a loopback origin. The record is a
 * plain file in the user's DSH home — anything running as that user could
 * rewrite it — and the CLI replays a bearer token to whatever URL it names,
 * so only this machine's loopback with an explicit port is accepted:
 * `http:` scheme, no userinfo, no path beyond `/`, no query, no fragment.
 */
export function parseHostBaseURL(raw) {
  if (typeof raw !== 'string' || raw.trim() === '') return null;
  let url;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol !== 'http:') return null;
  if (!LOOPBACK_HOSTS.has(url.hostname.toLowerCase())) return null;
  if (url.port === '') return null;
  if (url.username !== '' || url.password !== '') return null;
  if (url.pathname !== '/' && url.pathname !== '') return null;
  if (url.search !== '' || url.hash !== '') return null;
  return url;
}

/**
 * Parse + shape-check the App-published host record.
 * `record` is null whenever the file is missing or unusable; `problem` names
 * why so `--host` can explain the refusal instead of claiming no file exists.
 */
export function readHostState(home) {
  let text;
  try {
    text = readFileSync(join(home, HOST_FILE_NAME), 'utf8');
  } catch {
    return { record: null, problem: 'no-host-file', detail: '未找到 host.json — App 可能没有运行' };
  }
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { record: null, problem: 'invalid-host-file', detail: 'host.json 不是合法 JSON' };
  }
  if (parsed === null || typeof parsed !== 'object') {
    return { record: null, problem: 'invalid-host-file', detail: 'host.json 不是 JSON 对象' };
  }
  if (parsed.version !== HOST_FILE_VERSION) {
    return {
      record: null,
      problem: 'invalid-host-file',
      detail: `host.json 版本 ${String(parsed.version)} 不受支持（期望 ${HOST_FILE_VERSION}）`,
    };
  }
  if (typeof parsed.token !== 'string' || parsed.token === '') {
    return { record: null, problem: 'invalid-host-file', detail: 'host.json 缺少 token' };
  }
  if (!Number.isInteger(parsed.appPid) || parsed.appPid <= 0) {
    return { record: null, problem: 'invalid-host-file', detail: 'host.json 缺少合法的 appPid' };
  }
  const url = parseHostBaseURL(parsed.baseURL);
  if (!url) {
    return {
      record: null,
      problem: 'invalid-host-file',
      detail: `host.json 的 baseURL 不是本机回环 http 地址（要求 http://127.0.0.1:<port> 形式，带端口、无路径/查询/用户信息）`,
    };
  }
  return {
    record: {
      version: parsed.version,
      baseURL: url.origin,
      token: parsed.token,
      appPid: parsed.appPid,
      startedAt: typeof parsed.startedAt === 'string' ? parsed.startedAt : '',
    },
    problem: null,
  };
}

/** Convenience view of `readHostState`: the record, or null when unusable. */
export function readHostRecord(home) {
  return readHostState(home).record;
}

/** `process.kill(pid, 0)` probe; EPERM still means the pid exists. */
export function isProcessAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === 'EPERM';
  }
}

export class HostUnavailableError extends Error {
  constructor(message, { cause } = {}) {
    super(message, cause ? { cause } : undefined);
    this.name = 'HostUnavailableError';
  }
}

export class HostTimeoutError extends Error {
  constructor(message) {
    super(message);
    this.name = 'HostTimeoutError';
  }
}

/** One cookie name=value pair from a handshake response. */
export function parseAuthCookie(response) {
  const raw = typeof response.headers?.getSetCookie === 'function'
    ? response.headers.getSetCookie()
    : (() => {
        const joined = response.headers?.get?.('set-cookie');
        if (!joined) return [];
        // Split on commas that start a new cookie (Node folds multiple
        // Set-Cookie values into one string when getSetCookie is absent).
        return joined.split(/,(?=\s*[^;,=\s]+=)/);
      })();
  for (const value of raw) {
    const pair = String(value).split(';')[0].trim();
    const equals = pair.indexOf('=');
    if (equals <= 0) continue;
    const name = pair.slice(0, equals);
    const cookieValue = pair.slice(equals + 1);
    if (name.startsWith('dsh-auth-') && cookieValue !== '') return `${name}=${cookieValue}`;
  }
  return null;
}

/** Authenticated loopback client for one Host. */
export class HostClient {
  constructor({ baseURL, token, fetchImpl = globalThis.fetch }) {
    if (typeof fetchImpl !== 'function') throw new HostUnavailableError('fetch 不可用');
    this.baseURL = baseURL;
    this.token = token;
    this.fetchImpl = fetchImpl;
    this.cookie = null;
  }

  static async connect({ baseURL, token, fetchImpl = globalThis.fetch }) {
    const client = new HostClient({ baseURL, token, fetchImpl });
    await client.handshake();
    return client;
  }

  /** GET ?token → 303 + Set-Cookie. Redirects are deliberately not followed. */
  async handshake() {
    let response;
    try {
      response = await this.fetchImpl(`${this.baseURL}/?token=${encodeURIComponent(this.token)}`, {
        redirect: 'manual',
        signal: AbortSignal.timeout(HANDSHAKE_TIMEOUT_MS),
      });
    } catch (error) {
      throw new HostUnavailableError(`握手请求失败：${error.message}`, { cause: error });
    }
    // Undici reports manual redirects as the original status; 3xx other than
    // 303 (e.g. a 302 to a login page) is not this protocol.
    if (response.status !== 303) {
      await response.text().catch(() => {});
      throw new HostUnavailableError(`握手失败：HTTP ${response.status}`);
    }
    const cookie = parseAuthCookie(response);
    if (!cookie) {
      await response.text().catch(() => {});
      throw new HostUnavailableError('握手未返回 dsh-auth cookie');
    }
    this.cookie = cookie;
  }

  /** One POST api/<method>, re-handshaking once on HTTP 401. */
  async call(method, args) {
    let refreshed = false;
    for (;;) {
      const rpcId = randomUUID();
      let response;
      try {
        response = await this.fetchImpl(`${this.baseURL}/api/${method}`, {
          method: 'POST',
          headers: { 'content-type': 'application/json', cookie: this.cookie },
          body: JSON.stringify({
            type: 'client-request',
            rpcId,
            method,
            payload: { args },
          }),
          signal: AbortSignal.timeout(RPC_TIMEOUT_MS),
        });
      } catch (error) {
        throw new HostUnavailableError(`${method} 请求失败：${error.message}`, { cause: error });
      }
      if (response.status === 401) {
        await response.text().catch(() => {});
        if (refreshed) throw new HostUnavailableError(`${method}: 重新握手后仍被拒绝（401）`);
        refreshed = true;
        await this.handshake();
        continue;
      }
      const text = await response.text();
      if (!response.ok) {
        throw new HostUnavailableError(`${method}: HTTP ${response.status} ${text.slice(0, 300)}`);
      }
      let body;
      try {
        body = JSON.parse(text);
      } catch {
        throw new HostUnavailableError(`${method}: 响应不是 JSON`);
      }
      if (body?.type === 'server-response' && body.rpcId && body.rpcId !== rpcId) {
        throw new HostUnavailableError(`${method}: rpcId 不匹配`);
      }
      const result = body?.result;
      if (result?.ok === true) return result.value;
      const error = result?.error ?? {};
      throw new Error(
        `${method}: ${error.code ?? 'rpc-failed'}${error.message ? ` — ${error.message}` : ''}`);
    }
  }

  createSession(cwd) {
    return this.call('session/create', { request: { cwd } });
  }

  /**
   * `request.requestId` is echoed back by the Host as
   * `user/message.data.source.rpcId` (verified against a live Host), which is
   * how a client recognises its own prompt in the log. The envelope `rpcId` is
   * NOT echoed — that one is transport-only.
   */
  async prompt({ sessionId, text, requestId = randomUUID() }) {
    await this.call('session/prompt', {
      request: {
        requestId,
        sessionId,
        mode: 'queue',
        content: [{ type: 'text', text }],
      },
    });
    return { requestId };
  }

  async listSessions() {
    const value = await this.call('session/list', { _request: {} });
    return Array.isArray(value?.items) ? value.items : [];
  }

  projections(sessionId) {
    return this.call('session/projections', { request: { sessionId } });
  }

  page({ sessionId, throughSeq, maxMessages = 200, beforeSeq }) {
    // `beforeSeq: null` is rejected by gateway/input-invalid — omit it. Same
    // for `throughSeq`: a Session whose projections answer `migration-required`
    // has no cursor, so the page must be requested without one rather than
    // sending `undefined` (which JSON would drop) or a stale number.
    const request = {
      address: { kind: 'session', sessionId },
      maxMessages,
      turnWindow: { minMessages: 1, minTurns: 1 },
    };
    if (typeof throughSeq === 'number') request.throughSeq = throughSeq;
    if (typeof beforeSeq === 'number') request.beforeSeq = beforeSeq;
    return this.call('session/page', { request });
  }

  cancel(sessionId) {
    return this.call('session/cancel', { request: { sessionId } });
  }

  /// Mutate one *pending* queue occurrence. `remove` withdraws an item this
  /// client queued without disturbing the turn that is currently running.
  updateQueue({ sessionId, itemId, action }) {
    return this.call('session/updateQueue', { request: { sessionId, itemId, action } });
  }
}

/** Turn-outline entries from a projections payload (never throws on shape). */
export function turnOutlineOf(projections) {
  const value = projections?.values?.turnOutline;
  return Array.isArray(value) ? value : [];
}

/**
 * Read a `session/projections` answer without assuming it is `sequenced`.
 *
 * A Session written by an older Host answers `migration-required` and carries
 * no `asOfSeq`. Sending `session/page` with a missing cursor then fails, so the
 * caller has to know: `cursorAvailable === false` means "page without a
 * cursor" and the outline heuristic is the only ordering evidence available.
 */
export function projectionsState(value) {
  const outline = turnOutlineOf(value);
  const asOfSeq = typeof value?.asOfSeq === 'number' ? value.asOfSeq : null;
  const kind = typeof value?.kind === 'string' ? value.kind : null;
  const migrationRequired = kind === 'migration-required' || asOfSeq === null;
  return { value, outline, asOfSeq, kind, migrationRequired, cursorAvailable: asOfSeq !== null };
}

/**
 * Probe the App-published Host. A missing/invalid file, a dead owner pid, or a
 * failed handshake all mean "not available" — the caller falls back to
 * headless, and `--host` reports the specific `reason`/`detail`.
 */
export async function detectHost({ home, fetchImpl = globalThis.fetch } = {}) {
  const { record, problem, detail } = readHostState(home);
  if (!record) return { available: false, reason: problem, detail };
  if (!isProcessAlive(record.appPid)) {
    return {
      available: false,
      reason: 'stale-pid',
      record,
      detail: `host.json 记录的 appPid ${record.appPid} 已退出`,
    };
  }
  try {
    const client = await HostClient.connect({
      baseURL: record.baseURL,
      token: record.token,
      fetchImpl,
    });
    return { available: true, client, record };
  } catch (error) {
    return { available: false, reason: 'handshake-failed', record, error };
  }
}

/**
 * Transport decision: `--headless` wins, then a reachable Host, otherwise
 * headless — except `--host`, which turns unavailability into an error.
 */
export async function selectMode({
  forceHost = false,
  forceHeadless = false,
  home,
  fetchImpl = globalThis.fetch,
} = {}) {
  if (forceHeadless) return { mode: 'headless', reason: 'forced-headless' };
  const detected = await detectHost({ home, fetchImpl });
  if (detected.available) {
    return { mode: 'host', client: detected.client, record: detected.record };
  }
  if (forceHost) {
    throw new HostUnavailableError(`Host 模式不可用（${describeUnavailable(detected)}）`);
  }
  return { mode: 'headless', reason: detected.reason, error: detected.error, detail: detected.detail };
}

/** Human-readable reason used in diagnostics / forced-mode errors. */
export function describeUnavailable(detected) {
  switch (detected?.reason) {
    case 'no-host-file':
      return detected.detail ?? '未找到 host.json — App 可能没有运行';
    case 'invalid-host-file':
      return detected.detail ?? 'host.json 无效';
    case 'stale-pid':
      return detected.detail ?? `host.json 记录的 appPid ${detected.record?.appPid} 已退出`;
    case 'handshake-failed':
      return `握手失败：${detected.error?.message ?? '未知错误'}`;
    default:
      return detected?.detail ?? '未知原因';
  }
}

/**
 * Whether the log proves this Host echoes prompt ids at all: a `user/message`
 * carrying `source.rpcId`. Hosts that do are claimable by `requestId`; ones
 * that do not require the older turn-outline heuristic.
 */
function hostEchoesRequestIds(page) {
  return pageEvents(page).some(
    (event) => event.type === 'user/message'
      && event.data?.source?.kind === 'user'
      && typeof event.data.source.rpcId === 'string'
      && event.data.source.rpcId !== '');
}

/**
 * Whether this Host's log proves it echoes prompt ids at all.
 *
 * - `'echoes'`: at least one `user/message` carries `source.rpcId`.
 * - `'no-echo'`: there are user messages, none of them carries an id — a Host
 *   that cannot be claimed by `requestId` at all.
 * - `'unknown'`: no user message in view yet (a prompt still queued behind
 *   somebody else's turn), so absence proves nothing.
 */
export function requestIdEchoCapability(page) {
  const messages = pageEvents(page).filter(
    (event) => event.type === 'user/message' && event.data?.source?.kind === 'user');
  if (messages.some((event) => typeof event.data.source.rpcId === 'string' && event.data.source.rpcId !== '')) {
    return 'echoes';
  }
  return messages.length === 0 ? 'unknown' : 'no-echo';
}

/**
 * Withdraw this client's OWN work from a Session, and nothing else.
 *
 * Ctrl-C on a prompt that is still queued behind another client's running turn
 * used to call `session/cancel`, which cancels whatever turn the Session is
 * running — i.e. somebody else's work. So:
 *
 * 1. if our message is still in the pending inbox, remove exactly that item;
 * 2. else, only if the open turn is *ours* (claimed by our `requestId`), cancel
 *    the Session;
 * 3. otherwise leave the Host completely alone and let the caller exit.
 *
 * Never throws: a signal handler has no useful recovery path.
 */
export async function abortOwnTurn(client, { sessionId, requestId } = {}) {
  if (typeof sessionId !== 'string' || sessionId === '') return { action: 'none' };
  if (typeof requestId !== 'string' || requestId === '') return { action: 'none' };
  try {
    const projections = await client.projections(sessionId);
    const inbox = projections?.values?.inbox;
    const pending = [...(inbox?.['next-turn'] ?? []), ...(inbox?.['next-step'] ?? [])];
    const mine = pending.find(
      (message) => message?.source?.rpcId === requestId && typeof message.id === 'string');
    if (mine) {
      try {
        await client.updateQueue({ sessionId, itemId: mine.id, action: { kind: 'remove' } });
        return { action: 'removed' };
      } catch (error) {
        // The queue item can start running between the projections read and
        // the remove. That is not a failure to withdraw our work — the turn is
        // now the open one, so re-claim it and cancel only if it is ours.
        if (!isQueueItemNotFound(error)) throw error;
      }
    }
    return await cancelOwnRunningTurn(client, { sessionId, requestId });
  } catch {
    // Unreachable Host, unknown Session, older Host without updateQueue: the
    // safe move is to leave the queue alone and just exit.
  }
  return { action: 'none' };
}

/** Does this error mean "the pending item already left the queue"? */
function isQueueItemNotFound(error) {
  const code = error?.code ?? error?.errorCode;
  if (code === 'session/queue-item-not-found') return true;
  // HostClient.call flattens the RPC error into `method: code — message`.
  return typeof error?.message === 'string'
    && error.message.includes('session/queue-item-not-found');
}

/** Cancel the Session only when the open turn is provably the one we queued. */
async function cancelOwnRunningTurn(client, { sessionId, requestId }) {
  const projections = await client.projections(sessionId);
  const throughSeq = typeof projections?.asOfSeq === 'number' ? projections.asOfSeq : undefined;
  const page = await client.page({ sessionId, throughSeq, maxMessages: 200 });
  if (claimTurn(page, { requestId }).state === 'running') {
    await client.cancel(sessionId);
    return { action: 'cancelled' };
  }
  return { action: 'none' };
}

/**
 * Poll until THIS invocation's turn ends.
 *
 * Primary evidence is our own `turn/end`: the turn that contains the
 * `user/message` echoing our `requestId` (see `claimTurn`). While that message
 * is absent our prompt is still queued behind somebody else's turn, so the
 * loop keeps waiting instead of settling on a turn it does not own.
 *
 * Fallback (a Host that does not echo prompt ids, or no `requestId`): the
 * older `running` true→false plus turn-outline growth heuristic. Outline
 * growth alone is never completion — it tracks `turn/start`.
 */
export async function waitForTurn(client, {
  sessionId,
  requestId,
  baselineTurns,
  wasRunningBeforePrompt = false,
  pollIntervalMs = DEFAULT_POLL_INTERVAL_MS,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  sleepImpl = sleep,
  now = Date.now,
  onWarning = () => {},
} = {}) {
  const startedAt = now();
  let sawRunning = false;
  let warnedFallback = false;
  let warnedMigration = false;
  let pollCount = 0;
  // Our own turn's identity, remembered once seen so a window that no longer
  // contains our user message still settles on the right `turn/end`.
  let seen = null;
  // Lowest seq already scanned by the "our turn may have come and gone between
  // two polls" search, so repeated polls do not rescan the whole log.
  let searchFloor = null;
  for (;;) {
    pollCount += 1;
    const sessions = await client.listSessions();
    const row = sessions.find((session) => session?.sessionId === sessionId);
    if (!row && sawRunning) throw new Error(`会话 ${sessionId} 在等待期间消失`);
    if (row?.running === true) sawRunning = true;
    const idle = row?.running === false;

    let outline = baselineTurns;
    let projections = null;
    let throughSeq;
    try {
      projections = await client.projections(sessionId);
      const state = projectionsState(projections);
      outline = state.outline.length;
      // `null` for a `migration-required` Session: `client.page()` then omits
      // the cursor instead of failing on a missing `throughSeq`.
      throughSeq = state.asOfSeq ?? undefined;
      if (state.migrationRequired && !warnedMigration) {
        warnedMigration = true;
        onWarning('会话投影要求迁移（migration-required），改用无游标分页 + 轮次轮廓判据');
      }
    } catch {
      // Projections are optional for the fallback path; keep polling.
    }
    const grew = outline > baselineTurns;

    if (requestId && projections !== null && (grew || seen !== null)) {
      // Paging on every poll is wasteful during a long turn: refresh while our
      // message is still unclaimed, while the Session looks idle, and on a slow
      // background probe so a followup that keeps the Session busy cannot hide
      // our terminal event.
      const due = seen === null || idle || pollCount % 10 === 0;
      if (due) {
        const { claim, page, floorSeq } = await claimWithBackfill(client, {
          sessionId,
          throughSeq,
          requestId,
          hint: seen,
          // A prompt queued behind another turn can start and finish between
          // two polls; once the outline grew but our message is nowhere in the
          // window, walk back and look for it.
          search: seen === null && grew,
          floorSeq: searchFloor,
        });
        if (typeof floorSeq === 'number') searchFloor = floorSeq;
        if (claim.state === 'ended') return { projections, row, claim, page };
        if (claim.messageSeq !== undefined) {
          const turnNumber = typeof claim.turnNumber === 'number' ? claim.turnNumber : null;
          seen = { messageSeq: claim.messageSeq, turnNumber };
        }
        if (claim.state === 'missing' && seen === null && !hostEchoesRequestIds(page)) {
          if (!warnedFallback) {
            warnedFallback = true;
            onWarning('Host 未回显 prompt 的 requestId，退回轮次轮廓判据');
          }
          if (idle && grew) return { projections, row, claim: null, page, fallback: true };
        }
        // `running`/`uncovered`: ours is still open or only partly in view.
        // `missing` with echoed ids: still queued behind another turn.
      }
    } else if (!requestId && idle && (grew || (sawRunning && !wasRunningBeforePrompt))) {
      return { projections, row, claim: null, page: null };
    }

    if (timeoutMs > 0 && now() - startedAt > timeoutMs) {
      throw new HostTimeoutError(
        `等待第 ${baselineTurns + 1} 轮结束超时（${Math.round(timeoutMs / 1000)}s）`);
    }
    await sleepImpl(pollIntervalMs);
  }
}

/** Chronological events of a `session/page` payload. */
function pageEvents(page) {
  return (Array.isArray(page?.records) ? page.records : [])
    .map((record) => record?.event ?? record)
    .filter((event) => event && typeof event.seq === 'number')
    .sort((left, right) => left.seq - right.seq);
}

/** Text blocks of one assistant message, joined within the message. */
function assistantMessageText(event) {
  const content = event?.data?.message?.content;
  if (!Array.isArray(content)) return '';
  return content
    .filter((block) => block?.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text)
    .join('');
}

/** Final assistant text of one turn: the last text-bearing `assistant/message`
 * with `turnSeq <= seq < endSeq`. `turnOutline[].response` is a clipped
 * preview and is never used here. */
export function lastTurnAssistantText(page, { turnSeq = 0, endSeq } = {}) {
  const events = pageEvents(page).filter((event) => event.seq >= turnSeq);
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index];
    if (typeof endSeq === 'number' && event.seq >= endSeq) continue;
    if (event.type !== 'assistant/message') continue;
    const text = assistantMessageText(event);
    if (text !== '') return text;
  }
  return '';
}

/**
 * Locate THIS invocation's turn by the `requestId` we sent with
 * `session/prompt`, which the Host echoes as `user/message.data.source.rpcId`
 * (verified against a live Host; the transport `rpcId` is never echoed).
 *
 * Attribution is by TURN NUMBER, not seq window: every `assistant/message` and
 * `turn/end` carries `data.turn` (verified), so once our user message's turn is
 * known the reply is every text block of that turn — even when another client's
 * turn opened right behind ours inside the same page window.
 *
 * `state` is `missing` (our message is not in this window — still queued, the
 * window trimmed it, or a Host that does not echo), `running` (ours, no
 * `turn/end` yet) or `ended`.
 *
 * `hint` (`{messageSeq, turnNumber}`) is what a previous `claimTurn` call in the
 * same wait already established; it keeps the turn claimable after our own user
 * message scrolled out of a bounded page window. A hint is never trusted on its
 * own: the turn number must still show up in this window.
 */
export function claimTurn(page, { requestId, hint } = {}) {
  if (typeof requestId !== 'string' || requestId === '') {
    return { state: 'missing', reason: 'no-request-id' };
  }
  const events = pageEvents(page);
  const matched = events.find(
    (event) => event.type === 'user/message' && event.data?.source?.kind === 'user'
      && event.data?.source?.rpcId === requestId);

  let anchorSeq;
  let turnNumber;
  let fromHint = false;
  if (matched) {
    anchorSeq = matched.seq;
    // Our message lives inside our turn, so the closest preceding turn/start
    // owns it. A trimmed window may not show that boundary; then only the seq
    // window is available (see below).
    const turnStart = events.filter((event) => event.type === 'turn/start' && event.seq < matched.seq).at(-1);
    turnNumber = typeof turnStart?.data?.turn === 'number' ? turnStart.data.turn : null;
  } else if (hint && typeof hint.messageSeq === 'number' && typeof hint.turnNumber === 'number') {
    anchorSeq = hint.messageSeq;
    turnNumber = hint.turnNumber;
    fromHint = true;
  } else {
    return { state: 'missing' };
  }

  // The Host pages by TURN: with `turnWindow.minTurns` a window holds only the
  // last turn(s), so once a later turn opens our own leaves the window. A hint
  // alone is therefore not evidence — it must be backed by an event of that
  // turn number in the page we are looking at.
  if (fromHint && !events.some((event) => event.data?.turn === turnNumber)) {
    return { state: 'uncovered', messageSeq: anchorSeq, turnNumber, text: '' };
  }

  // Turn numbers are the identity: `assistant/message` and `turn/end` both
  // carry `data.turn` (verified), so a neighbouring client's turn that opened
  // inside the same window cannot leak into our reply.
  if (turnNumber !== null) {
    return { ...claimTurnByNumber(page, turnNumber), messageSeq: anchorSeq };
  }
  // No turn boundary in view: fall back to the seq window, which is still sound
  // because the Host only writes a queued prompt's user message when its turn
  // actually starts.
  const turnEnd = events.find((event) => event.type === 'turn/end' && event.seq > anchorSeq) ?? null;
  let text = '';
  for (const event of events) {
    if (event.type !== 'assistant/message') continue;
    if (event.seq < anchorSeq) continue;
    if (turnEnd !== null && event.seq >= turnEnd.seq) continue;
    const candidate = assistantMessageText(event);
    if (candidate !== '') text = candidate;
  }
  return {
    state: turnEnd ? 'ended' : 'running',
    messageSeq: anchorSeq,
    turnNumber: null,
    turnStartSeq: null,
    turnEndSeq: turnEnd?.seq ?? null,
    reason: turnEnd?.data?.reason?.kind ?? null,
    text,
  };
}

/**
 * Claim a turn purely by its number — the identity `--attach` uses when the
 * caller has no `requestId` (the Session already holds the turn we want).
 */
export function claimTurnByNumber(page, turnNumber) {
  if (typeof turnNumber !== 'number') {
    return { state: 'missing', turnNumber: null, turnStartSeq: null, turnEndSeq: null, reason: null, text: '' };
  }
  const events = pageEvents(page);
  const owned = events.filter((event) => event.data?.turn === turnNumber);
  if (owned.length === 0) {
    return { state: 'missing', turnNumber, turnStartSeq: null, turnEndSeq: null, reason: null, text: '' };
  }
  const turnEnd = owned.find((event) => event.type === 'turn/end') ?? null;
  const turnStartSeq = owned.find((event) => event.type === 'turn/start')?.seq ?? null;
  let text = '';
  for (const event of owned) {
    if (event.type !== 'assistant/message') continue;
    if (turnEnd !== null && event.seq >= turnEnd.seq) continue;
    const candidate = assistantMessageText(event);
    if (candidate !== '') text = candidate;
  }
  return {
    state: turnEnd ? 'ended' : 'running',
    turnNumber,
    turnStartSeq,
    turnEndSeq: turnEnd?.seq ?? null,
    reason: turnEnd?.data?.reason?.kind ?? null,
    text,
  };
}

/**
 * `claimTurnByNumber` with backward paging: the Host's page window holds only
 * the newest turn(s), so a turn we are watching can slide out of view while it
 * is still running. Walk `beforeSeq` back until the turn number is covered.
 */
export async function claimTurnByNumberWithBackfill(client, {
  sessionId,
  throughSeq,
  turnNumber,
  maxPages = 40,
}) {
  const firstPage = await client.page({ sessionId, throughSeq });
  let records = [...(Array.isArray(firstPage?.records) ? firstPage.records : [])];
  const covers = () => pageEvents({ records }).some((event) => event.data?.turn === turnNumber);
  let claim = claimTurnByNumber({ records }, turnNumber);
  if (claim.state !== 'missing') return { claim, page: { records } };
  let beforeSeq = records[0]?.event?.seq ?? records[0]?.seq;
  for (let index = 0; index < maxPages; index += 1) {
    if (typeof beforeSeq !== 'number') break;
    const page = await client.page({ sessionId, throughSeq, beforeSeq, maxMessages: 200 });
    const batch = Array.isArray(page?.records) ? page.records : [];
    if (batch.length === 0) break;
    records = [...batch, ...records];
    claim = claimTurnByNumber({ records }, turnNumber);
    if (claim.state !== 'missing') break;
    if (page?.hasMore !== true) break;
    beforeSeq = batch[0]?.event?.seq ?? batch[0]?.seq;
  }
  return { claim, page: { records } };
}

/**
 * `claimTurn` plus whatever paging is needed to get our turn into view.
 *
 * Two distinct gaps need different walks:
 *
 * - `uncovered` / hinted-`missing`: we already matched our message once, but
 *   the window has since slid past our turn (the Host pages by TURN). Walk back
 *   until the hinted turn number is covered again.
 * - `search`: our message was never seen at all — a prompt queued behind
 *   another turn can start and finish entirely between two polls. Walk back
 *   until the `requestId` shows up, bounded by nothing more than a page cap.
 *
 * `floorSeq` is the lowest seq already scanned for `search`, so repeated polls
 * do not rescan the whole log.
 */
export async function claimWithBackfill(client, {
  sessionId,
  throughSeq,
  requestId,
  hint = null,
  search = false,
  floorSeq = null,
  maxPages = 40,
}) {
  const firstPage = await client.page({ sessionId, throughSeq });
  let claim = claimTurn(firstPage, { requestId, hint });
  const hinted = hint !== null && hint !== undefined && typeof hint.messageSeq === 'number';
  // A search is only worth its pages when this Host echoes prompt ids at all:
  // on one that does not, walking back cannot ever find our message.
  const searchable = search && hostEchoesRequestIds(firstPage);
  const needsWalk = claim.state === 'uncovered'
    || (claim.state === 'missing' && hinted)
    || (claim.state === 'missing' && searchable && !hinted);
  if (!needsWalk) return { claim, page: firstPage, floorSeq };

  const records = [...(Array.isArray(firstPage?.records) ? firstPage.records : [])];
  let floor = floorSeq;
  let beforeSeq = records[0]?.event?.seq ?? records[0]?.seq;
  for (let index = 0; index < maxPages; index += 1) {
    if (typeof beforeSeq !== 'number') break;
    if (typeof floorSeq === 'number' && beforeSeq <= floorSeq) break;
    const page = await client.page({ sessionId, throughSeq, beforeSeq, maxMessages: 200 });
    const batch = Array.isArray(page?.records) ? page.records : [];
    if (batch.length === 0) break;
    records.unshift(...batch);
    const earliest = batch[0]?.event?.seq ?? batch[0]?.seq;
    if (typeof earliest === 'number') {
      floor = typeof floor === 'number' ? Math.min(floor, earliest) : earliest;
      beforeSeq = earliest;
    } else {
      beforeSeq = undefined;
    }
    const walked = claimTurn({ records }, { requestId, hint });
    // Stop as soon as the walk answered the question it was started for.
    if (walked.state === 'ended') return { claim: walked, page: { records }, floorSeq: floor };
    if (walked.state === 'running') return { claim: walked, page: { records }, floorSeq: floor };
    if (walked.state === 'ended' || walked.messageSeq !== undefined) {
      return { claim: walked, page: { records }, floorSeq: floor };
    }
    if (page?.hasMore !== true) break;
  }
  return { claim: claimTurn({ records }, { requestId, hint }), page: { records }, floorSeq: floor };
}

/** Terminal `turn/end` reason kind for the turn, when the window holds it. */
export function turnEndReason(page, { turnSeq = 0, endSeq } = {}) {
  const events = pageEvents(page);
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index];
    if (event.seq < turnSeq) break;
    if (typeof endSeq === 'number' && event.seq >= endSeq) continue;
    if (event.type === 'turn/end') return event.data?.reason?.kind ?? null;
  }
  return null;
}
/**
 * Backwards read that walks `beforeSeq` until the turn start is covered and
 * returns every record it saw. Bounded by a page cap so a pathological log
 * cannot spin forever.
 */
async function readBackwardsRecords(client, { sessionId, throughSeq, turnSeq, maxPages = 40 }) {
  const records = [];
  let beforeSeq;
  for (let index = 0; index < maxPages; index += 1) {
    const page = await client.page({ sessionId, throughSeq, beforeSeq, maxMessages: 200 });
    const batch = Array.isArray(page?.records) ? page.records : [];
    if (batch.length === 0) break;
    records.unshift(...batch);
    const earliest = batch[0]?.event?.seq ?? batch[0]?.seq;
    if (page?.hasMore !== true || typeof earliest !== 'number') break;
    beforeSeq = earliest;
    if (earliest <= turnSeq) break;
  }
  return records;
}

/**
 * Drive one full turn over the Host and return the complete final reply.
 * `sessionId` set means "continue this Session" and skips session/create.
 *
 * The reply is claimed by `requestId` (echoed by the Host as the user
 * message's `source.rpcId`), so a prompt queued behind another client's turn
 * can no longer be confused with that turn. If this Host does not echo prompt
 * ids the older turn-outline heuristic takes over and `onWarning` says so.
 */
export async function runHostTask(client, {
  task,
  cwd = process.cwd(),
  sessionId: requestedSessionId,
  requestId = randomUUID(),
  pollIntervalMs = DEFAULT_POLL_INTERVAL_MS,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  sleepImpl = sleep,
  now = Date.now,
  onSession = () => {},
  onPrompt = () => {},
  onEvent = () => {},
  onWarning = () => {},
} = {}) {
  let sessionId = requestedSessionId;
  let resolvedCwd = resolve(cwd);
  if (!sessionId) {
    const created = await client.createSession(resolvedCwd);
    if (typeof created?.sessionId !== 'string' || created.sessionId === '') {
      throw new Error('session/create 未返回 sessionId');
    }
    sessionId = created.sessionId;
  }

  // Announce the Session as soon as its identity is known: a --json consumer
  // needs the first `session` line before any turn progress, and the CLI's
  // SIGINT handler can only cancel a Session it has been told about.
  const announcement = { sessionId, cwd: resolvedCwd, via: 'host' };
  onSession(announcement);

  const before = await client.projections(sessionId);
  const baselineTurns = turnOutlineOf(before).length;
  const sessionsBefore = await client.listSessions();
  const previous = sessionsBefore.find((session) => session?.sessionId === sessionId);
  const wasRunningBeforePrompt = previous?.running === true;
  // A continued Session reports its own workspace; new Sessions use cwd.
  if (requestedSessionId && typeof previous?.cwd === 'string' && previous.cwd !== '') {
    resolvedCwd = previous.cwd;
  }

  // The id is minted by the caller (`ds-agent`'s signal handler needs it before
  // `session/prompt` returns) and announced once the Host accepted the prompt.
  await client.prompt({ sessionId, text: task, requestId });
  onPrompt({ sessionId, requestId });

  const { projections, claim, page: settledPage } = await waitForTurn(client, {
    sessionId,
    requestId,
    baselineTurns,
    wasRunningBeforePrompt,
    pollIntervalMs,
    timeoutMs,
    sleepImpl,
    now,
    onWarning,
  });

  const outline = turnOutlineOf(projections);
  const throughSeq = typeof projections?.asOfSeq === 'number' ? projections.asOfSeq : undefined;
  const page = settledPage ?? (await client.page({ sessionId, throughSeq }));
  let text = '';
  let reason = null;
  let turnSeq = 0;

  if (claim) {
    text = claim.text;
    reason = claim.reason;
    turnSeq = claim.turnStartSeq ?? claim.messageSeq;
    if (text === '' && claim.reason === 'completed' && claim.turnEndSeq !== null) {
      // Defensive: a turn that completed but whose text we could not read from
      // the (possibly trimmed) window. Walk back once more and re-claim.
      const records = await readBackwardsRecords(client, {
        sessionId,
        throughSeq,
        turnSeq: claim.messageSeq,
      });
      const wider = claimTurn({ records }, { requestId });
      if (wider.text !== '') {
        text = wider.text;
        reason = wider.reason ?? reason;
        turnSeq = wider.turnStartSeq ?? wider.messageSeq;
      }
    }
  } else {
    // Fallback: no prompt-id echo. Our turn is the first outline entry beyond
    // the baseline; a followup queued right behind ours may already have
    // opened its own entry, whose seq bounds ours.
    const finalTurn = outline[baselineTurns] ?? null;
    const nextTurnSeq = outline[baselineTurns + 1]?.seq;
    turnSeq = typeof finalTurn?.seq === 'number' ? finalTurn.seq : 0;
    text = lastTurnAssistantText(page, { turnSeq, endSeq: nextTurnSeq });
    if (text === '' && page?.hasMore === true) {
      const records = await readBackwardsRecords(client, { sessionId, throughSeq, turnSeq });
      text = lastTurnAssistantText({ records }, { turnSeq, endSeq: nextTurnSeq });
    }
    reason = turnEndReason(page, { turnSeq, endSeq: nextTurnSeq });
  }

  for (const event of text ? [{ type: 'text', text }] : []) onEvent(event);
  return {
    sessionId,
    cwd: resolvedCwd,
    requestId,
    text,
    reason,
    turnSeq,
    turnCount: outline.length,
    via: 'host',
  };
}

/**
 * Follow an existing Session without prompting — `ds-agent --attach`.
 *
 * With `requestId`: claim exactly that turn (returns at once if it already
 * ended, waits while it runs, keeps waiting while it is still queued). Without
 * it: observe the Session until its current turn really ran, then report that
 * turn's reply; a Session that was already idle returns its last turn.
 *
 * The already-idle case cannot be decided from one poll: a prompt accepted a
 * moment ago is neither `running` nor in the log yet, and reporting the
 * previous turn as the answer would be silently wrong. So "idle and nothing
 * happened" only settles after `settlePolls` consecutive idle observations,
 * and a turn that was observed running (or that made the outline grow) always
 * wins over that shortcut. The same bound ends a wait that can never succeed:
 * an idle turn whose terminal event still cannot be claimed, and (with
 * `requestId`) an idle Session whose log never shows any prompt at all.
 */
export async function attachToTurn(client, {
  sessionId,
  requestId,
  pollIntervalMs = DEFAULT_POLL_INTERVAL_MS,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  settlePolls = ATTACH_SETTLE_POLLS,
  sleepImpl = sleep,
  now = Date.now,
  onWarning = () => {},
} = {}) {
  if (typeof sessionId !== 'string' || sessionId === '') {
    throw new Error('--attach 需要一个会话 id');
  }
  const startedAt = now();
  const first = await client.projections(sessionId);
  const baseline = projectionsState(first);
  const sessions = await client.listSessions();
  const initialRow = sessions.find((session) => session?.sessionId === sessionId);
  if (!initialRow) throw new Error(`会话 ${sessionId} 不存在`);
  const baselineTurns = baseline.outline.length;

  let sawRunning = initialRow.running === true;
  let sawGrowth = false;
  let idleStreak = 0;
  /// Consecutive idle observations that saw the turn in the outline but could
  /// not claim its terminal event. Bounded like `idleStreak` so the unlimited
  /// default wait still ends with an error instead of hanging forever.
  let unsettledStreak = 0;
  let warnedMigration = false;
  let seen = null;
  let searchFloor = null;
  let pollCount = 0;

  for (;;) {
    pollCount += 1;
    const list = await client.listSessions();
    const row = list.find((session) => session?.sessionId === sessionId);
    if (!row) throw new Error(`会话 ${sessionId} 在等待期间消失`);
    if (row.running === true) sawRunning = true;
    const idle = row.running === false;

    let projections = null;
    let outline = baseline.outline;
    let throughSeq;
    try {
      projections = await client.projections(sessionId);
      const state = projectionsState(projections);
      outline = state.outline;
      throughSeq = state.asOfSeq ?? undefined;
      if (state.migrationRequired && !warnedMigration) {
        warnedMigration = true;
        onWarning('会话投影要求迁移（migration-required），改用无游标分页 + 轮次轮廓判据');
      }
    } catch {
      // Projections are optional; keep polling.
    }
    if (outline.length > baselineTurns) sawGrowth = true;

    if (requestId) {
      const due = seen === null || idle || pollCount % 10 === 0;
      if (due) {
        const { claim, page, floorSeq } = await claimWithBackfill(client, {
          sessionId,
          throughSeq,
          requestId,
          hint: seen,
          search: seen === null && (sawGrowth || sawRunning),
          floorSeq: searchFloor,
        });
        if (typeof floorSeq === 'number') searchFloor = floorSeq;
        if (claim.state === 'ended') {
          return settleAttachResult({ sessionId, requestId, row, projections, claim, page });
        }
        if (claim.messageSeq !== undefined) {
          seen = {
            messageSeq: claim.messageSeq,
            turnNumber: typeof claim.turnNumber === 'number' ? claim.turnNumber : null,
          };
        }
        // Echoed ids but never seen, with the Session idle and nothing having
        // run since we started: this requestId is not in this Session's log.
        if (claim.state === 'missing' && seen === null && idle && !sawGrowth
          && pollCount > settlePolls) {
          const echo = requestIdEchoCapability(page);
          if (echo === 'no-echo') {
            // Waiting here would never end: without a prompt-id echo the Host
            // gives a client no way to recognise its own message.
            throw new Error(
              `Host 没有回显 prompt 的 requestId，无法按 requestId 接回回合（会话 ${sessionId}）；`
              + '请改用不带 --request-id 的 --attach');
          }
          if (echo === 'echoes') {
            throw new Error(`会话 ${sessionId} 中找不到 requestId ${requestId} 对应的回合`);
          }
          // `unknown`: no user message at all in view. While the Session is
          // running our prompt may just be queued behind somebody else's turn,
          // so the loop keeps waiting (that branch is above this `idle` check).
          // An IDLE Session that never shows any user message, even after
          // `settlePolls` observations with no growth, has no such requestId.
          throw new Error(
            `会话 ${sessionId} 中找不到 requestId ${requestId} 对应的回合：`
            + '会话已空闲且日志没有增长（Host 也未回显任何 prompt 的 requestId）');
        }
      }
    } else {
      // No requestId: wait for the Session to settle on a turn we watched run.
      idleStreak = idle ? idleStreak + 1 : 0;
      const ranSinceStart = sawRunning || sawGrowth;
      // Only an idle observation counts toward "this turn will never settle".
      if (!idle) unsettledStreak = 0;
      if (idle && ranSinceStart) {
        // Turn numbers are 1-based and the outline has one entry per turn, so
        // the newest entry's number is simply its count.
        const { claim, page } = await claimTurnByNumberWithBackfill(client, {
          sessionId,
          throughSeq,
          turnNumber: outline.length,
        });
        if (claim.state === 'ended') {
          return settleAttachResult({ sessionId, requestId: null, row, projections, claim, page });
        }
        // The outline has the turn but its terminal event is not written yet.
        // That is normal for a poll or two; an idle Session that keeps failing
        // to give us the end event is not going to produce one, and waiting
        // forever (the default) would hang the CLI.
        unsettledStreak = idle ? unsettledStreak + 1 : 0;
        if (unsettledStreak >= settlePolls) {
          throw new Error(
            `没有取到最后一轮的完整回复（会话 ${sessionId}，回合 ${outline.length}）：`
            + `会话已空闲但日志中找不到该轮结束事件（claim=${claim.state}），`
            + '请稍后重试或使用 --request-id');
        }
      } else if (idle && idleStreak >= settlePolls) {
        // Nothing ran and nothing is queued: report the Session's last turn.
        const turnNumber = outline.length;
        const { claim, page } = await claimTurnByNumberWithBackfill(client, {
          sessionId,
          throughSeq,
          turnNumber,
        });
        // An empty reply with exit 0 is never right: if the turn cannot be
        // claimed as ended we did not actually read it, so say so.
        if (claim.state === 'ended') {
          return settleAttachResult({ sessionId, requestId: null, row, projections, claim, page });
        }
        throw new Error(
          `没有取到最后一轮的完整回复（会话 ${sessionId}，回合 ${turnNumber}）：`
          + `日志中找不到该轮结束事件（claim=${claim.state}），请稍后重试或使用 --request-id`);
      }
    }

    if (timeoutMs > 0 && now() - startedAt > timeoutMs) {
      throw new HostTimeoutError(
        `等待会话 ${sessionId} 的回合结束超时（${Math.round(timeoutMs / 1000)}s）`);
    }
    await sleepImpl(pollIntervalMs);
  }
}

/** Shape the `--attach` result like `runHostTask`'s, so the CLI prints it the same way. */
function settleAttachResult({ sessionId, requestId, row, projections, claim, page }) {
  return {
    sessionId,
    cwd: typeof row?.cwd === 'string' ? row.cwd : undefined,
    requestId: requestId ?? null,
    text: claim?.text ?? '',
    reason: claim?.reason ?? null,
    turnSeq: claim?.turnStartSeq ?? claim?.messageSeq ?? 0,
    turnCount: turnOutlineOf(projections).length,
    via: 'host',
    attached: true,
    page,
  };
}
