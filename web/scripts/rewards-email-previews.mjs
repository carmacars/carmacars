// The Rewards emails as Admin > Settings > Rewards previews them (r48, migration 3000): each email filled with its sample
// values by the emails' own engine, the same HTML a renter receives. Run after `node emails/build.mjs` when a Rewards
// email changes; the output is committed (the site's build has no access to the emails folder).
//   node web/scripts/rewards-email-previews.mjs           writes web/src/generated/rewards-emails.json
//   node web/scripts/rewards-email-previews.mjs --check   exits 1 when it is out of date
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { render, renderText } from '../../emails/src/engine.mjs';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const EMAILS = path.resolve(WEB, '../emails');
const OUT = path.join(WEB, 'src/generated/rewards-emails.json');
const cat = JSON.parse(fs.readFileSync(path.join(EMAILS, 'catalogue.json'), 'utf8'));
const globals = Object.fromEntries(cat.global_variables.map((v) => [v.name, v.sample]));
const out = {};
for (const e of cat.emails.filter((x) => x.code.startsWith('renter_rewards_')).sort((a, b) => a.code.localeCompare(b.code))) {
  const values = { ...globals, ...Object.fromEntries(e.variables.map((v) => [v.name, v.sample])), unsubscribe_url: 'https://carmacars.ca/unsubscribe?token=preview' };
  out[e.code] = { subject: renderText(e.subject, values), category: e.category, timing: e.timing,
    html: render(fs.readFileSync(path.join(EMAILS, e.template_html), 'utf8'), values).replace(/\n\s+/g, '\n') };
}
const json = JSON.stringify(out, null, 1) + '\n';
if (process.argv.includes('--check')) {
  if (!fs.existsSync(OUT) || fs.readFileSync(OUT, 'utf8') !== json) { console.error('out of date: web/src/generated/rewards-emails.json (node web/scripts/rewards-email-previews.mjs)'); process.exit(1); }
  console.log('rewards email previews are up to date');
} else {
  fs.writeFileSync(OUT, json);
  console.log(`wrote ${Object.keys(out).length} Rewards email previews`);
}
