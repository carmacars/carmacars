import './marketplace.css';
import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Badge, Card, PageHead, Table, Tiles, d } from '@/features/admin/ui';
import type { CarFacts, Rules } from '@/features/ads/listing';
import { bestPhotos, buildKit, type KitExtra, type KitSettings } from './kit';
import { ACTION_LABEL, marketplacePlan, type MpItem, type MpPosting } from './plan';
import { KitCards } from './KitCards';
import type { TeamClaim } from './team';

type Posting = MpPosting & { id: string; car: string };
type LogRow = { id: string; at: string; kind: string; car: string | null; conversations: number | null; replies: number | null; numbers: number | null; note: string | null; by: string | null };
export type MarketplaceData = { today: string; site_url: string; rules: Rules; cars: CarFacts[]; extra: Record<string, KitExtra>; settings: KitSettings & { max_live?: number; listing_days?: number }; team?: TeamClaim[]; phone: string | null; postings: Posting[]; log: LogRow[];
  done_today: number; week: { posted: number; renewed: number; conversations: number; replies: number; numbers: number }; leads_30: number; requests_30: number };

const KIND: Record<string, string> = { posted: 'Posted', renewed: 'Renewed', updated: 'Updated', removed: 'Taken down', inbox: 'Inbox' };
const tone = (a: MpItem['action']) => ({ update: 'pending_approval', remove: 'expired', post: 'on_rent', renew: 'confirmed' })[a];

// Admin > Marketing > Marketplace, the page's body (migration 0410; docs/runbooks/marketplace.md). Facebook Marketplace is posted from the
// owner's own profile, by Claude in his Chrome or by a person: this page is the kit for every car (computed now, so prices
// are today's), the rotation of what to post or renew (a few a day), the replies for the inbox, and the log of what was done.
export function MarketplaceView({ data, car, staff = false, scenes }: { data: MarketplaceData; car?: string; scenes?: (vehicle: string) => Promise<boolean>;
  /** r27 consolidation: Sales's Marketplace page (/staff/marketplace): the kits, today's plan and the replies, read only (logging, the photo ZIP and the settings stay Admin's) */ staff?: boolean }) {
  const sp = { car };
  const kits = data.cars.map((c) => ({ c, k: buildKit(c, data.rules, data.extra[c.vehicle_id], data.settings, data.site_url, data.today) }));
  const plan = marketplacePlan(kits.map(({ c, k }) => ({ vehicle_id: c.vehicle_id, name: `${c.name}${c.car_code ? ` (${c.car_code})` : ''}`, blocked: k.blockers.length > 0,
    partner: data.extra[c.vehicle_id]?.supply === 'partner', featured: !!c.is_featured })), data.postings,
  { today: data.today, perDay: data.settings.posts_per_day, renewDays: data.settings.renew_days, done: data.done_today });
  const pick = kits.find((x) => x.c.vehicle_id === sp.car) ?? kits.find((x) => x.c.vehicle_id === plan.today[0]?.vehicle_id) ?? kits.find((x) => !x.k.blockers.length) ?? kits[0];
  const live = new Map(data.postings.filter((p) => p.status === 'live').map((p) => [p.vehicle_id, p]));
  const refresh = ['/admin/marketing/marketplace', '/admin/marketing/ads', '/admin/marketing/listings'];
  const self = (id: string) => `${staff ? '/staff/marketplace' : '/admin/marketing/marketplace'}?car=${id}#kit`;

  const doneButton = (it: MpItem) => {
    if (staff) return null;
    const k = kits.find((x) => x.c.vehicle_id === it.vehicle_id)?.k;
    const base = { vehicle: it.vehicle_id, title: k?.title, body: k?.description, price_line: k?.priceLine };
    if (it.action === 'post') return <Act action="marketplace_log" payload={{ ...base, kind: 'posted' }} label="Posted" variant="primary" title={`Posted on Marketplace: ${it.name}`} refresh={refresh} done="Logged as posted."
      testId={`mp-posted-${it.vehicle_id}`} fields={[{ name: 'url', label: 'The listing\'s address (facebook.com/marketplace/item/...)', type: 'text', wide: true, info: false }, { name: 'on_date', label: 'Date posted', type: 'date', value: data.today, required: true, info: false }]} />;
    if (it.action === 'renew') return <Act action="marketplace_log" payload={{ vehicle: it.vehicle_id, kind: 'renewed' }} label="Renewed" variant="primary" refresh={refresh} done="Logged as renewed." testId={`mp-renewed-${it.vehicle_id}`} />;
    if (it.action === 'update') return <Act action="marketplace_log" payload={{ ...base, kind: 'updated' }} label="Updated" variant="primary" refresh={refresh} done="Logged as updated." testId={`mp-updated-${it.vehicle_id}`} />;
    return <Act action="marketplace_log" payload={{ vehicle: it.vehicle_id, kind: 'removed' }} label="Taken down" refresh={refresh} done="Logged as taken down." testId={`mp-removed-${it.vehicle_id}`}
      fields={[{ name: 'note', label: 'Why (off the site, sold, removed by Facebook)', type: 'text', info: false }]} />;
  };

  return (<>
    <PageHead kicker={staff ? 'Sales' : 'Marketing'} title="Marketplace" purpose={`Facebook Marketplace, posted from the owner's own profile: a kit for every car, ${data.settings.posts_per_day} posts or renewals a day, the inbox replies, and what was done. Playbook: docs/runbooks/marketplace.md.`} />
    <Tiles items={[
      { k: 'Live listings', v: plan.live, sub: plan.waiting ? `${plan.waiting} cars not posted yet` : 'Every car is up' },
      { k: 'Left today', v: `${plan.left_today} of ${data.settings.posts_per_day}`, sub: 'New posts and renewals' },
      { k: 'This week', v: `${data.week.conversations} chats`, sub: `${data.week.numbers} numbers, ${data.week.posted} posted, ${data.week.renewed} renewed` },
      { k: 'Last 30 days', v: `${data.requests_30} requests`, sub: `${data.leads_30} call-back leads from Marketplace`, href: staff ? undefined : '/admin/marketing/report' }
    ]} />

    <Card title="Today" testId="mp-today" tone={plan.today.length ? 'next' : undefined}>
      {plan.today.length === 0 ? <p className="small muted">Nothing due today. {plan.later[0] ? `Next: ${d(plan.later[0].date)}.` : ''}</p> : (
        <ol className="mp-list">{plan.today.map((it) => (
          <li key={`${it.action}-${it.vehicle_id}`} className="mp-item" data-testid="mp-due">
            <div className="mp-item__main">
              <Badge s={tone(it.action)}>{ACTION_LABEL[it.action]}</Badge>
              <Link prefetch={false} className="link mp-item__car" href={self(it.vehicle_id)}>{it.name}</Link>
              <span className="small muted mp-item__why">{it.reason}</span>
            </div>
            <div className="mp-item__acts">
              {live.get(it.vehicle_id)?.url ? <a className="btn btn--ghost btn--sm" href={live.get(it.vehicle_id)!.url!} target="_blank" rel="noopener noreferrer">Open listing</a> : null}
              <Link prefetch={false} className="btn btn--ghost btn--sm" href={self(it.vehicle_id)}>Kit</Link>
              {doneButton(it)}
            </div>
          </li>))}
        </ol>)}
      {plan.later.length > 0 && (
        <details className="mp-later" data-testid="mp-later"><summary className="small">Coming up: the next {plan.later.length === 1 ? 'day' : `${plan.later.length} days`}</summary>
          <ul className="small">{plan.later.map((day) => <li key={day.date}><b>{d(day.date)}:</b> {day.items.map((x) => `${ACTION_LABEL[x.action]} ${x.name}`).join(', ')}</li>)}</ul>
        </details>)}
    </Card>

    {pick && (() => {
      const { c, k } = pick;
      const lp = live.get(c.vehicle_id);
      return <KitCards c={c} k={k} rules={data.rules} phone={data.phone} action={staff ? '/staff/marketplace' : '/admin/marketing/marketplace'}
        zipHref={staff || !bestPhotos(c.photos).length ? null : `/admin/marketing/marketplace/photos/${c.vehicle_id}`} scenes={scenes?.(c.vehicle_id)}
        options={kits.map(({ c: x, k: y }) => ({ id: x.vehicle_id, label: `${x.name}${x.car_code ? ` (${x.car_code})` : ''}${y.blockers.length ? `: ${y.blockers[0]}` : live.has(x.vehicle_id) ? ': live' : ''}` }))}
        aside={lp ? <Badge s={lp.needs_update ? 'draft' : 'published'}>{lp.needs_update ? 'Live: update the price' : `Live since ${d(lp.posted_on)}`}</Badge> : <Badge s="closed">Not on Marketplace</Badge>} />;
    })()}

    {!staff && <Card title="The team's listings" testId="mp-team">
      <p className="small muted">Sales post from their own Facebook profiles in the Marketing tab, each in a copy variant of their own: at most {data.settings.max_live ?? 5} live listings a car, yours (variant 1) included. A listing ends when it is taken down or {data.settings.listing_days ?? 30} days after it was posted or renewed.</p>
      <Table testId="mp-team-table" caption="The team's listings" empty="No team listings yet." rowKey={(r) => String(r.id)} rows={(data.team ?? []) as unknown as Array<Record<string, unknown>>} cols={[
        { key: 'car', label: 'Car' }, { key: 'variant', label: 'Variant', num: true }, { key: 'poster', label: 'Posted by' },
        { key: 'status', label: 'Status', render: (r) => <><Badge s={r.status === 'live' ? 'published' : r.status === 'claimed' ? 'draft' : 'closed'}>{r.status === 'live' ? 'Live' : r.status === 'claimed' ? 'Claimed' : 'Ended'}</Badge>{r.ended_reason ? <span className="muted"> {String(r.ended_reason)}</span> : null}</> },
        { key: 'posted_on', label: 'Posted', render: (r) => (r.posted_on ? d(String(r.posted_on)) : '') },
        { key: 'expires_at', label: 'Ends', render: (r) => (r.status === 'ended' ? '' : d(String(r.expires_at))) },
        { key: 'url', label: 'Listing', render: (r) => (r.url ? <a className="link" href={String(r.url)} target="_blank" rel="noopener noreferrer">Open</a> : '') }]} />
    </Card>}

    {!staff && <Card title="Log an inbox session" testId="mp-inbox">
      <p className="small muted">After answering the Marketplace inbox: how many chats, and every phone number collected. Each new number becomes a lead with a call-back task for customer service within 15 minutes.</p>
      <Act action="marketplace_inbox" label="Log the session" variant="primary" title="The Marketplace inbox" refresh={refresh} done="Logged." testId="mp-inbox-log"
        fields={[{ name: 'conversations', label: 'Conversations answered', type: 'number', required: true, min: 0, max: 5000, info: false },
          { name: 'replies', label: 'Replies sent', type: 'number', min: 0, max: 5000, info: false },
          { name: 'numbers_text', label: 'Numbers collected, one per line: name, phone, car code', type: 'textarea', wide: true, placeholder: 'Sam, 416 555 0142, CC-7F3A', info: false },
          { name: 'note', label: 'Note', type: 'text', wide: true, info: false }]} />
    </Card>}

    <Card title="Log" testId="mp-log">
      {data.log.length === 0 ? <p className="small muted">Nothing logged yet.</p> : (
        <ul className="mp-log small">{data.log.slice(0, 15).map((x) => (
          <li key={x.id}><span className="muted">{d(x.at)}</span> <b>{KIND[x.kind] ?? x.kind}</b> {x.kind === 'inbox' ? `${x.conversations ?? 0} chats, ${x.numbers ?? 0} numbers` : x.car}{x.note ? `: ${x.note}` : ''}{x.by ? <span className="muted"> ({x.by})</span> : null}</li>))}
        </ul>)}
    </Card>

    {!staff && <Card title="Rotation settings" testId="mp-settings">
      <p className="small muted">{data.settings.posts_per_day} new posts or renewals a day, each listing renewed after {data.settings.renew_days} days, location {data.settings.location} when a car has no home area. Three to five a day avoids spam flags.</p>
      <Act action="marketplace_settings" label="Change" refresh={refresh} done="Saved." testId="mp-settings-save"
        fields={[{ name: 'posts_per_day', label: 'Posts and renewals a day', type: 'number', value: data.settings.posts_per_day, min: 1, max: 10, required: true, info: false },
          { name: 'renew_days', label: 'Renew after (days)', type: 'number', value: data.settings.renew_days, min: 2, max: 60, required: true, info: false },
          { name: 'location', label: 'Default location', type: 'text', value: data.settings.location, required: true, info: false }]} />
    </Card>}
  </>);
}
