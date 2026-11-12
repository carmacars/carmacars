import { IntentCard } from '@/features/intent/IntentCard';
import type { Intent } from '@/features/intent/model';
import { notFound } from 'next/navigation';
import type { PageCtx } from '@/features/shared-pages/context';
import { PageHead } from '@/features/admin/ui';
import { rpc } from '@/lib/db/repo';
import { clock, longDate, torontoParts } from '@/lib/dates';
import { LeadList } from './LeadList';
import { LeadPage } from './LeadPage';
import { SalesDashboard, SalesTeam } from './SalesDashboard';
import { listQuery, type CallTeam, type Dashboard, type LeadContext, type LeadDetail, type LeadList as Data, type LeadType } from './model';

// Find a renter is open to an Admin and to CS, Finance and Fleet (app/staff/renters): Sales gets no link there
const canOpenRenter = (ctx: PageCtx) => ctx.viewer.role === 'admin' || (ctx.viewer.role === 'staff' && ['cs', 'finance', 'fleet'].includes(ctx.viewer.fn));

/** Requests that did not go through (2670): refused or failed requests to book of the last 14 days that no later request
 *  closed, with the reason each person saw. Each one also has a Sales To-do. */
export interface RequestFailures { count: number; reasons: Array<{ code: string; reason: string; n: number }>;
  rows: Array<{ id: string; name: string | null; email: string | null; phone: string | null; car: string | null; pickup_at: string | null; return_at: string | null; code: string; reason: string; raw: string | null; unexpected: boolean; tries: number; last_at: string }> }
const when = (iso: string | null) => { if (!iso) return 'not set'; const t = torontoParts(iso); return `${longDate(t.date)}, ${clock(`${String(Math.floor(t.minutes / 60)).padStart(2, '0')}:${String(t.minutes % 60).padStart(2, '0')}`)}`; };
export function RequestFailuresCard({ d }: { d: RequestFailures | null }) {
  if (!d || !d.count) return null;
  return (
    <details className="panel" data-testid="request-failures">
      <summary><b>Requests that did not go through: <span className="num" data-testid="request-failures-count">{d.count}</span></b> <span className="small muted">last 14 days, not sent since. Each one is a Sales To-do.</span></summary>
      <ul className="small" style={{ margin: 'var(--s-2) 0' }}>{d.reasons.map((r) => <li key={r.code}><b className="num">{r.n}</b> {r.reason}</li>)}</ul>
      <div className="table-wrap"><table className="table small"><thead><tr><th>Who</th><th>Car and dates</th><th>Reason shown to them</th><th>Tries</th><th>Last try</th></tr></thead><tbody>
        {d.rows.map((r) => (
          <tr key={r.id}><td><b>{r.name ?? 'No name'}</b><br />{r.email && <a className="link" href={`mailto:${r.email}`}>{r.email}</a>}{r.email && r.phone ? ' ' : ''}{r.phone && <a className="link num" href={`tel:${r.phone.replace(/[^\d+]/g, '')}`}>{r.phone}</a>}</td>
            <td>{r.car || 'No car chosen'}<br /><span className="muted">{when(r.pickup_at)} to {when(r.return_at)}</span></td>
            <td>{r.reason}{r.unexpected && r.raw ? <><br /><span className="muted">The system said: {r.raw}</span></> : null}</td><td className="num">{r.tries}</td><td>{when(r.last_at)}</td></tr>))}
      </tbody></table></div>
    </details>
  );
}

/** The one Sales lead list, the same for an Admin and staff (r35): the page's base decides the portal. The Admin's copy has
 *  the team tab (the leaderboard); staff see their own numbers on top. `type` fixes the lead type (Owners > Leads). */
export async function SalesLeadsPage({ ctx, sp, base, listBase, type, title, purpose }: { ctx: PageCtx; sp: Record<string, string | undefined>; base: string; listBase?: string; type?: LeadType; title: string; purpose: string }) {
  const admin = ctx.viewer.role === 'admin';
  if (admin && sp.tab === 'team') {
    const [d, calls] = await Promise.all([ctx.read<Dashboard>('sales_dashboard', { period: sp.period }),
      ctx.read<{ team: CallTeam | null }>('my_call_minutes').then((c) => c.team ?? []).catch(() => undefined)]);
    return <><PageHead title="Sales team" purpose="Each person's leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, best first, with the call minutes of the month." /><SalesTeam d={d} base={`${base}?tab=team`} sp={sp} calls={calls} /></>;
  }
  const [d, dash, failures] = await Promise.all([ctx.read<Data>('sales_leads', listQuery(sp, type)), admin || type ? Promise.resolve(null) : ctx.read<Dashboard>('sales_dashboard').catch(() => null),
    // 2670: the Admin's count of requests to book that did not go through, with the reasons
    admin && !type && ctx.user ? (rpc('server_request_failures', { p_by: ctx.user.id }, { role: 'service_role' }) as unknown as Promise<RequestFailures>).catch(() => null) : Promise.resolve(null)]);
  return (
    <>
      <PageHead title={title} purpose={purpose} />
      <div className="stack">
        {dash && <SalesDashboard d={dash} base={base} />}
        <RequestFailuresCard d={failures} />
        <LeadList d={d} base={base} listBase={listBase ?? base} sp={sp} type={type} renterLink={canOpenRenter(ctx)} />
      </div>
    </>
  );
}

/** One lead's page (where every new-lead alert goes). */
export async function SalesLeadPage({ ctx, id, base, chatBase }: { ctx: PageCtx; id: string; base: string; chatBase: string }) {
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const d = await ctx.read<LeadDetail>('sales_lead', { id }).catch(() => null);
  if (!d) notFound();
  // r35 part C (1506): the lead's intent signals
  // r40 (2411): the whole person behind the lead, the same for an Admin and staff (the database decides how much)
  const [intent, context] = await Promise.all([ctx.ops<Intent | null>('intent', { lead: id }).catch(() => null), ctx.read<LeadContext>('lead_context', { lead: id }).catch(() => null)]);
  return <><IntentCard intent={intent} /><LeadPage d={d} base={base} chatHref={d.chat_id ? `${chatBase}?view=chat&id=${d.chat_id}` : null} context={context} renterLink={canOpenRenter(ctx)} /></>;
}
