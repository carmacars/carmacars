// Draws the default sharing image (public/og/default.png, 1200 x 630) from the brand values in the
// database: the brand logo (public/brand), the tagline and the city. Run again when the brand changes:
//   node scripts/og-image.mjs   (needs the local stack and Chromium)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import postgres from 'postgres';
import { chromium } from '@playwright/test';

process.env.PLAYWRIGHT_BROWSERS_PATH ??= '/opt/pw-browsers';
const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// OG_TAGLINE and OG_CITY: draw without the database (the values of Admin > Settings > Site)
let s;
if (process.env.OG_TAGLINE) s = { tagline: process.env.OG_TAGLINE, city: process.env.OG_CITY || 'Toronto' };
else {
  const sql = postgres(process.env.DATABASE_URL || 'postgresql://postgres@127.0.0.1:54322/carmacars', { max: 1, onnotice: () => {} });
  [{ s }] = await sql`select public.site_settings_public() s`;
  await sql.end();
}
const font = (f) => `data:font/woff2;base64,${fs.readFileSync(path.join(WEB, 'src/fonts', f)).toString('base64')}`;
const esc = (x) => String(x ?? '').replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c]);
// the brand logo (release 28, public/brand), white letters for the black card
const logo = `data:image/svg+xml;base64,${fs.readFileSync(path.join(WEB, 'public/brand/carma-logo-white.svg')).toString('base64')}`;
const html = `<!doctype html><html><head><style>
@font-face { font-family: D; src: url(${font('inter-display-800.woff2')}); font-weight: 800; }
@font-face { font-family: D; src: url(${font('inter-display-700.woff2')}); font-weight: 700; }
@font-face { font-family: T; src: url(${font('inter-500.woff2')}); font-weight: 500; }
html, body { margin: 0; width: 1200px; height: 630px; background: #000; color: #fff; }
.w { position: absolute; left: 70px; bottom: 64px; width: 760px; height: auto; }
.t { position: absolute; left: 76px; top: 72px; font: 700 64px/1.04 D; letter-spacing: -0.03em; max-width: 900px; }
.c { position: absolute; left: 78px; top: 230px; font: 500 28px T; color: #A3A3A3; }
.bar { position: absolute; left: 0; top: 0; width: 12px; height: 630px; background: #E30613; }
</style></head><body><div class="bar"></div><div class="t">${esc(s.tagline)}</div><div class="c">Car rental in ${esc(s.city)}, picked up or delivered</div>
<img class="w" src="${logo}" alt=""></body></html>`;
const b = await chromium.launch(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {});
const p = await b.newPage({ viewport: { width: 1200, height: 630 } });
await p.setContent(html, { waitUntil: 'load' });
await p.evaluate(() => document.fonts.ready);
fs.mkdirSync(path.join(WEB, 'public/og'), { recursive: true });
await p.screenshot({ path: path.join(WEB, 'public/og/default.png') });
await b.close();
console.log('og: public/og/default.png');
