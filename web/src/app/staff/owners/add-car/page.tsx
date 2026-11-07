import { pageMeta } from '@/features/seo/meta';
import { AddOwnerCarPage } from '@/features/add-owner-car-page/AddOwnerCarPage';
import { staffCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add a car for an owner', path: '/staff/owners/add-car', noindex: true, description: 'Add a car for an owner.' });

// Customer service, Fleet and Sales add a car for an owner (0067, 0340). r31: the same page as the Admin's.
export default async function VaAddCar({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([staffCtx('/staff/owners/add-car', ['cs', 'fleet', 'sales']), searchParams]);
  return <AddOwnerCarPage ctx={ctx} sp={sp} />;
}
