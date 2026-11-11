import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { storage } from '@/integrations/storage';
import { availRs, errorRs, parseAvailRq, type QuoteCar, type VehicleInfo } from '@/features/channel/ota';

// The Channel API for rental distribution partners (release 37, migration 2304; docs/channel-api.md). Separate from the
// Admin API keys (0562). Every call goes through public.channel_api: the switch, the key (SHA-256), the partner, the scope,
// the per-key rate limit and the call log are the database's. Public listing data and prices only.
//   GET    /api/channel/v1/locations
//   GET    /api/channel/v1/vehicles
//   GET    /api/channel/v1/availability?pickup_at=&return_at=[&ref=][&lat=&lng=][&coverage=]
//   POST   /api/channel/v1/ota                 OTA_VehAvailRateRQ (XML) -> OTA_VehAvailRateRS
//   POST   /api/channel/v1/bookings            a booking request (scope bookings:create)
//   DELETE /api/channel/v1/bookings/<number>   (scope bookings:cancel; the partner's own requests only)
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ path: string[] }> };
type Res = { ok: boolean; status?: number; code?: string; message?: string; partner?: string; data?: Record<string, unknown> };
const SR = { role: 'service_role' as const };
const HEAD = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' };

function keyOf(req: Request): string {
  const a = req.headers.get('authorization') ?? '';
  return (/^Bearer\s+(\S+)$/i.exec(a)?.[1] ?? req.headers.get('x-api-key') ?? '').slice(0, 200);
}
async function call(req: Request, name: string, p: Record<string, unknown> = {}): Promise<Res> {
  try { return (await rpc('channel_api', { p_key: keyOf(req), p_call: name, p: p as unknown as Json }, SR)) as unknown as Res; }
  catch { return { ok: false, status: 500, code: 'error', message: 'The channel API could not answer' }; }
}
/** Photo paths to full addresses on the public photo host. */
async function photos<T extends { photos?: unknown }>(rows: T[]): Promise<T[]> {
  const st = await storage();
  return rows.map((r) => ({ ...r, photos: Array.isArray(r.photos) ? (r.photos as string[]).map((p) => st.publicUrl(p)) : [] }));
}
const json = (r: Res) => (r.ok ? NextResponse.json({ ok: true, data: r.data }, { headers: HEAD }) : NextResponse.json({ ok: false, code: r.code, message: r.message }, { status: r.status ?? 400, headers: HEAD }));

export async function GET(req: Request, { params }: Params) {
  const [what] = (await params).path;
  const q = new URL(req.url).searchParams;
  if (what === 'locations') return json(await call(req, 'locations'));
  if (what === 'vehicles') {
    const r = await call(req, 'vehicles');
    if (r.ok && r.data) r.data.vehicles = await photos((r.data.vehicles as Array<{ photos?: unknown }>) ?? []);
    return json(r);
  }
  if (what === 'availability') {
    const p: Record<string, unknown> = { pickup_at: q.get('pickup_at'), return_at: q.get('return_at') };
    if (q.get('ref')) p.ref = q.get('ref');
    if (q.get('lat') && q.get('lng')) { p.lat = Number(q.get('lat')); p.lng = Number(q.get('lng')); }
    if (q.get('coverage')) p.options = { coverage: q.get('coverage') };
    return json(await call(req, 'availability', p));
  }
  return NextResponse.json({ ok: false, code: 'not_found', message: 'Unknown call' }, { status: 404, headers: HEAD });
}

export async function POST(req: Request, { params }: Params) {
  const [what] = (await params).path;
  if (what === 'ota') {
    const body = (await req.text().catch(() => '')).slice(0, 20_000);
    const rq = parseAvailRq(body);
    const xml = (s: string, status = 200) => new NextResponse(s, { status, headers: { ...HEAD, 'content-type': 'application/xml; charset=utf-8' } });
    if (!rq) return xml(errorRs('Send an OTA_VehAvailRateRQ with VehRentalCore PickUpDateTime and ReturnDateTime', '321'), 400);
    const r = await call(req, 'availability', { pickup_at: rq.pickupAt, return_at: rq.returnAt });
    if (!r.ok) return xml(errorRs(r.message ?? 'Refused', r.code === 'rate' ? '429' : '450'), r.status ?? 400);
    const v = await call(req, 'vehicles');
    const info = new Map(((v.ok ? await photos((v.data?.vehicles as VehicleInfo[]) ?? []) : []) as VehicleInfo[]).map((x) => [x.ref, x]));
    return xml(availRs(rq, (r.data?.vehicles as QuoteCar[]) ?? [], info));
  }
  if (what === 'bookings') {
    const b = (await req.json().catch(() => null)) as Record<string, unknown> | null;
    if (!b || typeof b !== 'object') return NextResponse.json({ ok: false, code: 'body', message: 'Send the booking as JSON' }, { status: 400, headers: HEAD });
    return json(await call(req, 'booking_create', b));
  }
  return NextResponse.json({ ok: false, code: 'not_found', message: 'Unknown call' }, { status: 404, headers: HEAD });
}

export async function DELETE(req: Request, { params }: Params) {
  const [what, number] = (await params).path;
  if (what !== 'bookings' || !number) return NextResponse.json({ ok: false, code: 'not_found', message: 'Unknown call' }, { status: 404, headers: HEAD });
  return json(await call(req, 'booking_cancel', { booking_number: number }));
}
