import Link from 'next/link';
import { $, Badge, Card, Table, t } from '@/features/admin/ui';

// The notices read (migration 0042): those waiting for a check first, then the recent ones, and every line that
// was not imported, with its reason, for Finance.
type Q = { reads: Array<{ id: string; read_number: string; file_name: string | null; method: string; authority: string | null; status: string; created_at: string; lines: number; imported: number; exceptions: number; low: number }>;
  exceptions: Array<{ id: string; read_id: string; read_number: string; line_no: number; plate: string | null; occurred_at: string | null; amount_cents: number | null; result_reason: string | null; vehicle_name: string | null }> };
const METHOD: Record<string, string> = { pdf_text: 'PDF text', vision: 'Vision model', csv: 'CSV', manual: 'Typed' };
export function ReadQueue({ q, base }: { q: Q; base: '/admin' | '/va' }) {
  return (<>
    <Card title="Notices read" testId="toll-reads">
      <Table rows={q.reads} empty="No notice read yet." testId="toll-reads-table" cols={[
        { key: 'read_number', label: 'Read', render: (r) => <Link prefetch={false} className="link" href={`${base}/tolls/read/${r.id}`}>{r.read_number}</Link> },
        { key: 'status', label: 'Status', render: (r) => <Badge s={r.status === 'in_review' ? 'needs_review' : r.status === 'confirmed' ? 'done' : 'cancelled'}>{r.status === 'in_review' ? 'To check' : r.status === 'confirmed' ? 'Confirmed' : 'Discarded'}</Badge> },
        { key: 'authority', label: 'Issuer' }, { key: 'file_name', label: 'File', className: 'wrap' }, { key: 'method', label: 'Read from', render: (r) => METHOD[r.method] ?? r.method },
        { key: 'lines', label: 'Lines', num: true }, { key: 'imported', label: 'Imported', num: true }, { key: 'exceptions', label: 'Not imported', num: true, render: (r) => r.exceptions ? <b className="ad-late">{r.exceptions}</b> : '0' },
        { key: 'created_at', label: 'Read', render: (r) => t(r.created_at) }]} />
    </Card>
    {q.exceptions.length > 0 && <Card title="Lines not imported" tone="warn" testId="toll-read-exceptions">
      <Table rows={q.exceptions} cols={[{ key: 'read_number', label: 'Read', render: (r) => <Link prefetch={false} className="link" href={`${base}/tolls/read/${r.read_id}`}>{r.read_number} line {r.line_no}</Link> },
        { key: 'plate', label: 'Plate' }, { key: 'vehicle_name', label: 'Car' }, { key: 'occurred_at', label: 'When', render: (r) => t(r.occurred_at) }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) },
        { key: 'result_reason', label: 'Why', className: 'wrap' }]} />
    </Card>}
  </>);
}
