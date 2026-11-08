import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { PageHead } from '@/features/admin/ui';
import { DriveImport } from '@/features/drive-import/DriveImport';
import type { RunRow } from '@/features/drive-import/types';
import type { PageCtx } from '@/features/shared-pages/context';
import { listingCan, portalBase } from '@/features/shared-pages/viewer';

// Cars > Import photos from Drive (release 33, migration 0760): one page for Admin and for Fleet and customer service staff.
// Paste the link of a public Drive folder (a top folder, one folder per make, then per car): each folder with photos is matched
// to a car on the platform, the table is confirmed here, and the photos go through the listing upload as staff uploads do.
export async function DriveImportPage({ ctx }: { ctx: PageCtx }) {
  if (!listingCan(ctx.viewer)) notFound();
  const portal = portalBase(ctx.viewer);
  const runs = await ctx.ops<RunRow[]>('drive_import_list', { vehicle: null }).catch(() => [] as RunRow[]);
  return (
    <>
      <PageHead title="Import photos from Drive"
        kicker={<><Link prefetch={false} className="link" href={`${portal}/listings`}>Listings</Link></>}
        purpose="Paste a public Google Drive folder link. Each car's folder is matched to a car on the platform; confirm the table, and the photos are added to each car's listing." />
      <DriveImport runs={runs} refresh={[`${portal}/listings`]} />
    </>
  );
}
