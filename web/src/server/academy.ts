import 'server-only';
import { notFound, redirect } from 'next/navigation';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import type { PathRow, SectionView } from '@/features/academy/model';

// The academy's reads (0207): the person's paths and a section to study. Staff (office or field) at /staff/academy; Admins
// take the Admin path at /admin/academy/learn.
export async function academyUser(next: string, admin = false) {
  const user = await currentUser();
  if (!user) redirect(`/sign-in?next=${encodeURIComponent(next)}`);
  const roles = await rolesOf(user.id);
  if (admin ? !roles.admin : !(roles.va || roles.field)) redirect(admin ? '/admin/no-access' : roles.admin ? '/admin/academy/learn' : '/staff/no-access');
  const aal = await sessionAal();
  if (roles.two_step_required && aal !== 'aal2') redirect(`/two-step?next=${encodeURIComponent(next)}`);
  return { user, roles, aal };
}
export async function academyHome(userId: string) {
  return door<{ paths: PathRow[]; gate: boolean; locked: boolean; pass_bps: number }>(userId, 'ops_read', 'academy_home');
}
export async function academySection(userId: string, path: string, section: string): Promise<SectionView | { closed: string }> {
  try { return await door<SectionView>(userId, 'ops_read', 'academy_section', { path, section }); }
  catch (e) {
    const m = (e as Error).message ?? '';
    if (/No such section/.test(m)) notFound();
    if (/Pass the section|not one of yours/.test(m)) return { closed: m };
    throw e;
  }
}
