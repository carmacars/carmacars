import { pageMeta } from '@/features/seo/meta';
import { adminCtx } from '@/features/shared-pages/context';
import { SalesLeadPage } from '@/features/sales-leads/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Lead', path: '/admin/sales-leads', noindex: true, description: 'One lead: who, where from, what they wrote, and what was done.' });

// One lead (r35, 0950): where every new-lead alert, push and email goes.
export default async function SalesLead({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const ctx = await adminCtx(`/admin/sales-leads/${id}`);
  return <SalesLeadPage ctx={ctx} id={id} base="/admin/sales-leads" chatBase="/admin/visitors" />;
}
