import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { Back, Dl } from '@/features/portal/Blocks';
import { day, monthOf } from '@/features/owner/Blocks';
import { MODE_LABEL, type StatementLine } from '@/features/owner/types';
import { ownerStatement, requireOwner } from '@/server/owner/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Statement', path: '/owner/statements', noindex: true, description: 'A monthly owner statement.' });

const c = (v?: number) => (v === undefined || v === null ? '' : money(v, { cents: true }));
const LINE: Record<string, string> = { rental: 'Rental', turo_trip: 'Turo trip', withheld: 'Withheld (chargeback open)', fees_deducted: 'Unpaid Fees deducted', owner_cost: 'Owner cost deducted', refund_or_chargeback: 'Earlier refund or chargeback', arrears_moved: 'Arrears moved', kickback_earned: 'Referral Kickback earned', hst_on_payout: 'HST on payout', balance_brought_forward: 'Balance brought forward', credit: 'Credit' };

function LineRow({ l }: { l: StatementLine }) {
  const ref = l.booking_number ? `Booking ${l.booking_number}` : l.invoice_number ? `Invoice ${l.invoice_number}` : l.from_vehicle_name ? `From ${l.from_vehicle_name}` : '';
  const detail = l.line_type === 'rental'
    ? [l.starts_on && `${day(l.starts_on)} to ${day(l.ends_on)}`, `Rental Charge ${c(l.rental_charge_cents)}`, l.mileage_overage_cents ? `mileage ${c(l.mileage_overage_cents)}` : '', l.refunds_cents ? `refunds ${c(-l.refunds_cents)}` : '', l.chargebacks_cents ? `chargebacks ${c(-l.chargebacks_cents)}` : '', l.kickback_cents ? `Referral Kickback ${c(-l.kickback_cents)}` : '', `Owner Revenue ${c(l.owner_revenue_cents)}`]
    : l.line_type === 'turo_trip' ? [`Turo gross ${c(l.turo_gross_cents)}`, `Turo fees ${c(-(l.turo_fees_cents ?? 0))}`]
    : l.line_type === 'fees_deducted' ? [`Fees with HST ${c(l.fee_cents)}`, l.late_fee_cents ? `Late Fee ${c(l.late_fee_cents)}` : '']
    : [l.description ?? ''];
  return <li><span>{LINE[l.line_type] ?? l.line_type}{ref ? ` · ${ref}` : ''}</span><span className="ow-amount">{c(l.amount_cents)}</span><span className="ow-meta">{detail.filter(Boolean).map((d, i) => <span key={i}>{d}</span>)}</span></li>;
}

// The statement as stored (11-statements-and-reports.md section 2.1): owner totals, then each vehicle
// with every line and the booking or invoice behind it.
export default async function OwnerStatementPage({ params }: { params: Promise<{ id: string }> }) {
  const [{ user }, { id }] = await Promise.all([requireOwner('/owner/statements'), params]);
  const s = await ownerStatement(user, id);
  const st = s.statement;
  return (
    <>
      <Back href="/owner/statements">Statements</Back>
      <header className="stack"><p className="pt-kicker">Statement {st.statement_number}{st.is_final ? ' · Final statement' : ''}</p><h1 className="d2">{monthOf(st.statement_month)}</h1><p className="muted">Payout date {day(st.payout_date)}. Fees are billed separately on the 15th.</p></header>
      <div className="pt-split">
        <div className="stack-lg">
          {s.vehicles.map((v) => (
            <section key={v.vehicle_id} className="pt-card" aria-label={v.name}>
              <div className="pt-card__head"><h2 className="d4">{v.name}</h2><span className="small muted">{[v.plate, MODE_LABEL[v.management_mode]].filter(Boolean).join(' · ')}</span></div>
              {v.lines.length ? <ul className="ow-rows">{v.lines.map((l) => <LineRow key={l.id} l={l} />)}</ul> : <p className="small muted">No rentals ended this month.</p>}
              <dl className="pt-dl pt-dl--money">
                <div><dt>Owner Revenue</dt><dd>{c(v.totals.owner_revenue_cents)}</dd></div>
                <div><dt>Revenue Share</dt><dd>{c(-(v.totals.revenue_share_cents ?? 0))}</dd></div>
                <div><dt>Net earnings</dt><dd>{c(v.totals.net_earnings_cents)}</dd></div>
                {(v.totals.fees_deducted_cents ?? 0) + (v.totals.late_fees_deducted_cents ?? 0) + (v.totals.owner_costs_deducted_cents ?? 0) + (v.totals.refund_chargeback_deducted_cents ?? 0) > 0 && <div><dt>Deductions</dt><dd>{c(-((v.totals.fees_deducted_cents ?? 0) + (v.totals.late_fees_deducted_cents ?? 0) + (v.totals.owner_costs_deducted_cents ?? 0) + (v.totals.refund_chargeback_deducted_cents ?? 0)))}</dd></div>}
                <div><dt><b>Vehicle payable</b></dt><dd className="pt-total">{c(v.totals.payable_cents)}</dd></div>
              </dl>
            </section>
          ))}
          {s.owner_lines.length > 0 && <section className="pt-card" aria-labelledby="ow-ol"><h2 className="d4" id="ow-ol">Across your vehicles</h2><ul className="ow-rows">{s.owner_lines.map((l) => <LineRow key={l.id} l={l} />)}</ul></section>}
        </div>
        <aside className="pt-split__aside">
          <section className="pt-card" aria-labelledby="ow-tot"><h2 className="d4" id="ow-tot">Totals</h2>
            <dl className="pt-dl pt-dl--money">
              <div><dt>Vehicles payable</dt><dd>{c(st.vehicles_payable_cents)}</dd></div>
              {st.kickbacks_earned_cents !== 0 && <div><dt>Referral Kickbacks earned</dt><dd>{c(st.kickbacks_earned_cents)}</dd></div>}
              {st.hst_on_payout_cents !== 0 && <div><dt>HST on payout</dt><dd>{c(st.hst_on_payout_cents)}</dd></div>}
              {st.balance_brought_forward_cents !== 0 && <div><dt>Balance brought forward</dt><dd>{c(st.balance_brought_forward_cents)}</dd></div>}
              <div><dt><b>{st.balance_carried_forward_cents < 0 ? 'Balance owing' : 'Payout'}</b></dt><dd className="pt-total" data-testid="statement-payout">{c(st.balance_carried_forward_cents < 0 ? -st.balance_carried_forward_cents : st.payout_cents)}</dd></div>
            </dl>
            {s.payout && <Dl rows={[['Paid', s.payout.paid_at ? day(s.payout.paid_at) : `Scheduled for ${day(s.payout.scheduled_for)}`], ['Method', s.payout.method.replace('_', ' ')], ['Reference', s.payout.reference ?? '']]} />}
          </section>
        </aside>
      </div>
    </>
  );
}
