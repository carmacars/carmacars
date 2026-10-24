// Relative imports with their extension: the unit tests run this file in Node directly (terms-shared.test.ts).
import { money } from '../../lib/format.ts';
import { pctOf } from './shared.ts';

// Owner terms per car (0135): the types and words shared by the Admin table (CarTerms.tsx) and the owner portal
// (OwnerTerms.tsx), outside the client component so server pages can call them.
export type Money = { insurance_fee_cents: number | null; tracker_fee_cents: number | null; revenue_share_bps: number | null; install_fee_cents?: number | null };
export interface Period extends Money { from: string | null; to: string | null; source: string; label: string; current: boolean; future: boolean }
export interface Change { id: string; kind: string; status: string; created_at: string; notice_on: string; effective_from: string; before: Money; after: Money; reason: string | null;
  cancelled_reason: string | null; signed_method: string | null; owner_signed_at: string | null; notice: boolean; label: string; can_cancel?: boolean }
export interface CarTermsRow { vehicle_id: string; name: string; plate: string | null; status: string; onboarding_status: string | null; supply_type: string; shareholder: boolean;
  state: 'not_set' | 'pending' | 'signed' | 'fixed'; enrolled: boolean; schedule_number: string | null; signed_at: string | null; mode: string; method: string | null;
  current: Required<Money>; since: string | null; sources?: Record<string, string> | null; scheduled: Period[]; periods: Period[]; changes: Change[];
  awaiting: { change_id: string; effective_from: string; created_at: string } | null;
  editable?: { fees: boolean; install: boolean; mode: boolean } | null; options?: Record<string, Array<{ method: string; label: string; recommended: boolean }>> | null }
export interface CarTermsData { today: string; notice_days: number; earliest_raise: string; owner_id?: string | null; cars: CarTermsRow[] }

export const fmtDay = (iso?: string | null) => (iso ? new Date(`${iso.slice(0, 10)}T12:00:00Z`).toLocaleDateString('en-CA', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' }) : '');
export const pc = (bps: number | null | undefined) => (bps === null || bps === undefined ? '' : `${pctOf(bps)}%`);
export const m = (c: number | null | undefined) => (c === null || c === undefined ? '' : money(c, { cents: true }));
export const STATE_TEXT: Record<string, string> = { not_set: 'Not approved yet', pending: 'Not signed yet', signed: 'Signed', fixed: 'Fixed terms' };
export const STATUS_TEXT: Record<string, string> = { applied: 'Done', noticed: 'Notice given', awaiting_signature: 'Waiting for the owner', cancelled: 'Cancelled' };

export function stateLine(c: CarTermsRow) {
  if (c.state === 'signed') return `Signed ${c.schedule_number ?? ''}${c.signed_at ? `, ${fmtDay(c.signed_at)}` : ''}`;
  if (c.state === 'pending') return `${c.schedule_number ?? 'Vehicle Schedule'} not signed yet`;
  if (c.state === 'fixed') return c.shareholder ? 'Shareholder: 90/10, no fees' : 'Fixed terms';
  return 'Not approved yet';
}
export function sinceLine(c: CarTermsRow) {
  if (c.state === 'signed') return c.since ? fmtDay(c.since) : 'From the Enrollment Date';
  if (c.state === 'pending') return 'Once signed';
  if (c.state === 'not_set') return 'Once approved and signed';
  return c.since ? fmtDay(c.since) : '';
}

