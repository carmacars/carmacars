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
  /** 2026-10-28: why the buttons are off and when they come on, said beside the buttons themselves (null when not locked) */
  why: string | null;
  /** when the buttons come on by themselves (the Sales wait ends, or the other person's claim runs out), or null */
  opensAt: string | null;
}

const time = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit', hour12: true }).format(new Date(iso)).replace(/\s?([ap])\.?m\.?/i, ' $1m').toLowerCase();

/** "Opens to you at 3:15 pm": a request a Sales person may answer only later. */
export function opensToYou(at: string | null | undefined): string | null {
  return at ? `Opens to you at ${time(at)}` : null;
}

/** Whether nobody holds the request now and this person may take it (no Sales wait for them, no live claim). */
export function claimFree(s: ClaimState | null, now: number = Date.now()): boolean {
  return Boolean(s && s.status === 'requested' && !s.sales_waits && !(s.claim && new Date(s.claim.until).getTime() > now));
}

const OPEN = { locked: false, why: null, opensAt: null } as const;

export function claimView(s: ClaimState | null, now: number = Date.now()): ClaimView {
  if (!s || s.status !== 'requested') return { ...OPEN, note: null, canTakeOver: false, mine: false };
  if (s.sales_waits) {
    const at = s.sales_opens_at;
    return { locked: true, note: `${s.sales_text ?? opensToYou(at) ?? 'Open to Sales later'}. Customer service answers it first.`, canTakeOver: false, mine: false, opensAt: at,
      why: `A request from the website goes to customer service first. ${at ? `It opens to you at ${time(at)}` : 'It opens to you later'} if nobody has answered it: the buttons come on by themselves then. Meanwhile, call or email the renter from the request above.` };
  }
  const c = s.claim && new Date(s.claim.until).getTime() > now ? s.claim : null;
  if (!c) return { ...OPEN, note: s.sales_text ? `${s.sales_text}.` : null, canTakeOver: false, mine: false };
  if (c.mine) return { ...OPEN, note: `You are answering this request: nobody else can send an answer while you work on it (until ${time(c.until)}, renewed while you work).`, canTakeOver: false, mine: true };
  return { locked: true, note: `${c.text}. The offer and decline buttons are off until they finish or their claim runs out at ${time(c.until)}.`, canTakeOver: s.admin, mine: false, opensAt: c.until,
    why: `${c.name} is answering this request. Their claim runs out at ${time(c.until)} unless they keep working on it; the buttons come on by themselves then, and the request is yours when you start on it. ${s.admin ? 'Press Take over to answer it yourself now.' : 'If it cannot wait, ask an Admin to take it over.'}` };
}
