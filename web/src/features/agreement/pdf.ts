import 'server-only';
import { PDFDocument, StandardFonts, rgb, type PDFImage, type PDFPage } from 'pdf-lib';
import type { Block, SignatureRow } from './model';

// The agreement as a PDF (pdf-lib: pure JavaScript, runs in the Worker). Deterministic: the same
// blocks and date give the same bytes, so the SHA-256 recorded at opening identifies the document.
// The standard fonts use WinAnsi, so characters outside it are mapped to plain equivalents.
const W = 612, H = 792, M = 54;           // US Letter, 0.75 inch margins
const INK = rgb(0, 0, 0), GREY = rgb(0.37, 0.37, 0.37), LINE = rgb(0.85, 0.85, 0.85), RED = rgb(0.816, 0.067, 0.106), WHITE = rgb(1, 1, 1), ZEBRA = rgb(0.965, 0.965, 0.965);
// a cell that is an amount (or a percentage, or a count with its unit) is right-aligned in a branded table
const NUMERIC = /^\**(-?\$[\d,]+\.\d{2}|-?[\d,.]+%|-?[\d,]+(\.\d+)?( days| hours)?)\**$/;

const MAP: Record<string, string> = { '−': '-', '–': '-', '—': '-', '☐': '[ ]', '☑': '[x]', '●': '-', '“': '"', '”': '"', '‘': "'", '’': "'", '…': '...', '\u202f': ' ', '\u2009': ' ' };
export const pdfSafe = (s: string) => s.replace(/[^\x20-\x7E\xA0-\xFF]/g, (c) => MAP[c] ?? '');

interface Seg { text: string; bold: boolean }
const segs = (s: string): Seg[] => pdfSafe(s).replace(/ {2,}/g, '; ').split(/(\*\*[^*]+\*\*)/).filter(Boolean).map((p) => (p.startsWith('**') ? { text: p.slice(2, -2), bold: true } : { text: p, bold: false }));

export interface PdfExtras {
  title: string;
  createdAt: Date;
  /** Signature images (PNG bytes) by signature row index. */
  images?: Map<number, Uint8Array>;
  /** The last page of a signed copy: who signed, when, how, from where. */
  record?: { heading: string; lines: string[][] };
  footer: string;
  /** The CarmaCars wordmark at the top of every page (statements, receipts, invoices). */
  brand?: boolean;
  /** The logo from Admin > Settings > Site (PNG or JPEG) in place of the wordmark, on branded documents. */
  logo?: Uint8Array | null;
}

export async function agreementPdf(blocks: Block[], x: PdfExtras): Promise<Uint8Array> {
  const doc = await PDFDocument.create({ updateMetadata: false });
  doc.setTitle(pdfSafe(x.title)); doc.setAuthor('CarmaCars'); doc.setCreator('CarmaCars'); doc.setProducer('CarmaCars');
  doc.setCreationDate(x.createdAt); doc.setModificationDate(x.createdAt);
  const reg = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);
  // only branded documents embed the italic face: an agreement's bytes (and so its SHA-256) stay as they were
  const boldItalic = x.brand ? await doc.embedFont(StandardFonts.HelveticaBoldOblique) : bold;
  let logo: PDFImage | null = null;
  if (x.brand && x.logo && x.logo.length > 8) {
    try { logo = x.logo[0] === 0x89 ? await doc.embedPng(x.logo) : x.logo[0] === 0xff ? await doc.embedJpg(x.logo) : null; } catch { logo = null; }
  }
  const images = new Map<number, PDFImage>();
  for (const [i, bytes] of x.images ?? []) images.set(i, await doc.embedPng(bytes));

  const TOP = x.brand ? H - M - 14 : H - M;
  let page: PDFPage = doc.addPage([W, H]);
  let y = TOP;
  const pages: PDFPage[] = [page];
  const newPage = () => { page = doc.addPage([W, H]); pages.push(page); y = TOP; };
  const need = (h: number) => { if (y - h < M + 18) newPage(); };

  // word wrap with bold runs; returns lines of runs
  const wrap = (s: string, size: number, width: number, forceBold = false): Seg[][] => {
    const words: Seg[] = [];
    for (const sg of segs(s)) for (const w of sg.text.split(/(\s+)/)) if (w) words.push({ text: w, bold: forceBold || sg.bold });
    const lines: Seg[][] = []; let cur: Seg[] = []; let wdt = 0;
    for (const w of words) {
      const f = w.bold ? bold : reg;
      const ww = f.widthOfTextAtSize(w.text, size);
      if (/^\s+$/.test(w.text)) { if (cur.length) { cur.push(w); wdt += ww; } continue; }
      if (wdt + ww > width && cur.length) {
        while (cur.length && /^\s+$/.test(cur[cur.length - 1]!.text)) cur.pop();
        lines.push(cur); cur = []; wdt = 0;
      }
      if (ww > width) { // a single long token (a hash, a URL): break it
        let rest = w.text;
        while (rest) { let n = rest.length; while (n > 1 && f.widthOfTextAtSize(rest.slice(0, n), size) > width) n--; lines.push([{ text: rest.slice(0, n), bold: w.bold }]); rest = rest.slice(n); }
        continue;
      }
      cur.push(w); wdt += ww;
    }
    if (cur.length) lines.push(cur);
    return lines.length ? lines : [[]];
  };
  const drawLine = (line: Seg[], x0: number, yy: number, size: number, color = INK) => {
    let xx = x0;
    for (const s of line) { const f = s.bold ? bold : reg; page.drawText(s.text, { x: xx, y: yy, size, font: f, color }); xx += f.widthOfTextAtSize(s.text, size); }
  };
  const para = (s: string, size = 9.5, indent = 0, lead = 1.38, forceBold = false, color = INK) => {
    for (const l of wrap(s, size, W - 2 * M - indent, forceBold)) { need(size * lead); y -= size * lead; drawLine(l, M + indent, y, size, color); }
  };

  const table = (head: string[], rows: string[][], kv: boolean) => {
    const size = 8.5, pad = 4, lead = size * 1.35;
    const full = W - 2 * M;
    const widths = kv ? (x.brand ? [full * 0.62, full * 0.38] : [full * 0.3, full * 0.7])
      : head.length === 3 ? (x.brand ? [full * 0.56, full * 0.16, full * 0.28] : [full * 0.3, full * 0.42, full * 0.28])
      : x.brand && head.length > 3 ? head.map((_, i) => (i === 0 ? full * 0.3 : (full * 0.7) / (head.length - 1)))
      : head.map(() => full / head.length);
    let n = 0;
    const row = (cells: string[], isHead: boolean) => {
      const wrapped = cells.map((c, i) => wrap(c, size, widths[i]! - 2 * pad, isHead || (kv && i === 0)));
      const h = Math.max(...wrapped.map((w) => w.length)) * lead + 2 * pad;
      need(h);
      const total = !isHead && x.brand && cells.some((c) => /^\*\*.*\*\*$/.test(c));
      if (isHead) page.drawRectangle({ x: M, y: y - h, width: full, height: h, color: x.brand ? INK : rgb(0.94, 0.94, 0.94) });
      else if (x.brand && n++ % 2 === 1) page.drawRectangle({ x: M, y: y - h, width: full, height: h, color: ZEBRA });
      if (total) page.drawLine({ start: { x: M, y }, end: { x: M + full, y }, thickness: 1.2, color: RED });
      let xx = M;
      wrapped.forEach((ls, i) => {
        const right = x.brand && i > 0 && (isHead ? rows.some((r) => NUMERIC.test((r[i] ?? '').trim())) && !kv : NUMERIC.test((cells[i] ?? '').trim()));
        ls.forEach((l, k) => {
          const tw = l.reduce((a, sg) => a + (sg.bold ? bold : reg).widthOfTextAtSize(sg.text, size), 0);
          drawLine(l, right ? xx + widths[i]! - pad - tw : xx + pad, y - pad - (k + 1) * lead + 2.5, size, isHead && x.brand ? WHITE : INK);
        });
        xx += widths[i]!;
      });
      if (!isHead || !x.brand) page.drawLine({ start: { x: M, y: y - h }, end: { x: M + full, y: y - h }, thickness: 0.5, color: LINE });
      y -= h;
    };
    y -= 4;
    row(head, true);
    for (const r of rows) row(r, false);
    y -= 6;
  };

  const signatures = (rows: SignatureRow[]) => {
    const size = 8.5, full = W - 2 * M, widths = [full * 0.2, full * 0.27, full * 0.3, full * 0.23];
    table(['Party', 'Name', 'Electronic signature', 'Date and time'], [], false);
    y += 6;
    rows.forEach((r, i) => {
      const img = images.get(i);
      // every line of each cell (the countersignature's approved wording runs to several lines): the row grows to fit
      const cells = [r.party, r.name, img ? '' : r.signature, r.when].map((c, k) => wrap(c, size, widths[k]! - 8));
      const h = Math.max(img ? 46 : 26, 10 + Math.max(...cells.map((c) => c.length)) * 11);
      need(h);
      let xx = M;
      cells.forEach((ls, k) => {
        ls.forEach((l, j) => drawLine(l, xx + 4, y - 12 - j * 11, size));
        xx += widths[k]!;
      });
      if (img) {
        const scale = Math.min((widths[2]! - 8) / img.width, 40 / img.height);
        page.drawImage(img, { x: M + widths[0]! + widths[1]! + 4, y: y - 43, width: img.width * scale, height: img.height * scale });
      }
      page.drawLine({ start: { x: M, y: y - h }, end: { x: M + full, y: y - h }, thickness: 0.5, color: LINE });
      y -= h;
    });
    y -= 6;
  };

  for (const b of blocks) {
    switch (b.t) {
      case 'title':
        need(40); y -= 22; page.drawText(pdfSafe(b.text), { x: M, y, size: 18, font: bold, color: INK });
        page.drawRectangle({ x: M, y: y - 8, width: 36, height: 3, color: RED }); y -= 14; break;
      case 'h2':
        if (x.brand) { y -= 12; need(44); page.drawRectangle({ x: M, y: y - 15, width: 3, height: 13, color: RED }); y -= 1; para(b.text, 12, 9, 1.3, true); y -= 3; break; }
        y -= 10; need(30); para(b.text, 13, 0, 1.4, true); y -= 2; break;
      case 'h3': y -= 4; need(24); para(b.text, 10.5, 0, 1.4, true); break;
      case 'p': para(b.text); y -= 4; break;
      case 'ul': case 'ol':
        b.items.forEach((it, i) => {
          const mark = b.t === 'ul' ? '-' : `${i + 1}.`;
          const ls = wrap(it, 9.5, W - 2 * M - 16);
          ls.forEach((l, k) => { need(13); y -= 13; if (k === 0) page.drawText(mark, { x: M + 2, y, size: 9.5, font: reg }); drawLine(l, M + 16, y, 9.5); });
        });
        y -= 4; break;
      case 'table': table(b.head, b.rows, !!b.kv); break;
      case 'signatures': signatures(b.rows); break;
    }
  }

  if (x.record) {
    newPage();
    para(x.record.heading, 13, 0, 1.4, true);
    y -= 4;
    table(['Item', 'Record'], x.record.lines, true);
  }

  const total = pages.length;
  pages.forEach((p, i) => {
    p.drawText(pdfSafe(`${x.footer}   Page ${i + 1} of ${total}`), { x: M, y: 30, size: 7.5, font: reg, color: GREY });
    if (x.brand) {
      // the header: the logo (or the CarmaCars wordmark) on the left, the document's title on the right, a red rule
      if (logo) {
        const sc = Math.min(120 / logo.width, 24 / logo.height);
        p.drawImage(logo, { x: M, y: H - 44, width: logo.width * sc, height: logo.height * sc });
      } else {
        const a = 'Carma', b = 'Cars', size = 16;
        p.drawText(a, { x: M, y: H - 40, size, font: boldItalic, color: INK });
        p.drawText(b, { x: M + boldItalic.widthOfTextAtSize(a, size), y: H - 40, size, font: boldItalic, color: RED });
      }
      const tt = pdfSafe(x.title), ts = 8.5;
      p.drawText(tt, { x: W - M - reg.widthOfTextAtSize(tt, ts), y: H - 38, size: ts, font: reg, color: GREY });
      p.drawRectangle({ x: M, y: H - 52, width: W - 2 * M, height: 1.5, color: RED });
    }
  });
  return doc.save({ useObjectStreams: false });
}
