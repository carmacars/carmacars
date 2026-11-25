import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { CheckinQueue } from '@/features/checkins/Queue';
import type { Queue } from '@/features/checkins/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Check-in visits', path: '/staff/check-ins', noindex: true, description: 'Monthly check-in visits of long rentals for Fleet and customer service.' });

// Release 50 (4000): Fleet and customer service see the same queue as the Admins.
export default async function StaffCheckins({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user, aal }, sp] = await Promise.all([vaPage('/staff/check-ins', ['fleet', 'cs']), searchParams]);
  const q = await door<Queue>(user.id, 'ops_read', 'checkin_queue', {}, aal);
  return (<><PageHead title="Check-in visits" purpose="Monthly visits of long rentals: condition, damage and maintenance due. A suggestion to the renter, never a fee." /><CheckinQueue q={q} base="/staff" show={sp.show} /></>);
}
