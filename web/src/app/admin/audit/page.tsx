import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead, Search, Table, Tabs, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Audit log', path: '/admin/audit', noindex: true, description: 'Who changed what.' });
type R = Record<string, unknown>;
const diff = (b: unknown, a: unknown) => {
  const x = (b ?? {}) as R; const y = (a ?? {}) as R;
  return [...new Set([...Object.keys(x), ...Object.keys(y)])].filter((k) => JSON.stringify(x[k]) !== JSON.stringify(y[k]) && !['updated_at'].includes(k)).slice(0, 8)
    .map((k) => `${k}: ${x[k] === undefined ? '' : JSON.stringify(x[k])} to ${y[k] === undefined ? '' : JSON.stringify(y[k])}`).join('; ');
};

// The audit log viewer (03-admin.md section 16): read only, before and after as a field diff.
export default async function Audit({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ list }, sp] = await Promise.all([page('/admin/audit'), searchParams]);
  const tab = sp.tab ?? 'changes';
  const eq: Record<string, unknown> = {};
  if (sp.table) eq.entity_table = sp.table;
  if (sp.record) eq.entity_id = sp.record;
  const { rows, count } = tab === 'access' ? await list('data_access_log', { q: sp.q, limit: 200 }) : await list('audit_log', { eq, q: sp.q, order: 'at', limit: 200 });
  return (<>
    <PageHead title="Audit log" kicker={`${count} entries`}><Search action="/admin/audit" value={sp.q} placeholder="Table, record id, value" /></PageHead>
    <Tabs current={`/admin/audit?tab=${tab}`} items={[['/admin/audit?tab=changes', 'Changes'], ['/admin/audit?tab=access', 'Data access']]} />
    {tab === 'access' ? <Table<R> rows={rows} empty="No entries." cols={Object.keys(rows[0] ?? { at: 1 }).slice(0, 7).map((k) => ({ key: k, label: k.replace(/_/g, ' ') }))} />
      : <Table<R> testId="audit" rows={rows} empty="No entries." cols={[{ key: 'at', label: 'When', render: (r) => t(r.at) }, { key: 'actor_name', label: 'Who', render: (r) => String(r.actor_name ?? r.actor_db_role ?? '') }, { key: 'action', label: 'Action' }, { key: 'entity_table', label: 'Table' }, { key: 'entity_id', label: 'Record' }, { key: 'diff', label: 'Change', className: 'wrap', render: (r) => diff(r.before, r.after) }]} />}
  </>);
}
