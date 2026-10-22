import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { FleetMaintenance } from '@/features/maintenance/Views';
import type { Overview } from '@/features/maintenance/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Maintenance', path: '/admin/maintenance', noindex: true, description: 'Every car\'s service status: oil, brakes, tires, inspections, registration.' });

// The fleet maintenance overview (migration 0089): every real car, most urgent first, with its status chips, filters and
// the one-step record pop-up. The To do lines and the Fleet tasks open it.
export default async function Maintenance({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/maintenance'), searchParams]);
  const data = await door<Overview>(user.id, 'ops_read', 'maint_overview');
  return (
    <>
      <PageHead title="Maintenance" kicker={`${data.cars.length} cars tracked`}>
        {data.can_settings && <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/settings/maintenance">Intervals and reminders</Link>}
      </PageHead>
      <FleetMaintenance data={data} base="/admin" sp={sp} />
    </>
  );
}
