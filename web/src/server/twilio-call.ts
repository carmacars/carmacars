import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { TWILIO_API, accountProblem, answeredBy, appUrlProblem, balanceProblem, bridgeTwiml, callRecordingsUrl, callToken, callerIdProblem, hangupTwiml, identityUser, noAnswerTwiml, pickRecording,
  recordingKey, recordingReady, recordingUrls, ringBrowsersTwiml, signedUrlCandidates, staffIdentity, startCallForm, testCallToken, testCallTwiml, toE164, twilioReady, verifyCallToken,
  verifyTestCallToken, verifyTwilioSignature, voiceAccessToken, type CheckStep } from '@/features/phone/twilio';

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
/** R51 (5301): the same values for the staff lines (web/src/server/staff-lines.ts). */
export const twilioConfig = cfg;
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
  return (await keepOutbound(w.id, r)) ? new Response(null, { status: 204 }) : new Response('copy failed', { status: 500 });
}

/** The audio of a recording, copied to our private storage at key. Null when it is copied; else why not. */
async function copyRecording(c: ReturnType<typeof cfg>, sid: string, key: string): Promise<string | null> {
  try {
    const res = await fetch(recordingUrls(c.accountSid!, sid).audio, { headers: { authorization: basic(c) }, signal: AbortSignal.timeout(20_000) });
    if (!res.ok) throw new Error(`Twilio answered ${res.status}`);
    const audio = new Uint8Array(await res.arrayBuffer());
    if (!audio.byteLength || audio.byteLength > 50_000_000) throw new Error('The recording is empty or too large');
    const { storage } = await import('@/integrations/storage');
    await (await storage()).put('documents', key, audio, 'audio/mpeg');
    return null;
  } catch (e) { return e instanceof Error ? e.message.slice(0, 200) : 'copy failed'; }
}
async function deleteAtTwilio(c: ReturnType<typeof cfg>, sid: string) {
  await fetch(recordingUrls(c.accountSid!, sid).resource, { method: 'DELETE', headers: { authorization: basic(c) }, signal: AbortSignal.timeout(10_000) }).catch(() => null);
}
/** A call placed from the site: its recording copied and kept on the call (true), or the failure kept (false). */
async function keepOutbound(id: string, r: { sid: string; seconds: number }): Promise<boolean> {
  const c = cfg();
  const key = recordingKey(id);
  const err = await copyRecording(c, r.sid, key);
  if (err) {
    await rpc('server_twilio_recording', { p: { id, recording_sid: r.sid, seconds: r.seconds, error: err } as unknown as Json }, SR).catch(() => null);
    return false;
  }
  const saved = (await rpc('server_twilio_recording', { p: { id, recording_sid: r.sid, key, seconds: r.seconds } as unknown as Json }, SR)) as unknown as { ok?: boolean; delete?: boolean } | null;
  if (saved?.ok && saved.delete) await deleteAtTwilio(c, r.sid);
  return !!saved?.ok;
}
/** r48 (2995): a call to the business number: its recording copied and kept on the call's history (by its CallSid). */
async function keepInbound(callSid: string, activityId: string, r: { sid: string; seconds: number }): Promise<boolean> {
  const c = cfg();
  const key = recordingKey(activityId);
  const err = await copyRecording(c, r.sid, key);
  const saved = (await rpc('server_twilio_inbound', { p: { kind: 'recording', call_sid: callSid, recording_sid: r.sid, seconds: r.seconds, ...(err ? { error: err } : { key }) } as unknown as Json }, SR)
    .catch(() => null)) as unknown as { ok?: boolean; delete?: boolean } | null;
  if (err) return false;
  if (saved?.ok && saved.delete) await deleteAtTwilio(c, r.sid);
  return !!saved?.ok;
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
let appWhy: string | null = null;

/** The TwiML App that browser calls go through: TWILIO_TWIML_APP_SID, or the app of that name in the account, made when
 *  missing. r48 CM: either way its Voice URL is checked (one look-up per server instance every 6 hours) and pointed at
 *  this site's client webhook when it points elsewhere (an old host, the Worker or the server), so a call never goes to a
 *  host that no longer answers. The business number, when it is a Twilio number with no Voice URL of its own (or Twilio's
 *  demo), is pointed at our incoming webhook. appWhy keeps the reason of a failure for the token's answer and Test call. */
async function twimlApp(c: ReturnType<typeof cfg>, force = false): Promise<string | null> {
  if (!force && appCache && Date.now() - appCache.at < 6 * 3600_000) return appCache.sid;
  const auth = { authorization: basic(c) };
  const acct = `${TWILIO_API}/Accounts/${encodeURIComponent(c.accountSid!)}`;
  const voiceUrl = `${c.base}/api/webhooks/twilio/client`;
  try {
    let app: { sid: string; voice_url: string | null } | null = null;
    if (c.appSid) {
      const res = await fetch(`${acct}/Applications/${encodeURIComponent(c.appSid)}.json`, { headers: auth, signal: AbortSignal.timeout(8_000) });
      const j = (await res.json().catch(() => ({}))) as { sid?: string; voice_url?: string | null; code?: number; message?: string };
      if (!res.ok || !j.sid) { appWhy = `Twilio answered ${res.status} for TWILIO_TWIML_APP_SID${j.message ? ` (${j.code ?? ''} ${j.message})` : ''}`; return appCache?.sid ?? c.appSid; }
      app = { sid: j.sid, voice_url: j.voice_url ?? null };
    } else {
      const res = await fetch(`${acct}/Applications.json?FriendlyName=${encodeURIComponent(APP_NAME)}`, { headers: auth, signal: AbortSignal.timeout(8_000) });
      const list = (await res.json().catch(() => ({}))) as { applications?: Array<{ sid: string; voice_url: string | null }>; code?: number; message?: string };
      if (!res.ok) { appWhy = `Twilio answered ${res.status}${list.message ? ` (${list.code ?? ''} ${list.message})` : ''}`; return null; }
      app = list.applications?.[0] ?? null;
    }
    if (!app || app.voice_url !== voiceUrl) {
      const f = new URLSearchParams({ FriendlyName: APP_NAME, VoiceUrl: voiceUrl, VoiceMethod: 'POST' });
      const res = await fetch(app ? `${acct}/Applications/${encodeURIComponent(app.sid)}.json` : `${acct}/Applications.json`, { method: 'POST', body: f, headers: { ...auth, 'content-type': 'application/x-www-form-urlencoded' }, signal: AbortSignal.timeout(8_000) });
      const j = (await res.json().catch(() => ({}))) as { sid?: string; code?: number; message?: string };
      if (!res.ok || !j.sid) { appWhy = `Twilio would not ${app ? 'update' : 'create'} the TwiML App (${res.status}${j.message ? `: ${j.message}` : ''})`; return app?.sid ?? null; }
      app = { sid: j.sid, voice_url: voiceUrl };
    }
    appWhy = null;
    appCache = { sid: app.sid, at: Date.now() };
    if (force || Date.now() - numberChecked > 6 * 3600_000) { numberChecked = Date.now(); await pointNumber(c, auth, acct).catch(() => undefined); }
    return app.sid;
  } catch (e) { appWhy = `Twilio did not answer (${e instanceof Error ? e.message.slice(0, 80) : 'network'})`; return appCache?.sid ?? c.appSid ?? null; }
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
  if (!app) return { ok: false, message: `The phone service is not ready (${appWhy ?? 'Twilio refused the API key'}). Ask an Admin to run Test call in Settings > Calls.` };
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
  // r48 CM: the Admin's test call (Settings > Calls): our test token for this person, then a short message; nobody is dialled
  if (params.test === '1') {
    return xmlResponse(user && (await verifyTestCallToken(c.apiSecret, user, params.t ?? null)) ? testCallTwiml() : hangupTwiml('This test call is not valid.'));
  }
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
  const ring = (await rpc('server_voice_ring', { p: { from: params.From ?? null, to: params.To ?? params.Called ?? null } as unknown as Json }, SR).catch(() => null)) as unknown as
    { enabled?: boolean; line?: boolean; ring?: Array<{ identity: string; who: string }>; seconds?: number; forward_to?: string | null; message?: string | null; caller_id?: string | null; record?: boolean } | null;
  await logIncoming(params, 'call.ringing');
  if (!ring?.enabled || !ring.ring?.length) {
    await logIncoming(params, 'call.missed', { completed_at: new Date().toISOString(), duration: 0 });
    // R51 (5301): a staff member's own line: that person hears of the missed call; never forwarded to anyone else
    if (ring?.line) { await lineMissed(params); return xmlResponse(hangupTwiml(ring.message ?? undefined)); }
    return xmlResponse(noAnswerTwiml({ forwardTo: toE164(ring?.forward_to), callerId: params.From ?? null, message: ring?.message, timeoutSeconds: ring?.seconds }));
  }
  // r48 (2995): recorded (Program setting phone_twilio_record) and the answered browser says who took it
  return xmlResponse(ringBrowsersTwiml({ ring: ring.ring, callerId: ourCallerId(c, ring.caller_id), actionUrl: `${c.base}/api/webhooks/twilio/ring-end`, timeoutSeconds: ring.seconds,
    answeredUrl: `${c.base}/api/webhooks/twilio/ring-answer`, recordingUrl: ring.record === false ? null : `${c.base}/api/webhooks/twilio/in-recording` }));
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
  // R51 (5301): a staff line nobody answered: its message, and that person hears of it
  const line = await lineMissed(params);
  if (line?.line) return xmlResponse(hangupTwiml(line.message ?? undefined));
  const v = await voiceSettings();
  return xmlResponse(noAnswerTwiml({ forwardTo: toE164(v.forward_to), callerId: params.From ?? null, message: v.message, timeoutSeconds: v.seconds }));
}

/** R51 (5301): a call to a staff line that nobody took: the alert to that person; { line: false } for the business number. */
async function lineMissed(params: Record<string, string>): Promise<{ line?: boolean; message?: string | null } | null> {
  const to = params.To ?? params.Called ?? null;
  if (!to) return null;
  return (await rpc('server_staff_line_missed', { p: { to, from: params.From ?? null, call_sid: params.CallSid ?? null } as unknown as Json }, SR).catch(() => null)) as unknown as { line?: boolean; message?: string | null } | null;
}

/** r48 (2995): a browser answered a call to the business number (the Client's answered callback): the call is answered
 *  now, by that staff member (the pop-up shows "On the phone now" at once, and the history names who took it). */
export async function ringAnswerWebhook(req: Request): Promise<Response> {
  const params = await formOf(req);
  if (!params || !(await signed(req, params))) return new Response('forbidden', { status: 403 });
  const a = answeredBy(params);
  if (a) await rpc('server_twilio_inbound', { p: { kind: 'answered', call_sid: a.parent, user_id: a.user } as unknown as Json }, SR).catch(() => null);
  return new Response(null, { status: 204 });
}

/** r48 (2995): the recording of a call to the business number is ready: copied to our private storage and kept on the
 *  call (a copy that fails answers 500 so Twilio tries again). */
export async function inRecordingWebhook(req: Request): Promise<Response> {
  const params = await formOf(req);
  if (!params || !(await signed(req, params))) return new Response('forbidden', { status: 403 });
  const r = recordingReady(params);
  if (!r) return new Response(null, { status: 204 });
  for (const sid of [params.CallSid, params.ParentCallSid]) {
    if (!sid || !/^CA[0-9a-f]{32}$/i.test(sid)) continue;
    const id = (await rpc('server_twilio_inbound_id', { p_call_sid: sid }, SR).catch(() => null)) as unknown as string | null;
    if (!id) continue;
    return (await keepInbound(sid, id, r)) ? new Response(null, { status: 204 }) : new Response('copy failed', { status: 500 });
  }
  return new Response(null, { status: 204 });
}

type BackfillDue = { twilio: Array<{ ref: string; kind: 'out' | 'in'; id: string; call_sid: string }>;
  quo: Array<{ ref: string; id: string; call_id: string; recording: boolean; transcript: boolean; summary: boolean }> };

/** r48 (2995): calls of the last 60 days whose recording, transcript or summary is missing, each looked up once: site
 *  calls at Twilio (the recording, then speech to text and the summary as for a new call), Quo calls at Quo (its
 *  recording, transcript and summary; ours when Quo has none). A few each run of the five-minute job. */
export async function runCallBackfill(limit = 3): Promise<Record<string, unknown>> {
  const due = (await rpc('server_call_backfill_due', { p_limit: limit }, SR).catch(() => null)) as unknown as BackfillDue | null;
  if (!due) return { checked: 0 };
  const c = cfg();
  const twilioOk = twilioReady(c).ready;
  let found = 0, checked = 0;
  const done = (p: Record<string, unknown>) => rpc('server_call_backfill_done', { p: p as unknown as Json }, SR).catch(() => null);
  for (const it of twilioOk ? due.twilio : []) {
    checked++;
    try {
      const res = await fetch(callRecordingsUrl(c.accountSid!, it.call_sid), { headers: { authorization: basic(c) }, signal: AbortSignal.timeout(10_000) });
      if (!res.ok) { await done({ ref: it.ref, result: `twilio ${res.status}` }); continue; }
      const r = pickRecording(await res.json().catch(() => null));
      if (!r) { await done({ ref: it.ref, result: 'no recording at twilio' }); continue; }
      const ok = it.kind === 'out' ? await keepOutbound(it.id, r) : await keepInbound(it.call_sid, it.id, r);
      if (ok) found++;
      await done({ ref: it.ref, result: ok ? 'recording copied' : 'copy failed' });
    } catch (e) { await done({ ref: it.ref, result: e instanceof Error ? e.message.slice(0, 150) : 'failed' }); }
  }
  const key = env().QUO_API_KEY?.trim();
  if (key && due.quo.length) {
    const { quoCallMedia } = await import('@/features/phone/quo-api');
    for (const it of due.quo) {
      checked++;
      try {
        const m = await quoCallMedia({ key }, it.call_id, { recording: it.recording, transcript: it.transcript, summary: it.summary });
        const any = m.recordings.length + m.transcript.length + m.summary.length > 0;
        if (any) found++;
        await done({ ref: it.ref, result: any ? 'found at quo' : 'nothing at quo', quo: m });
      } catch (e) { await done({ ref: it.ref, result: e instanceof Error ? e.message.slice(0, 150) : 'failed' }); }
    }
  }
  return { checked, found };
}

// ================================================================ r48 CM: Test call (Admin, Settings > Calls)
// Every step of a browser call, in order, each with what it found and, when it fails, what to press. The browser then
// places a real test call (Twilio's Voice SDK, our token, the TwiML App, our client webhook) that only plays a message.
export type SelfCheck = { ok: boolean; steps: CheckStep[]; test?: { token: string; t: string } };

export async function voiceSelfCheck(userId: string): Promise<SelfCheck> {
  const c = cfg();
  const steps: CheckStep[] = [];
  const done = (ok = steps.every((x) => x.ok)): SelfCheck => ({ ok, steps });
  const r = twilioReady(c);
  steps.push(r.ready ? { step: 'Keys on this server', ok: true, detail: `Account ${c.accountSid!.slice(0, 6)}..., API key ${c.apiKey!.slice(0, 6)}..., Auth Token set, caller ID ${c.callerId ?? '(Site settings)'}, app ${c.appSid ? 'set' : 'found by name'}.` }
    : { step: 'Keys on this server', ok: false, detail: r.why, fix: 'Add the missing Twilio values as repository secrets (TWILIO_ACCOUNT_SID, TWILIO_API_KEY, TWILIO_API_SECRET, TWILIO_AUTH_TOKEN, TWILIO_CALLER_ID); the next deploy puts them on the Worker and the server.' });
  if (!r.ready) return done(false);
  const auth = { authorization: basic(c) };
  const acct = `${TWILIO_API}/Accounts/${encodeURIComponent(c.accountSid!)}`;
  const get = async (url: string, headers: Record<string, string> = auth) => {
    try { const res = await fetch(url, { headers, signal: AbortSignal.timeout(8_000) }); return { status: res.status, j: (await res.json().catch(() => null)) as Record<string, unknown> | null }; }
    catch { return { status: 0, j: null }; }
  };
  const a = await get(`${acct}.json`);
  const ap = accountProblem(a.status, a.j as never);
  steps.push({ step: 'Twilio account', ...ap });
  if (!ap.ok && (a.status === 401 || a.status === 403 || a.status === 404 || a.status === 0)) return done(false);
  // the Auth Token signs every webhook: a wrong or rotated one makes this site refuse every call Twilio hands it
  const tokenAuth = { authorization: `Basic ${btoa(`${c.accountSid}:${c.authToken}`)}` };
  const at = await get(`${acct}.json`, tokenAuth);
  steps.push(at.status === 200 ? { step: 'Auth Token (webhook signatures)', ok: true, detail: 'The Auth Token is the account\'s current one.' }
    : { step: 'Auth Token (webhook signatures)', ok: false, detail: `Twilio refused the Auth Token (${at.status}): every webhook is refused as unsigned, so calls end at once.`,
        fix: 'Twilio Console > Account > API keys & tokens > Auth Tokens: copy the Primary token into the TWILIO_AUTH_TOKEN secret, then deploy.' });
  const b = await get(`${acct}/Balance.json`, tokenAuth);
  steps.push({ step: 'Balance', ...balanceProblem(b.status, b.j as never) });
  const app = await twimlApp(c, true);
  const want = `${c.base}/api/webhooks/twilio/client`;
  if (!app) steps.push({ step: 'TwiML App', ok: false, detail: appWhy ?? 'No TwiML App.', fix: 'Twilio Console > Voice > TwiML Apps: create one with Voice URL ' + want + ', and save its SID as TWILIO_TWIML_APP_SID.' });
  else {
    const x = await get(`${acct}/Applications/${encodeURIComponent(app)}.json`);
    steps.push({ step: 'TwiML App', ...appUrlProblem((x.j?.voice_url as string | null | undefined) ?? null, want) });
  }
  const callerId = ourCallerId(c, await voiceCallerId());
  const [owned, verified] = await Promise.all([get(`${acct}/IncomingPhoneNumbers.json?PageSize=50`), get(`${acct}/OutgoingCallerIds.json?PageSize=50`)]);
  const ownedList = ((owned.j?.incoming_phone_numbers as Array<{ phone_number: string }> | undefined) ?? []).map((n) => n.phone_number);
  const verifiedList = ((verified.j?.outgoing_caller_ids as Array<{ phone_number: string }> | undefined) ?? []).map((n) => n.phone_number);
  steps.push({ step: 'Caller ID', ...callerIdProblem(callerId, ownedList, verifiedList) });
  const v = await voiceSettings();
  steps.push(v.calls ? { step: 'Calls in the browser', ok: true, detail: 'On in Program settings.' }
    : { step: 'Calls in the browser', ok: false, detail: 'Off in Program settings.', fix: 'Settings > Program settings > Calls in the browser: on.' });
  // this site answers Twilio here: an unsigned request is refused (403), so the address is right and the route runs
  try {
    const res = await fetch(want, { method: 'POST', body: '', signal: AbortSignal.timeout(8_000) });
    steps.push(res.status === 403 ? { step: 'Webhook on this host', ok: true, detail: `${want} answers and checks Twilio's signature.` }
      : { step: 'Webhook on this host', ok: false, detail: `${want} answered ${res.status} (expected 403 without a signature).`, fix: 'The site address (NEXT_PUBLIC_APP_URL) must be the live host; check the DNS of carmacars.ca.' });
  } catch { steps.push({ step: 'Webhook on this host', ok: false, detail: `${want} did not answer from the server itself.`, fix: 'Check that carmacars.ca resolves and answers; a firewall may block the server calling itself (not a failure for Twilio by itself).' }); }
  const tok = await voiceToken(userId);
  if (!tok.ok) { steps.push({ step: 'Your call token', ok: false, detail: tok.message }); return done(false); }
  steps.push({ step: 'Your call token', ok: true, detail: 'Made for you (an hour).' });
  return { ok: steps.every((x) => x.ok), steps, test: { token: tok.token, t: await testCallToken(c.apiSecret!, userId) } };
}
