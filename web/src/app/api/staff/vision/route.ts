import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { visionModel } from '@/integrations/vision';
import { PLATE_PROMPT, PLATE_SCHEMA, PLATE_SYSTEM, TOLL_PROMPT, TOLL_SCHEMA, TOLL_SYSTEM } from '@/features/tolls/vision-schema';

// One image to the vision model (migration 0042): a page of a scanned toll notice (Finance, Admins) or a listing
// photo for the plate box (Fleet, customer service, Admins). The browser made the image small; the database
// says whether this person may ask, which model, and whether today's allowance has room; the call is recorded
// with its neurons. The answer goes back as JSON for the browser to check and show; nothing is stored from it
// except a plate suggestion on its photo.
export const dynamic = 'force-dynamic';
const MAX = 4_500_000;

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const user = await currentUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first.' }, { status: 401 });
  const aal = await sessionAal();
  const body = (await req.json().catch(() => null)) as { purpose?: string; image?: string; photo?: string; vehicle?: string } | null;
  const purpose = body?.purpose === 'plate_detect' ? 'plate_detect' : body?.purpose === 'toll_read' ? 'toll_read' : null;
  const image = typeof body?.image === 'string' ? body.image : '';
  if (!purpose) return NextResponse.json({ ok: false, message: 'Unknown request.' }, { status: 400 });
  if (!/^data:image\/(jpeg|png);base64,/.test(image) || image.length > MAX) {
    return NextResponse.json({ ok: false, message: 'Send a JPEG or PNG image under 3 MB.' }, { status: 400 });
  }
  let gate: { allowed: boolean; reason?: string; model: string; fallback_model: string | null };
  try { gate = await door(user.id, 'ops_read', 'ai_vision_gate', { purpose }, aal); }
  catch (e) { return NextResponse.json({ ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Not permitted.' }, { status: 403 }); }
  if (!gate.allowed) return NextResponse.json({ ok: false, reason: 'off', message: gate.reason ?? 'The vision model is not available.' });
  const t0 = Date.now();
  const r = await (await visionModel()).read({
    purpose, imageDataUrl: image,
    system: purpose === 'toll_read' ? TOLL_SYSTEM : PLATE_SYSTEM, prompt: purpose === 'toll_read' ? TOLL_PROMPT : PLATE_PROMPT,
    schema: (purpose === 'toll_read' ? TOLL_SCHEMA : PLATE_SCHEMA) as unknown as Record<string, unknown>, maxOutputTokens: purpose === 'toll_read' ? 2000 : 300
  }, [gate.model, gate.fallback_model ?? ''].filter(Boolean));
  const model = r.model ?? r.tried[r.tried.length - 1] ?? gate.model;
  await door(user.id, 'ops_do', 'ai_call_record', { purpose, model, ok: r.ok, error: r.ok ? null : `${r.reason}: ${r.message}`, neurons: r.usage?.neurons ?? 0, duration_ms: Date.now() - t0,
    vehicle: typeof body?.vehicle === 'string' && /^[0-9a-f-]{36}$/.test(body.vehicle) ? body.vehicle : null }, aal).catch(() => undefined);
  if (!r.ok) return NextResponse.json({ ok: false, reason: r.reason, message: r.message, model, tried: r.tried });
  if (purpose === 'plate_detect' && typeof body?.photo === 'string' && /^[0-9a-f-]{36}$/.test(body.photo)) {
    await door(user.id, 'ops_do', 'photo_plate_suggestion', { photo: body.photo, suggestion: { answer: r.data, model, at: new Date().toISOString() } }, aal).catch(() => undefined);
  }
  return NextResponse.json({ ok: true, model, neurons: r.usage.neurons, data: r.data });
}
