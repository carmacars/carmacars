// The back of a licence: the PDF417 barcode read from the photo itself, on the server (release 31, D2). Pure JavaScript
// (the Worker cannot compile WebAssembly from bytes): the photo decoded (jpeg-js, fast-png), made smaller, turned to
// grey, then read by the ZXing PDF417 reader at a few sizes and both ways up. Also a small JPEG of the photo for the
// vision model when there is no barcode. Nothing here is logged.
import jpeg from 'jpeg-js';
import { decode as decodePng } from 'fast-png';
// ESM in the bundle, CommonJS in Node's tests (whose namespace has only the default): both ways
import * as ZX from '@zxing/library';

const ZXing = ((ZX as unknown as { default?: typeof ZX }).default ?? ZX) as typeof ZX;
const { BinaryBitmap, DecodeHintType, HybridBinarizer, PDF417Reader, RGBLuminanceSource } = ZXing;

export interface Rgba { width: number; height: number; data: Uint8Array }

/** A JPEG or PNG as RGBA pixels; null for anything else or a photo too large to decode safely. */
export function decodeImage(bytes: Uint8Array): Rgba | null {
  try {
    if (bytes[0] === 0xff && bytes[1] === 0xd8) {
      const j = jpeg.decode(bytes, { useTArray: true, formatAsRGBA: true, maxResolutionInMP: 40, maxMemoryUsageInMB: 400 });
      return { width: j.width, height: j.height, data: j.data as Uint8Array };
    }
    if (bytes[0] === 0x89 && bytes[1] === 0x50) {
      const p = decodePng(bytes);
      const n = p.width * p.height;
      const out = new Uint8Array(n * 4);
      const ch = p.channels; const src = p.data;
      const scale = p.depth === 16 ? 257 : 1;
      for (let i = 0; i < n; i++) {
        const g = src[i * ch]! / scale;
        out[i * 4] = g;
        out[i * 4 + 1] = ch >= 3 ? src[i * ch + 1]! / scale : g;
        out[i * 4 + 2] = ch >= 3 ? src[i * ch + 2]! / scale : g;
        out[i * 4 + 3] = 255;
      }
      return { width: p.width, height: p.height, data: out };
    }
  } catch { /* not an image we can read */ }
  return null;
}

/** Made smaller (box average) so the longer side is at most `max` pixels. */
export function shrink(img: Rgba, max: number): Rgba {
  const f = Math.max(img.width, img.height) / max;
  if (f <= 1) return img;
  const w = Math.max(1, Math.round(img.width / f)); const h = Math.max(1, Math.round(img.height / f));
  const out = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    const y0 = Math.floor(y * f); const y1 = Math.min(img.height, Math.max(y0 + 1, Math.floor((y + 1) * f)));
    for (let x = 0; x < w; x++) {
      const x0 = Math.floor(x * f); const x1 = Math.min(img.width, Math.max(x0 + 1, Math.floor((x + 1) * f)));
      let r = 0, g = 0, b = 0, n = 0;
      for (let yy = y0; yy < y1; yy += 1) for (let xx = x0; xx < x1; xx += 1) {
        const i = (yy * img.width + xx) * 4; r += img.data[i]!; g += img.data[i + 1]!; b += img.data[i + 2]!; n++;
      }
      const o = (y * w + x) * 4; out[o] = r / n; out[o + 1] = g / n; out[o + 2] = b / n; out[o + 3] = 255;
    }
  }
  return { width: w, height: h, data: out };
}

function luminance(img: Rgba): Uint8ClampedArray {
  const n = img.width * img.height; const out = new Uint8ClampedArray(n);
  for (let i = 0; i < n; i++) out[i] = (img.data[i * 4]! * 299 + img.data[i * 4 + 1]! * 587 + img.data[i * 4 + 2]! * 114) / 1000;
  return out;
}

function rotate90(lum: Uint8ClampedArray, w: number, h: number): Uint8ClampedArray {
  const out = new Uint8ClampedArray(w * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) out[x * h + (h - 1 - y)] = lum[y * w + x]!;
  return out;
}

/** The PDF417 text on the photo, or null. Tries 2000 and 1400 pixels, then turned a quarter (a photo taken upright). */
export function readPdf417(img: Rgba): string | null {
  const hints = new Map<ZX.DecodeHintType, unknown>([[DecodeHintType.TRY_HARDER, true]]);
  const reader = new PDF417Reader();
  for (const max of [2000, 1400]) {
    const s = shrink(img, max);
    let lum = luminance(s); let w = s.width; let h = s.height;
    for (let turn = 0; turn < 2; turn++) {
      try {
        // RGBLuminanceSource takes grey pixels when given one byte a pixel
        const src = new RGBLuminanceSource(lum, w, h);
        const r = reader.decode(new BinaryBitmap(new HybridBinarizer(src)), hints);
        const t = r?.getText();
        if (t) return t;
      } catch { /* not found at this size or this way up */ }
      lum = rotate90(lum, w, h); [w, h] = [h, w];
    }
  }
  return null;
}

/** A small JPEG (longer side 1280) as a data URL, for the vision model. */
export function smallJpegDataUrl(img: Rgba, max = 1280): string {
  const s = shrink(img, max);
  const enc = jpeg.encode({ width: s.width, height: s.height, data: s.data }, 82);
  let bin = '';
  const b = enc.data;
  for (let i = 0; i < b.length; i += 0x8000) bin += String.fromCharCode(...b.subarray(i, i + 0x8000));
  return `data:image/jpeg;base64,${btoa(bin)}`;
}
