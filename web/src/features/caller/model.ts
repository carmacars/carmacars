// The caller pop-up and renter notes (migration 0800): the shapes of the caller_live and renter_notes reads, and the words
// the pop-up shows. No imports, so the unit tests run it as is (model.test.ts).

export type Portal = 'admin' | 'va';
export interface CallerNote { id: string; body: string; at: string; author: string; role: 'admin' | 'cs' | 'sales' | 'fleet' | 'finance'; booking_number: string | null; from_call: boolean }
export interface CallerDeposit { required_cents: number; held_cents: number; how: string | null; state: 'held' | 'waived' | 'released' | 'failed' | 'none' | 'not_taken' }
export interface CallerBalance { owed_cents: number; rental_cents: number; charges_cents: number; overdue: boolean }
export interface CallerRequest { kind: 'booking' | 'change' | 'question' | 'task'; label: string; booking_number: string | null; at: string }
export interface CallerRenter {
  id: string; name: string; identity_status: string; is_blocked: boolean;
  booking: { number: string; status: string; car: string | null; pickup_at: string; return_at: string; active: boolean } | null;
  balance: CallerBalance; deposit: CallerDeposit | null; requests: CallerRequest[]; notes: CallerNote[]; notes_count: number;
}
export interface LiveCall {
  id: string; thread_id: string; number: string; display: string; at: string; answered_at: string | null; ended_at: string | null; missed: boolean; live: boolean;
  kind: 'staff' | 'renter' | 'owner' | 'lead' | 'unknown'; who: string; lead_id: string | null; owner_id: string | null; renter: CallerRenter | null;
  /** r35 (0970): fleet when the call is about a pickup, a return, a delivery or a car on rent (it rings for Fleet first) */
  lane?: 'fleet' | 'cs';
}
export interface CallerLive { at: string; calls: LiveCall[] }
export interface NotesRead { renter_id: string; notes: CallerNote[]; can_remove: boolean }

/** How often the portals ask while in use (lib/poll slows it to once a minute when idle, never in a hidden tab). */
export const CALLER_POLL_MS = 10_000;
/** The calls a person closed are remembered (in this browser) for this long. */
export const DISMISS_KEEP_MS = 2 * 60 * 60_000;

export const money = (cents: number | null | undefined) =>
  `$${((cents ?? 0) / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

export const ROLE_WORDS: Record<CallerNote['role'], string> = { admin: 'Admin', cs: 'Customer service', sales: 'Sales', fleet: 'Fleet', finance: 'Finance' };

/** The calls to show: those not closed by this person, newest first. */
export function visibleCalls(calls: LiveCall[], dismissed: Record<string, number>): LiveCall[] {
  return calls.filter((c) => !(c.id in dismissed)).sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));
}

/** Closed calls older than the keep time are forgotten, so the stored list stays small. */
export function pruneDismissed(d: Record<string, number>, now: number): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [k, v] of Object.entries(d)) if (typeof v === 'number' && now - v < DISMISS_KEEP_MS) out[k] = v;
  return out;
}

/** The headline: who is on the phone. */
export function callerTitle(c: LiveCall): string {
  if (c.kind === 'unknown') return 'Unknown caller';
  if (c.kind === 'renter' && c.renter) return c.renter.name;
  return c.who;
}
export const KIND_WORDS: Record<LiveCall['kind'], string> = { staff: 'Staff', renter: 'Renter', owner: 'Owner', lead: 'Lead', unknown: 'Not matched' };

/** The state of the call in a few words. */
export function callState(c: LiveCall): string {
  if (c.live) return c.answered_at ? 'On the phone now' : 'Ringing now';
  if (c.missed) return 'Missed call';
  return 'Call ended';
}

export function depositWords(d: CallerDeposit | null): string {
  if (!d) return 'No booking';
  switch (d.state) {
    case 'held': return `${money(d.held_cents)} held${d.how === 'card_hold' ? ' on the card' : ''}`;
    case 'waived': return 'Waived';
    case 'released': return 'Released';
    case 'failed': return `Not taken: the card was declined (${money(d.required_cents)} due)`;
    case 'none': return 'None needed';
    default: return `Not taken yet (${money(d.required_cents)})`;
  }
}

export function balanceWords(b: CallerBalance): string {
  if (!b.owed_cents) return 'Nothing owed';
  return `${money(b.owed_cents)} owed${b.overdue ? ', overdue' : ''}`;
}

export function bookingWords(r: CallerRenter): string {
  const b = r.booking;
  if (!b) return 'No active or upcoming booking';
  return `${b.active ? 'On rent' : 'Next'}: ${b.number}${b.car ? `, ${b.car}` : ''}`;
}

/** The renter's full page in the person's portal. */
export function renterHref(portal: Portal, id: string): string {
  return portal === 'admin' ? `/admin/renters/${id}` : `/staff/renters?id=${encodeURIComponent(id)}`;
}
export function bookingHref(portal: Portal, n: string): string {
  return portal === 'admin' ? `/admin/bookings/${encodeURIComponent(n)}` : `/staff/bookings/${encodeURIComponent(n)}`;
}

/** Why a note cannot be saved (null: it can). The database checks the same. */
export function noteProblem(body: string): string | null {
  const s = body.trim();
  if (!s) return 'Write the note';
  if (s.length > 4000) return 'Keep a note under 4,000 characters';
  return null;
}
