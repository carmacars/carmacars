import { pageMeta } from '@/features/seo/meta';
import { RequestsPage } from '@/features/requests-page/RequestsPage';
import { adminCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Requests and offers', path: '/admin/requests', noindex: true, description: 'Booking requests and offers, oldest first, and chauffeur requests.' });

// The request inbox (03-admin.md section 3). r31: the same page as staff's (features/requests-page).
export default async function Requests({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([adminCtx('/admin/requests'), searchParams]);
  return <RequestsPage ctx={ctx} sp={sp} />;
}
