// An Apple Wallet pass (.pkpass) for a confirmed booking (Release 22). No imports: Worker and `node --test`.
// A .pkpass is a zip of pass.json, the images, manifest.json (the SHA-1 of every file) and signature: a detached
// PKCS #7 (CMS) signature of manifest.json made with the Pass Type ID certificate, carrying Apple's WWDR intermediate.
// This file builds every byte; the RSA signature itself comes from WebCrypto (src/server/wallet.ts).

export interface PassFacts { number: string; car: string; pickup: string; ret: string; place: string; returnPlace: string | null; phone: string | null; site: string }
export interface PassIds { passTypeId: string; teamId: string }

const enc = new TextEncoder();
export const bytes = (s: string) => enc.encode(s);

export function passJson(f: PassFacts, ids: PassIds): Record<string, unknown> {
  const back: Array<Record<string, string>> = [{ key: 'address', label: 'Pickup address', value: f.place }];
  if (f.returnPlace && f.returnPlace !== f.place) back.push({ key: 'return_address', label: 'Return address', value: f.returnPlace });
  if (f.phone) back.push({ key: 'phone', label: 'Questions', value: f.phone });
  back.push({ key: 'manage', label: 'Your booking', value: `${f.site.replace(/\/$/, '')}/account/bookings/${f.number}` });
  return {
    formatVersion: 1, passTypeIdentifier: ids.passTypeId, teamIdentifier: ids.teamId, serialNumber: f.number,
    organizationName: 'CarmaCars', description: `CarmaCars booking ${f.number}`, logoText: 'CarmaCars',
    foregroundColor: 'rgb(255, 255, 255)', backgroundColor: 'rgb(17, 17, 17)', labelColor: 'rgb(200, 200, 200)',
    relevantDate: f.pickup, expirationDate: new Date(new Date(f.ret).getTime() + 86400e3).toISOString(),
    barcodes: [{ format: 'PKBarcodeFormatQR', message: f.number, messageEncoding: 'iso-8859-1', altText: f.number }],
    eventTicket: {
      primaryFields: [{ key: 'car', label: 'CAR', value: f.car }],
      secondaryFields: [{ key: 'pickup', label: 'PICKUP', value: f.pickup, dateStyle: 'PKDateStyleMedium', timeStyle: 'PKDateStyleShort' },
        { key: 'return', label: 'RETURN', value: f.ret, dateStyle: 'PKDateStyleMedium', timeStyle: 'PKDateStyleShort' }],
      auxiliaryFields: [{ key: 'booking', label: 'BOOKING', value: f.number }, { key: 'place', label: 'WHERE', value: f.place }],
      backFields: back
    }
  };
}

// ---------------------------------------------------------------------------------------------- a plain PNG (the icon)
const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
function crc(b: Uint8Array): number { let c = 0xffffffff; for (const x of b) c = CRC[(c ^ x) & 0xff]! ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }
const u32 = (n: number) => new Uint8Array([(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]);
function cat(parts: Uint8Array[]): Uint8Array { const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let o = 0; for (const p of parts) { out.set(p, o); o += p.length; } return out; }
function chunk(type: string, data: Uint8Array): Uint8Array { const td = cat([bytes(type), data]); return cat([u32(data.length), td, u32(crc(td))]); }
/** A square PNG: the brand's dark ground with a lighter centre square (uncompressed deflate blocks; no library). */
export function iconPng(size: number): Uint8Array {
  const row = 1 + size * 3;
  const raw = new Uint8Array(row * size);
  for (let y = 0; y < size; y++) {
    raw[y * row] = 0;
    for (let x = 0; x < size; x++) {
      const inner = x > size * 0.3 && x < size * 0.7 && y > size * 0.3 && y < size * 0.7;
      raw.set(inner ? [230, 230, 230] : [17, 17, 17], y * row + 1 + x * 3);
    }
  }
  const blocks: Uint8Array[] = [];
  for (let o = 0; o < raw.length; o += 65535) {
    const part = raw.subarray(o, Math.min(o + 65535, raw.length));
    blocks.push(new Uint8Array([o + 65535 >= raw.length ? 1 : 0, part.length & 255, part.length >> 8, ~part.length & 255, (~part.length >> 8) & 255]), part);
  }
  let a = 1, b = 0; for (const x of raw) { a = (a + x) % 65521; b = (b + a) % 65521; }
  const z = cat([new Uint8Array([0x78, 0x01]), ...blocks, u32(((b << 16) | a) >>> 0)]);
  const ihdr = cat([u32(size), u32(size), new Uint8Array([8, 2, 0, 0, 0])]);
  return cat([new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', z), chunk('IEND', new Uint8Array())]);
}

// ---------------------------------------------------------------------------------------------- DER and CMS
function len(n: number): Uint8Array { if (n < 128) return new Uint8Array([n]); const b: number[] = []; while (n > 0) { b.unshift(n & 255); n = Math.floor(n / 256); } return new Uint8Array([0x80 | b.length, ...b]); }
export const tlv = (tag: number, ...parts: Uint8Array[]) => { const c = cat(parts); return cat([new Uint8Array([tag]), len(c.length), c]); };
const seq = (...p: Uint8Array[]) => tlv(0x30, ...p);
function oid(s: string): Uint8Array {
  const n = s.split('.').map(Number); const out = [40 * n[0]! + n[1]!];
  for (const v of n.slice(2)) { const b: number[] = [v & 127]; let x = Math.floor(v / 128); while (x > 0) { b.unshift((x & 127) | 128); x = Math.floor(x / 128); } out.push(...b); }
  return tlv(0x06, new Uint8Array(out));
}
const NULL = new Uint8Array([0x05, 0x00]);
const int = (n: number) => tlv(0x02, new Uint8Array([n]));
const OID = { data: '1.2.840.113549.1.7.1', signedData: '1.2.840.113549.1.7.2', sha256: '2.16.840.1.101.3.4.2.1', rsa: '1.2.840.113549.1.1.1',
  contentType: '1.2.840.113549.1.9.3', messageDigest: '1.2.840.113549.1.9.4', signingTime: '1.2.840.113549.1.9.5' };

/** Reads one DER element at o: its tag, where its content starts and where it ends. */
export function readTlv(b: Uint8Array, o: number): { tag: number; start: number; content: number; end: number } {
  const tag = b[o]!; let l = b[o + 1]!; let c = o + 2;
  if (l & 0x80) { const k = l & 0x7f; l = 0; for (let i = 0; i < k; i++) l = l * 256 + b[o + 2 + i]!; c += k; }
  return { tag, start: o, content: c, end: c + l };
}
/** The issuer and serial number of a certificate (DER), as the signer's IssuerAndSerialNumber needs them. */
export function issuerAndSerial(cert: Uint8Array): Uint8Array {
  const certSeq = readTlv(cert, 0); const tbs = readTlv(cert, certSeq.content);
  let o = tbs.content; let e = readTlv(cert, o);
  if (e.tag === 0xa0) { o = e.end; e = readTlv(cert, o); }
  const serial = cert.subarray(e.start, e.end);
  const sigAlg = readTlv(cert, e.end); const issuer = readTlv(cert, sigAlg.end);
  return seq(cert.subarray(issuer.start, issuer.end), serial);
}
export function pemToDer(pem: string): Uint8Array {
  const b64 = pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const bin = atob(b64); const out = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out;
}
function utcTime(d: Date): Uint8Array {
  const p = (n: number) => String(n).padStart(2, '0');
  return tlv(0x17, bytes(`${p(d.getUTCFullYear() % 100)}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}Z`));
}
function cmp(a: Uint8Array, b: Uint8Array): number { for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return a[i]! - b[i]!; return a.length - b.length; }
/** The signed attributes (content type, signing time, message digest), DER sorted; tag 0x31 for signing, 0xa0 in the SignerInfo. */
export function signedAttrs(digest: Uint8Array, at: Date, tag = 0x31): Uint8Array {
  const attrs = [seq(oid(OID.contentType), tlv(0x31, oid(OID.data))), seq(oid(OID.signingTime), tlv(0x31, utcTime(at))), seq(oid(OID.messageDigest), tlv(0x31, tlv(0x04, digest)))].sort(cmp);
  return tlv(tag, ...attrs);
}
/** The detached CMS SignedData around an RSA signature of signedAttrs(digest, at). */
export function cmsSignedData(o: { signerCert: Uint8Array; chain: Uint8Array[]; digest: Uint8Array; at: Date; signature: Uint8Array }): Uint8Array {
  const sha = seq(oid(OID.sha256), NULL);
  const signer = seq(int(1), issuerAndSerial(o.signerCert), sha, signedAttrs(o.digest, o.at, 0xa0), seq(oid(OID.rsa), NULL), tlv(0x04, o.signature));
  const sd = seq(int(1), tlv(0x31, sha), seq(oid(OID.data)), tlv(0xa0, o.signerCert, ...o.chain), tlv(0x31, signer));
  return seq(oid(OID.signedData), tlv(0xa0, sd));
}
