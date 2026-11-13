import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { TWILIO_API, bridgeTwiml, callToken, hangupTwiml, identityUser, noAnswerTwiml, recordingKey, recordingReady, recordingUrls, ringBrowsersTwiml, signedUrlCandidates,
  staffIdentity, startCallForm, toE164, twilioReady, verifyCallToken, verifyTwilioSignature, voiceAccessToken } from '@/features/phone/twilio';

// The site's outbound Call button (release 35, migration 0970): the server rings the signed-in staff member's own cell
// (their profile phone) through Twilio, and when they answer bridges the customer with the CarmaCars number as caller ID.
// The database checks the person, keeps the call and logs it on the person's history with its length and outcome.
const SR = { role: 'service_role' as const };

// r44 (2790): every value trimmed (a pasted secret often ends with a newline); the caller ID in E.164 whatever form it was
// typed in, so the TwiML never fails on "289-555-0123"
function cfg() {
  const e = env();
  const t = (v: string | undefined) => v?.trim() || undefined;
  const callerRaw = t(e.TWILIO_CALLER_ID);
  return { accountSid: t(e.TWILIO_ACCOUNT_SID), apiKey: t(e.TWILIO_API_KEY), apiSecret: t(e.TWILIO_API_SECRET), callerId: callerRaw ? (toE164(callerRaw) ?? callerRaw) : undefined,
    authToken: t(e.TWILIO_AUTH_TOKEN), appSid: t(e.TWILIO_TWIML_APP_SID), base: e.NEXT_PUBLIC_APP_URL.replace(/\/$/, '') };
}
const ourCallerId = (c: ReturnType<typeof cfg>, fromDb: string | null | undefined) => c.callerId || toE164(fromDb) || null;

export function twilioState(): { ready: true } | { ready: false; why: string } {
  return twilioReady(cfg());
}

export type StartResult = { ok: true; who: string; calling: string } | { ok: false; fallback: 'quo' | null; message: string; need_phone?: boolean };

/** Starts a call for this staff member to this number (E.164). */
export async function startStaffCall(userId: string, number: string, bookingNumber?: string | null): Promise<StartResult> {
  const c = cfg();
  const r = twilioReady(c);
  if (!r.ready) return { ok: false, fallback: 'quo', message: r.why };
  // r44 (2790): ringing the staff member's own mobile first is off by default (staff abroad have international numbers):
  // calls are placed in the browser
  if (!(await voiceSettings()).own_mobile) return { ok: false, fallback: null, message: 'Calls are made in your browser: reload the page and press Call again.' };
  let call: { id: string; staff_number: string; caller_id: string | null; who: string; ok?: boolean; need_phone?: boolean; message?: string };
  try {
    call = (await rpc('server_twilio_call_start', { p: { user_id: userId, number, booking_number: bookingNumber ?? null } as unknown as Json }, SR)) as unknown as typeof call;
  } catch (e) {
    return { ok: false, fallback: null, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '').slice(0, 200) : 'The call could not start' };
  }
  // 2460: no mobile of their own on file: the Call button asks for it, saves it and calls again
  if (call?.need_phone) return { ok: false, fallback: null, need_phone: true, message: call.message ?? 'Add your mobile number first: the call rings your phone, then connects the customer.' };
  if (!call?.id || !call.staff_number) return { ok: false, fallback: null, message: 'The call could not start. Try again in a moment.' };
  const callerId = ourCallerId(c, call.caller_id);
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
    // r40: say what to do (a wrong mobile on the profile, or the Twilio account: keys, caller ID, calling permissions)
    return { ok: false, fallback: 'quo', message: `The call did not start: ${(j.message ?? `the phone service answered ${res.status}`).slice(0, 160)}. Check your mobile number on your profile; if it is right, ask an Admin to check the Twilio account.` };
  }
  await event({ id: call.id, kind: 'started', call_sid: j.sid });
  return { ok: true, who: call.who, calling: call.staff_number.slice(0, -4).replace(/[0-9]/g, '•') + call.staff_number.slice(-4) };
}

async function event(p: Record<string, unknown>) {
  return rpc('server_twilio_call_event', { p: p as unknown as Json }, SR).catch(() => null);
}

const xmlResponse = (body: string, status = 200) => new Response(body, { status, headers: { 'content-type': 'text/xml; charset=utf-8', 'cache-control': 'no-store' } });

/** Twilio's signature on a webhook, against the address we gave Twilio (and the host the request came to). Fail closed:
 *  no Auth Token, no header or no match is refused. Cloudflare ends TLS in front of the Worker, so the address is rebuilt
 *  from the site's own https address, never trusted from req.url as it arrives. */
async function signed(req: Request, params: Record<string, string>): Promise<boolean> {
  const c = cfg();
  const sig = req.headers.get('x-twilio-signature');
  if (!c.authToken || !sig) return false;
  for (const url of signedUrlCandidates(c.base, req.url, req.headers.get('x-forwarded-host') ?? req.headers.get('host'))) {
    if (await verifyTwilioSignature(c.authToken, url, params, sig)) return true;
  }
  return false;
}
async function formOf(req: Request): Promise<Record<string, string> | null> {
  const raw = await req.text();
  if (raw.length > 20_000) return null;
  return Object.fromEntries(new URLSearchParams(raw));
}

/** A webhook of one call we started: our token, then Twilio's signature (both always). */
async function checked(req: Request): Promise<{ id: string; params: Record<string, string> } | null> {
  const c = cfg();
  const u = new URL(req.url);
  const id = u.searchParams.get('id');
  if (!(await verifyCallToken(c.apiSecret, id, u.searchParams.get('t')))) return null;
  const params = await formOf(req);
  if (!params || !(await signed(req, params))) return null;
  return { id: id!, params };
}

/** The staff member answered: the TwiML that connects the customer. */
export async function voiceWebhook(req: Request): Promise<Response> {
  const w = await checked(req);
  if (!w) return xmlResponse(hangupTwiml(), 403);
  const c = cfg();
  const call = (await rpc('server_twilio_call_get', { p_id: w.id }, SR).catch(() => null)) as unknown as { to: string; caller_id: string | null; record?: boolean } | null;
  const callerId = ourCallerId(c, call?.caller_id);
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

// ================================================================ r44 (2790): calls in the browser
// Staff place and take calls in the browser (Twilio's Voice SDK) with the CarmaCars number as caller ID. Sales staff abroad
// never use their own international number: the "ring my mobile" way (above) is used only when Program settings turn it on
// (phone_call_own_mobile, off by default). The database decides who may call, who rings, and logs every call.

export type VoiceSettings = { calls: boolean; inbound: boolean; own_mobile: boolean; seconds: number; forward_to: string | null; message: string | null };
const VOICE_OFF: VoiceSettings = { calls: false, inbound: false, own_mobile: false, seconds: 25, forward_to: null, message: null };

/** Program settings of calls (2790): in the browser, incoming calls ring the browser, the old "ring my mobile" way. */
export async function voiceSettings(): Promise<VoiceSettings> {
  return ((await rpc('server_voice_settings', {}, SR).catch(() => null)) as unknown as VoiceSettings | null) ?? VOICE_OFF;
}

const APP_NAME = 'CarmaCars browser calls';
let appCache: { sid: string; at: number } | null = null;
let numberChecked = 0;

/** The TwiML App that browser calls go through: TWILIO_TWIML_APP_SID, or the app of that name in the account, made when
 *  missing and pointed at our client webhook when it points elsewhere (one look-up per server instance every 6 hours).
 *  The business number, when it is a Twilio number with no Voice URL of its own (or Twilio's demo), is pointed at our
 *  incoming webhook, so incoming calls ring the browser with no step in Twilio's console. */
async function twimlApp(c: ReturnType<typeof cfg>): Promise<string | null> {
  if (c.appSid) return c.appSid;
  if (appCache && Date.now() - appCache.at < 6 * 3600_000) return appCache.sid;
  const auth = { authorization: basic(c) };
  const acct = `${TWILIO_API}/Accounts/${encodeURIComponent(c.accountSid!)}`;
  const voiceUrl = `${c.base}/api/webhooks/twilio/client`;
  try {
    const list = (await (await fetch(`${acct}/Applications.json?FriendlyName=${encodeURIComponent(APP_NAME)}`, { headers: auth, signal: AbortSignal.timeout(8_000) })).json()) as { applications?: Array<{ sid: string; voice_url: string | null }> };
    let app = list.applications?.[0] ?? null;
    if (!app || app.voice_url !== voiceUrl) {
      const f = new URLSearchParams({ FriendlyName: APP_NAME, VoiceUrl: voiceUrl, VoiceMethod: 'POST' });
      const res = await fetch(app ? `${acct}/Applications/${encodeURIComponent(app.sid)}.json` : `${acct}/Applications.json`, { method: 'POST', body: f, headers: { ...auth, 'content-type': 'application/x-www-form-urlencoded' }, signal: AbortSignal.timeout(8_000) });
      const j = (await res.json().catch(() => ({}))) as { sid?: string };
      if (!res.ok || !j.sid) return null;
      app = { sid: j.sid, voice_url: voiceUrl };
    }
    appCache = { sid: app.sid, at: Date.now() };
    if (Date.now() - numberChecked > 6 * 3600_000) { numberChecked = Date.now(); await pointNumber(c, auth, acct).catch(() => undefined); }
    return app.sid;
  } catch { return null; }
}
async function pointNumber(c: ReturnType<typeof cfg>, auth: Record<string, string>, acct: string) {
  const num = c.callerId ?? toE164((await voiceCallerId()) ?? '');
  if (!num) return;
  const j = (await (await fetch(`${acct}/IncomingPhoneNumbers.json?PhoneNumber=${encodeURIComponent(num)}`, { headers: auth, signal: AbortSignal.timeout(8_000) })).json()) as { incoming_phone_numbers?: Array<{ sid: string; voice_url: string | null; voice_application_sid: string | null }> };
  const n = j.incoming_phone_numbers?.[0];
  if (!n || n.voice_application_sid || (n.voice_url && !/demo\.twilio\.com/i.test(n.voice_url))) return;
  await fetch(`${acct}/IncomingPhoneNumbers/${encodeURIComponent(n.sid)}.json`, { method: 'POST', headers: { ...auth, 'content-type': 'application/x-www-form-urlencoded' }, signal: AbortSignal.timeout(8_000),
    body: new URLSearchParams({ VoiceUrl: `${c.base}/api/webhooks/twilio/incoming`, VoiceMethod: 'POST' }) });
}
async function voiceCallerId(): Promise<string | null> {
  return ((await rpc('server_voice_settings', {}, SR).catch(() => null)) as unknown as { caller_id?: string | null } | null)?.caller_id ?? null;
}

export type TokenResult = { ok: true; token: string; ring: boolean; ttl: number } | { ok: false; message: string };

/** A Voice SDK token for this staff member (an hour; the browser renews it before it ends). The database checks the person
 *  and says whether incoming calls ring them; it also marks them online (presence) for incoming calls. */
export async function voiceToken(userId: string): Promise<TokenResult> {
  const c = cfg();
  const r = twilioReady(c);
  if (!r.ready) return { ok: false, message: r.why };
  let p: { ok?: boolean; ring?: boolean; calls?: boolean; message?: string } | null;
  try { p = (await rpc('server_voice_presence', { p_user: userId, p: { online: true } as unknown as Json }, SR)) as unknown as typeof p; }
  catch (e) { return { ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '').slice(0, 200) : 'Not permitted' }; }
  if (!p?.calls) return { ok: false, message: p?.message ?? 'Calls in the browser are off (Program settings, Calls in the browser).' };
  const app = await twimlApp(c);
  if (!app) return { ok: false, message: 'The phone service did not accept the API key (Twilio). Ask an Admin to check the Twilio account.' };
  const ttl = 3600;
  return { ok: true, ring: !!p.ring, ttl, token: await voiceAccessToken({ accountSid: c.accountSid!, apiKey: c.apiKey!, apiSecret: c.apiSecret!, appSid: app, identity: staffIdentity(userId), ring: !!p.ring, ttlSeconds: ttl }) };
}

/** The browser says it is still online (every minute while the page is open) or that it closed. */
export async function voicePresence(userId: string, online: boolean): Promise<{ ok: boolean; ring?: boolean }> {
  return ((await rpc('server_voice_presence', { p_user: userId, p: { online } as unknown as Json }, SR).catch(() => null)) as unknown as { ok: boolean; ring?: boolean } | null) ?? { ok: false };
}

export type BrowserStart = { ok: true; id: string; t: string; who: string } | { ok: false; message: string };

/** A call from the browser: the database checks the person and keeps the call; the browser gets only the call's id and
 *  our token for it (never the customer's number when it is masked for them), and Twilio asks our client webhook. */
export async function startBrowserCall(userId: string, number: string, bookingNumber?: string | null): Promise<BrowserStart> {
  const c = cfg();
  const r = twilioReady(c);
  if (!r.ready) return { ok: false, message: r.why };
  try {
    const call = (await rpc('server_twilio_browser_call_start', { p: { user_id: userId, number, booking_number: bookingNumber ?? null } as unknown as Json }, SR)) as unknown as { id: string; who: string };
    return { ok: true, id: call.id, t: await callToken(c.apiSecret!, call.id), who: call.who };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '').slice(0, 200) : 'The call could not start' };
  }
}

/** The TwiML App's Voice URL: a browser placed a call. Twilio's signature, our token for the call, and the browser's
 *  identity must be the staff member who started it; then the customer is dialled with the CarmaCars number. */
export async function clientWebhook(req: Request): Promise<Response> {
  const params = await formOf(req);
  if (!params || !(await signed(req, params))) return xmlResponse(hangupTwiml(), 403);
  const c = cfg();
  const id = params.call ?? null;
  const user = identityUser(params.From ?? params.Caller);
  if (!user || !(await verifyCallToken(c.apiSecret, id, params.t ?? null))) return xmlResponse(hangupTwiml('This call can no longer be connected.'));
  const call = (await rpc('server_twilio_browser_call_get', { p_id: id!, p_user: user }, SR).catch(() => null)) as unknown as { to: string; caller_id: string | null; record?: boolean } | null;
  const callerId = ourCallerId(c, call?.caller_id);
  if (!call?.to || !callerId) return xmlResponse(hangupTwiml('This call can no longer be connected.'));
  await event({ id: id!, kind: 'staff_answered', call_sid: params.CallSid });
  const q = `id=${encodeURIComponent(id!)}&t=${await callToken(c.apiSecret!, id!)}`;
  return xmlResponse(bridgeTwiml({ to: call.to, callerId, actionUrl: `${c.base}/api/webhooks/twilio/dial?${q}`,
    recordingUrl: call.record === false ? null : `${c.base}/api/webhooks/twilio/recording?${q}` }));
}

async function logIncoming(params: Record<string, string>, type: 'call.ringing' | 'call.completed' | 'call.missed', extra: Record<string, unknown> = {}) {
  const sid = params.CallSid ?? '';
  if (!/^CA[0-9a-f]{32}$/i.test(sid)) return null;
  const r = (await rpc('server_phone_event', { p: { event_id: `twilio:${sid}:${type}`, type, call_id: sid, quo_id: sid, direction: 'in', their_number: params.From ?? null,
    status: type.slice(5), at: new Date().toISOString(), missed: type === 'call.missed', ...extra } as unknown as Json }, SR).catch(() => null)) as unknown as { send?: Array<{ id: string; to: string; body: string }> } | null;
  if (r?.send?.length) { const { sendTexts } = await import('@/server/phone'); await sendTexts(r.send).catch(() => undefined); }
  return r;
}

/** The business number's Voice URL (a Twilio number): the browsers of the staff online ring; nobody online, the no-answer
 *  way at once. The call is on the caller's history (and the caller pop-up) as every call to the CarmaCars number. */
export async function incomingWebhook(req: Request): Promise<Response> {
  const params = await formOf(req);
  if (!params || !(await signed(req, params))) return xmlResponse(hangupTwiml(), 403);
  const c = cfg();
  const ring = (await rpc('server_voice_ring', { p: { from: params.From ?? null } as unknown as Json }, SR).catch(() => null)) as unknown as
    { enabled?: boolean; ring?: Array<{ identity: string; who: string }>; seconds?: number; forward_to?: string | null; message?: string | null; caller_id?: string | null } | null;
  await logIncoming(params, 'call.ringing');
  if (!ring?.enabled || !ring.ring?.length) {
    await logIncoming(params, 'call.missed', { completed_at: new Date().toISOString(), duration: 0 });
    return xmlResponse(noAnswerTwiml({ forwardTo: toE164(ring?.forward_to), callerId: params.From ?? null, message: ring?.message, timeoutSeconds: ring?.seconds }));
  }
  return xmlResponse(ringBrowsersTwiml({ ring: ring.ring, callerId: ourCallerId(c, ring.caller_id), actionUrl: `${c.base}/api/webhooks/twilio/ring-end`, timeoutSeconds: ring.seconds }));
}

/** The ring ended: answered in a browser (logged with its length), or nobody answered (a missed call, then the no-answer way). */
export async function ringEndWebhook(req: Request): Promise<Response> {
  const params = await formOf(req);
  if (!params || !(await signed(req, params))) return xmlResponse(hangupTwiml(), 403);
  const s = (params.DialCallStatus ?? '').toLowerCase();
  if (s === 'completed' || s === 'answered') {
    await logIncoming(params, 'call.completed', { completed_at: new Date().toISOString(), duration: Number(params.DialCallDuration ?? '0') || 0 });
    return xmlResponse(hangupTwiml());
  }
  await logIncoming(params, 'call.missed', { completed_at: new Date().toISOString(), duration: 0 });
  const v = await voiceSettings();
  return xmlResponse(noAnswerTwiml({ forwardTo: toE164(v.forward_to), callerId: params.From ?? null, message: v.message, timeoutSeconds: v.seconds }));
}
