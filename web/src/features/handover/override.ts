// The Admin override of a pickup or a return recorded by hand, and the past trip (migration 0770). What the booking
// page (Admin and every staff portal) and the field job show, decided from app.override_view: the checks that stop
// the pickup or the return now, the requests waiting for an Admin, and whether a past trip can be recorded. The
// database decides who may do what; this only chooses the words and the buttons.

export interface OverrideCheck { code: string; label: string }
export interface OverrideRequest {
  id: string; action: 'pickup' | 'return' | 'past_trip' | 'book_now'; status: string; reason: string; requested_at: string;
  requested_by: string | null; mine: boolean; checks: OverrideCheck[] | null; payload?: Record<string, unknown> | null;
}
export interface OverrideRead {
  booking_id: string; booking_number: string; status: string; kind: 'pickup' | 'return' | null; admin: boolean;
  blockers: OverrideCheck[]; problem: string | null; past_trip: boolean; pickup_at: string; return_at: string; requests: OverrideRequest[];
}

export const ACTION_WORDS: Record<OverrideRequest['action'], string> = { pickup: 'the pickup', return: 'the return', past_trip: 'a past trip', book_now: 'booking the offer now' };

export interface OverrideView {
  show: boolean;
  /** the pickup or the return is blocked: list and the button */
  blocked: boolean;
  kind: 'pickup' | 'return' | null;
  heading: string;
  /** Admin: "Override and record"; staff: "Ask an Admin to override" */
  overrideLabel: string;
  overrideDone: string;
  pastTrip: boolean;
  pastLabel: string;
  pastDone: string;
  /** the requests an Admin approves here (or the requester cancels) */
  requests: Array<OverrideRequest & { words: string; canDecide: boolean; canCancel: boolean }>;
}

export function overrideView(r: OverrideRead | null): OverrideView {
  const none: OverrideView = { show: false, blocked: false, kind: null, heading: '', overrideLabel: '', overrideDone: '', pastTrip: false, pastLabel: '', pastDone: '', requests: [] };
  if (!r) return none;
  const kind = r.kind;
  const blocked = !!kind && r.blockers.length > 0 && !r.problem;
  const requests = (r.requests ?? []).filter((q) => q.status === 'requested').map((q) => ({
    ...q, words: ACTION_WORDS[q.action] ?? q.action, canDecide: r.admin, canCancel: q.mine || r.admin
  }));
  const pastTrip = !!r.past_trip && !requests.some((q) => q.action === 'past_trip');
  const what = kind === 'return' ? 'return' : 'pickup';
  return {
    show: blocked || pastTrip || requests.length > 0,
    blocked: blocked && !requests.some((q) => q.action === kind),
    kind,
    heading: kind === 'return' ? 'What stops the return now' : 'What stops the pickup now',
    overrideLabel: r.admin ? `Override and record the ${what}` : `Ask an Admin to override the ${what}`,
    overrideDone: r.admin ? `The ${what} is recorded with the override. It is on the booking's history; Admins are told.` : `Sent to an Admin. Once they approve, the ${what} is recorded with the time you entered.`,
    pastTrip,
    pastLabel: r.admin ? 'Record a past trip' : 'Ask to record a past trip',
    pastDone: r.admin ? 'The trip is recorded: the booking is Returned, so the deposit can be settled.' : 'Sent to an Admin. Once they approve, the trip is recorded with the times you entered.',
    requests
  };
}

/** One line for a request: who asked, what, and the checks it passes. */
export function requestLine(q: OverrideRequest): string {
  const who = q.requested_by ? `${q.requested_by} asks` : 'Asked';
  const checks = (q.checks ?? []).map((c) => c.label.charAt(0).toLowerCase() + c.label.slice(1)).join('; ');
  return `${who} to override ${ACTION_WORDS[q.action] ?? q.action}: ${q.reason}${checks ? `. It passes: ${checks}` : ''}.`;
}
