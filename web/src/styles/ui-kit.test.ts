// r35 UX: the style guide's guard (docs/style-guide.md). One button shape everywhere: no stylesheet gives .btn its own
// corners outside the two that define it (core.css, ui-kit.css), no page gives a .btn button an inline look (background,
// border or corners), and every portal layout loads the style guide's sheet last.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const SRC = fileURLToPath(new URL('../', import.meta.url));
function files(dir: string, ext: string, out: string[] = []): string[] {
  for (const f of readdirSync(dir)) {
    const p = join(dir, f);
    if (statSync(p).isDirectory()) { if (f !== 'node_modules') files(p, ext, out); } else if (p.endsWith(ext)) out.push(p);
  }
  return out;
}

// the rules allowed to shape a button by themselves: the round +/- steppers of the field portal and the ripple's dot
const ALLOWED = [/\.fd-stepper \.btn\b/, /\.btn::after\b/];

test('no stylesheet gives .btn its own corners (one button shape: styles/ui-kit.css)', () => {
  const bad: string[] = [];
  for (const f of files(SRC, '.css')) {
    const rel = relative(SRC, f);
    if (rel === 'styles/core.css' || rel === 'styles/ui-kit.css') continue;
    const css = readFileSync(f, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
    for (const m of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const sel = m[1]!.trim(); const body = m[2]!;
      if (!/\.btn(?![\w-])|\.btn--[\w-]+/.test(sel) || !/border-radius\s*:/.test(body)) continue;
      if (/border-radius\s*:\s*var\(--(r-pill|ui-r-pill)\)/.test(body)) continue;
      if (ALLOWED.some((a) => a.test(sel))) continue;
      bad.push(`${rel}: ${sel}`);
    }
  }
  assert.deepEqual(bad, []);
});

test('no .btn button has an inline look of its own (background, border or corners)', () => {
  const bad: string[] = [];
  for (const f of files(SRC, '.tsx')) {
    const src = readFileSync(f, 'utf8');
    for (const m of src.matchAll(/<(button|a|Link)\b[^>]*className=["{`][^>]*\bbtn\b[^>]*>/g)) {
      const style = m[0].match(/style=\{\{([^}]*)\}\}/);
      if (style && /\b(background|border|borderRadius|boxShadow)\b/.test(style[1]!)) bad.push(`${relative(SRC, f)}: ${m[0].slice(0, 80)}`);
    }
  }
  assert.deepEqual(bad, []);
});

test('every portal layout loads the style guide last', () => {
  for (const p of ['app/admin/layout.tsx', 'app/staff/layout.tsx', 'app/staff/field/layout.tsx', 'app/account/layout.tsx', 'app/owner/layout.tsx', 'app/investor/layout.tsx']) {
    const css = [...readFileSync(join(SRC, p), 'utf8').matchAll(/import '@\/styles\/([\w-]+)\.css'/g)].map((m) => m[1]);
    assert.equal(css[css.length - 1], 'ui-kit', p);
  }
});
