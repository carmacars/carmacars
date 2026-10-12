import type { StorageAdapter } from './types';

// Local stand-in: files live under public/_local/<bucket>/ and are served by the dev server.
// Private buckets are only ever used by later portal work; the links carry an expiry for parity.
export function localStorageAdapter(publicBase: string): StorageAdapter {
  const base = publicBase.replace(/\/$/, '');
  return {
    name: 'local',
    publicUrl: (p) => `${base}/${p.replace(/^\//, '')}`,
    async signedDownloadUrl(bucket, key, ttl = 300) {
      return `/_local/${bucket}/${key}?expires=${Math.floor(Date.now() / 1000) + ttl}`;
    },
    async signedUploadUrl(bucket, key, contentType, ttl = 300) {
      return { url: `/_local/${bucket}/${key}?expires=${Math.floor(Date.now() / 1000) + ttl}`, headers: { 'content-type': contentType } };
    }
  };
}
