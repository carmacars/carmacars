import 'server-only';
import { AwsClient } from 'aws4fetch';
import type { StorageAdapter } from './types';

// Cloudflare R2 through its S3 API. aws4fetch signs with SubtleCrypto, so it runs in the Worker.
export function r2Storage(o: { accountId: string; accessKeyId: string; secretAccessKey: string; bucketPrefix: string; publicBase: string }): StorageAdapter {
  const aws = new AwsClient({ accessKeyId: o.accessKeyId, secretAccessKey: o.secretAccessKey, service: 's3', region: 'auto' });
  const endpoint = `https://${o.accountId}.r2.cloudflarestorage.com`;
  const sign = async (method: string, bucket: string, key: string, ttl: number, headers: Record<string, string> = {}) => {
    const u = new URL(`${endpoint}/${o.bucketPrefix}${bucket}/${key.split('/').map(encodeURIComponent).join('/')}`);
    u.searchParams.set('X-Amz-Expires', String(ttl));
    const req = await aws.sign(new Request(u, { method, headers }), { aws: { signQuery: true } });
    return req.url;
  };
  return {
    name: 'r2',
    publicUrl: (p) => `${o.publicBase.replace(/\/$/, '')}/${p.replace(/^\//, '')}`,
    signedDownloadUrl: (bucket, key, ttl = 300) => sign('GET', bucket, key, ttl),
    async signedUploadUrl(bucket, key, contentType, ttl = 300) {
      return { url: await sign('PUT', bucket, key, ttl, { 'content-type': contentType }), headers: { 'content-type': contentType } };
    }
  };
}
