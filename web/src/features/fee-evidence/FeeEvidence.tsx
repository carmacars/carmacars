import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { $, Card } from '@/features/admin/ui';
import { EvidenceUpload } from './EvidenceUpload';
import { IMPROPER_REASONS, RETURN_CHARGES, STATUS_WORDS, evidenceLabel, type EvidenceStatus } from './model';

// r48 FE (3190): the evidence of every fee, on the booking's Money tab (Admin and staff). Each fee line says what its
// evidence needs (the registry), what was found by itself and what is missing; a line that needs evidence is not charged
// until it is attached (Attach evidence) or an Admin charges it anyway with the reason. Return charges (rental agreement
// 10.6 to 10.8 and 11.6) are added here. The database decides who may and refuses with the reason.
type Line = { line_item_id: string; charge_type: string; description: string | null; amount_cents: number; on_statement: boolean; status: EvidenceStatus; missing: string[];
  missing_text: string | null; requires: string[]; gathers: string[]; capture: string; captured_by: string; sources: string; have: Record<string, unknown>; override_reason: string | null;
  attached: Array<{ kind: string; note: string | null; photos: number; at: string }> };

const WHO: Record<string, string> = { field: 'Field', fleet: 'Fleet', finance: 'Finance' };

export async function FeeEvidence({ userId, aal, booking, bookingId, status, admin, refresh }: { userId: string; aal?: 'aal1' | 'aal2' | null; booking: string; bookingId: string;
  status: string; admin: boolean; refresh: string[] }) {
  const r = await door<{ lines: Line[] }>(userId, 'ops_read', 'fee_evidence', { booking }, aal).catch(() => null);
  const lines = (r?.lines ?? []).filter((l) => l.requires.some((k) => k !== 'booking_record'));
  const handedOver = ['on_rent', 'returned', 'closed'].includes(status);
  if (!lines.length && !handedOver) return null;
  const waiting = lines.filter((l) => l.status === 'needs_evidence').length;
  return (
    <Card title={`Evidence for every fee${waiting ? ` (${waiting} waiting)` : ''}`}>
      <div className="stack" data-testid="fee-evidence">
        {lines.length === 0 && <p className="small muted">No fee here needs evidence yet. Every fee added after the pickup is checked: the return time, the Tracker, the notices, the photos and the receipts are found by themselves.</p>}
        {lines.map((l) => (
          <div key={l.line_item_id} className={`pt-card stack${l.status === 'needs_evidence' ? ' is-warn' : ''}`} data-testid={`evidence-${l.charge_type}`} data-status={l.status}>
            <p><b>{l.description ?? l.charge_type}</b> {$(l.amount_cents)} <span className="small">{STATUS_WORDS[l.status] ?? l.status}{l.on_statement ? ', on a statement' : ''}</span></p>
            {l.status === 'needs_evidence' && <p className="alert alert--warn small" role="status"><span>Missing: {l.missing_text ?? l.missing.map(evidenceLabel).join(', ')}. {WHO[l.captured_by] ?? 'Staff'} captures it: {l.capture}</span></p>}
            <p className="small muted">Found by itself: {Object.keys(l.have).filter((k) => l.requires.includes(k) || l.gathers.includes(k)).map(evidenceLabel).join(', ') || 'nothing yet'}. Where it comes from: {l.sources}.</p>
            {l.attached.length > 0 && <ul className="small">{l.attached.map((a, i) => <li key={i}>{a.kind.replace(/_/g, ' ')}{a.photos ? `, ${a.photos} photo${a.photos > 1 ? 's' : ''}` : ''}{a.note ? `: ${a.note}` : ''}</li>)}</ul>}
            {l.override_reason && <p className="small">Charged without its evidence by an Admin: {l.override_reason}</p>}
            {!l.on_statement && l.status !== 'overridden' && <div className="ad-actions">
              <EvidenceUpload bookingId={bookingId} lineId={l.line_item_id} testId={`attach-${l.charge_type}`} />
              {admin && l.status === 'needs_evidence' && <Act ops action="fee_evidence_override" payload={{ line: l.line_item_id }} label="Charge without evidence" variant="quiet"
                title="Charge it without the missing evidence" refresh={refresh} done="Overridden: it is charged with the next statement."
                fields={[{ name: 'reason', label: 'Why (kept on the line and in the history)', type: 'textarea', required: true }]} testId={`override-${l.charge_type}`} />}
            </div>}
          </div>))}
        {handedOver && <div className="ad-actions"><Act ops action="return_charge_add" payload={{ booking }} label="Add a return charge" title="Add a return charge (rental agreement 10.6 to 11.6)" refresh={refresh}
          done="Added. Its evidence is checked by itself; what is missing becomes a To do." testId="return-charge-add"
          fields={[{ name: 'kind', label: 'The charge', type: 'select', options: RETURN_CHARGES, value: 'improper_return', required: true },
            { name: 'reason', label: 'Improper return: what was wrong', type: 'select', options: IMPROPER_REASONS, value: '' },
            { name: 'note', label: 'What happened (the renter sees it)', type: 'textarea', required: true },
            { name: 'costs', label: 'Actual costs (tow, impound, storage, tire, lockout...): a list of {"label": "Tow", "amount_cents": 18000}', type: 'json', value: [] },
            { name: 'mechanical_fault', label: 'Tire or roadside: a mechanical fault that is not the renter\'s (nothing is charged)', type: 'bool', value: false },
            { name: 'police_report', label: 'Theft: the police report number', type: 'text' }]} /></div>}
      </div>
    </Card>
  );
}
