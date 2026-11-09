import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { Timesheet } from '@/features/staff-clock/Timesheet';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Timesheet', path: '/admin/timesheet', noindex: true, description: 'The clocked hours of customer service, Fleet and Finance.' });

// 1061: the office staff's clocked hours (the same page as Finance's).
export default async function AdminTimesheet({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/timesheet'), searchParams]);
  return (<>
    <PageHead title="Timesheet" purpose="The hours customer service, Fleet and Finance clocked. Add hours someone forgot, or void a wrong entry, with the reason." />
    <Timesheet userId={user.id} from={sp.from} to={sp.to} base="/admin/timesheet" />
  </>);
}
