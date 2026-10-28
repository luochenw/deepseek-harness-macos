// Tests for the `ds-agent` Host bridge (scripts/ds-agent-host.mjs) and the CLI
// entry's mode selection. A fake Host speaks the same handshake + RPC shapes as
// the real DSH 0.2 Web Host — including echoing a prompt's `requestId` back as
// `user/message.data.source.rpcId` and serialising queued prompts into turns —
// so create → prompt → wait → page is exercised without the App.
//
//   node --test scripts/ds-agent.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

import {
  DEFAULT_TIMEOUT_MS,
  HostClient,
  HostUnavailableError,
  abortOwnTurn,
  attachToTurn,
  claimTurn,
  claimWithBackfill,
  detectHost,
  isProcessAlive,
  lastTurnAssistantText,
  parseAuthCookie,
  parseHostBaseURL,
  readHostRecord,
  parseDuration,
  readHostState,
  requestIdEchoCapability,
  runHostTask,
  selectMode,
  waitForTurn,
} from './ds-agent-host.mjs';

const CLI = fileURLToPath(new URL('./ds-agent', import.meta.url));
const AUTH_NAME = 'dsh-auth-test';
const AUTH_VALUE = 'cookie-secret';

/**
 * Fake Host with queueing semantics: each `session/prompt` joins a queue, and
 * `session/list` starts the next turn when the Session is idle. `runningPolls`
 * is how many polls a running turn stays running (large ⇒ never finishes);
 * `finishImmediately` starts and ends a turn inside one poll, modelling a turn
 * too fast to ever observe `running: true`. `pageMaxMessages` caps a page
 * window so backwards paging is testable. `echoRequestId: false` models a Host
 * that does not echo prompt ids (the fallback path).
 */
function startFakeHost({
  token = 'launch-token',
  runningPolls = 2,
  finishImmediately = false,
  pageMaxMessages = Infinity,
  pageWindowTurns = Infinity,
  echoRequestId = true,
  migrationRequired = false,
  replyFor = (text) => `回复：${text}`,
  // Delay the `session/prompt` response (the prompt is still recorded and
  // queued): models Ctrl-C landing while the request is in flight.
  promptResponseDelayMs = 0,
  // Make `session/updateQueue`'s remove lose the race: the queue item starts
  // running and the Host answers `session/queue-item-not-found`.
  loseQueueItemToRunning = false,
  // Finish turns in the log WITHOUT the terminal `turn/end` event.
  omitTurnEnd = false,
} = {}) {
  const state = {
    handshakes: 0,
    calls: [],
    prompts: [],
    cancelled: [],
    removed: [],
    sessions: new Map(),
  };

  const nextSeq = (session) => {
    session.seq += 1;
    return session.seq;
  };
  const push = (session, event) => session.records.push({ type: 'event', event });

  const startTurn = (session) => {
    const queued = session.pending.shift();
    session.running = true;
    session.polls = 0;
    session.current = queued;
    const turn = session.outline.length + 1;
    const turnSeq = nextSeq(session);
    push(session, { type: 'turn/start', seq: turnSeq, data: { turn } });
    push(session, {
      type: 'user/message',
      seq: nextSeq(session),
      data: {
        content: [{ type: 'text', text: queued.text }],
        source: echoRequestId ? { kind: 'user', rpcId: queued.requestId } : { kind: 'user' },
        role: 'user',
        id: `msg-${randomUUID()}`,
      },
    });
    session.turnNumber = turn;
    session.turnSeq = turnSeq;
  };

  const finishTurn = (session) => {
    const text = replyFor(session.current?.text ?? '');
    push(session, {
      type: 'assistant/message',
      seq: nextSeq(session),
      data: {
        turn: session.turnNumber,
        step: 1,
        message: { role: 'assistant', content: [{ type: 'text', text }] },
      },
    });
    if (!omitTurnEnd) {
      push(session, {
        type: 'turn/end',
        seq: nextSeq(session),
        data: { turn: session.turnNumber, reason: { kind: 'completed' } },
      });
    }
    session.outline.push({
      turn: session.turnNumber,
      seq: session.turnSeq,
      prompt: (session.current?.text ?? '').slice(0, 50),
      // Deliberately a clipped preview: the client must not read this.
      response: text.slice(0, 6),
    });
    session.running = false;
    session.current = null;
  };

  /** Advance every Session by one poll, mirroring the Host's turn driver. */
  const advance = () => {
    for (const session of state.sessions.values()) {
      if (session.running) {
        session.polls += 1;
        if (session.polls > runningPolls) finishTurn(session);
        continue;
      }
      if (session.pending.length === 0) continue;
      startTurn(session);
      if (finishImmediately) finishTurn(session);
    }
  };

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (req.method === 'GET' && url.pathname === '/') {
      if (url.searchParams.get('token') !== token) {
        res.writeHead(403).end('forbidden');
        return;
      }
      state.handshakes += 1;
      res.writeHead(303, {
        location: '/',
        'set-cookie': `${AUTH_NAME}=${AUTH_VALUE}; Path=/; HttpOnly; SameSite=Lax`,
      });
      res.end();
      return;
    }
    if (req.method !== 'POST' || !url.pathname.startsWith('/api/')) {
      res.writeHead(404).end('not found');
      return;
    }
    const cookie = req.headers.cookie ?? '';
    if (!cookie.split(';').map((part) => part.trim()).includes(`${AUTH_NAME}=${AUTH_VALUE}`)) {
      res.writeHead(401).end('unauthorized');
      return;
    }
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    const method = url.pathname.slice('/api/'.length);
    state.calls.push({ method, cookie, body });
    const args = body?.payload?.args ?? {};
    const reply = (value) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ type: 'server-response', rpcId: body.rpcId, result: { ok: true, value } }));
    };
    const fail = (code, message) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        type: 'server-response',
        rpcId: body.rpcId,
        result: { ok: false, error: { code, message } },
      }));
    };

    switch (method) {
      case 'session/create': {
        const sessionId = `session-${randomUUID()}`;
        state.sessions.set(sessionId, {
          sessionId,
          cwd: args.request?.cwd,
          running: false,
          polls: 0,
          outline: [],
          records: [],
          pending: [],
          seq: 0,
          current: null,
          turnNumber: 0,
          turnSeq: 0,
        });
        reply({ sessionId, agentPreset: 'standard' });
        return;
      }
      case 'session/prompt': {
        const session = state.sessions.get(args.request?.sessionId);
        if (!session) {
          fail('not-found', String(args.request?.sessionId));
          return;
        }
        const text = args.request?.content?.[0]?.text ?? '';
        const requestId = args.request?.requestId ?? null;
        state.prompts.push({ sessionId: session.sessionId, text, requestId });
        session.pending.push({ text, requestId, itemId: `item-${randomUUID()}` });
        if (promptResponseDelayMs > 0) {
          setTimeout(() => reply({ accepted: true }), promptResponseDelayMs);
          return;
        }
        reply({ accepted: true });
        return;
      }
      case 'session/list': {
        advance();
        reply({
          items: [...state.sessions.values()].map((session) => ({
            sessionId: session.sessionId,
            cwd: session.cwd,
            running: session.running,
            updatedAt: 1,
          })),
        });
        return;
      }
      case 'session/projections': {
        const session = state.sessions.get(args.request?.sessionId);
        if (!session) {
          reply(null);
          return;
        }
        // A Session from an older Host answers `migration-required` with no
        // cursor at all — `session/page` then has to cope without `throughSeq`.
        const inbox = {
          'next-turn': session.pending.map((entry) => ({
            id: entry.itemId,
            role: 'user',
            content: [{ type: 'text', text: entry.text }],
            source: echoRequestId
              ? { kind: 'user', rpcId: entry.requestId }
              : { kind: 'user' },
          })),
          'next-step': [],
        };
        reply(migrationRequired
          ? { kind: 'migration-required', values: { turnOutline: session.outline, inbox } }
          : {
              kind: 'sequenced',
              asOfSeq: session.seq,
              values: { turnOutline: session.outline, inbox },
            });
        return;
      }
      case 'session/page': {
        const session = state.sessions.get(args.request?.address?.sessionId);
        const request = args.request ?? {};
        if (request.beforeSeq === null) {
          fail('gateway/input-invalid', 'beforeSeq must not be null');
          return;
        }
        // Mirror the real Host: the page is cut by TURN (`turnWindow`), so a
        // window holds only the newest turns; `hasMore` is true when older
        // records exist beyond it. `maxMessages` trims further.
        const maxMessages = Math.min(request.maxMessages ?? 200, pageMaxMessages);
        const all = session?.records ?? [];
        const beforeSeq = request.beforeSeq;
        const inRange = all.filter((record) => {
          const seq = record.event.seq;
          if (typeof request.throughSeq === 'number' && seq > request.throughSeq) return false;
          if (typeof beforeSeq === 'number' && seq >= beforeSeq) return false;
          return true;
        });
        let eligible = inRange;
        if (Number.isFinite(pageWindowTurns)) {
          const turnStarts = inRange.filter((record) => record.event.type === 'turn/start');
          if (turnStarts.length > pageWindowTurns) {
            const cut = turnStarts[turnStarts.length - pageWindowTurns].event.seq;
            eligible = inRange.filter((record) => record.event.seq >= cut);
          }
        }
        const window = eligible.slice(Math.max(0, eligible.length - maxMessages));
        reply({ records: window, hasMore: window.length < inRange.length });
        return;
      }
      case 'session/cancel': {
        state.cancelled.push(args.request?.sessionId);
        const session = state.sessions.get(args.request?.sessionId);
        if (session) session.running = false;
        reply({ accepted: true });
        return;
      }
      case 'session/updateQueue': {
        const session = state.sessions.get(args.request?.sessionId);
        const item = session?.pending.find((entry) => entry.itemId === args.request?.itemId);
        if (!session || !item) {
          fail('session/queue-item-not-found', String(args.request?.itemId));
          return;
        }
        if (args.request?.action?.kind !== 'remove') {
          fail('gateway/bad-request', 'only remove is modelled');
          return;
        }
        // The real Host can promote the pending item to the running turn
        // between our projections read and this remove; the remove then fails
        // because the item is no longer in the queue.
        if (loseQueueItemToRunning && session.pending[0] === item) {
          startTurn(session);
          fail('session/queue-item-not-found', item.itemId);
          return;
        }
        session.pending = session.pending.filter((entry) => entry !== item);
        state.removed.push(item.itemId);
        reply({ accepted: true });
        return;
      }
      default:
        res.writeHead(404).end('unknown method');
    }
  });

  return new Promise((resolve, reject) => {
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const baseURL = `http://127.0.0.1:${server.address().port}`;
      resolve({
        state,
        baseURL,
        /** Seed a turn that is not ours (another client's queued prompt). */
        seedForeignPrompt(sessionId, text = '别人的任务') {
          const session = state.sessions.get(sessionId);
          session.pending.push({ text, requestId: `foreign-${randomUUID()}`, itemId: `item-${randomUUID()}` });
          return session;
        },
        close: () => new Promise((done) => server.close(done)),
        writeHostFile(home, overrides = {}) {
          writeFileSync(join(home, 'host.json'), JSON.stringify({
            version: 1,
            baseURL,
            token,
            appPid: process.pid,
            startedAt: new Date().toISOString(),
            ...overrides,
          }));
        },
      });
    });
  });
}

function tempHome() {
  return mkdtempSync(join(tmpdir(), 'ds-agent-test-'));
}

function runCli(args, { home, env = {}, input } = {}) {
  return new Promise((resolve) => {
    // A developer/CI environment may export DS_AGENT_TIMEOUT_MS; inheriting it
    // would silently time-box the "no timeout by default" cases under test.
    const inherited = { ...process.env };
    delete inherited.DS_AGENT_TIMEOUT_MS;
    const child = spawn(process.execPath, [CLI, ...args], {
      env: { ...inherited, DSH_HOME: home, ...env },
      stdio: [input === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'],
    });
    if (input !== undefined) child.stdin.end(input);
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('exit', (code, signal) => resolve({ code, signal, stdout, stderr }));
  });
}

// ---------------------------------------------------------------- helpers ---

test('parseAuthCookie picks the dsh-auth cookie out of Set-Cookie', () => {
  const response = {
    headers: {
      getSetCookie: () => ['other=1; Path=/', `${AUTH_NAME}=${AUTH_VALUE}; Path=/; HttpOnly`],
    },
  };
  assert.equal(parseAuthCookie(response), `${AUTH_NAME}=${AUTH_VALUE}`);
  assert.equal(parseAuthCookie({ headers: { getSetCookie: () => ['other=1'] } }), null);
});

test('parseHostBaseURL accepts only a loopback http origin with a port', () => {
  for (const good of [
    'http://127.0.0.1:8080',
    'http://127.0.0.1:8080/',
    'http://[::1]:8080',
    'http://localhost:9000',
    'http://LOCALHOST:9000',
  ]) {
    assert.ok(parseHostBaseURL(good), `expected valid: ${good}`);
  }
  for (const bad of [
    'https://127.0.0.1:8080',           // not http
    'http://example.com:8080',          // not loopback
    'http://127.0.0.1.nip.io:8080',     // resolves elsewhere
    'http://127.0.0.1',                 // no port
    'http://127.0.0.1:8080/api',        // path
    'http://user:pw@127.0.0.1:8080',    // userinfo
    'http://127.0.0.1:8080/?token=1',   // query
    'http://127.0.0.1:8080/#x',         // fragment
    'file:///etc/passwd',
    'not a url',
    '',
    null,
    undefined,
  ]) {
    assert.equal(parseHostBaseURL(bad), null, `expected invalid: ${String(bad)}`);
  }
  assert.equal(parseHostBaseURL('http://127.0.0.1:8080').origin, 'http://127.0.0.1:8080');
});

test('host.json validation rejects malformed records and names the problem', () => {
  const home = tempHome();
  try {
    assert.deepEqual(readHostState(home), {
      record: null,
      problem: 'no-host-file',
      detail: '未找到 host.json — App 可能没有运行',
    });
    assert.equal(readHostRecord(home), null);

    writeFileSync(join(home, 'host.json'), '{"version":2}');
    assert.equal(readHostState(home).problem, 'invalid-host-file');
    assert.equal(readHostRecord(home), null);

    writeFileSync(join(home, 'host.json'), 'not json');
    assert.equal(readHostState(home).problem, 'invalid-host-file');

    writeFileSync(join(home, 'host.json'), JSON.stringify({
      version: 1, baseURL: 'http://127.0.0.1:1', token: '', appPid: 1,
    }));
    assert.equal(readHostRecord(home), null);

    writeFileSync(join(home, 'host.json'), JSON.stringify({
      version: 1, baseURL: 'https://127.0.0.1:1', token: 't', appPid: process.pid,
    }));
    const refused = readHostState(home);
    assert.equal(refused.problem, 'invalid-host-file');
    assert.match(refused.detail, /baseURL/);

    writeFileSync(join(home, 'host.json'), JSON.stringify({
      version: 1, baseURL: 'http://127.0.0.1:1/', token: 't', appPid: process.pid,
    }));
    assert.deepEqual(readHostRecord(home), {
      version: 1,
      baseURL: 'http://127.0.0.1:1',
      token: 't',
      appPid: process.pid,
      startedAt: '',
    });
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test('claimTurn attributes a reply to the turn holding our own prompt', () => {
  const requestId = 'req-mine';
  const page = {
    records: [
      { type: 'event', event: { type: 'turn/start', seq: 2, data: { turn: 1 } } },
      {
        type: 'event',
        event: {
          type: 'user/message',
          seq: 3,
          data: { source: { kind: 'user', rpcId: 'req-foreign' }, content: [{ type: 'text', text: '别人' }] },
        },
      },
      {
        type: 'event',
        event: {
          type: 'assistant/message',
          seq: 4,
          data: { turn: 1, message: { content: [{ type: 'text', text: '别人的回复' }] } },
        },
      },
      { type: 'event', event: { type: 'turn/end', seq: 5, data: { turn: 1, reason: { kind: 'completed' } } } },
      { type: 'event', event: { type: 'turn/start', seq: 8, data: { turn: 2 } } },
      {
        type: 'event',
        event: {
          type: 'user/message',
          seq: 9,
          data: { source: { kind: 'user', rpcId: requestId }, content: [{ type: 'text', text: '我的' }] },
        },
      },
      {
        type: 'event',
        event: {
          type: 'assistant/message',
          seq: 11,
          data: { turn: 2, message: { content: [{ type: 'text', text: '我的回复' }] } },
        },
      },
    ],
  };
  const running = claimTurn(page, { requestId });
  assert.equal(running.state, 'running');
  assert.equal(running.messageSeq, 9);
  assert.equal(running.turnStartSeq, 8);
  assert.equal(running.text, '我的回复');

  page.records.push({ type: 'event', event: { type: 'turn/end', seq: 12, data: { turn: 2, reason: { kind: 'completed' } } } });
  const ended = claimTurn(page, { requestId });
  assert.equal(ended.state, 'ended');
  assert.equal(ended.text, '我的回复');
  assert.equal(ended.reason, 'completed');

  // A prompt that has not been drained into a turn yet.
  assert.equal(claimTurn(page, { requestId: 'req-queued' }).state, 'missing');
  // Not a single-turn or blanket match; our message anchors the span.
  assert.notEqual(ended.text, '别人的回复');
});

// ------------------------------------------------------------- transport ---

test('handshake stores the auth cookie and every RPC replays it', async () => {
  const host = await startFakeHost({ runningPolls: 1 });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    assert.equal(detected.available, true);
    assert.equal(host.state.handshakes, 1);
    const result = await runHostTask(detected.client, {
      task: '你好',
      cwd: home,
      pollIntervalMs: 1,
    });
    assert.equal(result.sessionId.startsWith('session-'), true);
    assert.equal(result.text, '回复：你好');
    const rpc = host.state.calls.filter((call) => call.method !== 'rejected');
    assert.deepEqual(rpc.map((call) => call.method).slice(0, 1), ['session/create']);
    for (const call of rpc) assert.equal(call.cookie, `${AUTH_NAME}=${AUTH_VALUE}`);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('HTTP 401 triggers one re-handshake and a replayed call', async () => {
  const host = await startFakeHost({ runningPolls: 1 });
  const home = tempHome();
  try {
    // Reject exactly the first RPC after the handshake, then let it through —
    // the client must re-handshake and replay instead of failing.
    const originalFetch = globalThis.fetch;
    let rejectNext = true;
    const fetchImpl = async (url, init) => {
      if (rejectNext && typeof url === 'string' && url.includes('/api/')) {
        rejectNext = false;
        return new Response('unauthorized', { status: 401 });
      }
      return originalFetch(url, init);
    };
    host.writeHostFile(home);
    const client = await HostClient.connect({
      baseURL: host.baseURL,
      token: 'launch-token',
      fetchImpl,
    });
    assert.equal(host.state.handshakes, 1);
    const result = await runHostTask(client, { task: '重放', cwd: home, pollIntervalMs: 1 });
    assert.equal(result.text, '回复：重放');
    assert.equal(host.state.handshakes, 2, '401 should re-handshake exactly once');
    assert.equal(host.state.prompts.length, 1, 'the replayed prompt must not be duplicated');
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

// ------------------------------------------------------------------ flow ---

test('full create → prompt → wait → page flow reads the complete assistant text', async () => {
  const longText = '完整回复：'.repeat(40);
  const host = await startFakeHost({ runningPolls: 2, replyFor: () => longText });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const result = await runHostTask(detected.client, {
      task: '长任务',
      cwd: home,
      pollIntervalMs: 1,
      timeoutMs: 5000,
    });
    assert.equal(result.text, longText, 'page text must not be clipped like turnOutline');
    assert.equal(result.reason, 'completed');
    assert.equal(host.state.calls.filter((call) => call.method === 'session/create').length, 1);
    assert.equal(host.state.prompts.length, 1);
    const pageCalls = host.state.calls.filter((call) => call.method === 'session/page');
    assert.ok(pageCalls.length >= 1);
    assert.equal('beforeSeq' in pageCalls[0].body.payload.args.request, false);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('a turn too fast to observe running=true still completes', async () => {
  const host = await startFakeHost({ finishImmediately: true, replyFor: () => '极快回复' });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const result = await runHostTask(detected.client, {
      task: '极快任务',
      cwd: home,
      pollIntervalMs: 1,
      timeoutMs: 5000,
    });
    assert.equal(result.text, '极快回复');
    assert.equal(result.turnCount, 1);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('a prompt queued behind another turn returns ITS OWN reply, not the stranger turn', async () => {
  const host = await startFakeHost({
    runningPolls: 2,
    replyFor: (text) => (text.includes('FIRST') ? '陌生人轮的回复' : '我这一轮的回复'),
  });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    // Somebody else's prompt is already queued in this Session, so ours will
    // be appended behind a turn we do not own.
    host.seedForeignPrompt(created.sessionId, 'FIRST 别人的任务');

    const result = await runHostTask(detected.client, {
      task: '我的任务',
      sessionId: created.sessionId,
      pollIntervalMs: 1,
      timeoutMs: 5000,
    });
    assert.equal(result.text, '我这一轮的回复');
    assert.equal(result.reason, 'completed');
    // Two turns ran; ours was the second one.
    assert.equal(result.turnCount, 2);
    const outlineCalls = host.state.calls.filter((call) => call.method === 'session/projections');
    assert.ok(outlineCalls.length > 0);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('two clients racing on one Session each get their own reply (turn-window paging)', async () => {
  // The Host pages by turn, so once the second turn opens the first turn's
  // events leave the window entirely. Each client must page back to its own
  // turn instead of hanging or stealing the neighbour's text.
  const host = await startFakeHost({
    runningPolls: 4,
    pageWindowTurns: 1,
    replyFor: (text) => (text.includes('A-TASK') ? 'A 的回复' : 'B 的回复'),
  });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const first = await detectHost({ home });
    const second = await HostClient.connect({ baseURL: host.baseURL, token: 'launch-token' });
    const created = await first.client.createSession(home);

    const slow = runHostTask(first.client, {
      task: 'A-TASK',
      sessionId: created.sessionId,
      pollIntervalMs: 1,
      timeoutMs: 5000,
    });
    // Let the first turn actually start (and be observed) before queueing
    // behind it, so the two claims genuinely overlap.
    while (host.state.prompts.length < 1) await new Promise((done) => setTimeout(done, 2));
    for (let i = 0; i < 20 && !host.state.sessions.get(created.sessionId)?.running; i += 1) {
      await new Promise((done) => setTimeout(done, 2));
    }
    const fast = runHostTask(second, {
      task: 'B-TASK',
      sessionId: created.sessionId,
      pollIntervalMs: 1,
      timeoutMs: 5000,
    });

    const [slowResult, fastResult] = await Promise.all([slow, fast]);
    assert.equal(slowResult.text, 'A 的回复');
    assert.equal(fastResult.text, 'B 的回复');
    // Each client claimed its OWN turn, not the neighbour's.
    assert.notEqual(fastResult.turnSeq, slowResult.turnSeq);
    assert.equal(slowResult.reason, 'completed');
    assert.equal(fastResult.reason, 'completed');
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('a long turn whose reply is outside the first page window pages backwards', async () => {
  // pageMaxMessages=1 makes every page a single record; the reply is only
  // reachable by walking beforeSeq back to our own user message.
  const host = await startFakeHost({ runningPolls: 1, pageMaxMessages: 1, replyFor: () => '分页回复' });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const result = await runHostTask(detected.client, {
      task: '长轮次',
      cwd: home,
      pollIntervalMs: 1,
      timeoutMs: 5000,
    });
    assert.equal(result.text, '分页回复');
    const pages = host.state.calls.filter((call) => call.method === 'session/page');
    assert.ok(pages.length > 1, `expected backwards paging, got ${pages.length} page call(s)`);
    const withBefore = pages.filter((call) => typeof call.body.payload.args.request.beforeSeq === 'number');
    assert.ok(withBefore.length > 0, 'expected at least one backwards page');
    for (const call of pages) {
      assert.notEqual(call.body.payload.args.request.beforeSeq, null);
    }
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('claimWithBackfill recovers a turn that the turn-window pushed out', async () => {
  // Direct unit test of the mechanism the race depends on: the first page
  // holds only the newest turn, so the client must walk `beforeSeq` back to
  // its own message and claim from there.
  const all = [
    { type: 'event', event: { type: 'turn/start', seq: 1, data: { turn: 1 } } },
    {
      type: 'event',
      event: { type: 'user/message', seq: 2, data: { source: { kind: 'user', rpcId: 'req-mine' }, content: [{ type: 'text', text: '我的' }] } },
    },
    { type: 'event', event: { type: 'assistant/message', seq: 3, data: { turn: 1, message: { content: [{ type: 'text', text: '我的回复' }] } } } },
    { type: 'event', event: { type: 'turn/end', seq: 4, data: { turn: 1, reason: { kind: 'completed' } } } },
    { type: 'event', event: { type: 'turn/start', seq: 10, data: { turn: 2 } } },
    {
      type: 'event',
      event: { type: 'user/message', seq: 11, data: { source: { kind: 'user', rpcId: 'req-other' }, content: [{ type: 'text', text: '别人' }] } },
    },
    { type: 'event', event: { type: 'assistant/message', seq: 12, data: { turn: 2, message: { content: [{ type: 'text', text: '别人的回复' }] } } } },
  ];
  const requested = [];
  const fakeClient = {
    async page({ beforeSeq }) {
      requested.push(beforeSeq ?? null);
      // newest turn only, mirroring turnWindow.minTurns = 1
      const window = all.filter((record) => record.event.seq >= 10);
      if (typeof beforeSeq !== 'number') return { records: window, hasMore: true };
      const older = all.filter((record) => record.event.seq < beforeSeq);
      return { records: older, hasMore: false };
    },
  };
  const hint = { messageSeq: 2, turnNumber: 1 };
  const { claim } = await claimWithBackfill(fakeClient, {
    sessionId: 's',
    throughSeq: 12,
    requestId: 'req-mine',
    hint,
  });
  assert.equal(claim.state, 'ended');
  assert.equal(claim.text, '我的回复');
  assert.deepEqual(requested, [null, 10]);
});

test('a Host that does not echo prompt ids falls back and warns on stderr', async () => {
  const host = await startFakeHost({ runningPolls: 1, echoRequestId: false, replyFor: () => '无回显回复' });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const warnings = [];
    const result = await runHostTask(detected.client, {
      task: '无回显',
      cwd: home,
      pollIntervalMs: 1,
      timeoutMs: 5000,
      onWarning: (message) => warnings.push(message),
    });
    assert.equal(result.text, '无回显回复');
    assert.equal(warnings.length, 1);
    assert.match(warnings[0], /未回显/);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('waitForTurn times out instead of hanging forever', async () => {
  const host = await startFakeHost({ runningPolls: 1_000_000 });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    await detected.client.prompt({ sessionId: created.sessionId, text: '不会结束' });
    await assert.rejects(
      waitForTurn(detected.client, {
        sessionId: created.sessionId,
        requestId: 'not-ours',
        baselineTurns: 0,
        pollIntervalMs: 1,
        timeoutMs: 50,
      }),
      /超时/,
    );
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('lastTurnAssistantText takes the last assistant message within bounds', () => {
  const page = {
    records: [
      { type: 'event', event: { type: 'assistant/message', seq: 3, data: { message: { content: [{ type: 'text', text: '旧轮' }] } } } },
      { type: 'event', event: { type: 'turn/start', seq: 10, data: { turn: 2 } } },
      { type: 'event', event: { type: 'assistant/message', seq: 12, data: { message: { content: [{ type: 'text', text: '换行' }] } } } },
      {
        type: 'event',
        event: {
          type: 'assistant/message',
          seq: 14,
          data: {
            message: {
              role: 'assistant',
              content: [
                { type: 'reasoning', text: '想' },
                { type: 'text', text: '第一段' },
                { type: 'text', text: '第二段' },
              ],
            },
          },
        },
      },
      { type: 'event', event: { type: 'turn/end', seq: 15, data: { turn: 2 } } },
    ],
  };
  assert.equal(lastTurnAssistantText(page, { turnSeq: 10 }), '第一段第二段');
  assert.equal(lastTurnAssistantText(page, { turnSeq: 20 }), '');
  // A followup turn already opened must not leak its reply into this turn.
  assert.equal(lastTurnAssistantText(page, { turnSeq: 10, endSeq: 14 }), '换行');
});

// ------------------------------------------------------------ timeout/attach ---

test('parseDuration understands 90s / 30m / 2h / bare milliseconds', () => {
  assert.equal(parseDuration('90s'), 90_000);
  assert.equal(parseDuration('30m'), 1_800_000);
  assert.equal(parseDuration('2h'), 7_200_000);
  assert.equal(parseDuration('1500ms'), 1_500);
  assert.equal(parseDuration('60000'), 60_000);
  assert.equal(parseDuration('0'), 0);
  for (const bad of ['', 'abc', '10x', '-5s', null, undefined]) {
    assert.equal(parseDuration(bad), null, `expected null for ${String(bad)}`);
  }
});

test('waiting is unbounded by default and --timeout leaves the turn running', async () => {
  // A turn that never finishes: without a timeout the CLI keeps waiting, so the
  // only way this test ends quickly is by killing the child.
  const host = await startFakeHost({ runningPolls: 1_000_000 });
  const home = tempHome();
  const home2 = tempHome();
  try {
    host.writeHostFile(home);
    // Default: no --timeout, no DS_AGENT_TIMEOUT_MS. Still running after 1s.
    const pending = spawn(process.execPath, [CLI, '--host', '长任务'], {
      env: { ...process.env, DSH_HOME: home, DS_AGENT_POLL_INTERVAL_MS: '20' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    pending.stderr.on('data', (chunk) => { stderr += chunk; });
    const started = Date.now();
    while (host.state.prompts.length === 0 && Date.now() - started < 5000) {
      await new Promise((done) => setTimeout(done, 20));
    }
    await new Promise((done) => setTimeout(done, 1_000));
    assert.equal(pending.exitCode, null, 'the CLI must still be waiting with no timeout');
    assert.equal(host.state.prompts.length, 1);
    pending.kill('SIGINT');
    await new Promise((done) => pending.on('exit', done));

    // With --timeout it gives up, prints how to re-attach, and cancels nothing.
    host.writeHostFile(home2);
    const promptsBefore = host.state.prompts.length;
    const result = await runCli(['--host', '--timeout', '1s', '长任务'], {
      home: home2,
      env: { DS_AGENT_POLL_INTERVAL_MS: '20' },
    });
    assert.equal(result.code, 1);
    assert.equal(host.state.prompts.length, promptsBefore + 1);
    assert.match(result.stderr, /超时/);
    assert.match(result.stderr, /会话 session-/);
    assert.match(result.stderr, /requestId [0-9a-f-]{8}/);
    assert.match(result.stderr, /接回这一轮：ds-agent --attach session-\S+ --request-id /);
    // A timeout must never cancel the turn on the Host.
    assert.equal(host.state.cancelled.length, 1, stderr); // only the SIGINT run above
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
    rmSync(home2, { recursive: true, force: true });
  }
});

test('--attach with a requestId returns a finished turn at once', async () => {
  const host = await startFakeHost({ runningPolls: 1, replyFor: () => '已结束的回复' });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    const { requestId } = await detected.client.prompt({ sessionId: created.sessionId, text: '先跑完' });
    // Drive the fake Host until the turn really finished.
    for (let i = 0; i < 40; i += 1) {
      await detected.client.listSessions();
      if (host.state.sessions.get(created.sessionId).outline.length === 1) break;
      await new Promise((done) => setTimeout(done, 10));
    }
    const started = Date.now();
    const result = await attachToTurn(detected.client, {
      sessionId: created.sessionId,
      requestId,
      pollIntervalMs: 5,
      timeoutMs: 5000,
    });
    assert.equal(result.text, '已结束的回复');
    assert.equal(result.reason, 'completed');
    assert.equal(result.requestId, requestId);
    assert.ok(Date.now() - started < 2000, 'a finished turn must return immediately');
    assert.equal(host.state.prompts.length, 1, '--attach must not prompt');
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('--attach with a requestId waits for a running turn to end', async () => {
  const host = await startFakeHost({ runningPolls: 2, replyFor: () => '还在跑的回复' });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    const { requestId } = await detected.client.prompt({ sessionId: created.sessionId, text: '慢任务' });
    const result = await attachToTurn(detected.client, {
      sessionId: created.sessionId,
      requestId,
      pollIntervalMs: 5,
      timeoutMs: 5000,
    });
    assert.equal(result.text, '还在跑的回复');
    assert.equal(host.state.prompts.length, 1);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('--attach without a requestId reports the last finished turn of an idle Session', async () => {
  const host = await startFakeHost({ runningPolls: 1, replyFor: () => '上一轮回复' });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    await detected.client.prompt({ sessionId: created.sessionId, text: '历史任务' });
    for (let i = 0; i < 40; i += 1) {
      await detected.client.listSessions();
      if (host.state.sessions.get(created.sessionId).outline.length === 1) break;
      await new Promise((done) => setTimeout(done, 10));
    }
    const result = await attachToTurn(detected.client, {
      sessionId: created.sessionId,
      pollIntervalMs: 5,
      timeoutMs: 5000,
    });
    assert.equal(result.text, '上一轮回复');
    assert.equal(result.requestId, null);
    // Settling on an already-idle Session must not be instant: a prompt queued
    // microseconds ago looks identical.
    assert.ok(host.state.prompts.length === 1);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('--attach without a requestId waits out the just-queued race', async () => {
  // Somebody else's prompt was accepted but has not started: `running` is still
  // false and the log is unchanged. Reporting the *previous* turn here would be
  // silently wrong, so --attach must keep waiting for the new turn.
  const host = await startFakeHost({
    runningPolls: 3,
    replyFor: (text) => (text.includes('旧') ? '旧的回复' : '新排队的回复'),
  });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    // Saturate the Session so the next poll starts the first turn.
    host.seedForeignPrompt(created.sessionId, '旧任务');
    await detected.client.listSessions();
    for (let i = 0; i < 60; i += 1) {
      await detected.client.listSessions();
      if (host.state.sessions.get(created.sessionId).outline.length === 1
        && host.state.sessions.get(created.sessionId).running === false) break;
      await new Promise((done) => setTimeout(done, 10));
    }
    // Accept a prompt without advancing: this is the race window.
    await detected.client.prompt({ sessionId: created.sessionId, text: '新任务' });
    const result = await attachToTurn(detected.client, {
      sessionId: created.sessionId,
      pollIntervalMs: 5,
      timeoutMs: 8000,
    });
    assert.equal(result.text, '新排队的回复', 'must wait for the queued turn, not report the old one');
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('--attach refuses to fall back to headless', async () => {
  const home = tempHome();
  try {
    const result = await runCli(['--attach', 'session-abc'], { home });
    assert.equal(result.code, 1);
    assert.match(result.stderr, /Host 模式不可用|未找到 host.json/);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test('--attach rejects task text and --request-id without --attach', async () => {
  const home = tempHome();
  try {
    const withTask = await runCli(['--attach', 'session-abc', '任务'], { home });
    assert.equal(withTask.code, 2);
    assert.match(withTask.stderr, /不接受任务文本/);
    const orphan = await runCli(['--request-id', 'abc', '任务'], { home });
    assert.equal(orphan.code, 2);
    assert.match(orphan.stderr, /只能配合 --attach/);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test('--help documents --timeout and --attach', async () => {
  const home = tempHome();
  try {
    const result = await runCli(['--help'], { home });
    assert.equal(result.code, 0, result.stderr);
    assert.match(result.stdout, /--timeout <时长>/);
    assert.match(result.stdout, /--attach <id>/);
    assert.match(result.stdout, /默认不限/);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test('a migration-required Session pages without a cursor instead of failing', async () => {
  // Old Sessions answer `migration-required` (no asOfSeq). Sending session/page
  // with a missing throughSeq used to fail the whole run.
  const host = await startFakeHost({ runningPolls: 1, migrationRequired: true, replyFor: () => '迁移会话回复' });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    const warnings = [];
    const result = await runHostTask(detected.client, {
      task: '迁移任务',
      sessionId: created.sessionId,
      pollIntervalMs: 1,
      timeoutMs: 5000,
      onWarning: (message) => warnings.push(message),
    });
    assert.equal(result.text, '迁移会话回复');
    assert.equal(warnings.some((line) => /迁移/.test(line)), true);
    const pages = host.state.calls.filter((call) => call.method === 'session/page');
    assert.ok(pages.length > 0);
    for (const call of pages) {
      assert.equal('throughSeq' in call.body.payload.args.request, false, 'no cursor may be sent');
    }
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

// ------------------------------------------------------------- selection ---

test('--session-id continues an existing Session without session/create', async () => {
  const host = await startFakeHost({ runningPolls: 1 });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    const before = host.state.calls.filter((call) => call.method === 'session/create').length;
    const result = await runHostTask(detected.client, {
      task: '继续',
      sessionId: created.sessionId,
      pollIntervalMs: 1,
    });
    assert.equal(result.sessionId, created.sessionId);
    assert.equal(
      host.state.calls.filter((call) => call.method === 'session/create').length,
      before,
      'continuing must not create a Session',
    );
    assert.equal(host.state.prompts.at(-1).sessionId, created.sessionId);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('mode selection: missing host.json ⇒ headless', async () => {
  const home = tempHome();
  try {
    const selection = await selectMode({ home });
    assert.equal(selection.mode, 'headless');
    assert.equal(selection.reason, 'no-host-file');
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test('mode selection: dead appPid ⇒ headless', async () => {
  const host = await startFakeHost();
  const home = tempHome();
  try {
    host.writeHostFile(home, { appPid: 999_999 });
    assert.equal(isProcessAlive(999_999), false);
    const selection = await selectMode({ home });
    assert.equal(selection.mode, 'headless');
    assert.equal(selection.reason, 'stale-pid');
    assert.equal(host.state.handshakes, 0, 'a dead pid must not be handshaken');
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('mode selection: a non-loopback baseURL is refused before any request', async () => {
  const host = await startFakeHost();
  const home = tempHome();
  try {
    host.writeHostFile(home, { baseURL: 'http://10.0.0.5:8080' });
    const selection = await selectMode({ home });
    assert.equal(selection.mode, 'headless');
    assert.equal(selection.reason, 'invalid-host-file');
    assert.match(selection.detail, /baseURL/);
    assert.equal(host.state.handshakes, 0, 'must not send the token anywhere');
    await assert.rejects(selectMode({ home, forceHost: true }), HostUnavailableError);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('mode selection: unreachable Host falls back unless --host', async () => {
  const host = await startFakeHost();
  const home = tempHome();
  try {
    host.writeHostFile(home, { baseURL: 'http://127.0.0.1:1' });
    const selection = await selectMode({ home });
    assert.equal(selection.mode, 'headless');
    assert.equal(selection.reason, 'handshake-failed');
    await assert.rejects(selectMode({ home, forceHost: true }), HostUnavailableError);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

// ------------------------------------------------------------------- cli ---

test('cli --host exits non-zero when the Host is unavailable', async () => {
  const home = tempHome();
  try {
    const result = await runCli(['--host', '任务'], { home });
    assert.equal(result.code, 1);
    assert.match(result.stderr, /Host 模式不可用/);
    assert.equal(result.stdout, '');
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test('cli --host explains a non-loopback host.json instead of "no file"', async () => {
  const host = await startFakeHost();
  const home = tempHome();
  try {
    host.writeHostFile(home, { baseURL: 'http://127.0.0.1:8080/some/path' });
    const result = await runCli(['--host', '任务'], { home });
    assert.equal(result.code, 1);
    assert.match(result.stderr, /baseURL/);
    assert.match(result.stderr, /回环/);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('cli without a Host falls back to the headless runtime', async () => {
  const home = tempHome();
  try {
    // A missing bundle makes the headless path fail fast instead of running a
    // real model turn — reaching exit 127 proves headless was selected.
    const result = await runCli(['任务'], { home, env: { DSH_APP: join(home, 'no-app') } });
    assert.equal(result.code, 127);
    assert.match(result.stderr, /no bundled runtime/);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test('cli reports an unusable host.json before falling back to headless', async () => {
  const host = await startFakeHost();
  const home = tempHome();
  try {
    host.writeHostFile(home, { baseURL: 'https://127.0.0.1:8080' });
    const result = await runCli(['任务'], { home, env: { DSH_APP: join(home, 'no-app') } });
    assert.equal(result.code, 127);
    assert.match(result.stderr, /host\.json 不可用/);
    assert.equal(host.state.handshakes, 0);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('cli routes dsh-only flags to headless even when a Host is reachable', async () => {
  const host = await startFakeHost();
  const home = tempHome();
  try {
    host.writeHostFile(home);
    // `--dump-config` is a dsh flag with no Host equivalent; the run must stay
    // on the pre-bridge path instead of being silently dropped.
    const result = await runCli(['--dump-config', '任务'], {
      home,
      env: { DSH_APP: join(home, 'no-app') },
    });
    assert.equal(result.code, 127);
    assert.match(result.stderr, /headless/);
    assert.equal(host.state.handshakes, 0);
    const rejected = await runCli(['--host', '--dump-config', '任务'], { home });
    assert.equal(rejected.code, 2);
    assert.match(rejected.stderr, /Host 模式不支持/);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('cli --headless ignores a reachable Host', async () => {
  const host = await startFakeHost();
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const result = await runCli(['--headless', '任务'], {
      home,
      env: { DSH_APP: join(home, 'no-app') },
    });
    assert.equal(result.code, 127);
    assert.equal(host.state.handshakes, 0);
    assert.equal(host.state.prompts.length, 0);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('cli --host runs the task through the Host and prints the final reply', async () => {
  const host = await startFakeHost({ runningPolls: 1, replyFor: () => '来自 Host 的回复' });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const result = await runCli(['--host', '你好'], { home, env: { DS_AGENT_POLL_INTERVAL_MS: '1' } });
    assert.equal(result.code, 0, result.stderr);
    assert.equal(result.stdout.trim(), '来自 Host 的回复');
    assert.equal(host.state.prompts.length, 1);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('cli --json emits a session first line and a final last line', async () => {
  const host = await startFakeHost({ runningPolls: 1, replyFor: () => 'JSON 回复' });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const result = await runCli(['--host', '--json', '你好'], {
      home,
      env: { DS_AGENT_POLL_INTERVAL_MS: '1' },
    });
    assert.equal(result.code, 0, result.stderr);
    const lines = result.stdout.trim().split('\n').map((line) => JSON.parse(line));
    assert.equal(lines[0].type, 'session');
    assert.equal(lines[0].via, 'host');
    assert.equal(typeof lines[0].sessionId, 'string');
    assert.equal(lines.at(-1).type, 'final');
    assert.equal(lines.at(-1).text, 'JSON 回复');
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('cli reads the task from stdin when passed "-"', async () => {
  const host = await startFakeHost({ runningPolls: 1, replyFor: () => 'STDIN 回复' });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const result = await runCli(['--host', '-'], {
      home,
      input: '从标准输入读到的任务',
      env: { DS_AGENT_POLL_INTERVAL_MS: '1' },
    });
    assert.equal(result.code, 0, result.stderr);
    assert.equal(result.stdout.trim(), 'STDIN 回复');
    assert.equal(host.state.prompts.at(-1).text, '从标准输入读到的任务');
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('SIGINT cancels the running Session and exits non-zero', async () => {
  const host = await startFakeHost({ runningPolls: 1_000_000 });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const child = spawn(process.execPath, [CLI, '--host', '长任务'], {
      env: { ...process.env, DSH_HOME: home, DS_AGENT_POLL_INTERVAL_MS: '20' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    const started = Date.now();
    while (host.state.prompts.length === 0 && Date.now() - started < 5000) {
      await new Promise((done) => setTimeout(done, 20));
    }
    assert.equal(host.state.prompts.length, 1, stderr);
    child.kill('SIGINT');
    const [code, signal] = await new Promise((done) => child.on('exit', (c, s) => done([c, s])));
    assert.notEqual(code, 0);
    assert.equal(signal, null);
    assert.equal(host.state.cancelled.length, 1);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('--json --help documents the line contract instead of a row index', async () => {
  const home = tempHome();
  try {
    const result = await runCli(['--help'], { home });
    assert.equal(result.code, 0, result.stderr);
    assert.match(result.stdout, /首行 session/);
    assert.match(result.stdout, /末行 final/);
    assert.match(result.stdout, /不要按行号取结果/);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test('requestIdEchoCapability distinguishes echoes / no-echo / unknown', () => {
  const page = (events) => ({ records: events.map((event, index) => ({ event: { seq: index + 1, ...event } })) });
  const user = (rpcId) => ({
    type: 'user/message',
    data: { source: rpcId ? { kind: 'user', rpcId } : { kind: 'user' } },
  });
  assert.equal(requestIdEchoCapability(page([{ type: 'turn/start', data: {} }])), 'unknown');
  assert.equal(requestIdEchoCapability(page([user(null)])), 'no-echo');
  assert.equal(requestIdEchoCapability(page([user(null), user('abc')])), 'echoes');
});

test('abortOwnTurn removes only a still-queued prompt of ours', async () => {
  const host = await startFakeHost({ runningPolls: 1_000_000 });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    // Somebody else's turn is running; our prompt is queued behind it.
    host.seedForeignPrompt(created.sessionId, '别人的长任务');
    await detected.client.listSessions();
    const { requestId } = await detected.client.prompt({ sessionId: created.sessionId, text: '我的排队任务' });
    const session = host.state.sessions.get(created.sessionId);
    assert.equal(session.pending.length, 1, 'our prompt must be pending');

    const outcome = await abortOwnTurn(detected.client, { sessionId: created.sessionId, requestId });
    assert.equal(outcome.action, 'removed');
    assert.equal(session.pending.length, 0, 'our queued item must be gone');
    assert.equal(host.state.removed.length, 1);
    assert.equal(host.state.cancelled.length, 0, 'never cancel somebody else\'s turn');
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('abortOwnTurn cancels the Session only when our own turn is running', async () => {
  const host = await startFakeHost({ runningPolls: 1_000_000 });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    const { requestId } = await detected.client.prompt({ sessionId: created.sessionId, text: '我的长任务' });
    await detected.client.listSessions(); // starts our turn
    assert.equal(host.state.sessions.get(created.sessionId).running, true);

    const outcome = await abortOwnTurn(detected.client, { sessionId: created.sessionId, requestId });
    assert.equal(outcome.action, 'cancelled');
    assert.deepEqual(host.state.cancelled, [created.sessionId]);
    assert.equal(host.state.removed.length, 0);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('abortOwnTurn leaves a foreign running turn untouched', async () => {
  const host = await startFakeHost({ runningPolls: 1_000_000 });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    host.seedForeignPrompt(created.sessionId, '别人的长任务');
    await detected.client.listSessions(); // the foreign turn is now running

    const outcome = await abortOwnTurn(detected.client, {
      sessionId: created.sessionId,
      requestId: 'request-that-was-never-sent',
    });
    assert.equal(outcome.action, 'none');
    assert.equal(host.state.cancelled.length, 0, 'a foreign turn must never be cancelled');
    assert.equal(host.state.removed.length, 0);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('CLI SIGINT while queued behind another turn removes our item only', async () => {
  const host = await startFakeHost({ runningPolls: 1_000_000 });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    host.seedForeignPrompt(created.sessionId, '别人的长任务');

    const child = spawn(process.execPath, [CLI, '--host', '--session-id', created.sessionId, '我的任务'], {
      env: { ...process.env, DSH_HOME: home, DS_AGENT_POLL_INTERVAL_MS: '20' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    const started = Date.now();
    while (host.state.prompts.length === 0 && Date.now() - started < 5000) {
      await new Promise((done) => setTimeout(done, 20));
    }
    assert.equal(host.state.prompts.length, 1, stderr);
    child.kill('SIGINT');
    const [code] = await new Promise((done) => child.on('exit', (c, s) => done([c, s])));
    assert.notEqual(code, 0);
    assert.equal(host.state.cancelled.length, 0, 'our queued prompt must not cancel the running foreign turn');
    assert.equal(host.state.removed.length, 1, 'our queued prompt must be withdrawn');
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('--attach --request-id errors out when the Host never echoes rpcIds', async () => {
  // Host that does not echo prompt ids: waiting could never succeed, so the CLI
  // must say why instead of hanging forever.
  const host = await startFakeHost({ runningPolls: 1, echoRequestId: false, replyFor: () => '回复' });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    await detected.client.prompt({ sessionId: created.sessionId, text: '历史任务' });
    for (let i = 0; i < 40; i += 1) {
      await detected.client.listSessions();
      if (host.state.sessions.get(created.sessionId).outline.length === 1) break;
      await new Promise((done) => setTimeout(done, 10));
    }
    const attached = await runCli(
      ['--attach', created.sessionId, '--request-id', 'not-in-log', '--timeout', '4s'],
      { home, env: { DS_AGENT_POLL_INTERVAL_MS: '5' } },
    );
    assert.notEqual(attached.code, 0, 'a requestId a non-echoing Host can never match must fail');
    assert.match(attached.stderr, /没有回显|找不到 requestId/);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('--attach without a requestId never prints empty text with exit 0', async () => {
  // An idle Session whose newest outline entry has no readable turn/end: the
  // old code reported an empty reply with status 0, which looks like success.
  const host = await startFakeHost({ runningPolls: 1, replyFor: () => '正常回复' });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    await detected.client.prompt({ sessionId: created.sessionId, text: '历史任务' });
    for (let i = 0; i < 40; i += 1) {
      await detected.client.listSessions();
      if (host.state.sessions.get(created.sessionId).outline.length === 1) break;
      await new Promise((done) => setTimeout(done, 10));
    }
    // Drop the records the claim needs while keeping the outline entry.
    host.state.sessions.get(created.sessionId).records = [];
    const result = await runCli(['--attach', created.sessionId], {
      home,
      env: { DS_AGENT_POLL_INTERVAL_MS: '5' },
    });
    assert.notEqual(result.code, 0, `empty text must not exit 0 (stdout=${JSON.stringify(result.stdout)})`);
    assert.match(result.stderr, /没有取到最后一轮的完整回复/);
    assert.equal(result.stdout.trim(), '', 'no empty final line on failure');
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('CLI SIGINT while the prompt request is still in flight still withdraws our turn', async () => {
  // Ctrl-C lands before `session/prompt` returns: the requestId must already
  // exist, or the handler has nothing to withdraw and the prompt survives.
  const host = await startFakeHost({ runningPolls: 1_000_000, promptResponseDelayMs: 1_500 });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    host.seedForeignPrompt(created.sessionId, '别人的长任务');

    const child = spawn(process.execPath, [CLI, '--host', '--session-id', created.sessionId, '我的任务'], {
      env: { ...process.env, DSH_HOME: home, DS_AGENT_POLL_INTERVAL_MS: '20' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    const started = Date.now();
    while (host.state.prompts.length === 0 && Date.now() - started < 5000) {
      await new Promise((done) => setTimeout(done, 20));
    }
    assert.equal(host.state.prompts.length, 1, stderr);
    // The response is still pending, so the CLI is blocked inside `prompt()`.
    child.kill('SIGINT');
    const [code] = await new Promise((done) => child.on('exit', (c, s) => done([c, s])));
    assert.notEqual(code, 0);
    assert.equal(host.state.cancelled.length, 0, 'the foreign running turn must stay alive');
    assert.equal(host.state.removed.length, 1, 'our in-flight prompt must be withdrawn by its requestId');
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('abortOwnTurn re-claims and cancels when the remove loses the race to a running turn', async () => {
  // Projections showed our prompt queued, but by the time the remove arrived
  // the Host had started it. The Host answers `session/queue-item-not-found`;
  // that is our turn now running, so it must be cancelled — not ignored.
  const host = await startFakeHost({ runningPolls: 1_000_000, loseQueueItemToRunning: true });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    host.seedForeignPrompt(created.sessionId, '别人的长任务');
    await detected.client.listSessions();
    const { requestId } = await detected.client.prompt({ sessionId: created.sessionId, text: '我的排队任务' });
    const session = host.state.sessions.get(created.sessionId);
    assert.equal(session.pending.length, 1, 'precondition: our prompt is still queued');

    const outcome = await abortOwnTurn(detected.client, { sessionId: created.sessionId, requestId });
    assert.equal(outcome.action, 'cancelled');
    assert.deepEqual(host.state.cancelled, [created.sessionId]);
    assert.equal(host.state.removed.length, 0, 'the remove lost the race');
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('abortOwnTurn still ignores unrelated updateQueue errors', async () => {
  const host = await startFakeHost();
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    const failing = {
      projections: () => detected.client.projections(created.sessionId),
      updateQueue: () => Promise.reject(new Error('session/updateQueue: gateway/bad-request — nope')),
      page: (args) => detected.client.page(args),
      cancel: (id) => detected.client.cancel(id),
    };
    // Our prompt never got queued here, so the inbox lookup must not even call
    // updateQueue; use a pending inbox entry by seeding one through the client.
    await detected.client.prompt({ sessionId: created.sessionId, text: '排队' });
    const { requestId } = host.state.prompts.at(-1);
    const outcome = await abortOwnTurn(failing, { sessionId: created.sessionId, requestId });
    assert.equal(outcome.action, 'none', 'a non-"not-found" error must not trigger a cancel');
    assert.equal(host.state.cancelled.length, 0);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('--attach without a requestId gives up when an idle turn never settles', async () => {
  // The outline has the turn and the Session is idle, but no terminal event
  // ever appears. Waiting is unlimited by default, so this used to loop forever.
  const host = await startFakeHost({ runningPolls: 1, replyFor: () => '正常回复', omitTurnEnd: true });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    await detected.client.prompt({ sessionId: created.sessionId, text: '历史任务' });
    for (let i = 0; i < 40; i += 1) {
      await detected.client.listSessions();
      if (host.state.sessions.get(created.sessionId).outline.length === 1) break;
      await new Promise((done) => setTimeout(done, 10));
    }
    assert.equal(host.state.sessions.get(created.sessionId).running, false);

    const result = await runCli(['--attach', created.sessionId], {
      home,
      env: { DS_AGENT_POLL_INTERVAL_MS: '5' },
    });
    assert.notEqual(result.code, 0, 'an unsettled idle turn must not be reported as success');
    assert.match(result.stderr, /没有取到最后一轮的完整回复/);
    assert.equal(result.stdout.trim(), '');
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('--attach --request-id gives up when the Session never shows any prompt at all', async () => {
  // Empty Session, unknown echo capability (no user message in view), idle:
  // waiting can never succeed, and the default timeout is unlimited.
  const host = await startFakeHost({ runningPolls: 1 });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    const result = await runCli(
      ['--attach', created.sessionId, '--request-id', 'never-sent'],
      { home, env: { DS_AGENT_POLL_INTERVAL_MS: '5' } },
    );
    assert.notEqual(result.code, 0, 'an unknown-echo idle Session must not hang forever');
    assert.match(result.stderr, /找不到 requestId never-sent/);
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('--attach --request-id keeps waiting while our prompt is queued behind a running turn', async () => {
  // The same `unknown` capability, but the Session is RUNNING: our prompt may
  // simply be queued, so giving up would be wrong.
  const host = await startFakeHost({ runningPolls: 1_000_000, replyFor: () => '正常回复' });
  const home = tempHome();
  try {
    host.writeHostFile(home);
    const detected = await detectHost({ home });
    const created = await detected.client.createSession(home);
    host.seedForeignPrompt(created.sessionId, '别人的长任务');
    await detected.client.listSessions(); // the foreign turn is running

    const child = spawn(process.execPath, [
      CLI, '--attach', created.sessionId, '--request-id', 'still-queued',
    ], {
      env: { ...process.env, DSH_HOME: home, DS_AGENT_POLL_INTERVAL_MS: '5' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    await new Promise((done) => setTimeout(done, 400));
    assert.equal(child.exitCode, null, `a queued turn must keep waiting (stderr=${stderr})`);
    child.kill('SIGTERM');
    await new Promise((done) => child.on('exit', done));
  } finally {
    await host.close();
    rmSync(home, { recursive: true, force: true });
  }
});

test('default timeout is 0 (wait forever) and ignores the environment', async () => {
  // The CLI computes it from the flag or DS_AGENT_TIMEOUT_MS; the exported
  // constant must be the "no limit" default the help text promises.
  assert.equal(DEFAULT_TIMEOUT_MS, 0);
});
