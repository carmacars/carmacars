import 'server-only';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import type { Bucket, StorageAdapter } from './types';
import { signStorageUrl } from './sign';

// Local stand-in for R2. The public bucket is public/_local/vehicle-public (served by the dev server);
// private buckets live under .local-storage/<bucket>/ outside public/, and their links go through
// /api/storage, which checks an HMAC and an expiry exactly like a presigned R2 link would.
export function localDir(): string {
  return process.env.LOCAL_STORAGE_DIR ?? path.join(/* turbopackIgnore: true */ process.cwd(), '.local-storage');
}
export function localPath(bucket: Bucket, key: string): string {
  const root = path.join(/* turbopackIgnore: true */ localDir(), bucket);
  const p = path.resolve(/* turbopackIgnore: true */ root, key);
  if (!p.startsWith(root + path.sep)) throw new Error('Invalid storage key');
  return p;
}

export function localStorageAdapter(publicBase: string, secret: string): StorageAdapter {
  const base = publicBase.replace(/\/$/, '');
  return {
    name: 'local',
    publicUrl: (p) => `${base}/${p.replace(/^\//, '')}`,
    signedDownloadUrl: (bucket, key, ttl = 300, filename) => signStorageUrl(secret, 'GET', bucket, key, ttl, { filename }),
    async signedUploadUrl(bucket, key, contentType, ttl = 300) {
      return { url: await signStorageUrl(secret, 'PUT', bucket, key, ttl, { contentType }), headers: { 'content-type': contentType } };
    },
    async put(bucket, key, body) {
      const p = localPath(bucket, key);
      await mkdir(path.dirname(p), { recursive: true });
      await writeFile(p, body);
    },
    async get(bucket, key) {
      try { return new Uint8Array(await readFile(localPath(bucket, key))); } catch { return null; }
    },
    async remove(bucket, key) {
      await rm(localPath(bucket, key), { force: true });
    }
  };
}
