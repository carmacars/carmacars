import { NextResponse, after } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';
import { runListingWorkerNow } from '@/server/listing-worker';
import { BACKDROP_PATH } from '@/features/listing/worker';

// The cut-out editor of an outside listing photo (release 33, migration 0700; features/listing/CutoutEditor.tsx).
// GET: what the editor works from, from this site's own address so the canvas can be read back (the plate route's
// reason, r28): part=info (the photo, its mask, its placement), original (the photo as taken), mask (the cut-out as last
// edited, else the automatic one), automask (the automatic one, for Reset) and backdrop (the studio). POST: action=save
// stores the edited cut-out privately and has the photo made again from it (app.photo_cutout_edit keeps the version
// before); action=mask asks the worker for the mask of a photo made before the masks were kept. Same rights as covering a
// plate (Fleet, customer service, an Admin), checked by the database on every call.
export const dynamic = 'force-dynamic';
const MAX = 15 * 1024 * 1024;
type Ctx = { id: string; vehicle_id: string; original_path: string | null; processed_path: string | null; auto_mask: string | null; mask: string | null; replaced: boolean; rebackground: boolean };
const msg = (e: unknown, d: string) => (e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : d);
const PRIVATE = { 'cache-control': 'private, no-store', 'x-content-type-options': 'nosniff' };

async function me() {
  const user = await currentUser();
  return user ? { user, aal: await sessionAal() } : null;
}

export async function GET(req: Request) {
  const q = new URL(req.url).searchParams;
  const photo = q.get('photo') ?? '', part = q.get('part') ?? 'info';
  if (!/^[0-9a-f-]{36}$/.test(photo) || !['info', 'original', 'mask', 'automask', 'backdrop'].includes(part)) return new NextResponse('Unknown photo.', { status: 400 });
  const m = await me();
  if (!m) return new NextResponse('Sign in first.', { status: 401 });
  let ctx: Ctx;
  try { ctx = await door<Ctx>(m.user.id, 'ops_read', 'photo_cutout_context', { photo }, m.aal); }
  catch (e) { return NextResponse.json({ ok: false, message: msg(e, 'Not permitted.') }, { status: 403 }); }
  if (part === 'info') return NextResponse.json({ ok: true, data: ctx }, { headers: PRIVATE });
  const s = await storage();
  const [bucket, path] = part === 'backdrop' ? ['vehicle-public' as const, BACKDROP_PATH]
    : part === 'original' ? ['vehicle-originals' as const, ctx.original_path]
    : ['vehicle-originals' as const, part === 'mask' ? ctx.mask ?? ctx.auto_mask : ctx.auto_mask];
  if (!path) return new NextResponse('No cut-out is kept for this photo yet.', { status: 409 });
  let body: Uint8Array | ArrayBuffer | null = await s.get(bucket, path).catch(() => null);
  if (!body && bucket === 'vehicle-public') {
    const r = await fetch(new URL(s.publicUrl(path), req.url), { signal: AbortSignal.timeout(10_000) }).catch(() => null);
    body = r && r.ok ? await r.arrayBuffer().catch(() => null) : null;
  }
  if (!body) return new NextResponse('The file could not be read.', { status: 404 });
  const b = body instanceof Uint8Array ? body : new Uint8Array(body);
  const type = b[0] === 0x89 ? 'image/png' : 'image/jpeg';
  return new NextResponse(b as unknown as BodyInit, { headers: { 'content-type': type, ...PRIVATE } });
}

function kick() {
  after(async () => { try { await runListingWorkerNow({ maxJobs: 4, deadlineMs: 25_000 }); } catch { /* the cron sweep picks it up */ } });
}

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const m = await me();
  if (!m) return NextResponse.json({ ok: false, message: 'Sign in first.' }, { status: 401 });
  const form = await req.formData().catch(() => null);
  const photo = String(form?.get('photo') ?? ''), action = String(form?.get('action') ?? '');
  if (!/^[0-9a-f-]{36}$/.test(photo) || !['save', 'mask'].includes(action)) return NextResponse.json({ ok: false, message: 'Unknown photo.' }, { status: 400 });
  if (action === 'mask') {
    try {
      const data = await door<{ queued: boolean; ready?: boolean; pending?: boolean }>(m.user.id, 'ops_do', 'photo_cutout_mask', { photo }, m.aal);
      if (data.queued) kick();
      return NextResponse.json({ ok: true, data });
    } catch (e) { return NextResponse.json({ ok: false, message: msg(e, 'The mask could not be asked for.') }, { status: 422 }); }
  }
  let ctx: Ctx;
  try { ctx = await door<Ctx>(m.user.id, 'ops_read', 'photo_cutout_context', { photo }, m.aal); }
  catch (e) { return NextResponse.json({ ok: false, message: msg(e, 'Not permitted.') }, { status: 403 }); }
  if (!ctx.rebackground || ctx.replaced) return NextResponse.json({ ok: false, message: 'Only an outside photo on the studio background is edited here.' }, { status: 409 });
  const file = form?.get('file');
  if (!(file instanceof Blob) || file.size === 0 || file.size > MAX) return NextResponse.json({ ok: false, message: 'The cut-out must be under 15 MB.' }, { status: 400 });
  const bytes = new Uint8Array(await file.arrayBuffer());
  if (!(bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47)) return NextResponse.json({ ok: false, message: 'The cut-out must be a PNG.' }, { status: 400 });
  const num = (k: string, d: number) => { const v = Number(form?.get(k)); return Number.isFinite(v) ? v : d; };
  const s = await storage();
  const path = `vehicles/${ctx.vehicle_id}/work/${ctx.id}-edit-${crypto.randomUUID().replace(/-/g, '').slice(0, 8)}.png`;
  await s.put('vehicle-originals', path, bytes, 'image/png');
  try {
    const data = await door<{ version: number }>(m.user.id, 'ops_do', 'photo_cutout_edit', { photo, cutout_path: path, adjust: { dx: num('dx', 0), dy: num('dy', 0), scale: num('scale', 1) } }, m.aal);
    kick();
    return NextResponse.json({ ok: true, data });
  } catch (e) {
    await s.remove('vehicle-originals', path).catch(() => undefined);
    return NextResponse.json({ ok: false, message: msg(e, 'The cut-out could not be saved.') }, { status: 422 });
  }
}
