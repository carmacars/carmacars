// Guide upkeep (migration 0049): the screenshots the guides workflow just took on the local stack are cropped exactly as
// the guides crop them (docs/guides/src/export.py, into a folder of its own), each crop is compared with the image the
// guide shows now (the committed one, or the one an earlier run put in its place), and a crop that looks different is
// sent to the site's job endpoint: stored in the public bucket, put in place of the old image in every draft and
// published copy of the guides; the text of its sections is then checked (below).
//
//   node scripts/guide-upkeep.mjs --shots <guide-shots out dir> --out <dir> [--threshold 0.03] [--apply --base https://carmacars.ca]
//
// The comparison is perceptual, not byte for byte: both images are made 160 pixels wide and grey, the shapes compared
// (a different aspect ratio is a change), and the mean difference of the pixels decides (default above 3%), so a new
// date or a name of the same length on a screen is not a change, while a moved button, a new field or a new section is.
// --apply needs the jobs' token (LINK_SIGNING_KEY, as guides-pdf.mjs). Without --apply it only reports.
//
// The text keeps up too (migration 0055). With --rewrite, after the screenshots: every section whose screenshot changed in
// this run, or that names a button no screen of this commit shows (the label check), is sent to the rewrite job with its
// facts, read from the code (portal-facts.mjs: the portal's menu, the labels of the screens the section shows, and for
// each missing button the closest labels that exist), with the sections the last run could not rewrite (0059). The job
// asks Workers AI for the new text and publishes it when it passes the checks, asking again more strictly when it does
// not; nothing waits for review. A section it still cannot rewrite keeps its old text (button names fixed where possible)
// and is logged for the next run. At most --max sections a run (default 15).
//   node scripts/guide-upkeep.mjs --last-sha --base <url>                   prints the commit of the last finished run
//   node scripts/guide-upkeep.mjs --finish --run <id> --sha <sha> [--pdfs n] --base <url>   records the run as done
import { createHmac } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { portalFacts, screenLabels } from './portal-facts.mjs';
import { closestLabels, missingLabels, navPathProblems, sectionAddresses } from '../src/features/guides/upkeep.ts';

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
const REWRITE = process.argv.includes('--rewrite');
const MAX = Number(arg('--max', '15'));

function token() {
  let key = process.env.LINK_SIGNING_KEY;
  if (!key) { const env = path.join(WEB, '.env.local'); const m = fs.existsSync(env) ? /^LINK_SIGNING_KEY=(.*)$/m.exec(fs.readFileSync(env, 'utf8')) : null; key = m?.[1]?.trim(); }
  if (!key) throw new Error('LINK_SIGNING_KEY is not set');
  return createHmac('sha256', key).update('carmacars-listing-worker-v1').digest('hex');
}
const job = async (p, init = {}) => {
  const r = await fetch(`${BASE}${p}`, { ...init, headers: { authorization: `Bearer ${token()}`, ...(init.body ? { 'content-type': 'application/json' } : {}), ...(init.headers ?? {}) } });
  if (!r.ok) throw new Error(`${init.method ?? 'GET'} ${p}: ${r.status} ${(await r.text()).slice(0, 200)}`);
  return r.json();
};

if (process.argv.includes('--last-sha')) { console.log((await job('/api/jobs/guide-upkeep-run')).sha ?? ''); process.exit(0); }
if (process.argv.includes('--finish')) {
  const prev = fs.existsSync(path.join(OUT, 'report.json')) ? JSON.parse(fs.readFileSync(path.join(OUT, 'report.json'), 'utf8')) : {};
  const r = await job('/api/jobs/guide-upkeep-run', { method: 'POST', body: JSON.stringify({ run: RUN, sha: arg('--sha', ''), status: arg('--status', 'done'),
    images: prev.applied?.filter((x) => x.ok).length ?? 0, sections_rewritten: prev.rewritten?.length ?? 0, sections_flagged: prev.kept?.length ?? 0,
    pdfs: Number(arg('--pdfs', '0')) || 0, result: { changed: (prev.changed ?? []).map((c) => c.name), rewritten: prev.rewritten ?? [], kept: prev.kept ?? [] } }) });
  console.log(`guide upkeep run ${RUN} recorded: ${r.run.status}, ${r.run.images} screenshots, ${r.run.sections_rewritten} sections rewritten, ${r.run.sections_flagged} kept for the next run, ${r.run.pdfs} PDFs`);
  process.exit(0);
}
if (!SHOTS) { console.error('--shots <dir> is required'); process.exit(2); }
fs.mkdirSync(path.join(OUT, 'img'), { recursive: true });

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
// 4. the text: sections whose screenshot changed, and sections naming buttons no screen shows
report.rewritten = []; report.kept = []; report.label_problems = [];
if (REWRITE && APPLY) {
  const facts = portalFacts();
  const labels = facts.labels;
  const plain = labels.filter((l) => !l.startsWith('~'));
  const navOf = (portal) => (portal === 'renter' ? [...facts.nav.renter] : facts.nav[portal] ?? []);
  const { sections } = await job(`/api/jobs/guide-rewrite?run=${encodeURIComponent(RUN)}`);
  const targets = [];
  for (const s of sections) {
    if (s.is_hidden) continue;
    const missing = missingLabels(s.body_md, labels);
    const paths = navPathProblems(s.body_md, navOf(s.portal));
    if (missing.length || paths.length) report.label_problems.push({ portal: s.portal, slug: s.slug, missing, paths });
    const changed = (s.images_changed ?? []).length > 0;
    const pending = !changed && !!s.pending;
    if (!changed && !missing.length && !paths.length && !s.retry && !pending) continue;
    const reason = [changed ? 'A screenshot in this section changed' : '', missing.length ? `It names buttons the portals no longer show (${missing.slice(0, 3).join(', ')})` : '',
      paths.length ? `Its menu paths do not match the menu (${paths.slice(0, 3).join('; ')})` : '', pending ? 'A screenshot in this section changed since its text was last checked' : '', s.retry ? 'The last run could not rewrite it' : ''].filter(Boolean).join('; ');
    targets.push({ s, missing, reason });
  }
  let paused = false;
  for (const { s, missing, reason } of targets.slice(0, MAX)) {
    // Workers AI paused for the day (the usage guard, 0104): no more calls this run; the next run takes them
    if (paused) { report.kept.push({ portal: s.portal, slug: s.slug, result: 'paused', summary: 'Workers AI is paused for today: the next run takes it', problems: [] }); continue; }
    const screen = [...new Set([...screenLabels(facts, sectionAddresses(s.body_md)).filter((l) => !l.startsWith('~')), ...navOf(s.portal).flatMap((g) => [g.group, ...g.links])])];
    const pool = screen.length > 20 ? screen : plain;
    const sectionFacts = { portal: s.portal, nav: navOf(s.portal).map((g) => ({ group: g.group, links: g.links })), screen_labels: screen,
      missing: missing.map((label) => ({ label, closest: closestLabels(label, pool).length ? closestLabels(label, pool) : closestLabels(label, plain) })) };
    try {
      const r = await job('/api/jobs/guide-rewrite', { method: 'POST', body: JSON.stringify({ section_id: s.id, run: RUN, reason, facts: sectionFacts, labels }) });
      if (r.paused) paused = true;
      const item = { portal: s.portal, slug: s.slug, result: r.result ?? (r.ok ? 'unknown' : 'model'), attempts: r.attempts ?? 1, labels_only: !!r.labels_only, summary: r.summary ?? r.message ?? '', problems: r.problems ?? [] };
      if (r.result !== 'same') (r.result === 'updated' ? report.rewritten : report.kept).push(item);
    } catch (e) { report.kept.push({ portal: s.portal, slug: s.slug, result: 'error', summary: String(e.message ?? e).slice(0, 200), problems: [] }); }
  }
  if (targets.length > MAX) report.kept.push(...targets.slice(MAX).map(({ s }) => ({ portal: s.portal, slug: s.slug, result: 'later', summary: `more than ${MAX} sections this run: the next run takes it`, problems: [] })));
}
fs.writeFileSync(path.join(OUT, 'report.json'), JSON.stringify(report, null, 1));
console.log(`${report.compared} screenshots compared: ${report.unchanged} unchanged, ${report.changed.length} changed${APPLY ? `, ${report.applied.filter((x) => x.ok).length} replaced in the guides` : ' (report only)'}; ${report.skipped.length} skipped`);
for (const c of report.changed) console.log(`changed: ${c.name} (${Math.round(c.diff * 100)}% different)`);
if (REWRITE) {
  console.log(`text: ${report.rewritten.length} sections rewritten and published, ${report.kept.length} kept their text for the next run; ${report.label_problems.length} sections named missing buttons`);
  for (const x of report.rewritten) console.log(`rewritten: ${x.portal}/${x.slug}${x.attempts > 1 ? ` (attempt ${x.attempts})` : ''}: ${x.summary}`);
  for (const x of report.kept) console.log(`next run: ${x.portal}/${x.slug} (${x.result}): ${[x.summary, ...x.problems].filter(Boolean).join('; ').slice(0, 240)}`);
}
