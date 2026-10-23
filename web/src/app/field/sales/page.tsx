import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { Commissions } from '@/features/sales/Commissions';
import type { StaffSales } from '@/features/va/SalesBoard';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My sales', path: '/field/sales', noindex: true, description: 'Your rentals and commissions.' });

// My sales for field staff (migration 0058): the commissions of the rentals they sourced (with their link or "I sourced
// this client"), each with its status, and the rentals they added.
export default async function FieldSales() {
  const { user } = await requireStaff('field', '/field/sales');
  const s = await door<StaffSales>(user.id, 'field_read', 'my_sales', { period: 'month', count: 3 });
  return (
    <div className="stack">
      <h1 className="d3">My sales</h1>
      <p className="small muted">The rentals you sourced or added, and the commission on each.</p>
      <Commissions c={s.commissions} own compact />
      <section className="fd-card" aria-labelledby="fs-deals"><h2 className="d4" id="fs-deals">Rentals</h2>
        {s.deals.length ? <ul className="fd-shots" data-testid="field-deals">{s.deals.map((x) => (
          <li key={x.booking_number}><span>{x.booking_number} · {x.vehicle}</span><span>{x.sourced ? 'You sourced it' : x.credited ? 'Entered for CarmaCars' : 'Not credited to you'}{x.commission ? `, commission ${x.commission.status.replace(/_/g, ' ')}` : ''}</span></li>))}</ul>
          : <p className="small muted">No rentals yet. Add one from Add a rental, or share your referral link.</p>}
      </section>
    </div>
  );
}
