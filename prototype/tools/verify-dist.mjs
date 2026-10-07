#!/usr/bin/env node
// Verifies dist/carmacars-prototype.html opened straight from disk (file://):
// zero network requests, zero console errors, every view renders, every
// internal link resolves to a view and (if present) an anchor in it.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || '/opt/node22/lib/node_modules/playwright/index.mjs');
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const file = path.join(ROOT, 'dist/carmacars-prototype.html'); const url = pathToFileURL(file).href;
const browser = await chromium.launch(); const problems = []; const requests = []; const errors = [];
for (const width of [1440, 375]) {
  const ctx = await browser.newContext({ viewport: { width, height: width < 500 ? 740 : 900 }, reducedMotion: 'reduce', offline: true });
  const page = await ctx.newPage(); page.setDefaultTimeout(6000);
  page.on('request', (r) => { if (!r.url().startsWith('data:') && r.url().split('#')[0] !== url) requests.push(r.url().slice(0, 120)); });
  page.on('console', (m) => { if (m.type() === 'error') errors.push(`@${width} ${m.text()}`); });
  page.on('pageerror', (e) => errors.push(`@${width} ${e.message}`));
  await page.goto(url); await page.waitForTimeout(300);
  const views = await page.evaluate(() => [...document.querySelectorAll('template[data-view]')].map((t) => t.dataset.view));
  let linkCount = 0;
  for (const v of views) {
    await page.evaluate((h) => { location.hash = h; }, '#/' + v); await page.waitForTimeout(140);
    const r = await page.evaluate((v) => {
      const out = { h1: document.querySelectorAll('main h1').length, title: document.title, bad: [], links: 0, imgs: 0, over: document.documentElement.scrollWidth - document.documentElement.clientWidth };
      document.querySelectorAll('img').forEach((i) => { out.imgs++; const s = i.getAttribute('src') || ''; if (!/^data:/.test(s)) out.bad.push('img not inlined: ' + s.slice(0, 60)); });
      document.querySelectorAll('source').forEach((i) => { const s = i.getAttribute('srcset') || ''; if (!/^data:/.test(s)) out.bad.push('source not inlined: ' + s.slice(0, 60)); });
      document.querySelectorAll('a[href]').forEach((a) => {
        const h = a.getAttribute('href'); out.links++;
        if (/^(mailto:|tel:|https?:)/.test(h)) return;
        if (h.startsWith('#/')) { let rest = h.slice(2); let anchor = ''; const t = rest.indexOf('~'); if (t > -1) { anchor = rest.slice(t + 1); rest = rest.slice(0, t); } const pg = rest.split('?')[0]; const tpl = document.querySelector('template[data-view="' + pg + '"]'); if (!tpl) out.bad.push('no view for ' + h); else if (anchor && !tpl.content.getElementById(anchor)) out.bad.push('no anchor for ' + h); return; }
        if (h.startsWith('#')) { if (!a.dataset.anchor || !document.getElementById(h.slice(1))) out.bad.push('dead in-page anchor ' + h); return; }
        out.bad.push('link leaves the file: ' + h);
      });
      return out;
    }, v);
    linkCount += r.links;
    if (r.h1 !== 1) problems.push(`@${width} ${v}: ${r.h1} h1`);
    if (r.over > 0) problems.push(`@${width} ${v}: horizontal overflow ${r.over}px`);
    r.bad.forEach((b) => problems.push(`@${width} ${v}: ${b}`));
  }
  // click-through: real clicks, real routing
  await page.evaluate(() => { location.hash = '#/index.html'; }); await page.waitForTimeout(200);
  if (width < 1024) { await page.locator('.menu-btn').click(); await page.locator('.menu-panel a[data-nav="fleet.html"]').click(); } else await page.locator('.nav a[data-nav="fleet.html"]').click();
  await page.waitForTimeout(200); if (!/fleet/i.test(await page.locator('main h1').textContent())) problems.push(`@${width} click to fleet did not route`);
  await page.locator('#fleet-grid > li:not([hidden]) a').first().click(); await page.waitForTimeout(250);
  if (!(await page.locator('[data-page="car"]').count())) problems.push(`@${width} click to a car did not route`);
  await page.locator('.car-top__cta a').click(); await page.waitForTimeout(250); // in-page anchor must not change the view
  if (!(await page.locator('[data-page="car"]').count())) problems.push(`@${width} in-page anchor changed the view`);
  await page.locator('[data-booking] [data-nav="1"]').click();
  await page.locator('[data-booking] [data-date="2026-11-24"]').click(); await page.locator('[data-booking] [data-date="2026-11-26"]').click(); await page.waitForTimeout(450);
  await page.locator('.booking__est [data-book]').click(); await page.waitForTimeout(300);
  if (!(await page.locator('[data-page="request"]').count())) problems.push(`@${width} Request to book did not route`);
  const tot = await page.locator('[data-summary-total]').textContent(); if (!/^\$\d/.test(tot)) problems.push(`@${width} request summary has no total: ${tot}`);
  await page.goBack(); await page.waitForTimeout(250); if (!(await page.locator('[data-page="car"]').count())) problems.push(`@${width} browser Back did not return to the car`);
  await page.evaluate(() => { location.hash = '#/nope.html'; }); await page.waitForTimeout(200); if (!/Wrong turn/.test(await page.locator('main h1').textContent())) problems.push(`@${width} unknown route did not show the 404 view`);
  console.log(`@${width}: views rendered: ${views.length}; links checked: ${linkCount}`);
  await ctx.close();
}
await browser.close();
console.log(`file size: ${(fs.statSync(file).size / 1024 / 1024).toFixed(2)} MB`);
console.log(`network requests: ${requests.length}; console errors: ${errors.length}; problems: ${problems.length}`);
[...new Set(requests)].slice(0, 10).forEach((r) => console.log('REQUEST', r)); errors.slice(0, 10).forEach((e) => console.log('ERROR', e)); problems.slice(0, 30).forEach((p) => console.log('PROBLEM', p));
process.exit(requests.length || errors.length || problems.length ? 1 : 0);
