import { pageMeta } from '@/features/seo/meta';
import { requireStaff } from '@/server/door';
import { SignList } from '@/features/manual/SignPages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Documents to sign', path: '/staff/field/sign', noindex: true, description: 'Your staff agreement, signed online.' });

export default async function FieldSign() {
  const { user } = await requireStaff('field', '/staff/field/sign');
  return <SignList userId={user.id} base="/staff/field/sign" />;
}
