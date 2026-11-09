import Link from '@/components/Link';
import { money } from '@/lib/format';
import { notFound } from 'next/navigation';
import { BOOKING_SECTIONS, bookingSection, shows } from '@/features/booking-sections/sections';
import { BookingCarSection } from '@/features/booking-sections/BookingCarSection';
import { ReopenOffer } from '@/features/offers/ReopenOffer';
import { BookingInsurer, type BookingInsurerData } from '@/features/insurers/BookingInsurer';
import { InsurerClaimEdit, type AdjusterOpt } from '@/features/insurers/InsurerClaimEdit';
import { StaffDocUpload } from '@/features/admin/StaffDocUpload';
import { Act } from '@/features/admin/Act';
import { DepositSettle } from '@/features/admin/DepositSettle';
import { depositStatus } from '@/features/money/deposit-words';
import { DocumentReview } from '@/features/admin/DocumentReview';
import '@/features/admin/todo/todo.css';
import { GeneratedFiles } from '@/features/admin/GeneratedFiles';
import { BookingReview, type B } from '@/features/admin/BookingReview';
import { BookingAddons } from '@/features/addons/BookingAddons';
import { DriverLinks, ProposeChange, type DriverLinkRow } from '@/features/admin/BookingChanges';
import { ManualPaymentForm, ManualPaymentList, PaperSignatureList, type ManualRow, type PaperRow } from '@/features/manual/ManualRecords';
import { $, Badge, Card, Kv, PageHead, Table, Tabs, t, label } from '@/features/admin/ui';
import { REFUND_OF } from '@/features/admin/refunds';
import { BookingMoney, type Money, type PanelLine } from '@/features/money/BookingMoney';
import { BookingFees, type Fees } from '@/features/money/BookingFees';
import { CoverageSwitch } from '@/features/money/CoverageSwitch';
import type { SwitchState } from '@/features/money/coverage-switch';
import { BookingEdit, type EditForm } from '@/features/money/BookingEdit';
import { BookingPeriods, type PeriodRow } from '@/features/money/BookingPeriods';
import { RenterEdit, type RenterForm } from '@/features/money/RenterEdit';
import { RenterMerge, type DuplicateRow } from '@/features/money/RenterMerge';
import { HandoverPanel } from '@/features/handover/HandoverPanel';
import { HandoverOverride } from '@/features/handover/HandoverOverride';
import { BookingSummary } from '@/features/admin/BookingSummary';
import { ReviewPanel } from '@/features/reviews/ReviewPanel';
import { AgreementPanel } from '@/features/agreements/AgreementPanel';
import { OwnerDeductionsPanel, OwnerVisibilityPanel } from '@/features/admin/OwnerControls';
import { MarketingSource, type MarketingData } from '@/features/ads/MarketingSource';
import { ClaimBanner, ClaimGate, RequestClaim } from '@/features/offers/RequestClaim';
import { BookingConversation } from '@/features/messages/BookingConversation';
import type { Conversation } from '@/features/messages/email-choices';
import { MoreActions, NextStepPanel } from '@/features/admin/NextStep';
import { nextStep } from '@/features/admin/next-step';
import { DateConflicts, PlaceholderBanner, type Overlap } from '@/features/admin/DateConflicts';
import { PayPlanCard } from '@/features/bookings-now/PayPlanCard';
import type { Pay } from '@/features/bookings-now/model';
import { ContactButtons } from '@/features/phone/QuoButtons';
import { LatePanel, type Late } from '@/features/va/LatePanel';
import { ReturnedButton } from '@/features/handover/ReturnedButton';
import { showReturned } from '@/features/handover/returned';
import type { PageCtx } from '@/features/shared-pages/context';
import { bookingCan, portalBase } from '@/features/shared-pages/viewer';
import { rpc } from '@/lib/db/repo';
import { signPayOf, signPayWords } from '@/features/portal/sign-pay';
import type { ChargeReasons } from '@/features/money/charge-reasons';
import { ActivityLog } from '@/features/activity/ActivityLog';
import { AccidentSummary } from '@/features/accident-card/AccidentCard';
import type { AccidentCardData } from '@/features/accident-card/model';
import { CountdownTable } from '@/features/deposit-review/Countdowns';
import { stageWords, type Countdowns, type ReviewView } from '@/features/deposit-review/model';
import { activityQuery, readParams, type ActivityPage } from '@/features/activity/model';

// r31 "Simple": one booking page for Admin and staff (03-admin.md section 4, 05-va.md sections 2 to 5). The loader picks
// the access path from the viewer (PageCtx) and reads only what the viewer's function uses; every section and button
// shows by `bookingCan`, so each staff function sees what it saw on its own copy and an Admin keeps everything.

type R = Record<string, unknown>;
type SalesCredit = { staff_id: string | null; how: string | null; at: string | null; name: string | null; by: string | null; revenue_cents: number; options: Array<{ id: string; name: string; function: string }>;
  sourced?: boolean; choice?: string | null; choice_by?: string | null; claim_by?: string | null; supply_type?: string;
  price?: { rental_cents: number; rate_sheet_cents: number | null; reason: string | null; by: string | null; at: string; flags: string[]; reviewed_at: string | null; review_note: string | null;
    /** 0112 */ tax?: 'plus' | 'included'; with_tax_cents?: number | null } | null;
  commissions?: Array<{ id: string; name: string; kind: string; status: string; rate_bps: number; base_cents: number; amount_cents: number; reason: string | null }> };
const HOW: Record<string, string> = { quote: 'their quote', manual_rental: 'a rental they added', offer: 'the first offer they sent', admin: 'given by an Admin', referral: 'their referral link' };
/** What the booking read answers. Staff reads leave out what the function may not see (payments for Sales and customer
 * service, the history and the emails for every function). */
type Detail = B & R & {
  renter: { id?: string; legal_name: string; email?: string; mobile?: string | null; identity_status?: string; is_blocked?: boolean; bookings?: number } | null;
  offers?: R[]; events: R[]; history?: R[]; emails?: R[]; payments?: R[]; refunds?: R[]; deposit: R | null; statements?: R[]; documents?: R[];
  change_requests: R[]; extensions: R[]; info_requests: R[]; competing: Overlap[]; tasks: R[]; drivers: R[]; available: boolean; readiness: R | null;
  /** 0283: a placeholder booking (insurance or a hold) */
  placeholder?: { on: boolean; reason: string | null; at: string | null; by: string | null; shape: boolean };
  request_sent: R; current_offer_version: number | null; offer_expires_at: string | null; insurer_name?: string | null; request_note: string | null;
};
const REFUND_REASONS = ['cancellation', 'carmacars_cancelled', 'driver_not_verifiable', 'pricing_error', 'breakdown_unused_days', 'goodwill', 'duplicate', 'other'];
const KINDS: Array<[string, string]> = [['handover', 'Handover'], ['delivery', 'Delivery'], ['return_check_in', 'Return check-out'], ['pickup_from_renter', 'Pickup from renter'], ['detail', 'Detail'], ['photo_shoot', 'Photo shoot'], ['recovery', 'Recovery'], ['other', 'Other']];
const ARRANGING = ['requested', 'offered', 'pending_payment'];
const none = <T,>(v: T) => () => v;
type NoShiftDay = { leg: string; day: string; work_day: string | null };
// 0910: Change the car: the free cars, each with its new total and the difference
type CarOptions = { refusal: string | null; total_cents: number; cars: Array<{ vehicle_id: string; name: string; plate: string | null; total_cents: number; difference_cents: number }> };
const carChoice = (v: CarOptions['cars'][number]) => `${v.name}${v.plate ? `, ${v.plate}` : ''}: ${money(v.total_cents, { cents: true })} (${v.difference_cents === 0 ? 'same price' : `${v.difference_cents > 0 ? '+' : '-'}${money(Math.abs(v.difference_cents), { cents: true })}`})`;
type BookingChain = { replaced_by: { number: string } | null; replaces: Array<{ number: string }> };
/** "Replaced by #N" on the old booking and "Replaces #M" on the new one, with links (the same on the Admin and staff pages). */
function ReplacedNote({ chain, portal }: { chain: BookingChain | null; portal: string }) {
  if (!chain || (!chain.replaced_by && !chain.replaces.length)) return null;
  const link = (n: string) => <Link prefetch={false} className="link" href={`${portal}/bookings/${encodeURIComponent(n)}`}>#{n}</Link>;
  return (
    <p className="small" data-testid="booking-replaced-note">
      {chain.replaced_by && <span data-testid="booking-replaced-by">Replaced by {link(chain.replaced_by.number)}</span>}
      {chain.replaced_by && chain.replaces.length > 0 && ' · '}
      {chain.replaces.length > 0 && <span data-testid="booking-replaces">Replaces {chain.replaces.map((r, i) => <span key={r.number}>{i > 0 && ', '}{link(r.number)}</span>)}</span>}
    </p>
  );
}

export async function BookingPage({ ctx, number, sp }: { ctx: PageCtx; number: string; sp: Record<string, string | undefined> }) {
  const { viewer, user, aal, read, list, own, ops } = ctx;
  const can = bookingCan(viewer);
  const fn = viewer.role === 'staff' ? viewer.fn : null;
  const portal = portalBase(viewer);
  const n = number;
  const b = can.admin ? await read<Detail | null>('booking', { number: n }) : await read<Detail | null>('booking', { number: n }).catch(none(null));
  // a request customer service has first (offer claims): it is on a Sales person's list before it opens to them, so the
  // list's Open says so here instead of a 404
  if (!b && fn === 'sales') return (
    <>
      <PageHead kicker={<Link prefetch={false} className="link" href="/staff">To do</Link>} title={n} />
      <Card title="Not open to you yet" testId="booking-not-yours">
        <p>Customer service has this request first. It opens to you on your To do list when it is yours to answer, or when it waits too long.</p>
        <p><Link prefetch={false} className="btn btn--ghost btn--sm" href="/staff">Back to To do</Link></p>
      </Card>
    </>
  );
  if (!b) notFound();
  const base = `${portal}/bookings/${encodeURIComponent(n)}`;
  const arranging = ARRANGING.includes(b.status) && can.offer;
  // the six sections (features/booking-sections); the old tab names open the section that holds them now
  const section = bookingSection(sp.tab);
  // staff keep the trip cards under the review while an offer is arranged (they had both before)
  const on = (x: string) => (x === 'overview' && !can.admin ? section === 'overview' : shows(section, x, arranging));
  const P = { booking: b.id };
  const refresh = can.admin ? [base, '/admin/requests'] : [base];
  const inbox = can.inbox ? `${portal}/visitors?view=chat` : null;
  const carHref = can.carLink ? `${portal}/vehicles/${b.vehicle_id}` : null;
  const notOwner = b.booking_type !== 'owner';

  // ---- the reads, each only where the viewer's section and function use it
  // 0780 and 0810: a request that expired and was replaced by a newer one says so on both bookings
  const chain = await ops<BookingChain>('booking_chain', { booking: b.id }).catch(none(null));
  // 0910: the cars this booking may move to before pickup (priced from each car's rate sheet), and its accident card
  const [carOpts, accident] = await Promise.all([
    can.changeCar && ['requested', 'offered', 'pending_payment', 'confirmed'].includes(b.status) && !b.handed_over_at && (section === 'overview' || section === 'car')
      ? ops<CarOptions>('car_change_options', { booking: b.id }).catch(none(null)) : null,
    (section === 'overview' || section === 'documents') && ['pending_payment', 'confirmed', 'on_rent'].includes(b.status) && notOwner
      ? ops<AccidentCardData>('accident_card', { booking: b.id }).catch(none(null)) : null]);
  const [ins, km, settings, credit, came, insurerCard, swapCars, fleetStaff, noShift, late] = await Promise.all([
    can.admin ? list<{ id: string; name: string }>('insurers', { eq: { is_active: true }, order: 'name', asc: true }) : { rows: [] as Array<{ id: string; name: string }>, count: 0 },
    can.admin || arranging ? list<{ km_per_day: number }>('km_allowance_choices', { eq: { is_active: true } }).catch(none({ rows: [] as Array<{ km_per_day: number }>, count: 0 })) : { rows: [] as Array<{ km_per_day: number }>, count: 0 },
    can.admin ? read<{ program: { offer_expiry_hours: number } }>('settings') : null,
    // who the booking is credited to for sales tracking, and who an Admin may give it to (0057)
    can.admin ? read<SalesCredit>('booking_sales', { booking: b.id }).catch(none(null)) : null,
    // where the renter came from, for Marketing > Bookings by channel (0167)
    can.admin && notOwner ? read<MarketingData>('booking_marketing', { booking: b.booking_number }).catch(none(null)) : null,
    // the insurance replacement: the rate sheet for this car, the rate and the insurer's invoices (0163)
    can.admin && (b.bill_to !== 'renter' || ARRANGING.includes(b.status)) ? read<BookingInsurerData | null>('booking_insurer', { booking: b.booking_number }).catch(none(null)) : null,
    // a swap during the trip picks the car from a list, never a typed id (sim item 4)
    can.admin && b.status === 'on_rent' ? list<{ id: string; year: number; make: string; model: string; plate: string | null; status: string }>('vehicles', { order: 'make', asc: true, limit: 500 })
      .then((r) => r.rows.filter((v) => v.id !== b.vehicle_id && v.status === 'available')).catch(none([])) : [],
    can.scheduleJob ? ops<{ staff: Array<{ id: string; name: string; eligible: boolean }> }>('field_staff').catch(none({ staff: [] as Array<{ id: string; name: string; eligible: boolean }> })) : { staff: [] as Array<{ id: string; name: string; eligible: boolean }> },
    // handovers and returns on a day with no field shifts (0880): someone must cover it, or the time must move
    can.scheduleJob ? ops<NoShiftDay[]>('field_no_shift_days', { booking: b.id }).catch(none([] as NoShiftDay[])) : [] as NoShiftDay[],
    // the late-return panel (05-va.md section 3.4) while the car is out past its time
    can.latePanel && b.status === 'on_rent' ? read<Late | null>('late_panel', { booking: b.id }).catch(none(null)) : null]);
  const [driverLinks, manual, paper, moneyByPart, fees, editForm, renterForm, activity, conv] = await Promise.all([
    can.driverLinks && section === 'documents' ? read<DriverLinkRow[]>('driver_links', { booking: b.id }).catch(none([] as DriverLinkRow[])) : [] as DriverLinkRow[],
    // payments received another way and documents signed on paper (migration 0044)
    can.manualPayments && on('money') ? ops<ManualRow[]>('manual_payments', { booking: b.id }).catch(none([] as ManualRow[])) : [] as ManualRow[],
    can.paperSignatures && section === 'documents' ? ops<PaperRow[]>('paper_signatures', { booking: b.id }).catch(none([] as PaperRow[])) : [] as PaperRow[],
    // the money by part (0129), the fees each changeable on its own (0132), the booking and renter edit forms (0132)
    on('money') ? ops<Money>('booking_money', { booking: b.booking_number }, true).catch(none(null)) : null,
    on('money') || on('overview') ? ops<Fees>('booking_fees', { booking: b.booking_number }, true).catch(none(null)) : null,
    on('overview') && !['requested', 'offered', 'pending_payment', 'tentative'].includes(String(b.status)) ? ops<EditForm>('booking_edit_form', { booking: b.booking_number }, true).catch(none(null)) : null,
    on('overview') || on('review') ? ops<RenterForm>('renter_edit_form', { booking: b.booking_number }, true).catch(none(null)) : null,
    // r35 (0850): the booking's one Activity log (emails, texts, chat, calls, notes, events, payments, documents, visits)
    on('history') ? ops<ActivityPage>('renter_activity', { booking: b.booking_number, ...readParams(activityQuery(sp)) }, true).catch(none(null)) : null,
    // Email the renter or the adjuster, with the booking's conversation and emails (0187)
    on('messages') ? ops<Conversation>('booking_conversation', { booking: b.booking_number }, true).catch(none(null)) : null]);
  // r35 (0890): card coverage or the Protection Plan, on an offer or an active booking
  const coverageSwitch = (on('overview') || on('money')) && notOwner && !['cancelled', 'declined', 'expired'].includes(b.status) ? await ops<SwitchState>('coverage_switch_state', { booking: b.booking_number }, true).catch(none(null)) : null;
  const [policyNote, adjusters, pay, periods, duplicates] = await Promise.all([
    on('review') && ['requested', 'offered', 'pending_payment', 'confirmed'].includes(b.status) ? (can.admin ? ops : own)<{ handover_note: string | null }>('listing_state', { vehicle_id: b.vehicle_id }).then((x) => x?.handover_note ?? null).catch(none(null)) : null,
    can.admin && on('overview') && notOwner && !['cancelled', 'declined', 'expired'].includes(b.status) ? own<AdjusterOpt[]>('insurer_adjusters', {}).catch(none([] as AdjusterOpt[])) : null,
    can.admin && (on('overview') || on('money')) && ['pending_payment', 'confirmed', 'on_rent', 'returned'].includes(b.status) && notOwner && !b.placeholder?.on
      ? ops<Pay & { may_change?: boolean }>('booking_pay_plan', { booking: b.booking_number }).catch(none(null)) : null,
    (on('overview') || on('money')) && b.billable_days > 27 ? ops<PeriodRow[]>('booking_periods', { booking: b.booking_number }).catch(none([] as PeriodRow[])) : null,
    (on('overview') || on('review')) && renterForm?.may_edit ? ops<DuplicateRow[]>('renter_duplicates', { renter: renterForm.renter_id }).catch(none([] as DuplicateRow[])) : null]);

  // r35 part RR (1010): the deposit review (Fleet, Finance and the Admin) and the Finance countdowns of this booking
  const moneyStaff = can.admin || fn === 'finance';
  const [review, countdown] = await Promise.all([
    (can.admin || fn === 'fleet' || fn === 'finance') && notOwner && (on('overview') || on('money')) && ['returned', 'closed'].includes(b.status)
      ? ops<ReviewView>('deposit_review', { booking: b.id }, true).catch(none(null)) : null,
    moneyStaff && notOwner && (on('overview') || on('money')) && ['confirmed', 'on_rent', 'returned', 'closed'].includes(b.status)
      ? ops<Countdowns>('finance_countdowns', { booking: b.id }, true).catch(none(null)) : null]);
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  const insurerBilled = b.bill_to !== 'renter' && !!b.insurer_id;
  const extrasCount = b.change_requests.filter((c) => ['requested', 'proposed'].includes(String(c.status))).length + b.extensions.filter((x) => x.status === 'requested').length;
  const tabs: Array<[string, string, number?]> = BOOKING_SECTIONS
    .filter(([k]) => (k !== 'money' || can.money) && (k !== 'extras' || can.extras))
    .map(([k, l]) => [`${base}?tab=${k}`, k === 'overview' && arranging ? 'Overview: review and offer' : l, k === 'extras' ? extrasCount : undefined]);
  const payments = b.payments;
  // r33 (0750): the renter's Sign and pay state from the one rule, and the reasons of the charges (the Money tab)
  const SR = { role: 'service_role' as const };
  const [renterRule, reasons] = await Promise.all([
    ['pending_payment', 'confirmed', 'on_rent'].includes(String(b.status)) ? rpc('server_booking_sign_pay', { p_booking: b.id }, SR).then((x) => signPayOf({ sign_pay: x as never })).catch(() => null) : null,
    on('money') ? rpc('server_booking_charge_reasons', { p_booking: b.id }, SR).then((x) => x as unknown as ChargeReasons).catch(() => null) : null]);
  const renterWords = renterRule ? signPayWords(renterRule) : null;
  // the next step under the status (2026-10-30): one sentence, and a button only when the viewer can do the step
  const step = nextStep({ status: b.status, base, now: new Date(), pickupAt: b.pickup_at, returnAt: b.return_at, offerExpiresAt: b.offer_expires_at,
    dueCents: Number(b.renter_due_at_booking_cents ?? b.total_due_at_booking_cents ?? 0),
    paidCents: (payments ?? []).filter((r) => r.kind === 'charge' && r.status === 'succeeded').reduce((a, r) => a + Number(r.amount_cents ?? 0), 0),
    awaitingSignature: b.readiness?.awaiting_signature === true, licenceOk: (b.readiness?.all_drivers_verified as boolean | undefined) ?? null, depositCents: Number(b.deposit_cents ?? 0), depositStatus: (b.deposit?.status as string | undefined) ?? null,
    insurerBilled: b.bill_to !== 'renter', renterLeft: renterWords?.left ?? null, renterStep: renterRule?.step ?? null,
    ...(can.admin ? {} : { can: { offer: can.offer, money: can.money, sign: can.sign, handover: can.handover, settle: can.settleDeposit } }) });
  const renterContact = b.renter && can.admin
    ? (testId: string) => <>{b.renter!.legal_name} · {b.renter!.email} · <ContactButtons phone={b.renter!.mobile} name={b.renter!.legal_name} booking={b.booking_number} look="link" inbox={inbox} testId={testId}>{b.renter!.mobile}</ContactButtons></>
    : null;

  return (
    <RequestClaim booking={b.id} status={b.status} answering={b.status === 'requested' && on('review') && can.offer} va={fn}>
      <PageHead kicker={<>{can.admin ? <Link prefetch={false} className="link" href="/admin/bookings">Bookings</Link> : <Link prefetch={false} className="link" href="/staff">Queue</Link>} · {b.vehicle?.name} · {b.renter?.legal_name}</>}
        title={<>{b.booking_number} <Badge s={b.status} />{can.admin && b.readiness?.awaiting_signature === true && <> <Badge s="awaiting_signature" /></>} {can.admin && (b.placeholder?.on ? <span className="ad-flag ad-flag--ph" data-testid="placeholder-flag">placeholder</span> : !b.blocks_calendar && <span className="ad-flag">not blocking</span>)}</>}>
        {/* r32: one tap when the car is back (overdue or due today), the late return alert's page included */}
        {can.handover && showReturned(b) && <ReturnedButton booking={b.id} number={b.booking_number} refresh={refresh} testId="returned-top" />}
        {b.renter && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}?tab=messages`} data-testid="email-renter-link">Email the renter</Link>}
        <MoreActions>
        {can.offer && b.status === 'requested' && <ClaimGate testId="claim-gate-head"><Act action="ask_info" payload={P} label="Ask the renter" fields={[{ name: 'question', label: 'Question', type: 'textarea', required: true }]} refresh={refresh} done="Question sent." />
          <Act action="decline_request" payload={P} label="Decline" variant="danger" fields={[{ name: 'note', label: 'Reason and any alternative', type: 'textarea', required: true }]} refresh={refresh} testId="decline" /></ClaimGate>}
        {can.offer && (can.editOfferPending || b.status === 'offered') && ['offered', 'pending_payment'].includes(b.status) && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}?tab=review`} data-testid="edit-offer">Edit the offer</Link>}
        {can.extras && ['confirmed', 'on_rent'].includes(b.status) && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}?tab=changes`} data-testid="edit-booking">Change the booking</Link>}
        {can.offer && ['offered', 'pending_payment'].includes(b.status) && <Act action="withdraw_offer" payload={{ ...P, expected_version: b.current_offer_version }} label="Withdraw the offer" confirm="The renter's offer is withdrawn and they are told. To change it instead, press Edit the offer." fields={[{ name: 'note', label: 'Note to the renter', type: 'text' }]} refresh={refresh} />}
        {can.admin && b.status === 'offered' && <Act action="resend_offer" payload={{ ...P, expected_version: b.current_offer_version }} label="Send again, later expiry" fields={[{ name: 'expires_at', label: 'Open until', type: 'datetime', required: true }, { name: 'message', label: 'Message', type: 'textarea' }]} refresh={refresh} />}
        {can.offer && b.status === 'offered' && <Act action="approve_offer_by_phone" payload={{ ...P, expected_version: b.current_offer_version }} label="Renter approved by phone" confirm="Record that the renter approved this offer on the phone. The history shows it was staff." refresh={refresh} />}
        {can.offer && b.status === 'expired' && <ReopenOffer booking={b.id} pickupAt={b.pickup_at} returnAt={b.return_at} refresh={refresh} />}
        {can.admin && ['confirmed', 'requested', 'offered', 'pending_payment', 'tentative'].includes(b.status) && !b.handed_over_at && (b.placeholder?.on
          ? <Act action="booking_placeholder" payload={{ ...P, on: false }} label="Make it a real booking" fields={[{ name: 'reason', label: 'Why', type: 'text', required: true }]} refresh={refresh} testId="placeholder-off" />
          : <Act action="booking_placeholder" payload={{ ...P, on: true }} label="Mark as a placeholder" confirm="A placeholder (for an insurer, or a hold) never blocks the calendar, is never handed over, sends the renter nothing and is never matched to a toll or ticket. The owner sees only that the car is unavailable." fields={[{ name: 'reason', label: 'What it is for', type: 'text', placeholder: 'Insurance or a hold' }]} refresh={refresh} testId="placeholder-on" />)}
        {can.admin && !b.placeholder?.on && ['confirmed', 'on_rent', 'requested', 'offered', 'pending_payment'].includes(b.status) && <Act action="blocks_calendar" payload={{ ...P, blocks: !b.blocks_calendar }} label={b.blocks_calendar ? 'Stop blocking the calendar' : 'Block the calendar'} fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={refresh} />}
        {can.cancelForRenter && ['confirmed', 'pending_payment'].includes(b.status) && <Act action="cancel_booking" payload={{ ...P, reason: 'renter_request' }} label="Cancel for the renter" variant="danger" fields={[
          { name: 'channel', label: 'Received by', type: 'select', required: true, options: [['email', 'Email'], ['portal', 'Portal'], ['phone', 'Phone']], value: 'email' },
          { name: 'at', label: 'Received at', type: 'datetime', required: true, value: new Date().toISOString() }, { name: 'note', label: 'Note', type: 'text' }]} refresh={refresh} />}
        {can.admin && ['confirmed', 'pending_payment'].includes(b.status) && <Act action="cancel_booking" payload={{ ...P, reason: 'carmacars_cancelled', channel: 'email' }} label="Cancel by CarmaCars" variant="danger" fields={[{ name: 'note', label: 'Reason (no vehicle, driver not verifiable, pricing error, other)', type: 'text', required: true }]} refresh={refresh} />}
        {carOpts && !carOpts.refusal && <Act ops action="car_change" payload={P} label="Change the car" testId="car-change" refresh={refresh} done="Car changed. The renter gets one email."
          title="Change the car before pickup" confirm="The price comes from the new car's rate sheet. More to pay is left open for the renter (Pay the balance or a pay link); less goes back as a refund for approval. An offer is sent again."
          fields={[{ name: 'vehicle', label: 'The new car (free for these dates)', type: 'select', required: true, options: [['', carOpts.cars.length ? 'Choose the car' : 'No other car is free for these dates'],
            ...carOpts.cars.map((v) => [v.vehicle_id, carChoice(v)] as [string, string])] }, { name: 'reason', label: 'Why the car changes', type: 'text', required: true }]} />}
        {can.admin && b.status === 'on_rent' && <Act action="swap_vehicle" payload={P} label="Swap vehicle" fields={[{ name: 'vehicle', label: 'The car the renter moves to', type: 'select', required: true, options: [['', swapCars.length ? 'Choose the car' : 'No car is free right now'], ...swapCars.map((v) => [v.id, `${v.year} ${v.make} ${v.model}${v.plate ? `, ${v.plate}` : ''}`] as [string, string])] }, { name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={refresh} />}
        {can.admin && ['confirmed', 'on_rent', 'returned', 'closed'].includes(b.status) && b.bill_to !== 'renter' && <Act action="draft_insurer_invoice" payload={P} label="Draft insurer invoice" refresh={['/admin/insurer-invoices']} />}
        {can.admin && b.status === 'returned' && <Act action="issue_booking_statement" payload={P} label="Issue final statement" confirm="Issue the Check-out statement from the assessed lines and settle the deposit plan." refresh={refresh} />}
        {can.scheduleJob && ['confirmed', 'on_rent'].includes(b.status) && <Act action="field_job_create" payload={{ ...P, vehicle: b.vehicle_id }} label="Schedule a field job" variant="primary" testId="schedule-job" fields={[
          { name: 'kind', label: 'Kind', type: 'select', required: true, options: KINDS, value: b.status === 'confirmed' ? 'handover' : 'return_check_in' },
          { name: 'assigned_to', label: 'Assigned to', type: 'select', options: fleetStaff.staff.filter((s) => s.eligible).map((s) => [s.id, s.name] as [string, string]) },
          { name: 'scheduled_at', label: 'When', type: 'datetime', required: true, value: b.status === 'confirmed' ? b.pickup_at : b.return_at },
          { name: 'place', label: 'Place', type: 'address', required: true, value: (b.status === 'confirmed' ? b.pickup_place : b.return_place) ?? 'Our location' }, { name: 'instructions', label: 'Instructions', type: 'textarea' }]} refresh={refresh} done="Job scheduled." />}
        {insurerBilled && b.insurer_adjuster_email && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}?tab=messages&to=adjuster`} data-testid="email-adjuster-link">Email the adjuster</Link>}
        </MoreActions>
      </PageHead>
      {can.admin && b.placeholder?.on ? <PlaceholderBanner p={b.placeholder} items={b.competing} /> : <NextStepPanel s={step} />}
      <ClaimBanner />
      <ReplacedNote chain={chain} portal={portal} />
      {noShift.length > 0 && <p className="alert alert--warn" role="status" data-testid="no-shift-warning">{noShift.map((w) => `${w.leg === 'handover' ? 'The handover' : 'The return'} is on ${w.day}, a day with no field shifts${w.work_day ? `: its job is planned for ${w.work_day}` : ''}.`).join(' ')} Someone must cover it, or the booking time must move.</p>}

      {late?.late && <LatePanel l={late} fleet={fn === 'fleet'} refresh={refresh} returning={can.returningNow} />}
      {can.photoReview && ['on_rent', 'returned', 'closed'].includes(b.status) && <p className="small"><Link prefetch={false} className="link" href={`/staff/review/${encodeURIComponent(n)}`} data-testid="photo-review-link">Photo review: pickup and return side by side</Link></p>}
      {can.admin && <BookingSummary status={b.status} pickupAt={b.pickup_at} returnAt={b.return_at} days={Number(b.billable_days)} totalCents={Number(b.total_due_at_booking_cents)} billTo={b.bill_to} />}
      {/* the six sections right under the summary */}
      <Tabs current={`${base}?tab=${section}`} items={tabs} />
      {/* 0770: what stops the pickup or the return, the Admin override (staff ask), a past trip, the requests waiting */}
      {(section === 'overview' || section === 'car') && (can.handover || can.admin) && ['offered', 'pending_payment', 'confirmed', 'on_rent'].includes(b.status) && <HandoverOverride booking={b.id} userId={user.id} aal={aal} refresh={[base]} />}
      {(section === 'overview' || section === 'car') && ['pending_payment', 'confirmed', 'on_rent', 'returned', 'closed'].includes(b.status) && <HandoverPanel userId={user.id} aal={aal} base={base} canHandover={can.handover} canSign={can.sign}
        b={{ id: b.id, booking_number: b.booking_number, status: b.status, return_at: b.return_at, checked_in_at: (b.checked_in_at as string | null | undefined) ?? null, minutes_late: (b.minutes_late as number | null | undefined) ?? null }} />}
      {section === 'activity' && ['confirmed', 'on_rent', 'returned', 'closed'].includes(b.status) && <ReviewPanel booking={b.booking_number} userId={user.id} aal={aal} refresh={[base]} />}
      {review?.exists && <Card title="Deposit review" testId="booking-deposit-review" aside={<Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}/deposit-review`} data-testid="deposit-review-link">Open the review</Link>}>
        <p className="small">{stageWords(review.state)}. {review.state?.stage === 'done' ? 'Bill what is owed or release the deposit on Money.' : 'The deposit stays held until Fleet and Finance signed every item.'}</p>
      </Card>}
      {countdown && countdown.rows.length > 0 && <Card title="Countdowns" testId="booking-countdowns"><CountdownTable c={countdown} bookingBase={`${portal}/bookings`} /></Card>}
      {accident && <Card title="Accident card" testId="booking-accident-card" aside={<Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}/accident-card`} data-testid="accident-card-print">Print the card</Link>}>
        <AccidentSummary d={accident} />
        {/* 1010: the renter's own policy number of the plan sold with the rental, when it was not captured at purchase */}
        {accident.coverage.kind === 'plan' && (can.admin || viewer.role === 'staff') && <Act ops action="plan_policy_set" payload={P} label={accident.coverage.plan_policy_entered ? 'Change the plan policy number' : 'Enter the plan policy number'}
          testId="plan-policy-set" fields={[{ name: 'policy_number', label: 'The renter\'s policy number from the plan provider', type: 'text', value: accident.coverage.plan_policy_entered ? accident.coverage.plan_policy_number ?? '' : '' }]} refresh={[base]} done="Saved: it is on the accident card." />}
      </Card>}
      {(section === 'overview' || section === 'documents') && ['pending_payment', 'confirmed', 'on_rent', 'returned', 'closed'].includes(b.status) && <AgreementPanel userId={user.id} aal={aal} base={base} b={{ id: b.id, status: b.status }} docBase={`${portal}/documents`} finance={can.agreementMoney} {...(can.admin ? {} : { openDocs: false })} />}
      {/* the renter's licence front, back and selfie, reviewed by Sales (0169); the coverage stays with customer service and Admin */}
      {can.licenceReview && ['requested', 'offered', 'tentative', 'pending_payment', 'confirmed', 'on_rent'].includes(b.status) && (
        <Card title="Renter licence" testId="booking-doc-review" aside={<DocumentReview booking={b.booking_number} refresh={refresh} label="Review the licence" />}>
          <p className="small muted">Licence front, back and selfie; a rejection tells the renter why. Coverage is reviewed by customer service or an Admin.</p>
        </Card>)}
      {/* staff upload the renter's documents: licence, insurance policy or pink card, insurer letters (0183) */}
      {can.staffUpload && ['pending_payment', 'confirmed', 'on_rent', 'returned'].includes(b.status) && notOwner && (
        <Card title="Upload a renter document" testId="booking-staff-upload">
          <StaffDocUpload bookingId={String(b.id)} drivers={(b.drivers ?? []).map((d) => ({ driver_id: String(d.driver_id), full_name: String(d.full_name ?? '') }))} />
        </Card>)}
      {/* what the owner sees of this booking (0156) */}
      {section === 'car' && <OwnerVisibilityPanel userId={user.id} aal={aal} va={fn} booking={b.booking_number} refresh={refresh} />}
      {section === 'car' && <BookingCarSection base={base} number={b.booking_number} vehicleId={b.vehicle_id} vehicleName={b.vehicle?.name ?? null} vehicleHref={carHref} status={b.status} canSign={can.sign} />}
      {on('review') && (
        <>
          <div className={can.admin ? 'ad-cols ad-cols--2' : undefined}>
            <Card title="The request as sent">
              <Kv rows={[['Pickup', t(b.request_sent.pickup_at)], ['Return', t(b.request_sent.return_at)], ['Note', String(b.request_note ?? '')],
                ['Renter', renterContact ? <>{renterContact('renter-phone')} · {b.renter?.bookings ? `${b.renter.bookings} past bookings` : 'first booking'}{b.renter?.is_blocked ? <b className="ad-late"> blocked</b> : null}</>
                  : `${b.renter?.legal_name ?? ''}${b.renter?.bookings ? `, ${b.renter.bookings} past bookings` : ', first booking'}`],
                // 2026-10-28: the renter's phone and email, to call or write to them (customer service and Sales)
                ...(can.admin ? [] : [['Phone', b.renter?.mobile ? <ContactButtons phone={b.renter.mobile} name={b.renter.legal_name} booking={b.booking_number} look="link" inbox={inbox} testId="request-renter-phone">{b.renter.mobile}</ContactButtons> : null],
                  ['Email', b.renter?.email ? <a className="link" href={`mailto:${b.renter.email}`} data-testid="request-renter-email">{b.renter.email}</a> : null]] as Array<[string, React.ReactNode]>),
                ['Offer', b.current_offer_version ? `version ${b.current_offer_version}${b.offer_expires_at ? `, open until ${t(b.offer_expires_at)}` : ''}` : 'not sent yet'],
                ...(can.admin ? [['Came from', came ? <MarketingSource key="mk" m={came} booking={b.booking_number} refresh={refresh} /> : ''],
                  ['Sales credit', credit ? <SalesCreditLine key="sc" c={credit} booking={b.booking_number} refresh={refresh} /> : '']] as Array<[string, React.ReactNode]>
                  : [['Car free', b.available ? 'yes' : 'no']] as Array<[string, React.ReactNode]>)]} />
            </Card>
            {can.admin && <Card title="Competing for these dates" testId="competing" aside={<span className="small">{b.available ? 'car free' : <b className="ad-late">car not free</b>}</span>}>
              <DateConflicts items={b.competing} self={{ placeholder: !!b.placeholder?.on }} />
            </Card>}
          </div>
          {policyNote && <p className="alert alert--warn" role="note" data-testid="offer-policy-warning"><span className="alert__title">Car not on the fleet policy yet</span>{can.admin
            ? <span>Requests, offers and payment are fine; the car cannot be handed over until the insurer confirms it. When it does, press Insurer confirmed on <Link prefetch={false} className="link" href={`/admin/vehicles/${b.vehicle_id}?tab=listing`}>the car</Link> (or on Admin &gt; Today).</span>
            : <span>Requests, offers and payment are fine; the car cannot be handed over until the insurer confirms it (the car&apos;s onboarding).</span>}</p>}
          {/* the renter's licence, uploaded with the request (0130) */}
          {can.renterDocs && <RenterDocs b={b} refresh={[base]} />}
          <ClaimGate testId="claim-gate-review" explain><BookingReview b={b} insurers={ins.rows} insurerRates={insurerCard?.rates ?? []} kmChoices={km.rows.map((k) => k.km_per_day)} offerHours={settings?.program.offer_expiry_hours ?? 24}
            editable={['requested', 'offered'].includes(b.status) || (b.status === 'pending_payment' && can.editOfferPending)} /></ClaimGate>
        </>
      )}
      {/* conflicting dates on this car (0284), once the booking is past the request */}
      {can.admin && on('overview') && b.competing.length > 0 && <Card title="Also on this car for these dates" testId="date-conflicts-card"><DateConflicts items={b.competing} self={{ placeholder: !!b.placeholder?.on }} /></Card>}
      {on('overview') && editForm && <BookingEdit x={editForm} fees={fees} />}
      {on('overview') && coverageSwitch && <CoverageSwitch x={coverageSwitch} />}
      {(on('overview') || on('money')) && insurerCard?.billed_to_insurer && <BookingInsurer x={insurerCard} />}
      {adjusters && <InsurerClaimEdit insurers={ins.rows} adjusters={adjusters} x={{
        booking: b.booking_number, bill_to: b.bill_to, insurer_id: b.insurer_id, claim_number: b.insurer_claim_number, adjuster_name: b.insurer_adjuster_name,
        adjuster_email: b.insurer_adjuster_email, adjuster_phone: b.insurer_adjuster_phone, policy_number: (b.insurer_policy_number as string | null) ?? null,
        policy_province: (b.insurer_policy_province as string | null) ?? null, authorized_days: b.insurer_authorized_days, authorized_until: b.insurer_authorized_until,
        authorized_daily_rate_cents: b.insurer_authorized_daily_rate_cents, adjuster_id: (b.insurer_adjuster_id as string | null) ?? null }} />}
      {pay && <PayPlanCard booking={b.id} pay={pay} refresh={[base]} admin={viewer.role === 'admin'} />}
      {periods && <BookingPeriods booking={b.booking_number} rows={periods} />}
      {(on('overview') || on('review')) && renterForm && <RenterEdit x={renterForm} />}
      {duplicates && renterForm && <RenterMerge renterId={renterForm.renter_id} name={renterForm.now.full_name ?? 'this renter'} rows={duplicates} />}
      {on('overview') && (
        <div className="ad-cols ad-cols--2">
          <Card title="Trip">
            <Kv rows={[['Car', carHref ? <Link prefetch={false} key="c" className="link" href={carHref}>{b.vehicle?.name} {b.vehicle?.plate}</Link> : `${b.vehicle?.name ?? ''} ${b.vehicle?.plate ?? ''}`],
              ['Pickup', `${t(b.pickup_at)}, ${b.pickup_place ?? 'our location'}`], ['Return', `${t(b.return_at)}, ${b.return_place ?? 'our location'}`],
              ...(can.admin ? [['Days', String(b.billable_days)], ['Bill to', `${label(b.bill_to)}${b.insurer_name ? `, ${b.insurer_name} claim ${b.insurer_claim_number ?? ''}` : ''}`]] as Array<[string, React.ReactNode]> : []),
              ['Renter', renterContact ? renterContact('renter-phone-2') : b.renter?.legal_name ?? ''],
              ...(can.admin ? [['Identity', label(b.renter?.identity_status)]] as Array<[string, React.ReactNode]> : [['Deposit', b.deposit ? depositStatus(b.deposit.status) : 'not taken']] as Array<[string, React.ReactNode]>),
              ...(can.admin && b.added_by_staff ? [['Added by hand', <span key="a" data-testid="booking-added">{b.added_mode === 'past' ? 'A past rental recorded by staff' : b.added_mode === 'in_progress' ? 'Added by staff while already underway (recorded as on trip at the pickup)' : 'Added by staff'}; source {label(b.source)}; payment: {label(b.payment_mode)}{b.do_not_email ? '; renter not emailed' : ''}{b.clash_override_reason ? `; added over a clash: ${String(b.clash_override_reason)}` : ''}</span>] as [string, React.ReactNode]] : []),
              ...(can.admin ? [['Came from', came ? <MarketingSource key="mk" m={came} booking={b.booking_number} refresh={refresh} /> : ''],
                ['Sales credit', credit ? <SalesCreditLine key="sc" c={credit} booking={b.booking_number} refresh={refresh} /> : '']] as Array<[string, React.ReactNode]> : []),
              ['Ready for handover', b.readiness ? ((b.readiness.missing as string[] | undefined)?.length ? `missing: ${(b.readiness.missing as string[]).map(label).join(', ')}` : 'yes') : '']]} />
          </Card>
          {can.renterDocs && ['pending_payment', 'confirmed', 'on_rent', 'requested', 'offered'].includes(b.status) && <RenterDocs b={b} refresh={[base]} />}
          {can.admin && <Card title="Price">
            <dl className="pt-dl pt-dl--money">{b.lines.map((l) => <div key={l.id}><dt>{l.description || label(l.charge_type)} <span className="muted small">{l.stage}</span></dt><dd>{$(l.amount_cents)}</dd></div>)}
              <div><dt><b>Total at booking</b></dt><dd><b>{$(b.total_due_at_booking_cents)}</b></dd></div></dl>
          </Card>}
          <Card title="Add-ons" testId="booking-addons-card"><BookingAddons items={b.addons ?? []} status={b.status} refresh={[base]} /></Card>
          <Card title="Open tasks"><Table rows={b.tasks} empty="No open tasks." cols={[{ key: 'title', label: 'Task', className: 'wrap' }, { key: 'queue', label: 'Queue' }, { key: 'due_at', label: 'Due', render: (r) => t(r.due_at) }]} /></Card>
        </div>
      )}
      {on('money') && (
        <div className="stack">
          {/* r29 C0: Rental charges and Security deposit, two panels; every money tool sits in the panel it belongs to, and the
              database decides who may do each */}
          {moneyByPart && <BookingMoney m={moneyByPart} reasons={reasons} lines={(b.lines as PanelLine[] | undefined) ?? []} totalCents={(b.total_due_at_booking_cents as number | null | undefined) ?? null}
            waived={!!(b as unknown as R).deposit_waived_at} lineAdmin={can.admin} expiredSettle={can.admin || can.settleDeposit || (viewer.role === 'staff' && viewer.fn === 'fleet')}
            rentalExtras={<>
              {coverageSwitch && <CoverageSwitch x={coverageSwitch} />}
              {fees && <BookingFees x={fees} withBalance={false} />}
              {payments?.some((r) => r.status === 'failed') && <Card title="Card payments that failed"><Table rows={payments.filter((r) => r.status === 'failed')} empty="No payments."
                cols={[{ key: 'created_at', label: 'When', render: (r) => t(r.created_at) }, { key: 'purpose', label: 'Purpose' }, ...(can.admin ? [{ key: 'method', label: 'Method' }] : []), { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'card_last4', label: 'Card' },
                  { key: 'act', label: '', render: (r) => can.manualPayments && r.kind === 'charge' ? <ManualPaymentForm prefix="bk-rp" booking={b.id} settlesPayment={String(r.id)} number={String(r.id).slice(0, 8)} balance={Number(r.amount_cents)} today={today} refresh={[base]} label="Paid another way" /> : null }]} /></Card>}
              {/* r35 (0970): Fleet records cash and e-Transfers, so it sees them too (without the card payments list) */}
              {can.manualPayments && manual.length > 0 && <details className="pt-card ad-card" data-testid="booking-manual-payments"><summary className="small">{can.voidRecords ? 'Correct or void a payment received another way' : 'Payments received another way'} ({manual.length})</summary>
                <ManualPaymentList rows={manual} canVoid={can.voidRecords} {...(can.voidRecords ? { refresh: [base] } : { docBase: '/staff/documents' })} /></details>}
              {payments && <div className="stack" data-testid="bm-refunds"><div className="row"><b className="small">Refunds</b>
                {can.admin ? (payments.length > 0 && <Act action="request_refund" payload={P} label="Refund" testId="new-refund" fields={refundFields()} refresh={[base]} />)
                  : can.refund && <Act action="request_refund" payload={P} label="Refund" testId="request-refund" fields={refundFields()} refresh={[base]} done="Refund requested." />}</div>
                {(b.refunds ?? []).length > 0 && <Table rows={b.refunds ?? []} testId="refunds" empty="No refunds." cols={[{ key: 'created_at', label: 'Requested', render: (r) => t(r.created_at) }, { key: 'reason', label: 'Reason', render: (r) => (can.admin ? String(r.reason ?? '') : label(r.reason)) }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) },
                  { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)}>{!can.admin && r.status === 'pending_approval' ? 'Waiting for an Admin' : undefined}</Badge> }, { key: 'due_by', label: 'Due by' },
                  ...(can.refundApprove ? [{ key: 'act', label: '', render: (r: R) => r.status === 'pending_approval' ? <Act action="refund_approve" payload={{ id: r.id }} label="Approve (within my limit)" refresh={[base]} /> : null }] : [])]} />}</div>}
            </>}
            depositExtras={can.admin ? <div className="ad-actions" data-testid="booking-debit-override">
              {['confirmed', 'pending_payment'].includes(b.status) && !b.deposit && !(b as unknown as R).deposit_waived_at && <Act action="waive_deposit" payload={P} label="Waive the deposit" fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={[base]} testId="bm-waive" />}
              <MoreActions start label="More" testId="deposit-more">
              {/* 0262: the deposit with a debit or prepaid card, for this booking */}
              {moneyByPart.debit_deposit?.takes && <Act action="booking_debit_deposit" payload={{ booking: b.booking_number }} label="Change the debit deposit" refresh={refresh} testId="booking-debit-deposit"
                fields={[{ name: 'amount_cents', label: 'Deposit with a debit or prepaid card (empty: the standard multiple)', type: 'money' }, { name: 'reason', label: 'Reason', type: 'text', required: true }]} />}
              {/* 0230: an Admin may allow a debit or prepaid card for this booking (never on card coverage) */}
              {moneyByPart.debit && !moneyByPart.debit.coverage && (moneyByPart.debit.allowed_at
                ? <Act action="booking_allow_debit" payload={{ booking: b.booking_number, allow: false }} label="Require a credit card again" refresh={refresh} testId="booking-debit-off"
                    confirm="The pay page, pay links and the deposit hold of this booking take a credit card only again." />
                : <Act action="booking_allow_debit" payload={{ booking: b.booking_number, allow: true }} label="Allow debit and prepaid cards for this booking" refresh={refresh} testId="booking-debit-on"
                    confirm="The pay page, staff pay links and the deposit hold of this booking will take a debit or prepaid card. The renter is told the hold lowers the money available on the card until it is released. The deductible may not be chargeable on such a card."
                    fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} />)}
              </MoreActions>
            </div> : undefined}
            depositSettle={can.settleDeposit ? <DepositSettle bookingId={b.id} bookingNumber={b.booking_number} refresh={[base]} /> : undefined} />}
          {!moneyByPart && payments && <Card title="Payments"><Table rows={payments} empty="No payments." cols={[{ key: 'created_at', label: 'When', render: (r) => t(r.created_at) }, { key: 'purpose', label: 'Purpose' }, { key: 'kind', label: 'Kind' }, ...(can.admin ? [{ key: 'method', label: 'Method' }] : []), { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }]} />
            {can.manualPayments && <><ManualPaymentList rows={manual} canVoid={can.voidRecords} {...(can.voidRecords ? { refresh: [base] } : { docBase: '/staff/documents' })} /><ManualPaymentForm booking={b.id} number={b.booking_number} balance={0} today={today} refresh={[base]} label="Record a payment received another way" /></>}</Card>}
          <OwnerDeductionsPanel userId={user.id} aal={aal} va={fn} booking={b.booking_number} refresh={refresh} />
          {payments && !can.admin && can.statement && b.status === 'returned' && <Card title="Statement"><Act action="issue_booking_statement" payload={P} label="Issue the final statement" confirm="Issue the Check-out statement from the assessed lines. Damage lines wait for an Admin." refresh={[base]} /></Card>}
          {can.admin && <Card title="Documents"><GeneratedFiles bookingId={b.id} /></Card>}
          {can.admin && <Card title="Statements"><Table rows={b.statements ?? []} empty="No statements." cols={[{ key: 'statement_number', label: 'Number' }, { key: 'kind', label: 'Kind' }, { key: 'issued_at', label: 'Issued', render: (r) => t(r.issued_at) }, { key: 'charges_cents', label: 'Charges', num: true, render: (r) => $(r.charges_cents) }, { key: 'charged_to_card_cents', label: 'To card', num: true, render: (r) => $(r.charged_to_card_cents) }]} /></Card>}
          {can.admin && <Card title="Offers"><Table rows={b.offers ?? []} empty="No offers." cols={[{ key: 'version', label: 'Version' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'sent_at', label: 'Sent', render: (r) => t(r.sent_at) }, { key: 'expires_at', label: 'Expires', render: (r) => t(r.expires_at) }, { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) }, { key: 'message', label: 'Message', className: 'wrap' }]} /></Card>}
        </div>
      )}
      {on('changes') && can.extras && (
        <div className="stack">
          {b.status === 'confirmed' && b.bill_to === 'renter' && <Card title="Propose a change" testId="propose-card"><ProposeChange booking={b.id} number={b.booking_number} pickupAt={b.pickup_at} returnAt={b.return_at} vehicleId={b.vehicle_id} rentalCents={Number(b.rental_charge_cents ?? 0)} refresh={[base]} /></Card>}
          <Card title="Change requests"><Table rows={b.change_requests} testId="change-requests" empty="No change requests." cols={[{ key: 'created_at', label: 'When', render: (r) => t(r.created_at) }, { key: 'requested_by_role', label: 'From' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
            { key: 'note', label: 'Reason', className: 'wrap' }, { key: 'accept_by', label: 'Answer by', render: (r) => t(r.accept_by) }, { key: 'total_difference_cents', label: 'Difference', num: true, render: (r) => $(r.total_difference_cents) },
            { key: 'act', label: 'Decide', render: (r) => r.status === 'requested' ? <span className="ad-actions"><Act action="approve_change" payload={{ request: r.id }} label="Approve" variant="primary" refresh={[base]} /><Act action="decline_change" payload={{ request: r.id }} label="Decline" fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={[base]} /></span>
              : r.status === 'proposed' ? <Act action="change_withdraw" payload={{ request: r.id }} label="Withdraw" confirm="The renter can no longer accept this change. The booking stays as it is." refresh={[base]} testId="change-withdraw" />
              : can.admin && r.status === 'approved' && !r.renter_agreed_at ? <Act action="decline_change" payload={{ request: r.id }} label="Withdraw the approval" fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={[base]} /> : null }]} /></Card>
          <Card title="Extensions"><Table rows={b.extensions} empty="No extensions." cols={[{ key: 'seq', label: 'No.' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'new_return_at', label: 'New return', render: (r) => t(r.new_return_at) }, { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) },
            { key: 'act', label: 'Decide', render: (r) => r.status === 'requested' ? <span className="ad-actions"><Act action="approve_extension" payload={{ extension: r.id }} label={can.admin ? 'Approve' : 'Approve and send the pay link'} variant="primary" refresh={[base]} /><Act action="decline_extension" payload={{ extension: r.id }} label="Decline" fields={[{ name: 'reason', label: 'Reason', type: 'text' }]} refresh={[base]} /></span> : null }]} /></Card>
          <Card title="Questions to the renter"><Table rows={b.info_requests} empty="No questions." cols={[{ key: 'asked_at', label: 'Asked', render: (r) => t(r.asked_at) }, { key: 'question', label: 'Question', className: 'wrap' }, { key: 'status', label: 'Status' }, { key: 'reply', label: 'Reply', className: 'wrap' }]} /></Card>
        </div>
      )}
      {/* r35 (0850): one Activity log in place of the messages, timeline, calls, visits and emails cards; the email form under it */}
      {section === 'activity' && <div className="stack">
        <ActivityLog data={activity} base={`${base}?tab=activity`} sp={sp} emailHref={b.renter ? '#email' : null} chatBase={inbox} inbox={inbox}
          phone={b.renter?.mobile} name={b.renter?.legal_name} booking={b.booking_number} />
        <div id="email">{conv ? <BookingConversation c={conv} refresh={[base]} initialTo={sp.to === 'adjuster' ? 'adjuster' : 'renter'} composeOnly /> : <p className="small muted">The email form could not be read. Reload the page.</p>}</div>
      </div>}
      {section === 'documents' && (
        <div className="ad-cols ad-cols--2" data-testid="booking-documents-section">
          {can.renterDocs && ['pending_payment', 'confirmed', 'on_rent', 'requested', 'offered'].includes(b.status) && <RenterDocs b={b} refresh={[base]} />}
          <Card title="Drivers"><Table rows={b.drivers} empty="No drivers." cols={[{ key: 'full_name', label: 'Name' }, { key: 'role', label: 'Role' }, ...(can.admin ? [{ key: 'age_band', label: 'Age band' }, { key: 'licence_last4', label: 'Licence' }, { key: 'accepted_at', label: 'Accepted', render: (r: R) => t(r.accepted_at) },
            { key: 'identity_verified_on', label: 'Identity', render: (r: R) => r.identity_verified_on ? `Verified${r.identity_method === 'in_person' ? ' in person' : ''}`
              : can.verifyInPerson && ['confirmed', 'pending_payment'].includes(String(b.status)) ? <Act ops action="verify_driver_in_person" payload={{ booking_driver_id: r.id }} label="Verified in person" testId={`verify-in-person-${String(r.role)}`} refresh={[base]}
                  fields={[{ name: 'note', label: 'What you checked (the licence seen, its number, the face matched)', type: 'text', required: true }]} /> : 'Not verified' }] : [])]} /></Card>
          {can.admin && <Card title="Documents"><Table rows={b.documents ?? []} empty="No documents." cols={[{ key: 'title', label: 'Title', render: (r) => <Link prefetch={false} className="link" href={`/admin/documents/${r.id}`}>{String(r.title ?? label(r.kind))}</Link> }, { key: 'kind', label: 'Kind', render: (r) => label(r.kind) }, { key: 'created_at', label: 'Added', render: (r) => t(r.created_at) }]} /></Card>}
          {can.driverLinks && <Card title="Additional drivers' signing links"><DriverLinks rows={driverLinks} refresh={[base]} /></Card>}
          {/* 0720: no new signature on paper (every agreement is signed in the portal); one recorded before stays readable */}
          {can.paperSignatures && paper.length > 0 && <Card title="Signed on paper (before November 2026)" testId="booking-paper"><div className="stack">
            <p className="small muted">Recorded before every agreement moved to the e-signature. A new signature is never recorded on paper: send the renter the signing link.</p>
            <PaperSignatureList rows={paper} canVoid={can.voidRecords} {...(can.voidRecords ? { refresh: [base] } : { docBase: '/staff/documents' })} /></div></Card>}
        </div>
      )}
    </RequestClaim>
  );
}

function refundFields() {
  return [{ name: 'reason', label: 'Reason', type: 'select' as const, required: true, options: REFUND_REASONS.map((x) => [x, label(x)] as [string, string]) },
    { name: 'refund_of', label: 'What it refunds', type: 'select' as const, required: true, options: REFUND_OF, value: 'rental', hint: 'Only a refund of the rental charge lowers staff commissions.' },
    { name: 'amount_cents', label: 'Amount', type: 'money' as const, required: true }, { name: 'note', label: 'Note', type: 'text' as const }];
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
  const missing = [r.all_drivers_verified === false ? 'every driver’s identity' : '', r.coverage_confirmed === false ? 'the proof of coverage' : ''].filter(Boolean);
  return (
    <Card title="Renter documents" testId="booking-doc-review" tone={missing.length ? 'next' : undefined} aside={<DocumentReview booking={b.booking_number} refresh={refresh} label="Review documents" />}>
      <p className="small">{missing.length ? `Still needed before the handover: ${missing.join(' and ')}. Approve or reject what the renter sent; a rejection tells them why.` : 'Identity and coverage are confirmed.'}</p>
      <StaffDocUpload bookingId={String(b.id)} drivers={(b.drivers ?? []).map((d) => ({ driver_id: String(d.driver_id), full_name: String(d.full_name ?? '') }))} />
    </Card>
  );
}
