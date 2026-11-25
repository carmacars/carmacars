import { redirect } from 'next/navigation';
import { rolesOf } from '@/server/door';
import { currentUser } from '@/server/portal/data';

export const dynamic = 'force-dynamic';

// r50 (5000): the place the townhall calendar invite names. Until the in-site call (release 50, part 2), the townhall page
// with its Join button; an Admin lands on the Admin townhall.
export default async function TownhallLive() {
  const me = await currentUser();
  if (!me) redirect('/sign-in?next=/staff/townhall/live');
  redirect((await rolesOf(me.id)).admin ? '/admin/townhall' : '/staff/townhall');
}
