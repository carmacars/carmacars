import { pageMeta } from '@/features/seo/meta';
import { adminCtx } from '@/features/shared-pages/context';
import { SalesLeadsPage } from '@/features/sales-leads/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Leads', path: '/admin/sales-leads', noindex: true, description: 'Every lead in one place, with claims and outcomes.' });

// People > Leads (r35, 0950): every lead in one place (renters, owners, partners), and the Sales team tab.
export default async function SalesLeads({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([adminCtx('/admin/sales-leads'), searchParams]);
  return <SalesLeadsPage ctx={ctx} sp={sp} base="/admin/sales-leads" title="Leads"
    purpose="Every lead in one place: renters (forms, live chat, phone box, games, expired offers, requests not sent, missed calls, Live visitors), owners and partners. New and hot first. Claim one to work on it." />;
}
