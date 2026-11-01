// The store app's icon, splash and store graphics, drawn from the brand (docs/apps/publish.md): the CC mark of the site's
// home screen icons (web/scripts/gen-app-icons.mjs), white C, red C and the red rule of the wordmark, on black, in the
// site's display face (web/src/fonts/inter-display-800.woff2). Rendered with the web app's Playwright.
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
const RED = '#d0111b';

const mark = (white, red) => `<text x="50" y="62" text-anchor="middle" font-family="Brand" font-weight="800" font-size="46" fill="${white}" letter-spacing="-2">C<tspan fill="${red}">C</tspan></text>
  <rect x="22" y="72" width="56" height="5" fill="${red}"/>`;
// one square: the mark inside `pad` percent of margin on each side
const square = (size, pad, { bg = '#000', white = '#fff', red = RED } = {}) => `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 100 100">
  ${bg ? `<rect width="100" height="100" fill="${bg}"/>` : ''}
  <g transform="translate(${pad} ${pad}) scale(${(100 - 2 * pad) / 100})">${mark(white, red)}</g></svg>`;
const feature = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="500" viewBox="0 0 1024 500">
  <rect width="1024" height="500" fill="#000"/>
  <text x="512" y="250" text-anchor="middle" font-family="Brand" font-weight="800" font-size="120" fill="#fff" letter-spacing="-5">Carma<tspan fill="${RED}">Cars</tspan></text>
  <rect x="402" y="285" width="220" height="10" fill="${RED}"/>
  <text x="512" y="365" text-anchor="middle" font-family="Brand" font-weight="800" font-size="34" fill="#a3a3a3">Car rental across Ontario</text></svg>`;

const out = [
  ['assets/icon-only.png', square(1024, 12)],
  ['assets/icon-foreground.png', square(1024, 24, { bg: null })],
  ['assets/icon-background.png', `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024"><rect width="1024" height="1024" fill="#000"/></svg>`],
  ['assets/splash.png', square(2732, 41)],
  ['assets/splash-dark.png', square(2732, 41)],
  ...[['mdpi', 24], ['hdpi', 36], ['xhdpi', 48], ['xxhdpi', 72], ['xxxhdpi', 96]].map(([d, px]) =>
    [`assets/notification/drawable-${d}/ic_stat_carmacars.png`, square(px, -8, { bg: null, white: '#fff', red: '#fff' })]),
  ['store/android/play-icon-512.png', square(512, 12)],
  ['store/android/feature-graphic.png', feature]
];

const browser = await chromium.launch();
const page = await browser.newPage();
for (const [file, svg] of out) {
  const w = Number(/width="(\d+)"/.exec(svg)[1]), h = Number(/height="(\d+)"/.exec(svg)[1]);
  mkdirSync(new URL(file.replace(/[^/]+$/, ''), APP), { recursive: true });
  await page.setViewportSize({ width: w, height: h });
  await page.setContent(`<html><head><style>@font-face{font-family:Brand;font-weight:800;src:url(data:font/woff2;base64,${font}) format("woff2")}
    html,body{margin:0;background:transparent}svg{display:block}</style></head><body>${svg}</body></html>`);
  await page.evaluate(() => document.fonts.ready);
  await page.locator('svg').screenshot({ path: new URL(file, APP).pathname, omitBackground: true });
}
await browser.close();
console.log('wrote', out.map((o) => o[0]).join(', '));
