'use client';
import type { TextLine } from './parse';

// PDF in the browser (pdf.js, loaded only when a PDF is opened): the text layer of each page as lines with their
// position, and each page drawn to a canvas for the review screen and for the vision model when a page has no
// text (a scan). Nothing of this runs in the Worker. The worker script is served from /vendor/pdfjs (the file of
// the installed pdfjs-dist; a unit test checks they match).
type PdfJs = typeof import('pdfjs-dist');
export type PdfDoc = Awaited<ReturnType<PdfJs['getDocument']>['promise']>;
let lib: Promise<PdfJs> | null = null;
async function pdfjs(): Promise<PdfJs> {
  lib ??= import('pdfjs-dist').then((m) => { m.GlobalWorkerOptions.workerSrc = '/vendor/pdfjs/pdf.worker.min.mjs'; return m; });
  return lib;
}

export async function openPdf(bytes: ArrayBuffer | Uint8Array): Promise<PdfDoc> {
  const m = await pdfjs();
  const data = bytes instanceof Uint8Array ? bytes.slice() : new Uint8Array(bytes.slice(0));
  return m.getDocument({ data, isEvalSupported: false, disableFontFace: false }).promise;
}

interface Item { str: string; x: number; y: number; w: number; h: number }
/** The text of every page as lines (items on one baseline, left to right; a wide gap becomes two spaces). */
export async function pdfLines(doc: PdfDoc, maxPages = 40): Promise<{ lines: TextLine[]; chars: number; pages: number }> {
  const lines: TextLine[] = [];
  let chars = 0;
  const pages = Math.min(doc.numPages, maxPages);
  for (let n = 1; n <= pages; n++) {
    const page = await doc.getPage(n);
    const vp = page.getViewport({ scale: 1 });
    const tc = await page.getTextContent();
    const items: Item[] = [];
    for (const it of tc.items as Array<{ str?: string; transform?: number[]; width?: number; height?: number }>) {
      if (!it.str || !it.transform) continue;
      items.push({ str: it.str, x: it.transform[4]!, y: it.transform[5]!, w: it.width ?? 0, h: Math.abs(it.height ?? it.transform[3] ?? 10) || 10 });
    }
    items.sort((a, b) => b.y - a.y || a.x - b.x);
    const rows: Item[][] = [];
    for (const it of items) {
      const row = rows.find((r) => Math.abs(r[0]!.y - it.y) <= Math.max(2, r[0]!.h * 0.35));
      if (row) row.push(it); else rows.push([it]);
    }
    for (const r of rows) {
      r.sort((a, b) => a.x - b.x);
      let text = '';
      let end = -Infinity;
      for (const it of r) {
        if (!it.str.trim()) { end = Math.max(end, it.x + it.w); continue; }
        const gap = it.x - end;
        const charW = it.str.length ? it.w / it.str.length : 5;
        text += text ? (gap > charW * 2.5 ? '  ' : gap > charW * 0.15 || /\s$/.test(text) ? ' ' : '') : '';
        text += it.str;
        end = it.x + it.w;
      }
      text = text.replace(/[ \t]{3,}/g, '  ').trim();
      if (!text) continue;
      chars += text.length;
      const y = 1 - (r[0]!.y + r[0]!.h) / vp.height;
      lines.push({ text, page: n, y: Math.max(0, Math.min(1, y)), h: Math.min(0.2, (r[0]!.h * 1.4) / vp.height) });
    }
  }
  return { lines, chars, pages: doc.numPages };
}

/** One page drawn on a canvas at a width (the review screen), or as a JPEG for the vision model. */
export async function drawPage(doc: PdfDoc, n: number, canvas: HTMLCanvasElement, width: number): Promise<{ width: number; height: number }> {
  const page = await doc.getPage(n);
  const vp1 = page.getViewport({ scale: 1 });
  const vp = page.getViewport({ scale: width / vp1.width });
  canvas.width = Math.round(vp.width); canvas.height = Math.round(vp.height);
  const ctx = canvas.getContext('2d')!;
  ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, canvas.width, canvas.height);
  await page.render({ canvasContext: ctx, viewport: vp }).promise;
  return { width: canvas.width, height: canvas.height };
}
export async function pageJpeg(doc: PdfDoc, n: number, longSide = 1600): Promise<string> {
  const page = await doc.getPage(n);
  const vp1 = page.getViewport({ scale: 1 });
  const c = document.createElement('canvas');
  await drawPage(doc, n, c, Math.round(vp1.width >= vp1.height ? longSide : (longSide * vp1.width) / vp1.height));
  return c.toDataURL('image/jpeg', 0.85);
}

/** A photo or a scan made small for the vision model (long side in pixels), as a JPEG data URL. */
export async function imageJpeg(src: Blob | string, longSide = 1600): Promise<{ dataUrl: string; width: number; height: number }> {
  const url = typeof src === 'string' ? src : URL.createObjectURL(src);
  try {
    const img = await new Promise<HTMLImageElement>((ok, no) => { const i = new Image(); i.onload = () => ok(i); i.onerror = () => no(new Error('The image could not be opened')); i.src = url; });
    const k = Math.min(1, longSide / Math.max(img.naturalWidth || 1, img.naturalHeight || 1));
    const c = document.createElement('canvas');
    c.width = Math.max(1, Math.round((img.naturalWidth || 1) * k)); c.height = Math.max(1, Math.round((img.naturalHeight || 1) * k));
    const ctx = c.getContext('2d')!;
    ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, c.width, c.height);
    ctx.drawImage(img, 0, 0, c.width, c.height);
    return { dataUrl: c.toDataURL('image/jpeg', 0.85), width: c.width, height: c.height };
  } finally { if (typeof src !== 'string') URL.revokeObjectURL(url); }
}

/** Ask the vision model about one image (the server checks who may, and the day's allowance). */
export async function askVision(purpose: 'toll_read' | 'plate_detect', image: string, extra: { photo?: string; vehicle?: string } = {}): Promise<{ ok: true; model: string; neurons: number; data: unknown } | { ok: false; message: string; reason?: string }> {
  try {
    const r = await fetch('/api/staff/vision', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ purpose, image, ...extra }) });
    const j = (await r.json().catch(() => null)) as ({ ok: true; model: string; neurons: number; data: unknown } | { ok: false; message: string; reason?: string }) | null;
    if (!j) return { ok: false, message: r.status >= 500 ? 'The server did not answer. Try again in a minute.' : `The request failed (${r.status}).` };
    return j;
  } catch { return { ok: false, message: 'No connection. Try again.' }; }
}
