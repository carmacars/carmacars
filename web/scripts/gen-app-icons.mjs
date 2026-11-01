// The site's home screen icons (web app manifest, migration 0300): the same mark as the staff portal's
// (scripts/gen-field-icons.mjs): black square, the CarmaCars initials, the red rule of the wordmark. Plus the alert badge
// (Android's status bar shows it as a white silhouette). Rendered with Playwright into public/icons.
// Run: node scripts/gen-app-icons.mjs
import { mkdirSync } from 'node:fs';
import { chromium } from '@playwright/test';

const OUT = new URL('../public/icons/', import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });
const mark = (white, red) => `<text x="50" y="62" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-weight="800" font-size="46" fill="${white}" letter-spacing="-2">C<tspan fill="${red}">C</tspan></text>
    <rect x="22" y="72" width="56" height="5" fill="${red}"/>`;
const svg = (size, pad, badge = false) => `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 100 100">
  ${badge ? '' : '<rect width="100" height="100" fill="#000"/>'}
  <g transform="translate(${pad} ${pad}) scale(${(100 - 2 * pad) / 100})">${badge ? mark('#fff', '#fff') : mark('#fff', '#d0111b')}</g></svg>`;
const icons = [['icon-192.png', 192, 4], ['icon-512.png', 512, 4], ['icon-maskable-512.png', 512, 14], ['apple-touch-icon.png', 180, 8], ['badge-96.png', 96, -8, true]];
const browser = await chromium.launch();
const page = await browser.newPage();
for (const [name, size, pad, badge] of icons) {
  await page.setViewportSize({ width: size, height: size });
  await page.setContent(`<html><body style="margin:0;background:transparent">${svg(size, pad, badge)}</body></html>`);
  await page.locator('svg').screenshot({ path: OUT + name, omitBackground: !!badge });
}
await browser.close();
console.log('wrote', icons.map((i) => i[0]).join(', '));
