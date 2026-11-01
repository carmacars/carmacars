import Link from 'next/link';
import { Act } from '@/features/admin/Act';
import { Badge, Card, PageHead, Tiles, d } from '@/features/admin/ui';
import { MarketingTabs } from '@/features/ads/MarketingTabs';
import { CopyText } from '@/features/ads/CopyText';
import type { CarFacts, Rules } from '@/features/ads/listing';
import { buildKit, type KitExtra, type KitSettings } from './kit';
import { ACTION_LABEL, marketplacePlan, type MpItem, type MpPosting } from './plan';
import { replies } from './replies';
import { CopyValue } from './CopyValue';
import { photoUrl } from '@/lib/photo';

type Posting = MpPosting & { id: string; car: string };
type LogRow = { id: string; at: string; kind: string; car: string | null; conversations: number | null; replies: number | null; numbers: number | null; note: string | null; by: string | null };
export type MarketplaceData = { today: string; site_url: string; rules: Rules; cars: CarFacts[]; extra: Record<string, KitExtra>; settings: KitSettings; phone: string | null; postings: Posting[]; log: LogRow[];
  done_today: number; week: { posted: number; renewed: number; conversations: number; replies: number; numbers: number }; leads_30: number; requests_30: number };

const KIND: Record<string, string> = { posted: 'Posted', renewed: 'Renewed', updated: 'Updated', removed: 'Taken down', inbox: 'Inbox' };
const tone = (a: MpItem['action']) => ({ update: 'pending_approval', remove: 'expired', post: 'on_rent', renew: 'confirmed' })[a];

// Admin > Marketing > Marketplace, the page's body (migration 0410; docs/runbooks/marketplace.md). Facebook Marketplace is posted from the
// owner's own profile, by Claude in his Chrome or by a person: this page is the kit for every car (computed now, so prices
// are today's), the rotation of what to post or renew (a few a day), the replies for the inbox, and the log of what was done.
export function MarketplaceView({ data, car }: { data: MarketplaceData; car?: string }) {
  const sp = { car };
  const kits = data.cars.map((c) => ({ c, k: buildKit(c, data.rules, data.extra[c.vehicle_id], data.settings, data.site_url, data.today) }));
  const plan = marketplacePlan(kits.map(({ c, k }) => ({ vehicle_id: c.vehicle_id, name: `${c.name}${c.car_code ? ` (${c.car_code})` : ''}`, blocked: k.blockers.length > 0,
    partner: data.extra[c.vehicle_id]?.supply === 'partner', featured: !!c.is_featured })), data.postings,
  { today: data.today, perDay: data.settings.posts_per_day, renewDays: data.settings.renew_days, done: data.done_today });
  const pick = kits.find((x) => x.c.vehicle_id === sp.car) ?? kits.find((x) => x.c.vehicle_id === plan.today[0]?.vehicle_id) ?? kits.find((x) => !x.k.blockers.length) ?? kits[0];
  const live = new Map(data.postings.filter((p) => p.status === 'live').map((p) => [p.vehicle_id, p]));
  const refresh = ['/admin/marketing/marketplace', '/admin/marketing/ads', '/admin/marketing/listings'];
  const self = (id: string) => `/admin/marketing/marketplace?car=${id}#kit`;

  const doneButton = (it: MpItem) => {
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
    <PageHead kicker="Marketing" title="Marketplace" purpose={`Facebook Marketplace, posted from the owner's own profile: a kit for every car, ${data.settings.posts_per_day} posts or renewals a day, the inbox replies, and what was done. Playbook: docs/runbooks/marketplace.md.`} />
    <MarketingTabs current="/admin/marketing/marketplace" />
    <Tiles items={[
      { k: 'Live listings', v: plan.live, sub: plan.waiting ? `${plan.waiting} cars not posted yet` : 'Every car is up' },
      { k: 'Left today', v: `${plan.left_today} of ${data.settings.posts_per_day}`, sub: 'New posts and renewals' },
      { k: 'This week', v: `${data.week.conversations} chats`, sub: `${data.week.numbers} numbers, ${data.week.posted} posted, ${data.week.renewed} renewed` },
      { k: 'Last 30 days', v: `${data.requests_30} requests`, sub: `${data.leads_30} call-back leads from Marketplace`, href: '/admin/marketing/report' }
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
      const rs = replies(c, data.rules, k.link, data.phone);
      const lp = live.get(c.vehicle_id);
      return (<>
        <Card id="kit" title={`Kit: ${c.name}${c.car_code ? ` (${c.car_code})` : ''}`} testId="mp-kit" aside={lp ? <Badge s={lp.needs_update ? 'draft' : 'published'}>{lp.needs_update ? 'Live: update the price' : `Live since ${d(lp.posted_on)}`}</Badge> : <Badge s="closed">Not on Marketplace</Badge>}>
          <form method="get" action="/admin/marketing/marketplace#kit" className="mp-pick">
            <label className="label" htmlFor="mp-car">Car</label>
            <select className="select" id="mp-car" name="car" defaultValue={c.vehicle_id} data-testid="mp-car">
              {kits.map(({ c: x, k: y }) => <option key={x.vehicle_id} value={x.vehicle_id}>{x.name}{x.car_code ? ` (${x.car_code})` : ''}{y.blockers.length ? `: ${y.blockers[0]}` : live.has(x.vehicle_id) ? ': live' : ''}</option>)}
            </select>
            <button className="btn btn--ghost btn--sm" type="submit">Show</button>
          </form>
          {k.blockers.length > 0 && <p className="small mp-warn" data-testid="mp-blockers"><b>Do not post yet:</b> {k.blockers.join('. ')}.</p>}
          {k.warnings.length > 0 && <ul className="small muted" data-testid="mp-warnings">{k.warnings.map((w) => <li key={w}>{w}</li>)}</ul>}
          <p className="small muted">facebook.com/marketplace/create/vehicle asks for these, in this order. Marketplace titles a vehicle Year Make Model by itself.</p>
          <dl className="mp-fields" data-testid="mp-fields">
            {k.fields.map((f) => <div key={f.label}><dt>{f.label}</dt><dd><span className="mp-val">{f.value || <span className="muted">{f.note}</span>}{f.value && f.note ? <span className="mp-note">{f.note}</span> : null}</span><CopyValue value={f.value} label={f.label} /></dd></div>)}
          </dl>
          <div className="stack">
            <CopyText label="Description" value={k.description} rows={Math.min(18, k.description.split('\n').length + 2)} max={5000} testId="mp-description" />
            <CopyText label="Tracked link" value={k.link} testId="mp-link" />
            <details><summary className="small">The description without the link (if Facebook holds the listing back for the link)</summary><CopyText label="Description without the link" value={k.descriptionNoLink} rows={10} testId="mp-description-nolink" /></details>
          </div>
        </Card>
        <Card title={`Photos, in this order (${k.photos.length} of 10)`} testId="mp-photos" aside={k.photos.length ? <a className="btn btn--primary btn--sm" href={`/admin/marketing/marketplace/photos/${c.vehicle_id}`} download data-testid="mp-zip">Download the photos (ZIP)</a> : null}>
          {k.photos.length === 0 ? <p className="small muted">No real photos yet.</p> : (
            <ol className="mp-photos">{k.photos.map((p, i) => (
              <li key={p.path}>
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={photoUrl(p.path)} alt={p.alt || `${c.name}, photo ${i + 1}`} loading="lazy" />
                <span className="small"><b>{i + 1}.</b> {p.label ?? p.shot ?? 'Photo'}</span>
              </li>))}
            </ol>)}
          <p className="small muted">The ZIP names them 01 to {String(k.photos.length).padStart(2, '0')}: add them in that order, the first is the cover.</p>
        </Card>
        <Card title="Inbox replies for this car" testId="mp-replies">
          <p className="small muted">Every reply ends on the next step: request on carmacars.ca, or send a number for a call. Log each number below.</p>
          <div className="mp-replies">{rs.map((r) => (
            <details key={r.key} className="mp-reply" data-testid={`mp-reply-${r.key}`}>
              <summary><b>{r.label}</b> <span className="small muted">{r.when}</span></summary>
              <CopyText label={`${r.label} reply`} value={r.text} rows={Math.min(8, r.text.split('\n').length + 3)} />
            </details>))}
          </div>
        </Card>
      </>);
    })()}

    <Card title="Log an inbox session" testId="mp-inbox">
      <p className="small muted">After answering the Marketplace inbox: how many chats, and every phone number collected. Each new number becomes a lead with a call-back task for customer service within 15 minutes.</p>
      <Act action="marketplace_inbox" label="Log the session" variant="primary" title="The Marketplace inbox" refresh={refresh} done="Logged." testId="mp-inbox-log"
        fields={[{ name: 'conversations', label: 'Conversations answered', type: 'number', required: true, min: 0, max: 5000, info: false },
          { name: 'replies', label: 'Replies sent', type: 'number', min: 0, max: 5000, info: false },
          { name: 'numbers_text', label: 'Numbers collected, one per line: name, phone, car code', type: 'textarea', wide: true, placeholder: 'Sam, 416 555 0142, CC-7F3A', info: false },
          { name: 'note', label: 'Note', type: 'text', wide: true, info: false }]} />
    </Card>

    <Card title="Log" testId="mp-log">
      {data.log.length === 0 ? <p className="small muted">Nothing logged yet.</p> : (
        <ul className="mp-log small">{data.log.slice(0, 15).map((x) => (
          <li key={x.id}><span className="muted">{d(x.at)}</span> <b>{KIND[x.kind] ?? x.kind}</b> {x.kind === 'inbox' ? `${x.conversations ?? 0} chats, ${x.numbers ?? 0} numbers` : x.car}{x.note ? `: ${x.note}` : ''}{x.by ? <span className="muted"> ({x.by})</span> : null}</li>))}
        </ul>)}
    </Card>

    <Card title="Rotation settings" testId="mp-settings">
      <p className="small muted">{data.settings.posts_per_day} new posts or renewals a day, each listing renewed after {data.settings.renew_days} days, location {data.settings.location} when a car has no home area. Three to five a day avoids spam flags.</p>
      <Act action="marketplace_settings" label="Change" refresh={refresh} done="Saved." testId="mp-settings-save"
        fields={[{ name: 'posts_per_day', label: 'Posts and renewals a day', type: 'number', value: data.settings.posts_per_day, min: 1, max: 10, required: true, info: false },
          { name: 'renew_days', label: 'Renew after (days)', type: 'number', value: data.settings.renew_days, min: 2, max: 60, required: true, info: false },
          { name: 'location', label: 'Default location', type: 'text', value: data.settings.location, required: true, info: false }]} />
    </Card>
  </>);
}
