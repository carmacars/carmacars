import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { LiveVisitors } from '@/features/live/LiveVisitors';
import type { LiveData } from '@/features/live/staff';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Live visitors', path: '/va/live', noindex: true, description: 'Who is on the site now and their buying signals.' });

// My work > Live visitors (migration 0060): customer service and Sales.
export default async function VaLive() {
  const { read, fn } = await vaPage('/va/live', ['cs', 'sales']);
  const d = await read<LiveData>('live_visitors');
  return (<><PageHead title="Live visitors" kicker={FN_LABEL[fn]} /><LiveVisitors initial={d} portal="va" /></>);
}
