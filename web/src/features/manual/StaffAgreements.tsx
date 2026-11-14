import { SendGenerated, SendToSign } from './SignRequests';

// Each staff member's agreement: on file and how it was signed (in the portal, or on paper before 0720), or waiting; with
// "Send the agreement to sign" (generated from the staff profile, 0049) and "Send a PDF to sign" (signed in the staff
// portal). No signature on paper is recorded since 0720: every agreement is signed with the e-signature. r45 (2862): "Send a new
// agreement" redoes one already sent or signed with the current terms (the one waiting is voided, a signed one superseded).
export interface StaffAgreementRow { user_id: string; name: string; email: string; staff_type: string; function: string | null; is_active: boolean; agreement_document_id: string | null;
  signed: { method: string; on: string; paper_id: string | null; document_id: string | null } | null; open: { id: string; title: string; sent_at: string } | null;
  /** r45 (2862): lives in Canada, but the current agreement has other terms; a signed one replaced by a newer one */
  needs_canada_terms?: boolean; superseded?: { id: string; signed_at: string | null; superseded_at: string } | null }
const day = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(`${iso.slice(0, 10)}T12:00:00Z`));
const REFRESH = ['/admin/settings/staff'];

export function StaffAgreements({ rows }: { rows: StaffAgreementRow[]; today?: string }) {
  if (!rows.length) return <p className="small muted">No staff yet.</p>;
  return (
    <ul className="mr-list">
      {rows.filter((r) => r.is_active).map((r) => (
        <li key={r.user_id} data-staff={r.email}>
          <span><b>{r.name}</b> ({r.function?.replace(/_/g, ' ') ?? r.staff_type}): <span data-testid="staff-agreement-status">{r.signed ? `signed ${r.signed.method === 'paper' ? 'on paper' : 'in the portal'}, ${day(r.signed.on)}` : r.open ? `sent ${day(r.open.sent_at)}, waiting for their signature` : r.agreement_document_id ? 'on file' : 'no agreement on file'}</span></span>
          {(r.signed?.document_id ?? r.agreement_document_id) && <a className="link small" href={`/admin/documents/${r.signed?.document_id ?? r.agreement_document_id}`} target="_blank" rel="noreferrer">Agreement</a>}
          {!r.open && !r.signed && <SendGenerated docType="staff_agreement" who={r.user_id} refresh={REFRESH} />}
          {!r.open && <SendToSign docType="staff_agreement" who={r.user_id} defaultTitle={`Staff agreement, ${r.name}`} refresh={REFRESH} />}
          {(r.open || r.signed) && <SendGenerated docType="staff_agreement" who={r.user_id} refresh={REFRESH} reissue />}
          {r.needs_canada_terms && <span className="ad-b ad-b--amber small" data-testid="staff-agreement-canada">Lives in Canada: needs the Canadian terms</span>}
          {r.superseded && <span className="small muted" data-testid="staff-agreement-superseded">A signed agreement was superseded {day(r.superseded.superseded_at)}</span>}
        </li>
      ))}
    </ul>
  );
}
