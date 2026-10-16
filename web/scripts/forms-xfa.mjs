// A pure XFA form (a "dynamic" Adobe form: the PDF's own pages only say "requires Adobe Reader") laid out by pdf.js
// in Chromium and printed to a plain PDF of the same page size, with the box of every field the layout drew. The
// result is the template for a coordinates-based placement (pdf_templates.kind = 'overlay'): the values are drawn
// at those boxes. Used by forms-fetch.mjs; needs Playwright's Chromium.
import http from 'node:http';
import { mkdtempSync, writeFileSync, readFileSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const PDFJS = dirname(require.resolve('pdfjs-dist/package.json'));

const PAGE = `<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="pdf_viewer.css">
<style>
  html, body { margin: 0; background: #fff; }
  .pg { position: relative; overflow: hidden; background: #fff; break-after: page; }
  /* the form's own buttons (print, clear, add) and the blue field shading are not part of the printed form */
  .xfaLayer button, .xfaLayer .xfaButton, .xfaLayer input[type=button] { visibility: hidden !important; }
  .xfaLayer input, .xfaLayer textarea, .xfaLayer select { background: transparent !important; }
  @page { margin: 0; }
</style></head><body><div id="out"></div>
<script type="module">
import * as pdfjs from './pdf.mjs';
pdfjs.GlobalWorkerOptions.workerSrc = './pdf.worker.mjs';
const doc = await pdfjs.getDocument({ url: 'form.pdf', enableXfa: true, standardFontDataUrl: './standard_fonts/' }).promise;
const out = document.getElementById('out');
const info = { pure: doc.isPureXfa, pages: [] };
for (let i = 1; i <= doc.numPages; i++) {
  const page = await doc.getPage(i);
  const vp = page.getViewport({ scale: 1 });
  const div = document.createElement('div'); div.className = 'pg'; div.dataset.page = String(i);
  div.style.width = vp.width + 'px'; div.style.height = vp.height + 'px';
  out.appendChild(div);
  const layer = document.createElement('div'); div.appendChild(layer);
  const xfa = await page.getXfa();
  if (xfa) pdfjs.XfaLayer.render({ viewport: vp.clone({ dontFlip: true }), div: layer, xfaHtml: xfa, annotationStorage: doc.annotationStorage,
    linkService: { getDestinationHash: () => '#', getAnchorUrl: () => '#', addLinkAttributes: () => {} }, intent: 'print' });
  info.pages.push([vp.width, vp.height]);
}
window.__info = info;
</script></body></html>`;

export async function renderXfa(bytes) {
  const dir = mkdtempSync(join(tmpdir(), 'xfa-'));
  for (const f of ['build/pdf.mjs', 'build/pdf.worker.mjs', 'web/pdf_viewer.css']) copyFileSync(join(PDFJS, f), join(dir, f.split('/').pop()));
  writeFileSync(join(dir, 'form.pdf'), bytes);
  writeFileSync(join(dir, 'index.html'), PAGE);
  const types = { mjs: 'text/javascript', css: 'text/css', pdf: 'application/pdf', html: 'text/html', pfb: 'application/octet-stream', ttf: 'font/ttf' };
  const srv = http.createServer((q, r) => {
    let p = decodeURIComponent(q.url.split('?')[0]); if (p === '/') p = '/index.html';
    const file = p.startsWith('/standard_fonts/') ? join(PDFJS, p) : join(dir, p);
    try { const b = readFileSync(file); r.writeHead(200, { 'content-type': types[file.split('.').pop()] ?? 'application/octet-stream' }); r.end(b); }
    catch { r.writeHead(404); r.end(); }
  });
  await new Promise((ok) => srv.listen(0, '127.0.0.1', ok));
  const { chromium } = await import('playwright');
  const browser = await chromium.launch({ args: ['--no-proxy-server'] });
  try {
    const page = await browser.newPage();
    await page.goto(`http://127.0.0.1:${srv.address().port}/`);
    await page.waitForFunction(() => window.__info, null, { timeout: 60_000 });
    await page.evaluate(() => document.fonts.ready);
    const info = await page.evaluate(() => window.__info);
    // every field the layout drew, with its box in PDF points (origin at the bottom left of its page)
    const boxes = await page.evaluate(() => {
      const seen = new Map();
      return [...document.querySelectorAll('.pg')].flatMap((pg) => {
        const p = pg.getBoundingClientRect();
        const n = Number(pg.dataset.page);
        return [...pg.querySelectorAll('input, textarea, select')].filter((e) => !['button', 'submit', 'reset'].includes(e.type)).map((e) => {
          const r = e.getBoundingClientRect();
          let label = (e.getAttribute('aria-label') || e.getAttribute('title') || e.getAttribute('name') || '').replace(/\s+/g, ' ').trim();
          if (!label) label = `Field on page ${n}`;
          const k = seen.get(label) ?? 0; seen.set(label, k + 1);
          const type = e.type === 'checkbox' || e.type === 'radio' ? 'checkbox' : e.tagName === 'SELECT' ? 'dropdown' : 'text';
          const rect = [r.x - p.x, p.height - (r.y - p.y) - r.height, r.width, r.height].map((v) => Math.round(v * 10) / 10);
          return { name: k ? `${label} (${k + 1})` : label, type, page: n, rect, label };
        }).filter((b) => b.rect[2] > 2 && b.rect[3] > 2);
      });
    });
    const [w, h] = info.pages[0] ?? [612, 792];
    // CSS pixels are printed at 96 per inch; scale 4/3 makes one CSS pixel one PDF point, so the boxes line up
    const pdf = await page.pdf({ width: `${w / 72}in`, height: `${h / 72}in`, scale: 4 / 3, printBackground: true, preferCSSPageSize: false });
    return { pdf: new Uint8Array(pdf), boxes, pages: info.pages.length, pure: info.pure };
  } finally {
    await browser.close();
    srv.close();
  }
}
