import { pageMeta } from '@/features/seo/meta';
import { DriveImportPage } from '@/features/drive-import/DriveImportPage';
import { staffCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Import photos from Drive', path: '/staff/listings/import-photos', noindex: true, description: 'Import car photos from a public Google Drive folder.' });

// Release 33 (0760): the same page as the Admin's (features/drive-import), read through the staff door (customer service and Fleet).
export default async function VaImportPhotos() {
  return <DriveImportPage ctx={await staffCtx('/staff/listings/import-photos', ['cs', 'fleet'])} />;
}
