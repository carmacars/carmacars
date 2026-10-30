import { Act } from './Act';
import { Badge, Table, t } from './ui';

// Forms C and D signed on paper with witnesses (migration 0040): the owner uploads the scan, customer service or an
// Admin approves it or sends it back with what to fix. The owner is emailed either way.
export type FormRow = {
  id: string; code: 'C' | 'D1'; status: 'uploaded' | 'approved' | 'rejected'; owner_id: string; owner_name: string; vehicle_name: string | null;
  document_id: string | null; witness_1_name: string | null; witness_2_name: string | null; uploaded_at: string; reviewed_at: string | null; reject_reason: string | null; reviewed_by_name: string | null;
};
const TITLE = { C: 'Form C, lender or lessor permission', D1: 'Form D, limited power of attorney' } as const;

export function OwnerFormsTable({ rows, base, refresh }: { rows: FormRow[]; base: '/admin' | '/staff'; refresh: string[] }) {
  return (
    <Table<FormRow> testId="owner-forms" rows={rows} empty="No forms uploaded." cols={[
      { key: 'owner_name', label: 'Owner', render: (r) => base === '/admin' ? <a className="link" href={`/admin/owners/${r.owner_id}`}>{r.owner_name}</a> : r.owner_name },
      { key: 'code', label: 'Form', render: (r) => <>{TITLE[r.code]}{r.vehicle_name ? <><br /><span className="small">{r.vehicle_name}</span></> : null}</> },
      { key: 'witness_1_name', label: 'Witnesses', render: (r) => [r.witness_1_name, r.witness_2_name].filter(Boolean).join(', ') },
      { key: 'document_id', label: 'Scan', render: (r) => r.document_id ? <a className="link" href={base === '/admin' ? `/admin/documents/${r.document_id}` : `/staff/documents/${r.document_id}`} target="_blank" rel="noreferrer">Open</a> : null },
      { key: 'uploaded_at', label: 'Uploaded', render: (r) => t(r.uploaded_at) },
      { key: 'status', label: 'Status', render: (r) => <Badge s={r.status} /> },
      { key: 'reject_reason', label: 'Review', className: 'wrap', render: (r) => r.reviewed_at ? `${r.reject_reason ?? 'Approved'} (${r.reviewed_by_name ?? 'staff'}, ${t(r.reviewed_at)})` : '' },
      { key: 'act', label: '', render: (r) => r.status === 'uploaded' ? <span className="ad-actions">
        <Act action="owner_form_review" payload={{ form: r.id, approve: true }} label="Approve" variant="primary" confirm="Every part is filled, initialled where asked, signed and witnessed." refresh={refresh} testId={`form-approve-${r.code}`} done="Approved." />
        <Act action="owner_form_review" payload={{ form: r.id, approve: false }} label="Send back" fields={[{ name: 'reason', label: 'What to fix (the owner reads this)', type: 'textarea', required: true }]} refresh={refresh} testId={`form-reject-${r.code}`} done="Sent back." />
      </span> : null }]} />
  );
}
