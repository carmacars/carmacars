import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { requireStaff, rolesOf } from '@/server/door';
import { currentUser } from '@/server/portal/data';
import { PageHead } from '@/features/admin/ui';
import { TownhallDeck } from '@/features/townhall/Townhall';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Townhall', path: '/staff/townhall', noindex: true, description: 'The weekly staff call and its deck.' });

// 1062: the weekly townhall for every staff member (office and field).
export default async function StaffTownhall({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [me, sp] = await Promise.all([currentUser(), searchParams]);
  if (!me) redirect('/sign-in?next=/staff/townhall');
  const kind = (await rolesOf(me.id)).va ? 'va' : 'field';
  const { user } = await requireStaff(kind, '/staff/townhall');
  return (<><PageHead title="Townhall" purpose="The weekly staff call: how the week went, what changed on the platform, and what comes next." /><TownhallDeck userId={user.id} base="/staff" week={sp.week} /></>);
}
