// The language versions' strings (release 36, part 2; migration 2004; .github/workflows/seo-i18n.yml).
//   node --experimental-strip-types web/scripts/seo-i18n.mjs sources > load.json        the catalog as {sources, missing: true}
//   MISSING=<file> MAX=<n> node ... seo-i18n.mjs translate > strings.json               machine translation of what is missing
// The translation is Workers AI's m2m100 model through the Cloudflare API (the account's free daily allowance: MAX
// strings a run). A translation that loses or adds a placeholder is refused (the page keeps the English string, and the
// language stays noindex until enough strings are translated). A person can replace any string later (status reviewed).
import fs from 'node:fs';
import { CATALOG, protect, restore, validTranslation } from '../src/features/i18n/catalog.ts';

const cmd = process.argv[2];
if (cmd === 'sources') {
  process.stdout.write(JSON.stringify({ sources: Object.entries(CATALOG).map(([key, text]) => ({ key, text })), missing: true }));
} else if (cmd === 'translate') {
  const missing = JSON.parse(fs.readFileSync(process.env.MISSING ?? 'missing.json', 'utf8')) ?? [];
  const acct = process.env.CLOUDFLARE_ACCOUNT_ID, token = process.env.CLOUDFLARE_API_TOKEN;
  const out = [];
  let refused = 0, failed = 0;
  if (!acct || !token) console.error('::notice title=seo-i18n::no Cloudflare account or token: the pages keep their English strings for now');
  else {
    for (const m of missing.slice(0, Number(process.env.MAX ?? 800))) {
      const p = protect(m.text);
      try {
        const r = await fetch(`https://api.cloudflare.com/client/v4/accounts/${acct}/ai/run/@cf/meta/m2m100-1.2b`, {
          method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
          body: JSON.stringify({ text: p.text, source_lang: 'en', target_lang: m.mt_code }), signal: AbortSignal.timeout(60_000) });
        if (!r.ok) { failed++; if (r.status === 429) break; continue; }
        const text = restore(String((await r.json())?.result?.translated_text ?? ''), p.names);
        if (validTranslation(m.text, text)) out.push({ lang: m.lang, key: m.key, text: text.trim(), source_hash: m.hash, status: 'machine' }); else refused++;
      } catch { failed++; }
    }
  }
  console.error(`::notice title=seo-i18n::${out.length} translated, ${refused} refused (placeholders), ${failed} failed, ${Math.max(0, missing.length - out.length - refused - failed)} left for the next run`);
  process.stdout.write(JSON.stringify({ strings: out }));
} else { console.error('usage: seo-i18n.mjs sources|translate'); process.exit(2); }
