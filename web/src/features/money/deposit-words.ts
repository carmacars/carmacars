// The deposit in plain words for staff screens (0155): never the database's codes.
export const DEPOSIT_METHOD: Record<string, string> = { card_hold: 'Held on the card', charged: 'Charged to the card', offline: 'Cash or e-Transfer', carried_over: 'Carried over from the last period' };
export const DEPOSIT_STATUS: Record<string, string> = { pending: 'Not taken yet', held: 'Held', captured: 'Collected', settled: 'Settled', failed: 'Not taken (declined or the hold lapsed)', carried_forward: 'Moved to the next period' };
export const depositMethod = (m: unknown) => (typeof m === 'string' ? DEPOSIT_METHOD[m] ?? m.replace(/_/g, ' ') : '');
export const depositStatus = (s: unknown) => (typeof s === 'string' ? DEPOSIT_STATUS[s] ?? s.replace(/_/g, ' ') : '');
