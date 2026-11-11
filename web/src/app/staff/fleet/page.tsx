import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { redirect } from 'next/navigation';
import { door, rolesOf } from '@/server/door';
import { currentUser } from '@/server/portal/data';
import { FieldJobsBoard, type Board } from '@/features/va/FieldJobs';
import type { CalVehicle } from '@/features/va/carboard';
import { requestNow } from '@/features/va/lanes';
import { carPhotos } from '@/server/car-photos';
import { FieldCallsCard, type FieldCall } from '@/features/field-portal/FieldCalls';
import { PrepPanel, WorkListsPanel, type PrepList, type WorkLists } from '@/features/field-portal/FleetPanels';
import { OnboardingApprovals } from '@/features/staff-onboarding/Approvals';
import type { ApprovalRow } from '@/features/staff-onboarding/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Field jobs', path: '/staff/fleet', noindex: true, description: 'Field job scheduling and assignment.' });

// Fleet Operations (05-va.md section 3): every confirmed booking gets its handover and return jobs by itself, at the booking's
// times and place, given to the least busy field staff member who passed the academy and holds a shift that day (0880).
// The board is the one shared with the Admin's page (features/va/FieldJobs.tsx).
export default async function Fleet() {
  // an Admin account is only an Admin (0882): it opens the same board in the Admin portal, with every action
  const me = await currentUser();
  if (me && (await rolesOf(me.id)).admin) redirect('/admin/field-jobs');
  const { user, aal, read } = await vaPage('/staff/fleet', ['fleet']);
  const now = requestNow();
  const [b, cal, past] = await Promise.all([door<Board>(user.id, 'ops_read', 'field_board', {}, aal),
    read<{ vehicles: CalVehicle[] }>('calendar', { from: new Date(now - 86_400_000).toISOString(), to: new Date(now + 2 * 86_400_000).toISOString() }).then((c) => c.vehicles).catch(() => [] as CalVehicle[]),
    // 0910: trips still open after their return time
    door<{ rows: unknown[] }>(user.id, 'ops_read', 'past_trips', {}, aal).then((x) => x.rows.length).catch(() => 0)]);
  const photos = await carPhotos([...b.unscheduled, ...b.jobs]);
  // r35 part X (0930): each person's list of the day with its completion, and the onboarding prep
  // 1068: the live calls of field applicants who passed the AI interview, in the hour before the townhall
  const [wl, prep, calls] = await Promise.all([door<WorkLists>(user.id, 'ops_read', 'field_work_lists', {}, aal).catch(() => null), door<PrepList>(user.id, 'ops_read', 'field_prep', {}, aal).catch(() => null),
    door<FieldCall[]>(user.id, 'ops_read', 'field_call_slots', {}, aal).catch(() => [] as FieldCall[])]);
  // 1154: onboarding step 4, the staff waiting for an Admin or a Fleet VA to approve
  const approvals = await door<ApprovalRow[]>(user.id, 'ops_read', 'staff_onboarding_approvals', {}, aal).catch(() => [] as ApprovalRow[]);
  return (
    <>
      {past > 0 && <p className="alert alert--warn" role="status" data-testid="past-trips-banner"><span>{past} {past === 1 ? 'trip is' : 'trips are'} still open after the return time. <Link prefetch={false} className="link" href="/staff/past-trips">Close past trips</Link></span></p>}
      {wl && <WorkListsPanel w={wl} />}
      <FieldJobsBoard b={b} cal={cal} now={now} photos={photos} base="/staff" />
      {prep && <PrepPanel p={prep} />}
      {calls.length > 0 && <FieldCallsCard calls={calls} />}
      {approvals.length > 0 && <section className="pt-card stack" aria-labelledby="onb-appr"><h2 className="d4" id="onb-appr">Onboarding approvals</h2><OnboardingApprovals rows={approvals} refresh={['/staff/fleet']} /></section>}
    </>
  );
}
