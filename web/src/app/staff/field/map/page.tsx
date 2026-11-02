import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff, sessionAal } from '@/server/door';
import { FleetTracking } from '@/features/tracking/FleetTracking';
import type { Fleet } from '@/features/tracking/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Map', path: '/staff/field/map', noindex: true, description: 'The cars of your jobs on the map.' });

// Field work > Map (r27 consolidation: Admin's fleet tracking map for field staff): only the cars of their own jobs from
// two days back to three days ahead, with their alerts and trips (migration 0500 narrows the read).
export default async function FieldMap() {
  const { user } = await requireStaff('field', '/staff/field/map');
  const f = await door<Fleet>(user.id, 'ops_read', 'tracker_fleet', {}, await sessionAal()).catch(() => null);
  const at = new Date().getTime();
  return (
    <>
      <header className="fd-home"><h1 className="fd-home__h">Map</h1><p className="fd-home__sub">The cars of your jobs, where they are now.</p></header>
      {f ? <FleetTracking initial={f} at={at} staff="field" /> : <p className="alert alert--error" role="alert"><span>The map could not be read. Reload the page.</span></p>}
    </>
  );
}
