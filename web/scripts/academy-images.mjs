#!/usr/bin/env node
// The academy's pictures (migration 4200): the guide screenshots and the example photos named by supabase/seed/academy/r50visuals.mjs,
// as webp files under 150 KB in public/academy, with their sizes in supabase/seed/academy/images.json. The files are committed: the
// site serves them as static assets, lazy-loaded. Run after changing the pictures a section uses:
//   node scripts/academy-images.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SEED = path.join(WEB, '..', 'supabase', 'seed', 'academy');
const { ROOT, MANIFEST, MAX_BYTES, PHOTO_JOBS, resolveShot } = await import(path.join(SEED, 'r50images.mjs'));
const { pictureKeys } = await import(path.join(SEED, 'r50visuals.mjs'));
const OUT = path.join(WEB, 'public', 'academy');
fs.mkdirSync(OUT, { recursive: true });

const TARGET = MAX_BYTES - 12 * 1024; // keep clear of the limit
/** A pipeline to the smallest webp under the target: quality down first, then the width. */
async function encode(pipeline, maxW) {
  const meta = await pipeline.clone().metadata();
  let w = Math.min(meta.width, maxW);
  for (;;) {
    for (let q = 74; q >= 38; q -= 6) {
      const buf = await pipeline.clone().resize({ width: w, withoutEnlargement: true }).webp({ quality: q, effort: 5 }).toBuffer({ resolveWithObject: true });
      if (buf.data.length <= TARGET) return buf;
    }
    w = Math.round(w * 0.85);
    if (w < 240) throw new Error('cannot make the picture small enough');
  }
}

const manifest = {};
const keys = pictureKeys();
for (const key of keys) {
  const job = PHOTO_JOBS.find((p) => p.name === key);
  let pipeline, name, from, maxW;
  if (job) { pipeline = sharp(await (await job.build(sharp)).png().toBuffer()); name = `${key}.webp`; from = 'sample-photos'; maxW = 800; }
  else {
    const file = resolveShot(key);
    pipeline = sharp(path.join(ROOT, 'docs', 'guides', 'src', 'img', file));
    name = `${file.replace(/\.(jpe?g|png)$/i, '')}.webp`; from = `docs/guides/src/img/${file}`;
    maxW = /-phone-/.test(file) ? 720 : 1000;
  }
  const out = await encode(pipeline, maxW);
  fs.writeFileSync(path.join(OUT, name), out.data);
  manifest[name] = { w: out.info.width, h: out.info.height, bytes: out.data.length, from };
}
for (const f of fs.readdirSync(OUT)) if (f.endsWith('.webp') && !manifest[f]) fs.rmSync(path.join(OUT, f));
fs.writeFileSync(MANIFEST, JSON.stringify(Object.fromEntries(Object.entries(manifest).sort(([a], [b]) => (a < b ? -1 : 1))), null, 1) + '\n');
const total = Object.values(manifest).reduce((n, m) => n + m.bytes, 0);
console.log(`academy images: ${keys.length} written, ${Math.round(total / 1024)} KB in all, the largest ${Math.round(Math.max(...Object.values(manifest).map((m) => m.bytes)) / 1024)} KB`);
