import { NextResponse } from 'next/server';
import { door } from '@/server/door';
import { realUser } from '@/server/portal/data';
import { visionModel } from '@/integrations/vision';
import { cleanPlate } from '@/features/old-photos/group';
import { foreignOrigin } from '@/lib/security/same-origin';

// Add old photos (5185), the bulk flow: the plate on one photo of a group, read by the vision chain (the same one that finds
// plates on listing photos, purpose plate_detect, inside its daily allowance). The call is recorded with its model and
// neurons; neither the photo nor the plate is kept. Any failure answers "no plate" and the time alone suggests the booking.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
const MAX = 1_500_000;
const NONE = { ok: true, plate: null };
const SYSTEM = 'You read licence plates in photos of cars for a car rental company. Answer with JSON only, in the shape asked. Never guess a character.';
const PROMPT = 'Read the licence plate (number plate) of the car in this photo, front or rear. Answer with one JSON object: {"plate": "ABCD123", "confidence": 0}. "plate" is the characters exactly as printed, letters and digits only, no spaces; null when no plate can be read clearly. "confidence" is 0 to 100.';
const SCHEMA = { type: 'object', properties: { plate: { type: ['string', 'null'] }, confidence: { type: ['number', 'null'] } }, required: ['plate'] };

export async function POST(req: Request) {
  if (foreignOrigin(req.headers.get('origin'), req.headers.get('host'), req.headers.get('sec-fetch-site'))) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403, headers: H });
  const user = await realUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first.' }, { status: 401, headers: H });
  const body = (await req.json().catch(() => null)) as { image?: unknown } | null;
  const image = typeof body?.image === 'string' ? body.image : '';
  if (!/^data:image\/jpeg;base64,/.test(image) || image.length > MAX) return NextResponse.json({ ok: false, message: 'Send a small JPEG.' }, { status: 400, headers: H });
  let gate: { allowed: boolean; model?: string; fallback_model?: string | null };
  try { gate = await door(user.id, 'ops_read', 'old_photo_plate_gate', {}); } catch { return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403, headers: H }); }
  if (!gate.allowed || !gate.model) return NextResponse.json(NONE, { headers: H });
  const t0 = Date.now();
  try {
    const r = await (await visionModel()).read({ purpose: 'plate_detect', imageDataUrl: image, system: SYSTEM, prompt: PROMPT, schema: SCHEMA, maxOutputTokens: 60 },
      [gate.model, gate.fallback_model ?? ''].filter(Boolean));
    const d = (r.ok ? r.data : null) as { plate?: unknown; confidence?: unknown } | null;
    const plate = d && (typeof d.confidence !== 'number' || d.confidence >= 60) ? cleanPlate(d.plate) : null;
    await door(user.id, 'ops_do', 'old_photo_plate_record', { model: r.model ?? r.tried[r.tried.length - 1] ?? gate.model, ok: r.ok && plate !== null,
      error: r.ok ? (plate ? null : 'no plate read') : r.reason, neurons: r.usage?.neurons ?? 0, duration_ms: Date.now() - t0 }).catch(() => undefined);
    return NextResponse.json({ ok: true, plate }, { headers: H });
  } catch (e) {
    console.error('old photo plate', e instanceof Error ? e.name : 'error');
    return NextResponse.json(NONE, { headers: H });
  }
}
