import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { pickOrigin } from './origin-pick.ts';

const SRC = join(import.meta.dirname, '../..');
function files(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? files(p) : /\.(ts|tsx)$/.test(n) && !/\.test\./.test(n) ? [p] : [];
  });
}
const routes = [...files(join(SRC, 'app')), ...files(join(SRC, 'server'))].filter((f) => !/\/(components|features)\//.test(f));

// Behind Caddy, req.url and the origin of the request URL read http://localhost:3000. These statements send a browser there.
const REQ_URL = /\b(req|request)\.url\b/;
const REQ_ORIGIN = /\b(u|url)\.origin\b|nextUrl\.origin/;
const SINK = /(?:Response\.redirect|NextResponse\.redirect|\bredirect)\s*\(|\blocation\s*[:=]|\bLocation\b\s*[:=]/gi;

function sinks(text: string): string[] {
  // the statement after each redirect or Location: up to the next semicolon, which template literals here never hold
  return [...text.matchAll(SINK)].map((m) => text.slice(m.index!, text.indexOf(';', m.index!) === -1 ? undefined : text.indexOf(';', m.index!)));
}

test('no route builds a redirect or Location from req.url or the request origin', () => {
  const bad = routes.filter((f) => sinks(readFileSync(f, 'utf8')).some((s) => REQ_URL.test(s) || REQ_ORIGIN.test(s)));
  assert.deepEqual(bad, []);
});

test('no app route reads u.origin (the request origin) at all', () => {
  const bad = files(join(SRC, 'app')).filter((f) => /\bu\.origin\b/.test(readFileSync(f, 'utf8')));
  assert.deepEqual(bad, []);
});

test('the guard catches nested template literals and every fixed pattern', () => {
  const samples = [
    'return Response.redirect(new URL(`/sign-in?next=${encodeURIComponent(`/a/${b}`)}`, req.url), 302);',
    'return NextResponse.redirect(new URL(path, u.origin));',
    "return new Response(null, { status: 302, headers: { location: new URL(url, req.url).toString() } });",
    'const res = NextResponse.redirect(new URL(r.to, request.url));',
    'return NextResponse.redirect(new URL(x, req.nextUrl.origin));',
  ];
  for (const s of samples) assert.ok(sinks(s).some((x) => REQ_URL.test(x) || REQ_ORIGIN.test(x)), s);
  assert.ok(!sinks("return localRedirect('/choose-portal', 302);").some((x) => REQ_URL.test(x)));
});

test('publicOrigin takes the forwarded host, else the site address, never localhost', () => {
  const site = 'https://carmacars.ca';
  assert.equal(pickOrigin('www.carmacars.ca', 'https', site), 'https://www.carmacars.ca');
  assert.equal(pickOrigin('carmacars.ca, other', 'https, http', site), 'https://carmacars.ca');
  assert.equal(pickOrigin(null, null, site), 'https://carmacars.ca');
  assert.equal(pickOrigin('localhost:3000', 'http', site), 'https://carmacars.ca');
  assert.equal(pickOrigin('evil.com/x', 'https', site), 'https://carmacars.ca');
  assert.equal(pickOrigin('localhost:3000', 'http', 'http://localhost:3000'), 'http://localhost:3000');
});
