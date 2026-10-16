#!/usr/bin/env node
// The official ServiceOntario forms (docs/changes/2026-10-16-supply-manual-rentals.md, section 5): resolve each
// dataset page of the Central Forms Repository (forms.mgcs.gov.on.ca) to its English PDF, download it, record its
// SHA-256, its pages and its fillable (AcroForm) fields with their page and box, whether it carries an XFA form,
// and, for a form with no fillable field, the text on each page with its position (the labels a coordinates-based
// placement is built from). Run by the forms-fetch workflow (GitHub Actions can reach the government site; the
// development sandbox cannot). Writes <out>/<code>.pdf and <out>/report.json.
//
//   node scripts/forms-fetch.mjs --out /tmp/forms
import { mkdirSync, writeFileSync, readFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { PDFDocument, PDFCheckBox, PDFDropdown, PDFOptionList, PDFRadioGroup, PDFSignature, PDFTextField, PDFName } from 'pdf-lib';

const FORMS = [
  { code: 'SR-LV-006', page: 'https://forms.mgcs.gov.on.ca/en/dataset/sr-lv-006' },
  { code: 'SR-LV-012', page: 'https://forms.mgcs.gov.on.ca/en/dataset/sr-lv-012/resource/d0cb7203-79fa-4e37-bee6-869621afdad4' },
  { code: 'ON00453', page: 'https://forms.mgcs.gov.on.ca/en/dataset/on00453' },
  { code: '013-0169', page: 'https://forms.mgcs.gov.on.ca/en/dataset/013-0169/resource/9ec64eb2-a48d-42d4-bef1-4dc87882dcf9' },
  { code: '013-1155', page: 'https://forms.mgcs.gov.on.ca/en/dataset/013-1155' }
];
const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const OUT = arg('--out', '/tmp/forms');
const UA = { 'user-agent': 'Mozilla/5.0 (CarmaCars forms check; +https://carmacars.ca)', accept: 'text/html,application/json,application/pdf;q=0.9,*/*;q=0.8' };
mkdirSync(OUT, { recursive: true });

async function get(url, as = 'text') {
  let last;
  for (let i = 0; i < 3; i++) {
    try {
      const r = await fetch(url, { headers: UA, redirect: 'follow' });
      if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
      return { url: r.url, type: r.headers.get('content-type') ?? '', body: as === 'bytes' ? new Uint8Array(await r.arrayBuffer()) : await r.text() };
    } catch (e) { last = e; await new Promise((s) => setTimeout(s, 1500 * (i + 1))); }
  }
  throw last;
}

const english = (r) => {
  const t = `${r.name ?? ''} ${r.description ?? ''} ${r.language ?? ''} ${r.url ?? ''}`.toLowerCase();
  if (/fran[cç]ais|french|\bfr\b|-f\.pdf|_f\.pdf|\(f\)/.test(t)) return -5;
  return (/english|\ben\b|-e\.pdf|_e\.pdf|\(e\)/.test(t) ? 5 : 0) + (/\.pdf/.test(String(r.url).toLowerCase()) || String(r.format).toLowerCase() === 'pdf' ? 3 : 0);
};

// 1. the CKAN API of the repository (package_show, or resource_show for a resource page); 2. the page's own links.
async function resolve(f) {
  const base = new URL(f.page);
  const m = /\/dataset\/([^/]+)(?:\/resource\/([0-9a-f-]+))?/.exec(base.pathname);
  const tried = [];
  if (m) {
    try {
      if (m[2]) {
        const r = JSON.parse((await get(`${base.origin}/api/3/action/resource_show?id=${m[2]}`)).body);
        if (r.success && r.result?.url) return { url: r.result.url, via: 'resource_show', resource: { name: r.result.name, format: r.result.format, language: r.result.language } };
      }
      const p = JSON.parse((await get(`${base.origin}/api/3/action/package_show?id=${m[1]}`)).body);
      if (p.success) {
        const res = (p.result.resources ?? []).filter((r) => r.url).sort((a, b) => english(b) - english(a));
        if (res[0] && english(res[0]) >= 0) return { url: res[0].url, via: 'package_show', title: p.result.title, resource: { name: res[0].name, format: res[0].format, language: res[0].language } };
      }
    } catch (e) { tried.push(`api: ${e.message}`); }
  }
  try {
    const page = await get(f.page);
    const links = [...page.body.matchAll(/href="([^"]+)"/g)].map((x) => new URL(x[1].replace(/&amp;/g, '&'), page.url).href);
    const pdf = links.filter((u) => /\.pdf(\?|$)|\/download\//i.test(u)).sort((a, b) => english({ url: b }) - english({ url: a }));
    if (pdf[0]) return { url: pdf[0], via: 'page links' };
    tried.push('page: no PDF link');
  } catch (e) { tried.push(`page: ${e.message}`); }
  throw new Error(`no English PDF found (${tried.join('; ')})`);
}

const typeOf = (x) => x instanceof PDFTextField ? 'text' : x instanceof PDFCheckBox ? 'checkbox' : x instanceof PDFDropdown || x instanceof PDFOptionList ? 'dropdown'
  : x instanceof PDFRadioGroup ? 'radio' : x instanceof PDFSignature ? 'signature' : 'button';

async function inspect(bytes) {
  const doc = await PDFDocument.load(bytes, { ignoreEncryption: true, updateMetadata: false });
  const pages = doc.getPages();
  let xfa = false;
  try { const acro = doc.catalog.lookup(PDFName.of('AcroForm')); xfa = !!(acro && acro.get && acro.get(PDFName.of('XFA'))); } catch { xfa = false; }
  let fields = [];
  try {
    fields = doc.getForm().getFields().map((x) => {
      const w = x.acroField.getWidgets();
      const first = w[0];
      const page = first?.P() ? pages.findIndex((p) => p.ref === first.P()) + 1 : 0;
      const r = first?.getRectangle();
      const opts = x instanceof PDFDropdown || x instanceof PDFOptionList || x instanceof PDFRadioGroup ? x.getOptions() : undefined;
      let tip = null;
      try { const tu = x.acroField.dict.lookup(PDFName.of('TU')); tip = tu ? (tu.decodeText ? tu.decodeText() : String(tu)) : null; } catch { tip = null; }
      let max = null;
      try { if (x instanceof PDFTextField) max = x.getMaxLength() ?? null; } catch { max = null; }
      return { name: x.getName(), type: typeOf(x), ...(page > 0 ? { page } : {}), ...(r ? { rect: [r.x, r.y, r.width, r.height].map((n) => Math.round(n * 10) / 10) } : {}),
               ...(opts?.length ? { options: opts } : {}), ...(tip ? { tooltip: tip } : {}), ...(max ? { max_length: max } : {}), widgets: w.length };
    });
  } catch (e) { fields = []; }
  const sizes = pages.map((p) => { const s = p.getSize(); return [Math.round(s.width), Math.round(s.height)]; });
  let info = null;
  try { info = { title: doc.getTitle() ?? null, subject: doc.getSubject() ?? null, producer: doc.getProducer() ?? null }; } catch { info = null; }
  return { pages: pages.length, sizes, xfa, fields, info };
}

// The template the platform fills: the publisher's PDF opened (the forms are encrypted with an empty password and
// allow filling form fields; pdf-lib cannot read an encrypted file, so qpdf removes the encryption), with its XFA
// part removed so the AcroForm fields are used. A pure XFA form (no AcroForm field at all) is laid out by pdf.js and
// printed to a plain PDF with the box of each field: a coordinates-based template.
function decrypt(bytes) {
  const dir = mkdtempSync(join(tmpdir(), 'form-'));
  writeFileSync(join(dir, 'in.pdf'), bytes);
  try { execFileSync('qpdf', ['--decrypt', join(dir, 'in.pdf'), join(dir, 'out.pdf')], { stdio: 'pipe' }); }
  catch (e) { if (e.status !== 3) throw new Error('qpdf could not open the PDF: ' + String(e.stderr ?? e.message).slice(0, 200)); }
  return new Uint8Array(readFileSync(join(dir, 'out.pdf')));
}
const encrypted = (b) => /\/Encrypt\s/.test(Buffer.from(b.subarray(Math.max(0, b.length - 4096))).toString('latin1') + Buffer.from(b.subarray(0, 4096)).toString('latin1'));

async function prepare(original) {
  const open = encrypted(original) ? decrypt(original) : original;
  const seen = await inspect(open);
  const fillable = seen.fields.filter((x) => x.type !== 'button');
  if (fillable.length) {
    const doc = await PDFDocument.load(open, { updateMetadata: false });
    doc.getForm().deleteXFA();
    const bytes = await doc.save({ useObjectStreams: false });
    return { kind: 'acroform', bytes, ...seen, fields: fillable, decrypted: open !== original };
  }
  if (seen.xfa) {
    const { renderXfa } = await import('./forms-xfa.mjs');
    const x = await renderXfa(open);
    return { kind: 'overlay', bytes: x.pdf, pages: x.pages, sizes: seen.sizes, xfa: true, pure_xfa: x.pure, fields: x.boxes, info: seen.info, decrypted: open !== original };
  }
  return { kind: 'overlay', bytes: open, ...seen, fields: [], decrypted: open !== original };
}

const LOCAL = arg('--local', null);
const report = { at: new Date().toISOString(), forms: [] };
for (const f of FORMS) {
  const row = { code: f.code, page: f.page };
  try {
    let b;
    if (LOCAL) { b = new Uint8Array(readFileSync(join(LOCAL, `${f.code}.pdf`))); row.pdf_url = 'local'; }
    else {
      const r = await resolve(f);
      Object.assign(row, { pdf_url: r.url, via: r.via, dataset_title: r.title ?? null, resource: r.resource ?? null });
      const pdf = await get(r.url, 'bytes');
      b = pdf.body;
      if (!(b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46)) throw new Error(`the download is not a PDF (${pdf.type})`);
    }
    row.bytes = b.length;
    row.original_sha256 = createHash('sha256').update(b).digest('hex');
    row.encrypted = encrypted(b);
    writeFileSync(join(OUT, `${f.code}.original.pdf`), b);
    const t = await prepare(b);
    row.kind = t.kind; row.pages = t.pages; row.sizes = t.sizes; row.xfa = t.xfa; row.pure_xfa = t.pure_xfa ?? false; row.info = t.info; row.decrypted = t.decrypted;
    row.fields = t.fields;
    row.fillable = t.kind === 'acroform';
    row.sha256 = createHash('sha256').update(t.bytes).digest('hex');
    row.template_bytes = t.bytes.length;
    row.file = `${f.code}.pdf`;
    writeFileSync(join(OUT, row.file), t.bytes);
    row.downloaded = true;
    row.ok = true;
    console.log(`${f.code}: ${row.pdf_url} ${row.bytes} bytes${row.encrypted ? ' (encrypted, opened)' : ''}, ${row.pages} pages, ${row.fields.length} ${row.kind === 'acroform' ? 'fillable fields' : 'boxes for placed text'}${row.pure_xfa ? ' (pure XFA form, laid out by pdf.js)' : ''}`);
  } catch (e) {
    row.ok = false; row.error = e.message;
    console.log(`${f.code}: FAILED ${e.message}`);
  }
  report.forms.push(row);
}
writeFileSync(join(OUT, 'report.json'), JSON.stringify(report, null, 1));
if (report.forms.every((x) => !x.ok)) process.exit(1);
