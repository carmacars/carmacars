import 'server-only';
import { PDFDocument, StandardFonts, rgb, type PDFImage, type PDFPage } from 'pdf-lib';
import type { Block, SignatureRow } from './model';

// The agreement as a PDF (pdf-lib: pure JavaScript, runs in the Worker). Deterministic: the same
// blocks and date give the same bytes, so the SHA-256 recorded at opening identifies the document.
// The standard fonts use WinAnsi, so characters outside it are mapped to plain equivalents.
const W = 612, H = 792, M = 54;           // US Letter, 0.75 inch margins
const INK = rgb(0, 0, 0), GREY = rgb(0.37, 0.37, 0.37), LINE = rgb(0.85, 0.85, 0.85), RED = rgb(0.816, 0.067, 0.106);

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
}

export async function agreementPdf(blocks: Block[], x: PdfExtras): Promise<Uint8Array> {
  const doc = await PDFDocument.create({ updateMetadata: false });
  doc.setTitle(pdfSafe(x.title)); doc.setAuthor('CarmaCars'); doc.setCreator('CarmaCars'); doc.setProducer('CarmaCars');
  doc.setCreationDate(x.createdAt); doc.setModificationDate(x.createdAt);
  const reg = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);
  const images = new Map<number, PDFImage>();
  for (const [i, bytes] of x.images ?? []) images.set(i, await doc.embedPng(bytes));

  let page: PDFPage = doc.addPage([W, H]);
  let y = H - M;
  const pages: PDFPage[] = [page];
  const newPage = () => { page = doc.addPage([W, H]); pages.push(page); y = H - M; };
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
    const widths = kv ? [full * 0.3, full * 0.7] : head.length === 3 ? [full * 0.3, full * 0.42, full * 0.28] : head.map(() => full / head.length);
    const row = (cells: string[], isHead: boolean) => {
      const wrapped = cells.map((c, i) => wrap(c, size, widths[i]! - 2 * pad, isHead || (kv && i === 0)));
      const h = Math.max(...wrapped.map((w) => w.length)) * lead + 2 * pad;
      need(h);
      if (isHead) page.drawRectangle({ x: M, y: y - h, width: full, height: h, color: rgb(0.94, 0.94, 0.94) });
      let xx = M;
      wrapped.forEach((ls, i) => { ls.forEach((l, k) => drawLine(l, xx + pad, y - pad - (k + 1) * lead + 2.5, size)); xx += widths[i]!; });
      page.drawLine({ start: { x: M, y: y - h }, end: { x: M + full, y: y - h }, thickness: 0.5, color: LINE });
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
      const h = img ? 46 : 26;
      need(h);
      let xx = M;
      [r.party, r.name, img ? '' : r.signature, r.when].forEach((c, k) => {
        wrap(c, size, widths[k]! - 8).slice(0, 3).forEach((l, j) => drawLine(l, xx + 4, y - 12 - j * 11, size));
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
      case 'h2': y -= 10; need(30); para(b.text, 13, 0, 1.4, true); y -= 2; break;
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
      const a = 'Carma', b = 'Cars', size = 13;
      const wa = bold.widthOfTextAtSize(a, size), wb = bold.widthOfTextAtSize(b, size);
      p.drawText(a, { x: W - M - wa - wb, y: H - 34, size, font: bold, color: INK });
      p.drawText(b, { x: W - M - wb, y: H - 34, size, font: bold, color: RED });
    }
  });
  return doc.save({ useObjectStreams: false });
}
