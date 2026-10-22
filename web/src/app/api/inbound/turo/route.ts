import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { jobAuthorized, turoGmailAuthorized } from '@/server/job-auth';
import { AI_SCHEMA, AI_SYSTEM, aiPrompt, gmailConfirmation, mergeAi, parseMime, parseTuroEmail, plainAddress, redact, type AiAnswer, type MatchCar } from '@/features/turo/email';

// Turo by email (migration 0063). The Worker's email handler (custom-worker.ts, Cloudflare Email Routing for
// trips@in.carmacars.ca) posts each raw message here with the jobs' bearer token and the envelope sender. The email is
// read in memory (web/src/features/turo/email.ts: rules first, Workers AI only for what the rules missed) and only the
// parsed fields go to the database (app.turo_email_receive). The message itself is never stored. The same route takes
// Turo emails from an Apps Script in rent@'s Gmail (scripts/turo-gmail.gs) with its own token (turoGmailAuthorized),
// which opens this route only.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };
const MAX = 1_000_000;

interface Keys { enabled: boolean; forwarders: string; ai_ok: boolean; cars: MatchCar[] }

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
  let p = parseTuroEmail(m, keys.cars ?? []);
  let method: 'rules' | 'ai' = 'rules';
  let neurons = 0;
  const tripKind = ['booked', 'changed', 'extended', 'cancelled'].includes(p.kind);
  // the model helps only with a Turo email the rules could not finish (or could not classify), within the day's neurons
  if (keys.enabled && keys.ai_ok && p.fromTuro && (p.missing.length > 0 || p.kind === 'other') && (tripKind || p.kind === 'other')) {
    const { textGenerator } = await import('@/integrations/llm');
    const gen = await textGenerator(undefined, 20_000);
    if (gen.name === 'workers-ai') {
      const a = await gen.generate<AiAnswer>({ task: 'turo_email', system: AI_SYSTEM, prompt: aiPrompt(m), schema: AI_SCHEMA, maxOutputTokens: 200, temperature: 0 });
      if (a.ok) {
        neurons = a.usage.neurons ?? 0;
        const merged = mergeAi(p, a.data, m, keys.cars ?? []);
        if (merged.kind !== p.kind || merged.missing.length < p.missing.length) { p = merged; method = 'ai'; }
      }
    }
  }
  const r = await rpc('turo_email_receive', { p: {
    ...base, from_turo: p.fromTuro, kind: p.kind, trip_id: p.tripId, vehicle_id: p.vehicleId, starts_at: p.start, ends_at: p.end,
    guest_first_name: p.guestFirstName, vehicle_hint: p.vehicleHint, missing: p.missing, method, neurons,
    // a short excerpt without addresses, phone numbers or links: the database keeps it only for an email someone must check
    excerpt: p.kind !== 'other' ? redact(m.text) : null
  } }, SR);
  return NextResponse.json({ ok: true, ...(r as Record<string, unknown>) });
}
