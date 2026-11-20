// The site's Call button through Twilio (release 35, migration 0970; the owner's decision of November 8: Quo keeps
// incoming calls, texts and AI answering; staff call out from the site). Release 44 (2790): calls are made and taken in the
// browser (Twilio's Voice SDK): staff abroad never use their own international number; the business number is the caller ID. No imports, so it runs in the Worker, in Node and
// in the unit tests (twilio.test.ts). Only Twilio's documented REST API and TwiML:
//   1. POST /2010-04-01/Accounts/{AccountSid}/Calls.json (Basic auth with an API key SID and its secret) calls the staff
//      member's own cell; From is the CarmaCars number (a Twilio verified caller ID); Url is our voice webhook.
//   2. When the staff member answers, the voice webhook returns TwiML: a short <Say> and a <Dial callerId> of the customer
//      with an action URL (the customer leg's DialCallStatus and DialCallDuration come back there).
//   3. The parent call's StatusCallback reports the staff leg (CallStatus, CallDuration).
// Webhooks are checked two ways: our own token in the URL (HMAC-SHA256 of the call id with a server secret), and, when the
// account's Auth Token is set, Twilio's X-Twilio-Signature (HMAC-SHA1 of the full URL followed by every POST parameter,
// sorted by name, each name then its value; base64).

const enc = new TextEncoder();

export const TWILIO_API = 'https://api.twilio.com/2010-04-01';

function bytesToB64(b: Uint8Array): string {
  let s = '';
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s);
}
function hex(b: Uint8Array): string {
  return Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
}
export function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
async function hmac(alg: 'SHA-1' | 'SHA-256', key: string, data: string): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey('raw', enc.encode(key) as BufferSource, { name: 'HMAC', hash: alg }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(data)));
}

/** Twilio's request signature: the URL, then each POST parameter (sorted by name) as name then value; HMAC-SHA1, base64. */
export async function twilioSignature(authToken: string, url: string, params: Record<string, string>): Promise<string> {
  const data = url + Object.keys(params).sort().map((k) => k + params[k]).join('');
  return bytesToB64(await hmac('SHA-1', authToken, data));
}

/** Checks X-Twilio-Signature. Fails closed without a token or a header. */
export async function verifyTwilioSignature(authToken: string | null | undefined, url: string, params: Record<string, string>, header: string | null | undefined): Promise<boolean> {
  if (!authToken || !header) return false;
  return sameText(await twilioSignature(authToken, url, params), header.trim());
}

/** Our own token for a call's webhooks: only the server that started the call can make it. */
export async function callToken(secret: string, callId: string): Promise<string> {
  return hex(await hmac('SHA-256', secret, `twilio-call:${callId}`)).slice(0, 40);
}
export async function verifyCallToken(secret: string | null | undefined, callId: string | null, token: string | null): Promise<boolean> {
  if (!secret || !callId || !token) return false;
  return sameText(await callToken(secret, callId), token);
}

const xml = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
const E164 = /^\+[1-9][0-9]{7,14}$/;

/** The TwiML when the staff member answers: a short message, then the customer with the CarmaCars number as caller ID. */
export function bridgeTwiml(o: { to: string; callerId: string; actionUrl: string; say?: string; timeoutSeconds?: number; recordingUrl?: string | null }): string {
  if (!E164.test(o.to)) throw new Error('The customer number is not in E.164 form');
  if (!E164.test(o.callerId)) throw new Error('The caller ID is not in E.164 form');
  const t = Math.max(5, Math.min(60, Math.round(o.timeoutSeconds ?? 30)));
  const say = o.say ? `<Say voice="alice" language="en-CA">${xml(o.say)}</Say>` : '';
  // 1880: the customer leg recorded from the answer, each side on its own channel; Twilio posts the finished recording to
  // our recording webhook (same token and signature as the other legs)
  const rec = o.recordingUrl ? ` record="record-from-answer-dual" recordingStatusCallback="${xml(o.recordingUrl)}" recordingStatusCallbackMethod="POST" recordingStatusCallbackEvent="completed"` : '';
  return `<?xml version="1.0" encoding="UTF-8"?><Response>${say}<Dial callerId="${xml(o.callerId)}" timeout="${t}" answerOnBridge="true" action="${xml(o.actionUrl)}" method="POST"${rec}><Number>${xml(o.to)}</Number></Dial></Response>`;
}

/** The TwiML that ends the call (after the customer leg, or when the call is not ours). */
export function hangupTwiml(say?: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?><Response>${say ? `<Say voice="alice" language="en-CA">${xml(say)}</Say>` : ''}<Hangup/></Response>`;
}

/** The form body of the REST call that rings the staff member's cell. */
export function startCallForm(o: { staffNumber: string; callerId: string; voiceUrl: string; statusUrl: string; timeoutSeconds?: number }): URLSearchParams {
  const f = new URLSearchParams();
  f.set('To', o.staffNumber);
  f.set('From', o.callerId);
  f.set('Url', o.voiceUrl);
  f.set('Method', 'POST');
  f.set('StatusCallback', o.statusUrl);
  f.set('StatusCallbackMethod', 'POST');
  f.append('StatusCallbackEvent', 'initiated');
  f.append('StatusCallbackEvent', 'answered');
  f.append('StatusCallbackEvent', 'completed');
  f.set('Timeout', String(Math.max(5, Math.min(60, Math.round(o.timeoutSeconds ?? 25)))));
  return f;
}

export interface TwilioConfig { accountSid?: string | null; apiKey?: string | null; apiSecret?: string | null; callerId?: string | null; authToken?: string | null }

/** Ready to call, or the reason it is not (the button then says why). r44: the Auth Token is required (every webhook is
 *  checked against Twilio's signature, fail closed); the account SID, the API key SID and the caller ID are checked for
 *  their form, so a value pasted in the wrong secret is named instead of failing at Twilio. */
export function twilioReady(c: TwilioConfig): { ready: true } | { ready: false; why: string } {
  const missing = [!c.accountSid && 'TWILIO_ACCOUNT_SID', !c.apiKey && 'TWILIO_API_KEY', !c.apiSecret && 'TWILIO_API_SECRET', !c.authToken && 'TWILIO_AUTH_TOKEN'].filter(Boolean) as string[];
  if (missing.length) return { ready: false, why: `Calling from the site is not set up yet (${missing.join(', ')} not saved).` };
  if (!/^AC[0-9a-f]{32}$/i.test(c.accountSid!.trim())) return { ready: false, why: 'TWILIO_ACCOUNT_SID does not look like an account SID (AC...).' };
  if (!/^SK[0-9a-f]{32}$/i.test(c.apiKey!.trim())) return { ready: false, why: 'TWILIO_API_KEY does not look like an API key SID (SK...).' };
  if (c.callerId && !toE164(c.callerId)) return { ready: false, why: 'TWILIO_CALLER_ID is not a phone number (use the form +12895550123).' };
  return { ready: true };
}

/** A phone number in E.164 (+ and up to 15 digits), from "+1 (289) 555-0123", "289-555-0123" or "12895550123"; null if it
 *  is not one. Ten digits are a North American number. */
export function toE164(raw: string | null | undefined): string | null {
  const s = (raw ?? '').trim();
  if (!s) return null;
  if (/[^\d\s()+.\-]/.test(s)) return null;
  let d = s.replace(/\D/g, '');
  if (!s.startsWith('+')) { if (d.length === 10) d = `1${d}`; else if (!(d.length === 11 && d.startsWith('1'))) return null; }
  const e = `+${d}`;
  return E164.test(e) ? e : null;
}

// ================================================================ r44 (2790): calls in the browser (Voice SDK)

/** The Voice SDK identity of a staff member: letters, digits and _ only, never a name or a number. */
export function staffIdentity(userId: string): string {
  if (!/^[0-9a-f-]{36}$/i.test(userId)) throw new Error('Not a user id');
  return `staff_${userId.toLowerCase().replace(/-/g, '')}`;
}
/** The user id of a Voice SDK identity (From "client:staff_..."), or null. */
export function identityUser(from: string | null | undefined): string | null {
  const m = /^(?:client:)?staff_([0-9a-f]{32})$/i.exec((from ?? '').trim());
  if (!m) return null;
  const h = m[1]!.toLowerCase();
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

const b64url = (b: Uint8Array | string) => bytesToB64(typeof b === 'string' ? enc.encode(b) : b).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');

/** A Twilio access token with a Voice grant (Twilio's documented JWT: HS256 with the API key secret, cty twilio-fpa;v=1):
 *  outgoing calls through our TwiML App, incoming calls to this identity when ring is on. */
export async function voiceAccessToken(o: { accountSid: string; apiKey: string; apiSecret: string; appSid: string; identity: string; ring: boolean; ttlSeconds?: number; now?: number }): Promise<string> {
  const iat = Math.floor((o.now ?? Date.now()) / 1000);
  const ttl = Math.max(300, Math.min(3600, Math.round(o.ttlSeconds ?? 3600)));
  const header = { alg: 'HS256', typ: 'JWT', cty: 'twilio-fpa;v=1' };
  const voice: Record<string, unknown> = { outgoing: { application_sid: o.appSid } };
  if (o.ring) voice.incoming = { allow: true };
  const payload = { jti: `${o.apiKey}-${iat}`, iss: o.apiKey, sub: o.accountSid, iat, nbf: iat - 5, exp: iat + ttl, grants: { identity: o.identity, voice } };
  const data = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  return `${data}.${b64url(await hmac('SHA-256', o.apiSecret, data))}`;
}

/** The TwiML for a call to the business number: the browsers of the staff online ring together (at most 10, Twilio's limit
 *  of Client nouns in one Dial). The browser is shown the business number as From and, as a parameter, who is calling as
 *  that staff member may see it (a name, or the number masked for Sales, 0970): the caller's own number never reaches a
 *  browser that may not see it. action reports whether anybody answered. */
export function ringBrowsersTwiml(o: { ring: Array<{ identity: string; who: string }>; callerId: string | null; actionUrl: string; timeoutSeconds?: number;
  recordingUrl?: string | null; answeredUrl?: string | null }): string {
  const ring = o.ring.filter((x) => /^staff_[0-9a-f]{32}$/.test(x.identity)).slice(0, 10);
  if (!ring.length) throw new Error('Nobody to ring');
  const t = Math.max(5, Math.min(60, Math.round(o.timeoutSeconds ?? 25)));
  const cid = o.callerId && E164.test(o.callerId) ? ` callerId="${xml(o.callerId)}"` : '';
  // r48 (2995): the answered browser says who took the call (the pop-up and the history name them); the call is recorded
  // from the answer, each side on its own channel, as calls placed from the site
  const cb = o.answeredUrl ? ` statusCallbackEvent="answered" statusCallback="${xml(o.answeredUrl)}" statusCallbackMethod="POST"` : '';
  const rec = o.recordingUrl ? ` record="record-from-answer-dual" recordingStatusCallback="${xml(o.recordingUrl)}" recordingStatusCallbackMethod="POST" recordingStatusCallbackEvent="completed"` : '';
  const clients = ring.map((x) => `<Client${cb}><Identity>${x.identity}</Identity><Parameter name="who" value="${xml(x.who.slice(0, 80))}"/></Client>`).join('');
  return `<?xml version="1.0" encoding="UTF-8"?><Response><Dial timeout="${t}" answerOnBridge="true"${cid} action="${xml(o.actionUrl)}" method="POST"${rec}>${clients}</Dial></Response>`;
}

/** Nobody answered (or nobody is online): forward to the number an Admin set (never a staff member's own number), or a
 *  short message and the end of the call (the missed call is logged and handled as every missed call). */
export function noAnswerTwiml(o: { forwardTo?: string | null; callerId?: string | null; message?: string | null; timeoutSeconds?: number }): string {
  const to = o.forwardTo && E164.test(o.forwardTo) ? o.forwardTo : null;
  if (to && o.callerId && E164.test(o.callerId)) {
    const t = Math.max(5, Math.min(60, Math.round(o.timeoutSeconds ?? 25)));
    return `<?xml version="1.0" encoding="UTF-8"?><Response><Dial callerId="${xml(o.callerId)}" timeout="${t}"><Number>${xml(to)}</Number></Dial></Response>`;
  }
  return hangupTwiml(o.message?.trim() || 'Sorry, we could not take your call. We will call you back shortly.');
}

/** The addresses Twilio may have signed: the site's own address (the one we give Twilio) first, then the host the request
 *  came to (a number whose Voice URL was typed by hand), always https: Cloudflare ends TLS, so req.url may say http. */
export function signedUrlCandidates(base: string, reqUrl: string, host: string | null | undefined): string[] {
  const u = new URL(reqUrl);
  const tail = `${u.pathname}${u.search}`;
  const out = [`${base.replace(/\/$/, '')}${tail}`];
  const h = (host ?? '').trim().toLowerCase();
  if (/^[a-z0-9.-]+(:\d+)?$/.test(h)) out.push(`https://${h}${tail}`);
  return [...new Set(out)];
}

/** Outcome words for the history, from the customer leg's DialCallStatus. */
export function dialOutcome(status: string | null | undefined): string {
  switch ((status ?? '').toLowerCase()) {
    case 'completed': case 'answered': return 'connected';
    case 'busy': return 'busy';
    case 'no-answer': return 'no answer';
    case 'canceled': return 'hung up before they answered';
    default: return 'did not connect';
  }
}

/** 1880: a recording callback worth copying: completed, with a recording SID of this account's form (RE + 32 hex). */
export function recordingReady(params: Record<string, string>): { sid: string; seconds: number } | null {
  const sid = params.RecordingSid ?? '';
  if (!/^RE[0-9a-f]{32}$/i.test(sid)) return null;
  if ((params.RecordingStatus ?? '').toLowerCase() !== 'completed') return null;
  const seconds = Math.max(0, Math.round(Number(params.RecordingDuration ?? '0')) || 0);
  return { sid, seconds };
}
/** The recording's audio (MP3) and the recording itself (DELETE), on Twilio's REST API. */
export function recordingUrls(accountSid: string, recordingSid: string): { audio: string; resource: string } {
  const base = `${TWILIO_API}/Accounts/${encodeURIComponent(accountSid)}/Recordings/${encodeURIComponent(recordingSid)}`;
  return { audio: `${base}.mp3`, resource: `${base}.json` };
}
/** r48 (2995): the recordings of one call, on Twilio's REST API (the backfill of calls whose callback never came). */
export function callRecordingsUrl(accountSid: string, callSid: string): string {
  if (!/^CA[0-9a-f]{32}$/i.test(callSid)) throw new Error('Not a call SID');
  return `${TWILIO_API}/Accounts/${encodeURIComponent(accountSid)}/Calls/${encodeURIComponent(callSid)}/Recordings.json`;
}
/** The finished recording of a call from that list (the longest, when there are several), or null. */
export function pickRecording(list: unknown): { sid: string; seconds: number } | null {
  const rows = (list && typeof list === 'object' && Array.isArray((list as { recordings?: unknown }).recordings) ? (list as { recordings: unknown[] }).recordings : [])
    .map((r) => (r && typeof r === 'object' ? (r as Record<string, unknown>) : {}))
    .filter((r) => typeof r.sid === 'string' && /^RE[0-9a-f]{32}$/i.test(r.sid) && String(r.status ?? 'completed').toLowerCase() === 'completed')
    .map((r) => ({ sid: r.sid as string, seconds: Math.max(0, Math.round(Number(r.duration ?? 0)) || 0) }))
    .sort((a, b) => b.seconds - a.seconds);
  return rows[0] ?? null;
}
/** The answered browser of a ring: the staff member's user id from the child leg's To ("client:staff_..."), or null. */
export function answeredBy(params: Record<string, string>): { parent: string; user: string | null } | null {
  const parent = params.ParentCallSid ?? '';
  if (!/^CA[0-9a-f]{32}$/i.test(parent)) return null;
  if (!['in-progress', 'answered'].includes((params.CallStatus ?? '').toLowerCase())) return null;
  return { parent, user: identityUser(params.To ?? params.Called) };
}

/** Where our copy is kept (private documents bucket); the database checks this form. */
export function recordingKey(callId: string): string {
  if (!/^[0-9a-f-]{36}$/i.test(callId)) throw new Error('Not a call id');
  return `calls/twilio/${callId.toLowerCase()}.mp3`;
}

// ================================================================ r48 CM: the Admin's test call (Settings > Calls)

export type CheckStep = { step: string; ok: boolean; detail: string; fix?: string };

/** What Twilio's account answer says about calling (GET /Accounts/{sid}.json, its HTTP status and body). */
export function accountProblem(status: number, j: { status?: string; type?: string; code?: number; message?: string } | null): { ok: boolean; detail: string; fix?: string } {
  if (status === 401 || status === 403 || j?.code === 20003) return { ok: false, detail: `Twilio refused the API key (${j?.code ?? status}: ${j?.message ?? 'authenticate'}).`,
    fix: 'Twilio Console > Account > API keys & tokens: create a Standard API key, then save its SID and secret as TWILIO_API_KEY and TWILIO_API_SECRET.' };
  if (status === 404) return { ok: false, detail: 'Twilio does not know this account SID (404).', fix: 'Copy the Account SID (AC...) from the Twilio Console home page into TWILIO_ACCOUNT_SID.' };
  if (status !== 200 || !j) return { ok: false, detail: `Twilio answered ${status}${j?.message ? `: ${j.message}` : ''}.`, fix: 'Try again in a minute; if it stays, check status.twilio.com.' };
  if (j.status && j.status !== 'active') return { ok: false, detail: `The Twilio account is ${j.status}.`, fix: 'Twilio Console > Admin > Account billing: settle the balance or reactivate the account.' };
  if (j.type === 'Trial') return { ok: false, detail: 'The Twilio account is a trial: it calls verified numbers only and plays a trial message.', fix: 'Twilio Console > Admin > Account billing > Upgrade account.' };
  return { ok: true, detail: `Account active (${j.type ?? 'Full'}).` };
}

/** The balance (GET /Accounts/{sid}/Balance.json): a call needs money on the account. */
export function balanceProblem(status: number, j: { balance?: string; currency?: string; message?: string } | null): { ok: boolean; detail: string; fix?: string } {
  if (status !== 200 || !j?.balance) return { ok: true, detail: 'The balance could not be read with this key (only the Auth Token may read it); not a failure by itself.' };
  const b = Number(j.balance);
  if (!Number.isFinite(b)) return { ok: true, detail: `Balance: ${j.balance} ${j.currency ?? ''}`.trim() };
  if (b <= 0.5) return { ok: false, detail: `Balance ${b.toFixed(2)} ${j.currency ?? 'USD'}: calls stop at zero.`, fix: 'Twilio Console > Admin > Account billing > Add funds (and turn on Auto-recharge).' };
  return { ok: true, detail: `Balance ${b.toFixed(2)} ${j.currency ?? 'USD'}.` };
}

/** May Twilio show this caller ID: a number of the account, or a verified caller ID (the Quo number is one). */
export function callerIdProblem(callerId: string | null, owned: string[], verified: string[]): { ok: boolean; detail: string; fix?: string } {
  if (!callerId) return { ok: false, detail: 'No caller ID: TWILIO_CALLER_ID is empty and Site settings has no phone.', fix: 'Set TWILIO_CALLER_ID to +12893125991 (the Quo number).' };
  if (owned.includes(callerId)) return { ok: true, detail: `${callerId} is a number of this Twilio account.` };
  if (verified.includes(callerId)) return { ok: true, detail: `${callerId} is a verified caller ID.` };
  return { ok: false, detail: `${callerId} is not verified in Twilio, so Twilio refuses it as the caller ID (error 21210 or 13214).`,
    fix: `Twilio Console > Phone Numbers > Manage > Verified Caller IDs > Add a new Caller ID: ${callerId}, then answer the call on the Quo line and enter the code.` };
}

/** The TwiML App's Voice URL must be this site's client webhook. */
export function appUrlProblem(voiceUrl: string | null | undefined, want: string): { ok: boolean; detail: string; fix?: string } {
  if (voiceUrl === want) return { ok: true, detail: `The TwiML App sends calls to ${want}.` };
  return { ok: false, detail: `The TwiML App sends calls to ${voiceUrl || 'nowhere'}, not ${want}.`, fix: 'Press Test call again: the site points the app at itself; or set the Voice URL in Twilio Console > Voice > TwiML Apps.' };
}

/** Our own token for a test call: only this server, for this person, for 10 minutes. */
export async function testCallToken(secret: string, userId: string, now = Date.now()): Promise<string> {
  const slot = Math.floor(now / 600_000);
  return `${slot}.${hex(await hmac('SHA-256', secret, `twilio-test:${userId}:${slot}`)).slice(0, 32)}`;
}
export async function verifyTestCallToken(secret: string | null | undefined, userId: string | null, token: string | null | undefined, now = Date.now()): Promise<boolean> {
  if (!secret || !userId || !token) return false;
  const slot = Number(token.split('.')[0]);
  const cur = Math.floor(now / 600_000);
  if (!Number.isInteger(slot) || (slot !== cur && slot !== cur - 1)) return false;
  return sameText(await testCallToken(secret, userId, slot * 600_000), token);
}

/** The test call's answer: a short message, then the end. Nobody is dialled and nothing is recorded. */
export function testCallTwiml(): string {
  return hangupTwiml('CarmaCars test call. Your browser phone works: the token, the connection, the TwiML App and the webhook are all right. Goodbye.');
}

/** A Voice SDK error in words, with its code (the Admin's test call and the staff phone). */
export function voiceErrorText(e: { code?: number; message?: string } | null | undefined): string {
  const c = e?.code;
  const m = (e?.message ?? '').slice(0, 120);
  if (c === 31401 || c === 31402 || /permission|NotAllowed/i.test(m)) return 'The browser did not allow the microphone. Allow it for this site (the icon in the address bar) and call again.';
  if (c === 20101 || c === 20104 || c === 31204 || c === 31205) return `The phone service refused the sign-in token (${c}): the API key or secret is wrong, or the key was deleted. Ask an Admin to run Test call.`;
  if (c === 31005 || c === 31009 || c === 53000 || c === 53405) return `The call dropped: the connection to the phone service was lost (${c}). Check your internet and call again.`;
  if (c === 31002 || c === 31003) return `The phone service could not reach our call handler (${c}). Ask an Admin to run Test call.`;
  if (c === 31000 || c === 31008) return `The call did not go through (${c}${m ? `: ${m}` : ''}). Ask an Admin to run Test call.`;
  return `The call did not go through${c ? ` (${c})` : ''}. Try again; if it happens again, ask an Admin to run Test call.`;
}
