import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { rpc } from '@/lib/db/repo';
import { visionModel } from '@/integrations/vision';
import { VIN_PROMPT, VIN_SYSTEM, vinsFromModel } from '@/features/vin/vin-read';
import { foreignOrigin } from '@/lib/security/same-origin';

// A photo of a VIN read by the vision model (release 28, migration 0560; features/vin/VinScan.tsx), when the photo has no
// barcode the browser could read. Anyone may ask (the owner's application and the earnings calculator are public): the
// database decides whether this person or this visitor may ask now (staff by the day's AI allowance; a signed-in person
// and a visitor each within a daily count; visitors together within a daily total) and which model. The call is
// recorded with its neurons, never the VIN; the photo is not kept. The answer goes back checked (vin-read.ts).
export const dynamic = 'force-dynamic';
const MAX = 4_500_000;
const SR = { role: 'service_role' as const };

async function clientKey(req: Request): Promise<string> {
  // a visitor is counted by a hash of the address and the day (never the address itself)
  const ip = req.headers.get('cf-connecting-ip') ?? req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'unknown';
  const day = new Date().toISOString().slice(0, 10);
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`vin-read|${day}|${ip}`));
  return [...new Uint8Array(d)].slice(0, 16).map((b) => b.toString(16).padStart(2, '0')).join('');
}

export async function POST(req: Request) {
  try { return await handle(req); } catch (e) {
    console.error('vin read', e instanceof Error ? `${e.name}: ${e.message}`.slice(0, 300) : 'error');
    return NextResponse.json({ ok: false, reason: 'unavailable', message: 'The photo could not be read just now. Type the VIN.' }, { status: 500 });
  }
}

async function handle(req: Request): Promise<Response> {
  const origin = req.headers.get('origin');
  if (foreignOrigin(origin, req.headers.get('host'), req.headers.get('sec-fetch-site'))) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const body = (await req.json().catch(() => null)) as { image?: string } | null;
  const image = typeof body?.image === 'string' ? body.image : '';
  if (!/^data:image\/(jpeg|png);base64,/.test(image) || image.length > MAX) {
    return NextResponse.json({ ok: false, message: 'Send a JPEG or PNG photo under 3 MB.' }, { status: 400 });
  }
  const user = await currentUser().catch(() => null);
  const client = await clientKey(req);
  const gate = (await rpc('server_vin_read_gate', { p_by: user?.id ?? undefined, p_client: client }, SR)) as unknown as { allowed: boolean; reason?: string; model: string; fallback_model: string | null };
  if (!gate?.allowed) return NextResponse.json({ ok: false, reason: 'off', message: gate?.reason ?? 'Reading a VIN photo is not available now. Type the VIN.' });
  const t0 = Date.now();
  const r = await (await visionModel()).read({ purpose: 'vin_read', imageDataUrl: image, system: VIN_SYSTEM, prompt: VIN_PROMPT,
    schema: { type: 'object', properties: { vin: { type: 'string' }, other: { type: 'array', items: { type: 'string' } } } }, maxOutputTokens: 120 },
  [gate.model, gate.fallback_model ?? ''].filter(Boolean));
  const vins = r.ok ? vinsFromModel(r.data) : [];
  await rpc('server_vin_read_record', { p_by: user?.id ?? undefined, p_client: client, p: { model: r.model ?? r.tried[r.tried.length - 1] ?? gate.model, ok: r.ok && vins.length > 0,
    error: r.ok ? (vins.length ? null : 'no VIN in the answer') : `${r.reason}: ${r.message}`, neurons: r.usage?.neurons ?? 0, duration_ms: Date.now() - t0,
    check_ok: vins[0]?.checkOk ?? null, corrected: vins[0]?.corrected ?? null } }, SR).catch(() => undefined);
  if (!vins.length) return NextResponse.json({ ok: false, reason: r.ok ? 'no_vin' : r.reason, message: 'No VIN could be read from this photo. Try a sharper photo, closer and in good light, or type it.' });
  return NextResponse.json({ ok: true, vins: vins.slice(0, 3) });
}
