import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { VehiclePage } from '@/features/vehicle-page/VehiclePage';
import { adminCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicle', path: '/admin/vehicles', noindex: true, description: 'One vehicle: rates, fees, calendar, listing.' });

// One vehicle (03-admin.md section 8.2). r31: the same page as staff's (features/vehicle-page), read through the Admin's door.
export default async function Vehicle({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ id }, sp] = await Promise.all([params, searchParams]);
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  return <VehiclePage ctx={await adminCtx(`/admin/vehicles/${id}`)} id={id} sp={sp} />;
}
