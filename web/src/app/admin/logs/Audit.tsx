import type { AdminPage } from '@/server/admin/api';
import { PageHead, Search, Table, t } from '@/features/admin/ui';

type R = Record<string, unknown>;
const diff = (b: unknown, a: unknown) => {
  const x = (b ?? {}) as R; const y = (a ?? {}) as R;
  return [...new Set([...Object.keys(x), ...Object.keys(y)])].filter((k) => JSON.stringify(x[k]) !== JSON.stringify(y[k]) && !['updated_at'].includes(k)).slice(0, 8)
    .map((k) => `${k}: ${x[k] === undefined ? '' : JSON.stringify(x[k])} to ${y[k] === undefined ? '' : JSON.stringify(y[k])}`).join('; ');
};

// The audit log viewer (03-admin.md section 16): read only, before and after as a field diff. Settings > Logs > Changes and
// Data access since r27 (/admin/audit redirects).
export async function Audit({ ctx: { list }, sp, tab }: { ctx: AdminPage; sp: Record<string, string | undefined>; tab: 'changes' | 'access' }) {
  const eq: Record<string, unknown> = {};
  if (sp.table) eq.entity_table = sp.table;
  if (sp.record) eq.entity_id = sp.record;
  const { rows, count } = tab === 'access' ? await list('data_access_log', { q: sp.q, limit: 200 }) : await list('audit_log', { eq, q: sp.q, order: 'at', limit: 200 });
  return (<>
    <PageHead title={tab === 'access' ? 'Data access' : 'Changes'} kicker={`${count} entries`} purpose={tab === 'access' ? 'Who opened personal data, and when.' : 'Who changed what: each change with its before and after.'}><Search action={`/admin/logs?tab=${tab}`} value={sp.q} placeholder="Table, record id, value" /></PageHead>
    {tab === 'access' ? <Table<R> rows={rows} empty="No entries match. Clear a filter, or search for a booking number or an email address." cols={Object.keys(rows[0] ?? { at: 1 }).slice(0, 7).map((k) => ({ key: k, label: k.replace(/_/g, ' ') }))} />
      : <Table<R> testId="audit" rows={rows} empty="No entries match. Clear a filter, or search for a booking number or an email address." cols={[{ key: 'at', label: 'When', render: (r) => t(r.at) }, { key: 'actor_name', label: 'Who', render: (r) => String(r.actor_name ?? r.actor_db_role ?? '') }, { key: 'action', label: 'Action' }, { key: 'entity_table', label: 'Table' }, { key: 'entity_id', label: 'Record' }, { key: 'diff', label: 'Change', className: 'wrap', render: (r) => diff(r.before, r.after) }]} />}
  </>);
}
