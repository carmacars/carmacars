import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { rpc } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { visionModel } from '@/integrations/vision';
import { GEMINI_DEFAULT_MODEL, geminiVision } from '@/integrations/vision/gemini';
import { DASH_PROMPT, DASH_SYSTEM, dashFromModel } from '@/features/handover/reading';
import { UUID } from '@/features/returns/claim';
import { foreignOrigin } from '@/lib/security/same-origin';

// The dashboard photo of a check-out or check-in read by the vision model (release 35, migration 0910): the renter of the
// booking, staff who record handovers, or the holder of the booking's return link. The database decides who and whether
// the day's AI allowance has room (purpose dash_read). Workers AI first; Gemini only when GEMINI_API_KEY is set and the
// first did not read it; any failure answers "not read" and the person types the reading. The call is recorded with its
// model and neurons, never the reading; the photo is not kept here (the person uploaded it to the report already).
export const dynamic = 'force-dynamic';
const MAX = 4_500_000;
const SR = { role: 'service_role' as const, skipViewAs: true };
const NOT_READ = { ok: false, message: 'The photo could not be read. Type the odometer and pick the fuel level.' };

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (foreignOrigin(origin, req.headers.get('host'), req.headers.get('sec-fetch-site'))) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const body = (await req.json().catch(() => null)) as { booking?: string; token?: string; image?: string } | null;
  const image = typeof body?.image === 'string' ? body.image : '';
  const booking = body?.booking && UUID.test(body.booking) ? body.booking : null;
  const token = body?.token && UUID.test(body.token) ? body.token : null;
  if (!/^data:image\/(jpeg|png);base64,/.test(image) || image.length > MAX || (!booking && !token)) {
    return NextResponse.json({ ok: false, message: 'Send a JPEG or PNG photo under 3 MB.' }, { status: 400 });
  }
  try {
    const user = await currentUser().catch(() => null);
    const gate = (await rpc('server_dash_read_gate' as never, { p_booking: booking, p_by: user?.id ?? null, p_token: token } as never, SR)) as unknown as
      { allowed: boolean; reason?: string; model?: string; fallback_model?: string | null };
    if (gate?.reason === 'not_permitted') return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
    const ask = { purpose: 'dash_read' as const, imageDataUrl: image, system: DASH_SYSTEM, prompt: DASH_PROMPT, maxOutputTokens: 120 };
    const t0 = Date.now();
    let r = gate?.allowed && gate.model ? await (await visionModel()).read(ask, [gate.model, gate.fallback_model ?? ''].filter(Boolean)) : null;
    const key = env().GEMINI_API_KEY;
    if ((!r || !r.ok) && key) r = await geminiVision(key, env().GEMINI_VISION_MODEL || GEMINI_DEFAULT_MODEL).read(ask, []);
    if (!r) return NextResponse.json(NOT_READ);
    const read = r.ok ? dashFromModel(r.data) : { odometer_km: null, fuel_eighths: null };
    await rpc('server_dash_read_record' as never, { p: { model: r.ok ? r.model : r.model ?? r.tried[r.tried.length - 1] ?? gate?.model, ok: r.ok && read.odometer_km !== null,
      error: r.ok ? (read.odometer_km === null ? 'no reading in the answer' : null) : `${r.reason}`, neurons: r.usage?.neurons ?? 0, duration_ms: Date.now() - t0 } } as never, SR).catch(() => undefined);
    if (read.odometer_km === null || read.fuel_eighths === null) return NextResponse.json(NOT_READ);
    return NextResponse.json({ ok: true, odometer_km: read.odometer_km, fuel_eighths: read.fuel_eighths, model: r.ok ? r.model : null });
  } catch (e) {
    console.error('dash read', e instanceof Error ? e.name : 'error');
    return NextResponse.json(NOT_READ);
  }
}
