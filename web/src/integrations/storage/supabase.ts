import 'server-only';
import type { StorageAdapter } from './types';

// Supabase Storage (STORAGE_PROVIDER=supabase), for a Cloudflare account without R2. Same buckets as
// docs/architecture.md section 6 (created by scripts/deploy/supabase.sh storage): vehicle-public is a
// public bucket (NEXT_PUBLIC_VEHICLE_PHOTOS_URL = <project>/storage/v1/object/public/vehicle-public);
// the others are private and reached only through short-lived signed links, issued on the server with
// the service role after row-level security has passed. Browser uploads PUT straight to a signed
// upload link bound to the key.
export function supabaseStorage(o: { url: string; serviceKey: string; publicBase: string }): StorageAdapter {
  const api = `${o.url.replace(/\/$/, '')}/storage/v1`;
  const auth = { Authorization: `Bearer ${o.serviceKey}`, apikey: o.serviceKey };
  const path = (key: string) => key.split('/').map(encodeURIComponent).join('/');
  const call = async (method: string, url: string, init: { body?: BodyInit; headers?: Record<string, string> } = {}) =>
    fetch(url, { method, body: init.body, headers: { ...auth, ...(init.headers ?? {}) } });
  return {
    name: 'r2',
    publicUrl: (p) => `${o.publicBase.replace(/\/$/, '')}/${p.replace(/^\//, '')}`,
    async signedDownloadUrl(bucket, key, ttl = 300, filename) {
      const r = await call('POST', `${api}/object/sign/${bucket}/${path(key)}`, { body: JSON.stringify({ expiresIn: ttl }), headers: { 'content-type': 'application/json' } });
      if (!r.ok) throw new Error(`Storage link failed (${r.status})`);
      const { signedURL } = (await r.json()) as { signedURL: string };
      const u = new URL(`${api}${signedURL.startsWith('/') ? '' : '/'}${signedURL}`);
      if (filename) u.searchParams.set('download', filename.replace(/[^\w.-]/g, '_'));
      return u.toString();
    },
    async signedUploadUrl(bucket, key, contentType) {
      // Supabase upload links last two hours; the key and the bucket are fixed by the signature.
      const r = await call('POST', `${api}/object/upload/sign/${bucket}/${path(key)}`, { headers: { 'x-upsert': 'true' } });
      if (!r.ok) throw new Error(`Storage upload link failed (${r.status})`);
      const { url } = (await r.json()) as { url: string };
      return { url: `${api}${url.startsWith('/') ? '' : '/'}${url}`, headers: { 'content-type': contentType, 'x-upsert': 'true' } };
    },
    async put(bucket, key, body, contentType) {
      const r = await call('POST', `${api}/object/${bucket}/${path(key)}`, { body: body as unknown as BodyInit, headers: { 'content-type': contentType, 'x-upsert': 'true' } });
      if (!r.ok) throw new Error(`Storage write failed (${r.status})`);
    },
    async get(bucket, key) {
      const r = await call('GET', `${api}/object/authenticated/${bucket}/${path(key)}`);
      if (r.status === 404 || r.status === 400) return null;
      if (!r.ok) throw new Error(`Storage read failed (${r.status})`);
      return new Uint8Array(await r.arrayBuffer());
    },
    async remove(bucket, key) {
      await call('DELETE', `${api}/object/${bucket}/${path(key)}`);
    }
  };
}
