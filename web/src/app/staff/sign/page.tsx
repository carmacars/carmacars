import { pageMeta } from '@/features/seo/meta';
import { redirect } from 'next/navigation';
import { requireStaff, rolesOf } from '@/server/door';
import { currentUser } from '@/server/portal/data';
import { SignList } from '@/features/manual/SignPages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Documents to sign', path: '/staff/sign', noindex: true, description: 'Your staff agreement, signed online.' });

export default async function VaSign() {
  // r48 FE (3196): one agreement whatever the portal: a person with field work only signs on the other sign page (Sales and Field: either)
  const u = await currentUser();
  const r = u ? await rolesOf(u.id).catch(() => null) : null;
  if (r && r.field && !r.va) redirect('/staff/field/sign');
  const { user } = await requireStaff('va', '/staff/sign');
  return <SignList userId={user.id} base="/staff/sign" />;
}
