import { pageMeta } from '@/features/seo/meta';
import { staffCtx } from '@/features/shared-pages/context';
import { SalesLeadsPage } from '@/features/sales-leads/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner leads', path: '/staff/owner-leads', noindex: true, description: 'Owner program enquiries, unfinished applications and owner contacts.' });

// Owners > Leads (r35, 0950): the lead list with owner leads only.
export default async function OwnerLeads({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([staffCtx('/staff/owner-leads', ['sales', 'cs']), searchParams]);
  return <SalesLeadsPage ctx={ctx} sp={sp} base="/staff/sales-leads" listBase="/staff/owner-leads" type="owner" title="Owner leads"
    purpose="Owner program enquiries, owner applications started and not finished, owner form contacts and earnings calculator contacts. Claim one, call or text, and record the outcome: contacted, call booked, applied, won or lost." />;
}
