#!/usr/bin/env node
// Keeps the build files of earlier deploys for 8 days (2026-11-06, docs/changes/2026-11-06-stale-chunks-car-card-photos.md).
//
//   node scripts/deploy/keep-assets.mjs [assets dir] [site]      after `npm run cf:build`, before the deploy
//
// Workers static assets belong to one Worker version: a deploy uploads its own /_next/static files and the previous
// build's files stop being served. A page whose HTML is from before the deploy (a tab left open, the browser's copy
// with stale-while-revalidate, the last good copy of 0106 kept for a week) then asks for script and stylesheet files
// that answer 404: the page stays half styled and its scripts never run (the owner's car page of November 1 showed the
// date picker of October with no day numbers). Next's file names carry their content hash (immutable), so earlier files
// can sit next to this build's without any clash.
//
// The live site serves _next/static/kept-assets.json: every build file it holds and when it was last part of a deploy.
// This script reads it, downloads from the live site each file this build no longer has and that left a deploy less
// than KEEP_DAYS ago, puts it into the assets directory, and writes the new list (this build's files at now, the
// carried ones with their old time). Wrangler uploads only files it does not have yet (by hash), so the carried files
// cost no upload. The first deploy with this script has no list yet: it carries the files the live home page, fleet page
// and a car page name, which is what an open tab of the previous build needs first. A file that cannot be downloaded is
// skipped with a warning; the deploy never fails here.
import fs from 'node:fs';
import path from 'node:path';

const KEEP_DAYS = Number(process.env.KEEP_ASSET_DAYS ?? 8);
const LIST = '_next/static/kept-assets.json';
const dir = path.resolve(process.argv[2] ?? 'web/.open-next/assets');
const site = (process.argv[3] ?? process.env.APP_URL ?? `https://${process.env.DOMAIN ?? 'carmacars.ca'}`).replace(/\/$/, '');
const now = Date.now();
const log = (m) => console.log(`keep-assets: ${m}`);
const warn = (m) => console.log(`::warning title=keep-assets::${m}`);

function walk(d, out = []) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) walk(p, out); else out.push(path.relative(dir, p).split(path.sep).join('/'));
  }
  return out;
}

async function get(url, ms = 20000) {
  const r = await fetch(url, { signal: AbortSignal.timeout(ms), headers: { 'user-agent': 'carmacars-deploy keep-assets' } });
  return r;
}

async function previous() {
  try {
    const r = await get(`${site}/${LIST}`);
    if (r.ok) { const j = await r.json(); if (j && typeof j.files === 'object') return { files: j.files, from: 'list' }; }
  } catch { /* the first deploy with this script, or the site down */ }
  // no list yet: the files the live pages name
  const files = {};
  for (const p of ['/', '/cars', '/how-it-works']) {
    try {
      const html = await (await get(site + p)).text();
      for (const m of html.matchAll(/\/(_next\/static\/[^"'\s)\\?]+)/g)) files[m[1]] = now;
      const car = html.match(/href="(\/cars\/[a-z0-9-]+)"/);
      if (car && p === '/cars') { const h = await (await get(site + car[1])).text(); for (const m of h.matchAll(/\/(_next\/static\/[^"'\s)\\?]+)/g)) files[m[1]] = now; }
    } catch { /* skip that page */ }
  }
  return { files, from: 'pages' };
}

async function pool(items, n, fn) {
  let i = 0;
  await Promise.all(Array.from({ length: n }, async () => { while (i < items.length) { const x = items[i++]; await fn(x); } }));
}

async function main() {
  if (!fs.existsSync(path.join(dir, '_next/static'))) { warn(`${dir}/_next/static not found: nothing kept`); return; }
  const mine = walk(path.join(dir, '_next/static')).filter((f) => f !== LIST);
  const have = new Set(mine);
  const prev = await previous();
  const cutoff = now - KEEP_DAYS * 86_400_000;
  const wanted = Object.entries(prev.files).filter(([f, t]) => !have.has(f) && Number(t) >= cutoff && /^_next\/static\/[\w./~@+-]+$/.test(f) && !f.includes('..'));
  const kept = {};
  let bytes = 0, failed = 0;
  await pool(wanted, 12, async ([f, t]) => {
    try {
      const r = await get(`${site}/${f}`);
      if (!r.ok) { failed++; return; }
      const b = Buffer.from(await r.arrayBuffer());
      const out = path.join(dir, f);
      fs.mkdirSync(path.dirname(out), { recursive: true });
      fs.writeFileSync(out, b);
      kept[f] = Number(t); bytes += b.length;
    } catch { failed++; }
  });
  const list = { written: new Date(now).toISOString(), keep_days: KEEP_DAYS, files: { ...kept } };
  for (const f of mine) list.files[f] = now;
  fs.writeFileSync(path.join(dir, LIST), JSON.stringify(list));
  const total = Object.keys(list.files).length;
  log(`this build ${mine.length} files; carried ${Object.keys(kept).length} earlier files (${(bytes / 1048576).toFixed(1)} MB, from the ${prev.from}); ${total} listed`);
  if (failed) warn(`${failed} earlier build files could not be downloaded from ${site} and are not kept`);
  if (total > 18000) warn(`${total} build files kept: close to the Workers static assets file limit; lower KEEP_ASSET_DAYS`);
}

main().catch((e) => { warn(`skipped: ${e?.message ?? e}`); });
