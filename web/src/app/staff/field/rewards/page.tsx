import { pageMeta } from '@/features/seo/meta';
import { requireStaff, sessionAal } from '@/server/door';
import { loadMyRewards, MyRewards } from '@/features/staff-rewards/MyRewards';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My rewards', path: '/staff/field/rewards', noindex: true, description: 'Your staff discount and your free rental days.' });

// My rewards (release 48, migration 3261), field staff: 1 free rental day per 100 handovers, and the discount on their own rentals.
export default async function FieldRewardsPage() {
  const { user } = await requireStaff('field', '/staff/field/rewards');
  const r = await loadMyRewards(user.id, await sessionAal());
  return (
    <>
      <header className="fp-hello"><h1>My rewards</h1><p>A discount on your own rentals, and free rental days you earn.</p></header>
      {r ? <MyRewards r={r} refresh={['/staff/field/rewards', '/staff/field']} />
        : <div className="pt-empty" data-testid="my-rewards-error"><p className="d4">My rewards did not load.</p><p className="muted">Reload the page. Nothing was changed.</p></div>}
    </>
  );
}
