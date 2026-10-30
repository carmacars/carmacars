import { pageMeta } from '@/features/seo/meta';
import { requireStaff } from '@/server/door';
import { SignList } from '@/features/manual/SignPages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Documents to sign', path: '/staff/sign', noindex: true, description: 'Your staff agreement, signed online.' });

export default async function VaSign() {
  const { user } = await requireStaff('va', '/staff/sign');
  return <SignList userId={user.id} base="/staff/sign" />;
}
