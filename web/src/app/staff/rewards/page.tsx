import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { currentUser } from '@/server/portal/data';
import { rolesOf, sessionAal } from '@/server/door';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { loadMyRewards, MyRewards } from '@/features/staff-rewards/MyRewards';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My rewards', path: '/staff/rewards', noindex: true, description: 'Your staff discount, your tier and your free rental days.' });

// My rewards (release 48, migration 3261), office staff. The emails and alerts link here for every staff member: a person
// with field work only is sent on to the field portal's own page.
export default async function StaffRewardsPage() {
  const u = await currentUser();
  if (u) { const r = await rolesOf(u.id); if (!r.va && r.field) redirect('/staff/field/rewards'); }
  const { user } = await vaPage('/staff/rewards');
  const r = await loadMyRewards(user.id, await sessionAal());
  return (
    <>
      <PageHead title="My rewards" purpose="A discount on your own rentals from day one, and free rental days you earn as you work." />
      {r ? <MyRewards r={r} refresh={['/staff/rewards', '/staff']} />
        : <div className="pt-empty" data-testid="my-rewards-error"><p className="d4">My rewards did not load.</p><p className="muted">Reload the page. Nothing was changed.</p></div>}
    </>
  );
}
