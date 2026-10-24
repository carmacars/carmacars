'use client';
import { useEffect, useState } from 'react';

// The photo queue of the field portal (06-field.md sections 1 and 11): photos wait on the phone and upload
// one at a time in the background; a failed upload is tried again when the connection returns (and every
// 10 seconds). The queue is kept in IndexedDB, so a reload or a closed tab loses nothing; it holds only
// photos still to send and is emptied as each one arrives. No service worker caches personal data.
export interface Item { id: string; job: string; seq: number; shot: string; mode: 'photo' | 'raw'; damage_label?: string | null; blob: Blob; taken_at: string; width?: number; height?: number; flags?: string[]; latitude?: number; longitude?: number; state: 'waiting' | 'sending' | 'failed'; error?: string }
type Listener = () => void;

const DB = 'cc-field'; const STORE = 'uploads';
function idb(): Promise<IDBDatabase | null> {
  return new Promise((res) => {
    try {
      const r = indexedDB.open(DB, 1);
      r.onupgradeneeded = () => r.result.createObjectStore(STORE, { keyPath: 'id' });
      r.onsuccess = () => res(r.result); r.onerror = () => res(null);
    } catch { res(null); }
  });
}
async function tx(mode: IDBTransactionMode, fn: (s: IDBObjectStore) => void) {
  const db = await idb(); if (!db) return;
  await new Promise<void>((res) => { try { const t = db.transaction(STORE, mode); fn(t.objectStore(STORE)); t.oncomplete = () => res(); t.onerror = () => res(); } catch { res(); } });
}
const retryable = (e?: string) => /network|connection|server/i.test(e ?? '');

class Queue {
  items: Item[] = [];
  done = new Map<string, string>(); // item id, and job:seq, of this session's arrived uploads -> storage key
  private ls = new Set<Listener>();
  private running = false;
  private loaded = false;
  on(l: Listener) { this.ls.add(l); return () => { this.ls.delete(l); }; }
  private emit() { for (const l of this.ls) l(); }
  async load() {
    if (this.loaded) return; this.loaded = true;
    // photos left from an earlier visit join the queue; anything added meanwhile is kept
    await tx('readonly', (s) => { const r = s.getAll(); r.onsuccess = () => {
      const known = new Set(this.items.map((x) => x.id));
      this.items = [...this.items, ...(r.result as Item[]).filter((x) => !known.has(x.id) && !this.done.has(x.id)).map((x) => ({ ...x, state: 'waiting' as const }))];
    }; });
    this.emit(); void this.run();
    window.addEventListener('online', () => void this.run());
    setInterval(() => { if (this.items.some((x) => x.state === 'failed' && retryable(x.error))) void this.run(); }, 10_000);
  }
  async add(i: Omit<Item, 'id' | 'state'>) {
    // a retake replaces the photo of the same shot still waiting
    const old = i.mode === 'photo' ? this.items.filter((x) => x.job === i.job && x.seq === i.seq && x.mode === 'photo' && x.state !== 'sending') : [];
    this.items = this.items.filter((x) => !old.includes(x));
    const item: Item = { ...i, id: `${i.job}-${i.seq}-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`, state: 'waiting' };
    this.items.push(item);
    await tx('readwrite', (s) => { for (const o of old) s.delete(o.id); s.put(item); });
    this.emit(); void this.run();
    return item.id;
  }
  /** One upload whose storage key is needed (a signature, a late-damage close-up). */
  async addAndWait(i: Omit<Item, 'id' | 'state'>): Promise<string> {
    const id = await this.add(i);
    return new Promise((res, rej) => {
      const check = () => {
        const k = this.done.get(id);
        if (k !== undefined) { off(); res(k); return; }
        const f = this.items.find((x) => x.id === id && x.state === 'failed' && !retryable(x.error));
        if (f) { off(); rej(new Error(f.error)); }
      };
      const off = this.on(check);
      check();
    });
  }
  async run() {
    if (this.running) return; this.running = true;
    try {
      for (;;) {
        const next = this.items.find((x) => x.state === 'waiting') ?? this.items.find((x) => x.state === 'failed' && retryable(x.error));
        if (!next) break;
        if (navigator.onLine === false) { next.state = 'failed'; next.error = 'No connection: waiting for the network.'; this.emit(); break; }
        next.state = 'sending'; this.emit();
        const fd = new FormData();
        fd.set('file', next.blob, `${next.seq}-${next.shot}.jpg`); fd.set('job', next.job); fd.set('seq', String(next.seq)); fd.set('shot', next.shot); fd.set('mode', next.mode);
        fd.set('taken_at', next.taken_at); if (next.width) fd.set('width', String(next.width)); if (next.height) fd.set('height', String(next.height));
        if (next.damage_label) fd.set('damage_label', next.damage_label); if (next.flags?.length) fd.set('flags', JSON.stringify(next.flags));
        if (typeof next.latitude === 'number' && typeof next.longitude === 'number') { fd.set('latitude', String(next.latitude)); fd.set('longitude', String(next.longitude)); }
        try {
          const r = await fetch('/api/field/upload', { method: 'POST', body: fd, credentials: 'same-origin' });
          const j = (await r.json().catch(() => ({}))) as { ok?: boolean; key?: string; message?: string };
          if (r.ok && j.ok) {
            this.items = this.items.filter((x) => x.id !== next.id);
            this.done.set(next.id, j.key ?? ''); if (next.mode === 'photo') this.done.set(`${next.job}:${next.seq}`, j.key ?? '');
            await tx('readwrite', (s) => s.delete(next.id));
          } else {
            next.state = 'failed';
            next.error = r.status >= 500 ? 'Server problem: it will be sent again.' : (j.message ?? `The upload was refused (${r.status}).`);
          }
        } catch {
          next.state = 'failed'; next.error = 'Network problem: it will be sent again when the connection returns.';
          this.emit(); break;
        }
        this.emit();
      }
    } finally { this.running = false; }
  }
  /** Forget a refused photo (to take it again). */
  drop(id: string) { this.items = this.items.filter((x) => x.id !== id); void tx('readwrite', (s) => s.delete(id)); this.emit(); }
}

const g = (typeof window !== 'undefined' ? window : {}) as { __ccQueue?: Queue };
export const uploads: Queue = (g.__ccQueue ??= new Queue());

export function useUploads(job: string) {
  const [, tick] = useState(0);
  useEffect(() => { void uploads.load(); return uploads.on(() => tick((n) => n + 1)); }, []);
  const mine = uploads.items.filter((x) => x.job === job);
  return { pending: mine, failed: mine.filter((x) => x.state === 'failed'), arrived: (seq: number) => uploads.done.has(`${job}:${seq}`) };
}

/** Resize to 2400 px on the long side at JPEG 85, and check size, blur and darkness (06-field.md section 6). */
export async function preparePhoto(file: File): Promise<{ blob: Blob; width: number; height: number; flags: string[] }> {
  try {
    const bmp = await createImageBitmap(file);
    const scale = Math.min(1, 2400 / Math.max(bmp.width, bmp.height));
    const w = Math.max(1, Math.round(bmp.width * scale)); const h = Math.max(1, Math.round(bmp.height * scale));
    const c = document.createElement('canvas'); c.width = w; c.height = h;
    const cg = c.getContext('2d')!; cg.drawImage(bmp, 0, 0, w, h);
    // darkness and blur on a small copy: mean luminance and the variance of a simple edge filter
    const sw = Math.max(3, Math.round(160 * (w / Math.max(w, h)))); const sh = Math.max(3, Math.round(160 * (h / Math.max(w, h))));
    const s = document.createElement('canvas'); s.width = sw; s.height = sh; const sg = s.getContext('2d')!; sg.drawImage(c, 0, 0, sw, sh);
    const px = sg.getImageData(0, 0, sw, sh).data; const lum: number[] = [];
    for (let i = 0; i < px.length; i += 4) lum.push(0.299 * px[i]! + 0.587 * px[i + 1]! + 0.114 * px[i + 2]!);
    const mean = lum.reduce((a, b) => a + b, 0) / lum.length;
    let ev = 0; let n = 0;
    for (let y = 1; y < sh - 1; y++) for (let x = 1; x < sw - 1; x++) { const k = y * sw + x; const e = 4 * lum[k]! - lum[k - 1]! - lum[k + 1]! - lum[k - sw]! - lum[k + sw]!; ev += e * e; n++; }
    const flags: string[] = [];
    if (Math.max(bmp.width, bmp.height) < 1600) flags.push('small');
    if (mean < 40) flags.push('dark');
    if (n && ev / n < 30) flags.push('blurry');
    if (bmp.height > bmp.width) flags.push('portrait');
    const blob = await new Promise<Blob>((res, rej) => c.toBlob((b) => (b ? res(b) : rej(new Error('encode'))), 'image/jpeg', 0.85));
    return { blob, width: w, height: h, flags };
  } catch {
    return { blob: file, width: 0, height: 0, flags: ['unchecked'] };
  }
}
