import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { storage } from '@/integrations/storage';
import type { Bucket } from '@/integrations/storage';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Card, Kv, PageHead, t, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Damage', path: '/admin/damages', noindex: true, description: 'One damage intake.' });
type R = Record<string, unknown>;

export default async function Damage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read } = await page(`/admin/damages/${id}`);
  const x = await read<(R & { candidates: { candidates: R[]; suggested: number | null; decision: string } | null; before: R | null; after: R | null; reports: R[]; photos: Array<{ report_id: string; shot: string; path: string; bucket: string }>; threshold_cents: number }) | null>('damage', { id });
  if (!x) notFound();
  const s = await storage();
  const photos = await Promise.all(x.photos.map(async (p) => ({ ...p, url: await s.signedDownloadUrl((p.bucket || 'condition-photos') as Bucket, p.path, 300) })));
  const R = [`/admin/damages/${id}`, '/admin/damages'];
  const over = Number(x.cost_cents ?? 0) >= x.threshold_cents;
  const side = (which: 'before' | 'after') => {
    const rep = x[which]; const ph = photos.filter((p) => p.report_id === rep?.id);
    return <Card title={which === 'before' ? 'Before' : 'After'}>{rep ? <><p className="small">{label(rep.kind)} · {t(rep.performed_at)}</p>
      {ph.length ? <ul className="ad-photos">{ph.map((p) => <li key={p.path}>
        {/* eslint-disable-next-line @next/next/no-img-element -- signed private photo */}
        <img src={p.url} alt={`${which} photo: ${label(p.shot)}`} width={300} height={200} loading="lazy" /><span>{label(p.shot)}</span></li>)}</ul> : <p className="small muted">No photos.</p>}</> : <p className="small muted">No report chosen.</p>}</Card>;
  };
  return (<>
    <PageHead kicker={<Link className="link" href="/admin/damages">Damage</Link>} title={<>{String(x.intake_number)} <Badge s={String(x.status)} /></>}>
      <Act action="damage_confirm" payload={{ id }} label="Confirm the suggestion" refresh={R} />
      <Act action="damage_bill" payload={{ id }} label="Bill the damage" variant="primary" confirm={over ? `The cost is ${$(x.cost_cents)}, at or over the ${$(x.threshold_cents)} deductible: billing opens a fleet policy claim and bills the renter the deductible and the fee.` : `The cost is under the ${$(x.threshold_cents)} deductible: the renter is billed the repair at cost and the fee.`} fields={[{ name: 'override_reason', label: 'Reason, if reporting after 48 hours' }]} refresh={R} />
    </PageHead>
    <p className={`ad-tie${over ? ' is-bad' : ''}`}>{over ? `At or over ${$(x.threshold_cents)}: fleet policy claim path.` : `Under ${$(x.threshold_cents)}: billed at cost.`}</p>
    <div className="ad-cols ad-cols--2">
      <Card title="Damage"><Kv rows={[['Vehicle', String(x.vehicle_name ?? '')], ['Found', t(x.found_at)], ['Happened', x.occurred_at ? t(x.occurred_at) : `${t(x.window_from)} to ${t(x.window_to)}`], ['Where', String(x.location ?? '')], ['What', String(x.description ?? '')], ['Cost', `${$(x.cost_cents)} ${label(x.cost_kind)} ${String(x.shop_name ?? '')}`], ['Matched', <>{label(x.matched_to)} {x.booking_number ? <BookingLink n={x.booking_number} /> : null} {String(x.match_confidence ?? '')}</>], ['Route', label(x.route)]]} /></Card>
      <Card title="Who had the car">{x.candidates?.candidates.length ? <ol className="ad-list">{x.candidates.candidates.map((c, i) => <li key={i}><span><b>{label(c.kind)}</b> {c.booking_number ? <BookingLink n={c.booking_number} /> : null} <span className="muted small">{String(c.confidence ?? '')}</span></span><Act action="damage_confirm" payload={{ id, choice: { index: i } }} label="Confirm" refresh={R} /></li>)}</ol> : <p className="small muted">No candidate.</p>}</Card>
      {side('before')}{side('after')}
    </div>
  </>);
}
