// The deposit in plain words for staff screens (0155): never the database's codes.
export const DEPOSIT_METHOD: Record<string, string> = { card_hold: 'Held on the card', charged: 'Charged to the card', offline: 'Cash or e-Transfer', carried_over: 'Carried over from the last period' };
export const DEPOSIT_STATUS: Record<string, string> = { pending: 'Not taken yet', held: 'Held', captured: 'Collected', settled: 'Settled', failed: 'Not taken (declined or the hold lapsed)', carried_forward: 'Moved to the next period' };
export const depositMethod = (m: unknown) => (typeof m === 'string' ? DEPOSIT_METHOD[m] ?? m.replace(/_/g, ' ') : '');
export const depositStatus = (s: unknown) => (typeof s === 'string' ? DEPOSIT_STATUS[s] ?? s.replace(/_/g, ' ') : '');

/** Release 47: the deposit in one chip beside a booking's status, for every staff role (the owner's report: Sales could not
 *  easily tell whether a hold was taken). The tone (a Badge status key) and the words: a live hold or a collected deposit
 *  is dark, nothing taken yet amber, a declined or lapsed hold red. Null when the booking takes no deposit. */
export function depositChip(bookingStatus: string, depositCents: number, d: { status?: unknown; method?: unknown; amount_cents?: unknown } | null, waived = false,
  pending?: DepositPending | null): { tone: string; text: string } | null {
  if (!['pending_payment', 'confirmed', 'on_rent', 'returned'].includes(bookingStatus)) return null;
  if (waived) return { tone: 'done', text: 'Deposit waived' };
  // r48 (2970): the car went out with the deposit still owed
  if (pending?.pending && !(d && ['held', 'captured', 'settled'].includes(String(d.status)))) {
    return { tone: pending.overdue ? 'failed' : 'pending_approval', text: `Deposit pending${dollars(Number(pending.amount_cents ?? depositCents) || 0)}` };
  }
  if (!d) return depositCents > 0 ? { tone: 'pending_approval', text: 'No deposit hold yet' } : null;
  const money = dollars(Number(d.amount_cents ?? depositCents) || 0);
  const how = d.method === 'card_hold' ? ' on the card' : d.method === 'charged' ? ' charged to the card' : d.method === 'offline' ? ' by cash or e-Transfer' : '';
  switch (d.status) {
    case 'held': return { tone: 'succeeded', text: `Deposit held${money}${how}` };
    case 'captured': return { tone: 'succeeded', text: `Deposit collected${money}${how}` };
    case 'settled': return { tone: 'done', text: `Deposit settled${money}` };
    case 'failed': return { tone: 'failed', text: 'Deposit hold failed: declined or lapsed' };
    case 'carried_forward': return { tone: 'done', text: 'Deposit moved to the next period' };
    default: return { tone: 'pending_approval', text: 'No deposit hold yet' };
  }
}

/** r48 (2970): a car out with the deposit still owed (server_deposit_pending_state). */
export interface DepositPending { pending: boolean; amount_cents?: number; since?: string; reason?: string; by_name?: string | null; overdue?: boolean;
  last_try_on?: string | null; last_try_result?: string | null; last_link_on?: string | null; retry_on?: boolean }

const dollars = (amt: number) => (amt ? ` $${(amt / 100).toLocaleString('en-CA', { minimumFractionDigits: amt % 100 ? 2 : 0, maximumFractionDigits: 2 })}` : '');

/** r48 (2970): one line under the chip for staff: why the car went out owing it, and what the morning job did. */
export function depositPendingLine(p: DepositPending | null | undefined): string | null {
  if (!p?.pending) return null;
  const who = p.by_name ? ` by ${p.by_name}` : '';
  const why = p.reason ? `: ${p.reason}` : '';
  const tried = p.retry_on === false ? ' The morning retry is off (Program settings).'
    : p.last_try_on ? ` Last morning try ${p.last_try_on}${p.last_try_result ? ` (${p.last_try_result})` : ''}${p.last_link_on ? `, link sent ${p.last_link_on}` : ''}.`
    : ' Each morning the saved card is tried once, then the deposit link goes to the renter.';
  return `The car went out with the deposit owed${who}${why}.${tried}${p.overdue ? ' Still owed after 48 hours: take it on the Money tab.' : ''}`;
}
