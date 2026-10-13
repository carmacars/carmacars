import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Card, Kv, PageHead, Table, t, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Incident', path: '/admin/incidents', noindex: true, description: 'One incident.' });

export default async function Incident({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { list } = await page(`/admin/incidents/${id}`);
  const [inc, claims] = await Promise.all([list('incidents', { eq: { id } }), list('claims', { eq: { incident_id: id } })]);
  const i = inc.rows[0]; if (!i) notFound();
  return (<>
    <PageHead kicker={<Link className="link" href="/admin/incidents">Incidents and claims</Link>} title={<>{String(i.incident_number)} <Badge s={String(i.status)} /></>}>
      {!claims.rows.length && <Act action="claim_open" payload={{ incident: id }} label="Open the claim" variant="primary" confirm="Open the claim from the costed damage; the path follows the deductible rule." refresh={[`/admin/incidents/${id}`]} />}
    </PageHead>
    <div className="ad-cols ad-cols--2">
      <Card title="Incident"><Kv rows={[['Kind', label(i.kind)], ['Vehicle', String(i.vehicle_name ?? '')], ['Booking', <BookingLink key="b" n={i.booking_number} />], ['Happened', t(i.occurred_at)], ['Reported', t(i.reported_at)], ['Place', String(i.place ?? '')], ['What', String(i.description ?? '')], ['Drivable', i.drivable === null ? '' : i.drivable ? 'Yes' : 'No'], ['Police report', String(i.police_report_number ?? '')], ['Owner told', t(i.owner_notified_at)]]} /></Card>
      <Card title="Claim"><Table rows={claims.rows} empty="No claim opened." cols={[{ key: 'claim_number', label: 'Claim' }, { key: 'path', label: 'Path', render: (r) => label(r.path) }, { key: 'status', label: 'Status' }, { key: 'damage_cost_cents', label: 'Damage', num: true, render: (r) => $(r.damage_cost_cents) }, { key: 'deductible_billed_cents', label: 'Deductible billed', num: true, render: (r) => $(r.deductible_billed_cents) }]} /></Card>
    </div>
  </>);
}
