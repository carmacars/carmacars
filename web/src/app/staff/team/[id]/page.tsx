import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { currentUser } from '@/server/portal/data';
import { requireStaff, rolesOf, sessionAal } from '@/server/door';
import { TeamMemberPage } from '@/features/team/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Team member', path: '/staff/team', noindex: true, description: 'One person of your team, read only.' });

// R51 (5302, REQ-131): one person of a manager's team; the database refuses anyone not on their team.
export default async function StaffTeamMember({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const u = await currentUser();
  const r = u ? await rolesOf(u.id).catch(() => null) : null;
  const { user, roles } = await requireStaff(r?.va ? 'va' : 'field', `/staff/team/${id}`);
  if (!roles.manager) notFound();
  return <TeamMemberPage userId={user.id} aal={await sessionAal()} id={id} />;
}
