import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door, sessionAal } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { PermitBulk, type Filed, type PermitCar, type Waiting } from '@/features/vehicles/PermitBulk';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Ownership documents', path: '/admin/ownership-documents', noindex: true, description: 'Upload ownership permits in bulk, each filed on its car.' });

// R50 hotfix 2 (5144): many ownership permits at once, each read for its VIN and plate and filed on its car.
export default async function OwnershipDocuments() {
  const { user } = await page('/admin/ownership-documents');
  const d = await door<{ waiting: Waiting[]; filed: Filed[]; cars: PermitCar[] }>(user.id, 'ops_read', 'permit_uploads', {}, await sessionAal());
  return (<><PageHead title="Ownership documents" kicker="Each permit is read for its VIN and plate and filed on its car; the owner sees it in their portal" />
    <PermitBulk waiting={d.waiting} filed={d.filed} cars={d.cars} base="/admin" /></>);
}
