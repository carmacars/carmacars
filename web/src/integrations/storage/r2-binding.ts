import 'server-only';
import { getCloudflareContext } from '@opennextjs/cloudflare';
import type { Bucket, StorageAdapter } from './types';
import { signStorageUrl } from './sign';

// Cloudflare R2 through the Worker's own bucket bindings (wrangler.jsonc r2_buckets: R2_VEHICLE_PUBLIC,
// R2_DOCUMENTS, ...). No S3 credentials: private files go through /api/storage with the same HMAC-signed,
// expiring links as the local adapter, and the public bucket is served by the Worker under /media
// (custom-worker.ts), so NEXT_PUBLIC_VEHICLE_PHOTOS_URL is `/media` (or the site's https://.../media).
interface R2ObjectBody { arrayBuffer(): Promise<ArrayBuffer> }
export interface R2BucketBinding {
  put(key: string, body: Uint8Array | ArrayBuffer | ReadableStream, o?: { httpMetadata?: { contentType?: string } }): Promise<unknown>;
  get(key: string): Promise<R2ObjectBody | null>;
  delete(key: string): Promise<void>;
}

export const bindingName = (bucket: Bucket) => `R2_${bucket.toUpperCase().replace(/-/g, '_')}`;

export async function r2Binding(bucket: Bucket): Promise<R2BucketBinding> {
  const { env } = await getCloudflareContext({ async: true });
  const b = (env as unknown as Record<string, R2BucketBinding | undefined>)[bindingName(bucket)];
  if (!b) throw new Error(`The Worker has no R2 binding ${bindingName(bucket)} (wrangler.jsonc)`);
  return b;
}

export function r2BindingStorage(publicBase: string, secret: string): StorageAdapter {
  const base = publicBase.replace(/\/$/, '');
  return {
    name: 'r2',
    publicUrl: (p) => `${base}/${p.replace(/^\//, '')}`,
    signedDownloadUrl: (bucket, key, ttl = 300, filename) => signStorageUrl(secret, 'GET', bucket, key, ttl, { filename }),
    async signedUploadUrl(bucket, key, contentType, ttl = 300) {
      return { url: await signStorageUrl(secret, 'PUT', bucket, key, ttl, { contentType }), headers: { 'content-type': contentType } };
    },
    async put(bucket, key, body, contentType) {
      await (await r2Binding(bucket)).put(key, body, { httpMetadata: { contentType } });
    },
    async get(bucket, key) {
      const o = await (await r2Binding(bucket)).get(key);
      return o ? new Uint8Array(await o.arrayBuffer()) : null;
    },
    async remove(bucket, key) {
      await (await r2Binding(bucket)).delete(key);
    }
  };
}
