#!/usr/bin/env node
// The positive-copy check of the SEO templates (release 36; web/src/features/seo/copy-lint.ts): fails when a search
// page template says what we lack ("not available", "we don't have", "we don't offer", "no car matches" ...). Comments
// are skipped. Runs in CI with the text check (scripts/check-text.sh).
//
//   node --experimental-strip-types --no-warnings scripts/check-seo-copy.mjs
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { lintSource, SEO_TEMPLATE_GLOBS, SEO_TEMPLATE_SKIP } from '../web/src/features/seo/copy-lint.ts';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const files = execFileSync('git', ['ls-files', '-z', '--', ...SEO_TEMPLATE_GLOBS.map((g) => `:(glob)${g}`), ':(glob)supabase/migrations/20??_r36s_*.sql'], { cwd: ROOT })
  .toString('utf8').split('\0').filter(Boolean).filter((f) => !SEO_TEMPLATE_SKIP.test(f));
let hits = 0;
for (const f of files) {
  const full = path.join(ROOT, f);
  if (!fs.existsSync(full)) continue;
  for (const h of lintSource(fs.readFileSync(full, 'utf8'), f.endsWith('.sql'))) {
    console.log(`${f}:${h.line}: "${h.hit.phrase}" (${h.hit.say})`);
    hits++;
  }
}
if (hits) { console.log(`SEO COPY CHECK FAILED: ${hits} negative phrase(s) in ${files.length} SEO template files`); process.exit(1); }
console.log(`SEO COPY CHECK PASSED (${files.length} files)`);
