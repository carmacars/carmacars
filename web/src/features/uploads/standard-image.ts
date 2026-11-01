'use client';
import { fitScale, HEIC_UNREADABLE, QUALITIES, sourceKind, sourceProblem, TARGET_BYTES, UNREADABLE } from './formats';

// A picked photo or scan as a standard JPEG (formats.ts): decoded by the browser (Safari reads HEIC itself; elsewhere
// the image element is tried too), a PDF's first page drawn with pdf.js, made smaller when large, location data gone.
async function decode(file: Blob): Promise<CanvasImageSource & { width: number; height: number }> {
  try { return await createImageBitmap(file); } catch { /* the image element below */ }
  // a data: address, not a blob: one (the site's content policy lets images load from data:, and nothing connects)
  const url = await new Promise<string>((ok, no) => {
    const r = new FileReader();
    r.onload = () => ok(String(r.result));
    r.onerror = () => no(r.error ?? new Error('unreadable'));
    r.readAsDataURL(file);
  });
  const img = new Image();
  img.decoding = 'async';
  img.src = url;
  await img.decode();
  return Object.assign(img, { width: img.naturalWidth, height: img.naturalHeight });
}

function toJpeg(src: CanvasImageSource & { width: number; height: number }): Promise<Blob> {
  const s = fitScale(src.width, src.height);
  const c = document.createElement('canvas');
  c.width = Math.max(1, Math.round(src.width * s)); c.height = Math.max(1, Math.round(src.height * s));
  const g = c.getContext('2d')!;
  g.fillStyle = '#fff'; g.fillRect(0, 0, c.width, c.height);
  g.drawImage(src, 0, 0, c.width, c.height);
  const at = (q: number) => new Promise<Blob>((res, rej) => c.toBlob((b) => (b ? res(b) : rej(new Error(UNREADABLE))), 'image/jpeg', q));
  return (async () => {
    let out = await at(QUALITIES[0]!);
    for (const q of QUALITIES.slice(1)) { if (out.size <= TARGET_BYTES) break; out = await at(q); }
    return out;
  })();
}

/** The standard JPEG of a picked file, or an Error whose message tells the person what to do. */
export async function toStandardImage(file: File): Promise<Blob> {
  const problem = sourceProblem(file);
  if (problem) throw new Error(problem);
  const kind = sourceKind(file);
  if (kind === 'pdf') {
    try {
      const { openPdf, pageJpeg } = await import('@/features/tolls/pdf');
      const doc = await openPdf(await file.arrayBuffer());
      const blob = await (await fetch(await pageJpeg(doc, 1, 2000))).blob();
      return await toJpeg(await decode(blob));
    } catch { throw new Error('We could not read that PDF. Upload a photo of the licence instead.'); }
  }
  try { return await toJpeg(await decode(file)); }
  catch { throw new Error(kind === 'heic' ? HEIC_UNREADABLE : UNREADABLE); }
}
