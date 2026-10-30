import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { Badge, Card, Kv, PageHead, t, label } from '@/features/admin/ui';
import { taskHref, type Task } from '@/features/va/tasks';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Task', path: '/staff', noindex: true, description: 'One task: take it, do it, wait, escalate or hand it over.' });

const inHours = (h: number) => new Date(Date.now() + h * 3600_000).toISOString();
type Sheet = Task & { notes: Array<{ body: string; at: string; by: string | null }>; rule: { description: string | null; completion_rule: string | null } | null; escalation_reason?: string | null };

// The task sheet (05-va.md section 1.2).
export default async function TaskSheet({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read, list, user } = await vaPage(`/staff/tasks/${id}`);
  const [x, staff] = await Promise.all([read<Sheet | null>('task', { id }), list<{ user_id: string; full_name: string; staff_type: string }>('staff_directory', { limit: 200 })]);
  if (!x) notFound();
  const open = ['open', 'in_progress', 'waiting'].includes(x.status);
  const work = taskHref(x);
  const R = [`/staff/tasks/${id}`, '/staff'];
  return (
    <>
      <PageHead kicker={<><Link prefetch={false} className="link" href="/staff">Queue</Link> · {label(x.task_type)}{x.procedure_no ? ` · procedure ${x.procedure_no}` : ''}</>} title={<>{x.title} <Badge s={x.status} /></>}>
        {open && x.assigned_to !== user.id && <Act action="task_take" payload={{ id }} label="Take it" refresh={R} />}
        {open && <Act action="task_done" payload={{ id }} label="Done" variant="primary" fields={[{ name: 'note', label: 'Note', type: 'text' }]} refresh={R} testId="task-done" />}
        {open && <Act action="task_wait" payload={{ id }} label="Waiting" fields={[{ name: 'reason', label: 'Waiting for', type: 'text', required: true }, { name: 'until', label: 'Back in the queue at', type: 'datetime', required: true, value: inHours(4) }]} refresh={R} />}
        {open && !x.escalated && <Act action="task_escalate" payload={{ id }} label="Escalate" fields={[{ name: 'reason', label: 'Why an Admin is needed', type: 'textarea', required: true }]} refresh={R} testId="task-escalate" />}
        {open && <Act action="task_handover" payload={{ id }} label="Hand over" fields={[{ name: 'to', label: 'Colleague', type: 'select', required: true, options: staff.rows.filter((s) => s.user_id !== user.id && s.staff_type === 'va').map((s) => [s.user_id, s.full_name] as [string, string]) }]} refresh={R} />}
      </PageHead>
      <div className="ad-cols ad-cols--2">
        <Card title="The task" tone="next">
          <Kv rows={[['Due', t(x.due_at)], ['Priority', x.priority], ['Record', x.booking_number ?? x.plate ?? ''], ['Assigned to', x.assigned_to === user.id ? 'me' : (x.assignee_name ?? 'nobody')],
            ['Detail', x.detail ?? ''], ['Waiting for', x.waiting_reason ?? ''], ['Escalated', x.escalated ? 'yes' : ''], ['Done when', x.rule?.completion_rule ? label(x.rule.completion_rule) : ''], ['Procedure note', x.rule?.description ?? '']]} />
          {work !== `/staff/tasks/${id}` && <p><Link prefetch={false} className="btn btn--primary btn--sm" href={work} data-testid="task-work">Open the working screen</Link></p>}
        </Card>
        <Card title="Notes">
          {x.notes.length ? <ol className="ad-timeline">{x.notes.map((n, i) => <li key={i}><time>{t(n.at)}</time><span>{n.body} <span className="muted small">{n.by ?? ''}</span></span></li>)}</ol> : <p className="small muted">No notes yet.</p>}
          {open && <Act action="task_note" payload={{ id }} label="Add a note" inline fields={[{ name: 'body', label: 'Note', type: 'textarea', required: true }]} refresh={R} done="Note added." />}
        </Card>
      </div>
    </>
  );
}
