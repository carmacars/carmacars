import { pageMeta } from '@/features/seo/meta';
import { staffCtx } from '@/features/shared-pages/context';
import { SalesLeadsPage } from '@/features/sales-leads/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Leads', path: '/staff/sales-leads', noindex: true, description: 'Every lead in one place, with claims and outcomes.' });

// Leads (r35, 0950): the same list as the Admin's, for Sales and customer service, with their own numbers on top.
export default async function SalesLeads({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([staffCtx('/staff/sales-leads', ['sales', 'cs']), searchParams]);
  return <SalesLeadsPage ctx={ctx} sp={sp} base="/staff/sales-leads" title="Leads"
    purpose="Every lead in one place. New and hot first. Claim one (or press Next lead), call, text or email from it, and record the outcome." />;
}
