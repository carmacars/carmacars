import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { workerToken } from '@/server/listing-worker';
import { aiPickCar, guesses } from '@/server/turo-ai';
import { matchCar, signalsOf, type MatchCar, type MatchTrip } from '@/features/turo/match';

// Turo by email (migration 0088): the Turo emails still waiting for their car are matched again whenever the fleet or
// what was learned changed (app.turo_rematch_due; the Worker's cron runs this only when the cron gate says "turo").
// This is also the backfill of the emails received before 0088. Only what the database kept is read (the subject, the
// car's name as Turo wrote it, its Turo car ids, the redacted excerpt); the model may pick between a short list once per
// email. The jobs' bearer token only.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };

interface Due { id: string; first: boolean; subject: string | null; kind: string; trip_id: string | null; starts_at: string | null; ends_at: string | null;
  guest_first_name: string | null; vehicle_hint: string | null; car_name: string | null; turo_car_ids: string[]; excerpt: string | null }

export async function POST(req: Request) {
  const want = await workerToken();
  const got = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  let d = want.length ^ got.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  if (d !== 0) return new NextResponse('Forbidden', { status: 403 });
  const due = (await rpc('turo_rematch_due', { p_limit: 20 }, SR)) as unknown as Due[];
  if (!due.length) return NextResponse.json({ ok: true, matched: 0, waiting: 0 });
  const keys = (await rpc('turo_match_keys', {}, SR)) as unknown as { enabled: boolean; ai_ok: boolean; cars: MatchCar[]; trips?: MatchTrip[] };
  const cars = keys.cars ?? [];
  const makes = [...new Set(cars.flatMap((c) => (c.make ? [c.make, c.make.split(/[\s-]/)[0]!] : [])))];
  let matched = 0, waiting = 0;
  for (const e of due) {
    const subject = e.subject ?? '';
    const text = [e.car_name && `Car: ${e.car_name}`, e.vehicle_hint && e.vehicle_hint !== e.car_name ? `your ${e.vehicle_hint}` : null, e.excerpt].filter(Boolean).join('\n');
    const sig = signalsOf(subject, text, '', { tripId: e.trip_id, guest: e.guest_first_name, start: e.starts_at, end: e.ends_at, makes });
    // the redacted excerpt writes a Turo link as "[Turo link 2711093]"
    const linked = [...(e.excerpt ?? '').matchAll(/\[Turo link (\d{5,12})\]/g)].map((x) => x[1]!).filter((x) => x !== e.trip_id);
    sig.turoCarIds = [...new Set([...(e.turo_car_ids ?? []), ...sig.turoCarIds, ...linked])];
    if (e.car_name && !sig.carNames.includes(e.car_name)) { sig.carNames.unshift(e.car_name); sig.carName = e.car_name; }
    const r = matchCar(sig, subject, text, cars, keys.trips ?? []);
    let vehicle = r.vehicleId, method: 'rules' | 'ai' = 'rules', why = r.why, neurons = 0;
    if (!vehicle && e.first && keys.enabled && keys.ai_ok && r.candidates.length >= 2) {
      const a = await aiPickCar(sig, subject, cars, r.candidates);
      neurons = a.neurons;
      if (a.id) { vehicle = a.id; method = 'ai'; why = `picked by the assistant between ${r.candidates.length} cars`; }
    }
    const out = (await rpc('turo_rematch_result', { p: { id: e.id, vehicle_id: vehicle, method, why: why?.slice(0, 280) ?? null, candidates: guesses(r.candidates),
      car_name: sig.carName, neurons } }, SR)) as unknown as { status: string };
    if (out.status === 'applied') matched++; else waiting++;
  }
  return NextResponse.json({ ok: true, matched, waiting });
}
