// The field portal's home screen icons (06-field.md section 1): black square, the CarmaCars initials, the
// red rule of the wordmark. Rendered with Playwright into public/field. Run: node scripts/gen-field-icons.mjs
import { mkdirSync } from 'node:fs';
import { chromium } from '@playwright/test';

const OUT = new URL('../public/field/', import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });
const svg = (size, pad) => `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 100 100">
  <rect width="100" height="100" fill="#000"/>
  <g transform="translate(${pad} ${pad}) scale(${(100 - 2 * pad) / 100})">
    <text x="50" y="62" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-weight="800" font-size="46" fill="#fff" letter-spacing="-2">C<tspan fill="#d0111b">C</tspan></text>
    <rect x="22" y="72" width="56" height="5" fill="#d0111b"/>
  </g></svg>`;
const icons = [['icon-192.png', 192, 4], ['icon-512.png', 512, 4], ['icon-maskable-512.png', 512, 14], ['apple-touch-icon.png', 180, 8]];
const browser = await chromium.launch();
const page = await browser.newPage();
for (const [name, size, pad] of icons) {
  await page.setViewportSize({ width: size, height: size });
  await page.setContent(`<html><body style="margin:0">${svg(size, pad)}</body></html>`);
  await page.locator('svg').screenshot({ path: OUT + name, omitBackground: false });
}
await browser.close();
console.log('wrote', icons.map((i) => i[0]).join(', '));
