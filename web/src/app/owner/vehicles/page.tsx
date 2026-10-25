import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { VehicleCard } from '@/features/owner/Blocks';
import { ownerView, requireOwner } from '@/server/owner/data';
import { carThisMonth, upcoming } from '@/features/owner/insights';
import { rpc } from '@/lib/db/repo';
import { OwnerTermsSummary } from '@/features/owner-billing/OwnerTerms';
import type { CarTermsData } from '@/features/owner-billing/terms-shared';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicles', path: '/owner/vehicles', noindex: true, description: 'Your vehicles with CarmaCars.' });

export default async function OwnerVehicles() {
  const { user, home } = await requireOwner('/owner/vehicles');
  // each car's terms and since when (0135)
  const terms = (await rpc('server_owner_car_terms', { p_by: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as CarTermsData | null;
  const { months, live, photo, bookings } = await ownerView(user, home);
  const nextOf = (id: string) => upcoming(bookings.filter((b) => b.vehicle_id === id), new Date(), 1)[0] ?? null;
  return (
    <>
      <PageHeader title="Vehicles" purpose="Your cars with CarmaCars: where each is right now, this month so far, terms and what each still needs. Open one for its months and bookings."
        action={<Link prefetch={false} className="btn btn--primary btn--sm" href="/list-your-car/apply">Add a vehicle</Link>} />
      {home.vehicles.length ? <ul className="ow-cars">{home.vehicles.map((v) => <VehicleCard key={v.vehicle_id} v={v} compact trackers={home.trackers_available} photo={photo[v.vehicle_id]} live={live[v.vehicle_id]} month={carThisMonth(months, v.vehicle_id)} next={nextOf(v.vehicle_id)} />)}</ul>
        : <div className="pt-empty"><p className="d4">No vehicles yet</p><Link prefetch={false} className="btn btn--primary" href="/list-your-car/apply">Add your first vehicle</Link></div>}
      {terms && <OwnerTermsSummary data={terms} />}
    </>
  );
}
