import { pageMeta } from '@/features/seo/meta';
import { requireAdmin } from '@/server/admin/data';
import { AcademySectionPage } from '@/features/academy/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Academy section', path: '/admin/academy/learn', noindex: true, description: 'Lessons and the quiz of a section.' });

export default async function AdminAcademySection({ params }: { params: Promise<{ path: string; section: string }> }) {
  const { path, section } = await params;
  const { user } = await requireAdmin(`/admin/academy/learn/${path}/${section}`);
  return <AcademySectionPage userId={user.id} base="/admin/academy/learn" path={path} section={section} />;
}
