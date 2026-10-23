import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { VehicleCard } from '@/features/owner/Blocks';
import { requireOwner } from '@/server/owner/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicles', path: '/owner/vehicles', noindex: true, description: 'Your vehicles with CarmaCars.' });

export default async function OwnerVehicles() {
  const { home } = await requireOwner('/owner/vehicles');
  return (
    <>
      <PageHeader title="Vehicles" purpose="Your cars with CarmaCars: status, terms and what each still needs. Open one for its details."
        action={<Link prefetch={false} className="btn btn--primary btn--sm" href="/list-your-car/apply">Add a vehicle</Link>} />
      {home.vehicles.length ? <ul className="ow-cars">{home.vehicles.map((v) => <VehicleCard key={v.vehicle_id} v={v} compact trackers={home.trackers_available} />)}</ul>
        : <div className="pt-empty"><p className="d4">No vehicles yet</p><Link prefetch={false} className="btn btn--primary" href="/list-your-car/apply">Add your first vehicle</Link></div>}
    </>
  );
}
