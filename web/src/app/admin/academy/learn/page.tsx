import { pageMeta } from '@/features/seo/meta';
import { requireAdmin } from '@/server/admin/data';
import { AcademyHomePage } from '@/features/academy/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Academy: my path', path: '/admin/academy/learn', noindex: true, description: 'The Admin path of the academy.' });

export default async function AdminAcademyLearn() {
  const { user } = await requireAdmin('/admin/academy/learn');
  return <AcademyHomePage userId={user.id} base="/admin/academy/learn" />;
}
