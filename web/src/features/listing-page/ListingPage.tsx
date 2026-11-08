import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { Act } from '@/features/admin/Act';
import { withOriginalUrls } from '@/server/listing-photos';
import { SimilarityTable, type Flag } from '@/features/admin/Similarity';
import type { CarCopyData } from '@/features/seo/CarCopyPanel';
import { ListingReview, type L, type Plates } from '@/features/admin/ListingReview';
import { Badge, Card, PageHead } from '@/features/admin/ui';
import { ListingCapture, type Capture } from '@/features/listing/ListingCapture';
import { DriveImport } from '@/features/drive-import/DriveImport';
import type { RunRow } from '@/features/drive-import/types';
import { ListingSteps, type Progress, type Steps } from '@/features/listing/ListingProgress';
import type { PageCtx } from '@/features/shared-pages/context';
import { listingCan, portalBase } from '@/features/shared-pages/viewer';

// r31 "Simple": one listing review page for Admin and staff (customer service and Fleet). The same steps, capture,
// similar cars and review; an Admin also retries a failed listing, unlists a published one and sees the sample photos
// note; Fleet links to the car and its rates.
export async function ListingPage({ ctx, id }: { ctx: PageCtx; id: string }) {
  const { viewer, read, ops } = ctx;
  const can = listingCan(viewer);
  if (!can) notFound();
  const portal = portalBase(viewer);
  const base = `${portal}/listings/${id}`;
  const l = await read<L | null>('listing', { id });
  if (!l) notFound();
  // possible duplicates of this car (migration 0040): an open flag that stops publishing is decided here first
  const flags = await read<Flag[]>('vehicle_similarity', { vehicle: l.vehicle_id }).catch(() => [] as Flag[]);
  const [cap, prog, plates, steps, samples, copy, driveRuns] = await Promise.all([ops<Capture>('listing_capture', { intake: id }), ops<Record<string, Progress>>('listing_progress', { intake: id }),
    ops<Plates>('listing_plates', { vehicle: l.vehicle_id }).catch(() => null), ops<Steps>('listing_steps', { intake: id }).catch(() => null),
    can.samplesNote ? ops<Array<{ vehicle_id: string }>>('vehicles_using_samples').catch(() => []) : [],
    ops<CarCopyData>('car_copy', { vehicle: l.vehicle_id }).catch(() => null),
    ops<RunRow[]>('drive_import_list', { vehicle: l.vehicle_id }).catch(() => [] as RunRow[])]);
  const usingSamples = (samples ?? []).some((x) => x.vehicle_id === l.vehicle_id);
  return (
    <>
      <PageHead kicker={<><Link prefetch={false} className="link" href={`${portal}/listings`}>Listings</Link>{can.carLink && <> · <Link prefetch={false} className="link" href={`${portal}/vehicles/${l.vehicle_id}${can.admin ? '' : '?tab=rates'}`} data-testid={can.admin ? undefined : 'va-listing-car'}>{can.admin ? l.vehicle.plate : 'The car and its rates'}</Link></>}</>}
        title={<>{l.vehicle.name} <Badge s={l.state} /></>}>
        {can.admin && ['failed'].includes(l.state) && <Act action="listing_retry" payload={{ intake: l.id }} label="Retry" />}
        {can.admin && l.listing?.status === 'published' && <Act action="listing_unlist" payload={{ vehicle: l.vehicle_id }} label="Unlist" variant="danger" fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }, { name: 'to_path', label: 'Redirect to (empty: the model page or 410)', type: 'text' }]} />}
      </PageHead>
      {l.reason && <p className="pt-note small">{l.reason}</p>}
      {usingSamples && <p className="alert alert--warn" role="note" data-testid="listing-using-samples-note"><span className="alert__title">Using sample photos</span><span>No real photo is approved yet, so the listing shows sample photos, marked &quot;Sample photo&quot; on the site. You can publish it as it is: the photo problems below apply once real photos are added. The licence plate check does not apply to sample photos.</span></p>}
      {steps && <ListingSteps initial={steps} progress={prog[id] ?? null} canReview hasCapture={!['published', 'cancelled'].includes(l.state)} refresh={[base]} />}
      {!['published', 'cancelled'].includes(l.state) && <ListingCapture initial={cap} refresh={[base]} />}
      {/* r33 (0760): the car's photos from a public Google Drive folder, through the same upload */}
      {!['published', 'cancelled'].includes(l.state) && <DriveImport vehicle={{ id: l.vehicle_id, label: l.vehicle.name }} runs={driveRuns} refresh={[base]} />}
      {flags.length > 0 && <Card title="Similar cars on file" testId="listing-similar"><SimilarityTable rows={flags} base={portal} refresh={[base]} showVehicle={false} /></Card>}
      <ListingReview l={await withOriginalUrls(l)} plates={plates} exterior={cap.shots.filter((x) => x.rebackground).map((x) => x.code)} copy={copy} />
    </>
  );
}
