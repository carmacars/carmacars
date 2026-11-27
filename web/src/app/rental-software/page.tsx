import { Crumbs } from '@/components/Crumbs';
import { Faq } from '@/components/Faq';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, faqLd, seoMeta, type Trail } from '@/features/seo/meta';
import { KitCta, KitHero, KitSection, KitSticky, KitTiles, KitToc, KitTrust } from '@/features/seo/kit/Kit';
import { Ico } from '@/features/seo/kit/icons';
import { FAQ, FEATURES, PORTALS, SOFTWARE } from '@/features/software/content';
import { SoftwareLeadForm } from '@/features/software/SoftwareLeadForm';
import { siteUrl } from '@/lib/site';

// r50 hotfix 2 (the owner): a page for car rental companies looking for software. Every portal and feature described,
// how it is built left out, no pricing (the form asks for it and makes a lead). Indexable, in the pages sitemap and in
// llms.txt, linked from no menu. Static: no database read.
export const revalidate = 86400;
const PATH = '/rental-software';
const trail: Trail = [['Home', '/'], ['Car rental software']];

export function generateMetadata() {
  return seoMeta({ title: SOFTWARE.title, description: SOFTWARE.description, path: PATH });
}

export default function RentalSoftware() {
  const url = siteUrl() + PATH;
  const ld = {
    '@type': 'Service', '@id': `${url}#service`, name: 'White-label car rental software', serviceType: 'Car rental management software', url, description: SOFTWARE.answer,
    provider: { '@id': `${siteUrl()}/#business` }, audience: { '@type': 'BusinessAudience', audienceType: 'Car rental companies' },
    hasOfferCatalog: { '@type': 'OfferCatalog', name: 'Portals and features', itemListElement: [...PORTALS.map((p) => p.name), ...FEATURES.map((f) => f.title)].map((name) => ({ '@type': 'Offer', itemOffered: { '@type': 'Service', name } })) }
  };
  const toc: Array<[string, string]> = [['Portals', 'portals'], ['Features', 'features'], ['Questions', 'faq'], ['Pricing', 'pricing']];
  return (
    <div className="p-landing sk" data-page="rental-software">
      <JsonLd graph={[breadcrumbLd(trail, PATH), faqLd(FAQ), ld]} />
      <KitHero kicker="For rental companies" icon="fleet" h1={SOFTWARE.h1} lead={SOFTWARE.lead} cta={<KitCta primary={['Ask for pricing', '#pricing']} secondary={['See the portals', '#portals']} />}
        note="White-label: your name, logo, colours and domain.">
        <Crumbs trail={trail} />
      </KitHero>
      <KitToc items={toc} />
      <div className="wrap landing__body">
        <section className="sk sk-sec" aria-label="In short"><p className="lead measure" data-testid="software-answer">{SOFTWARE.answer}</p></section>
        <KitTrust items={[['shield', 'Your brand on every page and email'], ['users', 'A portal for every role'], ['clock', 'Settings, not code changes'], ['star', 'Run daily by our own rental company']]} />
        <KitSection id="portals" kicker="Portals" h="One platform, a portal for everyone" p="Renters, the owners who supply cars, every staff role and the owners of the business each get their own.">
          <div className="stack-lg" data-testid="software-portals">
            {PORTALS.map((p) => (
              <article key={p.id} className="sk-tile" id={`portal-${p.id}`} aria-labelledby={`h-portal-${p.id}`} style={{ alignItems: 'flex-start' }}>
                <span className="sk-tile__ico"><Ico name={p.icon} /></span>
                <div className="stack"><h3 id={`h-portal-${p.id}`}>{p.name}</h3><p className="muted">{p.who}</p>
                  <ul className="measure">{p.points.map((x) => <li key={x}>{x}</li>)}</ul></div>
              </article>))}
          </div>
        </KitSection>
        <KitSection id="features" kicker="Features" h="What it does for you" p="The work a rental company does every day, done in one place.">
          <KitTiles items={FEATURES.map((f) => ({ icon: f.icon, title: f.title, text: f.text }))} />
          <div className="stack-lg" style={{ marginTop: 'var(--s-6)' }}>
            {FEATURES.map((f) => (
              <section key={f.id} id={`feature-${f.id}`} aria-labelledby={`h-feature-${f.id}`} className="stack">
                <h3 className="d4" id={`h-feature-${f.id}`}>{f.title}</h3>
                <ul className="measure">{f.points.map((x) => <li key={x}>{x}</li>)}</ul>
              </section>))}
          </div>
        </KitSection>
        <KitSection id="faq" kicker="Questions" h="Answers, before you ask"><Faq items={FAQ} /></KitSection>
        <KitSection id="pricing" kicker="Pricing" h="Pricing for your fleet" p="Tell us about your company. A person replies with pricing and a time for a walkthrough.">
          <div className="measure"><SoftwareLeadForm /></div>
        </KitSection>
      </div>
      <KitSticky title="Car rental software" sub="Pricing for your fleet, on request" cta="Ask for pricing" href="#pricing" />
    </div>
  );
}
