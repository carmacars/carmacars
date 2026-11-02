import Link from '@/components/Link';
import { QuickRange } from '@/components/QuickRange';
import { torontoToday } from '@/lib/nav/range';
import { GetForm } from '@/components/GetForm';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Card, PageHead, Table, Tiles, d, t } from '@/features/admin/ui';
import { rateFields, removeFields } from '@/features/insurers/fields';
import { rateLine, rateSource, type BillingRow, type SheetRate } from '@/features/insurers/rates';
import { DateRangePicker } from '@/components/DateRangePicker';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Insurer', path: '/admin/insurers', noindex: true, description: 'An insurer\'s rates by car class, their history, and its billing history.' });

type R = Record<string, unknown>;
type Rate = SheetRate & R & { id: string; effective_from: string; effective_to: string | null; replaced: boolean; current: boolean; by: string | null; note: string | null; created_at: string };
type ByClass = R & { class_code: string; class_label: string | null; bookings: number; days_authorized: number; days_used: number; days_covered: number; billed_cents: number; paid_cents: number;
  outstanding_cents: number; written_off_cents: number; average_rate_cents: number | null; days_to_pay: number | null };
type Row = Omit<BillingRow, 'invoices'> & R & { id: string; invoices: Array<{ id: string; invoice_number: string; status: string; total_cents: number; balance_cents: number }> };
type Billing = { insurer: { id: string; name: string; is_active: boolean; billing_email: string | null; billing_contact_name: string | null }; from: string | null; to: string | null; today: string;
  classes: Array<{ code: string; label: string }>; rates: Rate[]; by_class: ByClass[]; bookings: Row[];
  // 0234: by car, by adjuster, the charges to the insurer, the adjusters
  fee_codes?: Array<{ code: string; label: string }>; by_car?: Array<Sum & { vehicle_id: string; vehicle: string; class_code: string }>;
  by_adjuster?: Array<Sum & { adjuster_id: string | null; adjuster: string }>; class_charges?: Record<string, Sum>;
  booking_charges?: Record<string, { adjuster: string | null; vehicle: string; fees: Record<string, number>; rental_cents: number; hst_cents: number; share_cents: number }>;
  adjusters?: Array<{ id: string; name: string | null; email: string | null; phone: string | null; notes: string | null; is_active: boolean; bookings: number }>;
  totals: { bookings: number; days_authorized: number; days_used: number; days_covered: number; billed_cents: number; paid_cents: number; outstanding_cents: number; written_off_cents: number; average_rate_cents: number | null; days_to_pay: number | null } };

const DATE = /^\d{4}-\d{2}-\d{2}$/;
type Sum = R & { bookings: number; days: number; average_rate_cents: number | null; rental_cents: number; fees_cents: number; fees: Record<string, number>; hst_cents: number;
  share_cents: number; billed_cents: number; paid_cents: number; outstanding_cents: number };
const adjusterFields = (a?: { name: string | null; email: string | null; phone: string | null; notes: string | null; is_active?: boolean }) => [
  { name: 'name', label: 'Name', type: 'text' as const, value: a?.name ?? '' }, { name: 'email', label: 'Email (invoices go here)', type: 'email' as const, value: a?.email ?? '' },
  { name: 'phone', label: 'Phone', type: 'tel' as const, value: a?.phone ?? '' }, { name: 'notes', label: 'Notes', type: 'textarea' as const, value: a?.notes ?? '' },
  ...(a ? [{ name: 'is_active', label: 'Active', type: 'bool' as const, value: a.is_active ?? true }] : [])];

// One insurer (migration 0163): its rate for each class with the history of every change, and what it was billed, paid and
// still owes, by class and by booking, for the period chosen (CSV for the period).
export default async function Insurer({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ id }, sp] = await Promise.all([params, searchParams]);
  const { read } = await page(`/admin/insurers/${id}`);
  const from = sp.from && DATE.test(sp.from) ? sp.from : '';
  const to = sp.to && DATE.test(sp.to) ? sp.to : '';
  const x = /^[0-9a-f-]{36}$/i.test(id) ? await read<Billing | null>('insurer_billing', { insurer: id, from: from || null, to: to || null }) : null;
  if (!x) notFound();
  const base = `/admin/insurers/${id}`;
  const R = [base, '/admin/insurers'];
  const current = (code: string) => x.rates.find((r) => r.class_code === code && r.current) ?? null;
  const tot = x.totals;
  const qs = new URLSearchParams({ ...(from ? { from } : {}), ...(to ? { to } : {}) }).toString();
  const status = (r: Rate) => r.current ? 'Current' : r.replaced ? 'Replaced the same day' : r.effective_from > x.today ? 'Upcoming' : 'Ended';
  return (<>
    <PageHead title={x.insurer.name} kicker={<Link prefetch={false} className="link" href="/admin/insurers">Insurer rates</Link>}
      purpose={`${x.insurer.is_active ? 'Active' : 'Inactive'} insurer. Invoices go to each booking's adjuster${x.insurer.billing_email ? `, else ${x.insurer.billing_email}` : ''}.`}>
      <a className="btn btn--ghost btn--sm" href={`${base}/export${qs ? `?${qs}` : ''}`} data-testid="ir-csv" download>Download CSV</a>
      <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/settings/insurers">Contacts</Link>
    </PageHead>
    <GetForm className="row ad-filters" action={base} aria-label="Period" data-testid="ir-period">
      <QuickRange base={base} from={from || null} to={to || null} today={torontoToday()} customId="ir-from" label="Picked up" />
      <DateRangePicker id="ir-from" label="Picked up" from={from} to={to} quick={false} />
      <button className="btn btn--ghost btn--sm" type="submit">Show</button>{(from || to) && <Link prefetch={false} className="link small" href={base}>All time</Link>}
    </GetForm>
    <Tiles items={[
      { k: 'Bookings', v: tot.bookings, sub: `${tot.days_used} days used, ${tot.days_authorized} authorized` },
      { k: 'Billed', v: $(tot.billed_cents) }, { k: 'Paid', v: $(tot.paid_cents) },
      { k: 'Outstanding', v: $(tot.outstanding_cents), warn: tot.outstanding_cents > 0 },
      { k: 'Average daily rate', v: tot.average_rate_cents == null ? 'none' : $(tot.average_rate_cents) },
      { k: 'Days to pay', v: tot.days_to_pay == null ? 'none yet' : String(tot.days_to_pay), sub: 'from sent to paid, on average' }]} />
    <Card title="Rates by class" testId="ir-rates">
      <Table<{ code: string; label: string } & R> rows={x.classes} rowKey={(c) => c.code} caption="Rates by class"
        cols={[{ key: 'label', label: 'Class' },
          { key: 'rate', label: 'Rate today', render: (c) => { const r = current(c.code); return r && r.daily_rate_cents != null ? <span data-testid={`ir-rate-${c.code}`}>{rateLine(r)}</span> : <span className="muted">none</span>; } },
          { key: 'taxes', label: 'Taxes note', className: 'wrap', render: (c) => current(c.code)?.taxes_note ?? '' },
          { key: 'act', label: '', render: (c) => { const r = current(c.code); return <span className="ad-actions">
            <Act action="insurer_rate_set" payload={{ insurer_id: x.insurer.id, class_code: c.code }} label={r?.daily_rate_cents != null ? 'Change' : 'Set'} variant="quiet" title={`${x.insurer.name}: ${c.label}`}
              fields={rateFields(r?.daily_rate_cents != null ? r : null, x.today)} refresh={R} testId={`ir-page-set-${c.code}`} done="Rate saved. The earlier rate stays in the history." submitLabel="Save the rate" />
            {r?.daily_rate_cents != null && <Act action="insurer_rate_set" payload={{ insurer_id: x.insurer.id, class_code: c.code, remove: true }} label="End" variant="quiet" title={`${x.insurer.name}: no ${c.label} rate`}
              fields={removeFields(x.today)} refresh={R} done="The rate ends on that date." submitLabel="End the rate" />}</span>; } }]} />
    </Card>
    <Card title="History of the rates" testId="ir-history">
      <Table<Rate> rows={x.rates} empty="No rate saved yet: press Set on a class above."
        cols={[{ key: 'class_label', label: 'Class' }, { key: 'effective_from', label: 'From', render: (r) => d(r.effective_from) },
          { key: 'effective_to', label: 'To', render: (r) => r.effective_to ? d(r.effective_to) : '' },
          { key: 'line', label: 'Rate', className: 'wrap', render: (r) => rateLine(r) }, { key: 'taxes_note', label: 'Taxes note', className: 'wrap' },
          { key: 'state', label: 'Status', render: (r) => status(r) }, { key: 'note', label: 'Why', className: 'wrap' },
          { key: 'by', label: 'Saved', render: (r) => `${r.by ?? ''} ${t(r.created_at)}`.trim() }]} />
    </Card>
    <Card title="Billing by class" testId="ir-by-class">
      <Table<ByClass> rows={x.by_class} rowKey={(c) => c.class_code} empty="No booking billed to this insurer in the period."
        cols={[{ key: 'class_label', label: 'Class', render: (c) => c.class_label ?? c.class_code }, { key: 'bookings', label: 'Bookings', num: true },
          { key: 'days_authorized', label: 'Days authorized', num: true }, { key: 'days_used', label: 'Days used', num: true },
          { key: 'billed_cents', label: 'Billed', num: true, render: (c) => $(c.billed_cents) }, { key: 'paid_cents', label: 'Paid', num: true, render: (c) => $(c.paid_cents) },
          { key: 'outstanding_cents', label: 'Outstanding', num: true, render: (c) => $(c.outstanding_cents) },
          { key: 'average_rate_cents', label: 'Average rate', num: true, render: (c) => c.average_rate_cents == null ? '' : $(c.average_rate_cents) },
          { key: 'days_to_pay', label: 'Days to pay', num: true, render: (c) => c.days_to_pay ?? '' }]} />
    </Card>
    <Card title="Charged by class" testId="ir-class-charges">
      <Table<Sum & { class_code: string }> rows={Object.entries(x.class_charges ?? {}).map(([k, v]) => ({ ...v, class_code: k }))} rowKey={(c) => c.class_code} empty="No booking billed to this insurer in the period."
        cols={[{ key: 'class_code', label: 'Class', render: (c) => x.classes.find((k) => k.code === c.class_code)?.label ?? c.class_code }, ...sumCols(x.fee_codes ?? [])]} />
    </Card>
    <Card title="Billing by car" testId="ir-by-car">
      <Table<Sum & { vehicle_id: string; vehicle: string; class_code: string }> rows={x.by_car ?? []} rowKey={(c) => c.vehicle_id} empty="No booking billed to this insurer in the period."
        cols={[{ key: 'vehicle', label: 'Car', render: (c) => <Link prefetch={false} className="link" href={`/admin/vehicles/${c.vehicle_id}`}>{c.vehicle}</Link> },
          { key: 'class_code', label: 'Class', render: (c) => x.classes.find((k) => k.code === c.class_code)?.label ?? c.class_code }, ...sumCols(x.fee_codes ?? [])]} />
    </Card>
    <Card title="Billing by adjuster" testId="ir-by-adjuster">
      <Table<Sum & { adjuster_id: string | null; adjuster: string }> rows={x.by_adjuster ?? []} rowKey={(c) => c.adjuster_id ?? 'none'} empty="No booking billed to this insurer in the period."
        cols={[{ key: 'adjuster', label: 'Adjuster' }, ...sumCols(x.fee_codes ?? [])]} />
    </Card>
    <Card title={`Adjusters (${(x.adjusters ?? []).length})`} testId="ir-adjusters" aside={<Act action="insurer_adjuster_save" payload={{ insurer_id: x.insurer.id }} label="Add an adjuster" variant="quiet" testId="ir-adjuster-add" refresh={R} done="Adjuster saved." fields={adjusterFields()} />}>
      <p className="small">Each adjuster is saved from the bookings too (typed on Add a rental or the booking&apos;s insurance claim card), matched by email, else by name.</p>
      <Table<NonNullable<Billing['adjusters']>[number] & R> rows={(x.adjusters ?? []) as Array<NonNullable<Billing['adjusters']>[number] & R>} rowKey={(a) => a.id} empty="No adjuster yet."
        cols={[{ key: 'name', label: 'Name', render: (a) => `${a.name ?? ''}${a.is_active ? '' : ' (inactive)'}` }, { key: 'email', label: 'Email' }, { key: 'phone', label: 'Phone' },
          { key: 'bookings', label: 'Bookings', num: true }, { key: 'notes', label: 'Notes', className: 'wrap' },
          { key: 'act', label: '', render: (a) => <Act action="insurer_adjuster_save" payload={{ id: a.id }} label="Change" variant="quiet" refresh={R} done="Saved." testId={`ir-adjuster-edit-${a.id}`} fields={adjusterFields(a)} /> }]} />
    </Card>
    <Card title="Bookings" testId="ir-bookings">
      <Table<Row> rows={x.bookings} empty="No booking billed to this insurer in the period."
        cols={[{ key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'status', label: 'Status', render: (r) => <Badge s={r.status} /> },
          { key: 'class_label', label: 'Class', render: (r) => r.class_label ?? r.class_code }, { key: 'claim_number', label: 'Claim' },
          { key: 'vehicle', label: 'Car', render: (r) => x.booking_charges?.[r.id]?.vehicle ?? String(r.vehicle ?? '') },
          { key: 'adjuster', label: 'Adjuster', render: (r) => x.booking_charges?.[r.id]?.adjuster ?? '' },
          { key: 'charges', label: 'Charges', className: 'wrap', render: (r) => Object.entries(x.booking_charges?.[r.id]?.fees ?? {}).map(([k, v]) => `${(x.fee_codes ?? []).find((f) => f.code === k)?.label.split(' ')[0] ?? k} ${$(v)}`).join(', ') },
          { key: 'pickup_at', label: 'Dates', render: (r) => `${d(r.pickup_at)} to ${d(r.return_at)}` },
          { key: 'days', label: 'Days authorized / used', render: (r) => `${r.days_authorized ?? ''} / ${r.days_used ?? ''}` },
          { key: 'daily_rate_cents', label: 'Daily rate', render: (r) => <span>{r.daily_rate_cents == null ? 'none' : $(r.daily_rate_cents)} <span className="small muted">{rateSource(r.rate_source)}</span>
            {r.sheet_rate_cents != null && r.daily_rate_cents !== r.sheet_rate_cents ? <span className="small"> <span className="ad-flag">Sheet {$(r.sheet_rate_cents)}</span>{r.rate_reason ?? ''}</span> : null}</span> },
          { key: 'billed_cents', label: 'Billed', num: true, render: (r) => $(r.billed_cents) }, { key: 'paid_cents', label: 'Paid', num: true, render: (r) => $(r.paid_cents) },
          { key: 'outstanding_cents', label: 'Outstanding', num: true, render: (r) => $(r.outstanding_cents) },
          { key: 'days_to_pay', label: 'Days to pay', num: true, render: (r) => r.days_to_pay ?? '' },
          { key: 'invoices', label: 'Invoices', render: (r) => r.invoices.length ? <span className="stack">{r.invoices.map((i) => <span key={i.id}><a className="link" href={`/files/insurer_invoice/${i.id}`}>{i.invoice_number}</a> <Badge s={i.status} /></span>)}</span>
            : <span className="muted">none yet</span> }]} />
    </Card>
  </>);
}

// 0234: the figures of a group of bookings: days, the average rate, each charge to the insurer, the share, billed and owed
function sumCols<T extends Sum>(fees: Array<{ code: string; label: string }>) {
  return [
    { key: 'bookings', label: 'Bookings', num: true }, { key: 'days', label: 'Days', num: true },
    { key: 'average_rate_cents', label: 'Average daily rate', num: true, render: (c: T) => (c.average_rate_cents == null ? '' : $(c.average_rate_cents)) },
    { key: 'rental_cents', label: 'Rental', num: true, render: (c: T) => $(c.rental_cents) },
    ...fees.map((f) => ({ key: `fee_${f.code}`, label: f.label.split(' (')[0]!, num: true, render: (c: T) => (c.fees?.[f.code] ? $(c.fees[f.code]!) : '') })),
    { key: 'hst_cents', label: 'HST', num: true, render: (c: T) => $(c.hst_cents) },
    { key: 'share_cents', label: 'Insurer total', num: true, render: (c: T) => $(c.share_cents) },
    { key: 'billed_cents', label: 'Billed', num: true, render: (c: T) => $(c.billed_cents) },
    { key: 'outstanding_cents', label: 'Outstanding', num: true, render: (c: T) => $(c.outstanding_cents) }];
}
