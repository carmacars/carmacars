import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { jobAuthorized, turoGmailAuthorized } from '@/server/job-auth';
import { aiPickCar, guesses } from '@/server/turo-ai';
import { AI_SCHEMA, AI_SYSTEM, aiPrompt, gmailConfirmation, mergeAi, parseMime, parseTuroEmail, plainAddress, redact, type AiAnswer, type MatchCar, type MatchTrip } from '@/features/turo/email';

// Turo by email (migrations 0063, 0088). Turo emails arrive here as raw MIME: from an Apps Script in rent@'s Gmail
// (scripts/turo-gmail.gs, its own token, this route only) or from the Worker's email handler (custom-worker.ts,
// trips@in.carmacars.ca, the jobs' token). The email is read in memory (web/src/features/turo/email.ts and match.ts:
// rules first; the car scored on every active real car with what was learned; Workers AI for what the rules missed and
// to pick between a short list of cars) and only the parsed fields go to the database (app.turo_email_receive, which
// learns the car's Turo identifiers and keeps the guest). The message itself is never stored.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };
const MAX = 1_000_000;

interface Keys { enabled: boolean; forwarders: string; ai_ok: boolean; cars: MatchCar[]; trips?: MatchTrip[] }

export async function POST(req: Request) {
  if (!(await jobAuthorized(req)) && !(await turoGmailAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  const raw = await req.text();
  if (!raw || raw.length > MAX) return NextResponse.json({ ok: false, error: 'empty or too large' }, { status: 413 });
  const m = parseMime(raw);
  const envelope = plainAddress(req.headers.get('x-envelope-from') ?? '');
  const base = { message_id: m.messageId || null, sent_at: m.date?.toISOString() ?? null, envelope_from: envelope, subject: m.subject.slice(0, 200) };

  const g = gmailConfirmation(m);
  if (g) {
    const r = await rpc('turo_email_receive', { p: { ...base, kind: 'forwarding_confirmation', code: g.code, url: g.url } }, SR);
    return NextResponse.json({ ok: true, ...(r as Record<string, unknown>) });
  }

  const keys = (await rpc('turo_match_keys', {}, SR)) as unknown as Keys;
  const cars = keys.cars ?? [];
  let p = parseTuroEmail(m, cars, new Date(), keys.trips ?? []);
  let method: 'rules' | 'ai' = 'rules';
  let neurons = 0;
  const tripKind = ['booked', 'changed', 'extended', 'cancelled'].includes(p.kind);
  const aiOk = keys.enabled && keys.ai_ok && p.fromTuro;
  // the model helps with a Turo email the rules could not finish (or could not classify), within the day's neurons
  if (aiOk && (p.missing.some((x) => x !== 'car') || p.kind === 'other') && (tripKind || p.kind === 'other')) {
    const { textGenerator } = await import('@/integrations/llm');
    const gen = await textGenerator(undefined, 20_000);
    if (gen.name === 'workers-ai') {
      const a = await gen.generate<AiAnswer>({ task: 'turo_email', system: AI_SYSTEM, prompt: aiPrompt(m), schema: AI_SCHEMA, maxOutputTokens: 200, temperature: 0 });
      if (a.ok) {
        neurons += a.usage.neurons ?? 0;
        const merged = mergeAi(p, a.data, m, cars);
        if (merged.kind !== p.kind || merged.missing.length < p.missing.length) { p = merged; method = 'ai'; }
      }
    }
  }
  // still two or more cars: the model picks one of the short list, or says it is unsure (then "Which car is this?")
  if (aiOk && !p.vehicleId && ['booked', 'changed', 'extended'].includes(p.kind) && p.candidates.length >= 2) {
    const r = await aiPickCar(p, m.subject, cars, p.candidates);
    neurons += r.neurons;
    if (r.id) {
      const c = p.candidates.find((x) => x.vehicle_id === r.id)!;
      p = { ...p, vehicleId: r.id, vehicleHint: c.name, vehicleWhy: `picked by the assistant between ${p.candidates.length} cars`, matchHow: 'ai', missing: p.missing.filter((x) => x !== 'car') };
      method = 'ai';
    }
  }
  const r = await rpc('turo_email_receive', { p: {
    ...base, from_turo: p.fromTuro, kind: p.kind, trip_id: p.tripId, vehicle_id: p.vehicleId, starts_at: p.start, ends_at: p.end,
    guest_first_name: p.guestFirstName, guest_name: p.guestName, guest_phone: p.guestPhone, guest_email: p.guestEmail,
    vehicle_hint: p.vehicleHint, car_name: p.carName, turo_car_ids: p.turoCarIds, candidates: guesses(p.candidates), match_why: p.vehicleWhy?.slice(0, 300) ?? null,
    missing: p.missing, method, neurons,
    // a short excerpt without addresses, phone numbers or links: the database keeps it only for an email someone must check
    excerpt: p.kind !== 'other' ? redact(m.text) : null
  } }, SR);
  return NextResponse.json({ ok: true, ...(r as Record<string, unknown>) });
}
