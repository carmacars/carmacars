import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { sessionAal } from '@/server/door';
import { NewPage } from '@/features/insurance/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add an insurance replacement', path: '/admin/insurance-replacements/new', noindex: true, description: 'A rental an insurer pays for: the renter, the claim, the car and the dates.' });

export default async function Page({ searchParams }: { searchParams: Promise<{ draft?: string }> }) {
  const [{ user }, sp, aal] = await Promise.all([page('/admin/insurance-replacements/new'), searchParams, sessionAal()]);
  return <NewPage who={{ userId: user.id, aal }} base="/admin" draftId={sp.draft} />;
}
