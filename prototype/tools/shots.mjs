#!/usr/bin/env node
// Full-page screenshots of every page at 375 and 1440, plus mid-scroll frames.
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node tools/shots.mjs [page.html ...]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || '/opt/node22/lib/node_modules/playwright/index.mjs');
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, 'shots'); fs.mkdirSync(OUT, { recursive: true });
const args = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const only = process.argv.includes('--scroll') ? 'scroll' : process.argv.includes('--full') ? 'full' : 'both';
const files = args.length ? args : fs.readdirSync(ROOT).filter((f) => f.endsWith('.html')).sort();
const { serve } = await import('./serve.mjs'); const server = await serve(4199); const BASE = 'http://127.0.0.1:4199/';
const browser = await chromium.launch(); const errors = []; let n = 0;
const settle = async (page) => { await page.evaluate(async () => { document.querySelectorAll('img[loading="lazy"]').forEach((i) => { i.loading = 'eager'; }); const h = document.documentElement.scrollHeight; for (let y = 0; y < h; y += 800) { window.scrollTo(0, y); await new Promise((r) => setTimeout(r, 20)); } window.scrollTo(0, 0); await Promise.race([Promise.all([...document.images].map((i) => i.complete ? 0 : new Promise((r) => { i.onload = i.onerror = r; }))), new Promise((r) => setTimeout(r, 2500))]); }); await page.waitForTimeout(120); };
if (only !== 'scroll') for (const width of [375, 1440]) {
  const ctx = await browser.newContext({ viewport: { width, height: width === 375 ? 740 : 900 }, deviceScaleFactor: 1, reducedMotion: 'reduce' });
  const page = await ctx.newPage();
  page.on('console', (m) => { if (m.type() === 'error') errors.push(`${page.url().split('/').pop()} @${width}: ${m.text()}`); });
  page.on('pageerror', (e) => errors.push(`${page.url().split('/').pop()} @${width}: ${e.message}`));
  for (const f of files) {
    await page.goto(BASE + f);
    await settle(page);
    const over = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    if (over > 0) errors.push(`${f} @${width}: horizontal overflow ${over}px`);
    await page.screenshot({ path: path.join(OUT, `${f.replace('.html', '')}-${width}.png`), fullPage: true }); n++;
  }
  await ctx.close();
}
// mid-scroll frames with motion on
let m = 0;
if (only !== 'full') {
  const frames = [['index.html', [0, 260, 620, 1500, 2600, 3400, 4300]], ['car-mercedes-benz-c300.html', [0, 700, 1500, 2400]], ['fleet.html', [0, 500]], ['owners.html', [0, 900]]];
  for (const width of [375, 1440]) {
    const ctx = await browser.newContext({ viewport: { width, height: width === 375 ? 740 : 900 }, deviceScaleFactor: 1 });
    const page = await ctx.newPage();
    page.on('pageerror', (e) => errors.push(`${page.url().split('/').pop()} @${width} scroll: ${e.message}`));
    for (const [f, ys] of frames) {
      if (args.length && !args.includes(f)) continue;
      await page.goto(BASE + f); await settle(page);
      for (const y of ys) { await page.evaluate((yy) => window.scrollTo({ top: yy, behavior: 'instant' }), y); await page.waitForTimeout(450); await page.screenshot({ path: path.join(OUT, `scroll-${f.replace('.html', '')}-${width}-${String(y).padStart(4, '0')}.png`) }); m++; }
    }
    await ctx.close();
  }
}
await browser.close(); server.close();
console.log(`full-page screenshots: ${n}; mid-scroll frames: ${m}`);
console.log(errors.length ? 'ISSUES:\n' + errors.join('\n') : 'console errors: 0; horizontal overflow: none');
