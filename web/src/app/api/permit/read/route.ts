import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { rpc } from '@/lib/db/repo';
import { visionModel } from '@/integrations/vision';
import { PERMIT_PROMPT, PERMIT_SCHEMA, PERMIT_SYSTEM, normalizePermit, permitScore } from '@/features/vehicles/permit-read';
import { foreignOrigin } from '@/lib/security/same-origin';

// An ownership permit photo read by the vision model (migration 0290), when staff or an owner add a car. The browser made
// the photo small; the database says whether this person may ask now (staff, or a signed-in owner within the daily
// count) and which model; the call is recorded with its neurons and the number of fields read (never the values). The
// answer goes back checked (the VIN's check digit, the plate's format, the sticker date) for the person to review in the
// form; nothing read is saved here.
export const dynamic = 'force-dynamic';
const MAX = 4_500_000;
const SR = { role: 'service_role' as const };
const torontoToday = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

export async function POST(req: Request) {
  try { return await handle(req); } catch (e) {
    const message = e instanceof Error ? `${e.name}: ${e.message}`.slice(0, 300) : 'The permit could not be read.';
    console.error('permit read', message);
    return NextResponse.json({ ok: false, reason: 'unavailable', message: 'The permit could not be read just now. Type the details from the permit.' }, { status: 500 });
  }
}

async function handle(req: Request): Promise<Response> {
  const origin = req.headers.get('origin');
  if (foreignOrigin(origin, req.headers.get('host'), req.headers.get('sec-fetch-site'))) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const user = await currentUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first.' }, { status: 401 });
  const body = (await req.json().catch(() => null)) as { image?: string } | null;
  const image = typeof body?.image === 'string' ? body.image : '';
  if (!/^data:image\/(jpeg|png);base64,/.test(image) || image.length > MAX) {
    return NextResponse.json({ ok: false, message: 'Send a JPEG or PNG photo under 3 MB.' }, { status: 400 });
  }
  let gate: { allowed: boolean; reason?: string; model: string; fallback_model: string | null };
  try { gate = (await rpc('server_permit_read_gate', { p_by: user.id }, SR)) as unknown as typeof gate; }
  catch (e) { return NextResponse.json({ ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Not permitted.' }, { status: 403 }); }
  if (!gate.allowed) return NextResponse.json({ ok: false, reason: 'off', message: gate.reason ?? 'Reading a permit photo is not available. Type the details from the permit.' });
  const t0 = Date.now();
  const r = await (await visionModel()).read({ purpose: 'permit_read', imageDataUrl: image, system: PERMIT_SYSTEM, prompt: PERMIT_PROMPT,
    schema: PERMIT_SCHEMA as unknown as Record<string, unknown>, maxOutputTokens: 400 }, [gate.model, gate.fallback_model ?? ''].filter(Boolean));
  const model = r.model ?? r.tried[r.tried.length - 1] ?? gate.model;
  const read = r.ok ? normalizePermit(r.data, torontoToday()) : null;
  await rpc('server_permit_read_record', { p_by: user.id, p: { model, ok: r.ok, error: r.ok ? null : `${r.reason}: ${r.message}`, neurons: r.usage?.neurons ?? 0,
    duration_ms: Date.now() - t0, fields_read: read ? permitScore(read).ok : 0 } }, SR).catch(() => undefined);
  if (!r.ok || !read) return NextResponse.json({ ok: false, reason: r.ok ? 'invalid_output' : r.reason, message: 'The permit could not be read from this photo. Try a sharper photo, flat and in good light, or type the details.' });
  return NextResponse.json({ ok: true, model, read });
}
