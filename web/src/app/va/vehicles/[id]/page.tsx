import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Card, Kv, PageHead, Table, t, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicle', path: '/va', noindex: true, description: 'One vehicle for Fleet and customer service.' });

type V = Record<string, unknown> & { documents?: Array<Record<string, unknown>> };

// A vehicle as Fleet and customer service see it: the car, its status and its documents. Owner terms,
// fees and Revenue Share stay with an Admin (the database leaves them out).
export default async function VaVehicle({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read } = await vaPage(`/va/vehicles/${id}`, ['fleet', 'cs']);
  const v = await read<V | null>('vehicle', { id }).catch(() => null);
  if (!v?.id) notFound();
  const c = v;
  return (
    <>
      <PageHead title={`${String(c.year ?? '')} ${String(c.make ?? '')} ${String(c.model ?? '')}`} kicker={String(c.plate ?? '')} />
      <div className="ad-cols ad-cols--2">
        <Card title="Vehicle"><Kv rows={[['Plate', String(c.plate ?? '')], ['Colour', String(c.colour ?? '')], ['Status', label(c.status)], ['Odometer', c.odometer_km ? `${String(c.odometer_km)} km` : ''], ['Class', String(c.class ?? '')]]} /></Card>
        <Card title="Documents"><Table rows={v.documents ?? []} empty="No documents." cols={[{ key: 'title', label: 'Title' }, { key: 'kind', label: 'Kind', render: (r) => label(r.kind) }, { key: 'created_at', label: 'Added', render: (r) => t(r.created_at) }]} /></Card>
      </div>
    </>
  );
}
