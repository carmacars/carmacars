import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { TWILIO_API, bridgeTwiml, callToken, hangupTwiml, recordingKey, recordingReady, recordingUrls, startCallForm, twilioReady, verifyCallToken, verifyTwilioSignature } from '@/features/phone/twilio';

// The site's outbound Call button (release 35, migration 0970): the server rings the signed-in staff member's own cell
// (their profile phone) through Twilio, and when they answer bridges the customer with the CarmaCars number as caller ID.
// The database checks the person, keeps the call and logs it on the person's history with its length and outcome.
const SR = { role: 'service_role' as const };

function cfg() {
  const e = env();
  return { accountSid: e.TWILIO_ACCOUNT_SID, apiKey: e.TWILIO_API_KEY, apiSecret: e.TWILIO_API_SECRET, callerId: e.TWILIO_CALLER_ID, authToken: e.TWILIO_AUTH_TOKEN,
    base: e.NEXT_PUBLIC_APP_URL.replace(/\/$/, '') };
}

export function twilioState(): { ready: true } | { ready: false; why: string } {
  return twilioReady(cfg());
}

export type StartResult = { ok: true; who: string; calling: string } | { ok: false; fallback: 'quo' | null; message: string };

/** Starts a call for this staff member to this number (E.164). */
export async function startStaffCall(userId: string, number: string, bookingNumber?: string | null): Promise<StartResult> {
  const c = cfg();
  const r = twilioReady(c);
  if (!r.ready) return { ok: false, fallback: 'quo', message: r.why };
  let call: { id: string; staff_number: string; caller_id: string | null; who: string };
  try {
    call = (await rpc('server_twilio_call_start', { p: { user_id: userId, number, booking_number: bookingNumber ?? null } as unknown as Json }, SR)) as unknown as typeof call;
  } catch (e) {
    return { ok: false, fallback: null, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '').slice(0, 200) : 'The call could not start' };
  }
  const callerId = c.callerId || call.caller_id;
  if (!callerId) return { ok: false, fallback: 'quo', message: 'The CarmaCars number is not set (Site settings, Phone).' };
  const t = await callToken(c.apiSecret!, call.id);
  const q = `id=${encodeURIComponent(call.id)}&t=${t}`;
  const form = startCallForm({ staffNumber: call.staff_number, callerId, voiceUrl: `${c.base}/api/webhooks/twilio/voice?${q}`, statusUrl: `${c.base}/api/webhooks/twilio/status?${q}` });
  let res: Response;
  try {
    res = await fetch(`${TWILIO_API}/Accounts/${encodeURIComponent(c.accountSid!)}/Calls.json`, {
      method: 'POST', body: form, signal: AbortSignal.timeout(10_000),
      headers: { authorization: `Basic ${btoa(`${c.apiKey}:${c.apiSecret}`)}`, 'content-type': 'application/x-www-form-urlencoded' } });
  } catch {
    await event({ id: call.id, kind: 'failed_to_start', error: 'Twilio did not answer in time' });
    return { ok: false, fallback: 'quo', message: 'The phone service did not answer in time. Try again, or call from Quo.' };
  }
  const j = (await res.json().catch(() => ({}))) as { sid?: string; message?: string };
  if (!res.ok || !j.sid) {
    await event({ id: call.id, kind: 'failed_to_start', error: (j.message ?? `status ${res.status}`).slice(0, 200) });
    return { ok: false, fallback: 'quo', message: `The call did not start: ${(j.message ?? `the phone service answered ${res.status}`).slice(0, 160)}` };
  }
  await event({ id: call.id, kind: 'started', call_sid: j.sid });
  return { ok: true, who: call.who, calling: call.staff_number.slice(0, -4).replace(/[0-9]/g, '•') + call.staff_number.slice(-4) };
}

async function event(p: Record<string, unknown>) {
  return rpc('server_twilio_call_event', { p: p as unknown as Json }, SR).catch(() => null);
}

const xmlResponse = (body: string, status = 200) => new Response(body, { status, headers: { 'content-type': 'text/xml; charset=utf-8', 'cache-control': 'no-store' } });

/** A webhook from Twilio: our token, then (with the Auth Token set) Twilio's signature. */
async function checked(req: Request): Promise<{ id: string; params: Record<string, string> } | null> {
  const c = cfg();
  const u = new URL(req.url);
  const id = u.searchParams.get('id');
  if (!(await verifyCallToken(c.apiSecret, id, u.searchParams.get('t')))) return null;
  const raw = await req.text();
  if (raw.length > 20_000) return null;
  const params = Object.fromEntries(new URLSearchParams(raw));
  if (c.authToken) {
    const url = `${c.base}${u.pathname}${u.search}`;
    if (!(await verifyTwilioSignature(c.authToken, url, params, req.headers.get('x-twilio-signature')))) return null;
  }
  return { id: id!, params };
}

/** The staff member answered: the TwiML that connects the customer. */
export async function voiceWebhook(req: Request): Promise<Response> {
  const w = await checked(req);
  if (!w) return xmlResponse(hangupTwiml(), 403);
  const c = cfg();
  const call = (await rpc('server_twilio_call_get', { p_id: w.id }, SR).catch(() => null)) as unknown as { to: string; caller_id: string | null; record?: boolean } | null;
  const callerId = c.callerId || call?.caller_id;
  if (!call?.to || !callerId) return xmlResponse(hangupTwiml('This call can no longer be connected.'));
  await event({ id: w.id, kind: 'staff_answered', call_sid: w.params.CallSid });
  const t = await callToken(c.apiSecret!, w.id);
  const q = `id=${encodeURIComponent(w.id)}&t=${t}`;
  // 1880: recorded unless Program settings turn it off (phone_twilio_record); no caller notice (the owner's decision, as Quo)
  return xmlResponse(bridgeTwiml({ to: call.to, callerId, actionUrl: `${c.base}/api/webhooks/twilio/dial?${q}`, say: 'CarmaCars call. Connecting you now.',
    recordingUrl: call.record === false ? null : `${c.base}/api/webhooks/twilio/recording?${q}` }));
}

/** The customer leg ended (the Dial's action): its status and length. */
export async function dialWebhook(req: Request): Promise<Response> {
  const w = await checked(req);
  if (!w) return xmlResponse(hangupTwiml(), 403);
  await event({ id: w.id, kind: 'dial', status: w.params.DialCallStatus ?? '', duration: w.params.DialCallDuration ?? '0' });
  return xmlResponse(hangupTwiml());
}

/** The staff leg's status (initiated, answered, completed and the end states). */
export async function statusWebhook(req: Request): Promise<Response> {
  const w = await checked(req);
  if (!w) return new Response('forbidden', { status: 403 });
  const s = (w.params.CallStatus ?? '').toLowerCase();
  if (['completed', 'busy', 'no-answer', 'failed', 'canceled'].includes(s)) await event({ id: w.id, kind: 'staff', status: s, duration: w.params.CallDuration ?? '0', call_sid: w.params.CallSid });
  return new Response(null, { status: 204 });
}

const basic = (c: ReturnType<typeof cfg>) => `Basic ${btoa(`${c.apiKey}:${c.apiSecret}`)}`;

/** 1880: the customer leg's recording is ready. Copy the audio to our private storage, keep the key on the call, then
 *  delete it at Twilio (Program setting phone_twilio_delete_recording, on by default) so it is not kept twice. A copy
 *  that fails answers 500 so Twilio tries the callback again; the recording stays at Twilio until we have it. */
export async function recordingWebhook(req: Request): Promise<Response> {
  const w = await checked(req);
  if (!w) return new Response('forbidden', { status: 403 });
  const r = recordingReady(w.params);
  if (!r) return new Response(null, { status: 204 });
  const c = cfg();
  const urls = recordingUrls(c.accountSid!, r.sid);
  const key = recordingKey(w.id);
  let audio: Uint8Array;
  try {
    const res = await fetch(urls.audio, { headers: { authorization: basic(c) }, signal: AbortSignal.timeout(20_000) });
    if (!res.ok) throw new Error(`Twilio answered ${res.status}`);
    audio = new Uint8Array(await res.arrayBuffer());
    if (!audio.byteLength || audio.byteLength > 50_000_000) throw new Error('The recording is empty or too large');
    const { storage } = await import('@/integrations/storage');
    await (await storage()).put('documents', key, audio, 'audio/mpeg');
  } catch (e) {
    await rpc('server_twilio_recording', { p: { id: w.id, recording_sid: r.sid, seconds: r.seconds, error: e instanceof Error ? e.message.slice(0, 200) : 'copy failed' } as unknown as Json }, SR).catch(() => null);
    return new Response('copy failed', { status: 500 });
  }
  const saved = (await rpc('server_twilio_recording', { p: { id: w.id, recording_sid: r.sid, key, seconds: r.seconds } as unknown as Json }, SR)) as unknown as { ok?: boolean; delete?: boolean } | null;
  if (saved?.ok && saved.delete) {
    await fetch(urls.resource, { method: 'DELETE', headers: { authorization: basic(c) }, signal: AbortSignal.timeout(10_000) }).catch(() => null);
  }
  return new Response(null, { status: 204 });
}

/** 1880: the stored recordings due for speech to text (Workers AI Whisper, background tier, free allowance only; the
 *  database moves them to the next day when the share is used). The summary and the intent follow in the database. */
export async function runCallTranscripts(limit = 2): Promise<Record<string, unknown>> {
  const due = (await rpc('server_twilio_transcribe_due', { p_limit: limit }, SR)) as unknown as { items: Array<{ id: string; key: string; seconds: number }>; waiting: boolean; message?: string } | null;
  if (!due?.items?.length) return { transcribed: 0, waiting: !!due?.waiting };
  const [{ transcriber }, { storage }] = await Promise.all([import('@/integrations/transcribe'), import('@/integrations/storage')]);
  const t = await transcriber('call_transcribe');
  const st = await storage();
  let n = 0;
  for (const it of due.items) {
    const t0 = Date.now();
    const audio = await st.get('documents', it.key).catch(() => null);
    const r = audio
      ? await t.transcribe({ audio, type: 'audio/mpeg', seconds: it.seconds })
      : { ok: false as const, reason: 'unavailable' as const, message: 'The recording is missing from storage', neurons: 0 };
    await rpc('server_twilio_transcript', { p: { id: it.id, ok: r.ok, text: r.ok ? r.text : '', neurons: r.neurons ?? 0, error: r.ok ? null : r.message,
      reason: r.ok ? null : r.reason, duration_ms: Date.now() - t0 } as unknown as Json }, SR);
    if (r.ok) n++;
    if (!r.ok && r.reason === 'quota') break;
  }
  return { transcribed: n, of: due.items.length };
}
