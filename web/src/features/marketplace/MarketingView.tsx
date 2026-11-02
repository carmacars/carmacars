import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Badge, Card, PageHead, Tiles, d } from '@/features/admin/ui';
import { CopyText } from '@/features/ads/CopyText';
import { buildKit } from './kit';
import { KitCards } from './KitCards';
import type { MarketplaceData } from './MarketplaceView';
import { claudePrompt } from './prompt';
import { replyLink } from './replies';
import { TEAM_LABEL, freeVariant, teamPlan, type TeamAction, type TeamClaim, type TeamItem } from './team';
import { variantKit } from './variants';

export type MarketingData = MarketplaceData & { me: string; team: TeamClaim[] };

const KIND: Record<string, string> = { posted: 'Posted', renewed: 'Renewed', updated: 'Updated', removed: 'Taken down', inbox: 'Inbox' };
const tone = (a: TeamAction) => ({ finish: 'draft', update: 'pending_approval', remove: 'expired', post: 'on_rent', renew: 'confirmed' })[a];
const SELF = '/staff/marketing';
const REFRESH = [SELF];

/** Meta's auto-reply text for a listing (docs/runbooks/marketplace.md section 5), with the variant's tracked link. */
export const autoReply = (link: string) => `Hi! Yes, it's available to book by the day or week. Daily and weekly bookings only, not for sale. See the price for your dates and book in 2 minutes: ${link}\nOr send your phone number and our team will call you shortly.`;

// Sales > Marketing (migration 0510; the owner, November 2, 2026): the Marketplace tool for each salesperson's own Facebook
// profile. Today's list, the kit in the person's own copy variant (no two live listings share a title, description or
// cover), the auto-reply setup, the inbox replies, the inbox log (numbers credited to them), and the instructions for their
// own Claude in Chrome. Every post, renewal, update and take-down is logged per person, car and variant.
export function MarketingView({ data, car, academyHref }: { data: MarketingData; car?: string; academyHref: string }) {
  const now = new Date().toISOString();
  const s = data.settings;
  const maxLive = s.max_live ?? 5;
  const kits = data.cars.map((c) => ({ c, k: buildKit(c, data.rules, data.extra[c.vehicle_id], s, data.site_url, data.today) }));
  const ownerLive = new Set(data.postings.filter((p) => p.status === 'live').map((p) => p.vehicle_id));
  const team = data.team ?? [];
  const mine = team.filter((t) => t.poster_id === data.me && t.status !== 'ended' && t.expires_at > now);
  const plan = teamPlan(kits.map(({ c, k }) => ({ vehicle_id: c.vehicle_id, name: `${c.name}${c.car_code ? ` (${c.car_code})` : ''}`, blocked: k.blockers.length > 0,
    featured: !!c.is_featured, photos: k.photos.length, priceLine: k.priceLine })), team, data.me, ownerLive,
  { today: data.today, now, perDay: s.posts_per_day, renewDays: s.renew_days, done: data.done_today, maxLive });
  const pick = kits.find((x) => x.c.vehicle_id === car) ?? kits.find((x) => x.c.vehicle_id === plan.today[0]?.vehicle_id) ?? kits.find((x) => !x.k.blockers.length) ?? kits[0];
  const self = (id: string) => `${SELF}?car=${id}#kit`;
  const variantOf = (id: string, photos: number) => mine.find((t) => t.vehicle_id === id)?.variant ?? freeVariant({ vehicle_id: id, photos }, team, ownerLive.has(id), maxLive, now);

  const buttons = (it: TeamItem) => {
    const c = it.claim;
    if (it.action === 'post') {
      const x = kits.find((y) => y.c.vehicle_id === it.vehicle_id);
      if (!x) return null;
      const v = variantKit(x.k, x.c, it.variant);
      return <Act action="mp_claim" label={`Claim variant ${it.variant}`} variant="primary" refresh={REFRESH} done="Claimed: post it now, then press Posted." testId={`mk-claim-${it.vehicle_id}`}
        payload={{ vehicle: it.vehicle_id, variant: it.variant, title: v.title, body: v.description, cover: v.cover, price_line: v.priceLine }} />;
    }
    if (!c) return null;
    if (it.action === 'finish') return (<>
      <Act action="mp_team_log" payload={{ claim: c.id, kind: 'posted' }} label="Posted" variant="primary" title={`Posted on Marketplace: ${it.name}`} refresh={REFRESH} done="Logged as posted." testId={`mk-posted-${it.vehicle_id}`}
        fields={[{ name: 'url', label: 'The listing\'s address (facebook.com/marketplace/item/...)', type: 'text', wide: true, required: true, info: false }, { name: 'on_date', label: 'Date posted', type: 'date', value: data.today, required: true, info: false }]} />
      <Act action="mp_team_log" payload={{ claim: c.id, kind: 'removed', note: 'Let go before posting' }} label="Let go" confirm="Let this claim go? The variant becomes free for someone else." refresh={REFRESH} done="Let go." testId={`mk-letgo-${it.vehicle_id}`} />
    </>);
    if (it.action === 'renew') return <Act action="mp_team_log" payload={{ claim: c.id, kind: 'renewed' }} label="Renewed" variant="primary" refresh={REFRESH} done="Logged as renewed." testId={`mk-renewed-${it.vehicle_id}`} />;
    if (it.action === 'update') {
      const k = kits.find((y) => y.c.vehicle_id === it.vehicle_id)?.k;
      return <Act action="mp_team_log" payload={{ claim: c.id, kind: 'updated', price_line: k?.priceLine }} label="Updated" variant="primary" refresh={REFRESH} done="Logged as updated." testId={`mk-updated-${it.vehicle_id}`} />;
    }
    return <Act action="mp_team_log" payload={{ claim: c.id, kind: 'removed' }} label="Taken down" refresh={REFRESH} done="Logged as taken down." testId={`mk-removed-${it.vehicle_id}`}
      fields={[{ name: 'note', label: 'Why (off the site, removed by Facebook)', type: 'text', info: false }]} />;
  };

  const kitPart = (() => {
    if (!pick) return null;
    const { c, k } = pick;
    const v = variantOf(c.vehicle_id, k.photos.length);
    const claim = mine.find((t) => t.vehicle_id === c.vehicle_id);
    const options = kits.map(({ c: x, k: y }) => {
      const xv = variantOf(x.vehicle_id, y.photos.length);
      const m = mine.find((t) => t.vehicle_id === x.vehicle_id);
      return { id: x.vehicle_id, label: `${x.name}${x.car_code ? ` (${x.car_code})` : ''}${y.blockers.length ? `: ${y.blockers[0]}` : m ? `: yours, variant ${m.variant}` : xv === null ? ': all listings up' : ''}` };
    });
    if (v === null) return (
      <Card id="kit" title={`Kit: ${c.name}${c.car_code ? ` (${c.car_code})` : ''}`} testId="mp-kit" aside={<Badge s="closed">All listings up</Badge>}>
        <form method="get" action={`${SELF}#kit`} className="mp-pick">
          <label className="label" htmlFor="mp-car">Car</label>
          <select className="select" id="mp-car" name="car" defaultValue={c.vehicle_id} data-testid="mp-car">{options.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}</select>
          <button className="btn btn--ghost btn--sm" type="submit">Show</button>
        </form>
        <p className="small" data-testid="mk-full">This car already has its {maxLive} live listings (or every photo is a cover already), each in its own copy. Choose another car so no ad is posted twice.</p>
      </Card>);
    const vk = variantKit(k, c, v);
    return (<>
      <KitCards c={c} k={vk} rules={data.rules} phone={data.phone} variant={v} action={SELF} options={options}
        zipHref={vk.photos.length ? `${SELF}/photos/${c.vehicle_id}?v=${v}` : null}
        aside={claim ? <Badge s={claim.status === 'live' ? 'published' : 'draft'}>{claim.status === 'live' ? `Yours, live since ${d(claim.posted_on!)}` : 'Claimed by you'}</Badge> : <Badge s="on_rent">{`Variant ${v} is free`}</Badge>} />
      <Card title="Auto-reply for this listing" testId="mk-autoreply">
        <ol className="small">
          <li>On facebook.com/marketplace/create/vehicle, fill the listing and scroll to <b>Auto replies</b> (or <b>Meta AI replies</b>) near the description, before <b>Next</b>.</li>
          <li>Turn it <b>on</b> and open the drafted reply.</li>
          <li>Replace all of the draft with the text below (it has this listing&apos;s own link).</li>
          <li>Publish. For a listing already up: open it, <b>Edit</b>, and set the same reply if the option is shown.</li>
        </ol>
        <CopyText label="Auto-reply text" value={autoReply(replyLink(vk.link))} rows={4} testId="mk-autoreply-text" />
        <p className="small muted">It answers only the first &quot;Is this available?&quot;. Every other message waits for you (the inbox replies above).</p>
      </Card>
    </>);
  })();

  return (<>
    <PageHead kicker="Sales" title="Marketing" purpose={`Facebook Marketplace from your own profile: what to post today, your own copy of each car (never the same ad twice), the replies, and your log. ${s.posts_per_day} posts or renewals a day.`} />
    <Tiles items={[
      { k: 'My live listings', v: plan.mine_live, sub: plan.open_cars ? `${plan.open_cars} ${plan.open_cars === 1 ? 'car' : 'cars'} you can still post` : 'Nothing left to post' },
      { k: 'Left today', v: `${plan.left_today} of ${s.posts_per_day}`, sub: 'Your new posts and renewals' },
      { k: 'This week', v: `${data.week.conversations} chats`, sub: `${data.week.numbers} numbers, ${data.week.posted} posted, ${data.week.renewed} renewed` },
      { k: 'Your leads, 30 days', v: data.leads_30, sub: 'Numbers you collected from Marketplace' }
    ]} />

    <Card title="Today" testId="mk-today" tone={plan.today.length ? 'next' : undefined}>
      {plan.today.length === 0 ? <p className="small muted">Nothing due today. {plan.full_cars ? `${plan.full_cars} cars already have all their listings up.` : ''}</p> : (
        <ol className="mp-list">{plan.today.map((it) => (
          <li key={`${it.action}-${it.vehicle_id}`} className="mp-item" data-testid="mk-due">
            <div className="mp-item__main">
              <Badge s={tone(it.action)}>{TEAM_LABEL[it.action]}</Badge>
              <Link prefetch={false} className="link mp-item__car" href={self(it.vehicle_id)}>{it.name}</Link>
              <span className="small muted mp-item__why">{it.reason}</span>
            </div>
            <div className="mp-item__acts">
              {it.claim?.url ? <a className="btn btn--ghost btn--sm" href={it.claim.url} target="_blank" rel="noopener noreferrer">Open listing</a> : null}
              <Link prefetch={false} className="btn btn--ghost btn--sm" href={self(it.vehicle_id)}>Kit</Link>
              {buttons(it)}
            </div>
          </li>))}
        </ol>)}
    </Card>

    {kitPart}

    <Card title="Log an inbox session" testId="mk-inbox">
      <p className="small muted">After answering your Marketplace inbox: how many chats, and every phone number collected. Each new number is a lead credited to you, with a call-back task within 15 minutes.</p>
      <Act action="mp_team_inbox" label="Log the session" variant="primary" title="My Marketplace inbox" refresh={REFRESH} done="Logged." testId="mk-inbox-log"
        fields={[{ name: 'conversations', label: 'Conversations answered', type: 'number', required: true, min: 0, max: 5000, info: false },
          { name: 'replies', label: 'Replies sent', type: 'number', min: 0, max: 5000, info: false },
          { name: 'numbers_text', label: 'Numbers collected, one per line: name, phone, car code', type: 'textarea', wide: true, placeholder: 'Sam, 416 555 0142, CC-7F3A', info: false },
          { name: 'note', label: 'Note', type: 'text', wide: true, info: false }]} />
    </Card>

    <Card title="Your Claude in Chrome" testId="mk-claude" aside={<Link prefetch={false} className="btn btn--ghost btn--sm" href={academyHref} data-testid="mk-academy">Academy lesson</Link>}>
      <p className="small">Claude can post and answer for you in your own Chrome. Sign in to Facebook and to this site yourself, then paste these instructions into Claude and say &quot;Run my Marketplace session&quot;. Claude stops at any Facebook check and never types a password.</p>
      <CopyText label="Instructions for Claude" value={claudePrompt(data.site_url)} rows={10} max={6000} testId="mk-prompt" />
    </Card>

    <Card title="My listings and log" testId="mk-log">
      {mine.length > 0 && <ul className="mp-log small" data-testid="mk-mine">{mine.map((t) => (
        <li key={t.id}><b>{t.car}</b> variant {t.variant}: {t.status === 'live' ? `live since ${d(t.posted_on!)}, ends ${d(t.expires_at)}` : 'claimed, not posted yet'}{t.url ? <> <a className="link" href={t.url} target="_blank" rel="noopener noreferrer">Open</a></> : null}</li>))}
      </ul>}
      {data.log.length === 0 ? <p className="small muted">Nothing logged yet.</p> : (
        <ul className="mp-log small">{data.log.slice(0, 15).map((x) => (
          <li key={x.id}><span className="muted">{d(x.at)}</span> <b>{KIND[x.kind] ?? x.kind}</b> {x.kind === 'inbox' ? `${x.conversations ?? 0} chats, ${x.numbers ?? 0} numbers` : `${x.car ?? ''}${(x as { variant?: number | null }).variant ? `, variant ${(x as { variant?: number | null }).variant}` : ''}`}{x.note ? `: ${x.note}` : ''}</li>))}
        </ul>)}
    </Card>
  </>);
}
