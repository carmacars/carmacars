import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { FleetMaintenance } from '@/features/maintenance/Views';
import type { Overview } from '@/features/maintenance/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Maintenance', path: '/staff/maintenance', noindex: true, description: 'Every car\'s service status for Fleet.' });

// Fleet's maintenance overview (migration 0089): the same as the Admin's, for Fleet (and Finance, who bills).
export default async function VaMaintenance({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user, aal }, sp] = await Promise.all([vaPage('/staff/maintenance', ['fleet', 'finance']), searchParams]);
  const data = await door<Overview>(user.id, 'ops_read', 'maint_overview', {}, aal);
  return (
    <>
      <PageHead title="Maintenance" kicker={`${data.cars.length} cars tracked`} />
      <FleetMaintenance data={data} base="/staff" sp={sp} />
    </>
  );
}
