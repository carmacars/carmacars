// The official ServiceOntario forms are filled without changing anything else in them (the owner's rule of October 23,
// 2026: "the only thing you're allowed to modify is the empty text boxes"). The publisher's PDF is kept byte for byte
// and the values are written as an incremental update after its last byte, the way Adobe Reader saves a filled form:
// - each filled text field gets its value (/V) and the appearance of that value (/AP), drawn with the field's own font,
//   size and colour (its /DA) and the form's own font resources; nothing else in the field changes;
// - checkboxes, drop-downs, radio buttons, signature boxes and buttons are never touched (they are ticked, chosen and
//   signed by hand at the counter);
// - no page, annotation, image, font or stamp is added and nothing is flattened;
// - an encrypted form (the publisher's PDFs allow filling, nothing else) stays encrypted: the update is encrypted with
//   the file's own key;
// - a form that also carries an Adobe XFA copy of its fields (a "hybrid" form) has that copy switched off in the
//   update (the /XFA entry of the form dictionary; the earlier revision keeps it), so that Adobe Reader shows the
//   same PDF fields every other viewer shows, with their values; a form that is only XFA (no PDF fields, Adobe
//   Reader only) gets its values in its XFA data (the datasets packet) instead.
// Works the same in the browser and in Node (Web Crypto, CompressionStream); no dependency but pdf-lib's font metrics.
// Relative imports with their extension: the unit tests run this file in Node directly.
import { StandardFontEmbedder } from 'pdf-lib';

export class PdfFillError extends Error {}

// ---------------------------------------------------------------- values

export type V =
  | { t: 'num'; raw: string }
  | { t: 'name'; raw: string }
  | { t: 'str'; bytes: Uint8Array }
  | { t: 'arr'; items: V[] }
  | { t: 'dict'; entries: Array<[string, V]> }
  | { t: 'ref'; num: number; gen: number }
  | { t: 'bool'; v: boolean }
  | { t: 'null' }
  | { t: 'kw'; raw: string };

export const get = (d: V | undefined, key: string): V | undefined => (d && d.t === 'dict' ? d.entries.find(([k]) => k === key)?.[1] : undefined);
const set = (d: V & { t: 'dict' }, key: string, v: V) => { const i = d.entries.findIndex(([k]) => k === key); if (i >= 0) d.entries[i] = [key, v]; else d.entries.push([key, v]); };
const del = (d: V & { t: 'dict' }, key: string) => { d.entries = d.entries.filter(([k]) => k !== key); };
const num = (v: V | undefined): number | undefined => (v && v.t === 'num' ? Number(v.raw) : undefined);
const nameOf = (v: V | undefined): string | undefined => (v && v.t === 'name' ? v.raw.replace(/#([0-9a-fA-F]{2})/g, (_, h: string) => String.fromCharCode(parseInt(h, 16))) : undefined);
const clone = (v: V): V => (v.t === 'arr' ? { t: 'arr', items: v.items.map(clone) } : v.t === 'dict' ? { t: 'dict', entries: v.entries.map(([k, x]) => [k, clone(x)]) } : v.t === 'str' ? { t: 'str', bytes: v.bytes.slice() } : { ...v });
const N = (n: number): V => ({ t: 'num', raw: fmt(n) });
const fmt = (n: number) => (Number.isInteger(n) ? String(n) : n.toFixed(3).replace(/0+$/, '').replace(/\.$/, ''));

/** A PDF text string: Latin-1 when every character is, UTF-16BE with its byte order mark otherwise. */
export function textBytes(s: string): Uint8Array {
  if ([...s].every((c) => c.charCodeAt(0) < 256)) return Uint8Array.from([...s].map((c) => c.charCodeAt(0)));
  const out = [0xfe, 0xff];
  for (let i = 0; i < s.length; i++) { const c = s.charCodeAt(i); out.push(c >> 8, c & 0xff); }
  return Uint8Array.from(out);
}
export function bytesText(b: Uint8Array): string {
  if (b[0] === 0xfe && b[1] === 0xff) { let s = ''; for (let i = 2; i + 1 < b.length; i += 2) s += String.fromCharCode((b[i]! << 8) | b[i + 1]!); return s; }
  return String.fromCharCode(...b);
}

// ---------------------------------------------------------------- lexer and parser

const WS = new Set([0, 9, 10, 12, 13, 32]);
const DELIM = new Set([40, 41, 60, 62, 91, 93, 123, 125, 47, 37]);
const latin = (b: Uint8Array, a: number, z: number) => { let s = ''; for (let i = a; i < z; i++) s += String.fromCharCode(b[i]!); return s; };

class Parser {
  b: Uint8Array; p: number;
  constructor(b: Uint8Array, p = 0) { this.b = b; this.p = p; }
  ws() { const b = this.b; for (;;) { while (this.p < b.length && WS.has(b[this.p]!)) this.p++; if (b[this.p] === 37) { while (this.p < b.length && b[this.p] !== 10 && b[this.p] !== 13) this.p++; } else return; } }
  token(): string {
    this.ws();
    const b = this.b; const a = this.p;
    if (DELIM.has(b[a]!)) { this.p++; return latin(b, a, this.p); }
    while (this.p < b.length && !WS.has(b[this.p]!) && !DELIM.has(b[this.p]!)) this.p++;
    return latin(b, a, this.p);
  }
  peekToken(): string { const p = this.p; const t = this.token(); this.p = p; return t; }
  value(): V {
    this.ws();
    const b = this.b; const c = b[this.p];
    if (c === 47) { // name
      const a = ++this.p;
      while (this.p < b.length && !WS.has(b[this.p]!) && !DELIM.has(b[this.p]!)) this.p++;
      return { t: 'name', raw: latin(b, a, this.p) };
    }
    if (c === 40) return { t: 'str', bytes: this.literal() };
    if (c === 60 && b[this.p + 1] === 60) {
      this.p += 2; const entries: Array<[string, V]> = [];
      for (;;) {
        this.ws();
        if (b[this.p] === 62 && b[this.p + 1] === 62) { this.p += 2; return { t: 'dict', entries }; }
        const k = this.value();
        if (k.t !== 'name') throw new PdfFillError('A dictionary key is not a name.');
        entries.push([k.raw, this.value()]);
      }
    }
    if (c === 60) { // hex string
      const a = ++this.p; while (this.p < b.length && b[this.p] !== 62) this.p++;
      const hex = latin(b, a, this.p).replace(/[^0-9a-fA-F]/g, ''); this.p++;
      const h = hex.length % 2 ? hex + '0' : hex;
      return { t: 'str', bytes: Uint8Array.from(h.match(/../g) ?? [], (x) => parseInt(x, 16)) };
    }
    if (c === 91) {
      this.p++; const items: V[] = [];
      for (;;) { this.ws(); if (b[this.p] === 93) { this.p++; return { t: 'arr', items }; } items.push(this.value()); }
    }
    const t = this.token();
    if (t === 'true' || t === 'false') return { t: 'bool', v: t === 'true' };
    if (t === 'null') return { t: 'null' };
    if (/^[+-]?(\d+\.?\d*|\.\d+)$/.test(t)) {
      if (/^\d+$/.test(t)) { // a reference: num gen R
        const save = this.p;
        const g = this.token();
        if (/^\d+$/.test(g) && this.token() === 'R') return { t: 'ref', num: Number(t), gen: Number(g) };
        this.p = save;
      }
      return { t: 'num', raw: t };
    }
    if (!t) throw new PdfFillError('The PDF ends too early.');
    return { t: 'kw', raw: t };
  }
  literal(): Uint8Array {
    const b = this.b; this.p++;
    const out: number[] = []; let depth = 1;
    while (this.p < b.length) {
      const c = b[this.p++]!;
      if (c === 92) {
        const n = b[this.p++]!;
        const map: Record<number, number> = { 110: 10, 114: 13, 116: 9, 98: 8, 102: 12, 40: 40, 41: 41, 92: 92 };
        if (n in map) out.push(map[n]!);
        else if (n >= 48 && n <= 55) { let o = n - 48; for (let k = 0; k < 2 && b[this.p]! >= 48 && b[this.p]! <= 55; k++) o = o * 8 + (b[this.p++]! - 48); out.push(o & 255); }
        else if (n === 13) { if (b[this.p] === 10) this.p++; }
        else if (n !== 10) out.push(n);
      } else if (c === 40) { depth++; out.push(c); }
      else if (c === 41) { if (--depth === 0) break; out.push(c); }
      else out.push(c);
    }
    return Uint8Array.from(out);
  }
}

// ---------------------------------------------------------------- serializer

const hexOf = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
function write(v: V): string {
  switch (v.t) {
    case 'num': return v.raw;
    case 'name': return '/' + v.raw;
    case 'str': return '<' + hexOf(v.bytes) + '>';
    case 'arr': return '[' + v.items.map(write).join(' ') + ']';
    case 'dict': return '<<' + v.entries.map(([k, x]) => `/${k} ${write(x)}`).join(' ') + '>>';
    case 'ref': return `${v.num} ${v.gen} R`;
    case 'bool': return v.v ? 'true' : 'false';
    case 'null': return 'null';
    case 'kw': return v.raw;
  }
}

// ---------------------------------------------------------------- compression

async function pipe(data: Uint8Array, s: { readable: ReadableStream<Uint8Array>; writable: WritableStream<Uint8Array> }): Promise<Uint8Array> {
  const w = s.writable.getWriter(); void w.write(data as unknown as Uint8Array).catch(() => undefined); void w.close().catch(() => undefined);
  const parts: Uint8Array[] = []; const r = s.readable.getReader();
  for (;;) { const { done, value } = await r.read(); if (done) break; parts.push(value); }
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}
const inflate = async (d: Uint8Array) => {
  try { return await pipe(d, new DecompressionStream('deflate') as never); }
  catch { return pipe(d.subarray(2), new DecompressionStream('deflate-raw') as never); }
};
const deflate = (d: Uint8Array) => pipe(d, new CompressionStream('deflate') as never);

function unpredict(d: Uint8Array, parms: V | undefined): Uint8Array {
  const pred = num(get(parms, 'Predictor')) ?? 1;
  if (pred < 10) { if (pred === 1) return d; throw new PdfFillError('A TIFF predictor is not supported.'); }
  const colors = num(get(parms, 'Colors')) ?? 1; const bpc = num(get(parms, 'BitsPerComponent')) ?? 8; const cols = num(get(parms, 'Columns')) ?? 1;
  const bpp = Math.max(1, Math.ceil((colors * bpc) / 8)); const row = Math.ceil((colors * bpc * cols) / 8);
  const out = new Uint8Array(Math.floor(d.length / (row + 1)) * row);
  let prev = new Uint8Array(row);
  for (let r = 0, i = 0; i + row < d.length + 1 && r * row < out.length; r++) {
    const f = d[i++]!; const cur = out.subarray(r * row, r * row + row);
    for (let k = 0; k < row; k++) {
      const x = d[i++] ?? 0; const a = k >= bpp ? cur[k - bpp]! : 0; const up = prev[k]!; const c = k >= bpp ? prev[k - bpp]! : 0;
      let v = x;
      if (f === 1) v = x + a; else if (f === 2) v = x + up; else if (f === 3) v = x + ((a + up) >> 1);
      else if (f === 4) { const p = a + up - c; const pa = Math.abs(p - a), pb = Math.abs(p - up), pc = Math.abs(p - c); v = x + (pa <= pb && pa <= pc ? a : pb <= pc ? up : c); }
      cur[k] = v & 255;
    }
    prev = cur;
  }
  return out;
}

async function decode(dict: V, data: Uint8Array): Promise<Uint8Array> {
  const f = get(dict, 'Filter'); const p = get(dict, 'DecodeParms');
  const filters = f ? (f.t === 'arr' ? f.items : [f]).map((x) => nameOf(x)) : [];
  const parms = p ? (p.t === 'arr' ? p.items : [p]) : [];
  let d = data;
  for (let i = 0; i < filters.length; i++) {
    if (filters[i] !== 'FlateDecode' && filters[i] !== 'Fl') throw new PdfFillError(`The stream filter ${filters[i]} is not supported.`);
    d = unpredict(await inflate(d), parms[i]);
  }
  return d;
}

// ---------------------------------------------------------------- encryption (the standard security handler, RC4 and AES-128)

function md5(input: Uint8Array): Uint8Array {
  const K = new Uint32Array(64).map((_, i) => Math.floor(Math.abs(Math.sin(i + 1)) * 2 ** 32) >>> 0);
  const S = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
  const len = input.length; const total = ((len + 8) >>> 6) * 64 + 64;
  const m = new Uint8Array(total); m.set(input); m[len] = 0x80;
  const bits = len * 8; for (let i = 0; i < 8; i++) m[total - 8 + i] = Math.floor(bits / 2 ** (8 * i)) & 255;
  let a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
  const w = new Uint32Array(16);
  for (let o = 0; o < total; o += 64) {
    for (let i = 0; i < 16; i++) w[i] = m[o + i * 4]! | (m[o + i * 4 + 1]! << 8) | (m[o + i * 4 + 2]! << 16) | (m[o + i * 4 + 3]! << 24);
    let a = a0, b = b0, c = c0, d = d0;
    for (let i = 0; i < 64; i++) {
      let f: number, g: number;
      if (i < 16) { f = (b & c) | (~b & d); g = i; } else if (i < 32) { f = (d & b) | (~d & c); g = (5 * i + 1) % 16; } else if (i < 48) { f = b ^ c ^ d; g = (3 * i + 5) % 16; } else { f = c ^ (b | ~d); g = (7 * i) % 16; }
      const s = S[(i >> 4) * 4 + (i % 4)]!;
      const x = (a + f + K[i]! + w[g]!) >>> 0;
      a = d; d = c; c = b; b = (b + ((x << s) | (x >>> (32 - s)))) >>> 0;
    }
    a0 = (a0 + a) >>> 0; b0 = (b0 + b) >>> 0; c0 = (c0 + c) >>> 0; d0 = (d0 + d) >>> 0;
  }
  const out = new Uint8Array(16);
  [a0, b0, c0, d0].forEach((v, i) => { for (let k = 0; k < 4; k++) out[i * 4 + k] = (v >>> (8 * k)) & 255; });
  return out;
}
function rc4(key: Uint8Array, data: Uint8Array): Uint8Array {
  const s = new Uint8Array(256).map((_, i) => i);
  for (let i = 0, j = 0; i < 256; i++) { j = (j + s[i]! + key[i % key.length]!) & 255; [s[i], s[j]] = [s[j]!, s[i]!]; }
  const out = new Uint8Array(data.length);
  for (let k = 0, i = 0, j = 0; k < data.length; k++) { i = (i + 1) & 255; j = (j + s[i]!) & 255; [s[i], s[j]] = [s[j]!, s[i]!]; out[k] = data[k]! ^ s[(s[i]! + s[j]!) & 255]!; }
  return out;
}
const PAD = Uint8Array.from([0x28, 0xbf, 0x4e, 0x5e, 0x4e, 0x75, 0x8a, 0x41, 0x64, 0x00, 0x4e, 0x56, 0xff, 0xfa, 0x01, 0x08, 0x2e, 0x2e, 0x00, 0xb6, 0xd0, 0x68, 0x3e, 0x80, 0x2f, 0x0c, 0xa9, 0xfe, 0x64, 0x53, 0x69, 0x7a]);
const cat = (...a: Uint8Array[]) => { const o = new Uint8Array(a.reduce((n, x) => n + x.length, 0)); let p = 0; for (const x of a) { o.set(x, p); p += x.length; } return o; };
const subtle = () => { const s = globalThis.crypto?.subtle; if (!s) throw new PdfFillError('This browser cannot open an encrypted PDF.'); return s; };

class Crypt {
  private key: Uint8Array; private aes: boolean;
  constructor(key: Uint8Array, aes: boolean) { this.key = key; this.aes = aes; }
  static make(enc: V, id0: Uint8Array): Crypt {
    if (nameOf(get(enc, 'Filter')) !== 'Standard') throw new PdfFillError('The PDF uses an unknown security handler.');
    const v = num(get(enc, 'V')) ?? 0; const r = num(get(enc, 'R')) ?? 2;
    if (v >= 5 || r >= 5) throw new PdfFillError('AES-256 encryption is not supported.');
    let aes = false; let n = v === 1 ? 5 : Math.floor((num(get(enc, 'Length')) ?? 40) / 8);
    if (v === 4) {
      const cf = get(get(get(enc, 'CF'), nameOf(get(enc, 'StmF')) ?? 'StdCF') as V, 'CFM');
      aes = nameOf(cf) === 'AESV2'; n = 16;
    }
    const o = (get(enc, 'O') as { bytes: Uint8Array }).bytes.subarray(0, 32);
    const p = (num(get(enc, 'P')) ?? 0) >>> 0;
    const meta = get(enc, 'EncryptMetadata');
    let h = md5(cat(PAD, o, Uint8Array.from([p & 255, (p >>> 8) & 255, (p >>> 16) & 255, (p >>> 24) & 255]), id0,
      r >= 4 && meta?.t === 'bool' && !meta.v ? Uint8Array.from([255, 255, 255, 255]) : new Uint8Array(0)));
    if (r >= 3) for (let i = 0; i < 50; i++) h = md5(h.subarray(0, n));
    return new Crypt(h.slice(0, n), aes);
  }
  private objKey(n: number, g: number) {
    const k = md5(cat(this.key, Uint8Array.from([n & 255, (n >> 8) & 255, (n >> 16) & 255, g & 255, (g >> 8) & 255]), this.aes ? Uint8Array.from([0x73, 0x41, 0x6c, 0x54]) : new Uint8Array(0)));
    return k.subarray(0, Math.min(this.key.length + 5, 16));
  }
  async decrypt(n: number, g: number, data: Uint8Array): Promise<Uint8Array> {
    const k = this.objKey(n, g);
    if (!this.aes) return rc4(k, data);
    if (data.length < 32 || data.length % 16) return data.length <= 16 ? new Uint8Array(0) : data;
    const key = await subtle().importKey('raw', k as unknown as ArrayBuffer, 'AES-CBC', false, ['decrypt']);
    return new Uint8Array(await subtle().decrypt({ name: 'AES-CBC', iv: data.slice(0, 16) }, key, data.slice(16)));
  }
  async encrypt(n: number, g: number, data: Uint8Array): Promise<Uint8Array> {
    const k = this.objKey(n, g);
    if (!this.aes) return rc4(k, data);
    const iv = globalThis.crypto.getRandomValues(new Uint8Array(16));
    const key = await subtle().importKey('raw', k as unknown as ArrayBuffer, 'AES-CBC', false, ['encrypt']);
    return cat(iv, new Uint8Array(await subtle().encrypt({ name: 'AES-CBC', iv }, key, data as unknown as ArrayBuffer)));
  }
}

// ---------------------------------------------------------------- the document

type Entry = { kind: 'off'; off: number; gen: number } | { kind: 'stm'; stm: number; idx: number } | { kind: 'free' };
export interface Obj { num: number; gen: number; value: V; stream?: Uint8Array /* decrypted, still encoded */; inStm: boolean }

export class Pdf {
  xref = new Map<number, Entry>();
  trailer: V & { t: 'dict' } = { t: 'dict', entries: [] };
  lastXrefIsStream = false;
  startxref = 0;
  crypt: Crypt | null = null;
  encryptNum = -1;
  private cache = new Map<number, Promise<Obj | null>>();
  private stms = new Map<number, Promise<{ offsets: Array<[number, number]>; data: Uint8Array; first: number }>>();
  bytes: Uint8Array;
  constructor(bytes: Uint8Array) { this.bytes = bytes; }

  static async open(bytes: Uint8Array): Promise<Pdf> {
    const d = new Pdf(bytes);
    const tail = latin(bytes, Math.max(0, bytes.length - 2048), bytes.length);
    const m = /startxref\s+(\d+)/g; let last: RegExpExecArray | null = null; let x: RegExpExecArray | null;
    while ((x = m.exec(tail))) last = x;
    if (!last) throw new PdfFillError('The PDF has no cross-reference table.');
    d.startxref = Number(last[1]);
    const seen = new Set<number>();
    let off: number | undefined = d.startxref; let first = true;
    while (off !== undefined && !seen.has(off)) {
      seen.add(off);
      const t: V & { t: 'dict' } = await d.readXref(off, first);
      if (first) d.trailer = t;
      first = false;
      const stm = num(get(t, 'XRefStm'));
      if (stm !== undefined && !seen.has(stm)) { seen.add(stm); await d.readXref(stm, false); }
      off = num(get(t, 'Prev'));
    }
    const enc = get(d.trailer, 'Encrypt');
    if (enc) {
      const id = get(d.trailer, 'ID');
      const id0 = id?.t === 'arr' && id.items[0]?.t === 'str' ? id.items[0].bytes : new Uint8Array(0);
      let encDict = enc;
      if (enc.t === 'ref') { d.encryptNum = enc.num; encDict = (await d.obj(enc.num))!.value; }
      d.crypt = Crypt.make(encDict, id0);
    }
    return d;
  }

  private async readXref(off: number, newest: boolean): Promise<V & { t: 'dict' }> {
    const p = new Parser(this.bytes, off);
    if (p.peekToken() === 'xref') {
      p.token();
      if (newest) this.lastXrefIsStream = false;
      for (;;) {
        const t = p.peekToken();
        if (t === 'trailer') { p.token(); const tr = p.value(); if (tr.t !== 'dict') throw new PdfFillError('The trailer is not a dictionary.'); return tr; }
        const start = Number(p.token()); const count = Number(p.token());
        if (!Number.isFinite(start) || !Number.isFinite(count)) throw new PdfFillError('The cross-reference table cannot be read.');
        p.ws();
        for (let i = 0; i < count; i++) {
          const line = latin(this.bytes, p.p, p.p + 20); p.p += 20;
          const [o, g, k] = line.trim().split(/\s+/);
          const n = start + i;
          if (!this.xref.has(n)) this.xref.set(n, k === 'n' ? { kind: 'off', off: Number(o), gen: Number(g) } : { kind: 'free' });
        }
      }
    }
    // a cross-reference stream
    if (newest) this.lastXrefIsStream = true;
    const o = this.parseAt(off);
    if (!o.streamAt) throw new PdfFillError('The cross-reference stream cannot be read.');
    const dict = o.value as V & { t: 'dict' };
    const data = await decode(dict, this.bytes.subarray(o.streamAt, o.streamAt + this.length(dict)));
    const W = (get(dict, 'W') as { items: V[] }).items.map((x) => num(x)!);
    const idx = get(dict, 'Index');
    const ranges = idx?.t === 'arr' ? idx.items.map((x) => num(x)!) : [0, num(get(dict, 'Size'))!];
    const width = W.reduce((a, b) => a + b, 0);
    let p2 = 0;
    const field = (w: number) => { let v = 0; for (let i = 0; i < w; i++) v = v * 256 + data[p2++]!; return v; };
    for (let r = 0; r < ranges.length; r += 2) {
      for (let i = 0; i < ranges[r + 1]!; i++) {
        if (p2 + width > data.length) break;
        const type = W[0] ? field(W[0]) : 1; const a = field(W[1]!); const b = field(W[2]!);
        const n = ranges[r]! + i;
        if (this.xref.has(n)) continue;
        this.xref.set(n, type === 1 ? { kind: 'off', off: a, gen: b } : type === 2 ? { kind: 'stm', stm: a, idx: b } : { kind: 'free' });
      }
    }
    return dict;
  }

  private length(dict: V): number {
    const l = get(dict, 'Length');
    if (l?.t === 'num') return Number(l.raw);
    if (l?.t === 'ref') {
      const e = this.xref.get(l.num);
      if (e?.kind === 'off') { const v = this.parseAt(e.off).value; if (v.t === 'num') return Number(v.raw); }
    }
    throw new PdfFillError('A stream length cannot be read.');
  }

  /** num gen obj <value> [stream] at an offset (no decryption). */
  private parseAt(off: number): { value: V; num: number; gen: number; streamAt?: number } {
    const p = new Parser(this.bytes, off);
    const n = Number(p.token()); const g = Number(p.token());
    if (p.token() !== 'obj') throw new PdfFillError(`The object at ${off} cannot be read.`);
    const value = p.value();
    const save = p.p;
    if (p.token() === 'stream') {
      let s = p.p; if (this.bytes[s] === 13) s++; if (this.bytes[s] === 10) s++;
      return { value, num: n, gen: g, streamAt: s };
    }
    p.p = save;
    return { value, num: n, gen: g };
  }

  private async decryptStrings(v: V, n: number, g: number): Promise<V> {
    if (!this.crypt) return v;
    if (v.t === 'str') return { t: 'str', bytes: await this.crypt.decrypt(n, g, v.bytes) };
    if (v.t === 'arr') return { t: 'arr', items: await Promise.all(v.items.map((x) => this.decryptStrings(x, n, g))) };
    if (v.t === 'dict') return { t: 'dict', entries: await Promise.all(v.entries.map(async ([k, x]) => [k, await this.decryptStrings(x, n, g)] as [string, V])) };
    return v;
  }

  obj(n: number): Promise<Obj | null> {
    let p = this.cache.get(n);
    if (!p) { p = this.load(n); this.cache.set(n, p); }
    return p;
  }
  private async load(n: number): Promise<Obj | null> {
    const e = this.xref.get(n);
    if (!e || e.kind === 'free') return null;
    if (e.kind === 'stm') {
      const s = await this.objStm(e.stm);
      const at = s.offsets[e.idx];
      if (!at || at[0] !== n) { const f = s.offsets.find(([k]) => k === n); if (!f) return null; return { num: n, gen: 0, value: new Parser(s.data, s.first + f[1]).value(), inStm: true }; }
      return { num: n, gen: 0, value: new Parser(s.data, s.first + at[1]).value(), inStm: true };
    }
    const o = this.parseAt(e.off);
    const plain = n === this.encryptNum;
    const value = plain ? o.value : await this.decryptStrings(o.value, n, e.gen);
    let stream: Uint8Array | undefined;
    if (o.streamAt !== undefined) {
      const raw = this.bytes.subarray(o.streamAt, o.streamAt + this.length(o.value));
      const type = nameOf(get(o.value, 'Type'));
      stream = this.crypt && !plain && type !== 'XRef' ? await this.crypt.decrypt(n, e.gen, raw) : raw;
    }
    return { num: n, gen: e.gen, value, ...(stream ? { stream } : {}), inStm: false };
  }
  private objStm(n: number) {
    let p = this.stms.get(n);
    if (!p) {
      p = (async () => {
        const o = await this.obj(n);
        if (!o?.stream) throw new PdfFillError('An object stream cannot be read.');
        const data = await decode(o.value, o.stream);
        const count = num(get(o.value, 'N'))!; const first = num(get(o.value, 'First'))!;
        const hp = new Parser(data, 0); const offsets: Array<[number, number]> = [];
        for (let i = 0; i < count; i++) offsets.push([Number(hp.token()), Number(hp.token())]);
        return { offsets, data, first };
      })();
      this.stms.set(n, p);
    }
    return p;
  }
  async resolve(v: V | undefined): Promise<V | undefined> { return v?.t === 'ref' ? (await this.obj(v.num))?.value : v; }
  async streamData(o: Obj): Promise<Uint8Array> { return o.stream ? decode(o.value, o.stream) : new Uint8Array(0); }
  get size() { return num(get(this.trailer, 'Size')) ?? Math.max(0, ...this.xref.keys()) + 1; }

  /** The incremental update: the objects as given (new or replacing), then a cross-reference section of the same kind
   *  as the file's last one, chained to it with /Prev. The original bytes come first, unchanged. */
  async update(objs: Array<{ num: number; gen: number; value: V; stream?: Uint8Array }>): Promise<Uint8Array> {
    const enc = new TextEncoder();
    const parts: Uint8Array[] = [this.bytes];
    let pos = this.bytes.length;
    const push = (b: Uint8Array) => { parts.push(b); pos += b.length; };
    const last = this.bytes[this.bytes.length - 1];
    if (last !== 10 && last !== 13) push(enc.encode('\n'));
    const offsets = new Map<number, { off: number; gen: number }>();
    const encStr = async (v: V, n: number, g: number): Promise<V> => {
      if (!this.crypt) return v;
      if (v.t === 'str') return { t: 'str', bytes: await this.crypt.encrypt(n, g, v.bytes) };
      if (v.t === 'arr') return { t: 'arr', items: await Promise.all(v.items.map((x) => encStr(x, n, g))) };
      if (v.t === 'dict') return { t: 'dict', entries: await Promise.all(v.entries.map(async ([k, x]) => [k, await encStr(x, n, g)] as [string, V])) };
      return v;
    };
    for (const o of objs.sort((a, b) => a.num - b.num)) {
      offsets.set(o.num, { off: pos, gen: o.gen });
      let value = await encStr(o.value, o.num, o.gen);
      if (o.stream) {
        const data = this.crypt ? await this.crypt.encrypt(o.num, o.gen, o.stream) : o.stream;
        value = clone(value) as V & { t: 'dict' }; set(value as V & { t: 'dict' }, 'Length', N(data.length));
        push(enc.encode(`${o.num} ${o.gen} obj\n${write(value)}\nstream\n`)); push(data); push(enc.encode('\nendstream\nendobj\n'));
      } else push(enc.encode(`${o.num} ${o.gen} obj\n${write(value)}\nendobj\n`));
    }
    const keep = ['Root', 'Info', 'ID', 'Encrypt'];
    const tr: V & { t: 'dict' } = { t: 'dict', entries: this.trailer.entries.filter(([k]) => keep.includes(k)).map(([k, v]) => [k, clone(v)]) };
    if (this.lastXrefIsStream) {
      const xnum = Math.max(this.size, ...[...offsets.keys()].map((k) => k + 1)); const size = xnum + 1;
      offsets.set(xnum, { off: pos, gen: 0 });
      const nums = [...offsets.keys()].sort((a, b) => a - b);
      const index: number[] = []; const rows: number[] = [];
      for (const n of nums) {
        if (index.length && index[index.length - 2]! + index[index.length - 1]! === n) index[index.length - 1]!++; else index.push(n, 1);
        const e = offsets.get(n)!; rows.push(1, (e.off >>> 24) & 255, (e.off >>> 16) & 255, (e.off >>> 8) & 255, e.off & 255, (e.gen >> 8) & 255, e.gen & 255);
      }
      const data = Uint8Array.from(rows);
      const d: V & { t: 'dict' } = { t: 'dict', entries: [['Type', { t: 'name', raw: 'XRef' }], ['Size', N(size)], ['W', { t: 'arr', items: [N(1), N(4), N(2)] }],
        ['Index', { t: 'arr', items: index.map(N) }], ...tr.entries, ['Prev', N(this.startxref)], ['Length', N(data.length)]] };
      push(enc.encode(`${xnum} 0 obj\n${write(d)}\nstream\n`)); push(data); push(enc.encode(`\nendstream\nendobj\nstartxref\n${offsets.get(xnum)!.off}\n%%EOF\n`));
    } else {
      const at = pos;
      const nums = [...offsets.keys()].sort((a, b) => a - b);
      let s = 'xref\n';
      for (let i = 0; i < nums.length;) {
        let j = i; while (j + 1 < nums.length && nums[j + 1] === nums[j]! + 1) j++;
        s += `${nums[i]} ${j - i + 1}\n`;
        for (let k = i; k <= j; k++) { const e = offsets.get(nums[k]!)!; s += `${String(e.off).padStart(10, '0')} ${String(e.gen).padStart(5, '0')} n\r\n`; }
        i = j + 1;
      }
      const size = Math.max(this.size, ...nums.map((n) => n + 1));
      s += `trailer\n${write({ t: 'dict', entries: [['Size', N(size)], ...tr.entries, ['Prev', N(this.startxref)]] })}\nstartxref\n${at}\n%%EOF\n`;
      push(enc.encode(s));
    }
    return cat(...parts);
  }
}

// ---------------------------------------------------------------- fields

export type FieldKind = 'text' | 'checkbox' | 'radio' | 'dropdown' | 'signature' | 'button';
export interface Field {
  name: string; kind: FieldKind; num: number; gen: number; value: V & { t: 'dict' };
  widgets: Array<{ num: number; gen: number; value: V & { t: 'dict' }; page: number; rect: [number, number, number, number] }>;
  ff: number; maxLen?: number; q: number; da: string; options?: string[]; tooltip?: string;
}

export async function pages(pdf: Pdf): Promise<number[]> {
  const out: number[] = []; const seen = new Set<number>();
  const root = await pdf.resolve(get(pdf.trailer, 'Root'));
  const walk = async (r: V | undefined) => {
    if (r?.t !== 'ref' || seen.has(r.num)) return; seen.add(r.num);
    const n = await pdf.obj(r.num); if (!n) return;
    const kids = await pdf.resolve(get(n.value, 'Kids'));
    if (nameOf(get(n.value, 'Type')) === 'Pages' || kids?.t === 'arr') { if (kids?.t === 'arr') for (const k of kids.items) await walk(k); }
    else out.push(r.num);
  };
  await walk(get(root, 'Pages'));
  return out;
}

export async function acroForm(pdf: Pdf): Promise<{ root: Obj; form: V | undefined; formNum: number | null }> {
  const r = get(pdf.trailer, 'Root');
  if (r?.t !== 'ref') throw new PdfFillError('The PDF has no catalog.');
  const root = (await pdf.obj(r.num))!;
  const a = get(root.value, 'AcroForm');
  return { root, form: await pdf.resolve(a), formNum: a?.t === 'ref' ? a.num : null };
}

/** Every terminal field of the form, with its widgets, the page of each and the inherited attributes. */
export async function fields(pdf: Pdf): Promise<Field[]> {
  const { form } = await acroForm(pdf);
  const top = await pdf.resolve(get(form, 'Fields'));
  if (top?.t !== 'arr') return [];
  const pageNums = await pages(pdf);
  const pageOf = new Map<number, number>();
  for (let i = 0; i < pageNums.length; i++) {
    const p = await pdf.obj(pageNums[i]!);
    const annots = await pdf.resolve(get(p?.value, 'Annots'));
    if (annots?.t === 'arr') for (const a of annots.items) if (a.t === 'ref') pageOf.set(a.num, i + 1);
  }
  const defDa = (await pdf.resolve(get(form, 'DA'))) as V | undefined;
  const out: Field[] = []; const seen = new Set<number>();
  type Inh = { name: string; ft?: string; ff: number; maxLen?: number; q?: number; da?: string; opt?: V };
  const walk = async (ref: V, inh: Inh) => {
    if (ref.t !== 'ref' || seen.has(ref.num)) return; seen.add(ref.num);
    const o = await pdf.obj(ref.num); if (!o || o.value.t !== 'dict') return;
    const d = o.value as V & { t: 'dict' };
    const t = get(d, 'T');
    const name = t?.t === 'str' ? (inh.name ? inh.name + '.' : '') + bytesText(t.bytes) : inh.name;
    const da = get(d, 'DA');
    const here: Inh = { name, ft: nameOf(get(d, 'FT')) ?? inh.ft, ff: num(get(d, 'Ff')) ?? inh.ff, maxLen: num(await pdf.resolve(get(d, 'MaxLen'))) ?? inh.maxLen,
      q: num(get(d, 'Q')) ?? inh.q, da: da?.t === 'str' ? bytesText(da.bytes) : inh.da, opt: get(d, 'Opt') ?? inh.opt };
    const kids = await pdf.resolve(get(d, 'Kids'));
    const fieldKids: V[] = []; const widgetKids: Array<{ num: number; gen: number; value: V & { t: 'dict' } }> = [];
    if (kids?.t === 'arr') for (const k of kids.items) {
      if (k.t !== 'ref') continue;
      const ko = await pdf.obj(k.num); if (!ko || ko.value.t !== 'dict') continue;
      if (get(ko.value, 'T')) fieldKids.push(k); else widgetKids.push({ num: ko.num, gen: ko.gen, value: ko.value as V & { t: 'dict' } });
    }
    for (const k of fieldKids) await walk(k, here);
    if (fieldKids.length && !widgetKids.length) return;
    const widgets = nameOf(get(d, 'Subtype')) === 'Widget' ? [{ num: o.num, gen: o.gen, value: d }, ...widgetKids] : widgetKids;
    const ft = here.ft; const ff = here.ff;
    const kind: FieldKind = ft === 'Tx' ? 'text' : ft === 'Ch' ? 'dropdown' : ft === 'Sig' ? 'signature' : ft === 'Btn' ? (ff & 65536 ? 'button' : ff & 32768 ? 'radio' : 'checkbox') : 'text';
    const optV = await pdf.resolve(here.opt);
    const options = optV?.t === 'arr' ? (await Promise.all(optV.items.map(async (x) => { const v = await pdf.resolve(x); return v?.t === 'str' ? bytesText(v.bytes) : v?.t === 'arr' && v.items[1]?.t === 'str' ? bytesText(v.items[1].bytes) : ''; }))) : undefined;
    const tu = get(d, 'TU');
    out.push({
      name, kind, num: o.num, gen: o.gen, value: d, ff, q: here.q ?? num(get(form, 'Q')) ?? 0, ...(here.maxLen !== undefined ? { maxLen: here.maxLen } : {}),
      da: here.da ?? (defDa?.t === 'str' ? bytesText(defDa.bytes) : '/Helv 0 Tf 0 g'), ...(options ? { options } : {}), ...(tu?.t === 'str' ? { tooltip: bytesText(tu.bytes) } : {}),
      widgets: await Promise.all(widgets.map(async (w) => {
        const r = (await pdf.resolve(get(w.value, 'Rect'))) as { items: V[] } | undefined;
        const [x1, y1, x2, y2] = (r?.items ?? []).map((x) => num(x) ?? 0);
        const p = get(w.value, 'P');
        const page = pageOf.get(w.num) ?? (p?.t === 'ref' ? pageNums.indexOf(p.num) + 1 : 0);
        return { ...w, page, rect: [Math.min(x1!, x2!), Math.min(y1!, y2!), Math.abs(x2! - x1!), Math.abs(y2! - y1!)] as [number, number, number, number] };
      }))
    });
  };
  for (const f of top.items) await walk(f, { name: '', ff: 0 });
  return out;
}

// ---------------------------------------------------------------- appearances

const WIN: Record<number, number> = { 0x20ac: 0x80, 0x201a: 0x82, 0x192: 0x83, 0x201e: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87, 0x2c6: 0x88, 0x2030: 0x89, 0x160: 0x8a, 0x2039: 0x8b, 0x152: 0x8c,
  0x17d: 0x8e, 0x2018: 0x91, 0x2019: 0x92, 0x201c: 0x93, 0x201d: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x2dc: 0x98, 0x2122: 0x99, 0x161: 0x9a, 0x203a: 0x9b, 0x153: 0x9c, 0x17e: 0x9e, 0x178: 0x9f };
const winAnsi = (s: string) => Uint8Array.from([...s], (c) => { const u = c.codePointAt(0)!; return (u >= 32 && u < 127) || (u >= 160 && u < 256) ? u : WIN[u] ?? 63; });
const STD: Record<string, string> = { Helvetica: 'Helvetica', 'Helvetica-Bold': 'Helvetica-Bold', 'Times-Roman': 'Times-Roman', 'Times-Bold': 'Times-Bold', Courier: 'Courier', 'Courier-Bold': 'Courier-Bold',
  Arial: 'Helvetica', ArialMT: 'Helvetica', 'Arial-BoldMT': 'Helvetica-Bold', TimesNewRomanPSMT: 'Times-Roman', 'TimesNewRomanPS-BoldMT': 'Times-Bold' };

interface Metrics { width: (codes: Uint8Array, size: number) => number; ascent: number; descent: number }
async function metrics(pdf: Pdf, font: V | undefined): Promise<Metrics> {
  const f = await pdf.resolve(font);
  const base = nameOf(get(f, 'BaseFont')) ?? 'Helvetica';
  const widths = await pdf.resolve(get(f, 'Widths')); const first = num(get(f, 'FirstChar')) ?? 0;
  const fd = await pdf.resolve(get(f, 'FontDescriptor'));
  const std = StandardFontEmbedder.for((STD[base.replace(/^[A-Z]{6}\+/, '')] ?? 'Helvetica') as never);
  const ascent = (num(get(fd, 'Ascent')) ?? (/Times/.test(base) ? 683 : 718)) / 1000; const descent = (num(get(fd, 'Descent')) ?? (/Times/.test(base) ? -217 : -207)) / 1000;
  if (widths?.t === 'arr') {
    const w = widths.items.map((x) => num(x) ?? 0); const missing = num(get(fd, 'MissingWidth')) ?? 0;
    return { ascent, descent, width: (codes, size) => codes.reduce((s, c) => s + (w[c - first] ?? missing), 0) * size / 1000 };
  }
  return { ascent, descent, width: (codes, size) => std.widthOfTextAtSize(String.fromCharCode(...codes.map((c) => (c >= 128 && c < 160 ? 63 : c))).replace(/[^\x20-\xff]/g, '?'), size) };
}
const latinBytes = (s: string) => Uint8Array.from(s, (c) => c.charCodeAt(0) & 255);
const pdfString = (b: Uint8Array) => '(' + Array.from(b, (c) => (c === 40 || c === 41 || c === 92 ? '\\' + String.fromCharCode(c) : c === 10 ? '\\n' : c === 13 ? '\\r' : c < 32 || c > 126 ? '\\' + c.toString(8).padStart(3, '0') : String.fromCharCode(c))).join('') + ')';

/** The appearance of a filled text field, as Acrobat draws it: the field's font, size and colour from its /DA, its
 *  alignment (/Q), comb and multiline layout, clipped to the box less its border. Returns the stream and its dict. */
async function textAppearance(pdf: Pdf, form: V | undefined, f: Field, w: Field['widgets'][number], text: string): Promise<{ dict: V & { t: 'dict' }; data: Uint8Array }> {
  const mk = await pdf.resolve(get(w.value, 'MK'));
  const rot = (((num(get(mk, 'R')) ?? 0) % 360) + 360) % 360;
  const [, , rw, rh] = w.rect;
  const W = rot === 90 || rot === 270 ? rh : rw; const H = rot === 90 || rot === 270 ? rw : rh;
  const da = f.da;
  const m = /\/([^\s/]+)\s+([\d.]+)\s+Tf/.exec(da);
  const fontName = m?.[1] ?? 'Helv'; let size = Number(m?.[2] ?? 0);
  const dr = await pdf.resolve(get(form, 'DR')); const fonts = await pdf.resolve(get(dr, 'Font'));
  // the form's own font; a standard font the form names without defining it (Acrobat's Helv, TiRo, Cour) is the base font
  const STD_ALIAS: Record<string, string> = { Helv: 'Helvetica', HeBo: 'Helvetica-Bold', TiRo: 'Times-Roman', TiBo: 'Times-Bold', Cour: 'Courier', CoBo: 'Courier-Bold' };
  const plainName = fontName.replace(/#([0-9a-fA-F]{2})/g, (_, h: string) => String.fromCharCode(parseInt(h, 16)));
  const std = STD_ALIAS[plainName] ?? (STD[plainName] ? plainName : null);
  const fontRef = get(fonts, plainName) ?? get(fonts, fontName) ?? (std ? { t: 'dict', entries: [['Type', { t: 'name', raw: 'Font' }], ['Subtype', { t: 'name', raw: 'Type1' }],
    ['BaseFont', { t: 'name', raw: STD[std] ?? std }], ['Encoding', { t: 'name', raw: 'WinAnsiEncoding' }]] } as V : undefined);
  if (!fontRef) throw new PdfFillError(`The font ${fontName} of ${f.name} is not in the form's resources.`);
  const mt = await metrics(pdf, fontRef);
  const bs = await pdf.resolve(get(w.value, 'BS'));
  const bc = await pdf.resolve(get(mk, 'BC')); const bg = await pdf.resolve(get(mk, 'BG'));
  const bw = bc?.t === 'arr' && bc.items.length ? num(get(bs, 'W')) ?? 1 : 0;
  const pad = bw + 2;
  const codes = winAnsi(text);
  const lineH = (mt.ascent - mt.descent);
  const multiline = !!(f.ff & 4096); const comb = !!(f.ff & 16777216) && !!f.maxLen && !multiline;
  const color = (a: V | undefined, op: string) => { if (a?.t !== 'arr') return ''; const c = a.items.map((x) => fmt(num(x) ?? 0)); return c.length === 1 ? `${c[0]} ${op === 'rg' ? 'g' : 'G'}` : c.length === 3 ? `${c.join(' ')} ${op}` : c.length === 4 ? `${c.join(' ')} ${op === 'rg' ? 'k' : 'K'}` : ''; };
  let body = '';
  const daWith = (s: number) => da.replace(/([\d.]+)(\s+Tf)/, `${fmt(s)}$2`);
  if (multiline) {
    if (!size) size = 12;
    const wrap = (s: number) => {
      const lines: Uint8Array[] = [];
      for (const para of text.split(/\r\n|\r|\n/)) {
        let cur = '';
        for (const word of para.split(/(\s+)/)) {
          const next = cur + word;
          if (cur && mt.width(winAnsi(next.trimEnd()), s) > W - 2 * pad) { lines.push(winAnsi(cur.trimEnd())); cur = word.trimStart(); } else cur = next;
        }
        lines.push(winAnsi(cur.trimEnd()));
      }
      return lines;
    };
    let lines = wrap(size);
    while (size > 4 && lines.length * lineH * size > H - 2 * pad) { size -= 0.5; lines = wrap(size); }
    const lead = lineH * size;
    body = `BT\n${daWith(size)}\n${fmt(pad)} ${fmt(H - pad - mt.ascent * size)} Td\n${lead.toFixed(2)} TL\n` + lines.map((l, i) => (i ? 'T* ' : '') + pdfString(l) + ' Tj').join('\n') + '\nET';
  } else if (comb) {
    if (!size) size = Math.min(12, (H - 2 * pad) / lineH);
    const cell = W / f.maxLen!; const y = (H - lineH * size) / 2 - mt.descent * size;
    body = `BT\n${daWith(size)}\n` + Array.from(codes.subarray(0, f.maxLen), (c, i) => { const cw = mt.width(Uint8Array.of(c), size); return `1 0 0 1 ${fmt(i * cell + (cell - cw) / 2)} ${fmt(y)} Tm ${pdfString(Uint8Array.of(c))} Tj`; }).join('\n') + '\nET';
  } else {
    if (!size) { size = Math.min(12, (H - 2 * bw - 2) / lineH); }
    // a value wider than its box is shown smaller rather than cut
    while (size > 4 && mt.width(codes, size) > W - 2 * pad) size -= 0.25;
    const tw = mt.width(codes, size);
    const x = f.q === 1 ? (W - tw) / 2 : f.q === 2 ? W - pad - tw : pad;
    const y = (H - lineH * size) / 2 - mt.descent * size;
    body = `BT\n${daWith(size)}\n${fmt(x)} ${fmt(y)} Td\n${pdfString(codes)} Tj\nET`;
  }
  const bgOp = color(bg, 'rg'); const bcOp = color(bc, 'RG');
  const content = `${bgOp ? `q ${bgOp} 0 0 ${fmt(W)} ${fmt(H)} re f Q\n` : ''}${bcOp && bw ? `q ${bcOp} ${fmt(bw)} w ${fmt(bw / 2)} ${fmt(bw / 2)} ${fmt(W - bw)} ${fmt(H - bw)} re S Q\n` : ''}/Tx BMC\nq\n${fmt(bw + 1)} ${fmt(bw + 1)} ${fmt(Math.max(0, W - 2 * bw - 2))} ${fmt(Math.max(0, H - 2 * bw - 2))} re W n\n${body}\nQ\nEMC\n`;
  const matrix = rot === 90 ? [0, 1, -1, 0, 0, 0] : rot === 180 ? [-1, 0, 0, -1, 0, 0] : rot === 270 ? [0, -1, 1, 0, 0, 0] : null;
  const dict: V & { t: 'dict' } = { t: 'dict', entries: [['Type', { t: 'name', raw: 'XObject' }], ['Subtype', { t: 'name', raw: 'Form' }], ['BBox', { t: 'arr', items: [N(0), N(0), N(W), N(H)] }],
    ...(matrix ? [['Matrix', { t: 'arr', items: matrix.map(N) }] as [string, V]] : []),
    ['Resources', { t: 'dict', entries: [['Font', { t: 'dict', entries: [[fontName, clone(fontRef)]] }]] }]] };
  return { dict, data: latinBytes(content) };
}

// ---------------------------------------------------------------- XFA data (a form that is only XFA)

export interface XNode { name: string; start: number; openEnd: number; closeStart: number; end: number; self: boolean; children: XNode[]; parent: XNode | null; attrs: string }
export function xmlTree(s: string): XNode {
  const root: XNode = { name: '#root', start: 0, openEnd: 0, closeStart: s.length, end: s.length, self: false, children: [], parent: null, attrs: '' };
  let cur = root; let i = 0;
  while ((i = s.indexOf('<', i)) >= 0) {
    if (s.startsWith('<?', i)) { i = s.indexOf('?>', i) + 2; continue; }
    if (s.startsWith('<!--', i)) { i = s.indexOf('-->', i) + 3; continue; }
    if (s.startsWith('<![CDATA[', i)) { i = s.indexOf(']]>', i) + 3; continue; }
    if (s.startsWith('<!', i)) { i = s.indexOf('>', i) + 1; continue; }
    if (s[i + 1] === '/') { const e = s.indexOf('>', i); cur.closeStart = i; cur.end = e + 1; cur = cur.parent ?? root; i = e + 1; continue; }
    let j = i + 1; let q: string | null = null;
    for (; j < s.length; j++) { const c = s[j]!; if (q) { if (c === q) q = null; } else if (c === '"' || c === "'") q = c; else if (c === '>') break; }
    const tag = s.slice(i + 1, j); const self = tag.trimEnd().endsWith('/');
    const name = /^[^\s/>]+/.exec(tag)?.[0] ?? '';
    const node: XNode = { name, start: i, openEnd: j + 1, closeStart: j + 1, end: j + 1, self, children: [], parent: cur, attrs: tag.slice(name.length) };
    cur.children.push(node);
    if (!self) cur = node;
    i = j + 1;
  }
  return root;
}
const local = (n: string) => n.replace(/^[^:]*:/, '');
const escXml = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
function dataRoot(t: XNode): XNode | null {
  const ds = t.children.find((c) => local(c.name) === 'datasets');
  return ds?.children.find((c) => local(c.name) === 'data') ?? null;
}
/** The data node of a field named as Acrobat names XFA fields (form1[0].page1[0].body[0].orgName[0]): unnamed subforms
 *  (#subform[n]) are transparent; an unnamed field (#field[n]) has no data. */
function dataNode(data: XNode, som: string): XNode | null {
  let cur: XNode | null = data;
  for (const seg of som.split('.')) {
    const m = /^(.+?)(?:\[(\d+)\])?$/.exec(seg); if (!m) return null;
    if (m[1]!.startsWith('#subform')) continue;
    if (m[1]!.startsWith('#')) return null;
    const same: XNode[] = cur!.children.filter((c) => local(c.name) === m[1]);
    cur = same[Number(m[2] ?? 0)] ?? null;
    if (!cur) return null;
  }
  return cur === data ? null : cur;
}
/** The text fields an XFA-only form keeps data for, named the way the fill maps them (from its data, in order). */
function xfaFieldNames(xml: string, template: string | null): Array<{ name: string; type: FieldKind }> {
  const t = xmlTree(xml); const data = dataRoot(t); if (!data) return [];
  const types = new Map<string, FieldKind>();
  if (template) for (const m of template.matchAll(/<field\b[^>]*\bname="([^"]+)"[^>]*>([\s\S]*?)<\/field\s*>/g)) {
    if (types.has(m[1]!)) continue;
    const ui = /<ui\b[^>]*>\s*<(\w+)/.exec(m[2]!)?.[1];
    types.set(m[1]!, ui === 'checkButton' ? 'checkbox' : ui === 'choiceList' ? 'dropdown' : ui === 'signature' ? 'signature' : ui === 'button' ? 'button' : 'text');
  }
  const out: Array<{ name: string; type: FieldKind }> = [];
  const walk = (n: XNode, path: string) => {
    const counts = new Map<string, number>();
    for (const c of n.children) {
      const nm = local(c.name); const i = counts.get(nm) ?? 0; counts.set(nm, i + 1);
      const p = `${path ? path + '.' : ''}${nm}[${i}]`;
      if (/dataNode="dataGroup"/.test(c.attrs)) continue;
      if (c.children.length) walk(c, p); else out.push({ name: p, type: types.get(nm) ?? 'text' });
    }
  };
  walk(data, '');
  return out;
}
export async function xfaPackets(pdf: Pdf, form: V | undefined): Promise<Map<string, V>> {
  const x = await pdf.resolve(get(form, 'XFA'));
  const out = new Map<string, V>();
  if (x?.t === 'arr') for (let i = 0; i + 1 < x.items.length; i += 2) { const k = x.items[i]!; if (k.t === 'str') out.set(bytesText(k.bytes), x.items[i + 1]!); }
  else if (x?.t === 'ref') out.set('xdp', x);
  return out;
}
export async function packetText(pdf: Pdf, v: V | undefined): Promise<string | null> {
  if (v?.t !== 'ref') return null;
  const o = await pdf.obj(v.num); if (!o?.stream) return null;
  return new TextDecoder().decode(await pdf.streamData(o));
}

// ---------------------------------------------------------------- the API

export interface ReadField { name: string; type: FieldKind; page?: number; rect?: [number, number, number, number]; options?: string[]; tooltip?: string; max_length?: number }
/** The fields of a form: its PDF fields, or for a form that is only XFA, the text fields its XFA data keeps. */
export async function readPdfFields(bytes: Uint8Array): Promise<{ fields: ReadField[]; pages: number; xfaOnly: boolean }> {
  const pdf = await Pdf.open(bytes);
  const fs = await fields(pdf);
  const pageCount = (await pages(pdf)).length;
  if (fs.length) return { pages: pageCount, xfaOnly: false, fields: fs.map((f) => ({ name: f.name, type: f.kind, ...(f.widgets[0]?.page ? { page: f.widgets[0].page, rect: f.widgets[0].rect } : {}), ...(f.options?.length ? { options: f.options } : {}), ...(f.tooltip ? { tooltip: f.tooltip } : {}), ...(f.maxLen ? { max_length: f.maxLen } : {}) })) };
  const { form } = await acroForm(pdf);
  const packets = await xfaPackets(pdf, form);
  const ds = await packetText(pdf, packets.get('datasets'));
  return { pages: pageCount, xfaOnly: !!ds, fields: ds ? xfaFieldNames(ds, await packetText(pdf, packets.get('template'))) : [] };
}

export interface FillOut { bytes: Uint8Array; filled: string[]; missing: string[]; truncated: string[]; skipped: string[]; xfaOnly: boolean; xfaOff: boolean }
/** Fill the text fields named in values; any other field named (a checkbox, a drop-down, a signature) is left as it is
 *  and listed in skipped. A value longer than its field's maximum length is cut to it and listed in truncated. */
export async function fillTextFields(bytes: Uint8Array, values: Record<string, string | null>): Promise<FillOut> {
  const pdf = await Pdf.open(bytes);
  const { root, form, formNum } = await acroForm(pdf);
  const all = await fields(pdf);
  const byName = new Map(all.map((f) => [f.name, f]));
  const filled: string[] = []; const missing: string[] = []; const truncated: string[] = []; const skipped: string[] = [];
  const objs: Array<{ num: number; gen: number; value: V; stream?: Uint8Array }> = [];
  let next = pdf.size;
  const packets = await xfaPackets(pdf, form);
  const xfaOnly = !all.length && packets.has('datasets');
  let xml: string | null = null; let tree: XNode | null = null; const edits: Array<{ node: XNode; text: string }> = [];
  if (xfaOnly) { xml = await packetText(pdf, packets.get('datasets')); tree = xml ? xmlTree(xml) : null; }
  for (const [name, raw] of Object.entries(values)) {
    const v = (raw ?? '').replace(/\s+$/, '');
    if (xfaOnly) {
      const node = tree ? dataNode(dataRoot(tree)!, name) : null;
      if (!node || node.children.length) { missing.push(name); continue; }
      if (!v) continue;
      edits.push({ node, text: v }); filled.push(name); continue;
    }
    const f = byName.get(name);
    if (!f) { missing.push(name); continue; }
    if (f.kind !== 'text') { skipped.push(name); continue; }
    if (!v) continue;
    if (f.ff & 1) { skipped.push(name); continue; } // read-only
    let text = v;
    if (f.maxLen && text.length > f.maxLen) { truncated.push(name); text = text.slice(0, f.maxLen); }
    const fieldDict = clone(f.value) as V & { t: 'dict' };
    set(fieldDict, 'V', { t: 'str', bytes: textBytes(text) });
    const widgetDicts = new Map<number, V & { t: 'dict' }>();
    for (const w of f.widgets) {
      const ap = await textAppearance(pdf, form, f, w, text);
      const apNum = next++;
      objs.push({ num: apNum, gen: 0, value: ap.dict, stream: ap.data });
      const wd = w.num === f.num ? fieldDict : (widgetDicts.get(w.num) ?? (clone(w.value) as V & { t: 'dict' }));
      set(wd, 'AP', { t: 'dict', entries: [['N', { t: 'ref', num: apNum, gen: 0 }]] });
      if (w.num !== f.num) widgetDicts.set(w.num, wd);
    }
    objs.push({ num: f.num, gen: f.gen, value: fieldDict });
    for (const [n, d] of widgetDicts) objs.push({ num: n, gen: f.widgets.find((w) => w.num === n)!.gen, value: d });
    filled.push(name);
  }
  let xfaOff = false;
  if (xfaOnly && edits.length && xml) {
    let out = xml;
    for (const { node, text } of edits.sort((a, b) => b.node.start - a.node.start)) {
      out = node.self
        ? out.slice(0, node.start) + out.slice(node.start, node.openEnd).replace(/\s*\/>$/, '>') + escXml(text) + `</${node.name}>` + out.slice(node.end)
        : out.slice(0, node.openEnd) + escXml(text) + out.slice(node.closeStart);
    }
    const ref = packets.get('datasets') as V & { t: 'ref' };
    const o = (await pdf.obj(ref.num))!;
    if (o.inStm) throw new PdfFillError('The XFA data cannot be updated.');
    const d = clone(o.value) as V & { t: 'dict' }; del(d, 'DecodeParms'); set(d, 'Filter', { t: 'name', raw: 'FlateDecode' });
    objs.push({ num: o.num, gen: o.gen, value: d, stream: await deflate(new TextEncoder().encode(out)) });
  } else if (!xfaOnly && packets.size && filled.length) {
    // a hybrid form: Adobe Reader would show its XFA copy, still empty; switched off so every viewer shows these fields
    if (formNum !== null) { const a = clone(form!) as V & { t: 'dict' }; del(a, 'XFA'); objs.push({ num: formNum, gen: (await pdf.obj(formNum))!.gen, value: a }); }
    else { const r = clone(root.value) as V & { t: 'dict' }; const a = get(r, 'AcroForm') as V & { t: 'dict' }; del(a, 'XFA'); objs.push({ num: root.num, gen: root.gen, value: r }); }
    xfaOff = true;
  }
  return { bytes: objs.length ? await pdf.update(objs) : bytes.slice(), filled, missing, truncated, skipped, xfaOnly, xfaOff };
}

/** The values a filled form holds: each text field's /V, or for a form that is only XFA each leaf of its data, by the
 *  names the fill uses (for the tests and the checks of a downloaded form). */
export async function filledValues(bytes: Uint8Array): Promise<Record<string, string>> {
  const pdf = await Pdf.open(bytes);
  const all = await fields(pdf);
  const out: Record<string, string> = {};
  if (all.length) {
    for (const f of all) { const v = get(f.value, 'V'); if (v?.t === 'str') out[f.name] = bytesText(v.bytes); else if (v?.t === 'name') out[f.name] = nameOf(v)!; }
    return out;
  }
  const { form } = await acroForm(pdf);
  const xml = await packetText(pdf, (await xfaPackets(pdf, form)).get('datasets'));
  const data = xml ? dataRoot(xmlTree(xml)) : null;
  if (!data || !xml) return out;
  const unesc = (t: string) => t.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
  const walk = (n: XNode, path: string) => {
    const counts = new Map<string, number>();
    for (const c of n.children) {
      const nm = local(c.name); const i = counts.get(nm) ?? 0; counts.set(nm, i + 1);
      const p = `${path ? path + '.' : ''}${nm}[${i}]`;
      if (c.children.length) walk(c, p); else if (!c.self) out[p] = unesc(xml.slice(c.openEnd, c.closeStart));
    }
  };
  walk(data, '');
  return out;
}
