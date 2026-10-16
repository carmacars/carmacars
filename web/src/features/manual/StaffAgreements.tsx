import { PaperSignatureForm } from './ManualRecords';
import { SendToSign } from './SignRequests';

// Each staff member's agreement: on file and how it was signed (in the portal or on paper), or waiting; with "Send a
// PDF to sign" (signed in the VA or Field portal) and "Record paper signature" (migration 0044).
export interface StaffAgreementRow { user_id: string; name: string; email: string; staff_type: string; function: string | null; is_active: boolean; agreement_document_id: string | null;
  signed: { method: string; on: string; paper_id: string | null; document_id: string | null } | null; open: { id: string; title: string; sent_at: string } | null }
const day = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(`${iso.slice(0, 10)}T12:00:00Z`));
const REFRESH = ['/admin/settings/staff'];

export function StaffAgreements({ rows, today }: { rows: StaffAgreementRow[]; today: string }) {
  if (!rows.length) return <p className="small muted">No staff yet.</p>;
  return (
    <ul className="mr-list">
      {rows.filter((r) => r.is_active).map((r) => (
        <li key={r.user_id} data-staff={r.email}>
          <span><b>{r.name}</b> ({r.function?.replace(/_/g, ' ') ?? r.staff_type}): <span data-testid="staff-agreement-status">{r.signed ? `signed ${r.signed.method === 'paper' ? 'on paper' : 'in the portal'}, ${day(r.signed.on)}` : r.open ? `sent ${day(r.open.sent_at)}, waiting for their signature` : r.agreement_document_id ? 'on file' : 'no agreement on file'}</span></span>
          {(r.signed?.document_id ?? r.agreement_document_id) && <a className="link small" href={`/admin/documents/${r.signed?.document_id ?? r.agreement_document_id}`} target="_blank" rel="noreferrer">Agreement</a>}
          {!r.open && <SendToSign docType="staff_agreement" who={r.user_id} defaultTitle={`Staff agreement, ${r.name}`} refresh={REFRESH} />}
          <PaperSignatureForm docs={[{ doc_type: 'staff_agreement', target_id: r.user_id, label: `Staff agreement, ${r.name}`, signer: r.name }]} today={today} refresh={REFRESH} testId={`paper-staff-${r.email}`} />
        </li>
      ))}
    </ul>
  );
}
