import { notFound } from 'next/navigation';
import type { PageCtx } from '@/features/shared-pages/context';
import { PageHead } from '@/features/admin/ui';
import { LeadList } from './LeadList';
import { LeadPage } from './LeadPage';
import { SalesDashboard, SalesTeam } from './SalesDashboard';
import { listQuery, type CallTeam, type Dashboard, type LeadDetail, type LeadList as Data, type LeadType } from './model';

/** The one Sales lead list, the same for an Admin and staff (r35): the page's base decides the portal. The Admin's copy has
 *  the team tab (the leaderboard); staff see their own numbers on top. `type` fixes the lead type (Owners > Leads). */
export async function SalesLeadsPage({ ctx, sp, base, listBase, type, title, purpose }: { ctx: PageCtx; sp: Record<string, string | undefined>; base: string; listBase?: string; type?: LeadType; title: string; purpose: string }) {
  const admin = ctx.viewer.role === 'admin';
  if (admin && sp.tab === 'team') {
    const [d, calls] = await Promise.all([ctx.read<Dashboard>('sales_dashboard', { period: sp.period }),
      ctx.read<{ team: CallTeam | null }>('my_call_minutes').then((c) => c.team ?? []).catch(() => undefined)]);
    return <><PageHead title="Sales team" purpose="Each person's leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, best first, with the call minutes of the month." /><SalesTeam d={d} base={`${base}?tab=team`} sp={sp} calls={calls} /></>;
  }
  const [d, dash] = await Promise.all([ctx.read<Data>('sales_leads', listQuery(sp, type)), admin || type ? Promise.resolve(null) : ctx.read<Dashboard>('sales_dashboard').catch(() => null)]);
  return (
    <>
      <PageHead title={title} purpose={purpose} />
      <div className="stack">
        {dash && <SalesDashboard d={dash} base={base} />}
        <LeadList d={d} base={base} listBase={listBase ?? base} sp={sp} type={type} />
      </div>
    </>
  );
}

/** One lead's page (where every new-lead alert goes). */
export async function SalesLeadPage({ ctx, id, base, chatBase }: { ctx: PageCtx; id: string; base: string; chatBase: string }) {
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const d = await ctx.read<LeadDetail>('sales_lead', { id }).catch(() => null);
  if (!d) notFound();
  return <LeadPage d={d} base={base} chatHref={d.chat_id ? `${chatBase}?view=chat&id=${d.chat_id}` : null} />;
}
