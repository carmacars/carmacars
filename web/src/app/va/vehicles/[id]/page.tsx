import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { RateCardForm } from '@/features/rates/RateCardForm';
import { Card, Kv, PageHead, Table, t, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicle', path: '/va', noindex: true, description: 'One vehicle for Fleet and customer service.' });

type V = Record<string, unknown> & { documents?: Array<Record<string, unknown>> };

// A vehicle as Fleet and customer service see it: the car, its status and its documents. Owner terms,
// fees and Revenue Share stay with an Admin (the database leaves them out).
export default async function VaVehicle({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read, user, fn, aal } = await vaPage(`/va/vehicles/${id}`, ['fleet', 'cs']);
  const v = await read<V | null>('vehicle', { id }).catch(() => null);
  if (!v?.id) notFound();
  const c = v;
  // Fleet enters the rates (0064): the form shows only to Fleet (the database refuses anyone else)
  const rates = fn === 'fleet' ? await door<{ current: Record<string, unknown> | null }>(user.id, 'ops_read', 'rate_card_form', { vehicle: id }, aal).catch(() => null) : null;
  return (
    <>
      <PageHead title={`${String(c.year ?? '')} ${String(c.make ?? '')} ${String(c.model ?? '')}`} kicker={String(c.plate ?? '')} />
      <div className="ad-cols ad-cols--2">
        <Card title="Vehicle"><Kv rows={[['Plate', String(c.plate ?? '')], ['Colour', String(c.colour ?? '')], ['Status', label(c.status)], ['Odometer', c.odometer_km ? `${String(c.odometer_km)} km` : ''], ['Class', String(c.class ?? '')]]} /></Card>
        {rates && <Card title="Rates and kilometres" testId="va-rates"><p className="small muted">Rates, kilometres and deposit save together. Bookings already made keep their rates.</p>
          <RateCardForm vehicleId={id} card={rates.current} refresh={[`/va/vehicles/${id}`]} testId="va-rate-form" /></Card>}
        <Card title="Documents"><Table rows={v.documents ?? []} empty="No documents." cols={[{ key: 'title', label: 'Title' }, { key: 'kind', label: 'Kind', render: (r) => label(r.kind) }, { key: 'created_at', label: 'Added', render: (r) => t(r.created_at) }]} /></Card>
      </div>
    </>
  );
}
