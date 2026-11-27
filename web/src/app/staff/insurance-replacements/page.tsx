import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { STAFF_ONLY } from '@/server/portal-access';
import { ListPage } from '@/features/insurance/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Insurance replacements', path: '/staff/insurance-replacements', noindex: true, description: 'Every rental an insurer pays for: claims, invoices and their versions, payments and aging.' });

// Finance and customer service (5120; app/admin/insurance-replacements is the Admin's)
export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [{ user, aal }, sp] = await Promise.all([vaPage('/staff/insurance-replacements', STAFF_ONLY.insurance), searchParams]);
  return <ListPage who={{ userId: user.id, aal }} base="/staff" sp={sp} />;
}
