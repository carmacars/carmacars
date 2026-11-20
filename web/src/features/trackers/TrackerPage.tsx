import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { Crumbs } from '@/components/Crumbs';
import { Faq } from '@/components/Faq';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, faqLd, type Trail } from '@/features/seo/meta';
import { KitCompare, KitCta, KitFacts, KitHero, KitPrices, KitSection, KitSteps, KitSticky, KitTiles, KitToc, KitTrust, type PriceCard } from '@/features/seo/kit/Kit';
import { Ico } from '@/features/seo/kit/icons';
import { ServicePromo } from '@/features/services/ServicePromo';
import { getInstallPlaces } from '@/features/tracker-product/data';
import { trackerFacts } from './data';
import { siteUrl } from '@/lib/site';
import { money } from '@/lib/format';
import { WaitlistForm } from './WaitlistForm';
import { availability, ctaLabel, deviceNow, featureIcon, priceShort, PriceSentence, stage, trackerIntents, type Faq as Q, type TrackerFacts, type TrackerIntent } from './pages';

// The tracker pages' one template (release 48): the product page, each intent page and each install page are the same
// blocks in the same order, so a reader always finds the price, what it does and the waitlist in the same place:
// hero and action, jump chips, the short answer with quotable facts, the page's own section, what it does (icon tiles),
// price cards, a comparison table, how it works, install places, questions, the other services, the phone's sticky action.

export { trackerFacts } from './data';

/** The Product node: one Offer in CAD at the price that applies now (0 while the free pre-orders last, the pre-order
 *  price after that, the regular price after launch), and PreOrder (never InStock) while trackers cannot be installed. */
export function productLd(f: TrackerFacts, path: string) {
  return {
    '@type': 'Product', '@id': `${siteUrl()}/trackers#product`, name: f.name, category: 'GPS tracker with remote kill switch (starter interrupt)', url: siteUrl() + path,
    description: `GPS tracker for cars with a remote kill switch (starter interrupt), remote door locking, an alarm and trip history. Installed by ${f.brand} in ${f.city}, Ontario.`,
    brand: { '@type': 'Brand', name: f.brand },
    offers: { '@type': 'Offer', priceCurrency: 'CAD', price: (deviceNow(f) / 100).toFixed(2),
      availability: f.available ? 'https://schema.org/InStock' : 'https://schema.org/PreOrder', url: `${siteUrl()}/trackers#waitlist`, seller: { '@id': `${siteUrl()}/#business` },
      ...(f.installCents ? { description: `Installed by ${f.brand}: ${money(f.installCents)} once per car, charged with the install.` } : {}) }
  };
}

export function priceCards(f: TrackerFacts): PriceCard[] {
  const x = f.prices, ins = f.installCents ? `${money(f.installCents)} install, once per car` : 'Install quoted for your car';
  const amt = (c: number) => (c === 0 ? 'Free' : money(c));
  const st = stage(f);
  const owner: PriceCard = { forWhom: `${f.brand} vehicle owners`, amount: amt(x.ownerCents), per: 'the tracker', points: ['For cars listed with us', ins, 'Live GPS, kill switch, door locking and alarm'] };
  const pre: PriceCard | null = st === 'regular' ? null : st === 'free'
    ? { forWhom: `The first ${x.freeFirst} pre-orders`, amount: 'Free', per: 'the tracker', best: true, tag: 'Pre-order now', points: [`${money(x.preorderCents)} on pre-order after that`, `Installed by ${f.brand}`, ins] }
    : { forWhom: 'Pre-order', amount: amt(x.preorderCents), per: 'the tracker', best: true, tag: 'Pre-order now', points: [`${money(Math.max(0, x.regularCents - x.preorderCents))} less than after launch`, `Installed by ${f.brand}`, ins] };
  const reg: PriceCard = { forWhom: f.available ? 'Everyone else' : 'After launch', amount: amt(x.regularCents), per: 'the tracker', best: st === 'regular', points: ['The regular price', ins, 'Live GPS, kill switch, door locking and alarm'] };
  return [owner, ...(pre ? [pre] : []), reg];
}

interface Props {
  path: string; trail: Trail; kicker: string; icon: TrackerIntent['icon']; h1: string; answer: string; facts: TrackerFacts;
  own?: TrackerIntent['section']; compare?: TrackerIntent['compare']; faq: Q[]; lead?: string[]; city?: string; extraLd?: object[]; testId: string;
  placeNote?: React.ReactNode; places?: Array<{ href: string; label: string }>; placesTitle?: string;
}
export async function TrackerTemplate(x: Props) {
  const f = x.facts;
  const features = [...f.features].sort((a, b) => { const r = (t: string) => { const i = (x.lead ?? []).findIndex((l) => t.toLowerCase().startsWith(l.toLowerCase())); return i < 0 ? 99 : i; }; return r(a.title) - r(b.title); });
  const intents = trackerIntents(f).filter((i) => `/trackers/${i.slug}` !== x.path);
  const cta = ctaLabel(f);
  const toc: Array<[string, string]> = [['Price', 'price'], ['What it does', 'features'], ...(x.own ? [[x.own.h.length > 26 ? 'How it works' : x.own.h, 'own'] as [string, string]] : []),
    ...(x.compare ? [['Compare', 'compare'] as [string, string]] : []), [cta, 'waitlist'], ['Questions', 'faq']];
  return (
    <div className="p-landing sk" data-page={x.testId} data-trackers-available={f.available ? 'yes' : 'no'}>
      <JsonLd graph={[breadcrumbLd(x.trail, x.path), faqLd(x.faq), productLd(f, x.path), ...(x.extraLd ?? [])]} />
      <KitHero kicker={x.kicker} icon={x.icon} h1={x.h1} lead={x.answer} pill={f.available ? undefined : f.launchNote} cta={<KitCta primary={[cta, '#waitlist']} secondary={['See the price', '#price']} />}
        note={`Prices before ${f.hst} HST. Nothing is charged to join.`}>
        <Crumbs trail={x.trail} />
      </KitHero>
      <KitToc items={toc} />
      <div className="wrap landing__body">
        {x.placeNote}
        <KitSection id="price" kicker="Price" h={stage(f) === 'free' ? `Free for the first ${f.prices.freeFirst} pre-orders` : 'One price for the tracker, one for the install'} p={`${availability(f)}. Nothing is charged until we confirm your install.`}>
          <KitPrices cards={priceCards(f)} fine={`Prices are per tracker, one per car, before ${f.hst} HST.${f.installCents ? ` Everyone pays the ${money(f.installCents)} install, once per car.` : ''}${f.available ? '' : ` A pre-ordered tracker is installed by ${f.brand}.`}`} />
        </KitSection>
        <KitSection id="features" kicker="What it does" h="See it, lock it, stop it, prove it" p="Everything is worked from your phone or computer.">
          <KitTiles items={features.map((ft) => ({ icon: featureIcon(ft.title), title: ft.title, text: ft.text }))} />
        </KitSection>
        {x.own && (
          <KitSection id="own" h={x.own.h} p={x.own.p}>
            {x.own.steps && <KitSteps steps={x.own.steps} />}
            {x.own.points && <KitTiles items={x.own.points} />}
          </KitSection>
        )}
        {x.compare && <KitSection id="compare" kicker="Compare" h={x.compare.caption}><KitCompare caption={x.compare.caption} head={x.compare.head} rows={x.compare.rows} /></KitSection>}
        <KitSection id="waitlist-sec" kicker={f.available ? 'Order' : 'Waitlist and pre-order'} h={f.available ? 'Order your tracker' : 'Be first when trackers arrive'}>
          <div className="sk-two">
            <div className="stack" style={{ gap: 'var(--s-5)' }}>
              <KitFacts rows={[['Product', f.name], ['What it is', 'GPS tracker with a remote kill switch (starter interrupt), door locking and alarm'],
                ['The tracker', PriceSentence(f)], ['Install', f.installCents ? `${money(f.installCents)} once per car` : 'Quoted for your car'],
                ['When', f.available ? 'Installs are open' : `${f.launchNote}. Waitlist and pre-orders are open`], ['Installed by', `${f.brand}, ${f.city}, Ontario`], ['Price today', priceShort(f)]]} />
              <KitTrust items={[['shield', 'Nothing charged to join'], ['wrench', `Installed by ${f.brand}`], ['users', 'A person answers every sign-up'], ['dollar', 'Price confirmed in writing first']]} />
            </div>
            <div id="waitlist" style={{ scrollMarginTop: 'calc(var(--header-h) + 1rem)' }}>
              <WaitlistForm prices={f.prices} brand={f.brand} installCents={f.installCents} available={f.available} city={x.city} note={f.available ? 'Tell us how many cars. We reply with your install day and confirm the price before anything is billed.'
                : `${f.launchNote}. Leave your email and the number of cars: you hear first, and nothing is charged today.${stage(f) === 'free' ? ` The tracker is free for the first ${f.prices.freeFirst} pre-orders.` : ''}`} />
            </div>
          </div>
        </KitSection>
        {x.places && x.places.length > 0 && (
          <KitSection id="install" kicker="Install near you" h={x.placesTitle ?? 'Tracker install by city'} p={`${f.brand} installs each tracker and checks that it works. Pick your city.`}>
            <nav aria-label="Tracker install by city"><ul className="linklist landing__cols">{x.places.map((l) => <li key={l.href}><Link prefetch={false} className="link" href={l.href}>{l.label}</Link></li>)}</ul></nav>
          </KitSection>
        )}
        <KitSection id="faq" kicker="Questions" h="Answers, before you ask"><Faq items={x.faq} /></KitSection>
        <KitSection id="more" kicker="More on the tracker" h="Pick the page that fits your car">
          <ul className="sk-tiles" data-testid="tracker-intents">
            {[...(x.path === '/trackers' ? [] : [{ slug: '', kicker: 'The product', h1: `${f.name}: price and features`, icon: 'pin' as TrackerIntent['icon'] }]), ...intents.map((i) => ({ slug: i.slug, kicker: i.kicker, h1: i.h1, icon: i.icon }))].slice(0, 9).map((i) => (
              <li key={i.slug} className="sk-tile"><span className="sk-tile__ico"><Ico name={i.icon} /></span><div><h3><Link prefetch={false} className="link" href={i.slug ? `/trackers/${i.slug}` : '/trackers'}>{i.kicker}</Link></h3><p>{i.h1}</p></div></li>))}
          </ul>
        </KitSection>
      </div>
      <ServicePromo exclude="trackers" />
      <KitSticky title={stage(f) === 'free' ? `Free for the first ${f.prices.freeFirst} pre-orders` : `${money(deviceNow(f))} ${f.available ? 'per tracker' : 'on pre-order'}`} sub={f.available ? 'Installs are open' : f.launchNote} cta={cta} href="#waitlist" />
    </div>
  );
}

/** The facts or a 404 when the product is switched off. */
export async function loadTracker() {
  const x = await trackerFacts();
  if (!x) notFound();
  return x;
}
export async function installLinks(limit = 24) {
  return (await getInstallPlaces(limit)).map((p) => ({ href: `/trackers/install/${p.slug}`, label: `Tracker install in ${p.name}` }));
}
