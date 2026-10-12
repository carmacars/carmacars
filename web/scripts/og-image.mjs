// Draws the default sharing image (public/og/default.png, 1200 x 630) from the brand values in the
// database: the wordmark, the tagline and the city. Run again when the brand changes:
//   node scripts/og-image.mjs   (needs the local stack and Chromium)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import postgres from 'postgres';
import { chromium } from '@playwright/test';

process.env.PLAYWRIGHT_BROWSERS_PATH ??= '/opt/pw-browsers';
const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sql = postgres(process.env.DATABASE_URL || 'postgresql://postgres@127.0.0.1:54322/carmacars', { max: 1, onnotice: () => {} });
const [{ s }] = await sql`select public.site_settings_public() s`;
await sql.end();
const font = (f) => `data:font/woff2;base64,${fs.readFileSync(path.join(WEB, 'src/fonts', f)).toString('base64')}`;
const esc = (x) => String(x ?? '').replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c]);
const word = s.logo.wordmark || s.brand_name; const i = word.search(/(?<=.)[A-Z]/);
const html = `<!doctype html><html><head><style>
@font-face { font-family: D; src: url(${font('inter-display-800.woff2')}); font-weight: 800; }
@font-face { font-family: D; src: url(${font('inter-display-700.woff2')}); font-weight: 700; }
@font-face { font-family: T; src: url(${font('inter-500.woff2')}); font-weight: 500; }
html, body { margin: 0; width: 1200px; height: 630px; background: #000; color: #fff; }
.w { position: absolute; left: 72px; bottom: 64px; font: 800 168px/0.9 D; letter-spacing: -0.045em; }
.w b { color: #D0111B; font-weight: 800; }
.t { position: absolute; left: 76px; top: 72px; font: 700 64px/1.04 D; letter-spacing: -0.03em; max-width: 900px; }
.c { position: absolute; left: 78px; top: 230px; font: 500 28px T; color: #A3A3A3; }
.bar { position: absolute; left: 0; top: 0; width: 12px; height: 630px; background: #D0111B; }
</style></head><body><div class="bar"></div><div class="t">${esc(s.tagline)}</div><div class="c">Car rental in ${esc(s.city)}, picked up or delivered</div>
<div class="w">${i > 0 ? `${esc(word.slice(0, i))}<b>${esc(word.slice(i))}</b>` : esc(word)}</div></body></html>`;
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1200, height: 630 } });
await p.setContent(html, { waitUntil: 'load' });
await p.evaluate(() => document.fonts.ready);
fs.mkdirSync(path.join(WEB, 'public/og'), { recursive: true });
await p.screenshot({ path: path.join(WEB, 'public/og/default.png') });
await b.close();
console.log('og: public/og/default.png');
