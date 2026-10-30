import { Act } from './Act';
import { Badge, Table, t } from './ui';

// Possible duplicates (migration 0040): a VIN one character apart, the same plate, the same photo or listing text
// as a listed car stop publishing until someone clears the flag (different cars) or confirms it (the same car).
// The same year, make, model and colour is shown for the reviewer without stopping it.
export type Flag = {
  id: string; vehicle_id: string; other_vehicle_id: string; kind: 'vin' | 'plate' | 'photo' | 'copy' | 'specs'; blocking: boolean; detail: string; status: 'open' | 'cleared' | 'confirmed';
  score_bps: number | null; created_at: string; decided_at: string | null; decision_note: string | null; decided_by_name?: string | null;
  vehicle_name?: string; other_vehicle_name?: string; plate?: string | null; other_plate?: string | null; listing_status?: string | null; other_owner_name?: string | null;
};
const KIND: Record<Flag['kind'], string> = { vin: 'VIN one character apart', plate: 'Same plate', photo: 'Same photo', copy: 'Listing text alike', specs: 'Same year, make, model, colour' };

export function SimilarityTable({ rows, base, refresh, showVehicle = true }: { rows: Flag[]; base: '/admin' | '/staff'; refresh: string[]; showVehicle?: boolean }) {
  return (
    <Table<Flag> testId="similar-cars" rows={rows} empty="No possible duplicates." cols={[
      ...(showVehicle ? [{ key: 'vehicle_name', label: 'Car', render: (r: Flag) => base === '/admin' ? <a className="link" href={`/admin/vehicles/${r.vehicle_id}`}>{r.vehicle_name}</a> : r.vehicle_name }] : []),
      { key: 'kind', label: 'Looks like', render: (r) => <><b>{KIND[r.kind]}</b>{r.blocking ? <span className="ad-flag">stops publishing</span> : null}<br /><span className="small">{r.other_vehicle_name}{r.other_plate ? ` (${r.other_plate})` : ''}</span></> },
      { key: 'detail', label: 'Detail', className: 'wrap' },
      { key: 'status', label: 'Status', render: (r) => <Badge s={r.status} /> },
      { key: 'decision_note', label: 'Decision', className: 'wrap', render: (r) => r.decided_at ? `${r.decision_note ?? ''} (${r.decided_by_name ?? 'staff'}, ${t(r.decided_at)})` : '' },
      { key: 'act', label: '', render: (r) => r.status === 'open' ? <span className="ad-actions">
        <Act action="similarity_decide" payload={{ flag: r.id, decision: 'cleared' }} label="Not a duplicate" variant="primary" testId={`flag-clear-${r.kind}`}
          fields={[{ name: 'note', label: 'What you checked', type: 'textarea', required: true, placeholder: 'Different VIN on the permits; photos taken today' }]} refresh={refresh} done="Cleared." />
        <Act action="similarity_decide" payload={{ flag: r.id, decision: 'confirmed' }} label="Same car" variant="danger"
          fields={[{ name: 'note', label: 'What you found', type: 'textarea', required: true }]} refresh={refresh} done="Confirmed." />
      </span> : null }]} />
  );
}
