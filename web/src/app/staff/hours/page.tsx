import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { MyHours } from '@/features/staff-clock/Timesheet';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My hours', path: '/staff/hours', noindex: true, description: 'Your clocked hours.' });

// 1061: the hours of a customer service, Fleet or Finance staff member, from Clock in and out on their home.
export default async function StaffHours() {
  const { user, aal } = await vaPage('/staff/hours', ['cs', 'fleet', 'finance']);
  return (<>
    <PageHead title="My hours" purpose="Clock in when you start and out when you stop, on your home page. Finance pays from these hours." />
    <MyHours userId={user.id} aal={aal} />
  </>);
}
