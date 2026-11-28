// R51 (5200, 5210): buying a staff line, with its database steps and Twilio's config passed in so the unit tests run it with a
// mocked fetch and a fake database (they never buy). The number bought is the one quoted, carried by the database from the
// quote to the Buy step and never shown (an Admin sees its last 4 digits).
import { TWILIO_API } from './twilio.ts';
import { lineBuyBlocked, linePrice, maskedNumber, pickNumber } from './staff-lines.ts';

export interface LineCfg { accountSid?: string; apiKey?: string; apiSecret?: string; base: string }
export interface LineDb {
  check(): Promise<{ extension: string; name?: string; area_code: string }>;
  quoted(q: { number: string; monthly: string; currency: string }): Promise<void>;
  claim(c: { confirm: string; currency: string }): Promise<{ number: string; monthly: string; currency: string }>;
  bought(b: { number: string; sid: string; monthly_cents: number; currency: string }): Promise<{ line: string }>;
  end(): Promise<void>;
}
export type LineQuote = { ok: true; extension: string; name: string; monthly: string; currency: string; number: string } | { ok: false; message: string };
type Fail = { ok: false; message: string };

const basic = (c: LineCfg) => `Basic ${btoa(`${c.apiKey}:${c.apiSecret}`)}`;
const acct = (c: LineCfg) => `${TWILIO_API}/Accounts/${encodeURIComponent(c.accountSid!)}`;
export const lineMsg = (e: unknown) => (e instanceof Error ? e.message : String(e)).replace(/^.*?ERROR:\s*/, '').slice(0, 200);

async function search(c: LineCfg, area: string, f: typeof fetch): Promise<string | null> {
  const r = await f(`${acct(c)}/AvailablePhoneNumbers/CA/Local.json?AreaCode=${encodeURIComponent(area)}&VoiceEnabled=true&PageSize=5`,
    { headers: { authorization: basic(c) }, signal: AbortSignal.timeout(10_000) });
  const j = (await r.json().catch(() => null)) as { available_phone_numbers?: Array<{ phone_number?: string }>; message?: string } | null;
  if (!r.ok) throw new Error(`Twilio answered ${r.status}${j?.message ? `: ${j.message}` : ''}`);
  return pickNumber(j);
}
async function price(c: LineCfg, f: typeof fetch): Promise<{ monthly: string; currency: string } | null> {
  const r = await f('https://pricing.twilio.com/v1/PhoneNumbers/Countries/CA', { headers: { authorization: basic(c) }, signal: AbortSignal.timeout(10_000) });
  return r.ok ? linePrice(await r.json().catch(() => null)) : null;
}

/** The price and the number Twilio would sell now. The full number goes to the database for the Buy step; the Admin gets its last 4 digits. Nothing is bought. */
export async function quoteLine(c: LineCfg, db: LineDb, f: typeof fetch): Promise<LineQuote> {
  try {
    const chk = await db.check();
    const [num, p] = await Promise.all([search(c, chk.area_code, f), price(c, f)]);
    if (!num) return { ok: false, message: `Twilio has no local number in area code ${chk.area_code} right now. Change the area code in Program settings (phone_line_area_code) and try again.` };
    if (!p) return { ok: false, message: 'Twilio did not give the monthly price of a Canadian number. Nothing was bought.' };
    await db.quoted({ number: num, monthly: p.monthly, currency: p.currency });
    return { ok: true, extension: chk.extension, name: chk.name ?? '', monthly: p.monthly, currency: p.currency, number: maskedNumber(num) };
  } catch (e) { return { ok: false, message: lineMsg(e) }; }
}

/** Buys exactly the quoted number, once, on the live site only, after the Admin confirmed the quoted amount and currency. */
export async function buyLine(c: LineCfg, db: LineDb, confirmed: { monthly: string; currency: string }, f: typeof fetch): Promise<{ ok: true; line: string } | Fail> {
  const blocked = lineBuyBlocked(c.base);
  if (blocked) return { ok: false, message: blocked };
  let claimed: { number: string; monthly: string; currency: string };
  let ext: string;
  try {
    ext = (await db.check()).extension;
    // the database locks the quote, compares what the Admin confirmed with it and refuses a second purchase in progress
    claimed = await db.claim({ confirm: confirmed.monthly, currency: confirmed.currency });
  } catch (e) { return { ok: false, message: lineMsg(e) }; }
  const stop = async (message: string): Promise<Fail> => { await db.end().catch(() => undefined); return { ok: false, message }; };
  try {
    const p = await price(c, f);
    if (!p || p.monthly !== claimed.monthly || p.currency !== claimed.currency.toUpperCase())
      return await stop(`The price changed or could not be read (now ${p ? `${p.currency} ${p.monthly}` : 'unknown'} a month). Nothing was bought: press Get a number again.`);
    const body = new URLSearchParams({ PhoneNumber: claimed.number, VoiceUrl: `${c.base}/api/webhooks/twilio/incoming`, VoiceMethod: 'POST', FriendlyName: `CarmaCars staff line ext ${ext}` });
    const r = await f(`${acct(c)}/IncomingPhoneNumbers.json`,
      { method: 'POST', body, headers: { authorization: basic(c), 'content-type': 'application/x-www-form-urlencoded' }, signal: AbortSignal.timeout(15_000) });
    const j = (await r.json().catch(() => null)) as { sid?: string; phone_number?: string; message?: string } | null;
    if (!r.ok || !j?.sid || !j.phone_number) return await stop(`Twilio did not sell the quoted number (${r.status}${j?.message ? `: ${j.message}` : ''}). Nothing was bought: press Get a number again.`);
    try {
      const saved = await db.bought({ number: j.phone_number, sid: j.sid, monthly_cents: Math.round(Number(p.monthly) * 100), currency: p.currency });
      await db.end().catch(() => undefined);
      return { ok: true, line: saved.line };
    } catch (e) {
      // not recorded: give the number back so it does not cost money unseen
      await f(`${acct(c)}/IncomingPhoneNumbers/${encodeURIComponent(j.sid)}.json`, { method: 'DELETE', headers: { authorization: basic(c) }, signal: AbortSignal.timeout(10_000) }).catch(() => null);
      return await stop(`The number was bought but could not be saved, so it was given back to Twilio: ${lineMsg(e)}`);
    }
  } catch (e) { return await stop(lineMsg(e)); }
}
