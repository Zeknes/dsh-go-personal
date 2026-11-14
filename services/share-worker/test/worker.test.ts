import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import worker from '../src/index';
import { clientKey } from '../src/limits';
import { makeEnv, serve, workerFirst } from './fakes';

const ORIGIN = 'https://go.dshtui.com';

const get = (path: string, headers: Record<string, string> = {}) =>
  new Request(ORIGIN + path, { headers: { 'CF-Connecting-IP': '198.51.100.1', ...headers } });

describe('clientKey', () => {
  const key = (ip: string) => clientKey(new Request(ORIGIN, { headers: { 'CF-Connecting-IP': ip } }));
  it('keys IPv4 by address and IPv6 by /64', () => {
    expect(key('203.0.113.9')).toBe('203.0.113.9');
    expect(key('2001:db8:1:2:aaaa::1')).toBe('2001:db8:1:2::/64');
    expect(key('2001:0db8:0001:0002:ffff:ffff:ffff:ffff')).toBe('2001:db8:1:2::/64');
    expect(key('2001:db8::1')).toBe('2001:db8:0:0::/64');
    expect(clientKey(new Request(ORIGIN))).toBe('unknown');
  });
});

describe('pages', () => {
  // The site is files served without the Worker; the Worker runs first only
  // for its own routes and the files it hides.
  it('runs the Worker first only for its routes', () => {
    for (const p of ['/api/v1/c', '/api/usage/v1', '/api/github/stars', '/c/Ab3dE5gH9k', '/market/index.json', '/market',
      '/p/@scope/plugin', '/beta', '/beta/update.json', '/download', '/download/get', '/share', '/c.html', '/index.html']) {
      expect(workerFirst(p), p).toBe(true);
    }
    for (const p of ['/', '/app.js', '/assets/dsh-go.svg', '/share/', '/share/index.html', '/share/share.js', '/robots.txt', '/favicon.svg']) {
      expect(workerFirst(p), p).toBe(false);
    }
  });

  it('does not serve public conversation shares', async () => {
    const { env } = makeEnv();
    expect((await worker.fetch(get('/c/Ab3dE5gH9k'), env)).status).toBe(404);
    expect((await worker.fetch(get('/api/v1/c/Ab3dE5gH9k'), env)).status).toBe(404);
  });

  it('404s everything else', async () => {
    const ctx = makeEnv();
    for (const p of ['/c.html', '/c/', '/c/a_b', '/nope', '/share/nope.html', '/api/v2/c', '/api/v1/c/x/y',
      '/index.html', '/home/', '/home/index.html', '/home/app.js', '/assets/', '/assets/nope.webp', '/assets/features/']) {
      expect((await serve(get(p), ctx.env)).status, p).toBe(404);
    }
    expect((await serve(new Request(`${ORIGIN}/c/Ab3dE5gH9k`, { method: 'POST' }), ctx.env)).status).toBe(405);
    expect((await serve(new Request(`${ORIGIN}/app.js`, { method: 'POST' }), ctx.env)).status).toBe(405);
    expect((await serve(get('/api/v1/c'), ctx.env)).status).toBe(404);
    expect((await serve(get('/robots.txt'), ctx.env)).status).toBe(200);
  });
});

describe('home page', () => {
  const site = (name: string) => readFileSync(new URL(`../../../site/home/dist/${name}`, import.meta.url), 'utf8');

  it('is served at / with its own policy, indexable', async () => {
    const ctx = makeEnv();
    for (const method of ['GET', 'HEAD']) {
      const res = await serve(new Request(`${ORIGIN}/`, { method }), ctx.env);
      expect(res.status).toBe(200);
      expect(res.headers.get('Content-Type')).toContain('text/html');
      expect(res.headers.get('Content-Security-Policy')).toBe(
        "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; style-src-elem 'self'; " +
          "style-src-attr 'unsafe-inline'; img-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      );
      expect(res.headers.get('X-Frame-Options')).toBe('DENY');
      expect(res.headers.get('X-Content-Type-Options')).toBe('nosniff');
      expect(res.headers.get('Referrer-Policy')).toBe('no-referrer');
      expect(res.headers.get('Strict-Transport-Security')).toBe('max-age=31536000');
      expect(res.headers.get('Cache-Control')).toBe('no-cache');
      expect(res.headers.has('X-Robots-Tag')).toBe(false);
    }
    const body = await (await serve(get('/?from=qr'), ctx.env)).text();
    expect(body).toContain('<title>DSH Go · 万物皆插件，随身而行</title>');
    expect(body).toContain('<link rel="canonical" href="https://go.dshtui.com/">');
    expect(body).toContain('<script src="app.js" defer></script>');
  });

  it('serves its files at their own paths with types and a cache header', async () => {
    const ctx = makeEnv();
    for (const [path, type] of [
      ['/assets/features/01-local-engine.webp', 'image/webp'],
      ['/assets/author/download-qr-v2.png', 'image/png'],
      ['/assets/dsh-go.svg', 'image/svg+xml'],
      ['/app.js', 'text/javascript'],
      ['/site-config.js', 'text/javascript'],
      ['/styles.css', 'text/css'],
    ]) {
      const res = await serve(get(path!), ctx.env);
      expect(res.status, path).toBe(200);
      expect(res.headers.get('Content-Type'), path).toContain(type);
      expect(res.headers.get('Cache-Control'), path).toBe('public, max-age=3600');
      expect(res.headers.get('X-Content-Type-Options'), path).toBe('nosniff');
      expect(res.headers.has('X-Robots-Tag'), path).toBe(false);
    }
  });

  it('loads only what its policy allows, and every file it names is there', async () => {
    const page = site('index.html');
    // No inline scripts or handlers (script-src 'self'), no <style> blocks
    // (style-src-elem 'self'), nothing from another origin (img-src 'self').
    expect(page).not.toMatch(/<script(?![^>]*\ssrc=)[^>]*>/i);
    expect(page).not.toMatch(/\son[a-z]+\s*=/i);
    expect(page).not.toMatch(/<style[\s>]/i);
    // Every resource the page pulls in stays on this origin. Plain <a href>
    // links may point anywhere: they are navigations, not loads, and the CSP
    // does not govern where a click goes. The footer's friend links live there.
    const refs = [
      ...[...page.matchAll(/<(?:script|img)\b[^>]*\ssrc="([^"#][^"]*)"/gi)].map((m) => m[1]!),
      ...[...page.matchAll(/<link\b[^>]*\srel="(?:stylesheet|icon|apple-touch-icon)"[^>]*\shref="([^"#][^"]*)"/gi)].map((m) => m[1]!),
    ];
    expect(refs.filter((u) => /^[a-z]+:|^\/\//i.test(u))).toEqual([]);
    expect(page).toContain('href="https://dshtui.com/"');
    expect(page).toContain('href="https://github.com/ccch1mneyyy/dsh-TUI"');
    const images = [...site('site-config.js').matchAll(/(?:avatar|qrImage):\s*"([^"]+)"/g)].map((m) => m[1]!);
    expect(images).toEqual(['assets/dsh-go.svg', 'assets/author/download-qr-v2.png']);
    const ctx = makeEnv();
    for (const ref of new Set([...refs, ...images])) {
      expect((await serve(get('/' + ref), ctx.env)).status, ref).toBe(200);
    }
  });

  it('is the only thing robots.txt lets crawlers fetch', async () => {
    const ctx = makeEnv();
    const lines = (await (await serve(get('/robots.txt'), ctx.env)).text()).trim().split('\n');
    expect(lines.slice(0, 2)).toEqual(['User-agent: *', 'Allow: /$']);
    expect(lines).toContain('Allow: /app.js$');
    expect(lines).toContain('Allow: /assets/features/01-local-engine.webp$');
    expect(lines.at(-1)).toBe('Disallow: /');
    expect(lines.filter((l) => /^Allow: \/(?:share|c|beta|download|api|home)\b/.test(l))).toEqual([]);
  });

  it('leaves the other routes alone', async () => {
    const ctx = makeEnv();
    expect((await serve(get('/c/Ab3dE5gH9k'), ctx.env)).status).toBe(404);
    expect((await serve(get('/share/'), ctx.env)).status).toBe(404);
    expect((await serve(get('/favicon.svg'), ctx.env)).status).toBe(200);
    expect((await serve(get('/update.json'), ctx.env)).status).toBe(404);
    expect((await serve(new Request(`${ORIGIN}/`, { method: 'POST' }), ctx.env)).status).toBe(405);
  });
});
