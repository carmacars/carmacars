// The site's outbound Call button through Twilio (release 35, migration 0970; the owner's decision of November 8: Quo keeps
// incoming calls, texts and AI answering; staff call out from the site). No imports, so it runs in the Worker, in Node and
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
export function bridgeTwiml(o: { to: string; callerId: string; actionUrl: string; say?: string; timeoutSeconds?: number }): string {
  if (!E164.test(o.to)) throw new Error('The customer number is not in E.164 form');
  if (!E164.test(o.callerId)) throw new Error('The caller ID is not in E.164 form');
  const t = Math.max(5, Math.min(60, Math.round(o.timeoutSeconds ?? 30)));
  const say = o.say ? `<Say voice="alice" language="en-CA">${xml(o.say)}</Say>` : '';
  return `<?xml version="1.0" encoding="UTF-8"?><Response>${say}<Dial callerId="${xml(o.callerId)}" timeout="${t}" answerOnBridge="true" action="${xml(o.actionUrl)}" method="POST"><Number>${xml(o.to)}</Number></Dial></Response>`;
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

/** Ready to call, or the reason it is not (the button then falls back to the Quo link and says why). */
export function twilioReady(c: TwilioConfig): { ready: true } | { ready: false; why: string } {
  const missing = [!c.accountSid && 'TWILIO_ACCOUNT_SID', !c.apiKey && 'TWILIO_API_KEY', !c.apiSecret && 'TWILIO_API_SECRET'].filter(Boolean) as string[];
  if (missing.length) return { ready: false, why: `Calling from the site is not set up yet (${missing.join(', ')} not saved).` };
  if (!/^AC[0-9a-f]{32}$/i.test(c.accountSid!)) return { ready: false, why: 'TWILIO_ACCOUNT_SID does not look like an account SID (AC...).' };
  return { ready: true };
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
