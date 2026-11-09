import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { Commissions } from '@/features/sales/Commissions';
import type { StaffSales } from '@/features/va/SalesBoard';
import Link from '@/components/Link';
import { FieldButton } from '@/features/field/FieldButton';
import type { PathRow } from '@/features/academy/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My sales', path: '/staff/field/sales', noindex: true, description: 'Your rentals and commissions.' });

// The Sales tab of a field person who opted in (r35 part X, 0931): the Sales path first, then the Sales pages, adding a rental and the
// referral link. My sales for field staff (migration 0058): the commissions of the rentals they sourced (with their link or "I sourced
// this client"), each with its status, and the rentals they added.
export default async function FieldSales() {
  const { user } = await requireStaff('field', '/staff/field/sales');
  const [s, st] = await Promise.all([door<StaffSales>(user.id, 'field_read', 'my_sales', { period: 'month', count: 3 }),
    door<{ opted_in: boolean; ready: boolean; path: string; progress: PathRow | null } | null>(user.id, 'field_read', 'sales_state').catch(() => null)]);
  const done = st?.progress?.sections.filter((x) => x.passed).length ?? 0;
  const total = st?.progress?.sections.length ?? 0;
  return (
    <div className="stack">
      <h1 className="d3">Sales</h1>
      {!st?.opted_in ? <section className="fp-paystep" data-testid="sales-hub"><p className="small">Sell rentals too and earn commission on the rentals you bring in. The Sales path in Training comes first.</p>
          <FieldButton action="sales_optin" payload={{ on: true }} label="I want to do sales too" primary testId="sales-on" /></section>
        : !st.ready ? <section className="fp-paystep" data-testid="sales-hub"><h2 className="fd-section-h">First: the Sales path</h2>
          <p className="small">{done} of {total} sections passed. The Sales pages open once it is passed.</p>
          <Link prefetch={false} className="btn btn--primary fd-wide" href={`/staff/academy/${st.path}`}>Continue the Sales path</Link></section>
        : <section className="fp-paystep is-done stack" data-testid="sales-hub"><h2 className="fd-section-h">Your Sales pages</h2>
          <Link prefetch={false} className="btn btn--primary fd-wide" href="/staff/requests">Requests and offers</Link>
          <Link prefetch={false} className="btn btn--ghost fd-wide" href="/staff/visitors">Visitors</Link>
          <Link prefetch={false} className="btn btn--ghost fd-wide" href="/staff/my-sales">My sales numbers</Link></section>}
      <p className="row"><Link prefetch={false} className="btn btn--ghost btn--sm" href="/staff/field/rentals/new" data-testid="field-add-rental">Add a rental</Link>
        <Link prefetch={false} className="btn btn--ghost btn--sm" href="/staff/field/referrals">My referral link</Link></p>
      <h2 className="d4">My rentals and commissions</h2>
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
