// Release 35 (owner, Nov 8): the photo steps made here, in the Worker, instead of Cloudflare Image Transformations. Every
// step of the PhotoProcessor except the cut-out (the segmenter has no local stand-in) and a HEIC photo made a JPEG is done
// with the pure decoders and encoders already in the code (jpeg-js, the platform's deflate for PNG): decode once, one
// area-averaged pass down to the size asked (dimensions capped), encode once. No network apart from reading the inputs, no
// transformation counted. The site serves the stored files as they are (next/image is unoptimized; nothing resizes on view).
// hybridPhotos puts this in front: Cloudflare only for the cut-out and HEIC, or for everything when Program settings'
// listing_cf_transformations is on; any quota, outage or "not enabled" answer from Cloudflare falls back to here.
import type { PhotoOut, PhotoProcessor } from './types';
import { decodeImage, encodeJpeg } from '../../features/listing/showroom.ts';
import { encodePng, type Rgba } from '../../features/listing/subject-frame.ts';

/** The largest side a local step works at (the 1800 x 1200 frame, a little room for a trim). */
export const LOCAL_MAX_SIDE = 2400;

/** One separable pass from a source rectangle to dw x dh: area-averaged going down (no aliasing), bilinear going up. */
export function resample(src: Rgba, rect: { x: number; y: number; w: number; h: number }, dw: number, dh: number): Rgba {
  dw = Math.max(1, Math.round(dw)); dh = Math.max(1, Math.round(dh));
  const sw = src.width, s = src.data;
  // horizontal: rows of the rectangle to dw columns (premultiplied by alpha so clear pixels do not darken edges)
  const rows = Math.max(1, Math.ceil(rect.y + rect.h) - Math.floor(rect.y));
  const y0 = Math.max(0, Math.floor(rect.y));
  const mid = new Float32Array(dw * rows * 4);
  const kx = rect.w / dw;
  for (let x = 0; x < dw; x++) {
    const a = rect.x + x * kx, b = a + kx;
    for (let r = 0; r < rows; r++) {
      const sy = Math.min(src.height - 1, y0 + r), base = sy * sw;
      let R = 0, G = 0, B = 0, A = 0, wsum = 0;
      if (kx >= 1) {
        for (let sx = Math.max(0, Math.floor(a)); sx < Math.min(sw, Math.ceil(b)); sx++) {
          const w = Math.min(b, sx + 1) - Math.max(a, sx);
          if (w <= 0) continue;
          const i = (base + sx) * 4, al = s[i + 3]! * w;
          R += s[i]! * al; G += s[i + 1]! * al; B += s[i + 2]! * al; A += al; wsum += w;
        }
      } else {
        const c = Math.min(sw - 1, Math.max(0, a + kx / 2 - 0.5)), c0 = Math.floor(c), f = c - c0;
        for (const [sx, w] of [[c0, 1 - f], [Math.min(sw - 1, c0 + 1), f]] as const) {
          const i = (base + sx) * 4, al = s[i + 3]! * w;
          R += s[i]! * al; G += s[i + 1]! * al; B += s[i + 2]! * al; A += al; wsum += w;
        }
      }
      const o = (r * dw + x) * 4;
      const k = wsum ? 1 / wsum : 0;
      mid[o] = R * k; mid[o + 1] = G * k; mid[o + 2] = B * k; mid[o + 3] = A * k;
    }
  }
  // vertical: to dh rows, then back from premultiplied
  const out = new Uint8ClampedArray(dw * dh * 4);
  const ky = rect.h / dh;
  for (let y = 0; y < dh; y++) {
    const a = rect.y + y * ky - y0, b = a + ky;
    const taps: Array<[number, number]> = [];
    if (ky >= 1) {
      for (let r = Math.max(0, Math.floor(a)); r < Math.min(rows, Math.ceil(b)); r++) { const w = Math.min(b, r + 1) - Math.max(a, r); if (w > 0) taps.push([r, w]); }
    } else {
      const c = Math.min(rows - 1, Math.max(0, a + ky / 2 - 0.5)), c0 = Math.floor(c), f = c - c0;
      taps.push([c0, 1 - f], [Math.min(rows - 1, c0 + 1), f]);
    }
    for (let x = 0; x < dw; x++) {
      let R = 0, G = 0, B = 0, A = 0, wsum = 0;
      for (const [r, w] of taps) { const i = (r * dw + x) * 4; R += mid[i]! * w; G += mid[i + 1]! * w; B += mid[i + 2]! * w; A += mid[i + 3]! * w; wsum += w; }
      const o = (y * dw + x) * 4;
      if (A > 0) { out[o] = R / A; out[o + 1] = G / A; out[o + 2] = B / A; }
      out[o + 3] = wsum ? A / wsum : 0;
    }
  }
  return { width: dw, height: dh, data: out };
}

/** The image cropped to the aspect of W x H around its centre (after a trim of each edge) and sized to W x H. */
export function coverFit(img: Rgba, W: number, H: number, trim?: { top: number; right: number; bottom: number; left: number } | null): Rgba {
  const x0 = Math.max(0, trim?.left ?? 0), y0 = Math.max(0, trim?.top ?? 0);
  const w = Math.max(1, img.width - x0 - Math.max(0, trim?.right ?? 0)), h = Math.max(1, img.height - y0 - Math.max(0, trim?.bottom ?? 0));
  const k = Math.max(W / w, H / h);
  const cw = W / k, ch = H / k;
  return resample(img, { x: x0 + (w - cw) / 2, y: y0 + (h - ch) / 2, w: cw, h: ch }, W, H);
}

/** At most `width` wide (and LOCAL_MAX_SIDE high), never larger than it is. */
export function scaleDown(img: Rgba, width: number, height = LOCAL_MAX_SIDE): Rgba {
  const k = Math.min(1, width / img.width, height / img.height);
  if (k >= 1) return img;
  return resample(img, { x: 0, y: 0, w: img.width, h: img.height }, img.width * k, img.height * k);
}

/** `top` drawn over `base` (alpha), its top left corner at (x, y). In place. */
export function over(base: Rgba, top: Rgba, x: number, y: number, opacity = 1) {
  const bw = base.width, b = base.data, t = top.data;
  for (let ty = 0; ty < top.height; ty++) {
    const by = y + ty; if (by < 0 || by >= base.height) continue;
    for (let tx = 0; tx < top.width; tx++) {
      const bx = x + tx; if (bx < 0 || bx >= bw) continue;
      const i = (ty * top.width + tx) * 4, a = (t[i + 3]! / 255) * opacity; if (!a) continue;
      const o = (by * bw + bx) * 4;
      b[o] = b[o]! + (t[i]! - b[o]!) * a; b[o + 1] = b[o + 1]! + (t[i + 1]! - b[o + 1]!) * a; b[o + 2] = b[o + 2]! + (t[i + 2]! - b[o + 2]!) * a;
      b[o + 3] = Math.max(b[o + 3]!, t[i + 3]!);
    }
  }
}

/** An image fitted inside w x h (aspect kept), as the "contain" of a draw. */
function contain(img: Rgba, w: number, h?: number): Rgba {
  const k = Math.min(w / img.width, h ? h / img.height : Infinity);
  return resample(img, { x: 0, y: 0, w: img.width, h: img.height }, img.width * k, img.height * k);
}

/** Brightness, contrast, gamma, saturation (and a light sharpen) in one pass; the same numbers as the transformation's. */
export function tone(img: Rgba, v: { brightness?: number; contrast?: number; gamma?: number; saturation?: number; sharpen?: number }): Rgba {
  const lut = new Uint8ClampedArray(256);
  const br = v.brightness ?? 1, co = v.contrast ?? 1, ga = v.gamma ?? 1;
  for (let i = 0; i < 256; i++) { let x = (i / 255) * br; x = (x - 0.5) * co + 0.5; x = Math.max(0, x) ** (1 / ga); lut[i] = Math.round(x * 255); }
  const sat = v.saturation ?? 1, d = img.data, out = new Uint8ClampedArray(d.length);
  for (let i = 0; i < d.length; i += 4) {
    const r = lut[d[i]!]!, g = lut[d[i + 1]!]!, b = lut[d[i + 2]!]!, l = 0.299 * r + 0.587 * g + 0.114 * b;
    out[i] = l + (r - l) * sat; out[i + 1] = l + (g - l) * sat; out[i + 2] = l + (b - l) * sat; out[i + 3] = d[i + 3]!;
  }
  const sh = Math.min(1, Math.max(0, (v.sharpen ?? 0) / 10));
  if (sh > 0) {
    const W = img.width, H = img.height, src = new Uint8ClampedArray(out);
    for (let y = 1; y < H - 1; y++) for (let x = 1; x < W - 1; x++) for (let c = 0; c < 3; c++) {
      const i = (y * W + x) * 4 + c;
      const blur = (src[i - 4]! + src[i + 4]! + src[i - W * 4]! + src[i + W * 4]!) / 4;
      out[i] = src[i]! + (src[i]! - blur) * sh;
    }
  }
  return { width: img.width, height: img.height, data: out };
}

/** A heavy blur (a photo behind the windows): down to an eighth, three box blurs, back up. */
function heavyBlur(img: Rgba): Rgba {
  const small = resample(img, { x: 0, y: 0, w: img.width, h: img.height }, Math.max(8, img.width / 8), Math.max(8, img.height / 8));
  const { width: w, height: h, data } = small, tmp = new Float32Array(data.length);
  for (let pass = 0; pass < 3; pass++) {
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) for (let c = 0; c < 4; c++) {
      let s = 0, n = 0; for (let k = -3; k <= 3; k++) { const xx = x + k; if (xx >= 0 && xx < w) { s += data[(y * w + xx) * 4 + c]!; n++; } } tmp[(y * w + x) * 4 + c] = s / n;
    }
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) for (let c = 0; c < 4; c++) {
      let s = 0, n = 0; for (let k = -3; k <= 3; k++) { const yy = y + k; if (yy >= 0 && yy < h) { s += tmp[(yy * w + x) * 4 + c]!; n++; } } data[(y * w + x) * 4 + c] = s / n;
    }
  }
  return resample(small, { x: 0, y: 0, w, h }, img.width, img.height);
}

const jpeg = (img: Rgba, q: number): PhotoOut => ({ ok: true, bytes: encodeJpeg(img, q), contentType: 'image/jpeg', transformations: 0 });
const unreadable = (what: string): PhotoOut => ({ ok: false, reason: 'unavailable', retryable: true, message: `${what} could not be read` });

/** The local processor. `load` reads a link the worker handed out (its storage, or a fetch). */
export function localImages(load: (url: string) => Promise<Uint8Array | null>): PhotoProcessor {
  const read = async (url: string) => { const b = await load(url).catch(() => null); return b ? decodeImage(b) : null; };
  return {
    name: 'local',
    async cutout() { return { ok: false, reason: 'not_enabled', retryable: false, message: 'The car is cut out by the image service only' }; },
    async composite({ backdropUrl, shadowUrl, cutoutUrl, width, height, lettering, place }) {
      const [bg, car] = await Promise.all([read(backdropUrl), read(cutoutUrl)]);
      if (!bg || !car) return unreadable(!bg ? 'The backdrop' : 'The cut-out');
      const frame = coverFit(bg, width, height);
      if (lettering) {
        const band = await read(lettering.url);
        if (band) { const b = contain(band, Math.round(lettering.width * width / 1800)); over(frame, b, 0, Math.round(lettering.top * height / 1200)); }
      }
      if (place) {
        const c = contain(car, place.width, place.height);
        over(frame, c, Math.round(place.left + (place.width - c.width) / 2), Math.round(height - place.bottom - c.height));
      } else {
        const carW = Math.round(width * 0.8), floor = Math.round(height * 0.25);
        const sh = await read(shadowUrl);
        if (sh) { const s = contain(sh, Math.round(carW * 0.96)); over(frame, s, Math.round((width - s.width) / 2), height - Math.max(0, floor - Math.round(height * 0.035)) - s.height); }
        const c = contain(car, carW, Math.round(height * 0.6));
        over(frame, c, Math.round((width - c.width) / 2), height - floor - c.height);
      }
      for (let i = 3; i < frame.data.length; i += 4) frame.data[i] = 255;
      return jpeg(frame, 86);
    },
    async normalize({ sourceUrl, width, height, trim }) {
      const img = await read(sourceUrl);
      if (!img) return unreadable('The photo');
      return jpeg(tone(coverFit(img, width, height, trim), { brightness: 1.03, contrast: 1.03 }), 85);
    },
    async layer({ baseUrl, baseBlur, overlayUrl, width, height }) {
      const [base, top] = await Promise.all([read(baseUrl), read(overlayUrl)]);
      if (!base || !top) return unreadable(!base ? 'The base' : 'The overlay');
      let frame = coverFit(base, width, height);
      if (baseBlur) frame = heavyBlur(frame);
      over(frame, coverFit(top, width, height), 0, 0);
      for (let i = 3; i < frame.data.length; i += 4) frame.data[i] = 255;
      return jpeg(tone(frame, { brightness: 1.03, contrast: 1.03 }), 85);
    },
    async preview({ sourceUrl, width }) {
      const img = await read(sourceUrl);
      if (!img) return unreadable('The photo');
      return { ok: true, bytes: await encodePng(scaleDown(img, width)), contentType: 'image/png', transformations: 0 };
    },
    async enhance({ sourceUrl, width, height, values }) {
      const img = await read(sourceUrl);
      if (!img) return unreadable('The photo');
      return jpeg(tone(scaleDown(img, width, height), values), 86);
    },
    async toJpeg({ sourceUrl, width }) {
      const b = await load(sourceUrl).catch(() => null);
      const img = b ? await decodeImage(b) : null;
      if (!img) return { ok: false, reason: 'not_enabled', retryable: false, message: 'Only a JPEG or PNG is read here' };
      return jpeg(scaleDown(img, width, width), 88);
    },
    async resize({ sourceUrl, width }) {
      const img = await read(sourceUrl);
      if (!img) return unreadable('The photo');
      return jpeg(scaleDown(img, width), 82);
    }
  };
}

/** Cloudflare only where it is needed (the cut-out; a HEIC or WebP made a JPEG) unless `cfAll`; local for the rest, and
 *  local again whenever Cloudflare answers with a quota, an outage or "not enabled". */
export function hybridPhotos(local: PhotoProcessor, cf: PhotoProcessor | null, cfAll: boolean): PhotoProcessor {
  const back = (o: PhotoOut) => !o.ok && (o.reason === 'quota' || o.reason === 'unavailable' || o.reason === 'not_enabled' || o.reason === 'timeout');
  const pick = <A,>(f: (p: PhotoProcessor) => ((a: A) => Promise<PhotoOut>) | undefined) => async (a: A): Promise<PhotoOut> => {
    const lf = f(local)!;
    const cff = cfAll && cf ? f(cf) : undefined;
    if (!cff) return lf(a);
    const r = await cff(a);
    return back(r) ? lf(a) : r;
  };
  return {
    name: cf && cfAll ? cf.name : 'local',
    cutout: cf ? (u) => cf.cutout(u) : local.cutout,
    composite: pick((p) => p.composite),
    normalize: pick((p) => p.normalize),
    layer: pick((p) => p.layer),
    preview: pick((p) => p.preview),
    enhance: pick((p) => p.enhance),
    resize: pick((p) => p.resize),
    async toJpeg(r) {
      const l = await local.toJpeg!(r);
      if (l.ok || !cf?.toJpeg) return l;
      return cf.toJpeg(r);
    }
  };
}
