// Who is answering a booking request (migration 0177): the state the database gives (app.request_claim_state) and what a
// screen makes of it. Pure, so the unit tests cover it; RequestClaim.tsx is the screen part.

export interface ClaimInfo { by: string; name: string; since: string; until: string; mine: boolean; text: string }
export interface ClaimState {
  booking: string; status: string; current_offer_version: number | null;
  claim: ClaimInfo | null; sales_opens_at: string | null; sales_waits: boolean; sales_text: string | null; admin: boolean; minutes: number;
}

export interface ClaimView {
  /** the answer buttons are off for this person */
  locked: boolean;
  /** the line shown above the request, or null */
  note: string | null;
  /** this person may press Take over now */
  canTakeOver: boolean;
  mine: boolean;
}

const time = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit', hour12: true }).format(new Date(iso)).replace(/\s?([ap])\.?m\.?/i, ' $1m').toLowerCase();

/** "Opens to you at 3:15 pm": a request a Sales person may answer only later. */
export function opensToYou(at: string | null | undefined): string | null {
  return at ? `Opens to you at ${time(at)}` : null;
}

export function claimView(s: ClaimState | null, now: number = Date.now()): ClaimView {
  if (!s || s.status !== 'requested') return { locked: false, note: null, canTakeOver: false, mine: false };
  if (s.sales_waits) return { locked: true, note: `${s.sales_text ?? opensToYou(s.sales_opens_at) ?? 'Open to Sales later'}. Customer service answers it first.`, canTakeOver: false, mine: false };
  const c = s.claim && new Date(s.claim.until).getTime() > now ? s.claim : null;
  if (!c) return { locked: false, note: s.sales_text ? `${s.sales_text}.` : null, canTakeOver: false, mine: false };
  if (c.mine) return { locked: false, note: `You are answering this request: nobody else can send an answer while you work on it (until ${time(c.until)}, renewed while you work).`, canTakeOver: false, mine: true };
  return { locked: true, note: `${c.text}. The offer and decline buttons are off until they finish or their claim runs out at ${time(c.until)}.`, canTakeOver: s.admin, mine: false };
}
