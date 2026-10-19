// Draws the sharing images (1200 x 630) of the landing pages and the guides of migration 0061 from
// scripts/content/seo-content.json: the page's heading on the brand's black with the red bar and the wordmark, the
// same look as public/og/default.png. Writes public/og/pages/<slug>.png, public/og/guides/<slug>.png and the list of
// pages that have one (src/features/seo/og-images.json); a page added later in Admin uses the default image.
//   node scripts/og-pages.mjs   (needs Chromium; no database: the brand is CarmaCars and the tokens are left out)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from '@playwright/test';

process.env.PLAYWRIGHT_BROWSERS_PATH ??= '/opt/pw-browsers';
const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const seo = JSON.parse(fs.readFileSync(path.join(WEB, 'scripts/content/seo-content.json'), 'utf8'));
const font = (f) => `data:font/woff2;base64,${fs.readFileSync(path.join(WEB, 'src/fonts', f)).toString('base64')}`;
const esc = (x) => String(x ?? '').replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c]);
const clean = (x) => String(x).replace(/\{\{\w+\}\}/g, '').replace(/\s+/g, ' ').trim();
const page = (kicker, title) => `<!doctype html><html><head><style>
@font-face { font-family: D; src: url(${font('inter-display-800.woff2')}); font-weight: 800; }
@font-face { font-family: D; src: url(${font('inter-display-700.woff2')}); font-weight: 700; }
@font-face { font-family: T; src: url(${font('inter-500.woff2')}); font-weight: 500; }
html, body { margin: 0; width: 1200px; height: 630px; background: #000; color: #fff; }
.bar { position: absolute; left: 0; top: 0; width: 12px; height: 630px; background: #D0111B; }
.k { position: absolute; left: 76px; top: 70px; font: 500 26px T; letter-spacing: 0.14em; text-transform: uppercase; color: #A3A3A3; }
.t { position: absolute; left: 74px; top: 128px; right: 90px; font: 800 76px/1.02 D; letter-spacing: -0.035em; }
.w { position: absolute; left: 76px; bottom: 58px; font: 800 64px/1 D; letter-spacing: -0.045em; }
.w b { color: #D0111B; font-weight: 800; }
.u { position: absolute; right: 80px; bottom: 66px; font: 500 26px T; color: #A3A3A3; }
</style></head><body><div class="bar"></div><div class="k">${esc(kicker)}</div><div class="t">${esc(title)}</div>
<div class="w">Carma<b>Cars</b></div><div class="u">carmacars.ca</div></body></html>`;

const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1200, height: 630 } });
const made = { pages: [], guides: [] };
for (const [dir, items, kick, title] of [['pages', seo.pages, (x) => (x.kind === 'location' ? 'Car rental, delivered' : 'Car rental in Toronto'), (x) => x.copy.h1],
  ['guides', seo.articles, () => 'Guide', (x) => x.title]]) {
  fs.mkdirSync(path.join(WEB, 'public/og', dir), { recursive: true });
  for (const x of items) {
    await p.setContent(page(kick(x), clean(title(x))), { waitUntil: 'load' });
    await p.evaluate(() => document.fonts.ready);
    await p.screenshot({ path: path.join(WEB, 'public/og', dir, `${x.slug}.png`) });
    made[dir].push(x.slug);
  }
}
await b.close();
fs.writeFileSync(path.join(WEB, 'src/features/seo/og-images.json'), JSON.stringify(made, null, 1) + '\n');
console.log(`og: ${made.pages.length} landing pages, ${made.guides.length} guides`);
