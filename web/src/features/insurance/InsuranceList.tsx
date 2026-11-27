import './insurance.css';
import Link from '@/components/Link';
import { ListFilters } from '@/features/list-filters/ListFilters';
import { $, Badge, d, PageHead, Table, Tiles } from '@/features/admin/ui';
import { stageLabel } from './model';

export interface InsRow extends Record<string, unknown> {
  booking_number: string; claim_number: string | null; insurer: string; adjuster: string | null; renter: string; car: string; plate: string | null; outside_fleet: boolean;
  pickup_at: string; return_at: string; days: number; stage: string; bypass: boolean; invoice_number: string | null; versions: number; edited: boolean;
  billed_cents: number; approved_cents: number | null; paid_cents: number; balance_cents: number; written_off_cents: number; aging_days: number | null;
}
export interface InsList { rows: InsRow[]; count: number; outstanding_cents: number; over_30: number; over_60: number; to_invoice: number; may_money: boolean }
export type InsBase = '/admin' | '/staff';

const aging = (n: number | null) => n === null ? '' : `${n} d`;

// Insurance replacements (5120): every rental billed to an insurer, with where its claim stands at a glance. One list for
// Admin and the staff portal (Finance, customer service); the database decides what each person may do on a rental.
export function InsuranceList({ data, base, sp }: { data: InsList; base: InsBase; sp: Record<string, string | undefined> }) {
  const href = `${base}/insurance-replacements`;
  const open = (r: InsRow) => `${href}/${encodeURIComponent(r.booking_number)}`;
  return (<>
    <PageHead title="Insurance replacements" kicker="Insurers" purpose="Every rental an insurer pays for: the claim, the car, the dates, the invoice and its versions, and what the insurer approved and paid.">
      <Link prefetch={false} className="btn btn--primary btn--sm" href={`${href}/new`} data-testid="ins-add">Add an insurance replacement</Link>
    </PageHead>
    <Tiles items={[
      { k: 'Outstanding', v: $(data.outstanding_cents), sub: 'invoiced, not yet paid' },
      { k: 'To invoice', v: String(data.to_invoice), sub: 'returned, no invoice sent', href: `${href}?stage=returned`, warn: data.to_invoice > 0 },
      { k: 'Over 30 days', v: String(data.over_30), href: `${href}?aging=30`, warn: data.over_30 > 0 },
      { k: 'Over 60 days', v: String(data.over_60), href: `${href}?aging=60`, warn: data.over_60 > 0 }]} />
    <ListFilters id="insurance-replacements" base={href} sp={sp} kept={['aging', 'insurer']}
      search={{ placeholder: 'Claim, booking, renter, insurer, adjuster or plate' }}
      chips={{ name: 'stage', label: 'Stage', value: sp.stage ?? '', options: [['', 'All'], ['on_rent', 'On rent'], ['returned', 'To invoice'], ['invoiced', 'Invoiced'], ['negotiating', 'Negotiating'], ['approved', 'Approved']] }} />
    {sp.aging ? <p className="small" data-testid="ins-aging-filter">Outstanding for {sp.aging} days or more. <Link prefetch={false} className="link" href={href}>Show all</Link></p> : null}
    <Table<InsRow> testId="ins-list" rows={data.rows} rowKey={(r) => r.booking_number} caption="Insurance replacements"
      empty="No insurance replacement here. Add one with Add an insurance replacement."
      cols={[
        { key: 'claim_number', label: 'Claim', render: (r) => <Link prefetch={false} className="link" href={open(r)} data-testid="ins-open">{r.claim_number || r.booking_number}</Link> },
        { key: 'insurer', label: 'Insurer', render: (r) => <span className="stack"><span>{r.insurer}</span>{r.adjuster ? <span className="small muted">{r.adjuster}</span> : null}</span> },
        { key: 'renter', label: 'Renter' },
        { key: 'car', label: 'Car', render: (r) => <span className="stack"><span>{r.car}</span><span className="small muted">{[r.plate, r.outside_fleet ? 'not in the fleet' : null, r.bypass ? 'off the calendar' : null].filter(Boolean).join(', ')}</span></span> },
        { key: 'pickup_at', label: 'Dates', render: (r) => <span className="ins-nowrap">{d(r.pickup_at)} to {d(r.return_at)}</span> },
        { key: 'days', label: 'Days', num: true },
        { key: 'stage', label: 'Status', render: (r) => <span data-testid="ins-stage"><Badge s={r.stage}>{stageLabel(r.stage)}</Badge></span> },
        { key: 'invoice_number', label: 'Invoice', render: (r) => r.invoice_number ? <span className="stack"><span>{r.invoice_number}</span><span className="small muted">{r.versions ? `${r.versions} version${r.versions === 1 ? '' : 's'}` : 'draft'}{r.edited ? ', changes not sent' : ''}</span></span> : <span className="muted">none</span> },
        { key: 'billed_cents', label: 'Billed', num: true, render: (r) => (r.billed_cents ? $(r.billed_cents) : '') },
        { key: 'approved_cents', label: 'Approved', num: true, render: (r) => (r.approved_cents == null ? '' : $(r.approved_cents)) },
        { key: 'paid_cents', label: 'Paid', num: true, render: (r) => (r.paid_cents ? $(r.paid_cents) : '') },
        { key: 'balance_cents', label: 'Balance', num: true, render: (r) => (r.written_off_cents ? <span className="small">{$(r.written_off_cents)} written off</span> : r.balance_cents ? $(r.balance_cents) : '') },
        { key: 'aging_days', label: 'Aging', num: true, render: (r) => <span className={r.aging_days != null && r.aging_days >= 30 ? 'ins-late' : ''}>{aging(r.aging_days)}</span> }]} />
  </>);
}
