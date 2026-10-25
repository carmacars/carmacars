'use client';
import { useId } from 'react';

// On Add a rental and on an offer (migration 0156): what the car's owner sees of the booking, set from Program settings
// and changed here by those who may (an Admin, customer service, fleet); and on Add a rental the booking's documented
// owner deductions (an expense line, a Revenue Share for this booking), for those who may change fees. The database
// checks each again.
export interface OwnerDefaults { default: string; visibility: string; may: boolean; may_deduct?: boolean; may_override?: boolean }
export interface OwnerChoiceValue { visibility: string; reason: string; exp_category: string; exp_amount: string; exp_reason: string; exp_receipt: string; share: string; share_reason: string; above: boolean }
export const ownerChoiceInitial = (d: OwnerDefaults | null | undefined, visibility?: string): OwnerChoiceValue => ({
  visibility: visibility ?? d?.visibility ?? 'shown', reason: '', exp_category: 'cleaning', exp_amount: '', exp_reason: '', exp_receipt: '', share: '', share_reason: '', above: false });
export const VISIBILITY: Array<[string, string]> = [
  ['shown', 'Show to the owner right away'], ['until_return', 'Hide from the owner until the return'],
  ['until_statement', 'Hide from the owner until the statement is approved'], ['never', 'Not shown to the owner (no owner revenue: shows as unavailable)']];
const CATS: Array<[string, string]> = [['cleaning', 'Cleaning'], ['repair', 'Repair'], ['fuel', 'Fuel'], ['platform_fee', 'Platform fee'], ['other', 'Other']];
const cents = (v: string) => { const n = Number(v.replace(/[$,\s]/g, '')); return v.trim() && Number.isFinite(n) && n > 0 ? Math.round(n * 100) : undefined; };

/** What the form sends: only what the person may set. */
export function ownerChoicePayload(v: OwnerChoiceValue, d: OwnerDefaults | null | undefined, withDeductions = false): Record<string, unknown> {
  if (!d) return {};
  const out: Record<string, unknown> = {};
  if (d.may) { out.owner_visibility = v.visibility; if (v.reason.trim()) out.owner_visibility_reason = v.reason.trim(); }
  if (withDeductions && d.may_deduct) {
    const a = cents(v.exp_amount);
    if (a) out.owner_expenses = [{ category: v.exp_category, amount_cents: a, reason: v.exp_reason.trim(), receipt_ref: v.exp_receipt.trim() || undefined }];
    const pct = Number(v.share.replace('%', ''));
    if (v.share.trim() && Number.isFinite(pct)) out.owner_share = { bps: Math.round(pct * 100), reason: v.share_reason.trim(), above_terms: v.above || undefined };
  }
  return out;
}

export function OwnerChoice({ d, value, onChange, withDeductions = false, testPrefix }: { d: OwnerDefaults | null | undefined; value: OwnerChoiceValue; onChange: (v: OwnerChoiceValue) => void; withDeductions?: boolean; testPrefix: string }) {
  const id = useId();
  if (!d || (!d.may && !(withDeductions && d.may_deduct))) return null;
  const set = <K extends keyof OwnerChoiceValue>(k: K, x: OwnerChoiceValue[K]) => onChange({ ...value, [k]: x });
  return (
    <div className="stack" data-testid={`${testPrefix}-owner`}>
      {d.may && <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor={`${id}-vis`}>What the owner sees</label>
          <select className="select" id={`${id}-vis`} value={value.visibility} onChange={(e) => set('visibility', e.target.value)} data-testid={`${testPrefix}-owner-visibility`}>
            {VISIBILITY.map(([k, l]) => <option key={k} value={k}>{l}{k === d.visibility ? ' (the default)' : ''}</option>)}</select>
          <p className="hint">The owner&apos;s statement always includes every booking at its true amounts. A hidden booking shows to the owner as Booked, with its dates.</p></div>
        {value.visibility !== 'shown' && <div className="field ad-field"><label className="label" htmlFor={`${id}-why`}>Reason (optional, kept in the history)</label>
          <input className="input" id={`${id}-why`} value={value.reason} onChange={(e) => set('reason', e.target.value)} data-testid={`${testPrefix}-owner-reason`} /></div>}
      </div>}
      {withDeductions && d.may_deduct && <details data-testid={`${testPrefix}-owner-deductions`}><summary className="link small">Owner deductions on this booking (optional)</summary>
        <p className="hint">Shown to the owner, itemized with the reason, on their statement and in their portal.</p>
        <div className="ad-fields">
          <div className="field ad-field"><label className="label" htmlFor={`${id}-cat`}>Booking expense</label>
            <select className="select" id={`${id}-cat`} value={value.exp_category} onChange={(e) => set('exp_category', e.target.value)}>{CATS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
          <div className="field ad-field"><label className="label" htmlFor={`${id}-amt`}>Amount ($)</label>
            <input className="input" id={`${id}-amt`} inputMode="decimal" value={value.exp_amount} onChange={(e) => set('exp_amount', e.target.value)} data-testid={`${testPrefix}-owner-expense-amount`} /></div>
          <div className="field ad-field ad-field--wide"><label className="label" htmlFor={`${id}-er`}>Reason the owner reads</label>
            <input className="input" id={`${id}-er`} value={value.exp_reason} onChange={(e) => set('exp_reason', e.target.value)} data-testid={`${testPrefix}-owner-expense-reason`} /></div>
          <div className="field ad-field"><label className="label" htmlFor={`${id}-rc`}>Receipt (number or link, optional)</label>
            <input className="input" id={`${id}-rc`} value={value.exp_receipt} onChange={(e) => set('exp_receipt', e.target.value)} /></div>
          <div className="field ad-field"><label className="label" htmlFor={`${id}-sh`}>Revenue Share for this booking (%; empty: the car&apos;s terms)</label>
            <input className="input" id={`${id}-sh`} inputMode="decimal" value={value.share} onChange={(e) => set('share', e.target.value)} /></div>
          {value.share.trim() && <div className="field ad-field ad-field--wide"><label className="label" htmlFor={`${id}-sr`}>Why (the owner reads it)</label>
            <input className="input" id={`${id}-sr`} value={value.share_reason} onChange={(e) => set('share_reason', e.target.value)} /></div>}
          {value.share.trim() && d.may_override && <label className="check" htmlFor={`${id}-ab`}><input type="checkbox" id={`${id}-ab`} checked={value.above} onChange={(e) => set('above', e.target.checked)} /> <span>Above the car&apos;s signed terms (an Admin only)</span></label>}
        </div></details>}
    </div>
  );
}
