import { pageMeta } from '@/features/seo/meta';
import { requireStaff } from '@/server/door';
import { SignList } from '@/features/manual/SignPages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Documents to sign', path: '/va/sign', noindex: true, description: 'Your staff agreement, signed online.' });

export default async function VaSign() {
  const { user } = await requireStaff('va', '/va/sign');
  return <SignList userId={user.id} base="/va/sign" />;
}
