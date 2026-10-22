import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { RateCardForm } from '@/features/rates/RateCardForm';
import { Card, Kv, PageHead, Table, t, label } from '@/features/admin/ui';
import { Act } from '@/features/admin/Act';
import { CarMaintenancePanel } from '@/features/maintenance/Views';
import type { CarMaintenance } from '@/features/maintenance/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicle', path: '/va', noindex: true, description: 'One vehicle for Fleet and customer service.' });

type V = Record<string, unknown> & { documents?: Array<Record<string, unknown>> };

// A vehicle as Fleet and customer service see it: the car, its status and its documents. Owner terms,
// fees and Revenue Share stay with an Admin (the database leaves them out).
export default async function VaVehicle({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ id }, sp] = await Promise.all([params, searchParams]);
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read, user, fn, aal } = await vaPage(`/va/vehicles/${id}`, ['fleet', 'cs', 'finance']);
  // Finance opens a car only for its maintenance and bills (0089)
  if (fn === 'finance') {
    const m = await door<CarMaintenance>(user.id, 'ops_read', 'maint_vehicle', { vehicle_id: id }, aal).catch(() => null);
    if (!m) notFound();
    return (<><PageHead title={m.name} kicker={m.plate ?? ''} /><CarMaintenancePanel m={m} base="/va" autoRecord={sp.record === '1'} /></>);
  }
  const v = await read<V | null>('vehicle', { id }).catch(() => null);
  if (!v?.id) notFound();
  const c = v;
  // Fleet enters the rates (0064): the form shows only to Fleet (the database refuses anyone else)
  const rates = fn === 'fleet' ? await door<{ current: Record<string, unknown> | null }>(user.id, 'ops_read', 'rate_card_form', { vehicle: id }, aal).catch(() => null) : null;
  // the car's maintenance (0089), for Fleet
  const maint = fn === 'fleet' ? await door<CarMaintenance>(user.id, 'ops_read', 'maint_vehicle', { vehicle_id: id }, aal).catch(() => null) : null;
  // the listing (0070): Publish now and what is still open, for Fleet and customer service
  const ls = await door<{ public: boolean; can_publish: boolean; can_act: boolean; path: string | null; checklist: Array<{ code: string; label: string; action: string }>; missing: Array<{ code: string; label: string; action: string }> }>(user.id, 'va_read', 'listing_state', { vehicle_id: id }, aal).catch(() => null);
  return (
    <>
      <PageHead title={`${String(c.year ?? '')} ${String(c.make ?? '')} ${String(c.model ?? '')}`} kicker={String(c.plate ?? '')} />
      <div className="ad-cols ad-cols--2">
        {ls && <Card title={ls.public ? 'On the site' : 'Not on the site yet'} testId="va-listing">
          {ls.missing.length > 0 && <ul className="small">{ls.missing.map((m) => <li key={m.code}><b>{m.label}</b>: {m.action}</li>)}</ul>}
          {ls.checklist.length > 0 && <><p className="pt-kicker">Open items (the car stays listed)</p><ul className="small">{ls.checklist.map((m) => <li key={m.code}><b>{m.label}</b>: {m.action}</li>)}</ul></>}
          {ls.can_publish && ls.can_act && <Act ops action="listing_publish_now" payload={{ vehicle_id: id }} label="Publish now" variant="primary" refresh={[`/va/vehicles/${id}`]} testId="va-publish" done="Published." />}
        </Card>}
        <Card title="Vehicle"><Kv rows={[['Plate', String(c.plate ?? '')], ['Colour', String(c.colour ?? '')], ['Status', label(c.status)], ['Odometer', c.odometer_km ? `${String(c.odometer_km)} km` : ''], ['Class', String(c.class ?? '')]]} /></Card>
        {rates && <Card title="Rates and kilometres" testId="va-rates"><p className="small muted">Rates, kilometres and deposit save together. Bookings already made keep their rates.</p>
          <RateCardForm vehicleId={id} card={rates.current} refresh={[`/va/vehicles/${id}`]} testId="va-rate-form" /></Card>}
        <Card title="Documents"><Table rows={v.documents ?? []} empty="No documents." cols={[{ key: 'title', label: 'Title' }, { key: 'kind', label: 'Kind', render: (r) => label(r.kind) }, { key: 'created_at', label: 'Added', render: (r) => t(r.created_at) }]} /></Card>
      </div>
      {maint && <><h2 className="d4 mt-h">Maintenance</h2><CarMaintenancePanel m={maint} base="/va" autoRecord={sp.record === '1'} /></>}
    </>
  );
}
