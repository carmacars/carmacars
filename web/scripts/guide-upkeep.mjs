// Guide upkeep (migration 0049): the screenshots the guides workflow just took on the local stack are cropped exactly as
// the guides crop them (docs/guides/src/export.py, into a folder of its own), each crop is compared with the image the
// guide shows now (the committed one, or the one an earlier run put in its place), and a crop that looks different is
// sent to the site's job endpoint: stored in the public bucket, put in place of the old image in every draft and
// published copy of the guides, and its sections flagged "needs review" in Admin > Settings > Guides.
//
//   node scripts/guide-upkeep.mjs --shots <guide-shots out dir> --out <dir> [--threshold 0.03] [--apply --base https://carmacars.ca]
//
// The comparison is perceptual, not byte for byte: both images are made 160 pixels wide and grey, the shapes compared
// (a different aspect ratio is a change), and the mean difference of the pixels decides (default above 3%), so a new
// date or a name of the same length on a screen is not a change, while a moved button, a new field or a new section is.
// --apply needs the jobs' token (LINK_SIGNING_KEY, as guides-pdf.mjs). Without --apply it only reports.
import { createHmac } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ROOT = path.resolve(WEB, '..');
const SRC = path.join(ROOT, 'docs/guides/src');
const arg = (n, d) => { const i = process.argv.indexOf(n); return i > 0 ? process.argv[i + 1] : d; };
const SHOTS = arg('--shots');
const OUT = path.resolve(arg('--out', 'reports/guide-upkeep'));
const THRESHOLD = Number(arg('--threshold', '0.03'));
const APPLY = process.argv.includes('--apply');
const BASE = (arg('--base', process.env.APP_URL ?? 'http://localhost:3000') ?? '').replace(/\/$/, '');
const RUN = arg('--run', process.env.GITHUB_RUN_ID ?? `local-${new Date().toISOString().slice(0, 10)}`);
if (!SHOTS) { console.error('--shots <dir> is required'); process.exit(2); }
fs.mkdirSync(path.join(OUT, 'img'), { recursive: true });

function token() {
  let key = process.env.LINK_SIGNING_KEY;
  if (!key) { const env = path.join(WEB, '.env.local'); const m = fs.existsSync(env) ? /^LINK_SIGNING_KEY=(.*)$/m.exec(fs.readFileSync(env, 'utf8')) : null; key = m?.[1]?.trim(); }
  if (!key) throw new Error('LINK_SIGNING_KEY is not set');
  return createHmac('sha256', key).update('carmacars-listing-worker-v1').digest('hex');
}

// 1. crop the new screens as the guides do
execFileSync('python3', ['export.py'], { cwd: SRC, stdio: ['ignore', 'pipe', 'inherit'],
  env: { ...process.env, GUIDE_SCREENS: path.resolve(SHOTS), GUIDE_IMG: path.join(OUT, 'img'), GUIDE_CONTENT: path.join(OUT, 'content') } });

// 2. what each committed image is replaced by now
const current = new Map();
if (APPLY) {
  const r = await fetch(`${BASE}/api/jobs/guide-upkeep`, { headers: { authorization: `Bearer ${token()}` } });
  if (!r.ok) throw new Error(`GET ${BASE}/api/jobs/guide-upkeep: ${r.status}`);
  for (const x of (await r.json()).images) current.set(x.replaces_url, x.url);
}
const latest = (url) => { let u = url; for (let i = 0; i < 50 && current.has(u); i++) u = current.get(u); return u; };

// 3. compare
async function shape(buf) {
  const m = await sharp(buf).metadata();
  const raw = await sharp(buf).resize(160, Math.max(8, Math.round(160 * m.height / m.width)), { fit: 'fill' }).grayscale().raw().toBuffer({ resolveWithObject: true });
  return { ratio: m.height / m.width, data: raw.data, w: raw.info.width, h: raw.info.height, width: m.width, height: m.height };
}
function difference(a, b) {
  if (Math.abs(a.ratio - b.ratio) / b.ratio > 0.03) return 1;
  const h = Math.min(a.h, b.h); let sum = 0;
  for (let i = 0; i < a.w * h; i++) sum += Math.abs(a.data[i] - b.data[i]);
  return sum / (a.w * h * 255);
}
const portalOf = (name) => (name.startsWith('public-') ? 'renter' : name.startsWith('va-') ? 'va' : name.split('-')[0]);
const report = { run: RUN, threshold: THRESHOLD, compared: 0, unchanged: 0, changed: [], skipped: [], applied: [] };
for (const name of fs.readdirSync(path.join(OUT, 'img')).filter((n) => n.endsWith('.jpg')).sort()) {
  const committed = path.join(SRC, 'img', name);
  if (!fs.existsSync(committed)) { report.skipped.push({ name, why: 'not used by a guide yet' }); continue; }
  const fresh = fs.readFileSync(path.join(OUT, 'img', name));
  const shown = latest(`/guides/img/${name}`);
  let before;
  if (shown.startsWith('/guides/img/')) before = fs.readFileSync(committed);
  else { const r = await fetch(shown); if (!r.ok) { report.skipped.push({ name, why: `the current image did not load (${r.status})` }); continue; } before = Buffer.from(await r.arrayBuffer()); }
  const [a, b] = await Promise.all([shape(fresh), shape(before)]);
  const diff = Math.round(difference(a, b) * 1000) / 1000;
  report.compared++;
  if (diff <= THRESHOLD) { report.unchanged++; continue; }
  const item = { name, portal: portalOf(name), diff, old_url: shown, width: a.width, height: a.height };
  report.changed.push(item);
  if (APPLY) {
    const q = new URLSearchParams({ portal: item.portal, old_url: shown, diff: String(diff), width: String(a.width), height: String(a.height), run: RUN });
    const r = await fetch(`${BASE}/api/jobs/guide-upkeep?${q}`, { method: 'POST', headers: { authorization: `Bearer ${token()}`, 'content-type': 'image/jpeg' }, body: fresh });
    const j = await r.json().catch(() => ({ ok: false }));
    report.applied.push({ name, ok: !!j.ok, sections: j.sections ?? 0, url: j.url ?? null, status: r.status });
  }
}
fs.writeFileSync(path.join(OUT, 'report.json'), JSON.stringify(report, null, 1));
console.log(`${report.compared} screenshots compared: ${report.unchanged} unchanged, ${report.changed.length} changed${APPLY ? `, ${report.applied.filter((x) => x.ok).length} replaced in the guides` : ' (report only)'}; ${report.skipped.length} skipped`);
for (const c of report.changed) console.log(`changed: ${c.name} (${Math.round(c.diff * 100)}% different)`);
