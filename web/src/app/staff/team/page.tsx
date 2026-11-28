import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { currentUser } from '@/server/portal/data';
import { requireStaff, rolesOf, sessionAal } from '@/server/door';
import { TeamPage } from '@/features/team/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My team', path: '/staff/team', noindex: true, description: 'The staff assigned to you, read only.' });

// R51 (5201, REQ-131): a manager's team (office or field staff); the database refuses anyone who is not a manager.
export default async function StaffTeam() {
  const u = await currentUser();
  const r = u ? await rolesOf(u.id).catch(() => null) : null;
  const { user, roles } = await requireStaff(r?.va ? 'va' : 'field', '/staff/team');
  if (!roles.manager) notFound();
  return <TeamPage userId={user.id} aal={await sessionAal()} />;
}
