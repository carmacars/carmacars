import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, BookingLink, Card, Kv, PageHead, Table, d, t } from '@/features/admin/ui';
import { CopyField } from '@/features/partner-crm/PartnerCrmClient';
import { EARNING_WORDS, kindLabel, PAYOUT_METHODS, STATUS_WORDS } from '@/features/referral/model';
import { PARTNER_FIELDS, type PartnerValues } from '@/features/referral/fields';
import { QrSvg } from '@/features/referral/QrSvg';
import { partnerLink, portalAddress } from '@/server/referral/portal';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Referral partner', path: '/admin/referral-partners', noindex: true, description: 'A referral partner: link, flyer, kickbacks and payments.' });
type R = Record<string, unknown>;
type Partner = PartnerValues & { id: string; status: string; kind: string; business_name: string; referral_code: string; rate_text: string; portal_version: number; source: string; signup_note: string | null; created_at: string;
  referrals: number; completed: number; accruing_cents: number; pending_cents: number; approved_cents: number; paid_cents: number };
type Earning = { id: string; kind: string; status: string; booking_number: string; first_name: string; month: string; base_cents: number; amount_cents: number; reason: string | null; note: string | null; approvable: boolean };

// Admin > People > Referral partners > a partner (migration 0164): the short link, QR code and flyer, the private page link, the
// kickbacks and the payments, and the actions: edit, approve a sign-up, pause, a new link, tie a booking.
export default async function ReferralPartner({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read } = await page(`/admin/referral-partners/${id}`);
  const [r, list] = await Promise.all([
    read<{ partner: Partner; today: string; earnings: Earning[]; payouts: R[] } | null>('referral_partner', { id }).catch(() => null),
    read<{ settings: { flat_cents: number; percent_bps: number } }>('referral_partners')]);
  if (!r) notFound();
  const p = r.partner;
  const refresh = [`/admin/referral-partners/${id}`, '/admin/referral-partners'];
  const link = partnerLink(p.referral_code);
  const portal = await portalAddress(id, p.portal_version);
  const mail = `mailto:${p.email ?? ''}?subject=${encodeURIComponent('Your CarmaCars referral link')}&body=${encodeURIComponent(
    `Hello${p.contact_name ? ' ' + p.contact_name.split(' ')[0] : ''},\n\nThank you for joining the CarmaCars referral program. You earn ${p.rate_text} on each rental that comes through your link or code, once the rental is finished and paid in full.\n\nYour link: ${link}\nYour code: ${p.referral_code} (customers can also give it to us by phone or type it in the request form)\nYour private page, with your referrals and earnings: ${portal}\n\nA flyer with your QR code for your counter is attached.\n\nCarmaCars`)}`;
  const live = p.status === 'active';
  return (<>
    <PageHead title={p.business_name} kicker={<><Link prefetch={false} className="link" href="/admin/referral-partners">Referral partners</Link> &gt; {kindLabel(p.kind)}</>}>
      <Act action="referral_partner_save" payload={{ id }} label="Edit" testId="rp-edit" refresh={refresh} done="Saved." fields={PARTNER_FIELDS(p, list.settings, true)} />
      {p.status === 'pending' && <><Act action="referral_partner_decide" payload={{ id, action: 'approve' }} label="Approve" variant="primary" testId="rp-approve" refresh={refresh} done="Approved." />
        <Act action="referral_partner_decide" payload={{ id, action: 'decline' }} label="Decline" refresh={refresh} done="Declined." confirm="Decline this sign-up? They are not told by email." /></>}
      {live && <Act action="referral_partner_decide" payload={{ id, action: 'pause' }} label="Pause" refresh={refresh} done="Paused." confirm="Pause this partner? Their code stops tying new rentals to them; what they already earned stays." />}
      {(p.status === 'paused' || p.status === 'ended') && <Act action="referral_partner_decide" payload={{ id, action: 'resume' }} label="Resume" refresh={refresh} done="Active again." />}
      {live && <Act action="referral_partner_decide" payload={{ id, action: 'end' }} label="End" refresh={refresh} done="Ended." confirm="End this partnership? Their code stops working; what they already earned is still paid." />}
    </PageHead>
    <Card title="Partner" testId="rp-summary">
      <Kv rows={[['Status', STATUS_WORDS[p.status] ?? p.status], ['Kickback', p.rate_text], ['Contact', [p.contact_name, p.phone, p.email].filter(Boolean).join(', ')],
        ['Address', [p.address_line1, p.city, p.province, p.postal_code].filter(Boolean).join(', ')], ['Paid by', `${PAYOUT_METHODS.find((m) => m[0] === p.payout_method)?.[1] ?? p.payout_method}${p.payout_email ? ` (${p.payout_email})` : ''}`],
        ['Joined', `${d(p.created_at)} (${p.source === 'signup' ? 'signed up on the site' : 'added by an Admin'})`], ['Their note', p.signup_note], ['Notes', p.notes as string | null | undefined]]} />
      <p className="small muted">Referred rentals {p.referrals}, completed {p.completed}. Not earned yet {$(p.accruing_cents)}; pending approval {$(p.pending_cents)}; approved, to pay {$(p.approved_cents)}; paid {$(p.paid_cents)}.</p>
    </Card>
    <Card title="Link, QR code and flyer" testId="rp-link">
      <div className="ad-row" style={{ display: 'flex', gap: '1.5rem', flexWrap: 'wrap', alignItems: 'flex-start' }}>
        <QrSvg text={link} label={`QR code of ${link}`} />
        <div className="stack" style={{ flex: '1 1 20rem' }}>
          <CopyField label="Short link (the QR code opens it)" value={link} testId="rp-short-link" />
          <p className="small muted">A customer who opens it, or scans the code, has the partner kept for 60 days and sent with their request. They can also type the code <b>{p.referral_code}</b> in the request form or tell it to staff, who type it in Add a rental (Referred by).</p>
          <p className="row"><a className="btn btn--primary btn--sm" href={`/admin/referral-partners/${id}/flyer`} target="_blank" rel="noopener" data-testid="rp-flyer">Flyer for the counter (PDF)</a>
            {p.email && <a className="btn btn--ghost btn--sm" href={mail} data-testid="rp-mail">Write them their link</a>}</p>
          <CopyField label="Their private page (referrals and earnings; send it only to them)" value={portal} testId="rp-portal-link" />
          <Act action="referral_partner_link_new" payload={{ id }} label="New private page link" refresh={refresh} done="New link made: copy it above. The old one no longer works." confirm="The old private page link stops working at once. Make a new one?" />
        </div>
      </div>
    </Card>
    <Card title="Tie a booking to this partner" testId="rp-credit">
      <p className="small muted">The renter forgot the code? Enter the booking number. Not possible once a kickback on it is approved or paid, nor on a booking with an owner or field staff referrer.</p>
      <Act action="referral_partner_credit" payload={{ partner: id }} label="Tie a booking" testId="rp-credit-open" refresh={refresh} done="Booking tied to the partner."
        fields={[{ name: 'booking', label: 'Booking number', type: 'text', required: true }, { name: 'reason', label: 'Why', type: 'text', required: true }]} />
    </Card>
    <Card title="Kickbacks" testId="rp-earnings">
      <Table<Earning & R> rows={r.earnings as Array<Earning & R>} rowKey={(x) => x.id} empty="No referred booking yet." cols={[
        { key: 'booking_number', label: 'Booking', render: (x) => <BookingLink n={x.booking_number} /> }, { key: 'first_name', label: 'Renter' }, { key: 'month', label: 'Month' },
        { key: 'base_cents', label: 'Rental charge', num: true, render: (x) => $(x.base_cents) }, { key: 'amount_cents', label: 'Kickback', num: true, render: (x) => $(x.amount_cents) },
        { key: 'status', label: 'Status', className: 'wrap', render: (x) => <span>{x.kind === 'clawback' ? 'Clawback: ' : ''}{EARNING_WORDS[x.status] ?? x.status}{x.reason ? <span className="ad-sub">{x.reason}</span> : null}</span> },
        { key: 'act', label: '', render: (x) => <span className="ad-actions">{x.approvable && <Act action="referral_earning_approve" payload={{ ids: [x.id] }} label="Approve" refresh={refresh} done="Approved." />}
          {x.kind === 'earning' && ['accruing', 'pending_approval', 'approved', 'paid'].includes(x.status) && <Act action="referral_earning_reverse" payload={{ id: x.id }} label="Reverse" refresh={refresh} done="Reversed." fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} />}</span> }]} />
      {p.approved_cents > 0 && <Act action="referral_partner_payout" payload={{ partner: id }} label="Record a payment" variant="primary" testId="rp-pay" refresh={refresh} done="Payment recorded."
        fields={[{ name: 'method', label: 'How it was paid', type: 'select', options: PAYOUT_METHODS, required: true, value: p.payout_method }, { name: 'reference', label: 'Reference (e-Transfer or transfer number, cheque number)', type: 'text' },
          { name: 'paid_on', label: 'Date paid', type: 'date', required: true, value: r.today }, { name: 'note', label: 'Note', type: 'text' }]} />}
    </Card>
    <Card title="Payments made">
      <Table<R> rows={r.payouts} rowKey={(x) => String(x.id)} empty="Nothing paid yet." cols={[{ key: 'paid_on', label: 'Paid', render: (x) => d(x.paid_on) }, { key: 'amount_cents', label: 'Amount', num: true, render: (x) => $(x.amount_cents) },
        { key: 'method', label: 'How', render: (x) => PAYOUT_METHODS.find((m) => m[0] === x.method)?.[1] ?? String(x.method) }, { key: 'reference', label: 'Reference' }, { key: 'created_at', label: 'Recorded', render: (x) => t(x.created_at) }]} />
    </Card>
  </>);
}
