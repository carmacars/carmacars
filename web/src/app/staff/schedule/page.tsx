import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { StaffSchedules } from '@/features/staff-schedule/Schedules';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Schedule', path: '/staff/schedule', noindex: true, description: 'Your schedule and who is on duty today.' });

// 1502: the staff member's schedule and week, the role schedules, and today's duty board.
export default async function StaffSchedule() {
  const { user, aal } = await vaPage('/staff/schedule', ['cs', 'fleet', 'finance', 'sales']);
  return (<>
    <PageHead title="Schedule" purpose="Your days and hours (Toronto) and who is working today. Breaks are at your discretion." />
    <StaffSchedules userId={user.id} aal={aal} base="/staff/schedule" />
  </>);
}
