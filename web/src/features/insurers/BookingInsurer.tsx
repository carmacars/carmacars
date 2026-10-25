import Link from 'next/link';
import { $, Badge, Card, Kv, d } from '@/features/admin/ui';
import { rateLine, rateSource, type SheetRate } from './rates';

// The booking's Insurance replacement card (migration 0163): the insurer and claim, the daily rate and where it comes
// from (the rate sheet, or typed with its reason, flagged when it differs from the sheet), the caps and allowance, what
// the insurer pays, and its invoices with their PDFs.
export interface BookingInsurerData {
  billed_to_insurer: boolean; bill_to?: string; insurer?: { id: string; name: string } | null; claim_number?: string | null; authorized_days?: number | null; authorized_until?: string | null;
  daily_rate_cents?: number | null; rate_source?: string; sheet_rate_cents?: number | null; differs?: boolean; reason?: string | null;
  rate?: (SheetRate & { class_label?: string; effective_from: string }) | null; covered_days?: number; rental_share_cents?: number; fees_share_cents?: number; share_cents?: number; hst_cents?: number;
  rates?: SheetRate[];
  invoices?: Array<{ id: string; invoice_number: string; status: string; total_cents: number; paid_cents: number; balance_cents: number; daily_rate_cents: number | null; rate_source: string | null; sent_at: string | null; paid_at: string | null }>;
}

export function BookingInsurer({ x }: { x: BookingInsurerData }) {
  if (!x.billed_to_insurer) return null;
  return (
    <Card title="Insurance replacement" testId="booking-insurer" aside={x.insurer ? <Link prefetch={false} className="link small" href={`/admin/insurers/${x.insurer.id}`}>Rates and billing</Link> : null}>
      <Kv rows={[
        ['Insurer', `${x.insurer?.name ?? ''}${x.bill_to === 'split' ? ' (the rental only)' : ' (the rental and the fees)'}`],
        ['Claim', x.claim_number ?? 'not given'],
        ['Daily rate', <span key="r" data-testid="booking-insurer-rate">{x.daily_rate_cents == null ? 'none' : $(x.daily_rate_cents)} <span className="small muted">{rateSource(x.rate_source ?? 'none')}</span></span>],
        ...(x.differs ? [['Rate sheet', <span key="s" data-testid="booking-insurer-differs"><span className="ad-flag ad-flag--red">Differs</span> the sheet says {$(x.sheet_rate_cents)}; reason: {x.reason ?? 'none given'}</span>] as [string, React.ReactNode]] : []),
        ...(x.rate ? [['From the sheet', `${x.rate.class_label ?? x.rate.class_code}, from ${d(x.rate.effective_from)}: ${rateLine(x.rate)}`] as [string, string]] : []),
        ...(x.rate?.taxes_note ? [['Taxes', x.rate.taxes_note] as [string, string]] : []),
        ['Days covered', `${x.covered_days ?? 0}${x.authorized_days ? ` of ${x.authorized_days} authorized` : ''}${x.authorized_until ? `, until ${d(x.authorized_until)}` : ''}`],
        ['The insurer pays', `${$(x.share_cents ?? 0)} before HST (rental ${$(x.rental_share_cents ?? 0)}${x.fees_share_cents ? `, fees ${$(x.fees_share_cents)}` : ''}), HST ${$(x.hst_cents ?? 0)}`]]} />
      {x.invoices?.length ? <ul className="ad-list" data-testid="booking-insurer-invoices">{x.invoices.map((i) => (
        <li key={i.id}><a className="link" href={`/files/insurer_invoice/${i.id}`}>{i.invoice_number}</a> <Badge s={i.status} />
          <span className="ad-sub">{$(i.total_cents)}{i.balance_cents > 0 && i.status !== 'draft' ? `, ${$(i.balance_cents)} outstanding` : ''}{i.daily_rate_cents != null ? `, at ${$(i.daily_rate_cents)} a day` : ''}</span>
          {' '}<Link prefetch={false} className="link small" href={`/admin/insurer-invoices${i.status === 'draft' ? '?status=draft' : ''}`}>Insurer invoices</Link></li>))}</ul>
        : <p className="small muted">No invoice yet: press Draft insurer invoice once the booking is confirmed.</p>}
    </Card>
  );
}
