import { door } from '@/server/door';
import { Act } from './Act';
import { $, Card, t } from './ui';

// The owner's side of one booking, on the Admin's and the assistants' booking page (migration 0156): what the owner sees
// of it (shown, hidden until the return or the statement, or not shown at all), with Hide from the owner and Show to the
// owner; and the documented owner deductions (an expense line, a Revenue Share for this booking). The database decides
// who may and refuses with the reason, shown as written.
type Vis = {
  booking_id: string; booking_number: string; has_owner: boolean; owner_name: string | null; visibility: 'shown' | 'until_return' | 'until_statement' | 'never';
  owner_view: 'full' | 'booked' | 'unavailable'; label: string; reason: string | null; at: string | null; by: string | null; may: boolean; no_owner_revenue: boolean;
  on_statement: string | null; default: string; log: Array<{ from: string | null; to: string; reason: string | null; how: string; by: string | null; at: string }>;
};
type Ded = {
  booking_id: string; booking_number: string; has_owner: boolean; may: boolean; may_override: boolean; terms_bps: number; partner: boolean;
  share: { bps: number; terms_bps: number; above_terms: boolean; reason: string; by: string | null; at: string } | null;
  expenses: Array<{ id: string; category: string; amount_cents: number; reason: string; receipt_ref: string | null; by: string | null; at: string; voided_at: string | null; void_reason: string | null }>;
  split: { owner_revenue_cents: number; owner_expense_cents: number; company_share_cents: number; owner_payout_cents: number; paid_out: boolean } | null;
  owner_view: string; on_statement: string | null;
};

const VIS_WORD: Record<string, string> = { shown: 'Shown to the owner', until_return: 'Hidden until the return', until_statement: 'Hidden until the statement', never: 'Not shown to the owner' };
const HOW: Record<string, string> = { staff: '', new_booking: ' (when it was added)', statement: ' (the statement was approved)' };
export const EXPENSE_CATEGORIES: Array<[string, string]> = [['cleaning', 'Cleaning'], ['repair', 'Repair'], ['fuel', 'Fuel'], ['platform_fee', 'Platform fee'], ['other', 'Other']];
const pct = (bps: number) => `${(bps / 100).toFixed(bps % 100 ? 2 : 0)}%`;

export async function OwnerVisibilityPanel({ userId, booking, refresh, aal, va }: { userId: string; booking: string; refresh: string[]; aal?: 'aal1' | 'aal2' | null; va?: string | null }) {
  const v = await door<Vis>(userId, 'ops_read', 'booking_owner_visibility', { booking, ...(va ? { _va: va } : {}) }, aal).catch(() => null);
  if (!v || !v.has_owner) return null;
  const hideOptions: Array<[string, string]> = [['until_statement', 'Hide until the owner statement covering it is approved'], ['until_return', 'Hide until the car is returned'],
    ...(v.no_owner_revenue ? [['never', 'Not shown to the owner (no owner revenue: they see only that the car is unavailable)'] as [string, string]] : [])];
  return (
    <Card title="What the owner sees" testId="owner-visibility" tone={v.owner_view === 'full' ? undefined : 'warn'}
      aside={<span className={`badge${v.owner_view === 'full' ? '' : ' badge--outline'}`} data-testid="owner-visibility-state" data-view={v.owner_view}>{v.owner_view === 'full' ? 'The owner can see it' : v.owner_view === 'unavailable' ? 'Not shown to the owner' : 'Hidden from the owner'}</span>}>
      <p className="small" data-testid="owner-visibility-label">{v.label}{v.reason ? ` Reason: ${v.reason}.` : ''}{v.by ? ` Set by ${v.by}${v.at ? `, ${t(v.at)}` : ''}.` : ''}</p>
      <p className="small muted">The owner&apos;s statement always includes every booking at its true amounts{v.owner_view === 'booked' ? '; approving it shows this booking to the owner' : ''}. The calendar shows the owner the car is busy either way.</p>
      {v.may && !v.on_statement && <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        {v.visibility === 'shown'
          ? <Act ops action="booking_owner_visibility_set" payload={{ booking: v.booking_number }} label="Hide from the owner" testId="owner-hide" refresh={refresh} done="Hidden from the owner."
              fields={[{ name: 'visibility', label: 'Until', type: 'select', options: hideOptions, value: 'until_statement', required: true }, { name: 'reason', label: 'Reason (optional, kept in the history)', type: 'text' }]} />
          : <>
              <Act ops action="booking_owner_visibility_set" payload={{ booking: v.booking_number, visibility: 'shown' }} label="Show to the owner" variant="primary" testId="owner-show" refresh={refresh} done="The owner can see it now."
                fields={[{ name: 'reason', label: 'Reason (optional, kept in the history)', type: 'text' }]} />
              <Act ops action="booking_owner_visibility_set" payload={{ booking: v.booking_number }} label="Change how it is hidden" refresh={refresh} done="Saved."
                fields={[{ name: 'visibility', label: 'Until', type: 'select', options: hideOptions, value: v.visibility, required: true }, { name: 'reason', label: 'Reason (optional)', type: 'text' }]} />
            </>}
      </div>}
      {v.on_statement && <p className="small muted">On the approved statement {v.on_statement}: the owner sees it.</p>}
      {v.log.length > 0 && <details><summary className="link small">History ({v.log.length})</summary>
        <ul className="ad-list small" data-testid="owner-visibility-log">{v.log.map((g, i) => <li key={i}>{t(g.at)}: {VIS_WORD[g.to] ?? g.to}{HOW[g.how] ?? ''}{g.by ? ` by ${g.by}` : ''}{g.reason ? `: ${g.reason}` : ''}</li>)}</ul></details>}
    </Card>
  );
}

export async function OwnerDeductionsPanel({ userId, booking, refresh, aal, va }: { userId: string; booking: string; refresh: string[]; aal?: 'aal1' | 'aal2' | null; va?: string | null }) {
  const d = await door<Ded>(userId, 'ops_read', 'booking_owner_deductions', { booking, ...(va ? { _va: va } : {}) }, aal).catch(() => null);
  if (!d || !d.has_owner) return null;
  const live = d.expenses.filter((e) => !e.voided_at);
  const editable = d.may && !d.on_statement;
  return (
    <Card title="Owner deductions on this booking" testId="owner-deductions"
      aside={<span className="small muted">{d.partner ? 'Partner commission' : 'Revenue Share'} in the car&apos;s terms: {pct(d.terms_bps)}</span>}>
      <p className="small muted">Every deduction is itemized on the owner&apos;s statement and in their portal with its reason, and kept in the booking history. An expense comes off before Owner Revenue; the {d.partner ? 'commission' : 'Revenue Share'} applies to what is left.</p>
      {live.length ? <ul className="ad-list" data-testid="owner-expenses">{live.map((e) => (
        <li key={e.id}><b>{EXPENSE_CATEGORIES.find(([k]) => k === e.category)?.[1] ?? e.category} {$(e.amount_cents)}</b><span className="ad-sub">{e.reason}{e.receipt_ref ? ` · receipt ${e.receipt_ref}` : ''}{e.by ? ` · ${e.by}` : ''}, {t(e.at)}</span>
          {editable && <Act ops action="booking_owner_expense_void" payload={{ id: e.id }} label="Remove" variant="quiet" refresh={refresh} done="Removed." fields={[{ name: 'reason', label: 'Why it is removed', type: 'text', required: true }]} />}</li>))}</ul>
        : <p className="small muted">No booking expense.</p>}
      <p className="small" data-testid="owner-share">{d.share ? <>{d.partner ? 'Commission' : 'Revenue Share'} for this booking: <b>{pct(d.share.bps)}</b>{d.share.above_terms ? ' (above the signed terms, by an Admin)' : ''}: {d.share.reason}{d.share.by ? ` · ${d.share.by}` : ''}</> : `${d.partner ? 'Commission' : 'Revenue Share'}: the car's terms (${pct(d.terms_bps)}).`}</p>
      {d.split && <p className="small muted" data-testid="owner-split">So far: Owner Revenue {$(d.split.owner_revenue_cents)}{d.split.owner_expense_cents ? ` after ${$(d.split.owner_expense_cents)} of expenses` : ''}, {d.partner ? 'commission' : 'Revenue Share'} {$(d.split.company_share_cents)}, owner payout {$(d.split.owner_payout_cents)}.</p>}
      {d.on_statement && <p className="small muted">On the approved statement {d.on_statement}: a later cost goes on the owner&apos;s account as an owner cost.</p>}
      {editable && <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        <Act ops action="booking_owner_expense_add" payload={{ booking: d.booking_number }} label="Add a booking expense" testId="owner-expense-add" refresh={refresh} done="Added: it comes off before Owner Revenue."
          fields={[{ name: 'category', label: 'Category', type: 'select', options: EXPENSE_CATEGORIES, value: 'cleaning', required: true }, { name: 'amount_cents', label: 'Amount', type: 'money', required: true },
            { name: 'reason', label: 'Reason the owner reads', type: 'textarea', required: true }, { name: 'receipt_ref', label: 'Receipt (number or link, optional)', type: 'text' }]} />
        <Act ops action="booking_owner_share_set" payload={{ booking: d.booking_number }} label={`Set the ${d.partner ? 'commission' : 'Revenue Share'} for this booking`} testId="owner-share-set" refresh={refresh} done="Saved."
          fields={[{ name: 'bps', label: `${d.partner ? 'Commission' : 'Revenue Share'} (%; the terms allow up to ${pct(d.terms_bps)})`, type: 'percent', required: true, value: d.share?.bps ?? d.terms_bps },
            { name: 'reason', label: 'Reason the owner reads', type: 'textarea', required: true },
            ...(d.may_override ? [{ name: 'above_terms', label: 'Above the signed terms (an Admin only; the reason is required)', type: 'bool' as const }] : [])]} />
        {d.share && <Act ops action="booking_owner_share_set" payload={{ booking: d.booking_number, bps: '' }} label="Back to the car's terms" variant="quiet" refresh={refresh} done="Back to the car's terms."
          fields={[{ name: 'reason', label: 'Reason (optional)', type: 'text' }]} />}
      </div>}
    </Card>
  );
}
