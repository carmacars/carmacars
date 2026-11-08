// r34 (2026-11-08): an old email-link redirect (/account/bookings/:n/pickup back to the booking) hid the renter's own
// check-in page for months. A redirect in next.config.ts must never point away from a page that exists.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const root = join(import.meta.dirname, '..', '..');
const config = readFileSync(join(root, 'next.config.ts'), 'utf8');
const block = config.slice(config.indexOf('const EMAIL_PATHS'), config.indexOf('];', config.indexOf('const EMAIL_PATHS')));
const sources = [...block.matchAll(/\[\s*'([^']+)'\s*,\s*'[^']*'\s*\]/g)].map((m) => m[1]!);

// a source like /account/bookings/:n/pickup maps to app/account/bookings/[number]/pickup/page.tsx (any dynamic segment)
function pageExists(source: string): boolean {
  const parts = source.split('/').filter(Boolean);
  if (parts.some((p) => p.includes('*') || p.includes('('))) return false;
  const walk = (dir: string, i: number): boolean => {
    if (i === parts.length) return existsSync(join(dir, 'page.tsx'));
    const p = parts[i]!;
    if (p.startsWith(':')) {
      for (const d of ['[number]', '[id]', '[n]', '[slug]', '[token]']) if (existsSync(join(dir, d)) && walk(join(dir, d), i + 1)) return true;
      return false;
    }
    return existsSync(join(dir, p)) && walk(join(dir, p), i + 1);
  };
  return walk(join(root, 'src', 'app'), 0);
}

test('the redirect list has entries', () => { assert.ok(sources.length > 10); });

test('no redirect hides a page that exists', () => {
  const hidden = sources.filter(pageExists);
  assert.deepEqual(hidden, [], `these redirects hide real pages: ${hidden.join(', ')}`);
});
