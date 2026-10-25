import Link from 'next/link';
import { VisitorTimeline, type TimelineData } from '@/features/live/VisitorTimeline';
import { PhoneTimeline } from '@/features/phone/PhoneTimeline';
import type { PhoneTimelineData } from '@/features/phone/client';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { DepositSettle } from '@/features/admin/DepositSettle';
import { DocumentReview } from '@/features/admin/DocumentReview';
import '@/features/admin/todo/todo.css';
import { GeneratedFiles } from '@/features/admin/GeneratedFiles';
import { BookingReview, type B } from '@/features/admin/BookingReview';
import { BookingAddons } from '@/features/addons/BookingAddons';
import { DriverLinks, ProposeChange, type DriverLinkRow } from '@/features/admin/BookingChanges';
import { door } from '@/server/door';
import { ManualPaymentForm, ManualPaymentList, PaperSignatureForm, PaperSignatureList, type ManualRow, type PaperDoc, type PaperRow } from '@/features/manual/ManualRecords';
import { $, Badge, Card, Kv, PageHead, Table, Tabs, t, label } from '@/features/admin/ui';
import { REFUND_OF } from '@/features/admin/refunds';
import { BookingMoney, type Money } from '@/features/money/BookingMoney';
import { HandoverPanel } from '@/features/handover/HandoverPanel';
import { ReviewPanel } from '@/features/reviews/ReviewPanel';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Booking', path: '/admin/bookings', noindex: true, description: 'One booking: review, money, history.' });

type R = Record<string, unknown>;
type SalesCredit = { staff_id: string | null; how: string | null; at: string | null; name: string | null; by: string | null; revenue_cents: number; options: Array<{ id: string; name: string; function: string }>;
  sourced?: boolean; choice?: string | null; choice_by?: string | null; claim_by?: string | null; supply_type?: string;
  price?: { rental_cents: number; rate_sheet_cents: number | null; reason: string | null; by: string | null; at: string; flags: string[]; reviewed_at: string | null; review_note: string | null;
    /** 0112 */ tax?: 'plus' | 'included'; with_tax_cents?: number | null } | null;
  commissions?: Array<{ id: string; name: string; kind: string; status: string; rate_bps: number; base_cents: number; amount_cents: number; reason: string | null }> };
const HOW: Record<string, string> = { quote: 'their quote', manual_rental: 'a rental they added', offer: 'the first offer they sent', admin: 'given by an Admin', referral: 'their referral link' };
type Detail = B & R & {
  renter: { id: string; legal_name: string; email: string; mobile: string | null; identity_status: string; is_blocked: boolean; bookings: number } | null;
  offers: R[]; events: R[]; history: R[]; emails: R[]; payments: R[]; refunds: R[]; deposit: R | null; statements: R[]; documents: R[];
  change_requests: R[]; extensions: R[]; info_requests: R[]; competing: R[]; tasks: R[]; drivers: R[]; available: boolean; readiness: R | null;
  request_sent: R; current_offer_version: number | null; offer_expires_at: string | null; insurer_name: string | null; request_note: string | null;
};

// One booking for every status (03-admin.md section 4): the review-and-adjust screen while it is a
// request, then money, changes and the full history.
export default async function Booking({ params, searchParams }: { params: Promise<{ number: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ number }, sp] = await Promise.all([params, searchParams]);
  const n = decodeURIComponent(number);
  const { read, list, user } = await page(`/admin/bookings/${n}`);
  const [b, ins, km, settings] = await Promise.all([
    read<Detail | null>('booking', { number: n }), list<{ id: string; name: string }>('insurers', { eq: { is_active: true }, order: 'name', asc: true }),
    list<{ km_per_day: number }>('km_allowance_choices', { eq: { is_active: true } }), read<{ program: { offer_expiry_hours: number } }>('settings')]);
  if (!b) notFound();
  // who the booking is credited to for sales tracking, and who an Admin may give it to (0057)
  const credit = await read<SalesCredit>('booking_sales', { booking: b.id }).catch(() => null);
  const driverLinks = sp.tab === 'documents' ? await read<DriverLinkRow[]>('driver_links', { booking: b.id }).catch(() => []) : [];
  const base = `/admin/bookings/${encodeURIComponent(n)}`;
  // payments received another way and documents signed on paper (migration 0044)
  const [manual, paper] = await Promise.all([
    sp.tab === 'money' ? door<ManualRow[]>(user.id, 'ops_read', 'manual_payments', { booking: b.id }).catch(() => [] as ManualRow[]) : Promise.resolve([] as ManualRow[]),
    sp.tab === 'documents' ? door<PaperRow[]>(user.id, 'ops_read', 'paper_signatures', { booking: b.id }).catch(() => [] as PaperRow[]) : Promise.resolve([] as PaperRow[])]);
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  const paperDocs: PaperDoc[] = [{ doc_type: 'rental_agreement', target_id: b.id, label: 'Rental agreement', signer: b.renter?.legal_name ?? '' },
    ...b.change_requests.filter((c) => ['proposed', 'approved'].includes(String(c.status)) && !c.renter_agreed_at).map((c) => ({ doc_type: 'rental_amendment', target_id: String(c.id), label: `Booking change of ${t(c.created_at)}`, signer: b.renter?.legal_name ?? '' }))];
  const arranging = ['requested', 'offered', 'pending_payment'].includes(b.status);
  const tab = sp.tab ?? (arranging ? 'review' : 'overview');
  const P = { booking: b.id };
  // the renter's visits on the site (0060), on the history tab
  // the money by part (0129), on the Money tab
  const moneyByPart = tab === 'money' ? await door<Money>(user.id, 'ops_read', 'booking_money', { booking: b.booking_number }).catch(() => null) : null;
  const visits = tab === 'history' ? await door<TimelineData>(user.id, 'admin_read', 'visitor_timeline', { booking_id: b.id }).catch(() => null) : null;
  // calls and texts with the renter about this booking (0085)
  const calls = tab === 'history' ? await door<PhoneTimelineData>(user.id, 'admin_read', 'phone_timeline', { booking_id: b.id }).catch(() => null) : null;
  const refresh = [base, '/admin/requests'];
  const pendingChanges = b.change_requests.filter((c) => ['requested', 'proposed'].includes(String(c.status)));
  const pendingExt = b.extensions.filter((x) => x.status === 'requested');
  return (
    <>
      <PageHead kicker={<><Link prefetch={false} className="link" href="/admin/bookings">Bookings</Link> · {b.vehicle?.name} · {b.renter?.legal_name}</>} title={<>{b.booking_number} <Badge s={b.status} />{b.readiness?.awaiting_signature === true && <> <Badge s="awaiting_signature" /></>} {!b.blocks_calendar && <span className="ad-flag">not blocking</span>}</>}>
        {b.status === 'requested' && <Act action="ask_info" payload={P} label="Ask the renter" fields={[{ name: 'question', label: 'Question', type: 'textarea', required: true }]} refresh={refresh} done="Question sent." />}
        {b.status === 'requested' && <Act action="decline_request" payload={P} label="Decline" variant="danger" fields={[{ name: 'note', label: 'Reason and any alternative', type: 'textarea', required: true }]} refresh={refresh} testId="decline" />}
        {['offered', 'pending_payment'].includes(b.status) && <Link prefetch={false} className="btn btn--primary btn--sm" href={`${base}?tab=review`} data-testid="edit-offer">Edit the offer</Link>}
        {['confirmed', 'on_rent'].includes(b.status) && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}?tab=changes`} data-testid="edit-booking">Change the booking</Link>}
        {['offered', 'pending_payment'].includes(b.status) && <Act action="withdraw_offer" payload={P} label="Withdraw the offer" confirm="The renter's offer is withdrawn and they are told. To change it instead, press Edit the offer." fields={[{ name: 'note', label: 'Note to the renter', type: 'text' }]} refresh={refresh} />}
        {b.status === 'offered' && <Act action="resend_offer" payload={P} label="Send again, later expiry" fields={[{ name: 'expires_at', label: 'Open until', type: 'datetime', required: true }, { name: 'message', label: 'Message', type: 'textarea' }]} refresh={refresh} />}
        {b.status === 'offered' && <Act action="approve_offer_by_phone" payload={P} label="Renter approved by phone" confirm="Record that the renter approved this offer on the phone. The history shows it was staff." refresh={refresh} />}
        {b.status === 'expired' && <Act action="reopen_expired" payload={P} label="Reopen" fields={[{ name: 'note', label: 'Note', type: 'text' }]} refresh={refresh} />}
        {['confirmed', 'on_rent', 'requested', 'offered', 'pending_payment'].includes(b.status) && <Act action="blocks_calendar" payload={{ ...P, blocks: !b.blocks_calendar }} label={b.blocks_calendar ? 'Stop blocking the calendar' : 'Block the calendar'} fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={refresh} />}
        {['confirmed', 'pending_payment'].includes(b.status) && <Act action="cancel_booking" payload={P} label="Cancel for the renter" variant="danger" fields={[
          { name: 'channel', label: 'Received by', type: 'select', required: true, options: [['email', 'Email'], ['portal', 'Portal'], ['phone', 'Phone']], value: 'email' },
          { name: 'at', label: 'Received at', type: 'datetime', required: true, value: new Date().toISOString() }, { name: 'note', label: 'Note', type: 'text' }]} refresh={refresh} />}
        {['confirmed', 'pending_payment'].includes(b.status) && <Act action="cancel_booking" payload={{ ...P, reason: 'carmacars_cancelled', channel: 'email' }} label="Cancel by CarmaCars" variant="danger" fields={[{ name: 'note', label: 'Reason (no vehicle, driver not verifiable, pricing error, other)', type: 'text', required: true }]} refresh={refresh} />}
        {b.status === 'on_rent' && <Act action="swap_vehicle" payload={P} label="Swap vehicle" fields={[{ name: 'vehicle', label: 'New vehicle id', type: 'text', required: true }, { name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={refresh} />}
        {['confirmed', 'on_rent', 'returned', 'closed'].includes(b.status) && b.bill_to !== 'renter' && <Act action="draft_insurer_invoice" payload={P} label="Draft insurer invoice" refresh={['/admin/insurer-invoices']} />}
        {b.status === 'returned' && <Act action="issue_booking_statement" payload={P} label="Issue final statement" confirm="Issue the Check-in statement from the assessed lines and settle the deposit plan." refresh={refresh} />}
      </PageHead>
      {['pending_payment', 'confirmed', 'on_rent', 'returned', 'closed'].includes(b.status) && <HandoverPanel userId={user.id} base={base} canHandover canSign
        b={{ id: b.id, booking_number: b.booking_number, status: b.status, return_at: b.return_at, checked_in_at: (b.checked_in_at as string | null | undefined) ?? null, minutes_late: (b.minutes_late as number | null | undefined) ?? null }} />}
      {['confirmed', 'on_rent', 'returned', 'closed'].includes(b.status) && <ReviewPanel booking={b.booking_number} userId={user.id} refresh={[base]} />}
      <Tabs current={`${base}?tab=${tab}`} items={[
        ...(arranging ? [[`${base}?tab=review`, 'Review and offer']] as Array<[string, string]> : [[`${base}?tab=overview`, 'Overview']] as Array<[string, string]>),
        [`${base}?tab=money`, 'Money'], [`${base}?tab=changes`, 'Changes', pendingChanges.length + pendingExt.length], [`${base}?tab=history`, 'History'], [`${base}?tab=documents`, 'Drivers and documents']]} />
      {tab === 'review' && (
        <>
          <div className="ad-cols ad-cols--2">
            <Card title="The request as sent">
              <Kv rows={[['Pickup', t(b.request_sent.pickup_at)], ['Return', t(b.request_sent.return_at)], ['Note', String(b.request_note ?? '')],
                ['Renter', <>{b.renter?.legal_name} · {b.renter?.email} · {b.renter?.mobile} · {b.renter?.bookings ? `${b.renter.bookings} past bookings` : 'first booking'}{b.renter?.is_blocked ? <b className="ad-late"> blocked</b> : null}</>],
                ['Offer', b.current_offer_version ? `version ${b.current_offer_version}${b.offer_expires_at ? `, open until ${t(b.offer_expires_at)}` : ''}` : 'not sent yet'],
                ['Sales credit', credit ? <SalesCreditLine key="sc" c={credit} booking={b.booking_number} refresh={refresh} /> : '']]} />
            </Card>
            <Card title="Competing for these dates" aside={<span className="small">{b.available ? 'car free' : <b className="ad-late">car not free</b>}</span>}>
              {b.competing.length ? <ul className="ad-list">{b.competing.map((c) => <li key={String(c.id)}><Link prefetch={false} className="link" href={`/admin/bookings/${c.booking_number}`}>{String(c.booking_number)}</Link><Badge s={String(c.status)} /><span className="ad-sub">{t(c.pickup_at)} to {t(c.return_at)}</span></li>)}</ul> : <p className="small muted">No other request, offer or booking overlaps.</p>}
            </Card>
          </div>
          {['requested', 'offered', 'pending_payment', 'confirmed'].includes(b.status) && (await door<{ handover_note: string | null }>(user.id, 'ops_read', 'listing_state', { vehicle_id: b.vehicle_id }).catch(() => null))?.handover_note && <p className="alert alert--warn" role="note" data-testid="offer-policy-warning"><span className="alert__title">Car not on the fleet policy yet</span><span>Requests, offers and payment are fine; the car cannot be handed over until the insurer confirms it. When it does, press Insurer confirmed on <Link prefetch={false} className="link" href={`/admin/vehicles/${b.vehicle_id}?tab=listing`}>the car</Link> (or on Admin &gt; Today).</span></p>}
          {/* the renter's licence, uploaded with the request (0130) */}
          <RenterDocs b={b} refresh={[base]} />
          <BookingReview b={b} insurers={ins.rows} kmChoices={km.rows.map((k) => k.km_per_day)} offerHours={settings.program.offer_expiry_hours ?? 24} editable={['requested', 'offered', 'pending_payment'].includes(b.status)} />
        </>
      )}
      {tab === 'overview' && (
        <div className="ad-cols ad-cols--2">
          <Card title="Trip">
            <Kv rows={[['Car', <Link prefetch={false} key="c" className="link" href={`/admin/vehicles/${b.vehicle_id}`}>{b.vehicle?.name} {b.vehicle?.plate}</Link>], ['Pickup', `${t(b.pickup_at)}, ${b.pickup_place ?? 'our location'}`],
              ['Return', `${t(b.return_at)}, ${b.return_place ?? 'our location'}`], ['Days', String(b.billable_days)], ['Bill to', `${label(b.bill_to)}${b.insurer_name ? `, ${b.insurer_name} claim ${b.insurer_claim_number ?? ''}` : ''}`],
              ['Renter', <>{b.renter?.legal_name} · {b.renter?.email} · {b.renter?.mobile}</>], ['Identity', label(b.renter?.identity_status)],
              ...(b.added_by_staff ? [['Added by hand', <span key="a" data-testid="booking-added">{b.added_mode === 'past' ? 'A past rental recorded by staff' : b.added_mode === 'in_progress' ? 'Added by staff while already underway (recorded as on trip at the pickup)' : 'Added by staff'}; source {label(b.source)}; payment: {label(b.payment_mode)}{b.do_not_email ? '; renter not emailed' : ''}{b.clash_override_reason ? `; added over a clash: ${String(b.clash_override_reason)}` : ''}</span>] as [string, React.ReactNode]] : []),
              ['Sales credit', credit ? <SalesCreditLine key="sc" c={credit} booking={b.booking_number} refresh={refresh} /> : ''],
              ['Ready for handover', b.readiness ? ((b.readiness.missing as string[] | undefined)?.length ? `missing: ${(b.readiness.missing as string[]).map(label).join(', ')}` : 'yes') : '']]} />
          </Card>
          {['pending_payment', 'confirmed', 'on_rent', 'requested', 'offered'].includes(b.status) && <RenterDocs b={b} refresh={[base]} />}
          <Card title="Price">
            <dl className="pt-dl pt-dl--money">{b.lines.map((l) => <div key={l.id}><dt>{l.description || label(l.charge_type)} <span className="muted small">{l.stage}</span></dt><dd>{$(l.amount_cents)}</dd></div>)}
              <div><dt><b>Total at booking</b></dt><dd><b>{$(b.total_due_at_booking_cents)}</b></dd></div></dl>
          </Card>
          <Card title="Add-ons" testId="booking-addons-card"><BookingAddons items={b.addons ?? []} status={b.status} refresh={[base]} /></Card>
          <Card title="Open tasks"><Table rows={b.tasks} empty="No open tasks." cols={[{ key: 'title', label: 'Task', className: 'wrap' }, { key: 'queue', label: 'Queue' }, { key: 'due_at', label: 'Due', render: (r) => t(r.due_at) }]} /></Card>
        </div>
      )}
      {tab === 'money' && (
        <div className="stack">
          {moneyByPart && <BookingMoney m={moneyByPart} />}
          <Card title="Payments"><Table rows={b.payments} empty="No payments." cols={[{ key: 'created_at', label: 'When', render: (r) => t(r.created_at) }, { key: 'purpose', label: 'Purpose' }, { key: 'kind', label: 'Kind' }, { key: 'method', label: 'Method' }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'card_last4', label: 'Card' },
            { key: 'act', label: '', render: (r) => r.status === 'failed' && r.kind === 'charge' ? <ManualPaymentForm prefix="bk-rp" booking={b.id} settlesPayment={String(r.id)} number={String(r.id).slice(0, 8)} balance={Number(r.amount_cents)} today={today} refresh={[base]} label="Paid another way" /> : null }]} /></Card>
          <Card title="Paid another way" testId="booking-manual-payments">
            <ManualPaymentList rows={manual} canVoid refresh={[base]} />
            <ManualPaymentForm booking={b.id} number={b.booking_number} balance={0} today={today} refresh={[base]} label="Record a payment received another way" />
          </Card>
          <Card title="Refunds" aside={b.payments.length ? <Act action="request_refund" payload={P} label="New refund" testId="new-refund" fields={[{ name: 'reason', label: 'Reason', type: 'select', required: true, options: ['cancellation', 'carmacars_cancelled', 'driver_not_verifiable', 'pricing_error', 'breakdown_unused_days', 'goodwill', 'duplicate', 'other'].map((x) => [x, label(x)] as [string, string]) }, { name: 'refund_of', label: 'What it refunds', type: 'select', required: true, options: REFUND_OF, value: 'rental', hint: 'Only a refund of the rental charge lowers staff commissions.' }, { name: 'amount_cents', label: 'Amount', type: 'money', required: true }, { name: 'note', label: 'Note', type: 'text' }]} refresh={[base]} /> : null}>
            <Table rows={b.refunds} empty="No refunds." cols={[{ key: 'created_at', label: 'Requested', render: (r) => t(r.created_at) }, { key: 'reason', label: 'Reason' }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'due_by', label: 'Due by' }]} />
          </Card>
          <Card title="Deposit" aside={b.deposit ? <DepositSettle bookingId={b.id} refresh={[base]} /> : ['confirmed'].includes(b.status) ? <Act action="waive_deposit" payload={P} label="Waive the deposit" fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={[base]} /> : null}>
            {b.deposit ? <Kv rows={[['Amount', $(b.deposit.amount_cents)], ['Method', label(b.deposit.method)], ['Status', label(b.deposit.status)], ['Applied', $(b.deposit.applied_cents)], ['Held back', $(b.deposit.held_back_cents)], ['Released', $(b.deposit.released_cents)], ['Release due', String(b.deposit.release_due_on ?? '')]]} /> : <p className="small muted">No deposit taken yet ({$(b.deposit_cents)} at pickup).</p>}
          </Card>
          <Card title="Documents"><GeneratedFiles bookingId={b.id} /></Card>
          <Card title="Statements"><Table rows={b.statements} empty="No statements." cols={[{ key: 'statement_number', label: 'Number' }, { key: 'kind', label: 'Kind' }, { key: 'issued_at', label: 'Issued', render: (r) => t(r.issued_at) }, { key: 'charges_cents', label: 'Charges', num: true, render: (r) => $(r.charges_cents) }, { key: 'charged_to_card_cents', label: 'To card', num: true, render: (r) => $(r.charged_to_card_cents) }]} /></Card>
          <Card title="Offers"><Table rows={b.offers} empty="No offers." cols={[{ key: 'version', label: 'Version' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'sent_at', label: 'Sent', render: (r) => t(r.sent_at) }, { key: 'expires_at', label: 'Expires', render: (r) => t(r.expires_at) }, { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) }, { key: 'message', label: 'Message', className: 'wrap' }]} /></Card>
        </div>
      )}
      {tab === 'changes' && (
        <div className="stack">
          {b.status === 'confirmed' && b.bill_to === 'renter' && <Card title="Propose a change" testId="propose-card"><ProposeChange booking={b.id} number={b.booking_number} pickupAt={b.pickup_at} returnAt={b.return_at} vehicleId={b.vehicle_id} rentalCents={Number(b.rental_charge_cents ?? 0)} refresh={[base]} /></Card>}
          <Card title="Change requests"><Table rows={b.change_requests} testId="change-requests" empty="No change requests." cols={[{ key: 'created_at', label: 'When', render: (r) => t(r.created_at) }, { key: 'requested_by_role', label: 'From' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
            { key: 'note', label: 'Reason', className: 'wrap' }, { key: 'accept_by', label: 'Answer by', render: (r) => t(r.accept_by) }, { key: 'total_difference_cents', label: 'Difference', num: true, render: (r) => $(r.total_difference_cents) },
            { key: 'act', label: 'Decide', render: (r) => r.status === 'requested' ? <span className="ad-actions"><Act action="approve_change" payload={{ request: r.id }} label="Approve" variant="primary" refresh={[base]} /><Act action="decline_change" payload={{ request: r.id }} label="Decline" fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={[base]} /></span>
              : r.status === 'proposed' ? <Act action="change_withdraw" payload={{ request: r.id }} label="Withdraw" confirm="The renter can no longer accept this change. The booking stays as it is." refresh={[base]} testId="change-withdraw" />
              : r.status === 'approved' && !r.renter_agreed_at ? <Act action="decline_change" payload={{ request: r.id }} label="Withdraw the approval" fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={[base]} /> : null }]} /></Card>
          <Card title="Extensions"><Table rows={b.extensions} empty="No extensions." cols={[{ key: 'seq', label: 'No.' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'new_return_at', label: 'New return', render: (r) => t(r.new_return_at) }, { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) },
            { key: 'act', label: 'Decide', render: (r) => r.status === 'requested' ? <span className="ad-actions"><Act action="approve_extension" payload={{ extension: r.id }} label="Approve" variant="primary" refresh={[base]} /><Act action="decline_extension" payload={{ extension: r.id }} label="Decline" fields={[{ name: 'reason', label: 'Reason', type: 'text' }]} refresh={[base]} /></span> : null }]} /></Card>
          <Card title="Questions to the renter"><Table rows={b.info_requests} empty="No questions." cols={[{ key: 'asked_at', label: 'Asked', render: (r) => t(r.asked_at) }, { key: 'question', label: 'Question', className: 'wrap' }, { key: 'status', label: 'Status' }, { key: 'reply', label: 'Reply', className: 'wrap' }]} /></Card>
        </div>
      )}
      {tab === 'history' && (
        <div className="ad-cols ad-cols--2">
          <Card title="Timeline" testId="timeline">
            <ol className="ad-timeline">{b.events.map((e) => <li key={String(e.id)}><time>{t(e.created_at)}</time><span><b>{label(e.kind)}</b>{e.from_status && e.to_status && e.from_status !== e.to_status ? ` ${label(e.from_status)} to ${label(e.to_status)}` : ''}{e.offer_version ? `, offer v${String(e.offer_version)}` : ''}{e.note ? `: ${String(e.note)}` : ''} <span className="muted small">{String(e.actor_name ?? e.actor_type ?? '')}</span></span></li>)}</ol>
          </Card>
          <div className="stack">
            <Card title="Status history"><ol className="ad-timeline">{b.history.map((h, i) => <li key={i}><time>{t(h.at)}</time><span>{label(h.from)} to <b>{label(h.to)}</b> <span className="muted small">{String(h.by ?? '')}</span></span></li>)}</ol></Card>
            <Card title="Calls and texts" testId="booking-calls"><PhoneTimeline t={calls} inbox="/admin/chat" /></Card>
            <Card title="On the site" testId="booking-visits"><VisitorTimeline t={visits} chatBase="/admin/chat" /></Card>
            <Card title="Emails sent"><Table rows={b.emails} empty="No emails." cols={[{ key: 'created_at', label: 'When', render: (r) => t(r.created_at) }, { key: 'code', label: 'Email' }, { key: 'to', label: 'To' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }]} /></Card>
          </div>
        </div>
      )}
      {tab === 'documents' && (
        <div className="ad-cols ad-cols--2">
          {['pending_payment', 'confirmed', 'on_rent', 'requested', 'offered'].includes(b.status) && <RenterDocs b={b} refresh={[base]} />}
          <Card title="Drivers"><Table rows={b.drivers} empty="No drivers." cols={[{ key: 'full_name', label: 'Name' }, { key: 'role', label: 'Role' }, { key: 'age_band', label: 'Age band' }, { key: 'licence_last4', label: 'Licence' }, { key: 'accepted_at', label: 'Accepted', render: (r) => t(r.accepted_at) },
            { key: 'identity_verified_on', label: 'Identity', render: (r) => r.identity_verified_on ? `Verified${r.identity_method === 'in_person' ? ' in person' : ''}`
              : ['confirmed', 'pending_payment'].includes(String(b.status)) ? <Act ops action="verify_driver_in_person" payload={{ booking_driver_id: r.id }} label="Verified in person" testId={`verify-in-person-${String(r.role)}`} refresh={[base]}
                  fields={[{ name: 'note', label: 'What you checked (the licence seen, its number, the face matched)', type: 'text', required: true }]} /> : 'Not verified' }]} /></Card>
          <Card title="Documents"><Table rows={b.documents} empty="No documents." cols={[{ key: 'title', label: 'Title', render: (r) => <Link prefetch={false} className="link" href={`/admin/documents/${r.id}`}>{String(r.title ?? label(r.kind))}</Link> }, { key: 'kind', label: 'Kind', render: (r) => label(r.kind) }, { key: 'created_at', label: 'Added', render: (r) => t(r.created_at) }]} /></Card>
          <Card title="Additional drivers' signing links"><DriverLinks rows={driverLinks} refresh={[base]} /></Card>
          <Card title="Signed on paper" testId="booking-paper"><div className="stack"><PaperSignatureList rows={paper} canVoid refresh={[base]} /><PaperSignatureForm docs={paperDocs} today={today} refresh={[base]} /></div></Card>
        </div>
      )}
    </>
  );
}

// The credit line with the Admin's Reassign (a reason is kept in the booking's history; 0057), whether the person sourced
// the client, a claim to decide, a price typed by hand and the commission (0058).
function SalesCreditLine({ c, booking, refresh }: { c: SalesCredit; booking: string; refresh: string[] }) {
  const opts: Array<[string, string]> = [['', 'Choose who'], ...c.options.map((o) => [o.id, `${o.name} (${label(o.function)})`] as [string, string]), ['none', 'Nobody']];
  return (
    <span data-testid="booking-sales-credit">
      {c.staff_id ? <><Link prefetch={false} className="link" href={`/admin/staff/${c.staff_id}/sales`}>{c.name}</Link>, {HOW[c.how ?? ''] ?? ''}{c.how === 'admin' && c.by ? ` (${c.by})` : ''}; counts {$(c.revenue_cents)}</>
        : c.how === 'admin' ? 'Nobody (an Admin removed the credit)' : 'Nobody yet: the first offer sent credits its sender'}
      {c.staff_id ? <span data-testid="booking-sourced">{c.sourced ? '; sourced the client (earns the commission)' : '; entered for CarmaCars (no commission)'}</span> : null}{' '}
      <Act action="sales_reassign" payload={{ booking }} label="Reassign" testId="booking-sales-reassign" refresh={refresh} done="Reassigned."
        fields={[{ name: 'staff', label: 'Credit it to', type: 'select', options: opts, required: true },
          { name: 'sourced', label: 'Did they source the client?', type: 'select', options: [['true', 'Yes: they earn the commission'], ['false', 'No: entered for CarmaCars']], required: true, value: c.sourced ? 'true' : 'false' },
          { name: 'reason', label: 'Reason', type: 'text', required: true }]} />
      {c.claim_by && <span className="ad-sub" data-testid="booking-claim">{c.claim_by} says they sourced this client.{' '}
        <Act action="sales_claim_decide" payload={{ booking, accept: true }} label="Credit them" testId="claim-accept" refresh={refresh} done="Credited." fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} />{' '}
        <Act action="sales_claim_decide" payload={{ booking, accept: false }} label="Not theirs" testId="claim-decline" refresh={refresh} done="Claim closed." fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} /></span>}
      {c.price && <span className="ad-sub" data-testid="booking-custom-price">Price typed by hand: {c.price.tax === 'included' ? `${$(c.price.with_tax_cents ?? 0)} tax included (${$(c.price.rental_cents)} before tax)` : `${$(c.price.rental_cents)} plus tax`}, rate sheet {$(c.price.rate_sheet_cents ?? 0)}{c.price.by ? `, by ${c.price.by}` : ''}. {c.price.reason}
        {c.price.flags.length ? <b className="ad-late"> Flagged: {c.price.flags.map((f) => (f === 'below_floor' ? 'under the price floor' : 'past the discount limit')).join(', ')}.</b> : null}
        {c.price.reviewed_at ? ` Reviewed ${t(c.price.reviewed_at)}.` : <> <Act action="price_review" payload={{ booking }} label="Mark reviewed" testId="price-review" refresh={refresh} done="Reviewed." fields={[{ name: 'note', label: 'Note', type: 'text' }]} /></>}</span>}
      {c.commissions && c.commissions.length > 0 && <span className="ad-sub" data-testid="booking-commissions">Commission: {c.commissions.map((x) => `${x.name} ${$(x.amount_cents)} (${x.kind === 'commission' ? `${x.rate_bps / 100}%, ${x.status.replace(/_/g, ' ')}` : x.kind})`).join('; ')}
        {c.supply_type === 'program_owner' ? '. Deducted with the kickbacks before Owner Revenue.' : c.supply_type === 'partner' ? '. Paid from CarmaCars\' commission.' : '. A CarmaCars expense.'}</span>}
    </span>
  );
}

// The renter's licence, selfie and proof of coverage (0078): reviewed here by an Admin, no task needed. The images load
// when the pop-up opens.
function RenterDocs({ b, refresh }: { b: Detail; refresh: string[] }) {
  const r = b.readiness ?? {};
  const missing = [r.all_drivers_verified === false ? 'every driver\u2019s identity' : '', r.coverage_confirmed === false ? 'the proof of coverage' : ''].filter(Boolean);
  return (
    <Card title="Renter documents" testId="booking-doc-review" tone={missing.length ? 'next' : undefined} aside={<DocumentReview booking={b.booking_number} refresh={refresh} label="Review documents" />}>
      <p className="small">{missing.length ? `Still needed before the handover: ${missing.join(' and ')}. Approve or reject what the renter sent; a rejection tells them why.` : 'Identity and coverage are confirmed.'}</p>
    </Card>
  );
}
