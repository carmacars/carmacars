import { storageProviderFor } from '@/lib/platform/runtime';
import { env } from '@/lib/env';
import { linkSecret } from '@/server/links';
import { checkStorageUrl } from '@/integrations/storage/sign';
import { PRIVATE_BUCKETS, type Bucket } from '@/integrations/storage/types';
import { MAX_VIDEO_BYTES, recordingMime } from '@/features/careers/ai-interview';

// What a presigned R2 link does, for the local adapter and the R2-binding adapter (STORAGE_PROVIDER=local
// or r2-binding). GET serves a private object, PUT stores an upload, each only with a valid unexpired
// signature for that method, bucket, key (and content type for PUT). With STORAGE_PROVIDER=r2 (S3 API
// presigned links) this route does not exist (404).
export const dynamic = 'force-dynamic';
const MAX = 15 * 1024 * 1024;
// 0585: an interview answer's video (hiring/interviews/<id>/<n>-<id>-v.webm or .mp4) may be larger
const isVideo = (key: string) => /^hiring\/interviews\/[0-9a-f-]+\/[0-9]+-[a-z0-9]+-v\.(webm|mp4)$/.test(key);
interface R2Ranged { get(key: string, o?: { range?: { offset: number; length?: number } | { suffix: number } }): Promise<{ body: ReadableStream; size: number; range?: { offset: number; length: number } } | null>; head(key: string): Promise<{ size: number } | null> }

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
  // 0585: an interview video on R2 is read by the byte range asked (never the whole file into memory)
  if (isVideo(t.key) && storageProviderFor(env().STORAGE_PROVIDER) === 'r2-binding') return videoFromR2(req, t.bucket, t.key);
  const { storage } = await import('@/integrations/storage');
  const body = await (await storage()).get(t.bucket, t.key);
  if (!body) return new Response('Not found', { status: 404 });
  const type = t.key.endsWith('.pdf') ? 'application/pdf' : t.key.endsWith('.png') ? 'image/png' : t.key.endsWith('.jpg') ? 'image/jpeg'
    : recordingMime(t.key) ?? 'application/octet-stream';
  const fn = q.get('fn');
  // 0380: the interview recordings play in the page: Safari asks for byte ranges before it plays audio (0585: and video)
  const media = type.startsWith('audio/') || type.startsWith('video/');
  const range = media ? /^bytes=(\d*)-(\d*)$/.exec(req.headers.get('range') ?? '') : null;
  if (range && (range[1] || range[2])) {
    const size = body.byteLength;
    const start = range[1] ? Number(range[1]) : Math.max(size - Number(range[2]), 0);
    const end = range[1] && range[2] ? Math.min(Number(range[2]), size - 1) : size - 1;
    if (start >= size || start > end) return new Response(null, { status: 416, headers: { 'content-range': `bytes */${size}` } });
    return new Response(body.slice(start, end + 1) as unknown as BodyInit, { status: 206, headers: {
      'content-type': type, 'content-range': `bytes ${start}-${end}/${size}`, 'accept-ranges': 'bytes', 'cache-control': 'private, no-store', 'x-content-type-options': 'nosniff' } });
  }
  return new Response(body as unknown as BodyInit, { headers: {
    ...(media ? { 'accept-ranges': 'bytes' } : {}),
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
  const limit = isVideo(t.key) ? MAX_VIDEO_BYTES : MAX;
  if (Number(req.headers.get('content-length') ?? 0) > limit) return new Response('Too large', { status: 413 });
  // 0585: a video goes to R2 as it arrives (its length is known from the request), never whole in memory
  if (isVideo(t.key) && storageProviderFor(env().STORAGE_PROVIDER) === 'r2-binding' && req.body && Number(req.headers.get('content-length') ?? 0) > 0) {
    const { r2Binding } = await import('@/integrations/storage/r2-binding');
    await (await r2Binding(t.bucket)).put(t.key, req.body, { httpMetadata: { contentType: ct } });
    return new Response(null, { status: 200 });
  }
  const buf = new Uint8Array(await req.arrayBuffer());
  if (buf.byteLength > limit) return new Response('Too large', { status: 413 });
  const { storage } = await import('@/integrations/storage');
  await (await storage()).put(t.bucket, t.key, buf, ct);
  return new Response(null, { status: 200 });
}

async function videoFromR2(req: Request, bucket: Bucket, key: string): Promise<Response> {
  const { r2Binding } = await import('@/integrations/storage/r2-binding');
  const b = (await r2Binding(bucket)) as unknown as R2Ranged;
  const type = recordingMime(key) ?? 'application/octet-stream';
  const base = { 'content-type': type, 'accept-ranges': 'bytes', 'cache-control': 'private, no-store', 'x-content-type-options': 'nosniff' };
  const m = /^bytes=(\d*)-(\d*)$/.exec(req.headers.get('range') ?? '');
  if (!m || (!m[1] && !m[2])) {
    const o = await b.get(key);
    return o ? new Response(o.body, { headers: { ...base, 'content-length': String(o.size) } }) : new Response('Not found', { status: 404 });
  }
  const head = await b.head(key);
  if (!head) return new Response('Not found', { status: 404 });
  const size = head.size;
  const start = m[1] ? Number(m[1]) : Math.max(size - Number(m[2]), 0);
  const end = m[1] && m[2] ? Math.min(Number(m[2]), size - 1) : size - 1;
  if (start >= size || start > end) return new Response(null, { status: 416, headers: { 'content-range': `bytes */${size}` } });
  const o = await b.get(key, { range: { offset: start, length: end - start + 1 } });
  if (!o) return new Response('Not found', { status: 404 });
  return new Response(o.body, { status: 206, headers: { ...base, 'content-range': `bytes ${start}-${end}/${size}`, 'content-length': String(end - start + 1) } });
}
