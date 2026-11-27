import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { ListFilters } from '@/features/list-filters/ListFilters';
import { Badge, Card, d, PageHead, Table } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Shift claims', path: '/admin/shift-claims', noindex: true, description: 'Field shifts salespeople claimed: approve or deny each one.' });

type R = Record<string, unknown>;
type Data = { status: string; pending: number; rows: Array<{ id: string; staff: string; when: string; given_up: boolean; status: string; note: string | null; claimed_at: string; taken: number; capacity: number }> };
const WORDS: Record<string, string> = { pending: 'Waiting', approved: 'Approved', denied: 'Denied', lapsed: 'Not decided in time' };

// Admin > Team > Shift claims (5136): a salesperson's claim of a field shift waits here. Approve books it (the shift's own
// rules still decide); Deny needs the reason. They are told either way.
export default async function ShiftClaims({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/shift-claims'), searchParams]);
  const status = ['pending', 'approved', 'denied', 'lapsed', 'all'].includes(sp.status ?? '') ? sp.status! : 'pending';
  const x = await read<Data>('shift_claims', { status });
  const refresh = ['/admin/shift-claims'];
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/fleet">Field jobs</Link>} title="Shift claims"
      purpose="Salespeople who work field shifts claim them here first. Approve to give them the shift, or deny with the reason." />
    <ListFilters id="admin-shift-claims" base="/admin/shift-claims" sp={sp} chips={{ name: 'status', label: 'Status', value: status === 'pending' ? '' : status,
      options: [['', `Waiting (${x.pending})`], ['approved', 'Approved'], ['denied', 'Denied'], ['lapsed', 'Not decided in time'], ['all', 'All']] }} />
    <Card title={status === 'pending' ? 'Waiting for you' : 'Claims'} testId="shift-claims">
      <Table<R> rows={x.rows as unknown as R[]} rowKey={(r) => String(r.id)} empty={status === 'pending' ? 'No claim waits. A salesperson\'s claim of a shift shows here.' : 'No claim in this state.'} cols={[
        { key: 'when', label: 'Shift', className: 'wrap', render: (r) => <><b>{String(r.when)}</b>{r.given_up ? <><br /><span className="small muted">Given up by someone</span></> : null}</> },
        { key: 'staff', label: 'Salesperson' }, { key: 'claimed_at', label: 'Claimed', render: (r) => d(r.claimed_at) },
        { key: 'taken', label: 'On it', num: true, render: (r) => `${Number(r.taken)} of ${Number(r.capacity)}` },
        { key: 'status', label: 'Status', className: 'wrap', render: (r) => <><Badge s={r.status === 'approved' ? 'paid' : r.status === 'pending' ? 'pending' : 'void'}>{WORDS[String(r.status)] ?? String(r.status)}</Badge>{r.note ? <><br /><span className="small muted">{String(r.note)}</span></> : null}</> },
        { key: 'act', label: '', render: (r) => (r.status === 'pending' ? <span className="ad-actions">
          <Act action="shift_claim_decide" payload={{ claim: r.id, approve: true }} label="Approve" variant="primary" refresh={refresh} done="Approved: the shift is theirs. They were told." testId={`sc-approve-${String(r.id).slice(0, 8)}`} />
          <Act action="shift_claim_decide" payload={{ claim: r.id, approve: false }} label="Deny" variant="quiet" refresh={refresh} done="Denied. They were told why." testId={`sc-deny-${String(r.id).slice(0, 8)}`}
            fields={[{ name: 'note', label: 'Why (they read it)', type: 'text', required: true }]} /></span> : null) }]} />
    </Card>
  </>);
}
