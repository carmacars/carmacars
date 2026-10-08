#!/usr/bin/env node
// Lightweight accessibility audit across all pages (not a substitute for a manual review):
// labelled controls, named links and buttons, text contrast (WCAG AA), keyboard focus order sanity.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || '/opt/node22/lib/node_modules/playwright/index.mjs');
const { serve } = await import('./serve.mjs');
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const server = await serve(4195); const browser = await chromium.launch(); const problems = []; let texts = 0; let controls = 0;
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, reducedMotion: 'reduce' }); const page = await ctx.newPage();
for (const f of fs.readdirSync(ROOT).filter((x) => x.endsWith('.html'))) {
  await page.goto('http://127.0.0.1:4195/' + f);
  const r = await page.evaluate(() => {
    const out = { p: [], texts: 0, controls: 0 };
    const lum = (c) => { const a = c.map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }); return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2]; };
    const rgb = (s) => { const m = s.match(/[\d.]+/g).map(Number); return { c: m.slice(0, 3), a: m.length > 3 ? m[3] : 1 }; };
    const bgOf = (el) => { for (let e = el; e; e = e.parentElement) { const cs = getComputedStyle(e); const b = rgb(cs.backgroundColor); if (b.a > 0.95) return b.c; if (cs.backgroundImage !== 'none' && /gradient/.test(cs.backgroundImage) && !/repeating/.test(cs.backgroundImage)) return null; } return [255, 255, 255]; };
    document.querySelectorAll('main *, header *, footer *, .cookie *').forEach((el) => {
      if (![...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim().length > 1)) return;
      const cs = getComputedStyle(el); if (cs.visibility === 'hidden' || cs.display === 'none' || !el.getClientRects().length || el.closest('[hidden], [aria-hidden="true"], .vh, .skip')) return;
      if (el.closest('[aria-disabled="true"], [disabled], .is-booked, .is-past')) return; // disabled controls are exempt
      const fg = rgb(cs.color); if (fg.a < 0.95 || cs.webkitTextStrokeWidth !== '0px') return; const bg = bgOf(el); if (!bg) return; out.texts++;
      const L1 = lum(fg.c); const L2 = lum(bg); const ratio = (Math.max(L1, L2) + 0.05) / (Math.min(L1, L2) + 0.05);
      const size = parseFloat(cs.fontSize); const big = size >= 24 || (size >= 18.66 && +cs.fontWeight >= 600);
      if (ratio < (big ? 3 : 4.5)) out.p.push(`contrast ${ratio.toFixed(2)} (${cs.color} on rgb(${bg})) "${el.textContent.trim().slice(0, 40)}"`);
    });
    document.querySelectorAll('input:not([type=hidden]), select, textarea').forEach((el) => { out.controls++; const named = el.getAttribute('aria-label') || el.getAttribute('aria-labelledby') || (el.id && document.querySelector('label[for="' + el.id + '"]')) || el.closest('label'); if (!named) out.p.push('unlabelled control: ' + el.outerHTML.slice(0, 80)); });
    document.querySelectorAll('a, button').forEach((el) => { const name = (el.getAttribute('aria-label') || el.getAttribute('aria-labelledby') || el.textContent || '').trim(); if (!name && !el.querySelector('img[alt]:not([alt=""])')) out.p.push('no accessible name: ' + el.outerHTML.slice(0, 80)); });
    if (!document.querySelector('main') || !document.querySelector('header') || !document.querySelector('footer')) out.p.push('missing landmark');
    if (document.documentElement.lang !== 'en-CA') out.p.push('lang missing');
    return out;
  });
  texts += r.texts; controls += r.controls; [...new Set(r.p)].forEach((x) => problems.push(`${f}: ${x}`));
}
// keyboard: every Tab stop on the home page shows a focus indicator
await page.goto('http://127.0.0.1:4195/index.html'); let stops = 0; let invisible = 0;
for (let i = 0; i < 40; i++) { await page.keyboard.press('Tab'); await page.waitForTimeout(40); const s = await page.evaluate(() => { const e = document.activeElement; if (!e || e === document.body) return null; const cs = getComputedStyle(e); const lab = e.closest('label'); const ls = lab ? getComputedStyle(lab) : null; return { o: (cs.outlineStyle !== 'none' && parseFloat(cs.outlineWidth) > 0) || (ls && ls.outlineStyle !== 'none' && parseFloat(ls.outlineWidth) > 0), b: cs.boxShadow !== 'none', t: e.tagName }; }); if (!s) continue; stops++; if (!s.o && !s.b) invisible++; }
if (invisible) problems.push(`index.html: ${invisible} of ${stops} tab stops had no visible focus style`);
await browser.close(); server.close();
console.log(`text elements contrast-checked: ${texts}; form controls checked: ${controls}; tab stops checked: ${stops}`);
console.log(problems.length ? `PROBLEMS (${problems.length}):\n` + problems.slice(0, 40).join('\n') : 'accessibility problems found: 0');
process.exit(problems.length ? 1 : 0);
