import { Card, $ } from '@/features/admin/ui';
import { Act } from '@/features/admin/Act';
import { PLAN, day, planWords, type Pay } from './model';

// A booking's payment plan (migration 0330): how the renter pays (in full, weekly, every 2 weeks, monthly), each payment
// with its date and whether it is paid, and Change the plan (Admins, customer service, finance). Bookings > Now reads the
// same schedule for the next payment.
// 1066: an Admin can fix the amount of each payment; the last one takes the remainder, and the total never changes.
export function PayPlanCard({ booking, pay, refresh, admin = false }: { booking: string; pay: Pay & { may_change?: boolean }; refresh: string[]; admin?: boolean }) {
  // overdue: the payments the schedule counts as overdue, from the next one on
  const lateTo = pay.state === 'overdue' && pay.next ? pay.next.seq + pay.overdue_count - 1 : 0;
  const rows = pay.schedule ?? [];
  return (
    <Card title="Payment plan" testId="pay-plan" aside={<span className="small">{planWords(pay)}{pay.set ? '' : ' (automatic)'}{pay.fixed_cents ? `, ${$(pay.fixed_cents)} a payment` : ''}</span>}>
      {rows.length > 1 && (
        <ol className="ad-list" data-testid="pay-plan-rows">{rows.map((r) => {
          const paid = pay.paid_cents >= r.through_cents;
          const late = !paid && r.seq <= lateTo;
          return (
            <li key={r.seq}><span>Payment {r.seq} of {rows.length}, {day(r.due_at)}</span><b>{$(r.cents)}</b>
              <span className={late ? 'ad-late small' : 'small'}>{paid ? 'paid' : late ? 'overdue' : 'to pay'}</span></li>);
        })}</ol>)}
      <p className="small">Owed by the renter {$(pay.owed_cents)}, paid {$(pay.paid_cents)}{pay.open_cents ? `, open ${$(pay.open_cents)}` : ''}.
        {pay.insurer ? ` The insurer${pay.insurer.name ? ` (${pay.insurer.name})` : ''} pays ${$(pay.insurer.share_cents)}.` : ''}</p>
      {pay.may_change && !['insurer', 'owner'].includes(pay.plan) && (
        <Act ops action="booking_pay_every" payload={{ booking }} label="Change the plan" testId="pay-plan-change" refresh={refresh} done="Payment plan changed."
          fields={[{ name: 'pay_every', label: 'The renter pays', type: 'select', required: true, value: pay.set ? pay.plan : 'auto',
            options: [['auto', 'Automatic (monthly when the rental has periods, else in full)'], ['whole', PLAN.whole], ['weekly', PLAN.weekly], ['biweekly', PLAN.biweekly], ['monthly', PLAN.monthly]] },
            ...(admin ? [{ name: 'fixed_cents', label: 'Fixed amount per payment (Admin; empty: split by the days)', type: 'money' as const, value: pay.fixed_cents ?? undefined,
              hint: 'Weekly, every 2 weeks or monthly. Each payment is this amount and the last one takes the remainder; the total and the payments already made do not change.' }] : [])]} />)}
    </Card>
  );
}
