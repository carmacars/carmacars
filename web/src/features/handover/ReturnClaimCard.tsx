import { Act } from '@/features/admin/Act';
import { Card } from '@/features/admin/ui';
import { door } from '@/server/door';
import { storage } from '@/integrations/storage';
import type { Bucket } from '@/integrations/storage/types';
import { fuelLabel, FUEL_LEVELS } from '@/features/returns/claim';

// The renter's "I've returned the car" report on the booking page (migration 0532), for everyone who checks a car in
// (Admin, Fleet, Sales, Customer service, Field): what the renter gave, marked renter-provided, with their photos; Confirm
// (the readings and time may be corrected; the trip is completed) or Deny (the reason goes to the renter, the overdue
// notices resume). A decided report stays as one line.
interface Claim {
  id: string; status: 'pending' | 'confirmed' | 'denied'; claimed_at: string; returned_at: string | null; odometer_km: number | null; fuel_pct: number | null;
  note: string | null; photos: Array<{ bucket: string; path: string }>; decided_at: string | null; decided_by_name: string | null; decision_note: string | null;
  confirmed_returned_at: string | null; odometer_out_km: number | null;
}
const at = (iso: string | null) => (iso ? new Date(iso).toLocaleString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : 'not given');

export async function ReturnClaimCard({ booking, base, userId, aal }: { booking: string; base: string; userId: string; aal?: 'aal1' | 'aal2' | null }) {
  const c = await door<Claim | null>(userId, 'ops_read', 'return_claim', { booking }, aal).catch(() => null);
  if (!c) return null;
  if (c.status !== 'pending') {
    return <p className="small muted" data-testid="return-claim-decided">The renter reported the car returned on {at(c.claimed_at)}: {c.status === 'confirmed' ? 'confirmed' : `denied (${c.decision_note ?? 'no reason'})`}{c.decided_by_name ? ` by ${c.decided_by_name}` : ''}.</p>;
  }
  const s = await storage();
  const photos = await Promise.all(c.photos.slice(0, 30).map(async (p) => ({ ...p, url: await s.signedDownloadUrl((p.bucket || 'condition-photos') as Bucket, p.path, 600).catch(() => null) })));
  return (
    <Card title="The renter says the car is back" testId="return-claim" tone="warn">
      <div className="stack">
        <p>Reported {at(c.claimed_at)}. The overdue notices are paused until you decide. Renter-provided: returned <b>{at(c.returned_at)}</b>, odometer <b>{c.odometer_km !== null ? `${c.odometer_km.toLocaleString('en-CA')} km` : 'not given'}</b>
          {c.odometer_out_km !== null ? ` (out at ${c.odometer_out_km.toLocaleString('en-CA')} km)` : ''}, fuel <b>{fuelLabel(c.fuel_pct)}</b>, {c.photos.length} photo{c.photos.length === 1 ? '' : 's'}.</p>
        {c.note && <p className="small">Renter&apos;s note: {c.note}</p>}
        {photos.length > 0 && <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }} data-testid="return-claim-photos">
          {/* eslint-disable-next-line @next/next/no-img-element -- signed private photo */}
          {photos.map((p) => p.url ? <a key={p.path} href={p.url} target="_blank" rel="noreferrer"><img src={p.url} alt="Renter's return photo" width={96} height={72} style={{ objectFit: 'cover', borderRadius: 6 }} /></a> : null)}
        </div>}
        <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
          <Act ops action="return_claim_decide" payload={{ booking, decision: 'confirm' }} label="Confirm the return" variant="primary" testId="return-claim-confirm" refresh={[base]}
            done="Confirmed: the trip is completed and the renter's photos are on the check-in report."
            fields={[
              { name: 'returned_at', label: 'Return time', type: 'datetime', value: c.returned_at ?? c.claimed_at, required: true, hint: 'The late charges follow this time.' },
              { name: 'odometer_km', label: 'Odometer (km)', type: 'number', min: 0, value: c.odometer_km ?? undefined },
              { name: 'fuel_pct', label: 'Fuel', type: 'select', value: c.fuel_pct !== null ? String(c.fuel_pct) : '', options: [['', 'Not known'], ...FUEL_LEVELS.map(([l, p]) => [String(p), l] as [string, string])] },
              { name: 'reason', label: 'Note (optional)', type: 'text', wide: true }
            ]} />
          <Act ops action="return_claim_decide" payload={{ booking, decision: 'deny' }} label="Deny" testId="return-claim-deny" refresh={[base]}
            done="Denied: the renter is told why and the overdue notices resume."
            fields={[{ name: 'reason', label: 'Why (the renter reads this)', type: 'text', required: true, wide: true }]} />
        </div>
      </div>
    </Card>
  );
}
