import { chromium } from '@playwright/test';
const b = await chromium.launch({ args: ['--no-proxy-server'] });
const p = await b.newPage({ viewport: { width: 375, height: 800 } });
await p.goto('http://localhost:3000' + process.argv[2]);
await p.waitForTimeout(800);
if (process.argv[3]) await p.evaluate((s) => { document.querySelectorAll('[data-step]').forEach((e) => { e.hidden = e.dataset.step !== s; }); }, process.argv[3]);
const r = await p.evaluate(() => [...document.querySelectorAll('body *')].filter((e) => e.getBoundingClientRect().right > window.innerWidth + 1 && e.offsetParent).slice(0, 8).map((e) => `${e.tagName}.${e.className} ${Math.round(e.getBoundingClientRect().right)}`));
console.log(r.join('\n'));
await b.close();
