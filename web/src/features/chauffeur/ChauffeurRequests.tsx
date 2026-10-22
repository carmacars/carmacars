import { Act } from '@/features/admin/Act';
import { $, Badge, Card, Table, Tabs, d } from '@/features/admin/ui';

type Row = Record<string, unknown> & { id: string; reference: string; status: string; service_date: string; start_time: string; hours: number; vehicle: string; chauffeur_vehicle_id: string;
  name: string; email: string | null; phone: string | null; pickup_address: string; dropoff_address: string | null; passengers: number; occasion: string | null; notes: string | null;
  rate_cents: number; renter_cents: number; hst_cents: number; total_cents: number; sheet_cents: number; cut_bps: number; partner_payout_cents: number; carmacars_keep_cents: number;
  quote_note: string | null; staff_note: string | null; line: string };
export type ChauffeurData = { rows: Row[]; counts: Record<string, number>; today: Array<{ reference: string; start_time: string; vehicle: string; name: string; hours: number }>; vehicles: Array<{ id: string; name: string }> };
export const STATUSES = ['new', 'quoted', 'confirmed', 'completed', 'cancelled', 'declined'];

// The chauffeur requests (migration 0093), for Admin > Chauffeur and the assistants' Chauffeur (customer service and
// Sales): every request with its quote line (the hours at the 2-hour or 3+ hour rate, marked up, with HST) and what the
// partner is owed. Staff check the vehicle and the driver with the partner, send the quote (by email or phone, noted
// here), confirm it, and close it. The actions go through the staff door (ops_do).
export function ChauffeurRequests({ data, base, status }: { data: ChauffeurData; base: string; status?: string }) {
  const refresh = [base, '/admin', '/va'];
  const vehicles: Array<[string, string]> = data.vehicles.map((v) => [v.id, v.name]);
  return (
    <>
      <Tabs label="Status" current={status ? `${base}?status=${status}` : base}
        items={[[base, 'All'], ...STATUSES.map((s): [string, string, number] => [`${base}?status=${s}`, s.charAt(0).toUpperCase() + s.slice(1), data.counts[s] ?? 0])]} />
      <div className="ad-cols ad-cols--2">
        <Card title={`Chauffeur today (${data.today.length})`} testId="chauffeur-today">
          {data.today.length ? <ul className="ad-list">{data.today.map((r) => <li key={r.reference}><span>{r.start_time} {r.reference} {r.name}</span><span className="ad-sub">{r.vehicle}, {r.hours} hours</span></li>)}</ul>
            : <p className="small muted">No confirmed chauffeur bookings today.</p>}
        </Card>
        <Card title="How it works">
          <p className="small">A request is a quote waiting: check the vehicle and the driver with the partner, then send the quote line below by email or phone and mark it Quoted. When the client agrees, take the payment by a payment link or at pickup and mark it Confirmed. The partner is owed its sheet rate less the commission; the payout goes on its monthly statement.</p>
        </Card>
      </div>
      <Card title={`Requests (${data.rows.length})`} testId="chauffeur-requests">
        <Table rows={data.rows} empty="No chauffeur requests yet." rowKey={(r) => r.id} cols={[
          { key: 'reference', label: 'Request', render: (r) => <span data-testid={`ch-row-${r.reference}`}><b>{r.reference}</b><br /><Badge s={r.status} /></span> },
          { key: 'service_date', label: 'When', render: (r) => `${d(r.service_date)}, ${r.start_time.slice(0, 5)}, ${r.hours} hours` },
          { key: 'vehicle', label: 'Vehicle and trip', render: (r) => <>{r.vehicle}<br /><span className="small muted">{r.pickup_address}{r.dropoff_address ? ` to ${r.dropoff_address}` : ''}, {r.passengers} passengers{r.occasion ? `, ${r.occasion}` : ''}</span>{r.notes && <><br /><span className="small">{r.notes}</span></>}</> },
          { key: 'name', label: 'Client', render: (r) => <>{r.name}<br /><span className="small">{[r.email, r.phone].filter(Boolean).join(', ')}</span></> },
          { key: 'total_cents', label: 'Quote', num: true, render: (r) => <span title={r.line}>{$(r.renter_cents)} + HST {$(r.hst_cents)} = <b>{$(r.total_cents)}</b><br /><span className="small muted">{r.line}</span></span> },
          { key: 'partner_payout_cents', label: 'Partner, CarmaCars', num: true, render: (r) => <span className="small">Sheet {$(r.sheet_cents)}, partner {$(r.partner_payout_cents)}<br />CarmaCars keeps {$(r.carmacars_keep_cents)} ({r.cut_bps / 100}% cut plus markup)</span> },
          { key: 'id', label: '', render: (r) => (
            <div className="ad-actions">
              {r.status === 'new' && <Act ops action="chauffeur_request_update" payload={{ id: r.id, status: 'quoted' }} label="Quoted" testId={`ch-quote-${r.reference}`} refresh={refresh}
                fields={[{ name: 'quote_note', label: 'How the quote was sent', value: 'Emailed the quote', required: true }]} />}
              {['new', 'quoted'].includes(r.status) && <Act ops action="chauffeur_request_update" payload={{ id: r.id, status: 'confirmed' }} label="Confirm" variant="primary" testId={`ch-confirm-${r.reference}`} refresh={refresh}
                fields={[{ name: 'staff_note', label: 'How it is paid (payment link, at pickup)', value: r.staff_note ?? '' }]} />}
              {['new', 'quoted'].includes(r.status) && <Act ops action="chauffeur_request_update" payload={{ id: r.id }} label="Change" refresh={refresh}
                fields={[{ name: 'vehicle_id', label: 'Vehicle', type: 'select', options: vehicles, value: r.chauffeur_vehicle_id }, { name: 'hours', label: 'Hours (2 or more)', type: 'number', min: 2, max: 24, value: r.hours }, { name: 'staff_note', label: 'Note', value: r.staff_note ?? '' }]} />}
              {r.status === 'confirmed' && <Act ops action="chauffeur_request_update" payload={{ id: r.id, status: 'completed' }} label="Completed" refresh={refresh} />}
              {['new', 'quoted', 'confirmed'].includes(r.status) && <Act ops action="chauffeur_request_update" payload={{ id: r.id, status: r.status === 'new' ? 'declined' : 'cancelled' }} label={r.status === 'new' ? 'Decline' : 'Cancel'} variant="quiet" refresh={refresh}
                fields={[{ name: 'staff_note', label: 'Why', required: true }]} />}
            </div>) }]} />
      </Card>
    </>
  );
}
