import { redirect } from 'next/navigation';
import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, requireStaff, sessionAal } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { BugDetail, BugTable, type BugFull, type BugList } from '@/features/bug-report/views';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My bug reports', path: '/staff/bug-reports', noindex: true, description: 'The bugs you reported and what happened to them.' });

// Release 37 (2340): the bugs this staff member reported ("Report a bug" at the top of every page) and their status:
// new, being looked at, fixed (with the release) or won't fix. Office and field staff alike.
export default async function MyBugReports({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const me = await currentUser();
  if (!me) redirect('/sign-in?next=/staff/bug-reports');
  const roles = await rolesOf(me.id);
  const { user } = await requireStaff(roles.va ? 'va' : 'field', '/staff/bug-reports');
  const aal = await sessionAal();
  const one = sp.id ? await door<BugFull>(user.id, 'ops_read', 'bug_reports', { id: sp.id }, aal).catch(() => null) : null;
  if (one) return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/staff/bug-reports">My bug reports</Link>} title={`${one.number}: ${one.happened.slice(0, 80)}`} />
    <BugDetail r={one} admin={false} />
  </>);
  const data = await door<BugList>(user.id, 'ops_read', 'bug_reports', {}, aal).catch(() => ({ reports: [], counts: { new: 0, triaged: 0, fixed: 0, wont_fix: 0 } }) as BugList);
  return (<>
    <PageHead title="My bug reports" purpose='Something not working? Press "Report a bug" at the top of any page: a picture of the page and its errors go with your words. Here you see what happened to each report.' />
    <BugTable rows={data.reports} href={(r) => `/staff/bug-reports?id=${r.id}`} who={false} />
  </>);
}
