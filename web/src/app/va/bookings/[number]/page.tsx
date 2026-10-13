import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { BookingReview, type B } from '@/features/admin/BookingReview';
import { $, Badge, Card, Kv, PageHead, Table, Tabs, t, label } from '@/features/admin/ui';
import { QuickReply } from '@/features/va/QuickReply';

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
  const { read, list, fn } = await vaPage(`/va/bookings/${n}`);
  const b = await read<Detail | null>('booking', { number: n }).catch(() => null);
  if (!b) notFound();
  const arranging = ['requested', 'offered', 'pending_payment'].includes(b.status) && (fn === 'cs' || fn === 'sales');
  const tab = sp.tab ?? (arranging ? 'review' : 'overview');
  const base = `/va/bookings/${encodeURIComponent(n)}`;
  const P = { booking: b.id };
  const R = [base];
  const [km, replies, staff, messages] = await Promise.all([
    arranging ? list<{ km_per_day: number }>('km_allowance_choices', { eq: { is_active: true } }).catch(() => ({ rows: [], count: 0 })) : Promise.resolve({ rows: [], count: 0 }),
    fn === 'cs' && tab === 'messages' ? list<{ id: string; title: string; body: string }>('quick_replies', { order: 'sort_order', asc: true }) : Promise.resolve({ rows: [], count: 0 }),
    fn === 'fleet' ? read<{ staff: Array<{ id: string; name: string }> }>('fleet_board') : Promise.resolve({ staff: [] }),
    fn === 'cs' && tab === 'messages' ? read<R[]>('messages', { booking: b.id }) : Promise.resolve([] as R[])]);
  const tabs: Array<[string, string, number?]> = [
    ...(arranging ? [[`${base}?tab=review`, 'Review and offer']] as Array<[string, string]> : []), [`${base}?tab=overview`, 'Overview'],
    ...(fn === 'finance' || fn === 'cs' ? [[`${base}?tab=money`, 'Money']] as Array<[string, string]> : []),
    ...(fn === 'cs' ? [[`${base}?tab=changes`, 'Changes', b.change_requests.filter((c) => ['requested', 'proposed'].includes(String(c.status))).length + b.extensions.filter((x) => x.status === 'requested').length], [`${base}?tab=messages`, 'Messages']] as Array<[string, string, number?]> : []),
    [`${base}?tab=history`, 'History']];
  return (
    <>
      <PageHead kicker={<><Link prefetch={false} className="link" href="/va">Queue</Link> · {b.vehicle?.name} · {b.renter?.legal_name}</>} title={<>{b.booking_number} <Badge s={b.status} /></>}>
        {(fn === 'cs' || fn === 'sales') && b.status === 'requested' && <Act action="ask_info" payload={P} label="Ask the renter" fields={[{ name: 'question', label: 'Question', type: 'textarea', required: true }]} refresh={R} done="Question sent." />}
        {(fn === 'cs' || fn === 'sales') && b.status === 'requested' && <Act action="decline_request" payload={P} label="Decline" variant="danger" fields={[{ name: 'note', label: 'Reason and any alternative', type: 'textarea', required: true }]} refresh={R} />}
        {(fn === 'cs' || fn === 'sales') && ['offered', 'pending_payment'].includes(b.status) && <Act action="withdraw_offer" payload={P} label="Withdraw to edit" fields={[{ name: 'note', label: 'Note to the renter', type: 'text' }]} refresh={R} />}
        {fn === 'cs' && ['confirmed', 'pending_payment'].includes(b.status) && <Act action="cancel_booking" payload={{ ...P, reason: 'renter_request' }} label="Cancel for the renter" variant="danger" fields={[
          { name: 'channel', label: 'Received by', type: 'select', required: true, options: [['email', 'Email'], ['portal', 'Portal'], ['phone', 'Phone']], value: 'email' },
          { name: 'at', label: 'Received at', type: 'datetime', required: true, value: new Date().toISOString() }, { name: 'note', label: 'Note', type: 'text' }]} refresh={R} />}
        {fn === 'fleet' && ['confirmed', 'on_rent'].includes(b.status) && <Act action="field_job_create" payload={{ ...P, vehicle: b.vehicle_id }} label="Schedule a field job" variant="primary" testId="schedule-job" fields={[
          { name: 'kind', label: 'Kind', type: 'select', required: true, options: KINDS, value: b.status === 'confirmed' ? 'handover' : 'return_check_in' },
          { name: 'assigned_to', label: 'Assigned to', type: 'select', options: staff.staff.map((s) => [s.id, s.name] as [string, string]) },
          { name: 'scheduled_at', label: 'When', type: 'datetime', required: true, value: b.status === 'confirmed' ? b.pickup_at : b.return_at },
          { name: 'place', label: 'Place', type: 'text', required: true, value: (b.status === 'confirmed' ? b.pickup_place : b.return_place) ?? '' }, { name: 'instructions', label: 'Instructions', type: 'textarea' }]} refresh={R} done="Job scheduled." />}
      </PageHead>
      <Tabs current={`${base}?tab=${tab}`} items={tabs} />
      {tab === 'review' && arranging && (
        <>
          <Card title="The request as sent">
            <Kv rows={[['Pickup', t(b.request_sent.pickup_at)], ['Return', t(b.request_sent.return_at)], ['Note', String(b.request_note ?? '')], ['Renter', `${b.renter?.legal_name ?? ''}${b.renter?.bookings ? `, ${b.renter.bookings} past bookings` : ', first booking'}`],
              ['Offer', b.current_offer_version ? `version ${b.current_offer_version}${b.offer_expires_at ? `, open until ${t(b.offer_expires_at)}` : ''}` : 'not sent yet'], ['Car free', b.available ? 'yes' : 'no']]} />
          </Card>
          <BookingReview b={b} insurers={[]} kmChoices={km.rows.map((k) => k.km_per_day)} offerHours={24} editable={b.status === 'requested'} />
        </>
      )}
      {tab === 'overview' && (
        <div className="ad-cols ad-cols--2">
          <Card title="Trip">
            <Kv rows={[['Car', `${b.vehicle?.name ?? ''} ${b.vehicle?.plate ?? ''}`], ['Pickup', `${t(b.pickup_at)}, ${b.pickup_place ?? 'our location'}`], ['Return', `${t(b.return_at)}, ${b.return_place ?? 'our location'}`],
              ['Renter', b.renter?.legal_name ?? ''], ['Deposit', b.deposit ? label(b.deposit.status) : 'not taken'],
              ['Ready for handover', b.readiness ? ((b.readiness.missing as string[] | undefined)?.length ? `missing: ${(b.readiness.missing as string[]).map(label).join(', ')}` : 'yes') : '']]} />
          </Card>
          <Card title="Open tasks"><Table rows={b.tasks} empty="No open tasks." cols={[{ key: 'title', label: 'Task', className: 'wrap' }, { key: 'queue', label: 'Queue' }, { key: 'due_at', label: 'Due', render: (r) => t(r.due_at) }]} /></Card>
          <Card title="Drivers"><Table rows={b.drivers} empty="No drivers." cols={[{ key: 'full_name', label: 'Name' }, { key: 'role', label: 'Role' }]} /></Card>
        </div>
      )}
      {tab === 'money' && b.payments && (
        <div className="stack">
          <Card title="Payments"><Table rows={b.payments} empty="No payments." cols={[{ key: 'created_at', label: 'When', render: (r) => t(r.created_at) }, { key: 'purpose', label: 'Purpose' }, { key: 'kind', label: 'Kind' }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'card_last4', label: 'Card' }]} /></Card>
          <Card title="Refunds" aside={fn === 'finance' ? <Act action="request_refund" payload={P} label="Request a refund" testId="request-refund" fields={[{ name: 'reason', label: 'Reason', type: 'select', required: true, options: REFUND_REASONS.map((x) => [x, label(x)] as [string, string]) }, { name: 'amount_cents', label: 'Amount', type: 'money', required: true }, { name: 'note', label: 'Note', type: 'text' }]} refresh={R} done="Refund requested." /> : null}>
            <Table rows={b.refunds ?? []} testId="refunds" empty="No refunds." cols={[{ key: 'created_at', label: 'Requested', render: (r) => t(r.created_at) }, { key: 'reason', label: 'Reason', render: (r) => label(r.reason) }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)}>{r.status === 'pending_approval' ? 'Waiting for an Admin' : undefined}</Badge> }, { key: 'due_by', label: 'Due by' },
              { key: 'act', label: '', render: (r) => fn === 'finance' && r.status === 'pending_approval' ? <Act action="refund_approve" payload={{ id: r.id }} label="Approve (within my limit)" refresh={R} /> : null }]} />
          </Card>
          <Card title="Deposit" aside={fn === 'finance' && b.deposit ? <Act action="settle_deposit" payload={P} label="Settle the deposit" fields={[{ name: 'plan', label: 'Plan (apply, hold back, release)', type: 'json', value: { release: true } }]} refresh={R} /> : null}>
            {b.deposit ? <Kv rows={[['Amount', $(b.deposit.amount_cents)], ['Method', label(b.deposit.method)], ['Status', label(b.deposit.status)], ['Release due', String(b.deposit.release_due_on ?? '')]]} /> : <p className="small muted">No deposit taken yet ({$(b.deposit_cents)} at pickup).</p>}
          </Card>
          {fn === 'finance' && b.status === 'returned' && <Card title="Statement"><Act action="issue_booking_statement" payload={P} label="Issue the final statement" confirm="Issue the Check-in statement from the assessed lines. Damage lines wait for an Admin." refresh={R} /></Card>}
        </div>
      )}
      {tab === 'changes' && fn === 'cs' && (
        <div className="stack">
          <Card title="Change requests"><Table rows={b.change_requests} empty="No change requests." cols={[{ key: 'created_at', label: 'When', render: (r) => t(r.created_at) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'total_difference_cents', label: 'Difference', num: true, render: (r) => $(r.total_difference_cents) },
            { key: 'act', label: 'Decide', render: (r) => ['requested', 'proposed'].includes(String(r.status)) ? <span className="ad-actions"><Act action="approve_change" payload={{ request: r.id }} label="Approve" variant="primary" refresh={R} /><Act action="decline_change" payload={{ request: r.id }} label="Decline" fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={R} /></span> : null }]} /></Card>
          <Card title="Extensions"><Table rows={b.extensions} empty="No extensions." cols={[{ key: 'seq', label: 'No.' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'new_return_at', label: 'New return', render: (r) => t(r.new_return_at) }, { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) },
            { key: 'act', label: 'Decide', render: (r) => r.status === 'requested' ? <span className="ad-actions"><Act action="approve_extension" payload={{ extension: r.id }} label="Approve and send the pay link" variant="primary" refresh={R} /><Act action="decline_extension" payload={{ extension: r.id }} label="Decline" fields={[{ name: 'reason', label: 'Reason', type: 'text' }]} refresh={R} /></span> : null }]} /></Card>
          <Card title="Questions to the renter"><Table rows={b.info_requests} empty="No questions." cols={[{ key: 'asked_at', label: 'Asked', render: (r) => t(r.asked_at) }, { key: 'question', label: 'Question', className: 'wrap' }, { key: 'status', label: 'Status' }, { key: 'reply', label: 'Reply', className: 'wrap' }]} /></Card>
        </div>
      )}
      {tab === 'messages' && fn === 'cs' && (
        <div className="ad-cols ad-cols--2">
          <Card title="Messages"><ol className="ad-timeline" data-testid="messages">{messages.map((m) => <li key={String(m.id)}><time>{t(m.occurred_at)}</time><span><b>{m.direction === 'inbound' ? String(m.renter_first_name ?? 'Renter') : String(m.sent_by ?? 'CarmaCars')}</b> {String(m.body ?? m.subject ?? '')}</span></li>)}</ol>{!messages.length && <p className="small muted">No messages on this booking.</p>}</Card>
          <Card title="Reply"><QuickReply booking={b.id} replies={replies.rows} /></Card>
        </div>
      )}
      {tab === 'history' && (
        <Card title="Timeline" testId="timeline"><ol className="ad-timeline">{b.events.map((e) => <li key={String(e.id)}><time>{t(e.created_at)}</time><span><b>{label(e.kind)}</b>{e.note ? `: ${String(e.note)}` : ''} <span className="muted small">{String(e.actor_name ?? e.actor_type ?? '')}</span></span></li>)}</ol></Card>
      )}
    </>
  );
}
