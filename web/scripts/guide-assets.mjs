#!/usr/bin/env node
// The guides' screenshots as static assets (migration 0044): the cropped JPEGs the guides show
// (docs/guides/content/images.json, from docs/guides/src/export.py) are copied to public/guides/img, so the site serves
// them from Cloudflare's static assets at /guides/img/<name> with no Worker time. Run before every build (npm run build).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ROOT = path.resolve(WEB, '..');
const SRC = path.join(ROOT, 'docs/guides/src/img');
const DEST = path.join(WEB, 'public/guides/img');
const list = path.join(ROOT, 'docs/guides/content/images.json');

if (!fs.existsSync(list) || !fs.existsSync(SRC)) {
  console.log('guide assets: no guide images in this checkout, nothing copied');
  process.exit(0);
}
const names = JSON.parse(fs.readFileSync(list, 'utf8'));
fs.mkdirSync(DEST, { recursive: true });
let copied = 0, kept = 0, missing = 0;
for (const n of names) {
  if (!/^[\w.-]+\.(jpe?g|png|webp)$/i.test(n)) continue;
  const from = path.join(SRC, n), to = path.join(DEST, n);
  if (!fs.existsSync(from)) { missing++; continue; }
  if (fs.existsSync(to) && fs.statSync(to).size === fs.statSync(from).size) { kept++; continue; }
  fs.copyFileSync(from, to);
  copied++;
}
for (const f of fs.readdirSync(DEST)) if (!names.includes(f)) fs.rmSync(path.join(DEST, f));
console.log(`guide assets: ${copied} copied, ${kept} already there${missing ? `, ${missing} missing` : ''}`);
if (missing) process.exit(1);
