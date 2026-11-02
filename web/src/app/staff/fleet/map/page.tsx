import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { FleetTracking } from '@/features/tracking/FleetTracking';
import type { Fleet } from '@/features/tracking/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Fleet map', path: '/staff/fleet/map', noindex: true, description: 'Every car on the map with its renter, trips and alerts.' });

// Fleet > Fleet map (r27 consolidation: Admin's Cars > Fleet tracking for the fleet role, its own menu link): the live
// panel, the alerts and the trips; the trackers and their settings stay Admin's (the database checks both).
export default async function FleetMap() {
  const { user, aal, fn } = await vaPage('/staff/fleet/map', ['fleet']);
  const f = await door<Fleet>(user.id, 'ops_read', 'tracker_fleet', { _va: fn }, aal).catch(() => null);
  const at = new Date().getTime();
  return (
    <>
      <PageHead title="Fleet map" kicker={FN_LABEL[fn]} purpose="Where every car is now, who has it, its trips and the alerts." />
      {f ? <FleetTracking initial={f} at={at} staff /> : <p className="alert alert--error" role="alert"><span>Fleet tracking could not be read. Reload the page.</span></p>}
    </>
  );
}
