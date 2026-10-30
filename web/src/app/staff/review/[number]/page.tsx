import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { storage, type Bucket } from '@/integrations/storage';
import { PhotoReview, type Shot, type Side } from '@/features/va/PhotoReview';
import { Act } from '@/features/admin/Act';
import { Card, Kv, PageHead, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Photo review', path: '/staff', noindex: true, description: 'Pickup and return photos side by side.' });

type RawSide = Omit<Side, 'photos'> & { odometer_km: number | null; fuel_pct: number | null; keys_count: number | null; reviewed_at: string | null;
  photos: Array<{ seq: number; shot: string; bucket: string; path: string }>; damages: Array<{ label: string; location: string | null; description: string | null; is_new: boolean }> };
type V = { booking_id: string; booking_number: string; status: string; vehicle: string; plate: string; shots: Shot[]; pickup: RawSide | null; return: RawSide | null; staff: Array<{ id: string; name: string }> };

// Photo review (05-va.md section 3.3; procedures 3 and 4): the sets side by side with five-minute signed
// image links, the missing shots, the re-shoot; the findings go to Finance from the return task.
export default async function Review({ params, searchParams }: { params: Promise<{ number: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ number }, sp] = await Promise.all([params, searchParams]);
  const n = decodeURIComponent(number);
  const { read } = await vaPage(`/staff/review/${n}`, ['fleet']);
  const v = await read<V | null>('photo_review', { booking: n }).catch(() => null);
  if (!v) notFound();
  const s = await storage();
  const sign = async (x: RawSide | null): Promise<Side | null> => x && ({ ...x, photos: await Promise.all(x.photos.map(async (p) => ({ seq: p.seq, shot: p.shot,
    src: await s.signedDownloadUrl(p.bucket as Bucket, p.path, 300).catch(() => null) }))) });
  const [pickup, ret] = await Promise.all([sign(v.pickup), sign(v.return)]);
  const facts = (x: RawSide | null): Array<[string, string]> => x ? [['Taken by', x.performed_by_name ?? ''], ['Completed', t(x.completed_at)], ['Odometer', x.odometer_km !== null ? `${x.odometer_km} km` : ''],
    ['Fuel', x.fuel_pct !== null ? `${x.fuel_pct}%` : ''], ['Keys', x.keys_count !== null ? String(x.keys_count) : ''], ['Damage', x.damages.map((d) => `${d.label} ${d.location ?? ''}${d.is_new ? ' (new)' : ''}`).join('; ') || 'none recorded']] : [];
  return (<>
    <PageHead kicker={<><Link prefetch={false} className="link" href="/staff/reviews">Photo reviews</Link> · <Link prefetch={false} className="link" href={`/staff/bookings/${encodeURIComponent(n)}`}>{n}</Link></>} title={`${v.vehicle} ${v.plate}`}>
      {sp.task && <Act action="task_done" payload={{ id: sp.task }} label="Review done" variant="primary" refresh={['/staff', '/staff/reviews']} go="/staff/reviews" done="Task done." />}
    </PageHead>
    <div className="ad-cols ad-cols--2">
      <Card title="Pickup">{v.pickup ? <Kv rows={facts(v.pickup)} /> : <p className="small muted">No pickup report.</p>}</Card>
      <Card title="Return">{v.return ? <Kv rows={facts(v.return)} /> : <p className="small muted">No return report yet.</p>}</Card>
    </div>
    <PhotoReview booking={v.booking_id} shots={v.shots} pickup={pickup} ret={ret} staff={v.staff} />
  </>);
}
