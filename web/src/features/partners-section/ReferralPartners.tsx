import Link from '@/components/Link';
import { ListFilters } from '@/features/list-filters/ListFilters';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Card, PageHead, Table, Tabs, d } from '@/features/admin/ui';
import { EARNING_WORDS, kindLabel, PAYOUT_METHODS, STATUS_WORDS } from '@/features/referral/model';
import { PARTNER_FIELDS } from '@/features/referral/fields';
import { PartnerInvoices } from '@/features/partner-invoices/PartnerInvoices';

type R = Record<string, unknown>;
type Partner = { id: string; kind: string; status: string; business_name: string; contact_name: string | null; phone: string | null; email: string | null; referral_code: string; rate_text: string; source: string;
  referrals: number; completed: number; accruing_cents: number; pending_cents: number; approved_cents: number; paid_cents: number };
type Ledger = { id: string; kind: string; status: string; partner_id: string; partner: string; booking_number: string; first_name: string; month: string; base_cents: number; amount_cents: number; reason: string | null; note: string | null; approvable: boolean; paid_from: string };
const FROM: Record<string, string> = { owner_revenue: 'Owner\'s car: a kickback before Owner Revenue', carmacars_commission: 'Partner\'s car: from CarmaCars\' commission', carmacars: 'CarmaCars-owned car: a CarmaCars expense' };

// Admin > People > Referral partners (migration 0164): body shops and tow trucks that send us renters. Partners and sign-ups to
// approve, the ledger of kickbacks (approve, reverse), and the payments recorded by hand. Nothing is paid automatically.
type Read = <T = Record<string, unknown>>(what: string, p?: Record<string, unknown>) => Promise<T>;
export async function ReferralPartnersView({ userId, base, sp, read }: { userId: string; base: '/admin' | '/staff'; sp: Record<string, string | undefined>; read: Read }) {
  const user = { id: userId };
  const tab = sp.tab ?? 'partners';
  const root = `${base}/referral-partners`;
  const list = await read<{ today: string; settings: { flat_cents: number; percent_bps: number }; partners: Partner[]; waiting: number }>('referral_partners');
  const tabs = <Tabs current={`${root}?tab=${tab}`} items={[[`${root}?tab=partners`, 'Partners', list.waiting], [`${root}?tab=ledger`, 'Kickbacks'], [`${root}?tab=payments`, 'Payments made'], [`${root}?tab=invoices`, 'Invoices']]} />;
  const head = <PageHead title="Referral partners" kicker={`${list.partners.filter((p) => p.status === 'active').length} active`} purpose="Body shops and tow trucks that send renters. A partner earns when the rental is completed and paid in full; you approve it and record the payment.">
    <Act action="referral_partner_save" label="Add a partner" variant="primary" testId="rp-add" go={`${root}/{id}`} fields={PARTNER_FIELDS({}, { flat_cents: list.settings.flat_cents, percent_bps: list.settings.percent_bps })} /></PageHead>;
  // 0547: invoices to partners for their kickback on claim, towing or storage money, and the money they send
  if (tab === 'invoices') return (<>{head}{tabs}<PartnerInvoices userId={user.id} base={`${root}?tab=invoices`} sp={sp} /></>);
  if (tab === 'payments') {
    const r = await read<{ payouts: R[] }>('referral_earnings');
    return (<>{head}{tabs}
      <Table<R> testId="rp-payments" rows={r.payouts} rowKey={(x) => String(x.id)} empty="No kickback paid yet." cols={[
        { key: 'paid_on', label: 'Paid', render: (x) => d(x.paid_on) }, { key: 'partner', label: 'Partner', render: (x) => <Link prefetch={false} className="link" href={`${base}/referral-partners/${String(x.partner_id)}`}>{String(x.partner)}</Link> },
        { key: 'amount_cents', label: 'Amount', num: true, render: (x) => $(x.amount_cents) }, { key: 'method', label: 'How', render: (x) => PAYOUT_METHODS.find((m) => m[0] === x.method)?.[1] ?? String(x.method) },
        { key: 'reference', label: 'Reference' }, { key: 'note', label: 'Note', className: 'wrap' }]} /></>);
  }
  if (tab === 'ledger') {
    const r = await read<{ rows: Ledger[] }>('referral_earnings', { status: sp.status ?? '' });
    return (<>{head}{tabs}
      <p className="small muted">A kickback is earned when the rental is completed and paid in full, on the rental charge after discounts. Approve it, then record how you paid it under Partners. A refund or chargeback after payment comes back as a clawback on the next payment. On a program owner&apos;s car it is deducted before Owner Revenue, with the staff commissions; on a partner&apos;s or CarmaCars&apos; own car CarmaCars pays it.</p>
      <ListFilters id="admin-referral-partners-status" base={`${root}?tab=ledger`} sp={sp} chips={{ name: 'status', label: 'Status', value: sp.status ?? '', options: [['', 'All'], ['pending_approval', 'Pending approval'], ['approved', 'Approved'], ['accruing', 'Not earned yet'], ['paid', 'Paid']] }} />
      <Table<Ledger & R> testId="rp-ledger" rows={r.rows as Array<Ledger & R>} rowKey={(x) => x.id} empty="No kickbacks with this status." cols={[
        { key: 'partner', label: 'Partner', render: (x) => <Link prefetch={false} className="link" href={`${base}/referral-partners/${x.partner_id}`}>{x.partner}</Link> },
        { key: 'booking_number', label: 'Booking', render: (x) => <BookingLink n={x.booking_number} /> }, { key: 'first_name', label: 'Renter' }, { key: 'month', label: 'Month' },
        { key: 'base_cents', label: 'Rental charge', num: true, render: (x) => $(x.base_cents) }, { key: 'amount_cents', label: 'Kickback', num: true, render: (x) => $(x.amount_cents) },
        { key: 'status', label: 'Status', className: 'wrap', render: (x) => <span>{x.kind === 'clawback' ? 'Clawback: ' : ''}{EARNING_WORDS[x.status] ?? x.status}{x.reason ? <span className="ad-sub">{x.reason}</span> : null}</span> },
        { key: 'paid_from', label: 'Paid from', className: 'wrap', render: (x) => FROM[x.paid_from] ?? '' },
        { key: 'act', label: '', render: (x) => <span className="ad-actions">
          {x.approvable && <Act action="referral_earning_approve" payload={{ ids: [x.id] }} label="Approve" testId={`rp-approve-${x.booking_number}`} refresh={[root]} done="Approved." />}
          {x.kind === 'earning' && ['accruing', 'pending_approval', 'approved', 'paid'].includes(x.status) && <Act action="referral_earning_reverse" payload={{ id: x.id }} label="Reverse" refresh={[root]} done="Reversed."
            fields={[{ name: 'reason', label: 'Reason (for example the partner\'s own rental)', type: 'text', required: true }]} />}</span> }]} /></>);
  }
  const partners = list.partners;
  return (<>{head}{tabs}
    <Card title={`Partners (${partners.length})`} testId="rp-partners">
      <Table<Partner & R> rows={partners as Array<Partner & R>} rowKey={(x) => x.id} empty="No referral partners yet. Add a body shop or a tow truck company, or wait for a sign-up from the public page." cols={[
        { key: 'business_name', label: 'Partner', render: (x) => <Link prefetch={false} className="link" href={`${base}/referral-partners/${x.id}`} data-testid={`rp-${x.referral_code}`}>{x.business_name}</Link> },
        { key: 'kind', label: 'Kind', render: (x) => kindLabel(x.kind) },
        { key: 'status', label: 'Status', render: (x) => <Badge s={x.status === 'active' ? 'published' : x.status === 'pending' ? 'draft' : 'closed'}>{STATUS_WORDS[x.status] ?? x.status}</Badge> },
        { key: 'referral_code', label: 'Code' }, { key: 'rate_text', label: 'Kickback', className: 'wrap' },
        { key: 'referrals', label: 'Referred', num: true }, { key: 'pending_cents', label: 'To approve', num: true, render: (x) => $(x.pending_cents) },
        { key: 'approved_cents', label: 'Approved, to pay', num: true, render: (x) => $(x.approved_cents) }, { key: 'paid_cents', label: 'Paid', num: true, render: (x) => $(x.paid_cents) },
        { key: 'act', label: '', render: (x) => <span className="ad-actions">
          {x.status === 'pending' && <><Act action="referral_partner_decide" payload={{ id: x.id, action: 'approve' }} label="Approve" variant="primary" testId={`rp-approve-${x.referral_code}`} refresh={[root]} done="Approved. Send them their link from their page." />
            <Act action="referral_partner_decide" payload={{ id: x.id, action: 'decline' }} label="Decline" refresh={[root]} done="Declined." confirm={`Decline ${x.business_name}? They are not told by email.`} /></>}
          {x.pending_cents > 0 && <Act action="referral_earning_approve" payload={{ partner: x.id }} label="Approve all" testId={`rp-approve-all-${x.referral_code}`} refresh={[root]} done="Approved." confirm={`Approve every kickback of ${x.business_name} that is waiting. Nothing is paid until you record the payment.`} />}
          {x.approved_cents > 0 && <Act action="referral_partner_payout" payload={{ partner: x.id }} label="Record a payment" testId={`rp-pay-${x.referral_code}`} refresh={[root]} done="Payment recorded."
            fields={[{ name: 'method', label: 'How it was paid', type: 'select', options: PAYOUT_METHODS, required: true, value: 'e_transfer' }, { name: 'reference', label: 'Reference (e-Transfer or transfer number, cheque number)', type: 'text' },
              { name: 'paid_on', label: 'Date paid', type: 'date', required: true, value: list.today }, { name: 'note', label: 'Note', type: 'text' }]} />}</span> }]} />
    </Card>
    <p className="small muted">The program&apos;s starting rate ({$(list.settings.flat_cents)} flat, or {list.settings.percent_bps / 100}%) is set in <Link prefetch={false} className="link" href={`${base}/settings/program`}>Program settings</Link>; each partner&apos;s own rate is on their page. The public sign-up pages are <Link prefetch={false} className="link" href="/partners/body-shops">body shops</Link> and <Link prefetch={false} className="link" href="/partners/tow-trucks">tow trucks</Link>.</p></>);
}
