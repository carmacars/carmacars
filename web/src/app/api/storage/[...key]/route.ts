import { env } from '@/lib/env';
import { linkSecret } from '@/server/links';
import { checkStorageUrl } from '@/integrations/storage/sign';
import { PRIVATE_BUCKETS, type Bucket } from '@/integrations/storage/types';

// What a presigned R2 link does, for the local adapter and the R2-binding adapter (STORAGE_PROVIDER=local
// or r2-binding). GET serves a private object, PUT stores an upload, each only with a valid unexpired
// signature for that method, bucket, key (and content type for PUT). With STORAGE_PROVIDER=r2 (S3 API
// presigned links) this route does not exist (404).
export const dynamic = 'force-dynamic';
const MAX = 15 * 1024 * 1024;

async function target(params: Promise<{ key: string[] }>) {
  if (env().STORAGE_PROVIDER !== 'local' && env().STORAGE_PROVIDER !== 'r2-binding') return null;
  const [bucket, ...rest] = (await params).key.map(decodeURIComponent);
  if (!bucket || !PRIVATE_BUCKETS.includes(bucket as Bucket) || !rest.length) return null;
  return { bucket: bucket as Bucket, key: rest.join('/') };
}

export async function GET(req: Request, { params }: { params: Promise<{ key: string[] }> }) {
  const t = await target(params);
  if (!t) return new Response('Not found', { status: 404 });
  const q = new URL(req.url).searchParams;
  if (!(await checkStorageUrl(linkSecret(), 'GET', t.bucket, t.key, q))) return new Response('This link has expired.', { status: 403 });
  const { storage } = await import('@/integrations/storage');
  const body = await (await storage()).get(t.bucket, t.key);
  if (!body) return new Response('Not found', { status: 404 });
  const type = t.key.endsWith('.pdf') ? 'application/pdf' : t.key.endsWith('.png') ? 'image/png' : t.key.endsWith('.jpg') ? 'image/jpeg' : 'application/octet-stream';
  const fn = q.get('fn');
  return new Response(body as unknown as BodyInit, { headers: {
    'content-type': type, 'cache-control': 'private, no-store', 'x-content-type-options': 'nosniff', 'content-security-policy': 'sandbox',
    ...(fn ? { 'content-disposition': `attachment; filename="${fn.replace(/[^\w.-]/g, '_')}"` } : {})
  } });
}

export async function PUT(req: Request, { params }: { params: Promise<{ key: string[] }> }) {
  const t = await target(params);
  if (!t) return new Response('Not found', { status: 404 });
  const q = new URL(req.url).searchParams;
  const ct = req.headers.get('content-type') ?? '';
  if (!(await checkStorageUrl(linkSecret(), 'PUT', t.bucket, t.key, q, ct))) return new Response('This upload link has expired.', { status: 403 });
  const buf = new Uint8Array(await req.arrayBuffer());
  if (buf.byteLength > MAX) return new Response('Too large', { status: 413 });
  const { storage } = await import('@/integrations/storage');
  await (await storage()).put(t.bucket, t.key, buf, ct);
  return new Response(null, { status: 200 });
}
