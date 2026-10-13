import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { TuroImport } from '@/features/va/TuroImport';
import { $, Card, PageHead, Table, d, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Turo trips', path: '/va/turo', noindex: true, description: 'Turo trips for the owner statements.' });
type R = Record<string, unknown>;

// Turo trips (05-va.md section 2, /va/finance/turo): entered or imported; the database takes the car's
// Revenue Share on the trip's end date and the statement month, and checks the split.
export default async function VaTuro() {
  const { read } = await vaPage('/va/turo', ['finance']);
  const v = await read<{ trips: R[]; vehicles: Array<{ id: string; name: string }> }>('turo_trips');
  const RF = ['/va/turo'];
  return (<>
    <PageHead title="Turo trips"><Act action="turo_trip_save" label="Add a trip" variant="primary" testId="turo-add" refresh={RF} done="Trip saved." fields={[
      { name: 'vehicle', label: 'Car', type: 'select', required: true, options: v.vehicles.map((x) => [x.id, x.name] as [string, string]) },
      { name: 'turo_trip_ref', label: 'Trip reference', required: true }, { name: 'starts_at', label: 'Start', type: 'datetime', required: true }, { name: 'ends_at', label: 'End', type: 'datetime', required: true },
      { name: 'gross_cents', label: 'Gross (trip price and distance fees)', type: 'money', required: true }, { name: 'turo_fees_cents', label: 'Turo fees', type: 'money', required: true },
      { name: 'company_extras_cents', label: 'Delivery and extras (stay with CarmaCars)', type: 'money' }, { name: 'damage_payment_cents', label: 'Damage payment (to the owner)', type: 'money' }]} /></PageHead>
    <Card title="Trips" testId="turo-trips">
      <Table rows={v.trips} empty="No Turo trips recorded." cols={[{ key: 'turo_trip_ref', label: 'Trip' }, { key: 'vehicle', label: 'Car', render: (r) => `${String(r.vehicle)} ${String(r.plate ?? '')}` },
        { key: 'ends_at', label: 'Ended', render: (r) => t(r.ends_at) }, { key: 'gross_cents', label: 'Gross', num: true, render: (r) => $(r.gross_cents) }, { key: 'turo_fees_cents', label: 'Turo fees', num: true, render: (r) => $(r.turo_fees_cents) },
        { key: 'revenue_share_cents', label: 'Revenue Share', num: true, render: (r) => `${$(r.revenue_share_cents)} (${Number(r.revenue_share_bps) / 100}%)` }, { key: 'owner_payout_cents', label: 'Owner', num: true, render: (r) => $(r.owner_payout_cents) },
        { key: 'statement_month', label: 'Statement', render: (r) => `${d(r.statement_month)}${r.on_statement ? ' (on statement)' : ''}` }]} />
    </Card>
    <Card title="Import from a CSV"><TuroImport /></Card>
  </>);
}
