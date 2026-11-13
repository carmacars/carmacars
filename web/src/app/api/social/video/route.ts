import { NextResponse } from 'next/server';
import { revalidatePath } from 'next/cache';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';
import { MAX_BYTES } from '@/features/social/video';
import { foreignOrigin } from '@/lib/security/same-origin';

// Release 36b (2210): the short video of a car. GET ?vehicle=&photo=N: the kit's Nth photo from this site's own address
// (a photo drawn from the storage host taints the canvas and the recording then fails); GET ?vehicle=&video=<id>: the
// saved video as a download. POST (form: vehicle, seconds, file): the finished video into the public bucket under the
// car's social folder, recorded by the database (who may: app.marketing_may). Never cached by a shared cache.
export const dynamic = 'force-dynamic';
type Kit = { photos: string[]; videos: Array<{ id: string; path: string; mime: string }> };
const UUID = /^[0-9a-f-]{36}$/;
const ctype = (p: string) => (/\.png$/i.test(p) ? 'image/png' : /\.webp$/i.test(p) ? 'image/webp' : /\.avif$/i.test(p) ? 'image/avif' : 'image/jpeg');

async function kit(vehicle: string) {
  const user = await currentUser();
  if (!user) return { error: new NextResponse('Sign in first.', { status: 401 }) } as const;
  const aal = await sessionAal();
  try { return { user, aal, k: await door<Kit>(user.id, 'ops_read', 'social_video_kit', { vehicle }, aal) } as const; }
  catch { return { error: new NextResponse('Not permitted.', { status: 403 }) } as const; }
}

async function bytesOf(path: string, req: Request): Promise<ArrayBuffer | Uint8Array | null> {
  const st = await storage();
  const b = await st.get('vehicle-public', path).catch(() => null);
  if (b) return b;
  const r = await fetch(new URL(st.publicUrl(path), req.url), { signal: AbortSignal.timeout(15_000) }).catch(() => null);
  return r && r.ok ? r.arrayBuffer().catch(() => null) : null;
}

export async function GET(req: Request) {
  const q = new URL(req.url).searchParams;
  const vehicle = q.get('vehicle') ?? '';
  if (!UUID.test(vehicle)) return new NextResponse('Unknown car.', { status: 400 });
  const r = await kit(vehicle);
  if ('error' in r) return r.error;
  const video = q.get('video');
  const path = video ? r.k.videos.find((v) => v.id === video)?.path : r.k.photos[Number(q.get('photo') ?? -1)];
  if (!path) return new NextResponse('Not found.', { status: 404 });
  const body = await bytesOf(path, req);
  if (!body) return new NextResponse('The file could not be read.', { status: 404 });
  const headers: Record<string, string> = { 'content-type': video ? (path.endsWith('.mp4') ? 'video/mp4' : 'video/webm') : ctype(path), 'cache-control': 'private, no-store', 'x-content-type-options': 'nosniff' };
  if (video) headers['content-disposition'] = `attachment; filename="carmacars-${vehicle.slice(0, 8)}-${video.slice(0, 8)}.${path.split('.').pop()}"`;
  return new NextResponse(body as unknown as BodyInit, { headers });
}

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (foreignOrigin(origin, req.headers.get('host'))) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const form = await req.formData().catch(() => null);
  const vehicle = String(form?.get('vehicle') ?? '');
  const file = form?.get('file');
  const seconds = Number(form?.get('seconds') ?? 0);
  if (!UUID.test(vehicle) || !(file instanceof File) || !(seconds > 0)) return NextResponse.json({ ok: false, message: 'The video is missing.' }, { status: 400 });
  if (file.size === 0 || file.size > MAX_BYTES) return NextResponse.json({ ok: false, message: 'The video must be under 14 MB: use fewer photos.' }, { status: 413 });
  const r = await kit(vehicle);
  if ('error' in r) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const bytes = new Uint8Array(await file.arrayBuffer());
  // MP4 ("ftyp" at byte 4) or WebM (the EBML header)
  const mp4 = bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 && bytes[7] === 0x70;
  const webm = bytes[0] === 0x1a && bytes[1] === 0x45 && bytes[2] === 0xdf && bytes[3] === 0xa3;
  if (!mp4 && !webm) return NextResponse.json({ ok: false, message: 'The file is not an MP4 or WebM video.' }, { status: 415 });
  const key = `vehicles/${vehicle}/social/${crypto.randomUUID()}.${mp4 ? 'mp4' : 'webm'}`;
  const st = await storage();
  await st.put('vehicle-public', key, bytes, mp4 ? 'video/mp4' : 'video/webm');
  try {
    const data = await door<Record<string, unknown>>(r.user.id, 'ops_do', 'social_video_save', { vehicle, path: key, mime: mp4 ? 'video/mp4' : 'video/webm', seconds, bytes: bytes.length }, r.aal);
    revalidatePath('/admin/marketing/social');
    return NextResponse.json({ ok: true, data });
  } catch (e) {
    await st.remove('vehicle-public', key).catch(() => undefined);
    return NextResponse.json({ ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Not saved.' }, { status: 400 });
  }
}
