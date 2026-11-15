// Long-term rentals paid weekly (release 48, migration 2981): the state the booking page reads (rolling_weekly_state) and
// its words. No imports: unit tested in Node (model.test.ts).

export interface RollingState {
  on: boolean; since: string | null; by_name: string | null; end_at: string | null; return_at: string; next_return_at: string | null;
  lead_hours: number; reminded_for: string | null; may_turn_on: boolean; may_change?: boolean; weeks_paid: number;
  next: { total_cents: number; new_return_at: string; link_sent: boolean } | null;
}

const when = (iso: string) => new Date(iso).toLocaleString('en-CA', { timeZone: 'America/Toronto', weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });

/** The card's line: what the booking does now, in plain words. */
export function rollingWords(x: RollingState): { line: string } {
  if (!x.on) return { line: x.may_turn_on ? 'Off. Turn it on for a renter who pays week by week: the car stays out on the calendar until they give notice.' : 'Off.' };
  const paid = `Paid to ${when(x.return_at)}${x.weeks_paid ? ` (${x.weeks_paid} ${x.weeks_paid === 1 ? 'week' : 'weeks'} added)` : ''}.`;
  const end = x.end_at ? ` The renter gave notice: the rental ends ${when(x.end_at)}.` : ' The car stays out until the renter gives notice.';
  const remind = x.next_return_at ? ` ${x.lead_hours} hours before the return, the renter gets the pay link for the next week.` : '';
  return { line: paid + end + remind };
}
