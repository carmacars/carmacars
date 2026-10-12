// Screenshots of pages at 375 and 1440 for review: node tests/tools/shots.mjs / /cars ...
import { chromium } from '@playwright/test';
import fs from 'node:fs';
const base = process.env.BASE_URL || 'http://localhost:3000';
const out = process.env.SHOTS_DIR || 'reports/shots';
fs.mkdirSync(out, { recursive: true });
const paths = process.argv.slice(2).length ? process.argv.slice(2) : ['/'];
const widths = (process.env.WIDTHS || '375,1440').split(',').map(Number);
const browser = await chromium.launch({ args: ['--no-proxy-server'] });
for (const w of widths) {
  const ctx = await browser.newContext({ viewport: { width: w, height: 900 }, reducedMotion: 'reduce' });
  const page = await ctx.newPage();
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  for (const p of paths) {
    await page.goto(base + p, { waitUntil: 'load' });
    await page.waitForTimeout(1200);
    const name = (p.replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '') || 'home') + `-${w}.png`;
    await page.screenshot({ path: `${out}/${name}`, fullPage: process.env.FULL !== '0' });
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    console.log(`${w} ${p} -> ${name} overflow=${overflow}${errors.length ? ' ERRORS: ' + errors.join(' | ') : ''}`);
    errors.length = 0;
  }
  await ctx.close();
}
await browser.close();
