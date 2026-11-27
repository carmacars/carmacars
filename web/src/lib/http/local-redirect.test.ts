import { describe, expect, it } from 'vitest';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { localRedirect } from './local-redirect';

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? files(p) : /\.(ts|tsx)$/.test(n) && !/\.test\./.test(n) ? [p] : [];
  });
}

describe('localRedirect', () => {
  it('sends a relative Location, never the internal host', () => {
    const r = localRedirect('/choose-portal');
    expect(r.status).toBe(302);
    expect(r.headers.get('location')).toBe('/choose-portal');
  });
  it('refuses an outside address', () => {
    expect(() => localRedirect('https://evil.example')).toThrow();
    expect(() => localRedirect('//evil.example')).toThrow();
  });
  it('no route builds a redirect from req.url (it reads localhost behind Caddy)', () => {
    const bad = files(join(__dirname, '../../app')).filter((f) => /redirect\(\s*new URL\([^)]*\breq(uest)?\.url\)/.test(readFileSync(f, 'utf8')));
    expect(bad).toEqual([]);
  });
});
