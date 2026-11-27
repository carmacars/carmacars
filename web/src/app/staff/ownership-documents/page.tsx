import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { PermitBulk, type Filed, type PermitCar, type Waiting } from '@/features/vehicles/PermitBulk';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Ownership documents', path: '/staff/ownership-documents', noindex: true, description: 'Upload ownership permits in bulk, each filed on its car.' });

// R50 hotfix 2 (5144): Admin's Ownership documents for Fleet and customer service.
export default async function StaffOwnershipDocuments() {
  const { user, aal } = await vaPage('/staff/ownership-documents', ['fleet', 'cs']);
  const d = await door<{ waiting: Waiting[]; filed: Filed[]; cars: PermitCar[] }>(user.id, 'ops_read', 'permit_uploads', {}, aal);
  return (<><PageHead title="Ownership documents" purpose="Upload the ownership permits of many cars at once. Each is read for its VIN and plate and filed on its car; pick the car for any that did not match." />
    <PermitBulk waiting={d.waiting} filed={d.filed} cars={d.cars} base="/staff" /></>);
}
