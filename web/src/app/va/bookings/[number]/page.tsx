import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { DepositSettle } from '@/features/admin/DepositSettle';
import { depositMethod, depositStatus } from '@/features/money/deposit-words';
import { BookingReview, type B } from '@/features/admin/BookingReview';
import { BookingAddons } from '@/features/addons/BookingAddons';
import { DriverLinks, ProposeChange, type DriverLinkRow } from '@/features/admin/BookingChanges';
import { $, Badge, Card, Kv, PageHead, Table, Tabs, t, label } from '@/features/admin/ui';
import { REFUND_OF } from '@/features/admin/refunds';
import { BookingMoney, type Money } from '@/features/money/BookingMoney';
import { BookingFees, type Fees } from '@/features/money/BookingFees';
import { BookingEdit, type EditForm } from '@/features/money/BookingEdit';
import { BookingPeriods, type PeriodRow } from '@/features/money/BookingPeriods';
import { RenterEdit, type RenterForm } from '@/features/money/RenterEdit';
import { RenterMerge, type DuplicateRow } from '@/features/money/RenterMerge';
import { door } from '@/server/door';
import { ManualPaymentForm, ManualPaymentList, PaperSignatureForm, PaperSignatureList, type ManualRow, type PaperDoc, type PaperRow } from '@/features/manual/ManualRecords';
import { QuickReply } from '@/features/va/QuickReply';
import { LatePanel, type Late } from '@/features/va/LatePanel';
import { VisitorTimeline, type TimelineData } from '@/features/live/VisitorTimeline';
import { PhoneTimeline } from '@/features/phone/PhoneTimeline';
import { HandoverPanel } from '@/features/handover/HandoverPanel';
import { OwnerDeductionsPanel, OwnerVisibilityPanel } from '@/features/admin/OwnerControls';
import { ReviewPanel } from '@/features/reviews/ReviewPanel';
import { AgreementPanel } from '@/features/agreements/AgreementPanel';
import type { PhoneTimelineData } from '@/features/phone/client';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Booking', path: '/va', noindex: true, description: 'One booking, as the assistant works it.' });

type R = Record<string, unknown>;
type Detail = B & R & {
  renter: { legal_name: string; email?: string; mobile?: string | null; identity_status?: string; bookings?: number } | null;
  offers?: R[]; events: R[]; payments?: R[]; refunds?: R[]; deposit: R | null; statements?: R[]; change_requests: R[]; extensions: R[]; info_requests: R[]; competing: R[]; tasks: R[];
  drivers: R[]; available: boolean; readiness: R | null; request_sent: R; current_offer_version: number | null; offer_expires_at: string | null; request_note: string | null;
};
const REFUND_REASONS = ['cancellation', 'carmacars_cancelled', 'driver_not_verifiable', 'pricing_error', 'breakdown_unused_days', 'goodwill', 'duplicate', 'other'];
const KINDS: Array<[string, string]> = [['handover', 'Handover'], ['delivery', 'Delivery'], ['return_check_in', 'Return check-in'], ['pickup_from_renter', 'Pickup from renter'], ['detail', 'Detail'], ['photo_shoot', 'Photo shoot'], ['recovery', 'Recovery'], ['other', 'Other']];

// One booking for an assistant (05-va.md sections 2 to 5): the admin screens, narrowed by function. Customer
// service and Sales review and offer; Finance sees the money and asks for refunds; Fleet schedules the jobs.
export default async function VaBooking({ params, searchParams }: { params: Promise<{ number: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ number }, sp] = await Promise.all([params, searchParams]);
  const n = decodeURIComponent(number);
  const { read, list, fn, user, aal } = await vaPage(`/va/bookings/${n}`);
  const b = await read<Detail | null>('booking', { number: n }).catch(() => null);
  if (!b) notFound();
  const arranging = ['requested', 'offered', 'pending_payment'].includes(b.status) && (fn === 'cs' || fn === 'sales');
  const tab = sp.tab ?? (arranging ? 'review' : 'overview');
  const base = `/va/bookings/${encodeURIComponent(n)}`;
  const P = { booking: b.id };
  const R = [base];
  // the renter's visits on the site (0060), on the history tab
  const visits = tab === 'history' ? await door<TimelineData>(user.id, 'va_read', 'visitor_timeline', { booking_id: b.id }, aal).catch(() => null) : null;
  // the money by part (0129): record a payment, collect a card, confirm a booking paid another way
  const moneyByPart = tab === 'money' ? await door<Money>(user.id, 'ops_read', 'booking_money', { booking: b.booking_number, _va: fn }, aal).catch(() => null) : null;
  // the fees, each changeable on its own (0132), on the Money tab
  const fees = (tab === 'money' || tab === 'overview') ? await door<Fees>(user.id, 'ops_read', 'booking_fees', { booking: b.booking_number, _va: fn }, aal).catch(() => null) : null;
  // edit the booking directly, even on trip (0132), on the Overview tab
  const editForm = tab === 'overview' && !['requested', 'offered', 'pending_payment', 'tentative'].includes(String(b.status)) ? await door<EditForm>(user.id, 'ops_read', 'booking_edit_form', { booking: b.booking_number, _va: fn }, aal).catch(() => null) : null;
  // correct the renter's details from the booking (0132)
  const renterForm = tab === 'overview' || tab === 'review' ? await door<RenterForm>(user.id, 'ops_read', 'renter_edit_form', { booking: b.booking_number, _va: fn }, aal).catch(() => null) : null;
  // calls and texts with the renter (0085): customer service and Sales
  const calls = tab === 'history' ? await door<PhoneTimelineData>(user.id, 'va_read', 'phone_timeline', { booking_id: b.id }, aal).catch(() => null) : null;
  const [km, replies, staff, messages] = await Promise.all([
    arranging ? list<{ km_per_day: number }>('km_allowance_choices', { eq: { is_active: true } }).catch(() => ({ rows: [], count: 0 })) : Promise.resolve({ rows: [], count: 0 }),
    (fn === 'cs' || fn === 'sales') && tab === 'messages' ? list<{ id: string; title: string; body: string }>('quick_replies', { order: 'sort_order', asc: true }) : Promise.resolve({ rows: [], count: 0 }),
    fn === 'fleet' ? read<{ staff: Array<{ id: string; name: string }> }>('fleet_board') : Promise.resolve({ staff: [] }),
    fn === 'cs' && tab === 'messages' ? read<R[]>('messages', { booking: b.id }) : Promise.resolve([] as R[])]);
  // the additional drivers' signing links (migration 0040), for customer service
  // payments received another way (Finance) and rental documents signed on paper (customer service), migration 0044
  const [manual, paper] = await Promise.all([
    fn === 'finance' && tab === 'money' ? door<ManualRow[]>(user.id, 'ops_read', 'manual_payments', { booking: b.id }, aal).catch(() => [] as ManualRow[]) : Promise.resolve([] as ManualRow[]),
    fn === 'cs' && tab === 'overview' ? door<PaperRow[]>(user.id, 'ops_read', 'paper_signatures', { booking: b.id }, aal).catch(() => [] as PaperRow[]) : Promise.resolve([] as PaperRow[])]);
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  const paperDocs: PaperDoc[] = [{ doc_type: 'rental_agreement', target_id: b.id, label: 'Rental agreement', signer: b.renter?.legal_name ?? '' },
    ...b.change_requests.filter((c) => ['proposed', 'approved'].includes(String(c.status)) && !c.renter_agreed_at).map((c) => ({ doc_type: 'rental_amendment', target_id: String(c.id), label: `Booking change of ${t(c.created_at)}`, signer: b.renter?.legal_name ?? '' }))];
  const driverLinks = fn === 'cs' && tab === 'overview' ? await read<DriverLinkRow[]>('driver_links', { booking: b.id }).catch(() => []) : [];
  // the late-return panel (05-va.md section 3.4) for Fleet and customer service while the car is out past its time
  const late = (fn === 'fleet' || fn === 'cs') && b.status === 'on_rent'
    ? await read<Late | null>('late_panel', { booking: b.id }).catch(() => null) : null;
  const tabs: Array<[string, string, number?]> = [
    ...(arranging ? [[`${base}?tab=review`, 'Review and offer']] as Array<[string, string]> : []), [`${base}?tab=overview`, 'Overview'],
    ...(fn === 'finance' || fn === 'cs' || fn === 'sales' ? [[`${base}?tab=money`, 'Money']] as Array<[string, string]> : []),
    ...(fn === 'cs' ? [[`${base}?tab=changes`, 'Changes', b.change_requests.filter((c) => ['requested', 'proposed'].includes(String(c.status))).length + b.extensions.filter((x) => x.status === 'requested').length], [`${base}?tab=messages`, 'Messages']] as Array<[string, string, number?]> : []),
    ...(fn === 'sales' ? [[`${base}?tab=messages`, 'Messages']] as Array<[string, string]> : []),
    [`${base}?tab=history`, 'History']];
  return (
    <>
      <PageHead kicker={<><Link prefetch={false} className="link" href="/va">Queue</Link> · {b.vehicle?.name} · {b.renter?.legal_name}</>} title={<>{b.booking_number} <Badge s={b.status} /></>}>
        {(fn === 'cs' || fn === 'sales') && b.status === 'requested' && <Act action="ask_info" payload={P} label="Ask the renter" fields={[{ name: 'question', label: 'Question', type: 'textarea', required: true }]} refresh={R} done="Question sent." />}
        {(fn === 'cs' || fn === 'sales') && b.status === 'requested' && <Act action="decline_request" payload={P} label="Decline" variant="danger" fields={[{ name: 'note', label: 'Reason and any alternative', type: 'textarea', required: true }]} refresh={R} />}
        {(fn === 'cs' || (fn === 'sales' && b.status === 'offered')) && ['offered', 'pending_payment'].includes(b.status) && <Link prefetch={false} className="btn btn--primary btn--sm" href={`${base}?tab=review`} data-testid="edit-offer">Edit the offer</Link>}
        {fn === 'cs' && ['confirmed', 'on_rent'].includes(b.status) && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}?tab=changes`} data-testid="edit-booking">Change the booking</Link>}
        {(fn === 'cs' || fn === 'sales') && b.status === 'offered' && <Act action="approve_offer_by_phone" payload={P} label="Renter approved by phone" confirm="Record that the renter approved this offer on the phone. The history shows it was staff." refresh={R} />}
        {(fn === 'cs' || fn === 'sales') && ['offered', 'pending_payment'].includes(b.status) && <Act action="withdraw_offer" payload={P} label="Withdraw the offer" fields={[{ name: 'note', label: 'Note to the renter', type: 'text' }]} refresh={R} />}
        {fn === 'cs' && ['confirmed', 'pending_payment'].includes(b.status) && <Act action="cancel_booking" payload={{ ...P, reason: 'renter_request' }} label="Cancel for the renter" variant="danger" fields={[
          { name: 'channel', label: 'Received by', type: 'select', required: true, options: [['email', 'Email'], ['portal', 'Portal'], ['phone', 'Phone']], value: 'email' },
          { name: 'at', label: 'Received at', type: 'datetime', required: true, value: new Date().toISOString() }, { name: 'note', label: 'Note', type: 'text' }]} refresh={R} />}
        {fn === 'fleet' && ['confirmed', 'on_rent'].includes(b.status) && <Act action="field_job_create" payload={{ ...P, vehicle: b.vehicle_id }} label="Schedule a field job" variant="primary" testId="schedule-job" fields={[
          { name: 'kind', label: 'Kind', type: 'select', required: true, options: KINDS, value: b.status === 'confirmed' ? 'handover' : 'return_check_in' },
          { name: 'assigned_to', label: 'Assigned to', type: 'select', options: staff.staff.map((s) => [s.id, s.name] as [string, string]) },
          { name: 'scheduled_at', label: 'When', type: 'datetime', required: true, value: b.status === 'confirmed' ? b.pickup_at : b.return_at },
          { name: 'place', label: 'Place', type: 'address', required: true, value: (b.status === 'confirmed' ? b.pickup_place : b.return_place) ?? 'Our location' }, { name: 'instructions', label: 'Instructions', type: 'textarea' }]} refresh={R} done="Job scheduled." />}
      </PageHead>
      {late?.late && <LatePanel l={late} fleet={fn === 'fleet'} refresh={R} />}
      {fn === 'fleet' && ['on_rent', 'returned', 'closed'].includes(b.status) && <p className="small"><Link prefetch={false} className="link" href={`/va/review/${encodeURIComponent(n)}`} data-testid="photo-review-link">Photo review: pickup and return side by side</Link></p>}
      {['pending_payment', 'confirmed', 'on_rent', 'returned', 'closed'].includes(b.status) && <HandoverPanel userId={user.id} aal={aal} base={base} canHandover={fn !== 'finance'} canSign={fn !== 'finance'}
        b={{ id: b.id, booking_number: b.booking_number, status: b.status, return_at: b.return_at, checked_in_at: (b.checked_in_at as string | null | undefined) ?? null, minutes_late: (b.minutes_late as number | null | undefined) ?? null }} />}
      {['confirmed', 'on_rent', 'returned', 'closed'].includes(b.status) && <ReviewPanel booking={b.booking_number} userId={user.id} aal={aal} refresh={[base]} />}
      {['pending_payment', 'confirmed', 'on_rent', 'returned', 'closed'].includes(b.status) && <AgreementPanel userId={user.id} aal={aal} base={base} b={{ id: b.id, status: b.status }} docBase="/va/documents" finance={fn === 'finance'} openDocs={fn === 'cs' || fn === 'finance'} />}
      {/* what the owner sees of this booking (0156) */}
      <OwnerVisibilityPanel userId={user.id} aal={aal} va={fn} booking={b.booking_number} refresh={R} />
      <Tabs current={`${base}?tab=${tab}`} items={tabs} />
      {tab === 'review' && arranging && (
        <>
          <Card title="The request as sent">
            <Kv rows={[['Pickup', t(b.request_sent.pickup_at)], ['Return', t(b.request_sent.return_at)], ['Note', String(b.request_note ?? '')], ['Renter', `${b.renter?.legal_name ?? ''}${b.renter?.bookings ? `, ${b.renter.bookings} past bookings` : ', first booking'}`],
              ['Offer', b.current_offer_version ? `version ${b.current_offer_version}${b.offer_expires_at ? `, open until ${t(b.offer_expires_at)}` : ''}` : 'not sent yet'], ['Car free', b.available ? 'yes' : 'no']]} />
          </Card>
          {['requested', 'offered', 'pending_payment', 'confirmed'].includes(b.status) && (await door<{ handover_note: string | null }>(user.id, 'va_read', 'listing_state', { vehicle_id: b.vehicle_id }, aal).catch(() => null))?.handover_note && <p className="alert alert--warn" role="note" data-testid="offer-policy-warning"><span className="alert__title">Car not on the fleet policy yet</span><span>Requests, offers and payment are fine; the car cannot be handed over until the insurer confirms it (the car&apos;s onboarding).</span></p>}
          <BookingReview b={b} insurers={[]} kmChoices={km.rows.map((k) => k.km_per_day)} offerHours={24} editable={['requested', 'offered'].includes(b.status) || (b.status === 'pending_payment' && fn === 'cs')} />
        </>
      )}
      {tab === 'overview' && editForm && <BookingEdit x={editForm} fees={fees} />}
      {(tab === 'overview' || tab === 'money') && b.billable_days > 27 && <BookingPeriods booking={b.booking_number} rows={await door<PeriodRow[]>(user.id, 'ops_read', 'booking_periods', { booking: b.booking_number }, aal).catch(() => [] as PeriodRow[])} />}
      {(tab === 'overview' || tab === 'review') && renterForm && <RenterEdit x={renterForm} />}
      {(tab === 'overview' || tab === 'review') && renterForm?.may_edit && <RenterMerge renterId={renterForm.renter_id} name={renterForm.now.full_name ?? 'this renter'} rows={await door<DuplicateRow[]>(user.id, 'ops_read', 'renter_duplicates', { renter: renterForm.renter_id }, aal).catch(() => [] as DuplicateRow[])} />}
      {tab === 'overview' && (
        <div className="ad-cols ad-cols--2">
          <Card title="Trip">
            <Kv rows={[['Car', `${b.vehicle?.name ?? ''} ${b.vehicle?.plate ?? ''}`], ['Pickup', `${t(b.pickup_at)}, ${b.pickup_place ?? 'our location'}`], ['Return', `${t(b.return_at)}, ${b.return_place ?? 'our location'}`],
              ['Renter', b.renter?.legal_name ?? ''], ['Deposit', b.deposit ? depositStatus(b.deposit.status) : 'not taken'],
              ['Ready for handover', b.readiness ? ((b.readiness.missing as string[] | undefined)?.length ? `missing: ${(b.readiness.missing as string[]).map(label).join(', ')}` : 'yes') : '']]} />
          </Card>
          <Card title="Open tasks"><Table rows={b.tasks} empty="No open tasks." cols={[{ key: 'title', label: 'Task', className: 'wrap' }, { key: 'queue', label: 'Queue' }, { key: 'due_at', label: 'Due', render: (r) => t(r.due_at) }]} /></Card>
          <Card title="Add-ons" testId="booking-addons-card"><BookingAddons items={b.addons ?? []} status={b.status} refresh={R} /></Card>
          <Card title="Drivers"><Table rows={b.drivers} empty="No drivers." cols={[{ key: 'full_name', label: 'Name' }, { key: 'role', label: 'Role' }]} /></Card>
          {fn === 'cs' && <Card title="Additional drivers' signing links"><DriverLinks rows={driverLinks} refresh={R} /></Card>}
          {fn === 'cs' && <Card title="Signed on paper" testId="booking-paper"><div className="stack"><p className="small muted">The renter signed the rental agreement or a change on paper: upload the scan and it counts as signed. Only an Admin can void it.</p><PaperSignatureList rows={paper} canVoid={false} docBase="/va/documents" /><PaperSignatureForm docs={paperDocs} today={today} refresh={R} /></div></Card>}
        </div>
      )}
      {tab === 'money' && <OwnerDeductionsPanel userId={user.id} aal={aal} va={fn} booking={b.booking_number} refresh={R} />}
      {tab === 'money' && moneyByPart && !b.payments && <><BookingMoney m={moneyByPart} />{fees && <BookingFees x={fees} />}</>}
      {tab === 'money' && b.payments && (
        <div className="stack">
          {moneyByPart && <BookingMoney m={moneyByPart} />}
          {fees && <BookingFees x={fees} />}
          {(!moneyByPart || b.payments.some((r) => r.status === 'failed')) && <Card title={moneyByPart ? 'Card payments that failed' : 'Payments'}><Table rows={moneyByPart ? b.payments.filter((r) => r.status === 'failed') : b.payments} empty="No payments." cols={[{ key: 'created_at', label: 'When', render: (r) => t(r.created_at) }, { key: 'purpose', label: 'Purpose' }, { key: 'kind', label: 'Kind' }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'card_last4', label: 'Card' },
            { key: 'act', label: '', render: (r) => fn === 'finance' && r.status === 'failed' && r.kind === 'charge' ? <ManualPaymentForm prefix="bk-rp" booking={b.id} settlesPayment={String(r.id)} number={String(r.id).slice(0, 8)} balance={Number(r.amount_cents)} today={today} refresh={R} label="Paid another way" /> : null }]} /></Card>}
          {fn === 'finance' && <Card title="Paid another way" testId="booking-manual-payments"><ManualPaymentList rows={manual} canVoid={false} docBase="/va/documents" /><ManualPaymentForm booking={b.id} number={b.booking_number} balance={0} today={today} refresh={R} label="Record a payment received another way" /></Card>}
          <Card title="Refunds" aside={fn === 'finance' ? <Act action="request_refund" payload={P} label="Request a refund" testId="request-refund" fields={[{ name: 'reason', label: 'Reason', type: 'select', required: true, options: REFUND_REASONS.map((x) => [x, label(x)] as [string, string]) }, { name: 'refund_of', label: 'What it refunds', type: 'select', required: true, options: REFUND_OF, value: 'rental', hint: 'Only a refund of the rental charge lowers staff commissions.' }, { name: 'amount_cents', label: 'Amount', type: 'money', required: true }, { name: 'note', label: 'Note', type: 'text' }]} refresh={R} done="Refund requested." /> : null}>
            <Table rows={b.refunds ?? []} testId="refunds" empty="No refunds." cols={[{ key: 'created_at', label: 'Requested', render: (r) => t(r.created_at) }, { key: 'reason', label: 'Reason', render: (r) => label(r.reason) }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)}>{r.status === 'pending_approval' ? 'Waiting for an Admin' : undefined}</Badge> }, { key: 'due_by', label: 'Due by' },
              { key: 'act', label: '', render: (r) => fn === 'finance' && r.status === 'pending_approval' ? <Act action="refund_approve" payload={{ id: r.id }} label="Approve (within my limit)" refresh={R} /> : null }]} />
          </Card>
          <Card title="Deposit" aside={fn === 'finance' && (b.deposit || ['returned', 'closed'].includes(b.status)) ? <DepositSettle bookingId={b.id} bookingNumber={b.booking_number} refresh={R} /> : null}>
            {b.deposit ? <Kv rows={[['Amount', $(b.deposit.amount_cents)], ['Method', depositMethod(b.deposit.method)], ['Status', depositStatus(b.deposit.status)], ['Release due', String(b.deposit.release_due_on ?? '')]]} /> : <p className="small muted">No deposit taken yet ({$(b.deposit_cents)} at pickup).</p>}
          </Card>
          {fn === 'finance' && b.status === 'returned' && <Card title="Statement"><Act action="issue_booking_statement" payload={P} label="Issue the final statement" confirm="Issue the Check-in statement from the assessed lines. Damage lines wait for an Admin." refresh={R} /></Card>}
        </div>
      )}
      {tab === 'changes' && fn === 'cs' && (
        <div className="stack">
          {b.status === 'confirmed' && b.bill_to === 'renter' && <Card title="Propose a change" testId="propose-card"><ProposeChange booking={b.id} number={b.booking_number} pickupAt={b.pickup_at} returnAt={b.return_at} vehicleId={b.vehicle_id} rentalCents={Number(b.rental_charge_cents ?? 0)} refresh={R} /></Card>}
          <Card title="Change requests"><Table rows={b.change_requests} testId="change-requests" empty="No change requests." cols={[{ key: 'created_at', label: 'When', render: (r) => t(r.created_at) }, { key: 'requested_by_role', label: 'From' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'note', label: 'Reason', className: 'wrap' }, { key: 'accept_by', label: 'Answer by', render: (r) => t(r.accept_by) }, { key: 'total_difference_cents', label: 'Difference', num: true, render: (r) => $(r.total_difference_cents) },
            { key: 'act', label: 'Decide', render: (r) => r.status === 'requested' ? <span className="ad-actions"><Act action="approve_change" payload={{ request: r.id }} label="Approve" variant="primary" refresh={R} /><Act action="decline_change" payload={{ request: r.id }} label="Decline" fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={R} /></span>
              : r.status === 'proposed' ? <Act action="change_withdraw" payload={{ request: r.id }} label="Withdraw" confirm="The renter can no longer accept this change. The booking stays as it is." refresh={R} testId="change-withdraw" /> : null }]} /></Card>
          <Card title="Extensions"><Table rows={b.extensions} empty="No extensions." cols={[{ key: 'seq', label: 'No.' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'new_return_at', label: 'New return', render: (r) => t(r.new_return_at) }, { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) },
            { key: 'act', label: 'Decide', render: (r) => r.status === 'requested' ? <span className="ad-actions"><Act action="approve_extension" payload={{ extension: r.id }} label="Approve and send the pay link" variant="primary" refresh={R} /><Act action="decline_extension" payload={{ extension: r.id }} label="Decline" fields={[{ name: 'reason', label: 'Reason', type: 'text' }]} refresh={R} /></span> : null }]} /></Card>
          <Card title="Questions to the renter"><Table rows={b.info_requests} empty="No questions." cols={[{ key: 'asked_at', label: 'Asked', render: (r) => t(r.asked_at) }, { key: 'question', label: 'Question', className: 'wrap' }, { key: 'status', label: 'Status' }, { key: 'reply', label: 'Reply', className: 'wrap' }]} /></Card>
        </div>
      )}
      {tab === 'messages' && (fn === 'cs' || fn === 'sales') && (
        <div className="ad-cols ad-cols--2">
          <Card title="Messages"><ol className="ad-timeline" data-testid="messages">{messages.map((m) => <li key={String(m.id)}><time>{t(m.occurred_at)}</time><span><b>{m.direction === 'inbound' ? String(m.renter_first_name ?? 'Renter') : String(m.sent_by ?? 'CarmaCars')}</b> {String(m.body ?? m.subject ?? '')}</span></li>)}</ol>{!messages.length && <p className="small muted">No messages on this booking.</p>}</Card>
          <Card title="Reply"><QuickReply booking={b.id} replies={replies.rows} /></Card>
        </div>
      )}
      {tab === 'history' && (
        <div className="ad-cols ad-cols--2">
          <Card title="Timeline" testId="timeline"><ol className="ad-timeline">{b.events.map((e) => <li key={String(e.id)}><time>{t(e.created_at)}</time><span><b>{label(e.kind)}</b>{e.note ? `: ${String(e.note)}` : ''} <span className="muted small">{String(e.actor_name ?? e.actor_type ?? '')}</span></span></li>)}</ol></Card>
          <div className="stack">
            {calls && <Card title="Calls and texts" testId="booking-calls"><PhoneTimeline t={calls} inbox="/va/chat" /></Card>}
            <Card title="On the site" testId="booking-visits"><VisitorTimeline t={visits} chatBase="/va/chat" /></Card>
          </div>
        </div>
      )}
    </>
  );
}
