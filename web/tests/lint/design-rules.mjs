#!/usr/bin/env node
// The owner's design rules (design-rules-reels.md, release 48 AN) as a check over every stylesheet of the web app:
//   vh      a height in 100vh with no 100dvh beside it (phones: the address bar);
//   linear  a UI transition or animation with linear easing (spinners and progress bars say design-allow);
//   hex     a solid border in a hex colour (borders use alpha colours: rgb(0 0 0 / 0.12), oklch(... / a), a token);
//   input   a field (input, select, textarea) under 16px (iOS zooms in);
//   slow    a transition or animation over 300 ms.
// A line (or the line above it) with "design-allow" and a reason is let through. What the code base had when the check
// came in is listed in design-rules.baseline.json and reported as a count, so only new breaches fail:
//   node tests/lint/design-rules.mjs            fails on a breach not in the baseline
//   node tests/lint/design-rules.mjs --update   writes the baseline (only ever to remove fixed entries)
import { readFileSync, writeFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const WEB = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SRC = join(WEB, 'src');
const BASELINE = join(dirname(fileURLToPath(import.meta.url)), 'design-rules.baseline.json');

function* cssFiles(dir) {
  for (const f of readdirSync(dir)) {
    const p = join(dir, f);
    if (statSync(p).isDirectory()) yield* cssFiles(p);
    else if (f.endsWith('.css')) yield p;
  }
}
const ms = (v) => (v.endsWith('ms') ? Number(v.slice(0, -2)) : Number(v.slice(0, -1)) * 1000);

/** The breaches of one stylesheet: [{ rule, line, text }]. Exported for the unit test. */
export function breaches(css) {
  const out = [];
  const lines = css.split('\n');
  const allowed = (i) => /design-allow/.test(lines[i]) || (i > 0 && /design-allow/.test(lines[i - 1]));
  lines.forEach((text, i) => {
    if (allowed(i)) return;
    const add = (rule) => out.push({ rule, line: i + 1, text: text.trim() });
    if (/(^|[\s:(,])100vh\b/.test(text) && !/100dvh/.test(text)) add('vh');
    for (const m of text.matchAll(/(?:^|[;{\s])(transition|animation)(?:-[a-z-]+)?\s*:\s*([^;{}]*)/g)) {
      const v = m[2];
      if (/\blinear\b/.test(v) && !/spin|progress|marquee|toast-time|scroll/i.test(v)) add('linear');
      for (const d of v.matchAll(/(?<![\w-])(\d*\.?\d+)(ms|s)\b/g)) { if (ms(d[1] + d[2]) > 300) { add('slow'); break; } }
    }
    if (/border(?:-(?:top|right|bottom|left|block|inline)(?:-(?:start|end))?)?\s*:[^;{}]*\bsolid\s+#[0-9a-f]{3,8}\b/i.test(text)) add('hex');
  });
  // fields under 16px: a rule whose selector names a field and sets a smaller font size
  for (const m of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const sel = m[1], body = m[2];
    if (!/(^|[\s,>+~(])(input|select|textarea|\.input|\.select|\.textarea)(?![\w-])/.test(sel)) continue;
    if (/:(focus|hover|placeholder|autofill)|::|checkbox|radio|range|type="(checkbox|radio|range|submit|button|color|file)"/.test(sel)) continue;
    const f = /font-size\s*:\s*([\d.]+)(px|rem|em)\b/.exec(body);
    if (!f) continue;
    const px = f[2] === 'px' ? Number(f[1]) : Number(f[1]) * 16;
    if (px < 16) {
      const line = css.slice(0, m.index).split('\n').length;
      if (!/design-allow/.test(lines[line - 1] ?? '') && !/design-allow/.test(lines[line - 2] ?? '')) out.push({ rule: 'input', line, text: sel.trim().slice(0, 120) });
    }
  }
  return out;
}

const key = (file, b) => `${file}|${b.rule}|${createHash('sha1').update(b.text).digest('hex').slice(0, 12)}`;

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const found = new Map();
  for (const f of cssFiles(SRC)) {
    const rel = relative(WEB, f);
    for (const b of breaches(readFileSync(f, 'utf8'))) {
      const k = key(rel, b);
      found.set(k, [...(found.get(k) ?? []), { ...b, file: rel }]);
    }
  }
  const base = existsSync(BASELINE) ? JSON.parse(readFileSync(BASELINE, 'utf8')) : {};
  if (process.argv.includes('--update')) {
    const out = Object.fromEntries([...found.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, v.length]));
    writeFileSync(BASELINE, JSON.stringify(out, null, 1) + '\n');
    console.log(`design rules: baseline written, ${Object.keys(out).length} known breaches`);
    process.exit(0);
  }
  const fresh = [];
  for (const [k, v] of found) if (v.length > (base[k] ?? 0)) fresh.push(...v.slice(base[k] ?? 0));
  const known = [...found.values()].reduce((a, v) => a + v.length, 0) - fresh.length;
  if (fresh.length) {
    for (const b of fresh) console.error(`${b.file}:${b.line}  ${b.rule}  ${b.text.slice(0, 140)}`);
    console.error(`design rules: ${fresh.length} new breach(es) (vh: use 100dvh; linear: ease; hex: an alpha border; input: 16px or more; slow: 300 ms or less), ${known} known`);
    process.exit(1);
  }
  console.log(`design rules: no new breach (${known} known in the baseline, to fix over time)`);
}
