import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { $, Card, PageHead, Table, Tiles } from '@/features/admin/ui';
import { MarketingTabs } from '@/features/ads/MarketingTabs';
import { ChannelChart, type ChannelRow } from '@/features/ads/ChannelChart';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Bookings by channel', path: '/admin/marketing/report', noindex: true, description: 'Requests, bookings, revenue and conversion by channel and month, first or last touch.' });
type MonthRow = { month: string; channel: string; label: string; requests: number; bookings: number; revenue_cents: number };
type Data = { from: string; to: string; model: 'first' | 'last'; totals: { requests: number; bookings: number; revenue_cents: number }; channels: ChannelRow[]; months: MonthRow[]; postings: { live: number; needs_update: number } };
const pct = (bps: number) => `${(bps / 100).toFixed(bps % 100 ? 1 : 0)}%`;
const ok = (s: string | undefined) => (s && /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : undefined);

// Admin > Marketing > Bookings by channel (migration 0167, the spec's task 5): every request of the period counted once,
// under the channel staff set on the booking, else the renter's visit (its campaign source or the site it came from; the
// first visit or the last one before the request), else a referral code, else how it reached us. A booking is a request
// confirmed, paid or completed; revenue is its rental charge after discounts. The months add up to the Bookings list.
export default async function ChannelReport({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/marketing/report'), searchParams]);
  const model = sp.model === 'first' ? 'first' : 'last';
  const r = await read<Data>('ads_report', { from: ok(sp.from), to: ok(sp.to), model });
  const conv = r.totals.requests ? Math.round((r.totals.bookings * 10000) / r.totals.requests) : 0;
  return (<>
    <PageHead kicker="Marketing" title="Bookings by channel" purpose="Where requests and bookings came from, by month. Set the source on a booking by hand when the renter told you (a Kijiji reply, a walk-in)." />
    <MarketingTabs current="/admin/marketing/report" />
    <form className="vh-filters" method="get" action="/admin/marketing/report" data-testid="ads-report-filters">
      <div className="field"><label className="label" htmlFor="rp-from">From</label><input className="input" type="date" id="rp-from" name="from" defaultValue={r.from} /></div>
      <div className="field"><label className="label" htmlFor="rp-to">To</label><input className="input" type="date" id="rp-to" name="to" defaultValue={r.to} /></div>
      <div className="field"><label className="label" htmlFor="rp-model">Count each request under</label>
        <select className="select" id="rp-model" name="model" defaultValue={model}><option value="last">The last visit before the request</option><option value="first">The first visit</option></select></div>
      <div className="vh-filters__go"><button className="btn btn--primary btn--sm" type="submit">Show</button></div>
    </form>
    <Tiles items={[{ k: 'Requests', v: r.totals.requests }, { k: 'Bookings', v: r.totals.bookings }, { k: 'Conversion', v: pct(conv) }, { k: 'Revenue', v: $(r.totals.revenue_cents), sub: 'rental charge after discounts' },
      { k: 'Live ads', v: r.postings.live, sub: r.postings.needs_update ? `${r.postings.needs_update} to update` : undefined, href: '/admin/marketing/ads', warn: r.postings.needs_update > 0 }]} />
    <Card title="By channel" testId="ads-report-channels">
      <ChannelChart rows={r.channels} money={(c) => $(c)} />
      <Table<ChannelRow & Record<string, unknown>> rows={r.channels as Array<ChannelRow & Record<string, unknown>>} rowKey={(x) => x.channel} empty="No requests in these dates." cols={[
        { key: 'label', label: 'Channel' }, { key: 'requests', label: 'Requests', num: true }, { key: 'bookings', label: 'Bookings', num: true },
        { key: 'conversion_bps', label: 'Conversion', num: true, render: (x) => pct(x.conversion_bps) }, { key: 'revenue_cents', label: 'Revenue', num: true, render: (x) => $(x.revenue_cents) }]} />
    </Card>
    <Card title="By month" testId="ads-report-months">
      <Table<MonthRow & Record<string, unknown>> rows={r.months as Array<MonthRow & Record<string, unknown>>} rowKey={(x) => `${x.month}-${x.channel}`} empty="No requests in these dates." cols={[
        { key: 'month', label: 'Month' }, { key: 'label', label: 'Channel' }, { key: 'requests', label: 'Requests', num: true }, { key: 'bookings', label: 'Bookings', num: true },
        { key: 'revenue_cents', label: 'Revenue', num: true, render: (x) => $(x.revenue_cents) }]} />
    </Card>
    <p className="small muted">Tracked links carry utm_source (the channel), utm_medium and utm_campaign (the car code). A visit is kept with the request when it is sent, so the source outlives the 90 days of visit history. Visitors who refuse analytics cookies have no source; staff can set it on the booking (Came from).</p>
  </>);
}
