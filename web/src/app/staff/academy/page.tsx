import { pageMeta } from '@/features/seo/meta';
import { academyUser } from '@/server/academy';
import { AcademyHomePage } from '@/features/academy/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Academy', path: '/staff/academy', noindex: true, description: 'Your training path, lessons and quizzes.' });

export default async function StaffAcademy({ searchParams }: { searchParams: Promise<{ locked?: string }> }) {
  const { user } = await academyUser('/staff/academy');
  return <AcademyHomePage userId={user.id} base="/staff/academy" locked={(await searchParams).locked === '1'} />;
}
