import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { requireStaff, rolesOf } from '@/server/door';
import { currentUser } from '@/server/portal/data';
import { PageHead } from '@/features/admin/ui';
import { TownhallLive } from '@/features/calls/TownhallLive';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Townhall call', path: '/staff/townhall/live', noindex: true, description: 'The weekly staff call, in the site.' });

// r50 (5010): the place the townhall calendar invite names: the call in the site beside the deck. An Admin presents from
// the Admin portal.
export default async function StaffTownhallLive() {
  const me = await currentUser();
  if (!me) redirect('/sign-in?next=/staff/townhall/live');
  const roles = await rolesOf(me.id);
  if (roles.admin) redirect('/admin/townhall/live');
  const { user } = await requireStaff(roles.va ? 'va' : 'field', '/staff/townhall/live');
  return (<><PageHead title="Townhall call" purpose="Join with your camera on: being in the call counts your attendance by itself." /><TownhallLive userId={user.id} base="/staff" /></>);
}
