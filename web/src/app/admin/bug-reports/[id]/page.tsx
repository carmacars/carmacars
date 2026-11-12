import { notFound } from 'next/navigation';
import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Card, PageHead } from '@/features/admin/ui';
import { BugDetail, STATUS_LABEL, type BugFull } from '@/features/bug-report/views';
import { updateBugReport } from '@/server/actions/bug-reports';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Bug report', path: '/admin/bug-reports', noindex: true, description: 'One bug report: what happened, pictures, browser, errors and status.' });

// Release 37 (2340): one bug report for an Admin: the description, the pictures, the browser and build, the browser's last
// errors and failed calls, the server's errors for that person and page, and the triage (status, notes, fixed in).
export default async function BugReport({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ id }, sp] = await Promise.all([params, searchParams]);
  const ctx = await page(`/admin/bug-reports/${id}`);
  const r = await door<BugFull>(ctx.user.id, 'ops_read', 'bug_reports', { id }).catch(() => null);
  if (!r) notFound();
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/bug-reports">Bug reports</Link>} title={`${r.number}: ${r.happened.slice(0, 80)}`} />
    {sp.error ? <p className="err" role="alert">{sp.error}</p> : sp.saved ? <p className="ok" role="status">Saved.</p> : null}
    <Card title="Triage" testId="bug-triage">
      <form action={updateBugReport.bind(null, r.id)} className="stack">
        <label className="field ad-field"><span>Status</span>
          <select className="input" name="status" defaultValue={r.status} data-testid="bug-status">
            {Object.entries(STATUS_LABEL).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
          </select></label>
        <label className="field ad-field"><span>Fixed in (release)</span><input className="input" name="fixed_in" maxLength={40} defaultValue={r.fixed_in ?? ''} placeholder="r37" /></label>
        <label className="field ad-field ad-field--wide"><span>Add a note</span><textarea className="input ad-textarea" name="note" rows={2} maxLength={2000} /></label>
        <p><button type="submit" className="btn btn--sm btn--primary" data-testid="bug-save">Save</button></p>
      </form>
    </Card>
    <BugDetail r={r} admin />
  </>);
}
