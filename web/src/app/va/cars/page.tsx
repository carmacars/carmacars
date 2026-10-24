import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Card, PageHead, Search, Table } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Find a car', path: '/va/cars', noindex: true, description: 'Find a car by its car code, plate, VIN or name.' });

type Found = { vehicle_id: string; car_code: string; name: string; plate: string | null; status: string; is_sample: boolean; path: string | null };

// "Find a car" (migration 0079): renters quote the car code shown on the car's page (CC-7F3A); every assistant finds the
// car by it, or by the plate, VIN or name.
export default async function FindCar({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { read, fn } = await vaPage('/va/cars');
  const opens = fn === 'fleet' || fn === 'cs';
  const q = (sp.q ?? '').trim();
  const found = q.length >= 3 ? await read<Found[]>('find_car', { q }).catch(() => [] as Found[]) : [];
  return (<>
    <PageHead title="Find a car"><Search action="/va/cars" value={q} placeholder="Car code (CC-7F3A), plate, VIN or name" /></PageHead>
    {q && q.length < 3 && <p className="small muted">Type at least 3 characters.</p>}
    {q.length >= 3 && <Card title="Cars" testId="car-matches"><Table rows={found as unknown as Array<Record<string, unknown>>} empty="No car matches." cols={[
      { key: 'car_code', label: 'Car code' }, { key: 'name', label: 'Car', render: (r) => opens ? <Link prefetch={false} className="link" href={`/va/vehicles/${String(r.vehicle_id)}`}>{String(r.name)}</Link> : String(r.name) },
      { key: 'plate', label: 'Plate' }, { key: 'status', label: 'Status', render: (r) => `${String(r.status).replace(/_/g, ' ')}${r.is_sample ? ' (example car)' : ''}` },
      { key: 'path', label: 'On the site', render: (r) => r.path ? <a className="link" href={String(r.path)}>{String(r.path)}</a> : 'Not on the site' },
      ...(fn === 'cs' || fn === 'sales' ? [{ key: 'offer', label: '', render: (r: Record<string, unknown>) => r.is_sample ? null : <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/va/offers/new?car=${String(r.vehicle_id)}`} data-testid="offer-this-car">Send an offer</Link> }] : [])]} /></Card>}
  </>);
}
