import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Badge, Card, Kv, PageHead, d, label } from '@/features/admin/ui';
import { VerifyUpload } from '@/features/va/VerifyUpload';
import { Act } from '@/features/admin/Act';
import type { ReviewCoverage } from '@/features/coverage/types';
import { storage, type Bucket } from '@/integrations/storage';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Identity review', path: '/va', noindex: true, description: 'Identity and coverage documents of one booking.' });

type U = { id: string; kind: string; driver_id: string | null; status: string; uploaded_at: string; bucket: string; path: string; mime_type: string | null };
type V = { coverage?: ReviewCoverage | null; booking_id: string; booking_number: string; return_at: string; coverage_option: number | null; readiness: { all_drivers_verified: boolean; coverage_confirmed?: boolean };
  drivers: Array<{ driver_id: string; full_name: string; role: string; date_of_birth: string | null; licence_number: string | null; licence_class: string | null; licence_expiry: string | null; verified_on: string | null }>; uploads: U[] };

// Identity document review (05-va.md section 4.2). The database opens it only while customer service has
// the review task for this booking, and logs every opening; images come through one-minute signed links and
// are never cached. Sales (0169) review the licence front, back and selfie here too: the screen has no coverage
// for them, and the database refuses the proof of coverage and the Protection Plan.
export default async function Verify({ params }: { params: Promise<{ number: string }> }) {
  const { number } = await params;
  const n = decodeURIComponent(number);
  const { read, fn } = await vaPage(`/va/verify/${n}`, ['cs', 'sales']);
  const sales = fn === 'sales';
  const v = await read<V | null>('verification', { booking: n }).catch(() => null);
  if (!v) notFound();
  // Sales may review a licence on a booking whose own page they cannot open (the booking read is narrower)
  const bookingOpen = !sales || !!(await read<{ number: string } | null>('booking', { number: n }).catch(() => null));
  const s = await storage();
  const link = (u: U) => s.signedDownloadUrl(u.bucket as Bucket, u.path, 60);
  const links = new Map(await Promise.all(v.uploads.filter((u) => u.status === 'submitted').map(async (u) => [u.id, await link(u)] as const)));
  const forDriver = (id: string | null) => v.uploads.filter((u) => u.driver_id === id);
  const cov = v.coverage ?? null;
  const cp = cov?.proof ?? null;
  const pageLinks = new Map(await Promise.all((cp?.pages ?? []).filter((pg) => pg.bucket && pg.path).map(async (pg) => [pg.id, await s.signedDownloadUrl(pg.bucket as Bucket, pg.path!, 60)] as const)));
  return (
    <>
      <PageHead kicker={<><Link prefetch={false} className="link" href="/va">Queue</Link> · {bookingOpen ? <Link prefetch={false} className="link" href={`/va/bookings/${encodeURIComponent(n)}`}>{n}</Link> : n}</>} title={sales ? 'Licence review' : 'Identity and coverage'} />
      <p className="small muted">Identity {v.readiness.all_drivers_verified ? 'verified' : 'not verified yet'}{sales ? '' : ` · coverage ${v.readiness.coverage_confirmed ? 'confirmed' : 'not confirmed yet'}`} · return {d(v.return_at)}</p>
      {(v.uploads.some((u) => u.status === 'submitted') || (!sales && ((cp && cp.status === 'submitted') || (cov?.option === 3 && !cov.confirmed && cov.protection_plan_line)))) && (
        <Card title="Everything waiting, in one step" testId="va-approve-all">
          <p className="small">Look at each document below: the name and date of birth match, class G2 or G, valid past the return, no alteration, the selfie matches{sales ? '' : ', the coverage is active to the return date'}. Reject the wrong one first, with its reason.</p>
          <Act ops action="doc_review_approve_all" payload={{ booking: n }} label="Approve all" variant="primary" refresh={[`/va/verify/${n}`]} testId="va-approve-all-go" done="Approved." />
        </Card>)}
      {v.drivers.map((dr) => (
        <Card key={dr.driver_id} title={<>{dr.full_name} <span className="muted small">{label(dr.role)}</span> {dr.verified_on ? <Badge s="approved">Verified</Badge> : null}</>}>
          <Kv rows={[['Date of birth', dr.date_of_birth ?? ''], ['Licence number', dr.licence_number ?? ''], ['Class', dr.licence_class ?? ''], ['Expiry', dr.licence_expiry ?? '']]} />
          <div className="ad-cols ad-cols--3">{forDriver(dr.driver_id).map((u) => (
            <div key={u.id}><p className="pt-kicker">{label(u.kind)} <Badge s={u.status === 'submitted' ? 'needs_review' : u.status} /></p>
              {u.status === 'submitted' && links.get(u.id) ? <VerifyUpload id={u.id} kind={u.kind} src={links.get(u.id)!} pdf={u.mime_type === 'application/pdf'} /> : <p className="small muted">Decided.</p>}</div>))}
          </div>
          {!forDriver(dr.driver_id).length && <p className="small muted">Nothing uploaded for this driver yet.</p>}
        </Card>
      ))}
      {!sales && <Card title={`Coverage${v.coverage_option ? `, option ${v.coverage_option}` : ''}`} testId="va-coverage">
        {cov && <Kv rows={[
          ['Option', cov.option_label], ['Confirmed', cov.confirmed ? 'Yes' : 'Not yet: the car is not handed over until it is'], ['Return', cov.return_date],
          ...(cov.option === 1 && cp ? [['Insurer', cp.insurer_name ?? ''], ['Policy number', cp.policy_number ?? ''],
            ['Policy expiry', `${cp.policy_expiry ?? ''}${cp.policy_valid ? ', after the return: fine' : ', NOT after the return date'}`]] as Array<[string, string]> : []),
          ...(cov.option === 2 ? [['Card paid with', cov.card.brand ? `${cov.card.brand.toUpperCase()} ending ${cov.card.last4 ?? ''}, ${cov.card.funding ?? 'unknown'}` : 'Not paid yet'],
            ['Cardholder', `${cov.card.cardholder_name ?? ''}${cov.card.name_matches ? ' (matches the renter)' : ' (does NOT match the renter)'}`],
            ['Eligible', cov.card.eligible ? 'Yes: a credit card in the renter\u2019s name' : (cov.card.message ?? 'No')],
            ['Renter confirmed', cp?.renter_confirmed_at ? `${d(cp.renter_confirmed_at)}: ${cp.confirmation_text ?? ''}` : 'Not yet'],
            ['Still the Card on File', cp ? (cp.card_is_card_on_file ? 'Yes' : 'No: ask the renter again') : '']] as Array<[string, string]> : []),
          ...(cov.option === 3 ? [['Protection Plan on the booking', cov.protection_plan_line ? 'Yes' : 'No line yet']] as Array<[string, string]> : [])]} />}
        {cp && cp.pages.length > 0 && <div className="ad-cols ad-cols--3">{cp.pages.map((pg, i) => (
          <div key={pg.id}><p className="pt-kicker">Page {i + 1} <Badge s={pg.status === 'submitted' ? 'needs_review' : pg.status} /></p>
            {pageLinks.get(pg.id) ? <a className="link" href={pageLinks.get(pg.id)!} target="_blank" rel="noreferrer">{pg.mime_type === 'application/pdf' ? 'Open the PDF' : 'Open the photo'} (link valid one minute)</a> : null}</div>))}</div>}
        {cov && cp && cp.status === 'submitted' && (cov.option === 1 || cov.option === 2) && (
          <div className="ad-actions">
            <Act action="coverage_review" payload={{ proof: cp.id, approve: true }} label="Approve the coverage" variant="primary" refresh={[`/va/verify/${n}`]} testId="coverage-approve" />
            <Act action="coverage_review" payload={{ proof: cp.id, approve: false }} label="Reject" variant="danger" refresh={[`/va/verify/${n}`]} testId="coverage-reject"
              fields={[{ name: 'reason', label: 'Reason the renter sees', type: 'text', required: true }]} />
          </div>)}
        {cov && cov.option === 3 && !cov.confirmed && cov.protection_plan_line && (
          <Act action="protection_plan_confirm" payload={{ booking: n }} label="Confirm the Protection Plan is active" variant="primary" refresh={[`/va/verify/${n}`]} testId="plan-confirm"
            fields={[{ name: 'ref', label: 'Activation reference', type: 'text' }]} />)}
        {!cp && cov?.option !== 3 && <p className="small muted">No proof of coverage yet.</p>}
      </Card>}
      {sales && <p className="small muted" data-testid="va-licence-only">The proof of coverage and the Protection Plan are reviewed by customer service or an Admin.</p>}
    </>
  );
}
