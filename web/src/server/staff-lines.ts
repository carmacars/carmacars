import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { TWILIO_API, twilioReady } from '@/features/phone/twilio';
import { buyLine, lineMsg, quoteLine, type LineDb, type LineQuote } from '@/features/phone/staff-line-buy';
import { twilioConfig } from '@/server/twilio-call';

// R51 (5200, REQ-132): a staff member's own Twilio line. Only an Admin, from Admin > Settings > Staff, in two steps: Quote
// (Twilio's monthly price of a Canadian local number in the area code of Program settings, and the last 4 digits of the
// number found; nothing is bought) and Buy (the Admin confirmed that price: the number is bought, pointed at our incoming
// webhook and recorded). The full number never leaves the server. Tests and jobs never call this: the unit tests mock fetch,
// and lineBuyBlocked refuses any site that is not the production host (every test, preview and local server).
const SR = { role: 'service_role' as const };
const basic = (c: ReturnType<typeof twilioConfig>) => `Basic ${btoa(`${c.apiKey}:${c.apiSecret}`)}`;
const msg = lineMsg;

export type { LineQuote };

const dbFor = (adminId: string, userId: string): LineDb => ({
  check: async () => (await rpc('server_staff_line_check', { p_by: adminId, p_user: userId }, SR)) as unknown as { extension: string; name: string; area_code: string },
  quoted: async (q) => { await rpc('server_staff_line_quoted', { p: { by: adminId, user_id: userId, ...q } as unknown as Json }, SR); },
  claim: async (c) => (await rpc('server_staff_line_claim', { p: { by: adminId, user_id: userId, ...c } as unknown as Json }, SR)) as unknown as { number: string; monthly: string; currency: string },
  bought: async (b) => (await rpc('server_staff_line_bought', { p: { by: adminId, user_id: userId, ...b } as unknown as Json }, SR)) as unknown as { line: string },
  end: async () => { await rpc('server_staff_line_quote_end', { p_by: adminId, p_user: userId }, SR); },
});

/** The price and the number Twilio would sell now (last 4 digits only; the full number is kept server side for Buy). Nothing is bought. */
export async function lineQuote(adminId: string, userId: string, f: typeof fetch = fetch): Promise<LineQuote> {
  const c = twilioConfig();
  const ready = twilioReady(c);
  if (!ready.ready) return { ok: false, message: ready.why };
  return quoteLine(c, dbFor(adminId, userId), f);
}

/** Buys the quoted number after the Admin confirmed the quoted amount and currency. */
export async function lineBuy(adminId: string, userId: string, confirmed: { monthly: string; currency: string }, f: typeof fetch = fetch): Promise<{ ok: true; line: string } | { ok: false; message: string }> {
  const c = twilioConfig();
  const ready = twilioReady(c);
  if (!ready.ready) return { ok: false, message: ready.why };
  return buyLine(c, dbFor(adminId, userId), confirmed, f);
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
