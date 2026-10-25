import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, Filters, PageHead, Table, d } from '@/features/admin/ui';
import { MarketingTabs } from '@/features/ads/MarketingTabs';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Posted ads', path: '/admin/marketing/ads', noindex: true, description: 'Every ad posted by hand, which need updating after a rate change, and the ones taken down.' });
type Row = { id: string; vehicle_id: string; car: string; car_code: string | null; channel: string; channel_label: string; url: string | null; posted_on: string; status: string; price_line: string | null;
  needs_update: boolean; update_reason: string | null; updated_on: string | null; removed_on: string | null; removed_reason: string | null; posted_by: string | null };

// Admin > Marketing > Posted ads (migration 0167, the spec's task 6): the ads posted by hand on each channel. A rate or
// availability change that matters opens a task for the sales assistants and marks the ad here; the new text is one click
// away (Listings), and "Mark updated" records the new figures and closes the task.
export default async function PostedAds({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/marketing/ads'), searchParams]);
  const status = sp.status ?? '';
  const r = await read<{ rows: Row[]; counts: { live: number; needs_update: number; removed: number } }>('ads_postings', { status });
  const refresh = ['/admin/marketing/ads', '/admin/marketing/listings'];
  return (<>
    <PageHead kicker="Marketing" title="Posted ads" purpose={`${r.counts.live} live, ${r.counts.needs_update} to update. A change of 3% or more in a car's rates, of its deposit, kilometres or delivery fee, or the car leaving the site, marks its ads and opens a task.`} />
    <MarketingTabs current="/admin/marketing/ads" />
    <Filters base="/admin/marketing/ads" name="status" value={status} sp={sp} options={[['', `Live (${r.counts.live})`], ['needs_update', `To update (${r.counts.needs_update})`], ['removed', `Taken down (${r.counts.removed})`], ['all', 'All']]} />
    <Table<Row> testId="ads-postings" rows={r.rows} rowKey={(x) => x.id} empty="No ad recorded yet. Write one under Listings and mark it posted." cols={[
      { key: 'car', label: 'Car', render: (x) => <Link prefetch={false} className="link" href={`/admin/marketing/listings?car=${x.vehicle_id}&channel=${x.channel}`}>{x.car}{x.car_code ? ` (${x.car_code})` : ''}</Link> },
      { key: 'channel_label', label: 'Channel' },
      { key: 'posted_on', label: 'Posted', render: (x) => <>{d(x.posted_on)}{x.updated_on && x.updated_on !== x.posted_on ? <span className="ad-sub">updated {d(x.updated_on)}</span> : null}</> },
      { key: 'status', label: 'Status', className: 'wrap', render: (x) => x.status === 'removed' ? <span><Badge s="closed">Taken down</Badge><span className="ad-sub">{d(x.removed_on)}: {x.removed_reason}</span></span>
        : x.needs_update ? <span data-testid={`ads-update-${x.channel}`}><Badge s="draft">Needs updating</Badge><span className="ad-sub">{x.update_reason}</span></span> : <Badge s="published">Up to date</Badge> },
      { key: 'price_line', label: 'Says', className: 'wrap' },
      { key: 'url', label: 'Ad', render: (x) => x.url ? <a className="link" href={x.url} target="_blank" rel="noopener noreferrer">Open</a> : <span className="muted">no address</span> },
      { key: 'act', label: '', render: (x) => x.status === 'live' ? <span className="ad-actions">
        {x.needs_update && <Link prefetch={false} className="btn btn--primary btn--sm" href={`/admin/marketing/listings?car=${x.vehicle_id}&channel=${x.channel}`}>New text</Link>}
        <Act action="ad_posting_remove" payload={{ id: x.id }} label="Taken down" refresh={refresh} done="Recorded as taken down." fields={[{ name: 'reason', label: 'Why (sold out, car off the site, removed by the site)', type: 'text' }]} />
      </span> : null }]} />
  </>);
}
