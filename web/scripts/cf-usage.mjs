// The usage guard's Cloudflare figures (migration 0080), month to date per Toronto day: Worker requests and CPU time,
// Workers AI neurons, R2 storage. Run every hour by .github/workflows/usage.yml, which hands the JSON to
// app.usage_record_external() in the database. Parts the token may not read are listed under "unavailable".
//   CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=... node --experimental-strip-types scripts/cf-usage.mjs --out usage.json
import fs from 'node:fs';
import { cloudflareUsage } from '../src/features/usage/cloudflare.ts';

const token = process.env.CLOUDFLARE_API_TOKEN, account = process.env.CLOUDFLARE_ACCOUNT_ID;
const i = process.argv.indexOf('--out');
const out = i > 0 ? process.argv[i + 1] : null;
let report;
if (!token || !account) report = { source: 'cloudflare', days: [], unavailable: { all: 'CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID are needed' } };
else report = await cloudflareUsage({ token, account });
if (out) fs.writeFileSync(out, JSON.stringify(report));
console.log(JSON.stringify({ days: report.days.length, last: report.days.at(-1) ?? null, unavailable: report.unavailable }, null, 2));
