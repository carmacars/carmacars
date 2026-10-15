// Prints guide pages to PDF with Playwright Chromium.
// node print.mjs <page.html> <out.pdf> <cover|body> [footer label]
// Needs PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers and playwright on NODE_PATH (build.py sets both).
import { chromium } from 'playwright';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [, , page, out, mode, label = ''] = process.argv;

const footer = `<style>
.f{font-family:Inter,Helvetica,Arial,sans-serif;font-size:7.5pt;font-weight:500;color:#5E5E5E;width:7.2in;margin:0 auto;padding-top:7pt;border-top:0.75pt solid #E2E2E2;display:flex;justify-content:space-between;-webkit-print-color-adjust:exact}
.f b{color:#000;font-weight:700}.f b i{font-style:normal;color:#D0111B}.f .n{color:#000;font-weight:700}
</style><div class="f"><span><b>Carma<i>Cars</i></b>&nbsp;&nbsp;|&nbsp;&nbsp;${label}</span><span class="n"><span class="pageNumber"></span></span></div>`;

const browser = await chromium.launch();
const ctx = await browser.newContext();
const p = await ctx.newPage();
await p.goto(pathToFileURL(resolve(page)).href, { waitUntil: 'load' });
await p.evaluate(() => document.fonts.ready);
await p.waitForTimeout(150);
if (mode !== 'cover') {
  // anything wider than the text column makes Chromium shrink every page to fit: report it
  await p.setViewportSize({ width: 691, height: 900 });
  await p.emulateMedia({ media: 'print' });
  const wide = await p.evaluate(() => [...document.querySelectorAll('body *')]
    .filter((e) => e.getBoundingClientRect().right > 692 && !e.closest('.dummy'))
    .slice(0, 8).map((e) => `${e.tagName}.${e.className}: ${e.textContent.slice(0, 50)} (${Math.round(e.getBoundingClientRect().right)})`));
  if (wide.length) console.log('WIDE', JSON.stringify(wide, null, 1));
}
if (mode === 'cover') {
  await p.pdf({ path: out, width: '8.5in', height: '11in', printBackground: true, margin: { top: 0, right: 0, bottom: 0, left: 0 } });
} else {
  await p.pdf({
    path: out, format: 'Letter', printBackground: true, preferCSSPageSize: true, outline: true, tagged: true,
    displayHeaderFooter: true, headerTemplate: '<span></span>', footerTemplate: footer,
    margin: { top: '0.6in', right: '0.65in', bottom: '0.75in', left: '0.65in' }
  });
}
await browser.close();
