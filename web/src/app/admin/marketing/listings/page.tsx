import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, Card, PageHead, d } from '@/features/admin/ui';
import { CHANNELS, isChannel, type AdChannel } from '@/features/ads/channels';
import { writeListing, type CarFacts, type Rules } from '@/features/ads/listing';
import { CopyText } from '@/features/ads/CopyText';
import { MarketingTabs } from '@/features/ads/MarketingTabs';
import { photoUrl } from '@/lib/photo';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Listings', path: '/admin/marketing/listings', noindex: true, description: 'Listing text for each car and channel, with the tracked link and the photo order; record where each ad is posted.' });
type Posting = { id: string; vehicle_id: string; channel: string; channel_label: string; url: string | null; posted_on: string; needs_update: boolean; update_reason: string | null; updated_on: string | null };
type Data = { today: string; site_url: string; rules: Rules; cars: CarFacts[]; postings: Posting[] };

// Admin > Marketing > Listings (migration 0167, the spec's task 4): choose a car and a channel, get the title, the text, the
// price line and the hashtags within the channel's limits, the link back to the car's page (utm_source = the channel,
// utm_campaign = the car code) and the photos in order; copy each; then record the ad as posted (its address and date)
// so a rate change later opens a task to update it. Nothing is posted from here.
export default async function Listings({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/marketing/listings'), searchParams]);
  const data = await read<Data>('ads_listings');
  const car = data.cars.find((c) => c.vehicle_id === sp.car) ?? data.cars.find((c) => c.taking) ?? data.cars[0];
  const channel: AdChannel = isChannel(sp.channel) ? sp.channel : 'fb_marketplace';
  const spec = CHANNELS.find((c) => c.key === channel)!;
  const l = car ? writeListing(car, data.rules, channel, data.site_url) : null;
  const posted = car ? data.postings.filter((p) => p.vehicle_id === car.vehicle_id) : [];
  const live = posted.find((p) => p.channel === channel);
  const refresh = ['/admin/marketing/listings', '/admin/marketing/ads'];
  return (<>
    <PageHead kicker="Marketing" title="Listings" purpose="The text of an ad for each car and channel, ready to paste, with the tracked link and the photo order. Record where you posted it." />
    <MarketingTabs current="/admin/marketing/listings" />
    <Card title="Car and channel" testId="ads-pick">
      <form className="ad-row" method="get" action="/admin/marketing/listings" style={{ display: 'flex', flexWrap: 'wrap', gap: '0.75rem', alignItems: 'flex-end' }}>
        <div className="field"><label className="label" htmlFor="ads-car">Car</label>
          <select className="select" id="ads-car" name="car" defaultValue={car?.vehicle_id} data-testid="ads-car">
            {data.cars.map((c) => <option key={c.vehicle_id} value={c.vehicle_id}>{c.name}{c.car_code ? ` (${c.car_code})` : ''}{c.taking ? '' : ': not taking requests'}</option>)}
          </select></div>
        <div className="field"><label className="label" htmlFor="ads-channel">Channel</label>
          <select className="select" id="ads-channel" name="channel" defaultValue={channel} data-testid="ads-channel">
            {CHANNELS.map((c) => <option key={c.key} value={c.key}>{c.label}</option>)}
          </select></div>
        <button className="btn btn--primary btn--sm" type="submit" data-testid="ads-show">Write it</button>
      </form>
      {!car && <p className="small muted">No car has a listing yet. Publish a car first (Cars &gt; Listings).</p>}
    </Card>
    {car && l && (<>
      <Card title={`${spec.label}: ${car.name}`} testId="ads-text" aside={live ? <Badge s={live.needs_update ? 'draft' : 'published'}>{live.needs_update ? 'Posted: needs updating' : `Posted ${d(live.posted_on)}`}</Badge> : <Badge s="closed">Not posted yet</Badge>}>
        <p className="small muted">{spec.how}</p>
        {l.warnings.length > 0 && <ul className="small" data-testid="ads-warnings">{l.warnings.map((w) => <li key={w}>{w}</li>)}</ul>}
        {live?.needs_update && <p className="small" data-testid="ads-needs-update"><b>Why it needs updating:</b> {live.update_reason}</p>}
        <div className="stack">
          {l.title !== null && <CopyText label="Title" value={l.title} max={l.limits.title?.[1]} testId="ads-title" />}
          <CopyText label="Price line" value={l.priceLine} testId="ads-price" />
          <CopyText label={channel === 'instagram' || channel === 'facebook_page' ? 'Caption' : 'Description'} value={l.body} rows={Math.min(16, Math.max(6, l.body.split('\n').length + 2))} max={l.limits.body[1]} testId="ads-body" />
          {l.hashtags.length > 0 && <CopyText label="Hashtags" value={l.hashtags.join(' ')} testId="ads-tags" />}
          <CopyText label="Tracked link" value={l.link} testId="ads-link" />
          {l.bookingNote && <p className="small muted">{l.bookingNote}</p>}
        </div>
      </Card>
      <Card title={`Photos, in this order (${l.photos.length} of the ${spec.photoMax} ${spec.label} takes)`} testId="ads-photos">
        {l.photos.length === 0 ? <p className="small muted">No listing photos yet.</p> : (
          <ol className="ads-photos" style={{ listStyle: 'none', margin: 0, padding: 0, display: 'grid', gap: '0.75rem', gridTemplateColumns: 'repeat(auto-fill, minmax(9rem, 1fr))' }}>
            {l.photos.map((p, i) => (
              <li key={p.path} style={{ position: 'relative' }}>
                <a href={photoUrl(p.path)} target="_blank" rel="noopener" download>
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img src={photoUrl(p.path)} alt={p.alt || `${car.name}, photo ${i + 1}`} loading="lazy" style={{ width: '100%', aspectRatio: '4 / 3', objectFit: 'cover', borderRadius: '6px', display: 'block' }} />
                </a>
                <span className="small"><b>{i + 1}.</b> {p.label ?? p.shot ?? 'Photo'}{p.sample ? ' (sample)' : ''}</span>
              </li>))}
          </ol>)}
        <p className="small muted">Open a photo to save it, then add them to the ad in this order: the first is the cover.</p>
      </Card>
      <Card title="Record the ad" testId="ads-record">
        <p className="small muted">Once it is up, paste its address. When this car&apos;s rates or availability change, a task asks the sales assistants to update this ad, with the new text.</p>
        <Act action="ad_posting_save" variant="primary" testId="ads-mark-posted" label={live ? 'Mark the ad updated' : 'Mark as posted'} title={live ? `The ${spec.label} ad, updated` : `Posted on ${spec.label}`} refresh={refresh}
          done={live ? 'Recorded as updated.' : 'Recorded as posted.'}
          payload={{ vehicle: car.vehicle_id, channel, title: l.title, body: l.body, price_line: l.priceLine }}
          fields={[{ name: 'url', label: 'The ad\'s address (https://...)', type: 'text', value: live?.url ?? '', wide: true, required: channel !== 'google_business' && channel !== 'instagram' },
            { name: 'posted_on', label: live ? 'Date updated' : 'Date posted', type: 'date', value: data.today, required: true }, { name: 'note', label: 'Note (region, category)', type: 'text' }]} />
        {posted.length > 0 && (
          <ul className="small" data-testid="ads-car-postings">{posted.map((p) => (
            <li key={p.id}><Link prefetch={false} className="link" href={`/admin/marketing/listings?car=${car.vehicle_id}&channel=${p.channel}`}>{p.channel_label}</Link>: posted {d(p.posted_on)}{p.updated_on && p.updated_on !== p.posted_on ? `, updated ${d(p.updated_on)}` : ''}{p.needs_update ? ' (needs updating)' : ''}{p.url ? <> · <a className="link" href={p.url} target="_blank" rel="noopener noreferrer">open the ad</a></> : null}</li>))}
          </ul>)}
      </Card>
    </>)}
  </>);
}
