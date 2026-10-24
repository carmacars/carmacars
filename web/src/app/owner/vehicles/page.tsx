import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { VehicleCard } from '@/features/owner/Blocks';
import { requireOwner } from '@/server/owner/data';
import { rpc } from '@/lib/db/repo';
import { OwnerTermsSummary } from '@/features/owner-billing/OwnerTerms';
import type { CarTermsData } from '@/features/owner-billing/terms-shared';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicles', path: '/owner/vehicles', noindex: true, description: 'Your vehicles with CarmaCars.' });

export default async function OwnerVehicles() {
  const { user, home } = await requireOwner('/owner/vehicles');
  // each car's terms and since when (0135)
  const terms = (await rpc('server_owner_car_terms', { p_by: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as CarTermsData | null;
  return (
    <>
      <PageHeader title="Vehicles" purpose="Your cars with CarmaCars: status, terms and what each still needs. Open one for its details."
        action={<Link prefetch={false} className="btn btn--primary btn--sm" href="/list-your-car/apply">Add a vehicle</Link>} />
      {home.vehicles.length ? <ul className="ow-cars">{home.vehicles.map((v) => <VehicleCard key={v.vehicle_id} v={v} compact trackers={home.trackers_available} />)}</ul>
        : <div className="pt-empty"><p className="d4">No vehicles yet</p><Link prefetch={false} className="btn btn--primary" href="/list-your-car/apply">Add your first vehicle</Link></div>}
      {terms && <OwnerTermsSummary data={terms} />}
    </>
  );
}
