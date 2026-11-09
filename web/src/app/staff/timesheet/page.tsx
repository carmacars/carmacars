import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { Timesheet } from '@/features/staff-clock/Timesheet';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Timesheet', path: '/staff/timesheet', noindex: true, description: 'The clocked hours of customer service, Fleet and Finance.' });

// 1061: Finance's timesheet of the office staff.
export default async function StaffTimesheet({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user, aal }, sp] = await Promise.all([vaPage('/staff/timesheet', ['finance']), searchParams]);
  return (<>
    <PageHead title="Timesheet" purpose="The hours customer service, Fleet and Finance clocked. Add hours someone forgot, or void a wrong entry, with the reason." />
    <Timesheet userId={user.id} aal={aal} from={sp.from} to={sp.to} base="/staff/timesheet" />
  </>);
}
