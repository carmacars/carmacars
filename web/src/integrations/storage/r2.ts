import 'server-only';
import { AwsClient } from 'aws4fetch';
import type { StorageAdapter } from './types';

// Cloudflare R2 through its S3 API. aws4fetch signs with SubtleCrypto, so it runs in the Worker.
// Private buckets need a CORS rule allowing PUT from the site's origin for browser uploads.
export function r2Storage(o: { accountId: string; accessKeyId: string; secretAccessKey: string; bucketPrefix: string; publicBase: string }): StorageAdapter {
  const aws = new AwsClient({ accessKeyId: o.accessKeyId, secretAccessKey: o.secretAccessKey, service: 's3', region: 'auto' });
  const endpoint = `https://${o.accountId}.r2.cloudflarestorage.com`;
  const objectUrl = (bucket: string, key: string) => new URL(`${endpoint}/${o.bucketPrefix}${bucket}/${key.split('/').map(encodeURIComponent).join('/')}`);
  const sign = async (method: string, bucket: string, key: string, ttl: number, headers: Record<string, string> = {}, filename?: string) => {
    const u = objectUrl(bucket, key);
    u.searchParams.set('X-Amz-Expires', String(ttl));
    if (filename) u.searchParams.set('response-content-disposition', `attachment; filename="${filename.replace(/[^\w.-]/g, '_')}"`);
    const req = await aws.sign(new Request(u, { method, headers }), { aws: { signQuery: true } });
    return req.url;
  };
  return {
    name: 'r2',
    publicUrl: (p) => `${o.publicBase.replace(/\/$/, '')}/${p.replace(/^\//, '')}`,
    signedDownloadUrl: (bucket, key, ttl = 300, filename) => sign('GET', bucket, key, ttl, {}, filename),
    async signedUploadUrl(bucket, key, contentType, ttl = 300) {
      return { url: await sign('PUT', bucket, key, ttl, { 'content-type': contentType }), headers: { 'content-type': contentType } };
    },
    async put(bucket, key, body, contentType) {
      const r = await aws.fetch(objectUrl(bucket, key), { method: 'PUT', body: body as unknown as BodyInit, headers: { 'content-type': contentType } });
      if (!r.ok) throw new Error(`Storage write failed (${r.status})`);
    },
    async get(bucket, key) {
      const r = await aws.fetch(objectUrl(bucket, key), { method: 'GET' });
      if (r.status === 404) return null;
      if (!r.ok) throw new Error(`Storage read failed (${r.status})`);
      return new Uint8Array(await r.arrayBuffer());
    },
    async remove(bucket, key) {
      await aws.fetch(objectUrl(bucket, key), { method: 'DELETE' });
    }
  };
}
