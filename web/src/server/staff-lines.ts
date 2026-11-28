import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { TWILIO_API, twilioReady } from '@/features/phone/twilio';
import { lineBuyBlocked, linePrice, maskedNumber, pickNumber } from '@/features/phone/staff-lines';
import { twilioConfig } from '@/server/twilio-call';

// R51 (5301, REQ-132): a staff member's own Twilio line. Only an Admin, from Admin > Settings > Staff, in two steps: Quote
// (Twilio's monthly price of a Canadian local number in the area code of Program settings, and the last 4 digits of the
// number found; nothing is bought) and Buy (the Admin confirmed that price: the number is bought, pointed at our incoming
// webhook and recorded). The full number never leaves the server. Tests and jobs never call this: the unit tests mock fetch,
// and lineBuyBlocked refuses a site that is not a public https address (every test server).
const SR = { role: 'service_role' as const };
const basic = (c: ReturnType<typeof twilioConfig>) => `Basic ${btoa(`${c.apiKey}:${c.apiSecret}`)}`;
const msg = (e: unknown) => (e instanceof Error ? e.message : String(e)).replace(/^.*?ERROR:\s*/, '').slice(0, 200);

export type LineQuote = { ok: true; extension: string; name: string; monthly: string; currency: string; number: string } | { ok: false; message: string };

async function search(c: ReturnType<typeof twilioConfig>, area: string, f: typeof fetch): Promise<string | null> {
  const r = await f(`${TWILIO_API}/Accounts/${encodeURIComponent(c.accountSid!)}/AvailablePhoneNumbers/CA/Local.json?AreaCode=${encodeURIComponent(area)}&VoiceEnabled=true&PageSize=5`,
    { headers: { authorization: basic(c) }, signal: AbortSignal.timeout(10_000) });
  const j = (await r.json().catch(() => null)) as { available_phone_numbers?: Array<{ phone_number?: string }>; message?: string } | null;
  if (!r.ok) throw new Error(`Twilio answered ${r.status}${j?.message ? `: ${j.message}` : ''}`);
  return pickNumber(j);
}
async function price(c: ReturnType<typeof twilioConfig>, f: typeof fetch): Promise<{ monthly: string; currency: string } | null> {
  const r = await f('https://pricing.twilio.com/v1/PhoneNumbers/Countries/CA', { headers: { authorization: basic(c) }, signal: AbortSignal.timeout(10_000) });
  return r.ok ? linePrice(await r.json().catch(() => null)) : null;
}

/** The price and the number Twilio would sell now (last 4 digits only). Nothing is bought. */
export async function lineQuote(adminId: string, userId: string, f: typeof fetch = fetch): Promise<LineQuote> {
  const c = twilioConfig();
  const ready = twilioReady(c);
  if (!ready.ready) return { ok: false, message: ready.why };
  try {
    const chk = (await rpc('server_staff_line_check', { p_by: adminId, p_user: userId }, SR)) as unknown as { extension: string; name: string; area_code: string };
    const [num, p] = await Promise.all([search(c, chk.area_code, f), price(c, f)]);
    if (!num) return { ok: false, message: `Twilio has no local number in area code ${chk.area_code} right now. Change the area code in Program settings (phone_line_area_code) and try again.` };
    if (!p) return { ok: false, message: 'Twilio did not give the monthly price of a Canadian number. Nothing was bought.' };
    return { ok: true, extension: chk.extension, name: chk.name, monthly: p.monthly, currency: p.currency, number: maskedNumber(num) };
  } catch (e) { return { ok: false, message: msg(e) }; }
}

/** Buys the line after the Admin confirmed the price they were shown (confirmed must equal Twilio's price now). */
export async function lineBuy(adminId: string, userId: string, confirmed: string, f: typeof fetch = fetch): Promise<{ ok: true; line: string } | { ok: false; message: string }> {
  const c = twilioConfig();
  const ready = twilioReady(c);
  if (!ready.ready) return { ok: false, message: ready.why };
  const blocked = lineBuyBlocked(c.base);
  if (blocked) return { ok: false, message: blocked };
  try {
    const chk = (await rpc('server_staff_line_check', { p_by: adminId, p_user: userId }, SR)) as unknown as { extension: string; area_code: string };
    const p = await price(c, f);
    if (!p || p.monthly !== confirmed) return { ok: false, message: `The price changed or could not be read (now ${p ? `${p.currency} ${p.monthly}` : 'unknown'} a month). Nothing was bought: press Get a number again.` };
    const num = await search(c, chk.area_code, f);
    if (!num) return { ok: false, message: 'Twilio has no local number in that area code right now. Nothing was bought.' };
    const body = new URLSearchParams({ PhoneNumber: num, VoiceUrl: `${c.base}/api/webhooks/twilio/incoming`, VoiceMethod: 'POST', FriendlyName: `CarmaCars staff line ext ${chk.extension}` });
    const r = await f(`${TWILIO_API}/Accounts/${encodeURIComponent(c.accountSid!)}/IncomingPhoneNumbers.json`,
      { method: 'POST', body, headers: { authorization: basic(c), 'content-type': 'application/x-www-form-urlencoded' }, signal: AbortSignal.timeout(15_000) });
    const j = (await r.json().catch(() => null)) as { sid?: string; phone_number?: string; message?: string } | null;
    if (!r.ok || !j?.sid || !j.phone_number) return { ok: false, message: `Twilio did not sell the number (${r.status}${j?.message ? `: ${j.message}` : ''}). Nothing was bought.` };
    const cents = Math.round(Number(p.monthly) * 100);
    try {
      const saved = (await rpc('server_staff_line_bought', { p: { by: adminId, user_id: userId, number: j.phone_number, sid: j.sid, monthly_cents: cents, currency: p.currency } as unknown as Json }, SR)) as unknown as { line: string };
      return { ok: true, line: saved.line };
    } catch (e) {
      // not recorded: give the number back so it does not cost money unseen
      await f(`${TWILIO_API}/Accounts/${encodeURIComponent(c.accountSid!)}/IncomingPhoneNumbers/${encodeURIComponent(j.sid)}.json`, { method: 'DELETE', headers: { authorization: basic(c) }, signal: AbortSignal.timeout(10_000) }).catch(() => null);
      return { ok: false, message: `The number was bought but could not be saved, so it was given back to Twilio: ${msg(e)}` };
    }
  } catch (e) { return { ok: false, message: msg(e) }; }
}

/** Gives the line back to Twilio (the monthly charge stops) and records it. */
export async function lineRelease(adminId: string, userId: string, f: typeof fetch = fetch): Promise<{ ok: true; line: string } | { ok: false; message: string }> {
  const c = twilioConfig();
  const ready = twilioReady(c);
  if (!ready.ready) return { ok: false, message: ready.why };
  try {
    const sid = (await rpc('server_staff_line_sid', { p_by: adminId, p_user: userId }, SR)) as unknown as string | null;
    if (sid) {
      const r = await f(`${TWILIO_API}/Accounts/${encodeURIComponent(c.accountSid!)}/IncomingPhoneNumbers/${encodeURIComponent(sid)}.json`, { method: 'DELETE', headers: { authorization: basic(c) }, signal: AbortSignal.timeout(10_000) });
      if (!r.ok && r.status !== 404) return { ok: false, message: `Twilio did not release the number (${r.status}). It is still on the line.` };
    }
    const done = (await rpc('server_staff_line_released', { p: { by: adminId, user_id: userId } as unknown as Json }, SR)) as unknown as { line: string };
    return { ok: true, line: done.line };
  } catch (e) { return { ok: false, message: msg(e) }; }
}
