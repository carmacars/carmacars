import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Filters, PageHead, Table, d, t, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Tolls and tickets', path: '/admin/tolls', noindex: true, description: 'The toll and ticket work queues.' });
type Q = Record<string, unknown> & { id: string; bucket: string; age_days: number; age_band: string; due_soon: boolean; past_charge_by: boolean };
const BUCKETS: Array<[string, string]> = [['', 'All'], ['unmatched', 'Unmatched'], ['needs_review', 'Needs review'], ['matched_not_charged', 'Matched, not charged'], ['matched_not_billed', 'Owner, not billed'], ['matched_staff', 'Staff'], ['charged_not_notified', 'Charged, not notified'], ['disputed', 'Disputed']];

// The work queues by bucket and age (10-tolls-tickets-damages.md section 5).
export default async function Tolls({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/tolls'), searchParams]);
  const data = await read<{ queue: Q[]; summary: Array<{ bucket: string; age_band: string; count: number; amount_cents: number }> }>('tolls', sp.bucket ? { bucket: sp.bucket } : {});
  const count = (b: string) => data.summary.filter((s) => s.bucket === b).reduce((n, s) => n + Number(s.count), 0);
  const ids = (b: string) => data.queue.filter((q) => q.bucket === b).map((q) => q.id);
  return (<>
    <PageHead title="Tolls and tickets">
      <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/tolls/new">Log one</Link><Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/tolls/import">Import a statement</Link>
      {ids('needs_review').length > 0 && <Act action="toll_bulk_confirm" payload={{ ids: ids('needs_review') }} label="Bulk confirm high-confidence" refresh={['/admin/tolls']} />}
      {ids('matched_not_charged').length > 0 && <Act action="toll_charge" payload={{ ids: ids('matched_not_charged') }} label={`Charge ${ids('matched_not_charged').length} matched`} confirm="Charge every matched notice to its renter: one administration fee per statement and booking." refresh={['/admin/tolls']} />}
    </PageHead>
    <Filters base="/admin/tolls" name="bucket" value={sp.bucket ?? ''} sp={sp} options={BUCKETS.map(([k, l]) => [k, k ? `${l} (${count(k)})` : l])} />
    <Table<Q> testId="tolls" rows={data.queue} empty="Nothing in this queue." cols={[{ key: 'notice', label: 'Notice', render: (r) => <Link prefetch={false} className="link" href={`/admin/tolls/${r.id}`}>{String(r.notice_number ?? r.external_ref ?? 'open')}</Link> },
      { key: 'bucket', label: 'Queue', render: (r) => <Badge s={r.bucket === 'unmatched' ? 'failed' : r.bucket === 'needs_review' ? 'needs_review' : 'open'}>{label(r.bucket)}</Badge> }, { key: 'kind', label: 'Kind', render: (r) => label(r.kind) }, { key: 'authority', label: 'Issued by' },
      { key: 'plate', label: 'Plate' }, { key: 'occurred_at', label: 'When', render: (r) => t(r.occurred_at) }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) },
      { key: 'matched', label: 'Matched to', render: (r) => <>{label(r.matched_to)} {r.booking_number ? <BookingLink n={r.booking_number} /> : null} <span className="muted small">{String(r.match_confidence ?? '')}</span></> },
      { key: 'age', label: 'Age', render: (r) => <span className={r.past_charge_by ? 'ad-late' : r.due_soon ? 'ad-flag ad-flag--red' : undefined}>{r.age_days} d</span> }, { key: 'charge_by', label: 'Charge by', render: (r) => d(r.charge_by) }]} />
  </>);
}
