// r48 CM: read only. Twilio (account, balance, TwiML App, numbers, verified caller IDs) and Amazon SES (account, identity)
// as the providers see them. Never prints a key; phone numbers of the account only (the business lines).
import { sigV4 } from '../../web/src/lib/email-ses.ts';
const out = (k, v) => console.log(`${k}: ${typeof v === 'string' ? v : JSON.stringify(v)}`);
const e = process.env;
async function twilio() {
  const sid = (e.TWILIO_ACCOUNT_SID ?? '').trim(), tok = (e.TWILIO_AUTH_TOKEN ?? '').trim(), key = (e.TWILIO_API_KEY ?? '').trim(), sec = (e.TWILIO_API_SECRET ?? '').trim();
  out('twilio.secrets', { account_sid: !!sid && /^AC[0-9a-f]{32}$/i.test(sid), auth_token: !!tok, api_key: !!key && /^SK[0-9a-f]{32}$/i.test(key), api_secret: !!sec, caller_id: (e.TWILIO_CALLER_ID ?? '').trim() || null, twiml_app_sid: !!(e.TWILIO_TWIML_APP_SID ?? '').trim() });
  if (!sid) return;
  const base = `https://api.twilio.com/2010-04-01/Accounts/${sid}`;
  const get = async (path, user, pass) => { const r = await fetch(`${base}${path}`, { headers: { authorization: `Basic ${Buffer.from(`${user}:${pass}`).toString('base64')}` } }); const j = await r.json().catch(() => ({})); return { status: r.status, j }; };
  if (tok) {
    const a = await get('.json', sid, tok); out('twilio.account(auth token)', { http: a.status, status: a.j.status, type: a.j.type, code: a.j.code, message: a.j.message });
    const b = await get('/Balance.json', sid, tok); out('twilio.balance', { http: b.status, balance: b.j.balance, currency: b.j.currency, code: b.j.code, message: b.j.message });
  }
  if (key && sec) {
    const a = await get('.json', key, sec); out('twilio.account(api key)', { http: a.status, status: a.j.status, code: a.j.code, message: a.j.message });
    const apps = await get('/Applications.json?PageSize=20', key, sec); out('twilio.apps', { http: apps.status, code: apps.j.code, message: apps.j.message, apps: (apps.j.applications ?? []).map((x) => ({ name: x.friendly_name, voice_url: x.voice_url })) });
    const nums = await get('/IncomingPhoneNumbers.json?PageSize=20', key, sec); out('twilio.numbers', { http: nums.status, numbers: (nums.j.incoming_phone_numbers ?? []).map((x) => ({ n: x.phone_number, voice_url: x.voice_url, app: !!x.voice_application_sid })) });
    const cids = await get('/OutgoingCallerIds.json?PageSize=20', key, sec); out('twilio.verified_caller_ids', { http: cids.status, ids: (cids.j.outgoing_caller_ids ?? []).map((x) => x.phone_number) });
    const calls = await get('/Calls.json?PageSize=15', key, sec); out('twilio.recent_calls', { http: calls.status, calls: (calls.j.calls ?? []).map((x) => ({ at: x.start_time, status: x.status, dir: x.direction, from: x.from?.startsWith('client:') ? 'client' : x.from, to_tail: String(x.to ?? '').slice(-4) })) });
    const al = await get('/Notifications.json?PageSize=15', key, sec); out('twilio.alerts', { http: al.status, alerts: (al.j.notifications ?? []).map((x) => ({ at: x.date_created, code: x.error_code, level: x.log, url: x.request_url })) });
  }
}
async function ses() {
  const k = (e.AWS_SES_ACCESS_KEY_ID ?? '').trim(), s = (e.AWS_SES_SECRET_ACCESS_KEY ?? '').trim(), region = (e.AWS_SES_REGION ?? '').trim() || 'ca-central-1';
  out('ses.secrets', { key: !!k, secret: !!s, region });
  if (!k || !s) return;
  const call = async (path) => {
    const url = `https://email.${region}.amazonaws.com${path}`;
    const headers = await sigV4({ method: 'GET', url, region, service: 'ses', accessKeyId: k, secretAccessKey: s });
    const r = await fetch(url, { headers }); return { status: r.status, type: r.headers.get('x-amzn-errortype'), j: await r.json().catch(() => ({})) };
  };
  const a = await call('/v2/email/account');
  out('ses.account', { http: a.status, error: a.type, message: a.j.message, production: a.j.ProductionAccessEnabled, sending: a.j.SendingEnabled, enforcement: a.j.EnforcementStatus, quota: a.j.SendQuota, review: a.j.Details?.ReviewDetails });
  for (const id of ['carmacars.ca', 'rent@carmacars.ca']) {
    const i = await call(`/v2/email/identities/${encodeURIComponent(id)}`);
    out(`ses.identity ${id}`, { http: i.status, error: i.type, verified: i.j.VerifiedForSendingStatus, dkim: i.j.DkimAttributes?.Status, mail_from: i.j.MailFromAttributes?.MailFromDomainStatus });
  }
}
async function quo() {
  const key = (e.QUO_API_KEY ?? '').trim(); if (!key) return out('quo', 'no key');
  for (const p of ['/v1/phone-numbers', '/v1/messages?maxResults=5']) {
    const r = await fetch(`https://api.openphone.com${p}`, { headers: { authorization: key } }); const j = await r.json().catch(() => ({}));
    out(`quo ${p.split('?')[0]}`, { http: r.status, message: j.message, code: j.code, errors: j.errors });
  }
}
async function worker() {
  const t = e.CLOUDFLARE_API_TOKEN, acct = e.CLOUDFLARE_ACCOUNT_ID; if (!t || !acct) return out('worker', 'no Cloudflare token');
  const r = await fetch(`https://api.cloudflare.com/client/v4/accounts/${acct}/workers/scripts/carmacars-prod/secrets`, { headers: { authorization: `Bearer ${t}` } });
  const j = await r.json().catch(() => ({}));
  out('worker.secret_names', { http: r.status, names: (j.result ?? []).map((x) => x.name).filter((n) => /TWILIO|QUO|SES|RESEND|VAPID|APP_URL/.test(n)), errors: j.errors });
}
for (const f of [twilio, ses, quo, worker]) { try { await f(); } catch (x) { out(f.name, `failed: ${x.message}`); } }
