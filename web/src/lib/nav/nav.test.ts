import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { scrollOption, staysOnPage } from './same-page.ts';

describe('staysOnPage: a click on the page you are on keeps the scroll', () => {
  it('knows a tab, a filter, a page and a clear on the same path', () => {
    assert.equal(staysOnPage('/admin/visitors?view=history', '/admin/visitors'), true);
    assert.equal(staysOnPage('/admin/visitors', '/admin/visitors'), true);
    assert.equal(staysOnPage('?tab=emails', '/admin/hiring/abc'), true);
    assert.equal(staysOnPage('/admin/money/', '/admin/money'), true);
    assert.equal(staysOnPage({ pathname: '/admin/owners', query: { view: 'checklist' } }, '/admin/owners'), true);
  });
  it('sends a real navigation to the top', () => {
    assert.equal(staysOnPage('/admin/owners', '/admin/visitors'), false);
    assert.equal(staysOnPage('/admin/owners/abc?tab=invoices', '/admin/owners'), false);
    assert.equal(staysOnPage('/account/bookings/CC-1', '/account/bookings/CC-2'), false);
    assert.equal(staysOnPage('https://example.test/admin/visitors', '/admin/visitors'), false);
    assert.equal(staysOnPage('mailto:a@example.test', '/admin/visitors'), false);
  });
  it('leaves a #hash to the browser', () => {
    assert.equal(staysOnPage('/admin/visitors#rubric', '/admin/visitors'), false);
    assert.equal(staysOnPage('#top', '/admin/visitors'), false);
  });
  it('router calls: scroll is off only for the same page', () => {
    assert.deepEqual(scrollOption('/admin/visitors?x=1', '/admin/visitors'), { scroll: false });
    assert.deepEqual(scrollOption('/admin/owners/1', '/admin/visitors'), { scroll: true });
  });
});

/** Every source file under src, as [path, text]. */
function sources(dir: string, out: Array<[string, string]> = []): Array<[string, string]> {
  for (const f of readdirSync(dir)) {
    const p = join(dir, f);
    if (statSync(p).isDirectory()) sources(p, out);
    else if (/\.tsx?$/.test(f) && !f.endsWith('.test.ts')) out.push([p, readFileSync(p, 'utf8')]);
  }
  return out;
}

describe('the code keeps clicks from jumping the page', () => {
  const files = sources(join(process.cwd(), 'src'));
  it('imports Link only from the shared component', () => {
    const bad = files.filter(([p, s]) => !p.endsWith('components/Link.tsx') && /from ['"]next\/link['"]/.test(s)).map(([p]) => p);
    assert.deepEqual(bad, []);
  });
  it('has no href="#" links', () => {
    assert.deepEqual(files.filter(([, s]) => /href=["']#["']/.test(s)).map(([p]) => p), []);
  });
  it('gives every <button> with an onClick a type, so it never submits the form it sits in', () => {
    const bad: string[] = [];
    for (const [p, s] of files) s.split('\n').forEach((line, i) => { if (/<button\b/.test(line) && /onClick=/.test(line) && !/\btype=/.test(line)) bad.push(`${p}:${i + 1}`); });
    assert.deepEqual(bad, []);
  });
  it('router.push / replace with only a query keep the scroll', () => {
    const bad: string[] = [];
    for (const [p, s] of files) s.split('\n').forEach((line, i) => { if (/router\.(push|replace)\(\s*[`'"]\?/.test(line) && !/scroll/.test(line)) bad.push(`${p}:${i + 1}`); });
    assert.deepEqual(bad, []);
  });
});
