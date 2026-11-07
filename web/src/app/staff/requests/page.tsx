import { pageMeta } from '@/features/seo/meta';
import { RequestsPage } from '@/features/requests-page/RequestsPage';
import { staffCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Requests and offers', path: '/staff/requests', noindex: true, description: 'Booking requests and offers out.' });

// The requests inbox (05-va.md section 4.1). r31: the same page as the Admin's (features/requests-page), customer service and Sales.
export default async function VaRequests({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([staffCtx('/staff/requests', ['cs', 'sales']), searchParams]);
  return <RequestsPage ctx={ctx} sp={sp} />;
}
