import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { TollImport } from '@/features/admin/TollImport';
import { $, Badge, Card, Filters, PageHead, Table, d, t, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Tolls and tickets', path: '/va/tolls', noindex: true, description: 'Toll and ticket matching.' });

type Q = Record<string, unknown> & { id: string; bucket: string; age_days: number; due_soon: boolean; past_charge_by: boolean };

// Toll and ticket matching for Finance (05-va.md section 2, 10-tolls-tickets-damages.md): the same queues,
// import and actions as the Admin's; naming a renter to an authority and billing damage stay with an Admin.
export default async function VaTolls({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([vaPage('/va/tolls', ['finance']), searchParams]);
  const data = await read<{ queue: Q[] }>('tolls', sp.bucket ? { bucket: sp.bucket } : {});
  const ids = (b: string) => data.queue.filter((q) => q.bucket === b).map((q) => q.id);
  const R = ['/va/tolls'];
  return (
    <>
      <PageHead title="Tolls and tickets">
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/va/tolls/read">Read a notice</Link>
        {ids('needs_review').length > 0 && <Act action="toll_bulk_confirm" payload={{ ids: ids('needs_review') }} label="Bulk confirm high-confidence" refresh={R} />}
        {ids('matched_not_charged').length > 0 && <Act action="toll_charge" payload={{ ids: ids('matched_not_charged') }} label={`Charge ${ids('matched_not_charged').length} matched`} confirm="Charge every matched notice to its renter." refresh={R} />}
      </PageHead>
      <Filters base="/va/tolls" name="bucket" value={sp.bucket ?? ''} sp={sp} options={[['', 'All'], ['unmatched', 'Unmatched'], ['needs_review', 'Needs review'], ['matched_not_charged', 'Matched, not charged'], ['disputed', 'Disputed']]} />
      <Table<Q> testId="va-tolls" rows={data.queue} empty="Nothing in this queue." cols={[{ key: 'notice', label: 'Notice', render: (r) => String(r.notice_number ?? r.external_ref ?? 'open') },
        { key: 'bucket', label: 'Queue', render: (r) => <Badge s={r.bucket === 'unmatched' ? 'failed' : 'open'}>{label(r.bucket)}</Badge> }, { key: 'kind', label: 'Kind', render: (r) => label(r.kind) },
        { key: 'plate', label: 'Plate' }, { key: 'occurred_at', label: 'When', render: (r) => t(r.occurred_at) }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) },
        { key: 'matched', label: 'Matched to', render: (r) => `${label(r.matched_to)} ${String(r.booking_number ?? '')}` },
        { key: 'age', label: 'Age', render: (r) => <span className={r.past_charge_by ? 'ad-late' : undefined}>{r.age_days} d</span> }, { key: 'charge_by', label: 'Charge by', render: (r) => d(r.charge_by) },
        { key: 'act', label: '', render: (r) => <span className="ad-actions"><Act action="toll_rematch" payload={{ id: r.id }} label="Match again" refresh={R} /><Act action="toll_dispute" payload={{ id: r.id }} label="Dispute" fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={R} /></span> }]} />
      <Card title="Import a statement"><TollImport /></Card>
    </>
  );
}
