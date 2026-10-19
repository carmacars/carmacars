// Live chat (migration 0060): the rules every assistant reply passes before a visitor reads it, and the checks on a
// visitor's message that send the chat to a person without asking the model. Pure functions, unit tested
// (guardrails.test.ts). The principle: the assistant may only repeat amounts the database gave it in this
// conversation (a quote, a search, the rates and fees of the fleet); anything else is refused and replaced.

export type Escalation = 'person' | 'complaint' | 'damage' | 'payment' | 'legal' | 'insurance';

const ESCALATE: Array<[Escalation, RegExp]> = [
  ['person', /\b(human|real person|a person|an agent|live agent|representative|someone real|talk to (someone|somebody|staff|a person)|speak (to|with) (someone|somebody|a person|staff|a human|an agent|the manager)|call me|manager)\b/i],
  ['damage', /\b(accident|crash(ed)?|collision|damaged?|dent(ed)?|scratch(ed)?|broke down|breakdown|tow(ed)?|stolen|theft|police|injur(y|ed)|hit (a|another|my))\b/i],
  ['payment', /\b(was charged|been charged|double charged|charged twice|overcharg\w*|refunds?|chargeback|dispute|payment (failed|didn'?t go|declined|issue|problem)|card (was )?declined|charge on my card|my deposit (back|was|hasn'?t|has not))\b/i],
  ['complaint', /\b(complain\w*|terrible|awful|scam|ripped off|furious|angry|unacceptable|worst|disgusting|rude|never again|very disappointed)\b/i],
  ['insurance', /\b(insurance|insured|insurer|coverage|cover me|covered)\b/i],
  ['legal', /\b(lawyer|legal|sue|lawsuit|court|liabilit(y|ies)|liable)\b/i]
];

export const ESCALATION_WORDS: Record<Escalation, string> = {
  person: 'asked for a person', damage: 'damage, an accident or a breakdown', payment: 'a payment, charge or refund',
  complaint: 'a complaint', insurance: 'a question about insurance or protection', legal: 'a legal question'
};

/** Why a visitor's message goes to a person straight away (no model call), or null. */
export function escalationFor(text: string): Escalation | null {
  for (const [why, re] of ESCALATE) if (re.test(text)) return why;
  return null;
}

/** Every amount of money written in a text, in cents: $1,234.56, $59, CA$ 59.00, 59 dollars. */
export function amountsIn(text: string): number[] {
  const out: number[] = [];
  const re = /(?:CA\$|C\$|\$)\s?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?|(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?\s?(?:dollars|CAD)\b/gi;
  for (const m of text.matchAll(re)) {
    const whole = (m[1] ?? m[3] ?? '0').replace(/,/g, '');
    const frac = (m[2] ?? m[4] ?? '').padEnd(2, '0').slice(0, 2);
    out.push(Number(whole) * 100 + Number(frac || 0));
  }
  return out;
}

/** Every percentage written in a text. */
export function percentsIn(text: string): number[] {
  return [...text.matchAll(/(\d{1,3}(?:\.\d+)?)\s?(%|percent\b)/gi)].map((m) => Number(m[1]));
}

/** Every amount (in cents) found anywhere in a value: keys ending in _cents, at any depth. */
export function centsIn(v: unknown, out = new Set<number>()): Set<number> {
  if (Array.isArray(v)) { for (const x of v) centsIn(x, out); return out; }
  if (v && typeof v === 'object') {
    for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
      if (/_cents$/.test(k) && typeof x === 'number' && Number.isFinite(x)) out.add(Math.round(x));
      else centsIn(x, out);
    }
  }
  return out;
}

export interface ReplyContext {
  /** Amounts the database gave in this conversation (quotes, searches) and the fleet's rates and fees. */
  allowedCents: Set<number>;
  /** Percentages the site states (the non-refundable discount, the cancellation tiers, HST). */
  allowedPercents: Set<number>;
  /** Names that must never be said (the insurers, the Protection Plan's provider). */
  neverSay: string[];
}

export type ReplyCheck = { ok: true; text: string } | { ok: false; reason: string; text: string };

const PROMISE = /\b(guarantee[ds]?|i promise|we promise|reserved for you|i('ve| have) (booked|reserved)|it'?s booked|is booked for you|booking is confirmed|you'?re confirmed|confirmed your booking|hold (it|the car) for you|definitely (be )?available|will be available for sure)\b/i;
const DISCOUNT = /\b(discount|% off|percent off|promo(tion)?s?|coupon|special price|cheaper price|lower (the )?price|price match|deal for you|waive)\b/i;
const LEGAL = /\b(legal advice|you (should|could|can) sue|you are (not )?liable|you'?re (not )?liable|not responsible for (the )?damage)\b/i;
const INSURANCE = /\b(insurance|insured|insurer|coverage)\b/i;

/** Tidies a reply to the house style: no long dashes, the brand spelled CarmaCars. */
export function tidy(text: string): string {
  return text.replace(/\s*[—–]\s*/g, ', ').replace(/\bcarma\s?cars\b/gi, 'CarmaCars').replace(/\n{3,}/g, '\n\n').trim();
}

/** Checks one assistant reply. A refused reply is never shown; the caller replaces it. */
export function checkReply(raw: string, ctx: ReplyContext): ReplyCheck {
  const text = tidy(raw ?? '');
  if (!text) return { ok: false, reason: 'empty', text };
  if (text.length > 1400) return { ok: false, reason: 'too long', text };
  for (const a of amountsIn(text)) if (!ctx.allowedCents.has(a)) return { ok: false, reason: `an amount the database did not give: ${(a / 100).toFixed(2)}`, text };
  for (const p of percentsIn(text)) if (!ctx.allowedPercents.has(p)) return { ok: false, reason: `a percentage the site does not state: ${p}%`, text };
  if (INSURANCE.test(text)) return { ok: false, reason: 'insurance words', text };
  for (const n of ctx.neverSay) if (n && n.length > 2 && text.toLowerCase().includes(n.toLowerCase())) return { ok: false, reason: 'a provider name', text };
  if (PROMISE.test(text)) return { ok: false, reason: 'a promise', text };
  if (DISCOUNT.test(text) && !/non-?refundable/i.test(text)) return { ok: false, reason: 'a discount', text };
  if (LEGAL.test(text)) return { ok: false, reason: 'legal advice', text };
  return { ok: true, text };
}

export const money = (cents: number) => `$${(cents / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
