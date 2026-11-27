// Add old photos (5185): the capture time a phone wrote into a photo (EXIF DateTimeOriginal, with OffsetTimeOriginal when
// the phone gave its zone). The standard JPEG made before the upload drops every tag (standard-image.ts), so the time is read
// from the picked file first. JPEG and HEIC both carry the tags as "Exif\0\0" and a TIFF block; the block is found by those
// bytes, so one reader serves both. No I/O here.

export interface Captured { local: string; offset: string | null }

const EXIF = [0x45, 0x78, 0x69, 0x66, 0, 0];

function tiffAt(b: Uint8Array): number {
  for (let i = 0; i + 14 < b.length; i++) {
    if (b[i] !== 0x45 || b[i + 1] !== 0x78) continue;
    if (!EXIF.every((x, k) => b[i + k] === x)) continue;
    const t = i + 6;
    if ((b[t] === 0x49 && b[t + 1] === 0x49 && b[t + 2] === 0x2a && b[t + 3] === 0) || (b[t] === 0x4d && b[t + 1] === 0x4d && b[t + 2] === 0 && b[t + 3] === 0x2a)) return t;
  }
  return -1;
}

/** The capture time in the photo's bytes (the first few hundred kilobytes are enough for a JPEG), or null. */
export function captureTime(b: Uint8Array): Captured | null {
  const t = tiffAt(b);
  if (t < 0) return null;
  const le = b[t] === 0x49;
  const u16 = (o: number) => (o + 2 > b.length ? -1 : le ? b[o]! | (b[o + 1]! << 8) : (b[o]! << 8) | b[o + 1]!);
  const u32 = (o: number) => (o + 4 > b.length ? -1 : le ? (b[o]! | (b[o + 1]! << 8) | (b[o + 2]! << 16)) + b[o + 3]! * 0x1000000 : b[o]! * 0x1000000 + ((b[o + 1]! << 16) | (b[o + 2]! << 8) | b[o + 3]!));
  const ascii = (o: number, n: number) => { let s = ''; for (let k = 0; k < n && o + k < b.length && b[o + k] !== 0; k++) s += String.fromCharCode(b[o + k]!); return s; };
  // the tags of one directory: tag -> its text (ASCII only) or its number (LONG)
  function dir(off: number): Map<number, string | number> {
    const m = new Map<number, string | number>();
    const n = u16(t + off);
    if (n < 0 || n > 500) return m;
    for (let k = 0; k < n; k++) {
      const e = t + off + 2 + k * 12;
      const tag = u16(e), type = u16(e + 2), count = u32(e + 4);
      if (tag < 0 || count < 0) break;
      if (type === 2) m.set(tag, ascii(count <= 4 ? e + 8 : t + u32(e + 8), count));
      else if (type === 4) m.set(tag, u32(e + 8));
    }
    return m;
  }
  const ifd0 = dir(u32(t + 4));
  const exifOff = ifd0.get(0x8769);
  const ex = typeof exifOff === 'number' && exifOff > 0 ? dir(exifOff) : new Map<number, string | number>();
  const raw = String(ex.get(0x9003) ?? ex.get(0x9004) ?? ifd0.get(0x0132) ?? '');
  const m = /^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/.exec(raw);
  if (!m || m[1] === '0000') return null;
  const off = String(ex.get(0x9011) ?? ex.get(0x9010) ?? '');
  return { local: `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}`, offset: /^[+-]\d{2}:\d{2}$/.test(off) ? off : null };
}

/** The minutes a zone is ahead of UTC at an instant (Toronto: -300 or -240). */
function zoneOffset(ms: number, zone: string): number {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: zone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' })
    .formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
  return Math.round((Date.UTC(+p.year!, +p.month! - 1, +p.day!, +p.hour!, +p.minute!, +p.second!) - ms) / 60000);
}

/** The instant of a capture time: with its own offset when the phone wrote one, else as a wall clock in the zone (Toronto). */
export function captureInstant(c: Captured, zone = 'America/Toronto'): string | null {
  if (c.offset) { const d = new Date(`${c.local}${c.offset}`); return Number.isNaN(d.getTime()) ? null : d.toISOString(); }
  const wall = Date.parse(`${c.local}Z`);
  if (Number.isNaN(wall)) return null;
  let ms = wall - zoneOffset(wall, zone) * 60000;
  ms = wall - zoneOffset(ms, zone) * 60000;
  return new Date(ms).toISOString();
}
