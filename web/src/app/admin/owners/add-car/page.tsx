import { pageMeta } from '@/features/seo/meta';
import { AddOwnerCarPage } from '@/features/add-owner-car-page/AddOwnerCarPage';
import { adminCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add a car for an owner', path: '/admin/owners/add-car', noindex: true, description: 'Add a car for an owner, so the owner does not fill the application.' });

// Add a car for an owner (migration 0067). r31: the same page as staff's (features/add-owner-car-page).
export default async function AddCarForOwner({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([adminCtx('/admin/owners/add-car'), searchParams]);
  return <AddOwnerCarPage ctx={ctx} sp={sp} />;
}
