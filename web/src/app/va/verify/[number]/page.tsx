import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Badge, Card, Kv, PageHead, d, label } from '@/features/admin/ui';
import { VerifyUpload } from '@/features/va/VerifyUpload';
import { storage, type Bucket } from '@/integrations/storage';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Identity review', path: '/va', noindex: true, description: 'Identity and coverage documents of one booking.' });

type U = { id: string; kind: string; driver_id: string | null; status: string; uploaded_at: string; bucket: string; path: string; mime_type: string | null };
type V = { booking_id: string; booking_number: string; return_at: string; coverage_option: number | null; readiness: { all_drivers_verified: boolean; coverage_confirmed: boolean };
  drivers: Array<{ driver_id: string; full_name: string; role: string; date_of_birth: string | null; licence_number: string | null; licence_class: string | null; licence_expiry: string | null; verified_on: string | null }>; uploads: U[] };

// Identity document review (05-va.md section 4.2). The database opens it only while customer service has
// the review task for this booking, and logs every opening; images come through one-minute signed links and
// are never cached.
export default async function Verify({ params }: { params: Promise<{ number: string }> }) {
  const { number } = await params;
  const n = decodeURIComponent(number);
  const { read } = await vaPage(`/va/verify/${n}`, ['cs']);
  const v = await read<V | null>('verification', { booking: n }).catch(() => null);
  if (!v) notFound();
  const s = await storage();
  const link = (u: U) => s.signedDownloadUrl(u.bucket as Bucket, u.path, 60);
  const links = new Map(await Promise.all(v.uploads.filter((u) => u.status === 'submitted').map(async (u) => [u.id, await link(u)] as const)));
  const forDriver = (id: string | null) => v.uploads.filter((u) => u.driver_id === id);
  return (
    <>
      <PageHead kicker={<><Link prefetch={false} className="link" href="/va">Queue</Link> · <Link prefetch={false} className="link" href={`/va/bookings/${encodeURIComponent(n)}`}>{n}</Link></>} title="Identity and coverage" />
      <p className="small muted">Identity {v.readiness.all_drivers_verified ? 'verified' : 'not verified yet'} · coverage {v.readiness.coverage_confirmed ? 'confirmed' : 'not confirmed yet'} · return {d(v.return_at)}</p>
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
      <Card title={`Coverage${v.coverage_option ? `, option ${v.coverage_option}` : ''}`}>
        {forDriver(null).map((u) => <div key={u.id}><p className="pt-kicker">{label(u.kind)} <Badge s={u.status === 'submitted' ? 'needs_review' : u.status} /></p>
          {u.status === 'submitted' && links.get(u.id) ? <VerifyUpload id={u.id} kind={u.kind} src={links.get(u.id)!} pdf={u.mime_type === 'application/pdf'} /> : <p className="small muted">Decided.</p>}</div>)}
        {!forDriver(null).length && <p className="small muted">No proof of coverage uploaded yet.</p>}
      </Card>
    </>
  );
}
