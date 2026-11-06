// The store app's icon, splash and store graphics, drawn from the brand (docs/apps/publish.md; release 28): the CA mark of
// the brand kit (web/public/brand/carma-mark-white.svg, white CA over the red bar) on black, as on the site's home screen
// icons (web/public/icons), and the full logo (web/public/brand/carma-logo-white.svg) on the Play Store feature graphic.
// Rendered with the web app's Playwright.
//
//   node scripts/gen-assets.mjs        writes assets/ (the inputs of `npx capacitor-assets generate`, which makes every
//                                      iOS and Android size once the native projects exist) and the Play Store graphics
//
// Outputs: assets/icon-only.png (1024, iOS), assets/icon-foreground.png and icon-background.png (1024, Android adaptive),
// assets/splash.png and splash-dark.png (2732), assets/notification/drawable-*/ic_stat_carmacars.png (Android status bar,
// white on transparent), store/android/play-icon-512.png and store/android/feature-graphic.png (1024 x 500).
import { mkdirSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const APP = new URL('../', import.meta.url);
const WEB = new URL('../../../web/', import.meta.url);
const { chromium } = createRequire(new URL('package.json', WEB))('@playwright/test');
const font = readFileSync(new URL('src/fonts/inter-display-800.woff2', WEB)).toString('base64');
const BLACK = '#0A0A0A';
// the inside of a brand SVG (its paths), to nest at any size
const inner = (f) => readFileSync(new URL(`public/brand/${f}`, WEB), 'utf8').replace(/^<svg[^>]*>/, '').replace(/<\/svg>\s*$/, '');
const viewBox = (f) => /viewBox="([^"]+)"/.exec(readFileSync(new URL(`public/brand/${f}`, WEB), 'utf8'))[1];
const MARK = inner('carma-mark-white.svg');
// one square: the mark (its 1000 by 1000 box) inside `pad` percent of margin on each side
const square = (size, pad, { bg = BLACK, mono = false } = {}) => `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 100 100">
  ${bg ? `<rect width="100" height="100" fill="${bg}"/>` : ''}
  <g transform="translate(${pad} ${pad}) scale(${(100 - 2 * pad) / 1000})">${mono ? MARK.replace(/#E30613/gi, '#FFFFFF') : MARK}</g></svg>`;
const feature = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="500" viewBox="0 0 1024 500">
  <rect width="1024" height="500" fill="${BLACK}"/>
  <svg x="232" y="150" width="560" height="${Math.round(560 * 151.5 / 857.4)}" viewBox="${viewBox('carma-logo-white.svg')}">${inner('carma-logo-white.svg')}</svg>
  <text x="512" y="380" text-anchor="middle" font-family="Brand" font-weight="800" font-size="34" fill="#a3a3a3">Car rental across Ontario</text></svg>`;

const out = [
  ['assets/icon-only.png', square(1024, 0)],
  ['assets/icon-foreground.png', square(1024, 14, { bg: null })],
  ['assets/icon-background.png', `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024"><rect width="1024" height="1024" fill="#000"/></svg>`],
  ['assets/splash.png', square(2732, 36)],
  ['assets/splash-dark.png', square(2732, 36)],
  ...[['mdpi', 24], ['hdpi', 36], ['xhdpi', 48], ['xxhdpi', 72], ['xxxhdpi', 96]].map(([d, px]) =>
    [`assets/notification/drawable-${d}/ic_stat_carmacars.png`, square(px, -6, { bg: null, mono: true })]),
  ['store/android/play-icon-512.png', square(512, 0)],
  ['store/android/feature-graphic.png', feature]
];

// CHROME_PATH: a Chrome to use when Playwright's own browser of this version is not installed
const browser = await chromium.launch(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {});
const page = await browser.newPage();
for (const [file, svg] of out) {
  const w = Number(/width="(\d+)"/.exec(svg)[1]), h = Number(/height="(\d+)"/.exec(svg)[1]);
  mkdirSync(new URL(file.replace(/[^/]+$/, ''), APP), { recursive: true });
  await page.setViewportSize({ width: w, height: h });
  await page.setContent(`<html><head><style>@font-face{font-family:Brand;font-weight:800;src:url(data:font/woff2;base64,${font}) format("woff2")}
    html,body{margin:0;background:transparent}svg{display:block}</style></head><body>${svg}</body></html>`);
  await page.evaluate(() => document.fonts.ready);
  await page.locator('body > svg').screenshot({ path: new URL(file, APP).pathname, omitBackground: true });
}
await browser.close();
console.log('wrote', out.map((o) => o[0]).join(', '));
