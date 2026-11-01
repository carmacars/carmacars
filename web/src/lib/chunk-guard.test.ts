import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CHUNK_GUARD_SCRIPT, RELOAD_KEY } from './chunk-guard.ts';

// A fake window: the guard's listeners, a session store, fetch and reload counted.
function fakeWindow(stored: Record<string, string> = {}) {
  const on: Record<string, Array<(e: unknown) => void>> = {};
  const w = {
    location: { href: 'https://carmacars.ca/cars/x#dates', origin: 'https://carmacars.ca', reloads: 0, reload() { this.reloads++; } },
    sessionStorage: { getItem: (k: string) => stored[k] ?? null, setItem: (k: string, v: string) => { stored[k] = v; } },
    fetches: [] as Array<[string, RequestInit]>,
    fetch(u: string, o: RequestInit) { this.fetches.push([u, o]); return Promise.resolve(); },
    setTimeout: () => 0,
    performance: { getEntriesByType: () => [] as unknown[] },
    addEventListener(t: string, f: (e: unknown) => void) { (on[t] ??= []).push(f); },
    fire(t: string, e: unknown) { for (const f of on[t] ?? []) f(e); }
  };
  new Function('window', CHUNK_GUARD_SCRIPT)(w);
  return { w, stored };
}
const tick = () => new Promise((r) => setTimeout(r, 0));

test('a missing chunk of this site reloads the page once, fresh from the server', async () => {
  const { w, stored } = fakeWindow();
  w.fire('error', { target: { tagName: 'SCRIPT', src: 'https://carmacars.ca/_next/static/chunks/app/x-1a2b.js' } });
  await tick();
  assert.equal(w.fetches.length, 1);
  assert.equal(w.fetches[0]![1].cache, 'reload');
  assert.equal(w.location.reloads, 1);
  assert.ok(Number(stored[RELOAD_KEY]) > 0);
  w.fire('error', { target: { tagName: 'LINK', rel: 'stylesheet', href: '/_next/static/css/a.css' } });
  await tick();
  assert.equal(w.location.reloads, 1, 'never twice');
});

test('a chunk error on a client navigation reloads; other errors do not', async () => {
  const a = fakeWindow();
  a.w.fire('unhandledrejection', { reason: { name: 'Error', message: 'boom' } });
  a.w.fire('error', { target: a.w, message: 'TypeError: x is undefined' });
  a.w.fire('error', { target: { tagName: 'SCRIPT', src: 'https://js.stripe.com/v3/' } });
  a.w.fire('error', { target: { tagName: 'IMG', src: '/_next/static/media/x.png' } });
  await tick();
  assert.equal(a.w.location.reloads, 0);
  a.w.fire('unhandledrejection', { reason: { name: 'ChunkLoadError', message: 'Loading chunk 123 failed.' } });
  await tick();
  assert.equal(a.w.location.reloads, 1);
});

test('a reload in the last minute: no second one (a real outage never loops)', async () => {
  const { w } = fakeWindow({ [RELOAD_KEY]: String(Date.now() - 5000) });
  w.fire('error', { target: { tagName: 'SCRIPT', src: '/_next/static/chunks/main.js' } });
  await tick();
  assert.equal(w.location.reloads, 0);
});

test('at load, a /_next/static file answered 404 reloads', async () => {
  const { w } = fakeWindow();
  w.performance.getEntriesByType = () => [{ name: 'https://carmacars.ca/_next/static/chunks/old.js', responseStatus: 404 }];
  w.fire('load', {});
  await tick();
  assert.equal(w.location.reloads, 1);
});
