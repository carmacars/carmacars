import 'server-only';
import { after } from 'next/server';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { storage, type Bucket } from '@/integrations/storage';
import { photoProcessor } from '@/integrations/photos';
import { sha256Hex } from '@/server/links';
import { workerToken } from '@/server/listing-worker';
import { recordSort, sortShot } from '@/server/listing-sort';
import {
  apiDownloadUrl, apiListUrl, byFileName, embeddedViewUrl, folderPageUrl, htmlReason, imageKindOf, mergeEntries, parseApiList, parseEmbeddedView, parseFolderPage,
  publicDownloadUrl, sniffBytes, type DriveEntry, type ImageKind
} from '@/features/drive-import/drive-folder';
import { imageSize } from '@/features/drive-import/image-size';
import { matchFolder, type Car } from '@/features/drive-import/drive-match';

// Import photos from a Google Drive link (release 33, migration 0760). The runs and their state are the database's
// (drive_imports, drive_import_folders, drive_import_files); this is the Worker's side, in steps of one request each
// (like the signed copies of 0077): scan some folders, or match the folders to cars, or take a few photos. A step
// ends by starting the next one in its own request (service binding); the five-minute cron starts one that was lost.
//   * Listing a folder: with program_settings.google_drive_api_key the Drive v3 API (files.list); without, the folder
//     page's embedded data (and the embedded folder view, which lists every entry, when the page holds 50).
//   * Downloading: the API (alt=media) with the key, else drive.usercontent.google.com/download?...&confirm=t.
//   * Each photo goes through the listing upload as a staff upload does (app.record_listing_upload, by the person who
//     started the run): the shot sorted as "Add photos" sorts it, else filed as an extra photo, in the folder's file order.
//   * Politeness: one request at a time, a pause between two requests to Drive, at most 3 photos per step, 15 MB a photo,
//     5000 photos / 2000 folders / 40 GB a run (the database's app.drive_import_limits); a Drive that says "too many requests"
//     is left alone for a while and the photo is tried again later (3 tries).
const SR = { role: 'service_role' as const };

export interface Limits { max_files: number; max_folders: number; max_depth: number; max_total_bytes: number; max_file_bytes: number; pause_ms: number; tries: number }
type FolderJob = { id: string; drive_id: string; name: string; path: string; depth: number };
type MatchJob = { id: string; name: string; path: string; depth: number; images: number; ancestors: string[] };
type FileJob = { id: string; drive_id: string; name: string; mime: string | null; size: number | null; kind: ImageKind | null; vehicle_id: string; attempts: number };
type Claim = null
  | { phase: 'scan'; import: { id: string; kind: string }; folders: FolderJob[]; limits: Limits }
  | { phase: 'match'; import: { id: string; kind: string }; folders: MatchJob[]; limits: Limits }
  | { phase: 'import'; import: { id: string; kind: string }; files: FileJob[]; limits: Limits }
  | { phase: 'wait' | 'done'; import: { id: string; kind: string } };

const UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- starting a step
/** Starts /api/jobs/drive-import after the response: through the Worker's own service binding (its own invocation), else the
 *  site's address. A kick that fails changes nothing: the five-minute tick starts it. */
export function kickDriveImport(): void {
  try {
    after(async () => {
      try { await callJobs(); } catch (e) { console.error('drive import kick', e); }
    });
  } catch { /* outside a request (a script): the tick starts it */ }
}

async function callJobs(): Promise<void> {
  const url = `${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}/api/jobs/drive-import`;
  const init = { method: 'POST', headers: { authorization: `Bearer ${await workerToken()}` } };
  let self: { fetch(r: Request): Promise<Response> } | undefined;
  try {
    const { getCloudflareContext } = await import('@opennextjs/cloudflare');
    self = ((await getCloudflareContext({ async: true })).env as Record<string, unknown>).WORKER_SELF_REFERENCE as typeof self;
  } catch { self = undefined; }
  const r = self ? await self.fetch(new Request(url, init)) : await fetch(url, init);
  await r.text().catch(() => undefined);
}

/** The five-minute tick (the listing route): starts a step when a run has work. */
export async function kickDriveImportIfDue(): Promise<boolean> {
  const due = (await rpc('server_drive_import_due', {}, SR).catch(() => false)) as unknown as boolean;
  if (due) kickDriveImport();
  return due === true;
}

// ---------------------------------------------------------------- listing a folder
export interface FolderListing { entries: DriveEntry[]; note?: string; error?: string; rateLimited?: boolean; title?: string }

/** The entries of one Drive folder. `f` is fetch (a test passes its own). */
export async function listFolder(id: string, key: string | null, f: typeof fetch = fetch): Promise<FolderListing> {
  try {
    if (key) {
      const entries: DriveEntry[] = [];
      let token: string | null = null;
      for (let page = 0; page < 20; page++) {
        const r: Response = await f(apiListUrl(id, key, token), { signal: AbortSignal.timeout(20_000) });
        if (r.status === 429) return { entries, rateLimited: true, error: 'Google asked us to slow down' };
        if (r.status === 404) return { entries, error: 'Drive cannot find that folder' };
        if (r.status === 403 || r.status === 401) {
          const j = (await r.json().catch(() => null)) as { error?: { errors?: Array<{ reason?: string }> } } | null;
          const reason = j?.error?.errors?.[0]?.reason ?? '';
          if (/rateLimit|userRateLimit|quota/i.test(reason)) return { entries, rateLimited: true, error: 'Google asked us to slow down' };
          return { entries, error: 'The folder is not shared with "Anyone with the link", or the Drive API key is not allowed to use the Drive API' };
        }
        if (!r.ok) return { entries, error: `Drive answered ${r.status}` };
        const p = parseApiList(await r.json().catch(() => null));
        entries.push(...p.entries);
        token = p.next;
        if (!token) break;
        await sleep(150);
      }
      return { entries };
    }
    const r = await f(folderPageUrl(id), { headers: { 'user-agent': UA, 'accept-language': 'en-US,en;q=0.9' }, signal: AbortSignal.timeout(20_000), redirect: 'follow' });
    if (r.status === 429) return { entries: [], rateLimited: true, error: 'Google asked us to slow down' };
    if (r.status === 404) return { entries: [], error: 'Drive cannot find that folder' };
    if (/accounts\.google\.com/.test(r.url ?? '')) return { entries: [], error: 'The folder is not shared with "Anyone with the link"' };
    if (!r.ok) return { entries: [], error: `Drive answered ${r.status}` };
    const page = parseFolderPage(await r.text());
    if (!page.found) return { entries: [], error: 'The folder is not shared with "Anyone with the link", or Drive changed its page' };
    let entries = page.entries;
    let note: string | undefined;
    if (page.maybeMore) {
      // the page holds its first 50 entries; the embedded view lists the whole folder
      await sleep(300);
      const e = await f(embeddedViewUrl(id), { headers: { 'user-agent': UA, 'accept-language': 'en-US,en;q=0.9' }, signal: AbortSignal.timeout(20_000), redirect: 'follow' }).catch(() => null);
      const more = e && e.ok ? parseEmbeddedView(await e.text()) : null;
      if (more && more.entries.length > entries.length) entries = mergeEntries(entries, more.entries);
      else note = 'Drive showed only the first 50 entries of this folder. Ask an Admin to set the Google Drive API key (Settings) to read all of them.';
    }
    return { entries, note, title: page.title };
  } catch (e) {
    return { entries: [], error: e instanceof Error && (e.name === 'TimeoutError' || e.name === 'AbortError') ? 'Drive did not answer in time' : 'Drive could not be reached' };
  }
}

/** A listing as the database takes it: the subfolders, the photos in file order (those too large already skipped), the rest counted. */
export function toFolderResult(l: FolderListing, maxFileBytes: number): Json {
  const folders = l.entries.filter((e) => e.folder).map((e) => ({ id: e.id, name: e.name })).sort(byFileName);
  const files = l.entries.filter((e) => !e.folder);
  const images = files.map((e) => ({ e, kind: imageKindOf(e) })).filter((x): x is { e: DriveEntry; kind: ImageKind } => !!x.kind)
    .sort((a, b) => byFileName(a.e, b.e))
    .map(({ e, kind }) => ({ id: e.id, name: e.name, mime: e.mime || null, size: e.size ?? null, kind, ...(e.size && e.size > maxFileBytes ? { skip: `Larger than ${Math.round(maxFileBytes / 1048576)} MB` } : {}) }));
  return { folders, images, ignored: files.length - images.length, ...(l.note ? { note: l.note } : {}), ...(l.title ? { title: l.title } : {}) } as unknown as Json;
}

// ---------------------------------------------------------------- downloading a photo
type Fetched = { ok: true; bytes: Uint8Array } | { ok: false; reason: string; retry: boolean; skip?: boolean };

export async function downloadPhoto(id: string, key: string | null, maxBytes: number, f: typeof fetch = fetch): Promise<Fetched> {
  try {
    const r = await f(key ? apiDownloadUrl(id, key) : publicDownloadUrl(id), { headers: { 'user-agent': UA }, signal: AbortSignal.timeout(40_000), redirect: 'follow' });
    if (r.status === 429) return { ok: false, reason: 'Drive asked us to slow down', retry: true };
    if (r.status === 404) return { ok: false, reason: 'The file is gone or not shared', retry: false };
    if (r.status === 403 || r.status === 401) {
      const t = new Uint8Array(await r.arrayBuffer().catch(() => new ArrayBuffer(0)));
      const why = htmlReason(t);
      return { ok: false, reason: why, retry: /too many downloads/.test(why) };
    }
    if (!r.ok) return { ok: false, reason: `Drive answered ${r.status}`, retry: r.status >= 500 };
    const len = Number(r.headers.get('content-length') ?? '0');
    if (len > maxBytes) return { ok: false, reason: `Larger than ${Math.round(maxBytes / 1048576)} MB`, retry: false, skip: true };
    const bytes = new Uint8Array(await r.arrayBuffer());
    if (bytes.length > maxBytes) return { ok: false, reason: `Larger than ${Math.round(maxBytes / 1048576)} MB`, retry: false, skip: true };
    return { ok: true, bytes };
  } catch (e) {
    return { ok: false, reason: e instanceof Error && (e.name === 'TimeoutError' || e.name === 'AbortError') ? 'Drive did not answer in time' : 'Drive could not be reached', retry: true };
  }
}

const EXT: Record<string, string> = { jpeg: 'jpg', png: 'png' };

/** One photo: prepared by the database, downloaded, made a JPEG when it is HEIC or WebP, sorted to its shot, stored, recorded. */
async function importOne(file: FileJob, lim: Limits, apiKey: string | null): Promise<'done' | 'skipped' | 'failed' | 'later' | 'slow'> {
  const prep = (await rpc('server_drive_import_prepare', { p_file: file.id }, SR)) as unknown as { skip: boolean; vehicle_id?: string; intake?: string; created_by?: string; taken?: string[] };
  if (prep.skip || !prep.vehicle_id || !prep.intake || !prep.created_by) return 'skipped';
  const got = await downloadPhoto(file.drive_id, apiKey, lim.max_file_bytes);
  if (!got.ok) {
    if (got.skip) await rpc('server_drive_import_skip', { p_file: file.id, p_reason: got.reason }, SR);
    else await rpc('server_drive_import_file_fail', { p_file: file.id, p_reason: got.reason, p_retry: got.retry }, SR);
    return got.retry ? 'slow' : got.skip ? 'skipped' : 'failed';
  }
  let bytes = got.bytes;
  let kind = sniffBytes(bytes);
  if (kind === 'html') { const why = htmlReason(bytes); await rpc('server_drive_import_file_fail', { p_file: file.id, p_reason: why, p_retry: /too many downloads/.test(why) }, SR); return /too many downloads/.test(why) ? 'slow' : 'failed'; }
  if (kind === 'other') { await rpc('server_drive_import_file_fail', { p_file: file.id, p_reason: 'The file is not a photo (JPG, PNG, HEIC or WebP)', p_retry: false }, SR); return 'failed'; }
  const s = await storage();
  if (kind === 'heic' || kind === 'webp') {
    // the listing takes JPEG and PNG: a phone's HEIC and a WebP are made a JPEG by Cloudflare Images, from a private working copy
    const work = `vehicles/${prep.vehicle_id}/work/drive/${crypto.randomUUID().slice(0, 12)}.${kind}`;
    const issued = new Map<string, { bucket: Bucket; path: string }>();
    try {
      await s.put('vehicle-originals', work, bytes, kind === 'heic' ? 'image/heic' : 'image/webp');
      const url = await s.signedDownloadUrl('vehicle-originals', work, 300);
      issued.set(url, { bucket: 'vehicle-originals', path: work });
      const proc = await photoProcessor(async (u) => { const x = issued.get(u); return x ? s.get(x.bucket, x.path) : null; });
      const out = proc.toJpeg ? await proc.toJpeg({ sourceUrl: url, width: 3000 }) : null;
      if (!out || !out.ok) {
        await rpc('server_drive_import_file_fail', { p_file: file.id, p_reason: `A ${kind === 'heic' ? 'HEIC' : 'WebP'} photo could not be made a JPEG${out && !out.ok ? ` (${out.message.slice(0, 120)})` : ''}`, p_retry: !!out && !out.ok && out.retryable }, SR);
        return out && !out.ok && out.retryable ? 'later' : 'failed';
      }
      bytes = out.bytes;
      kind = sniffBytes(bytes);
    } finally { await s.remove('vehicle-originals', work).catch(() => undefined); }
    if (kind !== 'jpeg' && kind !== 'png') { await rpc('server_drive_import_file_fail', { p_file: file.id, p_reason: 'The photo could not be made a JPEG', p_retry: false }, SR); return 'failed'; }
  }
  if (bytes.length > lim.max_file_bytes) { await rpc('server_drive_import_skip', { p_file: file.id, p_reason: `Larger than ${Math.round(lim.max_file_bytes / 1048576)} MB` }, SR); return 'skipped'; }
  const type = kind === 'png' ? 'image/png' : 'image/jpeg';
  const size = imageSize(bytes);
  const sorted = await sortShot(prep.created_by, bytes, type, new Set(prep.taken ?? []));
  const path = `vehicles/${prep.vehicle_id}/original/${prep.intake}/${sorted.shot}-${crypto.randomUUID().slice(0, 8)}.${EXT[kind] ?? 'jpg'}`;
  await s.put('vehicle-originals', path, bytes, type);
  let rec: { photo_id?: string; skipped?: boolean; failed?: boolean };
  try {
    rec = (await rpc('server_drive_import_record', { p_file: file.id, p: { shot_type: sorted.shot, original_path: path, width: size?.width ?? null, height: size?.height ?? null,
      byte_size: bytes.length, mime_type: type, sha256: await sha256Hex(bytes) } as unknown as Json }, SR)) as unknown as typeof rec;
  } catch (e) {
    await s.remove('vehicle-originals', path).catch(() => undefined);
    throw e;
  }
  if (!rec.photo_id) { await s.remove('vehicle-originals', path).catch(() => undefined); return rec.skipped ? 'skipped' : 'failed'; }
  await recordSort(prep.created_by, sorted.sort, rec.photo_id);
  return 'done';
}

// ---------------------------------------------------------------- matching the folders to cars
async function matchRun(importId: string, folders: MatchJob[]): Promise<void> {
  const cars = ((await rpc('server_drive_import_cars', {}, SR)) as unknown as Array<Car & { id: string }>) ?? [];
  const taken = new Set<string>();
  const rows = folders.filter((f) => f.images > 0).map((f) => {
    const m = matchFolder(f.name, f.ancestors, cars, { taken });
    if (m.vehicle_id) taken.add(m.vehicle_id);
    return { folder: f.id, vehicle_id: m.vehicle_id, score: m.score, note: m.note, candidates: m.candidates, ambiguous: m.ambiguous };
  });
  await rpc('server_drive_import_matches', { p_import: importId, p: rows as unknown as Json }, SR);
}

// ---------------------------------------------------------------- one step
export interface StepResult { phase: string | null; worked: number; more: boolean }

export async function runDriveImportStep(o: { deadlineMs?: number } = {}): Promise<StepResult> {
  const start = Date.now();
  const deadline = o.deadlineMs ?? 20_000;
  const worker = `web-${crypto.randomUUID().slice(0, 8)}`;
  const claim = (await rpc('server_drive_import_claim', { p_worker: worker, p_files: 3, p_folders: 4 }, SR)) as unknown as Claim;
  if (!claim) return { phase: null, worked: 0, more: false };
  const id = claim.import.id;
  let delay = 0;
  let worked = 0;
  try {
    if (claim.phase === 'scan') {
      const key = ((await rpc('server_drive_import_key', {}, SR).catch(() => null)) as unknown as string | null) || null;
      for (const folder of claim.folders) {
        if (Date.now() - start > deadline && worked > 0) break;
        const l = await listFolder(folder.drive_id, key);
        if (l.rateLimited) { delay = 120; break; }
        await rpc('server_drive_import_folder_result', { p_folder: folder.id, p: l.error ? { error: l.error } : toFolderResult(l, claim.limits.max_file_bytes) }, SR);
        worked++;
        await sleep(claim.limits.pause_ms);
      }
    } else if (claim.phase === 'match') {
      await matchRun(id, claim.folders);
      worked = 1;
    } else if (claim.phase === 'import') {
      const key = ((await rpc('server_drive_import_key', {}, SR).catch(() => null)) as unknown as string | null) || null;
      for (const file of claim.files) {
        if (Date.now() - start > deadline && worked > 0) break;
        let r: Awaited<ReturnType<typeof importOne>>;
        try { r = await importOne(file, claim.limits, key); } catch (e) {
          console.error('drive import photo', file.id, e);
          await rpc('server_drive_import_file_fail', { p_file: file.id, p_reason: 'The photo could not be saved', p_retry: true }, SR).catch(() => undefined);
          r = 'later';
        }
        worked++;
        if (r === 'slow') { delay = 120; break; }
        await sleep(claim.limits.pause_ms);
      }
    }
  } catch (e) {
    console.error('drive import step', claim.phase, e);
    delay = 60;
  } finally {
    if (claim.phase !== 'done' && claim.phase !== 'wait') await rpc('server_drive_import_release', { p_import: id, p_delay_seconds: delay }, SR).catch(() => undefined);
  }
  return { phase: claim.phase, worked, more: claim.phase !== 'done' && claim.phase !== 'wait' && delay === 0 };
}
