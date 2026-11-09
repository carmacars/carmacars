// Close ended trips (1063). Pure: the page and the unit tests share it.
export interface EndedMoney { deposit_cents: number; deposit_status: string | null; hold_expired: boolean; deposit_waived: boolean; deposit_due: boolean; owed_cents: number; late_fee_cents: number; statement: boolean }
export interface EndedRow { booking_id: string; booking_number: string; status: 'confirmed' | 'on_rent' | 'returned'; pickup_at: string; return_at: string; handed_over_at: string | null; checked_in_at: string | null;
  vehicle: string; plate: string | null; renter: string | null; hours_past: number; money: EndedMoney; decision: { decision: 'full' | 'balance' | 'late_fee'; status: string; at: string; by: string | null } | null }

export const DEPOSIT_WORDS: Record<'full' | 'balance' | 'late_fee', string> = { full: 'Release in full', balance: 'Deduct the balance owed', late_fee: 'Deduct the late fee' };
export const depositChoices = (): Array<[string, string]> => [['balance', DEPOSIT_WORDS.balance], ['late_fee', DEPOSIT_WORDS.late_fee], ['full', DEPOSIT_WORDS.full], ['', 'Decide later']];
export const pastDue = (h: number) => (h < 24 ? `${Math.round(h)} h` : `${Math.floor(h / 24)} d`);
const $ = (c: number) => `$${(c / 100).toFixed(2)}`;

/** The deposit cell in words. */
export function moneyLine(m: EndedMoney): string {
  if (m.deposit_waived) return 'Deposit waived';
  if (m.hold_expired) return `Hold of ${$(m.deposit_cents)} expired: settled by expiry when closed`;
  if (m.deposit_due) return 'No deposit taken';
  if (!m.deposit_cents) return 'No deposit';
  return `${$(m.deposit_cents)} ${m.deposit_status === 'held' ? 'held' : m.deposit_status ?? ''}${m.owed_cents ? `, ${$(m.owed_cents)} owed` : ''}${m.late_fee_cents ? ` (late ${$(m.late_fee_cents)})` : ''}`;
}
