import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { VehiclePage } from '@/features/vehicle-page/VehiclePage';
import { staffCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicle', path: '/staff', noindex: true, description: 'One vehicle for Fleet and customer service.' });

// A vehicle as Fleet, customer service and Finance see it. r31: the same page as the Admin's (features/vehicle-page),
// read through the staff door in the page's function.
export default async function VaVehicle({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ id }, sp] = await Promise.all([params, searchParams]);
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  return <VehiclePage ctx={await staffCtx(`/staff/vehicles/${id}`, ['fleet', 'cs', 'finance'])} id={id} sp={sp} />;
}
