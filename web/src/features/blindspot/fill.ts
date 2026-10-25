// Draws a booking on Blind Spot's rental agreement (layout.ts says what goes where). The template has no fillable
// fields: the old address, Blind Spot's HST number and the old "Sam" signature are covered with the colour of their box
// (white, or the form's pink) and the pre-printed annotations carrying the old address are removed; then each value
// is drawn in its box in Helvetica, shrunk to fit. Page 2 (the terms) is not touched.
// The company representative's signature: the image uploaded in Admin > Settings > Forms when there is one, otherwise
// the representative's name written in a script hand (Blind Spot's instruction, October 23, 2026).
// The signed copy adds the renter's signature in boxes 16, 17 and 20 and a signature record page.
// Works in Node and in the Worker (pdf-lib only). Relative imports with their extension: the unit tests run it directly.
import { PDFArray, PDFDict, PDFDocument, PDFHexString, PDFName, PDFString, StandardFonts, rgb, type PDFFont, type PDFPage } from 'pdf-lib';
import { LINE_21, OLD_ADDRESS, PAGE_H, PINK, SIG, WHITE, type Layout, type SigBox, type Text } from './layout.ts';
import { SCRIPT_GLYPHS } from './script-glyphs.generated.ts';

export class BlindSpotTemplateError extends Error {}

/** The form's own fonts only know Latin-1: anything else is written without its accent, or as "?". */
export function winAnsi(s: string): string {
  return [...s.normalize('NFC')].map((c) => {
    const n = c.charCodeAt(0);
    if (n < 0x7f && n >= 0x20) return c;
    if (n >= 0xa0 && n <= 0xff) return c;
    if (c === '’' || c === '‘') return "'";
    if (c === '–' || c === '—' || c === '−') return '-';
    const base = c.normalize('NFD').replace(/[̀-ͯ]/g, '');
    return base && base.charCodeAt(0) < 0x7f ? base : '?';
  }).join('');
}

/** The width of a name written in the script hand, at a size. */
export function scriptWidth(text: string, size: number): number {
  return [...text].reduce((w, c) => w + (SCRIPT_GLYPHS[c]?.[0] ?? SCRIPT_GLYPHS[' ']![0]), 0) * size / 1000;
}

/** A name written in the script hand, its baseline at (x, y) in PDF coordinates (from the bottom). */
export function drawScript(page: PDFPage, text: string, x: number, y: number, size: number) {
  let cx = x;
  for (const c of text) {
    const g = SCRIPT_GLYPHS[c] ?? SCRIPT_GLYPHS[' ']!;
    if (g[1]) page.drawSvgPath(g[1], { x: cx, y, scale: size / 1000, color: rgb(0.08, 0.1, 0.25) });
    cx += g[0] * size / 1000;
  }
}

/** A signature in its box: the image fitted (kept in proportion, on the box's bottom line), or the name in the script
 *  hand sized to the box. */
async function drawSignature(doc: PDFDocument, page: PDFPage, box: SigBox, sig: Signature) {
  const bottom = PAGE_H - (box.top + box.h);
  if (sig.png) {
    const img = await doc.embedPng(sig.png);
    const k = Math.min(box.w / img.width, box.h / img.height);
    const w = img.width * k, h = img.height * k;
    page.drawImage(img, { x: box.x + (box.w - w) / 2, y: bottom, width: w, height: h });
    return;
  }
  const name = winAnsi(sig.name ?? '').replace(/[^A-Za-z .'-]/g, '').trim();
  if (!name) return;
  // the letters rise about 0.75 em above the line and fall 0.25 em below it
  const size = Math.min(box.h / 1.0, (box.w * 0.95) / Math.max(scriptWidth(name, 1), 0.001));
  drawScript(page, name, box.x + 2, bottom + size * 0.22, size);
}

export interface Signature { png?: Uint8Array | null; name?: string | null }

function fit(font: PDFFont, t: Text): { text: string; size: number } {
  let text = winAnsi(t.text);
  let size = t.size;
  const min = Math.min(5, t.size);
  while (size > min && font.widthOfTextAtSize(text, size) > t.w) size = Math.round((size - 0.25) * 100) / 100;
  // still too long at the smallest size: cut, with an ellipsis
  if (font.widthOfTextAtSize(text, size) > t.w) {
    while (text.length > 1 && font.widthOfTextAtSize(text + '...', size) > t.w) text = text.slice(0, -1);
    text = text.trimEnd() + '...';
  }
  return { text, size };
}

function decoded(v: unknown): string {
  if (v instanceof PDFString || v instanceof PDFHexString) return v.decodeText();
  return '';
}

/** Removes the pre-printed annotations whose text is the old address (they would show over the cover). */
function removeOldAddress(page: PDFPage): number {
  const annots = page.node.lookupMaybe(PDFName.of('Annots'), PDFArray);
  if (!annots) return 0;
  let removed = 0;
  for (let i = annots.size() - 1; i >= 0; i--) {
    const a = annots.lookupMaybe(i, PDFDict);
    if (!a) continue;
    if (OLD_ADDRESS.test(decoded(a.get(PDFName.of('Contents'))))) { annots.remove(i); removed++; }
  }
  return removed;
}

export interface FillResult { bytes: Uint8Array; drawn: string[]; shrunk: string[]; cut: string[]; removedAnnotations: number }

/** The template filled for a booking. `company` is the representative's signature (image or name); `renter`, on the
 *  signed copy only, the renter's; `record`, the signature record page of the signed copy. */
export interface FillOptions {
  company?: Signature | null; renter?: Signature | null; record?: { title: string; lines: Array<[string, string]> } | null; title?: string;
  /** 0143: each additional driver's drawn signature, side by side in box 10 */
  drivers?: Signature[] | null;
  /** 0143: the renter's initials (PNG): the clean-up charge line and box 40's X */
  initials?: Uint8Array | null;
  /** 0143: a version copy: written small in the renter's signature boxes ("Signed on the original, ...") */
  note?: string | null;
}
export async function fillBlindSpot(template: Uint8Array, l: Layout, o: FillOptions = {}): Promise<FillResult> {
  let doc: PDFDocument;
  try { doc = await PDFDocument.load(template, { updateMetadata: false }); } catch (e) { throw new BlindSpotTemplateError(`The template could not be opened: ${(e as Error).message}`); }
  if (doc.getPageCount() < 1) throw new BlindSpotTemplateError('The template has no page');
  const page = doc.getPage(0);
  const { width, height } = page.getSize();
  if (Math.abs(width - 595.28) > 2 || Math.abs(height - PAGE_H) > 2) throw new BlindSpotTemplateError(`The template is ${Math.round(width)} x ${Math.round(height)} points; Blind Spot's form is A4 (595 x 842)`);
  const removedAnnotations = removeOldAddress(page);
  const regular = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);
  for (const c of l.covers) {
    const col = c.color === 'pink' ? PINK : WHITE;
    page.drawRectangle({ x: c.x, y: PAGE_H - c.y - c.h, width: c.w, height: c.h, color: rgb(col.r, col.g, col.b) });
  }
  // the line under box 21's signature, where the old signature crossed it
  if (l.covers.some((c) => c.box === '21')) page.drawLine({ start: { x: LINE_21.x1, y: PAGE_H - LINE_21.y }, end: { x: LINE_21.x2, y: PAGE_H - LINE_21.y }, thickness: LINE_21.thickness, color: rgb(0, 0, 0) });
  const drawn: string[] = []; const shrunk: string[] = []; const cut: string[] = [];
  for (const t of l.texts) {
    const font = t.bold ? bold : regular;
    const f = fit(font, t);
    if (f.size < t.size) shrunk.push(t.box);
    if (f.text.endsWith('...') && !t.text.endsWith('...')) cut.push(t.box);
    const w = font.widthOfTextAtSize(f.text, f.size);
    const x = t.align === 'right' ? t.x - w : t.align === 'center' ? t.x - w / 2 : t.x;
    page.drawText(f.text, { x, y: PAGE_H - t.y, size: f.size, font, color: rgb(0.05, 0.05, 0.1) });
    drawn.push(t.box);
  }
  for (const d of l.dots) page.drawCircle({ x: d.x, y: PAGE_H - d.y, size: d.r, color: rgb(0.05, 0.05, 0.1) });
  if (o.company && (o.company.png || o.company.name)) await drawSignature(doc, page, SIG.company, o.company);
  if (o.renter && (o.renter.png || o.renter.name)) for (const b of [SIG.ldw, SIG.tickets, SIG.terms]) await drawSignature(doc, page, b, o.renter);
  const drivers = (o.drivers ?? []).filter((d) => d.png || d.name);
  if (drivers.length) {
    const w = SIG.drivers.w / drivers.length;
    for (const [i, d] of drivers.entries()) await drawSignature(doc, page, { ...SIG.drivers, x: SIG.drivers.x + i * w, w }, d);
  }
  if (o.initials) for (const b of [SIG.initialsCleanup, SIG.initialsDue]) await drawSignature(doc, page, b, { png: o.initials });
  if (o.note) for (const b of [SIG.ldw, SIG.tickets, SIG.terms]) {
    // the short form where the box is short (17): the note never runs past its box
    let size = 5.5; let text = winAnsi(b === SIG.tickets ? 'Signed on the original' : o.note);
    while (size > 4 && regular.widthOfTextAtSize(text, size) > b.w - 4) size -= 0.25;
    while (text.length > 4 && regular.widthOfTextAtSize(text, size) > b.w - 4) text = text.slice(0, -1);
    page.drawText(text, { x: b.x + 2, y: PAGE_H - (b.top + b.h) + 2, size, font: regular, color: rgb(0.1, 0.1, 0.35) });
  }
  if (o.record) {
    const p = doc.addPage([595.28, PAGE_H]);
    let y = PAGE_H - 60;
    p.drawText(winAnsi(o.record.title), { x: 50, y, size: 14, font: bold }); y -= 28;
    for (const [k, v] of o.record.lines) {
      p.drawText(winAnsi(k), { x: 50, y, size: 9, font: bold });
      // the value wrapped at the page width
      const words = winAnsi(v).split(/\s+/); let line = '';
      for (const w of words) {
        if (regular.widthOfTextAtSize(`${line} ${w}`.trim(), 9) > 330 && line) { p.drawText(line, { x: 215, y, size: 9, font: regular }); y -= 12; line = w; } else line = `${line} ${w}`.trim();
      }
      if (line) p.drawText(line, { x: 215, y, size: 9, font: regular });
      y -= 18;
      if (y < 60) break;
    }
  }
  if (o.title) doc.setTitle(winAnsi(o.title));
  doc.setProducer('CarmaCars');
  const bytes = await doc.save({ useObjectStreams: true });
  return { bytes, drawn, shrunk, cut, removedAnnotations };
}
