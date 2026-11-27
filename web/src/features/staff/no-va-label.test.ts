import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { signInRoleWords } from './nav.ts';

// r50 hotfix 2 (5180; the owner, many times): "VA" is for a remote virtual assistant only. A person who works in person
// (field staff, in-person sales, a fleet or customer service person at the office) shows their real role everywhere:
// the sign-in roles in words, and no page, email or guide of the staff portal says VA.
const ROOT = join(import.meta.dirname, '..', '..', '..', '..');
const walk = (d: string): string[] => readdirSync(d).flatMap((f) => { const p = join(d, f); return statSync(p).isDirectory() ? walk(p) : [p]; });
const code = (s: string) => s.replace(/\/\*[\s\S]*?\*\//g, '').split('\n').map((l) => l.replace(/(^|\s)\/\/.*$/, '')).join('\n');
const VA = /\bVAs?\b/;

test('the sign-in roles show words, never "va"', () => {
  assert.equal(signInRoleWords(['va']), 'Staff');
  assert.equal(signInRoleWords(['field']), 'Staff');
  assert.equal(signInRoleWords(['va', 'field', 'renter']), 'Staff, Renter');
  assert.equal(signInRoleWords(['admin', 'owner']), 'Admin, Owner');
  assert.equal(signInRoleWords(null), '');
});

test('no staff-portal page, townhall, call or onboarding text says VA', () => {
  const dirs = ['web/src/app/staff', 'web/src/features/staff', 'web/src/features/staff-onboarding', 'web/src/features/academy', 'web/src/features/townhall', 'web/src/features/calls', 'web/src/features/field'];
  const bad: string[] = [];
  for (const d of dirs) for (const f of walk(join(ROOT, d)).filter((x) => /\.(tsx?|css)$/.test(x) && !/\.test\./.test(x))) if (VA.test(code(readFileSync(f, 'utf8')))) bad.push(f.slice(ROOT.length + 1));
  assert.deepEqual(bad, []);
});

test('no email source or guide chapter of the in-person staff says VA', () => {
  const bad: string[] = [];
  for (const f of walk(join(ROOT, 'emails', 'src')).filter((x) => /\.(mjs|html|txt)$/.test(x))) if (VA.test(readFileSync(f, 'utf8'))) bad.push(f.slice(ROOT.length + 1));
  // the field guide, the staff guide and the academy seed (the Admin guide names the remote hiring roles, which are VAs)
  for (const f of ['docs/guides/content/field.json', 'docs/guides/content/va.json', 'supabase/seed/academy/r35docs.mjs']) if (VA.test(readFileSync(join(ROOT, f), 'utf8'))) bad.push(f);
  assert.deepEqual(bad, []);
});
