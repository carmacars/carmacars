import './insurance.css';
import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { $, Badge, Card, d, Kv, PageHead, t } from '@/features/admin/ui';
import { InvoiceEditor, type Working } from './InvoiceEditor';
import { diffVersions, stageLabel, type Snapshot } from './model';
import type { InsBase } from './InsuranceList';

export type Delivery = { to: string; at: string; status: 'queued' | 'sent' | 'delivered' | 'bounced' | 'failed'; reason: string | null; fallback: boolean };
export interface InsRental {
  booking: { id: string; booking_number: string; status: string; pickup_at: string; return_at: string; bill_to: string; hst_bps: number; bypass: boolean; authorized_days: number | null; notes: string | null };
  stage: string;
  claim: { insurer_id: string; insurer: string; claim_number: string | null; adjuster_name: string | null; adjuster_email: string | null; adjuster_phone: string | null; insurer_billing_email: string | null };
  renter: { name: string; email: string | null; phone: string | null };
  car: { name: string; year: number; make: string; model: string; plate: string | null; outside_fleet: boolean };
  invoice: null | { id: string; invoice_number: string; status: string; version: number; total_cents: number; paid_cents: number; balance_cents: number; sent_at: string | null;
    approved_cents: number | null; negotiating_at: string | null; negotiation_note: string | null; written_off_cents: number; written_off_reason: string | null; edited: boolean;
    working: Working; current: Snapshot; aging_days: number | null };
  from_booking: Working;
  versions: Array<{ id: string; version: number; kind: 'estimate' | 'invoice'; snapshot: Snapshot; emailed_to: string | null; sent_at: string; sent_by: string | null;
    /** 5204 (REQ-136): each email of the version and how it went; the bounce and the claims email it went to again */
    delivery?: Delivery[]; bounced_at?: string | null; bounce_reason?: string | null; fallback_to?: string | null }>;
  payments: Array<{ amount_cents: number; method: string; at: string }>;
  history: Array<{ at: string; note: string; by: string | null }>;
  may_money: boolean;
  insurers: Array<{ id: string; name: string }>;
}

const METHOD: Record<string, string> = { cheque: 'Cheque', e_transfer: 'e-Transfer', bank_transfer: 'Direct deposit' };

// One insurance replacement (5120): the claim, the car and dates (extend it here), the invoice and every version sent with
// what changed, getting paid, and the history. Every action goes through the database (ops_do), which checks who may.
export function InsuranceRental({ x, base, added }: { x: InsRental; base: InsBase; added?: boolean }) {
  const b = x.booking; const i = x.invoice; const n = b.booking_number;
  const R: string[] = [];
  const sentInvoice = i && ['sent', 'part_paid'].includes(i.status);
  return (<>
    <PageHead title={`${x.claim.insurer}: claim ${x.claim.claim_number ?? 'not given'}`}
      kicker={<Link prefetch={false} className="link" href={`${base}/insurance-replacements`}>Insurance replacements</Link>}
      purpose={<span>{x.renter.name}, {x.car.name}. <span data-testid="ins-detail-stage"><Badge s={x.stage}>{stageLabel(x.stage)}</Badge></span></span>}>
      <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}/bookings/${encodeURIComponent(n)}`}>Booking {n}</Link>
    </PageHead>
    {added && <p className="alert alert--ok" role="status" data-testid="ins-added"><span>Added as {n}. Finance and the Admins were told.</span></p>}

    <Card title="Claim" testId="ins-claim" aside={<Act ops action="insurer_rental_update" payload={{ booking: n }} label="Edit" title="The claim and the renter" testId="ins-edit-claim" refresh={R} done="Saved."
      fields={[{ name: 'claim_number', label: 'Claim number', required: true, value: x.claim.claim_number }, { name: 'insurer_id', label: 'Insurer', type: 'select', value: x.claim.insurer_id, options: x.insurers.map((o) => [o.id, o.name] as [string, string]) },
        { name: 'adjuster_name', label: 'Adjuster', value: x.claim.adjuster_name }, { name: 'adjuster_email', label: 'Adjuster\'s email', type: 'email', value: x.claim.adjuster_email },
        { name: 'adjuster_phone', label: 'Adjuster\'s phone', type: 'tel', value: x.claim.adjuster_phone }, { name: 'authorized_days', label: 'Days authorized', type: 'number', value: b.authorized_days, min: 0, max: 400 },
        { name: 'renter_phone', label: 'Renter\'s phone', type: 'tel', value: x.renter.phone }, { name: 'renter_email', label: 'Renter\'s email', type: 'email', value: x.renter.email },
        { name: 'notes', label: 'Notes', type: 'textarea', value: b.notes }]} />}>
      <Kv rows={[['Insurer', x.claim.insurer], ['Claim number', x.claim.claim_number ?? 'not given'],
        ['Adjuster', [x.claim.adjuster_name, x.claim.adjuster_email, x.claim.adjuster_phone].filter(Boolean).join(', ') || 'not given'],
        ['Renter', [x.renter.name, x.renter.phone, x.renter.email].filter(Boolean).join(', ')],
        ['The insurer pays', b.bill_to === 'split' ? 'The rental only' : 'The rental and the fees'],
        ...(b.notes ? [['Notes', b.notes] as [string, string]] : [])]} />
    </Card>

    <Card title="Car and dates" testId="ins-car" aside={<span className="ins-actions">
      <Act ops action="insurer_rental_extend" payload={{ booking: n }} label="Extend" title="Move the return" testId="ins-extend" refresh={R} done="Extended. The invoice's next version has the new figures."
        fields={[{ name: 'return_at', label: 'New return', type: 'datetime', required: true, value: b.return_at }, { name: 'reason', label: 'Reason', value: 'The insurer extended the rental' }]} />
      {!x.car.outside_fleet && <Act ops action="insurer_rental_update" payload={{ booking: n, bypass: !b.bypass }} testId="ins-bypass-switch" refresh={R}
        label={b.bypass ? 'Put on the calendar' : 'Take off the calendar'} done="Saved."
        confirm={b.bypass ? 'Put the rental back on the calendar and show it to the owner (they are told as for any booking).' : 'Take the rental off the calendar and hide it from the owner: no owner notice.'} />}
      {x.car.outside_fleet && <Act ops action="insurer_rental_update" payload={{ booking: n }} nest="car" label="Edit the car" title="The car not in the fleet" testId="ins-edit-car" refresh={R} done="Saved."
        fields={[{ name: 'year', label: 'Year', type: 'number', value: x.car.year, required: true }, { name: 'make', label: 'Make', value: x.car.make, required: true },
          { name: 'model', label: 'Model', value: x.car.model, required: true }, { name: 'plate', label: 'Plate', value: x.car.plate }]} />}</span>}>
      <Kv rows={[['Car', `${x.car.name}${x.car.plate ? `, ${x.car.plate}` : ''}${x.car.outside_fleet ? ' (not in the fleet)' : ''}`],
        ['Pickup', t(b.pickup_at)], ['Return', <span key="r" data-testid="ins-return">{t(b.return_at)}</span>], ['Booking', <Badge key="s" s={b.status} />],
        ['Calendar and owner', <span key="c" data-testid="ins-bypass-state">{b.bypass ? 'Off the calendar, no owner notices' : 'On the calendar, shown to the owner'}</span>]]} />
    </Card>

    <Card title={i ? `Invoice ${i.invoice_number}` : 'Invoice'} testId="ins-invoice"
      aside={i ? <span className="ins-actions"><Badge s={i.status} />{i.version ? <span className="small muted">{i.version} version{i.version === 1 ? '' : 's'} sent</span> : null}
        <a className="link small" href={`/files/insurer_invoice/${i.id}`} data-testid="ins-invoice-pdf">PDF as it stands</a></span> : null}>
      <p className="small">Every field is yours to change. Send it as an estimate (it bills nothing) or as the invoice, as often as needed: each send is a version, kept as sent, with what changed. Nothing on it says CarmaCars: it is issued by Blind Spot Car Rental.</p>
      <InvoiceEditor booking={n} working={i?.working ?? x.from_booking} current={i && i.version ? i.current : null} hstBps={b.hst_bps} status={i?.status ?? null}
        sentVersions={i?.version ?? 0} mayMoney={x.may_money} fromBooking={x.from_booking} adjusterEmail={x.claim.adjuster_email ?? x.claim.insurer_billing_email} />
    </Card>

    <Card title="Versions sent" testId="ins-versions">
      {x.versions.length ? <ol className="ins-versions">{[...x.versions].reverse().map((v) => {
        const prev = x.versions.filter((p) => p.version < v.version).pop() ?? null;
        const changes = diffVersions(prev?.snapshot ?? null, v.snapshot);
        return (<li key={v.id} data-testid="ins-version">
          <p className="ins-actions"><b>Version {v.version}: {v.kind === 'estimate' ? 'estimate' : 'invoice'}</b><span>{$(v.snapshot.total_cents)}</span>
            <span className="small muted">{t(v.sent_at)}{v.sent_by ? `, by ${v.sent_by}` : ''}{v.emailed_to ? `, to ${v.emailed_to}` : ', sent another way'}</span>
            <a className="link small" href={`/files/insurer_invoice/${i?.id}:v${v.version}`} data-testid="ins-version-pdf">PDF</a></p>
          {prev ? changes.length ? <ul className="ins-diff" data-testid="ins-version-diff">{changes.map((c) => <li key={c.label}><span>{c.label}</span><span><del>{c.before}</del> to <ins>{c.after}</ins></span></li>)}</ul>
            : <p className="small muted">The same as version {prev.version}.</p> : null}
          {/* 5204 (REQ-136): delivered means sent with no bounce in 24 hours (the provider gives no receipt) */}
          {!!v.delivery?.length && <ul className="ins-diff" data-testid="ins-version-delivery">{v.delivery.map((d, k) => <li key={k}><span>{d.to}{d.fallback ? ' (claims email, sent again)' : ''}</span>
            <span><Badge s={d.status} />{d.status === 'delivered' ? <span className="small muted"> no bounce in 24 hours</span> : null}{d.reason ? <span className="small"> {d.reason}</span> : null}</span></li>)}</ul>}
          {v.bounced_at && <p className="alert alert--warn small" role="status" data-testid="ins-version-bounced"><span>Bounced {t(v.bounced_at)}: {v.bounce_reason}. {v.fallback_to ? `Sent again to ${v.fallback_to}.` : 'No other claims email on file: an Admin To do has the allowlist request.'}</span></p>}
        </li>);
      })}</ol> : <p className="small muted">Nothing sent yet.</p>}
    </Card>

    <Card title="Getting paid" testId="ins-money">
      <Kv rows={[['Billed', i && i.status !== 'draft' ? $(i.total_cents) : 'not invoiced yet'], ['Approved by the adjuster', i?.approved_cents == null ? 'not yet' : $(i.approved_cents)],
        ['Paid', <span key="p" data-testid="ins-paid">{$(i?.paid_cents ?? 0)}</span>], ['Balance', <span key="b" data-testid="ins-balance">{sentInvoice ? $(i!.balance_cents) : $(0)}</span>],
        ...(i?.aging_days != null ? [['Aging', `${i.aging_days} days since the invoice`] as [string, string]] : []),
        ...(i?.negotiating_at ? [['Negotiating', `${d(i.negotiating_at)}: ${i.negotiation_note ?? ''}`] as [string, string]] : []),
        ...(i?.written_off_cents ? [['Written off', `${$(i.written_off_cents)}: ${i.written_off_reason ?? ''}`] as [string, string]] : [])]} />
      {x.payments.length > 0 && <ul className="ins-history" data-testid="ins-payments">{x.payments.map((p, k) => <li key={k}><time>{d(p.at)}</time>{$(p.amount_cents)} by {METHOD[p.method] ?? p.method}</li>)}</ul>}
      {x.may_money && sentInvoice ? <div className="ins-actions">
        <Act ops action="insurer_money" payload={{ booking: n, action: 'payment', client_id: `pay:${i!.id}:${i!.version}:${i!.paid_cents}` }} label="Record a payment" variant="primary" title="Money received from the insurer" testId="ins-pay" refresh={R} done="Payment recorded."
          fields={[{ name: 'amount_cents', label: 'Amount received', type: 'money', required: true, value: i!.balance_cents },
            { name: 'method', label: 'How', type: 'select', required: true, value: 'cheque', options: [['cheque', 'Cheque'], ['e_transfer', 'e-Transfer'], ['direct_deposit', 'Direct deposit']] },
            { name: 'reference', label: 'Reference (cheque or transfer number)' }, { name: 'received_on', label: 'Received on', type: 'date', value: new Date().toISOString().slice(0, 10) }]} />
        <Act ops action="insurer_money" payload={{ booking: n, action: 'approved' }} label="Approved amount" title="What the adjuster approved" testId="ins-approved" refresh={R} done="Saved."
          fields={[{ name: 'amount_cents', label: 'Approved', type: 'money', required: true, value: i!.approved_cents ?? i!.total_cents }, { name: 'note', label: 'Note' }]} />
        <Act ops action="insurer_money" payload={{ booking: n, action: 'negotiating', negotiating: !i!.negotiating_at }} label={i!.negotiating_at ? 'End the negotiation' : 'Negotiating'} testId="ins-negotiating" refresh={R} done="Saved."
          {...(i!.negotiating_at ? { confirm: 'The adjuster no longer disputes the invoice.' } : { title: 'What the adjuster disputes', fields: [{ name: 'note', label: 'What is disputed', type: 'textarea' as const, required: true }] })} />
        <Act ops action="insurer_money" payload={{ booking: n, action: 'write_off' }} label="Write off the rest" variant="danger" title={`Write off ${$(i!.balance_cents)}`} testId="ins-write-off" refresh={R} done="Written off."
          fields={[{ name: 'reason', label: 'Reason', required: true }]} />
      </div> : x.may_money ? <p className="small muted">Send the invoice first: payments, the approved amount and write-offs go on a sent invoice.</p> : <p className="small muted">Finance or an Admin records payments.</p>}
    </Card>

    <Card title="History" testId="ins-history">
      {x.history.length ? <ul className="ins-history">{x.history.map((h, k) => <li key={k}><time>{t(h.at)}</time>{h.note}{h.by ? <span className="muted">, {h.by}</span> : null}</li>)}</ul> : <p className="small muted">Nothing yet.</p>}
    </Card>
  </>);
}
