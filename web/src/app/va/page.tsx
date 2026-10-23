import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { Badge, Filters, MoreFilters, PageHead, Table, t, label } from '@/features/admin/ui';
import { taskHref, type Task } from '@/features/va/tasks';
import { QueueLive } from '@/features/va/QueueLive';
import { signCount } from '@/features/manual/SignPages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'To do', path: '/va', noindex: true, description: 'The assistant\'s work queue.' });

// One queue per function (05-va.md section 1.1): the open tasks, by priority then due time. Each task
// opens the screen where it is done.
export default async function Queue({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, fn, user }, sp] = await Promise.all([vaPage('/va'), searchParams]);
  const [all, toSign] = await Promise.all([read<Task[]>('queue'), signCount(user.id)]);
  const tab = sp.tab ?? 'all';
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto' }).format(new Date());
  const day = (iso: string | null) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto' }).format(new Date(iso)) : '');
  const rows = all.filter((r) => (tab === 'all' || r.bucket === tab)
    && (!sp.only || (sp.only === 'overdue' ? r.overdue : sp.only === 'escalated' ? r.escalated : sp.only === 'today' ? day(r.due_at) === today : true))
    && (!sp.type || r.task_type === sp.type));
  const types = [...new Set(all.map((r) => r.task_type))].sort();
  const count = (b: string) => all.filter((r) => r.bucket === b).length;
  return (
    <>
      <QueueLive open={all.length} />
      <PageHead title="To do" kicker={`${FN_LABEL[fn]} · ${all.length} open`} purpose="Your open tasks, most urgent first. Open a task to do it, or take one nobody has yet."><Link prefetch={false} className="btn btn--ghost btn--sm" href="/va/today">Today at a glance</Link></PageHead>
      {toSign > 0 && <p className="alert alert--warn" role="status" data-testid="va-to-sign"><span>You have {toSign === 1 ? 'a document' : `${toSign} documents`} to sign. <Link prefetch={false} className="link" href="/va/sign">Read and sign</Link></span></p>}
      <Filters base="/va" name="tab" value={tab} sp={sp} options={[['all', `All (${all.length})`], ['mine', `Mine (${count('mine')})`], ['unassigned', `Unassigned (${count('unassigned')})`], ['waiting', `Waiting (${count('waiting')})`]]} />
      <MoreFilters active={!!(sp.only || sp.type)}>
        <Filters base="/va" name="only" value={sp.only ?? ''} sp={sp} options={[['', 'Any time'], ['overdue', 'Overdue'], ['today', 'Due today'], ['escalated', 'Escalated']]} />
        {types.length > 1 && <Filters base="/va" name="type" value={sp.type ?? ''} sp={sp} options={[['', 'Every type'], ...types.map((x) => [x, label(x)] as [string, string])]} />}
      </MoreFilters>
      <Table<Task & Record<string, unknown>> testId="queue" caption="Open tasks" rows={rows as Array<Task & Record<string, unknown>>} empty={all.length ? 'No task matches these filters. Choose All to see every open task.' : 'Queue clear: nothing is waiting for you. New tasks appear here as they come in.'} cols={[
        { key: 'priority', label: 'Priority', render: (r) => <Badge s={r.priority === 'urgent' ? 'failed' : r.priority === 'high' ? 'needs_review' : 'open'}>{r.priority}</Badge> },
        { key: 'title', label: 'Task', className: 'wrap', render: (r) => <><Link prefetch={false} className="link" href={taskHref(r)} data-testid={`task-${r.task_type}`}>{r.title}</Link>{r.escalated ? <span className="ad-flag ad-flag--red">escalated</span> : null}</> },
        { key: 'record', label: 'Record', render: (r) => r.booking_number ?? r.plate ?? r.vehicle_name ?? '' },
        { key: 'due_at', label: 'Due', render: (r) => <span className={r.overdue ? 'ad-late' : undefined}>{t(r.due_at)}</span> },
        { key: 'created_at', label: 'Waiting since', render: (r) => t(r.created_at) },
        { key: 'assignee_name', label: 'Assigned to', render: (r) => r.assigned_to === user.id ? 'me' : (r.assignee_name ?? '') },
        { key: 'procedure_no', label: 'Procedure', render: (r) => r.procedure_no ? `P${r.procedure_no}` : '' },
        { key: 'act', label: 'Actions', render: (r) => <span className="ad-actions"><Link prefetch={false} className="btn btn--ghost btn--sm" href={`/va/tasks/${r.id}`}>Sheet</Link>
          {r.assigned_to !== user.id && <Act action="task_take" payload={{ id: r.id }} label="Take it" refresh={['/va']} />}</span> }]} />
    </>
  );
}
