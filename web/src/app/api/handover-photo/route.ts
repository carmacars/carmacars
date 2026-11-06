import { NextResponse } from 'next/server';
import { storage } from '@/integrations/storage';
import { rpc } from '@/lib/db/repo';
import { door } from '@/server/door';
import { realUser } from '@/server/portal/data';
import { photoKey, type PhotoScope } from '@/features/handover/angles';
import { MAX_PHOTO_BYTES, UUID } from '@/features/returns/claim';

// One photo of a check-out or check-in (migration 0545) or of a car picked up from or returned to its owner (0546). The
// browser made it a smaller JPEG first. Who may: self-pickup, the booking's renter; one-screen, staff who hand cars over;
// owner-handoff, an Admin, Fleet or field staff (and, to view, the car's owner). Private storage only; the record that
// lists the keys checks again that each belongs to this booking or car.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
const SR = { role: 'service_role' as const, skipViewAs: true };

async function allowed(userId: string, scope: string, id: string, view = false): Promise<boolean> {
  try {
    if (scope === 'self-pickup') return Boolean(await rpc('server_return_link', { p_booking: id, p_user: userId }, SR));
    if (scope === 'one-screen') { await door(userId, 'ops_read', 'self_handovers', { booking: id }); return true; }
    if (scope === 'owner-handoff') {
      if (view) { await rpc('server_owner_handoffs' as never, { p_by: userId, p_vehicle: id } as never, SR); return true; }
      await door(userId, 'ops_read', 'owner_handoffs', { vehicle: id }); return true;
    }
  } catch { return false; }
  return false;
}

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403, headers: H });
  const user = await realUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first.' }, { status: 401, headers: H });
  const form = await req.formData().catch(() => null);
  const scope = String(form?.get('scope') ?? '') as PhotoScope;
  const id = String(form?.get('id') ?? '');
  if (!['self-pickup', 'one-screen', 'owner-handoff'].includes(scope) || !UUID.test(id)) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 400, headers: H });
  if (!(await allowed(user.id, scope, id))) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403, headers: H });
  const file = form?.get('file');
  if (!(file instanceof Blob) || file.size === 0 || file.size > MAX_PHOTO_BYTES) return NextResponse.json({ ok: false, message: 'Each photo must be under 8 MB.' }, { status: 400, headers: H });
  const bytes = new Uint8Array(await file.arrayBuffer());
  const jpg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const png = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  if (!jpg && !png) return NextResponse.json({ ok: false, message: 'That file is not a photo.' }, { status: 400, headers: H });
  const key = photoKey(scope, id, crypto.randomUUID(), png);
  await (await storage()).put('condition-photos', key, bytes, png ? 'image/png' : 'image/jpeg');
  return NextResponse.json({ ok: true, bucket: 'condition-photos', path: key }, { headers: H });
}

/** A photo of an owner pickup or return, to see (staff, or the car's owner): ?vehicle=<id>&path=<key>. */
export async function GET(req: Request) {
  const u = new URL(req.url);
  const id = u.searchParams.get('vehicle') ?? '';
  const path = u.searchParams.get('path') ?? '';
  if (!UUID.test(id) || !new RegExp(`^vehicles/${id}/owner-handoff/[0-9a-f-]{36}\\.(jpg|png)$`).test(path)) return new Response('Not found', { status: 404 });
  const user = await realUser();
  if (!user || !(await allowed(user.id, 'owner-handoff', id, true))) return new Response('Not found', { status: 404 });
  const bytes = await (await storage()).get('condition-photos', path);
  if (!bytes) return new Response('Not found', { status: 404 });
  return new Response(bytes as unknown as BodyInit, { headers: { 'content-type': path.endsWith('.png') ? 'image/png' : 'image/jpeg', 'cache-control': 'private, max-age=300' } });
}
