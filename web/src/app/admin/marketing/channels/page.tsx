import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, Card, PageHead, Table, t } from '@/features/admin/ui';
import { CopyFeed } from '@/features/channels/CopyFeed';
import { MarketingTabs } from '@/features/ads/MarketingTabs';
import { siteUrl } from '@/lib/site';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Listing channels', path: '/admin/marketing/channels', noindex: true, description: 'Other car rental sites and directories: status, logins, notes, and the inventory feed each one can take.' });
type Channel = { id: string; slug: string; name: string; url: string | null; kind: string; status: string; login_owner: string | null; notes: string | null; how_to_list: string | null;
  feed_enabled: boolean; feed_token: string; feed_last_at: string | null; feed_fetches: number };
type Car = { id: string; name: string; car_code: string | null; supply_type: string; listed: boolean; opt_out: boolean };
const STATUS: Array<[string, string]> = [['not_started', 'Not started'], ['applied', 'Applied'], ['live', 'Live'], ['paused', 'Paused'], ['not_for_us', 'Not for us']];
const KIND: Record<string, string> = { peer_to_peer: 'Car sharing', aggregator: 'Aggregator', classifieds: 'Classifieds', social: 'Social', search: 'Search', directory: 'Directory' };
const tone = (s: string) => (s === 'live' ? 'published' : s === 'applied' ? 'draft' : 'closed');

// Admin > Marketing > Listing channels (migration 0214): the checklist of other sites (status, who holds the login, notes)
// and each channel's own feed of our cars (JSON, CSV, XML). No site here is connected automatically: a channel goes live
// when it is applied for on that site, and a site or partner program that takes a feed is given that channel's address.
export default async function Channels() {
  const { read } = await page('/admin/marketing/channels');
  const [d, site] = await Promise.all([read<{ hourly_max: number; channels: Channel[]; cars: Car[]; partner_cars: number }>('listing_channels'), Promise.resolve(siteUrl())]);
  const base = site.replace(/\/$/, '');
  const refresh = ['/admin/marketing/channels'];
  const feed = (c: Channel, f: string) => `${base}/api/feeds/${c.feed_token}?format=${f}`;
  const live = d.channels.filter((c) => c.status === 'live').length;
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/marketing/listings">Marketing</Link>} title="Listing channels"
      purpose={`Where our cars can be listed beyond carmacars.ca: ${live} live of ${d.channels.length}. Every feed has CarmaCars' own and co-hosted cars only, never a partner's car.`} />
    <MarketingTabs current="/admin/marketing/channels" />
    <Card title="Channels" testId="channels" aside={<Act action="listing_channel_save" label="Add a channel" refresh={refresh} done="Added." testId="channel-add"
      fields={[{ name: 'name', label: 'Site name', type: 'text', required: true }, { name: 'url', label: 'Address (https://...)', type: 'text' },
        { name: 'kind', label: 'Kind', type: 'select', value: 'directory', options: Object.entries(KIND) }, { name: 'login_owner', label: 'Who holds the login', type: 'text' }, { name: 'notes', label: 'Notes', type: 'textarea' }]} />}>
      <Table<Channel> rows={d.channels} rowKey={(c) => c.id} cols={[
        { key: 'name', label: 'Channel', render: (c) => <span>{c.url ? <a className="link" href={c.url} target="_blank" rel="noopener noreferrer">{c.name}</a> : c.name}<br /><span className="xs muted">{KIND[c.kind] ?? c.kind}</span></span> },
        { key: 'status', label: 'Status', render: (c) => <Badge s={tone(c.status)}>{STATUS.find((s) => s[0] === c.status)?.[1] ?? c.status}</Badge> },
        { key: 'login_owner', label: 'Login' },
        { key: 'notes', label: 'How and notes', className: 'wrap', render: (c) => <span className="small">{c.how_to_list}{c.notes ? <><br /><b>Notes:</b> {c.notes}</> : null}</span> },
        { key: 'feed', label: 'Feed', render: (c) => c.feed_enabled ? <span className="stack" style={{ gap: 4 }}>
            <CopyFeed url={feed(c, 'json')} label="JSON" /><CopyFeed url={feed(c, 'csv')} label="CSV" /><CopyFeed url={feed(c, 'xml')} label="XML" />
            <span className="xs muted">{c.feed_last_at ? `Last read ${t(c.feed_last_at)} (${c.feed_fetches})` : 'Not read yet'}</span></span> : <span className="small muted">Off</span> },
        { key: 'act', label: '', render: (c) => <span className="ad-actions">
          <Act action="listing_channel_save" payload={{ id: c.id }} label="Update" refresh={refresh} done="Saved." testId={`channel-${c.slug}`}
            fields={[{ name: 'status', label: 'Status', type: 'select', value: c.status, options: STATUS }, { name: 'login_owner', label: 'Who holds the login', type: 'text', value: c.login_owner },
              { name: 'url', label: 'Address (https://...)', type: 'text', value: c.url }, { name: 'notes', label: 'Notes', type: 'textarea', value: c.notes }, { name: 'feed_enabled', label: 'Feed on', type: 'bool', value: c.feed_enabled }]} />
          {c.feed_enabled && <Act action="listing_channel_feed_rotate" payload={{ id: c.id }} label="New key" variant="quiet" confirm="The old feed address stops working. Give the site the new one." refresh={refresh} done="New address made." />}
        </span> }]} />
      <p className="small muted">Each feed is read at most {d.hourly_max} times an hour, and each answer is kept 15 minutes. Car links carry utm_source with the channel, so bookings it sends show in Bookings by channel.</p>
    </Card>
    <Card title="Cars in the feeds" testId="channel-cars">
      <p className="small muted">CarmaCars&apos; own and co-hosted cars on the site. {d.partner_cars} partner cars (01 Motors and others) are never in any feed.</p>
      <Table<Car> rows={d.cars} rowKey={(c) => c.id} empty="No cars." cols={[{ key: 'name', label: 'Car' }, { key: 'car_code', label: 'Code' },
        { key: 'supply_type', label: 'Supply', render: (c) => (c.supply_type === 'company' ? 'CarmaCars' : 'Co-hosted') },
        { key: 'in', label: 'In the feeds', render: (c) => (!c.listed ? <span className="small muted">Not on the site</span> : c.opt_out ? <Badge s="closed">Kept out</Badge> : <Badge s="published">Yes</Badge>) },
        { key: 'act', label: '', render: (c) => <Act action="vehicle_channel_opt_out" payload={{ vehicle: c.id, opt_out: !c.opt_out }} label={c.opt_out ? 'Put back' : 'Keep out'} variant="quiet" refresh={refresh} done="Saved." testId={`channel-car-${c.id.slice(0, 8)}`} /> }]} />
    </Card>
  </>);
}
