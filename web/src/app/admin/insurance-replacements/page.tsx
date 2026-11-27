import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { sessionAal } from '@/server/door';
import { ListPage } from '@/features/insurance/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Insurance replacements', path: '/admin/insurance-replacements', noindex: true, description: 'Every rental an insurer pays for: claims, invoices and their versions, payments and aging.' });

// Money > Insurers > Replacements (5120)
export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [{ user }, sp, aal] = await Promise.all([page('/admin/insurance-replacements'), searchParams, sessionAal()]);
  return <ListPage who={{ userId: user.id, aal }} base="/admin" sp={sp} />;
}
