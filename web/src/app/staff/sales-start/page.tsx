import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { Card, PageHead } from '@/features/admin/ui';
import type { PathRow } from '@/features/academy/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Do sales too', path: '/staff/sales-start', noindex: true, description: 'Finance staff opt in to sales: the Sales path first, then the Sales pages.' });

type State = { opted_in: boolean; ready: boolean; path: string; progress: PathRow | null } | null;

// Finance staff opt in to Sales (release 35 part RR, 1010), as field staff do on their portal (0931): the Sales path is added
// to their academy (it never holds their Finance work), and the Sales pages open once it is passed.
export default async function SalesStart() {
  const { user, aal, fn } = await vaPage('/staff/sales-start', ['finance']);
  const st = await door<State>(user.id, 'ops_read', 'finance_sales_state', { _va: fn }, aal).catch(() => null);
  const done = st?.progress?.sections.filter((x) => x.passed).length ?? 0;
  const total = st?.progress?.sections.length ?? 0;
  const R = ['/staff/sales-start'];
  return (<>
    <PageHead title="Do sales too" purpose="Sell rentals too and earn commission on the rentals you bring in. The Sales path in the academy comes first." />
    <Card title="Sales" testId="sales-hub">
      {!st?.opted_in ? <><p className="small">Your Finance work stays as it is. The Sales path is added to your academy; the Sales pages open once you pass it.</p>
        <Act ops action="finance_sales_optin" payload={{ on: true }} label="I want to do sales too" variant="primary" testId="sales-on" refresh={R} done="The Sales path is on your academy." /></>
        : !st.ready ? <><p className="small">First, the Sales path: {done} of {total} sections passed. The Sales pages open once it is passed.</p>
          <div className="row" style={{ gap: 'var(--s-2)' }}><Link prefetch={false} className="btn btn--primary btn--sm" href={`/staff/academy/${st.path}`}>Continue the Sales path</Link>
            <Act ops action="finance_sales_optin" payload={{ on: false }} label="Stop" testId="sales-off" refresh={R} confirm="Take the Sales path off your academy?" /></div></>
        : <><p className="small">You do sales too. Your Sales pages are in the menu.</p>
          <p className="row" style={{ gap: 'var(--s-2)' }}><Link prefetch={false} className="btn btn--primary btn--sm" href="/staff/requests">Requests and offers</Link>
            <Link prefetch={false} className="btn btn--ghost btn--sm" href="/staff/my-sales">My sales numbers</Link>
            <Act ops action="finance_sales_optin" payload={{ on: false }} label="Stop doing sales" testId="sales-off" refresh={R} confirm="Stop doing sales? The Sales pages close." /></p></>}
    </Card>
  </>);
}
