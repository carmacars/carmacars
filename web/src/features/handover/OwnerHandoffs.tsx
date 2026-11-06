import { door } from '@/server/door';
import { rpc } from '@/lib/db/repo';
import { when } from '@/features/agreement/model';
import { angleLabel } from './angles';
import { OwnerHandoffForm } from './OwnerHandoffForm';
import { fuelLabel } from '@/features/returns/claim';

// The car picked up from its owner and returned to them (migration 0546): the baseline condition for disputes. Staff
// (Admin, Fleet, field) record them with many photos at once and the suggested angles; the owner reads them.
export interface Handoff { id: string; kind: 'pickup_from_owner' | 'return_to_owner'; at: string; odometer_km: number | null; fuel_pct: number | null; notes: string | null;
  photos: Array<{ bucket: string; path: string; angle: string | null }>; recorded_by_name: string | null; recorded_at: string }

const KIND = { pickup_from_owner: 'Pickup from owner', return_to_owner: 'Return to owner' } as const;

export async function OwnerHandoffs({ vehicleId, userId, aal, owner = false, refresh = [] }: { vehicleId: string; userId: string; aal?: 'aal1' | 'aal2' | null; owner?: boolean; refresh?: string[] }) {
  const list = owner
    ? ((await rpc('server_owner_handoffs' as never, { p_by: userId, p_vehicle: vehicleId } as never, { role: 'service_role', skipViewAs: true }).catch(() => null)) as unknown as Handoff[] | null)
    : await door<Handoff[]>(userId, 'ops_read', 'owner_handoffs', { vehicle: vehicleId }, aal).catch(() => null);
  if (list === null) return null;
  if (owner && !list.length) return null;
  return (
    <section className="pt-card stack" aria-labelledby={`oh-${vehicleId}`} data-testid="owner-handoffs">
      <h2 className="d4" id={`oh-${vehicleId}`}>Pickup from owner and return to owner</h2>
      <p className="small muted">{owner ? 'The car\'s condition when we picked it up from you and when we gave it back: the photos, km and fuel.' : 'The car\'s condition when it is picked up from its owner or returned: the baseline for any dispute. The owner sees these, read only.'}</p>
      {list.length ? <ul className="ho-photos">{list.map((h) => (
        <li key={h.id} className="stack" data-testid="owner-handoff">
          <span><b>{KIND[h.kind]}</b> {when(h.at)}{h.odometer_km != null ? ` · ${h.odometer_km.toLocaleString('en-CA')} km` : ''}{h.fuel_pct != null ? ` · fuel ${fuelLabel(h.fuel_pct)}` : ''}{h.recorded_by_name ? ` · by ${h.recorded_by_name}` : ''}</span>
          {h.notes && <span className="small">{h.notes}</span>}
          {h.photos.length > 0 && <span className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-1)' }}>{h.photos.map((p) => (
            <a key={p.path} href={`/api/handover-photo?vehicle=${vehicleId}&path=${encodeURIComponent(p.path)}`} target="_blank" rel="noreferrer" title={angleLabel(p.angle)}>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={`/api/handover-photo?vehicle=${vehicleId}&path=${encodeURIComponent(p.path)}`} alt={`${KIND[h.kind]}: ${angleLabel(p.angle)}`} width={96} height={72} loading="lazy" style={{ objectFit: 'cover' }} /></a>))}</span>}
          {!owner && <OwnerHandoffForm vehicleId={vehicleId} addTo={h.id} refresh={refresh} />}
        </li>))}</ul> : <p className="small muted">None recorded yet.</p>}
      {!owner && <OwnerHandoffForm vehicleId={vehicleId} refresh={refresh} />}
    </section>
  );
}
