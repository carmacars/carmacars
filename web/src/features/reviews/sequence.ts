// The review request sequence's timing and the hold's summary (migration 0146), for the staff screens: the booking
// page shows each step with when it went or when it will go, and the hold list says what is open. The database's
// app.review_step sends by the same rules (suite 91); these are the words and times staff read. No imports.

export type Step = 'checkin' | 'ask' | 'reminder' | 'final';
export const STEP_LABEL: Record<Step, string> = {
  checkin: 'Mid-trip check-in',
  ask: 'Review request',
  reminder: 'Reminder',
  final: 'Final follow-up'
};

export interface SeqSettings {
  checkinEnabled: boolean;
  checkinMinDays: number;
  checkinAfterHours: number;
  askAfterMinutes: number;
  reminderHours: number;
  finalDays: number;
  fromHour: number;
  untilHour: number;
}
export const DEFAULT_SETTINGS: SeqSettings = { checkinEnabled: true, checkinMinDays: 2, checkinAfterHours: 24, askAfterMinutes: 60, reminderHours: 24, finalDays: 7, fromHour: 9, untilHour: 21 };

export interface SeqFacts {
  /** the pickup (the handover when recorded) */
  pickupAt: Date;
  /** the return time booked */
  returnAt: Date;
  /** the check-in, once the car is back */
  returnedAt: Date | null;
  sent: Partial<Record<Step, Date | null>>;
}

export interface PlannedStep { step: Step; sentAt: Date | null; dueAt: Date | null; sendAt: Date | null; skipped?: string }

const H = 3_600_000;
const TZ = 'America/Toronto';

/** The wall-clock parts of a moment in Toronto. */
function torontoParts(d: Date): { y: number; m: number; day: number; h: number; min: number } {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
    .formatToParts(d).filter((x) => x.type !== 'literal').map((x) => [x.type, Number(x.value)]));
  return { y: p.year!, m: p.month!, day: p.day!, h: p.hour!, min: p.minute! };
}
/** The moment of a Toronto wall-clock time (a day and an hour). */
export function torontoAt(y: number, m: number, day: number, hour: number): Date {
  // start from the time as if UTC, then correct by the offset Toronto has at that moment (twice, for the change days)
  let t = Date.UTC(y, m - 1, day, hour);
  for (let i = 0; i < 2; i++) {
    const p = torontoParts(new Date(t));
    const asUtc = Date.UTC(p.y, p.m - 1, p.day, p.h, p.min);
    t += Date.UTC(y, m - 1, day, hour) - asUtc;
  }
  return new Date(t);
}

export function inWindow(d: Date, fromHour: number, untilHour: number): boolean {
  const h = torontoParts(d).h;
  return h >= fromHour && h < untilHour;
}

/** The first moment at or after `d` inside the sending hours. */
export function nextWindow(d: Date, fromHour: number, untilHour: number): Date {
  const p = torontoParts(d);
  if (p.h >= fromHour && p.h < untilHour) return d;
  if (p.h < fromHour) return torontoAt(p.y, p.m, p.day, fromHour);
  // after the hours: the next day's opening (a calendar day in Toronto)
  const next = new Date(Date.UTC(p.y, p.m - 1, p.day + 1));
  return torontoAt(next.getUTCFullYear(), next.getUTCMonth() + 1, next.getUTCDate(), fromHour);
}

/** Each step of one booking: when it went, or when it is due and when it will go (inside the sending hours). */
export function planSequence(f: SeqFacts, s: SeqSettings = DEFAULT_SETTINGS): PlannedStep[] {
  const out: PlannedStep[] = [];
  const at = (d: Date | null) => (d ? nextWindow(d, s.fromHour, s.untilHour) : null);
  const long = f.returnAt.getTime() - f.pickupAt.getTime() >= s.checkinMinDays * 24 * H;
  const checkinDue = new Date(f.pickupAt.getTime() + s.checkinAfterHours * H);
  const checkinSkip = !s.checkinEnabled ? 'off in settings' : !long ? `rentals under ${s.checkinMinDays} days get none`
    : !f.sent.checkin && checkinDue.getTime() > f.returnAt.getTime() - 6 * H ? 'too close to the return' : undefined;
  out.push({ step: 'checkin', sentAt: f.sent.checkin ?? null, dueAt: checkinSkip ? null : checkinDue, sendAt: checkinSkip || f.sent.checkin ? null : at(checkinDue), ...(checkinSkip && !f.sent.checkin ? { skipped: checkinSkip } : {}) });
  const back = f.returnedAt ?? f.returnAt;
  const askDue = new Date(back.getTime() + s.askAfterMinutes * 60_000);
  const ask = f.sent.ask ?? null;
  out.push({ step: 'ask', sentAt: ask, dueAt: askDue, sendAt: ask ? null : at(askDue) });
  const base = ask ?? at(askDue)!;
  const remDue = new Date(base.getTime() + s.reminderHours * H);
  out.push({ step: 'reminder', sentAt: f.sent.reminder ?? null, dueAt: remDue, sendAt: f.sent.reminder ? null : at(remDue) });
  const finDue = new Date(base.getTime() + s.finalDays * 24 * H);
  out.push({ step: 'final', sentAt: f.sent.final ?? null, dueAt: finDue, sendAt: f.sent.final ? null : at(finDue) });
  return out;
}

// ---------------------------------------------------------------- the hold
export type HoldReason = 'late' | 'km' | 'fuel' | 'cleaning' | 'smoking' | 'damage' | 'tolls' | 'other' | 'incident' | 'dispute';
export const HOLD_LABEL: Record<HoldReason, string> = {
  late: 'Late return', km: 'Kilometres over', fuel: 'Fuel or charging', cleaning: 'Cleaning', smoking: 'Smoking', damage: 'Damage',
  tolls: 'Tolls and tickets', other: 'Other charges', incident: 'Open incident', dispute: 'Card dispute'
};
/** The order a hold's reasons are read in: the return charges first, then the later ones. */
const ORDER: HoldReason[] = ['late', 'km', 'fuel', 'cleaning', 'smoking', 'damage', 'tolls', 'other', 'incident', 'dispute'];

export interface HoldItem { reason: string; label?: string; amount_cents?: number | null; kind?: string; state?: string }
export interface HoldGroup { reason: HoldReason; label: string; count: number; amount_cents: number }

/** The open items of a held booking, by reason, with their total. Empty: nothing holds it. */
export function holdSummary(items: HoldItem[]): HoldGroup[] {
  const by = new Map<HoldReason, HoldGroup>();
  for (const it of items ?? []) {
    const r = (ORDER as string[]).includes(it.reason) ? (it.reason as HoldReason) : 'other';
    const g = by.get(r) ?? { reason: r, label: HOLD_LABEL[r], count: 0, amount_cents: 0 };
    g.count += 1;
    g.amount_cents += Number(it.amount_cents ?? 0) || 0;
    by.set(r, g);
  }
  return ORDER.filter((r) => by.has(r)).map((r) => by.get(r)!);
}

/** One line for the hold list: "Late return $50.00, Tolls and tickets $12.00". */
export function holdLine(items: HoldItem[]): string {
  const money = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  return holdSummary(items).map((g) => (g.amount_cents ? `${g.label} ${money(g.amount_cents)}` : g.label)).join(', ');
}

export const STOP_LABEL: Record<string, string> = {
  renter_said_reviewed: 'The renter said they already left a review',
  staff_marked_reviewed: 'Marked reviewed by staff',
  onsite_review: 'Reviewed on the site',
  google_review: 'Reviewed on Google',
  staff_declined: 'Staff said not to ask',
  unsubscribed: 'The renter unsubscribed',
  too_late: 'Too long after the return'
};
