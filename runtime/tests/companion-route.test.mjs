import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';
import { apply } from '../bridge/dsh-go-bridge/lib/index.js';

const ROOT = '/dsh-go/v1/companion';
const AUTH = 'Bearer synthetic-companion-test';
async function fixture(t, { connection = true } = {}) {
  const home = await mkdtemp(join(tmpdir(), 'dsh-go-companion-route-'));
  const path = join(home, 'companion', 'state.json');
  const routes = [], disposals = [], guarded = [];
  const ctx = {
    logger: { warn() {} },
    get(name) {
      if (name === 'connection' && connection) return {
        requestRejection(req) {
          guarded.push(req.url);
          return req.headers.authorization === AUTH ? undefined : 401;
        },
      };
    },
    on() {}, provide() {},
    inject(_deps, fn) { fn(ctx); },
    effect(fn) { const dispose = fn(); if (typeof dispose === 'function') disposals.push(dispose); },
    webServer: {
      tapIndex() { return () => {}; },
      register(route) { routes.push(route); return () => {}; },
      registerUpgrade() { return () => {}; },
    },
  };
  const previousHome = process.env.DSH_HOME;
  process.env.DSH_HOME = home;
  try { apply(ctx, { persist: false, guardRoutes: false }); }
  finally {
    if (previousHome === undefined) delete process.env.DSH_HOME;
    else process.env.DSH_HOME = previousHome;
  }
  const server = createServer((req, res) => {
    const route = routes.find((r) => r.kind === 'prefix' && req.url.startsWith(r.path));
    if (!route) { res.writeHead(404); res.end(); return; }
    void Promise.resolve(route.handler(req, res)).catch((error) => {
      res.writeHead(500); res.end('Unexpected test harness failure');
      t.diagnostic(String(error));
    });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const origin = `http://127.0.0.1:${server.address().port}`;
  t.after(async () => {
    disposals.reverse().forEach((dispose) => dispose());
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await rm(home, { recursive: true, force: true });
  });
  async function request(pathname = ROOT, { method = 'GET', body, auth = true, contentType = 'application/json' } = {}) {
    const headers = {};
    if (auth) headers.authorization = AUTH;
    if (body !== undefined) headers['content-type'] = contentType;
    const response = await fetch(`${origin}${pathname}`, { method, headers,
      ...(body === undefined ? {} : { body: typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body) }) });
    const text = await response.text();
    return { status: response.status, headers: response.headers,
      body: response.headers.get('content-type')?.startsWith('application/json') ? JSON.parse(text) : text };
  }
  return { home, path, origin, guarded, request };
}
test('existing connection guard rejects every companion route before any storage access', async (t) => {
  const f = await fixture(t);
  for (const [path, method] of [[ROOT, 'GET'], [`${ROOT}/memories`, 'GET'], [`${ROOT}/memories`, 'POST'],
    [`${ROOT}/events`, 'POST'], [`${ROOT}/context`, 'POST'], [`${ROOT}/export`, 'GET'],
    [`${ROOT}/memories/delete`, 'POST'], [`${ROOT}/memories/clear`, 'POST'],
    [`${ROOT}/recall`, 'GET'], [`${ROOT}/recall/bind`, 'POST'],
    [`${ROOT}/recall/revoke`, 'POST'], [`${ROOT}/recall/bindings/${randomUUID()}`, 'GET']]) {
    const result = await f.request(path, { method, auth: false, ...(method === 'POST' ? { body: {} } : {}) });
    assert.equal(result.status, 401);
    assert.equal(result.headers.get('cache-control'), 'no-store');
  }
  assert.equal(f.guarded.length, 12);
  await assert.rejects(stat(f.path), { code: 'ENOENT' });
  const absent = await fixture(t, { connection: false });
  assert.equal((await absent.request()).status, 503);
  await assert.rejects(stat(absent.path), { code: 'ENOENT' });
});

test('authenticated companion endpoints are absent and do not create storage', async (t) => {
  const f = await fixture(t);
  for (const path of [ROOT, `${ROOT}/recall`, `${ROOT}/memories`, `${ROOT}/context`]) {
    assert.equal((await f.request(path)).status, 404);
  }
  await assert.rejects(stat(f.path), { code: 'ENOENT' });
});
