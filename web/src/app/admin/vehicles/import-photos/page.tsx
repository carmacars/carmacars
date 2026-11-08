import { pageMeta } from '@/features/seo/meta';
import { DriveImportPage } from '@/features/drive-import/DriveImportPage';
import { adminCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Import photos from Drive', path: '/admin/vehicles/import-photos', noindex: true, description: 'Import car photos from a public Google Drive folder.' });

// Release 33 (0760): the same page as staff's (features/drive-import), read through the Admin's door.
export default async function ImportPhotos() {
  return <DriveImportPage ctx={await adminCtx('/admin/vehicles/import-photos')} />;
}
