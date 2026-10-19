import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { LiveVisitors } from '@/features/live/LiveVisitors';
import type { LiveData } from '@/features/live/staff';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Live visitors', path: '/admin/live', noindex: true, description: 'Who is on the site now, what they look at and their buying signals.' });

// Today > Live visitors (migration 0060).
export default async function Live() {
  const { read } = await page('/admin/live');
  const d = await read<LiveData>('live_visitors');
  return (<><PageHead title="Live visitors" kicker="Today" /><LiveVisitors initial={d} portal="admin" /></>);
}
