import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, BookingLink, Card, Filters, PageHead, Table, Tabs, d, label, t } from '@/features/admin/ui';
import { pctBps, statusWords, type CommissionRow, type MonthProgress } from '@/features/sales/Commissions';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Staff commissions', path: '/admin/money/commissions', noindex: true, description: 'Approve and pay staff commissions; prices to review; sourcing claims.' });
type R = Record<string, unknown>;
type Person = { staff_id: string; name: string; function: string; scheme: string; commission_bps: number | null; month: MonthProgress; pending_count: number; pending_cents: number;
  approvable_count: number; approved_cents: number; approved_count: number; not_earned_cents: number; paid_cents: number };
type Row = CommissionRow & { staff_id: string; name: string; approvable: boolean; paid_from: string };
type Data = { today: string; settings: Record<string, number>; people: Person[]; rows: Row[];
  payouts: Array<{ id: string; name: string; staff_id: string; method: string; reference: string | null; paid_on: string; pay_period: string | null; amount_cents: number; note: string | null }> };
type Reviews = { prices: R[]; claims: R[] };
type OwnerReq = { id: string; owner_id: string; owner: string; staff: string; mode: string | null; status: 'pending' | 'approved' | 'declined'; kind: 'flat' | 'percent'; amount_cents: number | null;
  rate_bps: number | null; base: string | null; months: number | null; while_enrolled: boolean; asked: string; approved: string | null; changed: boolean; note: string | null; admin_note: string | null;
  stage: string; cars: number; blocked: string | null; earned_cents: number; created_at: string; decided_at: string | null; revisions: number };
const STAGE: Record<string, string> = { applied: 'Applied', declined: 'Application declined', approved: 'Approved', car_live: 'Car live', first_paid_rental: 'First paid rental' };

const METHODS: Array<[string, string]> = [['e_transfer', 'e-Transfer'], ['bank_transfer', 'Bank transfer'], ['wise', 'Wise'], ['cash', 'Cash'], ['pay_statement', 'On the monthly pay statement'], ['other', 'Another way']];
const FROM: Record<string, string> = { carmacars_expense: 'Owner brought in: a CarmaCars expense, never before Owner Revenue', owner_revenue: 'Owner\'s car: a kickback before Owner Revenue', carmacars_commission: 'Partner\'s car: from CarmaCars\' commission', carmacars: 'CarmaCars-owned car: a CarmaCars expense' };

// Admin > Money > Staff commissions (migration 0058): each person's commissions by status, approval (one by one or a
// person's month at once; a Sales month after it ends), payments recorded by hand (nothing is paid automatically), the
// prices typed by hand that were flagged, and staff who say they sourced a website request.
export default async function StaffCommissions({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/money/commissions'), searchParams]);
  const tab = sp.tab ?? 'commissions';
  const base = '/admin/money/commissions';
  const tabs = <Tabs current={`${base}?tab=${tab}`} items={[[`${base}?tab=commissions`, 'Commissions'], [`${base}?tab=payments`, 'Payments made'], [`${base}?tab=prices`, 'Prices to review'], [`${base}?tab=claims`, 'Sourcing claims'], [`${base}?tab=owners`, 'Owner requests']]} />;
  if (tab === 'owners') {
    // 0340: Sales ask for a commission on each owner they bring in; nothing accrues until it is approved here
    const o = await read<{ requests: OwnerReq[] }>('owner_recruit_requests', { status: sp.status ?? '' });
    return (<><PageHead title="Owner commission requests" />{tabs}
      <p className="small muted">Each owner a salesperson brings in has one request: a flat amount (earned at the owner&apos;s first paid rental) or a percent of the company&apos;s share or of the cars&apos; rental revenue, for a number of months or for as long as the car is with us. Approve it as asked, approve other terms, or decline it. Nothing accrues before it is approved; the commissions then come here for approval like any other. A CarmaCars expense: the owner&apos;s revenue is unchanged.</p>
      <Filters base={`${base}?tab=owners`} name="status" value={sp.status ?? ''} sp={sp} options={[['', 'All'], ['pending', 'Waiting'], ['approved', 'Approved'], ['declined', 'Declined']]} />
      <Table<OwnerReq & R> testId="owner-requests" rows={o.requests as Array<OwnerReq & R>} rowKey={(r) => r.id} empty="No requests." cols={[
        { key: 'owner', label: 'Owner', className: 'wrap', render: (r) => <><Link prefetch={false} className="link" href={`/admin/owners/${r.owner_id}`}>{r.owner}</Link><span className="ad-sub">{STAGE[r.stage] ?? r.stage}, {r.cars} car{r.cars === 1 ? '' : 's'}</span></> },
        { key: 'staff', label: 'Salesperson', render: (r) => <>{r.staff}{r.mode ? <span className="ad-sub">{r.mode === 'remote' ? 'remote' : 'in person'}</span> : null}</> },
        { key: 'asked', label: 'Asked', className: 'wrap', render: (r) => <>{r.asked}{r.note ? <span className="ad-sub">{r.note}</span> : null}</> },
        { key: 'status', label: 'Decision', className: 'wrap', render: (r) => r.status === 'pending' ? <span className="ad-pill">Waiting</span>
          : r.status === 'declined' ? <><span className="ad-pill ad-pill--red">Declined</span>{r.admin_note ? <span className="ad-sub">{r.admin_note}</span> : null}</>
          : <><span className="ad-pill ad-pill--ok">Approved{r.changed ? ', changed' : ''}</span><span className="ad-sub">{r.approved}{r.admin_note ? `. ${r.admin_note}` : ''}</span></> },
        { key: 'earned_cents', label: 'Earned', num: true, render: (r) => $(r.earned_cents) },
        { key: 'act', label: '', render: (r) => r.status !== 'pending' ? '' : r.blocked ? <span className="small">{r.blocked}</span> : <span className="ad-actions">
          <Act action="owner_recruit_decide" payload={{ id: r.id, decision: 'approve' }} label="Approve" variant="primary" testId={`orq-approve-${r.id}`} refresh={[`${base}?tab=owners`]} done="Approved."
            confirm={`Approve ${r.asked} for ${r.staff}.`} fields={[{ name: 'note', label: 'Note (optional)', type: 'text' }]} />
          <Act action="owner_recruit_decide" payload={{ id: r.id, decision: 'approve' }} label="Change and approve" testId={`orq-change-${r.id}`} refresh={[`${base}?tab=owners`]} done="Approved with your terms." fields={[
            { name: 'kind', label: 'Flat or percent', type: 'select', required: true, value: r.kind, options: [['flat', 'A flat amount'], ['percent', 'A percent']] },
            { name: 'amount_cents', label: 'Flat amount', type: 'money', value: r.amount_cents ?? '' },
            { name: 'rate_bps', label: 'Percent', type: 'percent', value: r.rate_bps ?? '' },
            { name: 'base', label: 'Percent of', type: 'select', value: r.base ?? 'company_share', options: [['company_share', 'The company\'s share'], ['car_revenue', 'The cars\' rental revenue']] },
            { name: 'duration', label: 'For how long', type: 'select', value: r.while_enrolled ? 'while' : 'months', options: [['months', 'A number of months'], ['while', 'As long as the car is with us']] },
            { name: 'months', label: 'Months', type: 'number', value: r.months ?? '', min: 1, max: 120 },
            { name: 'note', label: 'Note (optional)', type: 'text' }]} />
          <Act action="owner_recruit_decide" payload={{ id: r.id, decision: 'decline' }} label="Decline" testId={`orq-decline-${r.id}`} refresh={[`${base}?tab=owners`]} done="Declined."
            fields={[{ name: 'note', label: 'Note (optional)', type: 'text' }]} /></span> }]} /></>);
  }
  if (tab === 'prices' || tab === 'claims') {
    const rv = await read<Reviews>('commission_reviews');
    if (tab === 'prices') return (<><PageHead title="Prices to review" />{tabs}
      <p className="small muted">Prices staff typed by hand. A price under the floor or more than the discount limit under the rate sheet is flagged; nothing is blocked. Mark each one reviewed.</p>
      <Table<R> testId="prices" rows={rv.prices} rowKey={(r) => String(r.booking_number)} empty="No prices typed by hand to review." cols={[
        { key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'vehicle', label: 'Car', className: 'wrap' },
        { key: 'rental_cents', label: 'Price', num: true, render: (r) => r.tax === 'included' ? `${$(r.with_tax_cents)} tax included` : `${$(r.rental_cents)} plus tax` }, { key: 'rate_sheet_cents', label: 'Rate sheet', num: true, render: (r) => $(r.rate_sheet_cents) },
        { key: 'days', label: 'Days', num: true }, { key: 'by', label: 'Typed by' }, { key: 'reason', label: 'Reason', className: 'wrap' },
        { key: 'flags', label: 'Flag', render: (r) => (r.flags as string[]).length ? <b className="ad-late">{(r.flags as string[]).map((f) => (f === 'below_floor' ? 'under the floor' : 'past the discount limit')).join(', ')}</b> : 'none' },
        { key: 'act', label: '', render: (r) => r.reviewed_at ? `reviewed ${t(r.reviewed_at)}` : <Act action="price_review" payload={{ booking: r.booking_number }} label="Mark reviewed" testId={`price-review-${String(r.booking_number)}`} refresh={[base]} done="Reviewed." fields={[{ name: 'note', label: 'Note', type: 'text' }]} /> }]} /></>);
    return (<><PageHead title="Sourcing claims" />{tabs}
      <p className="small muted">A staff member said &quot;I sourced this client&quot; on the offer of a request that came in from the website. Website requests earn no commission unless you credit someone.</p>
      <Table<R> testId="claims" rows={rv.claims} rowKey={(r) => String(r.booking_number)} empty="No claims to decide." cols={[
        { key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'claim_by', label: 'Claimed by' }, { key: 'claim_at', label: 'When', render: (r) => t(r.claim_at) },
        { key: 'vehicle', label: 'Car', className: 'wrap' }, { key: 'status', label: 'Status', render: (r) => label(r.status) },
        { key: 'act', label: 'Decide', render: (r) => <span className="ad-actions">
          <Act action="sales_claim_decide" payload={{ booking: r.booking_number, accept: true }} label="Credit them" variant="primary" testId={`claim-accept-${String(r.booking_number)}`} refresh={[base]} done="Credited." fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} />
          <Act action="sales_claim_decide" payload={{ booking: r.booking_number, accept: false }} label="Not theirs" refresh={[base]} done="Claim closed." fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} /></span> }]} /></>);
  }
  const data = await read<Data>('commissions', { status: sp.status ?? '', staff: sp.staff ?? '', month: sp.month ?? '' });
  if (tab === 'payments') return (<><PageHead title="Commission payments" />{tabs}
    <Table<R> testId="commission-payments" rows={data.payouts as unknown as R[]} rowKey={(r) => String(r.id)} empty="No commission paid yet." cols={[
      { key: 'paid_on', label: 'Paid', render: (r) => d(r.paid_on) }, { key: 'name', label: 'Staff member' }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) },
      { key: 'method', label: 'How', render: (r) => METHODS.find((m) => m[0] === r.method)?.[1] ?? String(r.method) }, { key: 'reference', label: 'Reference', render: (r) => String(r.reference ?? (r.pay_period ? `pay statement ${d(r.pay_period)}` : '')) },
      { key: 'note', label: 'Note', className: 'wrap' }]} /></>);
  const s = data.settings;
  return (<><PageHead title="Staff commissions" kicker={`Staff outside Sales ${pctBps(s.staff_commission_bps ?? 1000)}; Sales ${pctBps(s.sales_tier_low_bps ?? 1000)}, ${pctBps(s.sales_tier_mid_bps ?? 1500)} from ${s.sales_tier_mid_days} days, ${pctBps(s.sales_tier_high_bps ?? 2000)} from ${s.sales_tier_high_days} days a month`} />{tabs}
    <p className="small muted">Nothing is paid automatically. Approve each commission (a Sales month once it has ended, when its tier is known), then record how you paid it. A refund or chargeback after payment comes back as a clawback on the next payment. Rates and tiers: <Link prefetch={false} className="link" href="/admin/settings/program">Program settings</Link>.</p>
    <Card title="By person" testId="commission-people">
      <Table<Person & R> rows={data.people as Array<Person & R>} rowKey={(r) => r.staff_id} empty="No commissions yet." cols={[
        { key: 'name', label: 'Staff member', render: (r) => <Link prefetch={false} className="link" href={`/admin/staff/${r.staff_id}/sales`}>{r.name}</Link> },
        { key: 'function', label: 'Function', render: (r) => label(r.function) },
        { key: 'month', label: 'This month', className: 'wrap', render: (r) => r.scheme === 'sales_tier' ? `${r.month.days} of ${r.month.target_days} days, ${pctBps(r.month.rate_bps)}` : `${pctBps(r.month.rate_bps)}${r.scheme === 'override' ? ' (own rate)' : ''}` },
        { key: 'not_earned_cents', label: 'Not earned yet', num: true, render: (r) => $(r.not_earned_cents) },
        { key: 'pending_cents', label: 'Pending approval', num: true, render: (r) => `${$(r.pending_cents)} (${r.pending_count})` },
        { key: 'approved_cents', label: 'Approved, to pay', num: true, render: (r) => $(r.approved_cents) },
        { key: 'paid_cents', label: 'Paid', num: true, render: (r) => $(r.paid_cents) },
        { key: 'act', label: 'Actions', render: (r) => <span className="ad-actions">
          {r.approvable_count > 0 && <Act action="commission_approve" payload={{ staff: r.staff_id }} label={`Approve ${r.approvable_count}`} variant="primary" testId={`approve-all-${r.staff_id}`} refresh={[base]} done="Approved. The staff member is told by email."
            confirm={`Approve the ${r.approvable_count} commission(s) of ${r.name} that may be approved now. Nothing is paid until you record the payment.`} />}
          {r.approved_cents > 0 && <Act action="commission_payout" payload={{ staff: r.staff_id }} label="Record a payment" testId={`pay-${r.staff_id}`} refresh={[base]} done="Payment recorded. The staff member is told by email."
            fields={[{ name: 'method', label: 'How it was paid', type: 'select', options: METHODS, required: true, value: 'e_transfer' }, { name: 'reference', label: 'Reference (e-Transfer, transfer or Wise number)', type: 'text' },
              { name: 'paid_on', label: 'Date paid', type: 'date', required: true, value: data.today }, { name: 'pay_period', label: 'Pay statement month (for the pay statement)', type: 'date' }, { name: 'note', label: 'Note', type: 'text' }]} />}
        </span> }]} />
    </Card>
    <Filters base={base} name="status" value={sp.status ?? ''} sp={sp} options={[['', 'All'], ['pending_approval', 'Pending approval'], ['approved', 'Approved'], ['accruing', 'Not earned yet'], ['paid', 'Paid'], ['reversed', 'Reversed']]} />
    <Table<Row & R> testId="commission-list" rows={data.rows as Array<Row & R>} rowKey={(r) => r.id} empty="No commissions with this status." cols={[
      { key: 'name', label: 'Staff member' }, { key: 'booking_number', label: 'Booking', className: 'wrap', render: (r) => <><BookingLink n={r.booking_number} />{r.what ? <span className="ad-sub">{r.what}</span> : null}</> }, { key: 'month_label', label: 'Month' },
      { key: 'rental_days', label: 'Days', num: true, render: (r) => (r.kind === 'commission' ? r.rental_days : '') }, { key: 'base_cents', label: 'Rental charge', num: true, render: (r) => (r.scheme === 'recruit_flat' ? '' : $(r.base_cents)) },
      { key: 'rate_bps', label: 'Rate', num: true, render: (r) => (r.scheme === 'recruit_flat' ? 'flat' : pctBps(r.rate_bps)) }, { key: 'amount_cents', label: 'Commission', num: true, render: (r) => $(r.amount_cents) },
      { key: 'status', label: 'Status', className: 'wrap', render: (r) => <span>{statusWords(r).replace('your next', 'the next')}{r.reason ? <span className="ad-sub">{r.reason}</span> : null}</span> },
      { key: 'paid_from', label: 'Paid from', className: 'wrap', render: (r) => FROM[r.paid_from] ?? '' },
      { key: 'act', label: '', render: (r) => <span className="ad-actions">
        {r.approvable && <Act action="commission_approve" payload={{ ids: [r.id] }} label="Approve" testId={`approve-${r.booking_number}`} refresh={[base]} done="Approved." />}
        {(r.kind === 'commission' || r.kind === 'owner_recruit') && ['accruing', 'pending_approval', 'approved', 'paid'].includes(r.status) && <Act action="commission_reverse" payload={{ id: r.id }} label="Reverse" refresh={[base]} done="Reversed."
          fields={[{ name: 'reason', label: 'Reason (for example a household rental)', type: 'text', required: true }]} />}</span> }]} /></>);
}
