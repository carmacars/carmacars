import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { STAFF_ONLY } from '@/server/portal-access';
import { NewPage } from '@/features/insurance/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add an insurance replacement', path: '/staff/insurance-replacements/new', noindex: true, description: 'A rental an insurer pays for: the renter, the claim, the car and the dates.' });

export default async function Page({ searchParams }: { searchParams: Promise<{ draft?: string }> }) {
  const [{ user, aal }, sp] = await Promise.all([vaPage('/staff/insurance-replacements/new', STAFF_ONLY.insurance), searchParams]);
  return <NewPage who={{ userId: user.id, aal }} base="/staff" draftId={sp.draft} />;
}
