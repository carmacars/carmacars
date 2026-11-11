import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { Payroll } from '@/features/payroll/Payroll';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Payroll', path: '/staff/payroll', noindex: true, description: 'Prepare the two-week payroll for an Admin\'s approval.' });

// 1503: Finance prepares the payroll (start, refresh, bonuses and deductions, Send for approval); an Admin approves and pays.
export default async function StaffPayroll({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user, aal }, sp] = await Promise.all([vaPage('/staff/payroll', ['finance']), searchParams]);
  return (<>
    <PageHead title="Payroll" purpose="Every two weeks: start the payroll once the period has ended, check each line against the timesheet, add any bonus or deduction with its reason, then Send for approval. An Admin approves it and records the payments." />
    <Payroll userId={user.id} aal={aal} base="/staff/payroll" date={sp.date} />
  </>);
}
