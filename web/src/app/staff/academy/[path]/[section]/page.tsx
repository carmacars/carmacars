import { pageMeta } from '@/features/seo/meta';
import { academyUser } from '@/server/academy';
import { AcademySectionPage } from '@/features/academy/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Academy section', path: '/staff/academy', noindex: true, description: 'Lessons and the quiz of a section.' });

export default async function StaffAcademySection({ params }: { params: Promise<{ path: string; section: string }> }) {
  const { path, section } = await params;
  const { user } = await academyUser(`/staff/academy/${path}/${section}`);
  return <AcademySectionPage userId={user.id} base="/staff/academy" path={path} section={section} />;
}
