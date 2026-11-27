import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, Card, d, PageHead, Table, Tiles } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Lead generators', path: '/admin/lead-generators', noindex: true, description: 'The people who find car owners for the closers, and the credit for each owner who signed.' });

type R = Record<string, unknown>;
type Data = { flat_cents: number; candidates: Array<[string, string]>;
  people: Array<{ id: string; name: string; lead_generator: boolean; leads: number; open: number; signed: number; owed_cents: number; paid_cents: number }>;
  credits: Array<{ id: string; lead_id: string; lead: string | null; staff: string; amount_cents: number; status: string; earned_at: string; paid_at: string | null; paid_reference: string | null; note: string | null }> };
const STATUS: Record<string, string> = { pending_approval: 'To approve', approved: 'Approved, not paid', paid: 'Paid', void: 'Void' };

// Admin > Team > Lead generators (5134): who has the role, their leads and credits; approve, void or pay each credit.
export default async function LeadGenerators() {
  const { read } = await page('/admin/lead-generators');
  const x = await read<Data>('lead_generators');
  const refresh = ['/admin/lead-generators'];
  const due = x.credits.filter((c) => c.status === 'pending_approval');
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/sales-leads?tab=team">Sales team</Link>} title="Lead generators"
      purpose={<>They enter interested car owners; the closers call them through the site. Each owner who signs earns {$(x.flat_cents)} (Settings &gt; Program settings, lead generators).</>}>
      {x.candidates.length > 0 && <Act action="lead_gen_set" label="Make someone a lead generator" variant="primary" refresh={refresh} done="Done. They see Owners I found in their portal." testId="lead-gen-add"
        fields={[{ name: 'staff', label: 'Salesperson', type: 'select', required: true, options: x.candidates }]} payload={{ on: true }} />}
    </PageHead>
    <Tiles items={[{ k: 'Lead generators', v: x.people.filter((p) => p.lead_generator).length }, { k: 'Credits to approve', v: due.length, warn: due.length > 0 },
      { k: 'Approved, not paid', v: $(x.people.reduce((n, p) => n + p.owed_cents, 0)) }]} />
    <Card title="People" testId="lead-gen-people">
      <Table<R> rows={x.people as unknown as R[]} rowKey={(r) => String(r.id)} empty="Nobody yet. Make a salesperson a lead generator with the button above." cols={[
        { key: 'name', label: 'Person', render: (r) => <><b>{String(r.name)}</b>{r.lead_generator ? null : <span className="small muted"> (role off)</span>}</> },
        { key: 'leads', label: 'Leads', num: true }, { key: 'open', label: 'Open', num: true }, { key: 'signed', label: 'Signed', num: true },
        { key: 'owed_cents', label: 'To pay', num: true, render: (r) => $(r.owed_cents) }, { key: 'paid_cents', label: 'Paid', num: true, render: (r) => $(r.paid_cents) },
        { key: 'act', label: '', render: (r) => <Act action="lead_gen_set" payload={{ staff: r.id, on: !r.lead_generator }} label={r.lead_generator ? 'End the role' : 'Give the role'} variant="quiet" refresh={refresh}
          confirm={r.lead_generator ? 'They can no longer add owner leads. Their leads and credits stay.' : undefined} done="Saved." testId={`lead-gen-toggle-${String(r.id).slice(0, 8)}`} /> }]} />
    </Card>
    <Card title="Credits" testId="lead-gen-credits">
      <Table<R> rows={x.credits as unknown as R[]} rowKey={(r) => String(r.id)} empty="No owner a lead generator found has signed yet. Each one shows here to approve." cols={[
        { key: 'earned_at', label: 'Signed', render: (r) => d(r.earned_at) }, { key: 'staff', label: 'Lead generator' },
        { key: 'lead', label: 'Owner', render: (r) => <Link prefetch={false} className="link" href={`/admin/sales-leads/${String(r.lead_id)}`}>{String(r.lead ?? 'The lead')}</Link> },
        { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) },
        { key: 'status', label: 'Status', className: 'wrap', render: (r) => <><Badge s={r.status === 'paid' ? 'paid' : r.status === 'void' ? 'void' : 'pending'}>{STATUS[String(r.status)] ?? String(r.status)}</Badge>{r.paid_reference ? <span className="small muted"> {String(r.paid_reference)}</span> : null}{r.note ? <><br /><span className="small muted">{String(r.note)}</span></> : null}</> },
        { key: 'act', label: '', render: (r) => <span className="ad-actions">
          {r.status === 'pending_approval' && <Act action="lead_gen_credit" payload={{ credit: r.id, action: 'approve' }} label="Approve" variant="primary" refresh={refresh} done="Approved." testId={`lgc-approve-${String(r.id).slice(0, 8)}`} />}
          {r.status === 'approved' && <Act action="lead_gen_credit" payload={{ credit: r.id, action: 'paid' }} label="Mark paid" refresh={refresh} done="Marked paid." testId={`lgc-paid-${String(r.id).slice(0, 8)}`}
            fields={[{ name: 'reference', label: 'Payment reference', type: 'text', required: true }]} />}
          {['pending_approval', 'approved'].includes(String(r.status)) && <Act action="lead_gen_credit" payload={{ credit: r.id, action: 'void' }} label="Void" variant="quiet" refresh={refresh} done="Voided." testId={`lgc-void-${String(r.id).slice(0, 8)}`}
            fields={[{ name: 'note', label: 'Why (the lead generator reads it)', type: 'text', required: true }]} />}</span> }]} />
    </Card>
  </>);
}
