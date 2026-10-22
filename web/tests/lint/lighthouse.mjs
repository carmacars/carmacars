// Lighthouse on home, fleet, a car page, a landing page, a guide and a model hub with mobile settings (Lighthouse's default mobile
// emulation and throttling), with the installed Chromium. Writes reports/lighthouse.json.
//   BASE_URL=http://localhost:3000 node tests/lint/lighthouse.mjs
import fs from 'node:fs';
import lighthouse from 'lighthouse';
import * as chromeLauncher from 'chrome-launcher';

const base = process.env.BASE_URL || 'http://localhost:3000';
const chromePath = process.env.CHROME_PATH || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
const pages = (process.env.PAGES || '/,/cars,/cars/mercedes-benz-c300,/car-rental/toronto,/guides/407-etr-tolls-in-a-rental-car,/cars/volkswagen/jetta/2020/sportline').split(',');
const chrome = await chromeLauncher.launch({ chromePath, chromeFlags: ['--headless=new', '--no-sandbox', '--no-proxy-server', '--disable-gpu'] });
const out = {};
try {
  for (const p of pages) {
    const r = await lighthouse(base + p, { port: chrome.port, output: 'json', logLevel: 'error', onlyCategories: ['performance', 'accessibility', 'best-practices', 'seo'] });
    const c = r.lhr.categories; const a = r.lhr.audits;
    out[p] = {
      performance: Math.round(c.performance.score * 100), accessibility: Math.round(c.accessibility.score * 100),
      bestPractices: Math.round(c['best-practices'].score * 100), seo: Math.round(c.seo.score * 100),
      lcp: a['largest-contentful-paint'].displayValue, cls: a['cumulative-layout-shift'].displayValue, tbt: a['total-blocking-time'].displayValue, fcp: a['first-contentful-paint'].displayValue,
      failed: Object.values(a).filter((x) => x.score !== null && x.score < 0.9 && x.scoreDisplayMode !== 'informative' && x.scoreDisplayMode !== 'manual' && x.scoreDisplayMode !== 'notApplicable').map((x) => `${x.id} ${x.displayValue ?? ''}`.trim()).slice(0, 12)
    };
    console.log(p, JSON.stringify(out[p]));
  }
} finally {
  await chrome.kill();
}
fs.mkdirSync('reports', { recursive: true });
fs.writeFileSync('reports/lighthouse.json', JSON.stringify(out, null, 2));
