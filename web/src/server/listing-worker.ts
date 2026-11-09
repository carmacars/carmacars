import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { storage, type Bucket } from '@/integrations/storage';
import { decodeVin } from '@/integrations/vin';
import { textGenerator } from '@/integrations/llm';
import { photoProcessor } from '@/integrations/photos';
import { linkSecret } from '@/server/links';
import { runListingWorker, type Claim, type RunSummary } from '@/features/listing/worker';
import { visionModel } from '@/integrations/vision';
import { MARK_PROMPT, MARK_SYSTEM, parseMarks, type MarkBox } from '@/features/listing/photo-sort';
import { letteringName } from '@/features/car/studio';
import { showroomPrompt, type ShowroomProvider } from '@/features/listing/showroom';
import { geminiEditImage } from '@/integrations/photos/gemini';

// The listing worker as the site runs it: the Cloudflare cron trigger (custom-worker.ts, every five
// minutes) and a submitted capture (right away, after the response) call runListingWorkerNow. The queue
// and its rules are the database's (migrations 0022 and 0032); this wires the real providers.
const SR = { role: 'service_role' as const };

/** The bearer token the cron trigger sends to /api/jobs/listing: HMAC of a fixed label with LINK_SIGNING_KEY. */
export async function workerToken(): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(linkSecret()), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode('carmacars-listing-worker-v1')));
  return Array.from(mac, (b) => b.toString(16).padStart(2, '0')).join('');
}

const b64 = (b: Uint8Array) => { let s = ''; for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000)); return btoa(s); };

/** 0567: where the marks are on an edited inside or detail photo (the vision model, purpose photo_sort, within the live
 *  AI share); null when the model may not be asked or did not answer usefully. */
async function findMarks(img: { bytes: Uint8Array; contentType: string; width: number; height: number; photoId: string }): Promise<MarkBox[] | null> {
  const gate = (await rpc('server_photo_mark_gate', {}, SR).catch(() => null)) as unknown as { allowed?: boolean; model?: string; fallback_model?: string | null } | null;
  if (!gate?.allowed || !gate.model || img.bytes.length > 3_400_000) return null;
  const t0 = Date.now();
  const r = await (await visionModel()).read({ purpose: 'photo_sort', imageDataUrl: `data:${img.contentType};base64,${b64(img.bytes)}`, system: MARK_SYSTEM, prompt: MARK_PROMPT,
    schema: { type: 'object' }, maxOutputTokens: 200 }, [gate.model, gate.fallback_model ?? ''].filter(Boolean)).catch(() => null);
  const marks = r?.ok ? parseMarks(r.data, img) : null;
  await rpc('server_photo_mark_record', { p: { model: r?.model ?? null, ok: !!marks, neurons: r?.usage?.neurons ?? 0, duration_ms: Date.now() - t0, photo_id: img.photoId, marks: marks?.length ?? null } }, SR).catch(() => undefined);
  return marks;
}

/** r35 (0990): the image model of the showroom photos, behind the database's gate (Program settings: on, the model, the
 *  daily limit; a quota answer stops it for the hour): never past the free use, and every call is recorded. */
export function showroomAi(apiKey: string, f: typeof fetch = fetch): ShowroomProvider {
  return {
    name: 'ai',
    async make(i, local) {
      const gate = (await rpc('server_showroom_ai_gate', { p: { photo_id: i.photoId } }, SR).catch(() => null)) as unknown as
        { allowed?: boolean; reason?: 'off' | 'limit' | 'quota'; model?: string; call_id?: string } | null;
      if (!gate?.allowed || !gate.call_id) return { ok: false, reason: gate?.reason ?? 'error', message: 'The image model may not be asked now' };
      const t0 = Date.now();
      const r = await geminiEditImage({ apiKey, model: gate.model, fetch: f }, { bytes: local, contentType: 'image/jpeg' },
        showroomPrompt({ cover: i.cover, name: i.model ? letteringName(i.model) : null }));
      await rpc('server_showroom_ai_record', { p: { call_id: gate.call_id, ok: r.ok, error: r.ok ? null : `${r.reason}: ${r.message}`, duration_ms: Date.now() - t0 } }, SR).catch(() => undefined);
      return r;
    }
  };
}

const absolute = (u: string) => (/^https?:\/\//.test(u) ? u : `${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}${u.startsWith('/') ? '' : '/'}${u}`);

export async function runListingWorkerNow(o: { maxJobs?: number; deadlineMs?: number } = {}): Promise<RunSummary> {
  const s = await storage();
  // the links handed to the photo provider, so the fake can read them back from storage
  const issued = new Map<string, { bucket: Bucket; path: string }>();
  const read = async (url: string) => { const f = issued.get(url); return f ? s.get(f.bucket, f.path) : null; };
  const worker = `web-${crypto.randomUUID().slice(0, 8)}`;
  return runListingWorker({
    claim: async (n) => {
      const c = (await rpc('server_listing_claim', { p_worker: worker, p_limit: n }, SR)) as unknown as Claim;
      // the usage guard (0080): photos keep their original while the month's included transformations are used
      if (c.jobs.some((j) => j.kind === 'process_photo' || j.kind === 'resize')) {
        try { c.budget = { ...c.budget, images_paused: ((await rpc('server_usage_gate', { p_service: 'images' }, SR)) as unknown as { ok: boolean }).ok === false }; }
        catch { /* the guard cannot be read: the photo budget of 0032 still applies */ }
      }
      return c;
    },
    report: (id, r) => rpc('server_listing_result', { p_job: id, p: r as unknown as Json }, SR),
    decodeVin: async (vin) => {
      const a = await decodeVin(vin);
      return { provider: a.provider, result: { ...a.result } };
    },
    text: await textGenerator(),
    plainCopy: true,
    photos: await photoProcessor(read),
    findMarks,
    showroomAi: env().GEMINI_API_KEY ? showroomAi(env().GEMINI_API_KEY!) : null,
    showroomNoKey: !env().GEMINI_API_KEY,
    files: {
      privateUrl: async (path) => { const u = absolute(await s.signedDownloadUrl('vehicle-originals', path, 900)); issued.set(u, { bucket: 'vehicle-originals', path }); return u; },
      publicUrl: (path) => { const u = absolute(s.publicUrl(path)); issued.set(u, { bucket: 'vehicle-public', path }); return u; },
      getPrivate: (path) => s.get('vehicle-originals', path),
      putPrivate: (path, bytes, type) => s.put('vehicle-originals', path, bytes, type),
      putPublic: (path, bytes, type) => s.put('vehicle-public', path, bytes, type),
      hasPublic: async (path) => (await s.get('vehicle-public', path)) !== null
    }
  }, o);
}
