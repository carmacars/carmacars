import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import Link from 'next/link';
import { Act } from '@/features/admin/Act';
import { adminTaskHref } from '@/features/va/tasks';
import { Badge, BookingLink, Filters, PageHead, Table, t, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Tasks', path: '/admin/tasks', noindex: true, description: 'Every queue.' });
type R = Record<string, unknown>;
const inADay = () => new Date(Date.now() + 86_400_000).toISOString();

// Tasks in every queue: assign, snooze, complete, escalate, and each one's link to where its work is done (0078).
export default async function Tasks({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ list, user }, sp] = await Promise.all([page('/admin/tasks'), searchParams]);
  const eq: Record<string, unknown> = { status: sp.status === 'done' ? ['done', 'cancelled'] : ['open', 'in_progress', 'waiting'] };
  if (sp.queue) eq.queue = sp.queue;
  if (sp.mine) eq.assigned_to = user.id;
  const { rows, count } = await list('tasks', { eq, order: 'due_at', asc: true, limit: 300 });
  const R = ['/admin/tasks'];
  const tomorrow = inADay();
  return (<>
    <PageHead title="Tasks" kicker={`${count} shown`} />
    <Filters base="/admin/tasks" name="queue" value={sp.queue ?? ''} sp={sp} options={[['', 'All queues'], ['admin', 'Admin'], ['cs', 'Customer service'], ['sales', 'Sales'], ['fleet', 'Fleet'], ['finance', 'Finance']]} />
    <Filters base="/admin/tasks" name="status" value={sp.status ?? ''} sp={sp} options={[['', 'Open'], ['done', 'Done']]} />
    <Table<R> testId="tasks" rows={rows} empty="No open tasks. Tasks the system raises (and the ones you add) show up here by queue." cols={[{ key: 'due_at', label: 'Due', render: (r) => <span className={typeof r.due_at === 'string' && new Date(r.due_at) < new Date() ? 'ad-late' : undefined}>{t(r.due_at)}</span> },
      { key: 'priority', label: 'Priority', render: (r) => <Badge s={r.priority === 'urgent' ? 'failed' : 'open'}>{String(r.priority)}</Badge> }, { key: 'queue', label: 'Queue' }, { key: 'title', label: 'Task', className: 'wrap', render: (r) => <>{String(r.title)}{r.escalated ? <span className="ad-flag ad-flag--red">escalated</span> : null}{r.detail ? <span className="ad-sub muted small"> {String(r.detail)}</span> : null}</> },
      { key: 'booking_number', label: 'Booking', render: (r) => r.booking_number ? <BookingLink n={r.booking_number} /> : null },
      { key: 'go', label: 'Where', render: (r) => { const href = adminTaskHref({ task_type: String(r.task_type ?? ''), booking_number: (r.booking_number as string | null) ?? null, vehicle_id: (r.vehicle_id as string | null) ?? null,
          related_table: (r.related_table as string | null) ?? null, related_id: (r.related_id as string | null) ?? null, owner_id: (r.owner_id as string | null) ?? null });
        return href === '/admin/tasks' ? null : <Link prefetch={false} className="link" href={href} data-testid="task-go">Open</Link>; } }, { key: 'assignee_name', label: 'Assigned' }, { key: 'status', label: 'Status', render: (r) => label(r.status) },
      { key: 'act', label: 'Actions', render: (r) => ['done', 'cancelled'].includes(String(r.status)) ? null : <span className="ad-actions">
        <Act action="task_assign" payload={{ id: r.id }} label="Mine" refresh={R} />
        <Act action="task_snooze" payload={{ id: r.id }} label="Snooze" fields={[{ name: 'until', label: 'Until', type: 'datetime', required: true, value: tomorrow }, { name: 'reason', label: 'Reason' }]} refresh={R} />
        <Act action="task_complete" payload={{ id: r.id }} label="Done" variant="primary" fields={[{ name: 'note', label: 'Note' }]} refresh={R} />
        {!r.escalated && <Act action="task_escalate" payload={{ id: r.id }} label="Escalate" fields={[{ name: 'reason', label: 'Reason', required: true }]} refresh={R} />}</span> }]} />
  </>);
}
