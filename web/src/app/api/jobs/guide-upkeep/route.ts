import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { jobAuthorized } from '@/server/job-auth';
import { isGuidePortal } from '@/server/guides';
import { sha256Hex } from '@/server/links';

// The guide upkeep run (web/scripts/guide-upkeep.mjs, migration 0049), with the jobs' bearer token.
//   GET   the screenshots replaced so far, so the run compares with the image the guide shows now
//   POST  one retaken screenshot (JPEG) that changed: stored in the public bucket, put in place of the old image in every
//         draft and published copy of the guides, and the sections that show it flagged "needs review"
export const dynamic = 'force-dynamic';
const MAX = 6_000_000;
const SR = { role: 'service_role' as const };

export async function GET(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  return NextResponse.json({ ok: true, images: await rpc('server_guide_images_replaced', {}, SR) });
}

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  const q = new URL(req.url).searchParams;
  const portal = q.get('portal') ?? '';
  const oldUrl = q.get('old_url') ?? '';
  if (!isGuidePortal(portal) || !/^(\/guides\/img\/[\w.-]+\.(jpg|png)|https:\/\/\S+)$/.test(oldUrl)) return new NextResponse('Unknown guide or image', { status: 400 });
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (!bytes.byteLength || bytes.byteLength > MAX || !(bytes[0] === 0xff && bytes[1] === 0xd8)) return new NextResponse('Not a JPEG', { status: 400 });
  const sha = await sha256Hex(bytes);
  const key = `guides/${portal}/upkeep-${sha.slice(0, 24)}.jpg`;
  const { storage } = await import('@/integrations/storage');
  const s = await storage();
  await s.put('vehicle-public', key, bytes, 'image/jpeg');
  const url = s.publicUrl(key);
  const r = await rpc('server_guide_upkeep_apply', { p: { run: q.get('run') ?? 'manual', images: [{ old_url: oldUrl, new_url: url, storage_key: key, portal,
    width: Number(q.get('width') ?? '') || null, height: Number(q.get('height') ?? '') || null, bytes: bytes.byteLength, diff: Number(q.get('diff') ?? '') || null }] } }, SR);
  return NextResponse.json({ ok: true, url, ...(r as unknown as Record<string, unknown>) });
}
