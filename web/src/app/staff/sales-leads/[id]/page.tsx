import { pageMeta } from '@/features/seo/meta';
import { staffCtx } from '@/features/shared-pages/context';
import { SalesLeadPage } from '@/features/sales-leads/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Lead', path: '/staff/sales-leads', noindex: true, description: 'One lead: who, where from, what they wrote, and what was done.' });

// One lead (r35, 0950): where every new-lead alert and push goes on the staff portal.
export default async function SalesLead({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const ctx = await staffCtx(`/staff/sales-leads/${id}`, ['sales', 'cs']);
  return <SalesLeadPage ctx={ctx} id={id} base="/staff/sales-leads" chatBase="/staff/visitors" />;
}
