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
import { availability, ctaLabel, featureIcon, highest, installSentence, lowest, monthly, priceSentence, tierLabel, trackerIntents, type Faq as Q, type TrackerFacts, type TrackerIntent } from './pages';

// The tracker pages' one template (release 48): the product page, each intent page and each install page are the same
// blocks in the same order, so a reader always finds the price, what it does and the waitlist in the same place:
// hero and action, jump chips, the short answer with quotable facts, the page's own section, what it does (icon tiles),
// price cards, a comparison table, how it works, install places, questions, the other services, the phone's sticky action.

export { trackerFacts } from './data';

/** The Product node: a price range in CAD, and PreOrder (never InStock) while trackers cannot be installed. */
export function productLd(f: TrackerFacts, path: string) {
  const lo = lowest(f), hi = highest(f);
  return {
    '@type': 'Product', '@id': `${siteUrl()}/trackers#product`, name: f.name, category: 'GPS tracker with remote kill switch (starter interrupt)', url: siteUrl() + path,
    description: `GPS tracker for cars with a remote kill switch (starter interrupt), remote door locking, an alarm and trip history. Installed by ${f.brand} in ${f.city}, Ontario.`,
    brand: { '@type': 'Brand', name: f.brand },
    ...(lo !== null && hi !== null ? { offers: { '@type': 'AggregateOffer', priceCurrency: 'CAD', lowPrice: (lo / 100).toFixed(2), highPrice: (hi / 100).toFixed(2), offerCount: f.tiers.length,
      availability: f.available ? 'https://schema.org/InStock' : 'https://schema.org/PreOrder', url: `${siteUrl()}/trackers#waitlist`, seller: { '@id': `${siteUrl()}/#business` } } } : {})
  };
}

export function priceCards(f: TrackerFacts): PriceCard[] {
  const tiers = [...f.tiers].sort((a, b) => a.from_cars - b.from_cars);
  const hi = highest(f);
  return tiers.map((t, i) => ({
    forWhom: tierLabel(t), amount: money(t.monthly_cents), per: 'a month per car', best: tiers.length > 1 && i === 1, tag: tiers.length > 1 && i === 1 ? 'Most hosts' : undefined,
    points: [...(hi !== null && t.monthly_cents < hi ? [`${money(hi - t.monthly_cents)} less per car than the first price`] : ['Live GPS, kill switch, door locking and alarm']),
      f.installCents ? `${money(f.installCents)} install, once per car` : 'Install quoted for your car', 'Every car billed at this price']
  }));
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
  const lo = lowest(f);
  const toc: Array<[string, string]> = [['Price', 'price'], ['What it does', 'features'], ...(x.own ? [[x.own.h.length > 26 ? 'How it works' : x.own.h, 'own'] as [string, string]] : []),
    ...(x.compare ? [['Compare', 'compare'] as [string, string]] : []), [cta, 'waitlist'], ['Questions', 'faq']];
  return (
    <div className="p-landing sk" data-page={x.testId} data-trackers-available={f.available ? 'yes' : 'no'}>
      <JsonLd graph={[breadcrumbLd(x.trail, x.path), faqLd(x.faq), productLd(f, x.path), ...(x.extraLd ?? [])]} />
      <KitHero kicker={x.kicker} icon={x.icon} h1={x.h1} lead={x.answer} pill={f.available ? undefined : f.launchNote} cta={<KitCta primary={[cta, '#waitlist']} secondary={['See the price', '#price']} />}
        note={`${priceSentence(f).replace(/^./, (c) => c.toUpperCase())}. ${installSentence(f).replace(/^./, (c) => c.toUpperCase())}. Before ${f.hst} HST.`}>
        <Crumbs trail={x.trail} />
      </KitHero>
      <KitToc items={toc} />
      <div className="wrap landing__body">
        {x.placeNote}
        <KitSection id="price" kicker="Price" h="One price per car, lower as you add cars" p={`${availability(f)}. Nothing is charged until we confirm your install.`}>
          <KitPrices cards={priceCards(f)} fine={`Monthly prices are per car, before ${f.hst} HST. The price per car is set by how many cars you have with us.${f.installCents ? ` The ${money(f.installCents)} install is charged once per car.` : ''}`} />
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
                ['Monthly price', priceSentence(f)], ['Install', f.installCents ? `${money(f.installCents)} once per car` : 'Quoted for your car'],
                ['When', f.available ? 'Installs are open' : `${f.launchNote}. Waitlist and pre-orders are open`], ['Installed by', `${f.brand}, ${f.city}, Ontario`], ['From', lo !== null ? `${monthly(lo)} per car` : null]]} />
              <KitTrust items={[['shield', 'Nothing charged to join'], ['wrench', `Installed by ${f.brand}`], ['users', 'A person answers every sign-up'], ['dollar', 'Price confirmed in writing first']]} />
            </div>
            <div id="waitlist" style={{ scrollMarginTop: 'calc(var(--header-h) + 1rem)' }}>
              <WaitlistForm tiers={f.tiers} installCents={f.installCents} available={f.available} city={x.city} note={f.available ? 'Tell us how many cars. We reply with your install day and confirm the price before anything is billed.'
                : `${f.launchNote}. Leave your email and the number of cars: you hear first, and nothing is charged today.`} />
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
      <KitSticky title={lo !== null ? `From ${monthly(lo)} per car` : f.name} sub={f.available ? 'Installs are open' : f.launchNote} cta={cta} href="#waitlist" />
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
