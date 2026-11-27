'use client';
import { useEffect, useState, useSyncExternalStore } from 'react';
import { toStandardImage } from '@/features/uploads/standard-image';
import { captureInstant, captureTime } from './exif';
import { retryDelay, uploadKey } from './group';

// Add old photos (5185): the photos upload in the background, two at a time, each with its own progress. A photo that fails
// on the network (no signal, a timeout, the server busy) waits and tries again by itself (2, 4, 8, 16, then every 30 seconds,
// at once when the phone is back online). Its key is made from the photo's bytes, so a retry, or the same photo picked again
// later, is attached once (the server answers "already added"); a photo picked twice in one go is queued once. A refusal
// (not permitted, not a photo) stops that photo with the reason and a Try again. Leaving the page while photos are still
// going asks first.
export type Kind = 'pickup' | 'return';
export type State = 'waiting' | 'preparing' | 'uploading' | 'done' | 'failed';
export interface Upload { id: string; key: string; name: string; at: string | null; booking: string; kind: Kind; state: State; loaded: number; total: number; tries: number; error?: string; dup?: boolean }
interface Inner { u: Upload; file: File; blob?: Blob; due: number }

/** The capture time of a picked file (EXIF), read from its first bytes (a HEIC's block can sit further in: more of the file then). */
export async function pickedTime(f: File): Promise<string | null> {
  try {
    let c = captureTime(new Uint8Array(await f.slice(0, 256 * 1024).arrayBuffer()));
    if (!c && f.size > 256 * 1024) c = captureTime(new Uint8Array(await f.slice(0, 16 * 1024 * 1024).arrayBuffer()));
    return c ? captureInstant(c) : null;
  } catch { return null; }
}

type Sent = { status: number; body: { ok?: boolean; duplicate?: boolean; message?: string } | null };
function send(u: Upload, blob: Blob, onProgress: (loaded: number, total: number) => void): Promise<Sent> {
  return new Promise((resolve) => {
    const fd = new FormData();
    fd.append('booking', u.booking); fd.append('kind', u.kind); fd.append('key', u.key);
    if (u.at) fd.append('taken_at', u.at);
    fd.append('file', blob, 'photo.jpg');
    const x = new XMLHttpRequest();
    x.open('POST', '/api/old-photos');
    x.timeout = 120_000;
    x.upload.onprogress = (e) => { if (e.lengthComputable) onProgress(e.loaded, e.total); };
    x.onload = () => { let body = null; try { body = JSON.parse(x.responseText); } catch { /* not JSON */ } resolve({ status: x.status, body }); };
    x.onerror = x.ontimeout = x.onabort = () => resolve({ status: 0, body: null });
    x.send(fd);
  });
}

class Queue {
  private list: Inner[] = [];
  private snap: Upload[] = [];
  private subs = new Set<() => void>();
  private active = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;
  readonly subscribe = (f: () => void) => { this.subs.add(f); return () => { this.subs.delete(f); }; };
  readonly get = () => this.snap;
  private emit() { this.snap = this.list.map((x) => x.u); this.subs.forEach((f) => f()); }
  private patch(id: string, u: Partial<Upload>, more: Partial<Omit<Inner, 'u'>> = {}) {
    this.list = this.list.map((x) => (x.u.id === id ? { ...x, ...more, u: { ...x.u, ...u } } : x));
    this.emit();
  }
  pending() { return this.list.some((x) => x.u.state !== 'done' && x.u.state !== 'failed'); }
  async add(files: Array<{ file: File; at: string | null }>, booking: string, kind: Kind) {
    for (const { file, at } of files) {
      let key: string;
      try { key = await uploadKey(await file.arrayBuffer()); } catch { key = crypto.randomUUID(); }
      if (this.list.some((x) => x.u.key === key && x.u.booking === booking && x.u.kind === kind)) continue;
      this.list = [...this.list, { file, due: 0, u: { id: crypto.randomUUID(), key, name: file.name, at, booking, kind, state: 'waiting' as State, loaded: 0, total: file.size, tries: 0 } }];
      this.emit();
      this.pump();
    }
  }
  retry(id: string) { this.patch(id, { state: 'waiting', error: undefined }, { due: 0 }); this.pump(); }
  online() { this.list = this.list.map((x) => (x.u.state === 'waiting' ? { ...x, due: 0 } : x)); this.pump(); }
  stop() { if (this.timer) clearTimeout(this.timer); this.timer = null; }
  pump = () => {
    this.stop();
    while (this.active < 2) {
      const now = Date.now();
      const next = this.list.find((x) => x.u.state === 'waiting' && x.due <= now);
      if (!next) break;
      this.active++;
      this.patch(next.u.id, { state: 'preparing' });
      void this.run(next.u.id).finally(() => { this.active--; this.pump(); });
    }
    const later = this.list.filter((x) => x.u.state === 'waiting').map((x) => x.due);
    if (later.length && this.active < 2) this.timer = setTimeout(this.pump, Math.max(500, Math.min(...later) - Date.now()));
  };
  private async run(id: string) {
    const it = this.list.find((x) => x.u.id === id)!;
    let blob = it.blob;
    if (!blob) {
      try { blob = await toStandardImage(it.file); } catch (e) { this.patch(id, { state: 'failed', error: e instanceof Error ? e.message : 'That photo could not be read.' }); return; }
      this.patch(id, { total: blob.size }, { blob });
    }
    this.patch(id, { state: 'uploading', loaded: 0 });
    const r = await send(it.u, blob, (loaded, total) => this.patch(id, { loaded, total }));
    if (r.status === 200 && r.body?.ok) { this.patch(id, { state: 'done', loaded: blob.size, error: undefined, dup: Boolean(r.body.duplicate) }, { blob: undefined }); return; }
    if (r.status === 0 || r.status >= 500 || r.status === 408 || r.status === 429) {
      const tries = it.u.tries + 1;
      this.patch(id, { state: 'waiting', tries, loaded: 0, error: navigator.onLine ? 'No answer: trying again.' : 'No signal: it goes on when the phone is back online.' },
        { due: Date.now() + retryDelay(tries) });
      return;
    }
    this.patch(id, { state: 'failed', error: r.body?.message ?? `The upload was refused (${r.status}).` });
  }
}

const EMPTY: Upload[] = [];

export function useUploads() {
  const [q] = useState(() => new Queue());
  const items = useSyncExternalStore(q.subscribe, q.get, () => EMPTY);
  useEffect(() => {
    const online = () => q.online();
    const leave = (e: BeforeUnloadEvent) => { if (q.pending()) { e.preventDefault(); e.returnValue = ''; } };
    window.addEventListener('online', online);
    window.addEventListener('beforeunload', leave);
    return () => { window.removeEventListener('online', online); window.removeEventListener('beforeunload', leave); q.stop(); };
  }, [q]);
  const count = (s: State) => items.filter((x) => x.state === s).length;
  const total = items.reduce((n, x) => n + (x.total || 1), 0);
  const sent = items.reduce((n, x) => n + (x.state === 'done' ? (x.total || 1) : Math.min(x.loaded, x.total)), 0);
  return {
    items, done: count('done'), failed: count('failed'), going: items.length - count('done') - count('failed'), pct: total ? Math.round((sent / total) * 100) : 0,
    add: (files: Array<{ file: File; at: string | null }>, booking: string, kind: Kind) => { void q.add(files, booking, kind); },
    retry: (id: string) => q.retry(id)
  };
}
