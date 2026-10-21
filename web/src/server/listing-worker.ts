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

const absolute = (u: string) => (/^https?:\/\//.test(u) ? u : `${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}${u.startsWith('/') ? '' : '/'}${u}`);

export async function runListingWorkerNow(o: { maxJobs?: number; deadlineMs?: number } = {}): Promise<RunSummary> {
  const s = await storage();
  // the links handed to the photo provider, so the fake can read them back from storage
  const issued = new Map<string, { bucket: Bucket; path: string }>();
  const read = async (url: string) => { const f = issued.get(url); return f ? s.get(f.bucket, f.path) : null; };
  const worker = `web-${crypto.randomUUID().slice(0, 8)}`;
  return runListingWorker({
    claim: async (n) => (await rpc('server_listing_claim', { p_worker: worker, p_limit: n }, SR)) as unknown as Claim,
    report: (id, r) => rpc('server_listing_result', { p_job: id, p: r as unknown as Json }, SR),
    decodeVin: async (vin) => {
      const a = await decodeVin(vin);
      return { provider: a.provider, result: { ...a.result } };
    },
    text: await textGenerator(),
    plainCopy: true,
    photos: await photoProcessor(read),
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
