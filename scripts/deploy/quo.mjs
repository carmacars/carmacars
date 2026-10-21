// The Quo phone line (migration 0085): checks the key and sets up our webhook, idempotently. Run by
// scripts/deploy/supabase.sh quo (the deploy) and by .github/workflows/quo-check.yml (check only).
//
//   node --experimental-strip-types --no-warnings scripts/deploy/quo.mjs check
//       the key works; the workspace's numbers (name and number only) and its webhooks (address, events, status)
//   node --experimental-strip-types --no-warnings scripts/deploy/quo.mjs setup --url <webhook url> --number <E.164> --have-key yes|no --out <file>
//       finds the inbox of our number (PN...), then creates our webhook (all call and text events, that inbox only) or
//       keeps it up to date; a new signing secret (created, or rotated because the vault has none) is written to --out
//       (mode 600), never printed. Prints {phone_number_id, number_name, webhook_id, action}.
//
// Needs QUO_API_KEY (the CarmaCars workspace's key: this script never sees another account's key). QUO_API_BASE
// overrides https://api.openphone.com.
import fs from 'node:fs';
import { listNumbers, listWebhooks, ensureWebhook, DEFAULT_QUO_BASE } from '../../web/src/features/phone/quo-api.ts';
import { EVENTS } from '../../web/src/features/phone/webhook.ts';

const key = process.env.QUO_API_KEY;
const base = process.env.QUO_API_BASE || DEFAULT_QUO_BASE;
const arg = (n) => { const i = process.argv.indexOf(`--${n}`); return i > 0 ? process.argv[i + 1] : undefined; };
const digits = (s) => String(s ?? '').replace(/[^0-9]/g, '').replace(/^1(?=\d{10}$)/, '');
const fail = (m) => { console.error(m); process.exit(1); };

if (!key) fail('QUO_API_KEY is not set');
const o = { key, base };
const cmd = process.argv[2];

if (cmd === 'check') {
  let nums;
  try { nums = await listNumbers(o); } catch (e) { fail(`The key does not work at ${base}: ${e.message}`); }
  console.log(`Quo key works at ${base}. Phone numbers in this workspace: ${nums.length}`);
  for (const n of nums) console.log(`  ${n.name ?? '(no name)'}: ${n.number}`);
  try {
    const hooks = await listWebhooks(o);
    console.log(`Webhooks: ${hooks.length}`);
    for (const w of hooks) console.log(`  ${w.url} (${w.status}, ${w.events?.length ?? 0} events${w.label ? `, ${w.label}` : ''})`);
  } catch (e) { console.log(`Webhooks could not be listed: ${e.message}`); }
} else if (cmd === 'setup') {
  const url = arg('url'), number = arg('number'), out = arg('out');
  if (!url || !number || !out) fail('setup needs --url, --number and --out');
  const nums = await listNumbers(o);
  const ours = nums.find((n) => digits(n.number) === digits(number));
  if (!ours) fail(`The CarmaCars number ${number} (Site settings) is not in this Quo workspace; its numbers: ${nums.map((n) => n.number).join(', ') || 'none'}`);
  const r = await ensureWebhook(o, { url, events: EVENTS, resourceIds: [ours.id], label: 'CarmaCars platform (calls and texts)', haveKey: arg('have-key') === 'yes' });
  if (r.key) fs.writeFileSync(out, r.key, { mode: 0o600 });
  console.log(JSON.stringify({ phone_number_id: ours.id, number_name: ours.name, webhook_id: r.id, action: r.action, new_key: !!r.key }));
} else {
  fail('usage: quo.mjs check | setup --url <url> --number <E.164> --have-key yes|no --out <file>');
}
