import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Badge, Filters, PageHead, Table, d } from '@/features/admin/ui';
import { APP_STATUS } from '@/features/admin/applications';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Applications', path: '/admin/applications', noindex: true, description: 'Owner applications to review.' });

type Row = { id: string; application_number: string; status: string; created_at: string; owner: string; email: string | null; vehicles: string[]; checks_done: number; is_test: boolean;
  requested_at: string | null; owner_replied_at: string | null };

// Owners and partners > Applications (October 16, 2026): every owner application from List your car, newest first; the
// chips filter by status. One click opens the application with everything needed to decide.
export default async function Applications({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/applications'), searchParams]);
  const status = sp.status ?? 'new';
  const r = await door<{ rows: Row[]; counts: Record<string, number> }>(user.id, 'ops_read', 'applications', { status: status === 'all' ? '' : status });
  const chips: Array<[string, string]> = [['new', `New (${r.counts.new ?? 0})`], ['waiting_on_owner', `Waiting on owner (${r.counts.waiting_on_owner ?? 0})`],
    ['approved', `Approved (${r.counts.approved ?? 0})`], ['declined', `Declined (${r.counts.declined ?? 0})`], ['all', 'All']];
  return (
    <>
      <PageHead title="Owner applications" kicker="From List your car on the website">
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/list-your-car/apply">Start an application</Link>
      </PageHead>
      <Filters base="/admin/applications" name="status" value={status} options={chips} sp={sp} />
      <Table<Row> testId="applications" caption="Owner applications" rows={r.rows}
        empty={status === 'new' ? 'No new applications. When an owner applies from List your car, the application shows up here and on your To do list.' : `No ${APP_STATUS[status]?.toLowerCase() ?? ''} applications.`} cols={[
        { key: 'application_number', label: 'Application', render: (x) => <Link prefetch={false} className="link" href={`/admin/applications/${x.id}`}>{x.application_number}</Link> },
        { key: 'status', label: 'Status', render: (x) => <Badge s={x.status === 'new' ? 'requested' : x.status === 'waiting_on_owner' ? 'sent' : x.status}>{APP_STATUS[x.status]}</Badge> },
        { key: 'owner', label: 'Owner', render: (x) => <>{x.owner}{x.is_test ? <span className="muted small"> (test)</span> : null}</> },
        { key: 'vehicles', label: 'Car', className: 'wrap', render: (x) => x.vehicles.join(', ') },
        { key: 'checks_done', label: 'Checks', render: (x) => `${x.checks_done} of 4` },
        { key: 'created_at', label: 'Applied', render: (x) => d(x.created_at) },
        { key: 'owner_replied_at', label: 'Owner answered', render: (x) => (x.owner_replied_at ? d(x.owner_replied_at) : '') }
      ]} />
    </>
  );
}
