import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { Back } from '@/features/portal/Blocks';
import { requireOwner } from '@/server/owner/data';
import { OwnerReview, type ReviewData } from '@/features/owner-billing/OwnerReview';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Review your details', path: '/owner/review', noindex: true, description: 'Check and correct your details and your car before you sign.' });

// What CarmaCars entered for the owner, to check and correct before signing (migration 0067).
export default async function OwnerReviewPage() {
  const { user, home } = await requireOwner('/owner/review');
  const data = (await rpc('server_owner_review', { p_by: user.id }, { role: 'service_role' })) as unknown as ReviewData;
  return (
    <>
      <Back href="/owner">Owner portal</Back>
      <header className="stack"><p className="pt-kicker">Before you sign</p><h1 className="d2">Review your details</h1>
        <p className="muted">Your agreements are filled in from these. Correct anything that is wrong, then sign.</p></header>
      <OwnerReview data={data} trackers={home.trackers_available} />
    </>
  );
}
