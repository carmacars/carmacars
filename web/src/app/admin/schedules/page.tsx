import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { StaffSchedules } from '@/features/staff-schedule/Schedules';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Schedules', path: '/admin/schedules', noindex: true, description: 'The office staff\'s schedules, who is on duty and who is late.' });

// 1502: the role schedules and each person's own, today's duty board (the same page as each staff member's Schedule).
export default async function AdminSchedules() {
  const { user } = await page('/admin/schedules');
  return (<>
    <PageHead title="Schedules" purpose="Each role's days and hours (Toronto), anyone's own schedule, and who is working, late or absent today. Lateness and the KPIs use these." />
    <StaffSchedules userId={user.id} base="/admin/schedules" />
  </>);
}
