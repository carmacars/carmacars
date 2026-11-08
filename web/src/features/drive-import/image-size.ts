// The size of a JPEG or PNG from its first bytes, as the camera held it (the EXIF orientation of a JPEG turns width and
// height when it is 5 to 8), so an imported photo is recorded like one the capture screen sent. Pure; image-size.test.ts.

export interface Size { width: number; height: number; orientation: number }

export function imageSize(b: Uint8Array): Size | null {
  if (b.length > 24 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) {
    const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    const width = dv.getUint32(16), height = dv.getUint32(20);
    return width > 0 && height > 0 ? { width, height, orientation: 1 } : null;
  }
  if (!(b.length > 4 && b[0] === 0xff && b[1] === 0xd8)) return null;
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let orientation = 1;
  let i = 2;
  while (i + 4 <= b.length) {
    if (b[i] !== 0xff) { i++; continue; }
    const marker = b[i + 1]!;
    if (marker === 0xff) { i++; continue; }
    if (marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7) || marker === 0x01) { i += 2; continue; }
    const len = dv.getUint16(i + 2);
    if (len < 2) return null;
    if (marker === 0xe1 && i + 10 < b.length && b[i + 4] === 0x45 && b[i + 5] === 0x78 && b[i + 6] === 0x69 && b[i + 7] === 0x66) orientation = exifOrientation(dv, i + 10, Math.min(b.length, i + 2 + len)) ?? orientation;
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      if (i + 9 > b.length) return null;
      const height = dv.getUint16(i + 5), width = dv.getUint16(i + 7);
      if (!(width > 0 && height > 0)) return null;
      return orientation >= 5 ? { width: height, height: width, orientation } : { width, height, orientation };
    }
    i += 2 + len;
  }
  return null;
}

function exifOrientation(dv: DataView, tiff: number, end: number): number | null {
  if (tiff + 8 > end) return null;
  const little = dv.getUint16(tiff) === 0x4949;
  if (!little && dv.getUint16(tiff) !== 0x4d4d) return null;
  const ifd = tiff + dv.getUint32(tiff + 4, little);
  if (ifd + 2 > end) return null;
  const n = dv.getUint16(ifd, little);
  for (let k = 0; k < n; k++) {
    const e = ifd + 2 + k * 12;
    if (e + 12 > end) return null;
    if (dv.getUint16(e, little) === 0x0112) { const v = dv.getUint16(e + 8, little); return v >= 1 && v <= 8 ? v : null; }
  }
  return null;
}
