import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';
import { LESSON_MAX_BYTES } from '@/features/academy/video';
import { foreignOrigin } from '@/lib/security/same-origin';

// Release 37 (2301): an academy lesson's video file. GET ?lesson=<id>[&download=1]: the lesson's current video from the
// private documents bucket, for whoever may watch the lesson (the database decides: app.academy_may_watch). POST (form:
// lesson, seconds, file): a recording made in the browser, kept as the lesson's video when none is current. Never cached.
export const dynamic = 'force-dynamic';
type Kit = { lessons: Array<{ lesson: string; video: { id: string; path: string; mime: string } | null }> };
const UUID = /^[0-9a-f-]{36}$/;

async function kit(lesson: string) {
  const user = await currentUser();
  if (!user) return { error: new NextResponse('Sign in first.', { status: 401 }) } as const;
  const aal = await sessionAal();
  try { return { user, aal, k: await door<Kit>(user.id, 'ops_read', 'academy_videos', { lesson }, aal) } as const; }
  catch { return { error: new NextResponse('Not permitted.', { status: 403 }) } as const; }
}

export async function GET(req: Request) {
  const q = new URL(req.url).searchParams;
  const lesson = q.get('lesson') ?? '';
  if (!UUID.test(lesson)) return new NextResponse('Unknown lesson.', { status: 400 });
  const r = await kit(lesson);
  if ('error' in r) return r.error;
  const v = r.k.lessons[0]?.video;
  if (!v) return new NextResponse('No video yet.', { status: 404 });
  const body = await (await storage()).get('documents', v.path).catch(() => null);
  if (!body) return new NextResponse('The file could not be read.', { status: 404 });
  const ext = v.path.split('.').pop();
  const headers: Record<string, string> = { 'content-type': v.mime, 'cache-control': 'private, no-store', 'x-content-type-options': 'nosniff',
    'content-disposition': `${q.get('download') ? 'attachment' : 'inline'}; filename="lesson-${lesson.slice(0, 8)}.${ext}"` };
  return new NextResponse(body as unknown as BodyInit, { headers });
}

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (foreignOrigin(origin, req.headers.get('host'))) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const form = await req.formData().catch(() => null);
  const lesson = String(form?.get('lesson') ?? '');
  const file = form?.get('file');
  const seconds = Number(form?.get('seconds') ?? 0);
  if (!UUID.test(lesson) || !(file instanceof File) || !(seconds > 0)) return NextResponse.json({ ok: false, message: 'The video is missing.' }, { status: 400 });
  if (file.size === 0 || file.size > LESSON_MAX_BYTES) return NextResponse.json({ ok: false, message: 'The video must be under 80 MB.' }, { status: 413 });
  const r = await kit(lesson);
  if ('error' in r) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  if (r.k.lessons[0]?.video) return NextResponse.json({ ok: true, data: r.k });
  const bytes = new Uint8Array(await file.arrayBuffer());
  // MP4 ("ftyp" at byte 4) or WebM (the EBML header)
  const mp4 = bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 && bytes[7] === 0x70;
  const webm = bytes[0] === 0x1a && bytes[1] === 0x45 && bytes[2] === 0xdf && bytes[3] === 0xa3;
  if (!mp4 && !webm) return NextResponse.json({ ok: false, message: 'The file is not an MP4 or WebM video.' }, { status: 415 });
  const key = `academy/videos/${lesson}/${crypto.randomUUID()}.${mp4 ? 'mp4' : 'webm'}`;
  const st = await storage();
  await st.put('documents', key, bytes, mp4 ? 'video/mp4' : 'video/webm');
  try {
    const data = await door<Record<string, unknown>>(r.user.id, 'ops_do', 'academy_video_save', { lesson, path: key, mime: mp4 ? 'video/mp4' : 'video/webm', seconds, bytes: bytes.length }, r.aal);
    if (data.kept === 'existing') await st.remove('documents', key).catch(() => undefined);
    return NextResponse.json({ ok: true, data });
  } catch (e) {
    await st.remove('documents', key).catch(() => undefined);
    return NextResponse.json({ ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Not saved.' }, { status: 400 });
  }
}

/** DELETE ?id=<video>: an Admin removes a bad recording and its file (the next "Watch as video" makes it again). */
export async function DELETE(req: Request) {
  const origin = req.headers.get('origin');
  if (foreignOrigin(origin, req.headers.get('host'))) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const id = new URL(req.url).searchParams.get('id') ?? '';
  const user = await currentUser();
  if (!user || !UUID.test(id)) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  try {
    const data = await door<Record<string, unknown>>(user.id, 'ops_do', 'academy_video_remove', { id }, await sessionAal());
    if (typeof data.removed_path === 'string') await (await storage()).remove('documents', data.removed_path).catch(() => undefined);
    return NextResponse.json({ ok: true, data });
  } catch (e) {
    return NextResponse.json({ ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Not removed.' }, { status: 403 });
  }
}
