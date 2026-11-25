import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { CheckinQueue } from '@/features/checkins/Queue';
import type { Queue } from '@/features/checkins/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Check-in visits', path: '/admin/check-ins', noindex: true, description: 'Monthly check-in visits of long rentals: booked, due, overdue and done.' });

// Release 50 (4000): the monthly check-in visits of long rentals, the same queue as Fleet's, customer service's and field work's.
export default async function AdminCheckins({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/check-ins'), searchParams]);
  const q = await door<Queue>(user.id, 'ops_read', 'checkin_queue');
  return (<><PageHead title="Check-in visits" kicker="Cars" purpose="Monthly visits of long rentals: condition, damage and maintenance due. A suggestion to the renter, never a fee." /><CheckinQueue q={q} base="/admin" show={sp.show} /></>);
}
