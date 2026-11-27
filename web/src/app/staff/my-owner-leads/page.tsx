import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { $, Badge, Card, d, PageHead, Table, Tiles } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My owner leads', path: '/staff/my-owner-leads', noindex: true, description: 'The car owners you found: add one, and see where each one is.' });

type Row = { id: string; name: string; phone: string | null; email: string | null; car: string | null; city: string | null; note: string | null; created_at: string; stage: string; closer: string | null;
  credit: { amount_cents: number; status: string; paid_at: string | null } | null };
type Data = { flat_cents: number; generator: boolean; rows: Row[]; totals: { leads: number; signed: number; earned_cents: number; waiting_cents: number; paid_cents: number } };
const CREDIT: Record<string, string> = { pending_approval: 'Waiting for an Admin', approved: 'Approved: paid with your pay', paid: 'Paid', void: 'Not credited' };

// 5134: the owner-lead generator's page. Add an interested car owner (name, phone, email, city, car); a closer calls them
// through the site. Each owner who signs earns the flat amount of Program settings. Every lead with where it is now.
export default async function MyOwnerLeads() {
  const { read } = await vaPage('/staff/my-owner-leads', ['sales']);
  const x = await read<Data>('my_owner_leads');
  const refresh = ['/staff/my-owner-leads'];
  return (<>
    <PageHead title="My owner leads" purpose={`Car owners you found. A closer calls each one through the site. You earn ${$(x.flat_cents)} for each owner who signs.`}>
      {x.generator && <Act action="owner_lead_add" label="Add an owner" variant="primary" refresh={refresh} testId="owner-lead-add" title="Add an interested car owner"
        done="Added. A closer will call them." submitLabel="Add the owner"
        fields={[{ name: 'name', label: 'Owner\'s name', type: 'text', required: true }, { name: 'phone', label: 'Phone', type: 'tel', required: true },
          { name: 'email', label: 'Email (optional)', type: 'email' }, { name: 'city', label: 'City', type: 'text' },
          { name: 'car', label: 'Car (year, make, model)', type: 'text' }, { name: 'note', label: 'Note for the closer', type: 'textarea', wide: true }]} />}
    </PageHead>
    <Tiles items={[{ k: 'Leads you found', v: x.totals.leads }, { k: 'Signed', v: x.totals.signed }, { k: 'Waiting for approval', v: $(x.totals.waiting_cents) },
      { k: 'Earned', v: $(x.totals.earned_cents), sub: `${$(x.totals.paid_cents)} paid` }]} />
    <Card title="Your leads" testId="my-owner-leads">
      <Table<Row> rows={x.rows} rowKey={(r) => r.id} empty="No leads yet. Press Add an owner for each car owner who is interested: a closer calls them." cols={[
        { key: 'name', label: 'Owner', className: 'wrap', render: (r) => <><b>{r.name}</b><br /><span className="small muted">{[r.phone, r.email].filter(Boolean).join(' · ')}</span></> },
        { key: 'car', label: 'Car', className: 'wrap', render: (r) => [r.car, r.city].filter(Boolean).join(', ') },
        { key: 'created_at', label: 'Added', render: (r) => d(r.created_at) },
        { key: 'stage', label: 'Where it is', className: 'wrap', render: (r) => <span data-testid={`ol-stage-${r.id.slice(0, 8)}`}>{r.stage}</span> },
        { key: 'closer', label: 'Closer', render: (r) => r.closer ?? 'Not picked up yet' },
        { key: 'credit', label: 'Your credit', render: (r) => (r.credit ? <><Badge s={r.credit.status === 'paid' ? 'paid' : r.credit.status === 'void' ? 'void' : 'pending'}>{CREDIT[r.credit.status] ?? r.credit.status}</Badge> {$(r.credit.amount_cents)}</> : '') }]} />
    </Card>
  </>);
}
