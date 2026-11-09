import { Act } from '@/features/admin/Act';
import { STAFF_FN_LABEL, heldFunctions } from '@/features/staff/nav';

// Who has not signed (migration 1060): every staff member (never an Admin) and their agreement, the ones not signed first.
// The agreement is sent by itself; an Admin sees what it waits for, whether the person is held, and can waive it with a reason.
export interface AgreementGateRow { user_id: string; name: string; preferred_name: string | null; email: string; functions: string[]; academy_locked: boolean; locked: boolean;
  state: 'signed' | 'waived' | 'sent' | 'none'; kind: 'in_person' | 'remote'; sent_at: string | null; signed_at: string | null; reminded_at: string | null;
  missing: string[]; error: string | null; waived_reason: string | null }

const day = (iso: string | null) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric' }).format(new Date(iso)) : '');
const REFRESH = ['/admin/settings/staff'];

export function stateWords(r: AgreementGateRow): string {
  if (r.state === 'signed') return `Signed ${day(r.signed_at)}`;
  if (r.state === 'waived') return `Waived: ${r.waived_reason ?? ''}`;
  if (r.state === 'sent') return `Sent ${day(r.sent_at)}${r.reminded_at ? `, reminded ${day(r.reminded_at)}` : ''}${r.academy_locked ? '; opens once the academy is passed' : ''}`;
  if (r.missing.length) return `Not sent: waits for ${r.missing.join(', ')}`;
  return r.error ? `Not sent: ${r.error}` : 'Being sent by itself';
}

export function AgreementGate({ rows }: { rows: AgreementGateRow[] }) {
  const open = rows.filter((r) => r.state !== 'signed' && r.state !== 'waived');
  return (
    <div className="stack" data-testid="agreement-gate">
      <p className="small">{open.length ? `${open.length} not signed yet.` : 'Everyone has signed.'} Each staff member signs their role&apos;s agreement after the academy: the Field Staff Agreement for field work, the contractor agreement for customer service, Fleet, Finance and Sales. Until then their portal opens only Welcome, their profile and the agreement.</p>
      {open.length > 0 && <ul className="mr-list">{open.map((r) => (
        <li key={r.user_id} data-testid={`agreement-gate-${r.email}`}>
          <span><b>{r.preferred_name ?? r.name}</b> ({heldFunctions(r.functions).map((f) => STAFF_FN_LABEL[f]).join(', ') || 'staff'}; {r.kind === 'in_person' ? 'field agreement' : 'contractor agreement'}): {stateWords(r)}{r.locked ? ' · held' : ''}</span>
          <Act action="staff_agreement_waive" payload={{ user_id: r.user_id, on: true }} label="Waive" refresh={REFRESH} done="Waived."
            fields={[{ name: 'reason', label: 'Why the agreement is waived', type: 'text', required: true }]} testId={`agreement-waive-${r.email}`} />
        </li>))}</ul>}
    </div>
  );
}
