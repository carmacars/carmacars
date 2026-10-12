import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { VehicleCard } from '@/features/owner/Blocks';
import { requireOwner } from '@/server/owner/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicles', path: '/owner/vehicles', noindex: true, description: 'Your vehicles with CarmaCars.' });

export default async function OwnerVehicles() {
  const { home } = await requireOwner('/owner/vehicles');
  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}><h1 className="d2">Vehicles</h1><Link className="btn btn--primary btn--sm" href="/list-your-car/apply">Add a vehicle</Link></div>
      {home.vehicles.length ? <ul className="ow-cars">{home.vehicles.map((v) => <VehicleCard key={v.vehicle_id} v={v} compact trackers={home.trackers_available} />)}</ul>
        : <div className="pt-empty"><p className="d4">No vehicles yet</p><Link className="btn btn--primary" href="/list-your-car/apply">Add your first vehicle</Link></div>}
    </>
  );
}
