import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { Badge, Card, PageHead, Table, t, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Field jobs', path: '/va/fleet', noindex: true, description: 'Field job scheduling and assignment.' });

type R = Record<string, unknown>;
type Board = { staff: Array<{ id: string; name: string }>; jobs: R[]; unscheduled: R[]; expiry: R[]; documents: R[] };
const KIND: Record<string, string> = { handover: 'Handover', return_check_in: 'Return check-in' };

// Fleet Operations (05-va.md section 3): every confirmed booking gets its handover and return jobs by itself, at the
// booking's times and place, given to the least busy field staff member (0144); Fleet changes the time, the place or
// the person here. Handovers and returns with no job yet (only when automatic jobs are off or a job was cancelled), every job of the next three
// days with who has it and whether they acknowledged, the expiry watch and the vehicle documents.
export default async function Fleet() {
  const { read } = await vaPage('/va/fleet', ['fleet']);
  const b = await read<Board>('fleet_board');
  const staff = b.staff.map((s) => [s.id, s.name] as [string, string]);
  const R = ['/va/fleet'];
  const late = (j: R) => !j.acknowledged_at && j.status === 'scheduled' && new Date(String(j.scheduled_at)).getTime() - Date.now() < 2 * 3600_000;
  return (
    <>
      <PageHead title="Field jobs" kicker={`${b.unscheduled.length} without a job · ${b.jobs.filter((j) => !j.assigned_to).length} unassigned`} />
      <p className="small muted" data-testid="fleet-auto-note">Handover and return jobs are made from each confirmed booking, at its times and place, and given to the least busy field staff member. Change the time, the place or the person below.</p>
      <div className="stack">
        <Card title="Handovers and returns without a job" testId="unscheduled">
          <Table rows={b.unscheduled} rowKey={(r) => `${r.booking_id}-${r.leg}`} empty="Every handover and return has a job." cols={[
            { key: 'at', label: 'When', render: (r) => t(r.at) }, { key: 'leg', label: 'Job', render: (r) => KIND[String(r.leg)] ?? label(r.leg) },
            { key: 'booking_number', label: 'Booking', render: (r) => <Link prefetch={false} className="link" href={`/va/bookings/${encodeURIComponent(String(r.booking_number))}`}>{String(r.booking_number)}</Link> },
            { key: 'vehicle_name', label: 'Car' }, { key: 'place', label: 'Place', className: 'wrap' },
            { key: 'act', label: '', render: (r) => <Act action="field_job_create" payload={{ booking: r.booking_id, vehicle: r.vehicle_id, kind: r.leg }} label="Schedule" variant="primary" testId={`schedule-${String(r.booking_number)}-${String(r.leg)}`} fields={[
              { name: 'assigned_to', label: 'Assigned to', type: 'select', options: staff }, { name: 'scheduled_at', label: 'When', type: 'datetime', required: true, value: r.at },
              { name: 'place', label: 'Place', type: 'address', required: true, value: r.place ?? 'Our location' }, { name: 'instructions', label: 'Instructions', type: 'textarea' }]} refresh={R} done="Scheduled." /> }]} />
        </Card>
        <Card title="Jobs, next three days" testId="jobs">
          <Table rows={b.jobs} empty="No jobs." cols={[
            { key: 'scheduled_at', label: 'When', render: (r) => <span className={late(r) ? 'ad-late' : undefined}>{t(r.scheduled_at)}</span> },
            { key: 'kind', label: 'Kind', render: (r) => <>{label(r.kind)}{r.auto_created ? <span className="muted small"> · made from the booking</span> : null}</> },
            { key: 'vehicle_name', label: 'Car' }, { key: 'booking_number', label: 'Booking' }, { key: 'place', label: 'Place', className: 'wrap' },
            { key: 'assignee_name', label: 'Field staff', render: (r) => r.assignee_name ? <>{String(r.assignee_name)} {r.acknowledged_at ? <span className="muted small">acknowledged</span> : <span className="ad-flag ad-flag--red">not acknowledged</span>}</> : <span className="ad-flag ad-flag--red">nobody</span> },
            { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
            { key: 'act', label: '', render: (r) => ['done', 'cancelled'].includes(String(r.status)) ? null : <span className="ad-actions">
              <Act action="field_job_assign" payload={{ id: r.id }} label={r.assigned_to ? 'Reassign' : 'Assign'} testId={`assign-${String(r.id)}`} fields={[{ name: 'to', label: 'Field staff', type: 'select', required: true, options: staff }]} refresh={R} />
              <Act action="field_job_reschedule" payload={{ id: r.id }} label="Move" fields={[{ name: 'scheduled_at', label: 'When', type: 'datetime', required: true, value: r.scheduled_at }, { name: 'place', label: 'Place', type: 'address', value: r.place ?? '' }]} refresh={R} />
              <Act action="field_job_cancel" payload={{ id: r.id }} label="Cancel" fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={R} /></span> }]} />
        </Card>
        <Card title="Expiry watch" id="expiry"><Table rows={b.expiry} empty="Nothing expiring." cols={[{ key: 'due_at', label: 'Due', render: (r) => t(r.due_at) }, { key: 'title', label: 'What', className: 'wrap' }, { key: 'vehicle_name', label: 'Car' },
          { key: 'act', label: '', render: (r) => <Link prefetch={false} className="link" href={`/va/tasks/${String(r.id)}`}>Open</Link> }]} /></Card>
        <Card title="Vehicle documents"><Table rows={b.documents} empty="No vehicle documents." cols={[{ key: 'created_at', label: 'Added', render: (r) => t(r.created_at) }, { key: 'kind', label: 'Kind', render: (r) => label(r.kind) }, { key: 'title', label: 'Title', className: 'wrap' },
          { key: 'vehicle_name', label: 'Car', render: (r) => <Link prefetch={false} className="link" href={`/va/vehicles/${String(r.vehicle_id)}`}>{String(r.vehicle_name)}</Link> }]} /></Card>
      </div>
    </>
  );
}
