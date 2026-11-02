import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

// No page uses the browser's own date picker any more (Release 27): every date goes through DateInput / DateRangePicker.
function walk(dir: string, out: string[] = []): string[] {
  for (const f of readdirSync(dir)) { const p = join(dir, f); if (statSync(p).isDirectory()) walk(p, out); else if (/\.tsx$/.test(p)) out.push(p); }
  return out;
}
describe('shared date fields', () => {
  it('no <input type="date|datetime-local|time"> is left outside DateInput', () => {
    const bad: string[] = [];
    for (const p of walk('src')) {
      if (p.endsWith('components/DateInput.tsx')) continue;
      const s = readFileSync(p, 'utf8');
      if (/<input\b[^>]*\btype="(date|datetime-local|time)"/.test(s)) bad.push(p);
    }
    assert.deepEqual(bad, []);
  });
});
