import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { Badge, Card, PageHead, Table, t, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner leads', path: '/va/leads', noindex: true, description: 'Owner leads and applications.' });

type R = Record<string, unknown>;

// Owner leads and applications (05-va.md sections 4.3 and 5): take a lead, mark it contacted or qualified,
// close it with a reason; applications show where each owner's cars are in onboarding.
export default async function Leads() {
  const { read, list, fn } = await vaPage('/va/leads', ['sales', 'cs']);
  const [o, enquiries, buyers] = await Promise.all([read<{ leads: R[]; applications: R[] }>('owner_leads'),
    fn === 'cs' ? list<R>('leads', { eq: { status: ['new', 'contacted', 'qualified'] }, limit: 100 }) : Promise.resolve({ rows: [] as R[], count: 0 }),
    list<R>('leads', { eq: { kind: ['buyer'], status: ['new', 'contacted', 'qualified'] }, limit: 100 })]);
  const R_ = ['/va/leads'];
  const actions = (r: R) => <span className="ad-actions">
    {!r.assigned_to && <Act action="lead_update" payload={{ id: r.id, take: true }} label="Take it" refresh={R_} />}
    <Act action="lead_update" payload={{ id: r.id }} label="Update" fields={[{ name: 'status', label: 'Status', type: 'select', required: true, value: r.status, options: [['new', 'New'], ['contacted', 'Contacted'], ['qualified', 'Qualified'], ['converted', 'Converted'], ['closed', 'Closed']] }, { name: 'closed_reason', label: 'Reason, when closed', type: 'text' }]} refresh={R_} /></span>;
  return (
    <>
      <PageHead title={fn === 'cs' ? 'Owners and enquiries' : 'Owner leads'} />
      <div className="stack">
        <Card title="Owner leads"><Table rows={o.leads} testId="owner-leads" empty="No open owner leads." cols={[{ key: 'created_at', label: 'Received', render: (r) => t(r.created_at) }, { key: 'name', label: 'Name' }, { key: 'email', label: 'Email' }, { key: 'phone', label: 'Phone' },
          { key: 'vehicle', label: 'Car' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'assignee_name', label: 'With' }, { key: 'act', label: '', render: actions }]} /></Card>
        {/* buyer leads from the /buy pages' "Find me this car" (0092); each also raised a To do line for Sales */}
        <Card title="Buyer leads"><Table rows={buyers.rows} testId="buyer-leads" empty="No open buyer leads." cols={[{ key: 'created_at', label: 'Received', render: (r) => t(r.created_at) }, { key: 'name', label: 'Name' }, { key: 'email', label: 'Email' }, { key: 'phone', label: 'Phone' },
          { key: 'car', label: 'Car', render: (r) => String((r.payload as R | null)?.vehicle ?? '') }, { key: 'budget', label: 'Budget', render: (r) => String((r.payload as R | null)?.budget ?? '') }, { key: 'when', label: 'When', render: (r) => String((r.payload as R | null)?.timeline ?? '') },
          { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'act', label: '', render: actions }]} /></Card>
        <Card title="Owner applications, last 90 days"><Table rows={o.applications} rowKey={(r) => String(r.application_number)} empty="No applications." cols={[{ key: 'application_number', label: 'Application' }, { key: 'owner_name', label: 'Owner' }, { key: 'vehicle_count', label: 'Cars', num: true },
          { key: 'statuses', label: 'Onboarding', render: (r) => ((r.statuses as string[] | null) ?? []).map(label).join(', ') }, { key: 'created_at', label: 'Applied', render: (r) => t(r.created_at) }]} /></Card>
        {fn === 'cs' && <Card title="Enquiries"><Table rows={enquiries.rows.filter((r) => r.kind !== 'owner_program' && r.kind !== 'buyer')} empty="No open enquiries." cols={[{ key: 'created_at', label: 'Received', render: (r) => t(r.created_at) }, { key: 'kind', label: 'Kind', render: (r) => label(r.kind) }, { key: 'name', label: 'Name' }, { key: 'email', label: 'Email' }, { key: 'message', label: 'Message', className: 'wrap' }, { key: 'status', label: 'Status' }, { key: 'act', label: '', render: actions }]} /></Card>}
      </div>
    </>
  );
}
