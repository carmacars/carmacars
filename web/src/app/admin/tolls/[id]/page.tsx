import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Card, Kv, PageHead, t, d, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Notice', path: '/admin/tolls', noindex: true, description: 'Match review for one notice.' });
type R = Record<string, unknown>;
type Cand = R & { kind: string; booking_number?: string; renter_first_name?: string; window_start?: string; window_end?: string; confidence?: string; near_boundary?: boolean; position_pct?: number; staff_name?: string; reason?: string; late_return?: boolean; extended?: boolean; swapped?: boolean; still_on_rent?: boolean };

// Match review (10-tolls-tickets-damages.md section 2): the candidates with their evidence; confirm one, then charge, bill to the owner, dispute or close.
export default async function Toll({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read } = await page(`/admin/tolls/${id}`);
  const n = await read<(R & { candidates: { candidates: Cand[]; decision: string; suggested: number | null; reason?: string } | null }) | null>('toll', { id });
  if (!n) notFound();
  const P = { id };
  const R = [`/admin/tolls/${id}`, '/admin/tolls'];
  const cands = n.candidates?.candidates ?? [];
  const status = String(n.status);
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/tolls">Tolls and tickets</Link>} title={<>{label(n.kind)} {String(n.notice_number ?? '')} <Badge s={status} /></>}>
      <Act action="toll_rematch" payload={P} label="Match again" refresh={R} />
      {n.matched_to === 'renter' && !!n.booking_id && !n.charged_at && <Act action="toll_charge" payload={{ ids: [id] }} label="Charge the renter" variant="primary" testId="toll-charge" confirm="Charge this notice and its administration fee on a later-charge statement." refresh={R} />}
      {n.matched_to === 'owner' && !n.owner_deduction_id ? ( <Act action="toll_bill_owner" payload={P} label="Bill to the owner" refresh={R} />) : null}
      {n.matched_to === 'staff' && !n.paid_by_company_at && <Act action="toll_company_paid" payload={P} label="CarmaCars pays" fields={[{ name: 'reference', label: 'Payment reference', required: true }]} refresh={R} />}
      <Act action="toll_authority_paid" payload={P} label="Paid the authority" fields={[{ name: 'reference', label: 'Reference', required: true }]} refresh={R} />
      <Act action="toll_dispute" payload={P} label="Dispute" fields={[{ name: 'reason', label: 'Reason', required: true }]} refresh={R} />
      <Act action="toll_close" payload={P} label="Close" variant="danger" fields={[{ name: 'reason', label: 'Reason', required: true }]} refresh={R} />
    </PageHead>
    <div className="ad-cols ad-cols--main">
      <div className="stack">
        <Card title="Candidates" testId="toll-candidates" aside={<span className="small">{n.candidates ? `${label(n.candidates.decision)}${n.candidates.reason ? `: ${n.candidates.reason}` : ''}` : 'no vehicle found'}</span>}>
          {cands.length ? <ol className="ad-list">{cands.map((c, i) => (
            <li key={i} data-testid="toll-candidate"><span><b>{label(c.kind)}</b> {c.booking_number ? <BookingLink n={c.booking_number} /> : null} {c.renter_first_name ?? c.staff_name ?? ''} <span className="muted small">{c.confidence} confidence{n.candidates?.suggested === i ? ', suggested' : ''}</span></span>
              <Act action="toll_confirm" payload={{ id, choice: { index: i } }} label="Confirm" variant={n.candidates?.suggested === i ? 'primary' : 'ghost'} testId={`toll-confirm-${i}`} refresh={R} />
              <span className="ad-sub">{c.window_start ? `${t(c.window_start)} to ${c.window_end ? t(c.window_end) : 'still on rent'}` : ''}{c.position_pct !== undefined ? ` · ${c.position_pct}% into the window` : ''}{c.near_boundary ? ' · near the edge' : ''}{c.late_return ? ' · late return' : ''}{c.extended ? ' · extended' : ''}{c.swapped ? ' · swapped' : ''}{c.reason ? ` · ${c.reason}` : ''}</span></li>))}</ol>
            : <p className="small muted">Nobody on record had the car. Close it with the reason, or dispute it.</p>}
        </Card>
      </div>
      <Card title="Notice"><Kv rows={[['Issued by', String(n.authority ?? '')], ['Plate', String(n.plate ?? '')], ['Vehicle', String(n.vehicle_name ?? '')], ['Found by', label(n.vehicle_found_by)], ['When', `${t(n.occurred_at)}${n.time_unknown ? ' (time not stated)' : ''}`], ['Place', String(n.place ?? '')],
        ['Amount', $(n.amount_cents)], ['Administration fee', $(n.admin_fee_cents)], ['Received', d(n.received_on)], ['Charge by', d(n.charge_by)], ['Matched to', `${label(n.matched_to)} ${String(n.booking_number ?? '')}`], ['Confidence', String(n.match_confidence ?? '')], ['How', label(n.matched_how)], ['Charged', t(n.charged_at)], ['Disputed', String(n.dispute_reason ?? '')]]} /></Card>
    </div>
  </>);
}
