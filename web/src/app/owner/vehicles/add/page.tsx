import Link from '@/components/Link';
import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { Back } from '@/features/portal/Blocks';
import { PageHeader } from '@/features/portal/Chrome';
import { requireOwner } from '@/server/owner/data';
import { VinList } from '@/features/onboarding/VinList';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add cars', path: '/owner/vehicles/add', noindex: true, description: 'Add several cars at once from a list of VINs.' });

// r34 (0824): Cars > Add cars. Several cars at once from a list of VINs; one car with its photos and details is the
// application (Add a vehicle). A fleet supplier adds each car with its tier and plate.
export default async function OwnerAddCars() {
  const { home } = await requireOwner('/owner/vehicles/add');
  if (home.kind === 'partner' || home.fleet_supplier) redirect('/owner/vehicles');
  return (<>
    <Back href="/owner/vehicles">Cars</Back>
    <PageHeader title="Add cars" purpose="Several cars at once from their VINs. For one car with its photos and details, use Add a vehicle." />
    <VinList ownerId={home.owner.id} viewer="owner" refresh={['/owner/vehicles', '/owner']} done="Open each car from Cars for its photos and next steps." />
    <p className="small"><Link prefetch={false} className="link" href="/list-your-car/apply">Add one vehicle with all its details</Link></p>
  </>);
}
