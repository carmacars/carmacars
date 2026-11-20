import Link from '@/components/Link';
import { Crumbs } from '@/components/Crumbs';
import { CtaBand } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, seoMeta, type Trail } from '@/features/seo/meta';
import { metaOr } from '@/features/seo/meta-fallback';
import { KitFacts, KitHero, KitCta, KitPrices, KitSection, KitSticky, KitToc, KitTrust } from '@/features/seo/kit/Kit';
import { Ico } from '@/features/seo/kit/icons';
import { serviceCards } from '@/features/services/catalog';
import { getAddons, getServiceFacts } from '@/features/services/data';
import { money } from '@/lib/format';
import { getSettings, siteUrl } from '@/lib/site';

// Everything CarmaCars does, on one page (release 48): each service with what it is, a price where the database has
// one, and the pages of its cluster. It is the hub the services module of every search page links to, so every service
// page is two clicks from any page. Prices come from the database; a service without a known price shows none.
export const revalidate = 3600;
const trail: Trail = [['Home', '/'], ['Services']];

export async function generateMetadata() {
  return metaOr(async () => {
    const s = await getSettings();
    return seoMeta({ title: `Services: car rental, GPS trackers, chauffeur, delivery | ${s.brand_name}`, path: '/services',
      description: `Everything ${s.brand_name} does in ${s.city}: car rental with delivery, the GPS tracker and kill switch, the owner program, a chauffeur, coverage and add-ons.`.slice(0, 170) });
  }, { title: 'Services' }, (m) => console.warn('services', m));
}

const UNIT: Record<string, string> = { per_day: 'a day', per_hour: 'an hour', per_trip: 'for the rental' };
export default async function Page() {
  const [f, s, addons] = await Promise.all([getServiceFacts(), getSettings(), getAddons()]);
  const cards = serviceCards(f);
  const priced = addons.filter((a) => a.price_cents);
  return (
    <div className="p-landing sk" data-page="services">
      <JsonLd graph={[breadcrumbLd(trail, '/services'), { '@type': 'ItemList', name: `${s.brand_name} services`, numberOfItems: cards.length,
        itemListElement: cards.map((c, i) => ({ '@type': 'ListItem', position: i + 1, name: c.title, url: siteUrl() + c.href.split('#')[0] })) }]} />
      <KitHero kicker="Services" icon="fleet" h1={`Everything ${s.brand_name} does`}
        lead={`${s.brand_name} rents cars in ${s.city}, delivers them, drives you, lists and manages owners' cars, and sells a GPS tracker with a kill switch for your own car. Each service, its price and its pages are below.`}
        cta={<KitCta primary={['Find a car', '/cars']} secondary={f.trackerOn ? ['GPS tracker and kill switch', '/trackers'] : undefined} />}>
        <Crumbs trail={trail} />
      </KitHero>
      <KitToc items={cards.map((c) => [c.title.split(':')[0]!.replace(/ and .*$/, ''), c.key] as [string, string])} />
      <div className="wrap landing__body">
        <div style={{ paddingTop: 'var(--s-5)' }}><KitTrust band items={[['shield', 'No payment to request'], ['clock', 'A person confirms every booking'], ['truck', 'Delivery across the area'], ['star', 'Every fee shown before you pay']]} /></div>
        {cards.map((c) => (
          <KitSection key={c.key} id={c.key} kicker={c.fact ?? undefined} h={c.title} p={c.line}>
            <div className="stack" style={{ gap: 'var(--s-4)' }}>
              {c.key === 'addons' && priced.length > 0 && (
                <KitPrices cards={priced.slice(0, 9).map((a) => ({ forWhom: a.name, amount: money(a.price_cents!), per: UNIT[a.pricing_unit] ?? '', points: [...(a.description ? [a.description] : []), ...(a.cap_cents ? [`At most ${money(a.cap_cents)} for the rental`] : [])] }))}
                  fine="Add-on prices are before HST and can depend on the car; your offer shows the exact line." />
              )}
              {c.key === 'trackers' && <KitFacts rows={[['Price', f.trackerPrice], ['When', f.trackerAvailable ? 'Installs are open' : `${f.trackerNote}. Waitlist and pre-orders are open`]]} />}
              {c.key === 'delivery' && <KitFacts rows={[['Delivery', f.deliveryFromCents ? `From ${money(f.deliveryFromCents)}` : null], ['Airports', f.airports.map((a) => a.name).join(', ') || null]]} />}
              {c.key === 'young' && <KitFacts rows={[['Minimum age', f.minAge ? String(f.minAge) : null], ['Licence', f.licence ? `Ontario ${f.licence}` : null]]} />}
              <ul className="sk-tiles" data-testid={`service-${c.key}`}>
                {c.more.map((m) => <li key={m.href} className="sk-tile"><span className="sk-tile__ico"><Ico name={c.icon} /></span><div><h3><Link prefetch={false} className="link" href={m.href}>{m.label}</Link></h3></div></li>)}
              </ul>
              <p><Link prefetch={false} className="btn btn--ghost" href={c.key === 'addons' ? '/cars' : c.href} data-service-go={c.key}>{c.key === 'addons' ? 'Pick a car and add them' : c.go}</Link></p>
            </div>
          </KitSection>
        ))}
      </div>
      <CtaBand h="Pick a car, send a request." p="No payment until we confirm the car and the price." />
      <KitSticky title="Pick a car, send a request" sub="No payment until we confirm" cta="Find a car" href="/cars" />
    </div>
  );
}
