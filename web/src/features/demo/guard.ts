import 'server-only';
import { redirect } from 'next/navigation';
import { currentUser } from '@/server/portal/data';
import { rolesOf } from '@/server/door';

// r50 hotfix 2: the demo portals are for every staff member (office and field) and the Admins.
export async function demoViewer(next: string): Promise<void> {
  const user = await currentUser();
  if (!user) redirect(`/sign-in?next=${encodeURIComponent(next)}`);
  const r = await rolesOf(user.id);
  if (!(r.admin || r.va || r.field)) redirect('/staff/no-access');
}
