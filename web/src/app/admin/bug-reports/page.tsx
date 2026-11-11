import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Filters, PageHead } from '@/features/admin/ui';
import { BugTable, type BugList } from '@/features/bug-report/views';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Bug reports', path: '/admin/bug-reports', noindex: true, description: 'Bugs reported by staff, with their pictures, browser and errors.' });

const STATUSES: Array<[string, string]> = [['open', 'Open'], ['new', 'New'], ['triaged', 'Being looked at'], ['fixed', 'Fixed'], ['wont_fix', 'Won\'t fix'], ['all', 'All']];

// Release 37 (2340): Settings > Bug reports. Every report from staff and Admins ("Report a bug" in each portal's frame),
// newest first; open ones by default. Claude reads the same through the connector (bug_reports_list, bug_report_get).
export default async function BugReports({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([page('/admin/bug-reports'), searchParams]);
  const status = STATUSES.some(([k]) => k === sp.status) ? sp.status! : 'open';
  const mine = sp.mine === '1';
  const data = await door<BugList>(ctx.user.id, 'ops_read', 'bug_reports', { status: status === 'all' ? null : status, mine }).catch(() => ({ reports: [], counts: { new: 0, triaged: 0, fixed: 0, wont_fix: 0 } }) as BugList);
  return (<>
    <PageHead title="Bug reports" purpose={`Bugs staff reported with "Report a bug": each with a picture of the page, the browser and its last errors. ${data.counts.new} new, ${data.counts.triaged} being looked at.`} />
    <Filters base="/admin/bug-reports" name="status" value={status} options={STATUSES} sp={sp} />
    <Filters base="/admin/bug-reports" name="mine" value={mine ? '1' : ''} options={[['', 'Everyone'], ['1', 'Mine']]} sp={sp} />
    <BugTable rows={data.reports} href={(r) => `/admin/bug-reports/${r.id}`} who />
  </>);
}
