#!/usr/bin/env node
// Guides and academy accuracy gate (r49): the guides (docs/guides/content/*.json) and the academy lessons must name only
// pages, buttons and settings that exist in the app, so a renamed button or a removed page fails CI instead of
// misleading a reader.
//
//   node scripts/check-guides-accuracy.mjs            exits 1 and lists every stale reference
//   node scripts/check-guides-accuracy.mjs --json     the same, as JSON
//
// 1. Pages: every carmacars.ca/<path> address (screenshots and text) and every `/path` in code font must match a route
//    of web/src/app (page.tsx or route.ts; [x] matches one segment, [...x] and [[...x]] the rest) or a redirect of
//    web/next.config.ts.
// 2. Buttons: every **bold label** (the labels of buttons and links, copied from the code) must appear as text in
//    web/src (a string, JSX text or a label) or in a migration that seeds screen text, unless it is in
//    scripts/guides-accuracy-allow.json (a bold word that is not a screen label: a name, a term).
// 3. Settings: every `snake_case` program setting named must be a column or key the code or a migration knows.
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const WEB = join(ROOT, 'web');
const walk = (d, ok, out = []) => {
  for (const e of readdirSync(d, { withFileTypes: true })) {
    if (e.name === 'node_modules' || e.name === '.next' || e.name.startsWith('.')) continue;
    const p = join(d, e.name);
    if (e.isDirectory()) walk(p, ok, out); else if (ok(e.name)) out.push(p);
  }
  return out;
};

// ---- the app's routes
const appDir = join(WEB, 'src', 'app');
const routeFiles = walk(appDir, (n) => /^(page|route)\.(tsx|ts)$/.test(n));
const routes = routeFiles.map((f) => {
  const segs = relative(appDir, dirname(f)).split('/').filter((s) => s && !/^\(.*\)$/.test(s) && !s.startsWith('@'));
  return segs;
});
const matchRoute = (path) => {
  const parts = path.replace(/[?#].*$/, '').split('/').filter(Boolean);
  return routes.some((segs) => {
    for (let i = 0; i < segs.length; i++) {
      const s = segs[i];
      if (/^\[\[\.\.\..+\]\]$/.test(s)) return true;
      if (/^\[\.\.\..+\]$/.test(s)) return parts.length > i;
      if (i >= parts.length) return false;
      if (!/^\[.+\]$/.test(s) && s !== parts[i]) return false;
    }
    return segs.length === parts.length;
  });
};
const nextConfig = existsSync(join(WEB, 'next.config.ts')) ? readFileSync(join(WEB, 'next.config.ts'), 'utf8') : '';
// the pairs of next.config.ts: ['/from', '/to'] (the catch-alls, :path*, are handled by the prefix map below)
const redirectSources = [...nextConfig.matchAll(/\['(\/[^']*)',\s*'\/[^']*'\]/g)].map((m) => m[1]).filter((s) => !s.includes('*'));
const redirected = (path) => redirectSources.some((s) => s === path || (s.includes(':') && new RegExp('^' + s.replace(/:[a-z]+\*?/gi, '[^/]+') + '$').test(path)));

// ---- the app's text
const srcFiles = walk(join(WEB, 'src'), (n) => /\.(tsx|ts)$/.test(n) && !/\.test\./.test(n));
const corpus = srcFiles.map((f) => readFileSync(f, 'utf8')).join('\n');
const migs = walk(join(ROOT, 'supabase', 'migrations'), (n) => n.endsWith('.sql'))
  .filter((f) => !/guide|academy|lesson/i.test(f)) // the guides themselves are not evidence
  .map((f) => readFileSync(f, 'utf8')).join('\n');
const norm = (s) => s.toLowerCase().replace(/&amp;/g, '&').replace(/&#39;|&apos;|[‘’]/g, "'").replace(/\s+/g, ' ');
const hay = norm(corpus);
const hayMig = norm(migs);
// a label with a changing part ("Sign, then pay $... below") matches when each fixed part is in the app; a program setting's
// label is its key in words ("Deposit review required" is deposit_review_required)
const inApp = (label) => {
  const parts = norm(label).split(/\$?\.\.\./).map((x) => x.trim()).filter((x) => x.length > 1);
  if (parts.length && parts.every((l) => hay.includes(l) || hayMig.includes(l))) return true;
  return settingKeys.has(norm(label).replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, ''));
};

const settingKeys = new Set([...(corpus + '\n' + migs).matchAll(/\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b/g)].map((m) => m[0]));
const allow = existsSync(join(ROOT, 'scripts', 'guides-accuracy-allow.json')) ? JSON.parse(readFileSync(join(ROOT, 'scripts', 'guides-accuracy-allow.json'), 'utf8')) : { labels: [], paths: [], settings: [] };
const allowLabel = new Set((allow.labels ?? []).map(norm));
const allowPath = new Set(allow.paths ?? []);
const allowSetting = new Set(allow.settings ?? []);

// ---- the guides and the academy
const sources = []; // { where, text }
const CONTENT = join(ROOT, 'docs', 'guides', 'content');
for (const f of readdirSync(CONTENT).filter((x) => x.endsWith('.json') && x !== 'images.json')) {
  const d = JSON.parse(readFileSync(join(CONTENT, f), 'utf8'));
  for (const s of d.sections ?? []) sources.push({ where: `guide ${d.portal ?? f.replace('.json', '')}/${s.slug}`, text: s.body_md ?? '' });
}

const chapterSlugs = new Set(sources.map((x) => x.where.replace('guide ', '')));
const problems = [];
const seen = new Set();
const add = (kind, where, ref) => { const k = `${kind}|${where}|${ref}`; if (!seen.has(k)) { seen.add(k); problems.push({ kind, where, ref }); } };

for (const { where, text } of sources) {
  // images and their captions carry "address:" metadata
  for (const m of text.matchAll(/address:\s*carmacars\.ca(\/[^\s;"]*)/g)) pathCheck(m[1], where);
  const prose = text.replace(/!\[[^\]]*\]\([^)]*\)/g, ' ');
  for (const m of prose.matchAll(/carmacars\.ca(\/[A-Za-z0-9_\-/\[\]<>]+)/g)) pathCheck(m[1], where);
  for (const m of prose.matchAll(/`(\/[a-z][A-Za-z0-9_\-/\[\]]*)`/g)) pathCheck(m[1], where);
  for (const m of prose.matchAll(/\*\*([^*\n]{2,60})\*\*/g)) {
    const label = m[1].trim().replace(/[:.,;]+$/, '');
    if (!label || !/[A-Za-z]/.test(label) || /^\d/.test(label) || allowLabel.has(norm(label))) continue;
    if (!inApp(label)) add('button', where, label);
  }
  for (const m of prose.matchAll(/`([a-z][a-z0-9]*(?:_[a-z0-9]+)+)`/g)) {
    if (!settingKeys.has(m[1]) && !allowSetting.has(m[1])) add('setting', where, m[1]);
  }
}
function pathCheck(p, where) {
  const clean = p.replace(/<[^>]*>/g, 'x').replace(/[.,;:)]+$/, '').replace(/\/$/, '') || '/';
  if (allowPath.has(clean) || clean.startsWith('/guides/') || clean.startsWith('/_')) return;
  // the catch-all redirects of next.config.ts: /va/<x> opens /staff/<x>, /field/<x> opens /staff/field/<x>
  const mapped = clean === '/va' ? '/staff' : clean.startsWith('/va/') ? '/staff/' + clean.slice(4) : clean === '/field' ? '/staff/field' : clean.startsWith('/field/') ? '/staff/field/' + clean.slice(7) : null;
  if (!matchRoute(clean) && !redirected(clean) && !(mapped && matchRoute(mapped))) add('page', where, clean);
}

// the academy lessons point to guide chapters (guide_refs 'portal/slug'): each must exist
for (const f of walk(join(ROOT, 'supabase', 'migrations'), (n) => n.endsWith('.sql'))) {
  const t = readFileSync(f, 'utf8');
  for (const m of t.matchAll(/guide_refs\b[^\n]{0,400}/g)) for (const r of m[0].matchAll(/'((?:admin|va|field|owner|renter|investor)\/[a-z0-9-]+)'/g)) {
    if (!chapterSlugs.has(r[1]) && !allowPath.has(r[1])) add('academy', relative(ROOT, f), r[1]);
  }
}

if (process.argv.includes('--json')) console.log(JSON.stringify(problems, null, 1));
else {
  console.log(`guides accuracy: ${sources.length} chapters, ${routes.length} routes, ${problems.length} stale reference(s)`);
  for (const p of problems) console.log(`  ${p.kind.padEnd(7)} ${p.where}: ${p.ref}`);
}
process.exit(problems.length ? 1 : 0);
