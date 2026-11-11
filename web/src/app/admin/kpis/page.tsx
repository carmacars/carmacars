import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Card, PageHead, d } from '@/features/admin/ui';
import { STAFF_FN_LABEL, type StaffFn } from '@/features/staff/nav';
import { kpiState, kpiTarget, kpiValue, type Kpi } from '@/features/kpis/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'KPIs', path: '/admin/kpis', noindex: true, description: 'Every staff member\'s KPIs for a week against the targets in Program settings.' });

type Board = { week: string; prev: string; next: string | null; people: Array<{ user_id: string; name: string; functions: string[]; items: Kpi[] }>; settings: { rate_target_pct: number; grace_minutes: number } };
// a scorecard is kept for assistants (customer service, Fleet, Finance); field staff have none (it would answer 404)
const VA_FNS = new Set(['cs', 'fleet', 'finance']);
const FNS: Array<[string, string]> = [['', 'Everyone'], ['cs', 'Customer service'], ['fleet', 'Fleet'], ['finance', 'Finance'], ['field', 'Field']];

// 1504: Admin > Team > KPIs, every staff member's KPIs of a week (customer service, Fleet, Finance, field; Sales keeps its
// month target on the scorecard). Each person's scorecard has the same KPIs by week.
export default async function AdminKpis({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/kpis'), searchParams]);
  const b = await door<Board>(user.id, 'admin_read', 'kpi_board', { week: sp.week ?? null, function: sp.fn ?? null });
  const q = (x: Record<string, string | null | undefined>) => `/admin/kpis?${new URLSearchParams(Object.entries({ week: sp.week, fn: sp.fn, ...x }).filter(([, v]) => v) as Array<[string, string]>)}`;
  return (<>
    <PageHead title="KPIs" kicker={`Week of ${d(b.week)}`} purpose={`Each role's KPIs against the targets in Program settings (kpi_*): rates must reach ${b.settings.rate_target_pct}%, on time is within ${b.settings.grace_minutes} minutes.`} />
    <p className="small" data-testid="kpi-nav"><Link prefetch={false} className="link" href={q({ week: b.prev })}>Earlier week</Link>{b.next ? <>{' · '}<Link prefetch={false} className="link" href={q({ week: b.next })}>Later week</Link></> : null}
      {' · '}{FNS.map(([k, l], i) => <span key={k}>{i ? ' · ' : ''}{(sp.fn ?? '') === k ? <b>{l}</b> : <Link prefetch={false} className="link" href={q({ fn: k || null })}>{l}</Link>}</span>)}</p>
    {b.people.map((p) => (
      <Card key={p.user_id} title={p.name} testId={`kpi-person-${p.user_id}`} aside={p.functions.some((f) => VA_FNS.has(f)) ? <Link prefetch={false} className="link small" href={`/admin/staff/${p.user_id}/scorecard`}>Scorecard</Link> : undefined}>
        <p className="small muted">{p.functions.map((f) => STAFF_FN_LABEL[f as StaffFn] ?? f).join(', ')}</p>
        {p.items.length ? <ul className="small">{p.items.map((k) => (
          <li key={k.key} className={kpiState(k) === 'missed' ? 'ad-late' : undefined} data-testid={`kpi-${p.user_id}-${k.key}`}><b>{k.label}:</b> {kpiValue(k)} (target {kpiTarget(k)}){k.detail ? `, ${k.detail}` : ''}{kpiState(k) === 'met' ? ' · met' : kpiState(k) === 'missed' ? ' · missed' : ''}</li>))}</ul>
          : <p className="small muted">No KPIs for this role (Sales: the month&apos;s target is on the scorecard).</p>}
      </Card>))}
    {!b.people.length && <p className="small muted">No staff in this role.</p>}
  </>);
}
